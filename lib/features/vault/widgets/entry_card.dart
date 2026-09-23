import 'package:flutter/material.dart';

import '../../../data/models/vault_item.dart';
import '../../../l10n/app_localizations.dart';
import 'entry_type_bits.dart';

/// 列表卡片：四种条目类型共用一张卡（图标 / 徽章 / 副标题按类型变化）。
///
/// 类型 → 图标 / 颜色 / 文案的映射**统一取自 [EntryTypeBits]**（表单选择器、
/// 详情页徽章用的是同一份约定），这里不再各写一套。
class EntryCard extends StatelessWidget {
  final VaultItem item;
  final VoidCallback onTap;

  /// 复制密码；只有登录条目会真正渲染出按钮（见 [VaultItem.isAutofillable]）。
  final VoidCallback? onCopyPassword;

  const EntryCard({
    super.key,
    required this.item,
    required this.onTap,
    this.onCopyPassword,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final accent = EntryTypeBits.color(item.type);
    // 副标题统一用 item.subtitle（登录→用户名/网址，身份→姓名，SSH→指纹，
    // 笔记→正文摘要），UI 不再自己挑字段。
    final subtitle = item.subtitle;
    // 复制按钮只在登录条目出现：其余类型没有"密码"可复制（契约 §4 列表）。
    final showCopyButton = item.isAutofillable && onCopyPassword != null;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        // 每类一个图标 + 一份强调色：登录=地球、笔记=便签、身份=证件、SSH=终端。
        leading: CircleAvatar(
          backgroundColor: accent.withValues(alpha: 0.14),
          child: Icon(EntryTypeBits.icon(item.type), color: accent, size: 24),
        ),
        // 标题 + 类型徽章同一行：Expanded 让长名字走 ellipsis（§10.6），
        // 徽章是定宽小标签，拿固有宽度即可。
        title: Row(
          children: [
            Expanded(
              child: Text(
                item.name,
                style: theme.textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            EntryTypeBits.badge(context, item.type, compact: true),
          ],
        ),
        subtitle: subtitle.isEmpty
            ? null
            : Text(
                subtitle,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item.isFavorite)
              const Icon(
                Icons.star,
                color: Colors.amber,
                size: 20,
              ),
            if (showCopyButton)
              IconButton(
                icon: Icon(
                  Icons.copy,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                onPressed: onCopyPassword,
                tooltip: l10n.copyPasswordTooltip,
              ),
            Icon(
              Icons.chevron_right,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
