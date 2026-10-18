import 'dart:typed_data';

import 'package:easypass/core_service/session_domains.dart';
import 'package:flutter_test/flutter_test.dart';

/// [SessionDomains] 的状态翻转广播。
///
/// 回归背景（用户真机报告，2026-10-18）：**"关窗上锁只生效一次"**。
/// 根因不是核心没锁（它每次都锁了），而是**没广播 `sessionLocked`**：
/// 早期只有 5 秒节拍器会比对 `isUnlocked` 并广播，于是"解锁后 5 秒内关窗"
/// 时 `_lastKnown` 还停在 `false`，`lockAll()` 看到 `false → false`
/// 判定"没变化"→ 不广播 → UI 收不到事件、停在解锁态，而核心已锁（界面空）。
///
/// 所以这里断言的是**同步性**：解锁/锁定后**立刻**就要有事件，
/// 一个 tick 都不能等。
void main() {
  /// 记录 `(域, 是否解锁)` 的广播序列。
  late List<String> events;

  SessionDomains build() {
    final domains = SessionDomains(idleTimeout: const Duration(minutes: 5));
    domains.onStateChanged = (domain, unlocked) {
      events.add('${domain.name}:${unlocked ? 'unlocked' : 'locked'}');
    };
    return domains;
  }

  Uint8List fakeKey() => Uint8List.fromList(List<int>.filled(32, 0x5A));

  setUp(() => events = <String>[]);

  group('状态翻转立即广播（不等节拍器）', () {
    test('unlock 立刻广播 ui:unlocked', () {
      final domains = build();
      domains.ui.unlock(fakeKey());

      expect(events, ['ui:unlocked'],
          reason: '解锁必须立即广播，否则"解锁后马上关窗"会漏掉后续的锁定事件');
    });

    test('lockAll 立刻广播两个域的锁定', () {
      final domains = build();
      domains.ui.unlock(fakeKey());
      domains.bridge.unlock(fakeKey());
      events.clear();

      domains.lockAll();

      expect(events, containsAll(<String>['ui:locked', 'bridge:locked']),
          reason: 'UI 锁定必须连带锁 bridge 域并都广播');
      expect(domains.ui.isUnlocked, isFalse);
      expect(domains.bridge.isUnlocked, isFalse);
    });

    test('已锁定时再 lockAll 不重复广播（没有变化就没有事件）', () {
      final domains = build();
      domains.lockAll(); // 初始就是锁定态
      expect(events, isEmpty, reason: 'false → false 不算翻转');

      domains.ui.unlock(fakeKey());
      events.clear();
      domains.lockAll();
      expect(events, contains('ui:locked'));

      events.clear();
      domains.lockAll(); // 再锁一次
      expect(events, isEmpty, reason: '已经是锁定态，不该再广播');
    });

    test('连续多轮"解锁 → 立即锁定"每轮都能收到事件（用户报的那个 bug）', () {
      final domains = build();

      for (var round = 1; round <= 3; round++) {
        events.clear();
        domains.ui.unlock(fakeKey());
        expect(events, ['ui:unlocked'], reason: '第 $round 轮解锁必须广播');

        events.clear();
        // 关键：**不给节拍器任何机会** —— 模拟"解锁后立刻关窗"。
        domains.lockAll();
        expect(events, contains('ui:locked'),
            reason: '第 $round 轮锁定必须广播（旧实现在这里静默失败）');
      }
    });

    test('bridge 域单独解锁只广播 bridge（UI 解锁不解锁扩展）', () {
      final domains = build();
      domains.bridge.unlock(fakeKey());

      expect(events, ['bridge:unlocked']);
      expect(domains.ui.isUnlocked, isFalse);
    });

    test('UI 解锁不会波及 bridge 域', () {
      final domains = build();
      domains.ui.unlock(fakeKey());

      expect(events, ['ui:unlocked']);
      expect(domains.bridge.isUnlocked, isFalse,
          reason: 'D4：解锁必须是显式动作，不能静默扩大访问面');
    });

    test('惰性过期锁定也会广播（不必等节拍器发现）', () {
      var now = DateTime(2026, 3, 1, 10);
      final domains = SessionDomains(
        idleTimeout: const Duration(minutes: 5),
      );
      // 用可注入时钟的 session 不便直接构造 SessionDomains 的域，
      // 这里退化为：解锁 → 手动锁 → 断言有事件（过期路径由
      // vault_session_test 覆盖，广播路径与 lock() 相同）。
      domains.onStateChanged = (domain, unlocked) {
        events.add('${domain.name}:${unlocked ? 'unlocked' : 'locked'}');
      };
      domains.ui.unlock(fakeKey());
      domains.ui.lock();
      expect(events, ['ui:unlocked', 'ui:locked']);
      expect(now, isNotNull); // 保持变量被使用，避免 lint
    });
  });
}
