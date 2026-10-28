# AGENTS.md

Guidance for AI agents working in this repository. 以**当前代码**为准；过时的历史细节不进本文。

## Project Overview

EasyPass 是本地优先的密码管理器（类 Bitwarden），Windows 桌面端，Flutter + 纯 Dart 核心服务。

- **核心架构**：`easypass_core` 是独立、常驻、无窗口的 Dart AOT 进程，**唯一**持有保险库
  与密钥；Flutter UI 是纯客户端（`lib/client/**` → `VaultApi`）；托盘只属于 UI。
- **当前功能线 3.1.0**：四种条目（login / secure_note / identity / ssh_key）、文件夹图标、搜索前缀
  （`type:` / `folder:` / `url:`）、生成器、自动锁定、TOTP、健康报告、加密导出/导入 + Bitwarden 导入、
  浏览器扩展（native messaging）、**智能体访问（MCP）**、**回收站**。
- **智能体访问（3.1.0）**：仅回环的 MCP 端点（固定端口 **47821**，占用即不启动）、按配对发放密钥
  （库里只存 SHA-256）、两种访问模式（逐次审批 / 可信直通）、条目级「开放 / 永久拒绝」硬闸
  （**仅 login / secure_note 可开放**；identity / SSH 由代码硬拒）、秘密只进系统剪贴板、
  审计落 `agent_audit`、写/删/恢复工具。智能体**自己新建的条目默认对它开放**（开关只能用户改）；
  智能体不能彻底删除。"零介入"的准确含义：agent 会话域**没有空闲自动锁**，只随总开关 / 显式锁定 /
  核心退出变化；桌面锁定不锁 agent 域。
- **回收站（3.1.0，schema 5）**：删除 = 软删（`password_entries.deleted_at`），可恢复；"彻底删除/清空"
  只在 UI 动作面。
- **发布状态**：版本 **3.1.0**（`pubspec.yaml` 3.1.0+16），**尚未发版 / 未打 tag**（用户要求缓打）。

文档分工：三份长期规范**入库** —— `docs/technical-spec.md`、`docs/protocol-api.md`、`docs/data-model.md`
（`.gitignore` 反向放行）。`docs/release-*.md` 也入库（CI 读）。**本地-only**：`HANDOFF.md`、`Plan.md`、
`docs/agent-mcp-spec.md`、`docs/README.md` 等。不要写"依赖本地文档才能读懂"的入库内容。

## Build / Test / Lint

