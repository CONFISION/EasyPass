# EasyPass

**English**: [README.md](README.md)

EasyPass 是一款**本地优先的 Windows 密码管理器**，配套 Chrome / Edge 浏览器扩展：保险库加密存放在你自己的电脑上，后台服务让它随时可用，浏览器里一键自动填充。长远目标是做一个**可自部署的 Bitwarden 替代品** —— 同样的便利，但数据不必交给别人的云。

![release](https://img.shields.io/badge/release-2.2.2-blue)
![platform](https://img.shields.io/badge/platform-Windows-0078D6)
![tests](https://img.shields.io/badge/tests-199%20passing-brightgreen)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

> **当前版本：2.2.2** —— 浏览器扩展已端到端可用（自动填充、popup 生成器、TOTP 验证码、复制操作、健康概览、解锁一次即可持续使用），桌面端界面也做了一轮精简：侧边栏占满窗口全高且品牌只出现一次、新增按钮改为纯图标、原生强制 900×600 的最小窗口尺寸。

---

## 为什么选择 EasyPass？

- **数据始终在你自己的设备上。** 保险库就是一个本地 SQLite 文件，字段级 AES-256-CBC 加密，主密码从不落盘。没有账号、没有订阅、没有遥测，任何东西都不会被上传。
- **真正的后台服务，而不是一个"关掉就死"的应用。** 从 2.0 起，保险库核心以守护进程运行、随登录启动，浏览器扩展通过仅限本机的通道访问它。关闭窗口只是收进托盘，扩展照常工作。
- **自动填充不打扰页面。** 只有页面确实存在**可见的密码输入框**时才会注入图标；绝不往网页里插主密码输入框；只在你点击时才读取凭据。
- **密钥不出桌面进程。** TOTP 密钥不会下发到浏览器 —— 由守护进程算出 6 位验证码，只把验证码交给扩展。
- **完全开源、可审计。** 加密、存储、桥接协议与扩展代码都在本仓库里。
- **不需要管理员权限。** 安装包是单用户安装，落在你自己的 `%LOCALAPPDATA%` 下。

**北极星**：做一个本地优先、可自部署的 Bitwarden 替代品。目前 EasyPass 有意保持"纯本地"（没有服务器、没有同步）；自部署同步服务是路线图上最重要的一项。

## 功能

### 保险库（桌面端）

- 主密码保护：PBKDF2-HMAC-SHA256 迭代 100,000 次派生出 AES-256 密钥（密钥 32 字节、盐 32 字节），主密码本身绝不存储
- 条目包含名称、网址、用户名、密码、备注、TOTP 密钥、收藏标记与所属文件夹；所有敏感字段写入 SQLite 前都经 AES-256-CBC 加密
- 文件夹、收藏、即时搜索
- 密码生成器（长度 4–64，大写/小写/数字/符号可选），新建条目时自动预填一个强密码
- 自动锁定可选 1 / 3 / 5 / 15 / 30 分钟（默认 5 分钟）；修改主密码会整库重新加密
- 密码健康报告：弱密码（少于 12 位、仅单一字符类型、或命中常见弱密码表）、重复使用的密码、缺少两步验证、缺少网址，给出 0–100 评分（≥80 良好、≥50 一般）

### 浏览器扩展（Chrome MV3 / Edge）

- **自动填充**：页面有密码框时，在**输入框内部**注入一个 EasyPass 小锁图标。点击后先判断保险库状态，再按**域名**匹配条目：命中一条直接填充，命中多条弹出扩展自己的选择列表；无匹配与"保险库已锁定"都会用气泡说明，而不是点了没反应
- 兼容 React / Vue / Angular 受控组件（原生 setter + `input`/`change` 事件）、open shadow root、iframe（所有 frame）以及 SPA 路由切换
- **popup 三个标签页**：
  - *密码库* —— 搜索（200ms 防抖）、点条目行即填充、复制用户名 / 密码 / 网址、显示与隐藏密码、查看带 1 秒倒计时的 TOTP 验证码（可复制）、条目计数
  - *生成器* —— 长度 8–64 与字符类型可选，调用桌面端的生成逻辑；保险库锁定时依然可用
  - *健康* —— 健康评分与四类问题计数
- 顶部有状态指示灯与**锁定**按钮
- **解锁一次即可**：会话保存在守护进程内存中，关掉 popup 或重启浏览器都不必重新输入主密码。它会在空闲超时、在 popup 点「锁定」、或锁定桌面端时立即清除
- 扩展绝不往网页注入主密码输入框、绝不把凭据写进 `chrome.storage`，且只在你点击时才读取

### 桌面端与系统集成

- 后台守护进程（`easypass.exe --service`）：无窗口运行，由原生消息桥接按需冷启动，空闲 10 分钟后自行退出
- 托盘图标：关闭窗口是隐藏而非退出；左键恢复窗口，右键提供 *Open EasyPass* / *Exit*
- 登录时自启（HKCU Run 键），安装时可勾选
- 架构：浏览器 → `easypass_native_host.exe`（x86 桥接）→ 带随机令牌握手的 loopback TCP → 守护进程 → 加密 SQLite
- 中英双语界面（跟随系统，可在设置里手动切换）、内置字体、深色主题、常驻侧边栏、最小窗口 900×600

## 与同类对比

以下如实反映 EasyPass 目前的水平。"规划中"指在路线图上，不代表已经可用。

| | **EasyPass 2.2.2** | **Bitwarden + Vaultwarden** | **KeePassXC** |
|---|---|---|---|
| 数据存放 | 你的电脑（加密 SQLite） | 你的服务器（Vaultwarden）或 Bitwarden 云端 | 你的电脑（加密 `.kdbx` 文件） |
| 是否需要服务器 | 不需要 | 自部署需要 | 不需要 |
| 浏览器自动填充 | 支持（Chrome / Edge） | 支持（主流浏览器全覆盖） | 支持（KeePassXC-Browser） |
| 多设备同步 | **无** —— *规划于 3.0* | 支持 | 仅靠你自己同步文件 |
| 移动端 | **无** —— *规划中* | 支持 | 有第三方兼容客户端（非 KeePassXC 本体） |
| 分享 / 组织 | **无** —— *规划中* | 支持 | 无 |
| 自部署难度 | 暂不适用（还没有服务端） | Vaultwarden：低（单个 Docker 容器） | 不适用（基于文件） |
| 许可证 | GPL-3.0 | Bitwarden 客户端：GPL-3.0；Vaultwarden 服务端：AGPL-3.0 | GPL-2.0/3.0 |

EasyPass 目前的优势：单机用户想要原生 Windows 应用、想要为浏览器自动填充服务的常驻后台服务、并且不想引入服务器、账号或订阅。明显的短板：一切与多设备相关的场景。

## 安装

### 方式一：下载安装包（Windows 用户推荐）

从本仓库的 [Releases](https://github.com/CONFISION/EasyPass/releases) 页面下载 `EasypassSetup.exe`。如果尚未发布 Release，请按方式二自行构建 —— 构建产物就是同一个安装包。

- 单用户安装到 `%LOCALAPPDATA%\Programs\EasyPass`，**无需管理员权限**
- 已内置 VC++ 运行时与 x86 原生消息桥接
- 会为 Chrome 与 Edge 注册浏览器主机（64 位与 32 位注册表视图都写），并可选择开机自启
- ⚠️ **安装包尚未做代码签名**，因此 Windows SmartScreen 可能提示"未知发布者"。如果你信任该构建，选择*更多信息 → 仍要运行*；也可以按方式二自行构建。

### 方式二：从源码构建

**前置要求**

| 依赖 | 版本 / 说明 |
|---|---|
| Windows | 10 或 11，64 位 |
| Git | 任意较新版本 |
| Flutter SDK | stable 渠道，且 Dart SDK 满足 `^3.12.2`，需在 `PATH` 中 |
| Visual Studio | 2022 或更新版本，需勾选 **「使用 C++ 的桌面开发」** 工作负载（用于构建 Windows runner 与 x86 桥接） |

**步骤**

```powershell
# 1. 克隆仓库
git clone https://github.com/CONFISION/EasyPass.git
cd easypass

# 2. 拉取依赖
flutter pub get

# 3. 构建发布版
#    这一步会通过 POST_BUILD 自动编译 x86 原生消息桥接（easypass_native_host.exe），
#    并把 MSVC 运行时 DLL 拷贝到应用旁边。
flutter build windows
```

产物在 `build\windows\x64\runner\Release\` —— 直接运行其中的 `easypass.exe`，或打包成安装包：

```powershell
# 可选：构建单用户安装包（需要 Inno Setup 7）
& "C:\Program Files\Inno Setup 7\ISCC.exe" installer\easypass_setup.iss
# 产物：build\installer\EasypassSetup.exe
```

> 生成文件（`database.g.dart`、`app_localizations*.dart`）已入库，克隆后可直接构建。若修改了 `lib/data/database/tables.drift`，需执行 `dart run build_runner build --delete-conflicting-outputs`；若修改了 `lib/l10n/*.arb`，需执行 `flutter gen-l10n`。

## 浏览器扩展

扩展位于 `browser_extension/`，仅使用桌面端时不需要它。

1. 先完成上面的构建，确保 `easypass_native_host.exe` 与 `easypass.exe` 在同一目录
2. 注册原生消息主机：
   ```powershell
   powershell -ExecutionPolicy Bypass -File browser_extension/native_host/install_host.ps1
   # 可选：-ExePath "C:\path\to\your\easypass.exe"
   ```
3. 打开 `edge://extensions`（或 `chrome://extensions`），开启**开发者模式**，选择**加载已解压的扩展程序**并指向 `browser_extension/` 文件夹
4. 重启浏览器，确认扩展 ID 为 `hlkbbdlgaocmnjlgpafkimobnkfniike`（由 manifest 的 `key` 字段固定）

**使用方式**：先解锁一次保险库（桌面端或工具栏 popup 均可），然后在任意登录框里点击 EasyPass 小锁图标即可填充。会话会一直在守护进程中保持解锁，直到空闲超时、在 popup 点**锁定**、或锁定桌面端为止。

**排障**

- popup 提示 `Unknown action: …`，说明扩展连上的是**升级后仍在运行的旧守护进程**。请在托盘图标里退出 EasyPass 再重新启动，然后重试。（2.2 起协议带版本协商，能自动识别并接管这类陈旧进程。）
- 想不开浏览器就判断问题出在哪一层：
  ```bash
  node browser_extension/tools/probe_bridge.mjs   # 端到端：桥接 + 守护进程 + 协议
  node browser_extension/tools/probe_daemon.mjs   # 直连已在运行的守护进程
  ```
  链路正常时 `getStatus` 会正常应答；返回 `Vault is locked` 说明链路没问题，只是保险库锁着。
- 注入图标只出现在有可见密码框的页面上，因此 `chrome://` 页面、扩展商店、PDF 查看器都不会被注入 —— 在这些页面请使用 popup（会退化为复制密码）。

## 开发与测试

```bash
flutter analyze                  # 静态分析（flutter_lints）
flutter test                     # 199 个单元/集成测试：加密、TOTP、生成器、导入导出、
                                 # 认证、守护进程、桥接、会话、域名匹配，以及桌面 widget 测试
```

扩展侧自检（无需浏览器）：

```bash
node browser_extension/tools/check_extension.mjs    # 语法、i18n 键、manifest、协议动作覆盖、版本号一致性
node browser_extension/tools/smoke_popup.mjs        # 用 jsdom 真跑 popup（21 项断言）
node browser_extension/tools/smoke_popup_extra.mjs  # 锁定失败路径、无障碍、DOM 契约（55 项）
node browser_extension/tools/smoke_content.mjs      # 用 jsdom 在假登录页上真跑内容脚本（15 项）
```

两个 smoke 脚本需要 `jsdom`（仅开发期，装在仓库之外）：

```powershell
cd %TEMP%; mkdir easypass-smoke; cd easypass-smoke; npm i jsdom
```

Windows runner 的 C++ 代码可以不做完整构建就做语法检查：

```powershell
cmd /c windows\runner\check_syntax.bat   # 用与真实构建相同的开关执行 cl /Zs
```

参与贡献前请先阅读 [AGENTS.md](AGENTS.md) —— 其中写明了构建分工、版本号同步规则与编码约定。

## 数据与安全模型

- **保险库数据库** —— `easypass.db`，存放在**可执行文件同目录**（安装目录，或源码构建的 `build\windows\x64\runner\Release\`）。备份方式：设置 → 导出，或直接复制该文件。
- **主密码状态与偏好设置** —— `%APPDATA%\easypass.com\easypass\`，在 Windows 上由 DPAPI 保护：用于解锁校验的盐值与主密码哈希，以及应用设置。
- **加密方案** —— 由主密码经 PBKDF2-HMAC-SHA256（100,000 次迭代）派生出 AES-256 密钥；敏感字段使用 AES-256-CBC 加密（`IV || 密文`，base64）。主密码绝不写入磁盘，派生密钥仅存在于内存。
- **浏览器会话** —— 从扩展解锁时会重新派生密钥，且只保存在守护进程内存中；空闲超时、在 popup 点锁定、以及锁定桌面端时都会立即清除。
- **TOTP 密钥不进浏览器** —— 守护进程解密密钥、算出 6 位验证码，只把验证码发出去；条目对扩展只暴露 `hasTotp` 布尔值。
- **仅限本机通道** —— 凭据通过 loopback TCP 传输，并由每次守护进程启动时随机生成的令牌守卫；端口与令牌存放于 `%LOCALAPPDATA%\EasyPass\daemon.json`（仅当前用户可写的目录）。
- **数据不会离开你的设备。** 本版本没有任何服务端组件、账号体系或遥测。

## 路线图

**2.3 —— 分发。** 把扩展发布到 Chrome 应用商店与 Edge 加载项，不再需要"加载已解压的扩展程序"。

**3.0 —— 自部署同步。** 提供服务端组件（可用 Docker 部署），包含账号、设备配对与组织密钥体系，让同一个客户端具备多设备同步与分享能力 —— 这一步才真正把 EasyPass 变成你自己托管的 Bitwarden 替代品。

**3.0 之后（未排期）。** Bitwarden / Vaultwarden 导入导出兼容；附件；通行密钥（passkeys）；以 Android 为优先的移动端；macOS 与 Linux 桌面版；紧急访问；支持 Argon2id 密钥派生；代码签名与 CI。

## 已知限制

- **仅支持 Windows** —— 尚无 macOS、Linux 或移动端客户端
- **没有云同步** —— 一个保险库对应一台机器，目前唯一的"同步"方式是手动拷贝数据库文件
- **扩展尚未上架**任何商店，只能以开发者模式加载
- **安装包未做代码签名**，SmartScreen 会提示未知发布者
- **没有 CI** —— `flutter analyze`、`flutter test` 与扩展自检都是手动执行
- 两步式登录（先用户名页、后密码页）只会在真正出现密码框的那一步填充；非 `<input>` 的自绘密码控件与 closed shadow root 不支持
- 暂无分享、组织、附件与通行密钥
- 扩展的健康标签页是只读的：能报告问题，但不能跳转到桌面端对应条目

## 许可证

EasyPass 以 **GNU General Public License v3.0** 发布，完整许可证文本见仓库根目录的 [`LICENSE`](LICENSE) 文件。

一句话概括：你可以自由使用、研究、修改、自行部署与再分发 EasyPass，但衍生作品必须以同样的许可证开源。

## 致谢

EasyPass 站在别人的工作上：桌面端基于 [Flutter](https://flutter.dev)，存储使用 [drift](https://drift.simonbinder.eu) 与 SQLite，配色取自 [Catppuccin](https://catppuccin.com)，安装包由 [Inno Setup](https://jrsoftware.org/isinfo.php) 构建，中文界面内置了 Maple Mono NF CN 字体。
