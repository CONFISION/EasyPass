@echo off
REM Fail loudly when the workspace carries a Low mandatory integrity label.
REM
REM Why this exists: Windows gives a process the integrity level of the image's
REM mandatory label. A process launched from a Low-labeled exe runs at Low
REM integrity, and a Low process
REM   * cannot register a tray icon (Shell_NotifyIcon fails silently),
REM   * cannot write to Medium locations (%TEMP%, %LOCALAPPDATA%, %APPDATA%),
REM   * is treated as untrusted content by SmartScreen.
REM Nothing in the app reports any of that, so it looks like an app bug. On
REM 2026-09-27 this cost about an hour of "why is there no tray icon".
REM
REM Where the label comes from: the DSH Windows ACL sandbox
REM (@deepseek-ai/dsh-sandbox-windows-acl). Its workspace-write grant applies a
REM Low no-write-up mandatory label to the workspace root together with the
REM workspace write ACE -- that label IS the sandbox's write-up protection -- so
REM it appears whenever a session runs in workspace-write mode. Full access
REM (danger-full-access) does not apply it, but it does not clear it either.
REM
REM Both the directories AND the two runner executables are checked: a stale Low
REM exe can sit inside an already-Medium directory (that happened here), and the
REM exe is what decides the process integrity level.
REM
REM Usage:  windows\runner\check_integrity.bat [/fix]
REM   (no args)  verify only
REM   /fix       also raise the label back to Medium (tree + runner exes)
REM Exit:   0 = clean (or fixed); 1 = Low label present, or the fix failed.
REM
REM Three bugs this script already paid for -- do not reintroduce:
REM   1. keep parenthesised strings ("(OI)(CI)Medium") out of multi-line
REM      `if (...)` blocks: cmd mis-parses them, and a version that echoed such a
REM      string inside a block printed the -- fix -- branch even without /fix and
REM      never actually ran icacls;
REM   2. `findstr /i "Low Mandatory"` is an OR match, so it also hits every
REM      "Mandatory Label\Medium..." line -- always use /c:"Low Mandatory";
REM   3. verify the label with a separate `icacls` call after /fix, never trust
REM      this script's own success message.
setlocal
for %%I in ("%~dp0..\..") do set "REPO_ROOT=%%~fI"
set "RELEASE_DIR=%REPO_ROOT%\build\windows\x64\runner\Release"
set "FIX_LOG=%TEMP%\easypass_integrity_fix.log"

set "DO_FIX="
if /i "%~1"=="/fix" set "DO_FIX=1"

call :scan
if not defined BAD goto :clean
if defined DO_FIX goto :fix
goto :report

:scan
set "BAD="
for /f "delims=" %%L in ('icacls "%REPO_ROOT%" 2^>nul ^| findstr /i /c:"Low Mandatory"') do set "BAD=%REPO_ROOT%"
for /f "delims=" %%L in ('icacls "%RELEASE_DIR%" 2^>nul ^| findstr /i /c:"Low Mandatory"') do set "BAD=%RELEASE_DIR%"
for /f "delims=" %%L in ('icacls "%RELEASE_DIR%\easypass.exe" 2^>nul ^| findstr /i /c:"Low Mandatory"') do set "BAD=%RELEASE_DIR%\easypass.exe"
for /f "delims=" %%L in ('icacls "%RELEASE_DIR%\easypass_native_host.exe" 2^>nul ^| findstr /i /c:"Low Mandatory"') do set "BAD=%RELEASE_DIR%\easypass_native_host.exe"
goto :eof

:clean
echo [check_integrity] OK - no Low mandatory label on the workspace or the runner exes
exit /b 0

:report
echo [check_integrity] LOW INTEGRITY LABEL DETECTED:
echo   %BAD%
echo.
echo   Anything launched from there runs at Low integrity: no tray icon, and
echo   writes to %%TEMP%% / %%LOCALAPPDATA%% / %%APPDATA%% fail silently.
echo   Usual source: the DSH Windows ACL sandbox in workspace-write mode.
echo.
echo   Fix, DACL untouched, reversible:
echo     windows\runner\check_integrity.bat /fix
echo   or by hand:
echo     icacls "%REPO_ROOT%" /setintegritylevel "(OI)(CI)Medium" /T
echo   Alternative: copy the Release bundle outside the workspace (e.g. into
echo   %%LOCALAPPDATA%%) and run it from there.
exit /b 1

:fix
echo [check_integrity] /fix: raising the tree and the runner exes back to Medium...
icacls "%REPO_ROOT%" /setintegritylevel "(OI)(CI)Medium" /T > "%FIX_LOG%" 2>&1
icacls "%RELEASE_DIR%" /setintegritylevel "(OI)(CI)Medium" /T >> "%FIX_LOG%" 2>&1
icacls "%RELEASE_DIR%\easypass.exe" /setintegritylevel Medium >> "%FIX_LOG%" 2>&1
icacls "%RELEASE_DIR%\easypass_native_host.exe" /setintegritylevel Medium >> "%FIX_LOG%" 2>&1
findstr /i /c:"Failed processing 0 files" "%FIX_LOG%" >nul || echo   note: icacls reported failures - see %FIX_LOG%
call :scan
if defined BAD goto :still_low
echo [check_integrity] OK - workspace and runner exes are Medium again
echo [check_integrity] note: a rebuild while the sandbox is active re-inherits the
echo   label - build/run from a copy outside the workspace to stay clean.
exit /b 0

:still_low
echo [check_integrity] still Low after the fix: %BAD%
echo   If this repeats the sandbox is re-applying it: switch this session to
echo   full access (danger-full-access), then run /fix again.
exit /b 1
