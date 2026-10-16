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
        _repository = repository;

  final AppDatabase _db;
  final CryptoService _cryptoService;
  final VaultRepository _repository;

  /// 轮换日志在 `vault_meta` 里的键名。
  static const String metaKey = 'rotation.pending';

  /// 是否挂着未完成的轮换。
  Future<bool> hasPendingRotation() async =>
      (await pendingRotation()) != null;

  /// 读取未完成的轮换日志；没有或格式不可解析时返回 null。
  Future<PendingRotation?> pendingRotation() async {
    final parsed = PendingRotation.tryParse(await _db.getMeta(metaKey));
    return parsed;
  }

  Future<void> _clearPending() => _db.deleteMeta(metaKey);

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
      await _db.setMeta(metaKey, jsonEncode(pending.toJson()));
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

  /// 校验用户输入的密码。
  ///
  /// 顺序刻意如此：**先试待完成轮换的目标密码**。因为轮换一旦开始，整库就是
  /// 新钥匙的密文，"能不能开库"与目标密码一致；而 secure storage 里可能还是
  /// 旧材料，此时若先按旧材料校验旧密码会通过、却派生出解不开新密文的旧钥匙。
  Future<CredentialCheck?> verifyCredentials(String password) async {
    final pending = await pendingRotation();
    if (pending != null) {
      if (_cryptoService.hashMasterPassword(password, pending.salt) ==
          pending.passwordHash) {
        return CredentialCheck(
          key: _cryptoService.deriveKey(password, pending.salt),
          salt: pending.salt,
          isTargetOfPendingRotation: true,
          hasPendingRotation: true,
        );
      }
    }

    final String? storedSalt;
    final String? storedHash;
    try {
      storedSalt = await _cryptoService.getStoredSalt();
      storedHash = await _cryptoService.getStoredPasswordHash();
    } catch (_) {
      // 钥匙串读不出来。若上面日志那条路也没认，就是真的无从校验了。
      return null;
    }
    if (storedSalt == null || storedHash == null) return null;

    if (_cryptoService.hashMasterPassword(password, storedSalt) != storedHash) {
      return null;
    }

    return CredentialCheck(
      key: _cryptoService.deriveKey(password, storedSalt),
      salt: storedSalt,
      isTargetOfPendingRotation: false,
      hasPendingRotation: pending != null,
    );
  }

  /// 收尾一次被打断的轮换，返回**本次应当用于解锁的钥匙**。
  ///
  /// [check] 必须是 [verifyCredentials] 通过的结果。本方法保证：只要
  /// [verifyCredentials] 认了这把密码，这里就一定还回一把能解开当前整库的
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
  ///    `providedKey` 之外的目标钥匙是做不到的，因此这里返回一个哨兵：
  ///    调用方会拿到 null 并提示用户改用新密码。
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

/// 定义在 data 层：它只依赖 data/core 的 provider，而 features 层的
/// `auth_provider` 需要用它做解锁恢复。
final masterPasswordRotationProvider = Provider<MasterPasswordRotation>((ref) {
  return MasterPasswordRotation(
    db: ref.watch(databaseProvider),
    cryptoService: ref.watch(cryptoServiceProvider),
    repository: ref.watch(vaultRepositoryProvider),
  );
});
