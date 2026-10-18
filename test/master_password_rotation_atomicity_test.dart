import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/storage/vault_meta_secret_store.dart';
import 'package:easypass/core_service/core_actions.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/services/master_password_rotation.dart';
import 'package:easypass/protocol/protocol.dart';

import 'core_actions_harness.dart';

/// 改主密码的**失败原子性**回归（v2.4 首要项）。
///
/// 背景：`changeMasterPassword` 要同时改动两个存储系统 ——
/// 1. **条目密文**（SQLite 事务）；
/// 2. **校验材料 salt + 哈希**（历史上在 `flutter_secure_storage`，**没有事务**）。
///
/// 旧实现在 2 的内部还要写两次（先 salt、后哈希），"整库已用新钥匙重写、而校验
/// 材料半新半旧"是可达状态，结果是**新旧主密码都开不了库** = 静默丢数据。
///
/// M4 之后校验材料搬进了库文件的 `vault_meta`，且与整库重加密**同一个事务域**；
/// 但"写不进去"这件事在真实世界依然存在（磁盘满 / 库文件只读 / 权限被降级）。
/// 所以不变量必须继续被测：**日志存在 ⇒ 整库已在新钥匙上 ⇒ 新密码一定能开库**。
///
/// 本文件用 [FailingSecretStore] 注入"写入第 n 次起全失败"，覆盖原来的
/// `FakeSecureStorage.failWriteFrom` 场景；动作打在 `CoreActions` 上（UI 的实际
/// 路径，见 `test/core_actions_harness.dart`）。
void main() {
  const oldPassword = 'old-master-password';
  const newPassword = 'new-master-password';
  const entryId = 'rotate-me';

  late FailingSecretStore materialStore;
  late CoreVault vault;

  setUp(() {
    vault = CoreVault.create(
      storeFactory: (inner) => materialStore = FailingSecretStore(inner),
    );
    addTearDown(vault.close);
  });

  /// 首次设置主密码（写 #1 salt、#2 哈希）+ 放一条登录条目。
  Future<CoreHarness> seed() async {
    final core = await vault.boot();
    await core.setMasterPassword(oldPassword);
    await core.repository.saveItem(VaultItem(
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
    return core;
  }

  /// 数据库里那条记录的原始密文 —— 用它判断"整库到底有没有被换钥匙"。
  Future<String> rawPasswordCiphertext() async {
    final rows = await vault.db.getAllEntries();
    return rows.firstWhere((r) => r.id == entryId).passwordEncrypted;
  }

  /// 当前会话密钥能读出的密码（宽容模式：解不开就是空串）。
  Future<String?> readPasswordWithSessionKey(CoreHarness core) async {
    final item = await core.repository.getItem(entryId);
    return item?.loginOrEmpty.password;
  }

  group('复现：改主密码中途写不进校验材料', () {
    test('整库照样完成轮换，且不留半新半旧的状态', () async {
      final core = await seed();
      final ciphertextBefore = await rawPasswordCiphertext();

      // 让轮换过程中**下一次**写入就失败（轮换要写 salt + hash 两次）。
      materialStore.failWriteFrom = materialStore.writeCount + 1;

      await core.changeMasterPassword(current: oldPassword, next: newPassword);

      // 整库确实换成了新钥匙的密文（危险窗口本身是真实的）。
      expect(await rawPasswordCiphertext(), isNot(ciphertextBefore),
          reason: '前置条件失败：整库应当已被重加密');

      // 但**不允许**出现"新 salt + 旧哈希"这种自相矛盾的校验材料：
      // 轮换日志承载了目标校验材料，写失败时日志被保留。
      final journal = await vault.db.getMeta(MasterPasswordRotation.metaKey);
      expect(journal, isNotNull,
          reason: '校验材料写失败时，轮换日志必须保留（它是新密码的唯一依据）');
      final pending = PendingRotation.tryParse(journal);
      expect(pending, isNotNull);

      // 日志里的校验材料必须与"当前整库的钥匙"一致。
      expect(
        core.crypto.hashMasterPassword(newPassword, pending!.salt),
        pending.passwordHash,
        reason: '日志与整库密文必须同源，否则又会退回"两边都开不了"',
      );

      // 而 vault_meta 里仍是旧材料（写失败了）—— 这正是需要日志兜底的场景。
      expect(await core.crypto.getStoredPasswordHash(),
          isNot(pending.passwordHash),
          reason: '故障注入没生效：不该已经是新哈希');
      final storedSalt = (await core.crypto.getStoredSalt())!;
      expect(
        core.crypto.hashMasterPassword(newPassword, storedSalt),
        isNot(await core.crypto.getStoredPasswordHash()),
        reason: '故障注入没生效：这不构成"verifier 与 salt 不匹配"的状态',
      );

      // 校验材料落在库文件的 vault_meta 里（D1）；两个键都还在旧值上。
      expect(
        await vault.db.getMeta(
          '${VaultMetaSecretStore.keyPrefix}easypass_master_pw_hash',
        ),
        isNotNull,
      );
    });

    test('故障后必须至少有一把主密码还能开库（不许两边都开不了）', () async {
      final core = await seed();
      materialStore.failWriteFrom = materialStore.writeCount + 1;
      await core.changeMasterPassword(current: oldPassword, next: newPassword);

      // 模拟用户重新启动：同一份库，全新会话。
      final restarted = await vault.boot();

      // 有日志 ⇒ 只有日志里的目标密码有效；旧密码在**校验阶段**就被拒
      // （不再放行一把解不开库的钥匙）。
      await expectLater(
        restarted.unlock(oldPassword),
        throwsA(
          isA<CoreActionException>().having(
            (e) => e.code,
            'code',
            ErrorCodes.unauthorized,
          ),
        ),
        reason: '旧密码不该再被放行',
      );

      // 新密码必须能进来 —— 依据是库里的轮换日志，**不依赖**校验材料是否写得进去
      // （此刻它仍然是坏的）。这是"不许两边都开不了"的核心保证。
      final unlocked = await restarted.unlock(newPassword);
      expect(unlocked['success'], isTrue,
          reason: '灾难：新旧主密码都无法解锁，条目永久解不开（静默丢数据）');

      // 而且解开之后数据必须真的能读出来（不是解锁了却全是空串）。
      expect(await readPasswordWithSessionKey(restarted), 'secret-pw',
          reason: '解锁成功了却读不出明文 —— 仍然是丢数据');
    });
  });

  group('故障之后：新密码能开库，旧密码被明确拒绝', () {
    test('旧密码的拒绝理由要落到"主密码不正确"而不是含糊的失败', () async {
      final core = await seed();
      materialStore.failWriteFrom = materialStore.writeCount + 1;
      await core.changeMasterPassword(current: oldPassword, next: newPassword);

      final restarted = await vault.boot();
      try {
        await restarted.unlock(oldPassword);
        fail('旧密码不该被接受');
      } on CoreActionException catch (error) {
        expect(error.code, ErrorCodes.unauthorized);
        expect(error.message, contains('主密码不正确'));
      }

      expect(await restarted.repository.getItem(entryId), isNull,
          reason: '被拒绝的解锁不该留下半个会话');
    });

    test('校验材料恢复后，残留的轮换日志会被自动清掉（收敛回去）', () async {
      final core = await seed();
      materialStore.failWriteFrom = materialStore.writeCount + 1;
      await core.changeMasterPassword(current: oldPassword, next: newPassword);
      expect(await vault.db.getMeta(MasterPasswordRotation.metaKey), isNotNull,
          reason: '前置条件：此刻日志应当还在');

      // 存储恢复可用，用户重新启动并用新密码解锁。
      materialStore.failWriteFrom = null;
      final restarted = await vault.boot();
      await restarted.unlock(newPassword);

      expect(await vault.db.getMeta(MasterPasswordRotation.metaKey), isNull,
          reason: '存储恢复后日志应当被清掉，不该永久留在库里');

      final salt = (await restarted.crypto.getStoredSalt())!;
      expect(
        await restarted.crypto.getStoredPasswordHash(),
        restarted.crypto.hashMasterPassword(newPassword, salt),
        reason: '日志清掉之后，vault_meta 里必须是新密码的校验材料',
      );
      expect(await readPasswordWithSessionKey(restarted), 'secret-pw');
    });

    test('导出在轮换失败后仍然可用（备份路径没被破坏）', () async {
      final core = await seed();
      materialStore.failWriteFrom = materialStore.writeCount + 1;
      await core.changeMasterPassword(current: oldPassword, next: newPassword);

      final restarted = await vault.boot();
      await restarted.unlock(newPassword);

      final json = await restarted.exporter.exportPlainJson();
      expect(json, contains('secret-pw'),
          reason: '轮换失败后导出仍要能拿到明文，用户才有自救手段');
    });
  });

  group('存储可用时：轮换是全有或全无', () {
    test('轮换成功：日志不留、材料是新密码的、旧密码被拒', () async {
      final core = await seed();
      final ciphertextBefore = await rawPasswordCiphertext();

      await core.changeMasterPassword(current: oldPassword, next: newPassword);

      expect(await rawPasswordCiphertext(), isNot(ciphertextBefore),
          reason: '轮换应当真的换掉了密文');
      expect(await vault.db.getMeta(MasterPasswordRotation.metaKey), isNull,
          reason: '成功轮换不该留下日志');

      // 改完即锁定：读不到明文。
      expect(await readPasswordWithSessionKey(core), isNull,
          reason: '改完主密码应当回到锁定态');

      await core.unlock(newPassword);
      expect(await readPasswordWithSessionKey(core), 'secret-pw');

      await core.lock();
      await expectLater(
        core.unlock(oldPassword),
        throwsA(
          isA<CoreActionException>().having(
            (e) => e.code,
            'code',
            ErrorCodes.unauthorized,
          ),
        ),
        reason: '旧密码不应再能开库',
      );
    });
  });
}
