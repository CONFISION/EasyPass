import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/data/state/session_key.dart';
import 'package:easypass/features/vault/providers/vault_provider.dart';
import 'package:easypass/features/vault/screens/vault_screen.dart';
import 'package:easypass/features/vault/widgets/entry_card.dart';
import 'package:easypass/l10n/app_localizations.dart';

import 'fakes.dart';

/// 保险库页布局回归：
/// 1) 侧边栏占满全高、**没有顶层 AppBar**，"EasyPass" 只在侧边栏顶部出现一次；
/// 2) 侧边栏不再有"密码生成器"入口（右上角工具栏已有同一个入口）；
/// 3) 右下角新增按钮是纯图标 FAB（无文字 label），只保留 tooltip 作为无障碍名称；
/// 4) **最小窗口尺寸（900×600）下不出现任何 RenderFlex 溢出** —— 用户报过的
///    "窄窗黄黑条纹"，根因是侧边栏头部 Row 里的 Text 没有 Expanded 包裹；
/// 5) 两栏顶部严格等高：侧边栏品牌头与右栏工具栏共用 `_topBarHeight`，
///    两者下方的分隔线必须落在同一 y 坐标。
///
/// 2.3.0 追加（多类型 + 类型筛选 + 文件夹图标）：
/// 6) 工具栏下方常驻类型筛选 chips，选中类型后只显示该类型条目；
/// 7) 类型筛选下空列表的文案走 `entryTypeEmptyForType`；
/// 8) 长按文件夹可重命名（走 `repository.updateFolder`）；
/// 9) 新建文件夹可选图标，侧边栏渲染 `folders.icon` 而不是写死的 Icons.folder；
/// 10) 搜索走 `repository.searchItems`，空查询给前缀提示；
/// 11) 四种类型同屏（含超长名字）时 900×600 依旧不溢出、侧边栏依旧 248。
///
/// 2.3.1 追加（"写入后不刷新"的 bug 修复）：
/// 12) 侧边栏文件夹列表全部由 `foldersProvider`（drift 流）推送：新建 / 改名 /
///     删除都不再调用 `ref.invalidate`，新建对话框与删除确认框里的两处死代码已删；
/// 13) 重命名后**标题栏**（`selectedFolderNameProvider`）与侧边栏同步更新。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  /// 与原生层的最小窗口尺寸保持一致（`windows/runner/win32_window.cpp` 的
  /// WM_GETMINMAXINFO，kMinWindowWidth/kMinWindowHeight = 900×600 逻辑像素）。
  /// 测试就在这个尺寸下跑，等于守住"最小窗口不溢出"的底线。
  const minWindow = Size(900, 600);

  // PBKDF2（100k 次）很慢：整个文件只派生一把会话密钥，所有测试复用。
  // 加密 / 解密只依赖密钥本身，与 CryptoService 实例无关。
  final seedCrypto = CryptoService(secureStorage: FakeSecureStorage());
  late final Uint8List sessionKey =
      seedCrypto.deriveKey('master-password', seedCrypto.generateSalt());

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
    // 解锁：条目流否则会返回空列表（仓储在未解锁时读不到任何东西）。
    container.read(encryptionKeyProvider.notifier).state = sessionKey;
  });

  tearDown(() => container.dispose());

  Future<AppLocalizations> pumpVaultScreen(
    WidgetTester tester, {
    Size size = minWindow,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const VaultScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.of(tester.element(find.byType(VaultScreen)));
  }

  /// 侧边栏的定宽盒 = 包住品牌图标的最内层 SizedBox（Scaffold 自己也有一层
  /// Material，按类型找会先命中整窗宽度的那个，所以必须沿图标向上找）。
  Finder sidebarBoxFinder() => find
      .ancestor(of: find.byIcon(Icons.security), matching: find.byType(SizedBox))
      .first;

  /// 点类型筛选 chip。
  ///
  /// 先 `ensureVisible`：筛选条是**横向可滚动**的（这是它在 900px 最小窗口下
  /// 不溢出的原因），而 flutter_test 的测试字体每个字符都占一个字宽，比真实字体
  /// 宽一倍左右，于是靠后的 chip 会落在屏幕外 —— 直接 tap() 会打空。
  Future<void> tapTypeChip(WidgetTester tester, String wireName) async {
    final chip = find.byKey(ValueKey('typeChip-$wireName'));
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();
  }

  /// 装一个假的剪贴板。
  ///
  /// 测试环境没有平台实现，`Clipboard.setData` 的 Future 永远不会完成，
  /// 复制按钮后面的 SnackBar 也就永远不出现（不是产品 bug）。返回的列表按顺序
  /// 收集每次复制的内容，顺便能断言"复制的是密码本身"。
  List<String?> installFakeClipboard(WidgetTester tester) {
    final copied = <String?>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String?);
      }
      return null;
    });
    addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    return copied;
  }

  VaultItem loginItem({
    String id = 'login-1',
    String name = 'GitHub',
    String url = 'https://github.com',
    String username = 'alice',
    String password = 'pw',
    bool favorite = false,
    String? folderId,
  }) {
    return VaultItem(
      id: id,
      folderId: folderId,
      type: EntryType.login,
      name: name,
      isFavorite: favorite,
      login: LoginData(url: url, username: username, password: password),
      createdAt: 0,
      updatedAt: 0,
    );
  }

  /// 一把梭写入四种类型的测试条目（走生产的加密路径）。
  Future<void> seedFourTypes() async {
    final repo = container.read(vaultRepositoryProvider);
    await repo.saveItem(loginItem(id: 'login-1', name: 'GitHub 登录'));
    await repo.saveItem(VaultItem(
      id: 'note-1',
      type: EntryType.secureNote,
      name: 'WiFi 笔记',
      notes: '家里路由器的密码',
      createdAt: 0,
      updatedAt: 0,
    ));
    await repo.saveItem(VaultItem(
      id: 'id-1',
      type: EntryType.identity,
      name: '身份证',
      identity: const IdentityData(firstName: '三', idNumber: '110101199001011234'),
      createdAt: 0,
      updatedAt: 0,
    ));
    await repo.saveItem(VaultItem(
      id: 'ssh-1',
      type: EntryType.sshKey,
      name: 'server key',
      sshKey: const SshKeyData(
        publicKey: 'ssh-ed25519 AAAA',
        fingerprint: 'SHA256:abcdef',
      ),
      createdAt: 0,
      updatedAt: 0,
    ));
  }

  testWidgets('最小窗口尺寸下无溢出；侧边栏固定 248 且没有生成器入口', (tester) async {
    final l10n = await pumpVaultScreen(tester);

    expect(tester.takeException(), isNull,
        reason: '900×600（最小窗口）下不应有任何 RenderFlex 溢出');

    // 先证明侧边栏真的渲染出来了，避免"整屏没渲染"造成的假通过。
    expect(find.byIcon(Icons.security), findsOneWidget,
        reason: '侧边栏顶部的品牌图标');
    expect(find.text(l10n.favorites), findsOneWidget, reason: '侧边栏"收藏"入口');

    expect(tester.getSize(sidebarBoxFinder()).width, 248,
        reason: '侧边栏是固定宽度，不再随窗口比例被压扁');

    expect(find.byIcon(Icons.auto_fix_high), findsOneWidget,
        reason: '本屏只剩右上角工具栏的生成器入口');
    expect(find.text(l10n.passwordGenerator), findsNothing,
        reason: '侧边栏的"密码生成器"项应已删除，不在任何位置重复出现');
  });

  testWidgets('品牌只出现一次（侧边栏），右栏工具栏显示上下文标题', (tester) async {
    final l10n = await pumpVaultScreen(tester);

    expect(find.byType(AppBar), findsNothing,
        reason: '已去掉顶层 AppBar：侧边栏因此能占满整个窗口高度');
    expect(find.text(l10n.appTitle), findsOneWidget,
        reason: '"EasyPass" 只保留在侧边栏顶部一处');

    // 上下文标题：侧边栏选中项 + 右栏工具栏各一份（默认视图 = 全部条目）。
    expect(find.text(l10n.allItems), findsNWidgets(2),
        reason: '侧边栏"全部条目" + 工具栏上下文标题');
  });

  testWidgets('两栏顶部严格等高：两条分隔线处于同一 y 坐标', (tester) async {
    await pumpVaultScreen(tester);

    final sidebarDivider =
        tester.getTopLeft(find.byKey(const ValueKey('sidebarHeaderDivider'))).dy;
    final toolbarDivider =
        tester.getTopLeft(find.byKey(const ValueKey('toolbarDivider'))).dy;

    expect(sidebarDivider, toolbarDivider,
        reason: '侧边栏品牌头与右栏工具栏共用 _topBarHeight，'
            '两条分隔线必须严格同高（不允许靠 padding 凑出来）');
    // 防退化：两条线都必须在顶部条"下方"，避免两边同时为 0 造成的假通过。
    expect(sidebarDivider, greaterThan(0),
        reason: '分隔线应位于顶部条下方，而不是贴在窗口顶端');
    expect(tester.takeException(), isNull);
  });

  testWidgets('新增按钮是纯图标 FAB，锚定在右下角', (tester) async {
    final l10n = await pumpVaultScreen(tester);

    final fab = tester.widget<FloatingActionButton>(
      find.byType(FloatingActionButton),
    );
    expect(fab.isExtended, isFalse, reason: '不应再是 extended（带文字标签）的 FAB');
    expect(fab.tooltip, l10n.add,
        reason: 'tooltip 保留：作为无障碍名称，悬停才出现');
    expect(
      find.descendant(
        of: find.byType(FloatingActionButton),
        matching: find.byType(Text),
      ),
      findsNothing,
      reason: 'FAB 内部不应有任何文字',
    );
    expect(find.byIcon(Icons.add), findsNWidgets(2),
        reason: '页面上的 + 图标：侧边栏"新建文件夹" + 右下角新增按钮');

    final fabRect = tester.getRect(find.byType(FloatingActionButton));
    expect(fabRect.right, greaterThan(minWindow.width - 120),
        reason: 'FAB 仍在窗口右下角（侧边栏改为全高后不应漂移）');
    expect(fabRect.bottom, greaterThan(minWindow.height - 120));
    expect(tester.takeException(), isNull);
  });

  testWidgets('超长文件夹名被 ellipsis 截断而不是溢出', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await container.read(vaultRepositoryProvider).addFolder(
          FoldersCompanion.insert(
            id: const Uuid().v4(),
            name: '这是一个特别特别长的文件夹名称' * 12,
            createdAt: now,
            updatedAt: now,
          ),
        );

    final l10n = await pumpVaultScreen(tester);

    expect(find.text(l10n.favorites), findsOneWidget, reason: '侧边栏确实渲染了');
    expect(tester.takeException(), isNull,
        reason: '长文件夹名必须走 maxLines/ellipsis，不能撑破 248px 的侧边栏');
  });

  // ─── 类型筛选（2.3.0）────────────────────────────────────

  testWidgets('类型筛选 chips 常驻，选中类型后只显示该类型条目', (tester) async {
    await seedFourTypes();
    final l10n = await pumpVaultScreen(tester);

    // 五个 chips：全部 + 四种类型（按 key 断言，避免和卡片上的类型徽章撞文案）。
    expect(find.byKey(const ValueKey('typeChip-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('typeChip-login')), findsOneWidget);
    expect(find.byKey(const ValueKey('typeChip-secure_note')), findsOneWidget);
    expect(find.byKey(const ValueKey('typeChip-identity')), findsOneWidget);
    expect(find.byKey(const ValueKey('typeChip-ssh_key')), findsOneWidget);
    expect(find.text(l10n.entryTypeAll), findsOneWidget,
        reason: '"全部类型"是筛选条的默认项');
    // 筛选条自己横向可滚：900px 最小窗口（+ 测试字体的宽字距）下也不会溢出。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('typeFilterBar')),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
      reason: '类型 chips 放在横向滚动条里，窄窗口不溢出',
    );

    // 默认全部类型：四类条目都在。
    expect(find.text('GitHub 登录'), findsOneWidget);
    expect(find.text('WiFi 笔记'), findsOneWidget);
    expect(find.text('身份证'), findsOneWidget);
    expect(find.text('server key'), findsOneWidget);

    await tapTypeChip(tester, 'secure_note');

    expect(find.text('WiFi 笔记'), findsOneWidget);
    expect(find.text('GitHub 登录'), findsNothing, reason: '筛类型后其它类型必须消失');
    expect(find.text('身份证'), findsNothing);

    await tapTypeChip(tester, 'ssh_key');
    expect(find.text('server key'), findsOneWidget);
    expect(find.text('WiFi 笔记'), findsNothing);

    // 切回"全部类型"后四类都回来（筛选不会把列表粘住）。
    await tapTypeChip(tester, 'all');
    expect(find.text('GitHub 登录'), findsOneWidget);
    expect(find.text('WiFi 笔记'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('类型筛选下空列表用 entryTypeEmptyForType 说明"哪个类型是空的"', (tester) async {
    final repo = container.read(vaultRepositoryProvider);
    await repo.saveItem(loginItem());
    final l10n = await pumpVaultScreen(tester);

    await tapTypeChip(tester, 'ssh_key');

    expect(
      find.text(l10n.entryTypeEmptyForType(l10n.entryTypeSshKey)),
      findsOneWidget,
      reason: '类型筛选激活时的空状态必须点名类型',
    );
    expect(find.text(l10n.emptyVaultTitle), findsNothing,
        reason: '有类型筛选时不该说"保险库是空的"（保险库里明明有登录条目）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('四种类型 + 超长名字在最小窗口下不溢出，侧边栏仍是 248', (tester) async {
    await seedFourTypes();
    final repo = container.read(vaultRepositoryProvider);
    await repo.saveItem(loginItem(
      id: 'long-1',
      name: '这是一个特别特别长的登录条目名称' * 8,
      url: 'https://example.com/${'path/' * 20}',
    ));

    final l10n = await pumpVaultScreen(tester);

    expect(find.text(l10n.entryTypeAll), findsOneWidget, reason: '筛选条渲染了');
    expect(tester.getSize(sidebarBoxFinder()).width, 248);
    expect(tester.takeException(), isNull,
        reason: '类型徽章 + 副标题 + trailing 的组合在 900×600 下不能溢出');

    // 两栏分隔线依旧同高（加了筛选条之后右栏顶部条没被挤动）。
    final sidebarDivider =
        tester.getTopLeft(find.byKey(const ValueKey('sidebarHeaderDivider'))).dy;
    final toolbarDivider =
        tester.getTopLeft(find.byKey(const ValueKey('toolbarDivider'))).dy;
    expect(sidebarDivider, toolbarDivider);

    // 类型徽章按类型渲染（卡片上的 Login 徽章，不是筛选条那个 chip）。
    expect(
      find.descendant(
        of: find.byType(EntryCard),
        matching: find.text(l10n.entryTypeLogin),
      ),
      findsNWidgets(2),
      reason: '两张登录卡片各带一个 Login 徽章',
    );
    expect(
      find.descendant(
        of: find.byType(EntryCard),
        matching: find.text(l10n.entryTypeSshKey),
      ),
      findsOneWidget,
      reason: 'SSH 卡片带 SSH key 徽章',
    );
  });

  // ─── 文件夹图标 / 重命名 / 删除（2.3.0）──────────────────

  testWidgets('新建文件夹可选图标，侧边栏渲染 folders.icon 而不是写死的 folder', (tester) async {
    final l10n = await pumpVaultScreen(tester);

    await tester.tap(find.byTooltip(l10n.newFolder));
    await tester.pumpAndSettle();
    expect(find.text(l10n.newFolder), findsWidgets, reason: '新建对话框打开了');
    expect(find.text(l10n.folderIconLabel), findsOneWidget,
        reason: '对话框里有图标选择器（folderIconLabel）');

    await tester.enterText(find.byType(TextField), '服务器');
    await tester.tap(find.byKey(const ValueKey('folderIcon-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.create));
    await tester.pumpAndSettle();

    // 新建对话框里已经**没有** ref.invalidate(foldersProvider)（2.3.1 删掉的
    // 死代码）：这一行断言同时也是"写入即推送"的回归守卫。
    expect(find.text('服务器'), findsOneWidget, reason: '文件夹出现在侧边栏');
    expect(find.byIcon(Icons.vpn_key_outlined), findsOneWidget,
        reason: '侧边栏用的是存储下来的图标');
    expect(find.byIcon(Icons.folder), findsNothing,
        reason: '不再硬编码 Icons.folder');

    final folders = await container.read(vaultRepositoryProvider).getFolders();
    expect(folders.single.icon, 'key', reason: '图标经 FoldersCompanion.icon 落库');
  });

  testWidgets('长按文件夹 → 重命名：对话框预填旧名，保存后侧边栏与标题栏都更新',
      (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await container.read(vaultRepositoryProvider).addFolder(
          FoldersCompanion.insert(
            id: const Uuid().v4(),
            name: '工作',
            createdAt: now,
            updatedAt: now,
          ),
        );
    final l10n = await pumpVaultScreen(tester);

    // 先选中它：标题栏显示文件夹名，于是 find.text('工作') 有侧边栏 + 标题两份。
    await tester.tap(find.text('工作'));
    await tester.pumpAndSettle();
    expect(find.text('工作'), findsNWidgets(2),
        reason: '侧边栏 + 工具栏上下文标题');

    await tester.longPress(find.text('工作').first);
    await tester.pumpAndSettle();
    expect(find.text(l10n.renameFolder), findsOneWidget,
        reason: '长按必须给出重命名入口');

    await tester.tap(find.text(l10n.renameFolder));
    await tester.pumpAndSettle();
    expect(find.text(l10n.folderEditTitle), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '工作',
      reason: '编辑对话框预填现有名字',
    );

    await tester.enterText(find.byType(TextField), '公司');
    await tester.tap(find.text(l10n.saveChanges));
    await tester.pumpAndSettle();

    expect(find.text('公司'), findsNWidgets(2),
        reason: '重命名后侧边栏与标题栏（selectedFolderNameProvider）都是新名字');
    expect(find.text('工作'), findsNothing, reason: '旧名字不再出现');
    expect(find.text(l10n.folderRenamed), findsOneWidget,
        reason: '重命名走的是 updateFolder 分支（不是新建）');

    final folders = await container.read(vaultRepositoryProvider).getFolders();
    expect(folders.single.name, '公司', reason: '走 repository.updateFolder 落库');
    expect(folders.single.id, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('回归：文件夹写入由流推送 —— 新建 / 改名 / 删除都无需手动 invalidate',
      (tester) async {
    final repo = container.read(vaultRepositoryProvider);
    final l10n = await pumpVaultScreen(tester);
    final now = DateTime.now().millisecondsSinceEpoch;

    // 模拟"别处写入"（另一个窗口 / 表单）：只碰仓储，不碰任何 provider，
    // 也不调用 ref.invalidate(foldersProvider)（2.3.1 已删掉那两处死代码）。
    await repo.addFolder(FoldersCompanion.insert(
      id: 'f-live',
      name: '工作',
      createdAt: now,
      updatedAt: now,
    ));
    await tester.pumpAndSettle();
    expect(find.text('工作'), findsOneWidget,
        reason: '新建的文件夹必须自己出现在侧边栏');

    // 选中 → 标题栏跟着走（selectedFolderNameProvider 也吃这条流）。
    await tester.tap(find.text('工作'));
    await tester.pumpAndSettle();
    expect(find.text('工作'), findsNWidgets(2), reason: '侧边栏 + 工具栏标题');

    // 改名：侧边栏与标题栏必须同时更新。
    await repo.updateFolder(
      'f-live',
      FoldersCompanion(name: const Value('公司'), updatedAt: Value(now)),
    );
    await tester.pumpAndSettle();
    expect(find.text('公司'), findsNWidgets(2),
        reason: '重命名后侧边栏与标题栏都是新名字');
    expect(find.text('工作'), findsNothing, reason: '旧名字不允许残留');

    // 夹内条目：当前选中的就是"公司"这个夹。
    await repo.saveItem(
        loginItem(id: 'in-live', name: '夹内条目', folderId: 'f-live'));
    await tester.pumpAndSettle();
    expect(find.text('夹内条目'), findsOneWidget, reason: '选中文件夹时显示夹内条目');

    // 删除走 UI（侧边栏长按 → 删除 → 确认）：文件夹消失、选中态清空、条目保留。
    await tester.longPress(find.text('公司').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.delete));
    await tester.pumpAndSettle();
    // 夹内还有条目 → 确认按钮是"保留条目"那一版（2.3.2 起的口径）。
    await tester.tap(
        find.widgetWithText(FilledButton, l10n.deleteFolderKeepEntries));
    await tester.pumpAndSettle();

    expect(find.text('公司'), findsNothing, reason: '侧边栏里的文件夹必须随流消失');
    expect(find.text(l10n.allItems), findsNWidgets(2),
        reason: '删掉选中的文件夹后标题回到"全部条目"');
    expect(find.text('夹内条目'), findsOneWidget, reason: '删文件夹不删条目');
    expect(container.read(selectedFolderIdProvider), isNull,
        reason: '被删掉的文件夹不能继续被选中');
    expect((await repo.getItems()).single.folderId, isNull,
        reason: 'removeFolder 会先解除归属');
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按文件夹 → 删除：条目保留但解除归属，选中态回到"全部条目"', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final folderId = const Uuid().v4();
    final repo = container.read(vaultRepositoryProvider);
    await repo.addFolder(FoldersCompanion.insert(
      id: folderId,
      name: '临时',
      createdAt: now,
      updatedAt: now,
    ));
    await repo.saveItem(loginItem(id: 'in-folder', name: '夹内条目', folderId: folderId));

    final l10n = await pumpVaultScreen(tester);

    // 先进入该文件夹（标题变成文件夹名）。
    await tester.tap(find.text('临时'));
    await tester.pumpAndSettle();
    expect(find.text('夹内条目'), findsOneWidget);
    expect(find.text('临时'), findsNWidgets(2),
        reason: '侧边栏 + 工具栏标题各一份');

    await tester.longPress(find.text('临时').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.delete));
    await tester.pumpAndSettle();

    expect(find.text(l10n.deleteFolderTitle), findsOneWidget);
    // 2.3.2：有条目时必须报数目 + 明说条目不会被删。
    expect(find.text(l10n.deleteFolderNotEmptyMessage('临时', 1)), findsOneWidget);
    await tester.tap(
        find.widgetWithText(FilledButton, l10n.deleteFolderKeepEntries));
    await tester.pumpAndSettle();

    // 文件夹没了、选中态清空 → 标题回到"全部条目"，条目本身还在（解除归属）。
    expect(find.text('临时'), findsNothing);
    expect(find.text('夹内条目'), findsOneWidget, reason: '删文件夹不能删条目');
    expect(container.read(selectedFolderIdProvider), isNull,
        reason: '删掉的文件夹不能继续被选中（标题否则会挂着一个不存在的名字）');
    final items = await repo.getItems();
    expect(items.single.folderId, isNull, reason: 'removeFolder 会先解除归属');
    expect(tester.takeException(), isNull);
  });

  // ─── 搜索（2.3.0）────────────────────────────────────────

  testWidgets('搜索：字段 hint、空前缀提示、结果走 searchItems 且用同一张卡片', (tester) async {
    final repo = container.read(vaultRepositoryProvider);
    await repo.saveItem(loginItem(
      id: 'gh',
      name: 'GitHub 登录',
      url: 'https://github.com',
      username: 'alice',
    ));
    await repo.saveItem(VaultItem(
      id: 'ssh',
      type: EntryType.sshKey,
      name: 'server key',
      sshKey: const SshKeyData(
        publicKey: 'ssh-ed25519 AAAA',
        fingerprint: 'SHA256:abcdef',
        comment: 'root@server',
      ),
      createdAt: 0,
      updatedAt: 0,
    ));

    final l10n = await pumpVaultScreen(tester);

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    expect(find.text(l10n.searchHint), findsOneWidget,
        reason: '搜索框 hint 用 l10n.searchHint');
    expect(find.text(l10n.searchPrefixesHint), findsOneWidget,
        reason: '空查询给前缀提示，而不是"没有结果"');
    expect(find.text(l10n.noResultsFound), findsNothing);

    // 类型前缀由仓储的 searchItems 解释（非登录类型也能被搜到）。
    await tester.enterText(find.byType(TextField), 'type:ssh');
    await tester.pumpAndSettle();
    expect(find.text('server key'), findsOneWidget);
    expect(find.text('GitHub 登录'), findsNothing);
    expect(find.byTooltip(l10n.copyPasswordTooltip), findsNothing,
        reason: 'SSH 卡片没有"复制密码"按钮');

    // 身份 / SSH / 自定义字段也在搜索范围内；搜不到时保持原行为。
    await tester.enterText(find.byType(TextField), 'zzz-not-exist');
    await tester.pumpAndSettle();
    expect(find.text(l10n.noResultsFound), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('复制密码：登录条目把密码写进剪贴板并提示，搜索结果也用同一张卡片', (tester) async {
    final repo = container.read(vaultRepositoryProvider);
    await repo.saveItem(loginItem(
      id: 'gh',
      name: 'GitHub 登录',
      url: 'https://github.com',
      username: 'alice',
      password: 'pw-copied',
    ));

    final l10n = await pumpVaultScreen(tester);
    final clipboard = installFakeClipboard(tester);

    // 列表里的登录条目：有复制按钮（isAutofillable）。
    await tester.tap(find.byTooltip(l10n.copyPasswordTooltip));
    await tester.pumpAndSettle();
    expect(find.text(l10n.passwordCopied), findsOneWidget);
    expect(clipboard, ['pw-copied'],
        reason: '登录条目复制的是密码本身（从不打印，只进剪贴板）');

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'github');
    await tester.pumpAndSettle();
    expect(find.text('GitHub 登录'), findsOneWidget, reason: '搜索结果用同一张卡片');
  });

  // ─── 文件夹的删除（2.3.2：用户报"只能加不能删" + 有条目的不许暴力删）─────

  /// 打开某个文件夹的操作面板（走显式的 ⋮ 按钮，而不是长按）。
  Future<void> openFolderActions(WidgetTester tester, String folderName) async {
    final tile = find.ancestor(
      of: find.text(folderName),
      matching: find.byType(ListTile),
    );
    final more = find.descendant(of: tile, matching: find.byIcon(Icons.more_vert));
    await tester.tap(more);
    await tester.pumpAndSettle();
  }

  testWidgets('每个文件夹都有看得见的操作入口（⋮ / 右键 / 长按三条路都通）', (tester) async {
    final repo = container.read(vaultRepositoryProvider);
    await repo.addFolder(FoldersCompanion.insert(
        id: 'f1', name: '邮箱', createdAt: 0, updatedAt: 0));
    await repo.addFolder(FoldersCompanion.insert(
        id: 'f2', name: '工作', createdAt: 0, updatedAt: 0));

    final l10n = await pumpVaultScreen(tester);

    // 每个文件夹一个 ⋮（这是用户真正会用的入口）
    expect(find.byTooltip(l10n.folderActions), findsNWidgets(2),
        reason: '删除入口必须"看得见"，长按是触屏手势，鼠标用户发现不了');

    await openFolderActions(tester, '邮箱');
    expect(find.text(l10n.renameFolder), findsOneWidget);
    expect(find.text(l10n.delete), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // 关掉面板
    await tester.pumpAndSettle();

    // 右键同样能打开（桌面习惯）
    await tester.tap(find.text('工作'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text(l10n.renameFolder), findsOneWidget);
  });

  testWidgets('删除空文件夹：普通确认即可，删完侧边栏立刻少一个', (tester) async {
    final repo = container.read(vaultRepositoryProvider);
    await repo.addFolder(FoldersCompanion.insert(
        id: 'f-empty', name: '空文件夹', createdAt: 0, updatedAt: 0));

    final l10n = await pumpVaultScreen(tester);
    await openFolderActions(tester, '空文件夹');
    await tester.tap(find.text(l10n.delete));
    await tester.pumpAndSettle();

    expect(find.text(l10n.deleteFolderMessage('空文件夹')), findsOneWidget);
    expect(find.text(l10n.deleteFolderKeepEntries), findsNothing,
        reason: '空文件夹不必吓唬用户');

    await tester.tap(find.widgetWithText(FilledButton, l10n.delete));
    await tester.pumpAndSettle();

    expect(find.text('空文件夹'), findsNothing);
    expect(find.text(l10n.folderDeleted('空文件夹')), findsOneWidget);
    expect(await repo.getFolders(), isEmpty);
  });

  testWidgets('删除有条目的文件夹：必须报出条目数 + 明说条目不会被删，且删完条目仍在',
      (tester) async {
    final repo = container.read(vaultRepositoryProvider);
    await repo.addFolder(FoldersCompanion.insert(
        id: 'f-work', name: '工作', createdAt: 0, updatedAt: 0));
    for (var i = 0; i < 3; i++) {
      await repo.saveItem(loginItem(
        id: 'w$i',
        name: '条目 $i',
        folderId: 'f-work',
      ));
    }

    final l10n = await pumpVaultScreen(tester);
    await openFolderActions(tester, '工作');
    await tester.tap(find.text(l10n.delete));
    await tester.pumpAndSettle();

    // 口径必须说清楚：有几条 + 条目不会被删 + 去哪了
    final warning = find.text(l10n.deleteFolderNotEmptyMessage('工作', 3));
    expect(warning, findsOneWidget,
        reason: '"有条目的不能暴力删除"—— 提示里必须带条目数');
    expect(find.text(l10n.deleteFolderMessage('工作')), findsNothing,
        reason: '有条目时不能走空文件夹那套轻描淡写的文案');
    expect(find.widgetWithText(FilledButton, l10n.deleteFolderKeepEntries),
        findsOneWidget,
        reason: '确认按钮本身要写明"保留条目"');
    expect(find.widgetWithText(FilledButton, l10n.delete), findsNothing);

    await tester.tap(find.text(l10n.deleteFolderKeepEntries));
    await tester.pumpAndSettle();

    // 文件夹没了，但条目一条不少，只是不再属于任何文件夹
    expect(await repo.getFolders(), isEmpty);
    final items = await repo.getItems();
    expect(items, hasLength(3), reason: '删文件夹绝不删条目');
    expect(items.every((i) => i.folderId == null), isTrue,
        reason: '条目被移到"无文件夹"，而不是留在指向已删文件夹的幽灵状态');
  });

  testWidgets('点取消：文件夹与条目都原封不动', (tester) async {
    final repo = container.read(vaultRepositoryProvider);
    await repo.addFolder(FoldersCompanion.insert(
        id: 'f1', name: '工作', createdAt: 0, updatedAt: 0));
    await repo.saveItem(loginItem(id: 'w0', name: '条目', folderId: 'f1'));

    final l10n = await pumpVaultScreen(tester);
    await openFolderActions(tester, '工作');
    await tester.tap(find.text(l10n.delete));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();

    expect(await repo.getFolders(), hasLength(1));
    expect((await repo.getItems()).single.folderId, 'f1');
    expect(find.text('工作'), findsOneWidget);
  });
}
