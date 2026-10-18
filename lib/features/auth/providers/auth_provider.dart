import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../adapters/flutter_secret_store.dart';
import '../../../client/api_providers.dart';
import '../../../client/vault_api.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/storage/secret_store.dart';
import '../../../l10n/app_localizations.dart';
import '../../../protocol/protocol.dart';

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

  /// 轮换已生效（整库已是新钥匙的密文），用户输入的旧密码无法派生新钥匙 ——
  /// 必须改用新密码。
  ///
  /// 注意：`VaultApi.unlock` / `changeMasterPassword` 目前对"密码错"与"必须改用
  /// 新密码"回的是**同一个** `unauthorized` 错误码，只能按核心文案细化（见
  /// `_newPasswordRequired`）。核心若给出结构化原因，这里应改为看错误码。
  static const useNewMasterPassword = 'useNewMasterPassword';

  /// 主密码已改成功，但新的校验材料没能落盘。
  ///
  /// **M4 之后不再可达**：校验材料现在由核心写进库文件的 `vault_meta`，与整库
  /// 重加密同一个事务域（`MasterPasswordRotation.completeRotation`），而
  /// `VaultApi.changeMasterPassword` 是 `Future<void>`，不把
  /// `keyMaterialPersisted` 带出来。保留常量与文案，供核心将来回传该字段时使用。
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

  /// 核心报告的空闲剩余秒数（仅用于显示倒计时）。
  ///
  /// **自动锁定的权威在核心**：UI 不再自己起定时器，也不自己判定超时 ——
  /// 锁定时核心会广播会话事件，UI 通过 [AuthNotifier.refreshSnapshot] 同步。
  final int? remainingSeconds;

  const AuthState({
    this.status = AuthStatus.loading,
    this.errorMessage,
    this.autoLockMinutes = AppConstants.autoLockTimeoutMinutes,
    this.remainingSeconds,
  });

  bool get isLocked => status == AuthStatus.locked;
  bool get isFirstRun => status == AuthStatus.firstRun;
  bool get isLoading => status == AuthStatus.loading;

  AuthState copyWith({
    AuthStatus? status,
    Object? errorMessage = _unset,
    int? autoLockMinutes,
    Object? remainingSeconds = _unset,
  }) {
    return AuthState(
      status: status ?? this.status,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
      autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
      remainingSeconds: identical(remainingSeconds, _unset)
          ? this.remainingSeconds
          : remainingSeconds as int?,
    );
  }
}

