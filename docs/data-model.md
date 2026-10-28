# EasyPass 数据模型与持久化规范

> **入库文档**（`.gitignore` 反向规则放行）。本文是**数据的权威规范**：改 schema、加字段、
> 写导入导出、动加密列之前必读。
>
> 事实基准：**3.1.0**（schema **5**）。当前 schema：`folders`、`password_entries`（含 `deleted_at`）、
> `vault_meta`（校验材料）、`agent_audit`（智能体访问审计）。

---

## 0. 一句话边界

**只有一个进程碰数据库：核心（`easypass_core`）。** UI 通过 `VaultApi`（协议 5）间接读写；
`test/architecture_boundary_test.dart` 禁止 `lib/features/**` 与 `lib/client/**`
import drift / 数据库 / 仓储。所以：

- **核心侧**（`lib/core_service/**`、`lib/data/**`）用本文 §3 的仓储 API。
- **UI 侧**用 `VaultApi` 的同名动作（`listItems` / `saveItem` / …），**没有**数据库句柄，
  也不持有密钥（密钥只活在核心的 `SessionDomains`）。

---

## 1. 数据模型

文件：`lib/data/models/{entry_type,entry_fields,vault_item,vault_item_mapper}.dart`

- **`EntryType`**：枚举 + `wireName`（`login` / `secure_note` / `identity` / `ssh_key`）。
  `EntryType.fromWire(Object?)` 容错解析（含 `ssh` / `note` 等别名），未知值回退 `login`。
  `isAutofillable` 只有登录类型为 true。
- **`CustomField{label, value, type}`**，`CustomFieldType{text, hidden, boolean}`；
  布尔以字符串 `'true'` / `'false'` 存。`CustomField.isEmpty` = 标签与值**都**为空（保存时丢弃）。
- **`IdentityData`**：`title/firstName/middleName/lastName/username/company/email/phone/
  idNumber/passportNumber/licenseNumber/address1/address2/city/state/postalCode/
  country/birthday/sex`，全 `String`，JSON 用 snake_case。
- **`SshKeyData`**：`publicKey/privateKey/passphrase/fingerprint/keyType/bits(int?)/comment`。
- **`EntryPayload`**：进 `data_encrypted` 的载荷 = `customFields + identity? + sshKey? + agentAccess?`（带 `v:1`）。
  `agentAccess`（模型里是 `agentOpen`）是"允许智能体访问"开关，**参与 `isEmpty` 判定**——
  只设了开关的载荷必须写进 `data_encrypted`，否则开关会被静默丢弃。
- **`VaultItem`**：**内存态明文模型**，四种类型共用：
  `id / folderId? / type / name / notes / isFavorite / deletedAt? / login? / identity? /
  sshKey? / customFields / createdAt / updatedAt`。
  便捷访问器 `loginOrEmpty` / `identityOrEmpty` / `sshKeyOrEmpty`；
  `subtitle`（列表副标题）、`searchableText`（**不含**密码 / TOTP / 私钥 / 口令 / 隐藏字段值）。
  `deletedAt` 非空 = 在回收站（schema 5）：它**不是**加密载荷的一部分（"在回收站"不是秘密，
  列表查询要按它过滤），也**不是**条目内容 —— 恢复只把它置回 null。

**这里改签名要三处同步**：`VaultItemMapper`、协议编解码（`lib/protocol/codecs.dart`，UI 与 bridge
两套形状）、导出/导入。bridge 侧的字段名**自协议 3 起冻结**（`protocol-api.md` §6）。

---

## 2. 持久化规则（冻结）

`password_entries` 在 schemaVersion **2** 增加了两列（1→2 迁移已实现）：

| 列 | 说明 |
|----|------|
| `type TEXT NOT NULL DEFAULT 'login'` | 类型标签，明文（SQL 过滤 / 列表用） |
| `data_encrypted TEXT NOT NULL DEFAULT ''` | 载荷密文（`EntryPayload` JSON 加密） |

- **登录字段仍走列**：`url` / `username` / `password_encrypted` / `totp_secret_encrypted`
  —— 旧数据零迁移，自动填充与搜索行为不变；`VaultItem.login` 只是这些列的投影。
