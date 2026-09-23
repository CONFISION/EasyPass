import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/data/services/export_import_service.dart';

import 'fakes.dart';

/// 导出格式 2.0.0 的**四种类型**往返测试（契约 §6）。
///
/// 覆盖：明文导出 / 加密备份两条路径下类型与字段是否存活，以及加密备份的
/// 原始文本里是否真的没有明文机密。
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

  Future<void> seedAll() async {
    await repo.addFolder(FoldersCompanion.insert(
      id: 'folder-1',
      name: 'Work',
      createdAt: 1700000000000,
      updatedAt: 1700000000000,
    ));
    for (final item in [loginSeed(), noteSeed(), identitySeed(), sshSeed()]) {
      await repo.saveItem(item);
    }
  }

  /// 导出（明文或加密）→ 导入到全新空库 → 返回导入后的条目。
  Future<List<VaultItem>> roundTrip({required bool encrypted}) async {
    await seedAll();
    final json = encrypted
        ? await service.exportEncrypted()
        : await service.exportPlainJson();

    final fresh = freshVault();
    final counts = await fresh.service.importFromJson(json);
    expect(counts['entries'], 4, reason: '四种类型都要被导入');
    expect(counts['folders'], 1);

    return fresh.repo.getItems();
  }

  Map<String, VaultItem> byId(List<VaultItem> items) => {
        for (final item in items) item.id: item,
      };

  for (final encrypted in [false, true]) {
    final label = encrypted ? '加密备份 round-trip' : '明文导出 round-trip';

    group(label, () {
      test('四种类型与文件夹归属都保留', () async {
        final items = byId(await roundTrip(encrypted: encrypted));

        expect(items.keys.toSet(), {'login-1', 'note-1', 'identity-1', 'ssh-1'});
        expect(items['login-1']!.type, EntryType.login);
        expect(items['note-1']!.type, EntryType.secureNote);
        expect(items['identity-1']!.type, EntryType.identity);
        expect(items['ssh-1']!.type, EntryType.sshKey);

        expect(items['login-1']!.folderId, 'folder-1');
        expect(items['note-1']!.folderId, 'folder-1');
        expect(items['identity-1']!.folderId, isNull);
        expect(items['ssh-1']!.folderId, isNull);

        // 名称 / 备注 / 收藏 / createdAt 全部保留
        expect(items['login-1']!.name, 'GitHub');
        expect(items['login-1']!.notes, 'work account');
        expect(items['login-1']!.isFavorite, isTrue);
        expect(items['note-1']!.isFavorite, isFalse);
        expect(items['login-1']!.createdAt, 1700000000001);
        expect(items['note-1']!.createdAt, 1700000000002);
        expect(items['identity-1']!.createdAt, 1700000000003);
        expect(items['ssh-1']!.createdAt, 1700000000004);
      });

      test('login 字段完整保留', () async {
        final login = byId(await roundTrip(encrypted: encrypted))['login-1']!;
        expect(login.login, isNotNull);
        expect(login.loginOrEmpty.toJson(), loginSeed().loginOrEmpty.toJson());
        expect(login.loginOrEmpty.password, kLoginPassword);
        expect(login.loginOrEmpty.totpSecret, kLoginTotp);
        expect(login.identity, isNull);
        expect(login.sshKey, isNull);
      });

      test('secure_note 正文存在 notes 里，且不受其它字段块影响', () async {
        final note = byId(await roundTrip(encrypted: encrypted))['note-1']!;
        expect(note.name, 'Recovery codes');
        expect(note.notes, kNoteBody);
        expect(note.login, isNull);
        expect(note.identity, isNull);
        expect(note.sshKey, isNull);
      });

      test('identity 全部字段保留', () async {
        final identity =
            byId(await roundTrip(encrypted: encrypted))['identity-1']!;
        expect(identity.identity, isNotNull);
        expect(identity.identity!.toJson(), identitySeed().identity!.toJson());
        expect(identity.identity!.idNumber, kIdNumber);
        expect(identity.identity!.passportNumber, kPassport);
        expect(identity.login, isNull);
        expect(identity.sshKey, isNull);
      });

      test('ssh_key 全部字段保留（公钥/私钥/口令/指纹/类型/位长/注释）', () async {
        final ssh = byId(await roundTrip(encrypted: encrypted))['ssh-1']!;
        expect(ssh.sshKey, isNotNull);
        expect(ssh.sshKey!.toJson(), sshSeed().sshKey!.toJson());
        expect(ssh.sshKey!.privateKey, kPrivateKey);
        expect(ssh.sshKey!.passphrase, kPassphrase);
        expect(ssh.sshKey!.bits, 256);
        expect(ssh.login, isNull);
        expect(ssh.identity, isNull);
      });

      test('自定义字段（text / hidden / boolean）保留', () async {
        final items = byId(await roundTrip(encrypted: encrypted));

        expect(
          items['login-1']!.customFields.map((f) => f.toJson()).toList(),
          [
            {'label': 'PIN', 'value': '1234', 'type': 'text'},
          ],
        );
        expect(
          items['note-1']!.customFields.map((f) => f.toJson()).toList(),
          [
            {'label': 'Hidden', 'value': kHiddenField, 'type': 'hidden'},
            {'label': 'Enabled', 'value': 'true', 'type': 'boolean'},
          ],
        );
        expect(items['note-1']!.customFields[1].booleanValue, isTrue);
        expect(items['identity-1']!.customFields, isEmpty);
      });
    });
  }

  // ─── 明文导出的条目形状 ──────────────────────────────────

  test('明文导出：每类条目只带自己的字段块', () async {
    await seedAll();
    final json = await service.exportPlainJson();
    final doc = jsonDecode(json) as Map<String, dynamic>;
    final entries = (doc['entries'] as List<dynamic>)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final byId = {for (final e in entries) e['id'] as String: e};

    expect(doc['version'], '2.0.0');
    expect(byId.keys.toSet(), {'login-1', 'note-1', 'identity-1', 'ssh-1'});

    final login = byId['login-1']!;
    expect(login['type'], 'login');
    expect(login.containsKey('identity'), isFalse);
    expect(login.containsKey('ssh_key'), isFalse);
    expect(login['login']['password'], kLoginPassword);

    final note = byId['note-1']!;
    expect(note['type'], 'secure_note');
    expect(note['notes'], kNoteBody);
    expect(note.containsKey('login'), isFalse);
    expect(note.containsKey('identity'), isFalse);
    expect(note.containsKey('ssh_key'), isFalse);

    final identity = byId['identity-1']!;
    expect(identity['type'], 'identity');
    expect(identity['identity']['id_number'], kIdNumber);
    expect(identity['identity']['passport_number'], kPassport);
    expect(identity.containsKey('login'), isFalse);
    expect(identity.containsKey('ssh_key'), isFalse);
    // 没有自定义字段时整个 custom_fields 键都省略
    expect(identity.containsKey('custom_fields'), isFalse);

    final ssh = byId['ssh-1']!;
    expect(ssh['type'], 'ssh_key');
    expect(ssh['ssh_key']['private_key'], kPrivateKey);
    expect(ssh['ssh_key']['passphrase'], kPassphrase);
    expect(ssh['ssh_key']['bits'], 256);
    expect(ssh.containsKey('login'), isFalse);
    expect(ssh.containsKey('identity'), isFalse);

    expect(login['custom_fields'], [
      {'label': 'PIN', 'value': '1234', 'type': 'text'},
    ]);
  });

  // ─── 加密备份里不得出现明文机密 ──────────────────────────

  test('加密备份的原始文本里没有任何明文密码 / TOTP / 私钥 / 口令 / 证件号', () async {
    await seedAll();

    final plain = await service.exportPlainJson();
    final encrypted = await service.exportEncrypted();

    // 先证明标记本身是有效的：明文导出里这些串确实存在，
    // 否则"加密备份里找不到"就成了永远成立的空断言。
    for (final secret in kSecretMarkers) {
      expect(plain, contains(secret), reason: '明文导出里应该有 $secret');
    }

    for (final secret in kSecretMarkers) {
      expect(encrypted, isNot(contains(secret)), reason: '加密备份泄漏了 $secret');
    }
    expect(encrypted, isNot(contains('Recovery codes')));
    expect(encrypted, isNot(contains('octocat')));

    // 外壳里只有密文
    final shell = jsonDecode(encrypted) as Map<String, dynamic>;
    expect(shell['format'], 'encrypted');
    expect(shell['data'], isA<String>());
  });
}

