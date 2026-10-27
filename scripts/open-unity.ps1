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
#   4. 大版本不同：直接拒绝。用别的大版本开工程会触发降级，
#      可能改写 ProjectSettings 与资源序列化，属于不可逆损坏。
#
# 本文件由踩坑得来的一条硬规则：
#   PowerShell 5.1 下单元素结果**不是数组**，`$x.Count` 可能是 $null，
#   于是 `if ($x.Count -gt 0)` 恒为假。所有"可能只有一项"的结果必须用 @(...) 包起来。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\open-unity.ps1
#   ... -DryRun                 只打印将要执行的命令，不真的启动（验证用）
#   ... -AcceptDifferentPatch   同 minor 补丁号不同时直接继续（脚本/CI 用）
param(
    [string]$ProjectPath = "",
    [switch]$DryRun,
    [switch]$AcceptDifferentPatch
)

$ErrorActionPreference = "Stop"

if (-not $ProjectPath) {
    $repoRoot = Split-Path -Parent $PSScriptRoot   # <repo>\scripts -> <repo>
    $ProjectPath = Join-Path $repoRoot "unity\Inspection3D"
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

# 2b. Hub 的"第二安装位置"（把编辑器装到别的盘时会记录在这里）
$secondaryJson = Join-Path $env:APPDATA "UnityHub\secondaryInstallPath.json"
if (Test-Path -LiteralPath $secondaryJson) {
    try {
        $secondary = (Get-Content -LiteralPath $secondaryJson -Raw).Trim() | ConvertFrom-Json
        if ($secondary -is [string] -and -not [string]::IsNullOrWhiteSpace($secondary)) {
            if (Test-Path -LiteralPath $secondary) {
                Add-Candidate (Join-Path $secondary "$wanted\Editor\Unity.exe")
            } else {
                Write-Host "[WARN] secondaryInstallPath.json 指向的目录不存在：$secondary" -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "[WARN] secondaryInstallPath.json 解析失败，已忽略：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# 2c. 扫描 Hub 目录下所有已装版本（只用于列出候选，不静默选用）
$installed = @()
$hubRoots = @((Join-Path $env:ProgramFiles "Unity\Hub\Editor"))
if (${env:ProgramFiles(x86)}) { $hubRoots += (Join-Path ${env:ProgramFiles(x86)} "Unity\Hub\Editor") }

foreach ($root in $hubRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $exe = Join-Path $dir.FullName "Editor\Unity.exe"
        if (Test-Path -LiteralPath $exe) {
            $installed += [pscustomobject]@{ Version = $dir.Name; Exe = $exe }
        }
    }
}
$installed = @($installed | Sort-Object Version -Unique)

# ---------------------------------------------------------------- 3. 选择
$chosen = $candidates | Select-Object -First 1

if (-not $chosen) {
    if ($installed.Count -eq 0) {
        Write-Host "[ERROR] 本机没有找到任何 Unity 编辑器。" -ForegroundColor Red
        Write-Host "        请用 Unity Hub 安装 $wanted（Personal 许可证免费）。"
        exit 1
    }

    # @(...) 不能省：单元素时也要是数组（见文件头那条硬规则）
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

# ---------------------------------------------------------------- 4. 多实例保护
$lockFile = Join-Path $ProjectPath "Temp\UnityLockfile"
if (Test-Path -LiteralPath $lockFile) {
    Write-Host "[WARN] 该工程似乎已被另一个 Unity 实例打开（存在 Temp\UnityLockfile）。" -ForegroundColor Yellow
    Write-Host "       先关掉那个实例，否则 Unity 会报多实例错误并直接退出。" -ForegroundColor Yellow
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