Requires Flutter with Dart SDK `^3.12.2`.

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # 改 tables.drift 后必须
flutter gen-l10n                                            # 改 lib/l10n/*.arb 后必须
flutter analyze --no-pub                                    # 门禁
flutter test --no-pub                                       # 门禁；当前 853 例（以后以实跑输出为准；§13 有计数命令）
flutter build windows                                       # 完整构建（含核心 + x86 桥 + 运行库）
```

- **`flutter build windows` 是完整构建**：`windows/runner/CMakeLists.txt` 的 POST_BUILD 会调
  `tool/build_core.ps1`，把 `core\easypass_core.exe` 与 `lib\sqlite3.dll` 摊平进 Release。不要再手动跑
  `tool/build_core.ps1`。只调 UI 可跳过核心：`flutter build windows -- -DEASYPASS_SKIP_CORE_BUILD=ON`。
- **Windows 原生构建由用户执行**（`flutter build windows` / `flutter run -d windows` / 安装包 / 签名 /
  上传）。agent 负责到构建前的一切（改代码、analyze/test、lint、语法检查、文档），然后交出确切命令与
  验收要点。`cmd /c windows\runner\check_syntax.bat` 可在 agent 侧验证 C++ 改动（不调 MSBuild）。
- **打包字体是子集（不是原版）**：`assets/fonts/` 里两个 Maple Mono 各 **~5.17MB**（GB2312 **汉字**全量 +
  App UI 文案字符 + 基础拉丁/标点；原字体本身缺的少量 GB2312 符号不覆盖）；完整原版每字重 ~19.7MB，
  只在 git 历史里。GB2312 之外的字/繁体由系统字体**逐字回退**（可读，字形不同）。重新生成：
  `python -m pip install fonttools` → `python tool/subset_fonts.py --source-dir <含完整字体的目录>`
  （脚本校验字族名与"原字体本应覆盖"的字符；SIL OFL 1.1 许可与版权记录保留在字体 name 表里）。
  **不要拿子集字体再当 source 裁**（会继续丢字；脚本目前拦不住这种误用，靠人守）。
- **加了新 Material 图标后，必须先删 `build\flutter_assets` 再 build。** Flutter 的 `CopyAssets`
  目标（图标字体裁剪）inputs 里没有 `app.dill`，只改 Dart 代码不会重建字体子集 → 新图标在真机空白。
  判断：`build\flutter_assets\fonts\MaterialIcons-Regular.otf` 的 mtime 早于 `Release\data\app.so`。
  修法：`Remove-Item -Recurse -Force build\flutter_assets`（或 `flutter clean`）。
- **构建卡在 `Building native assets failed` 先查网络/代理**：`package:sqlite3` 的 build hook 默认从
  GitHub 下载预编译 DLL；代理没开时失败且信息很少。诊断命令：
  `flutter assemble --no-version-check --output=build\agent_assemble -dTargetPlatform=windows-x64 -dBuildMode=release debug_bundle_windows-x64_assets`
- **核心用 `dart build cli` 构建，不是 `dart compile exe`**（依赖图有 build hook）。`tool/build_core.ps1`
  已封装；产物布局：`{app}\core\easypass_core.exe` + `{app}\lib\sqlite3.dll`（sqlite3 按 `<exe>\..\lib`
  解析，不能与 exe 同目录）。核心 AOT 构建是纯 Dart，agent 可自己跑。
- **核心探针只跑空库**：`dart run tool\probe_core.dart --core <path>`；检测到已有主密码会拒绝写操作。
- **不要 `dart format`**：仓库早于 Dart 3.13 新格式化器，格式化会重写未触碰的文件、淹没真实改动。
  `flutter analyze` 是唯一格式/静态门禁。
- **版本号四处一致**（`browser_extension/tools/check_extension.mjs` 校验）：`pubspec.yaml` 的
  `version`、设置页显示、`browser_extension/manifest.json`、`installer/easypass_setup.iss` 的
  `MyAppVersion` / `VersionInfoVersion`。

## Architecture

```
bin/easypass_core.dart         核心入口（--serve/--bridge/--lock/--shutdown/--status/--version）；不得 import Flutter
lib/main.dart                  UI 入口：ProviderScope + CLI dispatch（--install/--uninstall/--desktop-status 等）
lib/app.dart                   MaterialApp.router；go_router 路由 + auth redirect + 活动上报 + 全局气泡主题
lib/client/                    UI 唯一数据通道：vault_api.dart（接口）/ core_session.dart（发现拉起、重连、事件转发）/ api_providers.dart
lib/protocol/                  协议 5 线格式（纯 Dart）：frames / secure_channel / actions / events / codecs / errors / version / entry_type_wire
lib/mcp/                       MCP 传输层（纯 Dart）：mcp_http_server（回环 POST /mcp + 超时/并发闸）/ mcp_handler（JSON-RPC 2.0）/ mcp_tools（11 个工具 schema，surface v3）
lib/core_service/              核心实现（纯 Dart，不得 import Flutter）：
                               core_service（组装/广播/shutdown）、core_actions（UI 域动作）、
                               session_domains + vault_session（三域会话）、agent_access_store / agent_pairing_store /
                               agent_actions（MCP 工具实现 + 审批闸门）、agent_access_policy（纯函数判定）、
                               native_messaging_service（bridge 域动作）、core_info / core_singleton / core_client /
                               bridge_forwarder、url_matcher
lib/core/                      constants（PBKDF2/AES/端口/版本）、crypto（crypto_service / totp / ssh_key / agent_key_material）、
                               platform（app_paths / dpapi / system_clipboard）、storage（SecretStore / VaultMetaSecretStore）、utils
lib/data/                      database（tables.drift / database.dart / database.g.dart）、models、repositories/vault_repository.dart、
                               services（export_import / bitwarden_importer / master_password_rotation / font_discovery）
