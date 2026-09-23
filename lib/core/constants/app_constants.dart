class AppConstants {
  AppConstants._();

  static const String appName = 'EasyPass';
  static const String secureStorageKey = 'easypass_master_key';
  static const String masterPasswordHashKey = 'easypass_master_pw_hash';
  static const String firstRunKey = 'easypass_first_run';
  static const String autoLockStorageKey = 'easypass_auto_lock_minutes';
  static const String fontFamilyStorageKey = 'easypass_font_family';
  static const String themeModeStorageKey = 'easypass_theme_mode';

  // Font options
  static const String defaultFontFamily = 'Maple Mono NF CN';
  static const String systemFontOption = 'system';
  static const String monospaceFontOption = 'monospace';

  // PBKDF2 settings
  static const int pbkdf2Iterations = 100000;
  static const int pbkdf2KeyLength = 32; // 256-bit
  static const int pbkdf2SaltLength = 32;

  // AES settings
  static const int aesKeySize = 256;
  static const int aesIvLength = 16;

  // Auto-lock timeout (minutes)
  static const int autoLockTimeoutMinutes = 5;

  // ─── Browser bridge protocol ────────────────────────────

  /// 扩展 ↔ 桌面端 daemon 的桥接协议版本。
  ///
  /// **只有发生不兼容变更时才递增**：新增动作、新增响应字段属于兼容变更，
  /// 不需要动它；删除/改名动作、改变某个动作的语义或响应形状才需要。
  ///
  /// - 版本 1 = 未写版本号的 2.0.0 daemon（`daemon.json` 里没有
  ///   `protocolVersion` 字段，`getStatus` 也不回报版本）。
  /// - 版本 2 = 2.2.0：新增 `getHealthReport`；`getStatus` 增加
  ///   `idleTimeoutSeconds` / `autoLockRemainingSeconds` 并回报本版本号；
  ///   条目 JSON 用 `hasTotp` 取代明文 `totp`；帧读取改为有状态 reader。
  /// - 版本 3 = 2.3.0：条目 JSON 增加 `type` / `identity` / `sshKey` /
  ///   `customFields` 字段块（多条目类型），`getCredentials` 语义收紧为
  ///   **只返回登录条目**。旧 daemon（协议 2）不知道类型，会把安全笔记 / SSH
  ///   密钥当登录条目吐给扩展，因此这里必须递增，好让
  ///   [EasypassDaemon.probe] 把陈旧 daemon 换掉。
  ///
  /// 用途：**升级后旧的 daemon 进程可能仍在服务扩展**（它不认识新动作，
  /// 只会回 `Unknown action: xxx`）。[EasypassDaemon.probe] 用这个常量判定
  /// "陈旧"并接管，`getStatus` 会把它下发给扩展。
  ///
  /// 同步位置（改这个值时必须一起改）：
  /// - `browser_extension/background.js` 的 `EXPECTED_PROTOCOL_VERSION`
  /// - `browser_extension/tools/probe_daemon.mjs`（只读取并打印，无需改常量）
  static const int bridgeProtocolVersion = 3;

  // `daemon.json` 字段名（daemon 写入；桥接、扩展探针、probe_daemon.mjs 读取）。
  // 缺 `protocolVersion` 或 `pid` 的文件一律按"陈旧"处理（见 EasypassDaemon.probe）。
  static const String daemonInfoPortKey = 'port';
  static const String daemonInfoTokenKey = 'token';
  static const String daemonInfoProtocolVersionKey = 'protocolVersion';
  static const String daemonInfoPidKey = 'pid';
}