import 'package:flutter/material.dart';

import '../../../data/database/database.dart';

class EntryCard extends StatelessWidget {
  final PasswordEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onCopyPassword;

  const EntryCard({
    super.key,
    required this.entry,
    required this.onTap,
    this.onCopyPassword,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasUrl = entry.url.isNotEmpty;
    final hasUsername = entry.username.isNotEmpty;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(
            Icons.language,
            color: theme.colorScheme.onPrimaryContainer,
            size: 24,
          ),
        ),
        title: Text(
          entry.name,
          style: theme.textTheme.titleMedium,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasUsername)
              Text(
                entry.username,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            if (hasUrl)
              Text(
                entry.url,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (entry.isFavorite)
              Icon(
                Icons.star,
                color: Colors.amber,
                size: 20,
              ),
            if (onCopyPassword != null)
              IconButton(
                icon: Icon(
                  Icons.copy,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                onPressed: onCopyPassword,
                tooltip: 'Copy password',
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