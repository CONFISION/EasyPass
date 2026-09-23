import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/features/vault/widgets/entry_type_bits.dart';
import 'package:easypass/l10n/app_localizations.dart';

/// 类型选择器（共享组件，lead 所有）：**下拉** + 彩色图标 + 完全受控。
///
/// 用户反馈："添加界面里类型选择直接摊开 4 个类型我不满意，做成下拉菜单，
/// icon 是彩色的我比较满意，其余 UI 元素和其他元素保持一致。"
void main() {
  Future<void> pumpSelector(
    WidgetTester tester, {
    required EntryType value,
    required ValueChanged<EntryType> onChanged,
    bool enabled = true,
  }) {
    return tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: EntryTypeSelector(
            value: value,
            onChanged: onChanged,
            enabled: enabled,
          ),
        ),
      ),
    ));
  }

  testWidgets('是下拉而不是平铺的四张卡片，且每一项都带彩色图标', (tester) async {
    await pumpSelector(
      tester,
      value: EntryType.login,
      onChanged: (_) {},
    );

    expect(find.byType(DropdownButton<EntryType>), findsOneWidget);
    // 平铺版会把四个类型的说明各渲染一份；下拉收起时只有当前类型那一行 + 它的辅助说明
    final l10n = AppLocalizations.of(tester.element(find.byType(EntryTypeSelector)));
    expect(find.text(l10n.entryTypeSecureNoteDesc), findsNothing);
    expect(find.text(l10n.entryTypeIdentityDesc), findsNothing);
    expect(find.text(l10n.entryTypeSshKeyDesc), findsNothing);
    expect(find.text(l10n.entryTypeLoginDesc), findsOneWidget);

    final dropdown = tester.widget<DropdownButton<EntryType>>(
      find.byType(DropdownButton<EntryType>),
    );
    expect(dropdown.items, hasLength(EntryType.values.length));
    expect(dropdown.value, EntryType.login);

    // 展开后四个类型都在，且图标是带颜色的（不是默认单色）
    await tester.tap(find.byType(DropdownButton<EntryType>));
    await tester.pumpAndSettle();
    for (final type in EntryType.values) {
      expect(find.text(EntryTypeBits.label(AppLocalizations.of(
        tester.element(find.byType(EntryTypeSelector)),
      ), type)), findsWidgets);
    }
    final icons = tester
        .widgetList<Icon>(find.byIcon(EntryTypeBits.icon(EntryType.sshKey)))
        .toList();
    expect(icons, isNotEmpty);
    expect(icons.first.color, EntryTypeBits.color(EntryType.sshKey),
        reason: '彩色图标是用户明确满意、要保留的部分');
  });

  testWidgets('完全受控：父层不改 value，显示就不跟着变（取消切换不串状态）', (tester) async {
    EntryType parentValue = EntryType.login;
    final picks = <EntryType>[];

    await pumpSelector(
      tester,
      value: parentValue,
      onChanged: picks.add,
    );

    await tester.tap(find.byType(DropdownButton<EntryType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Secure note').last);
    await tester.pumpAndSettle();

    // 父层收到了选择，但**没有**采纳（模拟用户在确认框点了取消）
    expect(picks, [EntryType.secureNote]);
    final dropdown = tester.widget<DropdownButton<EntryType>>(
      find.byType(DropdownButton<EntryType>),
    );
    expect(dropdown.value, EntryType.login,
        reason: 'DropdownButtonFormField 会在这里显示成 secure note，和真实状态错位');

    // 父层采纳后才跟着变
    await pumpSelector(tester, value: EntryType.secureNote, onChanged: picks.add);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButton<EntryType>>(find.byType(DropdownButton<EntryType>))
          .value,
      EntryType.secureNote,
    );
  });

  testWidgets('辅助说明跟着当前类型走（保留一句话引导，不再占三行）', (tester) async {
    AppLocalizations l10n() =>
        AppLocalizations.of(tester.element(find.byType(EntryTypeSelector)));

    await pumpSelector(tester, value: EntryType.login, onChanged: (_) {});
    expect(find.text(l10n().entryTypeLoginDesc), findsOneWidget);

    await pumpSelector(tester, value: EntryType.sshKey, onChanged: (_) {});
    expect(find.text(l10n().entryTypeSshKeyDesc), findsOneWidget);
    expect(find.text(l10n().entryTypeLoginDesc), findsNothing,
        reason: '辅助说明必须反映当前选中的类型');
  });

  testWidgets('enabled=false 时不可点（编辑态由父层决定是否允许换类型）', (tester) async {
    var called = 0;
    await pumpSelector(
      tester,
      value: EntryType.identity,
      onChanged: (_) => called++,
      enabled: false,
    );

    // 收起状态下按钮里本来就有当前项的 DropdownMenuItem，
    // 所以用"点击前后菜单是否多出来"判断有没有真的展开。
    final collapsedItems = find.byType(DropdownMenuItem<EntryType>).evaluate().length;
    await tester.tap(find.byType(DropdownButton<EntryType>));
    await tester.pumpAndSettle();

    expect(called, 0);
    expect(find.byType(DropdownMenuItem<EntryType>).evaluate().length, collapsedItems,
        reason: '禁用时不应展开菜单');
  });
}