// ─── 测试数据 ─────────────────────────────────────────────

const String kLoginPassword = 'LOGIN-PASSWORD-MARKER-001';
const String kLoginTotp = 'TOTP-SECRET-MARKER-002';
const String kNoteMarker = 'NOTE-BODY-MARKER-003';
const String kNoteBody = '$kNoteMarker\n第二行正文';
const String kHiddenField = 'HIDDEN-FIELD-MARKER-004';
const String kIdNumber = 'ID-NUMBER-MARKER-005';
const String kPassport = 'PASSPORT-MARKER-006';
const String kPrivateKeyMarker = 'PRIVATE-KEY-MARKER-007';
const String kPrivateKey =
    '-----BEGIN OPENSSH PRIVATE KEY-----\n$kPrivateKeyMarker\n-----END OPENSSH PRIVATE KEY-----';
const String kPassphrase = 'PASSPHRASE-MARKER-008';
const String kFingerprint = 'SHA256:FINGERPRINT-MARKER-009';

/// 加密备份里一个都不许出现的明文标记（带 `-`，base64 字母表里没有它）。
///
/// 都用**不含换行**的片段：JSON 文本里换行会被转义成 `\n` 两个字符，
/// 拿含换行的整串去断言在明文导出里也匹配不上。
const List<String> kSecretMarkers = [
  kLoginPassword,
  kLoginTotp,
  kNoteMarker,
  kHiddenField,
  kIdNumber,
  kPassport,
  kPrivateKeyMarker,
  kPassphrase,
  kFingerprint,
];

