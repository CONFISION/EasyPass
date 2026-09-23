import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/database/database.dart';
import '../../../data/models/entry_type.dart';
import '../../../data/models/vault_item.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../data/state/session_key.dart';

// ─── Vault Items Stream ───────────────────────────────────
//
// 2.3.0 起 UI 只认 [VaultItem]（四种类型的统一明文模型），
// 不再有 [PasswordEntry] 行流进 widget 树：加密 / 解密由
// `VaultItemMapper` + [VaultRepository] 负责，UI 拿到的是已经解密的领域对象。
//
// ⚠️ 每个流式 provider 都先 `ref.watch(encryptionKeyProvider)`：
// `VaultRepository.watch*` 是在**创建流的那一刻**抓一把会话密钥的，密钥换了
// （改主密码、锁定、解锁）而流没被重建的话，它会一直用旧钥匙解密 ——
// 宽容模式不报错，直接把密码/私钥解成空串，用户看到的就是"改完主密码全空了"。
// watch 密钥让 provider 在密钥变化时重建流，重新抓钥匙。

/// 全部条目（不限文件夹 / 类型，含未收藏）。
final vaultEntriesProvider = StreamProvider<List<VaultItem>>((ref) {
  ref.watch(encryptionKeyProvider);
  final repo = ref.watch(vaultRepositoryProvider);
  return repo.watchItems();
});

/// 列表真正渲染的那条流：**文件夹 + 类型 + 收藏**三者叠加。
///
/// 三个维度在这里 combine（契约 §3 / §10.9），UI 不需要自己拼状态：
/// 换文件夹不会清掉类型筛选，切收藏也不会清掉类型筛选。
final filteredVaultEntriesProvider = StreamProvider<List<VaultItem>>((ref) {
  ref.watch(encryptionKeyProvider);
  final folderId = ref.watch(selectedFolderIdProvider);
  final type = ref.watch(selectedEntryTypeProvider);
  final favoritesOnly = ref.watch(showFavoritesProvider);
  final repo = ref.watch(vaultRepositoryProvider);
  return repo.watchItems(
    folderId: folderId,
    type: type,
    favoritesOnly: favoritesOnly,
  );
});

/// 收藏视图（跨文件夹），同样叠加当前的类型筛选。
///
/// 侧边栏的"收藏"入口是全局视图（点它会把文件夹选择清空），所以它不带
/// folderId；列表本身走 [filteredVaultEntriesProvider]（已包含收藏维度）。
final vaultFavoritesProvider = StreamProvider<List<VaultItem>>((ref) {
  ref.watch(encryptionKeyProvider);
  final type = ref.watch(selectedEntryTypeProvider);
  final repo = ref.watch(vaultRepositoryProvider);
  return repo.watchItems(favoritesOnly: true, type: type);
});

// ─── Search ───────────────────────────────────────────────

/// 搜索走 [VaultRepository.watchSearch]：支持 `type:` / `folder:` / `url:`
/// 前缀，并匹配身份 / SSH / 自定义字段（契约 §3）。
///
/// **流式**（2.3.1 修复）：原来是 `FutureProvider.family`，同一个查询词会被
/// 永久缓存 —— "搜一次 → 编辑条目 → 再搜同一个词"看到的是旧结果。
/// 空查询返回空列表（不是全量），与仓储契约一致。
final searchResultsProvider = StreamProvider.family<List<VaultItem>, String>(
  (ref, query) {
    ref.watch(encryptionKeyProvider); // 密钥变化要重建流（见文件头说明）
    final trimmed = query.trim();
    if (trimmed.isEmpty) return Stream.value(const []);
    final repo = ref.watch(vaultRepositoryProvider);
    return repo.watchSearch(trimmed);
  },
);

// ─── Folders ─────────────────────────────────────────────
// 单个条目的读取在 `entry_item_provider.dart` 的 `entryItemProvider`
// （详情页 / 编辑页共用；原先放在这里的同义 provider 已删除，避免两份真相）。

/// 文件夹列表 —— **流式**（2.3.1 修复）。
///
/// 原来是 `FutureProvider`：新增文件夹后侧边栏要手写 `ref.invalidate`
/// 才更新，而表单里那份私有副本没人刷新，于是"添加条目时只能选到第一个
/// 文件夹"（缓存的是首次打开时的列表）。改成监听 drift 后，谁写的都会立刻
/// 出现在所有读它的地方。
final foldersProvider = StreamProvider<List<Folder>>((ref) {
  final repo = ref.watch(vaultRepositoryProvider);
  return repo.watchFolders();
});

final selectedFolderIdProvider = StateProvider<String?>((ref) => null);

/// 列表的类型筛选；null = 全部类型（默认）。
///
/// `EntryType?` 而不是 `EntryType`：null 才能直接喂给
/// `watchItems(type: ...)` 的"不过滤"语义。
final selectedEntryTypeProvider = StateProvider<EntryType?>((ref) => null);

/// When true, the vault shows only favorites
final showFavoritesProvider = StateProvider<bool>((ref) => false);

/// Resolves the currently selected folder's name for the title bar.
///
/// **必须 null-safe**：选中的文件夹可能已经不存在了（被删除、或导入后被
/// 替换），此时返回 null 让标题回退到"全部条目"，而不是让 `firstWhere`
/// 在没有 `orElse` 的情况下抛 [StateError] 把整屏打崩。
final selectedFolderNameProvider = Provider<String?>((ref) {
  final folderId = ref.watch(selectedFolderIdProvider);
  if (folderId == null) return null;
  final folders = ref.watch(foldersProvider).valueOrNull;
  if (folders == null) return null;
  for (final folder in folders) {
    if (folder.id == folderId) return folder.name;
  }
  return null;
});
