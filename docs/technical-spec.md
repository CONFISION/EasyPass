# EasyPass 技术规范（3.0.0 核心服务架构）

> **本地文档**：本文件在 `docs/` 下，被 `.gitignore` 忽略，不会进入 git。
> 需要入库时见文末「§13 如何让本文档入库」。
>
> 阅读顺序建议：`AGENTS.md`（仓库约定）→ **本文**（系统怎么运转）→
> `docs/protocol-api.md`（对外接口契约）→ `docs/acceptance-3.0.0.md`（怎么验）。
>
> 事实基准：提交 `01bda50` 的工作树。文中每个数字/常量都取自代码，
> 关键处标注 `文件:行号`；**改动代码后请同步本文**（见 §13 的一致性检查）。

---

## 1. 系统组成

EasyPass 由**四个可执行形态**与一个数据库组成。3.0.0 的核心变化是：**密码库只有一个
所有者**——独立的常驻核心进程；其余一切都是它的客户端。

| 形态 | 可执行文件 | 职责 | 有窗口 | 有托盘 | 生命周期 |
| --- | --- | --- | --- | --- | --- |
| **核心服务** | `{app}\core\easypass_core.exe --serve`（Linux `core/easypass_core`） | 独占 `easypass.db`、持有唯一会话密钥、执行加解密与策略、向客户端推事件 | ❌ | ❌ | **常驻**，只有 `shutdownCore` / `--shutdown` 退出 |
| **桌面 UI** | `{app}\easypass.exe` | 纯客户端：窗口、托盘、渲染；自己不开库、不持密钥 | ✅ | ✅（唯一） | 用户开关 |
| **x86 桥** | `{app}\easypass_native_host.exe`（仅 Windows） | 浏览器 stdio ↔ 核心的回环 TCP 字节转发 | ❌ | ❌ | 浏览器连接期间 |
| **Dart 桥** | `easypass_core --bridge`（Linux 由 wrapper 启动） | 同上，但由核心二进制自带转发模式 | ❌ | ❌ | 浏览器连接期间 |
| **数据库** | `{app}\easypass.db` | 加密后的条目 + `vault_meta`（含校验材料与轮换日志） | — | — | 由核心独占打开 |

**为什么 x86 桥在 Windows 上不能省**：浏览器原生消息宿主必须是 32 位控制台程序
（32 位 Edge 拉起 64 位宿主时 stdio 句柄不是管道，实测 `FILE_TYPE_CHAR`，
见 `browser_extension/native_host/easypass_native_host.cpp` 顶部注释）；Dart AOT 出不了 ia32。
桥因此只做**字节转发**，不理解协议内容。

**为什么核心放在 `{app}\core\` 子目录**：`package:sqlite3` 的 build hook 按
`<exe 目录>\..\lib\<name>` 解析原生库（Dart 3.13.4 实测；放在 exe 旁边的 `sqlite3.dll`
永远不会被加载）。核心进 `core\` 后，这个相对路径正好落在 `{app}\lib\`，
**一切留在安装目录内**。数据坐标不受影响：`AppPaths` 在非 Linux 上会检查 exe 的父目录
是否含 `easypass[.exe]`，命中则数据目录取父目录（`lib/core/platform/app_paths.dart`
的 `_resolveDataDirectory`）。

---

## 2. 运行时拓扑

```
┌──────────────────────────── Windows / Linux ─────────────────────────────┐
│  easypass_core --serve     唯一、常驻、无窗口、无托盘                     │
│   ├ 独占 easypass.db（唯一密钥副本）                                      │
│   ├ 会话两域：ui / bridge（+ 预留 agent）                                 │
│   ├ 监听 127.0.0.1:47820（固定端口，兼作单实例闸门）                      │
│   ├ 写 daemon.json（port/token/protocolVersion/pid/coreVersion/exe）      │
│   └ 协议 5：握手双向证明 + 全帧加密                                       │
│         ▲                          ▲                        ▲             │
│   ┌─────┴──────┐          ┌────────┴────────┐      ┌────────┴────────┐    │
│   │ easypass   │          │ easypass_       │      │ (未来) MCP      │    │
│   │ .exe (UI)  │          │ native_host.exe │      │ 客户端          │    │
│   │ 托盘三项    │          │ (x86, 字节转发) │      └─────────────────┘    │
│   └────────────┘          └─────────────────┘                             │
│        │                          ▲                                       │
│        │ 同目录 core\ + lib\       │ 浏览器 native messaging (stdio)      │
└────────┼──────────────────────────┼───────────────────────────────────────┘
         │                          │
   用户操作 / 托盘               浏览器扩展（content script / popup / background.js）
