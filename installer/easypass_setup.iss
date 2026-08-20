; EasyPass 1.2.0 — Inno Setup installer script
;
; Per-user install: easypass.db is written next to the executable, so the
; app must live in a user-writable directory (LocalAppData), not Program
; Files. No admin rights are required.
;
; Compile:
;   "C:\Program Files\Inno Setup 7\ISCC.exe" installer\easypass_setup.iss

#define MyAppName "EasyPass"
#define MyAppVersion "1.2.0"
#define MyAppPublisher "easypass.com"
#define MyAppExeName "easypass.exe"
#define MyAppId "{{8F1E5B2A-6C4D-4E9F-9A1B-2C3D4E5F6071}"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
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
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "registerhost"; Description: "注册浏览器扩展 Native Messaging 主机"; GroupDescription: "浏览器集成:"; Flags: checkedonce

[Files]
; Application
Source: "..\build\windows\x64\runner\Release\easypass.exe"; DestDir: "{app}"; Flags: ignoreversion
; Flutter engine
Source: "..\build\windows\x64\runner\Release\flutter_windows.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\dartjni.dll"; DestDir: "{app}"; Flags: ignoreversion
; Flutter plugins
Source: "..\build\windows\x64\runner\Release\flutter_secure_storage_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\share_plus_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\sqlite3_flutter_libs_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\url_launcher_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\sqlite3.dll"; DestDir: "{app}"; Flags: ignoreversion
; VC++ runtime (app-local deployment)
Source: "..\build\windows\x64\runner\Release\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion
; Flutter AOT snapshot, ICU data and bundled assets
Source: "..\build\windows\x64\runner\Release\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
; Runtime-loaded fonts (FontLoader reads assets/fonts next to the exe)
Source: "..\build\windows\x64\runner\Release\assets\fonts\*"; DestDir: "{app}\assets\fonts"; Flags: ignoreversion recursesubdirs createallsubdirs
; Native messaging host registration scripts
Source: "..\browser_extension\native_host\install_host.ps1"; DestDir: "{app}\native_host"; Flags: ignoreversion
Source: "..\browser_extension\native_host\uninstall_host.ps1"; DestDir: "{app}\native_host"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\EasyPass"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\EasyPass"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\native_host\install_host.ps1"" -ExePath ""{app}\easypass.exe"""; StatusMsg: "注册浏览器扩展主机..."; Flags: runhidden; Tasks: registerhost
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,EasyPass}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\native_host\uninstall_host.ps1"""; Flags: runhidden
