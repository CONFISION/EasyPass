# Changelog

All notable changes to EasyPass are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — architecture or security-model change (crypto layer rewrite, database
  migration, key hierarchy rework)
- **minor** — new or removed features
- **patch** — bug fixes, performance and UI polish that do not change features

> Version numbers are kept in sync in **four** places: `pubspec.yaml`,
> `lib/features/settings/screens/settings_screen.dart`,
> `browser_extension/manifest.json`, and `installer/easypass_setup.iss`.
> `node browser_extension/tools/check_extension.mjs` fails if they disagree.

---

## [3.0.0] — 核心服务化

> **平台范围变更（3.0.0 之后）**：Linux 桌面支持（2.3.3 引入）已迁至本仓库的 `linux`
> 分支，主分支只构建与支持 **Windows**。本文件的历史条目保持原样 —— 2.3.3 确实发布过
> Linux 支持，改历史会让记录失真。

### Changed（架构 / 安全模型变更 → major）

- **保险库改由独立的核心服务进程持有。** 新增 `easypass_core`（纯 Dart AOT，无 Flutter、
  无窗口、无托盘）：它是唯一打开 `easypass.db`、唯一持有会话密钥的进程，常驻直到用户显式
  退出（不再有空闲自退）。UI 变成**纯客户端**，经 `VaultApi`（`lib/client/`）与本机回环
  协议访问核心，自己不再开库、不再持密钥。
- **协议 5 + 通道加密。** 核心与客户端之间**不再有明文**：握手改为「双方各出一个 nonce +
  用令牌双向 HMAC 证明」（**令牌本身永不上线**），握手末帧起所有帧用 AES-256-CBC +
  HMAC-SHA256（encrypt-then-MAC、四个方向密钥）加密认证。`role: ui` / `agent` **只能**
  走加密握手，旧明文形状一律 `unsupported`；唯一例外是 Windows 的 x86 桥（32 位 stdio
  限制下的字节转发器，回环 + 令牌认证）。
  能力边界：这保证"链路上没有明文"，挡得住没有令牌的进程与被动抓包；**挡不住同用户的
  恶意进程**（它能读 `daemon.json`，而 UI 本来就要显示明文密码）。
- **握手带 `role`**（`ui` / `bridge` / `agent`），核心主动推送 `changed` /
  `sessionLocked` / `sessionUnlocked` / `coreShuttingDown` 事件；扩展的 9 个动作形状保持不变。
- **会话分域。** `ui` 与 `bridge` 各自一份密钥与空闲计时，自动锁定由核心执行；UI 锁定会
  同时锁扩展，UI 解锁不会解锁扩展（刻意如此）。UI 通过 `touchActivity` 节流上报活动。
- **密钥材料迁入库文件的 `vault_meta`**（`VaultMetaSecretStore`）。旧版存在系统钥匙串里的
  salt / 校验哈希在首次启动 UI 时一次性交接给核心（`adoptLegacyKeyMaterial`），旧值不删除，
  便于降级回 2.4.x。
- **托盘只属于 UI**，菜单三项：`Open EasyPass` / `Exit UI Only` / `Exit UI and Stop Service`。
  关窗只隐藏到托盘；核心是否退出与窗口、托盘完全解耦。
- **Windows 核心唯一性**由固定回环端口保证：第二个 `--serve` 立即以退出码 2 退出。
- 安装布局：核心在 `{app}\core\easypass_core.exe`、运行库在 `{app}\lib\sqlite3.dll`；
  **保险库坐标不变**（仍是 `{app}\easypass.db`），升级不需要迁移数据。
- 自启项改为拉起核心（`{app}\core\easypass_core.exe --serve`）。

### Added

- **健康报告改由核心计算**（`healthReport` 动作，同一套 `HealthService.analyze`）：
  UI 只接收统计数字（条数 / 分数 / 问题条目的 id+名字），**明文密码与 TOTP 种子
  不再经过 IPC**。回归网：两个健康测试都用 `expect(api.called('listItems'), isFalse)`
  盯着"别再退回本地分析"。
- **关窗即锁**（Windows）：`WM_CLOSE` 先跑 `easypass_core --lock` 再隐藏到托盘，
  重新打开是锁屏；托盘 `Exit UI Only` 走同一条路径。此前关窗只隐藏，锁定完全依赖
  核心的空闲计时器（默认 5 分钟）。
  语义提醒：`--lock` → `lockAll()`，所以关窗后**浏览器扩展也需要重新解锁**（既定行为）。
