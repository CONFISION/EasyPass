import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/crypto_service.dart';
import '../database/database.dart';
import '../models/entry_type.dart';
import '../models/vault_item.dart';
import '../models/vault_item_mapper.dart';
import '../state/session_key.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  return AppDatabase();
});

final cryptoServiceProvider = Provider<CryptoService>((ref) {
  return CryptoService();
});

/// 条目模型 ↔ DB 行的映射器（加密 / 解密都在里面）。
final vaultItemMapperProvider = Provider<VaultItemMapper>((ref) {
  return VaultItemMapper(ref.watch(cryptoServiceProvider));
});

final vaultRepositoryProvider = Provider<VaultRepository>((ref) {
  return VaultRepository(
    db: ref.watch(databaseProvider),
    cryptoService: ref.watch(cryptoServiceProvider),
    // 每次调用时**现读**密钥：解锁/锁定不需要重建 repository，
    // 未解锁时读到的就是 null（写操作会抛 VaultLockedException）。
    keyReader: () => ref.read(encryptionKeyProvider),
  );
});

/// 保险库仓储：UI、健康报告与浏览器桥接共用的唯一数据入口。
///
/// 2.3.0 起对外的主 API 是 [watchItems] / [getItem] / [saveItem] —— 面向
/// [VaultItem]（多类型、已解密的明文模型），加密与行映射全部由
/// [VaultItemMapper] 负责，调用方**不要**自己碰 `*_encrypted` 列。
///
/// daemon 侧（`native_messaging_service`）没有 Riverpod 容器，直接构造即可：
/// ```dart
/// VaultRepository(db: db, cryptoService: crypto, keyReader: () => session.key)
/// ```
class VaultRepository {
  final AppDatabase db;
  final CryptoService cryptoService;

  /// 会话密钥读取器；返回 null 表示当前锁定。
  final Uint8List? Function()? keyReader;

  VaultRepository({
    required this.db,
    required this.cryptoService,
    this.keyReader,
  });

  VaultItemMapper get mapper => VaultItemMapper(cryptoService);

  /// 当前是否有可用会话密钥。
  bool get isUnlocked => _keyOrNull() != null;

  Uint8List? _keyOrNull() => keyReader?.call();

  Uint8List _requireKey() {
    final key = _keyOrNull();
    if (key == null) throw const VaultLockedException();
    return key;
  }

  // ─── 条目（多类型，2.3.0 主 API）────────────────────────

  /// 监听条目流，可按文件夹 / 类型 / 收藏过滤（过滤在 SQL 层完成）。
  ///
  /// 未解锁时返回空列表流（路由层本来就会把用户挡在 /lock）。
  Stream<List<VaultItem>> watchItems({
    String? folderId,
    EntryType? type,
    bool favoritesOnly = false,
  }) {
    final key = _keyOrNull();
    if (key == null) return Stream.value(const <VaultItem>[]);

    final mapper = this.mapper;
    return db
        .watchEntriesFiltered(
          folderId: folderId,
          type: type?.wireName,
          favoritesOnly: favoritesOnly,
        )
        .map((rows) => rows.map((row) => mapper.fromRow(row, key)).toList());
  }

  /// [watchItems] 的一次性版本。
  Future<List<VaultItem>> getItems({
    String? folderId,
    EntryType? type,
    bool favoritesOnly = false,
  }) async {
    final key = _keyOrNull();
    if (key == null) return const [];
    final mapper = this.mapper;
    final rows = await db.getEntriesFiltered(
      folderId: folderId,
      type: type?.wireName,
      favoritesOnly: favoritesOnly,
    );
    return rows.map((row) => mapper.fromRow(row, key)).toList();
  }

  /// 读取单个条目；不存在或未解锁时返回 null。
  Future<VaultItem?> getItem(String id) async {
    final key = _keyOrNull();
    if (key == null) return null;
    final row = await db.getEntryById(id);
    if (row == null) return null;
    return mapper.fromRow(row, key);
  }

