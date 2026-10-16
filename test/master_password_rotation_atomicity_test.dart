import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/data/services/export_import_service.dart';
import 'package:easypass/data/services/master_password_rotation.dart';
import 'package:easypass/features/auth/providers/auth_provider.dart';

import 'fakes.dart';

/// 改主密码的**失败原子性**回归（v2.4 首要项）。
///
/// 背景：`changeMasterPassword` 有两次独立写入 —— 先把整库用新钥匙重加密
/// （SQLite 事务，可靠），再把新的 salt + 校验哈希写进 `flutter_secure_storage`
/// （**不受事务保护**）。后者在真实世界会失败：Linux 的 Secret Service 不可用
/// （纯 tty / keyring 上锁），或 Windows 上进程被完整性标签降权写不了
/// `%APPDATA%`（HANDOFF §4 第 14 条的真实事故）。
///
/// 危险窗口在 `storeKeyMaterial` **内部**：它先写 salt、后写哈希，所以
/// "salt 写成功、哈希写失败"会留下这样一个库：
///
///   - 条目密文 = 新钥匙加密
///   - salt     = 新 salt
///   - 校验哈希 = 旧哈希（用旧 salt 算的）
///
/// 于是**新旧主密码都开不了库**：新密码算出的哈希对不上旧哈希，旧密码虽然
/// 校验通过、但派生出的是旧钥匙，解不开新密文（宽容模式只会解成空串）。
/// 这正是"静默丢数据"。
///
/// 本文件先用 `failWriteFrom` 复现这个状态，再断言修复后的行为。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const oldPassword = 'old-master-password';
  const newPassword = 'new-master-password';
  const entryId = 'rotate-me';

  late ProviderContainer container;
  late FakeSecureStorage storage;
  late CryptoService crypto;
  late AppDatabase db;

  Future<void> buildContainer({int? failWriteFrom}) async {
    storage = FakeSecureStorage();
    if (failWriteFrom != null) {
      storage.failWriteFrom = failWriteFrom;
    }
    crypto = CryptoService(secureStorage: storage);
    db = AppDatabase.forTesting(NativeDatabase.memory());

    container = ProviderContainer(overrides: [
      cryptoServiceProvider.overrideWithValue(crypto),
      databaseProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);

    // 首次设置主密码：写入 #1（salt）、#2（哈希）。
    final ok = await container
        .read(authProvider.notifier)
        .setMasterPassword(oldPassword, oldPassword);
    expect(ok, isTrue, reason: '初始状态搭建失败');

    // 放一条四种类型都会碰到的条目：登录字段 + 自定义字段。
    await container.read(vaultRepositoryProvider).saveItem(VaultItem(
          id: entryId,
          type: EntryType.login,
          name: 'Rotate',
          login: const LoginData(
            url: 'https://example.com/rotate',
            username: 'alice',
            password: 'secret-pw',
            totpSecret: 'JBSWY3DPEHPK3PXP',
          ),
          customFields: const [
            CustomField(
              label: 'PIN',
              value: '4321',
              type: CustomFieldType.hidden,
            ),
          ],
          createdAt: 0,
          updatedAt: 0,
        ));
  }

  /// 数据库里那条记录的原始密文 —— 用它判断"整库到底有没有被换钥匙"。
  Future<String> rawPasswordCiphertext() async {
    final rows = await db.getAllEntries();
    final row = rows.firstWhere((r) => r.id == entryId);
    return row.passwordEncrypted;
  }

  /// 当前会话密钥能读出的密码（宽容模式：解不开就是空串）。
  Future<String?> readPasswordWithSessionKey() async {
    final item = await container.read(vaultRepositoryProvider).getItem(entryId);
    return item?.loginOrEmpty.password;
  }

  group('复现：改主密码中途失败曾会锁死保险库', () {
    test('salt 写不进去时，整库照样完成轮换且不留下半新半旧的状态', () async {
      await buildContainer();
      final ciphertextBefore = await rawPasswordCiphertext();

      // 让轮换过程中的**第一次** secure-storage 写入（salt）就抛错。
      // 于是 storeKeyMaterial 在写哈希之前中断 —— 旧实现正是在这里丢数据。
      storage.failWriteFrom = storage.writeCount + 1;

      await container
          .read(authProvider.notifier)
          .changeMasterPassword(oldPassword, newPassword, newPassword);

      // 整库确实换成新钥匙的密文（危险窗口本身是真实的）。
      expect(await rawPasswordCiphertext(), isNot(ciphertextBefore),
          reason: '前置条件失败：整库应当已被重加密');

      // 但**不允许**出现"新 salt + 旧哈希"这种自相矛盾的校验材料：
      // 轮换日志承载了目标校验材料，secure storage 写失败时日志被保留。
      final journal = await db.getMeta(MasterPasswordRotation.metaKey);
      expect(journal, isNotNull,
          reason: 'secure storage 写失败时，轮换日志必须保留（它是新密码的唯一依据）');
      final pending = PendingRotation.tryParse(journal);
      expect(pending, isNotNull);

      // 日志里的校验材料必须与"当前整库的钥匙"一致：用日志的 salt 算新密码，
      // 得到的哈希就要等于日志里的哈希。
      expect(
        crypto.hashMasterPassword(newPassword, pending!.salt),
        pending.passwordHash,
        reason: '日志与整库密文必须同源，否则又会退回"两边都开不了"',
      );

      // 而 secure storage 里仍是旧材料（写失败了）—— 这正是需要日志兜底的场景。
      expect(await crypto.getStoredPasswordHash(), isNot(pending.passwordHash),
          reason: '故障注入没生效：secure storage 不该已经是新哈希');
      final hashWithStoredSalt =
          crypto.hashMasterPassword(newPassword, (await crypto.getStoredSalt())!);
      expect(hashWithStoredSalt, isNot(await crypto.getStoredPasswordHash()),
          reason: '故障注入没生效：这不构成"verifier 与 salt 不匹配"的状态');
    });

    test('故障后必须至少有一把主密码还能开库（不许两边都开不了）', () async {
      await buildContainer();
      storage.failWriteFrom = storage.writeCount + 1;

      await container
          .read(authProvider.notifier)
          .changeMasterPassword(oldPassword, newPassword, newPassword);

      // 模拟用户重新启动 / 锁定后重试两种密码。
      container.read(encryptionKeyProvider.notifier).state = null;
      final oldWorks =
          await container.read(authProvider.notifier).unlock(oldPassword);
      if (!oldWorks) {
        container.read(encryptionKeyProvider.notifier).state = null;
      }
      final newWorks = oldWorks
          ? false
          : await container.read(authProvider.notifier).unlock(newPassword);

      expect(oldWorks || newWorks, isTrue,
          reason: '灾难：新旧主密码都无法解锁，条目永久解不开（静默丢数据）');

      // 而且解开之后数据必须真的能读出来（不是解锁了却全是空串）。
      expect(await readPasswordWithSessionKey(), 'secret-pw',
          reason: '解锁成功了却读不出明文 —— 仍然是丢数据');
    });
  });

  group('修复后：轮换具备全有或全无语义', () {
    test('存储可用时轮换成功，新密码生效、旧密码失效', () async {
      await buildContainer();
      final ciphertextBefore = await rawPasswordCiphertext();

      final changed = await container
          .read(authProvider.notifier)
          .changeMasterPassword(oldPassword, newPassword, newPassword);
      expect(changed, isTrue);

      expect(await rawPasswordCiphertext(), isNot(ciphertextBefore),
          reason: '轮换应当真的换掉了密文');
      expect(await readPasswordWithSessionKey(), 'secret-pw');

      container.read(encryptionKeyProvider.notifier).state = null;
      expect(await container.read(authProvider.notifier).unlock(newPassword),
          isTrue, reason: '新密码应当能开库');
      expect(await readPasswordWithSessionKey(), 'secret-pw');

      container.read(encryptionKeyProvider.notifier).state = null;
      expect(await container.read(authProvider.notifier).unlock(oldPassword),
          isFalse, reason: '旧密码不应再能开库');
    });

    test('钥匙串写失败时：新密码能开库，旧密码被明确拒绝而不是静默损坏', () async {
      await buildContainer();
      final ciphertextBefore = await rawPasswordCiphertext();

      storage.failWriteFrom = storage.writeCount + 1;
      // 轮换在语义上是**成功**的：整库已换钥匙、新密码可用。钥匙串写失败只是
      // 降级（校验材料改由库内日志承载），不该向用户报"修改失败"。
      final changed = await container
          .read(authProvider.notifier)
          .changeMasterPassword(oldPassword, newPassword, newPassword);
      expect(changed, isTrue,
          reason: '整库确实换钥匙了，谎报失败会让用户以为密码没变');

      // 整库已是新钥匙密文。
      expect(await rawPasswordCiphertext(), isNot(ciphertextBefore));

      // 新密码：能开库，且能读出明文。
      container.read(encryptionKeyProvider.notifier).state = null;
      expect(await container.read(authProvider.notifier).unlock(newPassword),
          isTrue, reason: '钥匙串坏了也必须能用新密码开库（靠轮换日志）');
      expect(await readPasswordWithSessionKey(), 'secret-pw');

      // 旧密码：被明确拒绝。有轮换日志 ⇒ 整库已是新钥匙的密文，旧密码在
      // 校验阶段就被判否（不再放行一把解不开库的钥匙），所以这里报的是
      // "主密码错误"——对用户来说比"含糊的解锁失败"清楚。
      container.read(encryptionKeyProvider.notifier).state = null;
      expect(await container.read(authProvider.notifier).unlock(oldPassword),
          isFalse);
      expect(
        container.read(authProvider).errorMessage,
        AuthErrorCodes.incorrectMasterPassword,
      );
    });

    test('钥匙串恢复后，残留的轮换日志会被自动清掉（收敛回去）', () async {
      await buildContainer();
      storage.failWriteFrom = storage.writeCount + 1;
      await container
          .read(authProvider.notifier)
          .changeMasterPassword(oldPassword, newPassword, newPassword);
      expect(await db.getMeta(MasterPasswordRotation.metaKey), isNotNull,
          reason: '前置条件：此刻日志应当还在');

      // 钥匙串恢复可用，用户再解锁一次。
      storage.failWriteFrom = null;
      container.read(encryptionKeyProvider.notifier).state = null;
      expect(await container.read(authProvider.notifier).unlock(newPassword),
          isTrue);

      expect(await db.getMeta(MasterPasswordRotation.metaKey), isNull,
          reason: '钥匙串恢复后日志应当被清掉，不该永久留在库里');
      expect(await crypto.getStoredPasswordHash(), isNotNull);
      expect(await readPasswordWithSessionKey(), 'secret-pw');
    });

    test('导出在轮换失败后仍然可用（备份路径没被破坏）', () async {
      await buildContainer();
      storage.failWriteFrom = storage.writeCount + 1;
      await container
          .read(authProvider.notifier)
          .changeMasterPassword(oldPassword, newPassword, newPassword);

      container.read(encryptionKeyProvider.notifier).state = null;
      final unlocked =
          await container.read(authProvider.notifier).unlock(newPassword);
      expect(unlocked, isTrue);

      final service = ExportImportService(
        db,
        () => container.read(encryptionKeyProvider) ??
            (throw Exception('Vault is locked')),
        repository: container.read(vaultRepositoryProvider),
        cryptoService: crypto,
      );
      final json = await service.exportPlainJson();
      expect(json, contains('secret-pw'),
          reason: '回滚后导出应当仍能拿到明文，用户才有自救手段');
    });
  });
}