lib/features/                  UI（不得 import drift / database / repositories / 会话密钥；architecture_boundary_test 守着）
                               vault（列表/详情/编辑/回收站 + providers）、settings（含 agent_access_provider / agent_audit_screen /
                               agent_approval_host）、auth、generator、health、desktop_{tray,integration,autostart,single_instance}
lib/l10n/                      app_en.arb（源）/ app_zh.arb（中文）+ gen-l10n 产物
tool/build_core.ps1            核心构建；tool/probe_core.dart 核心探针；tool/ui_probe/ 真机验收（真实输入 + MCP 冒烟，仅本地 Release 构建）
browser_extension/             Chrome MV3 扩展 + 32 位 native host（x86 桥）
windows/                       Flutter Windows runner（含托盘/单实例/关闭即锁的 C++ 胶水；源码必须纯 ASCII）
installer/                     Inno Setup 安装包与发布产物收集
docs/                          技术规范（入库 3 份）+ 本地文档
```

**Data flow**：浏览器扩展 → native messaging → x86 桥 → 回环 TCP（协议 5，加密+双向证明）→ 核心；
Flutter UI → `VaultApi`（`lib/client`）→ 回环 TCP → 核心。核心独占 SQLite（`easypass.db`），UI 无数据库句柄。

**会话域**：`ui` / `bridge` / `agent` 各一份密钥副本。UI 锁定会同时锁 bridge，**不锁 agent**
（智能体零介入）；`agent` 域由 DPAPI 包裹的专属密钥在核心启动时自动解封（校验 `vault.keyId`，
不符/解不开就 fail closed 不启 MCP），**不参与空闲自动锁定**：只随总开关开/关、用户显式
「锁定智能体会话」、核心退出变化。方式 1 审批时若 agent 域被显式锁定，从 `ui` 域**复制**
一把钥匙、调用结束立刻锁回（`VaultSession._wipe()` 原地清零，不能共享 `Uint8List`）。
`ui`/`bridge` 的空闲自动锁定由核心执行（默认 5 分钟），UI 只上报 `touchActivity`（节流 20s）
并订阅 `sessionLocked/sessionUnlocked`。

**通道（协议 5）**：4 步握手 + AES-256-CBC/HMAC-SHA256 帧加密（令牌不上线）。`role: ui/agent` 必须走加密
握手；唯一例外是 Windows x86 C++ 桥（32 位 stdio 限制的字节转发器，仍是回环 + 令牌认证）。加密挡不住
同用户恶意进程 —— 真正边界是"同一 Windows 账户"。

**智能体访问（MCP，3.1.0）**：

- 端点：`http://127.0.0.1:47821/mcp`，MCP Streamable HTTP 单端点 `POST`，协议版本 `2025-06-18`；
  **固定端口，bind 失败即不启动**（fail closed，绝不退化临时端口 —— 否则客户端会把 Bearer 投递给占位进程）。
  传输规则：拒绝任何带 `Origin` 的请求、`Host` 必须是回环、只接受 POST、Bearer 只放 header、拒绝 query 凭据、
  不发任何 CORS 头；**先做头校验与认证、再读 body**；body ≤256KB 且读超时 15s（408）、整请求 90s（504）、
  并发上限 16（超出 503）。总开关关闭 / 端点未跑时 `daemon.json` 无 `mcpPort`。
- 工具（11，`agentToolSurfaceVersion = '3'`，`initialize.serverInfo.surfaceVersion` 返回）：`status` /
  `begin_session` / `end_session` / `list_entries` / `get_entry` / `create_entry` / `update_entry` /
  `delete_entry` / `list_trash` / `restore_entry` / `copy_to_clipboard`。
- 授权：`AgentAccessPolicy.evaluate` 是唯一判定；条目「永久拒绝」永远第一条闸，**类型硬闸**（`typeExposed`：
  只有 login / secure_note）紧随其后，identity / SSH 任何情况下都读/写/复制不了。单条目工具在弹审批**之前**
  先跑 `precheck`（未开放/类型不暴露/越界/配对失效直接拒绝、不弹窗，仍写 denied 审计）；**审批通过后重读
  pairing + item + 总开关并复跑完整策略**，写用 `updated_at` CAS、删/恢复用条件语句（防止审批窗口内改开关/
  撤销/删条/改密码被旧快照覆盖）。审批 pending 限流 3/配对、8/全局；校验/算参数尽量在弹窗之前。
