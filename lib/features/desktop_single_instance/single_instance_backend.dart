// 单实例后端抽象 + 内存替身。
//
// 之所以抽这一层：
//   1. **测试不依赖 `flock` / unix socket**。锁真实能不能拿 / socket 真实能不
//      能 connect 是 OS 行为，单测模拟不出"NFS 不支持 flock"等边界。替身把
//      "拿锁成功 / 失败 / socket 收消息" 三件事全留成 callback，测试驱动它。
//   2. **Linux 实现可单点替换**：未来要切 D-Bus / TCP port，只需要新写一个
//      backend 实现，不动调用点。
//   3. **进程退出钩子**：测试要能验证"主进程异常退出时锁会不会残留"—— 替身
//      直接暴露 [release]，逻辑显式。

import 'dart:async';

/// 后端的最小职责：拿/放锁 + 启/停 raise 通道。
abstract class SingleInstanceBackend {
  /// 尝试获取锁。成功 = true。
  Future<bool> acquireLock();

  /// 释放锁（[acquireLock] 返回 true 时才调用）。幂等。
  Future<void> releaseLock();

  /// 启动 raise 监听；收到任何字节就走 [handler]；返回值可被 [stopRaising]
  /// 取消。`primary` 进程拿到锁后调一次。
  Future<void> startRaising(FutureOr<void> Function() handler);

  /// 取消 raise 监听（与 [startRaising] 配对）。幂等。
  Future<void> stopRaising();

  /// 作为 secondary 进程：连接已有实例并发送 raise 消息（一个字节即可）。
  /// 返回 true = 已送达；false = 连接失败（主实例已退出 / socket 文件残留
  /// 但没人 listen 等）。调用方按 false 处理 → 通常是"无可唤起，UI 退出"。
  Future<bool> sendRaiseToPrimary({Duration timeout = const Duration(milliseconds: 250)});

  /// 进程退出 / 异常路径上统一清理（best-effort）。允许再次调用。
  Future<void> dispose();
}

/// 测试替身：所有行为由测试控制。
///
/// 用法：
/// ```dart
/// final backend = InMemorySingleInstanceBackend();
///
/// // 模拟"已被他人持有"
/// backend.simulateLockHeld = true;
/// expect(await backend.acquireLock(), isFalse);
///
/// // 模拟"我们是 primary + 收到 raise"
/// backend.simulateLockHeld = false;
/// expect(await backend.acquireLock(), isTrue);
/// final fired = <int>[];
/// await backend.startRaising(() => fired.add(1));
/// await backend.simulateRaiseReceived();
/// expect(fired, [1]);
/// await backend.dispose();
/// ```
class InMemorySingleInstanceBackend implements SingleInstanceBackend {
  /// `true` 时 [acquireLock] 返回 false（模拟"二次启动"）。
  bool simulateLockHeld = false;

  /// [sendRaiseToPrimary] 的返回值（默认 true = 送达）。
  bool simulateRaiseDelivered = true;

  /// 收到的 raise 次数（调试用）。
  int raisesReceived = 0;

  Completer<void>? _pendingRaise;
  FutureOr<void> Function()? _handler;
  bool _acquired = false;
  bool _disposed = false;

  @override
  Future<bool> acquireLock() async {
    if (_disposed) {
      throw StateError('InMemorySingleInstanceBackend already disposed');
    }
    if (simulateLockHeld) return false;
    _acquired = true;
    return true;
  }

  @override
  Future<void> releaseLock() async {
    if (!_acquired) return;
    _acquired = false;
  }

  @override
  Future<void> startRaising(FutureOr<void> Function() handler) async {
    if (_disposed) {
      throw StateError('InMemorySingleInstanceBackend already disposed');
    }
    _handler = handler;
  }

  @override
  Future<void> stopRaising() async {
    _handler = null;
  }

  @override
  Future<bool> sendRaiseToPrimary({Duration timeout = const Duration(milliseconds: 250)}) async {
    return simulateRaiseDelivered;
  }

  /// 测试驱动：假装主实例收到一个 raise 字节。
  ///
  /// 若 [_handler] 不为 null，会异步调一次；否则只增计数器、不报错（便于
  /// "raise 在 startRaising 之前到达" 的边界测试）。
  Future<void> simulateRaiseReceived() async {
    raisesReceived += 1;
    final h = _handler;
    if (h == null) {
      _pendingRaise = Completer<void>();
      return _pendingRaise!.future;
    }
    await h();
  }

  /// 等待一个尚未被 [startRaising] 接管的 raise（race 测试）。
  Future<void> awaitPendingRaise() async {
    final p = _pendingRaise;
    if (p == null) return;
    await p.future;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await releaseLock();
    await stopRaising();
  }
}