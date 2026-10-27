/// 协议 v4 的动作名常量：核心与客户端**共用同一份**，避免字符串拼写漂移。
///
/// 命名沿用既有桥接协议的 camelCase 风格（`getCredentials` 等），因为
/// `browser_extension/background.js` 与 C++ 桥依赖这些字面量。
class Actions {
  Actions._();

  // ─── 会话 / 认证 ────────────────────────────────────────

  /// 状态查询。`ui` 与 `bridge` 都可调用。
  static const String getStatus = 'getStatus';

  /// UI 的认证状态（首设 / 锁定 / 解锁 + 剩余秒数）。
  static const String getAuthState = 'getAuthState';

  /// 在当前会话域内解锁。
  static const String unlock = 'unlock';

  /// 锁定当前会话域；`ui` 域调用会同时锁定 `bridge` 域。
  static const String lock = 'lock';

  /// 首次设置主密码。
  static const String setMasterPassword = 'setMasterPassword';

  /// 原子轮换主密码（核心内事务）。
  static const String changeMasterPassword = 'changeMasterPassword';

  /// 只校验主密码（查看机密前的二次确认），不建立会话。
  static const String verifyMasterPassword = 'verifyMasterPassword';

  /// 把旧版存于系统钥匙串的校验材料交给核心（仅迁移期，只接受一次）。
  static const String adoptLegacyKeyMaterial = 'adoptLegacyKeyMaterial';

  /// 设置空闲自动锁定分钟数（核心持久化并重建定时器）。
  static const String setAutoLockMinutes = 'setAutoLockMinutes';

  /// 报告"用户还在活动"，用于续期空闲计时器。
  ///
  /// 空闲锁定的**权威在核心**：只有核心知道会话还剩多久。UI 在用户有
  /// 指针/键盘活动时节流上报，否则用户停在"不读数据"的页面上（生成器、
  /// 设置页）时，核心会把正在使用的保险库锁掉。
  ///
  /// 只影响调用方所在域（`ui`），不会顺手续期 `bridge` 域 —— 两个域独立
  /// 是刻意设计（D4）。
  static const String touchActivity = 'touchActivity';

  // ─── 读（快照）──────────────────────────────────────────

  static const String listItems = 'listItems';
  static const String getItem = 'getItem';
  static const String listFolders = 'listFolders';
  static const String searchItems = 'searchItems';
  static const String countItemsInFolder = 'countItemsInFolder';
  static const String getHealthReport = 'getHealthReport';
  static const String getTotp = 'getTotp';
  static const String generatePassword = 'generatePassword';

  // ─── 写 ────────────────────────────────────────────────

  static const String saveItem = 'saveItem';
  static const String deleteItem = 'deleteItem';
  static const String addFolder = 'addFolder';
  static const String updateFolder = 'updateFolder';
  static const String removeFolder = 'removeFolder';
  static const String deleteAllData = 'deleteAllData';

  // ─── 导出 / 导入（核心直接读写文件）─────────────────────

  static const String exportVault = 'exportVault';
  static const String importVault = 'importVault';

  // ─── 关于"订阅/快照动作" ────────────────────────────────
  //
  // 这里**故意没有** subscribe / getSnapshot 之类的动作。
  // 3.0.0 的推送模型是：核心在写入事务提交后主动向所有 `ui`/`bridge` 连接广播
  // `changed` 事件（带 topic + revision），客户端收到后自己去调对应的**读动作**
  // 重取快照（见 `lib/features/vault/providers/core_stream.dart`）。
  // 因此不存在"订阅某个主题"的状态，也就不需要订阅动作。
  // 之前这两个常量被列进白名单但从未实现（会落到 `unsupported`），是死代码，
  // 已删除 —— 别再加回来，除非真的引入按主题的服务端订阅状态。

  // ─── 管理 ──────────────────────────────────────────────

  /// 请求核心退出（唯一合法的停机通道）。不受锁定状态限制。
  static const String shutdownCore = 'shutdownCore';