- **身份 / SSH 专属字段 + 所有类型的自定义字段**统一进 `data_encrypted`。
- 空值一律存**空串**，不加密空字符串（`password_encrypted` 是 NOT NULL，非登录类型写 `''`）。
- `notes_encrypted` 承载所有类型的"备注"；安全笔记类型的**正文就是 `notes`**。
- **加密 / 解密只允许经由 `VaultItemMapper`**：
  `toInsert(item, key)` / `toUpdate(item, key)` / `fromRow(row, key, {lenient})` /
  `encodePayload` / `decodePayload`；`VaultItemMapper.normalize(item)` 丢弃与类型不符的字段块，
  并在 SSH 公钥可解析时自动补 `fingerprint/keyType/bits/comment`（不覆盖用户填过的值）。
- **绝不**在加密失败时退化成写明文。宁可抛错。
- 切换条目类型时用 `item.withoutTypeData()` 丢掉原类型字段（UI 负责二次确认）。

### 2.0 回收站：`deleted_at`

`password_entries` 增加一个**可空**列：

| 列 | 语义 |
|----|------|
| `deleted_at INTEGER` | `NULL` = 正常条目；非 NULL = 删除时间（毫秒），即"在回收站" |

- **删除 = 软删**：只写这一列，行、密文、`updated_at` 都不动 ⇒ 恢复是零成本的
  （`restoreEntry` 只是把它置回 NULL）。彻底删除（`permanentlyDeleteItem`）才真删行。
- **默认查询全部排除回收站**：`getEntriesFiltered` / `watchEntriesFiltered` /
  `getEntryCount` / `countEntriesFiltered` / `searchEntries` / `watchFavoriteEntries`
  都以 `deleted_at IS NULL` 为默认；只有回收站界面与"必须遍历全库"的路径
  （`getAllEntries`：轮换 / 钥匙探测 / 清库）会看到它们。
- **主密码轮换必须覆盖回收站行**：`reencryptAll` 走 `getAllEntries()`，
  `VaultItemMapper` 又保留 `deletedAt` —— 漏掉这一步的话，回收站里的密文会留在旧钥匙上，
  恢复后永久解不开。`test/trash_core_test.dart` 专门钉了这条（先删 → 改密 → 重启 → 恢复读密码）。
- **导出不包含回收站**：备份语义是"当前条目"（`exportPlainJson` 走 `getItems()`）。
- 清库（`deleteAllData`）连回收站一起清；删文件夹时回收站条目的 `folder_id` 也会被清空
  （恢复后落在"无文件夹"）。
- 智能体**只能把条目删进回收站**（`delete_entry`），"彻底删除 / 清空"只存在于 UI 动作面。

### 2.1 `vault_meta`

键值表，承载两类东西：

| 前缀 | 内容 | 写入者 |
| --- | --- | --- |
| `secret.*` | 主密码校验材料：salt、`SHA-256(derivedKey)` 验证子 | `VaultMetaSecretStore`（升级迁移 `auth.*` 一次） |
| `rotation.*` | 主密码轮换日志（目标 salt + 验签子 + 状态） | `MasterPasswordRotation` |
| `agent.pairing.<id>` | 智能体配对记录（昵称 / 方式 / **密钥的 SHA-256** / 撤销时间） | `AgentPairingStore` |
| `agent.enabled` | 智能体访问总开关（`'1'` = 开） | `AgentAccessStore` |
| `agent.wrap` | 用专属密钥**包裹后**的保险库密钥（base64，见 `AgentKeyMaterial`） | `AgentAccessStore` |
| `vault.keyId` | 当前 vaultKey 的 SHA-256 指纹；启动自动解封 agent 域时校验它，拒绝旧包裹 | `CoreActions`（设密/改密/开总开关/重置） |