/// 认证状态机。**UI 侧的会话权威是核心**：这里只把核心的会话状态翻译成
/// [AuthState]，并把核心的错误码翻译成 [AuthErrorCodes]。
///
/// 三条纪律：
/// 1. **不持有任何密钥**。密钥只存在于核心进程；UI 一个字节都拿不到。
/// 2. **不自己校验主密码**。`unlock` / `changeMasterPassword` 全交给核心的
///    `MasterPasswordVerifier`（唯一口径）。
/// 3. **不自己定时锁定**。空闲计时器在核心（`SessionDomains`）。
class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(this._api, this._legacyStore) : super(const AuthState()) {
    _checkInitialState();
  }

  final VaultApi _api;

  /// 迁移期读**旧**钥匙串（系统钥匙串）用的存储。
  ///
  /// 只在"核心还没有校验材料"时用一次：把 `easypass_master_key_salt` 与
  /// `easypass_master_pw_hash` 交给核心（`adoptLegacyKeyMaterial`），之后就再也
  /// 不碰它 —— 校验材料的唯一权威是库文件的 `vault_meta`。
  ///
  /// 生产实现由 [legacySecretStoreProvider] 提供（`FlutterSecretStore`）。
  final SecretStore _legacyStore;

  // ─── 启动探测 ──────────────────────────────────────────

  Future<void> _checkInitialState() async {
    try {
      final snapshot = await _api.authSnapshot();

      if (snapshot.hasAuthMaterial) {
        state = state.copyWith(
          status: _statusFromSnapshot(snapshot),
          autoLockMinutes: snapshot.autoLockMinutes,
          remainingSeconds: snapshot.remainingSeconds,
          errorMessage: null,
        );
        return;
      }

      // 核心还没有校验材料：可能是全新安装，也可能是**升级**后的第一次启动
      // （旧版把 salt/hash 存在系统钥匙串里）。两者必须区分开 —— 把升级误判成
      // 全新安装会让用户"重新设置主密码"，而整库密文还在旧钥匙下，等于丢数据。
      final adopted = await _adoptLegacyKeyMaterialIfPresent();
      state = state.copyWith(
        status: adopted ? AuthStatus.locked : AuthStatus.firstRun,
        autoLockMinutes: snapshot.autoLockMinutes,
        remainingSeconds: null,
        errorMessage: null,
      );
    } catch (_) {
      // 读不到权威状态（核心连不上 / 钥匙串上锁）时**不能**猜成 firstRun：
      // 那会把用户推到"设置主密码"表单，一旦他真设了，旧库就再也打不开。
      // 保持锁定态 + 可重试的错误码，由锁屏的恢复面板（Retry / Exit）兜底。
      state = state.copyWith(
        status: AuthStatus.locked,
        errorMessage: AuthErrorCodes.storageUnavailable,
      );
    }
  }

  /// 核心没有校验材料时，看旧钥匙串里有没有；有就一次性交给核心。
  ///
  /// 返回 true 表示"迁移完成，库已可解锁"。
  ///
  /// **刻意不删除**钥匙串里的旧材料：迁移成功后核心不再读它（`hasAuthMaterial`
  /// 已为 true），但用户若回退到 2.4.x，旧版会因为没有材料而判定"首次运行"，
  /// 那才是真正会毁数据的路径。留一份不生效的旧材料比留一个坑便宜。
  Future<bool> _adoptLegacyKeyMaterialIfPresent() async {
    final salt = await _legacyStore.read(
      key: '${AppConstants.secureStorageKey}_salt',
    );
    final passwordHash = await _legacyStore.read(
      key: AppConstants.masterPasswordHashKey,
    );
    if (salt == null || passwordHash == null || salt.isEmpty) return false;

    await _api.adoptLegacyKeyMaterial(salt: salt, passwordHash: passwordHash);
    return true;
  }

  AuthStatus _statusFromSnapshot(AuthSnapshot snapshot) {
    if (snapshot.isUnlocked) return AuthStatus.unlocked;
    if (snapshot.isFirstRun) return AuthStatus.firstRun;
    return AuthStatus.locked;
  }

  /// Re-runs the boot probe the boot sequence uses to decide between
  /// first-run / locked / unlocked. The lock screen wires this to its
  /// "Retry" button so the user can recover from a transient keyring /
  /// core-connection failure without restarting the app.
  Future<void> retryInitialState() async {
    await _checkInitialState();
  }

  /// 重新向核心要一次会话快照（状态 + 剩余秒数 + 自动锁定设置）。
  ///
  /// 屏幕想在空闲倒计时上显示剩余时间时调它；锁定本身由核心执行，UI 不负责。
  Future<void> refreshSnapshot() async {
    final snapshot = await _api.authSnapshot();
    state = state.copyWith(
      status: _statusFromSnapshot(snapshot),
      autoLockMinutes: snapshot.autoLockMinutes,
      remainingSeconds: snapshot.remainingSeconds,
    );
  }

  // ─── 首次设置 ──────────────────────────────────────────

  /// Set the master password for the first time.
  Future<bool> setMasterPassword(
    String password,
    String confirmPassword,
  ) async {
    // 本地先校验一次只是为了即时反馈；核心会**再校验一次**（它是权威）。
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
      await _api.setMasterPassword(password, confirmPassword);
    } on VaultApiException catch (error) {
      state = state.copyWith(
        status: AuthStatus.firstRun,
        errorMessage: _validationErrorCode(error) ?? AuthErrorCodes.failedToSave,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        status: AuthStatus.firstRun,
        errorMessage: AuthErrorCodes.failedToSave,
      );
      return false;
    }

    // 核心在设置成功时顺手解锁本次会话（`CoreActions._setMasterPassword`），
    // 所以这里的状态要从核心取，不能自己假设。
    await _syncAfterSessionChange(fallback: AuthStatus.unlocked);
    state = state.copyWith(errorMessage: null);
    return true;
  }

  // ─── 解锁 ──────────────────────────────────────────────

  /// Unlock the vault with the master password.
  ///
  /// 校验、轮换日志恢复（"两个密码都开不了库"的兜底）全部在核心里，UI 只做
  /// 错误码 → 文案的翻译。
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
      await _api.unlock(password);
    } on VaultApiException catch (error) {
      state = state.copyWith(
        status: AuthStatus.locked,
        errorMessage: _unlockErrorCode(error),
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        status: AuthStatus.locked,
        errorMessage: AuthErrorCodes.unlockError,
      );
      return false;
    }

    await _syncAfterSessionChange(fallback: AuthStatus.unlocked);
    state = state.copyWith(errorMessage: null);
    return true;
  }

  // ─── 改主密码 ──────────────────────────────────────────

  /// Change the master password (verification + whole-vault re-encryption are
  /// atomic inside the core).
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
      await _api.changeMasterPassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
        confirmPassword: confirmPassword,
      );
    } on VaultApiException catch (error) {
      state = state.copyWith(errorMessage: _changeErrorCode(error));
      return false;
    } catch (_) {
      state = state.copyWith(errorMessage: AuthErrorCodes.failedToChange);
      return false;
    }

    // 改完主密码**回到锁定态**（核心已经在同一个事务里 `lockAll()`，这里只是把
    // UI 状态归位，路由随即回 /lock）。
    //
    // 不留在解锁态的原因有两个：
    // 1. **让用户当场验收**新密码确实生效 —— 本仓库刚因为"改了主密码而实际
    //    生效的仍是旧密码"出过一次事故（三处校验口径不一致），"改完还能直接
    //    用"恰恰会让这类问题看不出来。锁定后必须用新密码重新进来。
    // 2. 换钥匙这个安全敏感动作之后重新认证一次，是密码管理器的常规做法。
    //
    // 不要"顺手恢复解锁"：`test/change_password_then_lock_test.dart` 盯着这条。
    state = state.copyWith(
      status: AuthStatus.locked,
      remainingSeconds: null,
      errorMessage: null,
    );
    return true;
  }

  // ─── 自动锁定设置 ──────────────────────────────────────

  /// Update the auto-lock timeout (persisted and enforced by the core).
  Future<void> setAutoLockMinutes(int minutes) async {
    final normalizedMinutes = minutes.clamp(1, 60).toInt();
    try {
      await _api.setAutoLockMinutes(normalizedMinutes);
    } catch (error, stackTrace) {
      // Do not publish a setting that was not persisted.  Report it in the
      // auth state and propagate the original error so the caller can show
      // an actionable message rather than claiming that the change worked.
      state = state.copyWith(errorMessage: AuthErrorCodes.failedToSaveSettings);
      Error.throwWithStackTrace(error, stackTrace);
    }

    state = state.copyWith(
      autoLockMinutes: normalizedMinutes,
      errorMessage: null,
    );
  }

  // ─── 锁定 ──────────────────────────────────────────────

  /// Lock the vault. 核心会顺带锁掉 bridge 域（"锁 App 不能留下解锁的浏览器"）。
  Future<void> lock() async {
    try {
      await _api.lock();
    } catch (_) {
      // 锁定请求本身失败也必须把 UI 置为锁定态：宁可让界面多锁一次，
      // 也不要停在"看起来还开着"的解锁界面上。
    }
    state = state.copyWith(
      status: AuthStatus.locked,
      remainingSeconds: null,
      errorMessage: null,
    );
  }

  // ─── 错误码映射 ────────────────────────────────────────

  /// 会话状态变化（解锁 / 首设成功）后向核心要一次权威快照。
  ///
  /// **不能因为这一步失败就报"解锁失败"** —— 动作已经成功了，那会变成假阴性。
  /// 取不到快照时退化为"按本地已知的结果置状态"，剩余秒数留空。
  Future<void> _syncAfterSessionChange({required AuthStatus fallback}) async {
    try {
      await refreshSnapshot();
    } catch (_) {
      state = state.copyWith(status: fallback, remainingSeconds: null);
    }
  }

  /// 把用户活动上报给核心（空闲锁定的权威在核心）。
  ///
  /// 调用方（`app.dart` 的活动监听）已做节流；核心不可达时静默失败。
  Future<void> touchActivity() => _api.touchActivity();

  /// 核心的会话事件：`locked` / `unlocked` / `shuttingDown`。
  ///
  /// **必须订阅**：空闲锁定发生在核心里，核心会广播 `sessionLocked`。
  /// 不订阅的话 UI 会停在"看起来还能用"的界面（每个动作都回 locked），
  /// 用户以为应用坏了 —— 这是客户端化最容易漏的一致性缺口。
  void handleSessionEvent(String event) {
    switch (event) {
      case 'locked':
        state = state.copyWith(status: AuthStatus.locked, remainingSeconds: null);
      case 'unlocked':
        _syncAfterSessionChange(fallback: AuthStatus.unlocked);
      case 'shuttingDown':
        // 核心要退出了：先把 UI 切回锁定态，避免用户继续对着假界面操作。
        state = state.copyWith(status: AuthStatus.locked, remainingSeconds: null);
    }
  }

  String _unlockErrorCode(VaultApiException error) {
    switch (error.code) {
      case ErrorCodes.needsKeyMigration:
        // 核心里没有校验材料。启动探测时已经尝试过迁移，走到这里说明旧钥匙串
        // 也确实没有材料 —— 只能让用户重新设置主密码。
        return AuthErrorCodes.noMasterPassword;
      case ErrorCodes.unauthorized:
        return _newPasswordRequired(error)
            ? AuthErrorCodes.useNewMasterPassword
            : AuthErrorCodes.incorrectMasterPassword;
      case ErrorCodes.rateLimited:
        // 二次校验的退避（`verifyMasterPassword`）不会出现在解锁路径上；
        // 真出现时按"解锁失败"提示，不要谎称密码错。
        return AuthErrorCodes.unlockError;
      default:
        return AuthErrorCodes.unlockError;
    }
  }

  String _changeErrorCode(VaultApiException error) {
    final validation = _validationErrorCode(error);
    if (validation != null) return validation;
    if (error.code == ErrorCodes.unauthorized) {
      return _newPasswordRequired(error)
          ? AuthErrorCodes.useNewMasterPassword
          : AuthErrorCodes.currentPasswordIncorrect;
    }
    if (error.code == ErrorCodes.locked) return AuthErrorCodes.vaultLocked;
    return AuthErrorCodes.failedToChange;
  }

  /// 核心的 `invalidRequest` 用文案区分两种输入校验失败（两次输入不一致 /
  /// 密码太短）。UI 在调用前已经本地校验过，这里只是把核心的拒绝也翻译对。
  /// 认不出的文案返回 null（调用方退化为通用错误码）—— 绝不误判成成功。
  String? _validationErrorCode(VaultApiException error) {
    if (error.code != ErrorCodes.invalidRequest) return null;
    if (error.message.contains('不一致')) return AuthErrorCodes.passwordsDoNotMatch;
    if (error.message.contains('8 位')) return AuthErrorCodes.passwordTooShort;
    return null;
  }

  /// "必须改用新密码"与"密码错"在协议上共用 `unauthorized`，只能按核心文案
  /// 细化：认不出时退化为"主密码不正确"（只是提示不够具体，不会误导用户去做
  /// 错误的操作）。核心若补上结构化原因，这里应改为看错误码。
  bool _newPasswordRequired(VaultApiException error) =>
      error.code == ErrorCodes.unauthorized &&
      error.message.contains('新的主密码');
}

/// 迁移期读旧钥匙串的存储。测试覆盖它即可模拟"升级后的第一次启动"。
final legacySecretStoreProvider = Provider<SecretStore>((ref) {
  return const FlutterSecretStore();
});

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final api = ref.watch(vaultApiProvider);
  final notifier = AuthNotifier(api, ref.watch(legacySecretStoreProvider));
  // 核心的会话事件（空闲自锁 / 解锁 / 即将退出）驱动 UI 状态。
  final subscription = api.sessionEvents.listen(notifier.handleSessionEvent);
  ref.onDispose(subscription.cancel);
  return notifier;
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
