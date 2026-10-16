import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../repositories/vault_repository.dart';
import '../../core/crypto/crypto_service.dart';

/// 「改主密码」待完成轮换的日志快照。
class PendingRotation {
  const PendingRotation({required this.salt, required this.passwordHash});

  /// 目标（新）salt。
  final String salt;

  /// 目标（新）主密码的校验哈希 —— 用 [salt] 算出。
  final String passwordHash;

  Map<String, dynamic> toJson() => {'salt': salt, 'password_hash': passwordHash};

  static PendingRotation? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return null;
      final salt = data['salt'];
      final hash = data['password_hash'];
      if (salt is! String || hash is! String) return null;
      if (salt.isEmpty || hash.isEmpty) return null;
      return PendingRotation(salt: salt, passwordHash: hash);
    } catch (_) {
      return null;
    }
  }
}

/// 凭据校验结果。
class CredentialCheck {
  const CredentialCheck({
    required this.key,
    required this.salt,
    required this.isTargetOfPendingRotation,
    required this.hasPendingRotation,
  });

  /// 由用户输入的密码派生出的密钥。
  final Uint8List key;

  /// 派生这把密钥所用的 salt。
  final String salt;

  /// 该密码是不是「待完成轮换」的目标密码（新密码）。
  final bool isTargetOfPendingRotation;

  /// 当前库上是否挂着未完成的轮换。
  final bool hasPendingRotation;
}

/// 主密码校验的**唯一口径**。
///
/// ## 为什么必须只有一份实现
///
/// 这个仓库里"校验主密码"曾被实现三遍：`AuthNotifier.unlock`、
/// `NativeMessagingService._unlock`（浏览器扩展走这条）、
/// `EntryDetailScreen._verify`（查看私钥前的二次确认）。后两处是照着
/// `secure storage` 里的 salt/hash 现算现比的 —— 而**只有**轮换日志知道
/// "整库现在到底在哪把钥匙上"。
///
/// 于是"轮换已提交、校验材料还没写进钥匙串"这个窗口里，两条口径会给出
/// 互相矛盾的答案：App 认新密码，扩展与详情页只认旧密码。用户看到的就是
/// **"在 App 里改了主密码，旧密码却还生效"**。
///
/// ## 判据：日志的存在本身就是状态
///
/// 不用去探测密文（那既慢又会被单行坏密文骗过 —— 而且**坏密文是现实存在的**，
/// 健康报告里就有"单条解密失败被跳过"的用例）。轮换的写入顺序给了我们一条
/// 更硬的依据：
///
/// - 日志与整库重加密在**同一个事务**里提交，所以
///   **有日志 ⇒ 整库已是新钥匙的密文**；
/// - 因此有日志时，**只有日志里的目标密码才是有效密码**，钥匙串里那份
///   （旧密码的）哈希一律不再作数 —— 它只是还没被补写掉而已。
///
/// 这条规则同时解决两个方向：新密码立刻可用（不再被钥匙串里的旧材料挡住），
/// 旧密码立刻失效（不再因为"哈希还对得上"而被放行）。
class MasterPasswordVerifier {
  const MasterPasswordVerifier({
    required AppDatabase db,
    required CryptoService cryptoService,
  })  : _db = db,
        _cryptoService = cryptoService;

  final AppDatabase _db;
  final CryptoService _cryptoService;

  /// 轮换日志在 `vault_meta` 里的键名。
  static const String metaKey = 'rotation.pending';

  /// 是否挂着未完成的轮换。
  Future<bool> hasPendingRotation() async =>
      (await pendingRotation()) != null;

  /// 读取未完成的轮换日志；没有或格式不可解析时返回 null。
  Future<PendingRotation?> pendingRotation() async =>
      PendingRotation.tryParse(await _db.getMeta(metaKey));

  /// 写 / 清轮换日志（只给 [MasterPasswordRotation] 用）。
  Future<void> writePending(PendingRotation pending) =>
      _db.setMeta(metaKey, jsonEncode(pending.toJson()));

  Future<void> clearPending() => _db.deleteMeta(metaKey);

