# EasyPass 协议 API 规范（协议 5）

> **本地文档**（`docs/` 被 `.gitignore` 忽略，见 `technical-spec.md` §13 的入库建议）。
> 本文是**对外接口契约**：任何客户端（桌面 UI、浏览器桥、未来的 MCP）都按本文实现。
>
> 实现位置：`lib/protocol/**`（线格式，核心与客户端共用）+ `lib/core_service/**`（服务端）。
> 契约变更纪律见 §9。

---

## 1. 传输与分帧

| 项 | 值 |
| --- | --- |
| 传输 | TCP，`127.0.0.1:<port>`（端口来自 `daemon.json` 的 `port`；核心默认固定 `47820`） |
| 连接认证 | 见 §2 握手；令牌**永不上线** |
| 分帧 | 4 字节**小端**无符号长度 + 负载；单帧上限 64 MiB（`frames.dart` `maxFramePayloadBytes`） |
| 负载 | 握手阶段是 UTF-8 JSON 明文；**握手完成后全是密文**（§3） |
| 流式读取 | 必须用**有状态** reader（`NativeMessageReader`）：一个 TCP chunk 里可能有多帧 |

> ⚠️ **历史教训**：每帧新建缓冲的读法会把同一 chunk 里的第二帧丢掉，对端只能等超时
> （扩展"偶发卡死 30 秒"的根因）。服务端握手与 serve 循环必须共用同一个 reader 实例。

---

## 2. 握手（4 步，明文阶段）

客户端先发 `clientNonce`；服务端回 `serverNonce` + **自己的证明**；客户端回**自己的证明**；
服务端确认并**从这一帧起全部加密**。

### 步骤 1 — 客户端 → 核心

```jsonc
{
  "hello": "easypass",
  "clientNonce": "<32 字节随机数的 hex，64 字符>",
  "role": "ui",                 // ui | bridge | agent
  "protocolVersion": 5,
  "clientVersion": "3.0.0"
}
```

### 步骤 2 — 核心 → 客户端（明文）

成功：

```jsonc
{
  "serverNonce": "<64 hex>",
  "serverProof": "<HMAC-SHA256 hex，64 字符>",
  "coreVersion": "3.0.0",
  "protocolVersion": 5
}
```

拒绝（不进入后续步骤，连接随即关闭）：

```jsonc
{ "ok": false, "error": "unsupported", "coreVersion": "3.0.0", "protocolVersion": 5 }
```

证明算法（`lib/protocol/secure_channel.dart`）：

```
serverProof = HMAC-SHA256(key = tokenBytes, msg = "easypass-server-proof" + "|" + clientNonce + "|" + serverNonce)
clientProof = HMAC-SHA256(key = tokenBytes, msg = "easypass-client-proof" + "|" + clientNonce + "|" + serverNonce)
tokenBytes  = hexDecode(token)（失败则退回 token 的 UTF-8 字节）
```

**客户端必须校验 `serverProof`**：不校验等于允许任何本机进程抢占端口冒充核心。

### 步骤 3 — 客户端 → 核心（明文）

```jsonc
{ "clientProof": "<64 hex>" }
```

`clientProof` 不匹配 ⇒ 核心发明文 `{"ok":false,"error":"unauthorized"}` 并关闭连接。

### 步骤 4 — 核心 → 客户端（**密文**）

握手完成后的第一帧就是密文（用派生出的方向密钥加密）：

```jsonc
{
  "ok": true,
  "coreVersion": "3.0.0",
  "protocolVersion": 5,
  "role": "ui",
  "capabilities": ["events", "multiType", "uiActions", "shutdown"]
}
```

> **为什么末帧也加密**：早期实现里这一帧是明文，能力表（`uiActions`）会暴露在抓包里。
> 明文阶段现在只剩 nonce 与两个 HMAC 证明，**不含令牌、不含任何业务字段**。

### 2.1 Windows x86 桥的兼容路径（v4 明文握手）

C++ 桥无法实现 AES/HMAC，走一条**受限的**兼容分支（`lib/core_service/core_service.dart`
的 `_onConnection`）：

```jsonc
// 客户端 → 核心（**必须 role 缺省或 "bridge"**）
{ "token": "<daemon.json 里的 token>" }
// 核心 → 客户端（明文；本连接的后续帧也是明文）
{ "ok": true, "coreVersion": "3.0.0", "protocolVersion": 5, "role": "bridge", "encrypted": false, "capabilities": [...] }
```

