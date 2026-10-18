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

  // ─── 订阅 / 快照 ────────────────────────────────────────

  static const String subscribe = 'subscribe';
  static const String getSnapshot = 'getSnapshot';

  // ─── 管理 ──────────────────────────────────────────────

  /// 请求核心退出（唯一合法的停机通道）。不受锁定状态限制。
  static const String shutdownCore = 'shutdownCore';

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
    subscribe,
    getSnapshot,
    shutdownCore,
  };
}
