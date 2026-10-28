# fix-bom.ps1 —— 给仓库里的 .ps1 补回 UTF-8 BOM
#
# 为什么需要它：Windows PowerShell 5.1 读**无 BOM** 的 .ps1 会按 ANSI(GBK) 解码，
# 中文字节会连带吃掉后面的引号 → 整段脚本解析失败。这个仓库里已经因此死过三次门禁
# （tools/verify-launcher.ps1 自己丢了 BOM → pre-commit 恒红）。
#
# 根因不是"谁忘了补"，而是**编辑工具写盘时不一定保留 BOM**。所以把"补 BOM"做成一条命令，
# 让检查器在失败信息里直接告诉人跑它，而不是靠每次记得。
#
# 【关键设计】只在**字节层**最前面插三个字节 EF BB BF，绝不解码再编码。
# 反例（上一版就是这么写的）：ReadAllText(..., UTF8) 对非 UTF-8 的 .ps1（GBK/ANSI、
# 无 BOM 的 UTF-16）不报错，而是把非法字节替换成 U+FFFD，再 WriteAllText 写回 ——
# 中文被不可逆毁掉，还没有备份。这个工具恰恰是检查器失败时让人直接跑的，
# 一旦命中就是静默毁文件。字节拼接保证其余内容一个字节都不变。
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

$bom = [byte[]](0xEF, 0xBB, 0xBF)
$fixed = 0
$already = 0
$failed = @()

foreach ($f in $targets) {
    # 每个文件单独 try/catch：某个 .ps1 只读/被占用时不能中断整轮，
    # 否则"前面的已补、后面的没补"，而人以为跑完了。
    try {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)

        # UTF-16（记事本存成 "Unicode"）开头是 FF FE / FE FF —— 它**已经有** BOM，
        # 只是不是 UTF-8 的。不先拦住，下面会把它当"缺 BOM"并在最前面插 EF BB BF，
        # 于是 PS 5.1 拿 UTF-8 去解 UTF-16 的字节，文件立刻变乱码。这个工具是写盘的，
        # 这种边界必须守：认出来就跳过，交给人转编码。
        $isUtf16 = ($bytes.Length -ge 2) -and (
            (($bytes[0] -eq 0xFF) -and ($bytes[1] -eq 0xFE)) -or
            (($bytes[0] -eq 0xFE) -and ($bytes[1] -eq 0xFF)))
        if ($isUtf16) {
            Write-Host ("  跳过（UTF-16 编码，需人工转成 UTF-8）: " + $f.Name) -ForegroundColor Red
            $failed += ($f.Name + ": 这是 UTF-16（FF FE / FE FF），需人工另存为 UTF-8 with BOM")
            continue
        }

        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $already++
            continue
        }
        Write-Host ("  缺 BOM: " + $f.Name) -ForegroundColor Yellow
        if (-not $CheckOnly) {
            $combined = New-Object byte[] ($bytes.Length + 3)
            [Array]::Copy($bom, 0, $combined, 0, 3)
            [Array]::Copy($bytes, 0, $combined, 3, $bytes.Length)
            [System.IO.File]::WriteAllBytes($f.FullName, $combined)
            $fixed++
        }
    }
    catch {
        $failed += ($f.Name + ": " + $_.Exception.Message)
        Write-Host ("  失败: " + $f.Name + " — " + $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host ""
if ($CheckOnly) {
    Write-Host ("检查 {0} 个 .ps1：{1} 个已有 BOM，{2} 个缺失" -f $targets.Count, $already, ($targets.Count - $already))
    if ($failed.Count -gt 0) { $failed | ForEach-Object { Write-Host ("  读不了: " + $_) -ForegroundColor Red } }
    if ($targets.Count -ne $already) { exit 1 } else { exit 0 }
}

Write-Host ("共 {0} 个 .ps1：{1} 个已有 BOM，{2} 个已补，{3} 个失败" -f $targets.Count, $already, $fixed, $failed.Count) -ForegroundColor Green
if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Host ("  失败详情: " + $_) -ForegroundColor Red }
    exit 1
}
exit 0
