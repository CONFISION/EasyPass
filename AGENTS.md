# AGENTS.md

Guidance for AI agents working in this repository.

## Project Overview

**EasyPass** is a local-first password manager (Bitwarden-like) built with Flutter.
Phase 1 (MVP: master-password vault, CRUD, folders, generator, search, auto-lock)
and Phase 2 (browser extension, native messaging, encrypted export/import, TOTP)
are implemented. **2.3.x** adds four entry types (login / secure note / identity /
SSH key) with custom fields, live TOTP codes, folder management (icons, rename,
guarded delete), type filtering and `type:`/`folder:`/`url:` search prefixes.
**2.3.3** adds the **Linux desktop port** (shipped as a native `.deb` since 3.0.0): tray + close-to-tray in the GTK
runner, single instance with a unix-socket wake-up, XDG autostart, the desktop-entry
CLI (`--install` / `--uninstall` / `--desktop-status`) and browser-host registration
(`--install-browser-host` / `--uninstall-browser-host` / `--browser-host-status`),
with the vault moved to `$XDG_DATA_HOME/easypass/`. **2.4.0** adds
**Bitwarden / Vaultwarden import** (JSON + CSV) and a **Bitwarden-compatible export**,
makes **master-password rotation atomic** (a rotation journal in the vault database,
schema **3**), and adds **CI** plus scripted release engineering. **3.0.0** turns the
app into a **core-service architecture**: a standalone, windowless, always-on
`easypass_core` process owns the vault, the Flutter app is a pure client
(`lib/client/**` → `VaultApi`), and the tray — which belongs to the UI only — offers
`Exit UI Only` and `Exit UI and Stop Service`. **Supported desktops
are Windows and Linux;** Phase 3 (cloud sync, sharing, emergency access, mobile/macOS)
is still planned.

> **Local-only docs (NOT in a fresh clone — `.gitignore` excludes them):** the
> roadmap `Plan.md`, the working agreement/pitfalls `HANDOFF.md`, the data model
> spec `docs/data-model.md`, the acceptance checklist `docs/acceptance-3.0.0.md`,
> the 3.0.0 design doc
> `docs/core-service-refactor.md`, release notes under `docs/`, and the `dist/` audit /
> phase evidence dumps. Never write a committed file that *depends* on them; this
> file and the READMEs must stand alone.

Security model: the master password is never stored. PBKDF2-HMAC-SHA256
(100,000 iterations) derives an AES-256-CBC key. **3.0.0 起** salt + verifier live in
the vault database itself (`vault_meta`, via `VaultMetaSecretStore`) — the old
`flutter_secure_storage` copy is read **once** during upgrade and handed to the core
(`adoptLegacyKeyMaterial`). The derived key exists only in the core process
(`SessionDomains`: separate `ui` / `bridge` sessions) and is cleared on lock
(auto-lock is enforced by the core).

## Build / Test / Lint

Requires Flutter with Dart SDK `^3.12.2`. Linux builds additionally need GTK 3 and
`libayatana-appindicator3-dev`.

```bash
flutter pub get          # install deps
dart run build_runner build --delete-conflicting-outputs   # regenerate database.g.dart (drift)
flutter gen-l10n        # regenerate app_localizations.dart after editing lib/l10n/*.arb
flutter analyze         # lint (flutter_lints)
flutter test            # 570 passing / 3 skipped on Windows (the tree declares ~600
                        # cases; Linux-only files register none here, so a Windows run
                        # reports FEWER CASES, not failures — see CONTRIBUTING.md)
flutter run -d windows  # run desktop app
flutter build windows   # ⚠️ 一条命令完整构建：easypass.exe + x86 桥 + MSVC 运行时
                        #    + core\easypass_core.exe + lib\sqlite3.dll（POST_BUILD）
flutter build linux --release   # Linux bundle → build/linux/x64/release/bundle/
                                # （Linux 侧核心仍要单独跑 tool/build_core.sh，见下）
```

- **`flutter build windows` 现在是完整构建，包含核心服务。** `windows/runner/CMakeLists.txt`
  的第三个 POST_BUILD 会跑 `tool/build_core.ps1`，把 `core\easypass_core.exe` 与
  `lib\sqlite3.dll` 摊平进 Release 目录。**不要再手动跑一遍** `tool/build_core.ps1`
  （幂等，但纯属浪费）。只想调 UI 时跳过核心：
  `flutter build windows -- -DEASYPASS_SKIP_CORE_BUILD=ON`。
  Linux 侧没有对应 hook（`linux/CMakeLists.txt` 未改），`tool/build_release_linux.sh` 与 CI
  仍单独调 `tool/build_core.sh --out-dir <bundle>`，再交给 `installer/deb/build_deb.sh` 打包。
- **构建卡在 `Building native assets failed` 时，先查网络/代理，不要改依赖版本。**
  `package:sqlite3` 的 build hook 在 Windows 上默认**从 GitHub 下载**预编译
  `sqlite3.x64.windows.dll`；代理没开时 `flutter build windows` 在 `build_hooks`
  阶段失败，只报那句没有信息量的 `Building native assets failed`。拿到真实原因的命令
  （不调 MSBuild，agent 可跑）：
  `flutter assemble --no-version-check --output=build\agent_assemble -dTargetPlatform=windows-x64 -dBuildMode=release debug_bundle_windows-x64_assets`
  —— 它会打印 `SocketException ... errno 121`。

- **核心服务（3.0.0）用 `dart build cli` 构建，不是 `dart compile exe`** —— 后者会以
  `'dart compile' does not support build hooks` 直接失败（依赖图里 `sqlite3` /
  `objective_c` 带 build hook）。`tool/build_core.ps1` / `tool/build_core.sh` 已封装：
  产物摊平到 `<OutDir>\core\easypass_core.exe` + `<OutDir>\lib\sqlite3.dll`。
  **`package:sqlite3` 的原生库按 `<exe>\..\lib\<name>` 解析**，所以核心必须待在
  子目录里、库放在 `{app}\lib` —— 这正是那个布局的原因（实测过：与 exe 同目录的
  `sqlite3.dll` 永远不会被加载）。核心 AOT 构建是纯 Dart、agent 可以自己跑来验证；
  正式发布产物仍由用户执行（同 `flutter build`）。
- **核心的输入是空库**：`dart run tool\probe_core.dart --core <path>` 会真正跑一遍
  会话/文件夹/条目/搜索/健康报告/锁定解锁，但**拒绝在已有主密码的库上执行写操作**。

- **Windows 构建命令固定为 `flutter build windows`** — 每次需要构建 Windows 发布版时都使用这条命令。
- **C++ runner 改动可以不用 MSBuild 验证** — `windows\runner\check_syntax.bat` 用与真实构建相同的开关
  （`/W4 /WX`、`cl /Zs`）对 `windows/runner/*.cpp` 做语法与类型检查，不产出任何文件、不调用 MSBuild。
  改过 `windows/runner/**` 后先跑它，别把编译错误留给用户。**该脚本末尾还会提示工作区的强制完整性
  标签问题**（见 `check_integrity.bat` 与下方 pitfalls）。
