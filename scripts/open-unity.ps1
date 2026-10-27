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

# 未声明的具名参数必须硬报错：PS 5.1 对它们会**静默忽略**，
# 于是把 -DryRun 打成 -Dryrn 时会真的启动编辑器（安全阀失效），实测过。
# 注意边界：单个**位置参数**仍会按位置绑定到 -ProjectPath（把工程文件夹拖到 .bat 上就能用），
# 只有多余的位置参数才落进 $args 被这里拦下。
if ($args.Count -gt 0) {
    Write-Host "[ERROR] 无法识别的参数：$($args -join ' ')" -ForegroundColor Red
    Write-Host "        支持：-ProjectPath <路径> / -DryRun / -AcceptDifferentPatch"
    exit 1
}

if ($PSBoundParameters.ContainsKey('ProjectPath')) {
    # 显式传了 -ProjectPath 就必须当回事：传空串通常意味着"变量没设"（例如 $env:PROJ 为空），
    # 静默回退到默认工程会让人以为打开的是自己指定的那个（实测过这种"看起来成功"）。
    if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        Write-Host "[ERROR] -ProjectPath 是空字符串。要么不传（用默认工程），要么传一个真实路径。" -ForegroundColor Red
        exit 1
    }
} else {
    $repoRoot = Split-Path -Parent $PSScriptRoot   # <repo>\scripts -> <repo>
    $ProjectPath = Join-Path $repoRoot "unity\Inspection3D"
}

