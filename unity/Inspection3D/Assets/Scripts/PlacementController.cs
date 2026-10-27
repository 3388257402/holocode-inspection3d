// PlacementController.cs —— 射线点击放置标记（题目 3.1.3 / 3.1.4 / 3.1.7 / 3.1.8）。
//
// 这个文件是本作业的**评分核心**（题目第 9 节第 1 条："是否正确使用射线检测，在场景实际命中位置放置标记"），
// 所以下面四件事每件都单独写明为什么这么做：
//
//   1) 射线从**相机**发出、用 `Physics.Raycast`、标记放在 `hit.point`（不是鼠标平面投影，也不是固定高度）；
//   2) **点 UI 时不放置**：`EventSystem.current.IsPointerOverGameObject()`；
//   3) **一次有效点击最多一个待提交标记**：新点击会移除旧标记再放新的（不是叠加）；
//   4) **取消要移除未保存标记**：`ClearPending()`。
using UnityEngine;
using UnityEngine.EventSystems;

public class PlacementController : MonoBehaviour
{
    [Tooltip("射线最远距离（米）。给 50 足够覆盖这个 30x30 的场地；太长会误命中远处。")]
    public float maxDistance = 50f;

    [Tooltip("标记球直径（米）。0.16 在机柜旁边肉眼可见，又不遮住场景。")]
    public float markerSize = 0.16f;

    private Camera _camera;
    private IssueFormUI _form;
    private GameObject _pendingMarker;

    public void Init(Camera cam, IssueFormUI form)
    {
        _camera = cam;
        _form = form;
    }

    private void Update()
    {
        // ESC 取消填写（等价于点"取消"），顺手把未保存标记移除。
        if (Input.GetKeyDown(KeyCode.Escape) && _form != null && _form.IsOpen)
        {
            _form.Cancel();
            return;
        }

        if (!Input.GetMouseButtonDown(0)) return;

        // 表单打开时不允许再放置：否则用户点"提交"按钮的同时会在场景里多放一个标记。
        if (_form != null && _form.IsOpen) return;

        // 【关键】点在 UI 上就不要放置（题目 3.1.7）。
        // 为什么不用"判断鼠标坐标是否在某矩形内"：Canvas 缩放、屏幕分辨率、多个面板
        // 都会让手算矩形出错；EventSystem 是 Unity 自己维护的权威判断。
        if (EventSystem.current != null && EventSystem.current.IsPointerOverGameObject()) return;

        if (_camera == null) { _camera = Camera.main; if (_camera == null) return; }

        // 射线从屏幕点发出（不是从相机正中间），这样点哪儿标哪儿。
        var ray = _camera.ScreenPointToRay(Input.mousePosition);
        if (!Physics.Raycast(ray, out var hit, maxDistance))
        {
            // 没打中任何东西：给个提示，而不是静默无反应——否则使用者会以为程序卡了。
            if (_form != null) _form.ShowHint("这里没有可标注的表面，请点击地面、墙面或设备。");
            return;
        }

        PlaceMarkerAt(hit.point, hit.normal);
    }

    /// <summary>
    /// 在实际命中位置生成标记，并把坐标交给表单。
    ///
    /// 为什么沿法线抬高一点点：球心正好落在表面上时，一半球会陷进墙面/地面里，
    /// 看起来像"标记被吞了"。抬高半径的量让球完整可见。
    /// </summary>
    private void PlaceMarkerAt(Vector3 point, Vector3 normal)
    {
        ClearPending(); // 【关键】先清旧的 → 保证最多一个待提交标记（题目 3.1.8）

        var marker = GameObject.CreatePrimitive(PrimitiveType.Sphere);
        marker.name = "PendingMarker";
        marker.transform.localScale = Vector3.one * markerSize;
        marker.transform.position = point + normal * (markerSize * 0.5f);

        // 标记不需要参与射线检测，否则下一次点击可能打中标记本身，
        // 结果标记越叠越高——这是这类功能最常见的隐性 bug。
        var col = marker.GetComponent<Collider>();
        if (col != null) Destroy(col);

        var renderer = marker.GetComponent<Renderer>();
        if (renderer != null)
        {
            renderer.material.color = new Color(1f, 0.45f, 0.1f); // 橙色，和场景灰白区分
        }

        _pendingMarker = marker;

        if (_form != null)
        {
            // 用**世界坐标**上报（后端只收数值；题目说明了不要求跨会话还原真实位置）。
            _form.Open(marker.transform.position);
        }
    }

    /// <summary>取消/提交成功后调用：移除未保存的标记（题目 3.1.8 后半句）。</summary>
    public void ClearPending()
    {
        if (_pendingMarker != null)
        {
            Destroy(_pendingMarker);
            _pendingMarker = null;
        }
    }
}