```

---

## 3. 启动与生命周期

### 3.1 UI 启动序列（`lib/main.dart`）

1. **CLI 早退**：`--install` / `--uninstall` / `--desktop-status` /
   `--install-browser-host` / `--uninstall-browser-host` / `--browser-host-status`
   在 `WidgetsFlutterBinding.ensureInitialized()` **之前**拦截并退出（这些不需要 Flutter、不碰库）。
2. `SecretStoreRegistry.register(const FlutterSecretStore())` —— 注册 UI 侧密钥材料存储
   （**仅迁移期**读旧钥匙串用）。
3. **单实例**：`acquireSingleInstance()`。Linux 用 `easypass.lock` + unix socket 唤醒；
   Windows 在**原生层**做（`windows/runner/main.cpp`：`Local\EasyPass.UI` Mutex →
   `FindWindowW` → `SW_RESTORE` + `SetForegroundWindow` → 退出）。
4. `runApp(ProviderScope(...))` —— **不做**任何开库动作。UI 进程**没有**数据库句柄。
5. 第一个 `vaultApiProvider` 使用时，`CoreSession` 才去发现/拉起核心（见 3.2）。

### 3.2 核心的发现与拉起（`lib/client/core_session.dart`）

```
读 daemon.json
 ├ 存在且 protocolVersion < 当前(5) → 判为陈旧核心：删发现文件（不盲杀进程，见 §8.3），继续往下
 ├ 存在且协议够 → 连接 + 握手 → 成功则复用
 └ 缺失 / 连不上 / 握手失败 → 删发现文件 → 拉起 <UI目录>/core/easypass_core.exe --serve
                               → 轮询 daemon.json（上限 10s，200ms 间隔）→ 再连接
