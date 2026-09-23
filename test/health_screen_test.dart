import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/data/state/session_key.dart';
import 'package:easypass/features/health/screens/health_screen.dart';
import 'package:easypass/l10n/app_localizations.dart';

import 'fakes.dart';

/// 健康报告页布局 / 文案回归（2.3.0）：
/// 1) 明确写出"只统计登录条目"，并显示被分析的登录条目数；
/// 2) 四个分区（弱密码 / 重复密码 / 无两步验证 / 无网址）保持存在；
/// 3) 安全笔记 / 身份 / SSH 条目不出现在任何问题列表里；
/// 4) **900×600（原生最小窗口）下不出现 RenderFlex 溢出** —— 超长条目名也不能撑破；
/// 5) 点问题条目跳到 `/vault/entry/:id`；
/// 6) 加载失败时给出错误 + 重试按钮。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  /// 与原生层的最小窗口尺寸一致（`windows/runner/win32_window.cpp`）。
  const minWindow = Size(900, 600);

  final l10n = lookupAppLocalizations(const Locale('en'));

  // PBKDF2（100k 次）很慢：整个文件只派生一把会话密钥，所有测试复用。
  final seedCrypto = CryptoService(secureStorage: FakeSecureStorage());
  late final Uint8List sessionKey = seedCrypto.deriveKey(
    'master-password',
    seedCrypto.generateSalt(),
  );

  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        cryptoServiceProvider.overrideWithValue(
          CryptoService(secureStorage: FakeSecureStorage()),
        ),
        databaseProvider.overrideWithValue(
          AppDatabase.forTesting(NativeDatabase.memory()),
        ),
      ],
    );
    container.read(encryptionKeyProvider.notifier).state = sessionKey;
  });

  tearDown(() => container.dispose());

  /// 超长名字：列表项必须换行 / 省略，而不是把窗口撑出黄黑条纹。
  final longName = 'A-Very-Long-Entry-Name-${'x' * 120}-END';

  VaultItem login({
    required String id,
    String? name,
    String password = 'Tr0ub4dor&3X!9',
    String url = '',
    String totpSecret = '',
  }) {
    return VaultItem(
      id: id,
      type: EntryType.login,
      name: name ?? 'Login-$id',
      login: LoginData(
        url: url,
        username: 'user-$id',
        password: password,
        totpSecret: totpSecret,
      ),
      createdAt: 0,
      updatedAt: 0,
    );
  }

  const nonLoginNames = [
    'NoteEntryName-MUST-NOT-APPEAR',
    'IdentityEntryName-MUST-NOT-APPEAR',
    'SshEntryName-MUST-NOT-APPEAR',
  ];

  List<VaultItem> nonLoginItems() => const [
        VaultItem(
          id: 'note-1',
          type: EntryType.secureNote,
          name: 'NoteEntryName-MUST-NOT-APPEAR',
          notes: 'body',
          createdAt: 0,
          updatedAt: 0,
        ),
        VaultItem(
          id: 'identity-1',
          type: EntryType.identity,
          name: 'IdentityEntryName-MUST-NOT-APPEAR',
          identity: IdentityData(firstName: 'Ada'),
          createdAt: 0,
          updatedAt: 0,
        ),
        VaultItem(
          id: 'ssh-1',
          type: EntryType.sshKey,
          name: 'SshEntryName-MUST-NOT-APPEAR',
          sshKey: SshKeyData(publicKey: 'ssh-ed25519 AAAA marker@host'),
          createdAt: 0,
          updatedAt: 0,
        ),
      ];

  /// 5 个登录条目 + 3 个非登录条目。
  ///
  /// 评分预期：弱密码 1 个(-10) + 重复密码 1 组(-15) + 无 TOTP 2 个(-4)
  /// + 无 URL 2 个(-4) = 67 分。
  Future<void> seedVault() async {
    final repo = container.read(vaultRepositoryProvider);
    await repo.saveItem(login(
      id: 'weak',
      name: longName,
      password: '123456',
    ));
    await repo.saveItem(login(
      id: 'reused-a',
      password: 'Tr0ub4dor&3X!9',
      url: 'https://a.example.com',
      totpSecret: 'JBSWY3DPEHPK3PXP',
    ));
    await repo.saveItem(login(
      id: 'reused-b',
      password: 'Tr0ub4dor&3X!9',
      url: 'https://b.example.com',
      totpSecret: 'JBSWY3DPEHPK3PXP',
    ));
    await repo.saveItem(login(
      id: 'nototp',
      password: 'AnotherStr0ng!pw',
      url: 'https://c.example.com',
    ));
    await repo.saveItem(login(
      id: 'nourl',
      password: 'ThirdStr0ng!pw',
      totpSecret: 'JBSWY3DPEHPK3PXP',
    ));
    for (final item in nonLoginItems()) {
      await repo.saveItem(item);
    }
    expect(await repo.countItems(), 8);
  }

  Future<void> pumpHealthScreen(WidgetTester tester) async {
    tester.view.physicalSize = minWindow;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = GoRouter(
      initialLocation: '/health',
      routes: [
        GoRoute(path: '/health', builder: (_, _) => const HealthScreen()),
        GoRoute(
          path: '/vault/entry/:id',
          builder: (_, state) => Scaffold(
            body: Text('entry-detail-${state.pathParameters['id']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 一屏一屏往下滚，收集期间渲染过的所有 `Text`（列表是懒加载的，
  /// 单次断言只能看到已构建的部分）。
  Future<Set<String>> collectTexts(WidgetTester tester) async {
    final texts = <String>{};
    for (var step = 0; step < 10; step++) {
      texts.addAll(
        tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data ?? '')
            .where((data) => data.isNotEmpty),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    return texts;
  }

  testWidgets('900×600：评分口径说明 + 登录条目数 + 四个分区 + 超长名字不溢出', (tester) async {
    await seedVault();
    await pumpHealthScreen(tester);

    // 口径说明与"被分析的登录条目数"（只有 5 个登录条目参与）
    expect(find.text(l10n.healthOnlyLogins), findsOneWidget);
    expect(find.text(l10n.healthLoginCount(5)), findsOneWidget);

    // 分数（见 seedVault 注释里的算分）
    expect(find.text('67'), findsOneWidget);

    // 超长名字渲染出来了（真的溢出的话 flutter_test 会直接判失败）
    expect(find.text(longName), findsOneWidget);

    // 四个分区都在（滚动全量收集，避免懒加载漏看）
    final texts = await collectTexts(tester);
    for (final title in [
      l10n.healthWeakPasswords,
      l10n.healthReusedPasswords,
      l10n.healthNoTotp,
      l10n.healthNoUrl,
    ]) {
      expect(texts, contains(title), reason: '缺少分区「$title」');
    }
    expect(texts, contains(l10n.healthTapToView));
  });

  testWidgets('非登录条目不出现在任何问题列表里', (tester) async {
    await seedVault();
    await pumpHealthScreen(tester);

    final texts = await collectTexts(tester);

    for (final name in nonLoginNames) {
      expect(texts, isNot(contains(name)), reason: '$name 不该出现在健康报告里');
    }
    // 登录条目确实出现在问题列表里（否则上面的断言可能只是"页面是空的"）
    expect(texts, contains('Login-reused-a'));
    expect(texts, contains('Login-nototp'));
    expect(texts, contains('Login-nourl'));
  });

  testWidgets('点问题条目跳转到详情页', (tester) async {
    await seedVault();
    await pumpHealthScreen(tester);

    final tile = find.text('Login-reused-a').first;
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(find.text('entry-detail-reused-a'), findsOneWidget);
  });

  testWidgets('保险库未解锁时显示错误状态与重试按钮', (tester) async {
    await seedVault();
    container.read(encryptionKeyProvider.notifier).state = null;
    await pumpHealthScreen(tester);

    expect(find.byIcon(Icons.health_and_safety_outlined), findsOneWidget);
    expect(find.text(l10n.retry), findsOneWidget);
  });
}
