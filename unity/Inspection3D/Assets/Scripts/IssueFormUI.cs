// IssueFormUI.cs —— 上报表单（题目 3.1.5 / 3.1.6）。
//
// 为什么用**代码**搭 uGUI，而不是让你在 Editor 里拖预制体：
//   ① 你只需要一个空场景按 Play 就能跑，不会因为"忘了挂引用"而 NullReference；
//   ② 评审人 clone 下来不用对着截图摆 UI；
//   ③ 拖拽产生的 .prefab 是这个作业里最容易出错、又最没技术含量的部分。
//
// 表单只有四个控件：标题（必填）、描述（可选）、优先级（点击循环 low→medium→high）、提交/取消。
// 优先级用"点一下换一个"而不是 Dropdown：Dropdown 需要拖一个模板对象，代码里搭很容易缺引用，
// 而题目只要求三档可选，循环按钮同样满足且不可能因为预制体缺失而崩。
using System;
using System.Collections;
using UnityEngine;
using UnityEngine.EventSystems;
using UnityEngine.UI;

public class IssueFormUI : MonoBehaviour
{
    /// <summary>提交成功后由 PlacementController 清掉未保存的标记。</summary>
    public Action onSubmitted;
    /// <summary>取消后同样要清标记（题目 3.1.8：取消填写后应移除未保存标记）。</summary>
    public Action onCancelled;

    public bool IsOpen => _panel != null && _panel.activeSelf;

    private IssueApiClient _api;
    private GameObject _panel;
    private InputField _titleInput;
    private InputField _descriptionInput;
    private Button _priorityButton;
    private Text _priorityLabel;
    private Text _statusText;
    private Text _hintText;
    private Coroutine _hintRoutine;

    private int _priorityIndex = 1; // 默认 medium：巡检里"中等"最常见，少让用户点一次
    private Vector3 _pendingPosition;

    private void Awake()
    {
        _api = gameObject.GetComponent<IssueApiClient>();
        if (_api == null) _api = gameObject.AddComponent<IssueApiClient>();
        BuildUi();
    }

    // ---------------------------------------------------------------- 对外

    /// <summary>打开表单并记录本次要上报的坐标。</summary>
    public void Open(Vector3 worldPosition)
    {
        _pendingPosition = worldPosition;
        _titleInput.text = "";
        _descriptionInput.text = "";
        _priorityIndex = 1;
        RefreshPriorityLabel();
        SetStatus("", Color.white);
        ShowHint("已放置标记 " + Format(_pendingPosition) + "，填写后提交。");
        _panel.SetActive(true);
        // 自动聚焦标题：少一次点击，且避免用户直接点提交看到"标题不能为空"。
        _titleInput.Select();
        _titleInput.ActivateInputField();
    }

    /// <summary>取消填写：关闭表单并通知外部移除标记。</summary>
    public void Cancel()
    {
        if (!IsOpen) return;
        _panel.SetActive(false);
        onCancelled?.Invoke();
    }

    /// <summary>表单之外的轻提示（例如"这里没有可标注的表面"）。3 秒后自动消失。</summary>
    public void ShowHint(string message)
    {
        if (_hintText == null) return;
        _hintText.text = message;
        if (_hintRoutine != null) StopCoroutine(_hintRoutine);
        _hintRoutine = StartCoroutine(HideHintLater());
    }

    // ---------------------------------------------------------------- 内部

    private IEnumerator HideHintLater()
    {
        yield return new WaitForSeconds(3f);
        if (_hintText != null) _hintText.text = "";
        _hintRoutine = null;
    }

    private void RefreshPriorityLabel()
    {
        var value = ApiConfig.Priorities[_priorityIndex];
        if (_priorityLabel != null) _priorityLabel.text = "优先级：" + value;
    }

    private void CyclePriority()
    {
        _priorityIndex = (_priorityIndex + 1) % ApiConfig.Priorities.Length;
        RefreshPriorityLabel();
    }

    private void Submit()
    {
        var title = _titleInput.text != null ? _titleInput.text.Trim() : "";
        if (string.IsNullOrEmpty(title))
        {
            // 前端先挡一次：不用等网络往返才知道标题没填（后端也会挡，两层都要有）。
            SetStatus("标题不能为空", new Color(1f, 0.45f, 0.45f));
            _titleInput.Select();
            return;
        }

        var payload = new IssuePayload
        {
            title = title,
            description = _descriptionInput.text != null ? _descriptionInput.text.Trim() : "",
            priority = ApiConfig.Priorities[_priorityIndex],
            x = _pendingPosition.x,
            y = _pendingPosition.y,
            z = _pendingPosition.z,
        };

        SetStatus("上报中…", Color.white);
        StartCoroutine(_api.Submit(payload, OnSubmitResult));
    }

