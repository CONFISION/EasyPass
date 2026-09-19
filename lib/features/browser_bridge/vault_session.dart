import 'dart:typed_data';

/// 保险库会话（C 方案）：解锁态跨连接保持 + 空闲超时惰性清除。
///
/// 背景：2.0 daemon 为每个浏览器连接新建一个 `NativeMessagingService`，
/// 原先每个连接各持一份会话密钥，连接一断（浏览器 MV3 service worker 30 秒
/// 就会被回收）就得重新输主密码，扩展无法日用。
///
/// 安全权衡（有意为之，不是遗漏）：
/// - **便利**：会话由 daemon 持有并在连接之间共享，解锁一次即可持续使用；
/// - **代价**：派生密钥在 daemon 进程内存中常驻，理论上可被内存转储/调试器
///   读取（进程被攻破的场景下与"每次连接重新派生"相比暴露窗口更长）；
/// - **收敛**：空闲 [idleTimeout]（默认 5 分钟）后自动清除；用户点"锁定"、
///   或进程退出也会清除。[lock] 会先把密钥字节清零再丢引用，尽量减少内存中
///   的明文残留（Dart 无法保证编译器不复制，这里是尽力而为）。
///
/// 过期判定是**惰性**的：不引入定时器，任何 [isUnlocked] / [key] / [remaining]
/// 读取都会先检查是否已空闲超时，超时则立刻 [lock]。
class VaultSession {
  /// 空闲多久后自动锁定。
  final Duration idleTimeout;

  /// 可注入时钟，便于单测过期逻辑；默认 [DateTime.now]。
  final DateTime Function() _clock;

  /// 当前会话密钥；锁定/过期后为 null。
  Uint8List? _key;

  /// 最后一次活跃时间（unlock / touch 时刷新）；锁定时为 null。
  DateTime? _lastActiveAt;

  VaultSession({
    this.idleTimeout = const Duration(minutes: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 是否处于解锁态。惰性过期：读取时若已空闲超时 → 先行锁定。
  bool get isUnlocked {
    _expireIfIdle();
    return _key != null;
  }

  /// 会话密钥（引用，不复制）；锁定或已过期时返回 null。
  Uint8List? get key {
    _expireIfIdle();
    return _key;
  }

  /// 距离自动锁定还剩多久；已锁定返回 null。
  Duration? get remaining {
    _expireIfIdle();
    final lastActiveAt = _lastActiveAt;
    if (_key == null || lastActiveAt == null) return null;

    final idle = _clock().difference(lastActiveAt);
    final left = idleTimeout - idle;
    // 负值不应该出现（_expireIfIdle 已处理），保险起见夹到 0。
    return left.isNegative ? Duration.zero : left;
  }

  /// 解锁并记录活跃时间。重复解锁会先清零上一份密钥。
  void unlock(Uint8List key) {
    _wipe();
    _key = key;
    _lastActiveAt = _clock();
  }

  /// 锁定：先把密钥字节清零，再丢弃引用，避免内存中残留明文密钥。
  void lock() {
    _wipe();
    _lastActiveAt = null;
  }

  /// 刷新活跃时间（保险库读操作成功后调用）。
  /// 锁定时是空操作，不会凭空"解锁"。
  void touch() {
    if (_key == null) return;
    _lastActiveAt = _clock();
  }

  /// 清理密钥引用并清零其字节。
  void _wipe() {
    final key = _key;
    if (key != null) {
      key.fillRange(0, key.length, 0);
    }
    _key = null;
  }

  /// 惰性过期：空闲时间达到 [idleTimeout] 即锁定。
  void _expireIfIdle() {
    final lastActiveAt = _lastActiveAt;
    if (_key == null || lastActiveAt == null) return;
    if (_clock().difference(lastActiveAt) >= idleTimeout) {
      lock();
    }
  }
}
