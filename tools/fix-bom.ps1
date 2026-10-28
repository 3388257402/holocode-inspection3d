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

# 扫描目录必须和 tools/verify-launcher.ps1 一致（它扫的是 root / scripts / tools / .githooks）。
# 早先这里少了 .githooks：检查器提示"跑 fix-bom"，fix-bom 却说"全部已有 BOM" exit 0，
# 而门禁仍是红的 —— 因为那个文件它压根没看见。
$scanDirs = @($root, (Join-Path $root "scripts"), (Join-Path $root "tools"), (Join-Path $root ".githooks"))

$targets = @()
foreach ($dir in $scanDirs) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $targets += @(Get-ChildItem -LiteralPath $dir -File -Filter *.ps1 -ErrorAction SilentlyContinue)
}
if (-not $CheckOnly) {
    Write-Host ("扫描目录: " + (($scanDirs | ForEach-Object { $_ }) -join ' ; '))
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

        # 【最重要的一道，必须排在"已有 BOM"短路之前】
        # "缺 BOM"和"不是 UTF-8"是两件事，绝不能用同一个动作覆盖。
        # 无 BOM 的 GBK/ANSI 文件在 PS 5.1 下本来能正常读（按系统 ANSI 解码）；
        # 一旦给它插上 UTF-8 BOM，PS 5.1 就改按 UTF-8 解码那些 GBK 字节 → 中文全成 U+FFFD。
        # 注意顺序：如果先判"已有 BOM 就 already++ 跳过"，那么**GBK 内容 + 已有 BOM** 的
        # 损坏文件会被算成"已有 BOM、0 失败"并 exit 0 —— 门禁三条判据也全绿，永久静默。
        # 所以合法性判定必须在最前面，对带不带 BOM 的文件都生效。
        $isLegalUtf8 = $true
        try {
            $null = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        }
        catch {
            $isLegalUtf8 = $false
        }

        # 无 BOM 的 UTF-16 不在上面 FF FE / FE FF 的覆盖范围内，而且它严格按 UTF-8 解码
        # **不抛异常**（全是 NUL 也是合法 UTF-8），所以再加一道 NUL 密度启发：
        # UTF-16 的 ASCII 文本每两字节就有一个 0x00，合法 UTF-8 文本几乎不会有 NUL。
        $nulCount = 0
        foreach ($b in $bytes) { if ($b -eq 0x00) { $nulCount++ } }
        $looksUtf16NoBom = ($bytes.Length -gt 0) -and (($nulCount * 4) -gt $bytes.Length)

        if (-not $isLegalUtf8 -or $looksUtf16NoBom) {
            # 归因要说准：UTF-16 的字节也可能过不了严格 UTF-8，那时不该报成 GBK。
            $why = if ($looksUtf16NoBom) { "疑似无 BOM 的 UTF-16（NUL 字节占比过高）" }
                   elseif ($isUtf16) { "UTF-16（带 BOM）" }
                   else { "内容不是合法 UTF-8（GBK/ANSI，或无 BOM 的 UTF-16）" }
            Write-Host ("  跳过（" + $why + "，需人工转成 UTF-8）: " + $f.Name) -ForegroundColor Red
            $failed += ($f.Name + ": " + $why + "；加/带 UTF-8 BOM 都救不了，需人工另存为 UTF-8 with BOM")
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
            # 替换要能真成：早期版本把备份放在 %TEMP%（C:），而 [IO.File]::Replace 要求
            # **备份与目标同卷**，跨卷必抛 —— 于是"唯一推荐的修复命令"在本机一次也修不成，
            # 还在目录里留下 xxx.ps1.bomnew（名字不匹配残稿扫描，检查器看不见）。
            # 现在：备份放同目录（.bombak 与 .bomnew 都由 finally 兜底删除），
            # Replace 失败就退回 Move -Force（同卷 rename，行为等价且不挑文件系统）。
            $tmpNew = $f.FullName + ".bomnew"
            $tmpBak = $f.FullName + ".bombak"
            try {
                [System.IO.File]::WriteAllBytes($tmpNew, $combined)
                try {
                    [System.IO.File]::Replace($tmpNew, $f.FullName, $tmpBak)
                }
                catch {
                    # 非 NTFS / 网络盘 / 被占用时 Replace 会抛，退回"删除后移动"：
                    # 先删目标再 Move 有极小窗口，但比"完全修不成"好，且原文件内容已
                    # 完整写进 $tmpNew，损坏风险只在极窄窗口内。
                    Move-Item -LiteralPath $tmpNew -Destination $f.FullName -Force
                }
                $fixed++
            }
            finally {
                # 失败路径也必须清干净：这两个名字不在检查器的残稿后缀里，漏了就永久静默残留。
                Remove-Item -LiteralPath $tmpNew -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $tmpBak -Force -ErrorAction SilentlyContinue
            }
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
