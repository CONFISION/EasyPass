import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/features/auth/providers/auth_provider.dart';

import 'fakes.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

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

  String? tryDecrypt(String data, Uint8List k) {
    try {
      return CryptoService().decryptData(data, k);
    } catch (_) {
      return null;
    }
  }

  test('first-run flow: set master password unlocks and stores the key', () async {
    final notifier = container.read(authProvider.notifier);
    await waitForAuth();
    expect(container.read(authProvider).isFirstRun, isTrue);

    final ok = await notifier.setMasterPassword('password123', 'password123');
    expect(ok, isTrue);
    expect(container.read(authProvider).isLocked, isFalse);
    expect(container.read(encryptionKeyProvider), isNotNull);
  });

  test('setMasterPassword rejects mismatched confirmation', () async {
    final notifier = container.read(authProvider.notifier);
    await waitForAuth();

    expect(
      await notifier.setMasterPassword('password123', 'different123'),
      isFalse,
    );
  });

  test('setMasterPassword rejects short passwords', () async {
    final notifier = container.read(authProvider.notifier);
    await waitForAuth();

    expect(await notifier.setMasterPassword('short', 'short'), isFalse);
  });

  test('lock clears the session key; unlock restores it; wrong password fails',
      () async {
    final notifier = container.read(authProvider.notifier);
    await waitForAuth();
    await notifier.setMasterPassword('password123', 'password123');

    notifier.lock();
    expect(container.read(authProvider).isLocked, isTrue);
    expect(container.read(encryptionKeyProvider), isNull);

    expect(await notifier.unlock('wrongpassword'), isFalse);
    expect(container.read(encryptionKeyProvider), isNull);

    expect(await notifier.unlock('password123'), isTrue);
    expect(container.read(encryptionKeyProvider), isNotNull);
  });

  test('changeMasterPassword re-encrypts all entries with the new key',
      () async {
    final notifier = container.read(authProvider.notifier);
    await waitForAuth();
    await notifier.setMasterPassword('password123', 'password123');

    final oldKey = container.read(encryptionKeyProvider)!;
    final repo = container.read(vaultRepositoryProvider);
    final now = DateTime.now().millisecondsSinceEpoch;
    await repo.saveEntry(
      PasswordEntriesCompanion.insert(
        id: 'entry-1',
        name: 'GitHub',
        passwordEncrypted: CryptoService().encryptData('s3cret!', oldKey),
        notesEncrypted: Value(CryptoService().encryptData('work', oldKey)),
        createdAt: now,
        updatedAt: now,
      ),
    );

    final ok = await notifier.changeMasterPassword(
        'password123', 'newpassword456', 'newpassword456');
    expect(ok, isTrue);

    final newKey = container.read(encryptionKeyProvider)!;
    final entries = await repo.getAllEntries();
    expect(entries.length, 1);
    expect(entries.single.name, 'GitHub');

    // Old key must no longer decrypt; the new key must.
    expect(tryDecrypt(entries.single.passwordEncrypted, oldKey),
        isNot('s3cret!'));
    expect(tryDecrypt(entries.single.passwordEncrypted, newKey), 's3cret!');
    expect(tryDecrypt(entries.single.notesEncrypted!, newKey), 'work');

    // The new password now unlocks; the old one does not.
    notifier.lock();
    expect(await notifier.unlock('newpassword456'), isTrue);
    notifier.lock();
    expect(await notifier.unlock('password123'), isFalse);
  });

  test('changeMasterPassword rejects a wrong current password', () async {
    final notifier = container.read(authProvider.notifier);
    await waitForAuth();
    await notifier.setMasterPassword('password123', 'password123');

    expect(
      await notifier.changeMasterPassword(
          'wrong', 'newpassword456', 'newpassword456'),
      isFalse,
    );
  });

  test('auto-lock minutes persist across provider containers', () async {
    final notifier = container.read(authProvider.notifier);
    await waitForAuth();
    expect(container.read(authProvider).autoLockMinutes, 5);

    await notifier.setAutoLockMinutes(30);
    expect(container.read(authProvider).autoLockMinutes, 30);

    final container2 = ProviderContainer(
      overrides: [
        cryptoServiceProvider.overrideWithValue(
          CryptoService(secureStorage: storage),
        ),
        databaseProvider.overrideWithValue(
          AppDatabase.forTesting(NativeDatabase.memory()),
        ),
      ],
    );
    addTearDown(container2.dispose);
    while (container2.read(authProvider).isLoading) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(container2.read(authProvider).autoLockMinutes, 30);
  });
}
