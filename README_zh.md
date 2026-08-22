# EasyPass

**English**: [README.md](README.md)

EasyPass 是一款**本地优先、开源**的密码管理器，使用 Flutter 构建，面向 Windows 桌面。你的凭据安全地保存在自己的设备上——**绝不联网上传**。配套的浏览器扩展可在 Chrome/Edge 中自动填充登录信息。

> **当前版本：2.0.0** — 服务化架构 + 托盘常驻 + 后台守护进程，关闭应用窗口后扩展依然可用。

---

## 为什么选择 EasyPass？

- **数据只属于你。** 保险库使用 PBKDF2 + AES-256-CBC 加密，存储在本地 SQLite 数据库中。没有服务器、没有账号、没有订阅——密码离线保存在你自己的机器上。
- **完全开源。** 加密与存储逻辑的每一行代码都在本仓库中，任何人可审计。
- **真正的后台服务。** 2.0 起保险库核心以守护进程运行并随系统启动。浏览器扩展即开即连，无冷启动延迟，关闭应用窗口后依然可用。
- **托盘优先的桌面体验。** 关闭窗口时 EasyPass 隐藏到系统托盘而非退出，守护进程在后台持续服务。
- **原生 Windows 应用。** 使用 Flutter 构建，提供快速熟悉的桌面体验；单用户安装包，无需管理员权限。

## 功能特性（v2.0.0）

**保险库**

- 主密码保护（PBKDF2-HMAC-SHA256，10 万次迭代；主密码本身绝不存储）
- 条目支持名称、网址、用户名、密码、备注与 TOTP 密钥——所有敏感字段均经 AES-256-CBC 加密
- 文件夹、收藏、即时搜索
- 可配置的密码生成器，新建条目时自动预填新生成的强密码
- 自动锁定（1–30 分钟）与修改主密码（全库重新加密）
- 密码健康报告：弱密码/重复密码/缺少 TOTP/缺少网址检测，0–100 评分

**浏览器扩展**（Chrome MV3 / Edge）

- 通过 Chrome Native Messaging 从桌面保险库自动填充登录表单
- popup 支持锁定/解锁、搜索、密码生成与 TOTP 验证码
- 双语界面（中文/英文）

**桌面端**

- 中英双语界面、自定义字体、常驻侧边栏、深色主题
- 加密备份导出/导入（可恢复）与明文 JSON 导出
- 后台守护进程 + 系统托盘（2.0）

## 安装

### 方式一：Windows 用户下载安装包（推荐）

从本仓库的 [Releases](https://github.com/) 页面下载 `EasypassSetup.exe`。

- 单用户安装到 `%LOCALAPPDATA%\Programs\EasyPass`——**无需管理员权限**
- 自带 VC++ 运行库与原生消息桥接
- 可选：注册浏览器主机、随登录启动（保险库守护进程随后台常驻，托盘可访问）

### 方式二：从源码构建自己的版本

从源码构建可以审查代码、自行修改或 fork 出属于你自己的版本。

**环境要求**

| 依赖 | 版本/说明 |
|------|-----------|
| Windows | 10 或 11，64 位 |
| Git | 任意较新版本 |
| Flutter SDK | `^3.12.2`（含 Dart 3.12+），加入 `PATH` |
| Visual Studio | 2022 或更新，需安装 **"使用 C++ 的桌面开发"** 工作负载（用于 Windows runner 与 x86 桥接） |

**构建步骤**

```powershell
# 1. 克隆仓库
git clone https://github.com/<your-org>/easypass.git
cd easypass

# 2. 安装依赖
flutter pub get

# 3. 构建 Windows 发布版
#    注意：此步骤会以 POST_BUILD 方式自动编译 x86 原生消息桥接
#    （easypass_native_host.exe），无需额外操作。
flutter build windows --release
```

产物位于 `build\windows\x64\runner\Release\`——可直接运行 `easypass.exe`，或用 Inno Setup 打包安装器：

```powershell
# 可选：构建单用户安装包（需安装 Inno Setup 7）
& "C:\Program Files\Inno Setup 7\ISCC.exe" installer\easypass_setup.iss
# 产物：build\installer\EasypassSetup.exe
```

> 提示：克隆后直接构建即可——生成文件（`database.g.dart`、`app_localizations*.dart`）已入库。若你修改了 `tables.drift`，需执行 `dart run build_runner build --delete-conflicting-outputs`；修改了 `lib/l10n/*.arb`，需执行 `flutter gen-l10n`。

**浏览器扩展**

扩展位于 `browser_extension/`（仅桌面应用不需要它）：

1. 先完成上面的构建，确保 `easypass_native_host.exe` 与 `easypass.exe` 同目录
2. 向浏览器注册原生主机：
   ```powershell
   powershell -ExecutionPolicy Bypass -File browser_extension/native_host/install_host.ps1
   # 可选：-ExePath "C:\path\to\your\easypass.exe"
   ```
3. 打开 `edge://extensions`（或 `chrome://extensions`），开启**开发者模式**，选择**加载已解压的扩展程序**并指向 `browser_extension/` 文件夹
4. 重启浏览器，确认扩展 ID 为 `hlkbbdlgaocmnjlgpafkimobnkfniike`（由 manifest 的 `key` 固定）

**测试**

```bash
flutter analyze
flutter test      # 94 个单元/集成测试
```

## 数据与安全模型

- **保险库数据库**：`easypass.db`，存放于**可执行文件同目录**（安装目录，或源码构建的 `build\windows\x64\runner\Release\`）。请定期备份（设置 → 导出，或直接复制该文件）。
- **主密码状态与设置**：`%APPDATA%\easypass.com\easypass\`（DPAPI 保护）：用于解锁验证的盐值+哈希与偏好设置。
- 敏感字段在写入 SQLite 前均经 AES-256-CBC 加密；派生密钥仅存在于内存，锁定即清除。
- 数据绝不离开你的设备。
