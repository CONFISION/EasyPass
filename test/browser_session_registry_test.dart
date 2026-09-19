import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/features/auth/providers/auth_provider.dart';
import 'package:easypass/features/browser_bridge/browser_session_registry.dart';
import 'package:easypass/features/browser_bridge/vault_session.dart';

import 'fakes.dart';

/// 覆盖"锁定桌面端 → 同步锁定浏览器扩展会话"这条链路（C 方案的安全一致性）。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Uint8List key() => Uint8List.fromList(List<int>.filled(32, 7));

  tearDown(() {
    // 登记处是进程级单例：每个用例后清干净，避免用例间互相影响。
    final current = BrowserSessionRegistry.current;
    if (current != null) BrowserSessionRegistry.unregister(current);
  });

  group('BrowserSessionRegistry', () {
    test('lockIfAny 锁定已登记的会话', () {
      final session = VaultSession()..unlock(key());
      BrowserSessionRegistry.register(session);
      expect(session.isUnlocked, isTrue);

      BrowserSessionRegistry.lockIfAny();

      expect(session.isUnlocked, isFalse);
      expect(session.key, isNull);
    });

    test('未登记任何会话时 lockIfAny 是安全空操作', () {
      expect(BrowserSessionRegistry.current, isNull);
      expect(BrowserSessionRegistry.lockIfAny, returnsNormally);
    });

    test('unregister 之后不再锁定旧会话', () {
      final session = VaultSession()..unlock(key());
      BrowserSessionRegistry.register(session);
      BrowserSessionRegistry.unregister(session);

      BrowserSessionRegistry.lockIfAny();

      expect(session.isUnlocked, isTrue, reason: '已注销的会话不应再被联动锁定');
    });

    test('重新登记会替换旧会话', () {
      final first = VaultSession()..unlock(key());
      final second = VaultSession()..unlock(key());
      BrowserSessionRegistry.register(first);
      BrowserSessionRegistry.register(second);

      BrowserSessionRegistry.lockIfAny();

      expect(second.isUnlocked, isFalse);
      expect(first.isUnlocked, isTrue);
    });
  });

  group('AuthNotifier.lock 与会话联动', () {
    late ProviderContainer container;
    late FakeSecureStorage storage;

    setUp(() {
      storage = FakeSecureStorage();
      container = ProviderContainer(
        overrides: [
          cryptoServiceProvider.overrideWithValue(
            CryptoService(secureStorage: storage),
          ),
          databaseProvider.overrideWithValue(
            AppDatabase.forTesting(NativeDatabase.memory()),
          ),
        ],
      );
      addTearDown(container.dispose);
    });

    Future<void> waitForAuth() async {
      while (container.read(authProvider).isLoading) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('锁定保险库会同时清掉浏览器会话密钥', () async {
      final notifier = container.read(authProvider.notifier);
      await waitForAuth();
      expect(await notifier.setMasterPassword('password123', 'password123'),
          isTrue);

      final browserSession = VaultSession()..unlock(key());
      BrowserSessionRegistry.register(browserSession);
      expect(browserSession.isUnlocked, isTrue);

      notifier.lock();

      expect(container.read(authProvider).isLocked, isTrue);
      expect(browserSession.isUnlocked, isFalse,
          reason: '桌面端锁定后，扩展不应还能用旧会话读保险库');
    });
  });
}
