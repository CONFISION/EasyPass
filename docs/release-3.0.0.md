# EasyPass 3.0.0

> **这是一次架构与安全模型变更（major）。** 保险库不再由界面进程持有：新增一个独立、
> 常驻、无窗口无托盘的**核心服务** `easypass_core`，界面变成它的纯客户端。
>
> **升级前请先读「升级须知」**：通信协议从 3/4 升到 **5**（全帧加密），旧客户端会被
> 明确拒绝而不是降级；`easypass.exe --service` / `--native-host` 两种形态已被移除；
> 密钥材料搬进了保险库文件。**保险库坐标没变，不需要迁移数据**；照例请先备份
> `easypass.db`。
>
> **平台范围**：本版只发布 **Windows** 产物。Linux 桌面端（2.3.3 引入）不在主分支，
> 完整实现保存在仓库的 `linux` 分支。

---

## 亮点

- **保险库有了唯一的所有者。** 核心服务 `{app}\core\easypass_core.exe` 独占
  `easypass.db` 与会话密钥，常驻且**不会空闲自退**——关掉界面它还在，浏览器扩展照常
  自动填充。界面 `easypass.exe` 只负责显示：它不开库、不持密钥、不碰数据库文件。
- **关窗即锁。** 点窗口右上角的 X（隐藏到托盘）会**先锁定保险库再隐藏**，重新打开就是
  锁屏；托盘 `Exit UI Only` 走同一条锁定路径（锁定失败只提示，仍然隐藏/退出，不把人
  困在界面里）。
- **托盘两档退出。** 菜单三项：`Open EasyPass` / `Exit UI Only`（界面退出，核心继续为
  浏览器服务）/ `Exit UI and Stop Service`（界面与核心一起退出，`daemon.json` 一并清理）。
- **界面单实例。** 双击第二次不会出现第二个窗口或第二个托盘图标：已有窗口被恢复到前台
  并置顶；带 `--` 开关的命令行调用不受这道闸门影响。
- **链路上没有明文。** 界面 / 扩展与核心之间是**全帧加密**通道（协议 5）：握手用双方
  nonce 互相证明，**令牌永不上线**；之后每一帧都是 AES-256-CBC + HMAC-SHA256
  （encrypt-then-MAC、四个方向密钥）。旧的明文握手会被明确拒绝，**不会**降级成明文。
- **健康报告在核心里算。** 明文密码与 TOTP 种子不再经过 IPC——界面只收到条数、分数与
  问题条目的 id / 名字，两个回归测试盯着"不许退回本地分析"。

## 本轮修复

- **关窗后上锁只生效一次（用户真机报告）。** 现象是：第一次关窗后重开界面要求密码，
  之后再关窗重开却直接显示解锁态、但条目全是空的。根因不是"没锁上"——核心每次都锁了
  ——而是**核心没把 `sessionLocked` 广播出来**：状态翻转原本只由 5 秒一次的节拍器比对，
  "解锁后 5 秒内关窗"时 `_lastKnown` 还没更新，`lockAll()` 看到"没有变化"就不广播，
  界面于是停在假解锁态。现在 `VaultSession` 的解锁/锁定**立即**通知 `SessionDomains`，
  不再依赖节拍器。
- **扩展解锁会让桌面端也变成解锁态（同一处修复里发现）。** 客户端把
  `sessionUnlocked` 一律当成自己的事件，**丢了 `domain`** —— 于是浏览器解锁后桌面端
  也显示解锁态（而 `ui` 域其实还锁着）。现在只认 `ui` 域的事件，`coreShuttingDown`
  仍然一律转发。
- **无 UI 的进程不再有 UI 表面（2.4.x 的真实缺陷）。** 2.4.x 的 `easypass.exe --service`
  窗口不可见，却照样注册了托盘图标，托盘 `Open EasyPass` 能把那个空窗口 `ShowWindow`
  出来（2026-10-17 用 `WM_COMMAND(1001)` 实测复现）。3.0.0 的修法不是加门控，而是
  **结构上不存在无 UI 的 Flutter 进程**：核心是纯 Dart 控制台程序，托盘只属于界面。
