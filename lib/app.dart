import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/constants/app_constants.dart';
import 'features/auth/screens/lock_screen.dart';
import 'features/auth/screens/set_master_password_screen.dart';
import 'features/auth/providers/auth_provider.dart';
import 'features/desktop_autostart/desktop_autostart.dart';
import 'features/desktop_single_instance/single_instance_backend.dart';
import 'features/desktop_single_instance/single_instance_raise_host.dart';
import 'features/generator/screens/generator_screen.dart';
import 'features/health/screens/health_screen.dart';
import 'features/settings/providers/font_settings_provider.dart';
import 'features/settings/providers/theme_provider.dart';
import 'features/settings/screens/settings_screen.dart';
import 'features/browser_bridge/browser_host_prompt.dart';
import 'features/vault/screens/add_edit_entry_screen.dart';
import 'features/vault/screens/entry_detail_screen.dart';
import 'features/vault/screens/vault_screen.dart';
import 'l10n/app_localizations.dart';

/// Selected UI locale; `null` follows the system language.
final localeProvider = StateProvider<Locale?>((ref) => null);

/// Single-instance backend: `null` on non-Linux platforms (or when the
/// primary instance check failed and the process should exit, but `main.dart`
/// already `exit(0)`s in that branch before reaching `runApp`).
final singleInstanceBackendProvider = Provider<SingleInstanceBackend?>((ref) => null);

/// Autostart coordinator (Linux only).
final autostartCoordinatorProvider = Provider<LinuxAutostartCoordinator>(
  (ref) => LinuxAutostartCoordinator(),
);

final _routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authProvider);

  return GoRouter(
    initialLocation: authState.isLocked ? '/lock' : '/vault',
    redirect: (context, state) {
      final currentAuth = ref.read(authProvider);
      final isLocked = currentAuth.isLocked;
      final isFirstRun = currentAuth.isFirstRun;
      final isLoading = currentAuth.isLoading;
      final isOnLock = state.matchedLocation == '/lock';
      final isOnSetPassword = state.matchedLocation == '/set-master-password';

      // Still determining auth state
      if (isLoading) return null;

      // First run: must set master password
      if (isFirstRun && !isOnSetPassword) return '/set-master-password';

      // Not first run and locked: must unlock
      if (!isFirstRun && isLocked && !isOnLock) return '/lock';

      // Unlocked but on lock/set-password pages: go to the vault
      if (!isFirstRun && !isLocked && (isOnLock || isOnSetPassword)) {
        return '/vault';
      }

      return null;
    },
    routes: [
      GoRoute(path: '/lock', builder: (context, state) => const LockScreen()),
      GoRoute(
        path: '/set-master-password',
        builder: (context, state) => const SetMasterPasswordScreen(),
      ),
      GoRoute(path: '/vault', builder: (context, state) => const VaultScreen()),
      GoRoute(
        path: '/vault/add',
        builder: (context, state) => const AddEditEntryScreen(),
      ),
      GoRoute(
        path: '/vault/edit/:id',
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          return AddEditEntryScreen(entryId: id);
        },
      ),
      GoRoute(
        path: '/vault/entry/:id',
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          return EntryDetailScreen(entryId: id);
        },
      ),
      GoRoute(
        path: '/generator',
        builder: (context, state) => const GeneratorScreen(),
      ),
      GoRoute(
        path: '/health',
        builder: (context, state) => const HealthScreen(),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
    ],
  );
});

class EasyPassApp extends ConsumerWidget {
  const EasyPassApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(_routerProvider);
    final locale = ref.watch(localeProvider);
    final fontSetting = ref.watch(fontFamilyProvider);
    final fontFamily = _resolveFontFamily(fontSetting.valueOrNull);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'EasyPass',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A73E8),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: fontFamily,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A73E8),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: fontFamily,
      ),
      themeMode: themeMode,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
      // 首次启动的浏览器集成提示（方案 B：不做设置页 UI，只提示一次）。
      builder: (context, child) => BrowserHostPromptHost(
        // 单实例：UI 准备好后启动 raise 监听，让二次启动的进程能把窗口
        // 唤到前台。该 Host 是 ConsumerStatefulWidget，只在主实例上挂 handler
        // （backend 非 null）；非 Linux / 没有 backend 时是空操作。
        child: SingleInstanceRaiseHost(child: child ?? const SizedBox.shrink()),
      ),
    );
  }

  /// Resolve the user's font setting into a `fontFamily` value:
  /// `null` falls back to the bundled [AppConstants.defaultFontFamily],
  /// the special `system` option maps to `null` (platform default), and
  /// any other value (including `monospace` or a custom family name) is
  /// passed through to the text engine.
  static String? _resolveFontFamily(String? setting) {
    if (setting == null || setting.isEmpty) {
      return AppConstants.defaultFontFamily;
    }
    if (setting == AppConstants.systemFontOption) {
      return null;
    }
    return setting;
  }
}
