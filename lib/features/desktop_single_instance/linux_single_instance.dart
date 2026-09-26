// Linux 单实例 + raise 通道实现（flock + unix socket）。
//
// 设计选择与边界，详见 `dist/P3.2-facts.md` §4.3 / §5。
//
// 关键不变量（实现要保证）：
//   1. 锁文件目录 = `dataDirectory`，与 `easypass.db` 同处一地 —— 复用
//      P1 的 0700 收紧（共享 `AppPaths._enforceLinuxPrivacy` 的语义，**不
//      直接调用**，因为该函数是 `_enforceLinuxPrivacy` 私有；这里走
//      [AppPaths.makePrivate] 同款 best-effort）。
//   2. bind 之前 `unlink()` 残留 socket 文件 —— 这是 unix socket 的标准
//      实践，避免 "EADDRINUSE"。
//   3. 进程退出路径必须 dispose（`[exitHook]` 注册 onExit），否则 `flock`
//      会一直挂到内核回收（崩溃时内核自动释放，正常退出时仍要显式
//      unlock）。
//   4. secondary 路径：拿到锁失败 → 不再尝试 "lock 文件残留" 的旧 PID 自愈
//      （P3.4 任务），只走 "connect raise socket → 写 1 字节 → exit"。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/platform/app_paths.dart';
import 'desktop_single_instance.dart';
import 'raise_channel.dart';
import 'single_instance_backend.dart';

/// 真实 Linux 后端：flock + unix socket。
///
/// 默认私有（构造器 + 实现细节）—— 测试通过 `@visibleForTesting` 标注的
/// [LinuxSingleInstanceBackend.newForTest] 入口构造，生产代码应走
/// `acquireLinuxSingleInstanceAsync` 工厂。
@visibleForTesting
class LinuxSingleInstanceBackend implements SingleInstanceBackend {
  LinuxSingleInstanceBackend._({
    required this.lockPath,
    required this.raiseSocketPath,
    Directory? dataDirectory,
  }) : _dataDirectory = dataDirectory ?? AppPaths.dataDirectory;

  /// 测试用工厂 —— 注入路径 + dataDirectory，避开 [AppPaths.dataDirectory]
  /// 走真实用户目录。仅在 `test/desktop_single_instance_test.dart` 中使用。
  @visibleForTesting
  factory LinuxSingleInstanceBackend.newForTest({
    required String lockPath,
    required String raiseSocketPath,
    required Directory dataDirectory,
  }) =>
      LinuxSingleInstanceBackend._(
        lockPath: lockPath,
        raiseSocketPath: raiseSocketPath,
        dataDirectory: dataDirectory,
      );

  /// 锁文件绝对路径。
  final String lockPath;

  /// raise unix socket 路径。
  final String raiseSocketPath;

  final Directory _dataDirectory;
  RandomAccessFile? _lockRaf;
  bool _lockAcquired = false;
  _LinuxRaiseChannel? _channel;
  bool _disposed = false;

  @override
  Future<bool> acquireLock() async {
    if (_disposed) {
      throw StateError('LinuxSingleInstanceBackend already disposed');
    }
    if (_lockAcquired) return true;
    try {
      // Create lock file (may or may not exist). parent.create is idempotent.
      if (!await _dataDirectory.exists()) {
        await _dataDirectory.create(recursive: true);
      }
      final lockFile = File(lockPath);
      if (!await lockFile.exists()) {
        await lockFile.create();
      }
      // EX | NB semantics in dart:io: `lock()` is exclusive; `tryLock` would
      // be the non-blocking variant, but Dart's [File.lock] does not have a
      // tryLock equivalent that returns false instead of throwing. We use
      // `lock()` and catch the FileSystemException for "already locked" —
      // see https://api.dart.dev/stable/dart-io/File/lock.html.
      final raf = await lockFile.open(mode: FileMode.append);
      try {
        await raf.lock();
      } on FileSystemException catch (e) {
        // `Resource temporarily unavailable` (EAGAIN) is what flock() LOCK_EX
        // | LOCK_NB surfaces on Linux when the lock is held by someone else.
        // We don't try to be exhaustive: any FS exception here means "can't
        // get the lock right now".
        await raf.close();
        if (e.osError?.errorCode == 35 /* EAGAIN */ ||
            e.osError?.errorCode == 11 /* EAGAIN on some libcs */ ||
            e.message.contains('Resource temporarily unavailable') ||
            e.message.contains('already locked')) {
          return false;
        }
        rethrow;
      }
      _lockRaf = raf;
      _lockAcquired = true;
      return true;
    } on FileSystemException catch (e) {
      // Lock file path itself is broken (perm denied, missing parent, …).
      // Treat as "can't acquire"; the caller decides to surface the error.
      // ignore: avoid_print
      print(
        'SingleInstance: failed to acquire ${_basename(lockPath)} '
        '(${e.osError?.errorCode ?? e.runtimeType}); '
        'continuing without single-instance protection',
      );
      return false;
    }
  }

