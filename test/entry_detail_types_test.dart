import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/core/crypto/totp_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/data/state/session_key.dart';
import 'package:easypass/features/vault/screens/entry_detail_screen.dart';
import 'package:easypass/l10n/app_localizations.dart';

import 'fakes.dart';

/// 条目详情页（2.3.0 四种类型）的字段分工回归。
///
/// 覆盖 `docs/entry-types.md` §4「详情页」表：
/// - secure_note 只渲染正文，不出现登录字段；
/// - identity 只渲染非空字段，空分组整块不渲染；
/// - ssh_key 的私钥默认打码，验证主密码后才显示；
/// - login 渲染 6 位 TOTP 动态码 + 倒计时，且**永不**渲染原始密钥；
/// - 自定义字段（文本 / 隐藏 / 勾选）的展示与打码。
///
/// 注意：详情页里的 TOTP 卡片带 1 秒周期定时器，`pumpAndSettle` 永远等不到
/// "没有待处理帧"，所以这里统一用固定帧数的 [settle]。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  /// 与原生层的最小窗口尺寸一致（900×600），守住"最小窗口不溢出"。
  const minWindow = Size(900, 600);

  const masterPassword = 'correct horse battery staple';

  late ProviderContainer container;
  late AppDatabase db;
  late CryptoService crypto;
  late FakeSecureStorage storage;
  late Uint8List key;

  setUp(() {
    storage = FakeSecureStorage();
    crypto = CryptoService(secureStorage: storage);
    key = crypto.deriveKey('session-master', crypto.generateSalt());
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        cryptoServiceProvider.overrideWithValue(crypto),
        databaseProvider.overrideWithValue(db),
      ],
    );
    container.read(encryptionKeyProvider.notifier).state = key;
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// 泵固定帧数：既让 drift 的 FutureProvider 落地，又不会被周期定时器挂住。
  Future<void> settle(WidgetTester tester, {int frames = 24}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<VaultItem?> readItem(String id) =>
      container.read(vaultRepositoryProvider).getItem(id);

  Future<void> seed(VaultItem item) =>
      container.read(vaultRepositoryProvider).saveItem(item);

  Future<AppLocalizations> pumpDetail(WidgetTester tester, String entryId) async {
    tester.view.physicalSize = minWindow;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: EntryDetailScreen(entryId: entryId),
        ),
      ),
    );
    await settle(tester);
    return AppLocalizations.of(tester.element(find.byType(EntryDetailScreen)));
  }

  /// 页面上所有 [Text] 的字符串（TOTP 动态码 / 倒计时断言用）。
  List<String> texts(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((widget) => widget.data)
      .whereType<String>()
      .toList();

  /// 主密码验证弹窗：输入密码 → 点 Verify。
  Future<void> verifyMasterPassword(WidgetTester tester, AppLocalizations l10n) async {
    expect(find.text(l10n.verifyMasterPasswordTitle), findsOneWidget,
        reason: '显示机密前必须先弹主密码验证框');
    await tester.enterText(find.byType(TextField), masterPassword);
    await tester.pump();
    await tester.tap(find.text(l10n.verify));
    // PBKDF2（10 万轮）+ 弹窗关闭动画，多给几帧。
    await settle(tester, frames: 40);
  }

  // ─── secure_note ──────────────────────────────────────

  testWidgets('安全笔记：渲染正文，且不出现用户名/密码/网址/TOTP 控件', (tester) async {
    await seed(const VaultItem(
      id: 'note-1',
      type: EntryType.secureNote,
      name: 'WiFi 密码',
      notes: '后台 192.168.1.1\n账号 admin / 密码 hunter2',
      createdAt: 0,
      updatedAt: 0,
    ));

    final l10n = await pumpDetail(tester, 'note-1');

    expect(find.text('WiFi 密码'), findsOneWidget);
    expect(find.text(l10n.entryTypeSecureNote), findsOneWidget, reason: '类型徽章');
    expect(find.text(l10n.secureNoteBodyLabel), findsOneWidget);
    expect(find.textContaining('192.168.1.1'), findsOneWidget, reason: '正文必须渲染');

    // 登录专属字段一个都不能出现。
    expect(find.text(l10n.username), findsNothing);
    expect(find.text(l10n.passwordField), findsNothing);
    expect(find.text(l10n.urlLabel), findsNothing);
    expect(find.text(l10n.totpCodeLabel), findsNothing);
    expect(find.text(l10n.none), findsNothing, reason: '安全笔记正文非空，不该出现 None 占位');
    expect(tester.takeException(), isNull, reason: '900×600 下不允许溢出');
  });

  // ─── identity ─────────────────────────────────────────

  testWidgets('身份：渲染非空字段，空字段与空分组都不渲染', (tester) async {
    await seed(const VaultItem(
      id: 'id-1',
      type: EntryType.identity,
      name: 'Ada Lovelace',
      identity: IdentityData(
        firstName: 'Ada',
        lastName: 'Lovelace',
        email: 'ada@example.com',
        city: 'London',
        country: 'United Kingdom',
      ),
      createdAt: 0,
      updatedAt: 0,
    ));

    final l10n = await pumpDetail(tester, 'id-1');

    // 非空字段 + 分组标题
    expect(find.text(l10n.identityPersonalSection), findsOneWidget);
    expect(find.text(l10n.identityFirstNameLabel), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('Lovelace'), findsOneWidget);
    expect(find.text(l10n.identityContactSection), findsOneWidget);
    expect(find.text('ada@example.com'), findsOneWidget);
    expect(find.text(l10n.identityAddressSection), findsOneWidget);
    expect(find.text('London'), findsOneWidget);

    // 空分组（证件）整块不渲染 —— 不留空标题。
    expect(find.text(l10n.identityDocumentSection), findsNothing);
    expect(find.text(l10n.identityIdNumberLabel), findsNothing);
    expect(find.text(l10n.identityPassportLabel), findsNothing);
    expect(find.text(l10n.identityLicenseLabel), findsNothing);

    // 空字段连标签都不渲染。
    expect(find.text(l10n.identityMiddleNameLabel), findsNothing);
    expect(find.text(l10n.identityBirthdayLabel), findsNothing);
    expect(find.text(l10n.identitySexLabel), findsNothing);
    expect(find.text(l10n.identityPhoneLabel), findsNothing);
    expect(find.text(l10n.usernameLabel), findsNothing);
    expect(find.text(l10n.none), findsNothing,
        reason: '身份行的空字段直接不渲染，不用 None 占位');
    expect(tester.takeException(), isNull);
  });

  // ─── ssh_key ──────────────────────────────────────────

  testWidgets('SSH：指纹/类型可见，私钥默认打码、验证主密码后才显示', (tester) async {
    // 真正配置一个主密码，验证流程才走得通。
    final salt = crypto.generateSalt();
    await crypto.storeKeyMaterial(
      salt,
      crypto.hashMasterPassword(masterPassword, salt),
    );

    const privateKey = '-----BEGIN OPENSSH PRIVATE KEY-----\n'
        'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gt\n'
        '-----END OPENSSH PRIVATE KEY-----';

    await seed(const VaultItem(
      id: 'ssh-1',
      type: EntryType.sshKey,
      name: 'GitHub deploy key',
      sshKey: SshKeyData(
        publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterial user@host',
        privateKey: privateKey,
        passphrase: 'pp-secret-passphrase',
        fingerprint: 'SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEF',
        keyType: 'ssh-ed25519',
        bits: 256,
        comment: 'user@host',
      ),
      createdAt: 0,
      updatedAt: 0,
    ));

    final l10n = await pumpDetail(tester, 'ssh-1');

    expect(find.text(l10n.sshKeySection), findsOneWidget);
    expect(find.text(l10n.sshFingerprintLabel), findsOneWidget);
    expect(find.text('SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEF'),
        findsOneWidget);
    expect(find.text(l10n.sshKeyTypeLabel), findsOneWidget);
    expect(find.text('ssh-ed25519'), findsOneWidget);
    expect(find.text(l10n.sshBitsValue(256)), findsOneWidget);
    expect(find.text('OpenSSH'), findsOneWidget, reason: '识别到的私钥格式');

    // 私钥与口令都打码。
    expect(find.text('••••••••••••'), findsNWidgets(2));
    expect(find.text(privateKey), findsNothing, reason: '私钥默认绝不能出现在界面上');
    expect(find.text('pp-secret-passphrase'), findsNothing);

    // 点眼睛 → 主密码验证 → 私钥才显示。
    await tester.tap(find.byTooltip(l10n.sshRevealPrivateKey));
    await settle(tester, frames: 12);
    await verifyMasterPassword(tester, l10n);

    expect(find.text(privateKey), findsOneWidget, reason: '验证通过后私钥才渲染');
    expect(find.text('pp-secret-passphrase'), findsNothing,
        reason: '口令是另一个机密，不该跟着一起显示');
    expect(tester.takeException(), isNull);
  });

  testWidgets('SSH：没有私钥时显示 sshNoPrivateKey，不显示眼睛/复制按钮', (tester) async {
    await seed(const VaultItem(
      id: 'ssh-2',
      type: EntryType.sshKey,
      name: '只存公钥',
      sshKey: SshKeyData(
        publicKey: 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQ user@host',
        keyType: 'ssh-rsa',
        bits: 3072,
      ),
      createdAt: 0,
      updatedAt: 0,
    ));

    final l10n = await pumpDetail(tester, 'ssh-2');

    expect(find.text(l10n.sshNoPrivateKey), findsOneWidget);
    expect(find.byTooltip(l10n.sshRevealPrivateKey), findsNothing);
    expect(find.text(l10n.sshPrivateKeyFormatLabel), findsNothing,
        reason: '没有私钥就没有"识别到的格式"这一行');
    expect(find.text(l10n.sshPassphraseLabel), findsNothing,
        reason: '空口令不占一行');
    expect(tester.takeException(), isNull);
  });

  // ─── login + TOTP ─────────────────────────────────────

  testWidgets('登录：渲染 6 位 TOTP 动态码 + 倒计时，绝不渲染原始密钥', (tester) async {
    const secret = 'JBSWY3DPEHPK3PXP';

    await seed(const VaultItem(
      id: 'login-1',
      type: EntryType.login,
      name: 'GitHub',
      login: LoginData(
        url: 'https://github.com',
        username: 'alice',
        password: 's3cret-pw',
        totpSecret: secret,
      ),
      createdAt: 0,
      updatedAt: 0,
    ));

    final l10n = await pumpDetail(tester, 'login-1');

    expect(find.text(l10n.username), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
    expect(find.text(l10n.passwordField), findsOneWidget);
    expect(find.text('••••••••••••'), findsOneWidget, reason: '密码默认打码');
    expect(find.text('s3cret-pw'), findsNothing);
    expect(find.text(l10n.urlLabel), findsOneWidget);
    expect(find.text('https://github.com'), findsOneWidget);

    // 原始密钥绝不作为字段渲染。
    expect(find.text(l10n.totpCodeLabel), findsOneWidget);
    expect(find.text(secret), findsNothing);
    expect(find.textContaining(secret), findsNothing);
    expect(find.text(l10n.totpSecretLabel), findsNothing,
        reason: '2.3.0 起详情页不再显示 TOTP 密钥字段');

    // 6 位动态码：必须是该密钥算出来的真实 TOTP。
    final codes =
        texts(tester).where((t) => RegExp(r'^\d{6}$').hasMatch(t)).toList();
    expect(codes, hasLength(1), reason: '应渲染唯一一个 6 位动态码');
    expect(TotpService().validateTotp(secret, codes.single), isTrue,
        reason: '渲染出来的必须是对应密钥的有效动态码');

    // 倒计时文案（值随当前秒数变化，1..30 里应命中一个）。
    final countdownCandidates = [
      for (var seconds = 1; seconds <= 30; seconds++)
        l10n.totpRefreshesIn(seconds),
    ];
    expect(texts(tester).any(countdownCandidates.contains), isTrue,
        reason: '应渲染 totpRefreshesIn(seconds) 倒计时');

    expect(find.byTooltip(l10n.totpCopyTooltip), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('登录（未配置 TOTP）：显示"未配置"，没有动态码也没有复制按钮', (tester) async {
    await seed(const VaultItem(
      id: 'login-2',
      type: EntryType.login,
      name: '内网系统',
      login: LoginData(url: 'https://intranet.local', username: 'bob', password: 'pw'),
      createdAt: 0,
      updatedAt: 0,
    ));

    final l10n = await pumpDetail(tester, 'login-2');

    expect(find.text(l10n.totpCodeLabel), findsOneWidget);
    expect(find.text(l10n.totpNotSet), findsOneWidget);
    expect(find.byTooltip(l10n.totpCopyTooltip), findsNothing);
    expect(
      texts(tester).where((t) => RegExp(r'^\d{6}$').hasMatch(t)),
      isEmpty,
      reason: '没有密钥就不该有动态码',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('登录：密码验证主密码后才显示，错误密码不显示明文，1 分钟后自动隐藏', (tester) async {
    final salt = crypto.generateSalt();
    await crypto.storeKeyMaterial(
      salt,
      crypto.hashMasterPassword(masterPassword, salt),
    );

    await seed(const VaultItem(
      id: 'login-3',
      type: EntryType.login,
      name: 'GitLab',
      login: LoginData(
        url: 'https://gitlab.com',
        username: 'carol',
        password: 'top-secret-pw',
      ),
      createdAt: 0,
      updatedAt: 0,
    ));

    final l10n = await pumpDetail(tester, 'login-3');
    expect(find.text('••••••••••••'), findsOneWidget);
    expect(find.text('top-secret-pw'), findsNothing, reason: '默认必须打码');

    await tester.tap(find.byTooltip(l10n.revealPasswordTooltip));
    await settle(tester, frames: 12);
    expect(find.text(l10n.verifyMasterPasswordTitle), findsOneWidget);

    // 错误主密码：弹窗不关、明文绝不出现。
    await tester.enterText(find.byType(TextField), 'wrong-master-password');
    await tester.pump();
    await tester.tap(find.text(l10n.verify));
    await settle(tester, frames: 40);
    expect(find.text(l10n.errorIncorrectMasterPassword), findsOneWidget);
    expect(find.text('top-secret-pw'), findsNothing,
        reason: '验证失败时绝不能顺手把明文显示出来');

    // 正确主密码：显示明文 + "1 分钟后自动隐藏"提示。
    await tester.enterText(find.byType(TextField), masterPassword);
    await tester.pump();
    await tester.tap(find.text(l10n.verify));
    await settle(tester, frames: 40);
    expect(find.text('top-secret-pw'), findsOneWidget);
    expect(find.text(l10n.visibleAutoHide), findsOneWidget);

    // 1 分钟到点：自动回到打码状态。
    await tester.pump(const Duration(minutes: 1, seconds: 1));
    await tester.pump();
    expect(find.text('top-secret-pw'), findsNothing,
        reason: '显示 1 分钟后必须自动隐藏');
    expect(find.text('••••••••••••'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ─── 自定义字段 ───────────────────────────────────────

  testWidgets('自定义字段：文本直接显示，隐藏字段默认打码、点眼睛才显示', (tester) async {
    await seed(const VaultItem(
      id: 'note-2',
      type: EntryType.secureNote,
      name: 'API 凭据',
      notes: '见自定义字段',
      customFields: [
        CustomField(label: 'PIN', value: '1234'),
        CustomField(
          label: 'Token',
          value: 'super-secret-token',
          type: CustomFieldType.hidden,
        ),
        CustomField(
          label: 'Enabled',
          value: 'true',
          type: CustomFieldType.boolean,
        ),
      ],
      createdAt: 0,
      updatedAt: 0,
    ));

    final l10n = await pumpDetail(tester, 'note-2');

    expect(find.text(l10n.customFieldsSection), findsOneWidget);
    expect(find.text('PIN'), findsOneWidget);
    expect(find.text('1234'), findsOneWidget);
    expect(find.text('Token'), findsOneWidget);
    expect(find.text('✓'), findsOneWidget, reason: '勾选型字段渲染勾号');
    expect(find.text('super-secret-token'), findsNothing, reason: '隐藏字段默认打码');
    expect(find.text('••••••••'), findsOneWidget);

    // 点眼睛 → 显示隐藏值。
    await tester.tap(find.byTooltip(l10n.revealPasswordTooltip));
    await settle(tester, frames: 4);

    expect(find.text('super-secret-token'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ─── 编辑后自动刷新（2.3.1 用户报的 bug）──────────────────
  //
  // 用户原话："编辑条目后页面不刷新，刚加的自定义字段不见了。"
  // 根因：详情页读的是一次性 `FutureProvider.family`，结果被永久缓存，而
  // "编辑保存 → 弹回详情页"这条路径上没有人 invalidate。现在
  // `entryItemProvider` 是 drift 单行查询上的流（`repository.watchItem`）。
  //
  // 下面两个用例**故意不调用任何 invalidate**（既不 invalidate provider，
  // 也不碰 container）：刷新只能来自"写库 → 流推送"。

  testWidgets('回归：保存后详情页自动刷新（改名 + 新增自定义字段，全程不 invalidate）',
      (tester) async {
    await seed(const VaultItem(
      id: 'live-1',
      type: EntryType.secureNote,
      name: '旧名字',
      notes: '正文',
      createdAt: 0,
      updatedAt: 0,
    ));

    final l10n = await pumpDetail(tester, 'live-1');
    expect(find.text('旧名字'), findsOneWidget);
    expect(find.text(l10n.customFieldsSection), findsNothing,
        reason: '刷新前没有自定义字段区块');

    // 模拟"编辑页保存"：直接走仓储写库（测试里不碰 provider）。
    await seed(const VaultItem(
      id: 'live-1',
      type: EntryType.secureNote,
      name: '新名字',
      notes: '正文',
      customFields: [CustomField(label: 'PIN', value: '4321')],
      createdAt: 0,
      updatedAt: 0,
    ));

    // 刷新期间不允许退回加载态（跳过一次加载帧就会出现进度圈）。
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '流式刷新时不允许闪一次进度圈（skipLoadingOnReload 语义）');
    }

    expect(find.text('新名字'), findsOneWidget, reason: '流必须把新名字推上来');
    expect(find.text('旧名字'), findsNothing, reason: '不允许残留旧内容');
    expect(find.text(l10n.customFieldsSection), findsOneWidget);
    expect(find.text('PIN'), findsOneWidget);
    expect(find.text('4321'), findsOneWidget,
        reason: '用户刚加的自定义字段必须出现在详情页');
    expect(tester.takeException(), isNull);
  });

  testWidgets('回归：条目在别处被删除后详情页立刻收敛到 entryNotFound', (tester) async {
    await seed(const VaultItem(
      id: 'live-2',
      type: EntryType.secureNote,
      name: '会被删掉',
      notes: '正文',
      createdAt: 0,
      updatedAt: 0,
    ));

    final l10n = await pumpDetail(tester, 'live-2');
    expect(find.text('会被删掉'), findsOneWidget);

    // 详情页自己删是走 _confirmDelete 弹窗；这里验证的是"流推 null → 页面收敛"。
    await container.read(vaultRepositoryProvider).deleteItem('live-2');
    await settle(tester);

    expect(find.text(l10n.entryNotFound), findsOneWidget);
    expect(find.text('会被删掉'), findsNothing,
        reason: '已删除的条目不允许继续挂在屏幕上');
    expect(find.byType(SwitchListTile), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // ─── 收藏开关 + 空态 ──────────────────────────────────

  testWidgets('收藏开关：走 saveItem 落库，流自己把开关刷成新值', (tester) async {
    await seed(const VaultItem(
      id: 'note-3',
      type: EntryType.secureNote,
      name: '收藏测试',
      notes: 'body',
      createdAt: 0,
      updatedAt: 0,
    ));

    final l10n = await pumpDetail(tester, 'note-3');
    expect(find.text(l10n.favorite), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse);

    await tester.tap(find.byType(SwitchListTile));
    await settle(tester);

    expect((await readItem('note-3'))!.isFavorite, isTrue,
        reason: '收藏必须通过 repo.saveItem 持久化');
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue, reason: 'entryItemProvider 是流，写库后开关应自己显示新值');
    expect(tester.takeException(), isNull);
  });

  testWidgets('条目不存在时显示 entryNotFound', (tester) async {
    final l10n = await pumpDetail(tester, 'missing-id');

    expect(find.text(l10n.entryNotFound), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
