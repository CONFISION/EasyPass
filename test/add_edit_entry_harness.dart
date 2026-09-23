import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
import 'package:easypass/features/vault/screens/add_edit_entry_screen.dart';
import 'package:easypass/features/vault/widgets/entry_type_bits.dart';
import 'package:easypass/l10n/app_localizations.dart';

import 'fakes.dart';

/// 文字断言一律用英文串：脚手架把 app locale 钉成 `en`，
/// 不依赖跑测机器的系统语言。
AppLocalizations get enL10n => lookupAppLocalizations(const Locale('en'));

/// 结构合法的 Ed25519 公钥（`ssh-string` 编码 + 32 字节填充）。
///
/// 不是真密钥，但走的是 OpenSSH 单行格式，[SshKeyService] 能解析出
/// 指纹 / 类型 / 位数 / 注释——正是表单自动推导要覆盖的路径。
String fakeEd25519PublicKey({String comment = 'alice@laptop'}) {
  final builder = BytesBuilder();
  void addBlob(List<int> bytes) {
    builder.add([
      (bytes.length >> 24) & 0xff,
      (bytes.length >> 16) & 0xff,
      (bytes.length >> 8) & 0xff,
      bytes.length & 0xff,
    ]);
    builder.add(bytes);
  }

  addBlob(utf8.encode('ssh-ed25519'));
  addBlob(List<int>.filled(32, 7));
  return 'ssh-ed25519 ${base64.encode(builder.toBytes())} $comment';
}

