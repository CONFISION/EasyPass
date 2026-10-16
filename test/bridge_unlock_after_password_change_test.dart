import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/core/crypto/totp_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/features/browser_bridge/native_messaging_service.dart';

import 'fakes.dart';

/// 真机复现（第二条路径）：**浏览器扩展 / daemon 的解锁**。
///
/// App 与桥接各自实现了一遍"校验主密码"：
/// - App（`AuthNotifier.unlock`）走 `MasterPasswordRotation.verifyCredentials`；
/// - 桥接（`NativeMessagingService._unlock`）自己拿 secure storage 里的
///   salt/hash 现算现比。
///
/// 两套实现必须给出**同一个答案**，否则就会出现"App 里改了主密码，扩展那边
/// 旧密码还能解锁"。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const oldPw = 'old-master-password';
  const newPw = 'new-master-password';

  late FakeSecureStorage storage;
  late CryptoService crypto;
  late AppDatabase db;
  late VaultRepository repo;

  setUp(() async {
    storage = FakeSecureStorage();
    crypto = CryptoService(secureStorage: storage);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    repo = VaultRepository(db: db, cryptoService: crypto, keyReader: () => null);
  });

  /// 桥接的一条连接（每次新建 = 扩展重开 popup / daemon 新建会话）。
  NativeMessagingService bridge() =>
      NativeMessagingService(db, crypto, TotpService());

  Future<Map<String, dynamic>> unlockVia(
    NativeMessagingService svc,
    String password,
  ) =>
      svc.handleRequest({
        'requestId': 'r',
        'action': 'unlock',
        'password': password,
      });

  /// 直接用 App 的那套逻辑完成一次改密码（不经过 UI，但走的是真代码）。
  Future<void> changePasswordInApp() async {
    // 先抓住旧 salt —— 换完钥匙它就没了。
    final oldSalt = (await crypto.getStoredSalt())!;
    final newSalt = crypto.generateSalt();
    final newKey = crypto.deriveKey(newPw, newSalt);

    // 整库换到新钥匙（真实流程里由 MasterPasswordRotation 在一个事务里完成）。
    await repo.reencryptAll(
      oldKey: crypto.deriveKey(oldPw, oldSalt),
      newKey: newKey,
    );
    await crypto.storeKeyMaterial(
      newSalt,
      crypto.hashMasterPassword(newPw, newSalt),
    );
  }

  Future<void> seedVault() async {
    final salt = crypto.generateSalt();
    await crypto.storeKeyMaterial(salt, crypto.hashMasterPassword(oldPw, salt));
    final key = crypto.deriveKey(oldPw, salt);
    final repo = VaultRepository(
        db: db, cryptoService: crypto, keyReader: () => key);
    await repo.saveItem(VaultItem(
      id: 'e1',
      type: EntryType.login,
      name: 'GitHub',
      login: const LoginData(url: 'https://github.com', username: 'alice', password: 'pw'),
      createdAt: 0,
      updatedAt: 0,
    ));
  }

  test('改完主密码后：桥接必须拒绝旧密码、接受新密码', () async {
    await seedVault();
    await changePasswordInApp();

    // 扩展用**旧密码**解锁 —— 真机症状是这里居然成功。
    final svcOld = bridge();
    final oldRes = await unlockVia(svcOld, oldPw);
    expect(oldRes['error'], isNotNull,
        reason: '真机症状：主密码已改，扩展却还能用旧密码解锁');
    expect(svcOld.isUnlocked, isFalse);

    // 扩展用**新密码**解锁 —— 真机症状是这里失败。
    final svcNew = bridge();
    final newRes = await unlockVia(svcNew, newPw);
    expect(newRes['error'], isNull,
        reason: '新密码应当能解锁桥接。error=${newRes['error']}');
    expect(svcNew.isUnlocked, isTrue);
  });
}
