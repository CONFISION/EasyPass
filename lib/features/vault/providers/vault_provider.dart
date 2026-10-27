import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/entry_type.dart';
import '../../../data/models/vault_item.dart';
import '../../../protocol/codecs.dart' show WireFolder;
import '../../../protocol/events.dart';
import 'core_stream.dart';

// ─── 保险库条目流（核心服务的客户端视角）────────────────────
//
// UI 从此不碰 AppDatabase / VaultRepository / encryptionKeyProvider：
// 每条流都是"**取快照 + 订阅主题重取**"（实现见 `core_stream.dart`）。
// 旧的四条 drift 流与协议主题一一对应：
//
//   repository.watchItems(...)  →  Topics.items
//   repository.watchItem(id)    →  Topics.item
//   repository.watchFolders()   →  Topics.folders
//   repository.watchSearch(q)   →  Topics.search
//
// 为什么全部 autoDispose：锁定 / 解锁会把路由从 /vault 换掉（VaultScreen 被卸载），
// 快照必须跟着销毁 —— 否则解锁后回到保险库看到的还是锁定前那份缓存，而且已解密的
// 明文会在内存里多留一份。重建时重新取快照，这就是"解锁后立刻看到新数据"。
//
// ⚠️ 未解锁时核心的 `listItems` / `listFolders` 会抛 `VaultApiException(locked)`：
// `coreSnapshotStream` 把它降级成空列表并轮询会话状态，绝不冒泡成红屏
// （旧实现是 `ref.watch(encryptionKeyProvider)`，密钥一没就整条流报错）。

/// 全部条目（不限文件夹 / 类型，含未收藏）。
final vaultEntriesProvider = StreamProvider.autoDispose<List<VaultItem>>((ref) {
  return coreSnapshotStream(
    ref,
    topic: Topics.items,
    lockedValue: const [],
    fetch: fetchItems,
  );
});

/// 列表真正渲染的那条流：**文件夹 + 类型 + 收藏**三者叠加。
///
/// 三个维度在这里 combine，UI 不需要自己拼状态：
/// 换文件夹不会清掉类型筛选，切收藏也不会清掉类型筛选。
/// 过滤本身由核心做（`listItems(folderId:, type:, favoritesOnly:)`），
/// UI 只负责把三个状态原样传下去。
final filteredVaultEntriesProvider =
    StreamProvider.autoDispose<List<VaultItem>>((ref) {
  final folderId = ref.watch(selectedFolderIdProvider);
  final type = ref.watch(selectedEntryTypeProvider);
  final favoritesOnly = ref.watch(showFavoritesProvider);
  return coreSnapshotStream(
    ref,
    topic: Topics.items,
    lockedValue: const [],
    fetch: (api) => fetchItems(
      api,
      folderId: folderId,
      type: type,
      favoritesOnly: favoritesOnly,
    ),
  );
});

/// 收藏视图（跨文件夹），同样叠加当前的类型筛选。
///
/// 侧边栏的"收藏"入口是全局视图（点它会把文件夹选择清空），所以它不带
/// folderId；列表本身走 [filteredVaultEntriesProvider]（已包含收藏维度）。
final vaultFavoritesProvider = StreamProvider.autoDispose<List<VaultItem>>((ref) {
  final type = ref.watch(selectedEntryTypeProvider);
  return coreSnapshotStream(
    ref,
    topic: Topics.items,
    lockedValue: const [],
    fetch: (api) => fetchItems(api, favoritesOnly: true, type: type),
  );
});

// ─── Search ───────────────────────────────────────────────

/// 搜索走核心的 `searchItems`：支持 `type:` / `folder:` / `url:` 前缀，
/// 并匹配身份 / SSH / 自定义字段。
///
/// **流式**：核心推 `Topics.search` → 重取当前查询词。
/// 空查询返回空列表（不是全量），与核心契约一致，而且**一次请求都不发**。
final searchResultsProvider =
    StreamProvider.autoDispose.family<List<VaultItem>, String>((ref, query) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return Stream.value(const []);
  return coreSnapshotStream(
    ref,
    topic: Topics.search,
    lockedValue: const [],
    fetch: (api) => fetchSearch(api, trimmed),
  );
});

// ─── Folders ─────────────────────────────────────────────
// 单个条目的读取在 `entry_item_provider.dart` 的 `entryItemProvider`
// （详情页 / 编辑页共用；原先放在这里的同义 provider 已删除，避免两份真相）。

/// 文件夹列表 —— 流式（核心推 `Topics.folders`，谁写的都会立刻出现在所有读它的地方）。
///
/// 这条流是 2.3.1 那个"添加条目时只能选到第一个文件夹"的修复：改成推送驱动后，
/// 写入方不需要（也不能）手写 `ref.invalidate`。
final foldersProvider = StreamProvider.autoDispose<List<WireFolder>>((ref) {
  return coreSnapshotStream(
    ref,
    topic: Topics.folders,
    lockedValue: const [],
    fetch: fetchFolders,
  );
});

/// 回收站列表（已删除条目；`items` 主题一变就重取）。
///
/// 删除 / 恢复 / 彻底删除都会广播 `items`，所以这条流与主列表天然同步 ——
/// 不需要任何手动 invalidate。
final trashItemsProvider = StreamProvider.autoDispose<List<VaultItem>>((ref) {
  return coreSnapshotStream(
    ref,
    topic: Topics.items,
    lockedValue: const [],
    fetch: fetchTrash,
  );
});

final selectedFolderIdProvider = StateProvider<String?>((ref) => null);

/// 列表的类型筛选；null = 全部类型（默认）。
///
/// `EntryType?` 而不是 `EntryType`：null 才能直接喂给
/// `listItems(type: ...)` 的"不过滤"语义。
final selectedEntryTypeProvider = StateProvider<EntryType?>((ref) => null);

/// When true, the vault shows only favorites
final showFavoritesProvider = StateProvider<bool>((ref) => false);

/// Resolves the currently selected folder's name for the title bar.
///
/// **必须 null-safe**：选中的文件夹可能已经不存在了（被删除、或导入后被
/// 替换），此时返回 null 让标题回退到"全部条目"，而不是让 `firstWhere`
/// 在没有 `orElse` 的情况下抛 [StateError] 把整屏打崩。
/// autoDispose：它 watch 的是 autoDispose 的 [foldersProvider]，跟着一起释放。
final selectedFolderNameProvider = Provider.autoDispose<String?>((ref) {
  final folderId = ref.watch(selectedFolderIdProvider);
  if (folderId == null) return null;
  final folders = ref.watch(foldersProvider).valueOrNull;
  if (folders == null) return null;
  for (final folder in folders) {
    if (folder.id == folderId) return folder.name;
  }
  return null;
});
