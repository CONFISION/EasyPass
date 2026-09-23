import 'dart:convert';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/models/vault_item_mapper.dart';

import 'fakes.dart';

/// 2.3.0 多条目类型：模型 / JSON 编解码 / 加解密映射 的契约测试。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final crypto = CryptoService(secureStorage: FakeSecureStorage());
  final key = crypto.deriveKey('master', crypto.generateSalt());

  group('EntryType', () {
    test('wireName 是稳定标识符（协议与导出都依赖它）', () {
      expect(EntryType.login.wireName, 'login');
      expect(EntryType.secureNote.wireName, 'secure_note');
      expect(EntryType.identity.wireName, 'identity');
      expect(EntryType.sshKey.wireName, 'ssh_key');
    });

    test('fromWire 容错：别名、大小写、未知值回退登录', () {
      expect(EntryType.fromWire('login'), EntryType.login);
      expect(EntryType.fromWire('  SSH_KEY '), EntryType.sshKey);
      expect(EntryType.fromWire('ssh-key'), EntryType.sshKey);
      expect(EntryType.fromWire('ssh'), EntryType.sshKey);
      expect(EntryType.fromWire('note'), EntryType.secureNote);
      expect(EntryType.fromWire('SecureNote'), EntryType.secureNote);
      expect(EntryType.fromWire('identity'), EntryType.identity);
      // 旧数据 / 旧 daemon 没有 type 字段
      expect(EntryType.fromWire(null), EntryType.login);
      expect(EntryType.fromWire(''), EntryType.login);
      expect(EntryType.fromWire(42), EntryType.login);
    });

    test('只有登录类型参与自动填充', () {
      expect(EntryType.login.isAutofillable, isTrue);
      expect(EntryType.secureNote.isAutofillable, isFalse);
      expect(EntryType.identity.isAutofillable, isFalse);
      expect(EntryType.sshKey.isAutofillable, isFalse);
    });
  });

  group('字段容器 JSON 往返', () {
    test('CustomField：三种类型都能往返，布尔值用字符串存', () {
      final fields = [
        const CustomField(label: 'PIN', value: '1234'),
        const CustomField(
          label: '恢复码',
          value: 'abcd-efgh',
          type: CustomFieldType.hidden,
        ),
        const CustomField(
          label: '已启用',
          value: 'true',
          type: CustomFieldType.boolean,
        ),
      ];

      final decoded = fields
          .map((f) => CustomField.fromJson(
              jsonDecode(jsonEncode(f.toJson())) as Map<String, dynamic>))
          .toList();

      expect(decoded.map((f) => f.label), ['PIN', '恢复码', '已启用']);
      expect(decoded[1].type, CustomFieldType.hidden);
      expect(decoded[2].isBoolean, isTrue);
      expect(decoded[2].booleanValue, isTrue);
    });

    test('CustomFieldType.fromWire 容错', () {
      expect(CustomFieldType.fromWire('HIDDEN'), CustomFieldType.hidden);
      expect(CustomFieldType.fromWire('checkbox'), CustomFieldType.boolean);
      expect(CustomFieldType.fromWire('wat'), CustomFieldType.text);
      expect(CustomFieldType.fromWire(null), CustomFieldType.text);
    });

    test('IdentityData 往返且缺字段不炸', () {
      const identity = IdentityData(
        firstName: '三',
        lastName: '张',
        idNumber: '110101199001011234',
        email: 'zhang@example.com',
        city: '北京',
        birthday: '1990-01-01',
      );
      final round = IdentityData.fromJson(
          jsonDecode(jsonEncode(identity.toJson())) as Map<String, dynamic>);
      expect(round.firstName, '三');
      expect(round.idNumber, '110101199001011234');
      expect(round.fullName, '三 张');

      final empty = IdentityData.fromJson(const {});
      expect(empty.firstName, '');
      expect(empty.fullName, '');
    });

    test('SshKeyData 往返，bits 缺失时为 null', () {
      const ssh = SshKeyData(
        publicKey: 'ssh-ed25519 AAAA test@host',
        privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\nx\n-----END-----',
        passphrase: 'pw',
        fingerprint: 'SHA256:abc',
        keyType: 'ssh-ed25519',
        bits: 256,
        comment: 'test@host',
      );
      final round = SshKeyData.fromJson(
          jsonDecode(jsonEncode(ssh.toJson())) as Map<String, dynamic>);
      expect(round.fingerprint, 'SHA256:abc');
      expect(round.bits, 256);
      expect(round.hasPrivateKey, isTrue);

      final noBits = SshKeyData.fromJson(const {'public_key': 'x'});
      expect(noBits.bits, isNull);
      expect(noBits.keyType, '');
    });

    test('EntryPayload：只输出有效字段，空载荷 isEmpty', () {
      const payload = EntryPayload(
        customFields: [
          CustomField(label: '', value: ''), // 完全空白的一行 → 丢弃
          CustomField(label: '有值', value: 'v'),
        ],
        identity: IdentityData(firstName: 'A'),
      );
      final json = payload.toJson();
      expect(json['v'], EntryPayload.version);
      expect((json['custom_fields'] as List).length, 1); // 空行被丢掉
      expect((json['identity'] as Map)['first_name'], 'A');
      expect(json.containsKey('ssh_key'), isFalse);

      expect(EntryPayload.empty.isEmpty, isTrue);
      expect(
        const EntryPayload(customFields: [CustomField(label: '', value: '')])
            .isEmpty,
        isTrue,
      );
      expect(payload.isEmpty, isFalse);
      // 有标签但没填值：保留（用户可能只是暂时没填），不算空
      expect(
        const EntryPayload(customFields: [CustomField(label: 'PIN')]).isEmpty,
        isFalse,
      );
    });
  });

  group('VaultItem', () {
    test('四种类型都能 JSON 往返（导出格式 2.0.0）', () {
      final items = [
        VaultItem(
          id: '1',
          type: EntryType.login,
          name: 'GitHub',
          notes: '备注',
          isFavorite: true,
          login: const LoginData(
            url: 'https://github.com',
            username: 'alice',
            password: 's3cret',
            totpSecret: 'JBSWY3DPEHPK3PXP',
          ),
          customFields: const [CustomField(label: 'PIN', value: '1')],
          createdAt: 10,
          updatedAt: 20,
        ),
        VaultItem(
          id: '2',
          type: EntryType.secureNote,
          name: 'WiFi',
          notes: '密码在保险箱里',
          createdAt: 10,
          updatedAt: 20,
        ),
        VaultItem(
          id: '3',
          type: EntryType.identity,
          name: '身份证',
          identity: const IdentityData(firstName: '三', idNumber: '123'),
          createdAt: 10,
          updatedAt: 20,
        ),
        VaultItem(
          id: '4',
          type: EntryType.sshKey,
          name: 'github key',
          sshKey: const SshKeyData(publicKey: 'ssh-ed25519 AAAA'),
          createdAt: 10,
          updatedAt: 20,
        ),
      ];

      for (final item in items) {
        final round = VaultItem.fromJson(
            jsonDecode(jsonEncode(item.toJson())) as Map<String, dynamic>);
        expect(round.id, item.id);
        expect(round.type, item.type);
        expect(round.name, item.name);
        expect(round.notes, item.notes);
        expect(round.isFavorite, item.isFavorite);
        expect(round.createdAt, item.createdAt);
        expect(round.loginOrEmpty.password, item.loginOrEmpty.password);
        expect(round.identityOrEmpty.idNumber, item.identityOrEmpty.idNumber);
        expect(round.sshKeyOrEmpty.publicKey, item.sshKeyOrEmpty.publicKey);
      }
    });

    test('只有当前类型的字段块会被导出', () {
      final ssh = VaultItem(
        id: '4',
        type: EntryType.sshKey,
        name: 'k',
        login: const LoginData(password: '不该出现'),
        sshKey: const SshKeyData(publicKey: 'ssh-ed25519 AAAA'),
        createdAt: 0,
        updatedAt: 0,
      );
      final json = ssh.toJson();
      expect(json.containsKey('login'), isFalse);
      expect(json['type'], 'ssh_key');
      expect(json.containsKey('ssh_key'), isTrue);
    });

    test('兼容 1.x 平铺导出的登录字段', () {
      final legacy = VaultItem.fromJson(const {
        'id': 'x',
        'name': '旧条目',
        'url': 'https://example.com',
        'username': 'bob',
        'password': 'pw',
        'totp_secret': 'SECRET',
        'is_favorite': true,
      });
      expect(legacy.type, EntryType.login);
      expect(legacy.loginOrEmpty.username, 'bob');
      expect(legacy.loginOrEmpty.password, 'pw');
      expect(legacy.loginOrEmpty.totpSecret, 'SECRET');
      expect(legacy.isFavorite, isTrue);
    });

    test('searchableText 不含密码 / 私钥 / 口令 / 隐藏字段值', () {
      final login = VaultItem(
        id: '1',
        type: EntryType.login,
        name: 'GitHub',
        login: const LoginData(
          url: 'https://github.com',
          username: 'alice',
          password: 'TOPSECRET',
          totpSecret: 'TOTPSECRET',
        ),
        customFields: const [
          CustomField(label: 'pin', value: 'HIDDENVALUE', type: CustomFieldType.hidden),
        ],
        createdAt: 0,
        updatedAt: 0,
      );
      final text = login.searchableText;
      expect(text.contains('github'), isTrue);
      expect(text.contains('alice'), isTrue);
      expect(text.contains('topsecret'), isFalse);
      expect(text.contains('totpsecret'), isFalse);
      expect(text.contains('hiddenvalue'), isFalse);

      final ssh = VaultItem(
        id: '2',
        type: EntryType.sshKey,
        name: 'key',
        sshKey: const SshKeyData(
          publicKey: 'ssh-ed25519 AAAACOMMENT',
          privateKey: 'PRIVATEKEYMATERIAL',
          passphrase: 'KEYPASS',
          fingerprint: 'SHA256:finger',
        ),
        createdAt: 0,
        updatedAt: 0,
      );
      final sshText = ssh.searchableText;
      expect(sshText.contains('sha256:finger'), isTrue);
      expect(sshText.contains('privatekeymaterial'), isFalse);
      expect(sshText.contains('keypass'), isFalse);
    });

    test('subtitle 按类型给出可读摘要', () {
      VaultItem make(EntryType type, {LoginData? login, IdentityData? identity, SshKeyData? ssh, String notes = ''}) =>
          VaultItem(
            id: 'i',
            type: type,
            name: 'n',
            notes: notes,
            login: login,
            identity: identity,
            sshKey: ssh,
            createdAt: 0,
            updatedAt: 0,
          );

      expect(make(EntryType.login, login: const LoginData(username: 'u')).subtitle, 'u');
      expect(make(EntryType.login, login: const LoginData(url: 'https://a.b')).subtitle, 'https://a.b');
      expect(make(EntryType.identity, identity: const IdentityData(firstName: 'A', lastName: 'B')).subtitle, 'A B');
      expect(make(EntryType.sshKey, ssh: const SshKeyData(fingerprint: 'SHA256:x')).subtitle, 'SHA256:x');
      expect(make(EntryType.secureNote, notes: 'line1\nline2').subtitle, 'line1 line2');
    });
  });

  group('VaultItemMapper：加密落库', () {
    late AppDatabase db;
    late VaultItemMapper mapper;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      mapper = VaultItemMapper(crypto);
    });

    tearDown(() => db.close());

    test('登录条目：字段进列，且库里看不到明文', () async {
      final item = VaultItem(
        id: 'login-1',
        type: EntryType.login,
        name: 'GitHub',
        notes: '工作账号',
        login: const LoginData(
          url: 'https://github.com',
          username: 'alice',
          password: 'S3CRET-PW',
          totpSecret: 'JBSWY3DPEHPK3PXP',
        ),
        customFields: const [CustomField(label: 'PIN', value: '9988')],
        createdAt: 1,
        updatedAt: 2,
      );

      await db.insertEntry(mapper.toInsert(item, key));
      final row = (await db.getAllEntries()).single;

      expect(row.type, 'login');
      expect(row.url, 'https://github.com');
      expect(row.username, 'alice');
      expect(row.passwordEncrypted.contains('S3CRET-PW'), isFalse);
      expect(row.notesEncrypted!.contains('工作账号'), isFalse);
      expect(row.dataEncrypted.contains('9988'), isFalse);
      expect(crypto.decryptData(row.passwordEncrypted, key), 'S3CRET-PW');

      final back = mapper.fromRow(row, key);
      expect(back.loginOrEmpty.password, 'S3CRET-PW');
      expect(back.notes, '工作账号');
      expect(back.customFields.single.value, '9988');
    });

    test('安全笔记：password 列留空，正文进 notes', () async {
      final item = VaultItem(
        id: 'note-1',
        type: EntryType.secureNote,
        name: 'WiFi',
        notes: '密码：12345678',
        createdAt: 1,
        updatedAt: 2,
      );
      await db.insertEntry(mapper.toInsert(item, key));
      final row = (await db.getAllEntries()).single;

      expect(row.type, 'secure_note');
      expect(row.passwordEncrypted, '');
      expect(row.url, '');
      expect(crypto.decryptData(row.notesEncrypted!, key), '密码：12345678');

      final back = mapper.fromRow(row, key);
      expect(back.type, EntryType.secureNote);
      expect(back.notes, '密码：12345678');
      expect(back.login, isNull);
    });

    test('身份 / SSH：类型字段进 data_encrypted，且不外泄到明文列', () async {
      final identity = VaultItem(
        id: 'id-1',
        type: EntryType.identity,
        name: '身份证',
        identity: const IdentityData(firstName: '三', idNumber: '110101199001011234'),
        createdAt: 1,
        updatedAt: 2,
      );
      final ssh = VaultItem(
        id: 'ssh-1',
        type: EntryType.sshKey,
        name: 'server key',
        sshKey: const SshKeyData(
          publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabc test@host',
          privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----',
          passphrase: 'KEYPASS',
        ),
        createdAt: 1,
        updatedAt: 2,
      );

      await db.insertEntry(mapper.toInsert(identity, key));
      await db.insertEntry(mapper.toInsert(ssh, key));
      final rows = await db.getAllEntries();
      final idRow = rows.firstWhere((r) => r.id == 'id-1');
      final sshRow = rows.firstWhere((r) => r.id == 'ssh-1');

      expect(idRow.dataEncrypted.contains('110101199001011234'), isFalse);
      expect(sshRow.dataEncrypted.contains('KEYPASS'), isFalse);
      expect(idRow.url, '');
      expect(sshRow.passwordEncrypted, '');

      final backIdentity = mapper.fromRow(idRow, key);
      expect(backIdentity.identityOrEmpty.idNumber, '110101199001011234');

      final backSsh = mapper.fromRow(sshRow, key);
      expect(backSsh.sshKeyOrEmpty.hasPrivateKey, isTrue);
      expect(backSsh.sshKeyOrEmpty.passphrase, 'KEYPASS');
      // 公钥能解析 → 保存时自动补上指纹与类型
      expect(backSsh.sshKeyOrEmpty.keyType, 'ssh-ed25519');
      expect(backSsh.sshKeyOrEmpty.bits, 256);
      expect(backSsh.sshKeyOrEmpty.fingerprint.startsWith('SHA256:'), isTrue);
      expect(backSsh.sshKeyOrEmpty.comment, 'test@host');
    });

    test('normalize：丢弃与类型不符的字段块（切换类型不留脏数据）', () {
      final messy = VaultItem(
        id: 'x',
        type: EntryType.secureNote,
        name: 'n',
        login: const LoginData(password: '不该留'),
        identity: const IdentityData(firstName: '不该留'),
        sshKey: const SshKeyData(privateKey: '不该留'),
        createdAt: 0,
        updatedAt: 0,
      );
      final clean = VaultItemMapper.normalize(messy);
      expect(clean.login, isNull);
      expect(clean.identity, isNull);
      expect(clean.sshKey, isNull);
    });

    test('解不开的密文：宽容模式给空值，严格模式抛异常', () async {
      final wrongKey = crypto.deriveKey('other', crypto.generateSalt());
      final item = VaultItem(
        id: 'login-2',
        type: EntryType.login,
        name: 'x',
        login: const LoginData(password: 'pw'),
        createdAt: 0,
        updatedAt: 0,
      );
      await db.insertEntry(mapper.toInsert(item, key));
      final row = (await db.getAllEntries()).single;

      expect(mapper.fromRow(row, wrongKey).loginOrEmpty.password, '');
      expect(
        () => mapper.fromRow(row, wrongKey, lenient: false),
        throwsA(isA<VaultDecryptException>()),
      );
    });

    test('空载荷不写 data_encrypted（保持空串，便于旧版本读）', () async {
      final item = VaultItem(
        id: 'plain',
        type: EntryType.login,
        name: 'x',
        login: const LoginData(username: 'u'),
        createdAt: 0,
        updatedAt: 0,
      );
      await db.insertEntry(mapper.toInsert(item, key));
      expect((await db.getAllEntries()).single.dataEncrypted, '');
    });
  });
}
