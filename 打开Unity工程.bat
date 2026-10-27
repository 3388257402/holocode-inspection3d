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
REM  Maintenance rules for THIS file:
REM    - ASCII only + CRLF line endings (verify: tools\verify-launcher.ps1)
REM    - restore the caller's code page on exit (chcp is process-global and is
REM      NOT undone by setlocal, so a caller sitting in a cmd window would
REM      otherwise be left on 65001)
REM ============================================================================
setlocal
for /f "tokens=2 delims=:" %%C in ('chcp') do set "OLDCP=%%C"
if defined OLDCP set "OLDCP=%OLDCP: =%"
chcp 65001 >nul

if not exist "%~dp0scripts\open-unity.ps1" (
  echo [ERROR] scripts\open-unity.ps1 is missing.
  set "RC=1"
  goto :finish
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\open-unity.ps1" %*
set "RC=%ERRORLEVEL%"

:finish
if defined OLDCP chcp %OLDCP% >nul
if not "%RC%"=="0" (
  echo.
  echo Script exited with code %RC%.
  if not defined UNITY_LAUNCHER_NO_PAUSE (
    echo Set UNITY_LAUNCHER_NO_PAUSE=1 before calling this to skip the pause when scripted.
    pause
  )
)
exit /b %RC%
