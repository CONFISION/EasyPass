import 'package:flutter/material.dart';

import '../../../data/models/entry_fields.dart';
import '../../../l10n/app_localizations.dart';

/// 自定义字段的只读展示（详情页用）。
///
/// - 隐藏型字段默认打码，点眼睛才显示（本组件自带状态，不外泄明文）；
/// - 勾选型字段显示勾 / 叉；
/// - 每行可复制（[onCopy] 由页面提供，用于弹"已复制"提示）。
class CustomFieldsView extends StatelessWidget {
  const CustomFieldsView({
    super.key,
    required this.fields,
    this.onCopy,
  });

  final List<CustomField> fields;

  /// 复制回调（传入要复制的值）；为空时不显示复制按钮。
  final ValueChanged<String>? onCopy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final visible = fields.where((f) => !f.isEmpty).toList(growable: false);
    if (visible.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.customFieldsSection,
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        for (final field in visible) _CustomFieldRow(field: field, onCopy: onCopy),
      ],
    );
  }
}

class _CustomFieldRow extends StatefulWidget {
  const _CustomFieldRow({required this.field, this.onCopy});

  final CustomField field;
  final ValueChanged<String>? onCopy;

  @override
  State<_CustomFieldRow> createState() => _CustomFieldRowState();
}

class _CustomFieldRowState extends State<_CustomFieldRow> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final field = widget.field;
    final isHidden = field.type == CustomFieldType.hidden;

    final String display;
    if (field.isBoolean) {
      display = field.booleanValue ? '✓' : '✗';
    } else if (isHidden && !_revealed) {
      display = '••••••••';
    } else {
      display = field.value;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              field.label.isEmpty ? '—' : field.label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              display.isEmpty ? '—' : display,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (isHidden)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: _revealed
                  ? AppLocalizations.of(context).hidePasswordTooltip
                  : AppLocalizations.of(context).revealPasswordTooltip,
              icon: Icon(
                _revealed ? Icons.visibility_off : Icons.visibility,
                size: 18,
              ),
              onPressed: () => setState(() => _revealed = !_revealed),
            ),
          if (widget.onCopy != null && field.value.isNotEmpty)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: AppLocalizations.of(context).copyFieldTooltip(field.label),
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () => widget.onCopy!(field.value),
            ),
        ],
      ),
    );
  }
}
