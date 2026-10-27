// ApiConfig.cs —— 后端地址与上报数据结构（三端字段名必须一致，题目第 4 节）。
//
// 为什么把这些集中在一个文件里：
//   字段名一旦在 Unity 侧手拼 JSON 时写错（比如 priority 写成 Priority），
//   后端会返回 400 bad_json，而 Unity 侧只看到"上报失败"，很难查。
//   集中成常量 + 一个序列化方法，改一处即可。
using System;
using UnityEngine;

public static class ApiConfig
{
    /// <summary>
    /// 后端基地址。**改成你电脑的局域网 IP**，形如 http://192.168.1.10:8080 。
    ///
    /// 注意：本题是"无 AR 设备版"，Unity 在 Editor 里跑，
    /// 所以用 http://localhost:8080 通常就能连上本机后端；
    /// 但如果后端跑在另一台机器/容器里，localhost 会指向你自己的机器 —— 那时必须换成真实 IP。
    /// </summary>
    public const string BaseUrl = "http://localhost:8080";

    /// <summary>单次请求超时（秒）。后端是本地 JSON 落盘，正常都在毫秒级；给 10 秒足够，且失败能快速反馈。</summary>
    public const int TimeoutSeconds = 10;

    public static readonly string[] Priorities = { "low", "medium", "high" };
}

/// <summary>
/// 上报体的数据结构。字段名与后端 server.go 的 JSON tag 逐字对应。
///
/// 为什么手写 ToJson 而不用 Newtonsoft.Json：
///   这套原型刻意不引入任何第三方包（华为/公司环境下换机器最容易卡在包管理器上）。
///   这里只有 4 个字段，手拼 JSON 的风险可控——而"引一个包"的风险不可控。
/// </summary>
[Serializable]
public class IssuePayload
{
    public string title;
    public string description;
    public string priority;
    public float x, y, z;

    /// <summary>
    /// 序列化成后端要求的形状：
    /// {"title":..,"description":..,"priority":..,"position":{"x":..,"y":..,"z":..}}
    ///
    /// 注意 position 是**嵌套对象**，不是三个平铺字段——写成平铺会被后端判 400。
    /// </summary>
    public string ToJson()
    {
        // JsonEscape 必须做：标题里出现引号/反斜杠/换行时，
        // 不转义会拼出非法 JSON，后端只能返回 bad_json，而使用者会以为"网络坏了"。
        return "{"
             + "\"title\":" + Quote(title) + ","
             + "\"description\":" + Quote(description) + ","
             + "\"priority\":" + Quote(priority) + ","
             + "\"position\":{"
             + "\"x\":" + Num(x) + ","
             + "\"y\":" + Num(y) + ","
             + "\"z\":" + Num(z)
             + "}}";
    }

    /// <summary>JSON 字符串字面量：加引号并转义。</summary>
    private static string Quote(string s)
    {
        if (s == null) return "\"\"";
        var sb = new System.Text.StringBuilder(s.Length + 2);
        sb.Append('"');
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    // 控制字符（含 0x00-0x1F）在 JSON 里必须转义，否则非法。
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
        return sb.ToString();
    }

    /// <summary>
    /// 数字格式化。用 InvariantCulture：某些系统区域设置会把手数点写成逗号（如 1,26），
    /// 那会拼出非法 JSON —— 这种 bug 只在别人的机器上复现。
    /// NaN/Infinity 也要挡住：后端会返回 position_invalid，但更好的做法是根本别发出去。
    /// </summary>
    private static string Num(float v)
    {
        if (float.IsNaN(v) || float.IsInfinity(v)) return "0";
        return v.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
    }
}