  /// 监听单个条目：**任何写入（编辑、收藏、改主密码）都会推新值**。
  ///
  /// 详情页必须用这个而不是 `getItem`：一次性读取 + 手写失效的写法，
  /// 只要漏掉一处（例如"编辑保存后弹回详情页"），用户看到的就还是旧条目 ——
  /// 新增的自定义字段不显示就是这么来的。
  Stream<VaultItem?> watchItem(String id) {
    final key = _keyOrNull();
    if (key == null) return Stream.value(null);
    final itemMapper = mapper;
    return db
        .watchEntryById(id)
        .map((row) => row == null ? null : itemMapper.fromRow(row, key));
  }

  /// 新增或更新（按 id upsert）。
  ///
  /// - `createdAt` 为 0 时按"现在"处理；已存在行的 `createdAt` 保持不变；
  /// - `updatedAt` 一律刷新为当前时间；
  /// - 未解锁时抛 [VaultLockedException]。
  Future<void> saveItem(VaultItem item) async {
    final key = _requireKey();
    final mapper = this.mapper;
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await db.getEntryById(item.id);

    if (existing == null) {
      final createdAt = item.createdAt == 0 ? now : item.createdAt;
      await db.insertEntry(
        mapper.toInsert(
          item.copyWith(createdAt: createdAt, updatedAt: now),
          key,
        ),
      );
      return;
    }

    await db.updateEntry(
      item.id,
      mapper.toUpdate(
        item.copyWith(createdAt: existing.createdAt, updatedAt: now),
        key,
      ),
    );
  }

  Future<void> deleteItem(String id) => db.deleteEntry(id);

