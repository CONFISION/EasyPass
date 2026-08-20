import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_provider.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/export_import_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final autoLockMinutes = ref.watch(authProvider).autoLockMinutes;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              children: [
                _buildSectionHeader(context, 'Security'),
                ListTile(
                  leading: const Icon(Icons.lock_reset),
                  title: const Text('Change Master Password'),
                  subtitle: const Text('Re-encrypts all entries with a new key'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _changeMasterPassword(context, ref),
                ),
                ListTile(
                  leading: const Icon(Icons.timer),
                  title: const Text('Auto-lock Timeout'),
                  subtitle: Text('$autoLockMinutes minutes'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _pickAutoLockTimeout(context, ref),
                ),
                ListTile(
                  leading: const Icon(Icons.fingerprint),
                  title: const Text('Biometric Unlock'),
                  subtitle: const Text('Use fingerprint to unlock'),
                  trailing: Switch(
                    value: false,
                    onChanged: (value) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text(
                                'Biometric unlock coming in a future update')),
                      );
                    },
                  ),
                ),
                const Divider(),
                _buildSectionHeader(context, 'Data'),
                ListTile(
                  leading: const Icon(Icons.upload_file),
                  title: const Text('Export Vault'),
                  subtitle: const Text('Encrypted backup or plain JSON'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _exportVault(context, ref),
                ),
                ListTile(
                  leading: const Icon(Icons.download),
                  title: const Text('Import Vault'),
                  subtitle: const Text('Restore from a backup or JSON file'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _importVault(context, ref),
                ),
                const Divider(),
                _buildSectionHeader(context, 'Danger Zone',
                    color: theme.colorScheme.error),
                ListTile(
                  leading: Icon(Icons.delete_forever, color: theme.colorScheme.error),
                  title: Text('Delete All Data',
                      style: TextStyle(color: theme.colorScheme.error)),
                  subtitle: const Text('This action cannot be undone'),
                  onTap: () => _confirmDeleteAll(context, ref),
                ),
                const Divider(),
                _buildSectionHeader(context, 'About'),
                const ListTile(
                  leading: Icon(Icons.info),
                  title: Text('Version'),
                  subtitle: Text('1.0.0'),
                ),
                const ListTile(
                  leading: Icon(Icons.code),
                  title: Text('EasyPass'),
                  subtitle: Text('A secure password manager'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title,
      {Color? color}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: color ?? theme.colorScheme.primary,
        ),
      ),
    );
  }

  // ─── Export ─────────────────────────────────────────────

  void _exportVault(BuildContext context, WidgetRef ref) async {
    final format = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Export Vault'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'encrypted'),
            child: const Row(
              children: [
                Icon(Icons.lock),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Encrypted backup (recommended)'),
                      Text('Password-protected by your master key',
                          style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'plain'),
            child: const Row(
              children: [
                Icon(Icons.description),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Plain JSON'),
                      Text('Decrypted text — keep it safe',
                          style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (format == null || !context.mounted) return;

    try {
      final service = ref.read(exportImportServiceProvider);
      final isPlain = format == 'plain';
      final content = isPlain
          ? await service.exportPlainJson()
          : await service.exportEncrypted();

      final now = DateTime.now();
      final date = '${now.year}'
          '${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}';
      final filename =
          '${isPlain ? 'easypass_plain' : 'easypass_backup'}_$date.json';

      final path = await FilePicker.platform.saveFile(
        dialogTitle: isPlain ? 'Save Plain Export' : 'Save Encrypted Backup',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (path == null || !context.mounted) return;

      await service.writeToFile(content, path);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Vault exported to $path')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  // ─── Import ─────────────────────────────────────────────

  void _importVault(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Vault'),
        content: const Text(
          'Importing will add all entries from the backup file to your '
          'current vault. Existing entries will not be overwritten. '
          'Continue?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Import')),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result == null || result.files.isEmpty || !context.mounted) return;

      final file = File(result.files.single.path!);
      final content = await file.readAsString();

      final service = ref.read(exportImportServiceProvider);
      final counts = await service.importFromJson(content);

      ref.invalidate(vaultRepositoryProvider);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Imported ${counts['entries']} entries and '
                '${counts['folders']} folders'),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  // ─── Change Master Password ─────────────────────────────

  void _changeMasterPassword(BuildContext context, WidgetRef ref) {
    final currentController = TextEditingController();
    final newController = TextEditingController();
    final confirmController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change Master Password'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: currentController,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Current Master Password',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.key),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: newController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'New Master Password',
                  hintText: 'At least 8 characters',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock_reset),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmController,
                obscureText: true,
                onSubmitted: (_) => Navigator.pop(ctx, true),
                decoration: const InputDecoration(
                  labelText: 'Confirm New Password',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock_reset),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final success = await ref
                  .read(authProvider.notifier)
                  .changeMasterPassword(
                    currentController.text,
                    newController.text,
                    confirmController.text,
                  );
              final error = ref.read(authProvider).errorMessage;
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      success
                          ? 'Master password changed'
                          : 'Failed: ${error ?? 'Unknown error'}',
                    ),
                    backgroundColor: success ? null : Colors.red,
                  ),
                );
              }
            },
            child: const Text('Change'),
          ),
        ],
      ),
    );
  }

  // ─── Auto-lock Timeout ──────────────────────────────────

  void _pickAutoLockTimeout(BuildContext context, WidgetRef ref) {
    final current = ref.read(authProvider).autoLockMinutes;
    const options = {
      1: '1 minute',
      3: '3 minutes',
      5: '5 minutes',
      15: '15 minutes',
      30: '30 minutes',
    };

    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Auto-lock Timeout'),
        children: options.entries.map((e) {
          final isSelected = e.key == current;
          return ListTile(
            title: Text(e.value),
            trailing:
                isSelected ? const Icon(Icons.check, color: Colors.green) : null,
            onTap: () async {
              Navigator.pop(ctx);
              await ref.read(authProvider.notifier).setAutoLockMinutes(e.key);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Auto-lock set to ${e.value}')),
                );
              }
            },
          );
        }).toList(),
      ),
    );
  }

  // ─── Delete All ─────────────────────────────────────────

  void _confirmDeleteAll(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete All Data?'),
        content: const Text(
            'This will permanently delete all your saved passwords and data. '
            'This action cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final db = ref.read(databaseProvider);
              final entries = await db.getAllEntries();
              for (final e in entries) {
                await db.deleteEntry(e.id);
              }
              final folders = await db.getAllFolders();
              for (final f in folders) {
                await db.deleteFolder(f.id);
              }
              ref.invalidate(vaultRepositoryProvider);
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('All data deleted')),
                );
              }
            },
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
  }
}
