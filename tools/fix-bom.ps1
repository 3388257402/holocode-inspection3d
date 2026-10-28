# fix-bom.ps1 —— 给仓库里的 .ps1 补回 UTF-8 BOM
#
# 为什么需要它：Windows PowerShell 5.1 读**无 BOM** 的 .ps1 会按 ANSI(GBK) 解码，
# 中文字节会连带吃掉后面的引号 → 整段脚本解析失败。这个仓库里已经因此死过三次门禁
# （tools/verify-launcher.ps1 自己丢了 BOM → pre-commit 恒红）。
#
# 根因不是"谁忘了补"，而是**编辑工具写盘时不一定保留 BOM**。所以把"补 BOM"做成一条命令，
# 让检查器在失败信息里直接告诉人跑它，而不是靠每次记得。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\fix-bom.ps1
#   ... -CheckOnly     只报告哪些缺 BOM，不写盘
param([switch]$CheckOnly)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$targets = @()
foreach ($dir in @($root, (Join-Path $root "scripts"), (Join-Path $root "tools"))) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $targets += @(Get-ChildItem -LiteralPath $dir -File -Filter *.ps1 -ErrorAction SilentlyContinue)
}

$fixed = 0
$already = 0
foreach ($f in $targets) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $already++
        continue
    }
    Write-Host ("  缺 BOM: " + $f.Name) -ForegroundColor Yellow
    if (-not $CheckOnly) {
        # 按 UTF-8 读（无 BOM 时默认走 UTF-8 而不是 GBK，避免把已有中文写坏），再以带 BOM 重写
        $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($f.FullName, $text, [System.Text.UTF8Encoding]::new($true))
        $fixed++
    }
}

Write-Host ""
if ($CheckOnly) {
    Write-Host ("检查 {0} 个 .ps1：{1} 个已有 BOM，{2} 个缺失" -f $targets.Count, $already, ($targets.Count - $already))
    if ($targets.Count -ne $already) { exit 1 } else { exit 0 }
}
Write-Host ("共 {0} 个 .ps1：{1} 个已有 BOM，{2} 个已补" -f $targets.Count, $already, $fixed) -ForegroundColor Green
exit 0
