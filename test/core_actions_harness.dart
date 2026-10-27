import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/core/crypto/totp_service.dart';
import 'package:easypass/core/storage/secret_store.dart';
import 'package:easypass/core/storage/vault_meta_secret_store.dart';
import 'package:easypass/core_service/agent_access_store.dart';
import 'package:easypass/core_service/agent_pairing_store.dart';
import 'package:easypass/core_service/core_actions.dart';
import 'package:easypass/core_service/session_domains.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/data/services/export_import_service.dart';
import 'package:easypass/data/services/master_password_rotation.dart';
import 'package:easypass/protocol/protocol.dart';

/// 测试用的核心装配：**与 `CoreService.start()` 同一套接线**（同一个
/// `CoreActions`、同一个 `MasterPasswordRotation`、同一个会话域）。
///
/// 为什么这些回归测试要打在这一层而不是打在 UI 上：M4 之后"改主密码"的语义
/// （校验 → 原子轮换 → 回到锁定态）**整体搬进了核心**，UI 只剩转发与错误码
/// 翻译。把断言留在 UI 上就只能测到一个假实现；打在 `CoreActions` 上，"改完
/// 密码新密码能开库、旧密码被拒、日志清空、密文真的换过"这些不变量仍然由真实
/// 代码守着（`test/change_password_*` / `test/master_password_rotation_atomicity_test.dart`）。
///
/// 用法：
/// ```dart
/// final vault = CoreVault.create();
/// addTearDown(vault.close);
/// final core = await vault.boot();          // "启动核心"
/// await core.setMasterPassword('pw');
/// ...
/// final restarted = await vault.boot();     // "重启核心"：同一份库，全新会话
/// ```
class CoreVault {
  CoreVault._(this.db, this.store);

  /// 建一份内存库（"库文件"）。
  ///
  /// [storeFactory] 可以包一层可注入失败的 [SecretStore] —— 用来复现"校验材料
  /// 写不进去"的真实故障（旧的 `FakeSecureStorage.failWriteFrom` 场景）。
  factory CoreVault.create({
    SecretStore Function(SecretStore inner)? storeFactory,
  }) {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final inner = VaultMetaSecretStore(db);
    return CoreVault._(db, storeFactory?.call(inner) ?? inner);
  }

  final AppDatabase db;

  /// 密钥材料的存储（生产环境是库文件的 `vault_meta`）。
  final SecretStore store;

  /// 启动一次核心：全新的 `CryptoService` / 会话域 / 仓库与动作，
  /// 但**复用同一份库**（就是"重启核心"）。
  Future<CoreHarness> boot({
    Duration idleTimeout = const Duration(minutes: 5),
  }) async {
    // 生产环境里核心启动时会把 VaultMetaSecretStore 注册到进程级 registry。
    SecretStoreRegistry.register(store);
    final crypto = CryptoService(secureStorage: store);
    final sessions = SessionDomains(idleTimeout: idleTimeout);
    final repository = VaultRepository(
      db: db,
      cryptoService: crypto,
      keyReader: () => sessions.ui.key,
    );
    final rotation = MasterPasswordRotation(
      db: db,
      cryptoService: crypto,
      repository: repository,
    );
    final exporter = ExportImportService(
      db,
      () => sessions.ui.key ?? (throw Exception('Vault is locked')),
      repository: repository,
      cryptoService: crypto,
    );

    final harness = CoreHarness._(
      vault: this,
      crypto: crypto,
      sessions: sessions,
      repository: repository,
      rotation: rotation,
      exporter: exporter,
    );
    final actions = CoreActions(
      db: db,
      cryptoService: crypto,
      repository: repository,
      rotation: rotation,
      exporter: exporter,
      totpService: TotpService(),
      sessions: sessions,
      pairingStore: AgentPairingStore(db),
      agentAccess: AgentAccessStore(db),
      onDataChanged: harness.changedTopics.addAll,
    );
    harness.actions = actions;
    await actions.refreshAuthMaterial();
    return harness;
  }

  Future<void> close() async {
    SecretStoreRegistry.reset();
    await db.close();
  }
}

/// 一次"核心运行"的句柄。
class CoreHarness {
  CoreHarness._({
    required this.vault,
    required this.crypto,
    required this.sessions,
    required this.repository,
    required this.rotation,
    required this.exporter,
  });

  final CoreVault vault;
  final CryptoService crypto;
  final SessionDomains sessions;
  final VaultRepository repository;
  final MasterPasswordRotation rotation;
  final ExportImportService exporter;

  late final CoreActions actions;

  /// 核心广播过的变更主题（`items` / `folders` / …）。
  final List<String> changedTopics = <String>[];

  bool get isUnlocked => sessions.ui.isUnlocked;

  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> params = const {},
  ]) {
    return actions.handle(action, params);
  }

  Future<Map<String, dynamic>> setMasterPassword(String password) => call(
        Actions.setMasterPassword,
        {'password': password, 'confirmPassword': password},
      );

  Future<Map<String, dynamic>> unlock(String password) =>
      call(Actions.unlock, {'password': password});

  Future<Map<String, dynamic>> lock() => call(Actions.lock);

  Future<Map<String, dynamic>> changeMasterPassword({
    required String current,
    required String next,
  }) =>
      call(Actions.changeMasterPassword, {
        'currentPassword': current,
        'newPassword': next,
        'confirmPassword': next,
      });

  Future<Map<String, dynamic>> authState() => call(Actions.getAuthState);
}

/// 可注入写入失败的 [SecretStore] 包装。
///
/// 模拟"校验材料落盘失败"（钥匙串不可用 / 存储写失败
/// 写不了 `%APPDATA%`；M4 之后对应"写不进库文件的 `vault_meta`"）。
class FailingSecretStore implements SecretStore {
  FailingSecretStore(this.inner);

  final SecretStore inner;

  /// 从第 n 次 [write]（1 基）起全部失败；null = 不失败。
  int? failWriteFrom;

  int _writeCount = 0;

  int get writeCount => _writeCount;

  @override
  Future<String?> read({required String key}) {
    final failure = readFailure;
    if (failure != null) throw failure;
    return inner.read(key: key);
  }

  @override
  Future<void> write({required String key, required String? value}) async {
    _writeCount++;
    final from = failWriteFrom;
    if (from != null && _writeCount >= from) {
      throw StateError('FailingSecretStore: write #$_writeCount failed');
    }
    await inner.write(key: key, value: value);
  }

  @override
  Future<void> delete({required String key}) => inner.delete(key: key);

  /// 读也整个不可用（模拟钥匙串读不出来）。
  Object? readFailure;
}
