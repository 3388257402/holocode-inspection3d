# 检查安卓手机是否支持 Unity AR Foundation 需要的 ARCore。
#
# 为什么用 adb 而不是"打开某个网页试试"：
#   ARCore 是系统级服务，网页只能验证 WebXR，而 WebXR 支持不等于 ARCore 支持。
#   真机能不能跑 AR Foundation，只看三个包在不在：
#     com.google.ar.core       ARCore 运行时
#     com.google.android.gms   Google Play 服务（ARCore 依赖它）
#     com.google.android.gsf   Google 服务框架
#
# 用法：手机用数据线连电脑，开启「开发者选项 → USB 调试」，手机点「允许」，然后
#   powershell -ExecutionPolicy Bypass -File tools\check-arcore.ps1
#
# 退出码（机器可判读）：
#   0 支持；2 找不到 adb；3 设备未连接/未授权；4 缺 GMS 或 GSF；5 缺 ARCore 运行时
#
# 实现上的一个坑（踩过）：
#   不要用 `& adb devices 2>$null | ...` 抓输出——adb 会拉起一个常驻 server 进程，
#   它继承了父进程的输出管道句柄，PowerShell 永远等不到 EOF，脚本会**卡死**（我实测卡了 5 分钟）。
#   所以统一走 Start-Process + 重定向到临时文件 + 带超时的 WaitForExit。

param(
  [string]$Adb = ""
)

