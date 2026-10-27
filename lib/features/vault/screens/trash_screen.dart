import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../client/api_providers.dart';
import '../../../data/models/vault_item.dart';
import '../../../l10n/app_localizations.dart';
import '../providers/vault_provider.dart';
import '../widgets/entry_type_bits.dart';

/// 回收站（schema 5 / 3.1.0）。
///
/// 语义：**删除 = 移到回收站**（只写 `deleted_at`，密文不动）。这里能"恢复"
/// 或"彻底删除"；彻底删除是用户独占的决定 —— 智能体工具面里没有它
/// （`delete_entry` 只会把条目删进这里）。
///
/// 数据只走 `VaultApi`（`listTrash` / `restoreItem` / `permanentlyDeleteItem` /
/// `emptyTrash`），并由核心的 `items` 主题推送驱动重取 —— 与主列表同一套机制，
/// 不手动 invalidate。
class TrashScreen extends ConsumerWidget {
  const TrashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final trashAsync = ref.watch(trashItemsProvider);
    final items = trashAsync.valueOrNull ?? const <VaultItem>[];

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.trashTitle),
        actions: [
          if (items.isNotEmpty)
            TextButton.icon(
              onPressed: () => _confirmEmptyTrash(context, ref, items.length),
              icon: const Icon(Icons.delete_forever, size: 20),
              label: Text(l10n.trashEmptyAction),
              style: TextButton.styleFrom(foregroundColor: scheme.error),
            ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.trashSubtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (items.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${items.length}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: trashAsync.when(
              // 刷新期间继续显示上一份列表，不闪加载圈（与详情页同款纪律）。
              skipLoadingOnReload: true,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(l10n.failedWithError('$error')),
                ),
              ),
              data: (items) => items.isEmpty
                  ? const _EmptyTrash()
                  : _buildList(context, ref, items),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    WidgetRef ref,
    List<VaultItem> items,
  ) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 76),
      itemBuilder: (context, index) {
        final item = items[index];
        final accent = EntryTypeBits.color(item.type);
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: accent.withValues(alpha: 0.14),
            child: Icon(EntryTypeBits.icon(item.type), color: accent, size: 20),
          ),
          title: Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${EntryTypeBits.label(l10n, item.type)} · '
            '${l10n.trashDeletedAt(_formatDeletedAt(item.deletedAt ?? item.updatedAt))}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 恢复与彻底删除都用图标按钮：之前一个是文字、一个是图标，
              // 视觉上不齐（用户指出）。
              IconButton(
                tooltip: l10n.trashRestore,
                icon: Icon(Icons.restore, color: scheme.primary),
                onPressed: () => _restore(context, ref, item),
              ),
              IconButton(
                tooltip: l10n.trashDeletePermanently,
                icon: Icon(Icons.delete_forever, color: scheme.error),
                onPressed: () => _confirmPermanentDelete(context, ref, item),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _restore(
    BuildContext context,
    WidgetRef ref,
    VaultItem item,
  ) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final api = ref.read(vaultApiProvider);
    try {
      await api.restoreItem(item.id);
      messenger.showSnackBar(SnackBar(content: Text(l10n.trashRestored(item.name))));
    } catch (error) {
      // 失败就明说：静默失败会让人以为"恢复按钮是死的"。
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.failedWithError('$error'))),
      );
    }
  }

  Future<void> _confirmPermanentDelete(
    BuildContext context,
    WidgetRef ref,
    VaultItem item,
  ) async {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final messenger = ScaffoldMessenger.of(context);
    final api = ref.read(vaultApiProvider);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.trashDeletePermanentlyTitle),
        content: Text(l10n.trashDeletePermanentlyMessage(item.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.trashDeletePermanently),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await api.permanentlyDeleteItem(item.id);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.trashDeletedPermanently(item.name))),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.failedWithError('$error'))),
      );
    }
  }

  Future<void> _confirmEmptyTrash(
    BuildContext context,
    WidgetRef ref,
    int count,
  ) async {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final messenger = ScaffoldMessenger.of(context);
    final api = ref.read(vaultApiProvider);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.trashEmptyConfirmTitle),
        content: Text(l10n.trashEmptyConfirmMessage('$count')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.trashEmptyAction),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final deleted = await api.emptyTrash();
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.trashEmptied('$deleted'))),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.failedWithError('$error'))),
      );
    }
  }
}

/// 回收站为空时的占位（空态要有出路：说明"删除的东西会来这里"）。
class _EmptyTrash extends StatelessWidget {
  const _EmptyTrash();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.delete_sweep_outlined,
              size: 56,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.trashEmptyTitle,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.trashEmptyMessage,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// `deleted_at` 的展示格式：本地时间 `yyyy-MM-dd HH:mm`。
///
/// 手写而不是 `DateFormat`：只有数字成分，不依赖 locale 数据初始化，
/// widget 测试里也不需要 `initializeDateFormatting`。
String _formatDeletedAt(int milliseconds) {
  final at = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}';
}
