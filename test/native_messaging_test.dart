import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/constants/app_constants.dart';
import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/core/crypto/totp_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/features/browser_bridge/native_messaging_service.dart';
import 'package:easypass/features/browser_bridge/vault_session.dart';

import 'fakes.dart';

/// Protocol-level tests for the native messaging host. These drive
/// [NativeMessagingService.handleRequest] directly (no real stdin/stdout),
/// covering the lock/unlock lifecycle, credential decryption, and errors.
/// 2.3.0 起还覆盖协议 3 的条目 JSON（四种类型）与"自动填充 / 健康报告只认登录条目"。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const masterPassword = 'correct horse battery staple';
  const entryName = 'GitHub';
  const entryUrl = 'https://github.com/login';
  const entryUsername = 'alice';
  const entrySecret = 's3cret-p@ssw0rd!';
  const entryNotes = 'personal account';
  const totpSecret = 'JBSWY3DPEHPK3PXP'; // RFC 6238 base32 test secret

  // 非登录类型的测试夹具（全部是明显的假数据，不是任何真实凭据）。
  const identityIdNumber = '110101199001011234';
  const sshFingerprint = 'SHA256:FixtureFingerprintForTests';
  const sshPublicKey = 'ssh-ed25519 FAKEFIXTUREPUBLICKEY user@host';
  const sshPrivateKeyFixture = 'FAKE-PRIVATE-KEY-MATERIAL-NOT-A-REAL-KEY';

  /// 协议 3 条目 JSON 的**完整**键集合（契约 §5 冻结，扩展依赖它）。
  const protocolEntryKeys = {
    'id',
    'type',
    'name',
    'url',
    'username',
    'password',
    'notes',
    'hasTotp',
    'isFavorite',
    'identity',
    'sshKey',
    'customFields',
  };

  late FakeSecureStorage storage;
  late AppDatabase db;
  late CryptoService crypto;
  late NativeMessagingService service;

  /// 会话密钥（PBKDF2 10 万轮是纯 Dart 实现，缓存一份省掉重复开销）。
  /// 与服务自己派生的那份是**不同实例**，所以 `lock` 清零密钥不会影响它。
  Uint8List? cachedKey;

  setUp(() async {
    storage = FakeSecureStorage();
    crypto = CryptoService(secureStorage: storage);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cachedKey = null;

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

  /// 当前库密钥（等同 daemon 的 `keyReader`）。
  Future<Uint8List> sessionKey() async {
    final cached = cachedKey;
    if (cached != null) return cached;
    final salt = await crypto.getStoredSalt();
    return cachedKey = crypto.deriveKey(masterPassword, salt!);
  }

  /// Insert one encrypted entry using the same key the host derives from
  /// [masterPassword].
  ///
  /// 刻意**手写行**（不走 `saveItem`）：这里要模拟"2.3.0 之前就存在的老库行"
  /// —— 只有登录列、没有 `data_encrypted`，正是协议 3 必须继续兼容的形态。
  Future<void> insertEntry({String? secret, bool withTotp = false}) async {
    final key = await sessionKey();
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

  /// 插入一条可自定义字段的条目（供健康报告 / URL 匹配用例使用）。
  /// [passwordEncryptedOverride] 用来塞入损坏的密文，验证容错解密
  /// （坏密文只能用原始行夹具造出来，走 `saveItem` 是写不出坏数据的）。
  Future<void> insertRow({
    required String id,
    required String name,
    String url = '',
    String password = entrySecret,
    bool withTotp = false,
    String? passwordEncryptedOverride,
  }) async {
    final key = await sessionKey();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insertEntry(PasswordEntriesCompanion.insert(
      id: id,
      name: name,
      url: Value(url),
      username: const Value('alice'),
      passwordEncrypted:
          passwordEncryptedOverride ?? crypto.encryptData(password, key),
      notesEncrypted: const Value(''),
      totpSecretEncrypted:
          Value(withTotp ? crypto.encryptData(totpSecret, key) : ''),
      createdAt: now,
      updatedAt: now,
    ));
  }

  /// 直接写行（模拟旧库 / 手改过的脏数据）：类型是 [type]，但 `url` 列有值。
  /// 用来证明"自动填充只认登录类型"，而不是"只看 url 列有没有值"。
  /// 这种"类型与列自相矛盾"的行**无法**由 `VaultItemMapper` 产出，所以只能用原始行夹具。
  Future<void> insertRawTypedRow({
    required String id,
    required String name,
    required String type,
    String url = '',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insertEntry(PasswordEntriesCompanion.insert(
      id: id,
      name: name,
      type: Value(type),
      url: Value(url),
      passwordEncrypted: '',
      createdAt: now,
      updatedAt: now,
    ));
  }

  /// 走**仓库**落库任意类型的条目（与 UI 保存同一条加密路径）。
  Future<void> saveItem(VaultItem item) async {
    final key = await sessionKey();
    await VaultRepository(db: db, cryptoService: crypto, keyReader: () => key)
        .saveItem(item);
  }

  /// 四种类型各落一条：登录（强密码 + TOTP + 网址）、安全笔记（无网址）、
  /// 身份（带证件号）、SSH 密钥（带指纹），每条都带自定义字段。
  Future<void> seedAllTypes() async {
    await saveItem(const VaultItem(
      id: 'login-1',
      type: EntryType.login,
      name: entryName,
      notes: entryNotes,
      isFavorite: true,
      login: LoginData(
        url: entryUrl,
        username: entryUsername,
        password: entrySecret,
        totpSecret: totpSecret,
      ),
      customFields: [CustomField(label: 'PIN', value: '1234')],
      createdAt: 0,
      updatedAt: 0,
    ));
    await saveItem(const VaultItem(
      id: 'note-1',
      type: EntryType.secureNote,
      name: 'WiFi',
      notes: 'note body text',
      customFields: [
        CustomField(
          label: 'Enabled',
          value: 'true',
          type: CustomFieldType.boolean,
        ),
      ],
      createdAt: 0,
      updatedAt: 0,
    ));
    await saveItem(const VaultItem(
      id: 'identity-1',
      type: EntryType.identity,
      name: 'Me',
      identity: IdentityData(
        firstName: 'Alice',
        lastName: 'Wang',
        username: 'alice-id',
        idNumber: identityIdNumber,
        email: 'alice@example.com',
      ),
      customFields: [CustomField(label: 'Member', value: 'gold')],
      createdAt: 0,
      updatedAt: 0,
    ));
    await saveItem(const VaultItem(
      id: 'ssh-1',
      type: EntryType.sshKey,
      name: 'Server key',
      sshKey: SshKeyData(
        publicKey: sshPublicKey,
        privateKey: sshPrivateKeyFixture,
        fingerprint: sshFingerprint,
        keyType: 'ssh-ed25519',
        bits: 256,
        comment: 'user@host',
      ),
      customFields: [CustomField(label: 'Host', value: 'example.com')],
      createdAt: 0,
      updatedAt: 0,
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

    test('锁定时下发 idleTimeoutSeconds，autoLockRemainingSeconds 为 null', () async {
      final res = await request('getStatus');
      final data = res['data'] as Map<String, dynamic>;
      expect(data['idleTimeoutSeconds'], 300);
      expect(data.containsKey('autoLockRemainingSeconds'), isTrue);
      expect(data['autoLockRemainingSeconds'], isNull);
    });

    test('下发桥接协议版本（UI 靠它识别陈旧 daemon，扩展靠它给错误定性）', () async {
      final res = await request('getStatus');
      final data = res['data'] as Map<String, dynamic>;
      expect(data['protocolVersion'], AppConstants.bridgeProtocolVersion);
      expect(data['protocolVersion'], isA<int>());
    });

    test('解锁后下发剩余秒数（0 < remaining <= idleTimeout）', () async {
      await request('unlock', {'password': masterPassword});

      final res = await request('getStatus');
      final data = res['data'] as Map<String, dynamic>;
      expect(data['idleTimeoutSeconds'], 300);
      final remaining = data['autoLockRemainingSeconds'];
      expect(remaining, isA<int>());
      expect(remaining, greaterThan(0));
      expect(remaining, lessThanOrEqualTo(300));
    });

    test('getStatus 不算活跃操作：轮询状态不会刷新空闲计时器', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final session = VaultSession(clock: () => now);
      final svc =
          NativeMessagingService(db, crypto, TotpService(), session: session);

      await svc.handleRequest(
          {'requestId': 'r', 'action': 'unlock', 'password': masterPassword});
      now = now.add(const Duration(minutes: 4));
      await svc.handleRequest({'requestId': 'r', 'action': 'getStatus'});
      now = now.add(const Duration(minutes: 4));

      final res = await svc.handleRequest({'requestId': 'r', 'action': 'getStatus'});
      final data = res['data'] as Map<String, dynamic>;
      expect(data['locked'], true);
      expect(data['autoLockRemainingSeconds'], isNull);
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

    test('entry JSON 含 hasTotp，且不下发明文 TOTP 密钥', () async {
      await insertEntry(withTotp: true);
      await request('unlock', {'password': masterPassword});

      final res = await request('getAllCredentials');
      expect(res['error'], isNull);
      final entry = (res['data'] as List).first as Map<String, dynamic>;

      expect(entry['hasTotp'], true);
      expect(entry.containsKey('totp'), isFalse);
      // 明文 base32 密钥绝不能出现在响应里
      expect(jsonEncode(res), isNot(contains(totpSecret)));
    });

    test('未配置 TOTP 的条目 hasTotp 为 false，同样没有 totp 字段', () async {
      await insertEntry(withTotp: false);
      await request('unlock', {'password': masterPassword});

      final res = await request('getAllCredentials');
      final entry = (res['data'] as List).first as Map<String, dynamic>;
      expect(entry['hasTotp'], false);
      expect(entry.containsKey('totp'), isFalse);
    });

    test('searchCredentials 结果也不含明文 TOTP 密钥', () async {
      await insertEntry(withTotp: true);
      await request('unlock', {'password': masterPassword});

      final res = await request('searchCredentials', {'query': 'github'});
      expect(res['error'], isNull);
      final entry = (res['data'] as List).first as Map<String, dynamic>;
      expect(entry['hasTotp'], true);
      expect(entry.containsKey('totp'), isFalse);
    });
  });

  group('getCredentials - 按域名匹配（契约 2.4）', () {
    test('条目 URL 带路径也能命中同域的页面 URL', () async {
      await insertEntry(); // https://github.com/login
      await request('unlock', {'password': masterPassword});

      final res =
          await request('getCredentials', {'url': 'https://github.com/session'});
      expect(res['error'], isNull);
      expect((res['data'] as List), hasLength(1));
      expect(((res['data'] as List).first as Map)['id'], 'entry-1');
    });

    test('忽略 scheme / 端口 / www. 差异', () async {
      await insertRow(
          id: 'e', name: 'Example', url: 'http://www.example.com:8080/login');
      await request('unlock', {'password': masterPassword});

      final res = await request('getCredentials',
          {'url': 'https://example.com/account'});
      expect((res['data'] as List), hasLength(1));
    });

    test('子域互相匹配（页面是条目的子域 / 条目是页面的子域）', () async {
      await insertRow(
          id: 'apex', name: 'Apex', url: 'https://example.com/login');
      await insertRow(
          id: 'deep', name: 'Deep', url: 'https://login.example.com/signin');
      await request('unlock', {'password': masterPassword});

      final res = await request('getCredentials',
          {'url': 'https://login.example.com/session'});
      final ids = (res['data'] as List).map((e) => e['id']).toList();
      expect(ids, containsAll(<String>['apex', 'deep']));
    });

    test('不同域名不返回', () async {
      await insertEntry(); // github.com
      await request('unlock', {'password': masterPassword});

      final res =
          await request('getCredentials', {'url': 'https://gitlab.com/login'});
      expect(res['error'], isNull);
      expect((res['data'] as List), isEmpty);
    });

    test('条目 url 为空的条目不参与匹配', () async {
      await insertRow(id: 'nourl', name: 'NoUrl', url: '');
      await request('unlock', {'password': masterPassword});

      final res =
          await request('getCredentials', {'url': 'https://github.com/login'});
      expect((res['data'] as List), isEmpty);
    });

    test('url 为空 / 不可解析时回退为全部登录条目（旧行为）', () async {
      await insertEntry();
      await insertRow(id: 'nourl', name: 'NoUrl', url: '');
      await request('unlock', {'password': masterPassword});

      final empty = await request('getCredentials', {'url': ''});
      expect((empty['data'] as List), hasLength(2));

      final missing = await request('getCredentials');
      expect((missing['data'] as List), hasLength(2));

      final unparsable = await request('getCredentials', {'url': 'about:blank'});
      expect((unparsable['data'] as List), hasLength(2));
    });

    test('锁定态报错', () async {
      final res =
          await request('getCredentials', {'url': 'https://github.com/login'});
      expect(res['error'], isNotNull);
    });
  });

  // ─── 协议 3：条目 JSON 形状（契约 §5）─────────────────────

  group('协议 3 条目 JSON（四种类型）', () {
    test('每种类型：type 判别 + 类型专属块 + 非登录字段为空串', () async {
      await seedAllTypes();
      await request('unlock', {'password': masterPassword});

      final res = await request('getAllCredentials');
      expect(res['error'], isNull);
      final data = (res['data'] as List).cast<Map<String, dynamic>>();
      expect(data, hasLength(4));
      final byId = {for (final e in data) e['id'] as String: e};
      expect(byId.keys,
          unorderedEquals(['login-1', 'note-1', 'identity-1', 'ssh-1']));

      // 键集合就是契约本身：多一个少一个都会让扩展解析出错。
      for (final entry in data) {
        expect(entry.keys.toSet(), protocolEntryKeys,
            reason: '${entry['id']} 的条目 JSON 键集合必须与契约 §5 完全一致');
        expect(entry['hasTotp'], isA<bool>());
      }

      // ── 登录：url / username / password 都有值，identity/sshKey 为 null
      final login = byId['login-1']!;
      expect(login['type'], 'login');
      expect(login['name'], entryName);
      expect(login['url'], entryUrl);
      expect(login['username'], entryUsername);
      expect(login['password'], entrySecret);
      expect(login['notes'], entryNotes);
      expect(login['hasTotp'], true);
      expect(login['isFavorite'], true);
      expect(login['identity'], isNull);
      expect(login['sshKey'], isNull);
      expect(login['customFields'],
          [{'label': 'PIN', 'value': '1234', 'type': 'text'}]);

      // ── 安全笔记：正文走 notes，其余一律空串
      final note = byId['note-1']!;
      expect(note['type'], 'secure_note');
      expect(note['name'], 'WiFi');
      expect(note['notes'], 'note body text');
      expect(note['url'], '');
      expect(note['username'], '');
      expect(note['password'], '');
      expect(note['hasTotp'], false);
      expect(note['identity'], isNull);
      expect(note['sshKey'], isNull);
      expect(note['customFields'],
          [{'label': 'Enabled', 'value': 'true', 'type': 'boolean'}]);

      // ── 身份：username 取 identity.username，identity 块是 snake_case
      final identity = byId['identity-1']!;
      expect(identity['type'], 'identity');
      expect(identity['url'], '');
      expect(identity['username'], 'alice-id');
      expect(identity['password'], '');
      expect(identity['hasTotp'], false);
      expect(identity['sshKey'], isNull);
      final identityBlock = identity['identity'] as Map<String, dynamic>;
      expect(identityBlock['first_name'], 'Alice');
      expect(identityBlock['last_name'], 'Wang');
      expect(identityBlock['id_number'], identityIdNumber);
      expect(identityBlock['email'], 'alice@example.com');
      expect(identityBlock.containsKey('firstName'), isFalse,
          reason: '键名必须是 IdentityData.toJson() 的 snake_case');
      expect(identity['customFields'],
          [{'label': 'Member', 'value': 'gold', 'type': 'text'}]);

      // ── SSH：sshKey 块是 snake_case，字段名与 SshKeyData.toJson() 一致
      final ssh = byId['ssh-1']!;
      expect(ssh['type'], 'ssh_key');
      expect(ssh['url'], '');
      expect(ssh['username'], '');
      expect(ssh['password'], '');
      expect(ssh['hasTotp'], false);
      expect(ssh['identity'], isNull);
      final sshBlock = ssh['sshKey'] as Map<String, dynamic>;
      expect(sshBlock['public_key'], sshPublicKey);
      expect(sshBlock['private_key'], sshPrivateKeyFixture);
      expect(sshBlock['fingerprint'], sshFingerprint);
      expect(sshBlock['key_type'], 'ssh-ed25519');
      expect(sshBlock['bits'], 256);
      expect(sshBlock['comment'], 'user@host');
      expect(sshBlock.containsKey('publicKey'), isFalse,
          reason: '键名必须是 SshKeyData.toJson() 的 snake_case');
      expect(ssh['customFields'],
          [{'label': 'Host', 'value': 'example.com', 'type': 'text'}]);
    });

    test('TOTP 密钥绝不出现在任何类型的条目 JSON 里', () async {
      await seedAllTypes();
      await request('unlock', {'password': masterPassword});

      for (final action in ['getAllCredentials', 'searchCredentials']) {
        final res = await request(
            action, action == 'searchCredentials' ? {'query': 'git'} : const {});
        expect(res['error'], isNull, reason: action);
        // 明文 base32 密钥绝不能出现在响应里，也不能有 totp 字段
        expect(jsonEncode(res), isNot(contains(totpSecret)), reason: action);
        for (final entry in (res['data'] as List).cast<Map>()) {
          expect(entry.containsKey('totp'), isFalse, reason: action);
          expect(entry.containsKey('totpSecret'), isFalse, reason: action);
        }
      }

      // getTotp 是唯一出口，且只回 6 位码
      final totp = await request('getTotp', {'entryId': 'login-1'});
      expect((totp['data'] as Map)['totp'], hasLength(6));
      expect(jsonEncode(totp), isNot(contains(totpSecret)));
    });

    test('没有自定义字段时 customFields 是空数组（不是 null、不缺键）', () async {
      await insertEntry(); // 登录条目，无自定义字段
      await request('unlock', {'password': masterPassword});

      final res = await request('getAllCredentials');
      final entry = (res['data'] as List).first as Map<String, dynamic>;
      expect(entry['customFields'], isEmpty);
      expect(entry['customFields'], isA<List<dynamic>>());
      expect(entry['type'], 'login');
      expect(entry['identity'], isNull);
      expect(entry['sshKey'], isNull);
    });

    test('getStatus.entryCount 数的是全部类型', () async {
      await seedAllTypes();
      await insertEntry(); // 再来一条登录条目
      await request('unlock', {'password': masterPassword});

      final res = await request('getStatus');
      expect((res['data'] as Map)['entryCount'], 5);
    });
  });

  // ─── 自动填充候选只认登录条目（契约 §5）───────────────────

  group('getCredentials - 只返回登录条目', () {
    test('URL 匹配路径：四种类型都在库里，只回登录条目', () async {
      await seedAllTypes();
      // 脏数据：类型是 secure_note，但 url 列能匹配页面 URL
      await insertRawTypedRow(
        id: 'note-with-url',
        name: 'NoteWithUrl',
        type: 'secure_note',
        url: 'https://github.com/login',
      );
      await request('unlock', {'password': masterPassword});

      final res = await request(
          'getCredentials', {'url': 'https://github.com/session'});
      expect(res['error'], isNull);
      expect((res['data'] as List).map((e) => e['id']), ['login-1'],
          reason: '笔记 / 身份 / SSH 出现在填充列表里 = 契约 §5 的坑');
    });

    test('回退路径（url 缺失 / 空 / 不可解析）同样只给登录条目', () async {
      await seedAllTypes();
      await request('unlock', {'password': masterPassword});

      for (final probe in <Map<String, dynamic>>[
        <String, dynamic>{},
        {'url': ''},
        {'url': 'about:blank'},
      ]) {
        final res = await request('getCredentials', probe);
        expect(res['error'], isNull, reason: '$probe');
        expect((res['data'] as List).map((e) => e['id']), ['login-1'],
            reason: '回退成"全部条目"时把非登录条目塞进来 = 契约 §5 的坑：$probe');
      }
    });

    test('库里只有非登录条目时，回退路径返回空列表', () async {
      await saveItem(const VaultItem(
        id: 'note-only',
        type: EntryType.secureNote,
        name: 'Note',
        notes: 'no url here',
        createdAt: 0,
        updatedAt: 0,
      ));
      await request('unlock', {'password': masterPassword});

      final res = await request('getCredentials', {'url': ''});
      expect(res['error'], isNull);
      expect(res['data'] as List, isEmpty);
    });
  });

  // ─── 搜索所有类型（契约 §5）──────────────────────────────

  group('searchCredentials - 所有类型', () {
    test('按证件号搜到身份条目', () async {
      await seedAllTypes();
      await request('unlock', {'password': masterPassword});

      final res = await request('searchCredentials', {'query': identityIdNumber});
      expect(res['error'], isNull);
      final data = (res['data'] as List).cast<Map<String, dynamic>>();
      expect(data.map((e) => e['id']), ['identity-1']);
      expect(data.first['type'], 'identity');
      expect((data.first['identity'] as Map)['id_number'], identityIdNumber);
    });

    test('按指纹搜到 SSH 条目', () async {
      await seedAllTypes();
      await request('unlock', {'password': masterPassword});

      final res = await request('searchCredentials', {'query': sshFingerprint});
      expect(res['error'], isNull);
      final data = (res['data'] as List).cast<Map<String, dynamic>>();
      expect(data.map((e) => e['id']), ['ssh-1']);
      expect(data.first['type'], 'ssh_key');
      expect((data.first['sshKey'] as Map)['fingerprint'], sshFingerprint);
    });

    test('按名称搜到安全笔记', () async {
      await seedAllTypes();
      await request('unlock', {'password': masterPassword});

      final res = await request('searchCredentials', {'query': 'wifi'});
      expect((res['data'] as List).map((e) => e['id']), ['note-1']);
      expect(((res['data'] as List).first as Map)['type'], 'secure_note');
    });

    test('空查询返回所有类型（popup 的完整列表）', () async {
      await seedAllTypes();
      await request('unlock', {'password': masterPassword});

      final res = await request('searchCredentials', {'query': ''});
      expect(res['error'], isNull);
      expect((res['data'] as List).map((e) => e['id']).toSet(),
          {'login-1', 'note-1', 'identity-1', 'ssh-1'});
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
      expect(data['period'], 30);
      expect(data['period'], NativeMessagingService.totpPeriodSeconds);
    });

    test('errors when the entry has no TOTP secret', () async {
      await insertEntry(withTotp: false);
      await request('unlock', {'password': masterPassword});

      final res = await request('getTotp', {'entryId': 'entry-1'});
      expect(res['error'], isNotNull);
    });

    test('非登录条目报错（不回空验证码）', () async {
      await seedAllTypes();
      await request('unlock', {'password': masterPassword});

      for (final id in ['note-1', 'identity-1', 'ssh-1']) {
        final res = await request('getTotp', {'entryId': id});
        expect(res['error'], isNotNull, reason: '$id 不是登录条目');
        expect(res['data'], isNull, reason: '$id 不该拿到任何验证码字段');
      }

      // 同库里的登录条目照常拿码（证明上面不是"整体坏了"）
      final ok = await request('getTotp', {'entryId': 'login-1'});
      expect(ok['error'], isNull);
      expect((ok['data'] as Map)['totp'], hasLength(6));
    });

    test('条目不存在时报错', () async {
      await request('unlock', {'password': masterPassword});

      final res = await request('getTotp', {'entryId': 'missing'});
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

  // ─── 帧读取（合并 chunk 回归）────────────────────────────

  group('NativeMessageReader - 合并 chunk 不丢帧', () {
    Uint8List frameOf(Map<String, dynamic> message) =>
        NativeMessagingService.encodeMessage(message);

    test('同一个 chunk 里的多帧不会被丢掉', () async {
      final a = {'requestId': 'a', 'action': 'getStatus'};
      final b = {'requestId': 'b', 'action': 'lock'};
      // 两帧拼成一个 chunk（bridge 把"握手帧 + 首个请求"一起写就是这样）
      final chunk = [...frameOf(a), ...frameOf(b)];

      final reader =
          NativeMessageReader(StreamIterator(Stream.fromIterable([chunk])));

      expect(await reader.read(), a);
      expect(await reader.read(), b);
      expect(await reader.read(), isNull);
    });

    test('同一 iterator 上连续调用 readMessage 也能读出第二帧（探针最小复现）',
        () async {
      final chunk = <int>[
        ...frameOf({'a': 1}),
        ...frameOf({'b': 2}),
      ];
      final it = StreamIterator<List<int>>(Stream.fromIterable([chunk]));

      expect(await NativeMessagingService.readMessage(it), {'a': 1});
      expect(await NativeMessagingService.readMessage(it), {'b': 2},
          reason: '第二帧被丢弃 = TCP 合并 chunk 时丢帧');
    });

    test('不同 iterator 之间不串缓冲', () async {
      final one = [...frameOf({'a': 1}), ...frameOf({'b': 2})];
      final it1 = StreamIterator<List<int>>(Stream.fromIterable([one]));
      final it2 = StreamIterator<List<int>>(
          Stream.fromIterable([frameOf({'c': 3})]));

      expect(await NativeMessagingService.readMessage(it1), {'a': 1});
      expect(await NativeMessagingService.readMessage(it2), {'c': 3});
      expect(await NativeMessagingService.readMessage(it1), {'b': 2});
    });

    test('三帧混写：整块 + 半个头 + 拆开的负载都能顺序读出', () async {
      final a = {'requestId': 'a', 'action': 'getStatus'};
      final b = {'requestId': 'b', 'action': 'lock'};
      final c = {'requestId': 'c', 'action': 'getStatus'};
      final frameB = frameOf(b);

      final reader = NativeMessageReader(StreamIterator(
          Stream.fromIterable(<List<int>>[
        [...frameOf(a), ...frameB.sublist(0, 2)],
        frameB.sublist(2),
        frameOf(c),
      ])));

      expect(await reader.read(), a);
      expect(await reader.read(), b);
      expect(await reader.read(), c);
      expect(await reader.read(), isNull);
    });

    test('EOF 时返回 null（半截帧同样视为结束）', () async {
      final frame = frameOf({'requestId': 'a', 'action': 'getStatus'});
      final reader = NativeMessageReader(
          StreamIterator(Stream.fromIterable([frame.sublist(0, 6)])));
      expect(await reader.read(), isNull);
    });
  });

  // ─── C 方案：会话跨连接保持 ──────────────────────────────

  group('VaultSession 共享（daemon 注入同一实例）', () {
    Future<Map<String, dynamic>> ask(
            NativeMessagingService svc, String action,
            [Map<String, dynamic> extra = const {}]) =>
        svc.handleRequest(
            {'requestId': 'r', 'action': action, ...extra});

    test('共享同一 session 时解锁态互通（第二个 service 无需再解锁）', () async {
      await insertEntry();
      final session = VaultSession();
      final a = NativeMessagingService(db, crypto, TotpService(),
          session: session);
      final b = NativeMessagingService(db, crypto, TotpService(),
          session: session);

      // a 解锁前，b 是锁定态
      expect(((await ask(b, 'getStatus'))['data'] as Map)['locked'], true);

      expect((await ask(a, 'unlock', {'password': masterPassword}))['error'],
          isNull);

      expect(((await ask(b, 'getStatus'))['data'] as Map)['locked'], false);

      final creds = await ask(b, 'getAllCredentials');
      expect(creds['error'], isNull);
      expect((creds['data'] as List), hasLength(1));
    });

    test('共享 session 时 lock 会同时锁掉所有 service', () async {
      final session = VaultSession();
      final a = NativeMessagingService(db, crypto, TotpService(),
          session: session);
      final b = NativeMessagingService(db, crypto, TotpService(),
          session: session);

      await ask(a, 'unlock', {'password': masterPassword});
      await ask(b, 'lock');

      expect(((await ask(a, 'getStatus'))['data'] as Map)['locked'], true);
      expect((await ask(a, 'getAllCredentials'))['error'], isNotNull);
    });

    test('不共享 session 时解锁态互不影响（默认自建会话）', () async {
      final a = NativeMessagingService(db, crypto, TotpService());
      final b = NativeMessagingService(db, crypto, TotpService());

      await ask(a, 'unlock', {'password': masterPassword});

      expect(((await ask(a, 'getStatus'))['data'] as Map)['locked'], false);
      expect(((await ask(b, 'getStatus'))['data'] as Map)['locked'], true);
      expect((await ask(b, 'getAllCredentials'))['error'], isNotNull);
    });

    test('空闲超时后自动回到锁定态（注入时钟）', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final session = VaultSession(clock: () => now);
      final svc = NativeMessagingService(db, crypto, TotpService(),
          session: session);

      await svc.handleRequest(
          {'requestId': 'r', 'action': 'unlock', 'password': masterPassword});
      expect(svc.isUnlocked, isTrue);

      now = now.add(const Duration(minutes: 5, seconds: 1));

      expect(svc.isUnlocked, isFalse);
      final status = await svc.handleRequest({'requestId': 'r', 'action': 'getStatus'});
      expect((status['data'] as Map)['locked'], true);
      expect((status['data'] as Map)['autoLockRemainingSeconds'], isNull);
      expect((await svc.handleRequest({'requestId': 'r', 'action': 'getAllCredentials'}))['error'],
          contains('locked'));
    });

    test('保险库读操作 touch：频繁读取可保持解锁', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final session = VaultSession(clock: () => now);
      final svc = NativeMessagingService(db, crypto, TotpService(),
          session: session);

      await svc.handleRequest(
          {'requestId': 'r', 'action': 'unlock', 'password': masterPassword});

      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(minutes: 4));
        final res =
            await svc.handleRequest({'requestId': 'r', 'action': 'getAllCredentials'});
        expect(res['error'], isNull, reason: '第 $i 次读取仍应处于解锁态');
      }

      // 累计 12 分钟，但每次读取都刷新了活跃时间 → 仍未过期
      expect(svc.isUnlocked, isTrue);

      // 超过 5 分钟不读 → 过期
      now = now.add(const Duration(minutes: 5, seconds: 1));
      expect(svc.isUnlocked, isFalse);
    });
  });

  // ─── 健康报告（契约 2.3）────────────────────────────────

  group('getHealthReport', () {
    test('锁定时报错', () async {
      final res = await request('getHealthReport');
      expect(res['error'], isNotNull);
      expect(res['error'].toString().toLowerCase(), contains('lock'));
    });

    test('返回契约 2.3 的统计结构，且不含任何明文密码', () async {
      // h1 健康；h2/h3 共用弱密码 '123456'，无 TOTP；h2 还没有 URL
      await insertRow(
          id: 'h1',
          name: 'GitHub',
          url: 'https://github.com',
          password: 'Str0ng-Passw0rd!x',
          withTotp: true);
      await insertRow(id: 'h2', name: 'Bank', url: '', password: '123456');
      await insertRow(
          id: 'h3',
          name: 'Shop',
          url: 'https://shop.example.com',
          password: '123456');
      await request('unlock', {'password': masterPassword});

      final res = await request('getHealthReport');
      expect(res['error'], isNull);
      final data = res['data'] as Map<String, dynamic>;

      expect(data['totalEntries'], 3);
      // 100 - 弱密码 2×10 - 重复 1 组×15 - 无 TOTP 2×2 - 无 URL 1×2 = 59
      expect(data['score'], 59);
      expect(data['level'], 'fair');
      expect(data['reusedGroupCount'], 1);

      final weak = data['weakPasswords'] as List;
      expect(weak.map((w) => w['id']), unorderedEquals(['h2', 'h3']));
      expect(weak.map((w) => w['reason']),
          everyElement('commonPassword'));
      expect(weak.map((w) => w['name']), unorderedEquals(['Bank', 'Shop']));

      final reused = data['reusedPasswords'] as List;
      expect(reused.map((r) => r['id']), unorderedEquals(['h2', 'h3']));
      expect(reused.map((r) => r['sharedCount']), everyElement(2));

      expect((data['noTotp'] as List).map((e) => e['id']),
          unorderedEquals(['h2', 'h3']));
      expect((data['noUrl'] as List).map((e) => e['id']), ['h2']);

      // 绝不下发明文密码：整份响应里不能出现密码原文，也不能有 password 字段
      final encoded = jsonEncode(res);
      expect(encoded, isNot(contains('123456')));
      expect(encoded, isNot(contains('Str0ng-Passw0rd!x')));
      expect(encoded, isNot(contains(totpSecret)));
      expect(encoded, isNot(contains('"password"')));
    });

    test('弱密码 reason 用枚举名（tooShort / singleCharType）', () async {
      await insertRow(id: 'w1', name: 'Short', url: 'https://a.com', password: 'ab1');
      await insertRow(
          id: 'w2',
          name: 'Digits',
          url: 'https://b.com',
          password: '987654321012',
          withTotp: true);
      await request('unlock', {'password': masterPassword});

      final res = await request('getHealthReport');
      final weak = (res['data'] as Map)['weakPasswords'] as List;
      final byId = {for (final w in weak) w['id']: w['reason']};
      expect(byId['w1'], 'tooShort');
      expect(byId['w2'], 'singleCharType');
    });

    test('全部健康时 score 100 / level good / 各列表为空', () async {
      await insertRow(
          id: 'ok',
          name: 'GitHub',
          url: 'https://github.com',
          password: 'Str0ng-Passw0rd!x',
          withTotp: true);
      await request('unlock', {'password': masterPassword});

      final res = await request('getHealthReport');
      final data = res['data'] as Map<String, dynamic>;
      expect(data['score'], 100);
      expect(data['level'], 'good');
      expect(data['totalEntries'], 1);
      expect(data['reusedGroupCount'], 0);
      expect(data['weakPasswords'], isEmpty);
      expect(data['reusedPasswords'], isEmpty);
      expect(data['noTotp'], isEmpty);
      expect(data['noUrl'], isEmpty);
    });

    test('空保险库：totalEntries 为 0，score 仍为满分', () async {
      await request('unlock', {'password': masterPassword});

      final res = await request('getHealthReport');
      final data = res['data'] as Map<String, dynamic>;
      expect(data['totalEntries'], 0);
      expect(data['score'], 100);
      expect(data['level'], 'good');
    });

    test('单条解密失败被跳过，不影响整份报告', () async {
      final salt = await crypto.getStoredSalt();
      final key = crypto.deriveKey(masterPassword, salt!);
      // 损坏密文：非法 base64（必然解密失败）+ 截断密文（大概率失败）
      final valid = crypto.encryptData('whatever', key);
      final raw = base64Decode(valid);
      final truncated = base64Encode(raw.sublist(0, raw.length - 1));

      await insertRow(
          id: 'bad1',
          name: 'Broken1',
          url: 'https://broken.example.com',
          passwordEncryptedOverride: '!!!not-base64!!!');
      await insertRow(
          id: 'bad2',
          name: 'Broken2',
          url: 'https://broken.example.com',
          passwordEncryptedOverride: truncated);
      await insertRow(
          id: 'ok',
          name: 'GitHub',
          url: 'https://github.com',
          password: 'Str0ng-Passw0rd!x',
          withTotp: true);
      await request('unlock', {'password': masterPassword});

      final res = await request('getHealthReport');
      expect(res['error'], isNull);
      final data = res['data'] as Map<String, dynamic>;
      expect(data['totalEntries'], 3);
      // 健康条目的判定不受损坏条目影响
      expect(data['noUrl'], isEmpty);
    });

    test('getHealthReport 会 touch 会话', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final session = VaultSession(clock: () => now);
      final svc = NativeMessagingService(db, crypto, TotpService(),
          session: session);

      await svc.handleRequest(
          {'requestId': 'r', 'action': 'unlock', 'password': masterPassword});
      now = now.add(const Duration(minutes: 4));
      await svc.handleRequest({'requestId': 'r', 'action': 'getHealthReport'});
      now = now.add(const Duration(minutes: 4));

      expect(svc.isUnlocked, isTrue);
    });

    // ── 只分析登录条目（契约 §5）────────────────────────────

    test('笔记 / 身份 / SSH 条目不计入 totalEntries，也不产生 noUrl / noTotp 问题',
        () async {
      await seedAllTypes(); // 只有 login-1 是登录条目，且完全健康
      await request('unlock', {'password': masterPassword});

      final res = await request('getHealthReport');
      expect(res['error'], isNull);
      final data = res['data'] as Map<String, dynamic>;

      expect(data['totalEntries'], 1, reason: 'totalEntries = 被分析的登录条目数');
      expect(data['score'], 100);
      expect(data['level'], 'good');
      expect(data['reusedGroupCount'], 0);
      expect(data['weakPasswords'], isEmpty);
      expect(data['reusedPasswords'], isEmpty);
      expect(data['noTotp'], isEmpty);
      // 安全笔记 / 身份 / SSH 本来就没有网址，不能变成"缺网址"问题
      expect(data['noUrl'], isEmpty);

      final encoded = jsonEncode(res);
      for (final id in ['note-1', 'identity-1', 'ssh-1']) {
        expect(encoded, isNot(contains(id)), reason: '报告里出现了非登录条目 $id');
      }
      expect(encoded, isNot(contains(totpSecret)));
    });

    test('非登录条目里的弱密码文本不参与打分', () async {
      await saveItem(const VaultItem(
        id: 'note-only',
        type: EntryType.secureNote,
        name: 'Note',
        notes: 'the old password was 123456', // 弱密码文本，但不该被分析
        createdAt: 0,
        updatedAt: 0,
      ));
      await saveItem(const VaultItem(
        id: 'identity-only',
        type: EntryType.identity,
        name: 'Me',
        identity: IdentityData(idNumber: identityIdNumber),
        createdAt: 0,
        updatedAt: 0,
      ));
      await request('unlock', {'password': masterPassword});

      final res = await request('getHealthReport');
      final data = res['data'] as Map<String, dynamic>;
      expect(data['totalEntries'], 0);
      expect(data['score'], 100);
      expect(data['level'], 'good');
      expect(data['weakPasswords'], isEmpty);
      expect(data['noUrl'], isEmpty);
      expect(data['noTotp'], isEmpty);
    });

    test('混库时只扣登录条目的分', () async {
      // 登录条目：弱密码 + 无 TOTP + 无网址 → 扣 10 + 2 + 2 = 14 分
      await insertRow(id: 'weak-login', name: 'Weak', url: '', password: '123456');
      // 三种非登录条目：全都不该被扣分
      await saveItem(const VaultItem(
        id: 'n1',
        type: EntryType.secureNote,
        name: 'Note',
        notes: 'whatever',
        createdAt: 0,
        updatedAt: 0,
      ));
      await saveItem(const VaultItem(
        id: 'n2',
        type: EntryType.sshKey,
        name: 'Key',
        sshKey: SshKeyData(publicKey: 'ssh-ed25519 FAKEFIXTUREPUBLICKEY'),
        createdAt: 0,
        updatedAt: 0,
      ));
      await request('unlock', {'password': masterPassword});

      final res = await request('getHealthReport');
      final data = res['data'] as Map<String, dynamic>;
      expect(data['totalEntries'], 1);
      expect(data['score'], 86);
      expect((data['weakPasswords'] as List).map((w) => w['id']), ['weak-login']);
      expect((data['noUrl'] as List).map((e) => e['id']), ['weak-login']);
      expect((data['noTotp'] as List).map((e) => e['id']), ['weak-login']);
    });
  });
}
