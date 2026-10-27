class AppConstants {
  AppConstants._();

  static const String appName = 'EasyPass';
  static const String secureStorageKey = 'easypass_master_key';
  static const String masterPasswordHashKey = 'easypass_master_pw_hash';
  static const String firstRunKey = 'easypass_first_run';
  static const String autoLockStorageKey = 'easypass_auto_lock_minutes';
  static const String fontFamilyStorageKey = 'easypass_font_family';
  static const String themeModeStorageKey = 'easypass_theme_mode';

  /// 首次启动的"浏览器集成"提示是否已展示过。
  static const String browserHostPromptKey = 'easypass_browser_host_prompted';

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
  /// - 版本 4 = 3.0.0：核心服务化。客户端握手带 `role`（`ui` / `bridge` /
  ///   `agent`），核心推送 `changed` / `sessionLocked` 等事件，新增 UI 动作面
  ///   与 `shutdownCore`。**v3 核心是旧的 Flutter `--service` 进程**，v4 客户端
  ///   不再与它对话（`daemon.json` 里没有 `coreVersion` 即判为陈旧）。
  ///
  /// 用途：**升级后旧的 daemon 进程可能仍在服务扩展**（它不认识新动作，
  /// 只会回 `Unknown action: xxx`）。[EasypassDaemon.probe] 用这个常量判定
  /// "陈旧"并接管，`getStatus` 会把它下发给扩展。
  ///
  /// 同步位置（改这个值时必须一起改）：
  /// - `browser_extension/background.js` 的 `EXPECTED_PROTOCOL_VERSION`
  /// - `browser_extension/tools/probe_daemon.mjs`（只读取并打印，无需改常量）
  static const int bridgeProtocolVersion = 5;

  // `daemon.json` 字段名（daemon 写入；桥接、扩展探针、probe_daemon.mjs 读取）。
  // 缺 `protocolVersion` 或 `pid` 的文件一律按"陈旧"处理（见 EasypassDaemon.probe）。
  static const String daemonInfoPortKey = 'port';
  static const String daemonInfoTokenKey = 'token';
  static const String daemonInfoProtocolVersionKey = 'protocolVersion';
  static const String daemonInfoPidKey = 'pid';

  /// 智能体接口（MCP）的 HTTP 端口。
  ///
  /// 纯新增字段：旧客户端不认识就忽略；缺这个字段说明该核心没启用 MCP。
  /// 端口取**临时端口**（不固定），避免与机器上的其他服务抢端口。
  static const String daemonInfoMcpPortKey = 'mcpPort';

  // ─── 核心服务（v3.0 架构改造）────────────────────────────

  /// 核心服务版本。
  ///
  /// M7 时与 `pubspec.yaml` / 设置页 / 扩展 manifest / `.iss` 四处同步；
  /// 目前带 `-dev` 后缀，表示尚未进入发布流程。
  static const String coreVersion = '3.0.0';

  /// 核心服务的**固定回环端口**：既是单实例闸门（第二个核心 bind 会失败），
  /// 也是 `daemon.json` 之外"核心是否在跑"的一条旁证。
  ///
  /// 端口被别的程序占用时核心退化为临时端口（此时唯一性只靠 `daemon.json`
  /// 探测保证），见 `lib/core_service/core_singleton.dart`。
  static const int coreFixedPort = 47820;
}