- **关窗后保险库不上锁（用户真机反馈）。** 以前 `WM_CLOSE` 只做"隐藏到托盘"，锁定完全
  依赖核心的空闲计时器（默认 5 分钟），所以关窗再打开还是解锁态。现在关窗与"仅退出界面"
  共用同一条锁定路径。**语义提醒**：锁定会连 bridge 域一起锁，所以关窗后浏览器扩展也
  需要重新解锁——这是既定的 `lockAll()` 行为，不是新引入的问题。
- **"校验材料没落盘"的提示此前是死代码。** 核心改主密码时会回报"新的校验材料是否真的
  写进库"，旧代码把这个字段丢了，于是写失败时用户看不到任何提示。现在
  `changeMasterPassword` 返回 `keyMaterialPersisted` + `reencrypted`，写失败会明确提示
  （此时**新密码仍然有效**：库里的轮换日志是权威）。
- 随本版一并收口的小项：陈旧核心的判定显式化（`protocolVersion` 落后即判为陈旧，只清理
  发现文件、**不盲杀进程**）；删掉两个从未实现的空壳动作（`subscribe` / `getSnapshot`）；
  安装器的两处 ISCC 失败（`[Code]` 段用 `{}` 当注释、`sqlite3.dll` 路径少一层 `Release`）
  与"`flutter build windows` 卡在 `build_hooks`"的真因（代理 / 网络）都写进了文档。

## 升级须知

### 协议 3 / 4 → 5：全程加密，旧客户端被拒绝

- 握手改为「双方各出一个 nonce + 用令牌双向 HMAC 证明」，**令牌本身不再出现在链路上**；
  握手末帧起所有帧 AES-256-CBC + HMAC-SHA256（encrypt-then-MAC，四个方向密钥）。
- `role: ui` / `agent` **只能**走加密握手；旧版的明文形状一律回 `unsupported` ——
  **不会**为了兼容而降级成明文。
- 因此**浏览器扩展也要一起换成 3.0.0**（扩展尚未上架商店，需要重新"加载已解压的扩展
  程序"）。旧扩展连上新核心只会拿到明确的协议错误，不会静默失配。
- 能力边界说清楚：这挡得住没有令牌的进程与被动抓包，**挡不住同一用户账户下的恶意进程**
  （它能读 `daemon.json`，而界面本来就要显示明文密码）。唯一例外见「已知限制」里的 x86 桥。

### 进程形态：`--service` / `--native-host` 已移除

- 旧的后台形态 `easypass.exe --service` 与 `easypass.exe --native-host` **不存在了**。
  后台是核心服务：`{app}\core\easypass_core.exe --serve`。
- 核心的命令行：`--serve` / `--bridge` / `--lock` / `--shutdown` / `--status` / `--version`。
  `--lock` **只锁库、不停核心**（托盘"仅退出界面"先跑它再退）。
- 浏览器原生消息宿主仍是 `{app}\easypass_native_host.exe`（32 位，浏览器 stdio 限制），
  它现在负责把浏览器连接转发给核心；注册方式不变（安装器写注册表）。

### 密钥材料搬进了保险库文件

- salt 与主密码校验哈希从**系统钥匙串**迁到库文件里的 `vault_meta`（核心自管）。
- 升级后**第一次打开界面**时一次性交接（`adoptLegacyKeyMaterial`）；**旧钥匙串里的值
  不删除**，便于回退到 2.4.x。
- 只跑扩展、从不开界面的用户：扩展会提示需要先打开一次桌面应用完成升级
  （`needsKeyMigration`）。
- **回退到 2.4.x**：旧钥匙串值与保险库坐标都还在，理论上装回 2.4.x 即可继续用；
  但反向路径本版**未实测**（见「已知限制」）。

### 数据坐标不变，不需要迁移数据