    private void OnSubmitResult(IssueApiClient.Result result)
    {
        if (result.ok)
        {
            // 成功后立刻关表单 + 清标记：留着标记会让人以为"还没提交成功"。
            SetStatus("上报成功", new Color(0.4f, 1f, 0.5f));
            _panel.SetActive(false);
            ShowHint("上报成功（issue id " + result.issueId + "）");
            onSubmitted?.Invoke();
        }
        else
        {
            // 失败时**保留表单和标记**：用户改完可以直接重试，不用重新点场景。
            SetStatus(result.error, new Color(1f, 0.45f, 0.45f));
        }
    }

    private void SetStatus(string message, Color color)
    {
        if (_statusText == null) return;
        _statusText.text = message;
        _statusText.color = color;
    }

    private static string Format(Vector3 p)
    {
        return string.Format("({0:0.00}, {1:0.00}, {2:0.00})", p.x, p.y, p.z);
    }

    // ---------------------------------------------------------------- 搭界面

    private void BuildUi()
    {
        EnsureEventSystem();

        var canvasGo = new GameObject("InspectionCanvas", typeof(Canvas), typeof(CanvasScaler), typeof(GraphicRaycaster));
        canvasGo.transform.SetParent(transform, false);
        var canvas = canvasGo.GetComponent<Canvas>();
        canvas.renderMode = RenderMode.ScreenSpaceOverlay;

        var scaler = canvasGo.GetComponent<CanvasScaler>();
        scaler.uiScaleMode = CanvasScaler.ScaleMode.ScaleWithScreenSize;
        scaler.referenceResolution = new Vector2(1280f, 720f);
        scaler.matchWidthOrHeight = 0.5f;

        var font = LoadFont();

        // ---- 表单面板（右侧）----
        _panel = MakePanel(canvasGo.transform, "FormPanel",
            new Vector2(1f, 1f), new Vector2(-16f, -16f), new Vector2(420f, 400f),
            new Color(0.10f, 0.12f, 0.16f, 0.94f));

        var layout = _panel.AddComponent<VerticalLayoutGroup>();
        layout.padding = new RectOffset(16, 16, 16, 16);
        layout.spacing = 8f;
        layout.childAlignment = TextAnchor.UpperLeft;
        layout.childControlWidth = true;
        layout.childControlHeight = false;
        layout.childForceExpandWidth = true;
        layout.childForceExpandHeight = false;

        MakeLabel(_panel.transform, font, "上报问题", 20, Color.white, 28f);
        MakeLabel(_panel.transform, font, "标题（必填）", 13, new Color(0.75f, 0.78f, 0.85f), 18f);
        _titleInput = MakeInput(_panel.transform, font, "例如：1 号机柜温度异常", 34f);

        MakeLabel(_panel.transform, font, "描述（可选）", 13, new Color(0.75f, 0.78f, 0.85f), 18f);
        _descriptionInput = MakeInput(_panel.transform, font, "例如：机柜右侧温度明显偏高", 34f);

        // 优先级：点一下换一档
        _priorityButton = MakeButton(_panel.transform, font, "优先级：medium", 34f,
            new Color(0.18f, 0.22f, 0.30f), CyclePriority);
        _priorityLabel = _priorityButton.GetComponentInChildren<Text>();

        // 提交 / 取消（同一行，用 HorizontalLayoutGroup 排版，避免手算坐标）
        var row = new GameObject("Buttons", typeof(RectTransform), typeof(HorizontalLayoutGroup), typeof(LayoutElement));
        row.transform.SetParent(_panel.transform, false);
        var rowLayout = row.GetComponent<HorizontalLayoutGroup>();
        rowLayout.spacing = 8f;
        rowLayout.childForceExpandWidth = true;
        rowLayout.childControlWidth = true;
        rowLayout.childControlHeight = true;
        row.GetComponent<LayoutElement>().minHeight = 38f;

        MakeButton(row.transform, font, "提交", 38f, new Color(0.15f, 0.45f, 0.30f), Submit);
        MakeButton(row.transform, font, "取消", 38f, new Color(0.35f, 0.20f, 0.20f), Cancel);

        _statusText = MakeLabel(_panel.transform, font, "", 13, Color.white, 46f);

        // ---- 底部轻提示 ----
        var hintGo = new GameObject("Hint", typeof(RectTransform), typeof(Text));
        hintGo.transform.SetParent(canvasGo.transform, false);
        var hintRect = hintGo.GetComponent<RectTransform>();
        hintRect.anchorMin = new Vector2(0f, 0f);
        hintRect.anchorMax = new Vector2(1f, 0f);
        hintRect.pivot = new Vector2(0.5f, 0f);
        hintRect.anchoredPosition = new Vector2(0f, 12f);
        hintRect.sizeDelta = new Vector2(-32f, 28f);
        _hintText = hintGo.GetComponent<Text>();
        _hintText.font = font;
        _hintText.fontSize = 15;
        _hintText.color = new Color(1f, 0.95f, 0.7f);
        _hintText.alignment = TextAnchor.MiddleCenter;
        _hintText.text = "";

        _panel.SetActive(false);
    }

