import 'package:flutter/material.dart';

import '../../../data/models/entry_fields.dart';
import '../../../l10n/app_localizations.dart';

/// 自定义字段编辑器（新建 / 编辑条目共用）。
///
/// 交互：每行 = 字段名 + 类型（文本 / 隐藏 / 勾选）+ 值 + 删除；
/// 底部一个"添加字段"。类型改成勾选时，值变成开关。
///
/// 数据纪律：本组件只维护 `TextEditingController`，**每次变更**把整份
/// 列表通过 [onChanged] 抛给调用方；调用方保存时用
/// `VaultItem.effectiveCustomFields` 丢掉完全空白的行。
class CustomFieldsEditor extends StatefulWidget {
  const CustomFieldsEditor({
    super.key,
    required this.onChanged,
    this.initialFields = const [],
  });

  final List<CustomField> initialFields;
  final ValueChanged<List<CustomField>> onChanged;

  @override
  State<CustomFieldsEditor> createState() => _CustomFieldsEditorState();
}

class _CustomFieldsEditorState extends State<CustomFieldsEditor> {
  final List<_EditableField> _rows = [];

  @override
  void initState() {
    super.initState();
    for (final field in widget.initialFields) {
      _rows.add(_EditableField.from(field));
    }
    // 初始状态也要上报一次，避免"编辑既有条目但没动过字段"时丢字段。
    WidgetsBinding.instance.addPostFrameCallback((_) => _emit());
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _emit() {
    if (!mounted) return;
    widget.onChanged([
      for (final row in _rows) row.toField(),
    ]);
  }

  void _addRow() {
    setState(() {
      _rows.add(_EditableField.empty());
    });
    _emit();
  }

  void _removeRow(int index) {
    setState(() {
      _rows.removeAt(index).dispose();
    });
    _emit();
  }

  void _changeType(int index, CustomFieldType type) {
    setState(() {
      final row = _rows[index];
      if (type == CustomFieldType.boolean) {
        // 切到勾选时把已有值规范成 'true' / 'false'
        final current = row.value.text.trim().toLowerCase();
        row.value.text = (current == 'true' || current == '1') ? 'true' : 'false';
      } else if (row.type == CustomFieldType.boolean) {
        row.value.text = '';
      }
      row.type = type;
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.customFieldsSection,
                style: theme.textTheme.titleSmall,
              ),
            ),
            TextButton.icon(
              onPressed: _addRow,
              icon: const Icon(Icons.add, size: 18),
              label: Text(l10n.customFieldAdd),
            ),
          ],
        ),
        if (_rows.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              l10n.customFieldNoFields,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        for (var i = 0; i < _rows.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _rows[i].label,
                    decoration: InputDecoration(
                      labelText: l10n.customFieldLabelHint,
                      isDense: true,
                    ),
                    onChanged: (_) => _emit(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 4,
                  child: _rows[i].type == CustomFieldType.boolean
                      ? _BooleanValue(
                          value: _rows[i].booleanValue,
                          onChanged: (value) {
                            setState(() {
                              _rows[i].value.text = value ? 'true' : 'false';
                            });
                            _emit();
                          },
                        )
                      : TextFormField(
                          controller: _rows[i].value,
                          // 隐藏型在编辑态也是密码框，并给一个眼睛按钮 ——
                          // 否则"文本 / 隐藏"在界面上完全看不出差别（空值时尤其）。
                          obscureText: _rows[i].type == CustomFieldType.hidden &&
                              !_rows[i].revealed,
                          decoration: InputDecoration(
                            labelText: l10n.customFieldValueHint,
                            isDense: true,
                            border: const OutlineInputBorder(),
                            suffixIcon: _rows[i].type == CustomFieldType.hidden
                                ? IconButton(
                                    tooltip: _rows[i].revealed
                                        ? l10n.hidePasswordTooltip
                                        : l10n.revealPasswordTooltip,
                                    icon: Icon(
                                      _rows[i].revealed
                                          ? Icons.visibility_off
                                          : Icons.visibility,
                                      size: 18,
                                    ),
                                    onPressed: () => setState(
                                      () => _rows[i].revealed =
                                          !_rows[i].revealed,
                                    ),
                                  )
                                : null,
                          ),
                          onChanged: (_) => _emit(),
                        ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  // 宽度 + isExpanded 双保险：类型下拉里最长的英文项
                  // "Checkbox" 在真实字体下约 84px、在 widget 测试的等宽测试
                  // 字体下约 130px。只给宽度不够（内边距 + 箭头还要吃掉 ~28px），
                  // isExpanded 让 item 文本拿到有界宽度从而能省略号收尾，
                  // 从根上避免 RenderFlex overflow。
                  width: 150,
                  child: DropdownButtonFormField<CustomFieldType>(
                    // 按行对象本身做 key：删掉中间一行时，剩下的下拉不会
                    // "继承"上一行的选择（FormField 是按下标复用状态的）。
                    key: ValueKey<Object>(_rows[i]),
                    isExpanded: true,
                    initialValue: _rows[i].type,
                    isDense: true,
                    // 与左侧两个输入框同一套外观（带 label + 描边），
                    // 否则下拉会比它们高半行，整行看起来就是没对齐。
                    decoration: InputDecoration(
                      labelText: l10n.entryTypeLabel,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: CustomFieldType.text,
                        child: Text(
                          l10n.customFieldTypeText,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: CustomFieldType.hidden,
                        child: Text(
                          l10n.customFieldTypeHidden,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: CustomFieldType.boolean,
                        child: Text(
                          l10n.customFieldTypeBoolean,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    onChanged: (type) {
                      if (type != null) _changeType(i, type);
                    },
                  ),
                ),
                IconButton(
                  tooltip: l10n.customFieldRemove,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _removeRow(i),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _BooleanValue extends StatelessWidget {
  const _BooleanValue({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return InputDecorator(
      decoration: InputDecoration(
        labelText: l10n.customFieldValueHint,
        isDense: true,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Switch(
          value: value,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// 一行可编辑字段（控制器与类型一起管，dispose 时统一释放）。
class _EditableField {
  final TextEditingController label;
  final TextEditingController value;
  CustomFieldType type;

  /// 隐藏型在编辑态是否已点开眼睛（仅影响显示，不影响存的值）。
  bool revealed = false;

  _EditableField({
    required this.label,
    required this.value,
    required this.type,
  });

  factory _EditableField.from(CustomField field) => _EditableField(
        label: TextEditingController(text: field.label),
        value: TextEditingController(text: field.value),
        type: field.type,
      );

  factory _EditableField.empty() => _EditableField(
        label: TextEditingController(),
        value: TextEditingController(),
        type: CustomFieldType.text,
      );

  bool get booleanValue => value.text.trim().toLowerCase() == 'true';

  CustomField toField() => CustomField(
        label: label.text,
        value: type == CustomFieldType.boolean
            ? (booleanValue ? 'true' : 'false')
            : value.text,
        type: type,
      );

  void dispose() {
    label.dispose();
    value.dispose();
  }
}
