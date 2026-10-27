; EasyPass 3.0.0 — Inno Setup installer script
;
; Per-user install: easypass.db is written next to the executable, so the
; app must live in a user-writable directory (LocalAppData), not Program
; Files. No admin rights are required.
;
; Native messaging host registration is done natively in [Code] (registry +
; manifest file). No PowerShell is spawned by the installer — this keeps
; Defender heuristics quiet: silently running powershell.exe with
; -ExecutionPolicy Bypass from an unsigned installer is a classic
; malware behavior and triggered Trojan:Win32/Wacatac.B!ml false positives.
;
; Compile:
;   1) flutter build windows
;   2) pwsh -File tool\build_core.ps1     (adds core\easypass_core.exe and
;                                         lib\sqlite3.dll to the Release dir)
;   3) "C:\Program Files\Inno Setup 7\ISCC.exe" installer\easypass_setup.iss
;
; Step 2 is required: the core service is a separate executable, and ISCC
; fails with "Source file ... does not exist" when it was never built.

#define MyAppName "EasyPass"
#define MyAppVersion "3.1.0"
#define MyAppPublisher "easypass.com"
#define MyAppExeName "easypass.exe"
#define MyAppId "{{8F1E5B2A-6C4D-4E9F-9A1B-2C3D4E5F6071}"

; ─── App-local MSVC runtime source ──────────────────────────────────────
; easypass.exe and the plugin DLLs import MSVCP140 / VCRUNTIME140 /
; VCRUNTIME140_1 (everything else is the UCRT that ships with Windows 10+), so
; the installer bundles them next to the app.
;
; Flutter's generated Windows runner does NOT copy them into the build output;
; installer\copy_vc_runtime.bat does (hooked into the build via a POST_BUILD
; step in windows\runner\CMakeLists.txt). Because `windows/` is gitignored and
; can be regenerated, this script falls back to the build machine's system
; directory instead of aborting the compile -- a missing runtime DLL would
; otherwise break packaging with a "Source file ... does not exist" error.
#define ReleaseDir "..\build\windows\x64\runner\Release"
#define SystemDir GetEnv('SystemRoot') + "\System32"

#if FileExists(AddBackslash(ReleaseDir) + "msvcp140.dll")
  #define CrtMsvcp140 AddBackslash(ReleaseDir) + "msvcp140.dll"
#else
  #define CrtMsvcp140 AddBackslash(SystemDir) + "msvcp140.dll"
#endif

#if FileExists(AddBackslash(ReleaseDir) + "vcruntime140.dll")
  #define CrtVcruntime140 AddBackslash(ReleaseDir) + "vcruntime140.dll"
#else
  #define CrtVcruntime140 AddBackslash(SystemDir) + "vcruntime140.dll"
#endif

#if FileExists(AddBackslash(ReleaseDir) + "vcruntime140_1.dll")
  #define CrtVcruntime140_1 AddBackslash(ReleaseDir) + "vcruntime140_1.dll"
#else
  #define CrtVcruntime140_1 AddBackslash(SystemDir) + "vcruntime140_1.dll"
#endif

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppComments=Local-first, open-source password manager for Windows
AppCopyright=Copyright (C) 2026 easypass.com
; Version resource of the generated Setup.exe. BOTH fields must track
; MyAppVersion -- check_extension.mjs asserts them. It used to check only
; VersionInfoVersion, which is how ProductVersion stayed behind at 2.4.0.0.
VersionInfoVersion=3.1.0.0
VersionInfoProductVersion=3.1.0.0
VersionInfoProductName=EasyPass
VersionInfoDescription=EasyPass Password Manager Installer
DefaultDirName={localappdata}\Programs\EasyPass
DefaultGroupName=EasyPass
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\build\installer
OutputBaseFilename=EasypassSetup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\easypass.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

[Languages]
; Inno Setup 官方安装包**不带**中文语言文件（中文属"非官方翻译"）：CI 上
; `choco install innosetup` 装出来的 Languages\ 目录里没有 ChineseSimplified.isl，
; 于是老的 `compiler:Languages\ChineseSimplified.isl` 直接编译失败（2026-10-18 CI 实测）。
;
; 现在把 .isl 随仓库分发（installer\languages\，UTF-8 BOM，文件头标注 Inno 6.5.0+，
; 6 与 7 都能用），并用 #if 做**条件 include**：文件不在就退化为只有英文，
; 绝不让"缺一个翻译文件"阻断打包。路径用 SourcePath 拼绝对路径，不依赖
; ISCC 的工作目录。
#define ChineseIsl AddBackslash(SourcePath) + "languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"
#if FileExists(ChineseIsl)
Name: "chinesesimplified"; MessagesFile: "{#ChineseIsl}"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "registerhost"; Description: "注册浏览器扩展 Native Messaging 主机"; GroupDescription: "浏览器集成:"; Flags: checkedonce
Name: "autostart"; Description: "登录时自动启动 EasyPass（后台服务随系统启动）"; GroupDescription: "随系统启动:"

