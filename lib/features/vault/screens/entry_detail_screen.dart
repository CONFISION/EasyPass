import 'dart:async';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/crypto/crypto_service.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../auth/providers/auth_provider.dart';
import '../providers/vault_provider.dart';

class EntryDetailScreen extends ConsumerWidget {
  final String entryId;

  const EntryDetailScreen({super.key, required this.entryId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entryAsync = ref.watch(selectedEntryProvider(entryId));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Entry Details'),
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
        error: (_, _) => const Center(child: Text('Failed to load entry')),
        data: (entry) {
          if (entry == null) {
            return const Center(child: Text('Entry not found'));
          }
          return _buildEntryDetails(context, ref, entry, theme);
        },
      ),
    );
  }

  Widget _buildEntryDetails(
      BuildContext context, WidgetRef ref, PasswordEntry entry, ThemeData theme) {
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
                  label: 'Username',
                  value: entry.username,
                  icon: Icons.person,
                  onCopy: () {
                    Clipboard.setData(ClipboardData(text: entry.username));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Username copied')),
                    );
                  },
                ),
              RevealablePasswordField(entry: entry, ref: ref),
              if (entry.url.isNotEmpty)
                _buildField(
                  context,
                  label: 'URL',
                  value: entry.url,
                  icon: Icons.link,
                  onCopy: () {
                    Clipboard.setData(ClipboardData(text: entry.url));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('URL copied')),
                    );
                  },
                ),
              SwitchListTile(
                title: const Text('Favorite'),
                subtitle: const Text('Mark this entry as favorite'),
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
                          totpSecretEncrypted: Value(entry.totpSecretEncrypted ?? ''),
                          isFavorite: Value(value),
                          folderId: entry.folderId != null
                              ? Value(entry.folderId!)
                              : const Value.absent(),
                          createdAt: Value(entry.createdAt),
                          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
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
                    tooltip: 'Copy $label',
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Entry'),
        content: const Text(
            'Are you sure you want to delete this entry? This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              await ref.read(vaultRepositoryProvider).deleteEntry(entryId);
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) Navigator.pop(context);
            },
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Delete'),
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
    final password = _passwordController.text;
    if (password.isEmpty) return;

    final storedSalt = await CryptoService().getStoredSalt();
    final storedHash = await CryptoService().getStoredPasswordHash();
    if (storedSalt == null || storedHash == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No master password configured')),
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
          const SnackBar(
            content: Text('Incorrect master password'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showMasterPasswordDialog() {
    _passwordController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Verify Master Password'),
        content: TextField(
          controller: _passwordController,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Master Password',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.key),
          ),
          onSubmitted: (_) => _verifyAndReveal(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: _verifyAndReveal, child: const Text('Verify')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Password',
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
                    child: Text('Visible • Auto-hides in 1 min',
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
                      const SnackBar(content: Text('Password copied')),
                    );
                  },
                  tooltip: 'Copy password',
                ),
                IconButton(
                  icon: Icon(_isRevealed ? Icons.visibility_off : Icons.visibility,
                      size: 20),
                  onPressed:
                      _isRevealed ? _hidePassword : _showMasterPasswordDialog,
                  tooltip: _isRevealed ? 'Hide password' : 'Reveal password',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}