- 硬口径：**方式 1（逐次审批）下**写/删/恢复 + 敏感读（剪贴板）永远逐次审批（"本会话内允许读取"只覆盖普通读，
  且可见、可撤销、在锁域/换方式/关开开关/改密/重置密钥/撤销配对时清空）；**方式 2（可信直通）不逐次弹窗**
  （配对时用主密码确认 + 设置页常驻警示，每次访问都写审计）。写工具只支持 login / secure_note
  （identity / SSH 硬拒；secure_note 传 url/username/password 会 `invalidRequest`，不静默忽略）；
  `create_entry` 建的条目默认开放；智能体不能改条目开关、不能彻底删除；秘密只进系统剪贴板
  （`copy_to_clipboard`，无 `reveal_secret`，不回传明文/长度；**剪贴板可被同用户进程/Win+V/云同步读到**）。
- 审计：`agent_audit` 保留最近 1000 条（启动后台裁剪 + 运行期每 100 条裁剪一次）；一次调用一行，
  decision `allowed` / `allowed_standing` / `denied` / `timeout` / `error`；HTTP 层拒绝（401/403/405/413/408/504）
  记 `nickname=未认证 / tool=http`；剪贴板审计 `op=clipboard:<field>`。
- 审批 UI：队列上限 20、回话期间按钮禁用、下一条 350ms 后才可点（防双击批错）、锁屏时不渲染且只允许拒绝；
  「详细」展示非秘密字段 old→new / 剪贴板 field / purpose+TTL / list 筛选，秘密只显示"已修改"。
- 窗口：`begin_session` TTL 默认 300s、范围 30–1800s，**越界报错**（不静默 clamp）；窗口只进元信息/提示，
  不参与授权判定，也不阻止任何锁定；`end_session` **不锁**会话域。
- 生命周期：agent 会话域由 DPAPI 包裹密钥自动解封（校验 `vault.keyId`，改密与重包裹同一事务）；设置页有
  「锁定 / 解锁智能体会话」；关总开关 / 显式锁定 / 核心退出才是锁域边界。

**Routing / auth gating**（`lib/app.dart` 的 `_routerProvider`）：`/lock`、`/set-master-password`、`/vault`、
`/vault/add`、`/vault/edit/:id`、`/vault/entry/:id`、`/vault/trash`、`/vault/agent-audit`、`/generator`、
`/health`、`/settings`。

**UI 约定（近期定型，勿回退）**：侧边栏底部固定「智能体活动」（回收站上方；智能体访问关闭时隐藏）与「回收站」；
条目右键 / ⋮ = `showMenu` 鼠标位置浮窗（主列表与搜索结果共用 `_showEntryContextMenu`）；底部提示统一
`EasyPassApp.snackBarTheme`（floating 380 宽、贴底 8px），带 action 的 SnackBar 必须 `persist: false`；
FAB 放在 body 的 Stack+Positioned（否则 floating SnackBar 会被抬高）。

## Key Files & Directories

- `lib/core/constants/app_constants.dart` — 加密参数（PBKDF2 100k/32B key/32B salt、AES-256-CBC/16B IV）、
  端口（core 47820 / MCP 47821）、`bridgeProtocolVersion = 5`、`coreVersion = 3.1.0`、默认自动锁 5 分钟。
