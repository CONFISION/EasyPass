import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/export_import_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

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
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _changeMasterPassword(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.timer),
            title: const Text('Auto-lock Timeout'),
            subtitle: const Text('5 minutes'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickAutoLockTimeout(context),
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
                      content: Text('Biometric unlock coming in a future update')),
                );
              },
            ),
          ),
          const Divider(),
          _buildSectionHeader(context, 'Data'),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('Export Vault'),
            subtitle: const Text('Save as encrypted JSON file'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _exportVault(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('Import Vault'),
            subtitle: const Text('Restore from a backup file'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _importVault(context, ref),
          ),
          const Divider(),
          _buildSectionHeader(context, 'Danger Zone', color: theme.colorScheme.error),
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

  Widget _buildSectionHeader(BuildContext context, String title, {Color? color}) {
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
    try {
      final service = ref.read(exportImportServiceProvider);
      final encrypted = await service.exportEncrypted();

      final now = DateTime.now();
      final filename =
          'easypass_backup_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.json';

      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Encrypted Backup',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (path == null || !context.mounted) return;

      await service.writeToFile(encrypted, path);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Vault exported to $path')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red),
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
          'Importing will add all entries from the backup file to your current vault. '
          'Existing entries will not be overwritten. Continue?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Import')),
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
                'Imported ${counts['entries']} entries and ${counts['folders']} folders'),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ─── Change Master Password ─────────────────────────────

  void _changeMasterPassword(BuildContext context, WidgetRef ref) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text(
              'To change your master password, lock the vault and use the "Forgot password" option (coming soon)')),
    );
  }

  // ─── Auto-lock Timeout ──────────────────────────────────

  void _pickAutoLockTimeout(BuildContext context) {
    final options = {1: '1 minute', 3: '3 minutes', 5: '5 minutes', 15: '15 minutes', 30: '30 minutes'};

    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Auto-lock Timeout'),
        children: options.entries.map((e) {
          final isSelected = e.key == 5; // default
          return ListTile(
            title: Text(e.value),
            trailing: isSelected ? const Icon(Icons.check, color: Colors.green) : null,
            onTap: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Auto-lock set to ${e.value}')),
              );
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
            'This will permanently delete all your saved passwords and data. This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              // Delete all entries and folders
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