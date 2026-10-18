import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/client/api_providers.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/features/vault/providers/entry_item_provider.dart';
import 'package:easypass/features/vault/providers/vault_provider.dart';
import 'package:easypass/protocol/codecs.dart' show WireFolder;

import 'fake_vault_api.dart';

/// 保险库 provider 的契约（M4：UI 是核心服务的客户端，全部 stream /
/// hold [VaultItem]，**不再有数据库句柄**）：
/// 1) 列表那条流把 **文件夹 + 类型 + 收藏** 三个维度叠加后交给
///    `VaultApi.listItems(...)`，互不覆盖；
/// 2) 类型筛选对收藏视图同样生效；
/// 3) `selectedFolderNameProvider` 在文件夹消失时返回 null（旧实现 firstWhere
///    没有 orElse，会抛 StateError 把整屏打崩）；
/// 4) 搜索把查询词**原样**交给 `searchItems`；空查询一次请求都不发；
/// 5) `entryItemProvider` 交出核心给的 VaultItem（明文由核心负责，UI 不再解密）；
/// 6) 刷新只能来自核心推送的主题 —— 下面的用例里**一次 `invalidate` 都没有**
///    （以前靠手写失效，漏一处就出"文件夹下拉只剩第一个"“详情页看不到新加的
///    自定义字段”这类问题）；
/// 7) **未解锁**：核心抛 `locked` 时列表是空的，不冒泡成红屏；解锁后自动重取。
void main() {
  late FakeVaultApi api;
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
    api = FakeVaultApi(initialStatus: 'unlocked');
    container = ProviderContainer(
      overrides: [vaultApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    addTearDown(api.dispose);

    api.folders['f-work'] = const WireFolder(
      id: 'f-work',
      name: '工作',
      createdAt: 0,
      updatedAt: 0,
    );
    api.folders['f-home'] = const WireFolder(
      id: 'f-home',
      name: '家里',
      createdAt: 0,
      updatedAt: 0,
    );
    // 工作夹里的收藏登录 + 工作夹里的笔记 + 家里夹的登录 + 无文件夹的 SSH。
    await api.saveItem(loginItem(
      id: 'login-work',
      name: '公司邮箱',
      folderId: 'f-work',
      favorite: true,
      password: 'pw-work',
    ));
    await api.saveItem(loginItem(
      id: 'login-home',
      name: '个人邮箱',
      folderId: 'f-home',
    ));
    await api.saveItem(VaultItem(
      id: 'note-work',
      folderId: 'f-work',
      type: EntryType.secureNote,
      name: 'WiFi',
      notes: '家里路由器的密码',
      createdAt: 0,
      updatedAt: 0,
    ));
    await api.saveItem(VaultItem(
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
  /// provider 现在由核心推送的主题驱动，刷新必须来自推送 —— 手写失效正是
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

  test('vaultEntriesProvider 交出四种类型的 VaultItem（读的是 VaultApi）', () async {
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
    expect(api.called('listItems'), isTrue,
        reason: 'UI 必须经 VaultApi 取数据，不能有第二条数据入口');
  });

  test('filteredVaultEntriesProvider：文件夹 + 类型 + 收藏三者叠加且互不覆盖', () async {
    // 默认：四个维度全放开 → 全部 4 条。
    expect(await filteredIds(), {'login-work', 'login-home', 'note-work', 'ssh-none'});
    expect(
      api.listItemRequests.last,
      (folderId: null, type: null, favoritesOnly: false),
      reason: '三个维度原样交给核心，UI 不自己过滤',
    );

    // 只按文件夹。
    container.read(selectedFolderIdProvider.notifier).state = 'f-work';
    expect(await filteredIds(), {'login-work', 'note-work'});
    expect(api.listItemRequests.last.folderId, 'f-work');

    // 文件夹 + 类型（再加一个维度，不回退文件夹筛选）。
    container.read(selectedEntryTypeProvider.notifier).state = EntryType.secureNote;
    expect(await filteredIds(), {'note-work'});
    expect(
      (api.listItemRequests.last.folderId, api.listItemRequests.last.type),
      ('f-work', EntryType.secureNote),
    );

    // 文件夹 + 类型 + 收藏：这条笔记不是收藏 → 空。
    container.read(showFavoritesProvider.notifier).state = true;
    expect(await filteredIds(), isEmpty);
    expect(api.listItemRequests.last.favoritesOnly, isTrue);

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
    expect(api.listItemRequests.last.favoritesOnly, isTrue);
    expect(api.listItemRequests.last.folderId, isNull);
  });

  test('selectedFolderNameProvider：选中的文件夹被删掉后返回 null 而不是抛异常', () async {
    expect(container.read(selectedFolderNameProvider), isNull, reason: '未选中文件夹');

    // 持有监听：这些 provider 是 autoDispose 的，没人听就会被释放，
    // 而 `container.read(...)` 不算"有人在听"。
    final foldersSub = container.listen(foldersProvider, (_, _) {});
    addTearDown(foldersSub.close);
    final nameSub = container.listen(selectedFolderNameProvider, (_, _) {});
    addTearDown(nameSub.close);

    container.read(selectedFolderIdProvider.notifier).state = 'f-work';
    await container.read(foldersProvider.future);
    expect(container.read(selectedFolderNameProvider), '工作');

    // 删文件夹（走核心的 removeFolder）→ 核心推 `folders` 主题 → 流自己重取。
    // **故意不 invalidate**：以前那句 `container.invalidate(foldersProvider)`
    // 是必需的，现在它只会掩盖"某条写入没被推送"的 bug。
    await api.removeFolder('f-work');
    await waitForPush(foldersProvider, (folders) {
      return folders.every((folder) => folder.id != 'f-work');
    });

    expect(container.read(selectedFolderNameProvider), isNull);
  });

  test('selectedFolderNameProvider：幽灵 id（文件夹从不存在）也返回 null', () async {
    final foldersSub = container.listen(foldersProvider, (_, _) {});
    addTearDown(foldersSub.close);
    final nameSub = container.listen(selectedFolderNameProvider, (_, _) {});
    addTearDown(nameSub.close);

    // 先确认文件夹列表真的到了（否则"返回 null"可能只是因为列表还是空/加载中）。
    expect(await container.read(foldersProvider.future), hasLength(2));

    container.read(selectedFolderIdProvider.notifier).state = 'ghost-folder';
    expect(container.read(selectedFolderNameProvider), isNull,
        reason: '旧实现是 folders.firstWhere(...) 没有 orElse → StateError');
  });

  test('foldersProvider：文件夹写入由核心主题推送刷新（无需 invalidate）', () async {
    final subscription = container.listen(foldersProvider, (_, _) {});
    addTearDown(subscription.close);
    await container.read(foldersProvider.future);

    // 模拟"别处写入"（另一个客户端 / 设置页）：只碰核心，不碰任何 provider。
    final id = await api.addFolder('服务器', icon: 'key');
    final folders = await waitForPush(
      foldersProvider,
      (list) => list.any((folder) => folder.id == id),
    );

    expect(folders.firstWhere((f) => f.id == id).icon, 'key',
        reason: '图标由核心存下来，UI 只读');
  });

  test('searchResultsProvider：查询词原样交给 searchItems，空查询不发请求', () async {
    expect(await container.read(searchResultsProvider('').future), isEmpty);
    expect(await container.read(searchResultsProvider('   ').future), isEmpty,
        reason: '空查询不是全量（与核心契约一致）');
    expect(api.searchQueries, isEmpty,
        reason: '空查询连请求都不该发（省一次 IPC）');

    expect(
      (await container.read(searchResultsProvider('type:ssh').future))
          .map((i) => i.id),
      isEmpty,
      reason: '前缀语义是核心的事：假核心不解释 `type:`，UI 只负责原样转发',
    );
    expect(api.searchQueries, ['type:ssh'],
        reason: '查询词必须原样过线（UI 不 trim 成空、不自己改语义以外的内容）');

    expect(
      (await container.read(searchResultsProvider('WiFi').future))
          .map((i) => i.id),
      ['note-work'],
      reason: '安全笔记正文也在搜索范围内（核心的 searchableText）',
    );
    expect(await container.read(searchResultsProvider('zzz-not-exist').future),
        isEmpty);
  });

  test('searchResultsProvider：核心推 search 主题后重取当前查询词', () async {
    final subscription = container.listen(searchResultsProvider('WiFi'), (_, _) {});
    addTearDown(subscription.close);
    expect(await container.read(searchResultsProvider('WiFi').future), hasLength(1));

    // 改名后核心推主题（假核心在 saveItem 时自动推）→ 同一查询词必须看到新结果。
    await api.saveItem(loginItem(id: 'login-work-2', name: 'WiFi 路由器'));
    final results = await waitForPush(
      searchResultsProvider('WiFi'),
      (items) => items.any((item) => item.id == 'login-work-2'),
    );
    expect(results.map((i) => i.id), contains('note-work'));
  });

  test('entryItemProvider：返回核心给的 VaultItem；不存在 / 未解锁返回 null', () async {
    final item = await container.read(entryItemProvider('login-work').future);

    expect(item, isNotNull);
    expect(item!.type, EntryType.login);
    expect(item.isAutofillable, isTrue);
    expect(item.loginOrEmpty.password, 'pw-work',
        reason: '交到 UI 的已经是明文（核心解密，UI 不做任何解密）');
    expect(item.loginOrEmpty.url, 'https://example.com/login-work');

    expect(await container.read(entryItemProvider('nope').future), isNull);

    // 未解锁：核心抛 locked → 流给 null（不是异常）。
    // 假核心的"锁定即拒绝读"是 opt-in（默认关闭，好让别的用例不必先解锁），
    // 这里显式打开才等价于真核心的 `_requireUnlocked()`。
    api.lockEnforcedReads = true;
    api.forceStatus('locked');
    expect(await container.read(entryItemProvider('login-home').future), isNull,
        reason: '未解锁不该把详情页打成红屏');
  });

  test('entryItemProvider：同一 id 被再次保存后自动推出新值（流式，无需 invalidate）',
      () async {
    final before = await container.read(entryItemProvider('login-work').future);
    expect(before!.loginOrEmpty.password, 'pw-work');

    // 模拟"编辑页保存"：只调核心，**不** invalidate 任何 provider。
    await api.saveItem(before.copyWith(
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
        reason: '新加的自定义字段必须随主题推送重取出来（用户报的"字段不见了"就是这个）');
    expect(after.customFields.single.value, '9999');
  });

  // ─── 未解锁 / 解锁（M4 新增契约）──────────────────────────

  test('未解锁时列表是空的（locked 不当异常），解锁后自动重取', () async {
    api.lockEnforcedReads = true;
    api.forceStatus('locked');

    final sub = container.listen(vaultEntriesProvider, (_, _) {});
    addTearDown(sub.close);

    final locked = await container.read(vaultEntriesProvider.future);
    expect(locked, isEmpty, reason: '未解锁 = 空列表，不是 AsyncError');

    // 解锁（核心的 authSnapshot 立刻改口）→ 流靠轮询自己恢复，无需 invalidate。
    api.forceStatus('unlocked');
    final items = await waitForPush(
      vaultEntriesProvider,
      (list) => list.isNotEmpty,
    );
    expect(items, hasLength(4),
        reason: '解锁后必须自动把数据接回来（核心的 sessionUnlocked 事件不经 UI 通道，'
            '所以这条靠 authSnapshot 轮询兜底）');
  }, timeout: const Timeout(Duration(seconds: 30)));
}