**轮换的原子性不变量**：目标 salt/验签子（写进 `rotation.*` 日志行）与整库重加密在**同一个 SQLite 事务**里写入。
"没有日志 ⇒ 库还是旧钥匙；有日志 ⇒ 库已经是新钥匙"，日志的存在就是"哪个密码有效"的权威。
智能体访问开着时，`agent.wrap` 与新 `vault.keyId` 也在这个事务里一起更新（改密失败/崩溃 ⇒ 一起回滚）。
`test/master_password_rotation_atomicity_test.dart` 与 `change_password_then_lock_test.dart` 守着这条。

### 2.2 `agent_audit`

智能体（MCP）访问审计。**只存"发生了什么"，不存秘密**：

| 列 | 含义 |
| --- | --- |
| `at` | 毫秒时间戳 |
| `pairing_id` / `nickname` | 哪个配对、用户给它起的名字（**只进库，不进模型上下文**） |
| `mode` | `trusted` / `approval` |
| `tool` / `op` | 工具名 + 读 / 敏感读 / 写 / 删；剪贴板成功记 `clipboard:<field>`；HTTP 层拒绝行 `tool=http` |
| `entry_id` / `entry_name` | 被操作的条目（可空，例如 `status`） |
| `decision` | 实际写入：`allowed` / `allowed_standing`（靠「本会话内允许读取」放行）/ `denied` / `timeout` / `error`（执行失败兜底；一次调用只写一行） |

**绝不写入**：配对密钥、真实客户端标识、明文参数、条目字段值。
写入是**旁路**（`AgentActions.auditSink`）：落库失败不影响工具调用，只在内存环形缓冲里保底。
表按 `id` 保留最近 **1000** 条（`pruneAgentAudit({int keep = 1000})`）：启动后**后台**裁剪一次，
运行期**每写 100 条**再触发一次（长跑进程不会无限增长）。
一次调用最多一行；剪贴板审计的 `op` 记 `clipboard:<field>`；HTTP 层拒绝（401/403/405/413/408/504）
也会写一行 `nickname=未认证 / mode=unknown / tool=http / op=read / decision=denied`。
超时/取消/拒绝各只写一行（decision = `timeout` / `denied`）。

`allowed_standing` 与 `error` 两个取值的含义：`_gate` 记住这次是否靠免询问放行
（审计要能区分"用户点了同意"与"被免询问绕过"）；`callTool` 的异常兜底在"本次还没写过审计"时
补一行 `error`（`notFound` / 参数错误 / 意外异常）。UI（侧边栏 → 智能体活动）
分别显示为「已允许（本会话免询问）」与「失败」。

---

## 3. 仓储 API（核心内部使用；UI 不得直接调用）

文件：`lib/data/repositories/vault_repository.dart`。密钥来源是**核心的会话域**
（`lib/core_service/session_domains.dart`）；UI 侧不持有密钥，也没有"当前密钥"这种东西。

```dart
// 条目（新代码只用这套）
Future<List<VaultItem>> getItems({String? folderId, EntryType? type, bool favoritesOnly = false});
Future<VaultItem?> getItem(String id, {bool includeDeleted = false}); // 未解锁 / 不存在 / 在回收站 → null
Stream<VaultItem?> watchItem(String id, {bool includeDeleted = false});
Future<void> saveItem(VaultItem item);          // 按 id upsert；createdAt 保留、updatedAt 刷新
Future<bool> updateItemIfUnchanged(VaultItem item, {required int expectedUpdatedAt});
                                                // CAS：updated_at 不匹配或已进回收站 ⇒ false（智能体写路径用）
Future<bool> encryptionProbeWorks(Uint8List key); // 用给定钥匙真解一行（自动解封 agent 域的旧库回退探测）
Future<List<VaultItem>> searchItems(String query);   // 见下
Future<int> countItems();
Future<int> countItemsByType(EntryType type);
Future<int> countItemsInFolder(String folderId);
Future<int> reencryptAll({required Uint8List oldKey, required Uint8List newKey}); // 含回收站行

// 回收站（schema 5）
Future<bool> deleteItem(String id);             // 软删：移入回收站；false = 没这条/已删
Future<List<VaultItem>> getTrashedItems();      // 会解密，只给回收站界面
Future<int> countTrashedItems();
Future<bool> restoreItem(String id);            // deleted_at 置回 NULL
Future<bool> permanentlyDeleteItem(String id);  // 只接受回收站里的条目
Future<int> emptyTrash();                       // 返回删除条数

// 文件夹
Future<List<Folder>> getFolders();
Future<void> addFolder(FoldersCompanion folder);
Future<void> updateFolder(String id, FoldersCompanion folder);   // 重命名 / 改图标
Future<void> removeFolder(String id);           // 先把条目 folder_id 清空
```

