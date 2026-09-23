import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/constants/app_constants.dart';
import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/features/settings/providers/theme_provider.dart';
import 'package:easypass/features/settings/screens/settings_screen.dart';
import 'package:easypass/l10n/app_localizations.dart';

import 'fakes.dart';

/// 主题设置（跟随系统 / 浅色 / 深色）的持久化回归。
///
/// 重点不是"能存能读"，而是**容错**：存储为空、值被写坏、存储本身读不出来时，
/// 启动必须落到 [ThemeMode.system] 且不抛异常 —— 主题是启动路径上的设置项，
/// 它一崩整个 app 就是白屏。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeSecureStorage storage;

  setUp(() {
    storage = FakeSecureStorage();
  });

  ProviderContainer newContainer([
    FlutterSecureStorage? overrideStorage,
  ]) {
    final container = ProviderContainer(
      overrides: [
        themeStorageProvider.overrideWithValue(overrideStorage ?? storage),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// 模拟一次启动：新 container + 新 notifier，等它读完存储再返回当前模式。
  Future<ThemeMode> loadMode([FlutterSecureStorage? overrideStorage]) async {
    final container = newContainer(overrideStorage);
    await container.read(themeModeProvider.notifier).ready;
    return container.read(themeModeProvider);
  }

  test('defaults to ThemeMode.system when storage is empty', () async {
    expect(await loadMode(), ThemeMode.system);
    expect(
      storage.store.containsKey(AppConstants.themeModeStorageKey),
      isFalse,
      reason: '默认值不应该被写回存储',
    );
  });

  test('persists light / dark and restores them on the next start', () async {
    final container = newContainer();
    final notifier = container.read(themeModeProvider.notifier);
    await notifier.ready;

    await notifier.setThemeMode(ThemeMode.dark);
    expect(
      storage.store[AppConstants.themeModeStorageKey],
      'dark',
      reason: '选择必须落盘到 themeModeStorageKey',
    );
    expect(await loadMode(), ThemeMode.dark, reason: '重启后应恢复深色');

    final restarted = newContainer();
    await restarted
        .read(themeModeProvider.notifier)
        .setThemeMode(ThemeMode.light);
    expect(await loadMode(), ThemeMode.light, reason: '重启后应恢复浅色');
  });

  test('unknown or corrupt stored values degrade to ThemeMode.system',
      () async {
    for (final garbage in ['chartreuse', '', 'LIGHT', '1', 'null', '  ']) {
      storage.store[AppConstants.themeModeStorageKey] = garbage;
      expect(
        await loadMode(),
        ThemeMode.system,
        reason: '存了 "$garbage" 也应该退回跟随系统，而不是抛异常',
      );
    }
  });

  test('a storage read failure keeps the default instead of throwing',
      () async {
    final notifier = newContainer(_ThrowingSecureStorage())
        .read(themeModeProvider.notifier);
    await notifier.ready;

    expect(await loadMode(_ThrowingSecureStorage()), ThemeMode.system);

    // 写失败同样不能抛（内存里已经切过去了）
    await notifier.setThemeMode(ThemeMode.dark);
    expect(notifier.state, ThemeMode.dark);
  });

  test('a missing platform implementation (real storage in tests) does not throw',
      () async {
    // 真机上这里是 DPAPI；单元测试环境里没有插件实现，read 会以
    // MissingPluginException 结束 —— notifier 必须吞掉它并保持跟随系统，
    // 否则 app 一启动就白屏。这里刻意**不覆盖** themeStorageProvider。
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(themeModeProvider.notifier);
    await notifier.ready;
    expect(container.read(themeModeProvider), ThemeMode.system);
  });

  test('setThemeMode notifies listeners', () async {
    final container = newContainer();
    await container.read(themeModeProvider.notifier).ready;

    final seen = <ThemeMode>[];
    final subscription = container.listen<ThemeMode>(
      themeModeProvider,
      (previous, next) => seen.add(next),
    );
    addTearDown(subscription.close);

    await container
        .read(themeModeProvider.notifier)
        .setThemeMode(ThemeMode.dark);
    await container
        .read(themeModeProvider.notifier)
        .setThemeMode(ThemeMode.system);

    expect(seen, [ThemeMode.dark, ThemeMode.system]);
    expect(container.read(themeModeProvider), ThemeMode.system);
  });

  test('storage round-trip helper maps every ThemeMode', () {
    expect(themeModeToStorageValue(ThemeMode.system), 'system');
    expect(themeModeToStorageValue(ThemeMode.light), 'light');
    expect(themeModeToStorageValue(ThemeMode.dark), 'dark');
    for (final mode in ThemeMode.values) {
      expect(themeModeFromStorageValue(themeModeToStorageValue(mode)), mode);
    }
    expect(themeModeFromStorageValue(null), ThemeMode.system);
  });

  // ─── 设置页接线 ──────────────────────────────────────────
  // provider 单测过了不代表 UI 接上了：这一条从设置页本身出发，验证
  // 「副标题显示当前选择 → 弹窗三个选项 → 选中后状态与存储都变」。
  testWidgets('settings theme row shows the current mode and switches it',
      (tester) async {
    // 最小窗口尺寸（windows/runner/win32_window.cpp 的 900×600）下跑，
    // 顺带守住"没有 RenderFlex 溢出"。
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final themeStorage = FakeSecureStorage();
    final container = ProviderContainer(
      overrides: [
        cryptoServiceProvider.overrideWithValue(
          CryptoService(secureStorage: FakeSecureStorage()),
        ),
        databaseProvider.overrideWithValue(
          AppDatabase.forTesting(NativeDatabase.memory()),
        ),
        themeStorageProvider.overrideWithValue(themeStorage),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l10n =
        AppLocalizations.of(tester.element(find.byType(SettingsScreen)));
    final themeTile = find.ancestor(
      of: find.byIcon(Icons.palette_outlined),
      matching: find.byType(ListTile),
    );

    // 默认展示"跟随系统"（语言那一行的副标题也是这个词，所以按行定位）
    expect(
      find.descendant(of: themeTile, matching: find.text(l10n.followSystem)),
      findsOneWidget,
    );

    // 主题行在 900×600 的首屏之外，先滚动到可见再点
    await tester.ensureVisible(themeTile);
    await tester.pumpAndSettle();
    await tester.tap(themeTile);
    await tester.pumpAndSettle();
    expect(find.text(l10n.themeLight), findsOneWidget);
    expect(find.text(l10n.themeDark), findsOneWidget);

    await tester.tap(find.text(l10n.themeDark));
    await tester.pumpAndSettle();
    expect(container.read(themeModeProvider), ThemeMode.dark);
    expect(themeStorage.store[AppConstants.themeModeStorageKey], 'dark');
    expect(
      find.descendant(of: themeTile, matching: find.text(l10n.themeDark)),
      findsOneWidget,
      reason: '副标题要跟着变成当前选择',
    );
    expect(tester.takeException(), isNull, reason: '900×600 下不应有溢出');
  });
}

/// 存储整个不可用（读 / 写都抛）时的降级行为：不崩、保持"跟随系统"。
class _ThrowingSecureStorage extends FakeSecureStorage {
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
    throw Exception('storage unavailable');
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
    throw Exception('storage unavailable');
  }
}
