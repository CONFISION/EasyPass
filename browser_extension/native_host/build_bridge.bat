@echo off
REM Build easypass_native_host.exe -- the x86 console bridge that connects
REM the browser's stdio native-messaging pipe to the EasyPass daemon.
REM
REM Usage:  build_bridge.bat [output_dir]
REM   output_dir defaults to build\windows\x64\runner\Release (next to
REM   easypass.exe, where the host manifest expects it).
REM
REM Uses cl.exe directly (no MSBuild), so it works even in environments where
REM the Flutter Windows build itself cannot run.

setlocal
set "OUT_DIR=%~1"
if "%OUT_DIR%"=="" set "OUT_DIR=build\windows\x64\runner\Release"

set "SCRIPT_DIR=%~dp0"
set "SRC=%SCRIPT_DIR%easypass_native_host.cpp"

REM Locate Visual Studio (any edition) with the x86 C++ tools.
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"

set "VCVARS="
if exist "%VSWHERE%" (
  for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2^>nul`) do set "VSINSTALL=%%i"
)
if defined VSINSTALL (
  if exist "%VSINSTALL%\VC\Auxiliary\Build\vcvars32.bat" set "VCVARS=%VSINSTALL%\VC\Auxiliary\Build\vcvars32.bat"
)
if not defined VCVARS (
  echo [build_bridge] Visual Studio C++ tools not found. Install "Desktop development with C++".
  exit /b 1
)

call "%VCVARS%" >nul
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"
cl /nologo /O1 /MT /EHsc /W3 /D_CRT_SECURE_NO_WARNINGS /Fe:"%OUT_DIR%\easypass_native_host.exe" "%SRC%" ws2_32.lib
if errorlevel 1 exit /b 1
echo [build_bridge] built %OUT_DIR%\easypass_native_host.exe
endlocal
