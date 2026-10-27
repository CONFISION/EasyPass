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

  /// 浏览器扩展的会话。
  bridge,

  /// 智能体（MCP）的会话。
  ///
  /// **独立于 `ui` 与 `bridge`**：智能体是可被提示注入驱动的调用者，
  /// 不能借用"用户自己解锁了 App / 浏览器"带来的解锁态（见 MCP spec 的 I-3 与 D4）。
  /// 空闲超时同样独立（默认 5 分钟），`end_session` 会立刻把它锁掉。
  agent,
}

/// 会话域集合：各自一份密钥副本与空闲计时器，外加"谁锁了"的传播规则。
class SessionDomains {
  SessionDomains({required Duration idleTimeout}) {
    _ui = VaultSession(idleTimeout: idleTimeout);
    _bridge = VaultSession(idleTimeout: idleTimeout);
    _agent = VaultSession(idleTimeout: idleTimeout);
    _lastKnown[SessionDomain.ui] = false;
    _lastKnown[SessionDomain.bridge] = false;
    _lastKnown[SessionDomain.agent] = false;
    // 解锁/锁定**立即**触发比对与广播，不等 5 秒节拍器 ——
    // 见 `VaultSession.onStateChanged` 的注释（"关窗上锁只生效一次"的根因）。
    _ui.onStateChanged = notifyIfChanged;
    _bridge.onStateChanged = notifyIfChanged;
    _agent.onStateChanged = notifyIfChanged;
  }

  late VaultSession _ui;
  late VaultSession _bridge;
  late VaultSession _agent;

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

  /// 智能体会话域。**绝不与 ui/bridge 共享密钥实例**：`VaultSession._wipe()` 是
  /// 原地清零，共享实例会让"锁一个域"顺手清掉另一个域的密钥。
  VaultSession get agent => _agent;

  VaultSession of(SessionDomain domain) {
    switch (domain) {
      case SessionDomain.ui:
        return _ui;
      case SessionDomain.bridge:
        return _bridge;
      case SessionDomain.agent:
        return _agent;
    }
  }

  void start() {
    _timer ??= Timer.periodic(tickInterval, (_) => notifyIfChanged());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// UI 锁定 ⇒ 所有域一起锁（既有语义：锁 App 不能留下解锁的浏览器会话）。
  /// 智能体接口起 agent 域也纳入：用户锁库时智能体不该还能读。
  void lockAll() {
    _ui.lock();
    _bridge.lock();
    _agent.lock();
    notifyIfChanged();
  }

  /// 更新空闲超时（用户改设置）。就地改字段，保住已解锁的钥匙。
  void setIdleTimeout(Duration value) {
    _ui.idleTimeout = value;
    _bridge.idleTimeout = value;
    _agent.idleTimeout = value;
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



