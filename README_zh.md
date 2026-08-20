# EasyPass

本地优先、对标 Bitwarden 的密码管理器，使用 Flutter 构建，支持 Windows 桌面端。
所有数据仅保存在你的电脑上，绝不联网上传。

当前版本：**1.2.0**（`pubspec.yaml: 1.2.0+4`）。

## 功能特性

### Phase 1 — MVP 核心

- **主密码保护** — PBKDF2-HMAC-SHA256（100,000 次迭代）派生 AES-256-CBC 密钥；主密码本身永不落盘
- **密码库 CRUD** — 条目包含名称、网址、用户名、密码、备注与 TOTP 密钥，支持文件夹分类与收藏
- **搜索** — 按名称、网址、用户名即时搜索
- **密码生成器** — 可配置长度与字符集；每次打开添加条目页都会预填一个全新的随机密码
- **自动锁定** — 可配置 1–30 分钟超时，超时后清除内存中的会话密钥
- **修改主密码** — 验证当前密码后用新派生的密钥对整个密码库重新加密

### Phase 2 — 扩展与可移植性

- **浏览器扩展**（Chrome MV3），通过 Chrome Native Messaging 实现登录表单自动填充
- **加密备份导出/导入**（可恢复）与明文 JSON 导出
- **TOTP**（RFC 6238）双因素验证码

### v1.2.0 — 本次发布

- **Native Messaging 主机已接线** — 主机直接以桌面程序本体运行（`easypass.exe --native-host`，见 `lib/main.dart`），无需独立二进制；与界面共享同一个数据库和加密存储。通过 `browser_extension/native_host/install_host.ps1` 注册到 Chrome/Edge
- **扩展界面双语化** — 浏览器扩展通过 `chrome.i18n` 支持中/英文，跟随浏览器语言
- **密码健康报告** — 弱密码、重复密码、未启用 TOTP、缺少网址的条目检测，附带 0–100 健康评分（密码库页 → 健康图标 → `/health`）
- **桌面端双语界面** — 跟随系统语言（中文/英文），设置页可手动切换
- **自定义字体** — Maple Mono NF CN 随程序分发（`assets/fonts/`），设置页可选择任意已检测到的字体
- **侧边栏与细节打磨** — 常驻侧边栏（2:8 分栏，最大 300px）、完整的条目详情视图、应用图标（`windows/runner/resources/app_icon.ico`）

## 安全模型

- 仅通过 `flutter_secure_storage`（Windows 上使用 DPAPI）持久化盐值与主密码哈希。
- 所有敏感字段（密码、备注、TOTP 密钥）在写入 SQLite 前，一律使用会话派生的密钥进行 AES-256-CBC 加密。
- 派生密钥仅存在于内存中，密码库锁定时（默认 5 分钟）即被清除。
- 绝不打印或记录密钥；密钥只以引用方式传递。

## 数据存储位置

EasyPass 将两类数据存放在两个不同的位置。**删除 `build/` 目录并不会重置应用** —— 它只移除编译产物；密码库数据与主密码状态都会保留。

### 1. 密码库数据库 — 可执行文件同目录

| 项目 | 位置 |
|------|------|
| `easypass.db` | 与 `easypass.exe` 同目录（例如 `build\windows\x64\runner\Release\`） |

存放所有密码条目（使用会话密钥加密）。由于它位于可执行文件旁，删除 `build/` 目录会连带删除条目。**清理构建产物前请先备份**（设置 → 导出，或直接复制 `easypass.db`）。

### 2. 主密码状态与设置 — Windows AppData 目录

| 项目 | 位置 |
|------|------|
| `flutter_secure_storage.dat` | `%APPDATA%\easypass.com\easypass\` |

DPAPI 加密文件，保存主密码的**盐值 + 哈希**（用于解锁验证）以及持久化设置（自动锁定时间、字体选择）。它与构建目录无关——这就是为什么重新构建后应用仍会要求输入旧主密码，而不是重新进入首次设置流程。

> 注意：该路径由 `windows/runner/Runner.rc` 中的 `CompanyName`（`easypass.com`）决定。修改它会改变上述 AppData 路径，旧目录中的数据不会自动迁移。

### 重置 / 恢复出厂

- **应用内**：设置 → *删除所有数据* 会清空密码库与加密存储，使应用回到首次运行状态。
- **手动**：关闭应用后，删除 `%APPDATA%\easypass.com\easypass\`（重置主密码状态）和/或 exe 旁的 `easypass.db`（重置条目）。重新启动即可看到首次设置流程。

## 构建与运行

需要 Flutter 且 Dart SDK `^3.12.2`。

```bash
flutter pub get                                  # 安装依赖
dart run build_runner build --delete-conflicting-outputs  # 修改 tables.drift 后执行
flutter gen-l10n                                 # 修改 lib/l10n/*.arb 后执行
flutter run -d windows                           # 运行桌面应用
flutter test                                     # 运行测试套件
flutter build windows                            # 发布构建
```

## 浏览器扩展

`browser_extension/` 下的扩展（Chrome MV3）通过 Chrome Native Messaging 与桌面应用通信。主机直接以桌面程序本体运行（`easypass.exe --native-host`，见 `lib/main.dart`），无需独立二进制——与界面共享同一个 `easypass.db` 和加密存储。Dart 协议实现位于 `lib/features/browser_bridge/native_messaging_service.dart`（锁定/解锁、凭据查询、搜索、密码生成、TOTP）。

注册主机到 Chrome/Edge：

```powershell
# 构建完成后，在仓库根目录执行：
powershell -ExecutionPolicy Bypass -File browser_extension/native_host/install_host.ps1
# （可选）通过 -ExePath "C:\path\to\easypass.exe" 指定可执行文件路径
```

然后重启浏览器，以开发者模式加载 `browser_extension/`。`uninstall_host.ps1` 可移除注册。请保持 `background.js` 中的动作与 `NativeMessagingService.handleRequest` 的 switch 同步。

## 测试

`flutter test` —— 共 79 个单元/组件测试，覆盖：加解密往返、RFC 6238 TOTP 测试向量、密码生成器、导出/导入往返（加密与明文）、认证生命周期（设置/解锁/修改主密码、自动锁定设置）、Native Messaging 主机协议（锁定/解锁、凭据解密、TOTP）、密码健康报告分析，以及添加条目页的密码预选行为。

## 版本规范

项目遵循 `major.minor.patch` 语义化版本（见 `pubspec.yaml`）：

- **主版本（`x`）** — 仅在重大底层架构变更时提升（如重写加密层、数据库迁移、安全模型变更）。
- **次版本（`y`）** — 新增、移除或变更功能时提升。
- **修订版本（`z`）** — 用于优化：缺陷修复、性能优化、不改变行为的 UI 打磨。

## 路线图

完整路线图见 `Plan.md`（中文）。Phase 1（MVP）与 Phase 2（扩展、TOTP、导出/导入）已完成；密码健康报告（原计划归入 Phase 3）已在 v1.2.0 作为纯本地功能落地。云端同步、密码共享、紧急访问与跨平台发布仍保留在 Phase 3 计划中。
