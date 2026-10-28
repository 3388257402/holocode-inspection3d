// InspectionSceneMenu.cs —— 编辑器入口：把虚拟巡检现场**烘进 .unity 场景文件**。
//
// 为什么需要它（这是评审反馈直接带来的改动）：
//   上一版只有运行时的 `[RuntimeInitializeOnLoadMethod]`，物体是「按 Play 才生成」的。
//   评审打开工程时看到的是「空场景 + 相机 + 平行光」，从外部看等于**没搭场景**——
//   题目 3.1.1 要求「使用 Unity 基础对象搭建现场」，所以物体必须真的在场景文件里。
//
// 用法：
//   ① 编辑器菜单 Tools/巡检/生成并保存场景  → 生成 Assets/Scenes/Inspection.unity 并加入 Build Settings；
//   ② 命令行（无人值守，本项目就是这么生成的）：
//      Unity.exe -batchmode -quit -projectPath <工程> -executeMethod InspectionSceneMenu.BuildAndSave
//
// 场景内容与运行时兜底共用 InspectionSceneBuilder，避免「编辑器里看到的」和「Play 时看到的」不一致。
#if UNITY_EDITOR
using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

public static class InspectionSceneMenu
{
    private const string SceneDir = "Assets/Scenes";
    private const string ScenePath = SceneDir + "/Inspection.unity";

    [MenuItem("Tools/巡检/生成并保存场景")]
    public static void BuildAndSave()
    {
        // 新建空场景：不加载默认的 Main Camera / Directional Light，
        // 这样场景里只有我们亲手搭的东西（清理由 InspectionSceneBuilder 负责）。
        var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);

        // 先把根节点建出来，场景内容全部挂在它下面：
        // Hierarchy 里一眼就能看到一棵树，而不是二十个散落的物体。
        var rootGo = new GameObject("__InspectionRoot");
        rootGo.transform.position = Vector3.zero;

        // 环境 + 光照 + 玩家（含主相机、CharacterController、PlayerMover）
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

        Directory.CreateDirectory(SceneDir);
        bool saved = EditorSceneManager.SaveScene(scene, ScenePath);
        if (!saved)
        {
            Debug.LogError("[巡检] 场景保存失败: " + ScenePath);
            return;
        }

        // 加进 Build Settings 并排在第一，这样打包/运行默认打开的就是它。
        var scenes = new EditorBuildSettingsScene[] { new EditorBuildSettingsScene(ScenePath, true) };
        EditorBuildSettings.scenes = scenes;

        AssetDatabase.SaveAssets();
        AssetDatabase.Refresh();
        Debug.Log("[巡检] 场景已生成: " + ScenePath + "（层级见 Hierarchy 的 __InspectionRoot）");
    }
}
#endif
