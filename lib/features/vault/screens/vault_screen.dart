import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../data/database/database.dart';
import '../../../data/models/entry_type.dart';
import '../../../data/models/vault_item.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/providers/auth_provider.dart';
import '../providers/vault_provider.dart';
import '../widgets/entry_card.dart';
import '../widgets/entry_type_bits.dart';

/// 文件夹可选图标（持久化在 `folders.icon` 的稳定名字上）。
///
/// 只放一小撮固定图标：够区分常见用途，又不至于让选择器变成图标大卖场。
/// 名字进了数据库就是契约，**只增不改**；未知名字回退到 [Icons.folder]。
const Map<String, IconData> _folderIcons = {
  'folder': Icons.folder,
  'work': Icons.work_outline,
  'home': Icons.home_outlined,
  'star': Icons.star_outline,
  'lock': Icons.lock_outline,
  'key': Icons.vpn_key_outlined,
  'card': Icons.credit_card,
  'bookmark': Icons.bookmark_border,
};

/// `folders.icon` → Material 图标（含旧数据 / 未知名字的回退）。
IconData _folderIconData(String? name) => _folderIcons[name] ?? Icons.folder;

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

  /// Height of the type-filter strip under the toolbar. Its own constant (not
  /// [_topBarHeight]): it sits *below* the shared top bar, so it must not take
  /// part in the "both dividers share one height" coupling.
  static const double _typeFilterHeight = 48;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showFavorites = ref.watch(showFavoritesProvider);
    final folderName = ref.watch(selectedFolderNameProvider);
    final selectedType = ref.watch(selectedEntryTypeProvider);
    // 一条流搞定 文件夹 + 类型 + 收藏 的叠加过滤（见 vault_provider.dart）。
    final entriesAsync = ref.watch(filteredVaultEntriesProvider);
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
                  _buildTypeFilterBar(context, ref, l10n),
                  const Divider(height: 1, key: ValueKey('typeFilterDivider')),
                  Expanded(
                    child: _buildEntriesArea(
                      context,
                      ref,
                      entriesAsync,
                      selectedType,
                    ),
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
                    delegate: _VaultSearchDelegate(
                      // SearchDelegate 的 searchFieldLabel 是无 context 的
                      // getter，拿不到 AppLocalizations，所以文案从外面传。
                      searchHint: l10n.searchHint,
                    ),
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

  /// Type filter: All / Login / Secure note / Identity / SSH key.
  ///
  /// Deliberately a chips row *under* the toolbar instead of a second toolbar:
  /// it composes with both the folder selection and the favourites view (the
  /// combination happens in [filteredVaultEntriesProvider]), and the chip row
  /// scrolls horizontally so the 900px minimum window never overflows.
  Widget _buildTypeFilterBar(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) {
    final theme = Theme.of(context);
    final selected = ref.watch(selectedEntryTypeProvider);

    return Material(
      color: theme.colorScheme.surface,
      child: SizedBox(
        key: const ValueKey('typeFilterBar'),
        height: _typeFilterHeight,
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Tooltip(
                message: l10n.entryTypeFilterTooltip,
                child: Icon(
                  Icons.filter_alt_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    // null 打头 = "全部类型"（不筛选）。
                    for (final type in <EntryType?>[null, ...EntryType.values])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          key: ValueKey('typeChip-${type?.wireName ?? 'all'}'),
                          label: Text(
                            type == null
                                ? l10n.entryTypeAll
                                : EntryTypeBits.label(l10n, type),
                          ),
                          labelStyle: theme.textTheme.labelMedium,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          selected: selected == type,
                          onSelected: (_) {
                            ref
                                .read(selectedEntryTypeProvider.notifier)
                                .state = type;
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntriesArea(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<VaultItem>> entriesAsync,
    EntryType? selectedType,
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
              onPressed: () {
                // 列表走的是 filteredVaultEntriesProvider，出错时三个都要重取。
                ref.invalidate(vaultEntriesProvider);
                ref.invalidate(vaultFavoritesProvider);
                ref.invalidate(filteredVaultEntriesProvider);
              },
              child: Text(l10n.retry),
            ),
          ],
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return _buildEmptyState(context, l10n, selectedType);
        }

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: ListView.builder(
              padding: const EdgeInsets.only(top: 8, bottom: 80),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return EntryCard(
                  item: item,
                  onTap: () => context.push('/vault/entry/${item.id}'),
                  // 只有登录条目给"复制密码"（契约 §4 列表）。
                  onCopyPassword: item.isAutofillable
                      ? () => _copyPassword(context, item)
                      : null,
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// Empty state: with a type filter active it says *which* type is empty
  /// (`entryTypeEmptyForType`), otherwise it keeps the original vault copy.
  Widget _buildEmptyState(
    BuildContext context,
    AppLocalizations l10n,
    EntryType? selectedType,
  ) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    final title = selectedType == null
        ? l10n.emptyVaultTitle
        : l10n.entryTypeEmptyForType(EntryTypeBits.label(l10n, selectedType));
    final hint = selectedType == null ? l10n.emptyVaultHint : null;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selectedType == null
                  ? Icons.lock_open
                  : EntryTypeBits.icon(selectedType),
              size: 80,
              color: muted.withAlpha(100),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(color: muted),
              textAlign: TextAlign.center,
            ),
            if (hint != null) ...[
              const SizedBox(height: 8),
              Text(
                hint,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Copies a login entry's password.
  ///
  /// The plaintext comes from the already-decrypted [VaultItem] (decryption is
  /// the repository mapper's job); it goes straight to the clipboard and is
  /// never logged, printed or stored.
  Future<void> _copyPassword(BuildContext context, VaultItem item) async {
    final password = item.loginOrEmpty.password;
    if (password.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: password));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).passwordCopied)),
    );
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
                    onPressed: () => _showFolderDialog(context, ref),
                    tooltip: l10n.newFolder,
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
                    // 桌面端必须有**看得见**的入口：长按是触屏手势，鼠标用户
                    // 不会去长按，右键也没有绑定 —— 用户反馈的"文件夹只能加
                    // 不能删"就是这么来的。这里给 ⋮ 按钮 + 右键两条明路，
                    // 长按继续保留（触屏/习惯用户）。
                    return GestureDetector(
                      onSecondaryTap: () =>
                          _showFolderActions(context, ref, folder),
                      child: ListTile(
                        // 图标来自 folders.icon（2.3.0 起真正接上），缺省是文件夹。
                        leading: Icon(_folderIconData(folder.icon)),
                        // Folder names are user input and can be arbitrarily long.
                        title: Text(
                          folder.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.more_vert, size: 18),
                          visualDensity: VisualDensity.compact,
                          tooltip: l10n.folderActions,
                          onPressed: () =>
                              _showFolderActions(context, ref, folder),
                        ),
                        selected: ref.watch(selectedFolderIdProvider) == folder.id &&
                            !ref.watch(showFavoritesProvider),
                        onTap: () {
                          ref.read(selectedFolderIdProvider.notifier).state = folder.id;
                          ref.read(showFavoritesProvider.notifier).state = false;
                        },
                        // 长按 = 重命名 / 删除（桌面端没有右键菜单的等价入口）。
                        onLongPress: () =>
                            _showFolderActions(context, ref, folder),
                      ),
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

  /// 新建 / 编辑文件夹对话框（共用一套：名字 + 图标选择器）。
  ///
  /// [folder] 为 null = 新建；否则是重命名 / 改图标，走
  /// [VaultRepository.updateFolder]。
  void _showFolderDialog(
    BuildContext context,
    WidgetRef ref, {
    Folder? folder,
  }) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isEdit = folder != null;
    final nameController = TextEditingController(text: folder?.name ?? '');
    var selectedIcon = folder?.icon ?? _folderIcons.keys.first;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(isEdit ? l10n.folderEditTitle : l10n.newFolder),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l10n.folderNameLabel,
                    hintText: l10n.folderNameHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.folderIconLabel,
                  style: theme.textTheme.labelMedium,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final icon in _folderIcons.entries)
                      _buildFolderIconChoice(
                        theme: theme,
                        iconName: icon.key,
                        icon: icon.value,
                        selected: icon.key == selectedIcon,
                        onSelected: () =>
                            setDialogState(() => selectedIcon = icon.key),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () async {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                final repo = ref.read(vaultRepositoryProvider);
                final now = DateTime.now().millisecondsSinceEpoch;

                if (isEdit) {
                  await repo.updateFolder(
                    folder.id,
                    FoldersCompanion(
                      name: Value(name),
                      icon: Value(selectedIcon),
                      updatedAt: Value(now),
                    ),
                  );
                } else {
                  await repo.addFolder(
                    FoldersCompanion.insert(
                      id: const Uuid().v4(),
                      name: name,
                      icon: Value(selectedIcon),
                      createdAt: now,
                      updatedAt: now,
                    ),
                  );
                }
                // 不需要 invalidate：foldersProvider 监听 drift（watchFolders），
                // 上面这次写入落库后侧边栏会自己刷新（2.3.1 起）。
                if (ctx.mounted) Navigator.pop(ctx);
                if (isEdit && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.folderRenamed)),
                  );
                }
              },
              child: Text(isEdit ? l10n.saveChanges : l10n.create),
            ),
          ],
        ),
      ),
    );
  }

  /// 图标选择器里的一格：选中态用 filledTonal，一眼能看出当前选择。
  Widget _buildFolderIconChoice({
    required ThemeData theme,
    required String iconName,
    required IconData icon,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    final key = ValueKey('folderIcon-$iconName');
    if (selected) {
      return IconButton.filledTonal(
        key: key,
        icon: Icon(icon),
        onPressed: onSelected,
        tooltip: iconName,
      );
    }
    return IconButton(
      key: key,
      icon: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
      onPressed: onSelected,
      tooltip: iconName,
    );
  }

  /// 文件夹的长按菜单：重命名 / 删除。
  ///
  /// 用 bottom sheet 而不是对话框：桌面窄窗下它天然不会溢出，条目也是
  /// 定宽列表项（§10.7）。
  void _showFolderActions(BuildContext context, WidgetRef ref, Folder folder) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                children: [
                  Icon(_folderIconData(folder.icon), size: 20),
                  const SizedBox(width: 8),
                  // 文件夹名是用户输入，必须 Expanded 才能走 ellipsis（§10.6）。
                  Expanded(
                    child: Text(
                      folder.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: Text(l10n.renameFolder),
              onTap: () {
                Navigator.pop(sheetContext);
                _showFolderDialog(context, ref, folder: folder);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: theme.colorScheme.error),
              title: Text(
                l10n.delete,
                style: TextStyle(color: theme.colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _confirmDeleteFolder(context, ref, folder);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 删除文件夹前的检查与确认。
  ///
  /// **不暴力删除**：先把里面的条目数查出来。空文件夹给普通确认；有条目的
  /// 必须明确告诉用户"有多少条、条目不会被删、会被移到『无文件夹』"，
  /// 确认按钮也换成带"保留条目"字样的措辞，避免误点。
  /// 真正的删除走 `removeFolder`（先把条目的 folder_id 清空，再删文件夹），
  /// 任何情况下都不会删除条目本身。
  Future<void> _confirmDeleteFolder(
      BuildContext context, WidgetRef ref, Folder folder) async {
    final l10n = AppLocalizations.of(context);

    final int entryCount;
    try {
      entryCount = await ref
          .read(vaultRepositoryProvider)
          .countItemsInFolder(folder.id);
    } catch (error) {
      // 连数都数不出来时不要装作成功：直接告诉用户失败原因。
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.failedWithError('$error'))),
        );
      }
      return;
    }
    if (!context.mounted) return;

    final hasEntries = entryCount > 0;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deleteFolderTitle),
        content: Text(hasEntries
            ? l10n.deleteFolderNotEmptyMessage(folder.name, entryCount)
            : l10n.deleteFolderMessage(folder.name)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.cancel)),
          FilledButton(
            onPressed: () async {
              try {
                // removeFolder 会先把条目的 folder_id 清空（否则留下幽灵条目）。
                await ref.read(vaultRepositoryProvider).removeFolder(folder.id);
                // 选中态是本页的 UI 状态，必须显式清掉：文件夹已经从库里消失，
                // 继续"选中"它会让标题挂着不存在的名字。列表本身由 foldersProvider
                // 的流推送，不需要（也不能）手动 invalidate。
                if (ref.read(selectedFolderIdProvider) == folder.id) {
                  ref.read(selectedFolderIdProvider.notifier).state = null;
                }
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.folderDeleted(folder.name))),
                  );
                }
              } catch (error) {
                // 删不掉就明说（对话框留着，用户可以重试或取消），
                // 否则界面看起来就是"点了没反应"。
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.failedWithError('$error'))),
                  );
                }
              }
            },
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            child: Text(hasEntries ? l10n.deleteFolderKeepEntries : l10n.delete),
          ),
        ],
      ),
    );
  }
}