- 未解锁时：读返回空 / null，写抛 `VaultLockedException`。
- **默认口径排除回收站**：`getItems` / `countItems*` / `searchItems` / 列表流都不含
  `deleted_at` 非空的行；只有 `getItem(..., includeDeleted: true)` 与回收站 API 能看到它们。
- `saveItem` 对**回收站里**的行是"就地更新但保持 deleted_at"（不会悄悄复活）；
  智能体侧干脆禁止更新回收站条目（要求先 `restore_entry`）。
- **`searchItems` 语义**：大小写不敏感的内存匹配（解密后字段），支持
  `type:login|note|identity|ssh|all`（中文别名：登录/笔记/身份/密钥/全部）、
  `folder:<名>`、`url:<子串>`，自由词之间是 **AND**；空查询返回空列表；
  结果按 `name`（忽略大小写）再按 `id` 排序。
  匹配面：名称 / 备注 / 各类型专属字段 / 自定义字段的**标签**与非隐藏字段的**值**；
  **不**匹配密码、TOTP 密钥、SSH 私钥与口令、隐藏字段的值。
- 同一套语义由核心的 `searchItems` 动作暴露给 UI（`protocol-api.md` §5.2），
  两边必须一致 —— 改一处要改另一处。
- 旧的行级 API（`watchEntries` / `getAllEntries` / `search` / `saveEntry`…）标了
  `@Deprecated`，只用于历史数据兼容；**新代码不要用**。
- **没有 `watch*` 流**：仓储不暴露 drift 流（UI 进程根本没有库句柄）。
  变更通知由核心在事务提交后广播 `changed` 事件，客户端重取快照 —— 见
  `protocol-api.md` §7 与 `lib/features/vault/providers/core_stream.dart`。

---

## 4. UI 字段分工（避免三个界面各写一套）

**新增 / 编辑表单**

| 类型 | 字段（顺序） |
|------|--------------|
| login | 名称* · 网址 · 用户名 · 密码*（生成 / 显示） · TOTP 密钥 · 文件夹 · 备注 · 收藏 · 自定义字段 |
| secure_note | 名称* · **笔记正文**（`notes`，多行，主输入区） · 文件夹 · 收藏 · 自定义字段 |
| identity | 名称* · 个人信息（称谓/名/中间名/姓/用户名/公司/生日/性别） · 联系方式（邮箱/电话） · 证件（证件号/护照号/驾照号） · 地址（地址/地址2/城市/省州/邮编/国家） · 文件夹 · 备注 · 收藏 · 自定义字段 |
| ssh_key | 名称* · 公钥 · 私钥（多行、可显示/隐藏） · 私钥口令（隐藏） · 指纹/类型/长度/注释（可由公钥自动推导，允许手改） · 文件夹 · 备注 · 收藏 · 自定义字段 |

- `*` = 必填。登录条目沿用"密码必填"；SSH 条目要求**公钥或私钥至少填一个**。
- **「允许智能体访问」开关只对 login / secure_note 显示**；类型切换到 identity / SSH 时强制
  `agentOpen=false`（保存时再兜一次），导入时非暴露类型也强制关闭（见 §5）。
- 类型选择器只在**新建**时可改；编辑既有条目时切换类型要弹确认框
  （`entryTypeSwitchTitle` / `entryTypeSwitchMessage` / `entryTypeSwitchConfirm`），
  确认后调 `withoutTypeData()` 再保存。
- 保存一律走 `VaultApi.saveItem(VaultItem)`（UI），**不要**自己拼 `PasswordEntriesCompanion`
  —— 后者是核心内部的事。

**详情页**

