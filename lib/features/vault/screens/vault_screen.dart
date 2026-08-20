import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/crypto/crypto_service.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/providers/auth_provider.dart';
import '../providers/vault_provider.dart';
import '../widgets/entry_card.dart';

class VaultScreen extends ConsumerWidget {
  const VaultScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showFavorites = ref.watch(showFavoritesProvider);
    final folderName = ref.watch(selectedFolderNameProvider);
    final entriesAsync = showFavorites
        ? ref.watch(vaultFavoritesProvider)
        : ref.watch(filteredVaultEntriesProvider);
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    String title;
    if (showFavorites) {
      title = l10n.favoritesTitle;
    } else if (folderName != null) {
      title = folderName;
    } else {
      title = l10n.appTitle;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              showSearch(
                context: context,
                delegate: _VaultSearchDelegate(ref: ref),
              );
            },
            tooltip: l10n.searchTooltip,
          ),
          IconButton(
            icon: const Icon(Icons.auto_fix_high),
            onPressed: () => context.push('/generator'),
            tooltip: l10n.generatorTooltip,
          ),
          IconButton(
            icon: const Icon(Icons.lock_outline),
            onPressed: () {
              ref.read(authProvider.notifier).lock();
            },
            tooltip: l10n.lockTooltip,
          ),
        ],
      ),
      drawer: _buildDrawer(context, ref),
      body: entriesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline,
                  size: 64, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text(l10n.failedToLoadVault(error.toString())),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => ref.invalidate(vaultEntriesProvider),
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
        data: (entries) {
          if (entries.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.lock_open,
                    size: 80,
                    color: theme.colorScheme.onSurfaceVariant.withAlpha(100),
                  ),
                  const SizedBox(height: 16),
                  Text(l10n.emptyVaultTitle,
                      style: theme.textTheme.headlineSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  Text(l10n.emptyVaultHint,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            );
          }

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: ListView.builder(
                padding: const EdgeInsets.only(top: 8, bottom: 80),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return EntryCard(
                    entry: entry,
                    onTap: () => context.push('/vault/entry/${entry.id}'),
                    onCopyPassword: () =>
                        _copyPassword(context, ref, entry),
                  );
                },
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/vault/add'),
        icon: const Icon(Icons.add),
        label: Text(l10n.add),
      ),
    );
  }

  void _copyPassword(BuildContext context, WidgetRef ref, PasswordEntry entry) async {
    final key = ref.read(encryptionKeyProvider);
    final encrypted = entry.passwordEncrypted;
    String decrypted;
    try {
      decrypted = key != null
          ? CryptoService().decryptData(encrypted, key)
          : encrypted;
    } catch (_) {
      decrypted = encrypted;
    }
    await Clipboard.setData(ClipboardData(text: decrypted));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).passwordCopied),
        ),
      );
    }
  }

  Widget _buildDrawer(BuildContext context, WidgetRef ref) {
    final foldersAsync = ref.watch(foldersProvider);
    final l10n = AppLocalizations.of(context);

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DrawerHeader(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Icon(Icons.security, size: 48,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 12),
                  const Text('EasyPass',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.inventory_2),
              title: Text(l10n.allItems),
              selected: ref.watch(selectedFolderIdProvider) == null &&
                  !ref.watch(showFavoritesProvider),
              onTap: () {
                ref.read(selectedFolderIdProvider.notifier).state = null;
                ref.read(showFavoritesProvider.notifier).state = false;
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.star),
              title: Text(l10n.favorites),
              selected: ref.watch(showFavoritesProvider),
              onTap: () {
                ref.read(showFavoritesProvider.notifier).state = true;
                ref.read(selectedFolderIdProvider.notifier).state = null;
                Navigator.pop(context);
              },
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Text(
                    l10n.foldersSection,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.add, size: 20),
                    onPressed: () => _showAddFolderDialog(context, ref),
                  ),
                ],
              ),
            ),
            foldersAsync.when(
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
              data: (folders) => Expanded(
                child: ListView.builder(
                  itemCount: folders.length,
                  itemBuilder: (context, index) {
                    final folder = folders[index];
                    return ListTile(
                      leading: const Icon(Icons.folder),
                      title: Text(folder.name),
                      selected: ref.watch(selectedFolderIdProvider) == folder.id &&
                          !ref.watch(showFavoritesProvider),
                      onTap: () {
                        ref.read(selectedFolderIdProvider.notifier).state = folder.id;
                        ref.read(showFavoritesProvider.notifier).state = false;
                        Navigator.pop(context);
                      },
                      onLongPress: () =>
                          _confirmDeleteFolder(context, ref, folder),
                    );
                  },
                ),
              ),
            ),
            const Divider(),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.auto_fix_high),
              title: Text(l10n.passwordGenerator),
              onTap: () {
                Navigator.pop(context);
                context.push('/generator');
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings),
              title: Text(l10n.settings),
              onTap: () {
                Navigator.pop(context);
                context.push('/settings');
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAddFolderDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.newFolder),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l10n.folderNameLabel,
            hintText: l10n.folderNameHint,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              final now = DateTime.now().millisecondsSinceEpoch;
              await ref.read(vaultRepositoryProvider).addFolder(
                    FoldersCompanion.insert(
                      id: const Uuid().v4(),
                      name: name,
                      createdAt: now,
                      updatedAt: now,
                    ),
                  );
              ref.invalidate(foldersProvider);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text(l10n.create),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteFolder(
      BuildContext context, WidgetRef ref, Folder folder) {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deleteFolderTitle),
        content: Text(l10n.deleteFolderMessage(folder.name)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.cancel)),
          FilledButton(
            onPressed: () async {
              await ref.read(vaultRepositoryProvider).removeFolder(folder.id);
              if (ref.read(selectedFolderIdProvider) == folder.id) {
                ref.read(selectedFolderIdProvider.notifier).state = null;
              }
              ref.invalidate(foldersProvider);
              ref.invalidate(filteredVaultEntriesProvider);
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.folderDeleted(folder.name))),
                );
              }
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

// ─── Search Delegate ─────────────────────────────────────

class _VaultSearchDelegate extends SearchDelegate<String?> {
  final WidgetRef ref;

  _VaultSearchDelegate({required this.ref});

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      if (query.isNotEmpty)
        IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, null));
  }

  @override
  Widget buildResults(BuildContext context) => _buildSearchResults(context);

  @override
  Widget buildSuggestions(BuildContext context) => _buildSearchResults(context);

  Widget _buildSearchResults(BuildContext context) {
    final results = ref.watch(searchResultsProvider(query));
    final l10n = AppLocalizations.of(context);

    return results.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Center(child: Text(l10n.searchFailed)),
      data: (entries) {
        if (entries.isEmpty) {
          return Center(child: Text(l10n.noResultsFound));
        }
        return ListView.builder(
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            return EntryCard(
              entry: entry,
              onTap: () {
                close(context, null);
                context.push('/vault/entry/${entry.id}');
              },
            );
          },
        );
      },
    );
  }
}
