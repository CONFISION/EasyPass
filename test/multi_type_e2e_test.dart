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
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/data/services/export_import_service.dart';

import 'fakes.dart';

/// 跨层端到端测试（lead 维护）：
/// **仓储 → 导出 → 导入 → 再读出来 → 主密码轮换**，四种类型全走一遍。
///
/// 各工作流的单测只覆盖自己那一层；这个文件专门盯"接口接缝"：
/// 类型标记、载荷列、导出格式、以及"换主密码后新列还能不能解开"。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late CryptoService crypto;
  late Uint8List key;
  late VaultRepository repo;

  // 四种类型的样本（值都取得有辨识度，便于在密文里搜"明文是否泄漏"）。
  const loginPassword = 'S3CRET-PW-42';
  const loginTotp = 'JBSWY3DPEHPK3PXP';
  const noteBody = '家里路由器：hunter2-please-change';
  const identityNumber = '110101199001011234';
  const sshPassphrase = 'KEYPASS-9';
  const sshPrivateBody = 'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ==';

  List<VaultItem> samples() => [
        VaultItem(
          id: 'login-1',
          type: EntryType.login,
          name: 'GitHub 登录',
          notes: '工作账号',
          login: const LoginData(
            url: 'https://github.com',
            username: 'alice',
            password: loginPassword,
            totpSecret: loginTotp,
          ),
          customFields: const [CustomField(label: 'PIN', value: '7788')],
          createdAt: 1,
          updatedAt: 2,
        ),
        VaultItem(
          id: 'note-1',
          type: EntryType.secureNote,
          name: 'WiFi',
          notes: noteBody,
          createdAt: 1,
          updatedAt: 2,
        ),
        VaultItem(
          id: 'identity-1',
          type: EntryType.identity,
          name: '我的身份证',
          identity: const IdentityData(
            firstName: '三',
            lastName: '张',
            email: 'zhang@example.com',
            idNumber: identityNumber,
            birthday: '1990-01-01',
          ),
          customFields: const [
            CustomField(
              label: '恢复码',
              value: 'RECOVERY-1',
              type: CustomFieldType.hidden,
            ),
          ],
          createdAt: 1,
          updatedAt: 2,
        ),
        VaultItem(
          id: 'ssh-1',
          type: EntryType.sshKey,
          name: 'server key',
          sshKey: const SshKeyData(
            // 真实世界的公钥（GitHub 公布的 ed25519 host key，公开材料），
            // 不用手写 base64：长度/填充位不对的假 key 会被严格解码拒绝。
            publicKey:
                'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl root@server',
            privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\n'
                '$sshPrivateBody\n'
                '-----END OPENSSH PRIVATE KEY-----',
            passphrase: sshPassphrase,
            comment: 'root@server',
          ),
          createdAt: 1,
          updatedAt: 2,
        ),
      ];

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    crypto = CryptoService(secureStorage: FakeSecureStorage());
    key = crypto.deriveKey('master', crypto.generateSalt());
    repo = VaultRepository(
      db: db,
      cryptoService: crypto,
      keyReader: () => key,
    );
    for (final item in samples()) {
      await repo.saveItem(item);
    }
  });

  tearDown(() => db.close());

  test('仓储层：四种类型写进去再读出来，字段一一对应', () async {
    expect(await repo.countItems(), 4);
    for (final type in EntryType.values) {
      expect(await repo.countItemsByType(type), 1, reason: type.wireName);
    }

    final login = (await repo.getItem('login-1'))!;
    expect(login.type, EntryType.login);
    expect(login.loginOrEmpty.password, loginPassword);
    expect(login.loginOrEmpty.totpSecret, loginTotp);
    expect(login.customFields.single.value, '7788');

    final note = (await repo.getItem('note-1'))!;
    expect(note.type, EntryType.secureNote);
    expect(note.notes, noteBody);
    expect(note.login, isNull);

    final identity = (await repo.getItem('identity-1'))!;
    expect(identity.identityOrEmpty.idNumber, identityNumber);
    expect(identity.customFields.single.type, CustomFieldType.hidden);

    final ssh = (await repo.getItem('ssh-1'))!;
    expect(ssh.sshKeyOrEmpty.passphrase, sshPassphrase);
    expect(ssh.sshKeyOrEmpty.hasPrivateKey, isTrue);
    // 公钥可解析 → 指纹/类型/长度由 mapper 自动补齐
    expect(ssh.sshKeyOrEmpty.keyType, 'ssh-ed25519');
    expect(ssh.sshKeyOrEmpty.bits, 256);
    expect(ssh.sshKeyOrEmpty.fingerprint.startsWith('SHA256:'), isTrue);
  });

  test('搜索能命中各类型的专属字段（但绝不命中密码/私钥/口令/隐藏值）', () async {
    expect((await repo.searchItems(identityNumber)).single.id, 'identity-1');
    expect((await repo.searchItems('type:ssh root@server')).single.id, 'ssh-1');
    expect((await repo.searchItems('hunter2')).single.id, 'note-1');
    // 隐藏字段：按标签能搜到，按值搜不到
    expect((await repo.searchItems('恢复码')).single.id, 'identity-1');
    expect(await repo.searchItems('RECOVERY-1'), isEmpty);

    expect(await repo.searchItems(loginPassword), isEmpty);
    expect(await repo.searchItems(sshPassphrase), isEmpty);
    expect(await repo.searchItems(sshPrivateBody), isEmpty);
    expect(await repo.searchItems(loginTotp), isEmpty);
  });

  test('明文导出 → 导入空库：类型与字段完整保留', () async {
    final service = ExportImportService(db, () => key);
    final exported = await service.exportPlainJson();
    final parsed = jsonDecode(exported) as Map<String, dynamic>;
    expect(parsed['version'], isNotNull);
    final exportedTypes = (parsed['entries'] as List)
        .map((e) => (e as Map)['type'])
        .toSet();
    expect(exportedTypes, {'login', 'secure_note', 'identity', 'ssh_key'});

    // 导入到一个全新的库
    final freshDb = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(freshDb.close);
    final freshRepo = VaultRepository(
      db: freshDb,
      cryptoService: crypto,
      keyReader: () => key,
    );
    final freshService = ExportImportService(freshDb, () => key);

    final counts = await freshService.importFromJson(exported);
    expect(counts['entries'], 4);
    expect(await freshRepo.countItems(), 4);

    final login = (await freshRepo.getItem('login-1'))!;
    expect(login.type, EntryType.login);
    expect(login.loginOrEmpty.password, loginPassword);
    expect(login.customFields.single.value, '7788');

    final note = (await freshRepo.getItem('note-1'))!;
    expect(note.type, EntryType.secureNote);
    expect(note.notes, noteBody);

    final identity = (await freshRepo.getItem('identity-1'))!;
    expect(identity.type, EntryType.identity);
    expect(identity.identityOrEmpty.idNumber, identityNumber);

    final ssh = (await freshRepo.getItem('ssh-1'))!;
    expect(ssh.type, EntryType.sshKey);
    expect(ssh.sshKeyOrEmpty.publicKey, contains('ssh-ed25519'));
    expect(ssh.sshKeyOrEmpty.passphrase, sshPassphrase);
  });

  test('加密备份：文件里不含任何明文（密码/口令/证件号/私钥/TOTP/备注）', () async {
    final service = ExportImportService(db, () => key);
    final backup = await service.exportEncrypted();

    for (final secret in [
      loginPassword,
      sshPassphrase,
      sshPrivateBody,
      identityNumber,
      loginTotp,
      noteBody,
      '7788',
      'RECOVERY-1',
    ]) {
      expect(backup.contains(secret), isFalse, reason: '备份里出现了明文：$secret');
    }

    // 还能原样导回
    final freshDb = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(freshDb.close);
    final freshRepo = VaultRepository(
      db: freshDb,
      cryptoService: crypto,
      keyReader: () => key,
    );
    await ExportImportService(freshDb, () => key).importFromJson(backup);
    expect((await freshRepo.getItem('ssh-1'))!.sshKeyOrEmpty.passphrase,
        sshPassphrase);
    expect((await freshRepo.getItem('login-1'))!.loginOrEmpty.password,
        loginPassword);
  });

  test('改主密码（reencryptAll）：新密钥能解开全部四种类型，旧密钥全部失效', () async {
    final oldKey = key;
    final newSalt = crypto.generateSalt();
    final newKey = crypto.deriveKey('new-master', newSalt);

    final rotated = await repo.reencryptAll(oldKey: oldKey, newKey: newKey);
    expect(rotated, 4);

    // 新密钥：一切正常（载荷列也被重新加密了）
    final afterNew = VaultRepository(
      db: db,
      cryptoService: crypto,
      keyReader: () => newKey,
    );
    final ssh = (await afterNew.getItem('ssh-1'))!;
    expect(ssh.sshKeyOrEmpty.passphrase, sshPassphrase);
    expect(ssh.sshKeyOrEmpty.fingerprint.startsWith('SHA256:'), isTrue);
    final identity = (await afterNew.getItem('identity-1'))!;
    expect(identity.identityOrEmpty.idNumber, identityNumber);
    expect((await afterNew.getItem('login-1'))!.loginOrEmpty.password,
        loginPassword);

    // 旧密钥：密码与载荷都解不开（宽容模式给空值），证明两处密文都换了钥匙
    final afterOld = VaultRepository(
      db: db,
      cryptoService: crypto,
      keyReader: () => oldKey,
    );
    expect((await afterOld.getItem('login-1'))!.loginOrEmpty.password, '');
    expect((await afterOld.getItem('identity-1'))!.identityOrEmpty.idNumber, '');
    expect((await afterOld.getItem('ssh-1'))!.sshKeyOrEmpty.passphrase, '');
  });

  test('reencryptAll 遇到坏行：整段回滚，没有任何行被改成新密钥', () async {
    // 直接塞一条密文损坏的条目（mapper 之外唯一合法的写入方式就是原生
    // companion —— 生产代码没有这条路径，这里是刻意制造"坏行"）。
    await db.insertEntry(PasswordEntriesCompanion.insert(
      id: 'broken-last',
      name: 'broken row',
      passwordEncrypted: 'not-a-valid-cipher',
      createdAt: 1,
      updatedAt: 2,
    ));

    final before = (await db.getAllEntries()).firstWhere((r) => r.id == 'login-1');
    final newKey = crypto.deriveKey('new-master', crypto.generateSalt());

    await expectLater(
      repo.reencryptAll(oldKey: key, newKey: newKey),
      throwsA(isA<VaultDecryptException>()),
    );

    // 事务回滚的硬证据：先前已处理过的行连 updatedAt 都没被改，
    // 更不用说密文 —— 否则这些条目只能用 newKey 打开，而主密码还是旧的。
    final after = (await db.getAllEntries()).firstWhere((r) => r.id == 'login-1');
    expect(after.updatedAt, before.updatedAt);
    expect(after.passwordEncrypted, before.passwordEncrypted);
    expect(after.dataEncrypted, before.dataEncrypted);

    final withOldKey = await repo.getItem('login-1');
    expect(withOldKey!.loginOrEmpty.password, loginPassword);
  });

  test('库层面：明文列里不该出现敏感值（只有加密列承载密文）', () async {
    final rows = await db.getAllEntries();
    expect(rows, hasLength(4));

    for (final row in rows) {
      // 明文列：name / url / username。密文列允许出现任意 base64。
      final plaintextColumns = '${row.name}\u0000${row.url}\u0000${row.username}';
      for (final secret in [
        loginPassword,
        sshPassphrase,
        sshPrivateBody,
        identityNumber,
        loginTotp,
        noteBody,
        'RECOVERY-1',
      ]) {
        expect(plaintextColumns.contains(secret), isFalse,
            reason: '明文列里出现了敏感值：$secret（id=${row.id}）');
      }
      // 而加密列确实承载了密文（说明确实存进去了，不是"没存所以没泄漏"）
      expect(
        row.passwordEncrypted.isNotEmpty ||
            (row.notesEncrypted ?? '').isNotEmpty ||
            row.dataEncrypted.isNotEmpty,
        isTrue,
        reason: '条目 ${row.id} 三个密文列全空，说明根本没落库',
      );
    }
  });
}
