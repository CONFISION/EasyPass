import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/client/api_providers.dart';
import 'package:easypass/features/settings/screens/agent_access_screen.dart';
import 'package:easypass/l10n/app_localizations.dart';

import 'fake_vault_api.dart';

/// 智能体访问页的布局与状态回归。
///
/// 重点不是"能不能渲染"，而是这几条与安全直接相关的可见性：
/// 1. 总开关关闭时**不显示**警示条（没开就不能让用户以为开了）；
/// 2. 打开后**必须**显示那条"保险库可被自动解锁"的警示 —— 它是唯一提醒；
/// 3. 关闭状态下不能配对（按钮 disabled + 一行说明）；
/// 4. 900×600（原生最小窗口）下不溢出。
void main() {
  const minWindow = Size(900, 600);
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

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(minWindow);
    addTearDown(() => tester.binding.setSurfaceSize(null));
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

  testWidgets('开启状态：显示警示条、服务徽章与配对卡片', (tester) async {
    api.agentEnabled = true;
    api.agentUnlocked = true;
    api.agentPairings.add({
      'id': 'p1',
      'nickname': 'DSH',
      'mode': 'trusted',
      'trusted': true,
      'revoked': false,
      'createdAt': 0,
      'lastUsedAt': null,
      'calls': 7,
    });

    await pump(tester);

    expect(find.text(l10n.agentWarningBanner), findsOneWidget,
        reason: '开启后必须提醒"保险库可被自动解锁"');
    expect(find.text(l10n.agentServiceOn), findsOneWidget);
    expect(find.text(l10n.agentDomainUnlocked), findsOneWidget);
    expect(find.text('DSH'), findsOneWidget);
    expect(find.textContaining('7'), findsWidgets);
    // 高级区（重置密钥）只在开启时出现。
    expect(find.text(l10n.agentResetKey), findsOneWidget);
  });

  testWidgets('空配对列表显示占位，不显示卡片', (tester) async {
    api.agentEnabled = true;
    api.agentUnlocked = true;
    await pump(tester);

    expect(find.text(l10n.agentNoPairings), findsOneWidget);
    expect(find.text(l10n.agentResetKey), findsOneWidget);
  });

  testWidgets('最小窗口下不溢出', (tester) async {
    api.agentEnabled = true;
    api.agentUnlocked = true;
    api.agentPairings.add({
      'id': 'p1',
      'nickname': 'A-Very-Long-Agent-Nickname-${'x' * 80}',
      'mode': 'trusted',
      'trusted': true,
      'revoked': false,
      'createdAt': 0,
      'calls': 12345,
    });

    await pump(tester);
    expect(tester.takeException(), isNull);
  });
}
