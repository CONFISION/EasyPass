import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/core/crypto/totp_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/features/browser_bridge/native_messaging_service.dart';

import 'fakes.dart';

/// Protocol-level tests for the native messaging host. These drive
/// [NativeMessagingService.handleRequest] directly (no real stdin/stdout),
/// covering the lock/unlock lifecycle, credential decryption, and errors.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const masterPassword = 'correct horse battery staple';
  const entryName = 'GitHub';
  const entryUrl = 'https://github.com/login';
  const entryUsername = 'alice';
  const entrySecret = 's3cret-p@ssw0rd!';
  const entryNotes = 'personal account';
  const totpSecret = 'JBSWY3DPEHPK3PXP'; // RFC 6238 base32 test secret

  late FakeSecureStorage storage;
  late AppDatabase db;
  late CryptoService crypto;
  late NativeMessagingService service;

  setUp(() async {
    storage = FakeSecureStorage();
    crypto = CryptoService(secureStorage: storage);
    db = AppDatabase.forTesting(NativeDatabase.memory());

    // Configure the master password (salt + hash), as the app does on
    // first run.
    final salt = crypto.generateSalt();
    final hash = crypto.hashMasterPassword(masterPassword, salt);
    await crypto.storeKeyMaterial(salt, hash);

    service = NativeMessagingService(db, crypto, TotpService());
  });

  tearDown(() async {
    await db.close();
  });

  Future<Map<String, dynamic>> request(String action,
      [Map<String, dynamic> extra = const {}]) {
    return service.handleRequest({
      'requestId': 'req-1',
      'action': action,
      ...extra,
    });
  }

  /// Insert one encrypted entry using the same key the host derives from
  /// [masterPassword].
  Future<void> insertEntry({String? secret, bool withTotp = false}) async {
    final salt = await crypto.getStoredSalt();
    final key = crypto.deriveKey(masterPassword, salt!);
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insertEntry(PasswordEntriesCompanion.insert(
      id: 'entry-1',
      name: entryName,
      url: Value(entryUrl),
      username: Value(entryUsername),
      passwordEncrypted: crypto.encryptData(secret ?? entrySecret, key),
      notesEncrypted: Value(crypto.encryptData(entryNotes, key)),
      totpSecretEncrypted:
          Value(withTotp ? crypto.encryptData(totpSecret, key) : ''),
      createdAt: now,
      updatedAt: now,
    ));
  }

  group('getStatus', () {
    test('reports locked before unlock', () async {
      final res = await request('getStatus');
      expect(res['requestId'], 'req-1');
      final data = res['data'] as Map<String, dynamic>;
      expect(data['connected'], true);
      expect(data['locked'], true);
      expect(data['entryCount'], 0);
    });

    test('reports unlocked after successful unlock', () async {
      final unlock = await request('unlock', {'password': masterPassword});
      expect(unlock['error'], isNull);

      final res = await request('getStatus');
      final data = res['data'] as Map<String, dynamic>;
      expect(data['locked'], false);
    });
  });

  group('unlock', () {
    test('fails with wrong master password', () async {
      final res = await request('unlock', {'password': 'wrong-password'});
      expect(res['error'], isNotNull);
    });

    test('fails when no master password is configured', () async {
      final bare = FakeSecureStorage();
      final bareCrypto = CryptoService(secureStorage: bare);
      final bareDb = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(bareDb.close);

      final bareService =
          NativeMessagingService(bareDb, bareCrypto, TotpService());
      final res = await bareService.handleRequest(
          {'requestId': 'r', 'action': 'unlock', 'password': 'x'});
      expect(res['error'], isNotNull);
    });
  });

  group('credentials', () {
    test('rejects credential access while locked', () async {
      final res = await request('getAllCredentials');
      expect(res['error'], isNotNull);
      expect(res['error'].toString().toLowerCase(), contains('lock'));
    });

    test('returns decrypted credentials after unlock', () async {
      await insertEntry();
      await request('unlock', {'password': masterPassword});

      final res = await request('getAllCredentials');
      expect(res['error'], isNull);

      final data = res['data'] as List<dynamic>;
      expect(data, hasLength(1));
      final entry = data.first as Map<String, dynamic>;
      expect(entry['id'], 'entry-1');
      expect(entry['name'], entryName);
      expect(entry['url'], entryUrl);
      expect(entry['username'], entryUsername);
      expect(entry['password'], entrySecret);
      expect(entry['notes'], entryNotes);
      expect(entry['isFavorite'], false);
    });

    test('searchCredentials filters by query', () async {
      await insertEntry();
      await request('unlock', {'password': masterPassword});

      final hit = await request('searchCredentials', {'query': 'github'});
      expect(hit['error'], isNull);
      expect((hit['data'] as List).length, 1);

      final miss = await request('searchCredentials', {'query': 'nothing'});
      expect((miss['data'] as List), isEmpty);
    });

    test('lock clears the session key', () async {
      await insertEntry();
      await request('unlock', {'password': masterPassword});

      final before = await request('getAllCredentials');
      expect(before['error'], isNull);

      final lockRes = await request('lock');
      expect(lockRes['error'], isNull);

      final after = await request('getAllCredentials');
      expect(after['error'], isNotNull);
    });
  });

  group('generatePassword', () {
    test('honors options and length', () async {
      final res = await request('generatePassword', {
        'options': {
          'length': 20,
          'useUpper': true,
          'useLower': true,
          'useNumbers': true,
          'useSymbols': false,
        }
      });
      expect(res['error'], isNull);
      final pw = (res['data'] as Map<String, dynamic>)['password'] as String;
      expect(pw.length, 20);
      expect(RegExp(r'[A-Z]').hasMatch(pw), isTrue);
      expect(RegExp(r'[a-z]').hasMatch(pw), isTrue);
      expect(RegExp(r'[0-9]').hasMatch(pw), isTrue);
      expect(RegExp(r'[!@#\$%^&*]').hasMatch(pw), isFalse);
    });

    test('works while locked (no vault access needed)', () async {
      final res = await request('generatePassword');
      expect(res['error'], isNull);
    });
  });

  group('getTotp', () {
    test('returns TOTP code for entries with a secret', () async {
      await insertEntry(withTotp: true);
      await request('unlock', {'password': masterPassword});

      final res = await request('getTotp', {'entryId': 'entry-1'});
      expect(res['error'], isNull);
      final data = res['data'] as Map<String, dynamic>;
      expect(data['totp'], isA<String>());
      expect((data['totp'] as String), hasLength(6));
      expect(data['remaining'], isA<int>());
    });

    test('errors when the entry has no TOTP secret', () async {
      await insertEntry(withTotp: false);
      await request('unlock', {'password': masterPassword});

      final res = await request('getTotp', {'entryId': 'entry-1'});
      expect(res['error'], isNotNull);
    });

    test('rejects while locked', () async {
      final res = await request('getTotp', {'entryId': 'entry-1'});
      expect(res['error'], isNotNull);
    });
  });

  group('unknown action', () {
    test('returns an error and echoes requestId', () async {
      final res = await request('bogus');
      expect(res['error'], isNotNull);
      expect(res['requestId'], 'req-1');
    });
  });
}
