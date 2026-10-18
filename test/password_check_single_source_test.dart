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
import 'package:easypass/data/services/master_password_rotation.dart';
import 'package:easypass/core_service/native_messaging_service.dart';

import 'fakes.dart';

/// **单一校验口径**回归。
///
/// 主密码"校验"在本仓库曾被实现三遍：
/// 1. `AuthNotifier.unlock` —— 走 `MasterPasswordRotation.verifyCredentials`（正确）
/// 2. `NativeMessagingService._unlock` —— 自己比 secure storage 的 salt/hash
/// 3. `EntryDetailScreen._verify` —— 同样自己比
///
/// 后两处不知道**轮换日志**的存在，于是"轮换已提交、校验材料还没写进钥匙串"
/// 这个窗口里，两边会给出互相矛盾的答案：App 认新密码，扩展 / 详情页只认旧密码。
/// 对用户就是"改了主密码，旧密码还生效"。
///
/// M4 之后 UI 侧那份实现（1）已经不存在了 —— `AuthNotifier` 只转发
/// `VaultApi`，校验全在核心里。但**核心内部**仍然有两个入口会碰主密码：UI 域
/// （`CoreActions._unlock`）和 bridge 域（`NativeMessagingService._unlock`，
/// 浏览器扩展走这条），它们必须继续共用 `MasterPasswordVerifier`。本文件就是
/// 这条约束的回归：bridge 那条路径必须和轮换日志给出同一个答案。
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

    // 初始状态：旧密码 + 一条条目
    final salt = crypto.generateSalt();
    await crypto.storeKeyMaterial(salt, crypto.hashMasterPassword(oldPw, salt));
    final key = crypto.deriveKey(oldPw, salt);
    final seeded = VaultRepository(
        db: db, cryptoService: crypto, keyReader: () => key);
    await seeded.saveItem(VaultItem(
      id: 'e1',
      type: EntryType.login,
      name: 'GitHub',
      login: const LoginData(url: 'https://github.com', password: 'pw'),
      createdAt: 0,
      updatedAt: 0,
    ));
  });

  /// 制造"轮换提交了、但钥匙串没更新"的真实窗口：
  /// 整库换成新钥匙 + 写入轮换日志，**不**动 secure storage。
  /// 这正是 `completeRotation` 写钥匙串失败时留下的状态。
  Future<void> simulateInterruptedRotation() async {
    final oldSalt = (await crypto.getStoredSalt())!;
    final newSalt = crypto.generateSalt();

    final rotation = MasterPasswordRotation(
      db: db,
      cryptoService: crypto,
      repository: repo,
    );
    await rotation.startRotation(
      oldKey: crypto.deriveKey(oldPw, oldSalt),
      newSalt: newSalt,
      newPasswordHash: crypto.hashMasterPassword(newPw, newSalt),
      newKey: crypto.deriveKey(newPw, newSalt),
    );
    // 刻意不调 completeRotation：模拟钥匙串写失败。
  }

  test('前置：这个状态下日志确实挂着、钥匙串仍是旧材料', () async {
    await simulateInterruptedRotation();

    final rotation = MasterPasswordRotation(
        db: db, cryptoService: crypto, repository: repo);
    expect(await rotation.hasPendingRotation(), isTrue);

    final salt = (await crypto.getStoredSalt())!;
    // 用钥匙串里的材料算旧密码 -> 命中；新密码 -> 不命中。
    expect(crypto.hashMasterPassword(oldPw, salt),
        await crypto.getStoredPasswordHash());
    expect(crypto.hashMasterPassword(newPw, salt),
        isNot(await crypto.getStoredPasswordHash()));
  });

  test('桥接 unlock 必须和 App 给出同一答案（新密码可用）', () async {
    await simulateInterruptedRotation();

    final svc = NativeMessagingService(db, crypto, TotpService());
    final res = await svc.handleRequest({
      'requestId': 'r',
      'action': 'unlock',
      'password': newPw,
    });

    expect(res['error'], isNull,
        reason: 'App 认新密码，桥接却不认 —— 两条口径不一致，用户会看到'
            '"在 App 里改了主密码，扩展那边旧密码还能用"');
    expect(svc.isUnlocked, isTrue);
  });

  test('桥接 unlock 必须拒绝旧密码（不能因为它还在钥匙串里就放行）', () async {
    await simulateInterruptedRotation();

    final svc = NativeMessagingService(db, crypto, TotpService());
    final res = await svc.handleRequest({
      'requestId': 'r',
      'action': 'unlock',
      'password': oldPw,
    });

    expect(res['error'], isNotNull,
        reason: '整库已经是新钥匙的密文，放行旧密码只会解出空值');
    expect(svc.isUnlocked, isFalse);
  });
}
