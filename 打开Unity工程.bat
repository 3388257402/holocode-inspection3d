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
REM ---- Read the caller's console code page ---------------------------------------
REM `chcp` output is LOCALIZED, so parsing by "tokens=2 delims=:" assumes an ASCII colon.
REM If a locale prints something else (or bars a trailing dot), the primary parse fails and
REM we fall back to the registry OEM code page.
REM
REM Three things that are easy to get wrong here (all measured):
REM   1. The console page is the OEM page, not the ANSI one. On a Western locale
REM      ACP=1252 while the console is 850 / 65001 -- restoring ACP picks a page the
REM      console never had. So read OEMCP.
REM   2. `reg query` prints it DECIMAL ("OEMCP  REG_SZ  936"); there is no 0x prefix.
REM   3. Every assignment stays OUTSIDE parenthesised blocks: %VAR% is expanded when a
REM      block is parsed, so a value assigned inside the same block is still empty there
REM      (measured: OLDCP stayed empty while the variable itself did get set).
REM
REM "Is this value usable?" is decided in ONE place (the digit checks below), so the
REM restore step and the warnings at :finish cannot disagree. Before, a defined-but-
REM unusable OLDCP was a silent exit: no restore and no warning at all.
set "OLDCP="
set "CPPRIMARY="
set "CPFROMFALLBACK="
set "OEMCP="
for /f "tokens=2 delims=:" %%C in ('chcp') do set "CPPRIMARY=%%C"
if defined CPPRIMARY set "CPPRIMARY=%CPPRIMARY: =%"
REM Strip the trailing dot some locales print ("Active code page: 850.") BEFORE validating,
REM so the primary path still yields the REAL page instead of falling back to OEMCP.
if defined CPPRIMARY for /f "delims=." %%D in ("%CPPRIMARY%") do set "CPPRIMARY=%%D"
set "OLDCP=%CPPRIMARY%"
set "CPOK="
if defined OLDCP echo %OLDCP%| findstr /r /c:"^[0-9][0-9]*$" >nul || set "OLDCP="
if defined OLDCP set "CPOK=1"
if not defined OLDCP for /f "tokens=3" %%R in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Nls\CodePage" /v OEMCP 2^>nul') do set "OEMCP=%%R"
if not defined OLDCP if defined OEMCP echo %OEMCP%| findstr /r /c:"^[0-9][0-9]*$" >nul && set "OLDCP=%OEMCP%"
REM Flag the fallback by "did the PRIMARY path produce a usable value", not by
REM "is CPPRIMARY defined": on a dot-locale CPPRIMARY is defined but unusable, and
REM that used to skip the WARN while still switching the caller to the OEM page.
if not defined CPOK if defined OLDCP set "CPFROMFALLBACK=1"
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
REM Restore LAST (see note above) and say which path was taken:
REM   - primary parse worked -> silent restore (the normal case)
REM   - fell back to OEMCP   -> visible WARN: the caller may end up on the system
REM     default page instead of the page it actually started on. Saying it out loud
REM     matters, because otherwise the user's terminal silently changes behaviour.
REM   - nothing readable     -> visible WARN: may stay on 65001.
if defined OLDCP if defined CPFROMFALLBACK (
  REM Also fix the stale reason in the header: OEMCP is NOT necessarily the page the
  REM caller had either, so the honest wording is "system default", not "the caller's page".
  echo [WARN] Caller code page unknown; restoring the system default %OLDCP%.
)
if not defined OLDCP (
  echo [WARN] Could not read the caller's code page; this window may stay on 65001.
)
REM OLDCP is digits-only by now (validated above), so no further parsing is needed.
if defined OLDCP chcp %OLDCP% >nul
exit /b %RC%