- **`windows/runner/**` 的源码必须是纯 ASCII** — `check_syntax.bat` 不带 `/utf-8`，cl.exe 按系统
  ANSI 代码页（本机 936）解码，中文注释/全角标点会以 C4819 命中 `/WX` 直接失败。`linux/runner/**`
  由 clang/gcc 编译，中文注释没问题。
- **Windows 上做完原生检查后要还原被 flutter 改写的 Linux 生成物** —
  `linux/flutter/generated_plugin_registrant.{cc,h}` 与 `generated_plugins.cmake` 会被 Windows 端的
  `flutter` 命令以 CRLF 重写（本仓库 `core.autocrlf=true` 且无 `.gitattributes`），
  提交前用 `git checkout -- linux/flutter/generated_*` 还原。
- **窗口最小尺寸在原生层强制** — Windows 在 `windows/runner/win32_window.cpp` 的 `WM_GETMINMAXINFO`
  （`kMinWindowWidth/kMinWindowHeight` = 900×600 逻辑像素，按 DPI 缩放，并夹到显示器工作区内）；
  Linux 在 `linux/runner/my_application.cc` 用 `gtk_widget_set_size_request`，同样先夹到
  `gdk_monitor_get_workarea`。这两个值必须与 `lib/features/vault/screens/vault_screen.dart` 里侧边栏的
  固定宽度保持一致，否则窄窗又会溢出。
- **构建分工（重要约定）** — Windows 原生构建（`flutter build windows` / `flutter run -d windows`）
  由用户亲自执行；agent 负责到构建前的完整测试与 debug（`flutter analyze`、`flutter test`、
  代码审查与修复）。agent 的执行环境与 MSBuild 存在兼容问题（FileTracker 崩溃），
  不要尝试在 agent 侧执行原生构建，也不要将其结果作为交付依据。
- **同理：凡是产出最终交付物的构建/打包，都交给用户** —— 安装包（ISCC）、`flutter build linux`、
  .deb（`installer/deb/build_deb.sh`）、`docker build`、`npm run build`、代码签名、
  发布上传等，agent 一律不自行执行；交付前把**确切命令**与验收要点写清楚即可。
  只读/轻量验证（测试、lint、语法检查、协议探针）agent 应当自己跑。
- **版本号约定（`major.minor.patch`，见下方 Versioning）** — 推进版本时同步更新 `pubspec.yaml` 的
  `version` 字段、`settings_screen.dart` 中显示的版本号、扩展 `manifest.json` 的 `version`
  与 `installer/easypass_setup.iss` 的 `MyAppVersion` / `VersionInfoVersion`
  （`browser_extension/tools/check_extension.mjs` 会校验这四处一致）。README 徽章与发布说明也
  一并更新。
- **打包安装包** — `& "C:\Program Files\Inno Setup 7\ISCC.exe" installer\easypass_setup.iss`
  （用户执行；产物在 `build\installer\EasypassSetup.exe`）。安装包需要 app-local 的
  MSVC 运行时（`msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll`），而 Flutter 生成的
  runner **不会**把它拷进 `build\windows\x64\runner\Release`（`windows/CMakeLists.txt` 的 `install()`
  只带 app/ICU/插件 DLL/字体/资源）：`installer/copy_vc_runtime.bat` 负责拷贝，并由
  `windows/runner/CMakeLists.txt` 的 POST_BUILD 调用（**该文件入库受版本控制，别把这段 hook 删了**）；
  `.iss` 里还有一层系统目录兜底，缺文件时不会中止编译。
- **打包 .deb** — `installer/deb/build_deb.sh [bundle 目录] [输出 .deb]`
  （用户执行；bundle 来自 `flutter build linux --release` + `tool/build_core.sh`，脚本从
  `pubspec.yaml` 读版本号）。安装到 `/opt/easypass`，`/usr/bin/easypass` 指向它，
  `easypass-core` / `easypass-native-host` 是设置 `LD_LIBRARY_PATH` 的包装器
  （核心按裸名 dlopen `libsqlite3.so`，bundle 自带而系统没有 `-dev` 包时不加这个就崩）。
  一键流程：`tool/build_release_linux.sh`（pub get → analyze → test → build → core → deb）。

- Regenerating code: after editing `lib/data/database/tables.drift`, you **must**
  rerun build_runner — `AppDatabase` and companions in `database.g.dart` are generated.
- Tests live in `test/`. **3.0.0 起 UI 测试注入假的 `VaultApi`**（`test/fake_vault_api.dart`），
  不再构造内存 drift 库；跑在核心侧的数据层测试仍用 `AppDatabase.forTesting()` +
  `FakeSecureStorage`（`test/fakes.dart`），轮换/加密的真实路径由
  `test/core_actions_harness.dart` 驱动 `CoreActions`。
- Linux-only test files (`browser_host_installer_test.dart`, `linux_window_controller_test.dart`,
  the POSIX-exec-bit cases in `desktop_integration_test.dart`) detect the platform and
  **register no cases on Windows** (or `skip:` themselves), so a Windows run reports fewer
  cases, not failures.
- **`test/architecture_boundary_test.dart` 是架构守卫**：`lib/features/**` 不得 import
  drift / database / repositories / session key；`lib/client/**` 不得碰数据库；
  `lib/core_service/**` 不得 import Flutter。加了新目录要同步这些规则。

## Architecture

