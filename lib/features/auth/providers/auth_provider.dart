import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/crypto/crypto_service.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/master_password_rotation.dart';
import '../../../data/state/session_key.dart';
import '../../../l10n/app_localizations.dart';
import '../../browser_bridge/browser_session_registry.dart';

// `encryptionKeyProvider` 的**定义**搬到了 data 层（VaultRepository 需要它，
// 而 data 不能反向 import features）。这里 re-export，保持既有 import 不变。
export '../../../data/state/session_key.dart' show encryptionKeyProvider;

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
  static const storageUnavailable = 'storageUnavailable';
  static const failedToSaveSettings = 'failedToSaveSettings';

  /// 上一次改主密码已经生效（整库已换钥匙），但校验材料没写进钥匙串；
  /// 用户输入的是旧密码，无法派生新钥匙 —— 必须改用新密码。
  static const useNewMasterPassword = 'useNewMasterPassword';

  /// 主密码已改成功，但新的校验材料没写进系统钥匙串（Linux Secret Service
  /// 不可用 / 钥匙串上锁）。新密码**仍然有效**（依据是库里的轮换日志），
  /// 所以这只是提示，不是失败。
  static const masterPasswordChangedStorageWarning =
      'masterPasswordChangedStorageWarning';
}

enum AuthStatus { loading, locked, unlocked, firstRun }

/// Sentinel for [AuthState.copyWith]: distinguishes "field not provided"
/// (keep the existing value) from "field provided as `null`" (clear it).
/// Without it the previous `copyWith` would overwrite `errorMessage` with
/// `null` whenever the caller only updated `status`, hiding the
/// "secure storage unavailable" banner the moment the user tapped Unlock.
const Object _unset = Object();

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
    Object? errorMessage = _unset,
    int? autoLockMinutes,
  }) {
    return AuthState(
      status: status ?? this.status,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
      autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
    );
  }
}

/// Holds the derived AES encryption key for the current session.
/// Cleared on lock.
///
/// 定义见 `lib/data/state/session_key.dart`（本文件 import + re-export）。

class AuthNotifier extends StateNotifier<AuthState> {
  final CryptoService _cryptoService;
  final Ref _ref;
  Timer? _autoLockTimer;
  int _autoLockMinutes = AppConstants.autoLockTimeoutMinutes;

  AuthNotifier(this._cryptoService, this._ref) : super(const AuthState()) {
    _checkInitialState();
  }

  Future<void> _checkInitialState() async {
    try {
      _autoLockMinutes = await _cryptoService.getAutoLockMinutes();
      final isFirstRun = await _cryptoService.isFirstRun();
      state = state.copyWith(
        status: isFirstRun ? AuthStatus.firstRun : AuthStatus.locked,
        autoLockMinutes: _autoLockMinutes,
        errorMessage: null,
      );
    } catch (_) {
      // A storage failure is not evidence that this is a fresh install.
      // Keep the app out of the first-run route and report the failure on
      // the lock screen instead of silently falling back to a false setup
      // state (or leaving routing in `loading` forever).
      state = state.copyWith(
        status: AuthStatus.locked,
        autoLockMinutes: _autoLockMinutes,
        errorMessage: AuthErrorCodes.storageUnavailable,
      );
    }
  }

  /// Re-runs the secure-storage probe the boot sequence uses to decide
  /// between first-run / locked / unlocked. The lock screen wires this to
  /// its "Retry" button so the user can recover from a transient keyring
  /// failure without restarting the app.
  Future<void> retryInitialState() async {
    await _checkInitialState();
  }

