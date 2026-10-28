# verify-launcher.ps1 —— 启动脚本的"维护规则"检查器
#
# 为什么需要它：这套脚本有两条不写在代码里就会被下一次改动悄悄破坏的规则——
#   1. 打开Unity工程.bat 必须 **纯 ASCII + CRLF**（cmd.exe 按字节切行，LF+中文会让
#      变量展开成空串，实测过：编辑器被用空路径启动）；
#   2. scripts\open-unity.ps1 必须 **UTF-8 with BOM**（PS 5.1 读无 BOM 的 .ps1 会按
#      ANSI(GBK) 解释，中文字节会吃掉后面的引号 → 整段解析失败，实测过）。
# 这两条都真实回归过一次，靠"记得"不可靠，所以固化成检查。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-launcher.ps1
# 退出码：0 = 全部通过；1 = 有问题（输出里逐条说明）
param([string]$RepoRoot = "")

$ErrorActionPreference = "Stop"
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }

$failures = New-Object System.Collections.Generic.List[string]
$script:seen = @()

function Check($name, $ok, $detail) {
    $script:seen += $name
    if ($ok) {
        Write-Host ("  [OK]   {0}" -f $name) -ForegroundColor Green
    } else {
        Write-Host ("  [FAIL] {0} — {1}" -f $name, $detail) -ForegroundColor Red
        $script:failures.Add("$name — $detail")
    }
}

Write-Host "检查启动脚本的维护规则（$RepoRoot）"

# ---- 0. 不许有临时残稿（*.new / *.bak / *.orig）留在脚本目录里。
#     有它们意味着"改了一半没落位"，而检查器只查正式文件名时会被它们骗过。
#     注意：这里逐个扩展名用 -Filter 查，而不是 -Include —— 在 -LiteralPath 下
#     -Include 会被忽略并返回**全部**文件（第一次写就踩了：把 node_modules 当残稿报出来）。
$scriptDirs = @($RepoRoot, (Join-Path $RepoRoot "scripts"), (Join-Path $RepoRoot "tools"), (Join-Path $RepoRoot ".githooks"))
$residue = @()
foreach ($dir in $scriptDirs) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    # 用 -like 精确匹配后缀，而不是 -Filter：`-Filter '*.bak'` 会把 foo.bak1 也算命中；
    # 同时要带 -Force，否则隐藏的残稿（hidden.orig）根本看不见。
    $residue += @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*.new' -or $_.Name -like '*.bak' -or $_.Name -like '*.orig' })
}
Check "没有 *.new / *.bak / *.orig 残稿" ($residue.Count -eq 0) (($residue | ForEach-Object { $_.FullName }) -join '; ')

# ---- 1. 所有 .bat / .cmd：纯 ASCII + 全 CRLF + 无 BOM
#     为什么要遍历而不是只查一个文件名：改名的启动器、复制出来的第二份 .bat 同样会被
#     cmd 以同一规则解析，只认一个文件名等于留后门。
$batFiles = @()
foreach ($dir in @($RepoRoot, (Join-Path $RepoRoot "scripts"), (Join-Path $RepoRoot "tools"))) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $batFiles += @(Get-ChildItem -LiteralPath $dir -File -Filter *.bat -ErrorAction SilentlyContinue)
    $batFiles += @(Get-ChildItem -LiteralPath $dir -File -Filter *.cmd -ErrorAction SilentlyContinue)
}
$batFiles = @($batFiles | Sort-Object FullName -Unique)

# 具名断言：README 里让用户双击的就是这个文件；只查"至少存在一个 .bat"的话，
# 把它删掉、留下任意 .cmd 也能全绿（实测过这种退化）。
Check "打开Unity工程.bat 存在" (Test-Path -LiteralPath (Join-Path $RepoRoot "打开Unity工程.bat")) "README 里让用户双击的就是它"
Check "至少存在一个 .bat/.cmd" ($batFiles.Count -gt 0) "根目录/scripts/tools 下没有任何 .bat/.cmd"

