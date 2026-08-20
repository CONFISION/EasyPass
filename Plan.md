# EasyPass 完整规划

EasyPass 是一个对标 Bitwarden 的开源密码管理工具，使用 Flutter 构建，支持 Windows、Android、iOS、macOS、Linux、Web 等多平台，并具备浏览器自动填充功能。

---

## 一、功能规划（分阶段实现）

### 🔴 Phase 1 — MVP 核心（v1.0）

| 功能 | 说明 |
|------|------|
| **主密码保护** | 启动时验证主密码，AES-256 加密所有数据 |
| **密码条目 CRUD** | 保存/编辑/删除网站登录信息（名称、URL、用户名、密码） |
| **文件夹/分类** | 按类别组织密码条目 |
| **密码生成器** | 可配置长度、字符类型的强密码生成 |
| **搜索** | 按名称、URL 快速搜索密码条目 |
| **本地 SQLite 存储** | 加密存储所有数据，离线可用 |
| **自动锁定** | 超时后自动锁定应用，需重新输入主密码 |
| **Windows 桌面端** | 优先完成 Windows 桌面应用 |

### 🟡 Phase 2 — 扩展与同步（v1.5）✅ 已完成

| 功能 | 说明 | 文件 |
|------|------|------|
| **浏览器扩展** | Chrome/Edge 扩展，自动填充用户名密码 | `browser_extension/` |
| **Native Messaging** | 桌面应用与浏览器扩展通过本地通道通信 | `lib/features/browser_bridge/` |
| **密码导出/导入** | 支持加密 JSON 格式 | `lib/data/services/export_import_service.dart` |
| **TOTP 双因素认证** | RFC 6238 标准 TOTP 代码生成器 | `lib/core/crypto/totp_service.dart` |

### 🟢 Phase 3 — 完整生态（v2.0）

| 功能 | 说明 |
|------|------|
| **全平台覆盖** | macOS、Linux、Web |
| **云端同步** | 自建后端服务实现多设备同步 |
| **密码共享** | 安全地与他人共享密码 |
| **密码健康报告** | 弱密码、重复密码、泄露检测 |
| **紧急访问** | 信任联系人紧急访问机制 |

---

## 二、技术选型

### Flutter 应用层

| 领域 | 技术 | 理由 |
|------|------|------|
| **状态管理** | `riverpod` | 类型安全、可测试、无依赖注入容器 |
| **路由** | `go_router` | 声明式路由，支持深链和 Web |
| **本地数据库** | `drift` (SQLite) | 类型安全的 ORM，编译时 SQL 验证 |
| **加密引擎** | `encrypt` + `crypto` | AES-256-CBC / PBKDF2 密钥派生 |
| **安全存储** | `flutter_secure_storage` | 存储主密码哈希、加密密钥等敏感数据 |
| **生物识别** | `local_auth` | 指纹/面部解锁 |
| **密码生成** | 自研 `dart:math` + `Random` | 无外部依赖，可控性强 |
| **HTTP 客户端** | `dio` | 拦截器、重试、文件下载（Phase 3 使用） |
| **剪贴板** | 自研剪贴板服务 | 复制密码后自动清除 |
| **本地通知** | `flutter_local_notifications` | 密码过期提醒等 |

### 浏览器扩展层（Phase 2）

| 领域 | 技术 | 理由 |
|------|------|------|
| **扩展框架** | Chrome Extension Manifest V3 | 现代标准，Firefox/Edge 兼容 |
| **通信方式** | Chrome Native Messaging | 与本地 Flutter 桌面应用通信 |
| **自动填充** | Content Scripts + DOM 操作 | 检测登录表单并注入凭据 |
| **扩展前端** | 纯 HTML/CSS/JS | 轻量、兼容性最佳 |

### 后端服务层（Phase 3，可选）

| 领域 | 技术 | 理由 |
|------|------|------|
| **后端框架** | Dart Frog 或 Node.js | Dart Frog 全栈 Dart；Node.js 生态成熟 |
| **数据库** | PostgreSQL | 成熟、加密支持好 |
| **API 风格** | RESTful + WebSocket | 实时同步 |
| **认证** | JWT + refresh token | |
| **部署** | Docker + 云服务 | |

---

## 三、安全架构

```
用户输入主密码
      │
      ▼
PBKDF2-HMAC-SHA256 (100,000+ 迭代)
      │
      ▼
派生加密密钥 (256-bit)
      │
      ├──▶ AES-256-CBC 加密密码数据
      │
      └──▶ 密钥哈希 (验证用) 存入 flutter_secure_storage
```