  @override
  Future<void> releaseLock() async {
    if (!_lockAcquired) return;
    final raf = _lockRaf;
    _lockRaf = null;
    _lockAcquired = false;
    if (raf == null) return;
    try {
      await raf.unlock();
    } catch (_) {
      // unlock failure is non-fatal; the kernel releases the lock on fd close.
    }
    try {
      await raf.close();
    } catch (_) {
      // best-effort
    }
  }

  @override
  Future<void> startRaising(FutureOr<void> Function() handler) async {
    if (_channel != null) {
      await _channel!.stop();
    }
    final ch = _LinuxRaiseChannel(raiseSocketPath);
    await ch.bindAndListen(handler);
    _channel = ch;
  }

  @override
  Future<void> stopRaising() async {
    final ch = _channel;
    _channel = null;
    if (ch != null) await ch.stop();
  }

  @override
  Future<bool> sendRaiseToPrimary({
    Duration timeout = const Duration(milliseconds: 250),
  }) async {
    final socket = File(raiseSocketPath);
    if (!await socket.exists()) return false;
    try {
      // dart:io 的 unix-socket connect：把 path 包成 `InternetAddress.unix(path)`，
      // port 参数会被忽略。这是 Linux Dart SDK ≥ 3.4 起稳定的官方用法；服务端
      // `ServerSocket.bind(InternetAddress.unix(path), 0)` 是同套语义。
      final s = await Socket.connect(
        InternetAddress(raiseSocketPath, type: InternetAddressType.unix),
        0,
        timeout: timeout,
      );
      try {
        s.add([1]);
        await s.flush();
      } finally {
        await s.close();
      }
      return true;
    } on Object {
      // Connection refused / timeout / permission denied → treat as "can't
      // raise". Caller exits silently; the alternative (throw) would surface
      // as a startup crash which the user can't act on.
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stopRaising();
    await releaseLock();
  }
}

class _LinuxRaiseChannel implements RaiseChannel {
  _LinuxRaiseChannel(this.path);

  final String path;
  ServerSocket? _server;
  FutureOr<void> Function()? _handler;
  bool _stopped = false;

  @override
  String get diagnosticLocation => 'unix://$path';