  // ─── 智能体访问（3.1.0；**只在 ui 域**）─────────────────
  //
  // 为什么全部只给 `ui`：配对与解锁是"用户授权"动作，智能体自己永远不能改。
  // 这些是**新增动作**，按协议演进规则不需要递增 `bridgeProtocolVersion`。

  static const String listAgentPairings = 'listAgentPairings';
  static const String createAgentPairing = 'createAgentPairing';
  static const String revokeAgentPairing = 'revokeAgentPairing';
  static const String setAgentAccessMode = 'setAgentAccessMode';
  static const String unlockAgentDomain = 'unlockAgentDomain';
  static const String lockAgentDomain = 'lockAgentDomain';
  static const String getAgentAccessState = 'getAgentAccessState';

  // ─── 扩展既有动作（bridge 专用，形状冻结）───────────────

  static const String getCredentials = 'getCredentials';
  static const String getAllCredentials = 'getAllCredentials';
  static const String searchCredentials = 'searchCredentials';

  /// 浏览器扩展可用的动作白名单（协议 v3 起就是这 9 个）。
  static const Set<String> bridgeAllowed = {
    getStatus,
    unlock,
    lock,
    getCredentials,
    getAllCredentials,
    searchCredentials,
    generatePassword,
    getTotp,
    getHealthReport,
    shutdownCore,
  };

  /// UI 客户端可用的动作。`ui` 域拥有全部动作。
  static const Set<String> uiAllowed = {
    getStatus,
    getAuthState,
    unlock,
    lock,
    setMasterPassword,
    changeMasterPassword,
    verifyMasterPassword,
    adoptLegacyKeyMaterial,
    setAutoLockMinutes,
    touchActivity,
    listItems,
    getItem,
    listFolders,
    searchItems,
    countItemsInFolder,
    getHealthReport,
    getTotp,
    generatePassword,
    saveItem,
    deleteItem,
    addFolder,
    updateFolder,
    removeFolder,
    deleteAllData,
    exportVault,
    importVault,
    shutdownCore,
    // 智能体访问：配对管理、方式切换、agent 域解锁（**只给 ui**）。
    listAgentPairings,
    createAgentPairing,
    revokeAgentPairing,
    setAgentAccessMode,
    unlockAgentDomain,
    lockAgentDomain,
    getAgentAccessState,
  };

  /// **智能体域（`role: agent`）** 的动作白名单。
  ///
  /// 为什么单独一份，而且**不是** `bridgeAllowed` 的子集：智能体是"可被提示注入
  /// 驱动的调用者"，与"用户点一下自动填充的浏览器扩展"不是一个确定性等级。
  /// `bridgeAllowed` 里有 `unlock` / `getTotp` / `shutdownCore`，这些能力一旦被
  /// 智能体拿到，等于绕过整个授权模型（见 `docs/agent-mcp-spec.md` 的 I-3）。
  ///
  /// 阶段 0 先留空 —— **空集合 = 默认全拒**，比"先继承 bridge 再慢慢收"安全。
  /// 阶段 1 起由 `AgentActions` 逐个填入（`status` / `begin_session` /
  /// `listAgentItems` / …）；届时本集合仍必须与 bridge 白名单**没有交集**。
  static const Set<String> agentAllowed = <String>{};

  /// 角色 → 动作白名单；**未知角色返回 `null`，调用方必须拒绝该连接**。
  ///
  /// 单一来源：握手期的角色校验与服务端分发都走这里，避免"两处各判一次"
  /// 之后慢慢分叉。曾经 `_dispatch` 写的是 `role == 'ui' ? ui : bridge`，
  /// 于是任何非 ui 角色都继承了 bridge 的全部权限 —— `agent` 只是文档里的
  /// 预留，代码层面等于 bridge。
  static Set<String>? allowedFor(String role) {
    switch (role) {
      case 'ui':
        return uiAllowed;
      case 'bridge':
        return bridgeAllowed;
      case 'agent':
        return agentAllowed;
      default:
        return null;
    }
  }

  /// 握手阶段可接受的角色（`allowedFor` 非空即合法）。
  static bool isKnownRole(String role) => allowedFor(role) != null;
}

