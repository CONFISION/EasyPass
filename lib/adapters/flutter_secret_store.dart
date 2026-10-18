import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/storage/secret_store.dart';

/// UI 侧的 [SecretStore]：系统钥匙串（Windows 凭据管理器 / Linux Secret Service）。
///
/// 这个文件是**唯一**允许 import `flutter_secure_storage` 的地方 —— 核心服务
/// 走 `VaultMetaSecretStore`，AOT 控制台编译不能带 Flutter 插件。
///
/// 迁移期它还有第二个用途：把旧版存在钥匙串里的 salt / 校验哈希读出来，
/// 通过 `adoptLegacyKeyMaterial` 动作交给核心（见 docs/core-service-refactor.md §3.6）。
class FlutterSecretStore implements SecretStore {
  const FlutterSecretStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> write({required String key, required String? value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);
}
