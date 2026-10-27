import { useCallback, useEffect, useMemo, useState } from "react";
import { ApiError, API_BASE, listIssues, updateStatus } from "./api";
import type { Issue, Status } from "./types";

/**
 * 状态的中文显示。注意：**只影响显示**，接口里的值永远是 open/in_progress/resolved
 * （题目要求三端字段一致，前端不能自己发明 `进行中` 这种值传回去）。
 */
const STATUS_LABEL: Record<Status, string> = {
  open: "待处理",
  in_progress: "处理中",
  resolved: "已解决",
};

const PRIORITY_LABEL: Record<Issue["priority"], string> = {
  low: "低",
  medium: "中",
  high: "高",
};

const STATUS_ORDER: Status[] = ["open", "in_progress", "resolved"];

export function App(): JSX.Element {
  const [issues, setIssues] = useState<Issue[]>([]);
  const [loading, setLoading] = useState(true);
  /** 加载失败的说明。**非空时页面显示错误块而不是白屏**（题目 3.2.4 明确要求）。 */
  const [loadError, setLoadError] = useState<string | null>(null);
  /** 改状态失败的说明，与加载失败分开：一种是"看不到数据"，一种是"改不动"。 */
  const [actionError, setActionError] = useState<string | null>(null);
  /** 正在改的那一条的 id：用来禁用下拉框，避免连点产生两次 PATCH。 */
  const [busyId, setBusyId] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const items = await listIssues();
      setIssues(items);
      setLoadError(null);
    } catch (err) {
      setLoadError(describe(err));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const onStatusChange = useCallback(async (issue: Issue, next: Status) => {
    if (next === issue.status) return;
    setBusyId(issue.id);
    setActionError(null);
    // 乐观更新：先改界面再发请求。网络慢时用户不会觉得"点了没反应"；
    // 失败则用服务端状态回滚（见 catch），而不是留下一屏假数据。
    setIssues((prev) => prev.map((it) => (it.id === issue.id ? { ...it, status: next } : it)));
    try {
      const updated = await updateStatus(issue.id, next);
      setIssues((prev) => prev.map((it) => (it.id === updated.id ? updated : it)));
    } catch (err) {
      setIssues((prev) =>
        prev.map((it) => (it.id === issue.id ? { ...it, status: issue.status } : it)),
      );
      setActionError(describe(err));
    } finally {
      setBusyId(null);
    }
  }, []);

  const counts = useMemo(() => {
    const base: Record<Status, number> = { open: 0, in_progress: 0, resolved: 0 };
    for (const it of issues) base[it.status] += 1;
    return base;
  }, [issues]);

  /** 页面加载时 index.html 记录的"地址参数无效"提示（有值就说明发生了静默回退）。 */
  const [apiWarning] = useState<string | null>(() => {
    const w = (window as unknown as { __INSPECTION_API_WARNING__?: unknown })
      .__INSPECTION_API_WARNING__;
    return typeof w === "string" && w.trim() !== "" ? w : null;
  });

  return (
    <main className="page">
      <header className="head">
        <div>
          <h1>园区巡检 · 管理端</h1>
          <p className="sub">
            后端 <code>{API_BASE}</code>
          </p>
        </div>
        <button className="btn" onClick={() => void refresh()} disabled={loading}>
          {loading ? "加载中…" : "刷新"}
        </button>
      </header>

      {apiWarning && (
        <div className="banner banner-warn" role="alert">
          <strong>后端地址参数无效</strong>
          <p>{apiWarning}</p>
          <p className="hint">
            上面显示的就是**实际**在用的地址——不要把"回退到默认地址"误当成"连上了你的后端"。
          </p>
        </div>
      )}

      <section className="stats">
        {STATUS_ORDER.map((s) => (
          <div key={s} className={`stat stat-${s}`}>
            <span className="stat-label">{STATUS_LABEL[s]}</span>
            <span className="stat-value">{counts[s]}</span>
          </div>
        ))}
      </section>

      {loadError && (
        <div className="banner banner-error" role="alert">
          <strong>加载失败</strong>
          <p>{loadError}</p>
          <p className="hint">
            检查后端是否在运行（<code>cd backend &amp;&amp; go run .</code>），以及
            <code>VITE_API_BASE</code> 是否指向正确地址。
          </p>
        </div>
      )}

      {actionError && (
        <div className="banner banner-warn" role="alert">
          <strong>状态修改失败</strong>
          <p>{actionError}</p>
        </div>
      )}

      {loading && issues.length === 0 ? (
        <p className="empty">正在加载问题列表…</p>
      ) : issues.length === 0 && !loadError ? (
        <p className="empty">还没有上报的问题。用 Unity 在真机放置一个标记试试。</p>
      ) : (
        <table className="table">
          <thead>
            <tr>
              <th>标题</th>
              <th>优先级</th>
              <th>状态</th>
              <th>位置</th>
              <th>上报时间</th>
            </tr>
          </thead>
          <tbody>
            {issues.map((issue) => (
              <tr key={issue.id} className={`row-priority-${issue.priority}`}>
                <td>
                  <div className="title">{issue.title}</div>
                  {issue.description && <div className="desc">{issue.description}</div>}
                </td>
                <td>
                  <span className={`pill pill-${issue.priority}`}>
                    {PRIORITY_LABEL[issue.priority]}
                  </span>
                </td>
                <td>
                  <select
                    className={`select select-${issue.status}`}
                    value={issue.status}
                    disabled={busyId === issue.id}
                    onChange={(e) => void onStatusChange(issue, e.target.value as Status)}
                  >
                    {STATUS_ORDER.map((s) => (
                      <option key={s} value={s}>
                        {STATUS_LABEL[s]}
                      </option>
                    ))}
                  </select>
                </td>
                <td className="mono">
                  {issue.position.x.toFixed(2)}, {issue.position.y.toFixed(2)},{" "}
                  {issue.position.z.toFixed(2)}
                </td>
                <td className="mono">{formatTime(issue.createdAt)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </main>
  );
}

/** 把任意异常转成一句人话；分类信息（HTTP 状态 / 错误码）留在句子里，方便现场排查。 */
function describe(err: unknown): string {
  if (err instanceof ApiError) return `${err.message}（${err.code} / HTTP ${err.status}）`;
  if (err instanceof Error) return err.message;
  return String(err);
}

/** 只做本地时区显示，不改变后端存的 RFC3339 原值。 */
function formatTime(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString("zh-CN", { hour12: false });
}