$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Resolve-Adb {
  param([string]$Explicit)
  if ($Explicit) { return $Explicit }
  $cmd = Get-Command adb -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($c in @(
      (Join-Path $PSScriptRoot "..\..\tools\platform-tools\adb.exe"),
      (Join-Path $PSScriptRoot "platform-tools\adb.exe"),
      (Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"))) {
    if (Test-Path $c) { return (Resolve-Path $c).Path }
  }
  return ""
}

# Invoke-Adb 通过临时文件拿输出，避免上面说的管道继承导致卡死。
# 返回 stdout 文本；超时返回 $null，让调用方能区分"没输出"和"跑不动"。
function Invoke-Adb {
  param([string]$AdbPath, [string[]]$AdbArgs, [int]$TimeoutMs = 20000)
  $out = [System.IO.Path]::GetTempFileName()
  $err = "$out.err"
  try {
    $p = Start-Process -FilePath $AdbPath -ArgumentList $AdbArgs -NoNewWindow -PassThru `
      -RedirectStandardOutput $out -RedirectStandardError $err
    if (-not $p.WaitForExit($TimeoutMs)) {
      try { $p.Kill() } catch {}
      return $null
    }
    # adb 退出码非 0 时，stdout 往往是空（错误信息在 stderr）。旧代码直接把空串返回，
    # 调用方于是把"adb 调用失败"读成"三个包都不存在" → 误报"手机不支持 ARCore"、
    # 建议换题/借手机。这里把失败转成 $null（与"超时"同义），让调用方走"无法判定"分支。
    #
    # 必须先判 $null：PS 5.1 里 `Start-Process -PassThru` 返回对象上的 ExitCode 可能是
    # $null（实测：即使 WaitForExit() 之后仍为 null），而 `$null -ne 0` 恒为真 ——
    # 直接写 `if ($p.ExitCode -ne 0)` 会把**每一次成功调用**都判成失败。
    if ($null -ne $p.ExitCode -and $p.ExitCode -ne 0) {
      return $null
    }
    return (Get-Content $out -Raw -ErrorAction SilentlyContinue)
  } finally {
    Remove-Item $out, $err -ErrorAction SilentlyContinue
  }
}

$adbPath = Resolve-Adb -Explicit $Adb
if (-not $adbPath -or -not (Test-Path $adbPath)) {
  Write-Host "找不到 adb。用 -Adb <路径> 指定，或把 platform-tools 加入 PATH。" -ForegroundColor Red
  exit 2
}

# 先确认"有设备且已授权"，再做任何判断：
# 否则 adb 调用失败会让三个包都判成"缺失" → 被误诊为"手机不支持 ARCore"，
# 把人引向换题/借手机，而真实原因是线没插或没授权。
$devicesText = Invoke-Adb -AdbPath $adbPath -AdbArgs @("devices")
if ($null -eq $devicesText) {
  Write-Host "adb devices 超时（可能 adb server 卡住）。试：adb kill-server 后重跑。" -ForegroundColor Red
  exit 3
}
$deviceLines = @($devicesText -split "`r?`n" | Where-Object { $_ -match "^(\S+)\s+(device|unauthorized|offline)$" })
if ($deviceLines.Count -eq 0) {
  Write-Host "没有检测到已授权的设备。请检查：" -ForegroundColor Yellow
  Write-Host "  1) 换一根能传数据的线（很多线只能充电）"
  Write-Host "  2) 设置 → 关于手机 → 连续点「版本号」7 次，开开发者选项"
  Write-Host "  3) 开发者选项里打开「USB 调试」，并在手机弹窗点「允许」"
  exit 3
}
$state = ($deviceLines[0] -split "\s+")[1]
if ($state -ne "device") {
  Write-Host "设备状态是 $state：请在手机上点「允许 USB 调试」后重跑。" -ForegroundColor Yellow
  exit 3
}

function Get-Prop {
  param([string]$Name)
  $v = Invoke-Adb -AdbPath $adbPath -AdbArgs @("shell", "getprop", $Name)
  if ($null -eq $v) { return "" }
  return $v.Trim()
}

$model   = Get-Prop "ro.product.model"
$market  = Get-Prop "ro.product.marketname"
$android = Get-Prop "ro.build.version.release"

$packages = Invoke-Adb -AdbPath $adbPath -AdbArgs @("shell", "pm", "list", "packages")
if ($null -eq $packages) {
  Write-Host "读取已安装包超时。请先解锁手机屏幕再重跑。" -ForegroundColor Red
  exit 3
}
$hasArCore = $packages -match "package:com\.google\.ar\.core"
$hasGms    = $packages -match "package:com\.google\.android\.gms"
$hasGsf    = $packages -match "package:com\.google\.android\.gsf"

$arVersion = "-"
if ($hasArCore) {
  $dump = Invoke-Adb -AdbPath $adbPath -AdbArgs @("shell", "dumpsys", "package", "com.google.ar.core")
  if ($dump) {
    $m = [regex]::Match($dump, "versionName=([^\s]+)")
    if ($m.Success) { $arVersion = $m.Groups[1].Value }
  }
}

Write-Host ""
Write-Host "===== 设备 =====" -ForegroundColor Cyan
Write-Host ("机型: {0}  ({1})" -f $model, $market)
Write-Host ("Android: {0}" -f $android)
Write-Host ""
Write-Host "===== ARCore 依赖 =====" -ForegroundColor Cyan
Write-Host ("com.google.ar.core      ARCore 运行时   : {0}" -f $(if ($hasArCore) { "有（$arVersion）" } else { "缺失" }))
Write-Host ("com.google.android.gms   Play 服务       : {0}" -f $(if ($hasGms) { "有" } else { "缺失" }))
Write-Host ("com.google.android.gsf   服务框架        : {0}" -f $(if ($hasGsf) { "有" } else { "缺失" }))
Write-Host ""

if ($hasArCore -and $hasGms -and $hasGsf) {
  Write-Host "结论：可以用这台手机做 Unity AR Foundation 真机测试。" -ForegroundColor Green
  Write-Host "下一步：Unity Hub 装 2022.3 LTS + Android Build Support，XR Plug-in Management 勾 ARCore。"
  exit 0
}

Write-Host "结论：这台手机当前不能跑 ARCore。" -ForegroundColor Red
if (-not $hasGms -or -not $hasGsf) {
  Write-Host "原因：缺 Google 服务（GMS/GSF）。国行机型常见；ARCore 依赖它，装上 ARCore 也跑不起来。"
  Write-Host "可选：A 找面试官换题（任务书写明可换）/ B 借一台在 Google ARCore 支持列表里的安卓机 / C iPhone + Mac"
  exit 4
}
Write-Host "原因：有 Google 服务但缺 ARCore 运行时。在 Google Play 安装「Google Play 服务（AR）」后重跑。"
exit 5
