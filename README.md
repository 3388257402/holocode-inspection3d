# 园区巡检 · 虚拟现场标注原型（Unity 3D · 无 AR 设备版）

一个最小三端闭环：**Unity 虚拟现场放置标记并上报 → Go 后端保存 → React 管理端查看/改状态**。

> 本题是「无 AR 设备备选版」：Unity 在 **Editor 里直接运行**，不需要手机、不需要 ARCore/ARKit。
> 题目里写"不要求复杂架构和精美界面"，所以这里的原则是：**每个功能都要能跑、能被验证，且失败时有明确提示**。

## 目录

```
backend/    Go 后端（零第三方依赖，JSON 文件持久化）
web/        React + TypeScript 管理端（Vite）
unity/      Unity 3D 客户端（虚拟巡检现场 + 射线点击放置）
docs/       排障记录
README.md   本文件
AI_LOG.md   与 AI 的交互记录（题目要求）
```

## 版本

| 部分 | 版本 |
|---|---|
| Go | 1.23.4（`go.mod` 声明 1.23） |
| Node | 20+（本机实测 v25.8.2） |
| React / TypeScript / Vite | 见 `web/package.json` |
| Unity | **LTS 2022.3.x**（AR Foundation 5.x） |

## 启动

### 1. 后端

```bash
cd backend
go run . -addr :8080 -data data/issues.json
```

- 默认监听 `:8080`（所有网卡），数据落在 `backend/data/issues.json`
- 启动日志会打印**绝对路径 + 可点击地址**，例如：
  `巡检后端已启动 http://localhost:8080 （手机用电脑局域网 IP 替换 localhost），数据文件 G:\...\data\issues.json`
- 自检：`curl http://localhost:8080/healthz` → `{"ok":true,...}`
- 测试：`go test ./...`（14 个用例，逐条对应题目 3.3 的 9 条要求）

### 2. React 管理端

```bash
cd web
npm install
npm run dev          # 默认 http://localhost:5173
```

后端地址有三种指定方式（**优先级从高到低**）：

| 方式 | 用法 | 适用 |
|---|---|---|
| **URL 参数**（最方便） | `http://localhost:5173/?api=http://192.168.1.10:8080` | dev / preview / 静态部署**都能用，不用重新构建** |
| 构建期环境变量 | `$env:VITE_API_BASE="http://192.168.1.10:8080"; npm run build` | 部署时想固定地址 |
| 默认值 | 不设任何东西 → `http://localhost:8080` | 本机跑 |

> 为什么必须有第一种：`VITE_API_BASE` 是**构建期烘焙**进产物的。用 `npm run preview`
> 或把 `dist/` 丢到静态服务器时，构建时没设这个变量，页面就会一直指向 `localhost`，
> 评审人换了后端地址却改不动、只能重新 build。加了 `?api=` 之后，**同一份产物**可以随时换后端。

### 3. Unity 客户端（Editor 里直接跑，不需要手机、不需要 AR 设备）

> **最省事的路径：双击 `打开Unity工程.bat`。**
> 它会从 `ProjectSettings/ProjectVersion.txt` 读出工程要求的版本，
> 找到对应编辑器并用独立进程打开工程；首次启动会让你登录 Unity 账号（Personal 免费）。
> 逻辑在 `scripts/open-unity.ps1` 里，`.bat` 只是个薄壳——原因见文件头注释（`.bat` 不能放复杂逻辑）。

手动路径：

1. Unity Hub 安装 **2022.3 LTS**（**不需要**勾 Android/iOS 模块，本题只要桌面端）
2. Unity Hub → Add → 选中 `unity/Inspection3D` 这个文件夹打开工程
3. 打开任意**空场景**（或保留默认 SampleScene），直接按 **Play**
   —— 场地、墙体、机柜、管线、灯光、相机、UI 全部由 `InspectionSceneBootstrap` 在运行时生成，
   不需要你手动摆物体、也不需要在 Inspector 里拖任何引用
4. **改后端地址**：`Assets/Scripts/ApiConfig.cs` 里的 `BaseUrl`
   —— 后端在本机跑就保持 `http://localhost:8080`；
   跑在另一台机器/容器里才需要换成那台机器的 IP
