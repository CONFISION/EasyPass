import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/client/api_providers.dart';
import 'package:easypass/features/settings/screens/agent_audit_screen.dart';
import 'package:easypass/features/settings/widgets/agent_approval_host.dart';
import 'package:easypass/l10n/app_localizations.dart';
import 'package:easypass/protocol/protocol.dart' show Topics;

import 'fake_vault_api.dart';

/// 方式 1 的审批弹窗 + 审计查看页。
///
/// 审批弹窗是**唯一**让用户看见"智能体想干什么"的地方，所以断言的重点是
/// **信息完整**（昵称 / 操作 / 条目都在）与**回话正确**（拒绝时确实回了 false）。
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

  Future<void> pumpApprovalHost(WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        AgentApprovalHost(
          child: const Scaffold(body: Center(child: Text('underlying'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> approvalRequest({
    String op = 'read',
    bool allowStanding = true,
    String? entryName = 'GitHub',
  }) =>
      {
        'event': 'agentApprovalRequested',
        'approvalId': 'a_1',
        'nickname': 'DSH',
        'tool': 'list_entries',
        'op': op,
        'entryId': entryName == null ? null : 'e1',
        'entryName': entryName,
        'allowStanding': allowStanding,
      };

  group('审批弹窗', () {
    testWidgets('弹出并完整展示昵称 / 操作 / 条目', (tester) async {
      await pumpApprovalHost(tester);

      api.emitAgentApproval(approvalRequest());
      await tester.pumpAndSettle();

      expect(find.text(l10n.agentApprovalTitle), findsOneWidget);
      expect(find.text('DSH'), findsOneWidget);
      expect(find.text(l10n.agentApprovalOpRead), findsOneWidget);
      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('list_entries'), findsOneWidget);
    });

    testWidgets('拒绝 ⇒ 回话 allow:false', (tester) async {
      await pumpApprovalHost(tester);
      api.emitAgentApproval(approvalRequest());
      await tester.pumpAndSettle();

      await tester.tap(find.text(l10n.agentApprovalDeny));
      await tester.pumpAndSettle();

      expect(api.approvalResponses.single['allow'], isFalse);
      expect(find.text(l10n.agentApprovalTitle), findsNothing);
    });

    testWidgets('同意 ⇒ 回话 allow:true，且不带免询问', (tester) async {
      await pumpApprovalHost(tester);
      api.emitAgentApproval(approvalRequest());
      await tester.pumpAndSettle();

      await tester.tap(find.text(l10n.agentApprovalAllow));
      await tester.pumpAndSettle();

      expect(api.approvalResponses.single['allow'], isTrue);
      expect(api.approvalResponses.single['allowStandingRead'], isFalse);
    });

    testWidgets('普通读显示「本会话内允许读取」，点了会带上 standing', (tester) async {
      await pumpApprovalHost(tester);
      api.emitAgentApproval(approvalRequest());
      await tester.pumpAndSettle();

      expect(find.text(l10n.agentApprovalAllowStanding), findsOneWidget);
      await tester.tap(find.text(l10n.agentApprovalAllowStanding));
      await tester.pumpAndSettle();

      expect(api.approvalResponses.single['allow'], isTrue);
      expect(api.approvalResponses.single['allowStandingRead'], isTrue);
    });

    testWidgets('敏感读**没有**「本会话内允许读取」按钮，操作显示为读取机密', (tester) async {
      await pumpApprovalHost(tester);
      api.emitAgentApproval(
        approvalRequest(op: 'sensitiveRead', allowStanding: false),
      );
      await tester.pumpAndSettle();

      expect(find.text(l10n.agentApprovalAllowStanding), findsNothing);
      expect(find.text(l10n.agentApprovalOpSensitiveRead), findsOneWidget);
    });

    testWidgets('写操作弹窗展示「详细」行（只有字段名），且没有免询问按钮', (tester) async {
      await pumpApprovalHost(tester);
      api.emitAgentApproval({
        ...approvalRequest(op: 'write', allowStanding: false),
        'tool': 'update_entry',
        'detail': '修改字段：url、password',
      });
      await tester.pumpAndSettle();

      expect(find.text(l10n.agentApprovalOpWrite), findsOneWidget);
      expect(find.text(l10n.agentApprovalDetail), findsOneWidget);
      expect(find.text('修改字段：url、password'), findsOneWidget);
      // 写操作永远没有「本会话内允许读取」。
      expect(find.text(l10n.agentApprovalAllowStanding), findsNothing);
      expect(find.text(l10n.agentApprovalAllow), findsOneWidget);
      expect(find.text(l10n.agentApprovalDeny), findsOneWidget);
    });

    testWidgets('删除操作弹窗写明"移入回收站、可恢复"', (tester) async {
      await pumpApprovalHost(tester);
      api.emitAgentApproval({
        ...approvalRequest(op: 'delete', allowStanding: false),
        'tool': 'delete_entry',
        'detail': '移到回收站（可恢复，不会彻底删除）',
      });
      await tester.pumpAndSettle();

      expect(find.text(l10n.agentApprovalOpDelete), findsOneWidget);
      expect(
        find.text('移到回收站（可恢复，不会彻底删除）'),
        findsOneWidget,
      );
      expect(find.text(l10n.agentApprovalAllowStanding), findsNothing);
    });

    testWidgets('没有条目时（status 之类）不显示条目标签', (tester) async {
      await pumpApprovalHost(tester);
      api.emitAgentApproval(approvalRequest(entryName: null));
      await tester.pumpAndSettle();

      expect(find.text(l10n.agentApprovalEntry), findsNothing);
      expect(find.text(l10n.agentApprovalTitle), findsOneWidget);
    });

    testWidgets('按钮横排一行（同意 → 本会话内允许读取 → 拒绝），拒绝红色实心且最显眼',
        (tester) async {
      await pumpApprovalHost(tester);
      api.emitAgentApproval(approvalRequest());
      await tester.pumpAndSettle();

      final allowFinder =
          find.widgetWithText(FilledButton, l10n.agentApprovalAllow);
      final standingFinder =
          find.widgetWithText(FilledButton, l10n.agentApprovalAllowStanding);
      final denyFinder =
          find.widgetWithText(FilledButton, l10n.agentApprovalDeny);

      // 拒绝必须是红色实心：红底 + onError 前景，比"同意"更显眼。
      final deny = tester.widget<FilledButton>(denyFinder);
      final scheme = Theme.of(tester.element(denyFinder)).colorScheme;
      expect(
        deny.style?.backgroundColor?.resolve(<WidgetState>{}),
        scheme.error,
        reason: '拒绝必须是红色背景，比"同意"更显眼',
      );
      expect(
        deny.style?.foregroundColor?.resolve(<WidgetState>{}),
        scheme.onError,
      );

      // 横排：三个按钮中心同一条水平线，且从左到右依次是 同意 → 允许读取 → 拒绝。
      final allowRect = tester.getRect(allowFinder);
      final standingRect = tester.getRect(standingFinder);
      final denyRect = tester.getRect(denyFinder);
      expect((allowRect.center.dy - denyRect.center.dy).abs(), lessThan(1.0),
          reason: '按钮必须横排，不能竖着堆');
      expect((standingRect.center.dy - denyRect.center.dy).abs(), lessThan(1.0));
      expect(allowRect.center.dx, lessThan(standingRect.center.dx));
      expect(standingRect.center.dx, lessThan(denyRect.center.dx));

      // 弹窗要够宽，横排才不憋屈（用户明确要求加宽，不要小气）。
      expect(
        tester.getSize(find.byKey(agentApprovalContentKey)).width,
        greaterThan(480),
        reason: '弹窗内容区加宽到 520，三个按钮才有资格横排',
      );
    });
  });

  group('审计查看页', () {
    Future<void> pumpAudit(WidgetTester tester) async {
      await tester.pumpWidget(wrap(const AgentAuditScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets('空表显示占位', (tester) async {
      await pumpAudit(tester);
      expect(find.text(l10n.agentAuditEmpty), findsOneWidget);
    });

    testWidgets('新审计记录通过主题推送实时出现在页面上（不用手动刷新）', (tester) async {
      await pumpAudit(tester);
      expect(find.text(l10n.agentAuditEmpty), findsOneWidget);

      api.agentAudit.add({
        'at': DateTime(2026, 10, 28, 2, 1, 2).millisecondsSinceEpoch,
        'nickname': 'DSH',
        'mode': 'approval',
        'tool': 'create_entry',
        'op': 'write',
        'entryId': 'e9',
        'entryName': '新建的条目',
        'decision': 'allowed',
      });
      // 核心每写一条审计都会广播这个主题；UI 订阅后自动重取。
      api.emitChange(Topics.agentAudit);
      await tester.pumpAndSettle();

      expect(find.textContaining('DSH'), findsOneWidget);
      expect(find.textContaining('create_entry'), findsOneWidget);
      expect(find.text(l10n.agentAuditEmpty), findsNothing);
    });

    testWidgets('显示昵称 / 工具 / 条目 / 结果', (tester) async {
      api.agentAudit.add({
        'at': DateTime(2026, 10, 27, 23, 5, 30).millisecondsSinceEpoch,
        'nickname': 'DSH',
        'mode': 'trusted',
        'tool': 'copy_to_clipboard',
        'op': 'sensitiveRead',
        'entryId': 'e1',
        'entryName': 'GitHub',
        'decision': 'allowed',
      });
      await pumpAudit(tester);

      expect(find.textContaining('DSH'), findsOneWidget);
      expect(find.textContaining('GitHub'), findsOneWidget);
      expect(find.textContaining(l10n.agentAuditDecisionAllowed), findsWidgets);
      expect(find.text(l10n.agentAuditCount('1')), findsOneWidget);
    });

    testWidgets('拒绝的记录用不同文案', (tester) async {
      api.agentAudit.add({
        'at': DateTime(2026, 10, 27, 23, 6).millisecondsSinceEpoch,
        'nickname': 'DSH',
        'mode': 'approval',
        'tool': 'list_entries',
        'op': 'read',
        'entryId': null,
        'entryName': null,
        'decision': 'denied',
      });
      await pumpAudit(tester);

      expect(find.textContaining(l10n.agentAuditDecisionDenied), findsWidgets);
    });
  });
}
