# AI_LOG

按题目要求：**保留 Prompt 原文**、按实际顺序、记录至少一次检查/修改/放弃 AI 结果的过程。

> 说明：本文件只收"我主动发给 AI 的指令"。IDE 的逐字补全不计。
> 涉及凭据一律脱敏为 `[REDACTED: ...]`。

---

## P-001

- 目标：确定后端持久化方案（SQLite 还是 JSON 文件），并确认能否零第三方依赖。

### Prompt 原文

> Unity AR 巡检题要求 Go 后端"数据重启后仍然存在"，允许 SQLite 或本地 JSON。我的判断是要零依赖（评卷人可能断网 clone）。请评估：a) 纯 Go SQLite 驱动是否会引入 `go mod download` 依赖；b) JSON 文件 + 每次全量落盘在几十条数据量下是否够；c) 全量落盘最容易被忽略的失败模式是什么。

### 结果

- **修改后采用**：JSON 文件 + 每次写操作全量落盘；拒绝了 SQLite（`modernc.org/sqlite` 要下载依赖，CGO 版要装 C 编译器，两者都会让"clone 即跑"失效）。
- 验证：`go test ./...` 里 `TestPersistenceAcrossRestart` 直接重新 `NewStore` 同一路径，断言数据还在。
- **我改动了 AI 的答案**：它建议 `os.WriteFile(tmp) + os.Rename` 即可；我追问后补充了 `f.Sync()`（刷数据）与目录 fsync（刷目录项），因为 rename 只保证目录项原子，不保证内容落盘。

---

## P-002

- 目标：设计"应用在重启后数据不丢"的落盘顺序，并确认异常时不静默丢数据。

### Prompt 原文

> 我的写盘是：写 tmp → rename。请指出在断电、进程被 kill、磁盘满这三种情况下分别会丢什么。另外：数据文件存在但内容为空时，服务应该怎么办（当作空列表启动，还是拒绝启动）？

### 结果

- **采用（并加强）**：AI 明确指出"目标文件存在长度为 0"是 rename 语义下的真实可能，建议加载期不能把空文件当空列表。我据此把 `NewStore` 改成**遇到空文件或非法 JSON 直接报错拒绝启动**，而不是静默重建空库。
- 验证：`TestPersistenceAcrossRestart` + 手工把 `data/issues.json` 清空后启动，确认进程退出并打印"数据文件存在但为空（可能被截断）"。
- 这条是本项目里最重要的一次"AI 提了正确方向、我决定实现强度"的交互。

---

## P-003

- 目标：Go 的优雅退出该怎么写，才能在 Ctrl+C 时不打断正在写的请求。

### Prompt 原文

> 我的 main 里有 `signal.Notify` + `srv.Shutdown(ctx, 5s)`。请检查：如果我开两个 goroutine 同时 `<-sig`，会有什么问题？失败路径（Shutdown 超时）退出码应该是什么？

### 结果

- **采用**：AI 指出"两个 goroutine 抢同一个 channel，Go 会随机唤醒一个"——确实是 bug（我的第一版就是这样写的），改成单一接收者。
- **未采用**：它建议再做"第二次 Ctrl+C 强制退出"。我否掉了：与"把在途写写完"目标冲突，而本服务一次落盘只有几毫秒，为省几秒引入竞态不划算；改为在 README「已知问题」里写明"关闭不可中断"。
- 验证：`go vet` + `go test` 通过；手工 Ctrl+C 观察日志停在"正在关闭（最多等 5 秒…）"。

---

## P-004

- 目标：校验规则应该放在哪一层（Unity 端 / Go 端 / 两端都放）。

### Prompt 原文

> 题目要求"标题为空或枚举值错误时返回明确的参数错误"。但 POST 的 body 里如果客户端传了 `status` 字段，按我现在的结构会被 JSON 解码器当成未知字段。请判断：a) `DisallowUnknownFields` 在这儿是帮我还是添乱；b) `status` 应该由谁决定。

### 结果

- **采用**：`status` 一律服务端置 `open`（题目要求"默认状态为 open"，客户端能指定就无法验证）；`DisallowUnknownFields` 保留，让 Unity 端手写 JSON 拼错字段时立刻报错而不是静默丢掉。
- 验证：`TestCreateRejectsClientSuppliedStatus`（传 `status` → 400 `bad_json`）+ `TestCreateDefaultsPriorityToMedium`。

---

## P-005

- 目标：CORS 该怎么配，才能让 React（:5173）访问 Go（:8080）而不在浏览器里报错。

### Prompt 原文

> React 用 Vite 跑在 5173，后端 8080。我在 Go 里手写 CORS 头。请确认：预检请求（OPTIONS）需要返回什么状态码、需要哪些响应头，以及"只在 GET 上加 Allow-Origin"会导致什么现象。

### 结果

- **采用**：`OPTIONS` 返回 204 + `Access-Control-Allow-Origin/Methods/Headers`，且这组头在**所有**方法上统一加（不只 GET）。
- 验证：`TestCORSPreflight`；另外 React 端用真实浏览器跑 `npm run dev` 手工确认列表能加载。

---