[Files]
; Application (UI only: no vault access, no keys)
Source: "..\build\windows\x64\runner\Release\easypass.exe"; DestDir: "{app}"; Flags: ignoreversion
; Core service: headless, owns the vault database, started as `--serve`.
; It lives in {app}\core so that its native library lookup
; (`<exe dir>\..\lib\sqlite3.dll`, see the next entry) stays inside {app}.
; The vault itself is still {app}\easypass.db: AppPaths takes the parent
; directory when it contains easypass.exe, so data coordinates are unchanged.
Source: "{#ReleaseDir}\core\easypass_core.exe"; DestDir: "{app}\core"; Flags: ignoreversion
; The core's sqlite3.dll, built as a Dart build-hook dependency. The Dart CLI
; runtime resolves it as `<exe dir>\..\lib\sqlite3.dll` -- measured on Dart
; 3.13.4; the copy sitting next to the executable is never consulted, and a
; native_assets.json sidecar is ignored. With the core in {app}\core that path
; is exactly {app}\lib. {app}\sqlite3.dll is Flutter's own copy for the UI and
; stays untouched.
;
; NOTE the path must include `Release`: tool/build_core.ps1 writes the library
; to <OutDir>\lib, and <OutDir> is the runner's Release directory. (An earlier
; version omitted it and ISCC failed with "Source file ... does not exist".)
Source: "{#ReleaseDir}\lib\sqlite3.dll"; DestDir: "{app}\lib"; Flags: ignoreversion
; x86 console bridge: browser stdio -> core TCP (native messaging host)
Source: "..\build\windows\x64\runner\Release\easypass_native_host.exe"; DestDir: "{app}"; Flags: ignoreversion
; Flutter engine
Source: "..\build\windows\x64\runner\Release\flutter_windows.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\dartjni.dll"; DestDir: "{app}"; Flags: ignoreversion
; Flutter plugins
Source: "..\build\windows\x64\runner\Release\flutter_secure_storage_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\share_plus_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\sqlite3_flutter_libs_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\url_launcher_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\sqlite3.dll"; DestDir: "{app}"; Flags: ignoreversion
; VC++ runtime (app-local deployment). Default source is the build output
; directory (filled in by installer\copy_vc_runtime.bat during the build); if it
; is not there -- e.g. `windows/` was regenerated and the POST_BUILD hook is
; gone -- the preprocessor above points at the system directory instead, so the
; compile still succeeds instead of failing with "Source file does not exist".
Source: "{#CrtMsvcp140}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#CrtVcruntime140}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#CrtVcruntime140_1}"; DestDir: "{app}"; Flags: ignoreversion
; Flutter AOT snapshot, ICU data and bundled assets
Source: "..\build\windows\x64\runner\Release\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
; Runtime-loaded fonts (FontLoader reads assets/fonts next to the exe)
Source: "..\build\windows\x64\runner\Release\assets\fonts\*"; DestDir: "{app}\assets\fonts"; Flags: ignoreversion recursesubdirs createallsubdirs
; Native messaging host scripts (manual registration only — the installer
; registers the host natively in [Code], see below)
Source: "..\browser_extension\native_host\install_host.ps1"; DestDir: "{app}\native_host"; Flags: ignoreversion
Source: "..\browser_extension\native_host\uninstall_host.ps1"; DestDir: "{app}\native_host"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\EasyPass"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\EasyPass"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,EasyPass}"; Flags: nowait postinstall skipifsilent

; ─── Native messaging host registration (no PowerShell) ────────────────

[Code]
const
  ExtensionId = 'hlkbbdlgaocmnjlgpafkimobnkfniike';
  HostName = 'com.easypass.app';

var
  HostRegistered: Boolean;

(* ─── Core service lifecycle ──────────────────────────────────────────────
  {app}\core\easypass_core.exe --serve is a user-level background process that
  owns the vault database. A running copy locks its own image and the vault in
  {app}, so it must be stopped before files are replaced (install) or removed
  (uninstall). The UI (easypass.exe) is left to Inno's own CloseApplications
  handling, which asks the user first.

  Everything here is best-effort ON PURPOSE: this is a per-user install and a
  failure to stop the core must never abort it (the autostart entry brings the
  core back). taskkill exits 128 when no process matches -- that is the normal
  "nothing to stop" case, not an error, so the exit code is ignored. *)
procedure StopCoreService();
var
  ResultCode: Integer;
  CorePath: String;
begin
  CorePath := ExpandConstant('{app}\core\easypass_core.exe');

  (* Graceful path: ask the running core to shut down (flushes, releases the
    vault, removes daemon.json). Started WITHOUT waiting -- a hung core must
    not be able to block the installer. Skipped on a fresh install and when
    upgrading from 2.4.x (there is no core binary yet). *)
  if FileExists(CorePath) then
  begin
    Exec(CorePath, '--shutdown', '', SW_HIDE, ewNoWait, ResultCode);
    (* ~3 s grace period for that shutdown, without a WaitForSingleObject that
      could hang: `ping` on loopback is the portable sleep here (`timeout`
      needs a console). *)
    Exec('cmd.exe', '/C ping -n 4 127.0.0.1 >NUL', '', SW_HIDE,
         ewWaitUntilTerminated, ResultCode);
  end;

  (* Backstop for anything still alive (a hung core, or one from an older
    version). Idempotent: no matching process is not an error. *)
  Exec('taskkill.exe', '/IM easypass_core.exe /F', '', SW_HIDE,
       ewWaitUntilTerminated, ResultCode);
