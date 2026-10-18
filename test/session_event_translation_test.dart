import 'package:easypass/client/core_session.dart';
import 'package:easypass/protocol/events.dart';
import 'package:flutter_test/flutter_test.dart';

/// 核心会话事件 → UI 事件的翻译规则（[uiSessionEvent]）。
///
/// 回归背景：
/// 1. **"关窗上锁只生效一次"**（用户真机报告）：核心每次都锁了，但不广播，
///    UI 停在解锁态而界面拿不到数据。核心侧已改成"状态一变立即广播"
///    （见 `SessionDomains` / `VaultSession` 的单测）；这里守的是**消费侧**。
/// 2. **扩展解锁不该让桌面端变成解锁态**（D4）：核心的两个会话域各自带
///    `domain` 广播，UI 只能被 `ui` 域驱动，否则"浏览器解锁 → 桌面端显示解锁"
///    就是又一次"UI 假解锁"。
void main() {
  Map<String, dynamic> ev(String name, {String? domain}) => {
        'event': name,
        'domain': ?domain,
      };

  group('只认 ui 域', () {
    test('ui 域锁定 / 解锁被转发', () {
      expect(uiSessionEvent(ev(Events.sessionLocked, domain: 'ui')), 'locked');
      expect(
          uiSessionEvent(ev(Events.sessionUnlocked, domain: 'ui')), 'unlocked');
    });

    test('bridge 域锁定 / 解锁被忽略', () {
      expect(uiSessionEvent(ev(Events.sessionLocked, domain: 'bridge')), isNull,
          reason: '扩展锁定不影响桌面端状态');
      expect(
        uiSessionEvent(ev(Events.sessionUnlocked, domain: 'bridge')),
        isNull,
        reason: 'D4：扩展解锁不能把桌面端也变成解锁态',
      );
    });

    test('缺 domain 时按 ui 处理（兼容旧核心）', () {
      expect(uiSessionEvent(ev(Events.sessionLocked)), 'locked');
      expect(uiSessionEvent(ev(Events.sessionUnlocked)), 'unlocked');
    });
  });

  group('其它事件', () {
    test('coreShuttingDown 一律转发（无 domain）', () {
      expect(uiSessionEvent(ev(Events.coreShuttingDown)), 'shuttingDown');
      expect(
        uiSessionEvent(ev(Events.coreShuttingDown, domain: 'bridge')),
        'shuttingDown',
        reason: '核心要退出了，UI 必须回锁屏，不管哪个域报的',
      );
    });

    test('changed / 未知事件不产生会话事件', () {
      expect(uiSessionEvent(ev(Events.changed, domain: 'ui')), isNull);
      expect(uiSessionEvent(ev('somethingElse')), isNull);
    });
  });

  group('关窗即锁的完整往返（核心 → UI 事件名）', () {
    test('lockAll 的两个广播里，UI 只收到一次 ui:locked 的语义', () {
      // 核心的 lockAll() 依次广播 ui 与 bridge 两个域的 locked。
      final uiLocked = uiSessionEvent(ev(Events.sessionLocked, domain: 'ui'));
      final bridgeLocked =
          uiSessionEvent(ev(Events.sessionLocked, domain: 'bridge'));
      expect(uiLocked, 'locked');
      expect(bridgeLocked, isNull);
    });

    test('连续多轮都成立（旧实现会"只生效一次"）', () {
      for (var round = 1; round <= 3; round++) {
        expect(
          uiSessionEvent(ev(Events.sessionUnlocked, domain: 'ui')),
          'unlocked',
          reason: '第 $round 轮解锁',
        );
        expect(
          uiSessionEvent(ev(Events.sessionLocked, domain: 'ui')),
          'locked',
          reason: '第 $round 轮锁定 —— 必须每轮都能到 UI',
        );
      }
    });
  });
}
