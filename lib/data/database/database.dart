import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

part 'database.g.dart';

@DriftDatabase(include: {'tables.drift'})
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.e);

  /// 2 = 2.3.0 多条目类型（`type` + `data_encrypted`）。
  @override
  int get schemaVersion => 2;

  /// 迁移策略。
  ///
  /// 1 → 2：新增两列（都带默认值，旧行自动成为 `type='login'`、
  /// `data_encrypted=''`，无需拷贝数据），并补上类型索引。
  /// **每加一列都必须同时改这里**，否则老用户升级后一开库就抛
  /// "no such column"（1.x 的 `onUpgrade` 是空实现，没有先例可抄）。
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(passwordEntries, passwordEntries.type);
            await m.addColumn(passwordEntries, passwordEntries.dataEncrypted);
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_password_entries_type '
              'ON password_entries(type)',
            );
          }
        },
      );

  // ─── Folders ───────────────────────────────────────────

  Future<List<Folder>> getAllFolders() => select(folders).get();

  /// 文件夹列表的**监听版**（2.3.1 修 bug 用）。
  ///
  /// 新增/重命名/删除文件夹后，正在打开的表单与侧边栏要立刻看到变化；
  /// 用一次性 `get()` + 手写 `ref.invalidate` 的写法漏一处就会出现
  /// "只能看到第一个文件夹"这种幽灵 bug。
  Stream<List<Folder>> watchAllFolders() => select(folders).watch();

  Future<Folder?> getFolderById(String id) {
    return (select(folders)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<void> insertFolder(FoldersCompanion folder) {
    return into(folders).insertOnConflictUpdate(folder);
  }

  Future<void> updateFolder(String id, FoldersCompanion folder) {
    return (update(folders)..where((t) => t.id.equals(id))).write(folder);
  }

  Future<void> deleteFolder(String id) {
    return (delete(folders)..where((t) => t.id.equals(id))).go();
  }

  // ─── Password Entries ──────────────────────────────────

  Future<List<PasswordEntry>> getAllEntries() => select(passwordEntries).get();

  Stream<List<PasswordEntry>> watchAllEntries() {
    return select(passwordEntries).watch();
  }

  /// When [folderId] is null, returns all entries.
  /// When [folderId] is a valid ID, returns only entries in that folder.
  Stream<List<PasswordEntry>> watchEntriesByFolder(String? folderId) {
    final query = select(passwordEntries);
    if (folderId != null) {
      query.where((t) => t.folderId.equals(folderId));
    }
    return query.watch();
  }

  Future<List<PasswordEntry>> searchEntries(String query) {
    final lowerQuery = '%${query.toLowerCase()}%';
    return (select(passwordEntries)
          ..where((t) => t.name.lower().like(lowerQuery) | t.url.lower().like(lowerQuery) | t.username.lower().like(lowerQuery)))
        .get();
  }

  /// 按文件夹 / 类型 / 收藏过滤条目（2.3.0 新增）。
  ///
  /// - [folderId] 为 null：不按文件夹过滤；
  /// - [type] 为 null：不限类型；传 `'login'` 可只取登录条目（自动填充只认它）；
  /// - [favoritesOnly]：只返回收藏。
  Stream<List<PasswordEntry>> watchEntriesFiltered({
    String? folderId,
    String? type,
    bool favoritesOnly = false,
  }) {
    final query = select(passwordEntries);
    if (folderId != null) {
      query.where((t) => t.folderId.equals(folderId));
    }
    if (type != null) {
      query.where((t) => t.type.equals(type));
    }
    if (favoritesOnly) {
      query.where((t) => t.isFavorite.equals(true));
    }
    return query.watch();
  }

  /// [watchEntriesFiltered] 的一次性版本。
  Future<List<PasswordEntry>> getEntriesFiltered({
    String? folderId,
    String? type,
    bool favoritesOnly = false,
  }) {
    final query = select(passwordEntries);
    if (folderId != null) {
      query.where((t) => t.folderId.equals(folderId));
    }
    if (type != null) {
      query.where((t) => t.type.equals(type));
    }
    if (favoritesOnly) {
      query.where((t) => t.isFavorite.equals(true));
    }
    return query.get();
  }

  /// 删除文件夹，并先把条目的归属清空。
  ///
  /// drift 默认不开启 SQLite 外键约束，因此表上声明的
  /// `ON DELETE SET NULL` 实际不会触发；若不显式清空，删掉文件夹后会留下
  /// 指向不存在文件夹的"幽灵条目"（在文件夹视图里消失、在全部条目里又出现）。
  Future<void> deleteFolderAndUnassign(String id) async {
    await (update(passwordEntries)..where((t) => t.folderId.equals(id)))
        .write(const PasswordEntriesCompanion(folderId: Value(null)));
    await deleteFolder(id);
  }

  Stream<List<PasswordEntry>> watchFavoriteEntries() {
    return (select(passwordEntries)..where((t) => t.isFavorite.equals(true)))
        .watch();
  }

  Future<PasswordEntry?> getEntryById(String id) {
    return (select(passwordEntries)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// 单条目的**监听版**：编辑弹回详情页后要立刻显示新内容（含新加的自定义字段）。
  Stream<PasswordEntry?> watchEntryById(String id) {
    return (select(passwordEntries)..where((t) => t.id.equals(id)))
        .watchSingleOrNull();
  }

  Future<void> insertEntry(PasswordEntriesCompanion entry) {
    return into(passwordEntries).insertOnConflictUpdate(entry);
  }

  Future<void> updateEntry(String id, PasswordEntriesCompanion entry) {
    return (update(passwordEntries)..where((t) => t.id.equals(id))).write(entry);
  }

  Future<void> deleteEntry(String id) {
    return (delete(passwordEntries)..where((t) => t.id.equals(id))).go();
  }

  Future<int> getEntryCount() {
    return (selectOnly(passwordEntries)..addColumns([passwordEntries.id.count()]))
        .map((row) => row.read(passwordEntries.id.count()) ?? 0)
        .getSingle();
  }

  /// 条目计数（不取行，只取 count）；[type] / [folderId] 非空时只数对应的行。
  ///
  /// [folderId] 用于"删文件夹前先数一数里面有多少条目"：不能为了弹个提示
  /// 就把整库解密一遍（`getItems` 会解密每个字段）。
  Future<int> countEntriesFiltered({String? type, String? folderId}) {
    final count = passwordEntries.id.count();
    final query = selectOnly(passwordEntries)..addColumns([count]);
    if (type != null) {
      query.where(passwordEntries.type.equals(type));
    }
    if (folderId != null) {
      query.where(passwordEntries.folderId.equals(folderId));
    }
    return query.map((row) => row.read(count) ?? 0).getSingle();
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    // Store the database next to the executable
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final file = File(p.join(exeDir, 'easypass.db'));

    return NativeDatabase.createInBackground(file);
  });
}