约束：
- 该分支**只接受 bridge 角色**；显式传 `ui` / `agent` 一律回 `unsupported`（"核心与 UI 之间禁止明文"的强制点）。
- 不校验 `protocolVersion`（桥是字节转发器，不理解协议；它承载的动作形状自协议 3 起冻结）。
- 明文连接**不接收事件**（`_broadcast` 跳过无 channel 的连接）。

---

## 3. 加密帧格式

握手完成后，每帧负载是 `SecureChannel.seal()` 的输出：

```
┌──────────┬────────────────────────┬──────────────┐
│ IV (16B) │ ciphertext (变长)       │ tag (32B)     │
└──────────┴────────────────────────┴──────────────┘
```

- 加密：AES-256-CBC + PKCS7，**每帧新随机 IV**。
- 认证：`HMAC-SHA256(macKey, IV ‖ ciphertext)`，**先验 MAC 再解密**（encrypt-then-MAC），
  常数时间比较。
- 密钥派生（每连接独立）：

```
prk     = HMAC-SHA256(key = tokenBytes, msg = clientNonce + "|" + serverNonce)
okm     = HKDF-Expand(prk, info = "easypass-channel-v5", len = 128)
c2sEnc  = okm[0..32)     c2sMac = okm[32..64)
s2cEnc  = okm[64..96)    s2cMac = okm[96..128)
```

**方向隔离**：客户端发用 `c2s*`，核心发用 `s2c*`。用错方向 ⇒ MAC 不匹配 ⇒ 拒绝。
解不开的帧必须**断开连接**，不得降级成空消息（`SecureChannelException`）。

---

## 4. 请求 / 响应信封

```jsonc
// 请求
{ "requestId": "<任意唯一串>", "action": "listItems", "folderId": "f1" }
// 成功
{ "requestId": "...", "data": { ... } }
// 失败
{ "requestId": "...", "error": "保险库已锁定", "errorCode": "locked" }
```

- `requestId` 由客户端生成，响应原样回显（**必需**：桥/扩展靠它匹配请求）。
- 参数**平铺**在请求对象顶层（与桥接协议一致）；也兼容 `{"params": {...}}` 包裹
  （核心的 `_flattenParams` 会合并）。
- **`error` 永远是字符串**（扩展的 `gradeDaemonError` 依赖它），`errorCode` 是 v5 新增的
  结构化补充；客户端可以不看 `errorCode`。

### 4.1 能力与角色

| 角色 | 白名单 | 说明 |
| --- | --- | --- |
| `ui` | **43 个动作**（见 §5） | 完整客户端面；连接一定是加密的 |
| `bridge` | **10 个动作**（见 §6） | 形状冻结；可能是明文（x86 桥） |
| `agent` | **0 个动作**（空集合） | 独立会话域；智能体走核心自己的 HTTP MCP 端点（`127.0.0.1:47821`，见 §5.7 与 `technical-spec.md` §12），**不从本协议发帧动作** |

角色不在白名单里 ⇒ `{"error":"Unsupported action for role ...","errorCode":"unsupported"}`。

---

## 5. UI 域动作（43 个）

### 5.1 会话 / 认证

| 动作 | 参数 | 返回 |
| --- | --- | --- |
| `getStatus` | — | `connected`、`locked`、`entryCount`、`idleTimeoutSeconds`、`autoLockRemainingSeconds`、`protocolVersion`、`coreVersion`、`hasAuthMaterial`、`autoLockMinutes` |
| `getAuthState` | — | `status`（`firstRun`/`locked`/`unlocked`）、`autoLockMinutes`、`remainingSeconds`、`hasAuthMaterial` |
| `unlock` | `password` | `{success: true}`。密码错 ⇒ `errorCode: unauthorized`；无校验材料 ⇒ `needsKeyMigration` |
| `lock` | — | `{success: true}`。**锁 `ui` 域的同时锁 `bridge` 域** |
| `setMasterPassword` | `password`、`confirmPassword` | `{success: true}`（首设；成功后 `ui` 域即解锁） |
| `changeMasterPassword` | `currentPassword`、`newPassword`、`confirmPassword` | `{success, reencrypted, keyMaterialPersisted}`；成功后**两个域都锁定** |
| `verifyMasterPassword` | `password` | `{ok: bool}`（只校验，不建会话；连续失败会 `rateLimited`） |
| `adoptLegacyKeyMaterial` | `salt`、`passwordHash` | `{ok: true}`。**仅当核心还没有校验材料时**接受，重复调用 ⇒ `invalidRequest` |
| `setAutoLockMinutes` | `minutes`（1–60，核心会 clamp） | `{ok: true, autoLockMinutes}` |
| `touchActivity` | — | `{ok: true}`。只续期 `ui` 域（**不**动 `bridge`） |