/// 表单 widget test 的脚手架：内存库 + 已解锁的会话密钥 + 一个真实的
/// GoRouter（保存后会 `context.pop()`，没有路由就弹不回去）。
class EntryFormHarness {
  EntryFormHarness() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    crypto = CryptoService(secureStorage: FakeSecureStorage());
    key = crypto.deriveKey('master', crypto.generateSalt());
    container = ProviderContainer(
      overrides: [
        cryptoServiceProvider.overrideWithValue(crypto),
        databaseProvider.overrideWithValue(db),
      ],
    );
    // 解锁：VaultRepository 每次调用时现读密钥。
    container.read(encryptionKeyProvider.notifier).state = key;
  }

  late final AppDatabase db;
  late final CryptoService crypto;
  late final Uint8List key;
  late final ProviderContainer container;

  VaultRepository get repo => container.read(vaultRepositoryProvider);

  Future<void> dispose() async {
    container.dispose();
    await db.close();
  }

  /// 打开"新增条目"。
  Future<void> pumpAdd(WidgetTester tester) => _pump(tester, null);

  /// 打开"编辑条目"（先渲染 `/`，再 push 编辑页，这样 `pop()` 有地方可回）。
  Future<void> pumpEdit(WidgetTester tester, String entryId) =>
      _pump(tester, entryId);

  Future<void> _pump(WidgetTester tester, String? entryId) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('vault-home')),
        ),
        GoRoute(
          path: '/vault/add',
          builder: (_, _) => const AddEditEntryScreen(),
        ),
        GoRoute(
          path: '/vault/edit/:id',
          builder: (_, state) =>
              AddEditEntryScreen(entryId: state.pathParameters['id']),
        ),
        GoRoute(
          path: '/generator',
          builder: (_, _) => const Scaffold(body: Text('generator')),
        ),
      ],
    );

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

    unawaited(
      router.push(entryId == null ? '/vault/add' : '/vault/edit/$entryId'),
    );
    await tester.pumpAndSettle();
  }

  /// 失焦 → 滚进可视区 → 点击。
  ///
  /// **必须先失焦**：输入框还持有焦点时，`EditableText` 会通过 showOnScreen 在
  /// 下一帧把视图拉回焦点字段，"滚到按钮"的那一跳随即被撤销——widget test 里
  /// 表现为 tap 落在屏幕外（按钮实际没被点到），真实用户表现为滚下去又弹回来。
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pump();
  }

  /// 点开类型选择器（**下拉**，不是四张卡片）。
  ///
  /// 2.3.1 起 `EntryTypeSelector` = `InputDecorator` + 完全受控的
  /// `DropdownButton<EntryType>`（key `entryTypeDropdown`）。
  Future<void> openTypeDropdown(WidgetTester tester) async {
    final dropdown = find.byKey(const Key('entryTypeDropdown'));
    expect(dropdown, findsOneWidget, reason: '类型选择器必须是下拉框');
    expect(find.byType(DropdownButton<EntryType>), findsOneWidget);
    await tapVisible(tester, dropdown);
    await tester.pumpAndSettle();
  }

  /// 在下拉里选一个类型（文案来自 [EntryTypeBits.label]）。
  ///
  /// 菜单项在 overlay 里，按钮上还有一份"当前值"的同名文案 ——
  /// 同名时取 `.last`（overlay 在页面之后入树）。
  Future<void> selectType(WidgetTester tester, EntryType type) async {
    final label = EntryTypeBits.label(enL10n, type);
    await openTypeDropdown(tester);
    final option = find.text(label);
    expect(option, findsWidgets, reason: '类型下拉菜单里必须有「$label」');
    await tester.tap(option.last);
    await tester.pumpAndSettle();
  }

  /// 选择器当前显示的类型（受控组件，读的就是它拿到的 `value`）。
  EntryType readSelectedType(WidgetTester tester) {
    return tester
        .widget<DropdownButton<EntryType>>(
          find.byKey(const Key('entryTypeDropdown')),
        )
        .value!;
  }

  /// 打开文件夹下拉。
  Future<void> openFolderDropdown(WidgetTester tester) async {
    await tapVisible(tester, find.byKey(EntryFormKeys.folder));
    await tester.pumpAndSettle();
  }

  /// 文件夹下拉当前提供的选项（`null` = 无文件夹）。
  ///
  /// 直接读 `DropdownButton.items`：这是"表单到底提供了哪些文件夹"的
  /// 唯一真相，用户报的 bug（只给无文件夹 + 第一个）就是它少了项。
  List<String?> folderOptionIds(WidgetTester tester) {
    final dropdown = tester.widget<DropdownButton<String?>>(
      find.byKey(EntryFormKeys.folder),
    );
    return dropdown.items!.map((item) => item.value).toList();
  }

  /// 文件夹下拉当前**显示**的 id（受控组件：读到的就是它拿到的 value）。
  String? readSelectedFolderId(WidgetTester tester) {
    return tester
        .widget<DropdownButton<String?>>(find.byKey(EntryFormKeys.folder))
        .value;
  }

  /// 建一个文件夹 —— 走仓储，和 UI 用的是同一条写入路径。
  ///
  /// 返回文件夹 id；[folderIds] 里也留了一份名字 → id 的映射。
  Future<String> addFolder(String name) async {
    final id = 'folder-${folderIds.length + 1}';
    final now = DateTime.now().millisecondsSinceEpoch;
    await repo.addFolder(
      FoldersCompanion.insert(
        id: id,
        name: name,
        createdAt: now,
        updatedAt: now,
      ),
    );
    folderIds[name] = id;
    return id;
  }

  /// 名字 → 文件夹 id（[addFolder] 建的）。
  final Map<String, String> folderIds = {};

  /// 点保存（把按钮滚进可视区再点，避免"点在了屏幕外"的假失败）。
  Future<void> tapSave(WidgetTester tester) async {
    await tapVisible(tester, find.byKey(EntryFormKeys.save));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 让 SnackBar 走完自己的 4 秒计时器。
  ///
  /// 不冲掉的话测试结束时会留下 pending Timer，widget test 直接判失败。
  Future<void> flushSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  /// 保存用的登录条目（类型切换测试的种子数据）。
  VaultItem loginItem({
    String id = 'seed-login',
    String name = 'GitHub',
    String url = 'https://github.com',
    String username = 'alice',
    String password = 'pw-seed',
    String notes = '',
    bool favorite = false,
    String? folderId,
  }) {
    return VaultItem(
      id: id,
      folderId: folderId,
      type: EntryType.login,
      name: name,
      notes: notes,
      isFavorite: favorite,
      login: LoginData(
        url: url,
        username: username,
        password: password,
      ),
      createdAt: 0,
      updatedAt: 0,
    );
  }
}