```
bin/easypass_core.dart         核心服务入口（--serve/--bridge/--lock/--shutdown/--status/--version）
                               **不得 import Flutter**：`dart build cli` 出的 AOT 控制台程序
lib/main.dart                  UI 入口：ProviderScope + portrait lock；CLI dispatch
                               (--install/--uninstall/--desktop-status, --install-browser-host/…)
                               —— 3.0.0 起 **没有** --service / --native-host 模式
lib/app.dart                   MaterialApp.router; go_router routes + auth redirect + 活动上报
lib/client/                    UI 的唯一数据通道（3.0.0 新增）
│   ├── vault_api.dart         VaultApi 抽象（UI 只依赖它；测试注入假实现）
│   ├── core_session.dart      CoreSession：发现/拉起核心、握手、自动重连、事件转发
│   └── api_providers.dart     vaultApiProvider / coreSessionProvider / coreChangesProvider
lib/protocol/                  协议 5 的线格式（核心与客户端共用，纯 Dart）
│   ├── frames.dart            4 字节长度前缀 + JSON 的唯一编解码实现
│   ├── secure_channel.dart    nonce/HMAC 互相证明 + AES-CBC/HMAC 帧加密（通道加密）
│   ├── actions.dart           动作名常量 + ui/bridge 白名单
│   ├── events.dart            推送事件与主题（changed / sessionLocked / …）
│   ├── codecs.dart            bridge JSON（冻结）与 UI JSON（完整明文）+ WireFolder
│   └── errors.dart            错误码（error 仍是字符串，errorCode 是结构化补充）
lib/core_service/              核心服务实现（纯 Dart，**不得 import Flutter**，有测试守着）
│   ├── core_service.dart      组装 + 监听 + 分发 + 事件广播 + shutdown
│   ├── core_actions.dart      UI 域动作（会话/条目/文件夹/导出导入/迁移）
│   ├── session_domains.dart   ui / bridge 两个会话域与锁定传播规则
│   ├── core_singleton.dart    固定端口单实例闸门
│   ├── core_info.dart         daemon.json 读写与清理
│   ├── core_client.dart       客户端连接 + 握手 + --shutdown 实现
│   ├── bridge_forwarder.dart  --bridge：stdio ↔ 回环 TCP（Linux 宿主）
│   ├── native_messaging_service.dart  bridge 域动作（协议 3 起形状冻结）
│   ├── vault_session.dart     会话（密钥 + 空闲过期）
│   └── url_matcher.dart       URL↔条目匹配
├── core/
│   ├── constants/app_constants.dart    PBKDF2/AES 参数、钥匙串键名、bridgeProtocolVersion、
│   │                                   coreVersion、coreFixedPort
│   ├── crypto/
│   │   ├── crypto_service.dart         Manual PBKDF2, AES-256-CBC (IV||cipher, base64)
│   │   ├── totp_service.dart           RFC 6238 TOTP (SHA-1, base32 secret, 30s/6-digit)
│   │   └── ssh_key_service.dart        OpenSSH public-key parsing + SHA256/MD5 fingerprints (pure)
│   ├── storage/                        SecretStore 抽象 + VaultMetaSecretStore（库内校验材料）
│   └── platform/app_paths.dart         Data dir + file paths per platform (XDG on Linux, exe dir on
│                                       Windows; 核心在子目录时取父目录), 0700/0600, legacy-DB migration
lib/adapters/flutter_secret_store.dart  唯一允许 import flutter_secure_storage 的"保险库路径"
├── data/
│   ├── database/
│   │   ├── tables.drift                Schema: folders, password_entries, vault_meta (schemaVersion 3)
│   │   ├── database.dart               AppDatabase: DAO queries + streams + migrations
│   │   └── database.g.dart             GENERATED — do not edit
│   ├── models/                         Entry types + payload models (2.3.0)
│   │   ├── entry_type.dart             EntryType enum (login/secure_note/identity/ssh_key) + wire names
│   │   ├── entry_fields.dart           LoginData / IdentityData / SshKeyData / CustomField / EntryPayload
│   │   ├── vault_item.dart             VaultItem: the single decrypted domain model used by core/UI/export
│   │   └── vault_item_mapper.dart      VaultItem ↔ DB row: the ONLY place that encrypts/decrypts entry fields
│   ├── repositories/vault_repository.dart  Item API (getItems/saveItem/searchItems/reencryptAll)
│   └── services/                       export_import_service.dart (JSON + encrypted export/import),
│                                       bitwarden_importer.dart (Bitwarden JSON/CSV import),
│                                       master_password_rotation.dart (atomic rotation journal)
└── features/                           UI only（不得直接碰 DB/仓储/密钥，见 test/architecture_boundary_test.dart）
    ├── auth/     auth_provider.dart (AuthState/AuthNotifier，全部经 VaultApi), lock/set-master-password screens
    ├── vault/    providers/{vault_provider,entry_item_provider,core_stream}.dart（快照 + 主题重取）,
    │             vault CRUD screens, widgets/{entry_card,entry_type_bits,custom_fields_editor,…}.dart
    ├── generator/ generator_provider.dart, generator_screen.dart
    ├── health/   health_service.dart（纯函数 + HealthReport.fromJson；核心也在用同一套 analyze）
    │             health_provider.dart（走核心的 healthReport 动作，密码不过 IPC）
    ├── settings/ settings_screen.dart（导出/导入/清库全走 VaultApi）, providers/{font_settings,theme}_provider.dart
    ├── browser_bridge/  browser_host_installer.dart (per-browser native-messaging manifests),
    │                    browser_host_prompt.dart (first-run registration prompt)
    ├── desktop_integration/  desktop_integration.dart (facade) + linux_desktop_integration.dart
    │                         (desktop entry / icon / --desktop-status), windows_desktop_integration.dart
    ├── desktop_tray/    desktop_tray.dart (facade) + linux_desktop_tray.dart, windows_desktop_tray.dart,
    │                    linux_window_controller.dart (MethodChannel `com.easypass.app/window`)
    ├── desktop_autostart/  desktop_autostart.dart + linux_autostart.dart (XDG), windows_autostart.dart
    └── desktop_single_instance/  desktop_single_instance.dart + linux_single_instance.dart
                                  (easypass.lock + unix socket)；Windows 的单实例在原生层
                                  （windows/runner/main.cpp 的 Mutex + FindWindow 抬窗），
                                  Dart 侧 windows_single_instance.dart 保持 notApplicable 桩
tool/build_core.ps1 / .sh                核心服务构建（dart build cli + 摊平产物）
tool/probe_core.dart                     核心功能探针（19 项；只跑空库）
browser_extension/                      Chrome MV3 extension (see below)
docs/data-model.md                      数据模型与持久化规范 (LOCAL ONLY — gitignored)
docs/acceptance-3.0.0.md                3.0.0 真机验收清单 (LOCAL ONLY — gitignored)
windows/                                Flutter Windows runner (CMake) + the tray/single-instance glue
linux/                                  Flutter Linux runner (CMake): my_application.cc (window + method
                                        channel), easypass_tray.cc (libayatana-appindicator + a
                                        StatusNotifierWatcher host probe; 三项菜单)
```

**Data flow (3.0.0 — 核心服务架构):** 保险库只有一个所有者：**核心服务进程**
（`easypass_core`）。UI 是纯客户端，自己不开库、不持密钥。

```
浏览器扩展 ─ native messaging ─▶ 桥(x86) ─┐
                                            │ 回环 TCP，协议 5：加密 + 双向证明
                                            ▼
                                      easypass_core  ──▶ VaultRepository ──▶ VaultItemMapper
  Flutter UI ── VaultApi(lib/client) ────────┘                │              （唯一加解密口）
  （托盘 / 窗口 / 两档退出）                                            ▼
                                                              加密 SQLite（easypass.db）
```

- 会话域：`ui` 与 `bridge` 各自一份密钥副本与空闲计时器。**UI 锁定会同时锁
  bridge 域；UI 解锁不会解锁扩展，扩展解锁也不影响 UI**（刻意如此）。
- 空闲自动锁定在**核心**（`SessionDomains`），UI 只上报活动（`touchActivity`，
  节流 20s）并订阅 `sessionLocked/sessionUnlocked` 事件。
- 明文边界：核心把**明文 `VaultItem`** 发给 UI（`ui` 域动作）；扩展拿到的是
  受限 JSON（`hasTotp`、无 TOTP 种子）。导出/导入由**核心读写文件**，UI 只传路径。
  **唯一例外已经收掉**：健康报告由核心算（`healthReport` 动作），UI 只收统计数字
  （条数 / 分数 / 问题条目的 id+名字），**密码与种子不再经过 IPC**。
  `test/health_test.dart` 与 `test/health_screen_test.dart` 用
  `expect(api.called('listItems'), isFalse)` 盯着这条回归。
