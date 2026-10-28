// InspectionSceneMenu.cs —— 编辑器工具：把虚拟巡检现场**烘进 .unity 场景文件**，并提供可复跑的校验。
//
// 为什么需要它（这是评审反馈直接带来的改动）：
//   上一版只有运行时的 `[RuntimeInitializeOnLoadMethod]`，物体是「按 Play 才生成」的。
//   评审打开工程时看到的是「空场景 + 相机 + 平行光」，从外部看等于**没搭场景**——
//   题目 3.1.1 要求「使用 Unity 基础对象搭建现场」，所以物体必须真的在场景文件里。
//
// 用法：
//   ① 菜单 Tools/巡检/生成并保存场景     → 生成 Assets/Scenes/Inspection.unity 并加入 Build Settings；
//   ② 菜单 Tools/巡检/校验场景并出预览图 → 只读校验：数物体、出一张预览图（不改场景、不关编辑器）；
//   ③ 命令行（本项目就是这么生成的，注意：跑之前先关掉编辑器，同一工程被占用时 batchmode 会直接崩）：
//      Unity.exe -batchmode -quit -projectPath <工程> -executeMethod InspectionSceneMenu.BuildAndSave
//      Unity.exe -batchmode -quit -projectPath <工程> -executeMethod InspectionSceneMenu.VerifyAndRender
//
// 场景内容与运行时兜底共用 InspectionSceneBuilder，避免「编辑器里看到的」和「Play 时看到的」不一致。
#if UNITY_EDITOR
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

public static class InspectionSceneMenu
{
    private const string SceneDir = "Assets/Scenes";
    private const string ScenePath = SceneDir + "/Inspection.unity";

    [MenuItem("Tools/巡检/生成并保存场景")]
    public static void BuildAndSave()
    {
        // 新建空场景：不加载默认的 Main Camera / Directional Light，
        // 这样场景里只有我们亲手搭的东西。
        var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);

        // 所有物体挂在同一个根节点下：Hierarchy 里一眼看到一棵树，而不是二十个散落物体。
        var rootGo = new GameObject("__InspectionRoot");
        rootGo.transform.position = Vector3.zero;

        var cam = InspectionSceneBuilder.Build(rootGo.transform);
        if (cam != null) cam.gameObject.tag = "MainCamera";

        // 交互组件挂在根节点上；environmentAlreadyBuilt=true 让运行时不再重复生成环境。
        var bootstrap = rootGo.AddComponent<InspectionSceneBootstrap>();
        var so = new SerializedObject(bootstrap);
        var flag = so.FindProperty("environmentAlreadyBuilt");
        if (flag != null)
        {
            flag.boolValue = true;
            so.ApplyModifiedPropertiesWithoutUndo();
        }
        else
        {
            // 字段被改名时不要静默放过：没有这个标志，运行时会在烘焙场景上再长一套物体。
            Debug.LogError("[巡检] 没找到 environmentAlreadyBuilt 字段，场景会重复生成，请检查字段名。");
        }

        // 用 AssetDatabase 建目录，而不是 Directory.CreateDirectory("Assets/Scenes")：
        // 后者按**进程 CWD** 解析，从别的工作目录启动会在工程外造出野 Assets\Scenes。
        if (!AssetDatabase.IsValidFolder(SceneDir))
        {
            AssetDatabase.CreateFolder("Assets", "Scenes");
        }

        bool saved = EditorSceneManager.SaveScene(scene, ScenePath);
        if (!saved)
        {
            Debug.LogError("[巡检] 场景保存失败: " + ScenePath);
            return;
        }

        AddSceneToBuildSettings();

