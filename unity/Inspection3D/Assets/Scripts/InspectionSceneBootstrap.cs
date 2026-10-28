// InspectionSceneBootstrap.cs —— 运行时装配：把场景内容 + 交互组件接起来。
//
// 场景内容本身在 InspectionSceneBuilder 里（编辑器菜单和运行时共用同一份），
// 这里只负责「谁来调用它、以及把组件按正确顺序挂上」。
//
// 两种进入方式都要能用：
//   ① 打开仓库自带的 Assets/Scenes/Inspection.unity（场景里已经有地面/墙/机柜…），
//      按 Play → 直接就是现场，物体在 Hierarchy 里也看得见；
//   ② 新建一个空场景按 Play → 运行时兜底把现场种出来（老行为，保留）。
using UnityEngine;

public class InspectionSceneBootstrap : MonoBehaviour
{
    /// <summary>
    /// 场景里是否**已经**烘好了环境物体。
    /// 供编辑器生成器写入：烘焙场景里设为 true，运行时就不再重复生成一遍，
    /// 否则 Hierarchy 里会出现两套 Ground / Cabinet（第一版就踩过这个）。
    /// </summary>
    [SerializeField] private bool environmentAlreadyBuilt;

    private Camera _camera;

    /// <summary>
    /// 兜底入口：空场景直接按 Play 时，自动挂载并把现场种出来。
    /// 场景里已经有 __InspectionRoot（烘焙场景）时直接返回，交给它自己的 Awake 处理。
    /// </summary>
    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    private static void AutoMount()
    {
        if (GameObject.Find("__InspectionRoot") != null) return;
        var root = new GameObject("__InspectionRoot");
        root.AddComponent<InspectionSceneBootstrap>();
    }

    private void Awake()
    {
        if (environmentAlreadyBuilt)
        {
            // 烘焙场景：物体已在场景文件里，只把相机找出来即可。
            // 用 Camera.main 而不是 GetComponent：相机挂在 Player/PlayerCamera 下面。
            _camera = Camera.main;
            if (_camera == null)
            {
                var camGo = new GameObject("PlayerCamera");
                camGo.transform.SetParent(transform, false);
                camGo.transform.localPosition = new Vector3(0f, 1.6f, 0f);
                _camera = camGo.AddComponent<Camera>();
                _camera.tag = "MainCamera";
            }
        }
        else
        {
            InspectionSceneBuilder.ClearDefaultSceneObjects();
            _camera = InspectionSceneBuilder.Build(transform);
        }

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
        if (_hintStyle == null)
        {
            _hintStyle = new GUIStyle(GUI.skin.label) { fontSize = 14 };
        }
        GUI.Label(new Rect(12f, 10f, 720f, 24f),
            "WASD 移动 · 按住右键转视角 · 左键点击场景放置标记 · ESC 取消", _hintStyle);
    }
}
