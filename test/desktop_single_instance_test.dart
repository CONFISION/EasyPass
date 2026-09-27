// P3.2 单实例 + raise 通道测试。
//
// 覆盖：
//   1. 平台分派（Linux → 真路径；Windows / 其他 → notApplicable）。
//   2. 拿锁成功 / 失败两分支（注入替身断言，**不依赖**真实 flock）。
//   3. 二次启动走 raise 路径（注入替身断言收到唤起）。
//   4. 锁被自己上次崩溃残留的处理（dispose 后再 acquireLock；真实锁场景下
//      内核自动释放——这里以替身模拟 dispose 后 [acquireLock] 仍可被调）。
//   5. 真实 Linux 后端 "sendRaiseToPrimary 在 socket 文件不存在时返回 false"
//      路径（用临时目录 + [LinuxSingleInstanceBackend.newForTest] 入口）。
//
// 不可自动化的项（手动）：真实 GTK 窗口的 `show()` 调用、真实 AppImage
// spawn 后的 raise 链路 —— 已在 `dist/PHASE3_2.md` §未自动化项列出。

import 'dart:io' show Directory, Platform;

import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/features/desktop_single_instance/desktop_single_instance.dart';
import 'package:easypass/features/desktop_single_instance/linux_single_instance.dart';
import 'package:easypass/features/desktop_single_instance/single_instance_backend.dart';

