import 'dart:async';

import 'package:easypass/core_service/vault_session.dart';

/// 核心服务内的会话域。
///
/// 为什么是两个域而不是一个（D4 决策）：桌面端解锁**不**等于把浏览器/智能体
/// 也解锁 —— 那会让"解锁"这个显式动作静默扩大访问面。反过来，桌面端点"锁定"
/// 必须把两边都锁掉（否则用户锁了 App，浏览器还开着）。
enum SessionDomain {
  /// 桌面 UI 的会话。
  ui,

  /// 浏览器扩展 / 未来智能体的会话。
  bridge,
}

/// 会话域集合：各自一份密钥副本与空闲计时器，外加"谁锁了"的传播规则。
class SessionDomains {
  SessionDomains({required Duration idleTimeout}) {
    _ui = VaultSession(idleTimeout: idleTimeout);
    _bridge = VaultSession(idleTimeout: idleTimeout);
    _lastKnown[SessionDomain.ui] = false;
    _lastKnown[SessionDomain.bridge] = false;
    // 解锁/锁定**立即**触发比对与广播，不等 5 秒节拍器 ——
    // 见 `VaultSession.onStateChanged` 的注释（"关窗上锁只生效一次"的根因）。
    _ui.onStateChanged = notifyIfChanged;
    _bridge.onStateChanged = notifyIfChanged;
  }

  late VaultSession _ui;
  late VaultSession _bridge;

  final Map<SessionDomain, bool> _lastKnown = {};
  Timer? _timer;
  bool _notifying = false;

  /// 状态翻转回调（域, 是否解锁）。核心用它广播 `sessionLocked/sessionUnlocked`。
  void Function(SessionDomain domain, bool unlocked)? onStateChanged;

  /// 定时检查间隔：`VaultSession` 的过期是**惰性**的（读 `isUnlocked` 才判定），
  /// 因此必须有这个节拍器才能把"空闲超时"变成可推送的事件。
  static const Duration tickInterval = Duration(seconds: 5);

  VaultSession get ui => _ui;

  VaultSession get bridge => _bridge;

  VaultSession of(SessionDomain domain) =>
      domain == SessionDomain.ui ? _ui : _bridge;

  void start() {
    _timer ??= Timer.periodic(tickInterval, (_) => notifyIfChanged());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// UI 锁定 ⇒ 两个域一起锁（既有语义：锁 App 不能留下解锁的浏览器会话）。
  void lockAll() {
    _ui.lock();
    _bridge.lock();
    notifyIfChanged();
  }

  /// 更新空闲超时（用户改设置）。就地改字段，保住已解锁的钥匙。
  void setIdleTimeout(Duration value) {
    _ui.idleTimeout = value;
    _bridge.idleTimeout = value;
  }

  Duration get idleTimeout => _ui.idleTimeout;

  /// 检查两个域的状态并在翻转时回调。
  ///
  /// 防重入：读 `isUnlocked` 可能触发惰性过期 → `lock()` → 又回调到这里。
  /// 没有这个标记会绕成一个（无害但没必要的）递归。
  void notifyIfChanged() {
    if (_notifying) return;
    _notifying = true;
    try {
      for (final domain in SessionDomain.values) {
        final unlocked = of(domain).isUnlocked;
        if (_lastKnown[domain] != unlocked) {
          _lastKnown[domain] = unlocked;
          onStateChanged?.call(domain, unlocked);
        }
      }
    } finally {
      _notifying = false;
    }
  }
}



