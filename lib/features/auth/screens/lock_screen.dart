import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../providers/auth_provider.dart';

class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    setState(() => _isLoading = true);

    final success = await ref
        .read(authProvider.notifier)
        .unlock(_passwordController.text);

    if (mounted) {
      setState(() => _isLoading = false);
      if (!success) {
        _passwordController.clear();
      }
    }
  }

  Future<void> _retryStorage() async {
    setState(() => _isLoading = true);
    try {
      await ref.read(authProvider.notifier).retryInitialState();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _exitApp() {
    // Closing the only window on Linux GTK ends the process; on Windows the
    // runner main.cpp handles WM_CLOSE the same way. Using [exit] is the
    // last-resort path explicitly requested by the "secure storage
    // unavailable" recovery UI: the user has acknowledged that no recovery
    // is possible in this session, and there is nothing left for the app
    // to do but terminate.
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final l10n = AppLocalizations.of(context);
    final errorMessage = authErrorMessage(l10n, authState.errorMessage);
    final theme = Theme.of(context);

    // Secure storage is genuinely unavailable (Linux keyring down, etc.):
    // the user cannot create or verify a master password, so the form is
    // not just useless, it would silently destroy state if a tap happened
    // to look successful. Replace the form with a recovery panel.
    if (authState.errorMessage == AuthErrorCodes.storageUnavailable) {
      return _StorageUnavailableScreen(
        l10n: l10n,
        theme: theme,
        isLoading: _isLoading,
        onRetry: _retryStorage,
        onExit: _exitApp,
      );
    }

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo / Icon
                Icon(
                  Icons.lock_outline,
                  size: 80,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.appTitle,
                  style: theme.textTheme.headlineLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.unlockScreenSubtitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 32),

                // Password Field
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  autofocus: true,
                  enabled: !_isLoading,
                  onSubmitted: (_) => _unlock(),
                  decoration: InputDecoration(
                    labelText: l10n.masterPasswordLabel,
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.key),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                      onPressed: () {
                        setState(() => _obscurePassword = !_obscurePassword);
                      },
                    ),
                    errorText: errorMessage,
                  ),
                ),
                const SizedBox(height: 24),

                // Unlock Button
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: _isLoading ? null : _unlock,
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(l10n.unlock),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when secure storage is unreachable. Deliberately omits the unlock
/// form (it cannot succeed) and gives the user two concrete next steps:
/// retry the probe, or give up and exit. Without this, a Linux user with a
/// locked Secret Service is left with a working-looking form that silently
/// no-ops.
class _StorageUnavailableScreen extends StatelessWidget {
  const _StorageUnavailableScreen({
    required this.l10n,
    required this.theme,
    required this.isLoading,
    required this.onRetry,
    required this.onExit,
  });

  final AppLocalizations l10n;
  final ThemeData theme;
  final bool isLoading;
  final VoidCallback onRetry;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 80,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    l10n.storageUnavailableTitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.storageUnavailableBody,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton.icon(
                      onPressed: isLoading ? null : onRetry,
                      icon: isLoading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.refresh),
                      label: Text(l10n.retry),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: isLoading ? null : onExit,
                      icon: const Icon(Icons.power_settings_new),
                      label: Text(l10n.exit),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