        AssetDatabase.SaveAssets();
        AssetDatabase.Refresh();
        Debug.Log("[巡检] 场景已生成: " + ScenePath + "（层级见 Hierarchy 的 __InspectionRoot）");
    }

    /// <summary>
    /// 把场景排进 Build Settings。**不整表覆盖**：使用者自己加过的场景不能被这个菜单清掉。
    /// 已存在（同 path）就保持原位，不存在才追加到末尾并设为启用。
    /// </summary>
    private static void AddSceneToBuildSettings()
    {
        var list = new List<EditorBuildSettingsScene>(EditorBuildSettings.scenes);
        bool exists = false;
        for (int i = 0; i < list.Count; i++)
        {
            if (list[i].path == ScenePath) { exists = true; break; }
        }
        if (!exists) list.Add(new EditorBuildSettingsScene(ScenePath, true));
        EditorBuildSettings.scenes = list.ToArray();
    }

    /// <summary>
    /// 打开已烘焙的场景、按名字校验物体是否齐全、再渲染一张预览图。
    ///
    /// 三条自查过的坑：
    ///   ① 绝不能在编辑器交互模式下调 EditorApplication.Exit —— 那会**把 Unity 直接关掉**（还带着未保存改动）。
    ///      所以只有 Application.isBatchMode 时才 Exit，交互模式只打日志。
    ///   ② 不能改烘焙场景里的相机再保存：那会把预览机位烘进仓库场景，进游戏的初始视角就废了。
    ///      所以这里用一台**临时相机**渲染，用完 DestroyImmediate，场景一点都不脏。
    ///   ③ 路径不能靠进程 CWD：预览图基于 Application.dataPath 算，目录用 AssetDatabase 建。
    /// </summary>
    [MenuItem("Tools/巡检/校验场景并出预览图")]
    public static void VerifyAndRender()
    {
        // 交互模式下先问用户要不要保存当前场景，避免直接丢掉别人正在改的东西。
        if (!Application.isBatchMode)
        {
            EditorSceneManager.SaveCurrentModifiedScenesIfUserWantsTo();
        }

        var scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        var root = GameObject.Find("__InspectionRoot");

        // 按**名字**校验，而不是数个数：数个数在场景正常增删时会假红，而且「14 个任意物体」也能通过。
        string[] required =
        {
            "Ground", "Wall_Back", "Wall_Front", "Wall_Left", "Wall_Right",
            "Cabinet_1", "Cabinet_2", "Cabinet_3", "Bench", "Device_1",
            "Pipe_1", "Pipe_2", "Player", "Directional Light"
        };
        var missing = new List<string>();
        var found = new List<string>();
        if (root != null)
        {
            var children = root.GetComponentsInChildren<Transform>(true);
            foreach (var t in children) found.Add(t.name);
        }
        foreach (var need in required) if (!found.Contains(need)) missing.Add(need);

        bool ok = root != null && missing.Count == 0;
        Debug.Log("[巡检] 场景=" + scene.name + " 物体总数=" + found.Count
                  + " 缺失=[" + string.Join(", ", missing.ToArray()) + "]");

        // 预览图：用临时相机 + 临时 RT，绝不碰场景里的相机。
        string pngPath = null;
        var cam = Camera.main;
        if (cam == null)
        {
            Debug.LogError("[巡检] 场景里没有 MainCamera，无法出预览图");
            ok = false;
        }
        else
        {
            var holder = new GameObject("__PreviewCamera");
            RenderTexture rt = null;
            Texture2D tex = null;
            try
            {
                var pv = holder.AddComponent<Camera>();
                pv.CopyFrom(cam);
                pv.transform.position = new Vector3(-10f, 8f, -10f);
                pv.transform.LookAt(new Vector3(0f, 1f, 4f));
                pv.clearFlags = CameraClearFlags.SolidColor;
                pv.backgroundColor = new Color(0.18f, 0.20f, 0.24f);

                const int w = 1280, h = 720;
                rt = new RenderTexture(w, h, 24);
                pv.targetTexture = rt;
                pv.Render();

                RenderTexture.active = rt;
                tex = new Texture2D(w, h, TextureFormat.RGB24, false);
                tex.ReadPixels(new Rect(0, 0, w, h), 0, 0);
                tex.Apply();
                RenderTexture.active = null;

                // 输出路径必须和 README 引用的那一张一致：仓库根/docs/scene-preview.png。
                // Application.dataPath = <工程>/Assets，上三级 = 仓库根（工程在 unity/Inspection3D）。
                // 用 dataPath 推，而不是进程 CWD —— batchmode 的 CWD 与从 Hub 打开时并不相同。
                var repoRoot = Path.GetFullPath(Path.Combine(Application.dataPath, "..", "..", ".."));
                var docsDir = Path.Combine(repoRoot, "docs");
                if (!Directory.Exists(docsDir)) Directory.CreateDirectory(docsDir);
                pngPath = Path.Combine(docsDir, "scene-preview.png");
                File.WriteAllBytes(pngPath, tex.EncodeToPNG());
                Debug.Log("[巡检] 预览图: " + pngPath);
            }
            catch (System.Exception ex)
            {
                Debug.LogError("[巡检] 预览图生成失败: " + ex.Message);
                ok = false;
            }
            finally
            {
                if (rt != null) { rt.Release(); Object.DestroyImmediate(rt); }
                if (tex != null) Object.DestroyImmediate(tex);
                Object.DestroyImmediate(holder);
            }
        }

        // 「图真的写到盘上了」也要算进结论：不然「预览失败」会被 exit 0 掩盖。
        if (pngPath == null || !File.Exists(pngPath) || new FileInfo(pngPath).Length == 0)
        {
            Debug.LogError("[巡检] 预览图未生成或为空");
            ok = false;
        }

        Debug.Log(ok ? "[巡检] 校验通过：场景物体齐全，预览图已生成" : "[巡检] 校验失败，见上面的缺失项/错误");

        if (Application.isBatchMode)
        {
            EditorApplication.Exit(ok ? 0 : 1);
        }
        // 交互模式：只留日志，不退出编辑器，也不保存场景（场景本来就没被改）。
    }
}
#endif