  /// 校验用户输入的密码，认了就返回它派生出的 [CredentialCheck]。
  ///
  /// 有轮换日志时**只看日志**（见类文档）：日志里的目标哈希就是唯一有效答案。
  /// 没有日志时按钥匙串里的 salt/hash 校验。
  Future<CredentialCheck?> verify(String password) async {
    final pending = await pendingRotation();
    if (pending != null) {
      if (_cryptoService.hashMasterPassword(password, pending.salt) !=
          pending.passwordHash) {
        // 有日志 ⇒ 整库已是新钥匙的密文，旧密码到这里就该被拒。
        return null;
      }
      return CredentialCheck(
        key: _cryptoService.deriveKey(password, pending.salt),
        salt: pending.salt,
        isTargetOfPendingRotation: true,
        hasPendingRotation: true,
      );
    }

    final String? storedSalt;
    final String? storedHash;
    try {
      storedSalt = await _cryptoService.getStoredSalt();
      storedHash = await _cryptoService.getStoredPasswordHash();
    } catch (_) {
      // 钥匙串读不出来、又没有日志可依，就是真的无从校验了。
      return null;
    }
    if (storedSalt == null || storedHash == null) return null;

    if (_cryptoService.hashMasterPassword(password, storedSalt) != storedHash) {
      return null;
    }

    // 无日志 ⇒ 重加密没提交（或从未发生）⇒ 整库就在这把钥匙上。
    return CredentialCheck(
      key: _cryptoService.deriveKey(password, storedSalt),
      salt: storedSalt,
      isTargetOfPendingRotation: false,
      hasPendingRotation: false,
    );
  }

  /// 只回答"这个密码能不能打开保险库"，不暴露密钥。
  ///
  /// 用于**不需要拿密钥**的场景（桥接的 unlock 自己管会话、详情页只做二次确认）。
  Future<bool> isCorrect(String password) async => await verify(password) != null;

  /// 校验材料是否已配置（用于区分"密码错"与"还没设过主密码"）。
  Future<bool> hasStoredCredential() async {
    try {
      return await _cryptoService.getStoredPasswordHash() != null;
    } catch (_) {
      return false;
    }
  }
}

/// 改主密码的**原子轮换**（v2.4）。
///
/// ## 为什么需要这个类
///
/// 改主密码要同时改动两个存储系统：
/// 1. **条目密文** —— 在 SQLite 里，有事务；
/// 2. **校验哈希 + salt** —— 在 `flutter_secure_storage` 里，**没有事务**。
///
/// 旧实现是"先重加密整库、再写 secure storage"。后者会真实失败：Linux 的
/// Secret Service 不可用（纯 tty、keyring 上锁），或 Windows 上进程被完整性
/// 标签降权后写不了 `%APPDATA%`。更糟的是 `storeKeyMaterial` 内部还要写两次
/// （先 salt、后哈希），所以"整库已用新钥匙重写、而校验材料半新半旧"是可达
/// 状态 —— 结果是**新旧主密码都开不了库**，等于静默丢数据。
///
/// ## 做法
///
/// 把「目标 salt + 目标校验哈希」当作**轮换日志**，与整库重加密放进
/// **同一个 SQLite 事务**：两者一起提交、或一起回滚。于是任意时刻的不变量是
///
/// - 日志**不存在** ⇒ 整库一定是旧钥匙的密文（重加密回滚了）；
/// - 日志**存在**   ⇒ 整库一定是新钥匙的密文（重加密已提交）。
///
/// 剩下唯一的窗口是"日志已提交、而 secure storage 还没写入"。这时下次解锁
/// 用**任一**密码都能进来：能开库的那个密码就是目标密码，[recoverPendingRotation]
/// 顺手把 secure storage 补齐、清掉日志，轮换完成。
class MasterPasswordRotation {
  // 命名参数用可读的公开名（db / cryptoService / repository）映射到私有字段，
  // 所以这里刻意不用 initializing formal。
  // ignore_for_file: prefer_initializing_formals
  MasterPasswordRotation({
    required AppDatabase db,
    required CryptoService cryptoService,
    required VaultRepository repository,
  })  : _db = db,
        _cryptoService = cryptoService,
        _repository = repository,
        verifier = MasterPasswordVerifier(
          db: db,
          cryptoService: cryptoService,
        );

  final AppDatabase _db;
  final CryptoService _cryptoService;
  final VaultRepository _repository;

  /// 校验口径（App / 桥接 / 详情页共用同一份实现）。
  final MasterPasswordVerifier verifier;

  /// 轮换日志在 `vault_meta` 里的键名。
  static const String metaKey = MasterPasswordVerifier.metaKey;

  /// 是否挂着未完成的轮换。
  Future<bool> hasPendingRotation() => verifier.hasPendingRotation();

  /// 读取未完成的轮换日志；没有或格式不可解析时返回 null。
  Future<PendingRotation?> pendingRotation() => verifier.pendingRotation();