end;

function JsonEscape(const S: String): String;
begin
  (* JSON strings need backslashes escaped. The install dir may contain no
    quotes, so escaping backslashes is sufficient for Windows paths. *)
  Result := S;
  StringChangeEx(Result, '\', '\\', True);
end;

procedure RegisterNativeHost();
var
  ManifestDir, ManifestPath, ExePath, Manifest: String;
begin
  ManifestDir := ExpandConstant('{localappdata}\EasyPass');
  if not DirExists(ManifestDir) then
    ForceDirectories(ManifestDir);
  ManifestPath := ManifestDir + '\' + HostName + '.json';
  ExePath := ExpandConstant('{app}\easypass_native_host.exe');

  Manifest :=
    '{' + #13#10 +
    '  "name": "' + HostName + '",' + #13#10 +
    '  "description": "EasyPass Password Manager Native Messaging Host",' + #13#10 +
    '  "path": "' + JsonEscape(ExePath) + '",' + #13#10 +
    '  "type": "stdio",' + #13#10 +
    '  "allowed_origins": ["chrome-extension://' + ExtensionId + '/"]' + #13#10 +
    '}';

  (* SaveStringToFile with Unicode=False writes ANSI -- since the manifest
    content is pure ASCII, the output bytes equal UTF-8 WITHOUT a BOM, which
    is what Chromium's JSON parser requires. Keep the content ASCII-only. *)
  if SaveStringToFile(ManifestPath, Manifest, False) then
  begin
    // Register BOTH registry views: 64-bit browsers read HKCU\Software\...
    // while 32-bit browsers (Edge/Chrome x86) read the redirected
    // HKCU\Software\WOW6432Node\... view. Missing one yields
    // "Specified native messaging host not found".
    RegWriteStringValue(HKCU64, 'Software\Google\Chrome\NativeMessagingHosts\' + HostName, '', ManifestPath);
    RegWriteStringValue(HKCU64, 'Software\Microsoft\Edge\NativeMessagingHosts\' + HostName, '', ManifestPath);
    RegWriteStringValue(HKCU32, 'Software\Google\Chrome\NativeMessagingHosts\' + HostName, '', ManifestPath);
    RegWriteStringValue(HKCU32, 'Software\Microsoft\Edge\NativeMessagingHosts\' + HostName, '', ManifestPath);
    HostRegistered := True;
  end;
end;

procedure UnregisterNativeHost();
begin
  RegDeleteKeyIncludingSubkeys(HKCU64, 'Software\Google\Chrome\NativeMessagingHosts\' + HostName);
  RegDeleteKeyIncludingSubkeys(HKCU64, 'Software\Microsoft\Edge\NativeMessagingHosts\' + HostName);
  RegDeleteKeyIncludingSubkeys(HKCU32, 'Software\Google\Chrome\NativeMessagingHosts\' + HostName);
  RegDeleteKeyIncludingSubkeys(HKCU32, 'Software\Microsoft\Edge\NativeMessagingHosts\' + HostName);
  DeleteFile(ExpandConstant('{localappdata}\EasyPass\') + HostName + '.json');
end;

(* Register EasyPass in the HKCU Run key so it starts at logon AND appears in
  Task Manager's "Startup" tab (Task Scheduler entries are NOT listed there).
  The value is written by the installer wizard itself (user-visible), not by
  a silent script, so it does not look like malware behavior.

  Since 3.0.0 this starts the CORE service (--serve), not the UI: the core is
  the resident process that owns the vault and serves the browser extension,
  while the UI is opened by the user (tray / desktop icon / start menu). *)
procedure RegisterAutoStart();
begin
  RegWriteStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run',
                      'EasyPass',
                      '"' + ExpandConstant('{app}\core\easypass_core.exe') + '" --serve');
end;

procedure UnregisterAutoStart();
var
  ResultCode: Integer;
begin
  RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run',
                 'EasyPass');
  // Clean up the legacy Task Scheduler entry registered by earlier builds.
  Exec('schtasks.exe', '/Delete /F /TN "EasyPass"', '', SW_HIDE,
       ewWaitUntilTerminated, ResultCode);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  (* ssInstall runs just before the files are copied: the core has to be gone
    by then. *)
  if CurStep = ssInstall then
    StopCoreService();

  if CurStep = ssPostInstall then
  begin
    if WizardIsTaskSelected('registerhost') then
      RegisterNativeHost();
    if WizardIsTaskSelected('autostart') then
      RegisterAutoStart();
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  (* usUninstall runs before the files are removed. *)
  if CurUninstallStep = usUninstall then
  begin
    StopCoreService();
    UnregisterAutoStart();
    UnregisterNativeHost();
  end;
end;



