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

/// 真机复现：改完主密码后**旧密码仍然生效**。
///
/// 与 `master_password_rotation_atomicity_test.dart` 的关键区别：
/// **每次"启动"都新建一个 ProviderContainer**（等于重启 App，会话密钥从 null
/// 开始），并且直接读 secure storage 与 vault_meta 的**实际内容**来判定，
/// 而不是只看 unlock() 的返回值。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const oldPw = 'old-master-password';
  const newPw = 'new-master-password';

  late FakeSecureStorage storage;
  late CryptoService crypto;
  late AppDatabase db;

  /// 模拟一次"启动 App"：全新的容器 + 全新的会话密钥（null）。
  ProviderContainer boot() {
    final container = ProviderContainer(overrides: [
      cryptoServiceProvider.overrideWithValue(crypto),
      databaseProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    storage = FakeSecureStorage();
    crypto = CryptoService(secureStorage: storage);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
  });

  Future<void> seed(ProviderContainer c) async {
    final ok = await c.read(authProvider.notifier).setMasterPassword(oldPw, oldPw);
    expect(ok, isTrue);
    await c.read(vaultRepositoryProvider).saveItem(VaultItem(
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
  }

  test('每一次启动都能用「新密码」开库，且旧密码不再生效', () async {
    // ── 启动 1：设置主密码、放条目
    var c = boot();
    await seed(c);

    // ── 启动 2：改主密码（真机上就是用户在设置页做的操作）
    c = boot();
    expect(await c.read(authProvider.notifier).unlock(oldPw), isTrue,
        reason: '改密码前应当能用旧密码解锁');
    final changed = await c
        .read(authProvider.notifier)
        .changeMasterPassword(oldPw, newPw, newPw);
    expect(changed, isTrue, reason: 'UI 会据此显示"已修改"');

    // 落在两个存储系统里的**实际内容**是什么？这一步是定位关键。
    final storedSalt = await crypto.getStoredSalt();
    final storedHash = await crypto.getStoredPasswordHash();
    final journal = await db.getMeta(MasterPasswordRotation.metaKey);

    expect(storedSalt, isNotNull);
    final expectedNewHash = crypto.hashMasterPassword(newPw, storedSalt!);
    final oldHashWithStoredSalt = crypto.hashMasterPassword(oldPw, storedSalt);

    expect(journal, isNull, reason: '轮换正常完成时日志应当被清掉');
    expect(expectedNewHash, storedHash,
        reason: 'secure storage 里必须是**新密码**的校验哈希');
    expect(oldHashWithStoredSalt, isNot(storedHash),
        reason: 'secure storage 不该还认旧密码');

    // ── 启动 3：模拟用户重启 App，然后用新密码解锁
    c = boot();
    final newWorks = await c.read(authProvider.notifier).unlock(newPw);
    expect(newWorks, isTrue,
        reason: '真机症状：新密码不生效。errorMessage=${c.read(authProvider).errorMessage}');
    expect(await c.read(vaultRepositoryProvider).getItem('e1'),
        isNotNull, reason: '解锁后应当能读到条目');

    // ── 启动 4：旧密码必须被拒绝
    c = boot();
    final oldWorks = await c.read(authProvider.notifier).unlock(oldPw);
    expect(oldWorks, isFalse,
        reason: '真机症状：旧密码仍然生效。errorMessage=${c.read(authProvider).errorMessage}');
  });
}
