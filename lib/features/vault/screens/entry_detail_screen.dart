import 'dart:async';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/crypto/crypto_service.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/providers/auth_provider.dart';
import '../providers/vault_provider.dart';

class EntryDetailScreen extends ConsumerWidget {
  final String entryId;

  const EntryDetailScreen({super.key, required this.entryId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entryAsync = ref.watch(selectedEntryProvider(entryId));
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.entryDetailsTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () => context.push('/vault/edit/$entryId'),
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () => _confirmDelete(context, ref),
          ),
        ],
      ),
      body: entryAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(child: Text(l10n.failedToLoadEntry)),
        data: (entry) {
          if (entry == null) {
            return Center(child: Text(l10n.entryNotFound));
          }
          return _buildEntryDetails(context, ref, entry, theme);
        },
      ),
    );
  }

  Widget _buildEntryDetails(
      BuildContext context, WidgetRef ref, PasswordEntry entry, ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(entry.name, style: theme.textTheme.headlineMedium),
              const SizedBox(height: 24),
              if (entry.username.isNotEmpty)
                _buildField(
                  context,
                  label: l10n.username,
                  value: entry.username,
                  icon: Icons.person,
                  onCopy: () {
                    Clipboard.setData(ClipboardData(text: entry.username));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.usernameCopied)),
                    );
                  },
                ),
              RevealablePasswordField(entry: entry, ref: ref),
              if (entry.url.isNotEmpty)
                _buildField(
                  context,
                  label: l10n.urlLabel,
                  value: entry.url,
                  icon: Icons.link,
                  onCopy: () {
                    Clipboard.setData(ClipboardData(text: entry.url));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.urlCopied)),
                    );
                  },
                ),
              SwitchListTile(
                title: Text(l10n.favorite),
                subtitle: Text(l10n.favoriteSubtitle),
                value: entry.isFavorite,
                onChanged: (value) async {
                  await ref.read(vaultRepositoryProvider).updateEntry(
                        entryId,
                        PasswordEntriesCompanion(
                          id: Value(entry.id),
                          name: Value(entry.name),
                          url: Value(entry.url),
                          username: Value(entry.username),
                          passwordEncrypted: Value(entry.passwordEncrypted),
                          notesEncrypted: Value(entry.notesEncrypted ?? ''),
                          totpSecretEncrypted:
                              Value(entry.totpSecretEncrypted ?? ''),
                          isFavorite: Value(value),
                          folderId: entry.folderId != null
                              ? Value(entry.folderId!)
                              : const Value.absent(),
                          createdAt: Value(entry.createdAt),
                          updatedAt:
                              Value(DateTime.now().millisecondsSinceEpoch),
                        ),
                      );
                  ref.invalidate(selectedEntryProvider(entryId));
                  ref.invalidate(vaultEntriesProvider);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(
    BuildContext context, {
    required String label,
    required String value,
    required IconData icon,
    VoidCallback? onCopy,
  }) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(child: Text(value, style: theme.textTheme.bodyLarge)),
                if (onCopy != null)
                  IconButton(
                    icon: const Icon(Icons.copy, size: 20),
                    onPressed: onCopy,
                    tooltip: l10n.copyFieldTooltip(label),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deleteEntryTitle),
        content: Text(l10n.deleteEntryDetailMessage),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.cancel)),
          FilledButton(
            onPressed: () async {
              await ref.read(vaultRepositoryProvider).deleteEntry(entryId);
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) Navigator.pop(context);
            },
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }
}

// ─── Revealable Password Field ───────────────────────────

class RevealablePasswordField extends ConsumerStatefulWidget {
  final PasswordEntry entry;
  final WidgetRef ref;

  const RevealablePasswordField({
    super.key,
    required this.entry,
    required this.ref,
  });

  @override
  ConsumerState<RevealablePasswordField> createState() =>
      _RevealablePasswordFieldState();
}

class _RevealablePasswordFieldState extends ConsumerState<RevealablePasswordField> {
  String _displayText = '••••••••••••';
  bool _isRevealed = false;
  Timer? _hideTimer;
  final _passwordController = TextEditingController();
  String? _decryptedPassword;

  @override
  void dispose() {
    _hideTimer?.cancel();
    _passwordController.dispose();
    super.dispose();
  }

  void _revealPassword() {
    final encrypted = widget.entry.passwordEncrypted;
    final key = ref.read(encryptionKeyProvider);
    String decrypted;
    try {
      decrypted = key != null ? CryptoService().decryptData(encrypted, key) : encrypted;
    } catch (_) {
      decrypted = encrypted;
    }
    setState(() {
      _decryptedPassword = decrypted;
      _displayText = decrypted;
      _isRevealed = true;
    });

    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(minutes: 1), () {
      if (mounted) {
        setState(() {
          _displayText = '••••••••••••';
          _isRevealed = false;
          _decryptedPassword = null;
        });
      }
    });
  }

  void _hidePassword() {
    _hideTimer?.cancel();
    setState(() {
      _displayText = '••••••••••••';
      _isRevealed = false;
      _decryptedPassword = null;
    });
  }

  void _verifyAndReveal() async {
    final l10n = AppLocalizations.of(context);
    final password = _passwordController.text;
    if (password.isEmpty) return;

    final storedSalt = await CryptoService().getStoredSalt();
    final storedHash = await CryptoService().getStoredPasswordHash();
    if (storedSalt == null || storedHash == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.noMasterPasswordConfigured)),
        );
      }
      return;
    }

    if (CryptoService().hashMasterPassword(password, storedSalt) == storedHash) {
      if (mounted) Navigator.pop(context);
      _revealPassword();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorIncorrectMasterPassword),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showMasterPasswordDialog() {
    final l10n = AppLocalizations.of(context);
    _passwordController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.verifyMasterPasswordTitle),
        content: TextField(
          controller: _passwordController,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l10n.masterPasswordLabel,
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.key),
          ),
          onSubmitted: (_) => _verifyAndReveal(),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.cancel)),
          FilledButton(
              onPressed: _verifyAndReveal,
              child: Text(l10n.verify)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(l10n.passwordField,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                if (_isRevealed) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange.withAlpha(50),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.orange.withAlpha(100)),
                    ),
                    child: Text(l10n.visibleAutoHide,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Colors.orange,
                              fontSize: 10,
                            )),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.lock, size: 20),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(_displayText,
                        style: Theme.of(context)
                            .textTheme
                            .bodyLarge
                            ?.copyWith(fontFamily: 'monospace'))),
                IconButton(
                  icon: const Icon(Icons.copy, size: 20),
                  onPressed: () {
                    final text = _isRevealed && _decryptedPassword != null
                        ? _decryptedPassword!
                        : _displayText;
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.passwordCopiedShort)),
                    );
                  },
                  tooltip: l10n.copyPasswordTooltip,
                ),
                IconButton(
                  icon: Icon(_isRevealed ? Icons.visibility_off : Icons.visibility,
                      size: 20),
                  onPressed:
                      _isRevealed ? _hidePassword : _showMasterPasswordDialog,
                  tooltip: _isRevealed
                      ? l10n.hidePasswordTooltip
                      : l10n.revealPasswordTooltip,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