foreach ($bat in $batFiles) {
    $label = $bat.Name
    $bytes = [System.IO.File]::ReadAllBytes($bat.FullName)
    $nonAscii = @($bytes | Where-Object { $_ -gt 0x7F }).Count
    Check "$label 纯 ASCII" ($nonAscii -eq 0) "发现 $nonAscii 个非 ASCII 字节（cmd 会按字节切行，中文必须移出 .bat）"

    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    $crlf = ([regex]::Matches($text, "`r`n")).Count
    $loneLf = ([regex]::Matches($text, "(?<!`r)`n")).Count
    Check "$label 全 CRLF" (($loneLf -eq 0) -and ($crlf -gt 0)) "CRLF=$crlf, 孤立 LF=$loneLf（LF+中文会让 %VAR% 展开为空）"

    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Check "$label 无 BOM" (-not $hasBom) "cmd 会把 BOM 当成命令字符"
    $endsWithNewline = ($bytes.Length -ge 2 -and $bytes[$bytes.Length-2] -eq 13 -and $bytes[$bytes.Length-1] -eq 10)
    Check "$label 末尾有换行" $endsWithNewline "末尾缺 CRLF：用 >> 追加内容会黏到最后一个命令上，静默改掉退出码"
}

# ---- 1.5 启动器必须真的切到 UTF-8（静态 + 目的说明）
#       为什么：§2.5 只验证"退出时还原"，删掉 `chcp 65001` 那行它照样全绿（实测过），
#       而那一行是整个中文输出正确的前提。所以单独断言它存在。
$launcherPath = Join-Path $RepoRoot "打开Unity工程.bat"
if (Test-Path -LiteralPath $launcherPath) {
    $lb = [System.IO.File]::ReadAllText($launcherPath)
    $hasUtf8 = ([regex]::IsMatch($lb, '(?m)^chcp\s+65001\b'))
    Check "启动器设置了 UTF-8 代码页（chcp 65001）" $hasUtf8 "缺这行时 PowerShell 的中文输出会按调用方码页编码，重定向/CI 下会乱码"
}
# ---- 2. 所有 .ps1：UTF-8 with BOM + 语法可解析
#     为什么遍历而不是只查一个文件名：上一版只认 scripts\open-unity.ps1，
#     于是一个无 BOM 的 tools\extra.ps1（或改名后的副本）能让检查器 8 项全绿 ——
#     它自己是"BOM 静默漂移"的唯一守门人，却绕过自己（实测能复现）。
#     现在它自己也在被检查之列。
$ps1Files = @()
foreach ($dir in $scriptDirs) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $ps1Files += @(Get-ChildItem -LiteralPath $dir -File -Filter *.ps1 -ErrorAction SilentlyContinue)
}
$ps1Files = @($ps1Files | Sort-Object FullName -Unique)

Check "至少检查到一个 .ps1" ($ps1Files.Count -gt 0) "根目录/scripts/tools 下没有任何 .ps1"

