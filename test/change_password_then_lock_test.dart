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
import 'package:easypass/data/services/master_password_rotation.dart';
import 'package:easypass/features/auth/providers/auth_provider.dart';

import 'fakes.dart';

/// 真机操作顺序逐字复刻：**改密码 → 不重启、直接锁定 → 依次试新旧密码**。
///
/// 真机反馈是"修改成功了"，所以要模拟的就是"成功之后"的状态，而不是任何
/// 故障注入。这里刻意**不**新建容器（不模拟重启），因为用户是在同一次运行里
/// 紧接着锁定再解锁的。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const oldPw = 'old-master-password';
  const newPw = 'new-master-password';

  late FakeSecureStorage storage;
  late CryptoService crypto;
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    storage = FakeSecureStorage();
    crypto = CryptoService(secureStorage: storage);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    container = ProviderContainer(overrides: [
      cryptoServiceProvider.overrideWithValue(crypto),
      databaseProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);

    final ok = await container
        .read(authProvider.notifier)
        .setMasterPassword(oldPw, oldPw);
    expect(ok, isTrue);

    await container.read(vaultRepositoryProvider).saveItem(VaultItem(
          id: 'e1',
          type: EntryType.login,
          name: 'GitHub',
          login: const LoginData(
            url: 'https://github.com',
            username: 'alice',
            password: 'secret-pw',
          ),
          createdAt: 0,
          updatedAt: 0,
        ));
  });

  /// 数据库里那条记录的原始密文 —— 用它判断"整库有没有真的换钥匙"。
  Future<String> rawCiphertext() async {
    final rows = await db.getAllEntries();
    return rows.firstWhere((r) => r.id == 'e1').passwordEncrypted;
  }

  test('改完密码立即锁定：新密码必须能开库、旧密码必须被拒', () async {
    // ── 1. 改主密码（用户在设置页做的操作）
    final changed = await container
        .read(authProvider.notifier)
        .changeMasterPassword(oldPw, newPw, newPw);
    expect(changed, isTrue, reason: '真机显示的就是"已修改"');

    // 改完之后应当**回到锁定态**：换钥匙后要求重新认证，也让用户当场验收
    // 新密码确实生效。
    expect(container.read(authProvider).status, AuthStatus.locked,
        reason: '改完主密码应当回到锁定态（并跳回锁屏）');
    expect(container.read(encryptionKeyProvider), isNull,
        reason: '锁定态不该还留着会话密钥');
    expect(container.read(authProvider).errorMessage, isNull,
        reason: '钥匙串写成功时不该留错误提示');

    // ── 2. 试新密码
    final newWorks = await container.read(authProvider.notifier).unlock(newPw);
    expect(newWorks, isTrue,
        reason: '改了密码之后新密码进不去。errorMessage='
            '${container.read(authProvider).errorMessage}');
    expect(await container.read(vaultRepositoryProvider).getItem('e1'),
        isNotNull);

    // ── 3. 试旧密码
    container.read(authProvider.notifier).lock();
    final oldWorks = await container.read(authProvider.notifier).unlock(oldPw);
    expect(oldWorks, isFalse,
        reason: '旧密码仍然能开库。errorMessage='
            '${container.read(authProvider).errorMessage}');
  });

  test('改完密码后的落盘状态：日志清空、钥匙串是新密码的、密文真的换了', () async {
    final before = await rawCiphertext();

    await container
        .read(authProvider.notifier)
        .changeMasterPassword(oldPw, newPw, newPw);

    final journal = await db.getMeta(MasterPasswordRotation.metaKey);
    expect(journal, isNull, reason: '轮换完成后日志必须被清掉');

    final salt = (await crypto.getStoredSalt())!;
    expect(crypto.hashMasterPassword(newPw, salt),
        await crypto.getStoredPasswordHash(),
        reason: '钥匙串里必须是新密码的校验哈希');
    expect(crypto.hashMasterPassword(oldPw, salt),
        isNot(await crypto.getStoredPasswordHash()),
        reason: '钥匙串不该还认旧密码');

    // 用**密文本身**判断整库有没有换钥匙。
    //
    // 不要用 encryptionProbeWorks 来断言"旧钥匙解不开"：那个方法刻意是宽容的
    // ——"钥匙不对"和"整库密文都坏了"用解密无法区分，所以一行都解不开时它返回
    // true（详见 vault_repository.dart）。拿它当"能否解密"的断言会得出反直觉
    // 的结论。这里直接比对密文，判据干净。
    expect(await rawCiphertext(), isNot(before),
        reason: '整库密文必须真的被换钥匙重写过');
  });

  test('改完密码后锁定的状态语义：应当回到 locked 而不是解锁', () async {
    await container
        .read(authProvider.notifier)
        .changeMasterPassword(oldPw, newPw, newPw);
    container.read(authProvider.notifier).lock();

    // 锁定后读不到条目（流式 provider 给空值）
    final item = await container.read(vaultRepositoryProvider).getItem('e1');
    expect(item, isNull, reason: '锁定时仓储不该交出明文');

    // 会话密钥已清空
    expect(container.read(encryptionKeyProvider), isNull);
    expect(container.read(authProvider).status, AuthStatus.locked);
  });
}
