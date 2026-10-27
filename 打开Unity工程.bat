@echo off
REM ============================================================================
REM  Tiny launcher. ALL logic lives in scripts\open-unity.ps1.
REM
REM  Why this file is only a launcher (and not the whole logic):
REM    .bat has no arrays, no reliable quoting, and a ")" inside a path such as
REM    "C:\Program Files (x86)\..." closes an if/for block early. Two earlier
REM    versions of this file broke exactly that way: first CRLF+Chinese tore the
REM    parser apart (variables expanded to empty -> editor launched with an empty
REM    project path), then a "(x86)" path crashed the script with no message.
REM    Path and version logic belongs in PowerShell, not here.
REM
REM  Maintenance rule for THIS file: ASCII only + CRLF line endings.
REM ============================================================================
chcp 65001 >nul
setlocal

if not exist "%~dp0scripts\open-unity.ps1" (
  echo [ERROR] scripts\open-unity.ps1 is missing.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\open-unity.ps1" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo Script exited with code %RC%.
  pause
)
exit /b %RC%
