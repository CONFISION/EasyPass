/// 条目类型（对标 Bitwarden 的 item type，但用可读字符串而非魔数）。
///
/// 存储与协议都用 [wireName]，**不要**依赖枚举下标：
/// - DB：`password_entries.type`（TEXT，默认 `'login'`，2.3.0 起）
/// - 桥接协议：[wireName] 出现在条目 JSON 的 `type` 字段（契约 3）
/// - 导出：[wireName] 出现在 JSON 的 `type` 字段（导出格式 2.0.0）
///
/// 未知值一律回退到 [EntryType.login]（旧导出/旧 daemon 的条目没有 type 字段，
/// 它们在 2.2.x 里本来就只可能是登录条目）。
enum EntryType {
  /// 登录（用户名 + 密码 + URL + TOTP），**唯一**参与浏览器表单自动填充的类型。
  login('login'),

  /// 安全笔记：正文放在通用 `notes` 字段里，可另加自定义字段。
  secureNote('secure_note'),

  /// 身份信息：姓名/证件号/地址/电话等，用于填写表单与备查。
  identity('identity'),

  /// SSH 密钥：公钥 + 私钥 + 口令 + 指纹。
  sshKey('ssh_key');

  const EntryType(this.wireName);

  /// 持久化 / 协议 / 导出用的稳定标识符。
  final String wireName;

  /// 未知输入的回退类型。
  static const EntryType fallback = EntryType.login;

  /// 只有登录条目参与自动填充（内容脚本按用户名/密码/TOTP 填表）。
  bool get isAutofillable => this == EntryType.login;

  /// 从任意来源（DB 列、协议 JSON、导入文件）解析类型，容错且不抛异常。
  ///
  /// 接受的别名：`note` / `securenote` / `secure-note` → [secureNote]；
  /// `ssh` / `sshkey` / `ssh-key` → [sshKey]；`password` / `credential` → [login]。
  static EntryType fromWire(Object? value) {
    if (value is EntryType) return value;
    if (value is String) {
      switch (value.trim().toLowerCase()) {
        case 'login':
        case 'password':
        case 'credential':
          return EntryType.login;
        case 'note':
        case 'notes':
        case 'secure_note':
        case 'secure-note':
        case 'securenote':
          return EntryType.secureNote;
        case 'identity':
          return EntryType.identity;
        case 'ssh':
        case 'ssh_key':
        case 'ssh-key':
        case 'sshkey':
          return EntryType.sshKey;
      }
    }
    return fallback;
  }
}