- **Windows UI 单实例**（`windows/runner/main.cpp`）：命名 Mutex `Local\EasyPass.UI`
  + `FindWindowW` 抬窗，双击两次不会再出现第二个进程/第二个托盘图标；带 `--` 开关的
  CLI 调用跳过闸门。
- **改密"写入失败"的提示恢复可达**：`VaultApi.changeMasterPassword` 现在返回
  `ChangePasswordResult`（`keyMaterialPersisted` + `reencrypted`），钥匙串/存储写失败时
  界面会提示 —— 此前那个字段被丢掉，提示是死代码。
- `easypass_core --serve / --bridge / --lock / --shutdown / --status / --version`。
  `--lock` 只锁库不停核心（托盘"仅退出 UI"先跑它再退 UI）。
- `tool/build_core.ps1`（`dart build cli` 封装）与
  `tool/probe_core.dart`（19 项核心动作面探针）。
- `test/architecture_boundary_test.dart`：UI 不得碰数据库、核心不得 import Flutter。

### Removed

- Flutter 的 `--service` / `--native-host` 模式、`EasypassDaemon`、`startInProcessDaemon`、
  `BrowserSessionRegistry`（被核心内会话域取代）。**这同时修掉了 2.4.x 的一个真实缺陷**：
  `--service` 进程虽然窗口不可见，却照样注册托盘图标，托盘 "Open EasyPass" 能把那个空窗口
  显示出来（2026-10-17 实测复现）。
- **Linux 桌面支持移出主分支**（2.3.3 引入的 AppImage / GTK 托盘 / XDG 自启等）。
  完整实现与文档保存在仓库的 `linux` 分支（分叉点 `3312384`）；主分支只构建与支持
  **Windows**。因此本版只发布 Windows 产物。

### Fixed

- **关窗上锁只生效一次**（用户真机报告：第一次关窗后重开要求密码，之后再关窗重开却
  直接显示解锁态且条目全空）。核心每次都锁了，但**没有广播 `sessionLocked`** ——
  状态翻转原本只由 5 秒节拍器比对，"解锁后 5 秒内关窗"时 `_lastKnown` 还没更新，
  `lockAll()` 判为"无变化"就不广播。现在 `VaultSession` 的解锁/锁定**立即**通知
  `SessionDomains`，不再依赖节拍器。回归网：`test/session_domains_test.dart`
  （连续三轮"解锁 → 立即锁定"，每轮都必须有事件）。
- **扩展解锁会让桌面端也变成解锁态**：客户端把 `sessionUnlocked` 一律当成自己的事件、
  **丢了 `domain`**，于是浏览器解锁后桌面端也显示解锁态（`ui` 域其实还锁着）。现在只认
  `ui` 域，`coreShuttingDown` 仍一律转发。回归网：`test/session_event_translation_test.dart`。

---

## [2.4.0]

### Added

- **Bitwarden / Vaultwarden import** (`lib/data/services/bitwarden_importer.dart`).
  Reads the *unencrypted* Bitwarden JSON export and the CSV export. Folders are
  recreated by name and reused on re-import. Cards (which EasyPass has no type for)
  are imported as secure notes with the card data preserved in custom fields; extra
  URIs on a login are kept as custom fields; password history and the fields
  Bitwarden has but EasyPass does not are appended to the notes. The import reports
  exactly how many entries were skipped and why — never a silent partial import.
- **Bitwarden-compatible export** (`ExportImportService.exportBitwardenJson`), so a
  migration is not a one-way door. SSH keys, which Bitwarden has no type for, are
  exported as secure notes with the key material in custom fields and an explicit
  note explaining the downgrade.
- **Master-password rotation journal** (`vault_meta` table, schema **3**). Rotating
  the master password now writes the target salt + verifier and the whole-vault
  re-encryption in **one SQLite transaction**, so the two can no longer disagree.
- **CI** (GitHub Actions): `flutter analyze`, `flutter test`, the browser-extension
  self-checks and the native-runner syntax check on every push and pull request;
  tagged releases build the Windows installer and publish it with
  `SHA256SUMS.txt`.
- **Release tooling**: `installer/release/collect_artifacts.mjs` generates the
  checksum file and a machine-readable artifact manifest, instead of recalling the
  artifact list by hand.
- `SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md`.

### Fixed

