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

## [3.1.0] — 智能体接口（MCP）+ 回收站

> 未打 tag（用户要求缓打），但代码与文档已按本版本号就位。

### Added（新功能 → minor）

- **智能体访问（MCP）**：核心内新增一个只监听 `127.0.0.1` 的 Streamable-HTTP 端点
  （固定端口 **47821**，单端点 `POST /mcp`）。设置 → **智能体访问** 打开总开关后：
  - **配对**：每个智能体一把 256-bit 密钥（库里只存 SHA-256，明文只显示一次）；
  - **两种访问方式**：`信任直通`（每次访问都写审计）与 `逐次审批`（每次调用弹窗，
    可勾「本会话内允许读取」，仅对普通读生效）；
  - **条目级开关**：「允许智能体访问：开放 / 永久拒绝」，默认**永久拒绝**，
    落在加密载荷里；编辑页 / 详情页 / 列表三处可见；
  - **11 个工具**：`status` / `begin_session` / `end_session` / `list_entries` /
    `get_entry` / `create_entry` / `update_entry` / `delete_entry` / `list_trash` /
    `restore_entry` / `copy_to_clipboard`；
  - **秘密不进模型上下文**：字段值只写进系统剪贴板（只回 `ok` + 长度），
    没有 `reveal_secret`；
  - **零介入解锁**：专属密钥由 Windows DPAPI 保护，核心启动时自动解封 `agent` 会话域
    （与 `ui` / `bridge` 域独立）；改主密码时自动重新包裹；
  - **审计**：`agent_audit` 表（schema 4，保留最近 1000 条）；侧边栏 → **智能体活动**
    （回收站上方，**未开启总开关时入口隐藏**）可查，页面实时刷新；
    decision 区分 `allowed` / `allowed_standing` / `denied` / `timeout` / `error`。
- **回收站**（schema **5**，`password_entries.deleted_at`）：删除 = 移到回收站（软删，
  密文不动、可恢复）；侧边栏新增「回收站」页面，可恢复 / 彻底删除 / 清空；
  删除条目后的提示条提供「撤销」。列表 / 搜索 / 健康报告 / 计数 / 导出默认排除回收站。

### Changed

- **智能体写 / 删**：新增新建、修改、删除（软删）、回收站列表与恢复。写/删/恢复在方式 1 下
  **永远逐次审批**；智能体**自己新建的条目默认对它自己开放**（它建完要能继续管理；
  用户可随时改成「永久拒绝」收回，开关本身智能体改不了）；智能体**不能彻底删除**条目。
- **审批弹窗**：写/删会多一行「详细」（只列字段名与动作，**不显示任何值**）；
  弹窗加宽、三个动作一排横放（同意 / 本会话内允许读取 / 拒绝），拒绝为红色实心。
- **`status.entryCount`** 改为"开放条目数"（方式 1 下不再恒为 0）。
- `deleteItem` 的语义从硬删改为**移入回收站**。
- **启动提速（核心）**：审计裁剪 `pruneAgentAudit` 从启动关键路径移除 —— 监听/写
  `daemon.json` 就绪后再后台执行；500k 行实测核心就绪 **728ms → 168ms**（后台仍在 2s 内裁到 1000 行）。
- **字体子集化**：打包字体从 **39.3MB 降到 10.3MB**（GB2312 全量 + App UI 文案字符 + 基础拉丁/标点；
  完整原版每字重 19.7MB 留在 git 历史）。冷启动更快；GB2312 之外的生僻字/繁体逐字回退系统字体（可读）。
  重新生成脚本：`tool/subset_fonts.py`。
- **底部提示统一改为浮起泡泡**：圆角、380 宽、水平居中、自动收起（可左右滑掉），
  不再用横贯底部的长条挡住侧边栏入口。

### Fixed

- **`create_entry` 对 secure_note 静默忽略登录字段**：现在传 `url` / `username` /
  `password` 会返回 `invalidRequest`（与 `update_entry` 一致），避免调用方误以为
  "密码已经存进去了"。
- **智能体新建 / 修改 / 删除 / 恢复条目后，UI 列表不实时刷新**：核心在智能体写库后
  没有广播变更主题，现在补上（`items` / `item` / `folders` / `search`）。
- **带「撤销」的提示条永不消失**（这台 Flutter 里带 action 的 `SnackBar` 默认
  `persist: true`），一直挡在底部导致点不到回收站入口；现在显式 `persist: false`
  并在 5 秒后自动收起。
- **智能体活动页面**从设置移到侧边栏（回收站上方），未启用智能体访问时隐藏；
  并改为推送驱动，新记录会实时出现。
- **条目列表支持右键 / ⋮ 菜单**（编辑 / 删除）：在**鼠标位置弹出浮窗**（`showMenu`，
  不是底部弹窗）；删除进回收站并给撤销提示，不必先打开详情页。**搜索结果**也接入了
  同一个浮窗菜单。
- **审批疲劳修复**：对「永久拒绝」/ 越界条目，读、复制、改、删、恢复都会在**弹审批之前**
  被硬闸预检挡下（`AgentAccessPolicy.precheck`）——不再出现"用户点了同意才发现被拒"，
  拒绝仍照常写一条 `denied` 审计。
- 回收站里的「恢复」与「彻底删除」**统一为图标按钮**（之前恢复是文字、删除是图标，视觉不齐）。
- 「智能体活动」入口与页面标题补上图标（统一用 `smart_toy`；`Icons.history` 字形在该构建中
  未渲染，用户实测确认——根因见下）。
- 底部提示气泡的贴底间距收紧到 8px，并把 FAB 移出 `Scaffold.floatingActionButton`：
  floating SnackBar 原本会被 FAB 抬高约 80px（`snackBarYOffsetBase = FAB.top`），
  现在真正贴住窗口底边。
- **图标字体子集修复**：Flutter 增量构建不会因 Dart 代码变化重新生成
  `MaterialIcons-Regular.otf`（`CopyAssets` 输入缺 `app.dill`），导致后加的图标
  （`edit_outlined` / `restore` / `history`）在真机上空白。构建前删 `build\flutter_assets`
  即可（已写入 `AGENTS.md` 的构建须知）。

### Security

- 配对密钥不参与任何解包（泄露它不能解密数据库）；DPAPI 只隔离其他 Windows 账户与搬运到
  其他机器的文件，同用户恶意进程仍是既有边界（见 `SECURITY.md`）。
- MCP 监听拒绝带 `Origin` 的请求、校验 `Host`、只接受 `POST`、Bearer 只放 header、
  不接受 query 凭据、不发 CORS 头、限制请求体大小。
- 智能体只能读到"对智能体开放"的条目；「永久拒绝」是硬闸，写/删同样受它约束。

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

