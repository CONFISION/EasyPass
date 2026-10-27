import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/client/api_providers.dart';
import 'package:easypass/features/settings/screens/agent_audit_screen.dart';
import 'package:easypass/features/settings/widgets/agent_approval_host.dart';
import 'package:easypass/l10n/app_localizations.dart';

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

    testWidgets('没有条目时（status 之类）不显示条目标签', (tester) async {
      await pumpApprovalHost(tester);
      api.emitAgentApproval(approvalRequest(entryName: null));
      await tester.pumpAndSettle();

      expect(find.text(l10n.agentApprovalEntry), findsNothing);
      expect(find.text(l10n.agentApprovalTitle), findsOneWidget);
    });

    testWidgets('拒绝按钮是红色实心，且按钮竖排（同意在上、拒绝在下）', (tester) async {
      await pumpApprovalHost(tester);
      api.emitAgentApproval(approvalRequest());
      await tester.pumpAndSettle();

      final denyFinder =
          find.widgetWithText(FilledButton, l10n.agentApprovalDeny);
      final deny = tester.widget<FilledButton>(denyFinder);
      final context = tester.element(denyFinder);
      final scheme = Theme.of(context).colorScheme;

      expect(
        deny.style?.backgroundColor?.resolve(<WidgetState>{}),
        scheme.error,
        reason: '拒绝必须是红色背景，比"同意"更显眼',
      );
      expect(
        deny.style?.foregroundColor?.resolve(<WidgetState>{}),
        scheme.onError,
      );

      final allowY = tester
          .getCenter(find.widgetWithText(FilledButton, l10n.agentApprovalAllow))
          .dy;
      final denyY = tester.getCenter(denyFinder).dy;
      expect(allowY, lessThan(denyY), reason: '按钮必须竖排，拒绝放最下面');

      // 竖排 + 占满宽度：两者宽度应基本一致。
      final allowWidth = tester
          .getSize(find.widgetWithText(FilledButton, l10n.agentApprovalAllow))
          .width;
      expect((allowWidth - tester.getSize(denyFinder).width).abs(),
          lessThan(1.0));
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