5. 操作方式（屏幕左上角也有常驻提示）：

| 操作 | 效果 |
|---|---|
| `W/A/S/D` 或方向键 | 前后左右移动 |
| 按住**鼠标右键**拖动 | 转动视角 |
| **鼠标左键**点击地面/墙面/机柜/管线 | 在射线实际命中位置放置一个标记，并弹出上报表单 |
| `ESC` 或表单里的「取消」 | 移除未保存的标记并关闭表单 |

> 若打开工程时提示 "Active Input Handling"，请在 Project Settings → Player → Other Settings
> 把它设为 **Input Manager (Old)** 或 **Both**（本工程用的是经典 `Input` API）。

## 已完成 / 未完成 / 已知问题

（这一节按实际情况更新，**不粉饰**——题目明确把这作为评分项。）

### 已完成

- Go：健康检查、创建、列表、按 ID 改状态、5 类参数错误、重启后数据仍在、CORS、并发安全（**14 个测试，实跑通过**）
- React：列表、状态切换（open → in_progress → resolved）、后端不可用时显示错误条而不是白屏
- Unity：场景自动生成（地面/四面墙/3 个机柜/设备台/2 根管线）、第一人称移动、
  **射线命中放置**、表单上报、**点 UI 不误放标记**、一次点击最多一次待提交标记、取消即移除
- 启动脚本：双击 `打开Unity工程.bat` 即可（版本从工程读取、同 minor 不同补丁会警告、大版本不同拒绝）

### 未完成 / 已知问题

| 项 | 说明 | 为什么这样 |
|---|---|---|
| **C# 未经 Unity 编译验证** | 本机虽已装好 Unity 2022.3.62f1，但 `Unity -batchmode` 需要先登录激活许可证（Personal 免费），登录这一步只能由使用者完成。在此之前 `Assets/Scripts/*.cs` 只做了静态检查（括号/引号配平、跨文件符号引用一致） | 如实说明；首次打开若报编译错，把报错原文贴过来即可修 |
| Unity 许可证未激活 | 同上：没有许可证时编辑器无法启动，`batchmode` 报 `No ULF license found` | 登录一次即可，之后不再需要 |
| 列表恢复标记 | 加分项：从后端拉问题列表并在场景里还原标记 | 必做功能里没有；先保证主干闭环 |
| 点击标记查看详情 | 加分项 | 同上 |

### 已知问题

| 问题 | 说明 | 为什么先这样 |
|---|---|---|
| JSON 文件单写者 | 同一 `data/issues.json` 不能被两个后端进程同时写 | 原型只跑一个实例；多写者需要文件锁或数据库 |
| 数据路径按**启动目录**解析 | `-data data/issues.json` 是相对当前工作目录的：在 `backend/` 里启动和在仓库根目录启动，会读写**两份不同的**数据文件 | 启动日志会打印**绝对路径**，看日志即可确认；要绝对路径就传绝对路径 |
| 断电场景的目录项未强刷 | Windows 不支持目录 fsync，`syncDir` 是尽力而为 | 只影响"拔电源"级别的事故，正常 Ctrl+C 与崩溃都安全 |
| 关闭不可中断 | 收到 Ctrl+C 后最多等 5 秒排空，期间重复中断无效 | 与"把在途写请求写完"冲突，换取实现简单 |
| AR 位置不跨会话恢复 | 题目明确不要求 | 只持久化坐标数值，不做视觉定位 |
| 前端无自动化测试 | 只有 `tsc --noEmit` + 真实浏览器手工验证 | 原型阶段优先保证"能跑通"；要补就先抽 `describe/formatTime` 这类纯函数单测 |

