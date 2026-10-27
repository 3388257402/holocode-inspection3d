# open-unity.ps1 —— 打开 Unity 工程（真正干活的脚本；.bat 只负责把它叫起来）
#
# 为什么逻辑放在 .ps1 而不是 .bat：
#   .bat 没有数组、没有可靠引号，`(x86)` 这种路径里的右括号会把 if/for 块提前闭合，
#   还有代码页与换行符的坑。这些坑已经踩过两轮（LF+中文撕裂解析 → 变量全空；
#   含 ")" 的路径直接崩且无提示）。路径/版本判断本来就该用 PowerShell 做。
#
# 版本策略（别改成"随便找个编辑器就行"）：
#   1. 期望版本只从 <工程>\ProjectSettings\ProjectVersion.txt 读 —— 单一事实来源；
#   2. 优先用**完全一致**的版本；
#   3. 同一 minor（如 2022.3.x）但补丁号不同：显式警告 + 要求确认，绝不静默；
#      tie-break：取**补丁号最高**的那个（不是最接近 wanted 的）——这是有意的，
#      同 minor 下高补丁版向后兼容更稳；改这条规则请同时改注释和下面的 Sort。
#   4. 大版本不同：直接拒绝。用别的大版本开工程会触发降级，
#      可能改写 ProjectSettings 与资源序列化，属于不可逆损坏。
#
# 两条踩坑得来的硬规则：
#   A. PowerShell 5.1 下单元素结果**不是数组**，`$x.Count` 可能是 $null，
#      于是 `if ($x.Count -gt 0)` 恒为假。所有"可能只有一项"的结果必须用 @(...) 包起来。
#   B. 本文件**必须保存为 UTF-8 with BOM**。PS 5.1 读无 BOM 的 .ps1 会按 ANSI(GBK) 解释，
#      中文字节可能连带吃掉后面的引号 → 整段脚本解析失败。校验：tools\verify-launcher.ps1
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\open-unity.ps1
#   ... -ProjectPath <路径>     指定工程目录（默认 <repo>\unity\Inspection3D）
#   ... -DryRun                 只打印将要执行的命令，不真的启动（验证用）
#   ... -AcceptDifferentPatch   同 minor 补丁号不同时直接继续（脚本/CI 用）
param(
    [string]$ProjectPath = "",
    [switch]$DryRun,
    [switch]$AcceptDifferentPatch
)

$ErrorActionPreference = "Stop"

# 未知参数必须硬报错：PS 5.1 对未声明的参数会**静默忽略**，
# 于是把 -DryRun 打成 -Dryrn 时会真的启动编辑器（安全阀失效），实测过。
# 副作用：本脚本从此不接受位置参数 / `$args`，当前也没有任何地方依赖它。
if ($args.Count -gt 0) {
    Write-Host "[ERROR] 无法识别的参数：$($args -join ' ')" -ForegroundColor Red
    Write-Host "        支持：-ProjectPath <路径> / -DryRun / -AcceptDifferentPatch"
    exit 1
}

if (-not $ProjectPath) {
    $repoRoot = Split-Path -Parent $PSScriptRoot   # <repo>\scripts -> <repo>
    $ProjectPath = Join-Path $repoRoot "unity\Inspection3D"
}