  /// 搜索（大小写不敏感，内存中匹配解密后的字段）。
  ///
  /// 支持前缀过滤，可与自由词混用（全部条件同时满足）：
  /// - `type:login` / `type:note` / `type:identity` / `type:ssh`
  ///   （也认中文：登录 / 笔记 / 身份 / 密钥）
  /// - `folder:工作`（文件夹名子串）
  /// - `url:example.com`（登录条目网址子串）
  ///
  /// 例：`type:ssh github`、`folder:工作 url:gitlab`。
  Future<List<VaultItem>> searchItems(String query) async {
    final filters = _SearchFilters.parse(query);
    if (filters.isEmpty) return const [];

    final items = await getItems();
    final folders = await db.getAllFolders();
    final folderNames = {
      for (final folder in folders) folder.id: folder.name,
    };

    final matched = items
        .where((item) => filters.matches(item, folderNames))
        .toList();
    matched.sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (byName != 0) return byName;
      return a.id.compareTo(b.id);
    });
    return matched;
  }

  Future<int> countItems() => db.countEntriesFiltered();

  Future<int> countItemsByType(EntryType type) =>
      db.countEntriesFiltered(type: type.wireName);

  /// 某个文件夹里有多少条目 —— 删文件夹前先数一数，用来决定提示的口气
  /// （空文件夹直接确认；有条目的必须明说"条目会保留"）。
  Future<int> countItemsInFolder(String folderId) =>
      db.countEntriesFiltered(folderId: folderId);

  /// 主密码轮换：把全库密文从 [oldKey] 重新加密到 [newKey]，返回处理条数。
  ///
  /// **必须走 mapper**：新增密文列（`data_encrypted`）时不需要再改这里，
  /// 而手写字段清单的老实现漏一列，就会出现"改完主密码后这一列解不开"。
  ///
  /// **整体在一个事务里**：任一行解不开（`VaultDecryptException`）就整段回滚。
  /// 这不是洁癖 —— 调用方（`AuthNotifier.changeMasterPassword`）是在本方法
  /// **之后**才写入新 salt/hash 的：如果这里改到一半就抛，前面的行已经用
  /// newKey 落库、而主密码还是旧的，那些条目就**永久解不开**了（宽容模式只会
  /// 返回空串，等于静默数据丢失）。坏密文是现实存在的（健康报告里就有
  /// "单条解密失败被跳过"的用例）。
  Future<int> reencryptAll({
    required Uint8List oldKey,
    required Uint8List newKey,
    bool touchUpdatedAt = true,
  }) async {
    final mapper = this.mapper;
    final rows = await db.getAllEntries();
    final now = DateTime.now().millisecondsSinceEpoch;

    var count = 0;
    await db.transaction(() async {
      for (final row in rows) {
        final item = mapper.fromRow(row, oldKey, lenient: false);
        final updated = touchUpdatedAt ? item.copyWith(updatedAt: now) : item;
        await db.updateEntry(row.id, mapper.toUpdate(updated, newKey));
        count++;
      }
    });
    return count;
  }

  // ─── 文件夹 ─────────────────────────────────────────────

  Future<List<Folder>> getFolders() => db.getAllFolders();

  /// 文件夹列表的监听版：表单与侧边栏共用，新增/改名/删除自动可见。
  Stream<List<Folder>> watchFolders() => db.watchAllFolders();

  /// 搜索结果流：条目一变就重算（搜索命中解密后的字段，所以不能只靠 SQL）。
  ///
  /// 用一次性 Future 的版本会在"搜索 → 编辑条目 → 再搜同一个词"时给旧结果。
  Stream<List<VaultItem>> watchSearch(String query) {
    return db.watchAllEntries().asyncMap((_) => searchItems(query));
  }

  Future<void> addFolder(FoldersCompanion folder) => db.insertFolder(folder);

  /// 重命名 / 改图标（2.3.0 起 UI 可用）。
  Future<void> updateFolder(String id, FoldersCompanion folder) =>
      db.updateFolder(id, folder);

  /// 删除文件夹，并解除其下条目的归属（drift 默认不开外键，必须显式清）。
  Future<void> removeFolder(String id) => db.deleteFolderAndUnassign(id);

  // ─── 旧行级 API（2.3.0 起废弃，UI 迁移完成后删除）────────
  //
  // 保留它们只是为了"迁移期间仓库始终可编译、可跑测试"：
  // 新代码一律用上面的 VaultItem API，不要再调用下面这些。

  @Deprecated('改用 watchItems()（多类型条目）')
  Stream<List<PasswordEntry>> watchEntries() => db.watchAllEntries();

  @Deprecated('改用 watchItems(folderId: ...)')
  Stream<List<PasswordEntry>> watchEntriesByFolder(String? folderId) =>
      db.watchEntriesByFolder(folderId);

  @Deprecated('改用 watchItems(favoritesOnly: true)')
  Stream<List<PasswordEntry>> watchFavorites() => db.watchFavoriteEntries();

  @Deprecated('改用 getItems()')
  Future<List<PasswordEntry>> getAllEntries() => db.getAllEntries();

  @Deprecated('改用 searchItems()（会解密并匹配类型专属字段）')
  Future<List<PasswordEntry>> search(String query) => db.searchEntries(query);

  @Deprecated('改用 getItem()')
  Future<PasswordEntry?> getEntry(String id) => db.getEntryById(id);

  @Deprecated('改用 saveItem()')
  Future<void> saveEntry(PasswordEntriesCompanion entry) =>
      db.insertEntry(entry);

  @Deprecated('改用 saveItem()')
  Future<void> updateEntry(String id, PasswordEntriesCompanion entry) =>
      db.updateEntry(id, entry);

  @Deprecated('改用 deleteItem()')
  Future<void> deleteEntry(String id) => db.deleteEntry(id);
}

/// 解析后的搜索条件。
class _SearchFilters {
  final List<String> terms;
  final Set<EntryType> types;
  final List<String> folderTerms;
  final List<String> urlTerms;

  const _SearchFilters({
    this.terms = const [],
    this.types = const {},
    this.folderTerms = const [],
    this.urlTerms = const [],
  });

