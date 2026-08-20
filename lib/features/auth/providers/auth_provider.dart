import 'dart:async';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/crypto/crypto_service.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../l10n/app_localizations.dart';

/// Error codes stored in [AuthState.errorMessage]. UI layers map these to
/// localized strings via `AppLocalizations`.
abstract final class AuthErrorCodes {
  static const passwordsDoNotMatch = 'passwordsDoNotMatch';
  static const passwordTooShort = 'passwordTooShort';
  static const failedToSave = 'failedToSave';
  static const noMasterPassword = 'noMasterPassword';
  static const incorrectMasterPassword = 'incorrectMasterPassword';
  static const unlockError = 'unlockError';
  static const currentPasswordIncorrect = 'currentPasswordIncorrect';
  static const vaultLocked = 'vaultLocked';
  static const failedToChange = 'failedToChange';
}

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
        errorMessage: AuthErrorCodes.passwordsDoNotMatch,
      );
      return false;
    }

    if (password.length < 8) {
      state = state.copyWith(
        status: AuthStatus.firstRun,
        errorMessage: AuthErrorCodes.passwordTooShort,
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
    } catch (_) {
      state = state.copyWith(
        status: AuthStatus.firstRun,
        errorMessage: AuthErrorCodes.failedToSave,
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
          errorMessage: AuthErrorCodes.noMasterPassword,
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
          errorMessage: AuthErrorCodes.incorrectMasterPassword,
        );
        return false;
      }
    } catch (_) {
      state = state.copyWith(
        status: AuthStatus.locked,
        errorMessage: AuthErrorCodes.unlockError,
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
      state = state.copyWith(errorMessage: AuthErrorCodes.passwordsDoNotMatch);
      return false;
    }

    if (newPassword.length < 8) {
      state = state.copyWith(
        errorMessage: AuthErrorCodes.passwordTooShort,
      );
      return false;
    }

    try {
      final storedSalt = await _cryptoService.getStoredSalt();
      final storedHash = await _cryptoService.getStoredPasswordHash();

      if (storedSalt == null || storedHash == null) {
        state = state.copyWith(
          errorMessage: AuthErrorCodes.noMasterPassword,
        );
        return false;
      }

      if (_cryptoService.hashMasterPassword(currentPassword, storedSalt) !=
          storedHash) {
        state = state.copyWith(
          errorMessage: AuthErrorCodes.currentPasswordIncorrect,
        );
        return false;
      }

      final oldKey = _ref.read(encryptionKeyProvider);
      if (oldKey == null) {
        state = state.copyWith(errorMessage: AuthErrorCodes.vaultLocked);
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
    } catch (_) {
      state = state.copyWith(
        errorMessage: AuthErrorCodes.failedToChange,
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

/// Maps an [AuthErrorCodes] value to a localized message.
String authErrorMessage(AppLocalizations l10n, String? code) {
  switch (code) {
    case AuthErrorCodes.passwordsDoNotMatch:
      return l10n.errorPasswordsDoNotMatch;
    case AuthErrorCodes.passwordTooShort:
      return l10n.errorPasswordTooShort;
    case AuthErrorCodes.failedToSave:
      return l10n.errorFailedToSave;
    case AuthErrorCodes.noMasterPassword:
      return l10n.errorNoMasterPassword;
    case AuthErrorCodes.incorrectMasterPassword:
      return l10n.errorIncorrectMasterPassword;
    case AuthErrorCodes.unlockError:
      return l10n.errorUnlockFailed;
    case AuthErrorCodes.currentPasswordIncorrect:
      return l10n.errorCurrentPasswordIncorrect;
    case AuthErrorCodes.vaultLocked:
      return l10n.errorVaultLocked;
    case AuthErrorCodes.failedToChange:
      return l10n.errorFailedToChange;
    default:
      return code ?? '';
  }
}