## API

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/healthz` | 服务状态 |
| GET | `/api/issues` | 列表（按创建时间倒序） |
| POST | `/api/issues` | 新建，返回 201；`status` 恒为 `open` |
| PATCH | `/api/issues/{id}` | 改状态，body `{"status":"in_progress"}` |

字段与题目第 4 节逐字一致：`id / title / description / priority / status / position{x,y,z} / createdAt / updatedAt`。

错误统一为：

```json
{ "error": { "code": "title_required", "message": "标题不能为空" } }
```

| code | HTTP | 触发 |
|---|---|---|
| `title_required` | 400 | 标题为空/全空白 |
| `title_too_long` | 400 | 标题 > 200 字符 |
| `priority_invalid` | 400 | priority 不在 low/medium/high |
| `position_invalid` | 400 | 坐标非有限数或超界 |
| `status_invalid` | 400 | status 不在 open/in_progress/resolved |
| `issue_not_found` | 404 | 改不存在的 ID |

## AR 基础理解（题目第 5 节的三问）

> 本题是**无 AR 设备备选版**，下面只答思路，不写对应实现。
> 我对这三问的判断标准是：能不能说清「AR 多出来的那一层是什么」。

### 1. 如果改成真实 AR，平面检测与点击放置要用哪些 AR Foundation 能力？

| 能力 | 组件 | 作用 |
|---|---|---|
| 会话与相机 | `ARSession` / `ARInputManager` + `ARCameraManager` | 启动 AR 子系统、拿相机画面与姿态；**先查 `ARSession.state`**，不是一上来就开 |
| 平面检测 | `ARPlaneManager` | 检测水平面，把每块面表示成 `ARPlane`（可限制 `detectionMode = Horizontal` 减少抖动） |
| 射线检测 | `ARRaycastManager` | 把屏幕点变成 AR 射线，与平面/点云求交：`Raycast(hit, TrackableType.PlaneWithinPolygon)` |
| 空间锚定 | `ARAnchorManager` | 在命中点**创建锚点**再挂标记，让标记随设备移动与平面更新保持贴合（不加锚点标记会漂） |
| 可选 | `ARPointCloudManager` / `AROcclusionManager` | 特征点少时辅助定位；遮挡让虚拟物被真实物体挡住 |

关键差异一句话：**普通 3D 的射线打在"我自己造的碰撞体"上；AR 的射线打在"设备现场估计出来的平面"上**，
所以 AR 侧必须多一层"锚点"，否则标记不跟随真实环境。

### 2. 为什么只存 Unity 的 x/y/z，下次启动通常对不上同一个真实位置？

三个原因，从根上说是**坐标系本身不持久**：

1. **AR 坐标系是会话相对的**：原点在"进入 AR 那一刻的设备位置/朝向"，每次启动都会重设。同一个
   `(1.2, 0.8, 2.4)` 在两次会话里指的不是同一个地方。
2. **SLAM 会漂移**：长时间运行、光照变化、纯色墙面导致特征点少，位置估计会累积误差并重定位。
3. **没有持久化地图**：要跨会话复现，需要把"空间记忆"存下来——`ARCloudAnchor`（云锚点）、
   `ARKit` 的 `ARWorldMap`、或视觉基准（图片跟踪 / 二维码贴纸）。这三者都是**以"场景特征"为锚**，
   而不是以"数字坐标"为锚。

所以正确做法是：**坐标只作为参考值展示，跨会话定位要存锚点或视觉基准**。

### 3. AR 初始化失败 / 设备不支持 / Tracking 异常，应该怎么提示？

| 情况 | 判据 | 用户看到的提示 |
|---|---|---|
| 设备不支持 | AR 子系统可用性检查失败（ARCore 未安装/机型不在支持列表） | "当前设备不支持 AR，可改用普通 3D 模式"——**给降级路径，而不是只报错** |
| 相机权限被拒 | 权限回调 | "需要相机权限才能识别现场"，并给"去设置"按钮 |
| Tracking 受限 | `ARSession.notTrackingReason` | 翻译成人话：`InsufficientLight` → "光线太暗，请开灯或移到明亮处"；`InsufficientFeatures` → "请对着有纹理的表面缓慢移动"；`ExcessiveMotion` → "移动太快，请放慢" |
| 初始化超时/失败 | 状态机停在 `Initializing` 超过阈值 | "AR 启动失败"，给**重试**按钮，并记录一次失败原因 |

原则三条：**不静默失败**（不能只留一个黑屏）、**说人话**（把枚举翻成动作建议）、**给出口**（重试或降级）。

## 演示视频

（两段 3–5 分钟，Unity Editor 直接运行即可）

- 客户端：移动/转动视角 → 点击设备或场景表面 → 放置标记 → 填写并提交
- 管理端：React 刷新看到该问题 → 修改状态 → Go 重启后数据仍在