### 5.2 读

| 动作 | 参数 | 返回 |
| --- | --- | --- |
| `listItems` | `folderId?`、`type?`（`login`/`secure_note`/`identity`/`ssh_key` 或别名）、`favoritesOnly?` | `{items: [VaultItemJson]}` |
| `getItem` | `id` | `{item: VaultItemJson}`；不存在 ⇒ `notFound` |
| `listFolders` | — | `{folders: [{id,name,icon,created_at,updated_at}]}` |
| `searchItems` | `query`（支持 `type:` / `folder:` / `url:` 前缀；空查询 ⇒ 空数组） | `{items: [...]}` |
| `countItemsInFolder` | `folderId` | `{count}` |
| `getHealthReport` | — | 见 §5.5 |
| `getTotp` | `entryId` | `{code, period, remainingSeconds}`（种子不出核心） |
| `generatePassword` | `length`、`useUpper`、`useLower`、`useNumbers`、`useSymbols` | `{password}` |

### 5.3 写

| 动作 | 参数 | 返回 |
| --- | --- | --- |
| `saveItem` | `item`（`VaultItemJson`） | `{id}` |
| `deleteItem` | `id` | `{ok: true, trashed: true}` —— **语义=移到回收站**（schema 5 起是软删，可恢复；见 §5.8） |
| `addFolder` | `name`、`icon?`（默认 `folder`） | `{id}` |
| `updateFolder` | `id`、`name?`、`icon?` | `{ok: true}` |
| `removeFolder` | `id` | `{ok: true, unassigned}`（条目**保留**并解绑） |
| `deleteAllData` | `confirm: true`（缺失 ⇒ `invalidRequest`） | `{ok, entries, folders}`（核心内单事务） |

### 5.4 导出 / 导入（核心直接读写文件）

| 动作 | 参数 | 返回 |
| --- | --- | --- |
| `exportVault` | `format`：`plain`/`encrypted`/`bitwarden`；`path`（绝对路径） | `{ok, path, bytes}` |
| `importVault` | `format`：`easypass`/`bitwardenJson`/`bitwardenCsv`；`path` | `{ok, imported, folders, skipped}`；bitwarden 额外回 `skippedDetails[]`、`extraUris`、`cardsAsNotes` |

> 设计要点：UI **只传路径**，文件由核心读写 —— 明文不必搬进 UI 进程，导入的原子事务也只能在核心内。

### 5.5 `getHealthReport` 响应

```jsonc
{
  "totalEntries": 5,          // 参与评分的**登录**条目数
  "score": 67,                // 0–100
  "level": "fair",            // good | fair | poor
  "reusedGroupCount": 1,
  "weakPasswords": [{ "entryId": "...", "entryName": "...", "reason": "commonPassword" }],
  "reusedPasswords": [{ "entryId": "...", "entryName": "...", "sharedCount": 2 }],
  "noTotpEntries": [{ "entryId": "...", "entryName": "..." }],
  "noUrlEntries": [{ "entryId": "...", "entryName": "..." }]
}
```

`reason` 取值：`tooShort` / `singleCharType` / `commonPassword`。
**响应里没有任何明文密码或 TOTP 种子**。

### 5.6 条目 JSON（UI 形状）

UI 拿的是**完整明文**（要显示/编辑密码与 TOTP 种子）：

```jsonc
{
  "id": "...", "folder_id": "f1" | null, "type": "login",
  "name": "...", "notes": "...", "is_favorite": false,
  "created_at": 1750000000000, "updated_at": 1750000000000,
  "login": { "url": "...", "username": "...", "password": "...", "totp_secret": "..." },
  "identity": { ... },              // 仅 identity 类型
  "ssh_key": { ... },               // 仅 ssh_key 类型
  "custom_fields": [{ "label": "...", "value": "...", "type": "text|hidden|boolean" }]
}
```

