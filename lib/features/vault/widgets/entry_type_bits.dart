import 'package:flutter/material.dart';

import '../../../data/models/entry_type.dart';
import '../../../l10n/app_localizations.dart';

/// 条目类型的展示约定（图标 / 强调色 / 文案）。
///
/// 列表、徽章、筛选器、表单选择器、详情页**统一从这里取**，
/// 避免同一份"类型 → 图标"的映射在五个文件里各写一遍、各长一个样。
class EntryTypeBits {
  const EntryTypeBits._();

  static IconData icon(EntryType type) {
    switch (type) {
      case EntryType.login:
        return Icons.language;
      case EntryType.secureNote:
        return Icons.sticky_note_2_outlined;
      case EntryType.identity:
        return Icons.badge_outlined;
      case EntryType.sshKey:
        return Icons.terminal;
    }
  }

  /// 固定强调色（亮/暗主题下都可读，不依赖 ColorScheme 的具体取值）。
  static Color color(EntryType type) {
    switch (type) {
      case EntryType.login:
        return const Color(0xFF3B82F6); // blue
      case EntryType.secureNote:
        return const Color(0xFFF59E0B); // amber
      case EntryType.identity:
        return const Color(0xFF8B5CF6); // violet
      case EntryType.sshKey:
        return const Color(0xFF10B981); // emerald
    }
  }

  static String label(AppLocalizations l10n, EntryType type) {
    switch (type) {
      case EntryType.login:
        return l10n.entryTypeLogin;
      case EntryType.secureNote:
        return l10n.entryTypeSecureNote;
      case EntryType.identity:
        return l10n.entryTypeIdentity;
      case EntryType.sshKey:
        return l10n.entryTypeSshKey;
    }
  }

  /// 类型选择器里的说明文案。
  static String description(AppLocalizations l10n, EntryType type) {
    switch (type) {
      case EntryType.login:
        return l10n.entryTypeLoginDesc;
      case EntryType.secureNote:
        return l10n.entryTypeSecureNoteDesc;
      case EntryType.identity:
        return l10n.entryTypeIdentityDesc;
      case EntryType.sshKey:
        return l10n.entryTypeSshKeyDesc;
    }
  }

  /// 小圆角徽章（列表、详情页标题旁都能用）。
  static Widget badge(
    BuildContext context,
    EntryType type, {
    bool compact = false,
  }) {
    final l10n = AppLocalizations.of(context);
    final color = EntryTypeBits.color(type);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon(type), size: compact ? 12 : 14, color: color),
          const SizedBox(width: 4),
          Text(
            label(l10n, type),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

/// 条目类型选择器（**下拉菜单**，与表单里其它字段保持同一套外观）。
///
/// 2.3.1 起从"四张卡片平铺"改成下拉：平铺在窄窗口里占三行、和周围输入框
/// 风格也不一致。彩色图标保留 —— 每个菜单项与选中项都带类型色图标。
///
/// [enabled] 为 false 时下拉不可点；**切换类型的二次确认由调用方负责**
/// （文案见 `entryTypeSwitchTitle` 等键）。
///
/// 这里用 `InputDecorator` + `DropdownButton`（**完全受控**）而不是
/// `DropdownButtonFormField`：后者自己持有一份内部状态，用户在确认框里点
/// "取消"时父层 `value` 没变、下拉却已经显示成新类型 —— 界面和真实状态对不上。
/// 受控版只认 `value`：父层不改，显示就不变。
class EntryTypeSelector extends StatelessWidget {
  const EntryTypeSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final EntryType value;
  final ValueChanged<EntryType> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final accent = EntryTypeBits.color(value);

    return InputDecorator(
      decoration: InputDecoration(
        labelText: l10n.entryTypeLabel,
        // 替代被删掉的四张卡片上的说明：一句话解释**当前**类型是什么，
        // 既保留了引导，又不再占三行。
        helperText: EntryTypeBits.description(l10n, value),
        border: const OutlineInputBorder(),
        prefixIcon: Icon(EntryTypeBits.icon(value), color: accent),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<EntryType>(
          key: const Key('entryTypeDropdown'),
          value: value,
          isExpanded: true,
          isDense: true,
          icon: const Icon(Icons.arrow_drop_down),
          items: [
            for (final type in EntryType.values)
              DropdownMenuItem<EntryType>(
                value: type,
                child: Row(
                  children: [
                    Icon(
                      EntryTypeBits.icon(type),
                      size: 18,
                      color: EntryTypeBits.color(type),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(EntryTypeBits.label(l10n, type))),
                  ],
                ),
              ),
          ],
          onChanged: enabled
              ? (type) {
                  if (type != null) onChanged(type);
                }
              : null,
        ),
      ),
    );
  }
}
