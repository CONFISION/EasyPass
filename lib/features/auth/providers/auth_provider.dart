import 'dart:async';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/crypto/crypto_service.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/vault_repository.dart';

enum AuthStatus { loading, locked, unlocked, firstRun }

class AuthState {
  final AuthStatus status;
  final String? errorMessage;
  final int autoLockMinutes;

  const AuthState({
    this.status = AuthStatus.loading,
    this.errorMessage,
    this.autoLockMinutes = AppConstants.autoLockTimeoutMinutes,
  });

  bool get isLocked => status == AuthStatus.locked;
  bool get isFirstRun => status == AuthStatus.firstRun;
  bool get isLoading => status == AuthStatus.loading;

  AuthState copyWith({
    AuthStatus? status,
    String? errorMessage,
    int? autoLockMinutes,
  }) {
    return AuthState(
      status: status ?? this.status,
      errorMessage: errorMessage,
      autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
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
  int _autoLockMinutes = AppConstants.autoLockTimeoutMinutes;

  AuthNotifier(this._cryptoService, this._ref) : super(const AuthState()) {
    _checkInitialState();
  }

  Future<void> _checkInitialState() async {
    _autoLockMinutes = await _cryptoService.getAutoLockMinutes();
    final isFirstRun = await _cryptoService.isFirstRun();
    state = state.copyWith(
      status: isFirstRun ? AuthStatus.firstRun : AuthStatus.locked,
      autoLockMinutes: _autoLockMinutes,
    );
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

  /// Change the master password: verify the current one, re-encrypt all
  /// entries with a freshly derived key, then persist the new salt + hash.
  Future<bool> changeMasterPassword(
    String currentPassword,
    String newPassword,
    String confirmPassword,
  ) async {
    if (newPassword != confirmPassword) {
      state = state.copyWith(errorMessage: 'Passwords do not match');
      return false;
    }

    if (newPassword.length < 8) {
      state = state.copyWith(
        errorMessage: 'Master password must be at least 8 characters',
      );
      return false;
    }

    try {
      final storedSalt = await _cryptoService.getStoredSalt();
      final storedHash = await _cryptoService.getStoredPasswordHash();

      if (storedSalt == null || storedHash == null) {
        state = state.copyWith(
          errorMessage: 'No master password configured',
        );
        return false;
      }

      if (_cryptoService.hashMasterPassword(currentPassword, storedSalt) !=
          storedHash) {
        state = state.copyWith(
          errorMessage: 'Current master password is incorrect',
        );
        return false;
      }

      final oldKey = _ref.read(encryptionKeyProvider);
      if (oldKey == null) {
        state = state.copyWith(errorMessage: 'Vault is locked');
        return false;
      }

      // Derive the new key first so a failure re-encrypts nothing.
      final newSalt = _cryptoService.generateSalt();
      final newKey = _cryptoService.deriveKey(newPassword, newSalt);
      final newHash = _cryptoService.hashMasterPassword(newPassword, newSalt);

      final repo = _ref.read(vaultRepositoryProvider);
      final entries = await repo.getAllEntries();
      final now = DateTime.now().millisecondsSinceEpoch;

      for (final entry in entries) {
        final notes = (entry.notesEncrypted ?? '').isEmpty
            ? null
            : _cryptoService.decryptData(entry.notesEncrypted!, oldKey);
        final totp = (entry.totpSecretEncrypted ?? '').isEmpty
            ? null
            : _cryptoService.decryptData(entry.totpSecretEncrypted!, oldKey);

        await repo.updateEntry(
          entry.id,
          PasswordEntriesCompanion(
            id: Value(entry.id),
            name: Value(entry.name),
            url: Value(entry.url),
            username: Value(entry.username),
            passwordEncrypted: Value(
              _cryptoService.encryptData(
                _cryptoService.decryptData(entry.passwordEncrypted, oldKey),
                newKey,
              ),
            ),
            notesEncrypted: Value(
              notes == null ? '' : _cryptoService.encryptData(notes, newKey),
            ),
            totpSecretEncrypted: Value(
              totp == null ? '' : _cryptoService.encryptData(totp, newKey),
            ),
            isFavorite: Value(entry.isFavorite),
            folderId: entry.folderId != null
                ? Value(entry.folderId!)
                : const Value.absent(),
            createdAt: Value(entry.createdAt),
            updatedAt: Value(now),
          ),
        );
      }

      await _cryptoService.storeKeyMaterial(newSalt, newHash);
      _ref.read(encryptionKeyProvider.notifier).state = newKey;

      state = state.copyWith(errorMessage: null);
      _startAutoLockTimer();
      return true;
    } catch (e) {
      state = state.copyWith(
        errorMessage: 'Failed to change master password: $e',
      );
      return false;
    }
  }

  /// Update the auto-lock timeout and persist it.
  Future<void> setAutoLockMinutes(int minutes) async {
    _autoLockMinutes = minutes.clamp(1, 60).toInt();
    await _cryptoService.setAutoLockMinutes(_autoLockMinutes);
    state = state.copyWith(autoLockMinutes: _autoLockMinutes);
    if (state.status == AuthStatus.unlocked) {
      _startAutoLockTimer();
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
      Duration(minutes: _autoLockMinutes),
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
  final cryptoService = ref.watch(cryptoServiceProvider);
  return AuthNotifier(cryptoService, ref);
});
