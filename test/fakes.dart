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

  /// When non-null, the *n*-th and all later [write] calls throw this
  /// exception (1-based). Lets a test cut a multi-write sequence in half —
  /// e.g. `storeKeyMaterial` writes salt first and hash second, so
  /// `failWriteFrom = 2` reproduces "vault re-encrypted but the verifier
  /// never landed", the exact shape of the Low-integrity-label incident.
  int? failWriteFrom;

  int _writeCount = 0;

  int get writeCount => _writeCount;

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
    _writeCount++;
    final partial = failWriteFrom;
    if (partial != null && _writeCount >= partial) {
      throw StateError('FakeSecureStorage: write #$_writeCount failed (injected)');
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