### 5.7 智能体访问（12 个，3.1.0）

这些动作**只对 `ui` 角色开放**。智能体自己不用本协议（它走核心的 HTTP MCP 端点，
见 `technical-spec.md` §12），UI 用这组动作管理开关、配对、访问方式与审批回话。

| 动作 | 参数 | 返回 |
| --- | --- | --- |
| `getAgentAccessState` | — | `{enabled, agentUnlocked}` |
| `enableAgentAccess` | — | `{ok, enabled: true, agentUnlocked: true}`；需 `ui` 域已解锁 |
| `disableAgentAccess` | — | `{ok, enabled: false, agentUnlocked: false}`；同时停 MCP 监听 |
| `resetAgentKey` | — | `{ok, enabled, agentUnlocked}`；换一把专属密钥重新包裹，库密文一个字节不动 |
| `unlockAgentDomain` | `password` | `{ok, agentUnlocked}` |
| `lockAgentDomain` | — | `{ok, agentUnlocked: false}` |
| `listAgentPairings` | — | `{pairings: [{id, nickname, mode, trusted, createdAt, lastUsedAt, calls}], agentUnlocked}`；**不返回密钥哈希** |
| `createAgentPairing` | `nickname`（唯一）、`mode`（`approval`/`trusted`）、`password`（`trusted` 时必填） | `{id, key, nickname, mode, trusted}` —— `key` **只在这里出现一次** |
| `revokeAgentPairing` | `id` | `{ok, agentUnlocked, remaining}`；配对记录被**彻底删除** |
| `setAgentAccessMode` | `id`、`mode`、`password`（切 `trusted` 时必填） | `{ok, agentUnlocked}`；切回 `approval` 会**立刻锁 agent 域** |
| `respondAgentApproval` | `approvalId`、`allow`、`allowStandingRead?` | `{ok}`；`ok:false` = 该审批已超时/已被处理 |
| `listAgentAudit` | `limit?`（1–500，默认 100） | `{entries: [{at, nickname, mode, tool, op, entryId, entryName, decision}], total}` |

> 配对密钥（`key`）库里只存 SHA-256；UI 只在创建那一次展示/复制它。
> 审计的 `decision` 取 `allowed` / `allowed_standing`（「本会话内允许读取」放行）/
> `denied` / `timeout` / `error`（执行失败兜底；一次调用只写一行）。

### 5.8 回收站（4 个，3.1.0 / schema 5）

删除 = 移到回收站（软删）；彻底删除只存在于这组 UI 动作，**不在智能体工具面里**。

| 动作 | 参数 | 返回 |
| --- | --- | --- |
| `listTrash` | — | `{items: [VaultItemJson…]}`（**完整明文**，与 `listItems` 同形状；回收站界面要显示条目信息） |
| `restoreItem` | `id` | `{ok: true}`；不在回收站 / 不存在 ⇒ `notFound` |
| `permanentlyDeleteItem` | `id` | `{ok: true}`；**只接受回收站里的条目**，正常条目 ⇒ `notFound` |
| `emptyTrash` | — | `{ok: true, deleted: n}` |

语义细节见 `data-model.md` §2.0：列表 / 搜索 / 健康 / 计数 / 导出默认排除回收站；
主密码轮换仍会重新加密回收站里的行。

---

## 6. Bridge 域动作（10 个，形状冻结）

这些动作的**字段名与形状自协议 3 起冻结**，因为 C++ 桥、`background.js` 与
`probe_bridge.mjs` 都依赖它们。**不要为了统一而改名。**

| 动作 | 参数 | 返回 |
| --- | --- | --- |
| `getStatus` | — | `connected`、`locked`、`entryCount`、`idleTimeoutSeconds`、`autoLockRemainingSeconds`、`protocolVersion` |
| `unlock` | `password` | `{success: true}` |
| `lock` | — | `{success: true}` |
| `getCredentials` | `url?` | **仅登录条目**；按域名匹配，匹配不到回退全部登录条目 |
| `getAllCredentials` | — | **所有类型**（popup 列表用） |
| `searchCredentials` | `query` | 匹配名称/URL/用户名/类型专属字段 |
| `generatePassword` | `options: {length,useUpper,useLower,useNumbers,useSymbols}` | `{password}` |
| `getTotp` | `entryId` | **`{totp, remaining, period}`**（注意：与 UI 的 `{code, period, remainingSeconds}` 字段名不同，见下方说明） |
| `getHealthReport` | — | 同 §5.5 |
| `shutdownCore` | — | `{ok: true}` 后连接断开 |

