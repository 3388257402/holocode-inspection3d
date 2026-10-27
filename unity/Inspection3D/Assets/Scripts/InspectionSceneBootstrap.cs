// InspectionSceneBootstrap.cs —— 用代码搭出整个虚拟巡检现场（题目 3.1.1）。
//
// 为什么用代码搭场景而不是让你在 Editor 里摆：
//   ① 你只需要「新建空场景 → 按 Play」就能看到完整场景，不用对着截图摆 20 分钟的方块；
//   ② 场景不依赖任何 .prefab / .unity 里的引用，clone 下来不会出现「引用丢失（Missing）」；
//   ③ 评审人能一眼看出场景是怎么构成的（题目不考察美术，但考察"是否正确使用射线检测"，
//      而射线能不能命中，取决于这些物体**有没有 Collider**——代码里明写，不靠默认行为）。
//
// 关键点：所有可点击的物体都用 `CreatePrimitive`，它自带 Collider；
//         标记球自己会把 Collider 删掉（见 PlacementController），避免"点标记叠标记"。
using UnityEngine;

public class InspectionSceneBootstrap : MonoBehaviour
{
    private Camera _camera;

    /// <summary>
    /// 自动挂载：只要按 Play，就会在当前场景里种出一个完整现场。
    ///
    /// 用 AfterSceneLoad：默认空场景自带 Main Camera 和 Directional Light，
    /// 这个时机它们已经存在，可以先把它们清掉，避免出现"两个相机/两个光源"导致的怪现象。
    /// </summary>
    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    private static void AutoMount()
    {
        if (GameObject.Find("__InspectionRoot") != null) return; // 防止重复种场景
        var root = new GameObject("__InspectionRoot");
        root.AddComponent<InspectionSceneBootstrap>();
    }

    private void Awake()
    {
        ClearDefaultSceneObjects();
        BuildEnvironment();
        BuildLighting();
        BuildPlayer();

        // ---- 组件装配顺序有讲究 ----
        // IssueFormUI 在 Awake 里会去找/挂 IssueApiClient，所以 api 必须先加。
        gameObject.AddComponent<IssueApiClient>();
        var form = gameObject.AddComponent<IssueFormUI>();
        var placement = gameObject.AddComponent<PlacementController>();

        placement.Init(_camera, form);
        // 提交成功 与 取消 都要移除未保存的标记（题目 3.1.8）。
        form.onSubmitted = placement.ClearPending;
        form.onCancelled = placement.ClearPending;

        Debug.Log("[巡检] WASD/方向键移动，按住鼠标右键转视角，左键点击场景放置标记。");
    }

    private GUIStyle _hintStyle; // 缓存：OnGUI 每帧会被调用多次，每次 new GUIStyle 会产生 GC 垃圾

    private void OnGUI()
    {
        // 操作提示常驻左上角：录演示视频时观众第一眼就知道怎么动。
        // 样式在第一次事件时创建，之后复用。
        if (_hintStyle == null)
        {
            _hintStyle = new GUIStyle(GUI.skin.label) { fontSize = 14 };
        }
        GUI.Label(new Rect(12f, 10f, 720f, 24f),
            "WASD 移动 · 按住右键转视角 · 左键点击场景放置标记 · ESC 取消", _hintStyle);
    }

    // ------------------------------------------------------------ 场景内容

    /// <summary>清掉默认空场景自带的相机与光源，保证"一套"。Destroy 是延迟生效的，所以后面新建不会冲突。</summary>
    private void ClearDefaultSceneObjects()
    {
        foreach (var cam in Camera.allCameras)
        {
            cam.gameObject.SetActive(false); // 先禁用，避免这一帧里出现两个 AudioListener
            Destroy(cam.gameObject);
        }
        foreach (var light in FindObjectsOfType<Light>())
        {
            if (light.type == LightType.Directional) Destroy(light.gameObject);
        }
    }