    /// <summary>
    /// 取内置字体。
    /// 为什么要 try 两种名字：Unity 2022 起内置字体从 "Arial.ttf" 改名为 "LegacyRuntime.ttf"，
    /// 写死旧名字在 2022+ 会返回 null → 所有文字都不显示（看起来像"界面没做出来"）。
    /// </summary>
    private static Font LoadFont()
    {
        var font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
        if (font == null) font = Resources.GetBuiltinResource<Font>("Arial.ttf");
        if (font == null) font = Font.CreateDynamicFontFromOSFont("Arial", 16);
        return font;
    }

    private static void EnsureEventSystem()
    {
        if (EventSystem.current != null) return;
        // 没有 EventSystem，uGUI 的按钮和输入框全部点不动——
        // 这个现象很像"UI 没渲染"，其实是没事件系统。
        new GameObject("EventSystem", typeof(EventSystem), typeof(StandaloneInputModule));
    }

    private static GameObject MakePanel(Transform parent, string name, Vector2 anchor, Vector2 anchoredPos, Vector2 size, Color color)
    {
        var go = new GameObject(name, typeof(RectTransform), typeof(Image));
        go.transform.SetParent(parent, false);
        var rect = go.GetComponent<RectTransform>();
        rect.anchorMin = anchor;
        rect.anchorMax = anchor;
        rect.pivot = new Vector2(1f, 1f);
        rect.anchoredPosition = anchoredPos;
        rect.sizeDelta = size;
        go.GetComponent<Image>().color = color;
        return go;
    }

    private static Text MakeLabel(Transform parent, Font font, string text, int size, Color color, float height)
    {
        var go = new GameObject("Label", typeof(RectTransform), typeof(Text), typeof(LayoutElement));
        go.transform.SetParent(parent, false);
        var t = go.GetComponent<Text>();
        t.font = font;
        t.fontSize = size;
        t.color = color;
        t.text = text;
        t.alignment = TextAnchor.MiddleLeft;
        t.horizontalOverflow = HorizontalWrapMode.Wrap;
        t.verticalOverflow = VerticalWrapMode.Truncate;
        go.GetComponent<LayoutElement>().minHeight = height;
        return t;
    }

    private static InputField MakeInput(Transform parent, Font font, string placeholderText, float height)
    {
        var go = new GameObject("Input", typeof(RectTransform), typeof(Image), typeof(InputField), typeof(LayoutElement));
        go.transform.SetParent(parent, false);
        go.GetComponent<Image>().color = new Color(0.16f, 0.19f, 0.24f);
        go.GetComponent<LayoutElement>().minHeight = height;

        var textGo = new GameObject("Text", typeof(RectTransform), typeof(Text));
        textGo.transform.SetParent(go.transform, false);
        StretchWithPadding(textGo.GetComponent<RectTransform>(), 8f);
        var text = textGo.GetComponent<Text>();
        text.font = font;
        text.fontSize = 14;
        text.color = Color.white;
        text.supportRichText = false; // 用户输入 "<b>" 之类的字符不该被当成富文本
        text.alignment = TextAnchor.MiddleLeft;

        var phGo = new GameObject("Placeholder", typeof(RectTransform), typeof(Text));
        phGo.transform.SetParent(go.transform, false);
        StretchWithPadding(phGo.GetComponent<RectTransform>(), 8f);
        var ph = phGo.GetComponent<Text>();
        ph.font = font;
        ph.fontSize = 14;
        ph.color = new Color(0.55f, 0.58f, 0.65f);
        ph.text = placeholderText;
        ph.alignment = TextAnchor.MiddleLeft;

        var input = go.GetComponent<InputField>();
        input.textComponent = text;
        input.placeholder = ph;
        input.targetGraphic = go.GetComponent<Image>();
        return input;
    }

    private static Button MakeButton(Transform parent, Font font, string label, float height, Color color, Action onClick)
    {
        var go = new GameObject("Button", typeof(RectTransform), typeof(Image), typeof(Button), typeof(LayoutElement));
        go.transform.SetParent(parent, false);
        go.GetComponent<Image>().color = color;
        go.GetComponent<LayoutElement>().minHeight = height;

        var textGo = new GameObject("Text", typeof(RectTransform), typeof(Text));
        textGo.transform.SetParent(go.transform, false);
        StretchWithPadding(textGo.GetComponent<RectTransform>(), 4f);
        var text = textGo.GetComponent<Text>();
        text.font = font;
        text.fontSize = 15;
        text.color = Color.white;
        text.text = label;
        text.alignment = TextAnchor.MiddleCenter;

        var button = go.GetComponent<Button>();
        // 用代码注册回调而不是拖 OnClick：拖拽引用是最容易在交付时丢失的东西。
        button.onClick.AddListener(() => onClick());
        return button;
    }

    private static void StretchWithPadding(RectTransform rect, float padding)
    {
        rect.anchorMin = Vector2.zero;
        rect.anchorMax = Vector2.one;
        rect.offsetMin = new Vector2(padding, padding);
        rect.offsetMax = new Vector2(-padding, -padding);
    }
}
