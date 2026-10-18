import 'package:easypass/core/storage/secret_store.dart';
import 'package:easypass/data/database/database.dart';

/// 把密钥材料存进**库文件自己的** `vault_meta` 表（D1 决策）。
///
/// 为什么可以放这里：轮换日志（`rotation.pending`）早就把同样的
/// salt / 校验哈希放在这张表里了；而校验哈希与"用猜到的密码试解密"是
/// 同一次 PBKDF2 的代价，把材料从系统钥匙串挪进库文件并不改变攻击成本。
/// 收益是核心服务彻底摆脱 Flutter 插件，且校验材料与轮换日志同处一个
/// SQLite 事务域。
///
/// 键名沿用旧钥匙串的键，前缀 `secret.` 与 `rotation.*` 区分开：
/// - `secret.easypass_master_key_salt`
/// - `secret.easypass_master_pw_hash`
/// - `secret.easypass_auto_lock_minutes`
class VaultMetaSecretStore implements SecretStore {
  VaultMetaSecretStore(this._db);

  final AppDatabase _db;

  /// `vault_meta` 里的命名空间前缀。
  static const String keyPrefix = 'secret.';

  static String metaKeyFor(String key) => '$keyPrefix$key';

  @override
  Future<String?> read({required String key}) => _db.getMeta(metaKeyFor(key));

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      await _db.deleteMeta(metaKeyFor(key));
      return;
    }
    await _db.setMeta(metaKeyFor(key), value);
  }

  @override
  Future<void> delete({required String key}) => _db.deleteMeta(metaKeyFor(key));
}
