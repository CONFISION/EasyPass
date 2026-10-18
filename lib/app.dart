import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/constants/app_constants.dart';
import 'features/auth/screens/lock_screen.dart';
import 'features/auth/screens/set_master_password_screen.dart';
import 'features/auth/providers/auth_provider.dart';
import 'features/desktop_autostart/desktop_autostart.dart';
import 'features/generator/screens/generator_screen.dart';
import 'features/health/screens/health_screen.dart';
import 'features/settings/providers/font_settings_provider.dart';
import 'features/settings/providers/theme_provider.dart';
import 'features/settings/screens/settings_screen.dart';
import 'features/vault/screens/add_edit_entry_screen.dart';
import 'features/vault/screens/entry_detail_screen.dart';
import 'features/vault/screens/vault_screen.dart';
import 'l10n/app_localizations.dart';

/// Selected UI locale; `null` follows the system language.
final localeProvider = StateProvider<Locale?>((ref) => null);

/// Autostart coordinator (Windows: managed by the installer, so the settings
/// toggle reports `unsupported`).
final autostartCoordinatorProvider = Provider<AutostartCoordinator>(
  (ref) => const AutostartCoordinator(),
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

/// 用户活动 → 核心会话续期。
///
/// 空闲锁定的权威在**核心**（`SessionDomains`）：UI 只负责把"用户还在动"
/// 告诉它。没有这一层，用户停在"不读数据"的页面（生成器、设置页）时，
/// 核心会在用户正在操作时把库锁掉。
///
/// 节流到 20 秒一次：远小于最短的自动锁定时间（1 分钟），又不会让每次
/// 指针移动都发一个请求。
class _ActivityTouchHost extends ConsumerStatefulWidget {
  const _ActivityTouchHost({required this.child});

  final Widget child;

  @override
  ConsumerState<_ActivityTouchHost> createState() => _ActivityTouchHostState();
}

class _ActivityTouchHostState extends ConsumerState<_ActivityTouchHost> {
  static const Duration _minInterval = Duration(seconds: 20);

  DateTime _lastTouch = DateTime.fromMillisecondsSinceEpoch(0);

  void _touch() {
    final now = DateTime.now();
    if (now.difference(_lastTouch) < _minInterval) return;
    _lastTouch = now;
    // 失败无所谓：核心没起来时，下一次真实动作会触发重连/拉起。
    unawaited(ref.read(authProvider.notifier).touchActivity());
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _touch(),
      onPointerMove: (_) => _touch(),
      child: widget.child,
    );
  }
}

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
      // 首次启动的浏览器集成提示与"二次启动抬窗"监听都只服务于 Linux 移植版，
      // 本分支已移除（见 `linux` 分支）；Windows 的宿主注册由安装器负责、单实例由
      // 原生 Mutex 闸门负责，UI 侧不需要再挂任何 Host。
      builder: (context, child) =>
          _ActivityTouchHost(child: child ?? const SizedBox.shrink()),
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