条目 JSON（bridge 形状，**受限**）：

```jsonc
{
  "id": "...", "type": "login", "name": "...",
  "url": "...", "username": "...", "password": "...", "notes": "...",
  "hasTotp": true,                  // 只有布尔值，**没有种子**
  "isFavorite": false,
  "identity": { ... }, "sshKey": { ... },
  "customFields": [ ... ]
}
```

> **两套 `getTotp` 形状不一致是故意的**：bridge 侧 `{totp, remaining, period}` 是扩展
> 已依赖的冻结契约（`browser_extension/popup/popup.js` 读 `totp` 与 `remaining`）；
> UI 侧是 v5 新增的客户端面，用了更明确的名字。改任何一侧都要同步对应客户端与测试。

---

## 7. 事件（核心 → 客户端）

服务端在写入事务提交后**主动广播**；客户端收到后**自己重取快照**（不推送数据本身）。

```jsonc
{ "event": "changed",         "topic": "items", "revision": 42 }
{ "event": "changed",         "topic": "item",  "revision": 43, "id": "<entryId>" }
{ "event": "sessionLocked",   "domain": "ui" }        // domain: ui | bridge | agent
{ "event": "sessionUnlocked", "domain": "bridge" }
{ "event": "agentApprovalRequested",
  "approvalId": "a_...", "nickname": "DSH", "tool": "list_entries",
  "op": "read", "entryId": null, "entryName": null, "allowStanding": true }
{ "event": "coreShuttingDown" }
```

- `agentApprovalRequested`（3.1.0，方式 1 专用）：智能体的调用被挂起，核心在等 UI 回话
  （最长 45 秒，**超时按拒绝**）。UI 用 `respondAgentApproval` 回应；
  只有 `ui` 客户端需要处理它，其它客户端应忽略。

| 主题 | 何时推 | 客户端动作 |
| --- | --- | --- |
| `items` | 条目增删改、文件夹改动、导入 | 重取 `listItems`（含当前过滤条件） |
| `item` | 单个条目变化（带 `id`） | 重取 `getItem(id)` |
| `folders` | 文件夹增删改 | 重取 `listFolders` |
| `search` | 任何可能影响搜索结果的写入 | 用当前查询词重取 `searchItems` |
| `agentAccess` | 智能体访问总开关打开 / 关闭 / 重置 / 改密重包裹 | 重取 `getAgentAccessState`（侧边栏「智能体活动」入口显隐） |
| `agentAudit` | 核心每写入一条智能体审计 | 重取 `listAgentAudit`（活动页实时刷新） |

> **写路径必须广播**：任何新增的"往库里写条目"的入口（智能体工具、导入、后台任务）
> 都要推 `items` / `item`（必要时 `folders` / `search`），否则 UI 不会刷新。
> 智能体侧由 `AgentActions.onDataChanged` 负责，核心在 `CoreService` 里接线。

- `revision` 是**进程内**单调递增计数，不跨重启持久化；重连后客户端应全量重取。
- `sessionLocked` / `sessionUnlocked` 带 `domain`：**UI 只跟随 `ui` 域**，`bridge` / `agent`
  的域事件必须忽略 —— 否则"浏览器扩展解锁"会让桌面端误显示成解锁态（D4：解锁必须是显式动作）。
- 客户端建议 50ms 去抖合并同一主题的连续事件。
- 未解锁时收到的 `changed` 可以忽略（解锁后全量重取）。
- **没有 `subscribe` 动作**：广播是无条件的，服务端不维护"订阅状态"。

---

## 8. 错误码

| `errorCode` | 含义 | 典型场景 |
| --- | --- | --- |
| `unauthorized` | 未授权 | 主密码错、`clientProof` 不匹配、角色不允许 |
| `locked` | 保险库已锁定 | 数据动作在未解锁时被调用 |
| `notFound` | 目标不存在 | `getItem` 的 id 不存在 |
| `invalidRequest` | 参数缺失/类型不对 | 两次密码不一致、`deleteAllData` 缺 `confirm` |
| `unsupported` | 未知动作 / 协议版本太低 / 角色越权 | 旧客户端、`subscribe` 之类的死动作 |
| `needsKeyMigration` | 校验材料尚未迁移到核心 | 升级后还没打开过 UI |
| `rateLimited` | 触发限速 | `verifyMasterPassword` 连续失败 |
| `storageError` | 磁盘/数据库写失败 | 只读介质、权限问题 |
| `cryptoError` | 加解密失败 | 密文损坏、密钥不对 |
| `internal` | 核心内部异常 | 兜底 |

