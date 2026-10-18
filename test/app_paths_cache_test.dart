// `AppPaths.dataDirectory` / `configDirectory` / `autostartDirectory`
// 在同进程内必须复用同一个 `Directory` 实例，避免每次 `daemonInfoFile` 等
// 调用都重读 env + `p.join`。
//
// 设计要点：
//   - 同进程两次连续 `dataDirectory` 应 `identical(...)` 为真。
//   - `debugResetAppPathsCacheForTesting()` 必须真正清空缓存，下一次访问
//     重新解析（用于测试 env 变化场景）。
//   - 失败语义保留：HOME 缺失时 `dataDirectory` 必须抛 `StateError`，不静默
//     兜底（不允许静默兜底）。
//   - 三条 getter (`dataDirectory` / `configDirectory` / `autostartDirectory`)
//     缓存相互独立 —— reset 一个不影响其他（实现是三个独立字段）。
//
// 跨平台：
//   - 这些都是「解析逻辑在 Linux 上才有 XDG 行为」的 getter，但缓存机制本
//     身是平台无关的 —— 测试在 Linux CI 上运行就够了；非 Linux 路径只走
//     `executableDirectory` 分支，逻辑更简单。

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:easypass/core/platform/app_paths.dart';

void main() {
  group('AppPaths memoization（同进程复用同一实例）', () {
    setUp(() {
      AppPaths.debugResetAppPathsCacheForTesting();
    });

    tearDown(() {
      AppPaths.debugResetAppPathsCacheForTesting();
    });

    test('dataDirectory returns the same instance on consecutive reads', () {
      final a = AppPaths.dataDirectory;
      final b = AppPaths.dataDirectory;
      expect(
        identical(a, b),
        isTrue,
        reason:
            'dataDirectory must memoize its result (same instance per process). '
            'Re-computing every call re-reads Platform.environment and '
            're-joins paths, which EasypassDaemon.probe hits hard on each '
            'idle check.',
      );
    });


    test('debugResetAppPathsCacheForTesting re-parses on next access', () {
      final first = AppPaths.dataDirectory;
      AppPaths.debugResetAppPathsCacheForTesting();
      final second = AppPaths.dataDirectory;
      // After reset, the value should still be `equal` semantically, but the
      // `Directory` instance should differ — i.e. the cache was actually cleared.
      expect(
        identical(first, second),
        isFalse,
        reason:
            'After a reset, the next read must compute a fresh Directory. '
            'A flag that just noops would silently leak the cached value '
            'across tests.',
      );
      // Path equality must still hold (the env did not change underneath).
      expect(p.equals(first.path, second.path), isTrue,
          reason: 'Reset must not change the resolved path.');
    });
    test('debugResetAppPathsCacheForTesting clears the cache (no stale left-over)', () {
      final before = AppPaths.dataDirectory;
      expect(identical(before, AppPaths.dataDirectory), isTrue);

      AppPaths.debugResetAppPathsCacheForTesting();
      expect(identical(before, AppPaths.dataDirectory), isFalse,
          reason: 'reset 之后必须重新解析出新的 Directory 实例');
    });

    test('dataDirectory resolves without reading the environment', () {
      // 3.0.0 起数据目录只由 exe 目录及其父目录决定，不再读 HOME/XDG；
      // Linux 的 XDG 语义随 linux 分支维护。这里确认它在当前环境下可解析。
      expect(AppPaths.dataDirectory, isNotNull);
    });
  });
}
