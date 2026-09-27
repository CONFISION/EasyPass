# EasyPass

**English**: [README.md](README.md)

**Windows 与 Linux 上的本地优先密码管理器**，配套 Chrome / Edge 扩展：加密保险库就在你自己的
机器上，常驻的后台服务让它随时可用，浏览器里一键自动填充。长期目标是做一个**可自部署的
Bitwarden 替代品** —— 同样的便利，但不把数据交给别人的云。

![release](https://img.shields.io/badge/release-2.3.3-blue)
![platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux-0078D6)
![tests](https://img.shields.io/badge/tests-536%20passing-brightgreen)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

> **当前版本 2.3.3 —— Linux 桌面端移植。** 2.3.3 新增原生 Linux 构建（AppImage）：托盘图标与
> 关闭到托盘、单实例（再次启动会把已有窗口抬到前台）、XDG 开机自启、桌面项命令行
> （`--install` 等）以及浏览器宿主注册；保险库迁移到 `$XDG_DATA_HOME/easypass/`，并施加
> `0700`/`0600` 的 POSIX 权限。同一版本还加固了 Windows runner 的托盘处理。保险库本身沿用
> 2.3.0 的功能集：**四种条目类型**（登录 / 安全笔记 / 身份信息 / SSH 密钥）+ 自定义字段、
> 实时 TOTP 验证码、文件夹管理，以及编辑后立即刷新的界面。

---

## 为什么选择 EasyPass？

- **数据只在自己设备上。** 保险库就是一个本地 SQLite 文件；所有敏感字段用主密码派生的密钥做
  AES-256-CBC 加密，主密码本身**从不保存**。没有账号、没有服务器、没有遥测。
- **真后台服务，而不是"假装常驻"的应用。** 自 2.0 起保险库核心作为无窗口服务运行
  （`easypass.exe --service`），扩展通过本机桥接与它通信 —— 界面没打开也能自动填充。
- **自动填充尊重页面。** 页面里没有可见的密码输入框就绝不注入；扩展永远不会在网页里索要
  主密码；只有**登录类型**的条目会被提供给填充。
- **密钥不出桌面进程。** TOTP 密钥在服务进程里解密并算出 6 位验证码，浏览器只拿得到验证码。
- **不只是登录。** 安全笔记、身份信息、SSH 密钥（含指纹解析）都在同一个加密保险库里，
  每种类型都支持自定义字段。
- **完全开源可审计。** 加密、存储、桥接协议与扩展全部在本仓库，GPL-3.0。
- **不需要管理员权限。** Windows 按用户安装到 `%LOCALAPPDATA%`；Linux 的 AppImage 就是家目录里的
  一个文件 —— 两边都不用 `sudo`。

## 功能

### 保险库（桌面端）

- **四种条目类型** —— *登录*、*安全笔记*、*身份信息*（姓名、证件号、联系方式、地址）、
  *SSH 密钥*（公钥、私钥、口令、指纹），每种之上都能加**自定义字段**（文本 / 隐藏 / 勾选）。
- **加密** —— PBKDF2-HMAC-SHA256（100,000 次迭代）派生 AES-256-CBC 密钥；派生密钥只在会话期内
  驻留内存，锁定时清除。加密备份使用同一套算法。
- **实时 TOTP** —— 详情页显示滚动的 6 位验证码、倒计时与一键复制。密钥本身不以明文展示，
  也不离开进程。
- **SSH 密钥** —— 粘贴 OpenSSH 公钥即可在本地算出指纹（SHA256 + MD5）、密钥类型、长度与注释。
  私钥默认遮蔽，查看或复制前需要重新输入主密码。
- **文件夹** —— 自定义图标、重命名，以及"带护栏的删除"：删除还有条目的文件夹会先告诉你数量，
  并把条目保留下来（归入"无文件夹"），**永远不会连条目一起删掉**。
- **搜索** —— 即时、大小写不敏感，覆盖名称、备注、身份/SSH 字段与自定义字段名；支持
  `type:` / `folder:` / `url:` 前缀。密码、TOTP 密钥、SSH 私钥与隐藏值**故意不可搜索**。
- **列表** —— 按类型显示图标与徽标，类型筛选可与文件夹、收藏叠加。
- **密码生成器** —— 长度 4–128、字符集可调，新建条目时预填一个新生成的建议值。
- **自动锁定** —— 1 / 3 / 5 / 15 / 30 / 60 分钟（默认 5）；**主题**可跟随系统或固定浅色/深色；
  界面支持中文与英文；内置字体。
- **密码健康报告** —— 弱密码（过短、字符集单一、常见密码）、重复使用、未配置两步验证、缺少
  URL，附带 0–100 评分，**只统计登录类型条目**。
- **导出 / 导入** —— 明文 JSON 便于检查，加密 JSON 用于备份（内部无明文）。2.0.0 格式携带类型与
  自定义字段；1.x 的导出仍可作为登录条目导入。

### 浏览器扩展（Chrome MV3 / Edge）

- **自动填充** —— 页面有密码框时会在**输入框内**注入 EasyPass 图标。点击后先查保险库状态，再按
  **域名**匹配（先精确主机名，再双向子域），命中一条直接填充，命中多条弹出扩展自己的选择列表。
  保险库锁定与"无匹配"都会用气泡提示，而不是静默失败。
- 兼容 React/Vue/Angular 受控输入（原生 setter + `input`/`change` 事件）、开放式 shadow root、
  iframe（所有框架）以及 SPA 路由切换。
- **弹窗三个页签**：
  - *保险库* —— 搜索（防抖）与类型筛选；填充登录、复制用户名 / 密码 / URL / TOTP、显示密码，
    复制安全笔记正文、身份信息字段，或 SSH 密钥的公钥 / 指纹 / 私钥（私钥仅在明确点击时复制）。
  - *生成器* —— 长度 8–64 与字符集，复用桌面端生成逻辑；锁定状态下也能用。
  - *健康* —— 总评分与四类问题数量。
- **一次解锁** —— 会话保存在服务进程内存里，关掉弹窗或重启浏览器都不用重新输入主密码；
  空闲超时、点击**锁定**、或在桌面端锁定时立即清除。
- **自动填充只认登录条目** —— 安全笔记、身份信息、SSH 密钥可以查看与复制，但绝不会出现在
  填充列表里。

### 桌面与系统集成

| | Windows | Linux |
|---|---|---|
| 托盘图标 + 关闭到托盘 | `windows/runner`（Win32 `Shell_NotifyIcon`） | `linux/runner`（GTK + libayatana-appindicator） |
| 单实例 | 未实现（无互斥门） | 通过 `easypass.db.lock` 加锁，并用 unix socket 唤醒已在运行的实例，二次启动会把旧窗口抬到前台 |
| 登录自启 | `HKCU\…\Run` 项，安装包内可选 | `$XDG_CONFIG_HOME/autostart/easypass.desktop`，设置页开关 |
| 应用菜单项 | Inno Setup 创建快捷方式 | `--install`（桌面项 + hicolor 图标）、`--desktop-status`、`--uninstall` |
| 浏览器宿主注册 | Inno Setup 写注册表 | `--install-browser-host` 写各浏览器的清单文件 |

- 后台服务（`easypass.exe --service`）：无窗口，由 native messaging 桥接按需冷启动，空闲 10 分钟
  自行退出。
- 链路（Windows）：浏览器 → `easypass_native_host.exe`（x86 桥接）→ 带随机令牌握手的回环 TCP →
  服务进程 → 加密 SQLite。Linux 上的 native messaging 宿主就是主程序自身
  （`easypass --native-host`，由生成的包装脚本启动）。
- 两个平台都在原生层强制最小窗口 900×600，侧边栏宽度固定。

## 安装

### 方式一 —— 安装包（Windows，推荐）

从 releases 页面下载 `EasypassSetup.exe` 运行即可。它**按用户安装**（不需要管理员），装到
`%LOCALAPPDATA%\Programs\EasyPass`，随包带上 VC++ 运行时与 x86 native messaging 桥接，为 Chrome
与 Edge 注册浏览器宿主，并可选择开机自启。

> ⚠️ 安装包**尚未代码签名**，SmartScreen 可能提示"未知发布者"。若你手上有校验值，请核对文件的
> SHA-256。

### 方式二 —— 从源码构建（Windows）

| 依赖 | 说明 |
|---|---|
| Windows | 10 或 11，64 位 |
| Flutter SDK | stable 渠道，Dart `^3.12.2`，在 `PATH` 中 |
| Visual Studio | 2022+，需勾选 **使用 C++ 的桌面开发**（编译 runner 与 x86 桥接） |
| Inno Setup 7 | 仅打包安装包时需要 |

```powershell
git clone https://github.com/CONFISION/EasyPass.git
cd EasyPass
flutter pub get
flutter build windows        # 同时编译 x86 桥接并拷贝 MSVC 运行时
# → build\windows\x64\runner\Release\easypass.exe

# 可选：打包安装包
& "C:\Program Files\Inno Setup 7\ISCC.exe" installer\easypass_setup.iss
# → build\installer\EasypassSetup.exe
```

只有改过 schema 或本地化文件时才需要重新生成代码：

```powershell
dart run build_runner build --delete-conflicting-outputs   # 改过 lib/data/database/tables.drift 后
flutter gen-l10n                                           # 改过 lib/l10n/*.arb 后
```

> 注意：`drift` / `drift_dev` / `build_runner` 的版本必须与当前 Dart SDK 匹配。analyzer 太旧时
> 代码生成会以 `Missing implementation of visitDotShorthandPropertyAccess` 崩溃且**不产出任何文件**，
> 这三个依赖要一起升（原因写在 `pubspec.yaml` 的注释里）。

## Linux（桌面端，AppImage）

Linux 版以**单文件 AppImage** 分发，功能与 Windows 桌面端对齐（保险库、托盘、自启、浏览器宿主）；
Windows 安装包与 `windows/` 源码不受影响。

### 三步安装

```bash
chmod +x EasyPass-2.3.3-linux-x86_64.AppImage    # 1. 赋予可执行权限
./EasyPass-2.3.3-linux-x86_64.AppImage           # 2. 先运行一次（创建保险库）
./EasyPass-2.3.3-linux-x86_64.AppImage --install # 3. 加入应用菜单
```

> **Ubuntu / 没有 FUSE 2 时的兜底。** 若 AppImage 因缺 `libfuse2` 起不来：要么自行安装
> （`sudo apt install libfuse2` —— EasyPass 自己绝不会 `sudo`、也不会替你装包），要么就地解包运行，
> 完全不需要 FUSE：
>
> ```bash
> ./EasyPass-2.3.3-linux-x86_64.AppImage --appimage-extract-and-run
> ./EasyPass-2.3.3-linux-x86_64.AppImage --appimage-extract-and-run --install
> ```

自行构建：先 `flutter build linux --release`，再执行
`installer/appimage/build_appimage.sh <bundle 目录> <输出 AppImage>`；脚本会从 `pubspec.yaml` 读版本号，
需要 `appimagetool`（可用 `$APPIMAGETOOL` 指定其位置）。

### 数据目录（XDG）

| 内容 | Linux 路径 |
|---|---|
| 保险库数据库 | `$XDG_DATA_HOME/easypass/easypass.db`（默认 `~/.local/share/easypass/easypass.db`） |
| 服务注册信息 | `$XDG_DATA_HOME/easypass/daemon.json` |
| native host 包装脚本 | `$XDG_DATA_HOME/easypass/easypass-native-host.sh` |
| 桌面项（`--install` 写入） | `$XDG_DATA_HOME/applications/easypass.desktop` |
| 图标（`--install` 写入） | `$XDG_DATA_HOME/icons/hicolor/1024x1024/apps/easypass.png` |
| 自启项（设置页开关） | `$XDG_CONFIG_HOME/autostart/easypass.desktop`（默认 `~/.config/autostart/`） |

`$XDG_DATA_HOME` 未设置或为空时按 XDG Base Directory 规范取 `~/.local/share`。数据目录权限 `0700`，
数据库 `0600`。

**旧布局迁移。** 早期构建把 `easypass.db` 放在**可执行文件旁边**。Linux 首次启动时会把它**复制**到
`$XDG_DATA_HOME/easypass/easypass.db`，原文件**原地保留**（只复制，绝不移动或删除），所以回退到旧版本
也不会丢数据。

### 桌面集成

```bash
./EasyPass-2.3.3-linux-x86_64.AppImage --install         # 桌面项 + 图标（幂等）
./EasyPass-2.3.3-linux-x86_64.AppImage --desktop-status  # 退出码 0 = 已安装，1 = 指向失效目标，2 = 未安装
./EasyPass-2.3.3-linux-x86_64.AppImage --uninstall       # 只删自己写过的东西，再清理空目录
```

`--install` 会把 AppImage 的真实路径（`$APPIMAGE`）写进 `Exec=`，因此移动 AppImage 之后需要重新安装。

GTK 应用 id 是 `com.easypass.app`（2.3.3 起；更早的构建用的是 Flutter 模板默认值
`com.example.easypass`）。旧版本写入的桌面项因此带着过期的 `StartupWMClass` —— 升级后请重跑一次
`--install`，否则任务栏/程序坞的窗口归类和图标查找会对不上。

### Linux 上的浏览器扩展

1. 先跑一次宿主安装：`./EasyPass-2.3.3-linux-x86_64.AppImage --install-browser-host`
   （会写 Chrome/Chromium/Brave/Edge 与 Firefox 的 native messaging 清单；`--browser-host-status`
   可查看各浏览器的状态）。然后加载未打包扩展。
2. **Chrome / Chromium / Brave / Edge** —— 打开 `chrome://extensions`（或对应浏览器的等价页面），
   开启**开发者模式**，选择**加载已解压的扩展程序** → `browser_extension/`。
3. **Firefox** —— 打开 `about:debugging#/runtime/this-firefox`，**临时载入附加组件…** →
   `browser_extension/manifest.json`；再到 `about:addons` → EasyPass → **权限**里确认 native messaging
   访问。Firefox **尚未端到端验证**，见下方限制。

### 开机自启

设置页的 **"登录时启动 EasyPass"** 是唯一的开关：它负责写入/删除
`$XDG_CONFIG_HOME/autostart/easypass.desktop`。

### Linux 已知差异与限制

- **托盘需要 StatusNotifier 宿主**（KDE Plasma，或装了 AppIndicator 扩展的 GNOME —— Ubuntu 默认
  已启用）。会话总线上没有宿主时，EasyPass 不会去创建无人承载的图标，而是让**关闭窗口即退出应用**
  而不是隐藏它 —— 这样就不会出现"窗口藏起来了、却没有任何图标能把它叫回来"的死局。
- **Firefox 支持未端到端验证**：清单与 native host 包装脚本都已就位，但仍在期待 MV3 事件页而非
  `background.service_worker` 的 Firefox 版本可能需要一个后续的清单变体。
- **未代码签名**，且 AppImage 需要 FUSE 2，除非使用 `--appimage-extract-and-run`。

## 浏览器扩展

Windows 安装包会自动注册 native host；Linux 上先执行一次 `--install-browser-host`（见上）。然后在
`chrome://extensions`（或 `edge://extensions`）开启**开发者模式**，选择**加载已解压的扩展程序** →
`browser_extension/`。扩展尚未上架任何商店，因此这一步必须手工完成。

若弹窗提示 *"Unknown action"*、或后台服务表现异常，通常是**旧的服务进程还在运行**：连同托盘一起
完全退出 EasyPass 再重新启动 —— 协议版本 3 会让应用主动淘汰旧进程。

## 开发与测试

```powershell
flutter analyze --no-pub
flutter test --no-pub      # Windows 上 536 通过 / 9 跳过（共 545 条）
flutter build linux --release   # Linux 桌面产物（需要 GTK 3 与 libayatana-appindicator3-dev）
```

跳过的 9 条是 Linux 专属用例（`browser_host_installer_test.dart` 等）：它们只在 Linux 上注册，
所以 Windows 上显示为 skipped，而不是"悄悄通过"。完整套件在 Linux 上声明约 568 条。

扩展自检（无需浏览器；需装好 `jsdom`）：

```powershell
node browser_extension/tools/check_extension.mjs   # 语法、i18n 键对齐、协议动作、四处版本号一致
node browser_extension/tools/smoke_content.mjs     # 19 项：自动填充行为
node browser_extension/tools/smoke_popup.mjs       # 71 项：弹窗渲染与动作
node browser_extension/tools/smoke_popup_extra.mjs # 58 项：失败路径、可访问性、DOM 契约
```

真机排障：`node browser_extension/tools/probe_daemon.mjs`（直连运行中的服务）与
`probe_bridge.mjs`（端到端拉起桥接），用来判断问题出在服务、桥接还是扩展。

两项原生预检查，都不需要 MSBuild：

```powershell
cmd /c windows\runner\check_syntax.bat      # 用真实开关（/W4 /WX）检查 windows/runner/*.cpp
cmd /c windows\runner\check_integrity.bat   # 工作区是否被打了低完整性标签？（见下表）
```

### 排错

| 现象 | 先查这个 |
|---|---|
| Windows：关闭再打开后没有托盘图标，或设置改了不生效 | `cmd /c windows\runner\check_integrity.bat`。工作区若带 **Low 强制完整性标签**（例如 agent 沙箱以 workspace-write 模式留下的），从 `build\` 启动的进程都会以低完整性运行：没有托盘图标，并且写 `%TEMP%` / `%LOCALAPPDATA%` / `%APPDATA%` 会静默失败。用 `check_integrity.bat /fix` 修。 |
| 扩展：提示 "Unknown action"、超时、弹窗空白 | 旧服务进程还在 —— 连同托盘完全退出 EasyPass 后重启；再跑 `node browser_extension/tools/probe_bridge.mjs`。 |
| Windows：`flutter test` 报加载 `sqlite3.dll` 失败 | `pubspec.yaml` 里的 sqlite3 hook 必须保持只对 Linux 生效（`source: {linux: system}`）；一旦不限定平台，Windows 的 SQLite 加载方式也会被改掉。 |
| Linux：应用能启动但托盘图标不出现 | 会话总线上没有 StatusNotifier 宿主 —— 见上文 *Linux 已知差异与限制*。 |

## 数据与安全模型

- **保险库数据库** —— `easypass.db`：Windows 上位于可执行文件旁，Linux 上位于
  `$XDG_DATA_HOME/easypass/`（按用户、可写、无需管理员权限）。
- **主密码** —— 从不保存；PBKDF2-HMAC-SHA256（100,000 次迭代、32 字节盐）派生 AES-256-CBC 密钥，
  只有盐与校验哈希存进 `flutter_secure_storage`（Windows 走 DPAPI，Linux 走 Secret Service）。
- **会话** —— 派生密钥只驻留内存，锁定即清除。浏览器侧会话密钥由服务进程持有，空闲超时后擦除。
- **加密覆盖范围** —— 密码、TOTP 密钥、笔记、身份/SSH 数据块与自定义字段全部在写入 SQLite 之前
  完成加密；明文从不落库。
- **TOTP 密钥不进浏览器** —— 服务进程算好验证码，只把验证码发出去。
- **只走本机通道** —— 凭据通过带一次性随机令牌的回环 TCP 传输，任何内容都不上传。
- **备份** —— 加密导出会加密整个载荷；明文导出仅供检查，并在界面中明确标注。

## 路线图

**2.4 —— 分发与迁移。** 扩展上架 Chrome Web Store 与 Edge 加载项、Bitwarden/Vaultwarden 导入、
GitHub Actions CI、校验值与代码签名。

**3.0 —— 自部署同步。** 两层密钥体系（账号密钥 → 用户密钥 → 组织密钥）、可 Docker 部署的服务端、
离线优先的同步引擎，随后是共享、组织与紧急访问 —— 这一步才让它真正成为"你自己的 Bitwarden"。

**更远（未排期）。** 附件、passkey、生物识别解锁、SQLCipher、支付卡、Steam Guard TOTP、
（可选）泄露检测、命令行工具、以 Android 为先的移动端、macOS、Firefox 扩展。

## 发布说明

### 2.3.3 —— 新增 Linux 桌面支持

**新平台。** 原生 Linux 构建（`flutter build linux` → AppImage），保险库与 Windows 一致；托盘图标与
关闭到托盘在 GTK runner 中实现（`libayatana-appindicator`）；单实例通过 unix socket 唤醒，二次启动
会把已有窗口抬到前台；支持 XDG 自启；新增桌面项命令行（`--install` / `--uninstall` /
`--desktop-status`）与浏览器宿主注册（`--install-browser-host` / `--uninstall-browser-host` /
`--browser-host-status`）。

随移植一起来的四条约定：

1. **Linux 上保险库换了位置。** 现在在 `$XDG_DATA_HOME/easypass/`，不再放在可执行文件旁；旧位置上
   的 `easypass.db` 会在首次启动时**复制**过去，原文件保留作为回退。
2. **仅 Linux 的权限收紧。** 数据目录 `0700`，数据库与迁移临时文件 `0600`，native host 包装脚本
   `0700`，浏览器清单 `0644` 且位于 `0700` 目录内。这些 POSIX 位只是 Linux 侧加固；Windows 仍沿用
   `%LOCALAPPDATA%` 的 ACL 行为。
3. **Linux 的 native messaging 宿主就是主程序自身**（`easypass --native-host`，由生成的包装脚本
   启动）。Windows 继续使用独立的 x86 桥接可执行文件与 `--service` 服务契约。
4. **同期加固了 Windows 的托盘处理**：runner 现在会确认图标是否真的注册成功（宁可在关窗时退出，
   也不隐藏一个没人能叫回来的窗口），Explorer 重启后会重新添加图标（`TaskbarCreated`），并把
   900×600 的最小窗口尺寸同样施加到 Linux。

### 2.3.0–2.3.2 —— 保险库成型

四种条目类型（登录 / 安全笔记 / 身份信息 / SSH 密钥）与自定义字段、实时 TOTP、文件夹管理
（图标、重命名、带护栏的删除）、`type:` / `folder:` / `url:` 搜索前缀，以及 2.3.1 / 2.3.2 修掉的
真机问题：文件夹下拉只显示第一个文件夹、编辑后界面不刷新、文件夹重命名与删除只藏在长按手势里。

## 已知限制

- **仅 Windows 与 Linux 桌面端** —— 没有 macOS、没有移动端；扩展支持 Chrome/Edge（Firefox 未验证）。
- **没有同步** —— 一个保险库对应一台机器；迁移只能手动复制数据库文件，且必须在 EasyPass 未运行时
  复制。
- **扩展尚未上架**，只能以开发者模式加载。
- **安装包与 AppImage 都未代码签名**，Windows 上 SmartScreen 可能提示未知发布者。
- **没有 CI** —— `flutter analyze`、`flutter test` 与扩展自检都是手工执行。
- **自动填充的边界** —— 两步登录（先用户名页）只会填带密码框的那一页；闭合的 shadow root 对内容
  脚本不可见；部分银行/支付控件可能需要手动填写。
- **暂无生物识别解锁**（设置项为占位），桌面端也无法显示扩展会话的剩余时间（该状态在服务进程里）。
- 尚无共享、组织、附件与 passkey。

## 许可证

GPL-3.0 —— 见 [LICENSE](LICENSE)。

## 致谢

基于 [Flutter](https://flutter.dev)、[drift](https://drift.simonbinder.eu)、
[encrypt](https://pub.dev/packages/encrypt)、[Riverpod](https://riverpod.dev) 与
[go_router](https://pub.dev/packages/go_router) 构建。感谢 Bitwarden 与 Vaultwarden
项目树立了这个项目努力对齐的标杆。
