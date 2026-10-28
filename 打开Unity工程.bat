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
REM Read the caller's code page. `chcp` output is LOCALIZED ("Active code page: 936"
REM vs the localized Chinese form), so parsing by "tokens=2 delims=:" assumes the text has a
REM colon. If a locale prints something else, OLDCP stays empty and the restore block
REM is skipped -- exactly the silent regression this file was fixed for once already.
for /f "tokens=2 delims=:" %%C in ('chcp') do set "OLDCP=%%C"
if defined OLDCP set "OLDCP=%OLDCP: =%"
REM Fallback that does NOT depend on localized text. Two things that are easy to get
REM wrong here (both measured):
REM   1. The console code page is the OEM code page, not the ANSI one. On a Western
REM      locale ACP=1252 while the console is 65001/850 -- restoring ACP would pick a
REM      page the console never had. So read OEMCP.
REM   2. `reg query` prints it DECIMAL ("OEMCP  REG_SZ  936"); there is no 0x prefix.
REM   3. The parse must live OUTSIDE any parenthesised block: %VAR% is expanded when
REM      the block is parsed, so a value assigned inside the same block is still empty
REM      there (measured: OLDCP stayed empty while the variable did get set).
set "OEMCP="
if not defined OLDCP for /f "tokens=3" %%R in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Nls\CodePage" /v OEMCP 2^>nul') do set "OEMCP=%%R"
if not defined OLDCP if defined OEMCP set "OLDCP=%OEMCP%"
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
if not defined OLDCP (
  REM Turn the silent case into a visible one: if neither `chcp` parsing nor the
  REM registry fallback produced a code page, the caller may be left on 65001 and
  REM later GBK output will look garbled. Saying so beats failing silently.
  echo [WARN] Could not read the caller's code page; this window may stay on 65001.
)
exit /b %RC%