- 保险库仍是 `{app}\easypass.db`，条目零丢失；`daemon.json` 仍在
  `%LOCALAPPDATA%\EasyPass\`。
- 核心虽然装在 `{app}\core\`，但数据目录仍取 `{app}`（界面二进制所在目录）——这是刻意的，
  所以升级不需要搬数据。**照例：升级前先备份 `easypass.db`。**

### 升级瞬间：旧 `--service` 进程可能还活着一会儿

- 2.4.x 的后台进程不会立刻消失：它按老行为在**最多 10 分钟**空闲后自退。这段时间里新旧
  两个进程可能同时打开同一个 SQLite 文件——SQLite 自己的锁保证数据不会被写坏。
- 它**不会**删掉新核心的 `daemon.json`（清理发现文件前会校验 port + pid），所以不必手工
  清理；安装器在替换文件前也会先停核心，并请正在运行的旧 `easypass.exe` 关闭。
- 想立刻干净升级：先在托盘完整退出旧版（或结束 `easypass.exe`），再装 3.0.0。

### 自启项指向核心

- Windows 的自启项从 `{app}\easypass.exe` 改为 `{app}\core\easypass_core.exe --serve`：
  登录后起来的是无窗口、无托盘的核心，界面由你自己打开（托盘 / 桌面图标 / 开始菜单）。
- 自启项由安装器写 `HKCU\…\Run\EasyPass`；卸载器会一并删除它。

### Linux 支持不在本版（重要）

- Linux 桌面端（2.3.3 引入的 AppImage / GTK 托盘 / XDG 自启等）**不在主分支**，
  完整实现与文档保存在仓库的 **`linux` 分支**。
- 因此 3.0.0 **只发布 Windows 产物**。Linux 用户请继续使用 2.3.3，或从 `linux` 分支
  自行构建（那条线的 3.0.0 适配**尚未做过编译与真机验证**）。

## 安装

- **Windows（推荐）**：下载 Release 页上的 `EasyPass-3.0.0-windows-x64-setup.exe`
  （即安装包本体 `EasypassSetup.exe`，上传前改名以便区分版本）直接运行。
  按用户安装、**免管理员**，装到 `%LOCALAPPDATA%\Programs\EasyPass`（保险库就在这个目录里），
  可选"随系统启动"，并注册 Chrome / Edge 的原生消息宿主。
- **安装包尚未代码签名**，SmartScreen 可能提示"未知发布者"。请核对下方的 SHA-256。
- **浏览器扩展**：尚未上架任何商店，需要打开 `chrome://extensions`（或
  `edge://extensions`）→ 开发者模式 → **加载已解压的扩展程序** → 选 `browser_extension/`。
  **本版协议变了，请务必使用 3.0.0 的扩展。**

## 产物与校验和

<!-- BEGIN GENERATED:artifacts —— 由 installer/release/generate_release_notes.mjs 依据 release-manifest.json 生成，勿手工编辑 -->

版本 **3.0.0**（pubspec `3.0.0+15`） · 产物 **1** 个 · 合计 **27.9 MiB** · 清单生成时间 2026-10-18T10:06:30.357Z

| 文件 | 平台 | 大小 | SHA-256 |
| --- | --- | ---: | --- |
| `EasypassSetup.exe` | Windows | 27.9 MiB | `aaaab0a51272a020e2ab8f9a853195da9c17cb8e9f106e2b61c2c6906eae66eb` |

`SHA256SUMS.txt` 的完整内容（与本文件同目录）：

```text
aaaab0a51272a020e2ab8f9a853195da9c17cb8e9f106e2b61c2c6906eae66eb  EasypassSetup.exe
```

产物来源（构建由用户 / CI 执行，脚本只做收集与哈希）：

```text
flutter build windows && "C:\Program Files\Inno Setup 7\ISCC.exe" installer\easypass_setup.iss
```

<!-- END GENERATED:artifacts -->

本版**至少**应发布 Windows 安装包（`build\installer\EasypassSetup.exe`）；
扩展商店包是可选项（`node browser_extension/tools/build_extension_zip.mjs`）。
校验方法：`Get-FileHash <文件> -Algorithm SHA256`，或 `certutil -hashfile <文件> SHA256`。

