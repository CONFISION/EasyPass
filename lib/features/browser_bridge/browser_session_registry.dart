import 'vault_session.dart';

/// 进程内浏览器会话登记处。
///
/// 背景（C 方案的安全一致性）：daemon 持有跨连接共享的 [VaultSession]，
/// 解锁态可以在浏览器连接断开后继续保留（空闲超时才清除）。这带来一个
/// 容易忽略的缺口——**用户在桌面端点"锁定"后，扩展侧仍可能处于解锁态**，
/// 直到空闲超时为止。
///
/// 解决办法：daemon 在启动时把它的会话登记到这里，桌面端的 `AuthNotifier.lock()`
/// 顺带调用 [lockIfAny]，于是"锁定桌面端"= "立刻锁定扩展会话"，行为与用户
/// 预期一致（Bitwarden 同理）。
///
/// 有意**不**做反方向的传播：桌面端解锁不会自动把扩展解锁，浏览器需要用户
/// 自己输入一次主密码。这样"解锁"始终是一次显式动作，不会因为桌面端解锁而
/// 静默扩大浏览器的访问权限。
///
/// 说明：这是进程内单例，仅用于同进程的 UI ↔ daemon 联动；daemon 独立进程
/// （`--service`）下没有 UI，登记后也不会有人调用 [lockIfAny]，行为不变。
class BrowserSessionRegistry {
  BrowserSessionRegistry._();

  static VaultSession? _session;

  /// daemon 启动时登记它实际使用的会话。
  static void register(VaultSession session) {
    _session = session;
  }

  /// 会话所属 daemon 停止时注销（避免指向已废弃的会话）。
  static void unregister(VaultSession session) {
    if (identical(_session, session)) _session = null;
  }

  /// 当前登记的会话（测试用）。
  static VaultSession? get current => _session;

  /// 立即锁定扩展侧会话；没有登记的会话时是空操作。
  static void lockIfAny() {
    _session?.lock();
  }
}