  /// Set the master password for the first time
  Future<bool> setMasterPassword(
    String password,
    String confirmPassword,
  ) async {
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

      state = state.copyWith(status: AuthStatus.unlocked, errorMessage: null);
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

  /// Unlock the vault with the master password.
  ///
  /// 这里同时是**被打断的轮换的恢复入口**：如果库上挂着未完成的轮换
  /// （见 [MasterPasswordRotation]），无论用户输入新旧哪个密码，都会先把
  /// 轮换补完 / 收尾，再决定用哪把钥匙继续。没有这一步，用户就会卡在
  /// "两个密码都开不了库"。
  Future<bool> unlock(String password) async {
    // Only switch to loading if storage is actually usable: if the boot
    // probe already published `storageUnavailable`, tapping Unlock would
    // otherwise erase the banner without ever talking to the password,
    // leaving the user staring at a half-form. Preserve the existing
    // errorMessage in that case so the banner survives the gesture.
    if (state.errorMessage == AuthErrorCodes.storageUnavailable) {
      return false;
    }
    state = state.copyWith(status: AuthStatus.loading);

    try {
      final rotation = _ref.read(masterPasswordRotationProvider);
      final check = await rotation.verifyCredentials(password);

      if (check == null) {
        state = state.copyWith(
          status: AuthStatus.locked,
          errorMessage: AuthErrorCodes.incorrectMasterPassword,
        );
        return false;
      }

      // 挂着轮换时先把它收尾；拿回来的钥匙保证能解开当前整库。
      final key = await rotation.recoverPendingRotation(
        check: check,
        providedKey: check.key,
      );
      if (key == null) {
        // 轮换其实已经生效（整库已是新钥匙的密文），但用户输入的是旧密码。
        // 目标钥匙无法由旧密码推出 —— 只能明确告诉他改用新密码。
        state = state.copyWith(
          status: AuthStatus.locked,
          errorMessage: AuthErrorCodes.useNewMasterPassword,
        );
        return false;
      }

      _ref.read(encryptionKeyProvider.notifier).state = key;
      state = state.copyWith(status: AuthStatus.unlocked, errorMessage: null);
      _startAutoLockTimer();
      return true;
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
      state = state.copyWith(errorMessage: AuthErrorCodes.passwordTooShort);
      return false;
    }

    try {
      final rotation = _ref.read(masterPasswordRotationProvider);

      // 校验当前密码 —— 走轮换服务，它会同时看 secure storage 与未完成的轮换
      // 日志（不能只看 secure storage：打断过的库里，那儿的材料和实际密文可能
      // 不一致）。
      final check = await rotation.verifyCredentials(currentPassword);
      if (check == null) {
        final stored = await _cryptoService.getStoredPasswordHash();
        state = state.copyWith(
          errorMessage: stored == null
              ? AuthErrorCodes.noMasterPassword
              : AuthErrorCodes.currentPasswordIncorrect,
        );
        return false;
      }

      var oldKey = check.key;
      if (check.hasPendingRotation) {
        // 上一次轮换没走完。先按日志把它收尾 / 回退，拿到真正能开库的钥匙，
        // 再在此基础上开始这一次。不收尾就直接轮换，会把库留在
        // "日志是旧的、密文是新的"这种自相矛盾的状态里。
        final resolved = await rotation.recoverPendingRotation(
          check: check,
          providedKey: check.key,
        );
        if (resolved == null) {
          // 走到这里意味着库已在新钥匙上、而当前密码是旧的 —— 但
          // verifyCredentials 刚刚认了它，所以理论上不可达。防御性处理：
          // 不改密码，避免把库搅坏。
          state = state.copyWith(
            errorMessage: AuthErrorCodes.useNewMasterPassword,
          );
          return false;
        }
        oldKey = resolved;
      }

      if (!await _ref
          .read(vaultRepositoryProvider)
          .encryptionProbeWorks(oldKey)) {
        // 兜底：用户给的当前密码不是当前整库的钥匙（例如上面刚被判为旧密码、
        // 而库其实已经在新钥匙上）。继续轮换只会把数据搅坏。
        state = state.copyWith(
          errorMessage: AuthErrorCodes.currentPasswordIncorrect,
        );
        return false;
      }

      // Derive the new key first so a failure re-encrypts nothing.
      final newSalt = _cryptoService.generateSalt();
      final newKey = _cryptoService.deriveKey(newPassword, newSalt);
      final newHash = _cryptoService.hashMasterPassword(newPassword, newSalt);

      // 整库重加密 + 轮换日志写进**同一个事务**（见 MasterPasswordRotation）。
      // 全库重加密走 repository → VaultItemMapper，**新加的密文列自动包含
      // 在内**；任何一行解不开都会抛异常并整段回滚。
      await rotation.startRotation(
        oldKey: oldKey,
        newSalt: newSalt,
        newPasswordHash: newHash,
        newKey: newKey,
      );

      // 最后一步：把新的校验材料写进 secure storage 并清掉日志。这一步失败
      // **不再会锁死库** —— 日志还在，条目密文已经在新钥匙上，下次解锁时
      // 用新密码即可由 recoverPendingRotation 自动补完。
      final storeUpdated = await rotation.completeRotation(
        PendingRotation(salt: newSalt, passwordHash: newHash),
      );

      // 改完主密码**回到锁定态**。
      //
      // 不留在解锁态的原因有两个：
      // 1. **让用户当场验收**新密码确实生效 —— 本仓库刚因为"改了主密码而实际
      //    生效的仍是旧密码"出过一次事故（三处校验口径不一致），"改完还能直接
      //    用"恰恰会让这类问题看不出来。锁定后必须用新密码重新进来。
      // 2. 换钥匙这个安全敏感动作之后重新认证一次，是密码管理器的常规做法。
      // 路由层（app.dart 的 redirect）会据此把界面送回 /lock。
      _autoLockTimer?.cancel();
      _ref.read(encryptionKeyProvider.notifier).state = null;
      BrowserSessionRegistry.lockIfAny();
      state = state.copyWith(
        status: AuthStatus.locked,
        // 钥匙串没写成功时给一句可操作的提示（新密码仍然有效，依据是库里的
        // 轮换日志）。写成功了就不打扰用户。
        errorMessage: storeUpdated
            ? null
            : AuthErrorCodes.masterPasswordChangedStorageWarning,
      );
      return true;
    } catch (_) {
      state = state.copyWith(errorMessage: AuthErrorCodes.failedToChange);
      return false;
    }
  }

  /// Update the auto-lock timeout and persist it.
  Future<void> setAutoLockMinutes(int minutes) async {
    final normalizedMinutes = minutes.clamp(1, 60).toInt();
    try {
      await _cryptoService.setAutoLockMinutes(normalizedMinutes);
    } catch (error, stackTrace) {
      // Do not publish a setting that was not persisted.  Report it in the
      // auth state and propagate the original error so the caller can show
      // an actionable message rather than claiming that the change worked.
      state = state.copyWith(errorMessage: AuthErrorCodes.failedToSaveSettings);
      Error.throwWithStackTrace(error, stackTrace);
    }

    _autoLockMinutes = normalizedMinutes;
    state = state.copyWith(
      autoLockMinutes: _autoLockMinutes,
      errorMessage: null,
    );
    if (state.status == AuthStatus.unlocked) {
      _startAutoLockTimer();
    }
  }

  /// Lock the vault
  void lock() {
    _autoLockTimer?.cancel();
    _ref.read(encryptionKeyProvider.notifier).state = null;
    // The browser extension keeps its own session inside the daemon (C 方案),
    // so lock that one too: "lock the app" must not leave the browser unlocked
    // until the idle timeout expires. No-op when no daemon runs in this process.
    BrowserSessionRegistry.lockIfAny();
    state = state.copyWith(status: AuthStatus.locked, errorMessage: null);
  }

  /// Start auto-lock timer
  void _startAutoLockTimer() {
    _autoLockTimer?.cancel();
    _autoLockTimer = Timer(Duration(minutes: _autoLockMinutes), lock);
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
    case AuthErrorCodes.storageUnavailable:
      return l10n.errorStorageUnavailable;
    case AuthErrorCodes.failedToSaveSettings:
      return l10n.errorFailedToSaveSettings;
    case AuthErrorCodes.useNewMasterPassword:
      return l10n.errorUseNewMasterPassword;
    case AuthErrorCodes.masterPasswordChangedStorageWarning:
      return l10n.masterPasswordChangedStorageWarning;
    default:
      return code ?? '';
  }
}
