/// 协议错误码（`errorCode` 字段的取值）。
///
/// 兼容性纪律：**响应里的 `error` 字段必须继续是字符串** —— 扩展侧
/// `background.js` 的 `gradeDaemonError(message.error)` 依赖它。`errorCode`
/// 是 v4 新增的结构化补充字段，客户端可以不看。
class ErrorCodes {
  ErrorCodes._();

  /// token 不匹配 / 角色不允许 / 未握手。
  static const String unauthorized = 'unauthorized';

  /// 保险库处于锁定态，该动作需要先解锁。
  static const String locked = 'locked';

  /// 目标条目 / 文件夹不存在。
  static const String notFound = 'notFound';

  /// 参数缺失或类型不对。
  static const String invalidRequest = 'invalidRequest';

  /// 未知动作或当前协议版本不支持。
  static const String unsupported = 'unsupported';

  /// 校验材料尚未迁移到核心（`adoptLegacyKeyMaterial` 之前）。
  static const String needsKeyMigration = 'needsKeyMigration';

  /// 触发限速（例如连续错误的二次校验）。
  static const String rateLimited = 'rateLimited';

  /// 磁盘 / 数据库写入失败。
  static const String storageError = 'storageError';

  /// 加解密失败。
  static const String cryptoError = 'cryptoError';

  static const String internal = 'internal';
}

/// 核心服务在 `error` 字段里回的中文可读文案（客户端可直接展示）。
class ErrorMessages {
  ErrorMessages._();

  static const String unauthorized = '未授权的连接';
  static const String locked = '保险库已锁定';
  static const String notFound = '找不到该条目';
  static const String invalidRequest = '请求参数无效';
  static const String unsupported = '不支持的操作';
  static const String needsKeyMigration = '需要先打开一次桌面应用完成升级';
  static const String rateLimited = '尝试过于频繁，请稍后再试';
  static const String storageError = '存储读写失败';
  static const String cryptoError = '解密失败';
  static const String internal = '核心内部错误';
}
