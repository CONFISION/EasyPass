import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core_service/core_actions.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/services/master_password_rotation.dart';
import 'package:easypass/protocol/protocol.dart';

import 'core_actions_harness.dart';

/// 真机操作顺序逐字复刻：**改密码 → 不重启、直接锁定 → 依次试新旧密码**。
///
/// M4 之前这个流程的一半在 `AuthNotifier` 里（UI 自己校验、自己轮换）。现在
/// 校验 + 原子轮换 + 会话锁定**全部在核心里**，UI 只是把 `changeMasterPassword`
/// 动作转发出去、再把状态置为 locked（`AuthState` 那一半见
/// `test/auth_test.dart` 的 "成功后必须回到锁定态"）。
///
/// 所以这里打在 `CoreActions` 上（`test/core_actions_harness.dart` 的接线与
/// `CoreService.start()` 完全一致）—— 断言"改完密码新密码能开库、旧密码被拒"
/// 仍然由真实代码守着，而不是守着一个假实现。
void main() {
  const oldPw = 'old-master-password';
  const newPw = 'new-master-password';

  late CoreVault vault;

  setUp(() {
    vault = CoreVault.create();
    addTearDown(vault.close);
  });

  VaultItem sampleItem() => VaultItem(
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
      );

  /// 数据库里那条记录的原始密文 —— 用它判断"整库有没有真的换钥匙"。
  Future<String> rawCiphertext() async {
    final rows = await vault.db.getAllEntries();
    return rows.firstWhere((r) => r.id == 'e1').passwordEncrypted;
  }

  test('改完密码立即锁定：新密码必须能开库、旧密码必须被拒', () async {
    final core = await vault.boot();
    await core.setMasterPassword(oldPw);
    await core.repository.saveItem(sampleItem());
    expect(core.isUnlocked, isTrue, reason: '前置：设置主密码会解锁本次会话');

    // ── 1. 改主密码（用户在设置页做的操作，UI 只是转发）
    await core.changeMasterPassword(current: oldPw, next: newPw);

    // 改完之后必须**回到锁定态**：换钥匙后要求重新认证，也让用户当场验收
    // 新密码确实生效。
    final state = await core.authState();
    expect(state['status'], 'locked', reason: '改完主密码应当回到锁定态');
    expect(state['hasAuthMaterial'], isTrue);
    expect(core.isUnlocked, isFalse, reason: '锁定态不该还留着 ui 域会话密钥');

    // ── 2. 试新密码
    final newWorks = await core.unlock(newPw);
    expect(newWorks['success'], isTrue);
    final item = await core.repository.getItem('e1');
    expect(item, isNotNull);
    expect(item!.loginOrEmpty.password, 'secret-pw',
        reason: '解锁了却读不出明文，等于丢数据');

    // ── 3. 试旧密码
    await core.lock();
    await expectLater(
      core.unlock(oldPw),
      throwsA(
        isA<CoreActionException>().having(
          (e) => e.code,
          'code',
          ErrorCodes.unauthorized,
        ),
      ),
      reason: '旧密码仍然能开库（真机事故的复发）',
    );
    expect(core.isUnlocked, isFalse);
  });

  test('改完密码后落盘状态：日志清空、校验材料是新密码的、密文真的换了', () async {
    final core = await vault.boot();
    await core.setMasterPassword(oldPw);
    await core.repository.saveItem(sampleItem());

    final before = await rawCiphertext();

    await core.changeMasterPassword(current: oldPw, next: newPw);

    final journal = await vault.db.getMeta(MasterPasswordRotation.metaKey);
    expect(journal, isNull, reason: '轮换完成后日志必须被清掉');

    final salt = (await core.crypto.getStoredSalt())!;
    expect(core.crypto.hashMasterPassword(newPw, salt),
        await core.crypto.getStoredPasswordHash(),
        reason: '校验材料里必须是新密码的哈希');
    expect(core.crypto.hashMasterPassword(oldPw, salt),
        isNot(await core.crypto.getStoredPasswordHash()),
        reason: '校验材料不该还认旧密码');

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
    final core = await vault.boot();
    await core.setMasterPassword(oldPw);
    await core.repository.saveItem(sampleItem());

    await core.changeMasterPassword(current: oldPw, next: newPw);
    await core.lock();

    expect(await core.repository.getItem('e1'), isNull,
        reason: '锁定时仓储不该交出明文');
    final state = await core.authState();
    expect(state['status'], 'locked');
    expect(state['remainingSeconds'], isNull);
  });

  test('改主密码会同时锁掉 bridge 域（锁 App 不能留下解锁的浏览器）', () async {
    final core = await vault.boot();
    await core.setMasterPassword(oldPw);

    // 模拟"浏览器扩展那边也解锁了"（bridge 域是独立会话）。
    core.sessions.bridge.unlock(Uint8List.fromList(List<int>.filled(32, 7)));
    expect(core.sessions.bridge.isUnlocked, isTrue);

    await core.changeMasterPassword(current: oldPw, next: newPw);

    expect(core.sessions.ui.isUnlocked, isFalse);
    expect(core.sessions.bridge.isUnlocked, isFalse,
        reason: '改主密码后 bridge 域还留着旧钥匙 —— 用户会以为扩展已经锁了');
  });

  test('CryptoService 走的是库内 vault_meta，不再依赖系统钥匙串', () async {
    final core = await vault.boot();
    await core.setMasterPassword(oldPw);

    // 校验材料的两个键都落在库文件的 vault_meta 里（D1 决策）。
    expect(
      await vault.db.getMeta('secret.easypass_master_key_salt'),
      isNotNull,
    );
    expect(
      await vault.db.getMeta('secret.easypass_master_pw_hash'),
      isNotNull,
    );
    expect(await core.crypto.getStoredSalt(), isNotNull);
  });
}