- **主密码永不存储**，只存储其哈希用于验证
- 所有敏感数据（密码、备注、TOTP 密钥）均以 AES-256-CBC 加密
- 密钥派生使用 PBKDF2，迭代次数 ≥ 100,000
- 使用 `flutter_secure_storage`（Windows 上用 DPAPI，Android 用 Keystore，iOS/macOS 用 Keychain）
- 应用进入后台/闲置超时后自动锁定并清除内存中的密钥

---

## 四、项目目录结构

```
easypass/
├── lib/
│   ├── main.dart                    # 应用入口
│   ├── app.dart                     # MaterialApp 配置
│   ├── core/
│   │   ├── crypto/                  # 加密模块 (AES, PBKDF2)
│   │   │   └── crypto_service.dart
│   │   ├── security/                # 主密码管理、锁定机制
│   │   │   └── lock_service.dart
│   │   ├── constants/               # 常量
│   │   │   └── app_constants.dart
│   │   └── utils/                   # 工具函数
│   ├── data/
│   │   ├── database/                # Drift 数据库定义
│   │   │   ├── database.dart
│   │   │   └── tables.dart
│   │   ├── models/                  # 数据模型
│   │   │   └── password_entry.dart
│   │   ├── repositories/            # 数据仓库层
│   │   │   └── vault_repository.dart
│   │   └── services/                # 后台服务
│   ├── features/
│   │   ├── auth/                    # 认证（主密码、生物识别）
│   │   │   ├── screens/
│   │   │   │   ├── lock_screen.dart
│   │   │   │   └── set_master_password_screen.dart
│   │   │   └── providers/
│   │   │       └── auth_provider.dart
│   │   ├── vault/                   # 密码保险库（列表、详情）
│   │   │   ├── screens/
│   │   │   │   ├── vault_screen.dart
│   │   │   │   └── entry_detail_screen.dart
│   │   │   ├── widgets/
│   │   │   │   └── entry_card.dart
│   │   │   └── providers/
│   │   │       └── vault_provider.dart
│   │   ├── generator/               # 密码生成器
│   │   │   ├── screens/
│   │   │   │   └── generator_screen.dart
│   │   │   └── providers/
│   │   │       └── generator_provider.dart
│   │   ├── search/                  # 搜索
│   │   ├── settings/                # 设置
│   │   │   └── screens/
│   │   │       └── settings_screen.dart
│   │   └── browser_bridge/          # 浏览器通信 (Phase 2)
│   ├── l10n/                        # 国际化
│   └── widgets/                     # 共享 UI 组件
├── browser_extension/               # 浏览器扩展 (Phase 2)
├── server/                          # 后端服务 (Phase 3)
├── test/
└── pubspec.yaml
```

---

## 五、数据模型

```
PasswordEntry                    Folder
├── id (UUID)                    ├── id (UUID)
├── folderId (FK, nullable)      ├── name
├── name (网站名称)               ├── icon
├── url (网站地址)                ├── createdAt
├── username                     └── updatedAt
├── password (加密存储)
├── notes (加密)
├── totpSecret (加密, Phase 2)
├── isFavorite
├── createdAt
└── updatedAt
```

---

## 六、实施路线图

### Phase 1 实施步骤

1. [x] 初始化项目结构，重命名应用
2. [x] 引入核心依赖（riverpod, go_router, drift, encrypt, flutter_secure_storage）
3. [x] 搭建目录结构和核心文件
4. [x] 实现加密模块（PBKDF2 + AES-256-CBC）
5. [x] 实现 Drift 数据库和表定义
6. [x] 实现主密码认证流程（设置/验证主密码）
7. [x] 实现锁定/解锁机制
8. [x] 实现密码保险库 CRUD
9. [x] 实现密码生成器
10. [x] 实现搜索功能
11. [x] 实现文件夹分类
12. [x] UI 美化和用户体验优化
13. [x] 测试（38 个单元测试：加密/TOTP/生成器/导入导出/认证）

### Phase 2 实施步骤

1. [x] 开发 Chrome 浏览器扩展
2. [x] 实现 Native Messaging 通信
3. [x] 实现自动填充功能
4. [x] 实现密码导出/导入
5. [x] 实现 TOTP 双因素认证
6. [ ] 移动端适配 (Phase 3)

### Phase 3 实施步骤

1. [ ] 搭建后端服务
2. [ ] 实现云端同步
3. [x] 密码健康报告（v1.2.0 本地实现：弱密码/重复密码/无 TOTP/无 URL 检测 + 评分）
4. [ ] 紧急访问
5. [ ] 全平台发布