| 类型 | 渲染 |
|------|------|
| login | 用户名 · 密码（显示需验证主密码） · 网址 · **TOTP 动态码 + 倒计时 + 复制** · 备注 · 自定义字段 · 收藏 |
| secure_note | 笔记正文（可选文字、可复制） · 自定义字段 · 收藏 |
| identity | 按分组展示所有非空字段 + 逐项复制 · 备注 · 自定义字段 · 收藏 |
| ssh_key | 公钥（复制） · 私钥（验证后显示、可复制） · 口令（隐藏） · 指纹（复制） · 类型/长度/注释 · 备注 · 自定义字段 · 收藏 |

**列表**

- 每类一个图标 + 类型徽章；副标题用 `item.subtitle`；收藏星标保留。
- 卡片上的"复制"按钮**只在登录条目**出现（复制密码）。
- 侧边栏 / 工具栏提供**类型筛选**（全部 / 登录 / 安全笔记 / 身份 / SSH），可与文件夹、收藏叠加。
- 搜索走 `VaultApi.searchItems`，搜索框下方给出前缀提示（`searchPrefixesHint`）。
- **文件夹管理**：新建 / 重命名 / 换图标 / **删除**。删除入口必须**看得见**
  （每行常驻 ⋮ 按钮）并且给鼠标原生手势（右键 `onSecondaryTap`），长按只是第三条路——
  只挂长按会让桌面用户以为"文件夹只能加不能删"。
  删除前先数条目（`countItemsInFolder`）：**空文件夹**普通确认；**有条目**时提示必须写明
  "有 N 条、条目**不会**被删除、会被移到『无文件夹』"，确认按钮文案也随之变化。
  删除只解除归属（`removeFolder` 先清 `folder_id` 再删），任何路径都不删条目。

---

## 5. 导出 / 导入格式

`format: 'plain'` / `'encrypted'` 外壳不变（`version` 为 `'2.0.0'`），`entries[]` 元素：

```json
{
  "id": "...", "folder_id": null, "type": "login",
  "name": "...", "notes": "...", "is_favorite": false,
  "created_at": 0, "updated_at": 0,
  "agent_access": "open",          // 仅当条目对智能体开放时出现；缺省 = 永久拒绝
  "login":     { "url": "...", "username": "...", "password": "...", "totp_secret": "..." },
  "identity":  { ... } | 省略,
  "ssh_key":   { ... } | 省略,
  "custom_fields": [ ... ] | 省略
}
```

- 导入必须**向后兼容 1.x 导出**：没有 `type` 时按 `login`，平铺的
  `url/username/password/totp_secret` 也要能读（`VaultItem.fromJson` 已处理）。
- 导入的登录字段要用**核心的会话密钥**重新加密后落地（`VaultApi.importVault` →
  核心读写文件；UI 只传路径）。
- **导入必须清洗本机权限/状态位**（`ExportImportService._parseEntry`）：
  - `deleted_at` **一律丢弃**（备份里的条目不会因导入而静默进回收站）；
  - `agent_access` 只对 login / secure_note 保留（用户自己备份的恢复语义），identity / SSH 强制关闭。
- 导出：EasyPass 自身 JSON 携带 `agent_access`；Bitwarden 兼容导出不携带（它没有这个概念）。
- 加密备份（`format:'encrypted'`）里**不得出现明文**密码 / 私钥 / 证件号。
- 另有 Bitwarden JSON / CSV 导入（`lib/data/services/bitwarden_importer.dart`）：
  结果里会额外回 `skippedDetails[]`、`extraUris`、`cardsAsNotes` 三个字段。

---

## 6. 迁移规则（改 schema 必读）

- **`schemaVersion` 当前是 5**，`AppDatabase.migration.onUpgrade` 真实实现了 1→2、2→3、3→4、4→5；
  每个新列 / 新表**都**要加进去，否则老库打开时报 "no such column" / "no such table"。
  - 1 → 2：`type` + `data_encrypted`（2.3.0 多类型）
  - 2 → 3：`vault_meta`（轮换日志）
  - 3 → 4：`agent_audit`（智能体访问审计，见 §2.2）
  - 4 → 5：`password_entries.deleted_at`（回收站，见 §2.0）
