import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/data/state/session_key.dart';
import 'package:easypass/features/vault/providers/entry_item_provider.dart';
import 'package:easypass/features/vault/providers/vault_provider.dart';

import 'fakes.dart';

/// 保险库 provider 的契约（2.3.0：全部 stream / hold [VaultItem]）：
/// 1) 列表那条流把 **文件夹 + 类型 + 收藏** 三个维度叠加，互不覆盖（契约 §10.9）；
/// 2) 类型筛选对收藏视图同样生效；
/// 3) `selectedFolderNameProvider` 在文件夹消失时返回 null（旧实现 firstWhere
///    没有 orElse，会抛 StateError 把整屏打崩）；
/// 4) 搜索走 `repository.searchItems`（前缀 + 类型专属字段）；
/// 5) `entryItemProvider` 交出的已经是**解密后**的 VaultItem。
///
/// 2.3.1 追加（"写入后不刷新"的 bug 修复）：
/// 6) `foldersProvider` / `entryItemProvider` 的刷新只能来自 drift 的推送 ——
///    下面的用例里**一次 `invalidate` 都没有**（以前靠手写失效，漏一处就出
///    "文件夹下拉只剩第一个"“详情页看不到新加的自定义字段”这类问题）。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // PBKDF2 很慢：整个文件只派生一把会话密钥。
  final seedCrypto = CryptoService(secureStorage: FakeSecureStorage());
  late final Uint8List sessionKey =
      seedCrypto.deriveKey('master-password', seedCrypto.generateSalt());

  late ProviderContainer container;

  VaultItem loginItem({
    required String id,
    required String name,
    String? folderId,
    bool favorite = false,
    String password = 'pw',
  }) {
    return VaultItem(
      id: id,
      folderId: folderId,
      type: EntryType.login,
      name: name,
      isFavorite: favorite,
      login: LoginData(
        url: 'https://example.com/$id',
        username: '$id@example.com',
        password: password,
      ),
      createdAt: 0,
      updatedAt: 0,
    );
  }

  setUp(() async {
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
    addTearDown(container.dispose);
    // 解锁（未解锁时仓储的读接口一律返回空）。
    container.read(encryptionKeyProvider.notifier).state = sessionKey;

    final repo = container.read(vaultRepositoryProvider);
    await repo.addFolder(FoldersCompanion.insert(
      id: 'f-work',
      name: '工作',
      createdAt: 0,
      updatedAt: 0,
    ));
    await repo.addFolder(FoldersCompanion.insert(
      id: 'f-home',
      name: '家里',
      createdAt: 0,
      updatedAt: 0,
    ));
    // 工作夹里的收藏登录 + 工作夹里的笔记 + 家里夹的登录 + 无文件夹的 SSH。
    await repo.saveItem(loginItem(
      id: 'login-work',
      name: '公司邮箱',
      folderId: 'f-work',
      favorite: true,
      password: 'pw-work',
    ));
    await repo.saveItem(loginItem(
      id: 'login-home',
      name: '个人邮箱',
      folderId: 'f-home',
    ));
    await repo.saveItem(VaultItem(
      id: 'note-work',
      folderId: 'f-work',
      type: EntryType.secureNote,
      name: 'WiFi',
      notes: '家里路由器的密码',
      createdAt: 0,
      updatedAt: 0,
    ));
    await repo.saveItem(VaultItem(
      id: 'ssh-none',
      type: EntryType.sshKey,
      name: 'server key',
      sshKey: const SshKeyData(
        publicKey: 'ssh-ed25519 AAAA',
        fingerprint: 'SHA256:abcdef',
      ),
      createdAt: 0,
      updatedAt: 0,
    ));
  });

  Future<Set<String>> filteredIds() async {
    final items = await container.read(filteredVaultEntriesProvider.future);
    return items.map((i) => i.id).toSet();
  }

  /// 等 provider **自己**推出满足条件的新值（带超时，避免测试挂死）。
  ///
  /// 用 [ProviderContainer.listen] 而不是 `container.invalidate(...)`：这些
  /// provider 现在都是 drift 流，刷新必须来自仓储的推送 —— 手写失效正是
  /// 2.3.1 之前那两个 bug 的来源。
  Future<T> waitForPush<T>(
    ProviderListenable<AsyncValue<T>> provider,
    bool Function(T value) predicate,
  ) async {
    final completer = Completer<T>();
    final subscription = container.listen(provider, (_, next) {
      final value = next.valueOrNull;
      if (value != null && predicate(value) && !completer.isCompleted) {
        completer.complete(value);
      }
    }, fireImmediately: true);
    try {
      return await completer.future.timeout(const Duration(seconds: 5));
    } finally {
      subscription.close();
    }
  }

  test('vaultEntriesProvider 交出四种类型的 VaultItem（没有行级 PasswordEntry）',
      () async {
    final items = await container.read(vaultEntriesProvider.future);

    expect(items, hasLength(4));
    expect(
      items.map((i) => i.type).toSet(),
      {EntryType.login, EntryType.secureNote, EntryType.sshKey},
      reason: 'provider 顶层类型已是 List<VaultItem>，这里顺带证明混合类型能一起流出来',
    );
    expect(
      items.firstWhere((i) => i.id == 'ssh-none').subtitle,
      'SHA256:abcdef',
      reason: '副标题由 VaultItem.subtitle 统一给出',
    );
  });

  test('filteredVaultEntriesProvider：文件夹 + 类型 + 收藏三者叠加且互不覆盖', () async {
    // 默认：四个维度全放开 → 全部 4 条。
    expect(await filteredIds(), {'login-work', 'login-home', 'note-work', 'ssh-none'});

    // 只按文件夹。
    container.read(selectedFolderIdProvider.notifier).state = 'f-work';
    expect(await filteredIds(), {'login-work', 'note-work'});

    // 文件夹 + 类型（再加一个维度，不回退文件夹筛选）。
    container.read(selectedEntryTypeProvider.notifier).state = EntryType.secureNote;
    expect(await filteredIds(), {'note-work'});

    // 文件夹 + 类型 + 收藏：这条笔记不是收藏 → 空。
    container.read(showFavoritesProvider.notifier).state = true;
    expect(await filteredIds(), isEmpty);

    // 收藏 + 登录（类型筛选保持有效）。
    container.read(selectedEntryTypeProvider.notifier).state = EntryType.login;
    expect(await filteredIds(), {'login-work'});

    // 清掉文件夹维度，类型 + 收藏仍然生效。
    container.read(selectedFolderIdProvider.notifier).state = null;
    expect(await filteredIds(), {'login-work'});

    // 全部放开 → 回到 4 条（状态没有互相粘住）。
    container.read(selectedEntryTypeProvider.notifier).state = null;
    container.read(showFavoritesProvider.notifier).state = false;
    expect(await filteredIds(), {'login-work', 'login-home', 'note-work', 'ssh-none'});
  });

  test('vaultFavoritesProvider：跨文件夹的收藏，并叠加类型筛选', () async {
    expect(
      (await container.read(vaultFavoritesProvider.future)).map((i) => i.id),
      ['login-work'],
      reason: '收藏视图不按文件夹过滤',
    );

    container.read(selectedEntryTypeProvider.notifier).state = EntryType.sshKey;
    expect(await container.read(vaultFavoritesProvider.future), isEmpty,
        reason: '类型筛选对收藏视图同样生效');
  });

  test('selectedFolderNameProvider：选中的文件夹被删掉后返回 null 而不是抛异常', () async {
    expect(container.read(selectedFolderNameProvider), isNull, reason: '未选中文件夹');

    container.read(selectedFolderIdProvider.notifier).state = 'f-work';
    await container.read(foldersProvider.future);
    expect(container.read(selectedFolderNameProvider), '工作');

    // 删文件夹（UI 的删除路径）→ 流自己推新列表。
    // **故意不 invalidate**：以前这句 `container.invalidate(foldersProvider)`
    // 是必需的，现在它只会掩盖"某条写入没被推送"的 bug。
    await container.read(vaultRepositoryProvider).removeFolder('f-work');
    await waitForPush(foldersProvider, (folders) {
      return folders.every((folder) => folder.id != 'f-work');
    });

    expect(container.read(selectedFolderNameProvider), isNull);
  });

  test('selectedFolderNameProvider：幽灵 id（文件夹从不存在）也返回 null', () async {
    container.read(selectedFolderIdProvider.notifier).state = 'ghost-folder';
    await container.read(foldersProvider.future);

    expect(container.read(selectedFolderNameProvider), isNull,
        reason: '旧实现是 folders.firstWhere(...) 没有 orElse → StateError');
  });

  test('searchResultsProvider：走 searchItems（前缀 + 类型专属字段），空查询为空', () async {
    expect(await container.read(searchResultsProvider('').future), isEmpty);
    expect(await container.read(searchResultsProvider('   ').future), isEmpty,
        reason: '空查询不是全量（与仓储契约一致）');

    expect(
      (await container.read(searchResultsProvider('type:ssh').future))
          .map((i) => i.id),
      ['ssh-none'],
    );
    expect(
      (await container.read(searchResultsProvider('folder:工作').future))
          .map((i) => i.id)
          .toSet(),
      {'login-work', 'note-work'},
    );
    expect(
      (await container.read(searchResultsProvider('路由器').future))
          .map((i) => i.id),
      ['note-work'],
      reason: '安全笔记正文也在搜索范围内',
    );
    expect(await container.read(searchResultsProvider('zzz-not-exist').future),
        isEmpty);
  });

  test('entryItemProvider：返回解密后的 VaultItem；不存在 / 未解锁返回 null', () async {
    final item = await container.read(entryItemProvider('login-work').future);

    expect(item, isNotNull);
    expect(item!.type, EntryType.login);
    expect(item.isAutofillable, isTrue);
    expect(item.loginOrEmpty.password, 'pw-work',
        reason: '交到 UI 的已经是明文（解密由仓储 mapper 负责）');
    expect(item.loginOrEmpty.url, 'https://example.com/login-work');

    expect(await container.read(entryItemProvider('nope').future), isNull);

    // 锁定后读不到（也不抛异常）。换一个没读过的 id，避免命中 provider 缓存。
    container.read(encryptionKeyProvider.notifier).state = null;
    expect(await container.read(entryItemProvider('login-home').future), isNull);
  });

  test('entryItemProvider：同一 id 被再次保存后自动推出新值（流式，无需 invalidate）',
      () async {
    final repo = container.read(vaultRepositoryProvider);
    final before = await container.read(entryItemProvider('login-work').future);
    expect(before!.loginOrEmpty.password, 'pw-work');

    // 模拟"编辑页保存"：写库即可，**不** invalidate 任何 provider。
    await repo.saveItem(before.copyWith(
      name: '公司邮箱（新）',
      login: const LoginData(
        url: 'https://example.com/login-work',
        username: 'login-work@example.com',
        password: 'pw-rotated',
      ),
      customFields: const [CustomField(label: 'PIN', value: '9999')],
    ));

    final after = await waitForPush(
      entryItemProvider('login-work'),
      (item) => item?.loginOrEmpty.password == 'pw-rotated',
    );

    expect(after!.name, '公司邮箱（新）');
    expect(after.customFields.single.label, 'PIN',
        reason: '新加的自定义字段必须随流推出来（用户报的"字段不见了"就是这个）');
    expect(after.customFields.single.value, '9999');
  });
}