  Future<void> _clearPending() => verifier.clearPending();

  /// 开始一次轮换，并**原子地**把库交给新钥匙。
  ///
  /// 返回实际重加密的条目数。抛异常时整库原封不动（事务回滚、日志未写入），
  /// 旧密码仍然有效。
  Future<int> startRotation({
    required Uint8List oldKey,
    required String newSalt,
    required String newPasswordHash,
    required Uint8List newKey,
  }) async {
    final pending = PendingRotation(salt: newSalt, passwordHash: newPasswordHash);

    late int count;
    await _db.transaction(() async {
      await verifier.writePending(pending);
      count = await _repository.reencryptAll(
        oldKey: oldKey,
        newKey: newKey,
        touchUpdatedAt: true,
      );
    });
    return count;
  }

  /// 轮换的最后一步：把目标校验材料写进 secure storage，然后清掉日志。
  ///
  /// **返回值表示 secure storage 是否真的写成功了。** 写失败时**故意保留日志**
  /// —— 日志里存着目标校验材料，是"新密码仍然能开库"的保证。若在这里把日志
  /// 也删掉，一旦钥匙串持续不可用，用户就会既进不去、又没有校验材料可依。
  ///
  /// 日志会在此后每次解锁时被重试清除，所以钥匙串恢复后会自动收敛。
  Future<bool> completeRotation(PendingRotation pending) async {
    try {
      await _cryptoService.storeKeyMaterial(pending.salt, pending.passwordHash);
    } catch (_) {
      // 钥匙串写不进去（Linux Secret Service 锁定 / Windows 低完整性降权）。
      // 不是致命错误：日志仍在，校验与解锁都走日志那条路。
      return false;
    }
    await _clearPending();
    return true;
  }

  /// 校验用户输入的密码（转交 [verifier]，保持既有调用点不变）。
  Future<CredentialCheck?> verifyCredentials(String password) =>
      verifier.verify(password);

  /// 收尾一次被打断的轮换，返回**本次应当用于解锁的钥匙**。
  ///
  /// [check] 必须是 [MasterPasswordRotation.verifyCredentials] 通过的结果。
  /// 本方法保证：只要校验认了这把密码，这里就一定还回一把能解开当前整库的
  /// 钥匙 —— **不依赖钥匙串是否可用**。校验材料必要时由库里的轮换日志提供，
  /// 所以"钥匙串坏了"不会演变成"两个密码都开不了库"。
  ///
  /// 三种落点：
  /// 1. 用户给的是**目标（新）密码** —— 轮换的重加密早已提交（日志存在 ⇒ 事务
  ///    提交过），库就在这把钥匙上；顺带补写 secure storage。
  /// 2. 用户给的是**旧密码**，且整库确实还在旧钥匙上 —— 说明这轮轮换的重加密
  ///    没提交（日志是半成品）。放弃轮换，用旧钥匙进库。
  /// 3. 用户给的是旧密码，但整库已是新钥匙的密文 —— 目标钥匙无法从旧密码推出。
  ///    把校验材料按日志切到目标（于是旧密码作废、必须改用新密码），返回
  ///    null，调用方据此提示用户改用新密码。
  Future<Uint8List?> recoverPendingRotation({
    required CredentialCheck check,
    required Uint8List providedKey,
  }) async {
    final pending = await pendingRotation();
    if (pending == null) return providedKey;

    if (check.isTargetOfPendingRotation) {
      await completeRotation(pending);
      return providedKey;
    }

    if (await _repository.encryptionProbeWorks(providedKey)) {
      // 落点 2：库还在旧钥匙上，这轮轮换没有生效，放弃它。
      await _clearPending();
      return providedKey;
    }

    // 落点 3：库已在新钥匙上，而用户只有旧密码。
    await completeRotation(pending);
    return null;
  }
}

/// 校验器：App / 桥接 / 详情页共用。
final masterPasswordVerifierProvider = Provider<MasterPasswordVerifier>((ref) {
  return MasterPasswordVerifier(
    db: ref.watch(databaseProvider),
    cryptoService: ref.watch(cryptoServiceProvider),
  );
});

/// 轮换器：需要仓储才能做整库重加密。
final masterPasswordRotationProvider = Provider<MasterPasswordRotation>((ref) {
  return MasterPasswordRotation(
    db: ref.watch(databaseProvider),
    cryptoService: ref.watch(cryptoServiceProvider),
    repository: ref.watch(vaultRepositoryProvider),
  );
});
