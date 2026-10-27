// IssueApiClient.cs —— 与 Go 后端通信的唯一出口。
//
// 设计决定：
//   1. 用 UnityWebRequest 协程，不引第三方 HTTP 库（换机器不折腾包管理器）。
//   2. **失败必须带原因**返回给 UI，而不是只返回 bool。题目 3.1.6 要求"成功或失败给明确提示"，
//      而"上报失败"这四个字对使用者毫无帮助——原因要能区分：连不上 / 超时 / 后端 400 / 后端 500。
//   3. 不重试。本地后端一次失败通常是配置错误（地址/端口/后端没起），自动重试只会掩盖它。
using System;
using System.Collections;
using System.Text;
using UnityEngine;
using UnityEngine.Networking;

public class IssueApiClient : MonoBehaviour
{
    /// <summary>一次上报的结果。error 为 null 表示成功。</summary>
    public struct Result
    {
        public bool ok;
        public string error;
        public string issueId;
    }

    /// <summary>
    /// 上报一条问题。调用方用 StartCoroutine(api.Submit(payload, result => ...))。
    ///
    /// 保证：无论成功失败都会回调一次（不会既不成功也不失败地卡住）。
    /// 不保证：后端不可达时多久返回——由 timeout 兜住。
    /// </summary>
    public IEnumerator Submit(IssuePayload payload, Action<Result> done)
    {
        var url = ApiConfig.BaseUrl.TrimEnd('/') + "/api/issues";
        var json = payload.ToJson();
        var body = Encoding.UTF8.GetBytes(json);

        using (var req = new UnityWebRequest(url, UnityWebRequest.kHttpVerbPOST))
        {
            req.uploadHandler = new UploadHandlerRaw(body);
            req.downloadHandler = new DownloadHandlerBuffer();
            // Content-Type 必须显式写：Go 侧用 json.Decoder 解析，
            // 不写这个头有些平台会当表单处理，后端直接 bad_json。
            req.SetRequestHeader("Content-Type", "application/json; charset=utf-8");
            req.timeout = ApiConfig.TimeoutSeconds;

            yield return req.SendWebRequest();

            // 注意：新版 Unity 用 result 判断，旧版用 isNetworkError/isHttpError。
            // 这里两种都写，避免版本差异导致"永远成功/永远失败"。
            bool transportFailed =
#if UNITY_2020_2_OR_NEWER
                req.result == UnityWebRequest.Result.ConnectionError ||
                req.result == UnityWebRequest.Result.DataProcessingError;
#else
                req.isNetworkError;
#endif
            if (transportFailed || req.responseCode == 0)
            {
                done(new Result
                {
                    ok = false,
                    error = "连不上后端 " + ApiConfig.BaseUrl + "（" + req.error + "）\n" +
                            "检查：后端是否已启动、地址端口是否正确"
                });
                yield break;
            }

            var text = req.downloadHandler != null ? req.downloadHandler.text : "";

            if (req.responseCode < 200 || req.responseCode >= 300)
            {
                // 后端错误包络是 {"error":{"code":"...","message":"..."}}，
                // 把 code 和 message 都带出来，排查时不用再翻后端日志。
                done(new Result
                {
                    ok = false,
                    error = "后端拒绝（HTTP " + req.responseCode + "）：" + ExtractError(text)
                });
                yield break;
            }

            done(new Result { ok = true, issueId = ExtractString(text, "id") });
        }
    }

    /// <summary>
    /// 从错误响应里取出人能读的原因。
    /// 为什么要手写解析：响应形状已知且只有一层，引一个 JSON 库不值得；
    /// 但**解析失败不能抛异常**——那会把"后端返回了意外内容"变成崩溃。
    /// </summary>
    private static string ExtractError(string json)
    {
        if (string.IsNullOrEmpty(json)) return "响应为空";
        var code = ExtractString(json, "code");
        var msg = ExtractString(json, "message");
        if (!string.IsNullOrEmpty(code) && !string.IsNullOrEmpty(msg)) return code + " / " + msg;
        if (!string.IsNullOrEmpty(msg)) return msg;
        if (!string.IsNullOrEmpty(code)) return code;
        return json.Length > 120 ? json.Substring(0, 120) + "…" : json;
    }

    /// <summary>
    /// 极简取值：找 "key":"value" 并返回 value。
    /// 只用于本项目已知的响应形状；遇到嵌套/转义就返回空串（宁可不显示，也不显示错的内容）。
    /// </summary>
    private static string ExtractString(string json, string key)
    {
        var needle = "\"" + key + "\"";
        var at = json.IndexOf(needle, StringComparison.Ordinal);
        if (at < 0) return null;
        var colon = json.IndexOf(':', at + needle.Length);
        if (colon < 0) return null;
        var q1 = json.IndexOf('"', colon + 1);
        if (q1 < 0) return null;
        var q2 = json.IndexOf('"', q1 + 1);
        if (q2 < 0) return null;
        return json.Substring(q1 + 1, q2 - q1 - 1);
    }
}