对应的用户文案在 `lib/protocol/errors.dart` 的 `ErrorMessages`（中文），客户端可直接展示
或按 `errorCode` 自行本地化。

---

## 9. 版本演进规则

`AppConstants.bridgeProtocolVersion`（当前 **5**）与
`browser_extension/background.js` 的 `EXPECTED_PROTOCOL_VERSION` **必须同步**。

| 变更类型 | 是否递增 `protocolVersion` |
| --- | --- |
| 新增动作 | ❌ 不需要 |
| 新增响应字段 | ❌ 不需要（旧客户端忽略即可） |
| 新增事件类型 / 主题 | ❌ 不需要（不认识就忽略） |
| 删除或改名动作 | ✅ 需要 |
| 改变某动作的语义或响应形状 | ✅ 需要 |
| 改变握手/加密方式 | ✅ 需要 |

**3.1.0 的智能体动作**（§5.7）**、回收站动作**（§5.8）与 `agentApprovalRequested` 事件属于
"新增动作 / 新增事件"，**协议版本仍是 5**，旧客户端不认就忽略；不用改 `EXPECTED_PROTOCOL_VERSION`。

**协议 5 的破坏点**（相对 4）：握手改为 nonce + 双向 HMAC 证明（令牌不再上线）、
握手末帧起全帧加密、`role: ui|agent` 禁止明文连接。v5 核心对旧客户端回 `unsupported`。

**退役旧核心**：客户端读 `daemon.json` 的 `protocolVersion`，低于当前即判为陈旧
（`CoreInfo.isStale`），删发现文件后拉起新核心。详见 `technical-spec.md` §8.3。

---

## 10. 完整往返示例

```
# 1) 客户端 → 核心（明文）
{"hello":"easypass","clientNonce":"9f2c…","role":"ui","protocolVersion":5,"clientVersion":"3.0.0"}
# 2) 核心 → 客户端（明文）
{"serverNonce":"41ab…","serverProof":"d3e1…","coreVersion":"3.0.0","protocolVersion":5}
# 3) 客户端 → 核心（明文）
{"clientProof":"7c90…"}
# 4) 核心 → 客户端（密文；解密后）
{"ok":true,"coreVersion":"3.0.0","protocolVersion":5,"role":"ui","capabilities":["events","multiType","uiActions","shutdown"]}

# 5) 请求（密文）
{"requestId":"7-1750000000123","action":"listItems","type":"login"}
# 6) 响应（密文）
{"requestId":"7-1750000000123","data":{"items":[{...}]}}

# 7) 写入后，核心主动广播（密文）
{"event":"changed","topic":"items","revision":1}
# 8) 客户端重取
{"requestId":"8-…","action":"listItems","type":"login"}
```

---

## 11. 调试与探针

| 工具 | 用途 |
| --- | --- |
| `dart run tool\probe_core.dart --core <核心>` | 走完整握手 + 19 项动作面（**只跑空库**） |
| `dart run tool\probe_channel_security.dart --core <核心>` | 11 项安全性质：链路无明文、令牌不上线、旧协议被拒、错误令牌被拒 |
| `node browser_extension/tools/probe_bridge.mjs` | 端到端（可用 `EASYPASS_BRIDGE` 指定桥路径） |
| `node browser_extension/tools/probe_daemon.mjs` | 直连已运行核心 |
| `easypass_core --status` | 打印 `daemon.json` + `getStatus` 摘要（JSON；未运行退 1） |

诊断提示：
- 报 `Unknown action: xxx` ⇒ 对端是**旧版本**（协议不匹配），不是代码 bug。
- 报 `核心身份校验失败（serverProof 不匹配）` ⇒ 端口被别的进程占用，或 `daemon.json` 过期。
- 报 `保险库已锁定` ⇒ 先 `unlock`（`ui` 域）或用 `--lock`/`getAuthState` 确认状态。
