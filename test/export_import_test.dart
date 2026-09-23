import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/models/vault_item_mapper.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/data/services/export_import_service.dart';

import 'fakes.dart';

/// 导出格式 2.0.0 的**外壳 / 兼容性 / 失败语义**测试。
///
/// 四种类型的字段往返在 `export_import_types_test.dart`。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late CryptoService crypto;
  late Uint8List key;
  late VaultRepository repo;
  late ExportImportService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    crypto = CryptoService(secureStorage: FakeSecureStorage());
    key = crypto.deriveKey('masterpw', crypto.generateSalt());
    repo = VaultRepository(db: db, cryptoService: crypto, keyReader: () => key);
    service = ExportImportService(
      db,
      () => key,
      repository: repo,
      cryptoService: crypto,
    );
  });

  tearDown(() => db.close());

  /// 另起一个空保险库（独立内存库 + 独立 service）用来导入。
  _TestVault freshVault() {
    final db2 = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db2.close);
    final crypto2 = CryptoService(secureStorage: FakeSecureStorage());
    final repo2 = VaultRepository(
      db: db2,
      cryptoService: crypto2,
      keyReader: () => key,
    );
    return _TestVault(
      db2,
      crypto2,
      repo2,
      ExportImportService(
        db2,
        () => key,
        repository: repo2,
        cryptoService: crypto2,
      ),
    );
  }

  VaultItem loginItem({
    String id = 'login-1',
    String name = 'GitHub',
    String url = 'https://github.com',
    String username = 'octocat',
    String password = 'LOGIN-PASSWORD-MARKER-001',
    String totpSecret = 'TOTP-SECRET-MARKER-002',
    String? folderId,
    bool favorite = true,
    int createdAt = 1700000000000,
  }) {
    return VaultItem(
      id: id,
      folderId: folderId,
      type: EntryType.login,
      name: name,
      notes: 'work account',
      isFavorite: favorite,
      login: LoginData(
        url: url,
        username: username,
        password: password,
        totpSecret: totpSecret,
      ),
      createdAt: createdAt,
      updatedAt: createdAt,
    );
  }

  Matcher throwsImportError([String? fragment]) => throwsA(
        isA<ExportImportException>().having(
          (e) => e.message,
          'message',
          fragment == null ? anything : contains(fragment),
        ),
      );

  // ─── 外壳 ───────────────────────────────────────────────

  group('导出格式 2.0.0 外壳', () {
    test('明文导出：version / format / 条目形状（只带本类型的字段块）', () async {
      await repo.saveItem(loginItem());
      final json = await service.exportPlainJson();
      final doc = jsonDecode(json) as Map<String, dynamic>;

      expect(doc['version'], '2.0.0');
      expect(doc['app'], 'EasyPass');
      expect(doc['format'], 'plain');
      expect(doc['exported_at'], isA<String>());

      final entries = doc['entries'] as List<dynamic>;
      expect(entries, hasLength(1));
      final entry = Map<String, dynamic>.from(entries.single as Map);
      expect(entry['id'], 'login-1');
      expect(entry['type'], 'login');
      expect(entry['name'], 'GitHub');
      expect(entry['notes'], 'work account');
      expect(entry['is_favorite'], isTrue);
      expect(entry['folder_id'], isNull);
      expect(entry['created_at'], 1700000000000);
      expect(entry['login'], {
        'url': 'https://github.com',
        'username': 'octocat',
        'password': 'LOGIN-PASSWORD-MARKER-001',
        'totp_secret': 'TOTP-SECRET-MARKER-002',
      });
      // 不属于该类型的字段块不写；空的自定义字段不写
      expect(entry.containsKey('identity'), isFalse);
      expect(entry.containsKey('ssh_key'), isFalse);
      expect(entry.containsKey('custom_fields'), isFalse);
      // 明文导出本来就是给用户自己看的，这里应该有明文
      expect(json, contains('LOGIN-PASSWORD-MARKER-001'));
    });

    test('加密备份：外壳固定为 version/app/format/data，且不含任何明文', () async {
      await repo.saveItem(loginItem());
      final json = await service.exportEncrypted();
      final doc = jsonDecode(json) as Map<String, dynamic>;

      expect(doc.keys.toSet(), {'version', 'app', 'format', 'data'});
      expect(doc['version'], '2.0.0');
      expect(doc['format'], 'encrypted');
      expect(doc['data'], isA<String>());

      expect(json, isNot(contains('LOGIN-PASSWORD-MARKER-001')));
      expect(json, isNot(contains('TOTP-SECRET-MARKER-002')));
      expect(json, isNot(contains('octocat')));
      expect(json, isNot(contains('work account')));
    });

    test('空库导出是合法的 2.0.0 文档（可被自己导入）', () async {
      final json = await service.exportPlainJson();
      final doc = jsonDecode(json) as Map<String, dynamic>;
      expect(doc['entries'], isEmpty);
      expect(doc['folders'], isEmpty);

      final fresh = freshVault();
      expect(await fresh.service.importFromJson(json), {
        'folders': 0,
        'entries': 0,
      });
    });
  });

  // ─── 登录条目往返 ────────────────────────────────────────

  group('登录条目 round-trip', () {
    test('明文导出 → 导入：字段 / 文件夹 / 收藏 / createdAt 保留，落库为密文', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await repo.addFolder(FoldersCompanion.insert(
        id: 'folder-1',
        name: 'Work',
        createdAt: now,
        updatedAt: now,
      ));
      await repo.saveItem(loginItem(folderId: 'folder-1'));

      final json = await service.exportPlainJson();
      final fresh = freshVault();
      final counts = await fresh.service.importFromJson(json);

      expect(counts['entries'], 1);
      expect(counts['folders'], 1);
      expect((await fresh.repo.getFolders()).single.name, 'Work');

      final item = (await fresh.repo.getItems()).single;
      expect(item.id, 'login-1');
      expect(item.type, EntryType.login);
      expect(item.name, 'GitHub');
      expect(item.notes, 'work account');
      expect(item.isFavorite, isTrue);
      expect(item.folderId, 'folder-1');
      expect(item.createdAt, 1700000000000);
      expect(item.updatedAt, greaterThanOrEqualTo(item.createdAt));
      expect(item.loginOrEmpty.url, 'https://github.com');
      expect(item.loginOrEmpty.username, 'octocat');
      expect(item.loginOrEmpty.password, 'LOGIN-PASSWORD-MARKER-001');
      expect(item.loginOrEmpty.totpSecret, 'TOTP-SECRET-MARKER-002');

      // 导入是"用会话密钥重新加密"，库里不能出现明文。
      final row = await fresh.db.getEntryById('login-1');
      expect(row, isNotNull);
      expect(row!.passwordEncrypted, isNotEmpty);
      expect(row.passwordEncrypted, isNot(contains('LOGIN-PASSWORD-MARKER-001')));
      expect(
        fresh.crypto.decryptData(row.passwordEncrypted, key),
        'LOGIN-PASSWORD-MARKER-001',
      );
    });

    test('加密备份 → 导入：字段保留，且备份里是密文', () async {
      await repo.saveItem(loginItem());

      final json = await service.exportEncrypted();
      final fresh = freshVault();
      final counts = await fresh.service.importFromJson(json);
      expect(counts['entries'], 1);

      final item = (await fresh.repo.getItems()).single;
      expect(item.type, EntryType.login);
      expect(item.loginOrEmpty.username, 'octocat');
      expect(item.loginOrEmpty.password, 'LOGIN-PASSWORD-MARKER-001');
      expect(item.loginOrEmpty.totpSecret, 'TOTP-SECRET-MARKER-002');
      expect(item.notes, 'work account');
    });

    test('备份用别的密钥加密 → 明确报错', () async {
      await repo.saveItem(loginItem());
      final json = await service.exportEncrypted();

      final otherKey = crypto.deriveKey('otherpw', crypto.generateSalt());
      final otherRepo = VaultRepository(
        db: db,
        cryptoService: crypto,
        keyReader: () => otherKey,
      );
      final otherService = ExportImportService(
        db,
        () => otherKey,
        repository: otherRepo,
        cryptoService: crypto,
      );

      await expectLater(
        otherService.importFromJson(json),
        throwsImportError('cannot decrypt'),
      );
    });

    test('相同 id 重复导入是覆盖（文件夹幂等）', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await repo.addFolder(FoldersCompanion.insert(
        id: 'folder-1',
        name: 'Work',
        createdAt: now,
        updatedAt: now,
      ));
      await repo.saveItem(loginItem(folderId: 'folder-1'));
      final json = await service.exportPlainJson();

      final fresh = freshVault();
      await fresh.service.importFromJson(json);
      await fresh.service.importFromJson(json);

      expect(await fresh.repo.countItems(), 1);
      expect((await fresh.repo.getFolders()), hasLength(1));
    });
  });

  // ─── 1.x 兼容 ───────────────────────────────────────────

  group('向后兼容 1.x 导出', () {
    const legacyPlainJson = '''
{
  "version": "1.0.0",
  "app": "EasyPass",
  "format": "plain",
  "exported_at": "2025-01-01T00:00:00.000",
  "folders": [
    {"id": "legacy-folder", "name": "Legacy", "icon": null,
     "created_at": 100, "updated_at": 100}
  ],
  "entries": [
    {
      "id": "legacy-1",
      "folder_id": "legacy-folder",
      "name": "GitHub",
      "url": "https://github.com",
      "username": "octocat",
      "password": "legacy-password",
      "notes": "legacy note",
      "totp_secret": "LEGACYSECRET",
      "is_favorite": true,
      "created_at": 111,
      "updated_at": 222
    }
  ]
}
''';

    test('1.0.0 明文导出（平铺字段 / 无 type）按登录导入', () async {
      final fresh = freshVault();
      final counts = await fresh.service.importFromJson(legacyPlainJson);

      expect(counts, {'folders': 1, 'entries': 1});
      expect((await fresh.repo.getFolders()).single.name, 'Legacy');

      final item = (await fresh.repo.getItems()).single;
      expect(item.type, EntryType.login);
      expect(item.id, 'legacy-1');
      expect(item.name, 'GitHub');
      expect(item.folderId, 'legacy-folder');
      expect(item.isFavorite, isTrue);
      expect(item.createdAt, 111);
      expect(item.loginOrEmpty.url, 'https://github.com');
      expect(item.loginOrEmpty.username, 'octocat');
      expect(item.loginOrEmpty.password, 'legacy-password');
      expect(item.loginOrEmpty.totpSecret, 'LEGACYSECRET');
      expect(item.notes, 'legacy note');
    });

    test('1.0.0 加密备份按登录导入', () async {
      final legacyEncrypted = _legacyEncryptedShell(legacyPlainJson, key);

      final fresh = freshVault();
      final counts = await fresh.service.importFromJson(legacyEncrypted);
      expect(counts, {'folders': 1, 'entries': 1});

      final item = (await fresh.repo.getItems()).single;
      expect(item.type, EntryType.login);
      expect(item.loginOrEmpty.password, 'legacy-password');
      expect(item.loginOrEmpty.totpSecret, 'LEGACYSECRET');
    });

    test('极老导出的 *_encrypted 密文字段也能解开导入', () async {
      final legacy = jsonEncode({
        'version': '1.0.0',
        'app': 'EasyPass',
        'format': 'plain',
        'entries': [
          {
            'id': 'old-1',
            'name': 'Old Entry',
            'password_encrypted': crypto.encryptData('old-password', key),
            'notes_encrypted': crypto.encryptData('old note', key),
            'totp_secret_encrypted': crypto.encryptData('OLDSECRET', key),
          }
        ],
      });

      final fresh = freshVault();
      await fresh.service.importFromJson(legacy);

      final item = (await fresh.repo.getItems()).single;
      expect(item.type, EntryType.login);
      expect(item.loginOrEmpty.password, 'old-password');
      expect(item.notes, 'old note');
      expect(item.loginOrEmpty.totpSecret, 'OLDSECRET');
    });

    test('极老密文字段解不开时报错（不静默丢字段）', () async {
      final otherKey = crypto.deriveKey('otherpw', crypto.generateSalt());
      final legacy = jsonEncode({
        'version': '1.0.0',
        'app': 'EasyPass',
        'format': 'plain',
        'entries': [
          {
            'id': 'old-1',
            'name': 'Old Entry',
            'password_encrypted': crypto.encryptData('old-password', otherKey),
          }
        ],
      });

      final fresh = freshVault();
      await expectLater(
        fresh.service.importFromJson(legacy),
        throwsImportError('cannot decrypt'),
      );
      expect(await fresh.repo.countItems(), 0);
    });
  });

  // ─── 类型容错 ───────────────────────────────────────────

  group('type 字段容错（未知一律回退登录）', () {
    String docWithoutKnownType(Object? type) {
      final entry = <String, dynamic>{
        'id': 'mystery-1',
        'name': 'Mystery',
        'url': 'https://mystery.example',
        'username': 'user',
        'password': 'mystery-password',
        'totp_secret': 'MYSTERYSECRET',
      };
      if (type != null) entry['type'] = type;
      return jsonEncode({
        'version': '2.0.0',
        'app': 'EasyPass',
        'format': 'plain',
        'entries': [entry],
      });
    }

    for (final testCase in <String, Object?>{
      '缺 type 字段': null,
      '未知字符串': 'banana',
      '大小写不同的未知值': 'SECURE_NOTE_V9',
      '数字': 42,
      '布尔': true,
      '列表': <String>[],
    }.entries) {
      test('${testCase.key} → 登录条目，不崩', () async {
        final fresh = freshVault();
        final counts = await fresh.service.importFromJson(
          docWithoutKnownType(testCase.value),
        );
        expect(counts['entries'], 1);

        final item = (await fresh.repo.getItems()).single;
        expect(item.type, EntryType.login);
        expect(item.loginOrEmpty.username, 'user');
        expect(item.loginOrEmpty.password, 'mystery-password');
        expect(item.loginOrEmpty.totpSecret, 'MYSTERYSECRET');
      });
    }
  });

  // ─── 非法输入 ───────────────────────────────────────────

  group('非法输入：明确报错、绝不半途导入', () {
    test('不是 JSON', () async {
      await expectLater(
        service.importFromJson('not json at all'),
        throwsImportError('not valid JSON'),
      );
    });

    test('顶层不是对象', () async {
      await expectLater(
        service.importFromJson('[1, 2, 3]'),
        throwsImportError('expected a JSON object'),
      );
    });

    test('既没有 entries 也没有 folders', () async {
      await expectLater(
        service.importFromJson('{"hello": "world"}'),
        throwsImportError('not an EasyPass export'),
      );
    });

    test('entries 不是数组', () async {
      await expectLater(
        service.importFromJson('{"format": "plain", "entries": "nope"}'),
        throwsImportError('"entries" must be a list'),
      );
    });

    test('entries 里混入非对象元素 → 抛错且一条都不导入', () async {
      final json = jsonEncode({
        'version': '2.0.0',
        'format': 'plain',
        'entries': [
          {
            'id': 'ok-1',
            'type': 'login',
            'name': 'OK',
            'login': {'username': 'u', 'password': 'p'},
          },
          42,
        ],
      });
      await expectLater(
        service.importFromJson(json),
        throwsImportError('entries[1] is not an object'),
      );
      expect(await repo.countItems(), 0);
    });

    test('folders 不是数组', () async {
      await expectLater(
        service.importFromJson(
          '{"format": "plain", "folders": {}, "entries": []}',
        ),
        throwsImportError('"folders" must be a list'),
      );
    });

    test('加密外壳缺 data / base64 坏 / 太短', () async {
      await expectLater(
        service.importFromJson('{"format": "encrypted", "version": "2.0.0"}'),
        throwsImportError('no "data" payload'),
      );
      await expectLater(
        service.importFromJson('{"format": "encrypted", "data": "!!!not-base64!!!"}'),
        throwsImportError('invalid base64'),
      );
      await expectLater(
        service.importFromJson('{"format": "encrypted", "data": "AAAA"}'),
        throwsImportError('too short'),
      );
    });

    test('加密备份里解出来的内容不是 JSON 文档 → 明确报错', () async {
      final shell = _encryptShell('this is not json', key);
      await expectLater(
        service.importFromJson(shell),
        throwsImportError('not valid JSON'),
      );
    });
  });

  // ─── 锁定状态 ───────────────────────────────────────────

  group('保险库锁定', () {
    test('未解锁时导出抛错，导入抛 VaultLockedException 且不落库', () async {
      await repo.saveItem(loginItem());
      final json = await service.exportPlainJson();

      final lockedDb = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(lockedDb.close);
      final lockedRepo = VaultRepository(
        db: lockedDb,
        cryptoService: crypto,
        keyReader: () => null,
      );
      final lockedService = ExportImportService(
        lockedDb,
        () => throw StateError('Vault is locked'),
        repository: lockedRepo,
        cryptoService: crypto,
      );

      await expectLater(lockedService.exportPlainJson(), throwsA(isA<StateError>()));
      await expectLater(
        lockedService.importFromJson(json),
        throwsA(isA<VaultLockedException>()),
      );
      expect(await lockedRepo.countItems(), 0);
    });
  });

  // ─── 文件读写 ───────────────────────────────────────────

  test('writeToFile / readFromFile 往返', () async {
    final dir = await Directory.systemTemp.createTemp('easypass_export_test');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}backup.json';

    await service.writeToFile('{"a": 1}', path);
    expect(await service.readFromFile(path), '{"a": 1}');
  });
}