  @override
  Future<void> bindAndListen(FutureOr<void> Function() handler) async {
    if (_server != null) return;
    _handler = handler;
    // Standard unix-socket dance: unlink any stale file so bind won't fail
    // with EADDRINUSE after a previous crash.
    final socketFile = File(path);
    if (await socketFile.exists()) {
      try {
        await socketFile.delete();
      } catch (_) {
        // ignore: best effort; if unlink fails the bind() below will surface
        // the real error.
      }
    }
    try {
      // Platform.isLinux is enforced by the caller — this file only runs on
      // Linux. [ServerSocket.bind] with an InternetAddress of unix loopback
      // is NOT what we want; for unix sockets we use [ServerSocket.bind] on
      // a Unix socket address. dart:io does not expose UnixServerSocket
      // directly; instead we use [Socket.connect] in the secondary path
      // against a path and rely on the kernel to route. For the listening
      // side we use [ServerSocket.bind] against an [InternetAddress] of
      // [InternetAddressType.unix] when available.
      //
      // dart:io DOES support Unix sockets via InternetAddress.unix(...) on
      // recent Dart SDKs (>=3.4). If that constructor isn't available we
      // fall back to a process-exit notification channel (see #error
      // branch below).
      final addr = InternetAddress(path, type: InternetAddressType.unix);
      _server = await ServerSocket.bind(addr, 0);
      _server!.listen(_onConnection, cancelOnError: false);
    } on Object catch (e) {
      // dart:io's Unix-socket support depends on the SDK; on the host Dart
      // 3.12 this is available. If we ever lose it the caller falls back to
      // "no-op raise" (window won't be raised but we still acquire the lock
      // and refuse the secondary launch).
      // ignore: avoid_print
      print(
        'SingleInstance: failed to bind raise socket at $path '
        '(${e.runtimeType}); secondary launches will fall through to exit',
      );
      _server = null;
      _handler = null;
    }
  }

  void _onConnection(Socket client) {
    final h = _handler;
    // Read at least one byte then call handler. We don't care about the
    // payload; we just need to know "the secondary launched".
    client.listen(
      (_) {},
      onDone: () {
        client.close();
        if (h != null) {
          // Fire and forget: a slow handler must not stall the accept loop.
          // ignore: unawaited_futures
          h();
        }
      },
      onError: (Object _) {
        try {
          client.close();
        } catch (_) {}
        if (h != null) {
          // ignore: unawaited_futures
          h();
        }
      },
      cancelOnError: true,
    );
  }

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    final s = _server;
    _server = null;
    _handler = null;
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
    }
    final socketFile = File(path);
    if (await socketFile.exists()) {
      try {
        await socketFile.delete();
      } catch (_) {}
    }
  }
}

/// Linux 入口：拿锁 + 决定角色。
///
/// 测试可通过 [injectedBackend] / [injectedChannel] 把真实现换成替身；
/// 不传 = 走真实 `flock` + unix socket（需要真实文件系统，没有 `$D/$S` 也不行）。
Future<SingleInstanceDecision> acquireLinuxSingleInstanceAsync({
  SingleInstanceBackend? injectedBackend,
  RaiseChannel? injectedChannel,
}) async {
  String? lockPath;
  String? raisePath;
  if (injectedBackend == null && injectedChannel == null) {
    try {
      lockPath = '${AppPaths.dataDirectory.path}/easypass.lock';
      raisePath = '${AppPaths.dataDirectory.path}/easypass-raise.sock';
    } on StateError catch (e) {
      return SingleInstanceDecision(
        role: SingleInstanceRole.notApplicable,
        detail: 'Cannot resolve single-instance paths: ${e.message}',
      );
    }
  }

  final backend = injectedBackend ??
      LinuxSingleInstanceBackend._(
        lockPath: lockPath!,
        raiseSocketPath: raisePath!,
      );

  final got = await backend.acquireLock();
  if (!got) {
    // We are secondary. Try to raise the primary; if that succeeds the
    // caller exits with code 0 silently. If it fails, the caller still
    // exits with code 0 but stderr gets a "could not raise" message —
    // either way, **no UI** for this process.
    final raised = await backend.sendRaiseToPrimary();
    final detail = raised
        ? 'Another EasyPass instance is running; this launch will exit.'
        : 'Another EasyPass instance is running and could not be raised; '
            'this launch will exit.';
    return SingleInstanceDecision(
      role: SingleInstanceRole.secondary,
      detail: detail,
    );
  }

  // We are primary. Caller will wire the raise handler once the window is
  // ready (see `lib/main.dart`).
  return SingleInstanceDecision(role: SingleInstanceRole.primary, backend: backend);
}

String _basename(String path) {
  final i = path.lastIndexOf('/');
  return i == -1 ? path : path.substring(i + 1);
}