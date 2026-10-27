// PlayerMover.cs —— 视角移动（题目 3.1.2：能移动并转动视角，查看场景不同位置）。
//
// 为什么用 CharacterController 而不是直接改 transform.position：
//   CharacterController 自带"贴地 + 不穿墙"的碰撞处理。手改 position 会穿墙，
//   走到机柜里就看不见场景了，演示时非常尴尬。
//
// 操作方式（Editor 与打包后一致）：
//   W/A/S/D 或方向键 —— 前后左右
//   按住鼠标右键拖动 —— 转动视角
//
// 为什么用"按住右键"而不是锁鼠标：Editor 里锁鼠标会让人切不回界面，
// 评审人在 Unity 里点一下 Play 就被困住，体验很差。
using UnityEngine;

[RequireComponent(typeof(CharacterController))]
public class PlayerMover : MonoBehaviour
{
    [Tooltip("移动速度（米/秒）。巡检是慢速观察，4 比 8 更像走路。")]
    public float moveSpeed = 4f;

    [Tooltip("视角灵敏度（度/像素）。")]
    public float lookSensitivity = 3f;

    [Tooltip("重力（米/秒²）。不施加重力时走下坡会飘起来。")]
    public float gravity = -20f;

    private CharacterController _controller;
    private float _pitch;      // 上下看的角度（限制在 ±85°，避免翻转）
    private float _vertical;   // 竖直速度

    private void Awake()
    {
        _controller = GetComponent<CharacterController>();
        // 起始朝向固定，保证每次运行视角一致（演示截图可复现）。
        _pitch = 0f;
    }

    private void Update()
    {
        Look();
        Move();
    }

    /// <summary>转视角：只有按住右键时才响应，避免 Editor 里误触。</summary>
    private void Look()
    {
        if (!Input.GetMouseButton(1)) return;

        var dx = Input.GetAxis("Mouse X") * lookSensitivity;
        var dy = Input.GetAxis("Mouse Y") * lookSensitivity;

        // 水平转：绕世界 Y 轴（角色整体转向）
        transform.Rotate(0f, dx, 0f, Space.Self);

        // 垂直转：只转相机，不转角色。用 Clamp 防止越过 90° 后画面倒过来。
        _pitch = Mathf.Clamp(_pitch - dy, -85f, 85f);
        var cam = GetComponentInChildren<Camera>();
        if (cam != null)
        {
            cam.transform.localEulerAngles = new Vector3(_pitch, 0f, 0f);
        }
    }

    /// <summary>移动：WASD/方向键，按角色朝向走。</summary>
    private void Move()
    {
        var h = Input.GetAxisRaw("Horizontal");
        var v = Input.GetAxisRaw("Vertical");
        var dir = (transform.right * h + transform.forward * v);
        if (dir.sqrMagnitude > 1f) dir.Normalize(); // 斜着走不该更快

        // 竖直方向：贴地时保留一点点向下的力，避免"悬空判定"抖动。
        if (_controller.isGrounded && _vertical < 0f) _vertical = -2f;
        _vertical += gravity * Time.deltaTime;

        var motion = dir * moveSpeed + Vector3.up * _vertical;
        _controller.Move(motion * Time.deltaTime);
    }
}
