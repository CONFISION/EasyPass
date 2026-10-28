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
/// 审批弹窗是**唯一**让用户看见"智能体想干什么"的地方，所以断言的重点是：
/// - 信息完整（昵称 / 操作 / 条目 / 不截断的 detail / 清洗过的文本）；
/// - 回话正确且只作用于当前这一条（防双击、防过期、防锁屏批准）；
/// - 锁屏时不渲染、队列有上限、核心 resolved 后弹窗消失。
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
    // AuthNotifier 的启动探测是异步的：等它把状态从 loading 置成 unlocked，
    // 否则浮层按"未解锁"处理不会渲染。
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> approvalRequest({
    String approvalId = 'a_1',
    String op = 'read',
    bool allowStanding = true,
    String? entryName = 'GitHub',
    String tool = 'list_entries',
    String? detail,
    String nickname = 'DSH',
  }) =>
      {
        'event': 'agentApprovalRequested',
        'approvalId': approvalId,
        'nickname': nickname,
        'tool': tool,
        'op': op,
        'entryId': entryName == null ? null : 'e1',
        'entryName': entryName,
        'allowStanding': allowStanding,
        'detail': ?detail,
      };

  /// 推一条请求并等它上屏；[arm] = true 时再等过只读窗口（否则按钮不可点）。
  Future<void> showRequest(
    WidgetTester tester,
    Map<String, dynamic> request, {
    bool arm = true,
  }) async {
    api.emitAgentApproval(request);
    await tester.pump();
    if (arm) {
      await tester.pump(agentApprovalArmDelay + const Duration(milliseconds: 80));
      await tester.pump();
    }
  }

  group('审批弹窗', () {
    testWidgets('弹出并完整展示昵称 / 操作 / 条目', (tester) async {
      await pumpApprovalHost(tester);
      await showRequest(tester, approvalRequest());

      expect(find.text(l10n.agentApprovalTitle), findsOneWidget);
      expect(find.text('DSH'), findsOneWidget);
      expect(find.text(l10n.agentApprovalOpRead), findsOneWidget);
      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('list_entries'), findsOneWidget);
    });

    testWidgets('拒绝 ⇒ 回话 allow:false', (tester) async {
      await pumpApprovalHost(tester);
      await showRequest(tester, approvalRequest());

      await tester.tap(find.text(l10n.agentApprovalDeny));
      await tester.pumpAndSettle();

      expect(api.approvalResponses.single['allow'], isFalse);
      expect(find.text(l10n.agentApprovalTitle), findsNothing);
    });

    testWidgets('同意 ⇒ 回话 allow:true，且不带免询问', (tester) async {
      await pumpApprovalHost(tester);
      await showRequest(tester, approvalRequest());

      await tester.tap(find.text(l10n.agentApprovalAllow));
      await tester.pumpAndSettle();

      expect(api.approvalResponses.single['allow'], isTrue);
      expect(api.approvalResponses.single['allowStandingRead'], isFalse);
    });

    testWidgets('普通读显示「本会话内允许读取」，点了会带上 standing', (tester) async {
      await pumpApprovalHost(tester);
      await showRequest(tester, approvalRequest());

      expect(find.text(l10n.agentApprovalAllowStanding), findsOneWidget);
      await tester.tap(find.text(l10n.agentApprovalAllowStanding));
      await tester.pumpAndSettle();

      expect(api.approvalResponses.single['allow'], isTrue);
      expect(api.approvalResponses.single['allowStandingRead'], isTrue);
    });

    testWidgets('敏感读**没有**「本会话内允许读取」按钮，操作显示为读取机密', (tester) async {
      await pumpApprovalHost(tester);
      await showRequest(
        tester,
        approvalRequest(op: 'sensitiveRead', allowStanding: false),
      );

      expect(find.text(l10n.agentApprovalAllowStanding), findsNothing);
      expect(find.text(l10n.agentApprovalOpSensitiveRead), findsOneWidget);
    });

    testWidgets('写操作弹窗展示完整「详细」行（含核心给的 old → new），且没有免询问按钮',
        (tester) async {
      const detail = '修改字段：url（https://old.example → https://new.example）';
      await pumpApprovalHost(tester);
      await showRequest(
        tester,
        approvalRequest(
          op: 'write',
          allowStanding: false,
          tool: 'update_entry',
          detail: detail,
        ),
      );

      expect(find.text(l10n.agentApprovalOpWrite), findsOneWidget);
      expect(find.text(l10n.agentApprovalDetail), findsOneWidget);
      // 不截断：完整的 detail 作为一个 Text 渲染（maxLines 为空）。
      final detailText = tester.widget<Text>(find.text(detail));
      expect(detailText.maxLines, isNull, reason: 'detail 不允许被省略号截断');
      // 写操作永远没有「本会话内允许读取」。
      expect(find.text(l10n.agentApprovalAllowStanding), findsNothing);
      expect(find.text(l10n.agentApprovalAllow), findsOneWidget);
      expect(find.text(l10n.agentApprovalDeny), findsOneWidget);
    });

    testWidgets('删除操作弹窗写明"移入回收站、可恢复"', (tester) async {
      await pumpApprovalHost(tester);
      await showRequest(
        tester,
        approvalRequest(
          op: 'delete',
          allowStanding: false,
          tool: 'delete_entry',
          detail: '移到回收站（可恢复，不会彻底删除）',
        ),
      );

      expect(find.text(l10n.agentApprovalOpDelete), findsOneWidget);
      expect(
        find.text('移到回收站（可恢复，不会彻底删除）'),
        findsOneWidget,
      );
      expect(find.text(l10n.agentApprovalAllowStanding), findsNothing);
    });

    testWidgets('没有条目时（status 之类）不显示条目标签', (tester) async {
      await pumpApprovalHost(tester);
      await showRequest(tester, approvalRequest(entryName: null));

      expect(find.text(l10n.agentApprovalEntry), findsNothing);
      expect(find.text(l10n.agentApprovalTitle), findsOneWidget);
    });

    testWidgets('按钮横排一行（同意 → 本会话内允许读取 → 拒绝），拒绝红色实心且最显眼',
        (tester) async {
      await pumpApprovalHost(tester);
      await showRequest(tester, approvalRequest());

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

    testWidgets('控制字符/RTL/零宽字符以可见转义渲染，不能伪造换行或翻转文本', (tester) async {
      await pumpApprovalHost(tester);
      await showRequest(
        tester,
        approvalRequest(
          op: 'write',
          allowStanding: false,
          tool: 'update_entry',
          entryName: '银行\n\u202Egnp.exe',
          detail: '修改字段：name\n（已授权）\u200B',
        ),
      );

      // 渲染出来的所有 Text 里都不能再出现真实的换行/双向控制符/零宽字符。
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data ?? '')
          .toList();
      expect(texts.any((text) => text.contains('\n')), isFalse);
      expect(texts.any((text) => text.contains('\u202E')), isFalse);
      expect(texts.any((text) => text.contains('\u200B')), isFalse);
      // 转义后可见。
      expect(find.textContaining(r'\n'), findsWidgets);
      expect(find.textContaining(r'\u202E'), findsWidgets);
    });

    testWidgets('只读窗口内点击无效（防"弹窗一闪就点"）', (tester) async {
      await pumpApprovalHost(tester);
      api.emitAgentApproval(approvalRequest());
      // 广播流事件经微任务送达；两次 pump 保证"事件已处理 + 新帧已构建"。
      await tester.pump();
      await tester.pump();

      // 还没过 arming 延迟：按钮是禁用的，点击不产生任何回应。
      expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, l10n.agentApprovalAllow))
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.text(l10n.agentApprovalAllow),
        warnIfMissed: false,
      );
      await tester.pump();

      expect(api.approvalResponses, isEmpty);

      await tester.pump(agentApprovalArmDelay + const Duration(milliseconds: 80));
      await tester.pump();
      await tester.tap(find.text(l10n.agentApprovalAllow));
      await tester.pumpAndSettle();

      expect(api.approvalResponses.single['approvalId'], 'a_1');
    });

    testWidgets('一次双击只批准当前这一条：下一条必须重新过 arming 窗口', (tester) async {
      await pumpApprovalHost(tester);
      api.emitAgentApproval(approvalRequest(approvalId: 'a_1'));
      api.emitAgentApproval(
        approvalRequest(approvalId: 'a_2', entryName: 'GitHub-2'),
      );
      await tester.pump();
      await tester.pump(agentApprovalArmDelay + const Duration(milliseconds: 80));
      await tester.pump();

      // 第一条提示"第 1 / 2 条"。
      expect(find.text(l10n.agentApprovalQueuePosition('1', '2')), findsOneWidget);

      // 第一次点击批准 a_1；回车/双击的第二次点击落在下一条的同一位置，
      // 但那时下一条还在只读窗口里，必须被丢弃。
      await tester.tap(find.text(l10n.agentApprovalAllow));
      await tester.pump();
      await tester.tap(
        find.text(l10n.agentApprovalAllow),
        warnIfMissed: false,
      );
      await tester.pump();

      expect(api.approvalResponses, hasLength(1));
      expect(api.approvalResponses.single['approvalId'], 'a_1');

      // 过 arming 窗口后，第二条才可点。
      await tester.pump(agentApprovalArmDelay + const Duration(milliseconds: 80));
      await tester.pump();
      await tester.tap(find.text(l10n.agentApprovalAllow));
      await tester.pumpAndSettle();

      expect(api.approvalResponses, hasLength(2));
      expect(api.approvalResponses.last['approvalId'], 'a_2');
    });

    testWidgets('回话前先 touchActivity（审批交互要续期 UI 空闲计时）', (tester) async {
      await pumpApprovalHost(tester);
      await showRequest(tester, approvalRequest());

      await tester.tap(find.text(l10n.agentApprovalAllow));
      await tester.pumpAndSettle();

      expect(api.calls, contains('touchActivity'));
      expect(
        api.callIndex('touchActivity'),
        lessThan(api.callIndex('respondAgentApproval')),
      );
    });

    testWidgets('核心广播 resolved 后当前弹窗消失，不再回话', (tester) async {
      await pumpApprovalHost(tester);
      await showRequest(tester, approvalRequest(approvalId: 'a_1'));

      api.emitAgentApprovalResolved('a_1', 'timeout');
      await tester.pumpAndSettle();

      expect(find.text(l10n.agentApprovalTitle), findsNothing);
      expect(api.approvalResponses, isEmpty,
          reason: '核心已按超时结算，UI 不能再回一条 allow/deny');
    });

    testWidgets('resolved 也移除排队中的请求（不会在之后又冒出来）', (tester) async {
      await pumpApprovalHost(tester);
      api.emitAgentApproval(approvalRequest(approvalId: 'a_1'));
      api.emitAgentApproval(
        approvalRequest(approvalId: 'a_2', entryName: 'GitHub-2'),
      );
      await tester.pump();
      await tester.pump(agentApprovalArmDelay + const Duration(milliseconds: 80));
      await tester.pump();

      api.emitAgentApprovalResolved('a_2', 'cancelled');
      await tester.pump();

      await tester.tap(find.text(l10n.agentApprovalDeny));
      await tester.pumpAndSettle();

      expect(api.approvalResponses, hasLength(1));
      expect(find.text(l10n.agentApprovalTitle), findsNothing,
          reason: 'a_2 已取消，拒绝 a_1 后不该再显示它');
    });

    testWidgets('队列上限：超出部分自动拒绝并提示', (tester) async {
      await pumpApprovalHost(tester);
      for (var i = 0; i < agentApprovalQueueLimit + 5; i++) {
        api.emitAgentApproval(
          approvalRequest(approvalId: 'a_$i', entryName: 'entry-$i'),
        );
      }
      await tester.pump();
      await tester.pump();

      // 超限的 5 条全部当场拒绝（fail closed），不留在队列里。
      expect(api.approvalResponses, hasLength(5));
      expect(api.approvalResponses.every((r) => r['allow'] == false), isTrue);

      // 当前这条仍然可审批，且显示"第 1 / 20 条"与超限警示。
      expect(find.text(l10n.agentApprovalQueuePosition('1', '20')), findsOneWidget);
      expect(find.text(l10n.agentApprovalQueueFull('5')), findsOneWidget);

      // 超限提示有 6s 自动清除计时器；冲掉避免 pending Timer 判失败。
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
    });

    testWidgets('锁屏时收到请求：不渲染浮层，直接拒绝耗尽它', (tester) async {
      // 用 locked 的假核心启动：AuthNotifier 会停在 locked。
      api.forceStatus('locked');
      container.dispose();
      api.dispose();
      api = FakeVaultApi(initialStatus: 'locked');
      container = ProviderContainer(
        overrides: [vaultApiProvider.overrideWithValue(api)],
      );
      await pumpApprovalHost(tester);

      api.emitAgentApproval(approvalRequest());
      await tester.pump();
      await tester.pump();

      expect(find.text(l10n.agentApprovalTitle), findsNothing);
      expect(api.approvalResponses.single['allow'], isFalse);
    });

    testWidgets('审批显示期间锁屏：浮层立即消失且请求被拒绝', (tester) async {
      await pumpApprovalHost(tester);
      await showRequest(tester, approvalRequest(approvalId: 'a_1'));

      api.forceStatus('locked');
      api.emitSessionEvent('locked');
      await tester.pump();
      await tester.pump();

      expect(find.text(l10n.agentApprovalTitle), findsNothing);
      expect(api.approvalResponses.single['approvalId'], 'a_1');
      expect(api.approvalResponses.single['allow'], isFalse);
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
      // 标题旁给一个活动图标（用户要求"智能体活动旁边要有图标"）。
      expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget);
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

    testWidgets('clipboard:<field> 显示为"复制到剪贴板（field）"', (tester) async {
      api.agentAudit.add({
        'at': DateTime(2026, 10, 28, 1, 2, 3).millisecondsSinceEpoch,
        'nickname': 'DSH',
        'mode': 'trusted',
        'tool': 'copy_to_clipboard',
        'op': 'clipboard:private_key',
        'entryId': 'e1',
        'entryName': 'SSH key',
        'decision': 'allowed',
      });
      await pumpAudit(tester);

      expect(
        find.textContaining(l10n.agentAuditOpClipboardField('private_key')),
        findsOneWidget,
        reason: '审计必须能区分复制的是密码还是私钥/备注',
      );
    });

    testWidgets('审计里的条目名/昵称也被清洗（不能靠换行伪造记录）', (tester) async {
      api.agentAudit.add({
        'at': DateTime(2026, 10, 28, 1, 2, 3).millisecondsSinceEpoch,
        'nickname': 'DSH\nfake',
        'mode': 'trusted',
        'tool': 'get_entry',
        'op': 'read',
        'entryId': 'e1',
        'entryName': 'GitHub\nallowed',
        'decision': 'denied',
      });
      await pumpAudit(tester);

      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data ?? '')
          .toList();
      expect(texts.any((text) => text.contains('\n')), isFalse);
      expect(find.textContaining(r'\n'), findsWidgets);
    });
  });
}