## 已知限制与验证状态

**已在 Windows 真机上验证**（用户执行）：

- 核心与界面进程分离；关掉界面后核心仍在、扩展仍可用。
- 托盘两档退出：`Exit UI Only`（先锁库再退界面，核心继续运行）与
  `Exit UI and Stop Service`（两个进程都退出）。
- **关窗即锁**，且连续多轮都生效；关窗后用扩展访问会要求重新解锁。
- **界面单实例**：双击两次只有一个进程、一个托盘图标。
- **安装 → 卸载 → 从 2.4.x 升级**三条路径；升级后旧主密码能正常打开原有保险库。

**仍然存在的限制（有意为之或未覆盖）**：

- **x86 桥与核心之间仍是明文 + 令牌认证**。32 位浏览器的 stdio 限制让桥只能做字节转发，
  这条链路是本版**已知的、有意保留的**信任边界，不在协议 5 的加密范围内。
- **同用户账户不是安全边界**。加密保证"链路上没有明文"，挡得住无令牌进程与被动抓包；
  同一用户下的恶意进程能读 `daemon.json`、也能附加调试器——真正的边界是 OS 账户。
- **通道加密的独立探针只在 agent 侧跑过**：`tool/probe_channel_security.dart` 11/11 通过
  （链路无明文、令牌不上线、旧协议被拒、错误令牌被拒）。用户构建产物上的端到端证据是
  "扩展在真机上能正常解锁并填充"。
- **回退到 2.4.x 未实测**（升级方向已验）。
- **Linux 不在本版**：见「升级须知 · Linux 支持不在本版」。
- 既有边界不变：无同步 / 分享 / 紧急访问；扩展未上架商店；安装包未代码签名；
  Firefox 未端到端验证。

## English summary

- **EasyPass 3.0.0 moves the vault into a standalone core service.** A windowless,
  tray-less `easypass_core` process owns `easypass.db` and the session key, stays
  resident (no idle shutdown), and keeps serving the browser extension while the UI is
  closed. The Flutter app is a pure client: it never opens the database and never holds
  the key.
- **Closing the window locks the vault** before hiding to the tray, and the tray offers
  two exits: `Exit UI Only` (the core keeps running) and `Exit UI and Stop Service`.
- **On Windows a second launch no longer creates a second window or tray icon**; it
  brings the existing window to the front.
- **Client ↔ core traffic is fully encrypted (protocol 5).** The handshake proves both
  sides with nonces and HMACs, the token never travels, and every frame is
  AES-256-CBC + HMAC-SHA256. Older clients are rejected (`unsupported`) instead of
  falling back to plaintext, so the browser extension must be updated to 3.0.0 too.
- **Key material (salt + verifier) moved from the OS keychain into the vault itself**
  (`vault_meta`). The first UI start after the upgrade hands the old values over, and
  the keychain copy is kept so a rollback to 2.4.x stays possible. The vault does not
  move (`{app}\easypass.db`), so there is no data migration.
- **Upgrade notes:** `easypass.exe --service` / `--native-host` are gone (the core is
  `{app}\core\easypass_core.exe --serve`), autostart now starts the core, and an old
  `--service` process may stay alive for up to 10 minutes after the upgrade (it cannot
  delete the new core's `daemon.json`).
- **Windows only.** The Linux desktop port now lives in the repository's `linux` branch
  and is not part of this release.
- **Fixes worth calling out:** close-to-lock used to work only once — the core did lock
  every time but never broadcast `sessionLocked` to the UI (state changes now notify
  immediately instead of waiting for a 5-second tick); and the client used to treat a
  browser-extension unlock as its own, making the desktop UI claim it was unlocked while
  the `ui` session was still locked. Both are covered by new regression tests.
- **Verified on real hardware** (Windows): process separation, both tray exits,
  close-to-lock across repeated rounds, UI single-instance, and install / uninstall /
  upgrade from 2.4.x.