- **通道加密（协议 5）**：`lib/protocol/secure_channel.dart`。握手用
  「nonce + 双向 HMAC 证明」，**令牌永不上线**；握手末帧起所有帧用
  AES-256-CBC + HMAC-SHA256（encrypt-then-MAC，四把方向密钥）加密。
  **`role: ui` / `agent` 只能走加密握手**，传 v4 明文形状一律 `unsupported`；
  唯一例外是 Windows 的 x86 C++ 桥（`role` 缺省 = bridge），它是 32 位 stdio
  限制下的字节转发器，与核心之间仍是回环 + 令牌认证 —— 这是**已知的、
  有意的**信任边界，不是遗漏。
  边界要说清楚：加密保证"链路上没有明文"，挡得住没有令牌的进程与被动的
  抓包者；**挡不住同用户的恶意进程**（它能读 `daemon.json`，而 UI 本来就要
  显示明文密码）。真正的边界是"同一用户账户"。

**Entry types (2.3.x):** one row can be `login`, `secure_note`, `identity` or
`ssh_key`. Login fields stay in the legacy columns (`url`, `username`,
`password_encrypted`, `totp_secret_encrypted`) so old data needs no rewrite; the
type-specific blocks for identity/SSH **and the custom fields of every type** are
serialised as `EntryPayload` JSON and stored encrypted in `data_encrypted`.

**Browser bridge flow:** content-script/popup → `chrome.runtime` message →
`background.js` service worker → native messaging (4-byte length prefix + JSON,
host id `com.easypass.app`) → bridge → **loopback TCP + token handshake to the
core** → `NativeMessagingService`（动作形状与 2.x 冻结不变）→ repository。
Actions: `getStatus`, `unlock`, `lock`, `getCredentials`, `getAllCredentials`,
`searchCredentials`, `generatePassword`, `getTotp`, `getHealthReport`. Response
always echoes `requestId`; errors come back in an `error` **string** field.
Since protocol 3 the entry JSON carries `type` + per-type blocks; `hasTotp`
replaces the TOTP secret, and `getCredentials` returns **login entries only**.
**Windows** 用独立的 32 位桥 `easypass_native_host.exe`（32 位浏览器的 stdio
句柄问题，Dart AOT 出不了 ia32）；**Linux** 由 wrapper `exec easypass_core
--bridge`，宿主就是核心二进制的转发模式。

**Desktop lifecycle (both platforms):** 核心是**独立、常驻、无窗口无托盘**的
进程，唯一性由固定回环端口（`AppConstants.coreFixedPort`）保证；**没有空闲自
退** —— 只有 `shutdownCore` 动作 / `--shutdown` 才退出。UI 启动时按需拉起核心，
从不开库。托盘**只属于 UI**，菜单三项：`Open EasyPass` / `Exit UI Only` /
`Exit UI and Stop Service`；关窗只隐藏到托盘（且仅在托盘图标真的注册成功时）。
核心 exe 位于 `{app}\core\easypass_core.exe`（原生资产按 `<exe>\..\lib` 解析，
所以库在 `{app}\lib`；数据目录仍取父目录 —— 见 `app_paths.dart` 的判据）。
**UI 单实例**：Linux 二次启动取 `easypass.lock` 并经 unix socket 唤醒已有实例；
Windows 由 `windows/runner/main.cpp` 的闸门负责（`Local\EasyPass.UI` Mutex →
`FindWindowW` → `SW_RESTORE` + `SetForegroundWindow`，然后退出；带 `--` 开关的 CLI
跳过闸门）。**核心自己的唯一性另算**（固定端口 47820），两者互不依赖。

**Routing / auth gating** is centralized in `lib/app.dart` (`_routerProvider`
redirect): `/lock`, `/set-master-password`, `/vault`, `/vault/add`,
`/vault/edit/:id`, `/vault/entry/:id`, `/generator`, `/settings`.

## Key Files & Directories

- **`lib/core/constants/app_constants.dart`** — crypto parameters (PBKDF2
  iterations=100000, key 32B, salt 32B, IV 16B), secure-storage key names and
  `bridgeProtocolVersion`. Changing these breaks stored data or the extension.
