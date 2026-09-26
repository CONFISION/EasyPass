# EasyPass

**English**: [README.md](README.md)

一款**本地优先的 Windows 密码管理器**，配套 Chrome / Edge 扩展：保险库加密存放在你自己的电脑上，后台服务让它随时可用，浏览器里一键自动填充。长远目标是做一个**可自部署的 Bitwarden 替代品** —— 同样的便利，但数据不必交给别人的云。

![release](https://img.shields.io/badge/release-2.3.2-blue)
![platform](https://img.shields.io/badge/platform-Windows-0078D6)
![tests](https://img.shields.io/badge/tests-412%20passing-brightgreen)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

> **当前版本 2.3.2** —— 保险库支持**四种条目类型**（登录 / 安全笔记 / 身份信息 / SSH 密钥）与自定义字段；详情页直接显示滚动的 TOTP 验证码；文件夹可新建、重命名、换图标、删除；编辑之后界面立刻更新。2.3.1 / 2.3.2 修掉了真机使用中暴露的问题：文件夹下拉只显示第一个文件夹、编辑后界面不刷新、文件夹的重命名与删除只藏在长按手势里。

---

## 为什么选择 EasyPass？

- **数据只在你的设备上。** 保险库是本机 SQLite 文件，所有敏感字段用主密码派生出的密钥做 AES-256-CBC 加密，主密码本身绝不存储。没有账号、没有服务端、没有遥测。
- **是真正的后台服务，不是一个被冻住的应用。** 自 2.0 起保险库核心以无窗口守护进程运行（`easypass.exe --service`），扩展通过本地桥接与它通信 —— 不开界面也能自动填充。
- **自动填充尊重页面。** 页面上没有可见密码框就绝不注入任何东西；扩展绝不往网页里要主密码；参与填充的**只有登录条目**。
- **机密留在桌面进程里。** TOTP 密钥由守护进程解密并计算出 6 位码，浏览器只拿到验证码本身。
- **不只是登录。** 安全笔记、身份证件、SSH 密钥（含指纹解析）都在同一个加密保险库里，且四种类型都支持自定义字段。
- **完全开源可审计。** 加密、存储、桥接协议与扩展全部在本仓库内，许可证 GPL-3.0。
- **不需要管理员权限。** 安装包是单用户安装，落在你自己的 `%LOCALAPPDATA%` 下。

## 功能

### 保险库（桌面端）

- **四种条目类型** —— *登录*、*安全笔记*、*身份信息*（姓名 / 证件号 / 联系方式 / 地址）、*SSH 密钥*（公钥 / 私钥 / 口令 / 指纹），每种类型都支持**自定义字段**（文本 / 隐藏 / 勾选）。
- **加密** —— PBKDF2-HMAC-SHA256（100,000 次迭代）派生出 AES-256-CBC 密钥；派生密钥只在本次会话的内存中，锁定即清除。备份文件使用同一套加密。
- **TOTP 动态码** —— 详情页显示滚动更新的 6 位码 + 倒计时 + 一键复制。密钥本身不以明文显示，也不出进程。
- **SSH 密钥** —— 粘贴 OpenSSH 公钥即自动推导指纹（SHA256 / MD5）、密钥类型、长度与注释；私钥默认打码，显示或复制前需要验证主密码。
- **文件夹** —— 自定义图标、重命名，以及**带检查的删除**：删除仍有条目的文件夹时会告诉你里面有多少条，并且**条目一条都不会删**（它们会移到「无文件夹」）。
- **搜索** —— 即时、大小写不敏感，覆盖名称、备注、身份 / SSH 字段与自定义字段的标签，支持 `type:` / `folder:` / `url:` 前缀。密码、TOTP 密钥、SSH 私钥与隐藏字段值**有意不参与搜索**。
- **列表** —— 每种类型独立图标与徽章，类型筛选可与文件夹、收藏叠加。
- **密码生成器** —— 长度 4–128、字符类型可选，新建条目时自动预填一个强密码。
- **自动锁定** —— 1 / 3 / 5 / 15 / 30 / 60 分钟（默认 5 分钟）；**主题**可跟随系统或固定浅色 / 深色；界面中英双语；内置字体。
- **密码健康报告** —— 弱密码（过短、单一字符类型、常见弱密码）、重复使用、缺少两步验证、缺少网址，给出 0–100 评分，且**只统计登录条目**。
- **导出 / 导入** —— 明文 JSON 供自己查看，加密 JSON 供备份（内部不含任何明文）。格式 2.0.0 带类型与自定义字段，同时仍能导入 1.x 的旧导出（按登录条目处理）。

### 浏览器扩展（Chrome MV3 / Edge）

- **自动填充** —— 页面有密码框时，在**输入框内部**注入 EasyPass 图标。点击后先判断保险库状态，再按**域名**匹配条目（先精确同域，再双向子域），命中一条直接填充，命中多条弹出扩展自己的选择列表；「未匹配」与「保险库已锁定」都会用气泡说明，而不是点了没反应。
- 兼容 React / Vue / Angular 受控组件（原生 setter + `input`/`change` 事件）、open shadow root、iframe（所有 frame）与 SPA 路由切换。
- **popup 三个标签页**：
  - *密码库* —— 搜索（防抖）与类型筛选；填充登录条目，复制用户名 / 密码 / 网址 / TOTP、显示与隐藏密码、复制安全笔记正文、身份信息字段，以及 SSH 公钥 / 指纹 / 私钥（私钥必须显式点击才会复制）。
  - *生成器* —— 长度 8–64 与字符类型可选，调用桌面端生成逻辑；保险库锁定时依然可用。
  - *健康* —— 健康评分与四类问题计数。
- **解锁一次即可** —— 会话保存在守护进程内存中，关掉 popup 或重启浏览器都不必重新输入主密码；空闲超时、在 popup 点「锁定」、或锁定桌面端时立即清除。
- **自动填充只认登录条目** —— 安全笔记、身份信息与 SSH 密钥可以查看和复制，但绝不会出现在填充列表里。

### 桌面与系统集成

- 后台守护进程（`easypass.exe --service`）：无窗口，由 native messaging 桥接按需冷启动，空闲 10 分钟后自行退出。
- 托盘图标：关闭窗口是隐藏而不是退出。
- 登录时自启（HKCU Run 键），安装包中可选。
- 链路：浏览器 → `easypass_native_host.exe`（x86 桥接）→ 带随机令牌握手的回环 TCP → 守护进程 → 加密 SQLite。
- 原生最小窗口 900×600；常驻侧边栏。

## 与同类对比

以下如实反映现状。"规划中"指在路线图上，不代表已经可用。

| | **EasyPass 2.3.2** | **Bitwarden + Vaultwarden** | **KeePassXC** |
|---|---|---|---|
| 数据存放 | 你的电脑（加密 SQLite） | 你的服务器（Vaultwarden）或 Bitwarden 云端 | 你的电脑（加密 `.kdbx`） |
| 是否需要服务器 | 不需要 | 自部署需要 | 不需要 |
| 条目类型 | 登录 / 安全笔记 / 身份信息 / SSH 密钥（+ 自定义字段） | 登录 / 卡片 / 身份 / 笔记 / SSH 密钥 | 登录 / 分组 / 笔记 / 卡片 / 身份 |
| 浏览器自动填充 | 支持（Chrome / Edge） | 支持（主流浏览器全覆盖） | 支持（KeePassXC-Browser） |
| 多设备同步 | **无** —— *规划于 3.0* | 支持 | 仅靠你自己同步文件 |
| 移动端 | **无** —— *规划中* | 支持 | 有第三方兼容客户端（非本体） |
| 分享 / 组织 | **无** —— *规划中* | 支持 | 无 |
| 自部署难度 | 暂不适用（还没有服务端） | Vaultwarden：低（单个容器） | 不适用（基于文件） |
| 许可证 | GPL-3.0 | 客户端 GPL-3.0 / 服务端 AGPL-3.0 | GPL-2.0/3.0 |

EasyPass 现在擅长的是：单机 Windows 用户想要原生应用、真正的后台服务做浏览器自动填充、且不引入服务器与订阅。明显不如别人的是：任何多设备场景。

## 安装

### 方式一 —— 安装包（推荐）

从 Release 页面下载 `EasypassSetup.exe` 直接运行。它是**单用户安装**（不需要管理员），落在 `%LOCALAPPDATA%\Programs\EasyPass`，自带 VC++ 运行时与 x86 native messaging 桥接，会为 Chrome 与 Edge 注册浏览器宿主，并可选开机自启。

> ⚠️ 安装包**尚未代码签名**，SmartScreen 可能提示"未知发布者"。若你手上有校验值，请核对文件的 SHA-256。

### 方式二 —— 从源码构建

| 依赖 | 说明 |
|---|---|
| Windows | 10 或 11，64 位 |
| Flutter SDK | stable 渠道，Dart `^3.12.2`，需在 `PATH` 中 |
| Visual Studio | 2022 及以上，含 **使用 C++ 的桌面开发**（构建 runner 与 x86 桥接） |
| Inno Setup 7 | 仅在需要打包安装包时 |

```powershell
git clone https://github.com/CONFISION/EasyPass.git
cd EasyPass
flutter pub get
flutter build windows        # 同时构建 x86 桥接并拷贝 MSVC 运行时
# → build\windows\x64\runner\Release\easypass.exe

# 可选：打包安装包
& "C:\Program Files\Inno Setup 7\ISCC.exe" installer\easypass_setup.iss
# → build\installer\EasypassSetup.exe
```

只有在改过 schema / 文案后才需要重新生成代码：

```powershell
dart run build_runner build --delete-conflicting-outputs   # 改过 lib/data/database/tables.drift 之后
flutter gen-l10n                                           # 改过 lib/l10n/*.arb 之后
```

> 注意：`drift` / `drift_dev` / `build_runner` 的版本必须与当前 Dart SDK 匹配。analyzer 太旧时
> 代码生成会以 `Missing implementation of visitDotShorthandPropertyAccess` 崩溃且**不产出任何文件**，
> 这三个依赖要一起升（原因写在 `pubspec.yaml` 的注释里）。

## Linux（桌面端，AppImage）

Linux 桌面构建以**单文件 AppImage**发布（另附解包即用的 `.tar.gz`）。它是
Windows 功能集的移植版（见下方发布说明）；Windows 安装包与 `windows/` 源码
未被它改动。

### 三步安装

```bash
chmod +x EasyPass-2.3.2-linux-x86_64.AppImage    # 1. 加执行位
./EasyPass-2.3.2-linux-x86_64.AppImage           # 2. 先运行一次（创建保险库）
./EasyPass-2.3.2-linux-x86_64.AppImage --install # 3. 加入应用菜单
```

> **Ubuntu / 没有 FUSE 2 时的兜底。** 若 AppImage 因缺 `libfuse2` 起不来：要么
> 自行安装（`sudo apt install libfuse2` —— EasyPass 自己绝不会 `sudo`、也
> 不会替你装包），要么用无需 FUSE 的自解包式运行：
>
> ```bash
> ./EasyPass-2.3.2-linux-x86_64.AppImage --appimage-extract-and-run
> ./EasyPass-2.3.2-linux-x86_64.AppImage --appimage-extract-and-run --install
> ```
>
> `.tar.gz` 就是为同一目的准备的：解包后直接跑
> `EasyPass-2.3.2-linux-x86_64/AppRun`。

### 数据目录（XDG）

| 内容 | Linux 路径 |
|---|---|
| 保险库数据库 | `$XDG_DATA_HOME/easypass/easypass.db`（缺省 `~/.local/share/easypass/easypass.db`） |
| 守护进程登记文件 | `$XDG_DATA_HOME/easypass/daemon.json` |
| 浏览器原生宿主 wrapper | `$XDG_DATA_HOME/easypass/easypass-native-host.sh` |
| 桌面入口（`--install` 写入） | `$XDG_DATA_HOME/applications/easypass.desktop` |
| 图标（`--install` 写入） | `$XDG_DATA_HOME/icons/hicolor/1024x1024/apps/easypass.png` |
| 开机自启入口（设置页开关） | `$XDG_CONFIG_HOME/autostart/easypass.desktop`（缺省 `~/.config/autostart/`） |

`$XDG_DATA_HOME` 未设置或为空即 `~/.local/share`（XDG Base Directory 规范）。
数据目录权限为 `0700`、数据库为 `0600` —— 见发布说明第 3 条声明。

**旧布局迁移（复制不删）。** 早期构建把 `easypass.db` 放在*可执行文件旁边*。
Linux 首次启动会把它**复制**到 `$XDG_DATA_HOME/easypass/easypass.db`，
原文件**保留不动**（只复制，绝不移动/删除），随时可以回退到旧构建。

### 桌面集成

```bash
./EasyPass-2.3.2-linux-x86_64.AppImage --install         # 写入桌面入口 + 图标（幂等）
./EasyPass-2.3.2-linux-x86_64.AppImage --desktop-status  # 退出码：0 = 已安装 / 1 = 入口指向失效 / 2 = 未安装
./EasyPass-2.3.2-linux-x86_64.AppImage --uninstall       # 只删自己写的文件，再清空目录
```

`--install` 会把 AppImage 的真实路径（`$APPIMAGE`）写进 `Exec=`，所以之后
**移动了 AppImage 需要重新 `--install`**。

### Linux 上的浏览器扩展

1. 先跑一次宿主安装：`./EasyPass-2.3.2-linux-x86_64.AppImage --install-browser-host`
   （会写 Chrome / Chromium / Brave / Edge 与 Firefox 的 native messaging 
   manifest；`--browser-host-status` 可逐个查看状态），然后加载扩展。
2. **Chrome / Chromium / Brave / Edge** —— 打开 `chrome://extensions`（或对应浏览器
   的扩展页），开启**开发者模式**，选择**加载已解压的扩展程序** → `browser_extension/`。
3. **Firefox** —— 打开 `about:debugging#/runtime/this-firefox`，**临时载入附加组件…**
   → `browser_extension/manifest.json`；再到 `about:addons` → EasyPass →
   **权限**确认已拿到 native messaging 权限。**Firefox 尚未端到端实测** ——
   见下方已知限制。

### 开机自启

设置页开关**「登录时启动 EasyPass」**是唯一的开关：它写入/删除
`$XDG_CONFIG_HOME/autostart/easypass.desktop`，不用其它机制。

### Linux 已知差异与限制

- **GNOME 未装 AppIndicator 扩展**时无法承载托盘图标，EasyPass 降级为
  *关窗即退出应用*，并在设置页给出说明。Ubuntu 默认带该扩展；KDE Plasma 原生支持托盘。
- **Firefox 侧未端到端实测**：manifest 与原生宿主 wrapper 已就位，但对仍期待
  MV3 事件页（而非 `background.service_worker`）的 Firefox 版本，可能还需一份
  变体 manifest。
- **未代码签名**；AppImage 需要 FUSE 2，除非用 `--appimage-extract-and-run` 或 `.tar.gz`。

## 浏览器扩展

安装包会自动注册 native host；在浏览器打开 `chrome://extensions`（或 `edge://extensions`），
打开**开发者模式**，选择**加载已解压的扩展程序** → `browser_extension/`。扩展尚未上架任何商店，所以这一步目前必须手动。

如果 popup 提示「未知操作」或"后台服务版本过旧"，说明旧守护进程还在跑：**完全退出 EasyPass（含托盘）再启动**即可 —— 协议版本 3 会把旧进程换掉。

## 开发与测试

```powershell
flutter analyze --no-pub
flutter test --no-pub                 # 412 个单元 / 集成测试
```

扩展自检（无需浏览器，需要装好 `jsdom`）：

```powershell
node browser_extension/tools/check_extension.mjs   # 语法、i18n 键对齐、协议动作、版本号四处一致
node browser_extension/tools/smoke_content.mjs     # 19 项断言：自动填充行为
node browser_extension/tools/smoke_popup.mjs       # 71 项断言：popup 渲染与操作
node browser_extension/tools/smoke_popup_extra.mjs # 58 项断言：失败路径、无障碍、DOM 契约
```

真机排障：`node browser_extension/tools/probe_daemon.mjs`（直连运行中的守护进程）与
`probe_bridge.mjs`（端到端拉起桥接）能告诉你问题出在守护进程、桥接还是扩展。

`cmd /c windows\runner\check_syntax.bat` 用与真实构建相同的告警开关（`/W4 /WX`）检查
`windows/runner/*.cpp`，不调用 MSBuild、不产出文件。

## 数据与安全模型

- **保险库数据库** —— `easypass.db`，与可执行文件同目录（单用户安装 → 可写，无需管理员权限）。
- **主密码** —— 绝不存储；PBKDF2-HMAC-SHA256（100,000 次迭代、32 字节盐）派生 AES-256-CBC 密钥。只有盐与校验哈希保存在 `flutter_secure_storage`（Windows 上即 DPAPI）。
- **会话** —— 派生密钥仅存在于内存，锁定即清除；浏览器会话密钥由守护进程持有，空闲超时后擦除。
- **加密覆盖** —— 密码、TOTP 密钥、备注、身份 / SSH 字段与自定义字段在写入 SQLite 之前全部加密，明文绝不进库。
- **TOTP 密钥不进浏览器** —— 守护进程算好验证码，只把验证码发出去。
- **仅本地通道** —— 凭据经由带随机令牌的回环 TCP 传输，不发生任何上传。
- **备份** —— 加密导出把整份载荷整体加密；明文导出仅供自己查看，并在界面中明确标注。

## 路线图

**2.4 —— 分发与迁移。** 扩展上架 Chrome 应用商店与 Edge 加载项、Bitwarden / Vaultwarden 导入、GitHub Actions CI、SHA256 校验值与代码签名。

**3.0 —— 自部署同步。** 两层密钥体系（账户密钥 → 用户密钥 → 组织密钥）、可 Docker 部署的服务端、离线优先的同步引擎，然后是分享、组织与紧急访问 —— 这一步才真正把 EasyPass 变成你自己托管的 Bitwarden 替代品。

**更远（未排期）。** 附件、通行密钥（passkeys）、生物识别解锁、SQLCipher 整库加密、卡片类型、Steam Guard TOTP、泄露检测（需显式开启）、命令行客户端、以 Android 为优先的移动端、macOS / Linux、Firefox 扩展。

## 发布说明 / Release notes

### 2.3.2 —— 新增 Linux 桌面支持

本次分支把桌面端带到 Linux：托盘 / 单实例 / 开机自启对齐、XDG 数据目录、
Linux 原生消息宿主、AppImage + `.tar.gz` 产物，以及桌面入口 CLI
（`--install` / `--uninstall` / `--desktop-status`，与 `--install-browser-host`
同套路）。`pubspec.yaml` 版本**有意保持 2.3.2** —— Windows 版本与本构建共用同一版本号。

随移植一并声明三件事：

1. **跨平台错误文案差异（有意）**。新增 CLI 按运行平台说话：Windows 上打印
   *“On Windows, use the EasyPass installer (Inno Setup) …”* 并退出 `0`；Linux 上
   打印真实结果（写入的路径、各浏览器宿主状态）。Linux 专属失败场景（缺 `HOME`、
   `$XDG_DATA_HOME` 不可写）给出自己的文案，而不是 Windows 注册表错误。**Windows
   任何代码路径的行为均未改变。**
2. **数据目录迁移：只复制、不删除**。保险库从*可执行文件同级*迁到
   `$XDG_DATA_HOME/easypass/`（缺省 `~/.local/share/easypass/`）。首次启动会把同级
   的 `easypass.db` **复制**到新位置，原文件保留作回退。
3. **Linux 专属权限**。数据目录 `chmod 0700`、保险库数据库 `0600`、原生宿主
   wrapper `0700`、浏览器宿主 manifest 文件 `0644`（所在目录 `0700`）。这些 POSIX
   位只是 Linux 加固；Windows 保持既有 `%LOCALAPPDATA%` ACL 语义，不受本轮影响。

## 已知限制

- **以 Windows 为主** —— Windows 版本是受支持的发行版；本分支新增了 Linux 桌面
  构建（AppImage / `.tar.gz`），但 macOS、移动端与上架商店的 Firefox 扩展仍不可用。
- **没有同步** —— 一个保险库对应一台机器，唯一"迁移"方式是拷贝数据库文件，且必须在 EasyPass 未运行时拷贝。
- **扩展尚未上架**，必须手动加载已解压的扩展程序。
- **安装包未签名**，SmartScreen 会提示未知发布者。
- **没有 CI** —— `flutter analyze`、`flutter test` 与扩展自检都是手动执行。
- **自动填充的已知缺口** —— 两步式登录（先用户名页、后密码页）只能填到带密码框的那一页；closed shadow root 里的表单内容脚本看不到；部分银行 / 支付类控件可能仍需手动填。
- **尚无生物识别解锁**（设置页入口是占位），桌面端也无法展示扩展会话的剩余时间（那份状态在守护进程里）。
- 暂不支持分享、组织、附件与通行密钥。

## 许可证

GPL-3.0 —— 见 [LICENSE](LICENSE)。

## 致谢

基于 [Flutter](https://flutter.dev)、[drift](https://drift.simonbinder.eu)、
[encrypt](https://pub.dev/packages/encrypt)、[Riverpod](https://riverpod.dev) 与
[go_router](https://pub.dev/packages/go_router) 构建。感谢 Bitwarden 与 Vaultwarden
项目树立了本项目的对标标准。