  bool get isEmpty =>
      terms.isEmpty && types.isEmpty && folderTerms.isEmpty && urlTerms.isEmpty;

  /// `type:` 能接受的全部取值：wire name + 常用英文别名 + 中文。
  ///
  /// 用显式白名单（而不是 `EntryType.fromWire`）是有意的：`fromWire` 对
  /// 未知值回退到 login，于是 `type:identiy`（拼错）会**静默变成"只搜登录"**，
  /// 用户看到一堆登录条目还以为筛选生效了。白名单让拼错走"自由词"分支，
  /// 结果是干净的"搜不到"。
  static const Map<String, EntryType> _typeAliases = {
    'login': EntryType.login,
    'password': EntryType.login,
    'credential': EntryType.login,
    '登录': EntryType.login,
    '密码': EntryType.login,
    'secure_note': EntryType.secureNote,
    'note': EntryType.secureNote,
    'notes': EntryType.secureNote,
    'secure-note': EntryType.secureNote,
    'securenote': EntryType.secureNote,
    '笔记': EntryType.secureNote,
    '安全笔记': EntryType.secureNote,
    'identity': EntryType.identity,
    '身份': EntryType.identity,
    '身份信息': EntryType.identity,
    'ssh_key': EntryType.sshKey,
    'ssh': EntryType.sshKey,
    'ssh-key': EntryType.sshKey,
    'sshkey': EntryType.sshKey,
    '密钥': EntryType.sshKey,
    'ssh密钥': EntryType.sshKey,
  };

  static _SearchFilters parse(String raw) {
    final terms = <String>[];
    final types = <EntryType>{};
    final folderTerms = <String>[];
    final urlTerms = <String>[];

    for (final token in raw.trim().split(RegExp(r'\s+'))) {
      if (token.isEmpty) continue;
      final separator = token.indexOf(':');
      if (separator <= 0 || separator == token.length - 1) {
        terms.add(token.toLowerCase());
        continue;
      }

      final prefix = token.substring(0, separator).toLowerCase();
      final value = token.substring(separator + 1).trim();
      if (value.isEmpty) {
        terms.add(token.toLowerCase());
        continue;
      }
      final lowerValue = value.toLowerCase();

      switch (prefix) {
        case 'type':
        case '类型':
          if (lowerValue == 'all' || lowerValue == '全部') {
            // `type:all` = 明确"不限类型"：把四种类型都放进集合，
            // 这样它不会退化成"空条件"而被当成空查询。
            types.addAll(EntryType.values);
            break;
          }
          final matched = _typeAliases[lowerValue];
          if (matched == null) {
            // 拼错/不认识的类型值：当成自由词，别静默回退成 login。
            terms.add(token.toLowerCase());
            break;
          }
          types.add(matched);
        case 'folder':
        case '文件夹':
          folderTerms.add(lowerValue);
        case 'url':
        case '网址':
          urlTerms.add(lowerValue);
        default:
          terms.add(token.toLowerCase());
      }
    }

    return _SearchFilters(
      terms: terms,
      types: types,
      folderTerms: folderTerms,
      urlTerms: urlTerms,
    );
  }

  bool matches(VaultItem item, Map<String, String> folderNames) {
    if (types.isNotEmpty && !types.contains(item.type)) return false;

    if (folderTerms.isNotEmpty) {
      final folderName =
          (item.folderId == null ? '' : folderNames[item.folderId] ?? '')
              .toLowerCase();
      for (final term in folderTerms) {
        if (!folderName.contains(term)) return false;
      }
    }

    if (urlTerms.isNotEmpty) {
      final url = item.loginOrEmpty.url.toLowerCase();
      for (final term in urlTerms) {
        if (!url.contains(term)) return false;
      }
    }

    if (terms.isNotEmpty) {
      final haystack = item.searchableText;
      for (final term in terms) {
        if (!haystack.contains(term)) return false;
      }
    }

    return true;
  }
}