## P-006

- 目标：写 Unity 客户端的核心脚本（场景、移动、射线放置、表单、上报）

### Prompt 原文

> 开始写 Unity 那几个脚本

### 结果

- **采用**：产出 6 个脚本（`ApiConfig` / `IssueApiClient` / `IssueFormUI` / `PlayerMover` / `PlacementController` / `InspectionSceneBootstrap`），
  场景与 UI 全部由代码生成，避免拖拽引用丢失。
- 验证：当时本机还没装 Unity，**只能做静态检查**（括号配平、跨文件符号引用），
  所以我在 README 的「已知问题」里如实写了"未经编译验证"，没有假装跑通。

---

## P-007

- 目标：让独立审查者挑刺，而不是自己看一眼就宣布没问题

### Prompt 原文

> 顺便看看自动审查会不会审查代码

### 结果

- **修改后采用**：独立审查给出的 4 条全部成立，逐条改掉：
  1. `RenderSettings.ambientLight` 在默认 Skybox 模式下**是空操作** → 先设 `ambientMode = Flat`；
  2. 我在注释里写"URP 下 `Material.color` 同样有效"是**错的**（URP/Lit 用 `_BaseColor`）
     → 改成 `HasProperty("_BaseColor")` 分支，并把注释改对；
  3. `OnGUI` 每次事件 `new GUIStyle` 产生 GC 垃圾 → 缓存为字段；
  4. 只有三面墙，玩家能走出场地无限下坠 → 补 `Wall_Front`。
- 验证：静态检查（花括号配平、4 处改动逐条 grep 确认在位）。

---

## P-008

- 目标：让"双击就能打开工程"这件事真的成立

### Prompt 原文

> 你来安装就行

### 结果

- **采用 + 修正 AI 的一个错误**：装了 Unity Hub（静默）与编辑器 2022.3.62f1（6.04 GB）。
- AI 一开始凭记忆在 `ProjectVersion.txt` 里写了 revision `0da89fac8e79`，
  后来用 Unity 官方 release API 查到真实值是 `4af31df58517` 并改正 —— 这是一次
  "**AI 凭印象写常量，被事实推翻**"的记录。
- 验证：`Unity.exe -batchmode` 实跑，日志明确报 `No ULF license found`（卡在许可证而不是编译），
  说明这条验证路径是通的、只差人工登录。

---

## P-009

- 目标：启动脚本要能在任何机器上跑

### Prompt 原文

> 继续

### 结果

- **未采用（放弃 AI 的第一版方案）**：第一版把路径/版本逻辑全写在 `.bat` 里，被审查打回两次：
  1. blocker：`.bat` 是 UTF-8 无 BOM + **纯 LF** 且含中文 → cmd.exe 按字节切行错位，
     `%UNITY%`/`%PROJ%` 展开为空 → 用空路径启动编辑器；
  2. 含 `)` 的路径（`C:\Program Files (x86)\...`）让括号块提前闭合，脚本硬崩且无提示；
     且版本不匹配时会**静默**换别的补丁版启动。
- **结论：放弃在 .bat 里做这件事**，改成 `.bat` 只做薄壳（chcp + 调 PowerShell + 透传参数），
  全部逻辑搬到 `scripts/open-unity.ps1`。这不是"再修一次"，是承认工具选错了。
- 验证：`cmd /c "打开Unity工程.bat -DryRun"` 端到端跑通；三个版本场景分别验：
  精确匹配 → 直接用；同 minor 不同补丁 → WARN + 要确认（`-AcceptDifferentPatch` 可跳过）；
  大版本不同 → 拒绝并列出已装版本。

---

## P-010

- 目标：脚本的"失败分支"也要被验证，而不是只验证成功路径

### Prompt 原文

> 继续，你使用子代理进行自主决策和推进吧，我睡觉了，有问题就和子代理开会讨论，以及代码的审查

### 结果

- **修改后采用**：写 PowerShell 时踩到 5.1 的坑 ——
  单元素结果**不是数组**，`$x.Count` 可能是 `$null`，导致 `if ($x.Count -gt 0)` 恒为假，
  于是"同 minor 补丁不同"的分支永远走不到。修法：所有可能只有一项的结果都用 `@(...)` 包起来。
- 验证：构造临时工程目录（只放 `ProjectSettings\ProjectVersion.txt`）分别写
  `2022.3.62f1` / `2022.3.99f1` / `6000.0.23f1`，跑 `-DryRun` 看三种分支的输出与退出码。

---

## 与 AI 的分工（如实说明）

| 我做 | AI 做 |
|---|---|
| 决定范围、判断"这个要不要做" | 写具体代码、写文档草稿、写测试 |
| 跑起来、看日志、判断真假 | 解释报错、给候选修法 |
| **证伪**：AI 说"应该没问题"时，用命令去验 | 承认被推翻（例如 revision 哈希、`.bat` 换行、`.Count` 陷阱） |

一条经验：AI 的错误集中在**"凭印象写的常量/配置"**和**"只在某台机器上成立的假设"**，
这两类错误用"跑一遍"几乎必现；而它不容易错的是"结构怎么切分"。
