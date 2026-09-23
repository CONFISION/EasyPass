import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/features/vault/widgets/custom_fields_editor.dart';
import 'package:easypass/l10n/app_localizations.dart';

/// 自定义字段编辑器（共享组件，lead 所有）的回归测试。
///
/// 用户报的两个问题在这里钉死：
/// 1. 类型下拉没有 label、比旁边两个输入框高半行 → 整行看起来没对齐；
/// 2. 选"隐藏"以后界面上看不出任何区别（空值时尤其），
///    现在隐藏型是密码框 + 眼睛按钮。
void main() {
  Future<Widget> buildEditor(
    List<CustomField> initial,
    ValueChanged<List<CustomField>> onChanged,
  ) async {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: SingleChildScrollView(
          child: CustomFieldsEditor(initialFields: initial, onChanged: onChanged),
        ),
      ),
    );
  }

  AppLocalizations l10nOf(WidgetTester tester) {
    final context = tester.element(find.byType(CustomFieldsEditor));
    return AppLocalizations.of(context);
  }

  testWidgets('类型下拉与左侧输入框同款装饰（带 label，行内元素对齐）', (tester) async {
    await tester.pumpWidget(await buildEditor(const [], (_) {}));
    await tester.tap(find.text('Add field'));
    await tester.pumpAndSettle();

    final l10n = l10nOf(tester);
    final dropdown = tester.widget<DropdownButtonFormField<CustomFieldType>>(
      find.byType(DropdownButtonFormField<CustomFieldType>),
    );
    final decoration = dropdown.decoration;

    expect(decoration.labelText, l10n.entryTypeLabel,
        reason: '没有 label 的下拉会比旁边带 label 的输入框高半行');
    expect(decoration.border, isA<OutlineInputBorder>(),
        reason: '要和表单其它字段一样有描边');

    // 三个控件的顶边应当基本齐平（同一条基线）
    final labelTop = tester.getTopLeft(find.byType(TextFormField).at(0)).dy;
    final valueTop = tester.getTopLeft(find.byType(TextFormField).at(1)).dy;
    final dropdownTop =
        tester.getTopLeft(find.byType(DropdownButtonFormField<CustomFieldType>)).dy;
    expect((labelTop - valueTop).abs(), lessThan(1.0));
    expect((labelTop - dropdownTop).abs(), lessThan(4.0),
        reason: '下拉与输入框顶边差超过 4px 就是肉眼可见的错位');
  });

  testWidgets('选"隐藏"后值变密码框，眼睛按钮能看回来', (tester) async {
    var captured = <CustomField>[];
    await tester.pumpWidget(await buildEditor(const [], (f) => captured = f));
    await tester.tap(find.text('Add field'));
    await tester.pumpAndSettle();

    final l10n = l10nOf(tester);
    await tester.enterText(find.byType(TextFormField).at(1), 'RECOVERY-1');
    await tester.pumpAndSettle();

    // 默认文本型：明文可见、没有眼睛按钮
    expect(
      tester
          .widgetList<EditableText>(find.byType(EditableText))
          .map((w) => w.obscureText)
          .toList(),
      [false, false],
    );
    expect(find.byIcon(Icons.visibility), findsNothing);

    // 切到隐藏
    await tester.tap(find.byType(DropdownButtonFormField<CustomFieldType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.customFieldTypeHidden).last);
    await tester.pumpAndSettle();

    expect(
      tester
          .widgetList<EditableText>(find.byType(EditableText))
          .map((w) => w.obscureText)
          .toList(),
      [false, true],
      reason: '隐藏型的值输入框必须是密码框',
    );
    expect(find.byIcon(Icons.visibility), findsOneWidget,
        reason: '没有眼睛按钮，用户根本不知道里面有没有内容');
    expect(captured.single.type, CustomFieldType.hidden);

    // 点眼睛后可以明文查看，且值没有被改动
    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<EditableText>(find.byType(EditableText))
          .map((w) => w.obscureText)
          .toList(),
      [false, false],
    );
    expect(captured.single.value, 'RECOVERY-1');
  });

  testWidgets('删掉中间一行后，剩下的行不会"继承"被删行的类型', (tester) async {
    var captured = <CustomField>[];
    await tester.pumpWidget(await buildEditor(
      const [
        CustomField(label: 'A', value: '1', type: CustomFieldType.boolean),
        CustomField(label: 'B', value: '2', type: CustomFieldType.hidden),
      ],
      (f) => captured = f,
    ));
    await tester.pumpAndSettle();

    final l10n = l10nOf(tester);
    expect(captured.map((f) => '${f.label}:${f.type.name}').toList(),
        ['A:boolean', 'B:hidden']);

    // 删掉第一行（勾选型）
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();

    expect(captured.map((f) => '${f.label}:${f.type.name}').toList(), ['B:hidden'],
        reason: 'FormField 按下标复用状态，没有按行做 key 时这里会串型');
    final dropdown = tester.widget<DropdownButtonFormField<CustomFieldType>>(
      find.byType(DropdownButtonFormField<CustomFieldType>),
    );
    expect(dropdown.initialValue, CustomFieldType.hidden);
    expect(find.text(l10n.customFieldTypeHidden), findsWidgets);
  });

  testWidgets('切到勾选型：值变开关并规范成 true/false', (tester) async {
    var captured = <CustomField>[];
    await tester.pumpWidget(await buildEditor(
      const [CustomField(label: 'PIN', value: '1')],
      (f) => captured = f,
    ));
    await tester.pumpAndSettle();

    final l10n = l10nOf(tester);
    await tester.tap(find.byType(DropdownButtonFormField<CustomFieldType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.customFieldTypeBoolean).last);
    await tester.pumpAndSettle();

    expect(find.byType(Switch), findsOneWidget);
    expect(captured.single.type, CustomFieldType.boolean);
    expect(captured.single.value, 'true', reason: '"1" 要被规范成 true');

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(captured.single.value, 'false');
  });
}
