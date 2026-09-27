@echo off
REM Syntax-check the Windows runner C++ sources with the same compiler flags the
REM real build uses (/W4 /WX), without invoking MSBuild.
REM
REM Why this exists: agents cannot run `flutter build windows` in this repo's
REM environment (MSBuild/FileTracker crashes), which used to make every change
REM under windows/runner/ unverifiable until the user built it. `cl /Zs` parses
REM and type-checks the translation units without generating any output, so a
REM broken edit is caught here instead of on the user's machine.
REM
REM Usage:  windows\runner\check_syntax.bat
REM Exit:   0 = all sources parse cleanly; non-zero = compiler diagnostics above.
REM
REM NOTE: keep everything under windows\runner\ ASCII-only (English comments).
REM There is no /utf-8 flag here or in the real build, so cl.exe decodes sources
REM in the system ANSI codepage (936/GBK on a Chinese Windows). Multi-byte
REM characters then derail the parse -- a UTF-8 comment can swallow the newline
REM and the next declaration, and any leftover byte trips C4819 which /WX turns
REM into an error. (The Linux runner sources live under linux\runner and are
REM compiled by clang/gcc, which default to UTF-8; Chinese comments there are
REM fine.)

setlocal
set "REPO_ROOT=%~dp0..\.."
cd /d "%REPO_ROOT%"

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VCVARS="
if exist "%VSWHERE%" (
  for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2^>nul`) do set "VSINSTALL=%%i"
)
if defined VSINSTALL (
  if exist "%VSINSTALL%\VC\Auxiliary\Build\vcvars64.bat" set "VCVARS=%VSINSTALL%\VC\Auxiliary\Build\vcvars64.bat"
)
if not defined VCVARS (
  echo [check_syntax] Visual Studio C++ build tools not found; skipping.
  exit /b 1
)
call "%VCVARS%" >nul

cl /nologo /Zs /std:c++17 /W4 /WX /wd4100 /EHsc ^
   /DUNICODE /D_UNICODE /DNOMINMAX /D_HAS_EXCEPTIONS=0 ^
   /I windows /I windows\flutter\ephemeral ^
   /I windows\flutter\ephemeral\cpp_client_wrapper\include ^
   windows\runner\win32_window.cpp ^
   windows\runner\main.cpp ^
   windows\runner\flutter_window.cpp ^
   windows\runner\utils.cpp

if errorlevel 1 (
  echo [check_syntax] FAILED
  exit /b 1
)

REM Advisory only (never fails this script): a Low-labeled workspace breaks
REM anything launched from build\ in ways that look like app bugs -- no tray
REM icon, and writes to %TEMP% / %LOCALAPPDATA% / %APPDATA% fail silently.
REM See check_integrity.bat. Printed right above the OK line so it still shows
REM up when only the tail of this output is read.
call "%~dp0check_integrity.bat" >nul 2>&1
if errorlevel 1 (
  echo.
  echo [check_syntax] WARNING: this workspace carries a Low integrity label.
  echo   Anything run from build\ has no tray icon and cannot write to
  echo   %%TEMP%% / %%LOCALAPPDATA%% / %%APPDATA%%. Usual source: the DSH sandbox
  echo   in workspace-write mode -- not an app bug.
  echo   Fix: windows\runner\check_integrity.bat /fix
  echo.
)

echo [check_syntax] OK - all runner sources parse cleanly
endlocal
