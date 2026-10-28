import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/client/api_providers.dart';
import 'package:easypass/features/settings/screens/agent_access_screen.dart';
import 'package:easypass/l10n/app_localizations.dart';

import 'fake_vault_api.dart';

/// 智能体访问页的布局、状态真实性与用户授权控制。
///
/// 重点不是"能不能渲染"，而是这些与安全直接相关的行为：
/// 1. 总开关关闭时**不显示**警示条（没开就不能让用户以为开了）；
/// 2. 服务徽标读的是**真实 MCP 运行态**（mcpRunning/mcpPort/mcpError），
///    不是"用户想开"的持久标记；
/// 3. 「本会话内允许读取」必须常驻可见 + 可撤销（无痕授权是安全缺陷）；
/// 4. 智能体会话有显式的锁定/解锁入口；
/// 5. 配对密钥**不自动进剪贴板**，只在用户点"复制"时写并提示风险；
/// 6. 900×600（原生最小窗口）下不溢出。
void main() {
  const minWindow = Size(900, 600);
  final l10n = lookupAppLocalizations(const Locale('en'));

  late FakeVaultApi api;
  late ProviderContainer container;

  setUp(() {
    api = FakeVaultApi(
      initialStatus: 'unlocked',
      masterPassword: 'pw',
    );
    container = ProviderContainer(
      overrides: [vaultApiProvider.overrideWithValue(api)],
    );
  });

  tearDown(() {
    container.dispose();
    api.dispose();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = minWindow;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const AgentAccessScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> pairing({
    String id = 'p1',
    String nickname = 'DSH',
    String mode = 'trusted',
    bool standingRead = false,
  }) =>
      {
        'id': id,
        'nickname': nickname,
        'mode': mode,
        'trusted': mode == 'trusted',
        'revoked': false,
        'createdAt': 0,
        'lastUsedAt': null,
        'calls': 7,
        'standingRead': standingRead,
      };

  /// 把目标滚进可见区（设置页很长：高级区在视口 + cacheExtent 之外时
  /// ListView 是懒构建的，不滚动就 `find` 不到）。
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  /// 填主密码确认框并点确认（AgentAccessScreen 用 showDialog 要密码）。
  Future<void> confirmMasterPassword(
    WidgetTester tester,
    String password,
  ) async {
    final dialog = find.byType(AlertDialog);
    await tester.enterText(
      find.descendant(of: dialog, matching: find.byType(TextField)),
      password,
    );
    await tester.tap(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(FilledButton, l10n.agentConfirm),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('关闭状态：无警示条、配对按钮不可用、给出说明', (tester) async {
    await pump(tester);

    expect(find.text(l10n.agentWarningBanner), findsNothing);
    expect(find.text(l10n.agentServiceOff), findsOneWidget);
    expect(find.text(l10n.agentEnableFirst), findsOneWidget);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, l10n.agentCreatePairing),
    );
    expect(button.onPressed, isNull, reason: '没开开关就不该能配对');
  });

  testWidgets('开启状态：警示条 + 真实服务徽标（端口）+ 配对卡片', (tester) async {
    api.agentEnabled = true;
    api.agentUnlocked = true;
    api.mcpRunning = true;
    api.mcpPort = 47821;
    api.agentPairings.add(pairing());

    await pump(tester);

    expect(find.text(l10n.agentWarningBanner), findsOneWidget,
        reason: '开启后必须提醒"保险库可被自动解锁"');
    // 徽标读真实运行态：有监听端口就显示端口。
    expect(find.text(l10n.agentServiceRunning('47821')), findsOneWidget);
    expect(find.text(l10n.agentDomainUnlocked), findsOneWidget);
    expect(find.text('DSH'), findsOneWidget);
    // 高级区（会话锁 + 重置密钥）只在开启时出现（列表懒构建：先滚到它）。
    await scrollTo(tester, find.text(l10n.agentLock));
    expect(find.text(l10n.agentLock), findsOneWidget);
    expect(find.text(l10n.agentResetKey), findsOneWidget);
  });

  testWidgets('开启但 MCP 没起来：徽标显示"未运行"，并给出核心错误原因', (tester) async {
    api.agentEnabled = true;
    api.agentUnlocked = true;
    api.mcpRunning = false;
    api.mcpError = 'bind failed: 47821 in use';

    await pump(tester);

    expect(find.text(l10n.agentServiceUnavailable), findsOneWidget);
    expect(
      find.text(l10n.agentServiceError('bind failed: 47821 in use')),
      findsOneWidget,
      reason: '不能只显示"服务运行中"来掩盖启动失败',
    );
  });

  testWidgets('开启失败：显示核心返回的真实错误，且不把开关谎报成已开', (tester) async {
    api.enableAgentAccessFailure = StateError('mcp bind failed');
    await pump(tester);

    // 打开开关 → 主密码确认 → enable 抛错。
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await confirmMasterPassword(tester, 'pw');

    expect(find.textContaining('mcp bind failed'), findsOneWidget);
    expect(api.calls, contains('verifyMasterPassword'));
    expect(api.calls, isNot(contains('unlock')),
        reason: '只做 verify，避免重新 unlock 触发 router 重建');
    expect(api.agentEnabled, isFalse);
    expect(find.text(l10n.agentServiceOff), findsOneWidget);

    // SnackBar 有 4s 计时器；不冲掉会留下 pending Timer 让 widget test 失败。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('空配对列表显示占位，不显示卡片', (tester) async {
    api.agentEnabled = true;
    api.agentUnlocked = true;
    api.mcpRunning = true;
    api.mcpPort = 47821;
    await pump(tester);

    expect(find.text(l10n.agentNoPairings), findsOneWidget);
    await scrollTo(tester, find.text(l10n.agentResetKey));
    expect(find.text(l10n.agentResetKey), findsOneWidget);
  });

  testWidgets('本会话免询问读取：常驻指示 + 按配对撤销', (tester) async {
    api.agentEnabled = true;
    api.agentUnlocked = true;
    api.mcpRunning = true;
    api.mcpPort = 47821;
    api.agentPairings.add(pairing(standingRead: true));

    await pump(tester);

    expect(find.text(l10n.agentStandingReadTitle), findsOneWidget,
        reason: '免询问必须是可见状态，不能是无痕授权');
    expect(find.text(l10n.agentStandingReadBanner('DSH')), findsOneWidget);
    expect(find.text(l10n.agentStandingReadRevoke), findsOneWidget);

    await tester.tap(find.text(l10n.agentStandingReadRevoke));
    await tester.pumpAndSettle();

    expect(api.standingReadCleared, ['p1']);
    expect(api.calls, contains('clearStandingRead'));
    expect(find.text(l10n.agentStandingReadRevoked('DSH')), findsOneWidget);
    // 撤销后指示消失（fake 里 map 的 standingRead 被置 false）。
    expect(find.text(l10n.agentStandingReadTitle), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('本会话免询问读取：全部撤销', (tester) async {
    api.agentEnabled = true;
    api.agentUnlocked = true;
    api.mcpRunning = true;
    api.mcpPort = 47821;
    api.agentPairings.add(pairing(id: 'p1', nickname: 'A', standingRead: true));
    api.agentPairings.add(pairing(id: 'p2', nickname: 'B', standingRead: true));

    await pump(tester);

    await tester.tap(find.text(l10n.agentStandingReadRevokeAll));
    await tester.pumpAndSettle();

    expect(api.standingReadCleared, containsAll(['p1', 'p2']));
    expect(find.text(l10n.agentStandingReadRevokedAll), findsOneWidget);
    expect(find.text(l10n.agentStandingReadTitle), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('智能体会话锁定/解锁：显式入口 + 调核心动作', (tester) async {
    api.agentEnabled = true;
    api.agentUnlocked = true;
    api.mcpRunning = true;
    api.mcpPort = 47821;
    await pump(tester);

    // 已解锁 → 显示"锁定智能体会话"（高级区在页面底部，先滚过去）。
    await scrollTo(tester, find.text(l10n.agentLock));
    await tester.tap(find.text(l10n.agentLock));
    await tester.pumpAndSettle();
    expect(api.calls, contains('lockAgentDomain'));
    expect(api.agentUnlocked, isFalse);
    expect(find.text(l10n.agentUnlock), findsOneWidget);

    // 已锁定 → 显示"为智能体解锁"，要主密码。
    await tester.tap(find.text(l10n.agentUnlock));
    await tester.pumpAndSettle();
    await confirmMasterPassword(tester, 'pw');

    expect(api.calls, contains('unlockAgentDomain'));
    expect(api.agentUnlocked, isTrue);
    expect(find.text(l10n.agentLock), findsOneWidget);
  });

  testWidgets('重置密钥确认文案：不再谎称"需要重新配对"', (tester) async {
    api.agentEnabled = true;
    api.agentUnlocked = true;
    api.mcpRunning = true;
    api.mcpPort = 47821;
    await pump(tester);

    await scrollTo(tester, find.text(l10n.agentResetKey));
    await tester.tap(find.text(l10n.agentResetKey));
    await tester.pumpAndSettle();

    expect(find.text(l10n.agentResetKeyConfirm), findsOneWidget);
    expect(
      l10n.agentResetKeyConfirm.toLowerCase(),
      isNot(contains('pair it again')),
      reason: '重置包裹密钥不影响配对，文案不能误导用户重新配对',
    );
  });

  testWidgets('最小窗口下不溢出', (tester) async {
    api.agentEnabled = true;
    api.agentUnlocked = true;
    api.mcpRunning = true;
    api.mcpPort = 47821;
    api.agentPairings.add(pairing(
      nickname: 'A-Very-Long-Agent-Nickname-${'x' * 80}',
    ));

    await pump(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('创建配对：密钥不自动进剪贴板，只有点"复制"才写并提示风险',
      (tester) async {
    final clipboard = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String? ?? '');
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    api.agentEnabled = true;
    api.agentUnlocked = true;
    api.mcpRunning = true;
    api.mcpPort = 47821;
    await pump(tester);

    // 配对：先填昵称，再用主密码确认。
    await tester.tap(find.widgetWithText(FilledButton, l10n.agentCreatePairing));
    await tester.pumpAndSettle();
    final nicknameDialog = find.byType(AlertDialog);
    await tester.enterText(
      find.descendant(of: nicknameDialog, matching: find.byType(TextField)),
      'DSH',
    );
    await tester.tap(
      find.descendant(
        of: nicknameDialog,
        matching: find.widgetWithText(FilledButton, l10n.agentCreatePairing),
      ),
    );
    await tester.pumpAndSettle();
    await confirmMasterPassword(tester, 'pw');

    // 密钥弹窗出现了，但**没有**自动复制。
    expect(find.text(l10n.agentKeyClipboardHint), findsOneWidget);
    expect(clipboard, isEmpty,
        reason: '配对密钥不能在用户没点"复制"时进入剪贴板');

    await tester.tap(find.text(l10n.agentCopy));
    await tester.pumpAndSettle();

    expect(clipboard, ['key-p_1']);
    expect(find.text(l10n.agentKeyCopiedHint), findsOneWidget);
  });
}
