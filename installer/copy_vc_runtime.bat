@echo off
REM Copy the app-local x64 MSVC runtime DLLs next to easypass.exe.
REM
REM Why this exists: the installer (installer\easypass_setup.iss) ships the
REM VC++ runtime app-local, but Flutter's generated Windows runner does not copy
REM it into the build output -- windows\CMakeLists.txt only installs the app,
REM ICU data, plugin DLLs, fonts and assets, so nothing ever produced these three
REM files and packaging failed with "Source file ... does not exist".
REM This script is wired into the build by a POST_BUILD step in
REM windows\runner\CMakeLists.txt (a tracked file -- keep that hook). The .iss
REM additionally falls back to the system directory so packaging never hard-fails
REM without it.
REM
REM Which DLLs: `dumpbin /dependents` on easypass.exe and the plugin DLLs shows
REM exactly MSVCP140.dll, VCRUNTIME140.dll and VCRUNTIME140_1.dll (everything
REM else is the UCRT, which ships with Windows 10+).
REM
REM Usage:  copy_vc_runtime.bat [output_dir]
REM   output_dir defaults to build\windows\x64\runner\Release (next to
REM   easypass.exe, which is what the installer collects).

setlocal enabledelayedexpansion
set "OUT_DIR=%~1"
if "%OUT_DIR%"=="" set "OUT_DIR=build\windows\x64\runner\Release"
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

set "CRT_SRC="

REM 1) Preferred: the VS redistributable folder (set by vcvars*/developer prompt).
if defined VCToolsRedistDir (
  for /d %%d in ("%VCToolsRedistDir%x64\Microsoft.VC*CRT") do set "CRT_SRC=%%~fd"
)

REM 2) Otherwise ask vswhere for the VS install and use its newest redist.
if not defined CRT_SRC (
  set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
  if not exist "!VSWHERE!" set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
  if exist "!VSWHERE!" (
    for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2^>nul`) do set "VSINSTALL=%%i"
  )
  if defined VSINSTALL (
    for /d %%v in ("!VSINSTALL!\VC\Redist\MSVC\*") do (
      for /d %%d in ("%%~fv\x64\Microsoft.VC*CRT") do set "CRT_SRC=%%~fd"
    )
  )
)

REM 3) Last resort: the system directory (the redistributable is installed there
REM    by any VC++ redist / Visual Studio installation).
if not defined CRT_SRC set "CRT_SRC=%SystemRoot%\System32"

set "MISSING="
for %%f in (msvcp140.dll vcruntime140.dll vcruntime140_1.dll) do (
  if exist "%CRT_SRC%\%%f" (
    copy /y "%CRT_SRC%\%%f" "%OUT_DIR%\%%f" >nul
  ) else (
    set "MISSING=!MISSING! %%f"
  )
)

if defined MISSING (
  echo [copy_vc_runtime] WARNING: missing in "%CRT_SRC%":!MISSING!
  echo [copy_vc_runtime] Packaging still works ^(the .iss falls back to the system directory^),
  echo [copy_vc_runtime] but the build output is not self-contained.
  REM Deliberately exit 0: this runs as a POST_BUILD step, and a packaging-only
  REM concern must never fail `flutter build windows`.
  endlocal
  exit /b 0
)

echo [copy_vc_runtime] MSVC runtime copied from "%CRT_SRC%" to "%OUT_DIR%"
endlocal
