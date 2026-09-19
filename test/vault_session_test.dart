import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/features/browser_bridge/vault_session.dart';

/// [VaultSession] 单测：解锁/锁定生命周期、惰性空闲过期、可注入时钟、
/// 以及 lock() 对密钥字节的清零（C 方案的安全下限）。
void main() {
  late DateTime now;
  late VaultSession session;

  setUp(() {
    now = DateTime(2026, 3, 1, 10, 0, 0);
    session = VaultSession(clock: () => now);
  });

  /// 造一份可识别的假密钥，便于断言字节被清零。
  Uint8List fakeKey([int seed = 0xAB]) =>
      Uint8List.fromList(List.generate(32, (i) => (seed + i) & 0xff));

  group('解锁 / 锁定生命周期', () {
    test('新建会话是锁定态，key 与 remaining 均为 null', () {
      expect(session.isUnlocked, isFalse);
      expect(session.key, isNull);
      expect(session.remaining, isNull);
    });

    test('unlock 后可读密钥，remaining 等于 idleTimeout', () {
      final key = fakeKey();
      session.unlock(key);

      expect(session.isUnlocked, isTrue);
      expect(session.key, same(key));
      expect(session.remaining, const Duration(minutes: 5));
    });

    test('unlock 同时记录活跃时间（不经过 touch 也不会立刻过期）', () {
      session.unlock(fakeKey());
      now = now.add(const Duration(minutes: 4, seconds: 59));
      expect(session.isUnlocked, isTrue);
    });

    test('lock 后回到锁定态且 remaining 为 null', () {
      session.unlock(fakeKey());
      session.lock();

      expect(session.isUnlocked, isFalse);
      expect(session.key, isNull);
      expect(session.remaining, isNull);
    });

    test('lock 先把密钥字节清零再置空（内存不残留）', () {
      final key = fakeKey();
      session.unlock(key);
      expect(key, isNot(everyElement(0)));

      session.lock();

      expect(key, everyElement(0));
      expect(session.key, isNull);
    });

    test('重复 unlock 会清零上一份密钥字节', () {
      final first = fakeKey(0x11);
      final second = fakeKey(0x22);
      session.unlock(first);
      session.unlock(second);

      expect(first, everyElement(0));
      expect(session.key, same(second));
    });

    test('锁定时 touch 是空操作，不会凭空解锁', () {
      session.touch();
      expect(session.isUnlocked, isFalse);
      expect(session.key, isNull);
    });
  });

  group('空闲过期（惰性）', () {
    test('空闲超过 idleTimeout 后 isUnlocked 读取即锁定', () {
      session.unlock(fakeKey());
      now = now.add(const Duration(minutes: 5, seconds: 1));

      expect(session.isUnlocked, isFalse);
      expect(session.key, isNull);
      expect(session.remaining, isNull);
    });

    test('恰好等于 idleTimeout 即视为过期', () {
      session.unlock(fakeKey());
      now = now.add(const Duration(minutes: 5));

      expect(session.isUnlocked, isFalse);
    });

    test('过期锁定同样会清零密钥字节', () {
      final key = fakeKey();
      session.unlock(key);
      now = now.add(const Duration(minutes: 6));

      session.isUnlocked; // 触发惰性过期

      expect(key, everyElement(0));
    });

    test('remaining 随空闲时间递减', () {
      session.unlock(fakeKey());
      now = now.add(const Duration(minutes: 1));
      expect(session.remaining, const Duration(minutes: 4));

      now = now.add(const Duration(minutes: 3, seconds: 30));
      expect(session.remaining, const Duration(seconds: 30));
    });

    test('touch 刷新活跃时间，重新获得完整的 idleTimeout', () {
      session.unlock(fakeKey());
      now = now.add(const Duration(minutes: 4, seconds: 30));
      session.touch();

      now = now.add(const Duration(minutes: 4, seconds: 30));
      expect(session.isUnlocked, isTrue);
      expect(session.remaining, const Duration(seconds: 30));
    });

    test('touch 不刷新则 5 分钟后过期（对照）', () {
      session.unlock(fakeKey());
      now = now.add(const Duration(minutes: 4, seconds: 30));
      now = now.add(const Duration(minutes: 4, seconds: 30));

      expect(session.isUnlocked, isFalse);
    });

    test('可自定义 idleTimeout', () {
      final short = VaultSession(
        idleTimeout: const Duration(seconds: 30),
        clock: () => now,
      );
      short.unlock(fakeKey());
      expect(short.remaining, const Duration(seconds: 30));

      now = now.add(const Duration(seconds: 31));
      expect(short.isUnlocked, isFalse);
    });

    test('默认 idleTimeout 为 5 分钟', () {
      expect(VaultSession().idleTimeout, const Duration(minutes: 5));
    });
  });
}
