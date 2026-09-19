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
echo [check_syntax] OK - all runner sources parse cleanly
endlocal
