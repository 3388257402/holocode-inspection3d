import type { Issue, Status } from "./types";

/**
 * 后端地址的解析顺序（先到先用）：
 *
 *   1. `window.__INSPECTION_API__`  ← 由 index.html 里的小脚本写入（支持 `?api=...`）
 *   2. `import.meta.env.VITE_API_BASE` ← 构建期注入
 *   3. `http://localhost:8080`        ← 默认值
 *
 * 为什么不能只有第 2 种：`VITE_API_BASE` 是**构建期**烘焙进产物的。
 * 我用 `npm run preview` 或直接把 `dist/` 放到静态服务器时，build 时没设这个变量，
 * 页面就会一直指向 localhost——评审人换了后端地址却改不动，只能重新 build。
 * 加了第 1 种之后，**同一份构建产物**可以用 `?api=http://192.168.1.10:8080` 直接换后端。
 */
/**
 * 只接受"纯 origin"的 http/https 地址（如 `http://192.168.1.10:8080`）。
 *
 * 为什么拒绝带路径/查询串的地址：基址是要拼 `/api/issues` 的，
 * 如果传 `http://host:8080/api`，拼出来就是 `/api/api/issues`——打不到接口却不会报错，
 * 只表现为"后端 404"。与其让人猜，不如直接判定为无效、回退默认地址。
 */
function normalizeBase(candidate: string): string | null {
  const trimmed = candidate.trim().replace(/\/+$/, "");
  if (!trimmed) return null;
  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    return null;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  if (url.pathname !== "/" || url.search !== "" || url.hash !== "") return null;
  // 返回 origin（而不是 href）：href 会给根地址补尾斜杠，拼出 `//api/issues`。
  return url.origin;
}

function resolveApiBase(): string {
  const injected = (window as unknown as { __INSPECTION_API__?: unknown }).__INSPECTION_API__;
  if (typeof injected === "string") {
    const fromWindow = normalizeBase(injected);
    if (fromWindow) return fromWindow;
  }
  const fromEnv = import.meta.env.VITE_API_BASE as string | undefined;
  if (typeof fromEnv === "string") {
    const fromEnvNorm = normalizeBase(fromEnv);
    if (fromEnvNorm) return fromEnvNorm;
  }
  // 兜底也要过一遍归一化：万一将来默认值被改成带尾斜杠/非 http 的形式，行为保持一致。
  return normalizeBase("http://localhost:8080") ?? "http://localhost:8080";
}

export const API_BASE: string = resolveApiBase();

/** 后端返回的错误包络：{ error: { code, message } }。 */
export class ApiError extends Error {
  readonly code: string;
  readonly status: number;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
  }
}

/**
 * 统一请求封装。
 *
 * 保证：非 2xx 一律抛 ApiError（带后端给的 code），网络失败抛带说明的 Error；
 *      **绝不返回 undefined 让上层去猜**——那种"静默成功"正是白屏的来源。
 * 不保证：自动重试（这是本地原型，重试只会让"后端没起来"这件事更难被发现）。
 */
async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${API_BASE}${path}`, {
      ...init,
      headers: { "Content-Type": "application/json", ...(init?.headers ?? {}) },
    });
  } catch (err) {
    // fetch 抛异常 = 连不上（后端没起、IP 不通、被防火墙拦、http 被浏览器拦）。
    // 单独分类，页面才能说"连不上后端"而不是笼统的"请求失败"。
    throw new Error(
      `连不上后端 ${API_BASE}（${err instanceof Error ? err.message : String(err)}）`,
    );
  }

  if (!res.ok) {
    let code = "http_error";
    let message = `HTTP ${res.status}`;
    try {
      const body = (await res.json()) as { error?: { code?: string; message?: string } };
      code = body.error?.code ?? code;
      message = body.error?.message ?? message;
    } catch {
      // 响应不是 JSON（反代返回 HTML 错误页等）：保留状态码，别假装解析成功。
    }
    throw new ApiError(res.status, code, message);
  }

  return (await res.json()) as T;
}

export async function listIssues(): Promise<Issue[]> {
  const data = await request<{ items: Issue[] }>("/api/issues");
  // 后端若因版本不一致返回了别的形状，这里给一句人话，而不是让 undefined 传到渲染层炸出白屏。
  if (!Array.isArray(data.items)) {
    throw new Error(`后端返回的 items 不是数组（${JSON.stringify(data).slice(0, 80)}）`);
  }
  return data.items;
}

export async function updateStatus(id: string, status: Status): Promise<Issue> {
  const data = await request<{ item: Issue }>(`/api/issues/${encodeURIComponent(id)}`, {
    method: "PATCH",
    body: JSON.stringify({ status }),
  });
  if (!data.item || typeof data.item !== "object") {
    throw new Error("后端没有返回更新后的 item");
  }
  return data.item;
}