    private void BuildEnvironment()
    {
        // 地面：Plane 默认 10x10，放大 3 倍得到 30x30 的场地
        var ground = GameObject.CreatePrimitive(PrimitiveType.Plane);
        ground.name = "Ground";
        ground.transform.SetParent(transform, false);
        ground.transform.localScale = new Vector3(3f, 1f, 3f);
        Paint(ground, new Color(0.35f, 0.37f, 0.40f));

        // 四面墙（前/后/左/右）：把场地围合起来挡住人。
        // 为什么是四面而不是三面：只有三面时玩家可以直接走出地面边界，
        // 掉进无底空间后画面全黑，看起来像程序崩了。
        var wallColor = new Color(0.55f, 0.57f, 0.60f);
        MakeBox("Wall_Back", new Vector3(0f, 2f, 15f), new Vector3(30f, 4f, 0.3f), wallColor);
        MakeBox("Wall_Front", new Vector3(0f, 2f, -15f), new Vector3(30f, 4f, 0.3f), wallColor);
        MakeBox("Wall_Left", new Vector3(-15f, 2f, 0f), new Vector3(0.3f, 4f, 30f), wallColor);
        MakeBox("Wall_Right", new Vector3(15f, 2f, 0f), new Vector3(0.3f, 4f, 30f), wallColor);

        // 三个机柜（题目要求"至少两个可以观察或点击的场景对象"）
        MakeBox("Cabinet_1", new Vector3(-3f, 1f, 4f), new Vector3(1.4f, 2f, 0.9f), new Color(0.20f, 0.42f, 0.55f));
        MakeBox("Cabinet_2", new Vector3(0f, 1f, 4f), new Vector3(1.4f, 2f, 0.9f), new Color(0.20f, 0.42f, 0.55f));
        MakeBox("Cabinet_3", new Vector3(3f, 1f, 4f), new Vector3(1.4f, 2f, 0.9f), new Color(0.20f, 0.42f, 0.55f));

        // 设备台 + 一台"设备"，给场景多一点可标注的地方
        MakeBox("Bench", new Vector3(8f, 0.4f, 6f), new Vector3(4f, 0.8f, 1.4f), new Color(0.42f, 0.40f, 0.38f));
        MakeBox("Device_1", new Vector3(8f, 1.2f, 6f), new Vector3(0.8f, 0.8f, 0.8f), new Color(0.55f, 0.45f, 0.25f));

        // 管线：两根圆柱，顺便证明"非立方体也能被射线命中"
        MakeCylinder("Pipe_1", new Vector3(-8f, 2.4f, 8f), new Vector3(0.25f, 4f, 0.25f), Quaternion.Euler(0f, 0f, 90f),
            new Color(0.60f, 0.62f, 0.66f));
        MakeCylinder("Pipe_2", new Vector3(8f, 2.6f, 10f), new Vector3(0.25f, 5f, 0.25f), Quaternion.Euler(90f, 0f, 0f),
            new Color(0.60f, 0.62f, 0.66f));
    }

    private void BuildLighting()
    {
        var lightGo = new GameObject("Directional Light");
        lightGo.transform.SetParent(transform, false);
        var light = lightGo.AddComponent<Light>();
        light.type = LightType.Directional;
        light.intensity = 1.0f;
        light.color = new Color(1f, 0.97f, 0.92f);
        // 斜向下打光：有明暗变化，看得清立方体的面，而不是一片灰。
        lightGo.transform.rotation = Quaternion.Euler(50f, -30f, 0f);

        // 环境光：必须先切成 Flat 再设 ambientLight。
        // 默认 ambientMode = Skybox 时，ambientLight 这个值**完全不生效**（设了也没用），
        // 这是很容易误判成"设置没起作用"的坑。
        RenderSettings.ambientMode = UnityEngine.Rendering.AmbientMode.Flat;
        RenderSettings.ambientLight = new Color(0.35f, 0.36f, 0.40f);
    }

    private GameObject BuildPlayer()
    {
        var player = new GameObject("Player");
        player.transform.position = new Vector3(0f, 0.2f, -6f);

        var controller = player.AddComponent<CharacterController>();
        controller.height = 1.7f;
        controller.radius = 0.3f;
        controller.center = new Vector3(0f, 0.85f, 0f); // 让胶囊体站在地面上而不是陷进去
        controller.slopeLimit = 45f;
        controller.stepOffset = 0.3f;

        player.AddComponent<PlayerMover>();

        var camGo = new GameObject("PlayerCamera");
        camGo.transform.SetParent(player.transform, false);
        camGo.transform.localPosition = new Vector3(0f, 1.6f, 0f); // 视线高度

        _camera = camGo.AddComponent<Camera>();
        _camera.tag = "MainCamera";   // Camera.main / ScreenPointToRay 都依赖这个 tag
        _camera.fieldOfView = 65f;
        _camera.nearClipPlane = 0.05f; // 贴近墙面看标记时不会被裁掉
        camGo.AddComponent<AudioListener>();

        return player;
    }

    // ------------------------------------------------------------ 小工具

    private GameObject MakeBox(string name, Vector3 pos, Vector3 size, Color color)
    {
        var go = GameObject.CreatePrimitive(PrimitiveType.Cube);
        go.name = name;
        go.transform.SetParent(transform, false);
        go.transform.localPosition = pos;
        go.transform.localScale = size;
        Paint(go, color);
        return go;
    }

    private GameObject MakeCylinder(string name, Vector3 pos, Vector3 size, Quaternion rot, Color color)
    {
        var go = GameObject.CreatePrimitive(PrimitiveType.Cylinder);
        go.name = name;
        go.transform.SetParent(transform, false);
        go.transform.localPosition = pos;
        go.transform.localRotation = rot;
        go.transform.localScale = size;
        Paint(go, color);
        return go;
    }

    /// <summary>
    /// 上色。用 `renderer.material`（会创建材质实例）而不是 `sharedMaterial`：
    /// sharedMaterial 会改到内置材质资源本身，Editor 里停不下来、还会把默认材质染成灰色。
    ///
    /// 为什么要判断 `_BaseColor`：内置管线（Standard shader）的颜色属性叫 `_Color`，
    /// URP 的 `Lit` shader 叫 `_BaseColor`。只写 `material.color` 在 URP 工程里会**静默无效**
    /// （颜色改不动，也不报错）——"设置没生效"这类问题最费时间，所以两种都处理。
    /// </summary>
    private static void Paint(GameObject go, Color color)
    {
        var renderer = go.GetComponent<Renderer>();
        if (renderer == null) return;
        var mat = renderer.material;
        if (mat.HasProperty("_BaseColor")) mat.SetColor("_BaseColor", color);
        else mat.color = color;
    }
}
