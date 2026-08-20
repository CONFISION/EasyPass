import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/providers/auth_provider.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/export_import_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final autoLockMinutes = ref.watch(authProvider).autoLockMinutes;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              children: [
                _buildSectionHeader(context, l10n.securitySection),
                ListTile(
                  leading: const Icon(Icons.lock_reset),
                  title: Text(l10n.changeMasterPassword),
                  subtitle: Text(l10n.changeMasterPasswordSubtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _changeMasterPassword(context, ref),
                ),
                ListTile(
                  leading: const Icon(Icons.timer),
                  title: Text(l10n.autoLockTimeout),
                  subtitle: Text(l10n.autoLockMinutesValue(autoLockMinutes)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _pickAutoLockTimeout(context, ref),
                ),
                ListTile(
                  leading: const Icon(Icons.fingerprint),
                  title: Text(l10n.biometricUnlock),
                  subtitle: Text(l10n.biometricUnlockSubtitle),
                  trailing: Switch(
                    value: false,
                    onChanged: (value) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l10n.biometricComingSoon)),
                      );
                    },
                  ),
                ),
                const Divider(),
                _buildSectionHeader(context, l10n.dataSection),
                ListTile(
                  leading: const Icon(Icons.upload_file),
                  title: Text(l10n.exportVault),
                  subtitle: Text(l10n.exportVaultSubtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _exportVault(context, ref),
                ),
                ListTile(
                  leading: const Icon(Icons.download),
                  title: Text(l10n.importVault),
                  subtitle: Text(l10n.importVaultSubtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _importVault(context, ref),
                ),
                const Divider(),
                _buildSectionHeader(context, l10n.languageSection),
                ListTile(
                  leading: const Icon(Icons.language),
                  title: Text(l10n.language),
                  subtitle: Text(_languageSubtitle(context, ref)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _pickLanguage(context, ref),
                ),
                const Divider(),
                _buildSectionHeader(context, l10n.dangerZoneSection,
                    color: theme.colorScheme.error),
                ListTile(
                  leading: Icon(Icons.delete_forever, color: theme.colorScheme.error),
                  title: Text(l10n.deleteAllData,
                      style: TextStyle(color: theme.colorScheme.error)),
                  subtitle: Text(l10n.deleteAllDataSubtitle),
                  onTap: () => _confirmDeleteAll(context, ref),
                ),
                const Divider(),
                _buildSectionHeader(context, l10n.aboutSection),
                ListTile(
                  leading: const Icon(Icons.info),
                  title: Text(l10n.version),
                  subtitle: Text('1.0.0'),
                ),
                ListTile(
                  leading: const Icon(Icons.code),
                  title: Text(l10n.appTitle),
                  subtitle: Text(l10n.appInfo),
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

  // ─── Language ──────────────────────────────────────────

  String _languageSubtitle(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final locale = ref.watch(localeProvider);
    if (locale == null) return l10n.followSystem;
    return locale.languageCode == 'zh' ? l10n.languageChinese : l10n.languageEnglish;
  }

  void _pickLanguage(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final current = ref.read(localeProvider);

    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.language),
        children: [
          ListTile(
            title: Text(l10n.followSystem),
            trailing: current == null
                ? const Icon(Icons.check, color: Colors.green)
                : null,
            onTap: () {
              ref.read(localeProvider.notifier).state = null;
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            title: Text(l10n.languageChinese),
            trailing: current?.languageCode == 'zh'
                ? const Icon(Icons.check, color: Colors.green)
                : null,
            onTap: () {
              ref.read(localeProvider.notifier).state = const Locale('zh');
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            title: Text(l10n.languageEnglish),
            trailing: current?.languageCode == 'en'
                ? const Icon(Icons.check, color: Colors.green)
                : null,
            onTap: () {
              ref.read(localeProvider.notifier).state = const Locale('en');
              Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
  }

  // ─── Export ─────────────────────────────────────────────

  void _exportVault(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final format = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.exportDialogTitle),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'encrypted'),
            child: Row(
              children: [
                const Icon(Icons.lock),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.encryptedBackup),
                      Text(l10n.encryptedBackupDesc,
                          style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'plain'),
            child: Row(
              children: [
                const Icon(Icons.description),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.plainJson),
                      Text(l10n.plainJsonDesc,
                          style: const TextStyle(fontSize: 12)),
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
        dialogTitle:
            isPlain ? l10n.savePlainExportDialog : l10n.saveEncryptedBackupDialog,
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (path == null || !context.mounted) return;

      await service.writeToFile(content, path);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.vaultExportedTo(path))),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.exportFailed(e.toString())),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  // ─── Import ─────────────────────────────────────────────

  void _importVault(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.importDialogTitle),
        content: Text(l10n.importDialogMessage),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.import)),
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
            content: Text(l10n.importedCounts(
                counts['entries'] ?? 0, counts['folders'] ?? 0)),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.importFailed(e.toString())),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  // ─── Change Master Password ─────────────────────────────

  void _changeMasterPassword(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final currentController = TextEditingController();
    final newController = TextEditingController();
    final confirmController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.changeMasterPassword),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: currentController,
                obscureText: true,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l10n.currentMasterPasswordLabel,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.key),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: newController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l10n.newMasterPasswordLabel,
                  hintText: l10n.masterPasswordHint,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.lock_reset),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmController,
                obscureText: true,
                onSubmitted: (_) => Navigator.pop(ctx, true),
                decoration: InputDecoration(
                  labelText: l10n.confirmNewPasswordLabel,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.lock_reset),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.cancel)),
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
                final messenger = ScaffoldMessenger.of(context);
                final appL10n = AppLocalizations.of(context);
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      success
                          ? appL10n.masterPasswordChanged
                          : appL10n.failedWithError(
                              authErrorMessage(appL10n, error)),
                    ),
                    backgroundColor: success ? null : Colors.red,
                  ),
                );
              }
            },
            child: Text(l10n.change),
          ),
        ],
      ),
    );
  }

  // ─── Auto-lock Timeout ──────────────────────────────────

  void _pickAutoLockTimeout(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final current = ref.read(authProvider).autoLockMinutes;
    const options = [1, 3, 5, 15, 30];

    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.autoLockTimeout),
        children: options.map((minutes) {
          final isSelected = minutes == current;
          return ListTile(
            title: Text(l10n.autoLockMinutesValue(minutes)),
            trailing:
                isSelected ? const Icon(Icons.check, color: Colors.green) : null,
            onTap: () async {
              Navigator.pop(ctx);
              await ref.read(authProvider.notifier).setAutoLockMinutes(minutes);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(l10n.autoLockSet(
                          l10n.autoLockMinutesValue(minutes)))),
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
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deleteAllDataTitle),
        content: Text(l10n.deleteAllDataMessage),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.cancel)),
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
                  SnackBar(content: Text(l10n.allDataDeleted)),
                );
              }
            },
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            child: Text(l10n.deleteAll),
          ),
        ],
      ),
    );
  }
}
