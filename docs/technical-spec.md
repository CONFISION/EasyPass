# EasyPass 技术规范（核心服务架构，3.1.0）

> **入库文档**（`.gitignore` 反向规则放行）。本文描述**当前代码**（版本 3.1.0、schema 5）。
>
> 阅读顺序建议：`AGENTS.md`（仓库约定）→ **本文**（系统怎么运转）→
> `docs/protocol-api.md`（对外接口契约）→ `docs/data-model.md`（数据模型）。
>
> 文中每个数字/常量都取自代码；**改动代码后请同步本文**（一致性检查见 §13）。

---

## 1. 系统组成

EasyPass 由**四个可执行形态**与一个数据库组成。核心设计：**密码库只有一个所有者**——
独立的常驻核心进程；其余一切都是它的客户端。

| 形态 | 可执行文件 | 职责 | 有窗口 | 有托盘 | 生命周期 |
| --- | --- | --- | --- | --- | --- |
| **核心服务** | `{app}\core\easypass_core.exe --serve` | 独占 `easypass.db`、持有唯一会话密钥、执行加解密与策略、向客户端推事件 | ❌ | ❌ | **常驻**，只有 `shutdownCore` / `--shutdown` 退出 |
| **桌面 UI** | `{app}\easypass.exe` | 纯客户端：窗口、托盘、渲染；自己不开库、不持密钥 | ✅ | ✅（唯一） | 用户开关 |
| **x86 桥** | `{app}\easypass_native_host.exe`（仅 Windows） | 浏览器 stdio ↔ 核心的回环 TCP 字节转发 | ❌ | ❌ | 浏览器连接期间 |
| **Dart 桥** | `easypass_core --bridge` | 同上，但由核心二进制自带转发模式（stdio ↔ 回环 TCP） | ❌ | ❌ | 浏览器连接期间 |
| **数据库** | `{app}\easypass.db` | 加密后的条目 + `vault_meta`（含校验材料与轮换日志） | — | — | 由核心独占打开 |

**为什么 x86 桥在 Windows 上不能省**：浏览器原生消息宿主必须是 32 位控制台程序
（32 位 Edge 拉起 64 位宿主时 stdio 句柄不是管道，实测 `FILE_TYPE_CHAR`，
见 `browser_extension/native_host/easypass_native_host.cpp` 顶部注释）；Dart AOT 出不了 ia32。
桥因此只做**字节转发**，不理解协议内容。

**为什么核心放在 `{app}\core\` 子目录**：`package:sqlite3` 的 build hook 按
`<exe 目录>\..\lib\<name>` 解析原生库（Dart 3.13.4 实测；放在 exe 旁边的 `sqlite3.dll`
永远不会被加载）。核心进 `core\` 后，这个相对路径正好落在 `{app}\lib\`，
**一切留在安装目录内**。数据坐标不受影响：`AppPaths` 会检查 exe 的父目录
是否含 `easypass[.exe]`，命中则数据目录取父目录（`lib/core/platform/app_paths.dart`
的 `_resolveDataDirectory`）。

---

## 2. 运行时拓扑

```
┌──────────────────────────────── Windows ─────────────────────────────────┐
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
3. **单实例**：`acquireSingleInstance()`。Windows 在原生层做（`Local\EasyPass.UI` Mutex →
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



> **验证状态**：本表描述的是当前代码的实际行为；2026-10-28 已在 Windows 真机确认
> "核心/界面分离""托盘两档退出""界面单实例""关窗即锁"。不要从本文推断"已验证"，
> 以用户真机验收与 `HANDOFF.md` 的当前状态为准。

### 3.4 核心自身

- **无空闲自退**：常驻直到显式停机。
- **启动顺序（UI 就绪相关）**：`refreshAuthMaterial()` → `_listen()`（绑定端口并写
  `daemon.json`）→ **后台** `pruneAgentAudit()`。审计裁剪是旁路维护，必须 `unawaited`；
  实测 500k 行 prune ≈570ms，若挡在 `_listen` 之前会把核心就绪拖到 728ms（后置后 168ms）。
  新增启动期维护任务一律后置，不能挡 daemon.json 写出。
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