- **迁移必须原子 + 幂等 + 拒绝降级**（`database.dart` 的 `onUpgrade`）：
  - 整段 `onUpgrade` 包在 `transaction()` 里（drift 的迁移回调本身不在事务中；中途失败会留下
    "列已加、user_version 没变"的半迁移库，重跑 `ADD COLUMN` 就 duplicate column、库永久打不开）；
  - 每步先 `PRAGMA table_info` 判断列是否已存在，索引用 `CREATE INDEX IF NOT EXISTS`（可重复执行）；
  - 库版本高于程序（`from > to`，用户装回旧版）抛 `UnsupportedSchemaDowngradeException`，
    **不写库**，让用户装回 3.1.0+。
- **改 `tables.drift` 必须跑**
  `dart run build_runner build --delete-conflicting-outputs`。
  先读 `pubspec.yaml` 里那段注释：analyzer 版本必须跟得上 Dart SDK，
  否则 `drift_dev` 会以 `Missing implementation of visitDotShorthandPropertyAccess` 崩，
  而且**什么都不写**（`--delete-conflicting-outputs` 已经把旧文件删了 ⇒ 仓库直接编不过）。
- `test/migration_test.dart` 手工构造 v1 / v2 / v3 / v4 库并断言 1→2、2→3、3→4、4→5
  四条升级路径、v1→最新、重复执行（幂等）与降级拒绝 —— 新增列 / 表时扩展它。
- drift **不启用** SQLite 外键，所以 `ON DELETE SET NULL` 永远不会触发：
  `deleteFolderAndUnassign()` 显式清 `folder_id`。
- **迁移没有退路**：升级必须能在老库上补出新列，且不破坏旧密文。

---

## 7. 数据纪律（不可违反）

1. **加密列必须被 `reencryptAll` 覆盖**。历史上漏列 = 那列只能用旧密钥解。
   现在统一走 `VaultItemMapper`，加列不用改轮换逻辑 —— 但要确认新列确实经过它。
   **回收站行同样必须被覆盖**：轮换遍历 `getAllEntries()`（含 `deleted_at` 非空的行），
   漏掉的后果是"恢复一条旧条目后永远解不开它"（`trash_core_test.dart` 钉着）。
2. **改主密码必须整段事务**：`reencryptAll` 的循环包在 `db.transaction` 内。
   中途抛错若不回滚，已处理条目只能用新钥匙开，而主密码还是旧的 ⇒ 静默数据丢失。
3. **明文的边界**：未加密存储的是标题、用户名、URL、文件夹名、类型、收藏位、时间戳
   （列表/搜索/自动填充需要它们）。**库文件本身不是不透明 blob**，别把它当加密容器宣传。
4. **扩展拿不到种子**：bridge 的条目 JSON 只有 `hasTotp`（布尔），没有 TOTP 密钥；
   `getCredentials` 只返回**登录**条目（否则填充面板会出现安全笔记）。
5. **不要吞解密异常后写回明文**；`fromRow(lenient: true)` 只用于"读展示"路径，
   不可用于回写。
6. **UI 不得自己比对 salt/hash**：校验只有 `MasterPasswordVerifier` 一个实现，
   且只跑在核心里（`technical-spec.md` §5.2）。
7. **写路径的授权/状态位只能由核心改**：`agent_access`、`deleted_at` 不接受来自导入/客户端的
   任意值（导入强制清洗）；智能体只能"删进回收站"，不能改开关、不能彻底删除。

---

## 8. 与其它文档的关系

| 想知道 | 看 |
| --- | --- |
| 数据存哪、哪个进程能碰、密码学参数 | `technical-spec.md` §5、§6 |
| 动作层面的读写接口（UI / bridge） | `protocol-api.md` §5、§6 |
| 扩展形状为什么冻结、字段叫什么 | `protocol-api.md` §6 |
| 改 schema 的工程流程与门禁 | `CONTRIBUTING.md` |
| 校验材料为什么放在库里 | `technical-spec.md` §5.2、`SECURITY.md` |