# 归一化：去掉尾随分隔符并转绝对路径。
# 为什么必须在**读版本文件之前**做：`Start-Process -ArgumentList @("-projectPath", "`"$ProjectPath`"")`
# 里若路径以 `\` 结尾，CRT 会把 `\"` 当成转义引号 → Unity 收到 `"...\proj" ` 这种非法值。
# 这个 bug 在 -DryRun 打印里看不出来，只有真启动才炸（实测：探针收到 [C:\x\proj" ]）。
try {
    $ProjectPath = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd('\', '/')
} catch {
    Write-Host "[ERROR] ProjectPath 不是合法路径：$ProjectPath" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- 1. 读期望版本
$versionFile = Join-Path $ProjectPath "ProjectSettings\ProjectVersion.txt"
if (-not (Test-Path -LiteralPath $versionFile)) {
    Write-Host "[ERROR] 找不到工程版本文件：$versionFile" -ForegroundColor Red
    Write-Host "        确认 ProjectPath 指向 Unity 工程目录（含 ProjectSettings）。"
    exit 1
}

$wanted = $null
foreach ($line in Get-Content -LiteralPath $versionFile) {
    if ($line -match '^\s*m_EditorVersion:\s*(\S+)') { $wanted = $Matches[1]; break }
}
if (-not $wanted) {
    Write-Host "[ERROR] $versionFile 里没有 m_EditorVersion 行" -ForegroundColor Red
    exit 1
}
$majorMinor = ((($wanted -split '\.')[0..1]) -join '.')   # 例如 2022.3
Write-Host "工程要求 Unity $wanted"

# ---------------------------------------------------------------- 2. 收集候选
$candidates = New-Object System.Collections.Generic.List[string]

function Add-Candidate([string]$exe) {
    if ([string]::IsNullOrWhiteSpace($exe)) { return }
    if (-not (Test-Path -LiteralPath $exe)) { return }
    foreach ($existing in $candidates) { if ($existing -ieq $exe) { return } }
    $candidates.Add($exe)
}

# 2a. Hub 默认安装目录（64 位 / 32 位两种 ProgramFiles）
Add-Candidate (Join-Path $env:ProgramFiles "Unity\Hub\Editor\$wanted\Editor\Unity.exe")
if (${env:ProgramFiles(x86)}) {
    Add-Candidate (Join-Path ${env:ProgramFiles(x86)} "Unity\Hub\Editor\$wanted\Editor\Unity.exe")
}

# 2b. Hub 的"第二安装位置"：既是候选来源，也要并入下面的扫描根，
#     否则"本机已装"列表会漏掉装在别的盘上的版本（极端时会误报"本机没有编辑器"）。
$hubRoots = @((Join-Path $env:ProgramFiles "Unity\Hub\Editor"))
if (${env:ProgramFiles(x86)}) { $hubRoots += (Join-Path ${env:ProgramFiles(x86)} "Unity\Hub\Editor") }

$secondaryJson = Join-Path $env:APPDATA "UnityHub\secondaryInstallPath.json"
if (Test-Path -LiteralPath $secondaryJson) {
    try {
        $secondary = (Get-Content -LiteralPath $secondaryJson -Raw).Trim() | ConvertFrom-Json
        if ($secondary -is [string] -and -not [string]::IsNullOrWhiteSpace($secondary)) {
            if (Test-Path -LiteralPath $secondary) {
                Add-Candidate (Join-Path $secondary "$wanted\Editor\Unity.exe")
                $hubRoots += $secondary
            } else {
                Write-Host "[WARN] secondaryInstallPath.json 指向的目录不存在：$secondary" -ForegroundColor Yellow
            }
        } else {
            # 不能静默：形状不对时用户会以为"第二安装位置"已生效，实际整段被忽略，
            # 最后只看到"找不到编辑器"这种误导性结论。
            Write-Host "[WARN] secondaryInstallPath.json 内容不是路径字符串（实际类型：$($secondary.GetType().Name)），已忽略" -ForegroundColor Yellow
            Write-Host "       请在 Unity Hub 的偏好设置里重新指定安装位置"
        }
    } catch {
        Write-Host "[WARN] secondaryInstallPath.json 解析失败，已忽略：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# 2c. 扫描所有已知安装根（只用于列候选，不静默选用）
$installed = @()
foreach ($root in ($hubRoots | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $exe = Join-Path $dir.FullName "Editor\Unity.exe"
        if (Test-Path -LiteralPath $exe) {
            $installed += [pscustomobject]@{ Version = $dir.Name; Exe = $exe }
        }
    }
}

# 先按版本去重，再按**语义版本**降序排。
# 为什么先去重：同一个版本可能同时出现在 ProgramFiles 与 ProgramFiles(x86) 两个根下；
#   而 PS 5.1 的 Sort-Object 对**相等键不保证保序**（实测相等项会被反向排列），
#   所以"重复项谁在前"不能依赖排序，必须显式去重。
# 为什么不用字符串序：字符串序下 "2022.3.10f1" < "2022.3.9f1"，会推荐错的那一个。
$installed = @(
    $installed |
        Group-Object Version |
        ForEach-Object { $_.Group[0] } |
        Sort-Object -Property @{
            Expression = {
                try { [version](($_.Version -split 'f')[0]) } catch { [version]'0.0.0' }
            }
        } -Descending
)

# ---------------------------------------------------------------- 3. 选择
$chosen = $candidates | Select-Object -First 1

if (-not $chosen) {
    if ($installed.Count -eq 0) {
        Write-Host "[ERROR] 本机没有找到任何 Unity 编辑器。" -ForegroundColor Red
        Write-Host "        请用 Unity Hub 安装 $wanted（Personal 许可证免费）。"
        exit 1
    }

    # @(...) 不能省：单元素时也要是数组（见文件头硬规则 A）
    $sameMinor = @($installed | Where-Object { $_.Version -like "$majorMinor.*" })

    if ($sameMinor.Count -gt 0) {
        if (-not $AcceptDifferentPatch) {
            Write-Host ""
            Write-Host "[WARN] 工程要求 $wanted，本机没有这个补丁版本。" -ForegroundColor Yellow
            Write-Host "       本机已装的 $majorMinor 系列：" -ForegroundColor Yellow
            $sameMinor | ForEach-Object { Write-Host "         - $($_.Version)" }
            Write-Host "       用不同补丁版打开会触发 Unity 的版本处理流程，" -ForegroundColor Yellow
            Write-Host "       可能改写 ProjectSettings / 资源序列化。" -ForegroundColor Yellow
            $answer = Read-Host "       仍然用 $($sameMinor[0].Version) 打开？输入 y 继续，其他任意键取消"
            if ($answer -ne "y") {
                Write-Host "已取消。建议在 Unity Hub 里安装 $wanted 后重试。" -ForegroundColor Yellow
                exit 2
            }
        } else {
            Write-Host "[WARN] 用补丁版 $($sameMinor[0].Version) 打开工程 $wanted（-AcceptDifferentPatch）" -ForegroundColor Yellow
        }
        $chosen = $sameMinor[0].Exe
    }
    else {
        Write-Host "[ERROR] 本机装的版本与工程要求的大版本不一致，拒绝打开。" -ForegroundColor Red
        Write-Host "        工程要求：$wanted"
        Write-Host "        本机已装："
        $installed | ForEach-Object { Write-Host "          - $($_.Version)" }
        Write-Host "        请安装 $wanted。用别的大版本开工程可能破坏序列化数据。"
        exit 1
    }
}

# ---------------------------------------------------------------- 4. 多实例提示
# 只提示不阻断：另一个实例可能正在关闭，硬拒绝会把"我刚关了它"这种正常操作也挡住。
# 但必须说清后果——Unity 自己会报多实例错误并退出，看起来像工程坏了。
$lockFile = Join-Path $ProjectPath "Temp\UnityLockfile"
if (Test-Path -LiteralPath $lockFile) {
    Write-Host "[WARN] 该工程似乎已被另一个 Unity 实例打开（存在 Temp\UnityLockfile）。" -ForegroundColor Yellow
    Write-Host "       若那个实例没关，Unity 会报多实例错误并直接退出。" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 5. 启动
Write-Host "使用编辑器：$chosen"
Write-Host "打开工程  ：$ProjectPath"
Write-Host ""
Write-Host "首次启动需要登录 Unity 账号激活许可证（Personal 免费）。"

if ($DryRun) {
    Write-Host ""
    Write-Host "[DryRun] 将执行：""$chosen"" -projectPath ""$ProjectPath""" -ForegroundColor Cyan
    exit 0
}

# 分离进程：关掉 .bat 窗口不应该杀掉正在导入/编译的编辑器
Start-Process -FilePath $chosen -ArgumentList @("-projectPath", "`"$ProjectPath`"")
Write-Host "已请求启动编辑器，本窗口可以关闭。"
exit 0
