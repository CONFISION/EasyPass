<#
.SYNOPSIS
    Build the EasyPass core service (easypass_core.exe) into <OutDir>\core\ and
    its runtime libraries into <OutDir>\lib\.

.DESCRIPTION
    `dart compile exe` is NOT usable in this repository: the dependency graph
    contains packages with build hooks (sqlite3 / objective_c) and the SDK
    answers "'dart compile' does not support build hooks, use 'dart build'
    instead". `dart build cli` is the supported path (verified with Dart SDK
    3.13.4).

    `dart build cli -o <dir>` produces a bundle:

        <dir>/bundle/bin/easypass_core.exe     the executable
        <dir>/bundle/lib/sqlite3.dll           build-hook dynamic libraries

    WHY THE CORE LIVES IN A SUBDIRECTORY (measured, not assumed)
    -----------------------------------------------------------
    package:sqlite3 is compiled with `@ffi.DefaultAsset`, so the VM resolves
    the library as a path relative to the EXECUTABLE:

        <exe_dir>\..\lib\<name>

    Measured on Windows x64 / Dart 3.13.4:

      * exe in <d>, sqlite3.dll in <d>            -> FAILS
        ("Failed to load dynamic library '..\lib\sqlite3.dll' relative to
          '<d>\easypass_core.exe'")
      * exe in <d>\core, sqlite3.dll in <d>\lib   -> works

    The standard Windows "DLL next to the exe" search does NOT apply to this
    artifact, and a `native_assets.json` sidecar is ignored as well. The layout
    below satisfies the lookup while keeping everything inside the application
    directory:

        <OutDir>\easypass.exe              the UI (Flutter build, untouched)
        <OutDir>\sqlite3.dll               Flutter's own copy, used by the UI
        <OutDir>\core\easypass_core.exe    the core service
        <OutDir>\lib\sqlite3.dll           the core's library
                                           (<exe>\..\lib resolves to <OutDir>\lib)

    The data directory is still <OutDir> even though the core sits one level
    deeper: AppPaths._resolveDataDirectory() (lib/core/platform/app_paths.dart)
    takes the parent directory when it contains the UI binary, so the vault
    (easypass.db) and daemon.json keep their 2.4.x coordinates.

.PARAMETER OutDir
    Directory that holds easypass.exe. Defaults to the Flutter Windows
    Release directory.

.PARAMETER EntryPoint
    Dart entry point, relative to the repository root.
    Defaults to bin\easypass_core.dart.

.PARAMETER BuildDir
    Intermediate `dart build cli -o` directory (kept between runs so the build
    is incremental). Defaults to build\core.

.EXAMPLE
    pwsh -File tool\build_core.ps1
    pwsh -File tool\build_core.ps1 -OutDir build\spike_core2

.NOTES
    Exit code 0 only when the core is in place, every library from the bundle is
    at the path the runtime resolves, and the produced binary passes its
    --version smoke test. Comments are ASCII on purpose: Windows PowerShell 5.1
    decodes a BOM-less script with the system ANSI code page (the same trap as
    windows/runner/**), so non-ASCII bytes here would be read as mojibake.
#>
[CmdletBinding()]
param(
  [string]$OutDir = "build\windows\x64\runner\Release",
  [string]$EntryPoint = "bin\easypass_core.dart",
  [string]$BuildDir = "build\core"
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ExeName = 'easypass_core.exe'
$SqliteName = 'sqlite3.dll'
$CoreSubdir = 'core'
$LibSubdir = 'lib'

function Fail([string]$Message) {
  Write-Host "build_core: ERROR: $Message" -ForegroundColor Red
  exit 1
}

function Copy-Libs([string]$SourceDir, [string]$TargetDir, [string]$Label) {
  $count = 0
  if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) { return 0 }
  if (-not (Test-Path -LiteralPath $TargetDir)) {
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
  }
  foreach ($lib in Get-ChildItem -LiteralPath $SourceDir -File) {
    $target = Join-Path $TargetDir $lib.Name
    Copy-Item -LiteralPath $lib.FullName -Destination $target -Force
    Write-Host ("build_core: {0} {1} ({2:N0} bytes)" -f $Label, $target, $lib.Length)
    $count++
  }
  return $count
}

Push-Location $RepoRoot
try {
  if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $EntryPoint))) {
    Fail "entry point not found: $EntryPoint (expected under $RepoRoot)"
  }
  if (-not (Get-Command dart -ErrorAction SilentlyContinue)) {
    Fail 'dart is not on PATH (install the Flutter/Dart SDK, or run from a Flutter shell)'
  }

  Write-Host "build_core: dart build cli -o $BuildDir -t $EntryPoint"
  & dart build cli -o $BuildDir -t $EntryPoint
  if ($LASTEXITCODE -ne 0) {
    Fail "dart build cli failed (exit $LASTEXITCODE)"
  }

  $bundleBin = Join-Path $RepoRoot (Join-Path $BuildDir 'bundle\bin')
  $bundleLib = Join-Path $RepoRoot (Join-Path $BuildDir 'bundle\lib')
  $srcExe = Join-Path $bundleBin $ExeName
  if (-not (Test-Path -LiteralPath $srcExe)) {
    Fail "dart build cli produced no $ExeName (looked for $srcExe)"
  }

  if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  }
  if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
    Fail "output path is not a directory: $OutDir"
  }
  $outAbs = (Resolve-Path -LiteralPath $OutDir).Path
  $coreDir = Join-Path $outAbs $CoreSubdir
  # This IS the path the runtime resolves: <exe_dir> is <OutDir>\core, so
  # <exe_dir>\..\lib == <OutDir>\lib.
  $libDir = Join-Path $outAbs $LibSubdir

  # --- 1. the core executable: always replaced -----------------------------
  if (-not (Test-Path -LiteralPath $coreDir)) {
    New-Item -ItemType Directory -Force -Path $coreDir | Out-Null
  }
  $dstExe = Join-Path $coreDir $ExeName
  try {
    Copy-Item -LiteralPath $srcExe -Destination $dstExe -Force
  } catch {
    Fail ("cannot write $dstExe -- $($_.Exception.Message). " +
          'A running easypass_core.exe locks its own image; stop it first: ' +
          'taskkill /IM easypass_core.exe /F')
  }
  $exeSize = (Get-Item -LiteralPath $dstExe).Length
  Write-Host ("build_core: core    {0} ({1:N0} bytes, {2:N2} MB)" -f $dstExe, $exeSize, ($exeSize / 1MB))

  # --- 2. the core's libraries: <OutDir>\lib, refreshed every build --------
  # The directory belongs to the core (Flutter keeps its own sqlite3.dll in
  # <OutDir> itself), so a stale library from an earlier build is replaced.
  $nLib = Copy-Libs -SourceDir $bundleLib -TargetDir $libDir -Label 'lib    '

  # --- 3. verify every bundle library is where the runtime looks -----------
  $missing = @()
  if (Test-Path -LiteralPath $bundleLib -PathType Container) {
    foreach ($lib in Get-ChildItem -LiteralPath $bundleLib -File) {
      if (-not (Test-Path -LiteralPath (Join-Path $libDir $lib.Name))) {
        $missing += $lib.Name
      }
    }
  }
  if ($missing.Count -gt 0) {
    Fail "not loadable at runtime: $($missing -join ', ') missing from $libDir"
  }
  if (-not (Test-Path -LiteralPath (Join-Path $libDir $SqliteName))) {
    Write-Host "build_core: WARNING: no $SqliteName in $libDir -- easypass_core.exe cannot open the vault" -ForegroundColor Yellow
  }

  # --- 4. smoke test: the produced binary must start ------------------------
  # `--version` prints and exits before any vault access, so running it here is
  # side-effect free (no daemon.json, no core.lock, no database).
  $version = & $dstExe --version
  if ($LASTEXITCODE -ne 0) {
    Fail "the produced core failed its --version smoke test (exit $LASTEXITCODE)"
  }
  Write-Host "build_core: smoke   $($version -join ' ')"

  # --- 5. report the UI side's copy (produced by the Flutter build) --------
  $uiSqlite = Join-Path $outAbs $SqliteName
  if (Test-Path -LiteralPath $uiSqlite) {
    Write-Host ("build_core: keep    {0} ({1:N0} bytes, Flutter's copy for the UI)" -f $uiSqlite, (Get-Item -LiteralPath $uiSqlite).Length)
  } else {
    Write-Host "build_core: note: no $uiSqlite yet -- the UI's copy comes from the Flutter build, not from here"
  }

  Write-Host ''
  Write-Host "build_core: OK"
  Write-Host "  core        : $dstExe"
  Write-Host ("  size        : {0:N0} bytes ({1:N2} MB)" -f $exeSize, ($exeSize / 1MB))
  Write-Host "  core libs   : $libDir  ($nLib file(s); loaded as ..\lib\<name> relative to the exe)"
  exit 0
} finally {
  Pop-Location
}