- **`lib/core/platform/app_paths.dart`** — every platform-dependent path in one
  place (XDG dirs, exe dir, daemon.json, native-host wrapper, autostart/desktop
  entry, migration temporaries). `dataDirectory` 有一个**父目录判据**：非 Linux 上
  若 exe 的父目录里存在 `easypass[.exe]`，数据目录取父目录 —— 这样核心被放在
  `{app}\core\` 时保险库坐标仍是 `{app}`，不需要迁移数据。
- **`lib/protocol/**`** — 协议 5 的线格式。**帧编解码只有一份实现**
  （`frames.dart` 的 `NativeMessageReader` / `encodeMessage` / `encodePayload`），
  核心、桥、探针、测试共用；`secure_channel.dart` 是**通道加密**的唯一实现
  （握手证明 + 四把方向密钥 + encrypt-then-MAC）。`actions.dart` 是动作名的单一来源。
- **`lib/core_service/native_messaging_service.dart`** — bridge 域动作的实现
  （`getCredentials` 等 9 个，协议 3 起形状冻结）；UI 域动作在
  `core_actions.dart`，两者共用同一个仓储与会话密钥口径。
- **`lib/core/storage/secret_store.dart`** — 密钥材料存储抽象。核心注册
  `VaultMetaSecretStore`（写库内 `vault_meta`），UI 注册 `FlutterSecretStore`
  （只在迁移期读旧钥匙串）。未注册时任何存储操作都会**明确抛错**，不会静默退化。
- **`lib/data/database/tables.drift`** — the schema (folders, password_entries).
  Sensitive columns are `*_encrypted` TEXT; plaintext never touches the DB.
- **`lib/features/browser_bridge/browser_host_installer.dart`** — Linux 的宿主
  注册（生成 wrapper + 各浏览器 manifest）。wrapper 现在 `exec easypass_core
  --bridge`。
- **`browser_extension/manifest.json`** — MV3 manifest; `nativeMessaging` permission.
- **`browser_extension/native_host/com.easypass.app.json`** — host registration
  pointing at `easypass_native_host.exe`; the installer rewrites the equivalent
  manifest under `%LOCALAPPDATA%\EasyPass\` to point at the install directory.
- **`windows/`** — the Windows runner (tracked source, not disposable output);
  binary name `easypass`, plus `check_syntax.bat` and `check_integrity.bat`.
- **`linux/runner/`** — the GTK runner: `my_application.cc` (window, min size,
  `com.easypass.app/window` method channel), `easypass_tray.cc` (AppIndicator +
  StatusNotifier host probe).
- **`installer/deb/build_deb.sh`** — Debian package layout (`/opt/easypass`, desktop
  entry, icons, native-messaging manifests; version from `pubspec.yaml`).
- **`tool/build_release_linux.sh`** — one-shot Linux release (analyze/test/build/core/deb).
- **`Plan.md`** — roadmap (Chinese, **local-only**; not in a fresh clone).
- **`README.md`** / **`README_zh.md`** — product READMEs (features, security model, build, extension status).

## Coding Conventions

- **State management:** Riverpod, hand-written providers (`StateNotifierProvider`,
  `StreamProvider`, `StreamProvider`/`FutureProvider.family`, `StateProvider`).
  **No `@riverpod` codegen** — match the existing hand-written style. (2.3.0 removed the
  unused `riverpod_generator` / `riverpod_lint` / `custom_lint` dev-dependencies: they
  produced nothing here, and `custom_lint ^0.7` pinned `analyzer ^7`, which is what broke
  drift code generation on the current Dart SDK. Re-adding them means upgrading the whole
  riverpod family and re-checking codegen — see the comments in `pubspec.yaml`.)
- **Layering (3.0.0):** `core` = pure logic (no widgets), `data` = persistence,
  `protocol` = 线格式, `core_service` = 核心进程（不得 import Flutter）,
  `client` = UI 的数据通道, `features` = UI。**UI 不得直接 import drift /
  database / repositories / session key** —— 由 `test/architecture_boundary_test.dart`
  强制（它同时守着"核心不得 import Flutter"）。
- **Naming:** feature folders contain `screens/`, `providers/`, `widgets/`;
  providers are named `*Provider`; DB companions use Drift naming.
- **Encryption discipline:** passwords/notes/TOTP secrets are always encrypted
  via `CryptoService` before persistence; the key comes from the session
  (`SessionDomains` in the core — **UI never holds it**); never log or print secrets.
- **Comments:** mixed Chinese/English comments throughout — **except
  `windows/runner/**`, which must stay pure ASCII** (see Build/Test/Lint).
- **Formatting:** do **not** run `dart format` on this repo. It predates Dart 3.13's
  new formatter, so it rewrites files that were never touched and buries real changes.
  `flutter analyze` is the gate.
- **Localization:** all UI strings live in `lib/l10n/app_en.arb` (source) and
  `app_zh.arb` (Chinese); reference them via `AppLocalizations.of(context)`.
  After adding a key to an ARB file, run `flutter gen-l10n`. The UI follows the
  system locale by default with a manual override in Settings (`localeProvider`
  in `lib/app.dart`).
- **Errors:** services return `bool` + set `errorMessage` on state (auth) or throw
  exceptions caught by callers (native messaging returns `error` field).
- **Auth errors** are error codes (`AuthErrorCodes` in `auth_provider.dart`);
  map them to localized text with `authErrorMessage(l10n, code)`.
- **Auth provider** adds `changeMasterPassword()` (verifies the current password
  through the core, which re-encrypts all entries with a fresh key and then locks)
  and `setAutoLockMinutes()` (persisted by the core); `AuthState.autoLockMinutes`
  drives the settings UI. 全部经 `VaultApi`，UI 不自己校验、不自己定时。
  `VaultApi.changeMasterPassword` 返回 **`ChangePasswordResult`**
  （`keyMaterialPersisted` + `reencrypted`）：写入失败时界面会显示
  `masterPasswordChangedStorageWarning` —— 这个字段一旦被丢掉，那条提示就又变成死代码。
- **Export/import** distinguishes `format: 'encrypted'` backups (restorable) from
  plain JSON; plain imports are re-encrypted with the session key on import.
- **Platform split:** `features/desktop_*/` and `core/platform/` hold the platform
  differences; Dart-side `Platform.isLinux` / `Platform.isWindows` checks belong
  inside those files, never scattered through the UI. New platform behaviour needs
  a test that either fakes the platform or skips cleanly on the other OS.

## Versioning

Semantic versioning `x.y.z`, applied to `pubspec.yaml`'s `version` field and the
in-app version shown on the Settings screen:

- **`x` (major)** — 大版本号。只在发生重大底层架构更新（例如重写加密层、
  数据库迁移、安全模型变更）时推进。
- **`y` (minor)** — 中版本号。有功能变更（新增/移除功能）时推进。
- **`z` (patch)** — 小版本号。一般用于软件优化：bug 修复、性能优化、
  UI 打磨等不改变功能的行为调整。

Rule of thumb: 功能变更 → `y`，纯优化/修复 → `z`，架构/安全模型重构 → `x`。
新增平台（如 2.3.3 的 Linux 桌面端）按"功能变更"走 `y`。

## Git Workflow

- Branch: `master`; commits are few and direct-to-master (no PR workflow yet).
- Commit messages are **Chinese**, `type: description` style (e.g. `add:添加了浏览器扩展的图标`, `init`).
- `.gitignore` ignores the whole `build/` output tree; `windows/flutter/ephemeral/` is
  ignored by `windows/.gitignore`. **The rest of `windows/` IS tracked** (runner sources,
  CMake files, icon) — treat it as normal source, not as disposable generated output.
  `linux/flutter/generated_*` **is** tracked: keep it committed, but restore it with
  `git checkout --` after a Windows-side `flutter` run (CRLF rewrite).

## CI/CD

CI exists as of v2.4.0. `.github/workflows/ci.yml` runs on every push and pull
request; `.github/workflows/release.yml` runs on tags matching `v*` to build the
installer and the Linux `.deb` and publish them with `SHA256SUMS.txt`. Triggers and the
Flutter version pinning decision are documented in `.github/workflows/README.md`.

The same gates are still run by hand by the agent before handing a build to the user
(a green CI run does not cover a local change that has not been pushed):
`flutter analyze --no-pub`, `flutter test --no-pub`,
`node browser_extension/tools/check_extension.mjs` (+ the three jsdom smoke
scripts), `node browser_extension/tools/build_extension_zip.mjs --dry-run` when the
extension package is due, `cmd /c windows\runner\check_syntax.bat` and
`cmd /c windows\runner\check_integrity.bat`.

Release artifacts and their checksums are **generated, not recalled by hand**:
`node installer/release/collect_artifacts.mjs` writes `SHA256SUMS.txt` +
`release-manifest.json` and copies the artifacts into `dist/release/<version>/`
(so the whole directory can be uploaded); `node installer/release/generate_release_notes.mjs`
fills the artifact table in `docs/release-<version>.md` while preserving hand-written
prose. The version comes from `pubspec.yaml` only. Runbook: `installer/release/README.md`.

## Tips for AI Agents

- **After any `tables.drift` change:** run `dart run build_runner build --delete-conflicting-outputs` or the app will fail to compile against stale `database.g.dart`.
  Codegen needs an `analyzer` that understands the installed Dart SDK: with a too-old
  analyzer, `drift_dev` dies with `Missing implementation of visitDotShorthandPropertyAccess`
  and **writes nothing** (while `--delete-conflicting-outputs` has already deleted the old
  file, leaving the repo uncompilable). If that happens, bump `drift`/`drift_dev`/
  `build_runner` together (see `pubspec.yaml`) before touching the schema.
- **Schema changes need a migration, not just a column.** `schemaVersion` is **3** and
  `AppDatabase.migration.onUpgrade` implements 1→2 and 2→3 for real; every new column/table
  must be added there too, or existing installs fail to open with "no such column" / "no such
  table". `test/migration_test.dart` hand-builds v1 and v2 databases and asserts both upgrade
  paths — extend it whenever you add a column or a table.
  Also: drift does **not** enable SQLite foreign keys, so `ON DELETE SET NULL` never fires —
  `deleteFolderAndUnassign()` clears `folder_id` explicitly.
- **Master-password rotation is atomic via a journal, and that is load-bearing.** The target
  salt + verifier live in `vault_meta` and are written in the **same transaction** as the
  whole-vault re-encryption (`MasterPasswordRotation`). The invariant is "no journal ⇒ the
  vault is on the old key; journal present ⇒ the vault is on the new key", so the journal's
  existence is the authority on which password is valid. Do not go back to "re-encrypt, then
  write the key material": that ordering is what could leave neither password able to open
  the vault. Regression net: `test/master_password_rotation_atomicity_test.dart` and
  `test/change_password_then_lock_test.dart`.
- **Password verification has exactly ONE implementation: `MasterPasswordVerifier`.**
  It used to exist three times and only one copy knew about the rotation journal — which is
  how "the old master password still works after changing it" shipped in 2.4.0. 3.0.0 起它
  **只跑在核心里**（`CoreActions._unlock` / `_changeMasterPassword` / `verifyMasterPassword`
  都走它）；UI 通过 `verifyMasterPassword` 动作二次校验，**任何地方都不许自己比对
  salt/hash**。判据仍是"日志存在 ⇒ 只有日志里的目标密码有效"。
- **Changing the master password leaves the vault LOCKED**（核心 `lockAll()` + UI 置
  `AuthStatus.locked`；路由回 `/lock`）。That is deliberate: it forces the user to prove
  the new password works, and it re-authenticates after a security-sensitive key change.
  Do not "helpfully" restore the old auto-unlocked state — that is exactly the state in
  which a broken rotation stays invisible.
- **SQLite 只由核心打开。** 3.0.0 起 UI 进程**没有**数据库句柄；测试若要真库，用
  `AppDatabase.forTesting()` + `NativeDatabase.memory()` 并注册
  `InMemorySecretStore`（`lib/core/storage/secret_store.dart`）。实机排查"库里到底有什么"
  请用 `easypass_core --status`，不要从 UI 进程去读文件。
- **`pubspec.yaml`'s sqlite3 hook must stay Linux-scoped.** It reads
  `hooks: user_defines: sqlite3: source: {linux: system}` — the `linux:` key, with **no
  `default:`**. Removing the hook or adding a default makes the Windows build download
  package binaries instead of using `sqlite3_flutter_libs`, and `flutter test` then fails
  with `Failed to load dynamic library 'sqlite3.dll'` (206 tests at once).
- **The native host exe IS built by the Windows build.** `windows/runner/CMakeLists.txt`
  (tracked in git) has a POST_BUILD step that runs `browser_extension/native_host/build_bridge.bat`
  (cl.exe, x86, no MSBuild) next to `easypass.exe`; a second POST_BUILD step copies the MSVC
  runtime DLLs via `installer/copy_vc_runtime.bat`. Keep both hooks when touching that file.
  The bridge protocol contract is the single source of truth on both sides —
  keep `background.js` actions in sync with `handleRequest`'s switch.
- **Auth state is async** — `app.dart` redirects on `isLoading` by returning
  `null`; don't assume `authProvider` is resolved when a screen builds.
- **Portrait-locked** in `main.dart`; Windows desktop still respects it via
  `SystemChrome` (harmless, but relevant if adding responsive layouts).
- **Secrets in code:** never print encryption keys/passwords; follow the
  existing pattern of passing `Uint8List` keys around by reference only.
- **Linux debugging hooks (2.3.3):** `EASYPASS_DEBUG_NO_TRAY=1` forces the
  "no StatusNotifier host" path and `EASYPASS_DEBUG_AUTO_CLOSE_MS=<ms>` closes the
  window by itself, so the degrade-on-close behaviour can be checked without a
  desktop session that lacks a tray. The CLI surface for scripted checks is
  `--install`, `--uninstall`, `--desktop-status`, `--install-browser-host`,
  `--uninstall-browser-host`, `--browser-host-status`.
- **Plan.md** (local-only) holds the roadmap: v2.4 = master-password rotation atomicity + Bitwarden
  import + CI + release engineering；**v3.0 = 核心服务化（本版已实现）**；再往后才是
  自部署同步 / 密钥体系改造（orgKey 分层）。Sync is **not** implemented, and the
  health report is (login entries only). 2.3.3 has shipped and passed the Linux hardware
  acceptance run.
- **Protocol versioning (2.2.1+):** 核心把 `protocolVersion` + `pid` + `coreVersion` + `exe`
  写进 `daemon.json`，`getStatus` 也回 `protocolVersion`。
  `AppConstants.bridgeProtocolVersion` (`lib/core/constants/app_constants.dart`) and
  `EXPECTED_PROTOCOL_VERSION` (`browser_extension/background.js`) **must be bumped
  together** whenever the protocol changes incompatibly. **协议 5 = 3.0.0**：握手带
  `role` 且**全程加密**（令牌不上线），核心推送 `changed` / `sessionLocked` 等事件；
  v5 核心拒绝 v4 及更旧的客户端（明文握手只留给 x86 桥的 bridge 角色）。
- **`easypass_core --lock`**：连上运行中的核心并锁定保险库，**不停核心**；
  没有核心在跑时退 0（无事可做）。托盘"仅退出 UI"就是先跑它再退 UI ——
  `windows/runner/flutter_window.cpp` 的 **`LockVault()`**（关窗隐藏与"仅退出 UI"共用）/
  `linux/runner/easypass_tray.cc` 的 `lock_vault_before_exit()`，锁定失败只提示、
  仍然退出（不能把用户困在界面里）。
  **关窗 = 立即锁定**（`WM_CLOSE` 先 `--lock` 再 `MinimizeToTray`）：用户实测报告过
  "关窗后保险库没上锁、重开还是解锁态"，这不是 bug 而是当时压根没做 —— 只有核心的
  空闲计时器（默认 5 分钟）会锁。注意 `--lock` 派发到 `Actions.lock`，而核心的
  `lockAll()` 会**连 bridge 域一起锁**，所以关窗后浏览器扩展也需要重新解锁；若以后
  希望扩展不受影响，需要一个"只锁 ui 域"的动作，别直接改 `lock` 的语义。
- **Debug tools (no browser needed):** `node browser_extension/tools/probe_bridge.mjs`
  （端到端：拉起桥，桥再去找/拉起核心）、`probe_daemon.mjs`（直连已在跑的核心），
  以及 `dart run tool\probe_core.dart --core <path>`（19 项核心动作面，只跑空库）。
  三者配合能判断问题在扩展、桥还是核心。jsdom smoke + `check_extension.mjs` 是扩展
  改动的回归网。
- **Store upload package:** `node browser_extension/tools/build_extension_zip.mjs`
  (`--dry-run` validates and lists what would ship; without it writes
  `dist/easypass-extension-<version>.zip`). It packs a **whitelist** (manifest,
  background/content scripts, `popup/`, `icons/`, `_locales/` — never `tools/` or
  `native_host/`), is dependency-free and reproducible, and fails the build unless the
  extension ID derived from `manifest.key` matches the Dart constant, the `.iss` and
  `native_host/com.easypass.app.json`.

## Linux .deb packaging (3.0.0)

- **The core is a plain AOT image with no rpath.** `dart build cli` does not let us
  set one, and `patchelf --set-rpath` **corrupts the image** (afterwards it behaves
  like the plain Dart VM: `--version` prints the SDK version, `--serve` prints
  `dartvm` usage). Never patch it. Instead the library directory is supplied at
  runtime: `launchCoreIfPresent()` prepends `<core>/../lib` to `LD_LIBRARY_PATH`
  when it spawns the core, and `/usr/bin/easypass-core` does the same for CLI use.
- **Your dev machine needs `libsqlite3-dev`, end users must not.** Ubuntu installs
  only `libsqlite3.so.0`; the hook asks for the bare `libsqlite3.so`. The bundle
  ships its own copy next to the app, so the deb works without the `-dev` package —
  but `dart run tool/probe_core.dart` runs in *your* shell and needs the system
  symlink. `sudo apt-get install -y libsqlite3-dev` is a dev-only requirement.
- **Run `flutter test` with `XDG_CONFIG_HOME`/`XDG_DATA_HOME` unset.** Several
  `browser_host_installer_test.dart` cases build a temp `$HOME` and assert the vendor
  roots/manifests land there; `install()` falls back to the *environment's*
  `XDG_CONFIG_HOME`, so an exported value makes them write into your real `~/.config`
  and 9 cases fail. `env -u XDG_CONFIG_HOME -u XDG_DATA_HOME flutter test --no-pub` is
  the honest gate (CI runners do not export those).
- **Linux has no CMake hook for the core.** `flutter build linux` wipes the bundle,
  so `tool/build_core.sh --out-dir <bundle>` must run *after* it — that is exactly
  what `tool/build_release_linux.sh` and CI do. Do not "fix" this by adding a
  POST_BUILD hook that runs `dart build cli` under CMake; the tool invocation needs
  the Flutter SDK's Dart, not CMake's environment.

## Pitfalls we already paid for

Each of these cost real debugging time — do not re-introduce them. The Chinese long-form
version lives in the local `HANDOFF.md` (section 4, "踩过的坑").

- **The extension's permission set is deliberately minimal: `clipboardWrite` +
  `nativeMessaging` + host `<all_urls>`.** `storage`, `scripting` and `activeTab` were
  removed before store submission because no code path uses them (there is no
  `chrome.storage` call anywhere — the unlocked session lives in the desktop app — and the
  declarative content script needs neither `activeTab` nor `scripting`). Re-adding an unused
  permission is what makes store reviewers ask questions, and `build_extension_zip.mjs`
  warns about it; if a change really needs one, add it *and* update the permission
  justifications in `docs/store-listing.md`.
- **The extension ID is a four-way contract.** `manifest.json`'s `key` fixes the ID
  (`hlkbbdlgaocmnjlgpafkimobnkfniike`), and it must match `BrowserHostInstaller.extensionId`,
  `installer/easypass_setup.iss` and `native_host/com.easypass.app.json` — that ID is the
  native-messaging allowlist, so changing it silently disconnects every existing install.
  The packaging script enforces this; after publishing to a store, verify the ID the store
  actually assigned (Edge especially) and extend the allowlist via
  `EASYPASS_BROWSER_HOST_EXTENSION_ID` instead of editing the old one away.
- **`flutter build windows` fails with `MSB3073` when an EasyPass instance is still
  running from `build\windows\x64\runner\Release`.** The POST_BUILD steps
  (`browser_extension/native_host/build_bridge.bat` and `installer/copy_vc_runtime.bat`)
  write into that same directory, and `copy_vc_runtime.bat` uses `copy /y` — which is
  **unconditional**, so it fails even when the file contents are unchanged. A running
  `easypass.exe` keeps `MSVCP140.dll` / `VCRUNTIME140.dll` / `VCRUNTIME140_1.dll` mapped
  and therefore locked ("The process cannot access the file because it is being used by
  another process"), `copy` returns 1, and MSBuild aborts the whole build. **3.0.0 起还有
  第二个进程会锁文件**：`core\easypass_core.exe`（常驻核心）以及它的
  `lib\sqlite3.dll`。
  **Before building, stop them:** `Get-Process easypass,easypass_core -ErrorAction
  SilentlyContinue | Stop-Process -Force`（或先跑 `core\easypass_core.exe --shutdown`），
  再删掉陈旧的 `%LOCALAPPDATA%\EasyPass\daemon.json`。MSBuild's `MSB3073`
  output does **not** include the script's own message, so run the two `.bat` files by
  hand with the output dir as the argument to see the real error.
- **A Low mandatory integrity label on the workspace breaks the app in ways that look like
  code bugs.** Windows gives a process the integrity level of its image's mandatory label;
  a process started from a Low-labelled exe runs at **Low integrity**, and a Low process
  cannot register a tray icon (`Shell_NotifyIcon` fails silently) and cannot write to
  Medium locations (`%TEMP%`, `%LOCALAPPDATA%`, `%APPDATA%`). Symptom set seen on
  2026-09-27: no tray icon from `build\`, `daemon.json` never updated, settings that did not
  stick, a SmartScreen prompt — with the vault itself perfectly fine (the DB sits in the
  same Low directory, so write-*down* succeeds). The label came from an agent sandbox in
  *workspace-write* mode (it labels the workspace Low on purpose, as its write-up
  protection). Detect and fix with `cmd /c windows\runner\check_integrity.bat` /
  `… /fix`; `check_syntax.bat` warns about it too. A Low **file** can survive inside an
  already-Medium directory, so check the exe, not just the folder.
- **`windows/runner/**` must stay pure ASCII.** `check_syntax.bat` does not pass `/utf-8`,
  so cl.exe decodes the sources with the system ANSI code page: a Chinese comment or a
  full-width character trips C4819, which `/WX` turns into a build failure (and can shift
  reported line numbers enough to look like a parse error).
- **The `sqlite3` hook in `pubspec.yaml` is scoped to Linux on purpose** (see the Tips
  section): unscope it and 206 Windows tests fail on `sqlite3.dll`.
- **Never trust a script's own success message when it changes permissions or ACLs.**
  While writing `check_integrity.bat`, two batch bugs made it print the `/fix` branch
  without `/fix` (parenthesised strings inside a multi-line `if (...)` block confuse cmd's
  parser, so the block was mis-scoped and `icacls` never ran) and report a false positive
  (`findstr /i "Low Mandatory"` is an **OR** match, so it matched every `Mandatory
  Label\Medium…` line — use `/c:"Low Mandatory"`). Always verify the resulting state with a
  separate `icacls` call.
- **A Windows-side `flutter` run rewrites the tracked `linux/flutter/generated_*` files with
  CRLF.** They show up as modified without anyone touching Linux; `git checkout --` them
  before reviewing or committing (the repo has `core.autocrlf=true` and no `.gitattributes`).
- **`Text` inside a `Row` needs `Expanded`/`Flexible`** — otherwise `overflow: ellipsis`
  never engages (the Text asks for its intrinsic width in unbounded space) and the row
  overflows: that was the narrow-window yellow/black stripes.
- **Never fake alignment with padding.** Both column headers share `_topBarHeight`, and a
  widget test asserts the two divider `dy` values are equal (mutation-tested). The same
  coupling applies to `_sidebarWidth` ↔ the native minimum window size.
- **Frame reads must share one stateful reader.** A single TCP chunk can carry several
  frames; a per-call buffer silently drops the rest (that made the extension freeze for
  30 seconds). Use `NativeMessageReader` for the handshake *and* the serve loop.
- **`getCredentials` returns an array** — treating it as a single object fails silently
  (the old in-field icon filled nothing while looking like it worked).
- **A frame without a login form must not answer `fillCredentials`** — the popup takes the
  first response, so an empty iframe answering `success:false` makes a successfully filled
  page look "restricted" (and the popup overwrites the clipboard).
- **In jsdom, `textContent` includes `hidden` subtrees**, so it cannot assert that
  something is invisible — walk the ancestor chain for the `hidden` attribute instead.
  jsdom also does no layout (`offsetParent` is always null, `getBoundingClientRect` always
  zero), so visibility APIs must be stubbed when testing the content script.
- **Verify numbers against the code before writing them into docs** — "auto-lock 1–60 min"
  was wrong (the UI offers 1/3/5/15/30/60), `^3.12.2` is the *Dart* SDK constraint rather
  than a Flutter version, and the test count in this file was stale for three releases.
- **When a CLI takes long text from PowerShell, put it in a file** — embedded double quotes
  break argument parsing (`git commit -F msg.txt`; the same bit `ov add-memory`).
- **`Select-Object -First N` closes the pipeline early**, so the upstream command can be
  reported as `exit 1` even when it succeeded — do not use it when the exit code matters.
- **Never hand-build `PasswordEntriesCompanion` for entry data.** Since 2.3.0 all entry
  reads/writes go through `VaultItem` + `VaultItemMapper`; writing the `*_encrypted` columns
  yourself is how you get a column that the master-password rotation (`reencryptAll`) and the
  export path silently miss. The legacy row-level `VaultRepository` methods are `@Deprecated`
  migration bridges only.
- **Two agents running `flutter test` in the same checkout collide** on
  `build\native_assets\windows\sqlite3.dll` ("Flutter failed to delete file … cannot access
  the file"). It is not a code failure — serialize test runs, or retry after the other run
  finishes. Same class of problem: `dart run build_runner` in two shells at once.
- **Read vault data through streams, never one-shot futures + manual `ref.invalidate`.**
  The 2.3.1 user-visible bugs (the folder picker offering only the first folder; the detail
  page still showing the old entry — and therefore no new custom field — after an edit) both
  came from `FutureProvider` caches that some write path forgot to invalidate.
  **3.0.0 的写法**：`lib/features/vault/providers/core_stream.dart` 的
  `coreSnapshotStream` = 取快照 + 订阅核心推送的主题重取；四个读 provider
  （`filteredVaultEntriesProvider` / `entryItemProvider` / `searchResultsProvider` /
  `foldersProvider`）全走它。**不要**在写操作后手动 `ref.invalidate`，也不要订阅
  `coreChangesProvider.stream`（Riverpod 2.6 已 deprecated，且 `AsyncValue` 会把
  连续相同的主题去重掉）—— 用 `VaultApi.changes`。
- **核心锁了自己，UI 必须跟着锁。** 空闲超时发生在核心里，会广播 `sessionLocked`；
  `CoreSession` 把它转成 `sessionEvents`，`authProvider` 订阅后置为 locked。
  任何"直接读 `authSnapshot` 而不订阅事件"的写法都会留下"界面可用、动作全报
  locked"的窗口。
- **用户活动要续期。** 核心只对"读写数据的动作" `touch()`；UI 靠 `app.dart` 的
  `_ActivityTouchHost` 节流上报 `touchActivity`。删掉它，用户停在生成器/设置页时
  会被自动锁定。
- **A dropdown whose choice can be rejected must be controlled.** `DropdownButtonFormField`
  holds its own state, so "pick a new value → confirm dialog → cancel" leaves the control
  showing the value the user just rejected while the form still has the old one.
  `EntryTypeSelector` therefore wraps a plain `DropdownButton(value: ...)` in an
  `InputDecorator`; the custom-fields type dropdown keeps the FormField (no cancel path) but
  keys each row by its row object so deleting a row cannot shift the next row's selection.
- **Form controls in a row must share the same decoration.** A bare dropdown (no label, no
  outline) next to two labelled `OutlineInputBorder` fields sits half a line higher and reads
  as "misaligned"; `test/custom_fields_editor_test.dart` asserts the top edges are within 4px.
- **Never leave a desktop feature behind a touch gesture only.** Folder delete/rename lived
  exclusively on `onLongPress`, so mouse users concluded "folders can only be added, never
  deleted" (2.3.2). Anything a desktop user must be able to do needs a *visible* affordance
  (a `more_vert` button) **and** the mouse-native gesture (`onSecondaryTap`); long-press stays
  as a third path, never the only one.
- **Destructive actions state their blast radius.** Deleting a non-empty folder now counts the
  entries first (`countItemsInFolder`) and switches both the message ("it still contains N
  entries — they will NOT be deleted") and the confirm label ("Delete folder, keep entries").
  Never let a destructive confirm read the same for "empty" and "has data".
- **A dialog that silently swallows a failure looks like a dead button.** The delete path wraps
  both the count and the delete in try/catch and reports the error in a SnackBar; without that,
  a failed write leaves the user staring at an unchanged list.
- **A window state that hides the only window needs a way back.** Close-to-tray used to hide
  the window unconditionally, even when the icon was never registered — the app then ran on
  with no visible UI and no tray entry (user report: "the process is still there but the app
  is gone"). Close-to-tray now requires a *successful* icon registration (and a
  `TaskbarCreated` re-add after an Explorer restart); on Linux the tray degrades to "close
  quits" when no StatusNotifier host is registered.
- **3.0.0：无 UI 形态绝不能有 UI 表面。** 2.4 的 `--service` 虽然窗口不可见，但它
  **照样注册了托盘图标**，托盘菜单的 "Open EasyPass" 能把那个空窗口 `ShowWindow` 出来
  （2026-10-17 用 `WM_COMMAND(1001)` 实测复现）。3.0.0 的修法不是加门控，而是**根本
  没有无 UI 的 Flutter 进程**：核心是纯 Dart 控制台程序，托盘只属于 UI。










