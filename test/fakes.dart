import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// In-memory [FlutterSecureStorage] for tests. Only the methods used by
/// [CryptoService] are overridden.
class FakeSecureStorage extends FlutterSecureStorage {
  final Map<String, String> store = {};

  /// When non-null, every [read] call throws this exception. Used by the
  /// "secure storage unavailable" recovery tests to simulate a Linux
  /// machine with a locked Secret Service — the [AuthNotifier] boot probe
  /// should publish `storageUnavailable`, the user should see Retry/Exit
  /// instead of a half-broken unlock form, and a successful retry should
  /// clear the banner.
  Object? readFailure;

  /// When non-null, every [write] call throws this exception.
  Object? writeFailure;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final failure = readFailure;
    if (failure != null) {
      throw failure;
    }
    return store[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final failure = writeFailure;
    if (failure != null) {
      throw failure;
    }
    if (value == null) {
      store.remove(key);
    } else {
      store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    store.remove(key);
  }
}
