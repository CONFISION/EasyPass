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

  /// Fixed sidebar width in logical pixels.
  ///
  /// Deliberately a fixed width instead of the old `flex: 2 / maxWidth: 300`
  /// ratio: in a narrow window the ratio squeezed the sidebar to ~130px, which
  /// pushed the brand header past its Row and produced the overflow stripes the
  /// user saw. A fixed 248px keeps the header and the folder list readable, and
  /// at the 900px minimum window width (enforced natively in
  /// `windows/runner/win32_window.cpp`) it still leaves ~650px for the entries.
  static const double _sidebarWidth = 248;

  /// Height of the top strip of **both** columns: the sidebar's brand header and
  /// the right column's toolbar.
  ///
  /// Shared on purpose. Each side centres its own content inside a fixed-height
  /// box of this value, so the divider under the brand header and the divider
  /// under the toolbar land on the exact same y coordinate by construction —
  /// not because padding and font metrics happen to add up. Change this one
  /// value and both columns follow.
  static const double _topBarHeight = 64;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showFavorites = ref.watch(showFavoritesProvider);
    final folderName = ref.watch(selectedFolderNameProvider);
    final entriesAsync = showFavorites
        ? ref.watch(vaultFavoritesProvider)
        : ref.watch(filteredVaultEntriesProvider);
    final l10n = AppLocalizations.of(context);

    // Context title of the right pane. The brand is NOT part of it: "EasyPass"
    // is shown once, at the top of the sidebar (see _buildSidebar).
    String title;
    if (showFavorites) {
      title = l10n.favoritesTitle;
    } else if (folderName != null) {
      title = folderName;
    } else {
      title = l10n.allItems;
    }

    return Scaffold(
      // Two full-height columns and no top-level AppBar: the sidebar owns the
      // brand and stretches from the very top to the very bottom of the window,
      // while the right column carries its own toolbar (context title + the five
      // global actions).
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: _sidebarWidth, child: _buildSidebar(context, ref)),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildToolbar(context, ref, l10n, title),
                  const Divider(height: 1, key: ValueKey('toolbarDivider')),
                  Expanded(
                    child: _buildEntriesArea(context, ref, entriesAsync),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      // Icon-only on purpose (the user asked for a minimal UI): the tooltip
      // stays so the button keeps an accessible name on hover / for screen
      // readers without taking up visual space.
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/vault/add'),
        tooltip: l10n.add,
        child: const Icon(Icons.add),
      ),
    );
  }

  /// Right-column toolbar: the context title (all items / favorites / folder
  /// name) followed by the five global actions.
  ///
  /// It carries no brand on purpose — "EasyPass" appears exactly once, at the top
  /// of the sidebar. Keeping the context title means "which folder am I looking
  /// at" stays visible after the AppBar is gone; if it ever feels redundant, drop
  /// the [Expanded] Text and the toolbar becomes a pure action row.
  Widget _buildToolbar(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    String title,
  ) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: SizedBox(
        // Same height as the sidebar's brand header (_topBarHeight): both columns
        // centre their content in a fixed-height box of that value, which is what
        // makes the two dividers below them line up exactly.
        height: _topBarHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    title,
                    style: theme.textTheme.titleLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
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
                icon: const Icon(Icons.health_and_safety_outlined),
                onPressed: () => context.push('/health'),
                tooltip: l10n.healthReport,
              ),
              IconButton(
                icon: const Icon(Icons.lock_outline),
                onPressed: () {
                  ref.read(authProvider.notifier).lock();
                },
                tooltip: l10n.lockTooltip,
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => context.push('/settings'),
                tooltip: l10n.settings,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEntriesArea(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<PasswordEntry>> entriesAsync,
  ) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return entriesAsync.when(
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
                  onCopyPassword: () => _copyPassword(context, ref, entry),
                );
              },
            ),
          ),
        );
      },
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

  // ─── Persistent Sidebar ─────────────────────────────────

  Widget _buildSidebar(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final foldersAsync = ref.watch(foldersProvider);

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header — the single place the brand is shown. Fixed height shared
            // with the right toolbar (_topBarHeight), content centred inside it,
            // so the divider below sits at the same y as the toolbar's.
            SizedBox(
              height: _topBarHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(Icons.security,
                        size: 32, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    // Expanded is what makes `ellipsis` actually take effect: the
                    // bare Text asked for its intrinsic width, so the Row overflowed
                    // as soon as the sidebar got narrow (the yellow/black stripes).
                    Expanded(
                      child: Text(
                        l10n.appTitle,
                        style: theme.textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, key: ValueKey('sidebarHeaderDivider')),
            ListTile(
              leading: const Icon(Icons.inventory_2),
              title: Text(
                l10n.allItems,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              selected: ref.watch(selectedFolderIdProvider) == null &&
                  !ref.watch(showFavoritesProvider),
              onTap: () {
                ref.read(selectedFolderIdProvider.notifier).state = null;
                ref.read(showFavoritesProvider.notifier).state = false;
              },
            ),
            ListTile(
              leading: const Icon(Icons.star),
              title: Text(
                l10n.favorites,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              selected: ref.watch(showFavoritesProvider),
              onTap: () {
                ref.read(showFavoritesProvider.notifier).state = true;
                ref.read(selectedFolderIdProvider.notifier).state = null;
              },
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.foldersSection,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
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
                      // Folder names are user input and can be arbitrarily long.
                      title: Text(
                        folder.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      selected: ref.watch(selectedFolderIdProvider) == folder.id &&
                          !ref.watch(showFavoritesProvider),
                      onTap: () {
                        ref.read(selectedFolderIdProvider.notifier).state = folder.id;
                        ref.read(showFavoritesProvider.notifier).state = false;
                      },
                      onLongPress: () =>
                          _confirmDeleteFolder(context, ref, folder),
                    );
                  },
                ),
              ),
            ),
            // The generator and settings entries live in the right-column
            // toolbar; they are intentionally not duplicated down here, and with
            // nothing left below the folder list the separator above them is gone
            // too.
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
