import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/client/api_providers.dart';
import 'package:easypass/client/vault_api.dart';
import 'package:easypass/core/constants/app_constants.dart';
import 'package:easypass/features/auth/providers/auth_provider.dart';
import 'package:easypass/protocol/protocol.dart';

import 'fake_vault_api.dart';
import 'fakes.dart';

/// 认证状态机（`AuthNotifier`）的回归。
///
/// M4 之后 **UI 只是核心的客户端**：
/// * 会话状态、校验、原子轮换、空闲锁定全在核心里；
/// * UI 负责把核心的状态翻成 `AuthStatus`、把错误码翻成 `AuthErrorCodes`；
/// * 迁移期多一件事：核心还没有校验材料时，把旧钥匙串里的 salt/hash 交上去。
///
/// 所以这里的依赖全部是**假的 `VaultApi`**（`test/fake_vault_api.dart`），
/// 不再有内存 drift 库、不再有 `encryptionKeyProvider`。
/// 真实轮换语义的回归在 `test/change_password_then_lock_test.dart`（打核心）。
void main() {
  late FakeVaultApi api;
  late FakeSecureStorage legacyStore;
  late ProviderContainer container;

  ProviderContainer buildContainer() {
    container = ProviderContainer(
      overrides: [
        vaultApiProvider.overrideWithValue(api),
        legacySecretStoreProvider.overrideWithValue(legacyStore),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    api = FakeVaultApi(masterPassword: 'password123');
    legacyStore = FakeSecureStorage();
  });

  tearDown(() => api.dispose());

  /// 等启动探测落地（`AuthNotifier` 在构造函数里就发起它）。
  Future<void> waitForAuth() async {
    for (var i = 0; i < 50; i++) {
      if (!container.read(authProvider).isLoading) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('启动探测没有在预期时间内落地');
  }

  /// 把"旧版把校验材料放在系统钥匙串里"这个升级现场摆出来。
  void seedLegacyKeychain({String salt = 'LEGACY-SALT', String hash = 'LEGACY-HASH'}) {
    legacyStore.store['${AppConstants.secureStorageKey}_salt'] = salt;
    legacyStore.store[AppConstants.masterPasswordHashKey] = hash;
  }

  // ─── 启动探测 ──────────────────────────────────────────

  group('启动探测：状态来自核心，迁移只做一次', () {
    test('核心有校验材料 ⇒ locked，自动锁定分钟数取自核心', () async {
      api = FakeVaultApi(masterPassword: 'password123', autoLockMinutes: 30);
      buildContainer();
      await waitForAuth();

      final state = container.read(authProvider);
      expect(state.isLocked, isTrue);
      expect(state.autoLockMinutes, 30);
      expect(state.errorMessage, isNull);
      expect(api.called('adoptLegacyKeyMaterial'), isFalse,
          reason: '核心已有材料时不该去读旧钥匙串');
    });

    test('核心已经解锁 ⇒ unlocked（UI 不自己假设状态）', () async {
      api = FakeVaultApi(
        masterPassword: 'password123',
        initialStatus: 'unlocked',
      );
      api.forceStatus('unlocked', remainingSeconds: 300);
      buildContainer();
      await waitForAuth();

      final state = container.read(authProvider);
      expect(state.status, AuthStatus.unlocked);
      expect(state.remainingSeconds, 300,
          reason: '剩余秒数只能来自 authSnapshot()');
    });

    test('核心无材料、旧钥匙串也空 ⇒ firstRun', () async {
      api = FakeVaultApi(hasAuthMaterial: false, initialStatus: 'firstRun');
      buildContainer();
      await waitForAuth();

      final state = container.read(authProvider);
      expect(state.isFirstRun, isTrue);
      expect(state.errorMessage, isNull);
      expect(api.called('adoptLegacyKeyMaterial'), isFalse);
    });

    test('升级迁移：旧钥匙串里有 salt+hash ⇒ 交给核心并进入 locked', () async {
      api = FakeVaultApi(hasAuthMaterial: false, initialStatus: 'firstRun');
      seedLegacyKeychain();
      buildContainer();
      await waitForAuth();

      final state = container.read(authProvider);
      expect(state.isLocked, isTrue,
          reason: '迁移完成后库是"有材料但未解锁"，不是 firstRun');
      expect(state.isFirstRun, isFalse);
      expect(state.errorMessage, isNull);

      expect(api.adoptedSalt, 'LEGACY-SALT');
      expect(api.adoptedPasswordHash, 'LEGACY-HASH');
      expect(api.called('adoptLegacyKeyMaterial'), isTrue);
    });

    test('只有一半旧材料（缺哈希）⇒ firstRun，不发起迁移', () async {
      api = FakeVaultApi(hasAuthMaterial: false, initialStatus: 'firstRun');
      legacyStore.store['${AppConstants.secureStorageKey}_salt'] = 'ONLY-SALT';
      buildContainer();
      await waitForAuth();

      expect(container.read(authProvider).isFirstRun, isTrue);
      expect(api.called('adoptLegacyKeyMaterial'), isFalse);
    });

    test('迁移被核心拒绝 ⇒ 报 storageUnavailable，绝不谎报 firstRun', () async {
      // 谎报 firstRun 的后果：用户会去"重新设置主密码"，而整库密文还在旧钥匙下
      // —— 那是真正会毁数据的路径。
      api = FakeVaultApi(hasAuthMaterial: false, initialStatus: 'firstRun');
      api.adoptLegacyKeyMaterialFailure = VaultApiException(
        ErrorCodes.invalidRequest,
        '校验材料已存在，拒绝覆盖',
      );
      seedLegacyKeychain();
      buildContainer();
      await waitForAuth();

      final state = container.read(authProvider);
      expect(state.isFirstRun, isFalse);
      expect(state.isLocked, isTrue);
      expect(state.errorMessage, AuthErrorCodes.storageUnavailable);
    });

    test('核心连不上 ⇒ storageUnavailable + 锁定（不误判 firstRun）', () async {
      api = FakeVaultApi(hasAuthMaterial: false, initialStatus: 'firstRun');
      api.authSnapshotFailure = VaultApiException(
        ErrorCodes.unsupported,
        '核心服务未运行，且找不到核心可执行文件（easypass_core）',
      );
      buildContainer();
      await waitForAuth();

      final state = container.read(authProvider);
      expect(state.isLocked, isTrue);
      expect(state.isFirstRun, isFalse);
      expect(state.errorMessage, AuthErrorCodes.storageUnavailable);
    });

    test('旧钥匙串读不出来 ⇒ storageUnavailable（保留重试语义）', () async {
      api = FakeVaultApi(hasAuthMaterial: false, initialStatus: 'firstRun');
      legacyStore.readFailure = StateError('keyring locked');
      buildContainer();
      await waitForAuth();

      expect(
        container.read(authProvider).errorMessage,
        AuthErrorCodes.storageUnavailable,
      );
    });

    test('retryInitialState 在环境恢复后清掉横幅', () async {
      api = FakeVaultApi(hasAuthMaterial: false, initialStatus: 'firstRun');
      legacyStore.readFailure = StateError('keyring locked');
      buildContainer();
      await waitForAuth();
      expect(
        container.read(authProvider).errorMessage,
        AuthErrorCodes.storageUnavailable,
      );

      // 钥匙串恢复 + 核心仍是"没材料"⇒ 真的首次运行。
      legacyStore.readFailure = null;
      await container.read(authProvider.notifier).retryInitialState();

      final state = container.read(authProvider);
      expect(state.errorMessage, isNull);
      expect(state.isFirstRun, isTrue);
    });
  });

  // ─── 解锁 ──────────────────────────────────────────────

  group('unlock', () {
    test('成功 ⇒ unlocked、错误清空、剩余秒数来自核心', () async {
      buildContainer();
      await waitForAuth();

      final ok = await container.read(authProvider.notifier).unlock(
            'password123',
          );

      expect(ok, isTrue);
      final state = container.read(authProvider);
      expect(state.status, AuthStatus.unlocked);
      expect(state.errorMessage, isNull);
      expect(state.remainingSeconds, 5 * 60);
      expect(api.called('unlock'), isTrue);
      expect(api.isUnlocked, isTrue);
    });

    test('密码错 ⇒ locked + incorrectMasterPassword', () async {
      buildContainer();
      await waitForAuth();

      final ok = await container.read(authProvider.notifier).unlock('wrong');

      expect(ok, isFalse);
      final state = container.read(authProvider);
      expect(state.isLocked, isTrue);
      expect(state.errorMessage, AuthErrorCodes.incorrectMasterPassword);
    });

    test('核心要求"改用新密码" ⇒ useNewMasterPassword', () async {
      buildContainer();
      await waitForAuth();

      api.unlockFailure = VaultApiException(
        ErrorCodes.unauthorized,
        '请改用新的主密码',
      );
      final ok = await container.read(authProvider.notifier).unlock('old');

      expect(ok, isFalse);
      expect(
        container.read(authProvider).errorMessage,
        AuthErrorCodes.useNewMasterPassword,
      );
    });

    test('核心说还没迁移（needsKeyMigration）⇒ noMasterPassword', () async {
      api = FakeVaultApi(hasAuthMaterial: false, initialStatus: 'locked');
      buildContainer();
      await waitForAuth();

      final ok = await container.read(authProvider.notifier).unlock('whatever');

      expect(ok, isFalse);
      expect(
        container.read(authProvider).errorMessage,
        AuthErrorCodes.noMasterPassword,
      );
    });

    test('storageUnavailable 时点解锁：横幅不被抹掉，也不假装在加载', () async {
      api.authSnapshotFailure = StateError('core down');
      buildContainer();
      await waitForAuth();
      expect(
        container.read(authProvider).errorMessage,
        AuthErrorCodes.storageUnavailable,
      );

      final tapped = await container.read(authProvider.notifier).unlock('x');

      expect(tapped, isFalse);
      final state = container.read(authProvider);
      expect(state.errorMessage, AuthErrorCodes.storageUnavailable);
      expect(state.isLoading, isFalse);
      expect(api.called('unlock'), isFalse,
          reason: '存储不可用时不该把请求发出去');
    });

    test('解锁成功后快照失败 ⇒ 仍然是解锁态（不产生假阴性）', () async {
      buildContainer();
      await waitForAuth();

      // 第 1 次快照是启动探测；让解锁之后那次（第 2 次）失败 —— 模拟连接抖一下。
      api.authSnapshotFailFromCall = 2;

      final ok = await container.read(authProvider.notifier).unlock(
            'password123',
          );

      expect(ok, isTrue, reason: '解锁已经成功，不能因为随后取快照失败就报失败');
      final state = container.read(authProvider);
      expect(state.status, AuthStatus.unlocked);
      expect(state.errorMessage, isNull);
      expect(state.remainingSeconds, isNull, reason: '取不到快照时剩余时间留空');
    });
  });

  // ─── 首次设置主密码 ────────────────────────────────────

  group('setMasterPassword', () {
    test('成功 ⇒ unlocked（核心设置成功即解锁本次会话）', () async {
      api = FakeVaultApi(hasAuthMaterial: false, initialStatus: 'firstRun');
      buildContainer();
      await waitForAuth();

      final ok = await container
          .read(authProvider.notifier)
          .setMasterPassword('password123', 'password123');

      expect(ok, isTrue);
      expect(container.read(authProvider).status, AuthStatus.unlocked);
      expect(api.called('setMasterPassword'), isTrue);
      expect(api.masterPassword, 'password123');
    });

    test('两次输入不一致 ⇒ passwordsDoNotMatch，且不打扰核心', () async {
      api = FakeVaultApi(hasAuthMaterial: false, initialStatus: 'firstRun');
      buildContainer();
      await waitForAuth();

      final ok = await container
          .read(authProvider.notifier)
          .setMasterPassword('password123', 'different123');

      expect(ok, isFalse);
      final state = container.read(authProvider);
      expect(state.errorMessage, AuthErrorCodes.passwordsDoNotMatch);
      expect(state.isFirstRun, isTrue);
      expect(api.called('setMasterPassword'), isFalse);
    });

    test('太短 ⇒ passwordTooShort，且不打扰核心', () async {
      api = FakeVaultApi(hasAuthMaterial: false, initialStatus: 'firstRun');
      buildContainer();
      await waitForAuth();

      final ok = await container
          .read(authProvider.notifier)
          .setMasterPassword('short', 'short');

      expect(ok, isFalse);
      expect(
        container.read(authProvider).errorMessage,
        AuthErrorCodes.passwordTooShort,
      );
      expect(api.called('setMasterPassword'), isFalse);
    });

    test('核心写不进去 ⇒ failedToSave，状态留在 firstRun', () async {
      api = FakeVaultApi(hasAuthMaterial: false, initialStatus: 'firstRun');
      api.setMasterPasswordFailure = VaultApiException(
        ErrorCodes.storageError,
        '存储读写失败',
      );
      buildContainer();
      await waitForAuth();

      final ok = await container
          .read(authProvider.notifier)
          .setMasterPassword('password123', 'password123');

      expect(ok, isFalse);
      final state = container.read(authProvider);
      expect(state.errorMessage, AuthErrorCodes.failedToSave);
      expect(state.isFirstRun, isTrue);
    });
  });

  // ─── 改主密码 ──────────────────────────────────────────

  group('changeMasterPassword', () {
    test('成功后必须回到锁定态，且不留错误提示（回归）', () async {
      api = FakeVaultApi(masterPassword: 'old-password');
      buildContainer();
      await waitForAuth();
      expect(await container.read(authProvider.notifier).unlock('old-password'),
          isTrue);

      final changed = await container
          .read(authProvider.notifier)
          .changeMasterPassword('old-password', 'new-password', 'new-password');

      expect(changed, isTrue);
      final state = container.read(authProvider);
      expect(state.status, AuthStatus.locked,
          reason: '改完主密码必须回到锁定态，让用户用新密码重新进来');
      expect(state.errorMessage, isNull);
      expect(state.remainingSeconds, isNull);
      expect(api.called('changeMasterPassword'), isTrue);
      expect(api.masterPassword, 'new-password');
    });

    test('即使核心没有把会话锁上，UI 也要回到锁定态', () async {
      api = FakeVaultApi(masterPassword: 'old-password');
      api.lockOnChangeMasterPassword = false;
      buildContainer();
      await waitForAuth();

      await container
          .read(authProvider.notifier)
          .changeMasterPassword('old-password', 'new-password', 'new-password');

      expect(container.read(authProvider).status, AuthStatus.locked);
    });

    test('轮换成功但校验材料没落盘 ⇒ 提示 masterPasswordChangedStorageWarning', () async {
      // 这是 3.0.0 之前不可达的那条文案：核心现在通过
      // ChangePasswordResult.keyMaterialPersisted 告诉我们写入失败了。
      // 轮换本身仍然有效（日志是权威），但用户必须知道"这次没写进去"。
      api = FakeVaultApi(masterPassword: 'old-password');
      api.keyMaterialPersistedOnChange = false;
      buildContainer();
      await waitForAuth();
      await container.read(authProvider.notifier).unlock('old-password');

      final changed = await container
          .read(authProvider.notifier)
          .changeMasterPassword('old-password', 'new-password', 'new-password');

      expect(changed, isTrue, reason: '轮换是成功的，只是材料没落盘');
      final state = container.read(authProvider);
      expect(state.status, AuthStatus.locked);
      expect(
        state.errorMessage,
        AuthErrorCodes.masterPasswordChangedStorageWarning,
        reason: '写入失败必须提示，不能悄悄吞掉',
      );
    });

    test('当前密码错 ⇒ currentPasswordIncorrect', () async {
      api = FakeVaultApi(masterPassword: 'old-password');
      buildContainer();
      await waitForAuth();

      final changed = await container
          .read(authProvider.notifier)
          .changeMasterPassword('wrong', 'new-password', 'new-password');

      expect(changed, isFalse);
      expect(
        container.read(authProvider).errorMessage,
        AuthErrorCodes.currentPasswordIncorrect,
      );
    });

    test('两次输入不一致 / 太短：本地拦下，不发给核心', () async {
      api = FakeVaultApi(masterPassword: 'old-password');
      buildContainer();
      await waitForAuth();
      final notifier = container.read(authProvider.notifier);

      expect(
        await notifier.changeMasterPassword('old-password', 'new-password', 'x'),
        isFalse,
      );
      expect(
        container.read(authProvider).errorMessage,
        AuthErrorCodes.passwordsDoNotMatch,
      );

      expect(
        await notifier.changeMasterPassword('old-password', 'short', 'short'),
        isFalse,
      );
      expect(
        container.read(authProvider).errorMessage,
        AuthErrorCodes.passwordTooShort,
      );

      expect(api.called('changeMasterPassword'), isFalse);
    });

    test('核心轮换失败 ⇒ failedToChange', () async {
      api = FakeVaultApi(masterPassword: 'old-password');
      api.changeMasterPasswordFailure = VaultApiException(
        ErrorCodes.storageError,
        '存储读写失败',
      );
      buildContainer();
      await waitForAuth();

      final changed = await container
          .read(authProvider.notifier)
          .changeMasterPassword('old-password', 'new-password', 'new-password');

      expect(changed, isFalse);
      expect(
        container.read(authProvider).errorMessage,
        AuthErrorCodes.failedToChange,
      );
    });
  });

  // ─── 自动锁定 / 锁定 ───────────────────────────────────

  group('自动锁定设置与锁定', () {
    test('setAutoLockMinutes 成功 ⇒ 状态与核心一致', () async {
      buildContainer();
      await waitForAuth();
      expect(container.read(authProvider).autoLockMinutes, 5);

      await container.read(authProvider.notifier).setAutoLockMinutes(30);

      expect(container.read(authProvider).autoLockMinutes, 30);
      expect(api.autoLockMinutes, 30);
    });

    test('超范围的值按 1..60 夹取后再交给核心', () async {
      buildContainer();
      await waitForAuth();

      await container.read(authProvider.notifier).setAutoLockMinutes(999);

      expect(api.autoLockMinutes, 60);
      expect(container.read(authProvider).autoLockMinutes, 60);
    });

    test('核心没保存成功 ⇒ 不谎报成功：failedToSaveSettings + 抛回', () async {
      api.setAutoLockMinutesFailure = VaultApiException(
        ErrorCodes.storageError,
        '存储读写失败',
      );
      buildContainer();
      await waitForAuth();

      await expectLater(
        container.read(authProvider.notifier).setAutoLockMinutes(30),
        throwsA(isA<VaultApiException>()),
      );

      final state = container.read(authProvider);
      expect(state.errorMessage, AuthErrorCodes.failedToSaveSettings);
      expect(state.autoLockMinutes, 5, reason: '没落盘的设置不许发布出去');
    });

    test('lock ⇒ 核心收到锁定请求，UI 状态回到 locked', () async {
      api = FakeVaultApi(masterPassword: 'password123', initialStatus: 'unlocked');
      buildContainer();
      await waitForAuth();
      expect(container.read(authProvider).isLocked, isFalse);

      await container.read(authProvider.notifier).lock();

      expect(api.called('lock'), isTrue);
      final state = container.read(authProvider);
      expect(state.isLocked, isTrue);
      expect(state.remainingSeconds, isNull);
    });

    test('核心拒绝锁定请求时，UI 仍然置为锁定态（fail-safe）', () async {
      api = FakeVaultApi(masterPassword: 'password123', initialStatus: 'unlocked');
      api.lockFailure = VaultApiException(ErrorCodes.internal, '核心内部错误');
      buildContainer();
      await waitForAuth();

      await container.read(authProvider.notifier).lock();

      expect(container.read(authProvider).isLocked, isTrue);
    });

    test('refreshSnapshot 同步核心的剩余秒数（核心空闲超时把自己锁了）', () async {
      api = FakeVaultApi(masterPassword: 'password123', initialStatus: 'unlocked');
      buildContainer();
      await waitForAuth();
      expect(container.read(authProvider).isLocked, isFalse);

      // 核心侧空闲超时：状态翻转，UI 一刷新就跟上。
      api.forceStatus('locked');
      await container.read(authProvider.notifier).refreshSnapshot();

      final state = container.read(authProvider);
      expect(state.isLocked, isTrue);
      expect(state.remainingSeconds, isNull);
    });
  });
}
