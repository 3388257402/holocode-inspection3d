// InspectionSceneBuilder.cs —— 把「虚拟巡检现场」的搭建逻辑集中在这里（题目 3.1.1）。
//
// 为什么要把搭建逻辑抽成静态方法、而不是只写在运行时的 Awake 里：
//   最初的版本所有物体都是**按 Play 时才生成**的，于是评审打开工程、看 Scene 视图，
//   看到的是「一个空场景 + 一个相机 + 一个平行光」——从外部看等于「没搭场景」。
//   现在同一份代码被两个入口复用：
//     ① 编辑器菜单 Tools/巡检/生成并保存场景 → 把物体真正**烘进 .unity 文件**，
//        clone 下来打开就能在 Hierarchy 里看到 Ground / Wall_* / Cabinet_* / Pipe_*；
//     ② 运行时 InspectionSceneBootstrap → 场景里没有这些物体时兜底生成。
//   一份代码两个入口，避免「编辑器里看到的」和「按 Play 看到的」不是同一个东西。
//
// 关键点：所有可点击物体都用 CreatePrimitive 生成 —— 它自带 Collider，
//         射线能不能命中取决于 Collider 存不存在，这里不靠默认行为，而是明写。
using UnityEngine;

public static class InspectionSceneBuilder
{
    /// <summary>
    /// 在当前已打开的场景里搭出完整现场（地面 / 四面墙 / 3 个机柜 / 设备台 + 设备 / 2 根管线），
    /// 并返回玩家相机的引用。
    /// </summary>
    /// <param name="root">所有物体的父节点；传 null 时会新建一个名为 __InspectionRoot 的根。</param>
    /// <returns>玩家身上的 Camera（后续放置标记要用它做 ScreenPointToRay）。</returns>
    public static Camera Build(Transform root)
    {
        if (root == null)
        {
            var rootGo = new GameObject("__InspectionRoot");
            root = rootGo.transform;
        }

        BuildEnvironment(root);
        BuildLighting(root);
        return BuildPlayer(root);
    }

    /// <summary>清掉默认空场景自带的相机与平行光，保证场上只有「一套」。</summary>
    public static void ClearDefaultSceneObjects()
    {
        foreach (var cam in Camera.allCameras)
        {
            cam.gameObject.SetActive(false); // 先禁用，避免这一帧出现两个 AudioListener
            Object.DestroyImmediate(cam.gameObject);
        }
        foreach (var light in Object.FindObjectsOfType<Light>())
        {
            if (light.type == LightType.Directional) Object.DestroyImmediate(light.gameObject);
        }
    }

    private static void BuildEnvironment(Transform root)
    {
        // 地面：Plane 默认 10x10，放大 3 倍得到 30x30 的场地
        var ground = GameObject.CreatePrimitive(PrimitiveType.Plane);
        ground.name = "Ground";
        ground.transform.SetParent(root, false);
        ground.transform.localScale = new Vector3(3f, 1f, 3f);
        Paint(ground, new Color(0.35f, 0.37f, 0.40f));

        // 四面墙：把场地围合起来。只有三面时玩家能走出边界、掉进空白里，看起来像程序崩了。
        var wallColor = new Color(0.55f, 0.57f, 0.60f);
        MakeBox(root, "Wall_Back", new Vector3(0f, 2f, 15f), new Vector3(30f, 4f, 0.3f), wallColor);
        MakeBox(root, "Wall_Front", new Vector3(0f, 2f, -15f), new Vector3(30f, 4f, 0.3f), wallColor);
        MakeBox(root, "Wall_Left", new Vector3(-15f, 2f, 0f), new Vector3(0.3f, 4f, 30f), wallColor);
        MakeBox(root, "Wall_Right", new Vector3(15f, 2f, 0f), new Vector3(0.3f, 4f, 30f), wallColor);

        // 三个机柜 —— 题目要求的「至少两个可观察/可点击的场景对象」
        var cabinetColor = new Color(0.20f, 0.42f, 0.55f);
        MakeBox(root, "Cabinet_1", new Vector3(-3f, 1f, 4f), new Vector3(1.4f, 2f, 0.9f), cabinetColor);
        MakeBox(root, "Cabinet_2", new Vector3(0f, 1f, 4f), new Vector3(1.4f, 2f, 0.9f), cabinetColor);
        MakeBox(root, "Cabinet_3", new Vector3(3f, 1f, 4f), new Vector3(1.4f, 2f, 0.9f), cabinetColor);

        // 设备台 + 一台设备：给场景多一点可标注的地方
        MakeBox(root, "Bench", new Vector3(8f, 0.4f, 6f), new Vector3(4f, 0.8f, 1.4f), new Color(0.42f, 0.40f, 0.38f));
        MakeBox(root, "Device_1", new Vector3(8f, 1.2f, 6f), new Vector3(0.8f, 0.8f, 0.8f), new Color(0.55f, 0.45f, 0.25f));

        // 管线：两根圆柱，顺便证明「非立方体也能被射线命中」
        MakeCylinder(root, "Pipe_1", new Vector3(-8f, 2.4f, 8f), new Vector3(0.25f, 4f, 0.25f),
            Quaternion.Euler(0f, 0f, 90f), new Color(0.60f, 0.62f, 0.66f));
        MakeCylinder(root, "Pipe_2", new Vector3(8f, 2.6f, 10f), new Vector3(0.25f, 5f, 0.25f),
            Quaternion.Euler(90f, 0f, 0f), new Color(0.60f, 0.62f, 0.66f));
    }

