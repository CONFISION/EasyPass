import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/crypto/crypto_service.dart';

enum AuthStatus { loading, locked, unlocked, firstRun }

class AuthState {
  final AuthStatus status;
  final String? errorMessage;

  const AuthState({
    this.status = AuthStatus.loading,
    this.errorMessage,
  });

  bool get isLocked => status == AuthStatus.locked;
  bool get isFirstRun => status == AuthStatus.firstRun;
  bool get isLoading => status == AuthStatus.loading;

  AuthState copyWith({AuthStatus? status, String? errorMessage}) {
    return AuthState(
      status: status ?? this.status,
      errorMessage: errorMessage,
    );
  }
}

/// Holds the derived AES encryption key for the current session.
/// Cleared on lock.
final encryptionKeyProvider = StateProvider<Uint8List?>((ref) => null);

class AuthNotifier extends StateNotifier<AuthState> {
  final CryptoService _cryptoService;
  final Ref _ref;
  Timer? _autoLockTimer;

  AuthNotifier(this._cryptoService, this._ref) : super(const AuthState()) {
    _checkInitialState();
  }

  Future<void> _checkInitialState() async {
    final isFirstRun = await _cryptoService.isFirstRun();
    if (isFirstRun) {
      state = state.copyWith(status: AuthStatus.firstRun);
    } else {
      state = state.copyWith(status: AuthStatus.locked);
    }
  }

  /// Set the master password for the first time
  Future<bool> setMasterPassword(String password, String confirmPassword) async {
    if (password != confirmPassword) {
      state = state.copyWith(
        status: AuthStatus.firstRun,
        errorMessage: 'Passwords do not match',
      );
      return false;
    }

    if (password.length < 8) {
      state = state.copyWith(
        status: AuthStatus.firstRun,
        errorMessage: 'Master password must be at least 8 characters',
      );
      return false;
    }

    try {
      final salt = _cryptoService.generateSalt();
      final passwordHash = _cryptoService.hashMasterPassword(password, salt);
      final derivedKey = _cryptoService.deriveKey(password, salt);
      await _cryptoService.storeKeyMaterial(salt, passwordHash);

      // Store the derived key for the session
      _ref.read(encryptionKeyProvider.notifier).state = derivedKey;

      state = state.copyWith(
        status: AuthStatus.unlocked,
        errorMessage: null,
      );
      _startAutoLockTimer();
      return true;
    } catch (e) {
      state = state.copyWith(
        status: AuthStatus.firstRun,
        errorMessage: 'Failed to save master password: $e',
      );
      return false;
    }
  }

  /// Unlock the vault with the master password
  Future<bool> unlock(String password) async {
    state = state.copyWith(status: AuthStatus.loading);

    try {
      final storedSalt = await _cryptoService.getStoredSalt();
      final storedHash = await _cryptoService.getStoredPasswordHash();

      if (storedSalt == null || storedHash == null) {
        state = state.copyWith(
          status: AuthStatus.locked,
          errorMessage: 'No master password configured',
        );
        return false;
      }

      final computedHash = _cryptoService.hashMasterPassword(password, storedSalt);

      if (computedHash == storedHash) {
        // Derive and store session key
        final derivedKey = _cryptoService.deriveKey(password, storedSalt);
        _ref.read(encryptionKeyProvider.notifier).state = derivedKey;

        state = state.copyWith(
          status: AuthStatus.unlocked,
          errorMessage: null,
        );
        _startAutoLockTimer();
        return true;
      } else {
        state = state.copyWith(
          status: AuthStatus.locked,
          errorMessage: 'Incorrect master password',
        );
        return false;
      }
    } catch (e) {
      state = state.copyWith(
        status: AuthStatus.locked,
        errorMessage: 'Error unlocking vault: $e',
      );
      return false;
    }
  }

  /// Lock the vault
  void lock() {
    _autoLockTimer?.cancel();
    _ref.read(encryptionKeyProvider.notifier).state = null;
    state = state.copyWith(status: AuthStatus.locked, errorMessage: null);
  }

  /// Start auto-lock timer
  void _startAutoLockTimer() {
    _autoLockTimer?.cancel();
    _autoLockTimer = Timer(
      const Duration(minutes: 5),
      lock,
    );
  }

  /// Reset the timer on user activity
  void onUserActivity() {
    if (state.status == AuthStatus.unlocked) {
      _startAutoLockTimer();
    }
  }

  @override
  void dispose() {
    _autoLockTimer?.cancel();
    super.dispose();
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final cryptoService = CryptoService();
  return AuthNotifier(cryptoService, ref);
});