foreach ($ps1 in $ps1Files) {
    $label = $ps1.Name
    $bytes = [System.IO.File]::ReadAllBytes($ps1.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Check "$label 带 UTF-8 BOM" $hasBom ("缺 BOM → PS 5.1 按 GBK 读中文会解析失败。" +
        "修（推荐）：powershell -ExecutionPolicy Bypass -File tools\fix-bom.ps1 ；" +
        "若丢 BOM 的正是 fix-bom.ps1 自己（它那时也跑不起来），用这条不依赖它的自救命令：" +
        'powershell -NoProfile -c "[IO.File]::WriteAllBytes(''' + $ps1.FullName + ''',[byte[]](0xEF,0xBB,0xBF)+[IO.File]::ReadAllBytes(''' + $ps1.FullName + '''))"')

    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($ps1.FullName, [ref]$null, [ref]$parseErrors)
    $count = 0
    if ($parseErrors) { $count = @($parseErrors).Count }
    $detail = ""
    if ($count -gt 0) { $detail = (@($parseErrors) | Select-Object -First 3 | ForEach-Object { "L$($_.Extent.StartLineNumber): $($_.Message)" }) -join "; " }
    Check "$label 语法可解析" ($count -eq 0) $detail
}

# ---- 2.5 行为断言：启动器必须把调用方的代码页还原
#       编码/语法检查看不出"块内用 !VAR! 但没开延迟展开"这类语义错误：那一版静态检查全绿，
#       而调用方被永久留在 65001（实测过）。所以这里真起子 cmd 跑一遍。
#
#       两点是自己踩过才加的：
#       a) 本检查器自己也会把**当前控制台**切到 $target，必须 try/finally 还原 ——
#          它被 pre-commit 调用，否则每次 git commit 都会把用户的终端留在 437。
#       b) 兜底分支（chcp 读不出 → 用 OEMCP 猜）在主路径正常时永远跑不到，所以要另造
#          一个"删掉主解析"的副本单独断言，否则那条分支坏了也全绿。
$launcher = Join-Path $RepoRoot "打开Unity工程.bat"
if (-not (Test-Path -LiteralPath $launcher)) {
    # §1 已断言"具名启动器存在"，这里不重复失败
}
elseif (-not (Get-Command cmd.exe -ErrorAction SilentlyContinue)) {
    Check "cmd.exe 可用（代码页行为断言的前提）" $false "找不到 cmd.exe，无法验证启动器是否还原代码页"
}
else {
    $probe = (& cmd /c "chcp" 2>&1) -join ' '
    $current = $null
    $probeTail = (('' + $probe) -replace '\.\s*\r?\n?\s*$','').TrimEnd(); if ($probeTail -match '(\d+)\s*$') { $current = [int]$Matches[1] }

    if ($null -eq $current) {
        # 解析失败时不能默认 0 继续跑：那会让 $target 恒为 437，若本机本来就是 437，
        # 断言就成了空转（永远绿，启动器坏着也看不出来）。
        Check "能读到当前代码页" $false "chcp 输出无法解析：$probe"
    }
    else {
        $target = if ($current -eq 437) { 850 } else { 437 }   # 故意选与当前不同的，避免空转
        try {
            $cmdLine = "chcp $target >nul & call `"$launcher`" -DryRun < nul & chcp"
            $out = (& cmd /c $cmdLine 2>&1) -join ' '
            # 主路径：应静默还原成 $target
            # 用整数比较，而不是正则子串：`..437..` 这种正文里出现数字不算还原成功
            $outTail = ([string]$out) -replace '\.\s*$', ''
            $outCp = if ($outTail -match '(\d+)\s*$') { [int]$Matches[1] } else { -1 }
            Check "启动器还原调用方代码页（$target）" ($outCp -eq $target) "跑完后代码页是 $outCp，期望 $target：$($out.Trim())"
            # 兜底路径：把主解析行删掉，强制走 OEMCP 分支。
            # 可接受两种结果：仍还原成 $target，或明确打出"system default"的 WARN。
            # 不可接受的是"静默换成别的页"——那正是这条断言要拦的。
            $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cp-fallback-" + [guid]::NewGuid().ToString('N').Substring(0,8))
            New-Item -ItemType Directory -Force $tmpDir | Out-Null
            try {
                $copy = Join-Path $tmpDir "launcher.bat"
                $body = Get-Content -LiteralPath $launcher -Raw
                # 去掉主解析（for /f ... delims=: ... chcp）与 OEMCP 兜底的依赖，只留兜底
                $bodyBefore = $body
                $body = $body -replace '(?m)^for /f "tokens=2 delims=:" %%C in \(''chcp''\) do set "CPPRIMARY=%%C"\r?\n', ''
                $body = $body -replace '(?m)^if defined CPPRIMARY set "CPPRIMARY=%CPPRIMARY: =%"\r?\n', ''
                Check "兜底副本确实删掉了主解析行" (($body -notmatch 'delims=:" %%C') -and ($body -notmatch 'CPPRIMARY: =')) "替换未命中：副本仍含主解析行，兜底断言会退化成重跑主路径"
                Set-Content -LiteralPath $copy -Value $body -Encoding ASCII -NoNewline
                $cmdLine2 = "chcp $target >nul & call `"$copy`" -DryRun < nul & chcp"
                $out2 = (& cmd /c $cmdLine2 2>&1) -join ' '
                $out2Tail = (('' + $out2) -replace '\.\s*$','').TrimEnd()
                $out2Cp = if ($out2Tail -match '(\d+)\s*$') { [int]$Matches[1] } else { -1 }
                $warned = ($out2 -match 'system default')
                $restored2 = ($out2Cp -eq $target)
                # 只接受两种组合：静默且还原到 $target，或明确 WARN（此时按系统默认页还原）。
                # 注意：单纯 `$restored2 -or $warned` 会让"WARN 了但根本没读到页"也算通过（$out2Cp=-1），
# 所以要求 warned 分支下 $out2Cp -gt 0 —— 那才证明"确实按某个页还原过"。
                Check "兜底分支：不静默换页（要么还原 $target，要么打出 system default 提示）" (($restored2 -and -not $warned) -or ($warned -and $out2Cp -gt 0)) "还原到 $out2Cp、WARN=$warned（WARN 但读不到任何可用页也算失败）：$($out2.Trim())"
            }
            finally {
                Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        finally {
            # 无论断言成败都还原本检查器改过的控制台码页
            & cmd /c "chcp $current >nul" | Out-Null
        }
    }
}
# ---- 2.6 git hook 的形态：存在 + 全 LF
#       为什么查：core.autocrlf=true 的机器 checkout 成 CRLF 后，`#!/bin/sh` 会变成
#       `#!/bin/sh\r`，git 执行 hook 时报 bad interpreter(127)——看起来像"门禁坏了"，
#       其实是"行尾被换了"。.gitattributes 里的 `.githooks/** text eol=lf` 是第一道保险，
#       这里是第二道（防止有人在本地把它改回 CRLF 后提交）。
$hook = Join-Path $RepoRoot ".githooks/pre-commit"
if (Test-Path -LiteralPath $hook) {
    $hookText = [System.IO.File]::ReadAllText($hook)
    $cr = ([regex]::Matches($hookText, "`r")).Count
    Check ".githooks/pre-commit 全 LF" ($cr -eq 0) "发现 $cr 个 CR：CRLF 的 hook 会让 git 报 bad interpreter(127)"
    Check ".githooks/pre-commit 有 shebang" ($hookText.StartsWith('#!')) "缺少 #!/bin/sh，git 无法执行"
} else {
    Check ".githooks/pre-commit 存在" $false "缺失则钩子不生效（README 让用户 git config core.hooksPath .githooks）"
}
# ---- 3. .gitattributes 是否仍然约束 *.bat 为 CRLF
$attr = Join-Path $RepoRoot ".gitattributes"
if (Test-Path -LiteralPath $attr) {
    $t = Get-Content -LiteralPath $attr -Raw
    Check ".gitattributes 约束 *.bat 为 CRLF" ($t -match '\*\.bat\s+text\s+eol=crlf') "缺少 '*.bat text eol=crlf'，别人 checkout 时可能拿到 LF"
} else {
    Check ".gitattributes 存在" $false "文件不存在"
}

Write-Host ""
# ---- 0. 自检：关键断言必须真的出现过
# 为什么需要：9c3a515 曾把主路径 Check 改成赋值（$outCp 成为死变量），项数从 20 掉到 19，
# 而检查器照样"全部通过"——删掉一条断言，门禁自己看不见。这份清单是给"门禁的完整性"
# 也加一道断言：少一项就 FAIL，而不是靠人肉数输出。
$requiredChecks = @(
    "打开Unity工程.bat 存在",
    "打开Unity工程.bat 纯 ASCII",
    "打开Unity工程.bat 全 CRLF",
    "打开Unity工程.bat 末尾有换行",
    "启动器设置了 UTF-8 代码页（chcp 65001）",
    "启动器还原调用方代码页（$target）",
    "兜底副本确实删掉了主解析行",
    "兜底分支：不静默换页（要么还原 $target，要么打出 system default 提示）",
    ".githooks/pre-commit 全 LF"
)
foreach ($need in $requiredChecks) {
    Check "断言清单里有：$need" ($script:seen -contains $need) "该断言本次没有执行过（可能被删掉或改了名）"
}

if ($failures.Count -eq 0) {
    Write-Host "全部通过。" -ForegroundColor Green
    exit 0
}
Write-Host ("有 {0} 项未通过，修好再提交。" -f $failures.Count) -ForegroundColor Red
exit 1
