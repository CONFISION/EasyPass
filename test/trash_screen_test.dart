import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/client/api_providers.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/features/vault/screens/trash_screen.dart';
import 'package:easypass/l10n/app_localizations.dart';

import 'fake_vault_api.dart';

/// 回收站界面（schema 5）：删除的条目在这里能恢复 / 彻底删除 / 清空。
///
/// 断言重点不是像素，而是**动作真的发给了核心**、且危险动作必须过确认框
/// （回收站里点错"彻底删除"是不可恢复的，不能一步到位）。
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  late FakeVaultApi api;
  late ProviderContainer container;

  setUp(() {
    api = FakeVaultApi(initialStatus: 'unlocked');
    container = ProviderContainer(
      overrides: [vaultApiProvider.overrideWithValue(api)],
    );
  });

  tearDown(() {
    container.dispose();
    api.dispose();
  });

  Widget wrap(Widget child) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: child,
        ),
      );

  VaultItem trashed({
    String id = 't1',
    String name = '已删除的 GitHub',
    int deletedAt = 1793120000000,
  }) {
    return VaultItem(
      id: id,
      type: EntryType.login,
      name: name,
      notes: '不该显示的备注',
      login: const LoginData(username: 'alice'),
      createdAt: 1,
      updatedAt: 1,
      deletedAt: deletedAt,
    );
  }

  Future<void> pumpTrash(WidgetTester tester) async {
    await tester.pumpWidget(wrap(const TrashScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('空回收站显示占位文案', (tester) async {
    await pumpTrash(tester);

    expect(find.text(l10n.trashTitle), findsOneWidget);
    expect(find.text(l10n.trashEmptyTitle), findsOneWidget);
    expect(find.text(l10n.trashEmptyMessage), findsOneWidget);
    // 空的时候不该出现"清空回收站"动作。
    expect(find.text(l10n.trashEmptyAction), findsNothing);
  });

  testWidgets('列出已删除条目：名称 / 类型 / 删除时间，且不展示备注内容', (tester) async {
    api.trash['t1'] = trashed();
    await pumpTrash(tester);

    expect(find.text('已删除的 GitHub'), findsOneWidget);
    expect(find.textContaining(l10n.entryTypeLogin), findsOneWidget);
    // 删除时间按本地时间渲染成 yyyy-MM-dd HH:mm（手写格式化，不依赖 intl 数据）。
    expect(find.textContaining('2026-'), findsOneWidget);
    expect(find.text('不该显示的备注'), findsNothing,
        reason: '回收站列表是元数据视图，不是详情页');
    // 两个动作入口都得看得见（桌面端不做隐藏手势）。
    expect(find.text(l10n.trashRestore), findsOneWidget);
    expect(find.byTooltip(l10n.trashDeletePermanently), findsOneWidget);
  });

  testWidgets('恢复：调用核心 restoreItem，条目从回收站消失并提示', (tester) async {
    api.trash['t1'] = trashed();
    await pumpTrash(tester);

    await tester.tap(find.text(l10n.trashRestore));
    await tester.pumpAndSettle();

    expect(api.calls, contains('restoreItem'));
    final item = await api.getItem('t1');
    expect(item, isNotNull, reason: '恢复后回到正常列表');
    expect(api.trash, isEmpty);
    expect(find.text(l10n.trashRestored('已删除的 GitHub')), findsOneWidget);
  });

  testWidgets('彻底删除必须过确认框', (tester) async {
    api.trash['t1'] = trashed();
    await pumpTrash(tester);

    await tester.tap(find.byTooltip(l10n.trashDeletePermanently));
    await tester.pumpAndSettle();

    expect(find.text(l10n.trashDeletePermanentlyTitle), findsOneWidget);
    expect(find.text(l10n.cancel), findsOneWidget);

    // 取消：什么都不发生。
    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    expect(api.calls, isNot(contains('permanentlyDeleteItem')));
    expect(api.trash, hasLength(1));

    await tester.tap(find.byTooltip(l10n.trashDeletePermanently));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, l10n.trashDeletePermanently));
    await tester.pumpAndSettle();

    expect(api.calls, contains('permanentlyDeleteItem'));
    expect(api.trash, isEmpty);
    expect(
      find.text(l10n.trashDeletedPermanently('已删除的 GitHub')),
      findsOneWidget,
    );
  });

  testWidgets('清空回收站必须过确认框，并显示删除条数', (tester) async {
    api.trash['t1'] = trashed(id: 't1');
    api.trash['t2'] = trashed(id: 't2', name: '第二条');
    await pumpTrash(tester);

    await tester.tap(find.text(l10n.trashEmptyAction));
    await tester.pumpAndSettle();
    expect(find.text(l10n.trashEmptyConfirmTitle), findsOneWidget);
    expect(
      find.text(l10n.trashEmptyConfirmMessage('2')),
      findsOneWidget,
      reason: '危险动作必须说清影响范围',
    );

    await tester.tap(find.widgetWithText(FilledButton, l10n.trashEmptyAction));
    await tester.pumpAndSettle();

    expect(api.calls, contains('emptyTrash'));
    expect(api.trash, isEmpty);
    expect(find.text(l10n.trashEmptied('2')), findsOneWidget);
    expect(find.text(l10n.trashEmptyTitle), findsOneWidget);
  });

  testWidgets('核心不可达时显示错误，而不是伪装成空回收站', (tester) async {
    api.readFailure = StateError('core down');
    await pumpTrash(tester);

    expect(find.text(l10n.trashEmptyTitle), findsNothing);
    expect(find.textContaining('core down'), findsOneWidget);
  });
}