VaultItem loginSeed() => const VaultItem(
      id: 'login-1',
      folderId: 'folder-1',
      type: EntryType.login,
      name: 'GitHub',
      notes: 'work account',
      isFavorite: true,
      login: LoginData(
        url: 'https://github.com',
        username: 'octocat',
        password: kLoginPassword,
        totpSecret: kLoginTotp,
      ),
      customFields: [
        CustomField(label: 'PIN', value: '1234', type: CustomFieldType.text),
      ],
      createdAt: 1700000000001,
      updatedAt: 1700000000001,
    );

VaultItem noteSeed() => const VaultItem(
      id: 'note-1',
      folderId: 'folder-1',
      type: EntryType.secureNote,
      name: 'Recovery codes',
      notes: kNoteBody,
      customFields: [
        CustomField(
          label: 'Hidden',
          value: kHiddenField,
          type: CustomFieldType.hidden,
        ),
        CustomField(
          label: 'Enabled',
          value: 'true',
          type: CustomFieldType.boolean,
        ),
      ],
      createdAt: 1700000000002,
      updatedAt: 1700000000002,
    );

VaultItem identitySeed() => const VaultItem(
      id: 'identity-1',
      type: EntryType.identity,
      name: 'Passport',
      notes: 'identity notes',
      identity: IdentityData(
        title: 'Mr',
        firstName: 'Ada',
        middleName: 'M',
        lastName: 'Lovelace',
        username: 'ada',
        company: 'Analytical Engines',
        email: 'ada@example.com',
        phone: '+1 555 0100',
        idNumber: kIdNumber,
        passportNumber: kPassport,
        licenseNumber: 'LICENSE-MARKER-010',
        address1: '1 Engine Rd',
        address2: 'Apt 2',
        city: 'London',
        state: 'LDN',
        postalCode: 'N1',
        country: 'UK',
        birthday: '1815-12-10',
        sex: 'F',
      ),
      createdAt: 1700000000003,
      updatedAt: 1700000000003,
    );

VaultItem sshSeed() => const VaultItem(
      id: 'ssh-1',
      type: EntryType.sshKey,
      name: 'GitHub deploy key',
      notes: 'deploy key',
      sshKey: SshKeyData(
        publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB0notarealkey marker@host',
        privateKey: kPrivateKey,
        passphrase: kPassphrase,
        fingerprint: kFingerprint,
        keyType: 'ssh-ed25519',
        bits: 256,
        comment: 'marker@host',
      ),
      createdAt: 1700000000004,
      updatedAt: 1700000000004,
    );

class _TestVault {
  final AppDatabase db;
  final CryptoService crypto;
  final VaultRepository repo;
  final ExportImportService service;

  const _TestVault(this.db, this.crypto, this.repo, this.service);
}
