import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';

import 'fakes.dart';

void main() {
  late CryptoService service;

  setUp(() {
    service = CryptoService(secureStorage: FakeSecureStorage());
  });

  test('generateSalt returns a 32-byte base64 salt', () {
    final salt = service.generateSalt();
    expect(base64Decode(salt).length, 32);
  });

  test('deriveKey is deterministic for the same password and salt', () {
    final salt = service.generateSalt();
    final k1 = service.deriveKey('password123', salt);
    final k2 = service.deriveKey('password123', salt);
    expect(k1, k2);
  });

  test('different passwords derive different keys', () {
    final salt = service.generateSalt();
    expect(
      service.deriveKey('password-a', salt),
      isNot(service.deriveKey('password-b', salt)),
    );
  });

  test('hashMasterPassword matches only for the same password', () {
    final salt = service.generateSalt();
    expect(
      service.hashMasterPassword('pw1', salt),
      service.hashMasterPassword('pw1', salt),
    );
    expect(
      service.hashMasterPassword('pw1', salt),
      isNot(service.hashMasterPassword('pw2', salt)),
    );
  });

  test('encryptData/decryptData round-trips', () {
    final key = service.deriveKey('master', service.generateSalt());
    final cipher = service.encryptData('secret value', key);
    expect(cipher, isNot('secret value'));
    expect(service.decryptData(cipher, key), 'secret value');
  });

  test('decryptData with a wrong key never yields the plaintext', () {
    final salt = service.generateSalt();
    final key1 = service.deriveKey('pw1', salt);
    final key2 = service.deriveKey('pw2', salt);
    final cipher = service.encryptData('top secret', key1);

    String? result;
    try {
      result = service.decryptData(cipher, key2);
    } catch (_) {
      result = null; // expected: padding validation fails
    }
    expect(result, isNot('top secret'));
  });

  test('storeKeyMaterial and getters round-trip', () async {
    final salt = service.generateSalt();
    final hash = service.hashMasterPassword('pw', salt);
    await service.storeKeyMaterial(salt, hash);

    expect(await service.getStoredSalt(), salt);
    expect(await service.getStoredPasswordHash(), hash);
    expect(await service.isFirstRun(), isFalse);
  });

  test('isFirstRun is true when nothing is stored', () async {
    expect(await service.isFirstRun(), isTrue);
  });

  test('auto-lock minutes persist and clamp to [1, 60]', () async {
    expect(await service.getAutoLockMinutes(), 5); // default

    await service.setAutoLockMinutes(30);
    expect(await service.getAutoLockMinutes(), 30);

    await service.setAutoLockMinutes(999);
    expect(await service.getAutoLockMinutes(), 60);

    await service.setAutoLockMinutes(0);
    expect(await service.getAutoLockMinutes(), 1);
  });
}