**存库内**（`vault_meta`，键前缀 `secret.`，见
`lib/core/storage/vault_meta_secret_store.dart`），不依赖系统钥匙串。

为什么可以放库文件：推导密钥与比对哈希是同一次 PBKDF2（拿到库文件的人本来就能以
同样代价穷举），而轮换日志（`rotation.pending`）本来就在这张表里；收益是核心彻底摆脱
Flutter 插件，且校验材料与轮换日志同处一个 SQLite 事务域。

**迁移**：升级后首次打开 UI 时，`AuthNotifier` 读旧钥匙串
（`easypass_master_key_salt` / `easypass_master_pw_hash`），调 `adoptLegacyKeyMaterial`
一次性交给核心；核心**仅在 `auth.*` 不存在时**接受。**旧钥匙串值不删除**（便于回退旧版本）。
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

| 项 | 路径 |
| --- | --- |
| 数据目录 | `{app}`（exe 目录；核心在 `core\` 时取父目录） |
| 数据库 | `{app}\easypass.db` |
| 发现文件 | `%LOCALAPPDATA%\EasyPass\daemon.json` |
| 核心 exe | `{app}\core\easypass_core.exe` |
| 核心原生库 | `{app}\lib\sqlite3.dll` |
| UI 原生库 | `{app}\sqlite3.dll`（Flutter 自带，与核心那份互不影响） |
| 权限 | `%LOCALAPPDATA%` 的 ACL | 数据目录 `0700`、库/临时文件 `0600`、wrapper `0700` |
| 调试日志 | `%TEMP%\easypass-tray.log` | —（走 stderr / journal） |

`daemon.json` 字段（`lib/core_service/core_info.dart`）：

```jsonc
{
  "port": 47820,                 // 核心监听端口
  "token": "<32B hex>",          // 连接凭据（永不上线，只用于 HMAC 证明）
  "protocolVersion": 5,
  "pid": 1234,
  "coreVersion": "3.1.0",        // 旧版本文件没有这个字段
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

- **打包字体是子集**：`assets/fonts/MapleMono-NF-CN-*.ttf` 已裁成 GB2312 全量 + App UI 文案字符 +
  基础拉丁/标点（单字重 **5.17MB**，两字重合计 **10.3MB**；完整原版每字重 19.7MB，在 git 历史里）。
  GB2312 之外的生僻字/繁体由系统字体**逐字回退**（可读，字形不同）。重新生成：
  `python tool/subset_fonts.py --source-dir <含完整字体的目录>`（需 `pip install fonttools`；
  脚本会校验字族名与"原字体本应覆盖"的字符）。

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
| **桥 / bridge** | 浏览器 native messaging 宿主（Windows 上的独立 x86 exe） |
| **会话域** | 核心内的 `ui` / `bridge` 两套独立会话（+ 预留 `agent`） |
| **发现文件** | `daemon.json`，告诉客户端核心在哪、用哪个令牌 |
| **布局/凭证** | 令牌只在 `daemon.json` 与两端内存中，不上线 |
| **锁定（lock）** | 清除会话密钥；`ui` 域调用会连带锁 `bridge` 域 |
| **陈旧核心** | `protocolVersion` 低于当前的核心（升级前的旧 daemon） |

---

## 12. 智能体接口（MCP，3.1.0）

> 给"要接 AI 智能体"的人看：怎么开、怎么配对、能用什么、边界在哪。
> 设计取舍与威胁模型的完整讨论在本地文档 `docs/agent-mcp-spec.md`（不入库）。

### 12.1 一句话

核心进程内跑一个只监听 `127.0.0.1` 的 MCP 端点（Streamable HTTP）。默认**关闭**；
打开后，被配对过的智能体可以**零介入**读"开放"条目的**元数据**、把字段值直接
送进**系统剪贴板**（明文不进模型上下文），也可以**新建 / 修改 / 删除条目** ——
其中"删除"只是移入**回收站**，且敏感操作在方式 1 下都要用户逐次同意。

### 12.2 打开总开关

1. 解锁保险库（UI 域）。
2. 设置 → **智能体访问** → 打开开关，输入主密码确认。
3. 打开时核心会：
   - 生成一把 256-bit **专属密钥**，用 Windows DPAPI 加密存到
     `<数据目录>\agent.key.dpapi`；
   - 用它**包裹**一份保险库密钥，存进库的 `vault_meta.agent.wrap`；
   - 解锁 **agent 会话域**（与 ui / bridge 三个域互相独立）；
   - 启动 MCP 端点，端口写进 `daemon.json` 的 `mcpPort`（默认固定 **47821**）。
4. 关掉开关 = 删 DPAPI blob + 删 wrap + 锁 agent 域 + **停掉监听**（端口释放）。

> ⚠️ 开关打开期间，**保险库可以被 EasyPass 自己解锁**（这正是"零介入"的含义），
> 任何以你这个 Windows 账户运行的程序都可能受益。关掉开关即可立刻收回。

### 12.3 配对（生成密钥）

设置 → 智能体访问 → **配对智能体**：

1. 填一个昵称（会出现在审计里，**同名只能有一个**）；
2. 用主密码确认（核心据此把该配对标记为 `trusted`）；
3. 弹出**只显示一次**的密钥卡片（已自动复制）。核心库里只存它的 SHA-256。

**撤销** = 立刻删除该配对记录，那把密钥立即失效（其它配对不受影响）。

**访问方式**（配对卡片右侧菜单可切换）：

| 方式 | 行为 | 切换代价 |
| --- | --- | --- |
| `trusted`（可信直通，配对时默认） | 不弹窗，每次访问都写审计 | 需要主密码确认 |
| `approval`（每次询问） | **每次调用都弹窗**，写明昵称/操作/条目；可勾「本会话内允许读取」 | 不需要，但会立刻锁掉 agent 会话域 |

- 方式 1 的「本会话内允许读取」**只对普通读生效**；敏感读（复制到剪贴板）、写、删
  永远每次都要同意 —— 否则它就是绕过审批的后门；
- 写 / 删的弹窗多一行**「详细」**（例如"修改字段：url、password"、"移到回收站（可恢复）"），
  **只列字段名与动作，绝不显示值**（密码不会出现在屏幕上）；
- 审批弹窗挂在应用外壳上，跳到任何页面都会弹出；**关掉弹窗 = 拒绝**；
- 审批超时 45 秒（短于客户端的 `tools/call` 超时）按拒绝处理；
- 核心在没有 UI 可问时直接拒绝（fail closed）。

### 12.4 客户端配置

端点：`http://127.0.0.1:47821/mcp`，认证方式都是 `Authorization: Bearer <密钥>`。
四条硬性要求：只支持 `POST`、**不能带 `Origin` 头**、`Host` 必须是回环地址、
密钥只能放 header（不能放 query）。

**DeepSeek Harness**（`~/.dsh/profiles/desktop/cordis.patch.yml`）：

```yaml
- insert:
    - id: mcp-easypass
      name: "@deepseek-ai/dsh-mcp-client"
      config:
        serverName: easypass
        transport: streamable-http
        url: http://127.0.0.1:47821/mcp
        headers:
          Authorization: "Bearer <密钥>"
        failOnStartupError: false
```

**Claude Code**：

```bash
claude mcp add --transport http easypass http://127.0.0.1:47821/mcp \
  --header "Authorization: Bearer <密钥>"
```

**MiniMax Code**（`~/.minimax/mcp.json`）：`{"type":"streamable-http","url":…,"headers":{…}}`
**Command Code**（`~/.commandcode/mcp.json`）：`{"transport":"http","url":…,"headers":{…}}`

> Claude Desktop **连不上**：它的远程连接器由 Anthropic 云端发起，到不了 `127.0.0.1`；
> 本地配置又只支持 stdio。这是客户端限制，不是 EasyPass 的问题。

### 12.5 工具清单（11 个，静态）

| 工具 | 作用 |
| --- | --- |
| `status` | 配对状态、是否解锁、**开放条目数**、活动窗口 |
| `begin_session` | 开一个批量窗口（`purpose` 必填，TTL 30–1800 秒），窗口内不因空闲被打断 |
| `end_session` | 关闭窗口（**不锁** agent 域，零介入语义） |
| `list_entries` | 条目**元数据**（名称/类型/文件夹/URL/用户名/有无密码/有无 TOTP） |
| `get_entry` | 单条元数据 |
| `create_entry` | 新建 login / secure_note；`password: {"generate": true}` 让核心生成并加密入库，**明文不回传**；secure_note 没有 url / username / password 字段（传了返回 `invalidRequest`，不静默忽略） |
| `update_entry` | 局部更新（没传的字段不动）；只改 login / secure_note 的字段 |
| `delete_entry` | **移入回收站**（软删，可恢复）；智能体**永远不能彻底删除** |
| `list_trash` | 回收站里**对智能体开放**的元数据（带删除时间） |
| `restore_entry` | 从回收站恢复 |
| `copy_to_clipboard` | 把字段值写进**系统剪贴板**，只回 `ok` + 长度，**不返回明文** |

几条硬口径：

- **写 / 删 / 恢复永远逐次审批**（方式 1 下），「本会话内允许读取」只覆盖普通读；
- 智能体新建的条目**默认对智能体开放**（否则它建完就读不到/改不了/删不掉）；
  用户可随时在条目里改成「永久拒绝」收回 —— **开关本身只能由用户改**；
- 写 / 删 / 恢复成功后核心会广播变更主题，**UI 列表实时刷新**（不需要用户手动刷新）；
- **审批前先过硬闸预检**（`AgentAccessPolicy.precheck`）：条目「永久拒绝」/ 越界 / 配对
  失效时**直接拒绝、不弹审批**，同样写一条 `denied` 审计 —— 避免智能体诱导无意义弹窗
  （审批疲劳是社会工程入口）。预检不替代最终判定：审批期间条目开关可能被用户改掉，
  `_gate` 之后仍会再走一次完整 `evaluate`；
- 审批弹窗对写 / 删会多一行「详细」（**只列字段名与动作**，不含任何值）；
- 智能体没有"彻底删除 / 清空回收站"的能力：`delete_entry` 只做软删，
  彻底删除只由用户在 回收站 界面操作；
- **身份信息 / SSH 密钥条目有意不对智能体开放**（产品决定，不是技术限制）：写工具只支持
  login / secure_note，且这两类在条目级开关上默认/建议保持「永久拒绝」；
- TOTP 工具（`totp_code`）**待定**：当前用 `copy_to_clipboard` 的 `field:'totp'` 覆盖；
  用户暂未使用 TOTP，是否单独开工具等有真实需求再定；
- 业务上限：名称 ≤200 字符、备注 ≤100000 字符、单字段 ≤5000 字符、自定义字段 ≤50 个
  （防止一次调用把库撑爆）。

侧边栏 → **智能体活动**（回收站上方；**未开启总开关时该入口隐藏**）：
按时间倒序列出每次访问（昵称 / 工具 / 操作 / 条目 / 结果）。页面是**实时**的
（核心每写一条审计都会推送 `agentAudit` 主题，新记录直接冒出来）。
数据来自 `agent_audit` 表；结果分 `allowed` / `allowed_standing`（本会话免询问放行）×
`denied` / `timeout` / `error`；**界面同样不显示密钥与明文**（表里也没有）。

字段侧：`password` / `totp` / `notes` / `private_key` / `passphrase` / `custom`（配 `customLabel`）。

### 12.6 条目级开关

每个条目有「允许智能体访问：**开放 / 永久拒绝**」，默认**永久拒绝**（存量条目无需迁移）。
开关落在**加密载荷** `EntryPayload.agentAccess` 里，不出现在明文列。
可见位置：条目编辑页（可改）、条目详情页（只读展示）、条目列表（机器人图标标识）。

- 「永久拒绝」是**硬闸**：任何方式、任何 scope 都读不到、复制不了、**也改不了、删不掉**；
- `copy_to_clipboard`、`update_entry`、`delete_entry`、`restore_entry` 同样受它约束。
- 例外仅一条：**智能体自己新建的条目默认开放**（见 §12.5），否则它无法继续管理自己建的东西；
  用户改为「永久拒绝」后立即生效。

### 12.7 回收站（schema 5）

**删除 = 移到回收站**（只写 `password_entries.deleted_at`，密文一个字节都不动）：

- 主界面 → 侧边栏底部**回收站**入口：列表（最近删除在前）、**恢复**、**彻底删除**、**清空回收站**；
- 列表 / 搜索 / 健康报告 / 计数 / 导出**默认全部排除**回收站条目；
- 回收站里的条目**仍会被主密码轮换重新加密**（否则恢复后永久解不开）；
- 彻底删除与清空只存在于 UI 动作面（智能体做不到）；
- 删除时会给一个 SnackBar「已移到回收站 / 撤销」——"删了就没了"是本地密码管理器
  最不该让用户踩的坑。

### 12.8 安全边界（不要过度承诺）

- 专属密钥由 DPAPI 保护：**别的 Windows 用户、拷贝到别的机器都解不开**；
- 配对密钥只是 MCP 的**身份凭据**，不参与任何解包 —— 泄露它不能解密数据库；
- 但**同用户的恶意进程**既读得到 DPAPI blob 也读得到库文件，这是本项目的既有边界；
- 明文只在"核心 → 系统剪贴板"之间移动，**永远不进模型上下文**；
- 写/删只是改了 `deleted_at` 或密文内容，**恢复语义不扩大攻击面**：能写的前提仍是
  "条目开放 + 本次用户同意（或可信配对）"；
- 审计落库在 `agent_audit` 表（schema 4）：只记昵称/工具/条目/结果，**不记密钥、不记明文参数**；
  表保留最近 **1000** 条（核心启动时裁剪）。

### 12.9 常见排障

| 现象 | 原因 |
| --- | --- |
| `denied (notTrusted)` | 配对不是 trusted：撤销后重新配对（配对时会要主密码） |
| `locked` | agent 域没解锁：确认总开关是开的，或重启核心让它自动解封 |
| 连不上 / 401 | `daemon.json` 里没有 `mcpPort`（没开开关），或密钥被撤销 |
| 工具里只有部分条目 | 其余条目是「永久拒绝」 |
| `denied (entryClosed)`（写/删时） | 该条目没有对智能体开放；先去条目编辑页打开开关 |
| `invalidRequest: 在回收站里` | 改 / 删回收站条目；先 `restore_entry` 或者让用户恢复 |
| 端口不是 47821 | 固定端口被占用，退化为临时端口；以 `daemon.json` 为准 |

---

## 13. 文档入库 + 一致性检查

**入库现状**：`docs/*` 在 `.gitignore` 里被整体忽略，但**三份长期规范已用反向规则入库**
（`.gitignore` 的 `!docs/technical-spec.md` / `!docs/protocol-api.md` / `!docs/data-model.md`），
`docs/release-*.md` 也在库内（CI 发布任务要读它）。其余本地文档（`Plan.md`、`HANDOFF.md`、
`docs/agent-mcp-spec.md` 等）保持本地。**新增 docs 文件要么加一条 `!` 例外，要么用 `git add -f`**；
不要为图省事改掉整条忽略规则（会把本地文档一起放出来，需要先确认）。

**一致性检查**（改代码后跑一遍，把结果与本文对照）：

```powershell
# 常量
Select-String lib\core\constants\app_constants.dart -Pattern 'pbkdf2|aesIv|bridgeProtocolVersion|coreVersion|coreFixedPort'
# schema（应为 5）
Select-String lib\data\database\database.dart -Pattern 'schemaVersion => \d'
# 动作规模（应为 ui=43 / bridge=10 / agent=0）
$t = Get-Content -Raw lib\protocol\actions.dart
[regex]::Matches($t,'(?s)bridgeAllowed = \{(.*?)\};')[0].Groups[1].Value.Split(',').Where({$_.Trim()}).Count
[regex]::Matches($t,'(?s)uiAllowed = \{(.*?)\};')[0].Groups[1].Value.Split(',').Where({$_.Trim()}).Count
[regex]::Matches($t,'(?s)agentAllowed = <String>\{(.*?)\};')[0].Groups[1].Value.Split(',').Where({$_.Trim()}).Count
# MCP 工具面（应为 11；工具面版本 2）
Select-String lib\mcp\mcp_tools.dart -Pattern "name: '|agentToolSurfaceVersion ="
# 事件与主题
Select-String lib\protocol\events.dart -Pattern "static const String \w+ = '"
```

