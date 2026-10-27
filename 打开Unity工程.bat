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
if not "%RC%"=="0" (
  echo.
  echo Script exited with code %RC%.
  if not defined UNITY_LAUNCHER_NO_PAUSE (
    echo Set UNITY_LAUNCHER_NO_PAUSE=1 before calling this to skip the pause when scripted.
    pause
  )
)
REM Restore the caller's code page LAST, right before exiting.
REM Order matters: chcp is process-global, and if we restored it before the messages
REM above, a redirected run would mix encodings in one stream (the PowerShell part in
REM UTF-8, the cmd part in the caller's code page) - unreadable for both decoders.
REM Strip a trailing dot first: some locales print "Active code page: 850." and
REM "chcp 850." is rejected by cmd, which would leave the caller on 65001 silently.
REM
REM Use %%A directly instead of a !VAR! temp: this file does NOT enable delayed
REM expansion (deliberately - see top of file: !VAR! would eat "!" inside %* paths),
REM and under normal expansion "!CP!" stays literal, so findstr never matches and the
REM restore is skipped silently. That regression was measured (caller stayed on 65001).
if defined OLDCP (
  for /f "delims=." %%A in ("%OLDCP%") do (
    echo %%A| findstr /r /c:"^[0-9][0-9]*$" >nul && chcp %%A >nul
  )
)
exit /b %RC%