// ─── Search Delegate ─────────────────────────────────────

class _VaultSearchDelegate extends SearchDelegate<String?> {
  /// Hint of the search field (`l10n.searchHint`), forwarded to the base
  /// constructor: [SearchDelegate.searchFieldLabel] is a context-free field and
  /// cannot reach `AppLocalizations` on its own.
  _VaultSearchDelegate({required String searchHint})
      : super(searchFieldLabel: searchHint);

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
    final l10n = AppLocalizations.of(context);

    // 空查询不给"没有结果"，而是把前缀用法摆出来（searchPrefixesHint）。
    if (query.trim().isEmpty) {
      return _buildPrefixesHint(context, l10n);
    }

    // 搜索走仓储的 searchItems：type: / folder: / url: 前缀 + 身份 / SSH /
    // 自定义字段匹配（契约 §3），结果与列表用同一张卡片渲染。
    //
    // 用 [Consumer] 而不是外面传进来的 WidgetRef：搜索页是独立的 route，
    // 它的 build 不会被保险库页的重建带动 —— 如果在这里 `ref.watch` 保险库页的
    // ref，异步结果回来时没人重建，界面会一直卡在转圈上（每个新按键才顺带刷新
    // 上一次的结果）。Consumer 自己订阅自己重建，才是对的。
    return Consumer(
      builder: (context, ref, _) {
        final results = ref.watch(searchResultsProvider(query));

        return results.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => Center(child: Text(l10n.searchFailed)),
          data: (items) {
            if (items.isEmpty) {
              return Center(child: Text(l10n.noResultsFound));
            }
            return ListView.builder(
              padding: const EdgeInsets.only(top: 8, bottom: 80),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return EntryCard(
                  item: item,
                  onTap: () {
                    close(context, null);
                    context.push('/vault/entry/${item.id}');
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  /// 搜索框下方的前缀提示（空查询时显示）。
  Widget _buildPrefixesHint(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            children: [
              Icon(
                Icons.tips_and_updates_outlined,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              // Expanded：Row 里的 Text 不加就会撑破（§10.6）。
              Expanded(
                child: Text(
                  l10n.searchPrefixesHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