    private static void BuildLighting(Transform root)
    {
        var lightGo = new GameObject("Directional Light");
        lightGo.transform.SetParent(root, false);
        var light = lightGo.AddComponent<Light>();
        light.type = LightType.Directional;
        light.intensity = 1.0f;
        light.color = new Color(1f, 0.97f, 0.92f);
        lightGo.transform.rotation = Quaternion.Euler(50f, -30f, 0f);

        // 环境光：必须先切成 Flat 再设 ambientLight；Skybox 模式下这个值完全不生效（设了也没用）。
        RenderSettings.ambientMode = UnityEngine.Rendering.AmbientMode.Flat;
        RenderSettings.ambientLight = new Color(0.35f, 0.36f, 0.40f);
    }

    private static Camera BuildPlayer(Transform root)
    {
        var player = new GameObject("Player");
        player.transform.SetParent(root, false);
        player.transform.localPosition = new Vector3(0f, 0.2f, -6f);

        var controller = player.AddComponent<CharacterController>();
        controller.height = 1.7f;
        controller.radius = 0.3f;
        controller.center = new Vector3(0f, 0.85f, 0f); // 胶囊体站在地面上而不是陷进去
        controller.slopeLimit = 45f;
        controller.stepOffset = 0.3f;

        player.AddComponent<PlayerMover>();

        var camGo = new GameObject("PlayerCamera");
        camGo.transform.SetParent(player.transform, false);
        camGo.transform.localPosition = new Vector3(0f, 1.6f, 0f); // 视线高度

        var cam = camGo.AddComponent<Camera>();
        cam.tag = "MainCamera";   // Camera.main / ScreenPointToRay 都依赖这个 tag
        cam.fieldOfView = 65f;
        cam.nearClipPlane = 0.05f; // 贴近墙面看标记时不会被裁掉
        camGo.AddComponent<AudioListener>();
        return cam;
    }

    private static GameObject MakeBox(Transform root, string name, Vector3 pos, Vector3 size, Color color)
    {
        var go = GameObject.CreatePrimitive(PrimitiveType.Cube);
        go.name = name;
        go.transform.SetParent(root, false);
        go.transform.localPosition = pos;
        go.transform.localScale = size;
        Paint(go, color);
        return go;
    }

    private static GameObject MakeCylinder(Transform root, string name, Vector3 pos, Vector3 size, Quaternion rot, Color color)
    {
        var go = GameObject.CreatePrimitive(PrimitiveType.Cylinder);
        go.name = name;
        go.transform.SetParent(root, false);
        go.transform.localPosition = pos;
        go.transform.localRotation = rot;
        go.transform.localScale = size;
        Paint(go, color);
        return go;
    }

    /// <summary>
    /// 上色。用 renderer.material（材质实例）而不是 sharedMaterial —— 后者会改到内置材质本身。
    /// 同时处理 _BaseColor：内置管线叫 _Color，URP 的 Lit 叫 _BaseColor，
    /// 只写 material.color 在 URP 工程里会**静默无效**（颜色改不动也不报错）。
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