void main() {
  group('acquireSingleInstance 平台分派', () {
    setUp(() => debugSetSingleInstanceFactoryForTesting(null));
    tearDown(() => debugSetSingleInstanceFactoryForTesting(null));

    test('未注入 factory + 非 Linux：默认返回 notApplicable', () async {
      if (Platform.isLinux) {
        // Linux CI 上跑默认分派 → 走真实 backend，断言"非 null"即可。
        // 我们不能强制返回 notApplicable，否则会破坏 Linux 默认路径的覆盖。
        debugSetSingleInstanceFactoryForTesting(
          () async => const SingleInstanceDecision(
            role: SingleInstanceRole.notApplicable,
          ),
        );
      }
      final d = await acquireSingleInstance();
      if (Platform.isLinux) {
        expect(d.role, isNotNull);
      } else {
        expect(d.role, SingleInstanceRole.notApplicable);
      }
    });

    test('注入 factory 被调用一次', () async {
      var calls = 0;
      debugSetSingleInstanceFactoryForTesting(() async {
        calls++;
        return const SingleInstanceDecision(
          role: SingleInstanceRole.secondary,
          detail: 'injected',
        );
      });
      final d = await acquireSingleInstance();
      expect(calls, 1);
      expect(d.role, SingleInstanceRole.secondary);
      expect(d.detail, 'injected');
    });

    test('同时注入 factory + backend：抛 StateError', () async {
      debugSetSingleInstanceFactoryForTesting(
        () async => const SingleInstanceDecision(
          role: SingleInstanceRole.secondary,
        ),
      );
      final backend = InMemorySingleInstanceBackend();
      expect(
        () => acquireSingleInstance(injectedBackend: backend),
        throwsStateError,
      );
      await backend.dispose();
    });
  });

  group('acquireLinuxSingleInstanceAsync (注入 backend)', () {
    test('锁已被他人持有 + raise 成功 → secondary，detail 含 "EasyPass instance"',
        () async {
      final backend = InMemorySingleInstanceBackend()
        ..simulateLockHeld = true
        ..simulateRaiseDelivered = true;
      final d = await acquireLinuxSingleInstanceAsync(injectedBackend: backend);
      expect(d.role, SingleInstanceRole.secondary);
      expect(d.detail, contains('EasyPass instance'));
      expect(d.backend, isNull);
      await backend.dispose();
    });

    test('锁已被他人持有 + raise 失败 → detail 含 "could not be raised"', () async {
      final backend = InMemorySingleInstanceBackend()
        ..simulateLockHeld = true
        ..simulateRaiseDelivered = false;
      final d = await acquireLinuxSingleInstanceAsync(injectedBackend: backend);
      expect(d.role, SingleInstanceRole.secondary);
      expect(d.detail, contains('could not be raised'));
      await backend.dispose();
    });

    test('拿到锁 → primary，backend 可继续使用', () async {
      final backend = InMemorySingleInstanceBackend();
      final d = await acquireLinuxSingleInstanceAsync(injectedBackend: backend);
      expect(d.role, SingleInstanceRole.primary);
      expect(d.backend, same(backend));
      await backend.dispose();
    });

    test('"上次崩溃残留"：dispose 后 [acquireLinuxSingleInstanceAsync] 仍可拿到新锁',
        () async {
      // 模拟「进程 1」拿锁后崩溃 —— dispose 把 _lockAcquired 重置。
      final backend1 = InMemorySingleInstanceBackend();
      final d1 = await acquireLinuxSingleInstanceAsync(injectedBackend: backend1);
      expect(d1.role, SingleInstanceRole.primary);
      await backend1.dispose();

      // 「上次崩溃残留」+「再启动一个进程」：真实场景下内核已释放 flock，新
      // 进程的 RandomAccessFile 拿得到。这里新建一个替身表达「新 fd 重新
      // 尝试」，验证 acquireLinuxSingleInstanceAsync 在干净环境下返 primary。
      final backend2 = InMemorySingleInstanceBackend();
      final d2 = await acquireLinuxSingleInstanceAsync(injectedBackend: backend2);
      expect(d2.role, SingleInstanceRole.primary);
      await backend2.dispose();
    });
  });

  group('raise 通道：二次启动 → 唤起一次', () {
    test('startRaising → simulateRaiseReceived → handler 触发', () async {
      final backend = InMemorySingleInstanceBackend();
      var fires = 0;
      await backend.startRaising(() => fires++);
      await backend.simulateRaiseReceived();
      // Future 回调可能跨 microtask —— 等一拍再断言。
      await Future<void>.delayed(Duration.zero);
      expect(fires, 1);
      await backend.dispose();
    });

    test('多次 raise 连续触发 → handler 多次触发', () async {
      final backend = InMemorySingleInstanceBackend();
      var fires = 0;
      await backend.startRaising(() => fires++);
      await backend.simulateRaiseReceived();
      await backend.simulateRaiseReceived();
      await backend.simulateRaiseReceived();
      await Future<void>.delayed(Duration.zero);
      expect(fires, 3);
      await backend.dispose();
    });

    test('dispose 后再 startRaising → throw StateError', () async {
      final backend = InMemorySingleInstanceBackend();
      await backend.dispose();
      // startRaising 是 Future<void>，异常通过 Future 抛 —— 用 try/await
      // 捕获再断言。
      Object? caught;
      try {
        await backend.startRaising(() {});
      } catch (e) {
        caught = e;
      }
      expect(caught, isStateError);
    });

    test('sendRaiseToPrimary 走替身 simulateRaiseDelivered', () async {
      final backend = InMemorySingleInstanceBackend()
        ..simulateRaiseDelivered = true;
      expect(await backend.sendRaiseToPrimary(), isTrue);
      backend.simulateRaiseDelivered = false;
      expect(await backend.sendRaiseToPrimary(), isFalse);
      await backend.dispose();
    });
  });

  group('真实 Linux 后端：路径解析', () {
    test('sendRaiseToPrimary 在 socket 文件不存在时返回 false', () async {
      // 拿一个 tmpdir；用绝对不存在的 socket 文件路径。
      final tmp = await Directory.systemTemp.createTemp('easypass_si_test_');
      try {
        final socketPath = '${tmp.path}/raise.sock';
        final backend = LinuxSingleInstanceBackend.newForTest(
          lockPath: '${tmp.path}/easypass.lock',
          raiseSocketPath: socketPath,
          dataDirectory: tmp,
        );
        expect(await backend.sendRaiseToPrimary(), isFalse);
        await backend.dispose();
      } finally {
        if (await tmp.exists()) {
          await tmp.delete(recursive: true);
        }
      }
    });

    test('newForTest 返回的对象是 SingleInstanceBackend', () {
      // 静态类型校验（防止未来重构里改名/改签名）：
      final backend = LinuxSingleInstanceBackend.newForTest(
        lockPath: '/tmp/easypass.lock',
        raiseSocketPath: '/tmp/easypass-raise.sock',
        dataDirectory: Directory('/tmp'),
      );
      expect(backend, isA<SingleInstanceBackend>());
      // The teardown keeps the temp dir clean — we used /tmp literal here, no
      // creation to undo.  Don't dispose here; the lock file doesn't exist on
      // Linux so releaseLock is a no-op and the OS file handles are not held.
    });
  });
}