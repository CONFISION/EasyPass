import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/auth/screens/lock_screen.dart';
import 'features/auth/screens/set_master_password_screen.dart';
import 'features/auth/providers/auth_provider.dart';
import 'features/vault/screens/vault_screen.dart';
import 'features/vault/screens/add_edit_entry_screen.dart';
import 'features/vault/screens/entry_detail_screen.dart';
import 'features/generator/screens/generator_screen.dart';
import 'features/settings/screens/settings_screen.dart';

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

      // Unlocked but on lock/set-password pages: go to vault
      if (!isFirstRun && !isLocked && (isOnLock || isOnSetPassword)) return '/vault';

      return null;
    },
    routes: [
      GoRoute(
        path: '/lock',
        builder: (context, state) => const LockScreen(),
      ),
      GoRoute(
        path: '/set-master-password',
        builder: (context, state) => const SetMasterPasswordScreen(),
      ),
      GoRoute(
        path: '/vault',
        builder: (context, state) => const VaultScreen(),
      ),
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

    return MaterialApp.router(
      title: 'EasyPass',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A73E8),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A73E8),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      themeMode: ThemeMode.system,
      routerConfig: router,
    );
  }
}