- **Data-loss class: a failed master-password change could lock the vault
  permanently.** The old sequence was "re-encrypt the whole vault, *then* write the
  new salt + verifier to the OS keychain". `storeKeyMaterial` itself writes two
  values (salt first, hash second), so a failure in between left the ciphertext on
  the new key while the stored verifier belonged to the old salt — **neither the old
  nor the new master password could open the vault**, and the entries decrypted to
  empty strings. This is reachable in practice when the OS keychain is unavailable
  or locked) and on Windows (a process demoted to Low integrity cannot write
  `%APPDATA%`). The vault is now all-or-nothing: the journal and the re-encryption
  commit together, a keychain failure leaves the new password usable via the
  journal, and the journal is retried and cleared on the next successful unlock.
  See `test/master_password_rotation_atomicity_test.dart`.
- **The old master password kept working after a change** (found on the first real
  hardware run, after the fix above had already landed). "Verify the master password"
  had **three** separate implementations (`AuthNotifier.unlock`,
  `NativeMessagingService._unlock` for the browser extension, and
  `EntryDetailScreen._verify` for the reveal-private-key prompt), and only the first
  knew about the rotation journal. Whenever a rotation did not get its verifier into
  the OS keychain, the other two kept accepting the old password — its hash still
  matched the stale keychain copy — and rejected the new one. All three now go
  through a single `MasterPasswordVerifier`, whose rule is: **a rotation journal
  exists ⇒ only the journal's target password is valid; the keychain copy is stale.**
- **Changing the master password left the vault unlocked**, returning straight to the
  vault instead of to the lock screen. That made a broken rotation undetectable —
  nothing forced the user to prove the new password worked. The app now clears the
  session key, locks the browser-bridge session too, and returns to `/lock`.
- A failed keychain write during rotation now says so on the lock screen instead of
  leaving the user at an unexplained prompt (the new password is still valid; the
  verifier is served from the in-vault journal).
- `encryptionProbeWorks` only inspected the first row, so one corrupt row made a
  working key look wrong — which broke the deliberate "a single undecryptable entry
  must not affect the whole report" property.

### Changed

- Unlock consults the rotation journal as well as secure storage.
- The browser extension no longer requests the `storage`, `scripting` or `activeTab`
  permissions — no code path used them.

---

## [2.3.3] — Linux desktop port

### Added

- **Linux desktop support (AppImage)**: tray icon and close-to-tray via
  GTK/AppIndicator, single instance (`easypass.db.lock` + unix socket wake-up),
  XDG autostart, desktop-entry CLI (`--install` / `--uninstall` /
  `--desktop-status`) and native-messaging host registration
  (`--install-browser-host` / `--uninstall-browser-host` / `--browser-host-status`).
- The vault lives in `$XDG_DATA_HOME/easypass/` on Linux (permissions tightened to
  `0700`/`0600`), with migration of a legacy database file next to the executable.
- The native-messaging host on Linux is the app binary itself
  (`easypass --native-host`); there is no separate x86 bridge.

### Fixed

- Settings screens surface font-setting load/save failures instead of silently
  falling back.
- The storage-unavailable state stays visible with Retry/Exit instead of deadlocking.
- The daemon persists `daemon.json` only after it is listening, validates pid
  liveness, and redacts error details.
- Linux tray: the embedder delete-event is disconnected so the tray survives close.
- The AppImage bundles `libsqlite3` and fails loudly when the sqlite plugin target is
  missing.

---

## [2.3.0] — entry types

### Added

- Four entry types: login, secure note, identity and SSH key, plus custom fields on
  every type.
- Folder management (icons, rename, guarded delete), `type:` / `folder:` / `url:`
  search prefixes, live TOTP codes.
- `EntryPayload` JSON (identity + SSH blocks and all custom fields) encrypted into the
  new `data_encrypted` column; schema **2** with a real 1→2 migration.
- Bridge protocol **3**: entry JSON carries `type` / `identity` / `sshKey` /
  `customFields`; `hasTotp` replaces the raw TOTP secret; `getCredentials` returns
  login entries only.

### Removed

- Unused `riverpod_generator` / `riverpod_lint` / `custom_lint` dev-dependencies
  (they produced nothing here and pinned `analyzer ^7`, which broke drift codegen).

---

## [2.2.2] and earlier

See the git history. Highlights: the browser extension became functional
(autofill, session keep-alive, protocol extension) in 2.2.0; encrypted export/import
and TOTP in Phase 2; the Phase 1 MVP (master-password vault, CRUD, folders,
generator, search, auto-lock) came first.

[Unreleased]: https://github.com/CONFISION/EasyPass/compare/v2.3.3...HEAD
[2.3.3]: https://github.com/CONFISION/EasyPass/releases/tag/v2.3.3