- `lib/core/platform/app_paths.dart` — 所有平台路径；exe 在 `{app}\core\` 时数据目录取父目录 `{app}`。
- `lib/data/database/tables.drift` — schema：`folders`、`password_entries`（含 `deleted_at`）、`vault_meta`、
  `agent_audit`（schemaVersion **5**）。敏感列一律 `*_encrypted`。
- `lib/data/models/vault_item.dart` + `vault_item_mapper.dart` — 唯一加解密口；README 的导出形状由它们决定。
- `lib/data/services/master_password_rotation.dart` — 原子轮换日志（salt/verifier 与整库重加密同一事务）。
- `lib/core_service/agent_actions.dart` — 11 个工具实现 + `_gate` + `precheck` + 审批后重校验 + 审计；
  `agent_access_policy.dart` 纯函数判定（`entryOpen` → `typeExposed` 硬闸）。
- `lib/features/vault/screens/vault_screen.dart` — 主界面（侧边栏/工具栏/列表/右键浮窗/搜索 delegate）。
- `lib/app.dart` — 路由、`snackBarTheme`、活动上报。
- `windows/runner/**` — 托盘、单实例、**关窗即锁**（`WM_CLOSE` 先 `--lock`）；源码必须纯 ASCII。
- `browser_extension/manifest.json` — 扩展 ID 由 `key` 固定，四处契约（见 Pitfalls）。

## Coding Conventions

- Riverpod 手写 provider（无 `@riverpod` codegen），匹配现有风格。
- 分层守卫（`test/architecture_boundary_test.dart`）：`features` 不得 import drift/database/repositories/会话密钥；
  `client` 不得碰 DB；`core_service` 不得 import Flutter。新增目录要同步规则。
- 加密纪律：密码/备注/TOTP 种子/私钥落库前必须经 `CryptoService`；密钥只在核心；绝不打印密钥或明文。
- 注释中英混排；**`windows/runner/**` 纯 ASCII**（cl.exe 按 ANSI 代码页编译，`/WX` 会把 C4819 变失败）。
- UI 文案全部走 `lib/l10n/app_en.arb` + `app_zh.arb`，改完 `flutter gen-l10n`。
- 错误：服务层返回 bool + `errorMessage`，或抛异常由调用方处理；bridge 动作沿用 `error` 字符串字段。
- 平台差异集中在 `features/desktop_*` 与 `core/platform`；Dart 侧 `Platform.isWindows` 不要散落 UI。
- 不写"历史包袱"注释；注释解释**为什么**（当前约束），不记录版本演变。

## Versioning

语义化 `major.minor.patch`：架构/安全模型重构 → major；功能变更 → minor；修复/打磨 → patch。
功能变更时同步：`pubspec.yaml`、设置页显示、扩展 `manifest.json`、`.iss` 的 `MyAppVersion` / `VersionInfoVersion`。
当前 **3.1.0**（尚未发版、tag 缓打，用户决定）。

## Git Workflow

- 分支 `master`，直接提交，无 PR 流程。
- 提交信息**中文**，`type: 描述`。
- **agent 只做本地提交（add + commit，含提交信息）；`git push`、打 tag、发 Release 一律由用户执行。**
  推送前工作区必须干净且已提交。

## CI/CD

`.github/workflows/ci.yml`（push/PR）跑 analyze + test + 扩展检查；`release.yml`（tag `v*`）构建 Windows
安装包并上传带 `SHA256SUMS.txt` 的 Release。版本来自 `pubspec.yaml`。
agent 交付前仍需本地跑：`flutter analyze --no-pub`、`flutter test --no-pub`、
`node browser_extension/tools/check_extension.mjs`（扩展改动时加 jsdom smoke / `build_extension_zip.mjs --dry-run`）、
`cmd /c windows\runner\check_syntax.bat`（C++ 改动）。
发布产物：`node installer/release/collect_artifacts.mjs` 生成哈希与清单；发布说明由
`generate_release_notes.mjs` 填充。Runbook：`installer/release/README.md`。

## Pitfalls（当前仍有效的坑；每条都是真金白银）

- **`dart format` 禁用**（见 Build）。**schema 改动必须写迁移**：`onUpgrade` 实现 1→2、2→3、3→4、4→5；
  整段迁移**必须包在 `transaction()` 里**，每步用 `PRAGMA table_info` / `IF NOT EXISTS` 做**幂等**，
  库版本高于程序（`from > to`）必须抛 `UnsupportedSchemaDowngradeException` 拒绝而不是写 `user_version`。
  drift 未开 SQLite 外键，删文件夹必须显式清 `folder_id`。
- **主密码轮换是原子日志**：salt/verifier 与整库重加密同一事务；"有日志 ⇒ 只有日志里的目标密码有效"。
  不要改回"先重加密再写钥匙材料"。**智能体访问开着时，重包裹的 `agent.wrap` 与新 `vault.keyId` 必须写进
  同一个轮换事务**（改密前先锁 agent 域 + 取消 pending 审批 + 清 standing）；重包裹失败 ⇒ 自动关闭智能体访问。
- **主密码校验只有一份实现 `MasterPasswordVerifier`**（只在核心跑）；UI 走 `verifyMasterPassword` 动作，
  任何地方不许手比 salt/hash。改完主密码必须回到锁定态（强制用新密码再进一次）。
- **SQLite 只由核心打开**；UI 无数据库句柄。测试用 `AppDatabase.forTesting()` + `InMemorySecretStore`。
- **核心启动关键路径上不能有慢活**：`CoreService.start()` 的顺序是
  `refreshAuthMaterial` → `_listen()`（写 daemon.json）→ 后台 `pruneAgentAudit`。
  审计裁剪必须保持 `unawaited`（500k 行实测 prune ≈570ms；放在 `_listen` 之前会直接推迟
  UI 就绪——实测 daemon 728ms → 168ms）。新增启动期维护任务照此办理：监听先就绪，维护后置。
- **删除是软删**：只写 `deleted_at`；列表/搜索/计数/健康/导出默认排除回收站；`getAllEntries()` 覆盖回收站
  （`reencryptAll` 必须用它，否则恢复后永久解不开）；"彻底删除/清空"只在 UI 动作面，**永不进 MCP**。
- **写路径必须广播**：`CoreActions`/`AgentActions` 写完条目要推 `items/item/folders/search`；每写一条审计
  推 `Topics.agentAudit`；否则 UI 流式 provider 不重取。读数据用 `coreSnapshotStream`，不要在写后手动
  `ref.invalidate`、也不要订阅 deprecated 的 `coreChangesProvider.stream`。
- **审批前先过硬闸预检**（`AgentAccessPolicy.precheck`）：未开放/类型不暴露/越界/配对失效直接拒绝且不弹窗
  （仍审计）；预检不替代审批后的**完整 `evaluate`**（审批期间可能改开关/删条/撤销）。审批通过后必须重读
  pairing/item/总开关再执行；写用 `updated_at` CAS、删/恢复用条件语句。
- **agent 域没有空闲锁**：生命周期只有总开关开/关、显式锁定、核心退出；桌面锁定不锁 agent 域。
  单条目工具在 agent 域锁定时返回明确的 `locked`（不读库、不弹审批），不要恢复"先查库后过闸"。
- **剪贴板是"值不出核"的例外**：`copy_to_clipboard` 把值写系统剪贴板（同用户进程 / Win+V / 云同步可读），
  只回 `ok`（不回明文/长度），审计 `op=clipboard:<field>`；PowerShell 用绝对路径 + 写后回读校验。
- **`SnackBar` 双坑**：本 Flutter 版本带 action 时 `persist` 默认 true（不显式 `persist: false` 永不消失）；
  floating SnackBar 会被 `Scaffold.floatingActionButton` 抬高（`snackBarYOffsetBase = FAB.top`）。
- **图标字体子集会被增量构建冻结**：加/换图标后先删 `build\flutter_assets`（见 Build）。
- **桌面功能必须有可见入口**：右键要配 `⋮` 或显式按钮；长按只能是第三条路径，不能是唯一路径。
- **条目右键菜单只有一份**：`_showEntryContextMenu`（`vault_screen.dart` 顶层），主列表与搜索 delegate 共用；
  搜索页先 `close(context, null)` 再把编辑/删除交回页面。
- **`pubspec.yaml` 的 sqlite3 hook 必须是 map 形式或整段省略**；裸 `source: system` 会让测试集体失败。
- **`flutter build windows` 报 MSB3073** 通常是 `Release` 目录里的 `easypass.exe`/`easypass_core.exe` 锁住了
  DLL：先 `Get-Process easypass,easypass_core -EA SilentlyContinue | Stop-Process -Force`，并删过期的
  `%LOCALAPPDATA%\EasyPass\daemon.json`。
- **工作区 Low 强制完整性标签**会让 exe 以低完整性运行（无托盘、写不了用户目录、SmartScreen），
  用 `cmd /c windows\runner\check_integrity.bat /fix` 修复。**`windows/runner/**` 必须纯 ASCII。**
- **`Text` 在 `Row` 里必须 `Expanded`/`Flexible`**，否则 ellipsis 不生效、窄窗溢出；
  对齐不要用 padding 硬凑（侧边栏 248px 与原生最小窗口 900×600 是耦合的）。
- **状态要与 UI 解耦地判**：UI 只通过 `AuthNotifier`/事件跟随核心锁定；删掉 `_ActivityTouchHost` 会让用户
  停在设置页时被自动锁。**扩展 ID 是四处契约**（manifest `key`、Dart 常量、`.iss`、native host JSON），
  改动会静默断开所有已装扩展。**扩展权限保持最小**：`clipboardWrite` + `nativeMessaging` + host `<all_urls>`。
- **帧读取必须共用一个有状态 reader**（`NativeMessageReader`）：一个 TCP chunk 可能含多帧，
  每次新建 buffer 会丢帧（扩展曾因此卡 30s）。
- **`getCredentials` 返回数组**；没有登录表单的 frame 不得应答 `fillCredentials`（否则成功填充显示成"受限"）。
- **jsdom 没有布局**：`textContent` 包含 hidden 子树、`offsetParent` 恒 null；测可见性要自己走祖先链/打桩。
- **两个 `flutter test` 并发会抢 `build\native_assets\windows\sqlite3.dll`**（同一 checkout）：串行跑或重试。
- **文档里的数字要对代码核**：动作数（ui=44 / bridge=10 / agent=0）、MCP 工具 11、schema 5 都可由
  `docs/technical-spec.md` §13 的快照命令重生；**测试用例数以 `flutter test --no-pub` 实跑输出为准**（不要手抄旧数字）。
- **给 CLI 传长文本用文件**（`git commit -F msg.txt`）；`Select-Object -First N` 会提前关管道，别用它判断退出码。

## Tips

- PBKDF2-HMAC-SHA256 100,000 次、AES-256-CBC（IV‖cipher, base64）；改参数会破坏已存数据/扩展。
- 协议 5：握手带 `role` 且全程加密；`AppConstants.bridgeProtocolVersion` 与
  `browser_extension/background.js` 的 `EXPECTED_PROTOCOL_VERSION` 必须一起改。v5 核心拒绝 v4 及更旧的客户端
  （明文握手只留给 x86 桥）。
- 核心由固定端口 47820 保证唯一；`daemon.json` 记录 pid/port/protocol/coreVersion/exe/mcpPort，**原子写**
  （temp+rename）。文件损坏 ⇒ `CoreDiscovery.read()` 抛 `CoreDiscoveryException`；`--lock` / `--shutdown`
  fail closed（打失败信息、退非零），UI 报"核心不可用"而不是删文件重新拉起。
- `easypass_core --lock` 锁库不停核心（托盘"仅退出 UI"、关窗共用 `LockVault()`）。
- 调试工具：`node browser_extension/tools/probe_bridge.mjs`、`probe_daemon.mjs`、`dart run tool\probe_core.dart --core <path>`。
- **真机验收**：`tool/ui_probe/`（Windows PowerShell）——真实 SendInput 的窗口置前/截图/点击/滚轮 +
  MCP 传输冒烟/单工具调用 + 审批按钮识别。只对**本地已启动的 Release 构建**使用，会移动真实鼠标/前台窗口
  （尽量副屏）；写/删用例只用一次性条目，剪贴板用例先备份后恢复。详见 `tool/ui_probe/README.md`。
  **不参与 CI 门禁**，CI 只做脚本语法检查。
- 扩展打包：`node browser_extension/tools/build_extension_zip.mjs`（`--dry-run` 校验；白名单打包）。
- 发布产物与哈希由脚本生成，不要手抄：`installer/release/README.md`。
- `Plan.md`（本地）是路线图；改架构先看 `docs/technical-spec.md`，改协议先看 `docs/protocol-api.md`，
  改 schema 先看 `docs/data-model.md`。

