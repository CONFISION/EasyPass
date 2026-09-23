import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/data/database/database.dart' show FoldersCompanion;
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/features/vault/providers/vault_provider.dart';
import 'package:easypass/features/vault/screens/add_edit_entry_screen.dart';
import 'package:easypass/features/vault/widgets/entry_type_bits.dart';

import 'add_edit_entry_harness.dart';

/// 新增/编辑条目表单的屏幕级行为：生成密码预填回归、类型选择器（下拉）、
/// 文件夹下拉（实时 / 删除兜底）、编辑既有条目、条目不存在、删除确认、
/// 保存后的实时刷新、900×600 最小窗口布局。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late EntryFormHarness harness;

  setUp(() => harness = EntryFormHarness());
  tearDown(() => harness.dispose());

  /// 旧的定位方式（"密码框是第 4 个 TextFormField"）在类型选择器加入后
  /// 不再成立——现在一律按 [EntryFormKeys] 找字段。
  String readField(WidgetTester tester, Key key) {
    final field = tester.widget<TextFormField>(find.byKey(key));
    return field.controller?.text ?? '';
  }

  String readPasswordField(WidgetTester tester) =>
      readField(tester, EntryFormKeys.password);

  // ─── 回归：生成密码预填 ───────────────────────────────

  testWidgets('open add-entry twice in one session yields different passwords',
      (tester) async {
    // First open.
    await harness.pumpAdd(tester);
    final firstPassword = readPasswordField(tester);
    expect(firstPassword, isNotEmpty,
        reason: 'add screen pre-fills a password');

    // Close the screen (unmount), then open it again — same ProviderScope,
    // simulating the user adding another entry without restarting the app.
    await tester.pumpWidget(const SizedBox.shrink());
    await harness.pumpAdd(tester);
    final secondPassword = readPasswordField(tester);
    expect(secondPassword, isNotEmpty);

    expect(
      secondPassword,
      isNot(equals(firstPassword)),
      reason: 'each add-entry screen open must pre-fill a fresh password',
    );
  });

  // ─── 类型选择器 ───────────────────────────────────────

  testWidgets('新建默认是登录类型：密码/网址/TOTP 都在，没有笔记正文框', (tester) async {
    await harness.pumpAdd(tester);

    expect(find.byKey(EntryFormKeys.password), findsOneWidget);
    expect(find.byKey(EntryFormKeys.url), findsOneWidget);
    expect(find.byKey(EntryFormKeys.username), findsOneWidget);
    expect(find.byKey(EntryFormKeys.totpSecret), findsOneWidget);
    expect(find.text(enL10n.secureNoteBodyLabel), findsNothing);
    expect(find.byKey(EntryFormKeys.ssh('public_key')), findsNothing);
    expect(find.byKey(EntryFormKeys.identity('first_name')), findsNothing);
  });

  testWidgets('切到安全笔记：登录字段消失，笔记正文（notes）变成主输入区',
      (tester) async {
    await harness.pumpAdd(tester);
    await harness.selectType(tester, EntryType.secureNote);

    expect(find.byKey(EntryFormKeys.password), findsNothing);
    expect(find.byKey(EntryFormKeys.url), findsNothing);
    expect(find.byKey(EntryFormKeys.username), findsNothing);
    expect(find.byKey(EntryFormKeys.totpSecret), findsNothing);
    expect(find.text(enL10n.secureNoteBodyLabel), findsOneWidget);
    expect(find.byKey(EntryFormKeys.notes), findsOneWidget);

    // 自定义字段与文件夹是四种类型共用的。
    expect(find.byKey(EntryFormKeys.customFields), findsOneWidget);
    expect(find.byKey(EntryFormKeys.favorite), findsOneWidget);
  });

  testWidgets('四种类型在 900×600 最小窗口下都不溢出', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await harness.pumpAdd(tester);
    expect(tester.takeException(), isNull, reason: 'login 布局不应溢出');

    for (final type in EntryType.values) {
      await harness.selectType(tester, type);
      expect(
        tester.takeException(),
        isNull,
        reason: '${type.wireName} 的字段分区不应溢出',
      );

      // 真的切过去了（而不是"选了没生效、四次都在量同一套布局"）：
      // 选择器显示新类型，且该类型自己的字段分区确实渲染了出来。
      expect(
        harness.readSelectedType(tester),
        type,
        reason: '900×600 用例必须逐个类型都真的切换过',
      );
      final anchor = switch (type) {
        EntryType.login => find.byKey(EntryFormKeys.url),
        EntryType.secureNote => find.text(enL10n.secureNoteBodyLabel),
        EntryType.identity => find.byKey(EntryFormKeys.identity('first_name')),
        EntryType.sshKey => find.byKey(EntryFormKeys.ssh('public_key')),
      };
      expect(anchor, findsOneWidget, reason: '${type.wireName} 的字段分区必须渲染');

      // 滚到底部（保存按钮）也要能完整布局。
      await tester.ensureVisible(find.byKey(EntryFormKeys.save));
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: '${type.wireName} 滚动到底部不应溢出',
      );
    }
  });

  testWidgets('类型选择器是下拉框（不是平铺的四张卡片），四个类型都能选、彩色图标保留',
      (tester) async {
    await harness.pumpAdd(tester);

    // 是受控下拉：`InputDecorator` + `DropdownButton<EntryType>`。
    expect(find.byKey(const Key('entryTypeDropdown')), findsOneWidget);
    expect(find.byType(DropdownButton<EntryType>), findsOneWidget);
    // 收起时只有当前类型那一行；旧的四卡片布局会把四个类型名全铺在表单上。
    expect(find.text(enL10n.entryTypeLogin), findsOneWidget);
    expect(find.text(enL10n.entryTypeSecureNote), findsNothing);
    expect(find.text(enL10n.entryTypeIdentity), findsNothing);
    expect(find.text(enL10n.entryTypeSshKey), findsNothing);

    // 展开后四个类型都点得到，且每个菜单项都带类型色图标
    // （彩色图标是用户明确说"满意、要保留"的部分）。
    await harness.openTypeDropdown(tester);
    for (final type in EntryType.values) {
      expect(
        find.widgetWithText(
          DropdownMenuItem<EntryType>,
          EntryTypeBits.label(enL10n, type),
        ),
        findsWidgets,
        reason: '下拉菜单里必须能选到 ${type.wireName}',
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Icon &&
              widget.icon == EntryTypeBits.icon(type) &&
              widget.color == EntryTypeBits.color(type),
        ),
        findsWidgets,
        reason: '${type.wireName} 的类型色图标必须保留',
      );
    }

    // 选最后一个类型：选择器显示新值，表单换成对应分区。
    await tester.tap(find.text(enL10n.entryTypeSshKey).last);
    await tester.pumpAndSettle();
    expect(harness.readSelectedType(tester), EntryType.sshKey);
    expect(find.text(enL10n.entryTypeSshKey), findsOneWidget);
    expect(find.byKey(EntryFormKeys.ssh('public_key')), findsOneWidget);
    expect(find.byKey(EntryFormKeys.url), findsNothing);
  });

  testWidgets('编辑态取消类型切换：选择器与表单都停在原类型（不会显示被拒的新类型）',
      (tester) async {
    await harness.repo.saveItem(harness.loginItem());
    await harness.pumpEdit(tester, 'seed-login');
    expect(harness.readSelectedType(tester), EntryType.login);

    // 在下拉里选"身份信息" → 弹确认框。
    await harness.selectType(tester, EntryType.identity);
    expect(find.text(enL10n.entryTypeSwitchTitle), findsOneWidget);

    await tester.tap(find.text(enL10n.cancel));
    await tester.pumpAndSettle();

    // 选择器必须还显示"登录"：受控下拉只认父层 value，不会自己记住被拒的选择。
    expect(harness.readSelectedType(tester), EntryType.login);
    expect(find.text(enL10n.entryTypeLogin), findsOneWidget);
    expect(find.text(enL10n.entryTypeIdentity), findsNothing);
    // 表单也还是登录那套字段。
    expect(find.byKey(EntryFormKeys.url), findsOneWidget);
    expect(find.byKey(EntryFormKeys.identity('first_name')), findsNothing);

    // 接着保存：仍然是登录条目，原字段一个没丢。
    await harness.tapSave(tester);
    await harness.flushSnackBar(tester);

    final item = (await harness.repo.getItems()).single;
    expect(item.type, EntryType.login);
    expect(item.loginOrEmpty.url, 'https://github.com');
    expect(item.loginOrEmpty.password, 'pw-seed');
  });

  // ─── 文件夹下拉（实时 + 删除兜底）──────────────────────

  testWidgets('文件夹下拉列出全部文件夹，而不是"无文件夹 + 第一个"', (tester) async {
    final work = await harness.addFolder('工作');
    final personal = await harness.addFolder('个人');
    final server = await harness.addFolder('服务器');
    await harness.pumpAdd(tester);

    // 表单实际提供的选项 = 无文件夹 + 全部三个。
    // （旧实现是私有 FutureProvider，缓存住首次的列表，只会给出第一个。）
    expect(
      harness.folderOptionIds(tester),
      hasLength(4),
      reason: '无文件夹 + 3 个文件夹',
    );
    expect(
      harness.folderOptionIds(tester),
      containsAll(<String?>[null, work, personal, server]),
    );

    // 用户真正看到的菜单里也都在。
    await harness.openFolderDropdown(tester);
    expect(find.text(enL10n.noFolder), findsWidgets);
    for (final name in ['工作', '个人', '服务器']) {
      expect(find.text(name), findsWidgets, reason: '「$name」必须出现在下拉菜单里');
    }

    // 选最后一个（旧实现根本提供不了）→ 保存后条目确实挂在它下面。
    await tester.tap(find.text('服务器').last);
    await tester.pumpAndSettle();
    expect(harness.readSelectedFolderId(tester), server);
    expect(find.text('服务器'), findsOneWidget);

    await tester.enterText(find.byKey(EntryFormKeys.name), 'in server folder');
    await tester.enterText(find.byKey(EntryFormKeys.password), 'pw-1');
    await harness.tapSave(tester);
    await harness.flushSnackBar(tester);

    final item = (await harness.repo.getItems()).single;
    expect(item.folderId, server);
  });

  testWidgets('表单打开期间新增 / 改名文件夹：下拉立刻跟着变（列表是活的）',
      (tester) async {
    final work = await harness.addFolder('工作');
    await harness.pumpAdd(tester);
    expect(harness.folderOptionIds(tester), hasLength(2));
    expect(harness.folderOptionIds(tester), containsAll(<String?>[null, work]));

    // 表单还开着的时候，别处（侧边栏 / 导入 / 同步）又建了两个文件夹 ——
    // 这正是用户报的场景：缓存版的表单只会一直给"无文件夹 + 工作"。
    final fresh = await harness.addFolder('新文件夹');
    final second = await harness.addFolder('第二个');
    await tester.pumpAndSettle();

    expect(
      harness.folderOptionIds(tester),
      containsAll(<String?>[null, work, fresh, second]),
      reason: '文件夹列表必须是 drift 流：新增后无需重开表单',
    );
    await harness.openFolderDropdown(tester);
    expect(find.text('新文件夹'), findsWidgets);
    expect(find.text('第二个'), findsWidgets);
    await tester.tap(find.text('新文件夹').last);
    await tester.pumpAndSettle();
    expect(harness.readSelectedFolderId(tester), fresh);

    // 改名同理 —— 打开着的表单里显示的名字也要更新。
    await harness.repo.updateFolder(
      fresh,
      FoldersCompanion(
        name: const Value('改名了'),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    await tester.pumpAndSettle();
    await harness.openFolderDropdown(tester);
    expect(find.text('改名了'), findsWidgets, reason: '改名也要推到打开着的表单');
    expect(find.text('新文件夹'), findsNothing);
  });

  testWidgets('编辑期间文件夹被删除：回退到"无文件夹"，不崩，也不会把旧 id 写回去',
      (tester) async {
    final temp = await harness.addFolder('临时');
    await harness.repo.saveItem(harness.loginItem(folderId: temp));
    await harness.pumpEdit(tester, 'seed-login');
    expect(harness.readSelectedFolderId(tester), temp);

    // 表单还开着，文件夹在别处被删了（本地列表 → 编辑页这条流会推过来）。
    await harness.repo.removeFolder(temp);
    await tester.pumpAndSettle();

    // 旧实现把不在 items 里的 value 交给下拉框 → 断言崩溃（红屏）。
    expect(tester.takeException(), isNull, reason: 'value 不在 items 里不能崩');
    expect(harness.readSelectedFolderId(tester), isNull);
    expect(find.text(enL10n.noFolder), findsOneWidget);
    expect(find.text('临时'), findsNothing);

    await harness.tapSave(tester);
    await harness.flushSnackBar(tester);

    final item = await harness.repo.getItem('seed-login');
    expect(item!.folderId, isNull, reason: '不能把已删除的文件夹 id 写回条目');
    expect(await harness.repo.getFolders(), isEmpty);
  });

  // ─── 校验 ─────────────────────────────────────────────

  testWidgets('登录条目缺密码：校验报错且不落库', (tester) async {
    await harness.pumpAdd(tester);
    await tester.enterText(find.byKey(EntryFormKeys.name), 'GitHub');
    await tester.enterText(find.byKey(EntryFormKeys.password), '');
    await harness.tapSave(tester);

    expect(find.text(enL10n.passwordRequired), findsOneWidget);
    expect(await harness.repo.countItems(), 0);
  });

  testWidgets('名称为空：校验报错且不落库', (tester) async {
    await harness.pumpAdd(tester);
    await harness.tapSave(tester);

    expect(find.text(enL10n.nameRequired), findsOneWidget);
    expect(await harness.repo.countItems(), 0);
  });

  // ─── 登录条目的保存 / 回填 ─────────────────────────────

  testWidgets('保存登录条目：登录字段走列，notes 一起落库', (tester) async {
    await harness.pumpAdd(tester);
    await tester.enterText(find.byKey(EntryFormKeys.name), 'GitLab');
    await tester.enterText(find.byKey(EntryFormKeys.url), 'https://gitlab.com');
    await tester.enterText(find.byKey(EntryFormKeys.username), 'alice');
    await tester.enterText(find.byKey(EntryFormKeys.password), 'pw-123');
    await tester.enterText(
        find.byKey(EntryFormKeys.totpSecret), 'JBSWY3DPEHPK3PXP');
    await tester.enterText(find.byKey(EntryFormKeys.notes), 'work account');
    await harness.tapSave(tester);

    expect(find.text(enL10n.entrySaved), findsWidgets);
    await harness.flushSnackBar(tester);

    final items = await harness.repo.getItems(type: EntryType.login);
    expect(items, hasLength(1));
    final login = items.single.loginOrEmpty;
    expect(items.single.name, 'GitLab');
    expect(items.single.notes, 'work account');
    expect(login.url, 'https://gitlab.com');
    expect(login.username, 'alice');
    expect(login.password, 'pw-123');
    expect(login.totpSecret, 'JBSWY3DPEHPK3PXP');

    // 明文绝不进列。
    final row = await harness.db.getEntryById(items.single.id);
    expect(row!.passwordEncrypted, isNotEmpty);
    expect(row.passwordEncrypted, isNot(contains('pw-123')));
    expect(row.notesEncrypted, isNot(contains('work account')));
  });

  testWidgets('编辑既有登录条目：按条目自己的类型回填字段', (tester) async {
    await harness.repo.saveItem(
      harness.loginItem(notes: 'seed notes', favorite: true),
    );
    await harness.pumpEdit(tester, 'seed-login');

    expect(readField(tester, EntryFormKeys.name), 'GitHub');
    expect(readField(tester, EntryFormKeys.url), 'https://github.com');
    expect(readField(tester, EntryFormKeys.username), 'alice');
    expect(readPasswordField(tester), 'pw-seed');
    expect(readField(tester, EntryFormKeys.notes), 'seed notes');
    expect(
      tester.widget<SwitchListTile>(find.byKey(EntryFormKeys.favorite)).value,
      isTrue,
    );
    expect(find.byKey(EntryFormKeys.delete), findsOneWidget);
    // 编辑态不预填生成密码（否则每次打开都会改掉用户存的密码）。
    expect(readPasswordField(tester), 'pw-seed');
  });

  testWidgets('编辑保存：走 saveItem 更新，不新增条目', (tester) async {
    await harness.repo.saveItem(harness.loginItem());
    await harness.pumpEdit(tester, 'seed-login');

    await tester.enterText(find.byKey(EntryFormKeys.username), 'bob');
    await harness.tapSave(tester);
    expect(find.text(enL10n.entryUpdated), findsWidgets);
    await harness.flushSnackBar(tester);

    final items = await harness.repo.getItems();
    expect(items, hasLength(1));
    expect(items.single.id, 'seed-login');
    expect(items.single.loginOrEmpty.username, 'bob');
    expect(items.single.loginOrEmpty.password, 'pw-seed');
  });

  testWidgets('编辑保存后：仓储、条目流与列表 provider 都拿到新值（全程没有手动刷新）',
      (tester) async {
    await harness.repo.saveItem(harness.loginItem());
    await harness.pumpEdit(tester, 'seed-login');

    // 列表页读的那条 drift 流 + 它外面的 provider。保存前先订阅，
    // 看它们会不会**自己**推新值 —— 这里刻意不调用任何 invalidate：
    // 手写失效正是 2.3.1 之前"保存后界面还是旧数据"的来源。
    final rowEmissions = <List<VaultItem>>[];
    final rowSub = harness.repo.watchItems().listen(rowEmissions.add);
    addTearDown(rowSub.cancel);

    final providerEmissions = <List<VaultItem>>[];
    final providerSub = harness.container.listen(
      vaultEntriesProvider,
      (_, next) {
        final value = next.valueOrNull;
        if (value != null) providerEmissions.add(value);
      },
      fireImmediately: true,
    );
    addTearDown(providerSub.close);

    await tester.pumpAndSettle();
    expect(rowEmissions, isNotEmpty, reason: '订阅后先收到当前列表');
    expect(rowEmissions.last.single.loginOrEmpty.username, 'alice');
    expect(providerEmissions, isNotEmpty);
    expect(providerEmissions.last.single.loginOrEmpty.username, 'alice');

    await tester.enterText(find.byKey(EntryFormKeys.username), 'bob');
    await harness.tapSave(tester);
    await harness.flushSnackBar(tester);

    // 1) 仓储里是保存后的值。
    final stored = await harness.repo.getItem('seed-login');
    expect(stored, isNotNull);
    expect(stored!.loginOrEmpty.username, 'bob');
    expect(stored.updatedAt, isNot(0), reason: 'updatedAt 由仓储刷新');

    // 2) 条目流自己推了新值。
    expect(rowEmissions.length, greaterThan(1), reason: '保存必须触发一次推送');
    expect(rowEmissions.last.single.loginOrEmpty.username, 'bob');
    // 3) 列表 provider（UI 真正渲染的那份）也推了新值。
    expect(providerEmissions.last.single.loginOrEmpty.username, 'bob');
  });

  testWidgets('条目不存在时显示 entryNotFound', (tester) async {
    await harness.pumpEdit(tester, 'missing-entry');

    expect(find.byKey(EntryFormKeys.notFound), findsOneWidget);
    expect(find.text(enL10n.entryNotFound), findsOneWidget);
  });

  // ─── 删除 ─────────────────────────────────────────────

  testWidgets('删除仍走确认框，确认后条目消失', (tester) async {
    await harness.repo.saveItem(harness.loginItem());
    await harness.pumpEdit(tester, 'seed-login');

    await tester.tap(find.byKey(EntryFormKeys.delete));
    await tester.pumpAndSettle();
    expect(find.text(enL10n.deleteEntryTitle), findsOneWidget);
    expect(find.text(enL10n.deleteEntryMessage), findsOneWidget);

    await tester.tap(find.text(enL10n.delete));
    await tester.pumpAndSettle();

    expect(await harness.repo.getItem('seed-login'), isNull);
    expect(find.text('vault-home'), findsOneWidget);
  });

  testWidgets('删除确认框可以取消', (tester) async {
    await harness.repo.saveItem(harness.loginItem());
    await harness.pumpEdit(tester, 'seed-login');

    await tester.tap(find.byKey(EntryFormKeys.delete));
    await tester.pumpAndSettle();
    await tester.tap(find.text(enL10n.cancel));
    await tester.pumpAndSettle();

    expect(await harness.repo.getItem('seed-login'), isNotNull);
    expect(find.byKey(EntryFormKeys.save), findsOneWidget);
  });
}