# 归一化：转绝对路径 + 去掉尾随分隔符。两件事都必须在**读版本文件之前**做。
#
# 为什么相对路径不能用 [IO.Path]::GetFullPath：它按**进程工作目录**解析，
# 而 Test-Path/Get-ChildItem 按 PowerShell 的当前位置（$PWD）解析。同进程里 cd 过之后两者会分叉
# （实测：PWD=仓库而 EnvCD=启动目录时，Test-Path 认为存在、GetFullPath 却指向别处 →
#  要么报"找不到版本文件"，要么**静默打开启动目录下的同名工程**）。
# 所以相对路径走 PowerShell 自己的路径解析；绝对路径才交给 GetFullPath。
# 顺带解决"进程位置不在文件系统"（如 HKLM:）的情况——那种会抛异常，走下面的 catch。
#
# 为什么必须去掉尾随 `\`：`Start-Process -ArgumentList @("-projectPath", "`"$ProjectPath`"")` 里
# 若路径以 `\` 结尾，CRT 会把 `\"` 当成转义引号 → Unity 收到 `"...\proj" ` 这种非法值。
# 这个 bug 在 -DryRun 打印里看不出来，只有真启动才炸（实测：探针收到 [C:\x\proj" ]）。
try {
    # 只有"完整的绝对路径"（盘符 + 分隔符）才交给 GetFullPath；
    # 其余一律走 PowerShell 的解析：
    #   - `C:proj`（盘符相对）虽然 IsPathRooted 为 True，但 GetFullPath 会按**盘符当前目录**
    #     解析，仍然与 $PWD 分叉（实测过）；
    #   - `\\server\share` 形式不完整时 GetFullPath 直接抛异常。
    if ($ProjectPath -match '^[A-Za-z]:[\\/]') {
        $ProjectPath = [System.IO.Path]::GetFullPath($ProjectPath)
    } else {
        $ProjectPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectPath)
    }
    $ProjectPath = $ProjectPath.TrimEnd('\', '/')
} catch {
    Write-Host "[ERROR] ProjectPath 无法解析成文件系统路径：$ProjectPath" -ForegroundColor Red
    Write-Host "        当前 PowerShell 位置：$($PWD.Path)"
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
# 用函数判空再拼：$env:ProgramFiles 在极简环境里可能为空，直接 Join-Path 会抛未捕获的绑定异常
# （实测：打印完"工程要求"就裸栈中断，所有友好失败分支都走不到）。
function Join-HubPath([string]$programFiles, [string]$relative) {
    if ([string]::IsNullOrWhiteSpace($programFiles)) { return $null }
    return (Join-Path $programFiles $relative)
}

$pf64 = $env:ProgramFiles
$pf86 = ${env:ProgramFiles(x86)}

Add-Candidate (Join-HubPath $pf64 "Unity\Hub\Editor\$wanted\Editor\Unity.exe")
Add-Candidate (Join-HubPath $pf86 "Unity\Hub\Editor\$wanted\Editor\Unity.exe")

# 2b. Hub 的"第二安装位置"：既是候选来源，也要并入下面的扫描根，
#     否则"本机已装"列表会漏掉装在别的盘上的版本（极端时会误报"本机没有编辑器"）。
$hubRoots = @()
$r = Join-HubPath $pf64 "Unity\Hub\Editor"; if ($r) { $hubRoots += $r }
$r = Join-HubPath $pf86 "Unity\Hub\Editor"; if ($r) { $hubRoots += $r }

$secondaryJson = Join-HubPath $env:APPDATA "UnityHub\secondaryInstallPath.json"
if ($secondaryJson -and (Test-Path -LiteralPath $secondaryJson)) {
    # 分三步读，而不是一句 ConvertFrom-Json 包住全部：
    # 空文件与字面 null 都会让后面的 .Trim()/.GetType() 抛异常，被 catch 说成"解析失败"——
    # 而实际上**什么都没解析失败**，这会把正常机器误报成配置损坏。
    $raw = $null
    $readOk = $false
    try {
        $raw = Get-Content -LiteralPath $secondaryJson -Raw
        $readOk = $true
    } catch {
        Write-Host "[WARN] 读不到 secondaryInstallPath.json：$($_.Exception.Message)" -ForegroundColor Yellow
    }

    # 读失败与"文件为空"是两件事，不能合并：都走"空文件"分支会把 IO 故障
    # 说成正常状态（实测：把 json 建成目录 → 同时出现"读不到"和"是空文件"两条自相矛盾的话）。
    if (-not $readOk) {
        Write-Host "       这一项被跳过，其余检查照常进行。" -ForegroundColor DarkGray
    }
    elseif ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Host "[INFO] secondaryInstallPath.json 是空文件，按「未配置第二安装位置」处理" -ForegroundColor DarkGray
    } else {
        $secondary = $null
        $parsed = $true
        try {
            $secondary = $raw.Trim() | ConvertFrom-Json
        } catch {
            $parsed = $false
            Write-Host "[WARN] secondaryInstallPath.json 不是合法 JSON，已忽略：$($_.Exception.Message)" -ForegroundColor Yellow
        }

        if ($parsed) {
            if ($null -eq $secondary) {
                # Hub 清空第二安装位置时写的可能就是字面 null —— 正常状态，不是错误。
                Write-Host "[INFO] secondaryInstallPath.json 内容是 null，按「未配置第二安装位置」处理" -ForegroundColor DarkGray
            }
            elseif ($secondary -is [string]) {
                $secPath = $secondary.Trim().TrimEnd('\', '/')   # 归一化，否则拼出 ...\SEC\\2022.3.x
                if ([string]::IsNullOrWhiteSpace($secPath)) {
                    Write-Host "[INFO] secondaryInstallPath.json 里是空字符串，按「未配置第二安装位置」处理" -ForegroundColor DarkGray
                }
                else {
                    # Test-Path 对含非法字符的路径（如 `C:\bad|name`）会抛 ArgumentException，
                    # 不能用 -ErrorAction Stop 之外的默认行为直接调用：那会裸栈中断，
                    # 让用户看到 "Illegal characters in path" 而不是下面的友好 WARN（实测复现过）。
                    # -ErrorAction SilentlyContinue 让它返回 $false，与"目录不存在"合并处理。
                    $secExists = Test-Path -LiteralPath $secPath -ErrorAction SilentlyContinue
                    if ($secExists) {
                        Add-Candidate (Join-Path $secPath "$wanted\Editor\Unity.exe")
                        $hubRoots += $secPath
                        Write-Host "       已读取第二安装位置：$secPath" -ForegroundColor DarkGray
                    } else {
                        Write-Host "[WARN] secondaryInstallPath.json 指向的目录不存在或路径非法：$secPath" -ForegroundColor Yellow
                    }
                }
            }
            else {
                # 形状不对必须说清（不能静默丢掉），否则用户会以为第二安装位置已生效。
                Write-Host "[WARN] secondaryInstallPath.json 内容不是路径字符串（实际类型：$($secondary.GetType().Name)），已忽略" -ForegroundColor Yellow
                Write-Host "       请在 Unity Hub 的偏好设置里重新指定安装位置"
            }
        }
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
