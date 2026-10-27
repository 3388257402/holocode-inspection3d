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

function Check($name, $ok, $detail) {
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
$scriptDirs = @($RepoRoot, (Join-Path $RepoRoot "scripts"), (Join-Path $RepoRoot "tools"))
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
    Check "$label 带 UTF-8 BOM" $hasBom "缺 BOM → PS 5.1 按 GBK 读中文，可能连带吃掉引号导致解析失败"

    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($ps1.FullName, [ref]$null, [ref]$parseErrors)
    $count = 0
    if ($parseErrors) { $count = @($parseErrors).Count }
    $detail = ""
    if ($count -gt 0) { $detail = (@($parseErrors) | Select-Object -First 3 | ForEach-Object { "L$($_.Extent.StartLineNumber): $($_.Message)" }) -join "; " }
    Check "$label 语法可解析" ($count -eq 0) $detail
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
if ($failures.Count -eq 0) {
    Write-Host "全部通过。" -ForegroundColor Green
    exit 0
}
Write-Host ("有 {0} 项未通过，修好再提交。" -f $failures.Count) -ForegroundColor Red
exit 1
