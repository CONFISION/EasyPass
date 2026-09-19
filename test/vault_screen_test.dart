import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/features/vault/screens/vault_screen.dart';
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
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  /// 与原生层的最小窗口尺寸保持一致（`windows/runner/win32_window.cpp` 的
  /// WM_GETMINMAXINFO，kMinWindowWidth/kMinWindowHeight = 900×600 逻辑像素）。
  /// 测试就在这个尺寸下跑，等于守住"最小窗口不溢出"的底线。
  const minWindow = Size(900, 600);

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
}
