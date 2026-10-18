import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core_service/core_actions.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/services/master_password_rotation.dart';
import 'package:easypass/protocol/protocol.dart';

import 'core_actions_harness.dart';

/// 真机复现：改完主密码后**旧密码仍然生效**。
///
/// 与 `master_password_rotation_atomicity_test.dart` 的关键区别：
/// **每次"启动"都新建一套核心会话**（等于重启核心：同一份库、全新会话，
/// 会话密钥从 null 开始），并且直接读 vault_meta 里的**实际内容**来判定，
/// 而不是只看 unlock() 的返回值。
///
/// M4 之后 `AuthNotifier` 不再自己校验 / 轮换，所以这里打在 `CoreActions` 上
/// —— 与 UI 走的是同一条动作路径（`VaultApi.unlock` / `changeMasterPassword`）。
void main() {
  const oldPw = 'old-master-password';
  const newPw = 'new-master-password';

  late CoreVault vault;

  setUp(() {
    vault = CoreVault.create();
    addTearDown(vault.close);
  });

  test('每一次启动都能用「新密码」开库，且旧密码不再生效', () async {
    // ── 启动 1：设置主密码、放条目
    var core = await vault.boot();
    await core.setMasterPassword(oldPw);
    await core.repository.saveItem(VaultItem(
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

    // ── 启动 2：改主密码（真机上就是用户在设置页做的操作）
    core = await vault.boot();
    await core.unlock(oldPw);
    await core.changeMasterPassword(current: oldPw, next: newPw);

    // 落在**库文件里**的实际内容是什么？这一步是定位关键。
    final storedSalt = await core.crypto.getStoredSalt();
    final storedHash = await core.crypto.getStoredPasswordHash();
    final journal = await vault.db.getMeta(MasterPasswordRotation.metaKey);

    expect(journal, isNull, reason: '轮换正常完成时日志应当被清掉');
    expect(storedSalt, isNotNull);
    expect(core.crypto.hashMasterPassword(newPw, storedSalt!), storedHash,
        reason: 'vault_meta 里必须是**新密码**的校验哈希');
    expect(core.crypto.hashMasterPassword(oldPw, storedSalt), isNot(storedHash),
        reason: 'vault_meta 不该还认旧密码');

    // ── 启动 3：模拟用户重启 App，然后用新密码解锁
    core = await vault.boot();
    await core.unlock(newPw);
    expect(await core.repository.getItem('e1'), isNotNull,
        reason: '解锁后应当能读到条目');

    // ── 启动 4：旧密码必须被拒绝
    core = await vault.boot();
    await expectLater(
      core.unlock(oldPw),
      throwsA(
        isA<CoreActionException>().having(
          (e) => e.code,
          'code',
          ErrorCodes.unauthorized,
        ),
      ),
      reason: '真机症状：改了主密码之后旧密码仍然生效',
    );
  });
}