```

UI 冷启动时若没有核心，会**自动拉起**——用户先点扩展还是先开 UI，最终都是同一个核心。

### 3.3 退出路径

| 触发 | 谁执行 | 保险库 | 核心 | 扩展 |
| --- | --- | --- | --- | --- |
| 窗口 X（`WM_CLOSE`） | `windows/runner/flutter_window.cpp` 的 `LockVault()` | **立即锁定**（`--lock` → `lockAll`） | 继续运行 | 也被锁（见 §5.2） |
| 托盘 `Open EasyPass` | UI | 保持（已锁则停在锁屏） | — | — |
| 托盘 `Exit UI Only` | `LockVault()` 后 `Destroy()` | 锁定 | 继续运行 | 也被锁 |
| 托盘 `Exit UI and Stop Service` | 跑 `easypass_core --shutdown`，成功后退出 | 销毁 | **退出** | 断连 |
| `easypass_core --shutdown` | CLI | 销毁 | 退出 | 断连 |
| 强制杀 UI | 系统 | 保持运行（空闲超时后锁） | 继续运行 | 不受影响 |
| 核心被杀 | 系统 | — | — | 下次请求由桥重新拉起 |

> Linux 的对应实现（`lock_vault_before_exit()`）随 `linux` 分支维护。

> **验证状态**：本表描述的是 3.0.0 代码的实际行为。截止 2026-10-18，Windows 上
> "核心/界面分离""托盘两档退出""界面单实例"已真机确认；**"关窗即锁"是最后一轮才实现的，
> 待真机复验**；Linux 全部未验证。各项的当前状态以 `docs/acceptance-3.0.0.md` 开头的
> 状态表为准，不要从本文推断"已验证"。

### 3.4 核心自身

- **无空闲自退**：常驻直到显式停机（2.4.x 的 10 分钟自退已删除）。
- **单实例**：`CoreSingleton.bind()` 独占固定端口 `47820`；抢不到且端口有人应答 ⇒
  以**退出码 2** 退出（调用方据此改连已有核心）。端口被别的程序占用时退化为临时端口。
- **停机顺序**：广播 `coreShuttingDown` → 关所有连接 → 关监听 → 删自己写的
  `daemon.json`（`removeIfOurs` 校验 port+token）→ 关库。

---

## 4. 会话模型

核心内有两个**独立会话域**（`lib/core_service/session_domains.dart`），各持一份密钥副本与
独立空闲计时器。

| 事件 | `ui` 域 | `bridge` 域 |
| --- | --- | --- |
| UI 解锁 | 解锁 | 不变 |
| UI 锁定 / 关窗 / 空闲超时 | 锁定 | **同时锁定** |
| 扩展解锁 | 不变 | 解锁 |
| 扩展锁定 | 不变 | 锁定 |
| 核心退出 | 清零 | 清零 |

规则要点：

- **UI 锁 ⇒ 全锁**（`SessionDomains.lockAll()`）：用户在桌面端点锁定或关窗，
  不能留下一个仍可自动填充的浏览器会话。
- **UI 解锁 ⇏ 扩展解锁**（D4 决策）：解锁必须是一次显式动作，不能因为桌面端解锁就
  静默扩大浏览器的访问面。
- **空闲锁定归核心**：默认 5 分钟（`AppConstants.autoLockTimeoutMinutes`），
  用户可在设置里调 1–60 分钟；核心用固定节拍（5s）检查并广播
  `sessionLocked`/`sessionUnlocked`。
- **活动续期**：只有"读写数据的动作"会 `touch()`；UI 额外通过 `touchActivity`
  动作节流上报用户指针活动（`lib/app.dart` 的 `_ActivityTouchHost`，20s 一次），
  否则用户停在生成器/设置页时会被自动锁定。
- 过期判定是**惰性**的（读 `isUnlocked`/`key`/`remaining` 才判定）+ 节拍器负责推送。

---

## 5. 密码学与密钥材料

### 5.1 数据加密（条目）

| 参数 | 值 | 位置 |
| --- | --- | --- |
| KDF | PBKDF2-HMAC-SHA256，100,000 次 | `app_constants.dart` `pbkdf2Iterations` |
| 派生密钥 | 32 字节（AES-256） | `pbkdf2KeyLength` |
| salt | 32 字节随机（base64 存） | `pbkdf2SaltLength` |
| 条目字段加密 | AES-256-CBC，`base64(IV‖cipher)`，IV 16 字节随机 | `crypto_service.dart` |

敏感列一律 `*_encrypted`；明文只在核心内存与"核心→UI 的 `ui` 域响应"中出现。
唯一加解密口是 `VaultItemMapper`。

### 5.2 校验材料（salt / passwordHash）

**3.0.0 起存库内**（`vault_meta`，键前缀 `secret.`，见
`lib/core/storage/vault_meta_secret_store.dart`），不再依赖系统钥匙串。

为什么可以放库文件：推导密钥与比对哈希是同一次 PBKDF2（拿到库文件的人本来就能以
同样代价穷举），而轮换日志（`rotation.pending`）早就把同样的材料放在这张表里了；
收益是核心彻底摆脱 Flutter 插件，且校验材料与轮换日志同处一个 SQLite 事务域。

**迁移**：升级后首次打开 UI 时，`AuthNotifier` 读旧钥匙串
（`easypass_master_key_salt` / `easypass_master_pw_hash`），调 `adoptLegacyKeyMaterial`
一次性交给核心；核心**仅在 `auth.*` 不存在时**接受。**旧钥匙串值不删除**（便于回退 2.4.x）。
只跑扩展、从不开 UI 的升级用户会收到 `needsKeyMigration` → 提示"请先打开一次桌面应用"。

### 5.3 通道加密（协议 5）

唯一实现：`lib/protocol/secure_channel.dart`。规格详见 `docs/protocol-api.md` §2–§4。

| 参数 | 值 |
| --- | --- |
| nonce | 32 字节随机（hex 64 字符），每连接新生成 |
| 互相证明 | `HMAC-SHA256(token, "easypass-server-proof\|cn\|sn")` / `"…client-proof\|…"` |
| 会话密钥派生 | HKDF-Extract(salt=cn‖sn, IKM=token) + Expand → 128 字节 |
| 方向密钥 | `c2sEnc(0..32) / c2sMac(32..64) / s2cEnc(64..96) / s2cMac(96..128)` |
| 帧加密 | AES-256-CBC + PKCS7，每帧随机 IV 16 字节 |
| 认证 | `HMAC-SHA256(macKey, IV‖cipher)` 32 字节，**encrypt-then-MAC**，常数时间比较 |

**令牌永不上线**：握手只交换 nonce 与 HMAC 证明。握手末帧（服务端 `ok` + 能力表）**也是密文**。

---

## 6. 数据与文件坐标

| 项 | Windows | Linux |
| --- | --- | --- |
| 数据目录 | `{app}`（exe 目录；核心在 `core\` 时取父目录） | `$XDG_DATA_HOME/easypass`（默认 `~/.local/share/easypass`） |
| 数据库 | `{app}\easypass.db` | `$XDG_DATA_HOME/easypass/easypass.db` |
| 发现文件 | `%LOCALAPPDATA%\EasyPass\daemon.json` | `$XDG_DATA_HOME/easypass/daemon.json` |
| 核心 exe | `{app}\core\easypass_core.exe` | `core/easypass_core`（AppImage: `usr/bin/core/`） |
| 核心原生库 | `{app}\lib\sqlite3.dll` | `lib/libsqlite3.so`（AppImage: `usr/bin/lib/`） |
| UI 原生库 | `{app}\sqlite3.dll`（Flutter 自带） | 同上（共用） |
| 权限 | `%LOCALAPPDATA%` 的 ACL | 数据目录 `0700`、库/临时文件 `0600`、wrapper `0700` |
| 调试日志 | `%TEMP%\easypass-tray.log` | —（走 stderr / journal） |

`daemon.json` 字段（`lib/core_service/core_info.dart`）：

```jsonc
{
  "port": 47820,                 // 核心监听端口
  "token": "<32B hex>",          // 连接凭据（永不上线，只用于 HMAC 证明）
  "protocolVersion": 5,
  "pid": 1234,
  "coreVersion": "3.0.0",        // 2.4.x 的文件没有这个字段
  "exe": "C:\\...\\core\\easypass_core.exe"   // 安全终止旧核心时的镜像校验依据
}
```

---

## 7. 构建与打包

### 7.1 一条命令（Windows）

```powershell
flutter build windows
```

`windows/runner/CMakeLists.txt` 有三个 POST_BUILD：

1. `browser_extension/native_host/build_bridge.bat` —— 编 x86 桥（cl.exe，不调 MSBuild）
2. `installer/copy_vc_runtime.bat` —— 拷 app-local MSVC 运行时
3. `tool/build_core.ps1` —— `dart build cli` 编核心并摊平到 `core\` + `lib\`

跳过核心构建：`flutter build windows -- -DEASYPASS_SKIP_CORE_BUILD=ON`。

### 7.2 核心单独构建

```powershell
pwsh -File tool\build_core.ps1 [-OutDir build\windows\x64\runner\Release]
```

**必须用 `dart build cli`，不能用 `dart compile exe`**：后者报
`'dart compile' does not support build hooks`（依赖图含 `sqlite3` / `objective_c` 的
build hook）。产物布局：`<OutDir>/core/easypass_core[.exe]` + `<OutDir>/lib/sqlite3.dll`。

### 7.3 已知构建坑

| 症状 | 真因 | 处理 |
| --- | --- | --- |
| `Building native assets failed` | `package:sqlite3` 的 hook 从 GitHub 下载预编译 dll，代理未开（`errno 121`） | 开代理重试；诊断用 `flutter assemble … debug_bundle_windows-x64_assets` |
| `MSB3073` | 有 `easypass.exe` 或 `easypass_core.exe` 在跑，锁着 Release 目录的文件 | 先 `--shutdown` / 杀进程 |
| ISCC 找不到 `sqlite3.dll` | `.iss` 的 `Source` 路径少一层 `Release`（已修，现用 `{#ReleaseDir}`） | 见 §9.2 |
| ISCC `Syntax error` | `[Code]` 段里用 `{ }` 当注释（Inno 的 `{` 是常量展开符） | 用 `(* *)` 或 `//` |

### 7.4 打包

```powershell
& "C:\Program Files\Inno Setup 7\ISCC.exe" installer\easypass_setup.iss
```
产物 `build\installer\EasypassSetup.exe`；发布前用
`node installer/release/collect_artifacts.mjs` 生成 `SHA256SUMS.txt` + 清单。

---

## 8. 安全边界（重要：不要过度承诺）

### 8.1 能防什么

- **链路无明文**：UI ↔ 核心的握手令牌不上线，全部业务帧加密认证；被动抓包拿不到密码。
- **无令牌者连不上**：客户端必须证明知道令牌（`clientProof`）。
- **冒充核心会被识破**：客户端校验 `serverProof`，端口被别的进程抢占时直接失败。
- **篡改会被拒**：encrypt-then-MAC，逐字节改动都会被拒（`test/secure_channel_test.dart`
  对前 40 字节逐个翻转验证）。
- **旧协议不降级**：v5 核心对 v4 及更旧客户端回 `unsupported`，绝不退回明文。

### 8.2 不能防什么（必须如实告知用户）

- **同用户的恶意进程**。它能读 `daemon.json` 拿到令牌，从而连上核心；而且 UI 本来就要
  显示明文密码。**真正的安全边界是"同一用户账户"**，不是密码学。
- **内存取证 / 调试器**附加到核心或 UI 进程。
- **x86 桥 ↔ 核心这一段仍是明文 + 令牌**（32 位 stdio 限制，见 §1）。它与核心之间是
  本机回环 + 令牌认证，属于**已知的、有意的**信任边界；扩展侧拿到的本来就是明文密码。

### 8.3 陈旧核心为什么"只删文件不盲杀"

升级时可能遇到 2.4.x 的 `easypass.exe --service` 进程。它写的 `daemon.json` **没有 `exe`
字段**，我们无法把 pid 与"确实是我们自己的镜像"对上——盲杀 pid 有误杀风险。因此
`CoreSession` 只删除发现文件并拉起新核心：

- 旧进程会 10 分钟空闲自退；
- 它的 `_removeInfoIfOurs` 校验 port+pid，不会删掉新核心的注册信息；
- 安装包升级时 Inno 的 CloseApplications 会先请它关闭。

代价：最多 10 分钟内两个进程并发访问同一 SQLite（SQLite 能扛，不损坏数据）。

---

## 9. 测试与门禁

### 9.1 门禁（agent 交付前必须全绿）

```powershell
flutter analyze --no-pub                 # 目标 0 issue
flutter test --no-pub                    # 578 通过 / 3 跳过（Windows）
cmd /c windows\runner\check_syntax.bat   # 改过 windows/runner/** 必跑
cmd /c windows\runner\check_integrity.bat
node browser_extension/tools/check_extension.mjs
node browser_extension/tools/smoke_content.mjs    # + smoke_popup / smoke_popup_extra
node browser_extension/tools/build_extension_zip.mjs --dry-run   # 扩展包到期时
```

### 9.2 探针（不依赖浏览器/UI）

| 探针 | 验什么 | 用法 |
| --- | --- | --- |
| `tool/probe_core.dart` | 核心 19 项动作面（会话/条目/搜索/TOTP/健康/锁定） | `dart run tool\probe_core.dart --core <核心路径>`（**只跑空库**） |
| `tool/probe_channel_security.dart` | 通道无明文、令牌不上线、旧协议被拒、错误令牌被拒（11 项） | 同上 `--core <路径>` |
| `browser_extension/tools/probe_bridge.mjs` | 端到端：桥 → 核心 | `node …`（可用 `EASYPASS_BRIDGE` 指定桥路径） |
| `browser_extension/tools/probe_daemon.mjs` | 直连已运行的核心 | 同上 |

### 9.3 测试分层

- **UI 层**：注入假 `VaultApi`（`test/fake_vault_api.dart`），**不构造内存数据库**。
- **核心侧数据层**：`AppDatabase.forTesting()`（内存 drift）+ `FakeSecureStorage`；
  轮换/加密真实路径由 `test/core_actions_harness.dart` 驱动真实 `CoreActions`。
- **架构守卫**：`test/architecture_boundary_test.dart` 三条规则（见 §10）。
- **通道**：`test/secure_channel_test.dart`（加解密往返、篡改、方向隔离、密钥派生）。
- **发现文件**：`test/core_info_test.dart`（含"协议 4 ⇒ 陈旧"的升级判定）。

---

## 10. 架构守卫（不可违反的依赖方向）

`test/architecture_boundary_test.dart` 强制三条：

1. `lib/features/**` **不得** import `package:drift/`、`package:sqlite3`、`data/database/`、
   `data/repositories/`、`data/state/session_key.dart`；
   且 `features/{vault,auth,health,generator}/**` **不得** import `flutter_secure_storage`。
2. `lib/client/**` 不得 import `data/database/`、`data/repositories/`（客户端只能经协议说话）。
3. `lib/core_service/**` **不得** import 任何 `package:flutter/`、`flutter_riverpod`、
   `flutter_secure_storage` —— 这是"核心能脱离 Flutter 编译"的前提，破了 `dart build cli` 立刻失败。

依赖方向：`features` → `client` → `protocol`；`core_service` → `data`/`core`/`protocol`；
`data`/`core` 不得 import `features`。

---

## 11. 术语表

| 术语 | 含义 |
| --- | --- |
| **核心 / core** | `easypass_core` 进程，唯一持有库与密钥 |
| **UI / 客户端** | `easypass.exe`，纯客户端 |
| **桥 / bridge** | 浏览器 native messaging 宿主（Windows x86 exe；Linux 核心的 `--bridge` 模式） |
| **会话域** | 核心内的 `ui` / `bridge` 两套独立会话（+ 预留 `agent`） |
| **发现文件** | `daemon.json`，告诉客户端核心在哪、用哪个令牌 |
| **布局/凭证** | 令牌只在 `daemon.json` 与两端内存中，不上线 |
| **锁定（lock）** | 清除会话密钥；`ui` 域调用会连带锁 `bridge` 域 |
| **陈旧核心** | `protocolVersion` 低于当前的核心（升级前的旧 daemon） |

---

## 12. 变更记录

| 日期 | 变更 |
| --- | --- |
| 3.0.0 | 核心服务化：独立核心进程、UI 变纯客户端、协议 5（通道加密）、密钥材料入库、关窗即锁、UI 单实例 |
| 2.4.0 | 原子主密码轮换、Bitwarden 导入导出、CI/发布工程化 |
| 2.3.x | 四种条目类型、自定义字段、文件夹管理、搜索前缀；2.3.3 加 Linux 桌面端 |

---

## 13. 如何让本文档入库 + 一致性检查

**入库**：`docs/` 在 `.gitignore:14` 里被整体忽略。若要把技术规范/API 规范纳入版本控制，
二选一：

- 逐文件强制：`git add -f docs/technical-spec.md docs/protocol-api.md`
- 改忽略规则（**需要你确认**）：在 `.gitignore` 里改成
  `docs/*` + 用 `!docs/technical-spec.md` / `!docs/protocol-api.md` 反向放行，
  同时保留 `Plan.md` / `HANDOFF.md` / `release-*.md` 的本地属性。

> ⚠️ 按你的既定偏好（"项目知识写进仓库文档"），**这两份规范建议入库**；
> 发布说明与验收清单按仓库既有惯例保持本地。

**一致性检查**（改代码后跑一遍，把结果与本文对照）：

```powershell
# 常量
Select-String lib\core\constants\app_constants.dart -Pattern 'pbkdf2|aesIv|bridgeProtocolVersion|coreVersion|coreFixedPort'
# 动作规模（应为 ui=27 / bridge=10）
$t = Get-Content -Raw lib\protocol\actions.dart
[regex]::Matches($t,'(?s)bridgeAllowed = \{(.*?)\};')[0].Groups[1].Value.Split(',').Where({$_.Trim()}).Count
[regex]::Matches($t,'(?s)uiAllowed = \{(.*?)\};')[0].Groups[1].Value.Split(',').Where({$_.Trim()}).Count
# 事件与主题
Select-String lib\protocol\events.dart -Pattern "static const String \w+ = '"
```

