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
///
/// **例外（`agent` 域）**：智能体会话域不参与空闲自动锁定（[autoLockEnabled] 为
/// false），生命周期只由总开关、显式锁与核心退出决定 —— 见 `SessionDomains`
/// 的 D1 说明。
class VaultSession {
  /// 空闲多久后自动锁定。
  ///
  /// 可变：核心服务在用户改"自动锁定分钟数"时要**就地**更新 ui/bridge 两个
  /// 会话域的超时；重建 [VaultSession] 会把已解锁的钥匙丢掉。
  ///
  /// 对 [autoLockEnabled] 为 false 的会话（agent 域）这个字段没有实际意义：它只
  /// 影响 [remaining] 的展示，不产生过期。
  Duration idleTimeout;

  /// 是否参与空闲自动锁定（默认 true）。
  ///
  /// 为什么 agent 域关掉它：智能体访问的语义是"用户一次授权、之后零介入"，
  /// 空闲 5 分钟就锁会让可信直通在无人值守时确定性地失效；agent 域的钥匙只在
  /// 核心里，收回路径是总开关/显式锁/核心退出，不依赖空闲计时。
  final bool autoLockEnabled;

  /// 可注入时钟，便于单测过期逻辑；默认 [DateTime.now]。
  final DateTime Function() _clock;

  /// 当前会话密钥；锁定/过期后为 null。
  Uint8List? _key;

  /// 最后一次活跃时间（unlock / touch 时刷新）；锁定时为 null。
  DateTime? _lastActiveAt;

  VaultSession({
    this.idleTimeout = const Duration(minutes: 5),
    this.autoLockEnabled = true,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 状态翻转回调（解锁 / 锁定后立即触发）。
  ///
  /// 由 [SessionDomains] 注入，用来把 `sessionLocked` / `sessionUnlocked`
  /// 广播出去。**这是修复"关窗上锁只生效一次"的关键**：早期只靠
  /// `SessionDomains` 的 5 秒节拍器比对 `isUnlocked`，导致"解锁后 5 秒内关窗"
  /// 时 `_lastKnown` 还停在 `false`，`lockAll()` 看到 `false → false` 判定
  /// "没变化"，于是**不广播** —— UI 收不到 `sessionLocked`，停在解锁态，
  /// 而核心其实已经锁了（界面拿不到数据）。
  void Function()? onStateChanged;

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
  ///
  /// **不参与空闲自动锁定的会话（[autoLockEnabled] == false）恒为 null**：它没有
  /// "还剩多久自动锁"这个概念，生命周期由总开关与显式锁控制。
  Duration? get remaining {
    _expireIfIdle();
    final lastActiveAt = _lastActiveAt;
    if (_key == null || lastActiveAt == null) return null;
    if (!autoLockEnabled) return null;

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
    onStateChanged?.call();
  }

  /// 锁定：先把密钥字节清零，再丢弃引用，避免内存中残留明文密钥。
  void lock() {
    final hadKey = _key != null;
    _wipe();
    _lastActiveAt = null;
    // 本来就没有密钥时不回调：避免无变化的空转广播。
    if (hadKey) onStateChanged?.call();
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
  ///
  /// [autoLockEnabled] 为 false 的会话永远不因时间过期（解锁/锁定只由显式调用
  /// 驱动）。
  void _expireIfIdle() {
    if (!autoLockEnabled) return;
    final lastActiveAt = _lastActiveAt;
    if (_key == null || lastActiveAt == null) return;
    if (_clock().difference(lastActiveAt) >= idleTimeout) {
      lock();
    }
  }
}


