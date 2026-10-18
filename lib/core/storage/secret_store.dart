/// 密钥材料的存储抽象。
///
/// 为什么需要它：`CryptoService` 过去直接依赖 Flutter 插件 `flutter_secure_storage`，
/// 于是**核心服务（无 Flutter 的 AOT 可执行文件）无法使用它**。把存储抽成接口后：
/// - 核心侧：`VaultMetaSecretStore`（写进库文件的 `vault_meta` 表，与轮换日志同一个
///   事务域）；
/// - UI 侧：`lib/adapters/flutter_secret_store.dart`（系统钥匙串，迁移期读旧值用）；
/// - 测试：`test/fakes.dart` 的 `FakeSecureStorage`（既有，继续可用）。
library;

/// 键值型小对象存储。签名刻意与 `flutter_secure_storage` 的子集一致，
/// 这样既有测试替身（`FakeSecureStorage`）只需 `implements SecretStore`。
abstract class SecretStore {
  Future<String?> read({required String key});

  Future<void> write({required String key, required String? value});

  Future<void> delete({required String key});
}

/// 未注册时的兜底实现：**任何操作都抛错**。
///
/// 刻意不静默退化成内存存储：那会让"校验材料只存在内存里"这种致命问题
/// 表现成"重启后主密码打不开库"，排查成本极高。纯计算（deriveKey /
/// encryptData / hashMasterPassword）不碰存储，因此不受影响。
class UnregisteredSecretStore implements SecretStore {
  const UnregisteredSecretStore();

  Never _fail() => throw StateError(
        'SecretStore 未注册：该 CryptoService 需要读写密钥材料，但既没有传入 '
        'SecretStore，也没有通过 SecretStoreRegistry.register() 注册。'
        'UI 侧请用 FlutterSecretStore，核心侧请用 VaultMetaSecretStore。',
      );

  @override
  Future<String?> read({required String key}) async => _fail();

  @override
  Future<void> write({required String key, required String? value}) async =>
      _fail();

  @override
  Future<void> delete({required String key}) async => _fail();
}

/// 进程级默认存储：由 `main.dart`（UI）或核心服务在启动时注册一次。
///
/// 存在的意义是让 `CryptoService()` 这个既有构造方式在两侧都能用，
/// 而不必在 48 处调用点逐个传参。
class SecretStoreRegistry {
  SecretStoreRegistry._();

  static SecretStore? _store;

  /// 当前默认存储；未注册时返回 [UnregisteredSecretStore]。
  static SecretStore get instance => _store ?? const UnregisteredSecretStore();

  /// 注册默认存储（可重复调用，最后一次生效）。
  static void register(SecretStore store) => _store = store;

  /// 清空注册（仅测试使用）。
  static void reset() => _store = null;
}

/// 内存实现：只给测试与"纯计算"场景用。
class InMemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({required String key}) async => values.remove(key);
}