/// 手工造一个 1.0.0 风格的加密备份（`IV(16) || ciphertext` 的 base64，
/// 与 `CryptoService.encryptData` / 老导出的线格式一致）。
String _legacyEncryptedShell(String plainJson, Uint8List key) {
  return const JsonEncoder.withIndent('  ').convert({
    'version': '1.0.0',
    'app': 'EasyPass',
    'format': 'encrypted',
    'data': _encryptPayload(plainJson, key),
  });
}

/// 同上，但外壳版本写成 2.0.0（用于"解出来不是 JSON"这类用例）。
String _encryptShell(String plainJson, Uint8List key) {
  return jsonEncode({
    'version': '2.0.0',
    'app': 'EasyPass',
    'format': 'encrypted',
    'data': _encryptPayload(plainJson, key),
  });
}

String _encryptPayload(String plaintext, Uint8List key) {
  final iv = encrypt.IV.fromSecureRandom(16);
  final encrypter = encrypt.Encrypter(
    encrypt.AES(encrypt.Key(key), mode: encrypt.AESMode.cbc),
  );
  final cipher = encrypter.encrypt(plaintext, iv: iv);
  return base64Encode(Uint8List.fromList(iv.bytes + cipher.bytes));
}

class _TestVault {
  final AppDatabase db;
  final CryptoService crypto;
  final VaultRepository repo;
  final ExportImportService service;

  const _TestVault(this.db, this.crypto, this.repo, this.service);
}
