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

# ---- 1. .bat：纯 ASCII + 全 CRLF
$bat = Join-Path $RepoRoot "打开Unity工程.bat"
if (-not (Test-Path -LiteralPath $bat)) {
    Check "打开Unity工程.bat 存在" $false "文件不存在"
} else {
    $bytes = [System.IO.File]::ReadAllBytes($bat)
    $nonAscii = @($bytes | Where-Object { $_ -gt 0x7F }).Count
    Check "bat 纯 ASCII" ($nonAscii -eq 0) "发现 $nonAscii 个非 ASCII 字节（cmd 会按字节切行，中文必须移出 .bat）"

    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    $crlf = ([regex]::Matches($text, "`r`n")).Count
    $loneLf = ([regex]::Matches($text, "(?<!`r)`n")).Count
    Check "bat 全 CRLF" (($loneLf -eq 0) -and ($crlf -gt 0)) "孤立 LF=$loneLf（LF+中文会让 %VAR% 展开为空）"

    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Check "bat 无 BOM" (-not $hasBom) "cmd 会把 BOM 当成命令字符"
}

# ---- 2. ps1：UTF-8 with BOM + 语法可解析
$ps1 = Join-Path $RepoRoot "scripts\open-unity.ps1"
if (-not (Test-Path -LiteralPath $ps1)) {
    Check "scripts\open-unity.ps1 存在" $false "文件不存在"
} else {
    $bytes = [System.IO.File]::ReadAllBytes($ps1)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Check "ps1 带 UTF-8 BOM" $hasBom "缺 BOM → PS 5.1 按 GBK 读中文，可能连带吃掉引号导致解析失败"

    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$null, [ref]$parseErrors)
    $count = 0
    if ($parseErrors) { $count = @($parseErrors).Count }
    $detail = ""
    if ($count -gt 0) { $detail = (@($parseErrors) | Select-Object -First 3 | ForEach-Object { "L$($_.Extent.StartLineNumber): $($_.Message)" }) -join "; " }
    Check "ps1 语法可解析" ($count -eq 0) $detail
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
