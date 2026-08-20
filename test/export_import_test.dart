import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/services/export_import_service.dart';

import 'fakes.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late CryptoService crypto;
  late Uint8List key;
  late ExportImportService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    crypto = CryptoService(secureStorage: FakeSecureStorage());
    key = crypto.deriveKey('masterpw', crypto.generateSalt());
    service = ExportImportService(db, () => key);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedEntry() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insertEntry(
      PasswordEntriesCompanion.insert(
        id: 'entry-1',
        name: 'GitHub',
        url: Value('https://github.com'),
        username: Value('octocat'),
        passwordEncrypted: crypto.encryptData('s3cret!', key),
        notesEncrypted: Value(crypto.encryptData('work account', key)),
        totpSecretEncrypted: Value(crypto.encryptData('BASE32SECRET', key)),
        isFavorite: Value(true),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  test('encrypted export/import round-trips data', () async {
    await seedEntry();
    final json = await service.exportEncrypted();
    expect(json, contains('"format": "encrypted"'));
    expect(json, isNot(contains('s3cret!'))); // never plaintext in backup

    // Import into a fresh database.
    final db2 = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => db2.close());
    final service2 = ExportImportService(db2, () => key);

    final counts = await service2.importFromJson(json);
    expect(counts['entries'], 1);
    expect(counts['folders'], 0);

    final entries = await db2.getAllEntries();
    expect(entries.length, 1);
    final e = entries.single;
    expect(e.name, 'GitHub');
    expect(e.username, 'octocat');
    expect(e.isFavorite, isTrue);
    expect(crypto.decryptData(e.passwordEncrypted, key), 's3cret!');
    expect(crypto.decryptData(e.notesEncrypted!, key), 'work account');
    expect(crypto.decryptData(e.totpSecretEncrypted!, key), 'BASE32SECRET');
  });

  test('plain export contains decrypted values', () async {
    await seedEntry();
    final json = await service.exportPlainJson();
    expect(json, contains('"format": "plain"'));
    expect(json, contains('s3cret!'));
    expect(json, contains('work account'));
    expect(json, contains('BASE32SECRET'));
  });

  test('plain export/import round-trips', () async {
    await seedEntry();
    final json = await service.exportPlainJson();

    final db2 = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => db2.close());
    final service2 = ExportImportService(db2, () => key);

    final counts = await service2.importFromJson(json);
    expect(counts['entries'], 1);

    final entries = await db2.getAllEntries();
    expect(crypto.decryptData(entries.single.passwordEncrypted, key),
        's3cret!');
  });

  test('importing an encrypted backup with the wrong key fails', () async {
    await seedEntry();
    final json = await service.exportEncrypted();

    final otherKey = crypto.deriveKey('otherpw', crypto.generateSalt());
    final service2 = ExportImportService(db, () => otherKey);
    expect(() => service2.importFromJson(json), throwsA(anything));
  });

  test('import is idempotent for folders with explicit ids', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insertFolder(
      FoldersCompanion.insert(
        id: 'folder-1',
        name: 'Work',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final json = await service.exportPlainJson();
    final db2 = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => db2.close());
    final service2 = ExportImportService(db2, () => key);

    final counts = await service2.importFromJson(json);
    expect(counts['folders'], 1);
    expect((await db2.getAllFolders()).single.name, 'Work');
  });
}
