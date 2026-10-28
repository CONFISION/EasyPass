
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../../core/platform/app_paths.dart';

part 'database.g.dart';

/// 数据库文件比当前程序新（用户装回了旧版本）。
///
/// 必须在写任何东西之前抛出：drift 只在 `beforeOpen`（含 `onUpgrade`）全部成功
/// 之后才把 `schemaVersion` 写进 `user_version`，所以抛错既不会改库、也不会留下
/// "版本号倒退"的半迁移状态；用户换回新版本后仍能打开原来的库。
class UnsupportedSchemaDowngradeException implements Exception {
  const UnsupportedSchemaDowngradeException(this.from, this.to);

  /// 库文件里的 schema 版本。
  final int from;

  /// 当前程序支持的 schema 版本。
  final int to;

  @override
  String toString() =>
      '数据库版本（schema $from）高于当前程序支持的版本（schema $to）：'
      '降级不受支持，请安装 3.1.0 或更高版本。';
}

@DriftDatabase(include: {'tables.drift'})
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.e);

  /// 5 = 回收站（`password_entries.deleted_at` 列，3.1.0）。
  /// 4 = 智能体访问审计（`agent_audit` 表，3.1.0）。
  /// 3 = 改主密码的轮换日志（`vault_meta` 表，v2.4）。
  /// 2 = 2.3.0 多条目类型（`type` + `data_encrypted`）。
  @override
  int get schemaVersion => 5;

  /// 迁移策略。
  ///
  /// 1 → 2：新增两列（都带默认值，旧行自动成为 `type='login'`、
  /// `data_encrypted=''`，无需拷贝数据），并补上类型索引。
  /// 2 → 3：新增 `vault_meta` 键值表（改主密码的轮换日志）。纯新增表，
  /// 不动任何已有数据。
  /// 3 → 4：新增 `agent_audit` 审计表（智能体访问日志）。纯新增表 + 索引。
  /// 4 → 5：`password_entries` 新增可空列 `deleted_at`（回收站）+ 索引。
  /// 旧行该列自动为 NULL = 不在回收站，**不需要回填**。
  /// **每加一列/一表都必须同时改这里**，否则老用户升级后一开库就抛
  /// "no such column" / "no such table"（1.x 的 `onUpgrade` 是空实现，
  /// 没有先例可抄）。
  ///
  /// 两个硬约束（都来自"迁移失败会永久锁死库"）：
  /// - **降级先拒绝**：库比程序新时抛 [UnsupportedSchemaDowngradeException]，
  ///   不写任何东西；
  /// - **整段迁移在一个事务里**：drift 的迁移回调**不在事务中**（它在
  ///   `beforeOpen` 内逐条自动提交，全部成功后才写 `user_version`）。中途失败
  ///   会留下"列已加、版本号没变"的半迁移库，下次启动重跑
  ///   `ALTER TABLE ... ADD COLUMN` 就报 duplicate column、库从此打不开。
  ///   事务保证要么全成、要么全滚。
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
      if (from > to) {
        throw UnsupportedSchemaDowngradeException(from, to);
      }
      await transaction(() async {
        if (from < 2) {
          // 幂等：半迁移/降级留下的库可能已经有这些列。
          if (!await _hasColumn('password_entries', 'type')) {
            await m.addColumn(passwordEntries, passwordEntries.type);
          }
          if (!await _hasColumn('password_entries', 'data_encrypted')) {
            await m.addColumn(passwordEntries, passwordEntries.dataEncrypted);
          }
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_password_entries_type '
            'ON password_entries(type)',
          );
        }
        if (from < 3) {
          await m.createTable(vaultMeta);
        }
        if (from < 4) {
          await m.createTable(agentAudit);
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_agent_audit_at '
            'ON agent_audit(at)',
          );
        }
        if (from < 5) {
          // 幂等：上次迁移若已加列、但没来得及写 user_version，这次不能再
          // ALTER 一遍（SQLite 会报 duplicate column name）。
          if (!await _hasColumn('password_entries', 'deleted_at')) {
            await m.addColumn(passwordEntries, passwordEntries.deletedAt);
          }
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_password_entries_deleted '
            'ON password_entries(deleted_at)',
          );
        }
      });
    },
  );

  /// `table` 表上是否已经存在 [column] 列（迁移幂等用）。
  ///
  /// 表名只由本类内部的字面量传入（`password_entries`），不来自任何外部输入，
  /// 因此这里拼进 PRAGMA 没有注入面；迁移事务内可用。
  Future<bool> _hasColumn(String table, String column) async {
    final rows = await customSelect('PRAGMA table_info($table)').get();
    return rows.any((row) => row.read<String>('name') == column);
  }

  // ─── Vault meta（轮换日志）──────────────────────────────

  Future<String?> getMeta(String metaKey) async {
    final row = await (select(
      vaultMeta,
    )..where((t) => t.metaKey.equals(metaKey))).getSingleOrNull();
    return row?.metaValue;
  }

  Future<void> setMeta(String metaKey, String metaValue) {
    return into(vaultMeta).insertOnConflictUpdate(
      VaultMetaCompanion.insert(metaKey: metaKey, metaValue: metaValue),
    );
  }

  Future<void> deleteMeta(String metaKey) {
    return (delete(vaultMeta)..where((t) => t.metaKey.equals(metaKey))).go();
  }

  // ─── 智能体审计 ────────────────────────────────────────

  /// 追加一条审计记录。**只写"发生了什么"**（见 `tables.drift` 的说明）。
  Future<int> insertAgentAudit({
    required int at,
    required String pairingId,
    required String nickname,
    required String mode,
    required String tool,
    required String op,
    String? entryId,
    String? entryName,
    required String decision,
  }) {
    return into(agentAudit).insert(AgentAuditCompanion.insert(
      at: at,
      pairingId: pairingId,
      nickname: nickname,
      mode: mode,
      tool: tool,
      op: op,
      entryId: Value(entryId),
      entryName: Value(entryName),
      decision: decision,
    ));
  }

  /// 最近的审计记录（新的在前）。
  Future<List<AgentAuditData>> recentAgentAudit({int limit = 200}) {
    return (select(agentAudit)
          ..orderBy([(t) => OrderingTerm(expression: t.at, mode: OrderingMode.desc)])
          ..limit(limit))
        .get();
  }

  Future<int> countAgentAudit() async {
    final query = selectOnly(agentAudit)..addColumns([agentAudit.id.count()]);
    final row = await query.getSingle();
    return row.read(agentAudit.id.count()) ?? 0;
  }

  /// 只保留最近 [keep] 条（默认 1000；防止审计表无限增长）。
  Future<void> pruneAgentAudit({int keep = 1000}) async {
    await customStatement(
      'DELETE FROM agent_audit WHERE id NOT IN '
      '(SELECT id FROM agent_audit ORDER BY id DESC LIMIT ?)',
      [keep],
    );
  }

  Future<void> clearAgentAudit() => delete(agentAudit).go();

  /// 按前缀列出 `vault_meta`（智能体配对记录用 `agent.pairing.` 前缀）。
  ///
  /// 前缀由调用方保证**不含** SQL 通配符（`%` / `_`），这里不做转义：
  /// 当前唯一的调用方用的是常量前缀 `agent.pairing.`。
  Future<List<VaultMetaData>> getMetaByPrefix(String prefix) {
    return (select(vaultMeta)
          ..where((t) => t.metaKey.like('$prefix%'))
          ..orderBy([(t) => OrderingTerm(expression: t.metaKey)]))
        .get();
  }

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

  /// **全部行，包含回收站**。
  ///
  /// 只给"必须遍历全库"的路径用：主密码轮换（漏掉回收站行 = 那些密文留在旧钥匙
  /// 上，恢复后永久解不开）、钥匙探测、清空全部数据。普通列表请用
  /// [watchEntriesFiltered] / [getEntriesFiltered]（默认排除回收站）。
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
    return (select(passwordEntries)..where(
          (t) =>
              (t.name.lower().like(lowerQuery) |
                  t.url.lower().like(lowerQuery) |
                  t.username.lower().like(lowerQuery)) &
              t.deletedAt.isNull(),
        ))
        .get();
  }

  /// 按文件夹 / 类型 / 收藏过滤条目（2.3.0 新增；3.1.0 起默认**不含回收站**）。
  ///
  /// - [folderId] 为 null：不按文件夹过滤；
  /// - [type] 为 null：不限类型；传 `'login'` 可只取登录条目（自动填充只认它）；
  /// - [favoritesOnly]：只返回收藏；
  /// - [includeDeleted]：`true` 时连回收站里的行一起返回（**只有**回收站界面与
  ///   轮换/清库这类"必须看到全部行"的路径用；普通列表一律默认排除）。
  Stream<List<PasswordEntry>> watchEntriesFiltered({
    String? folderId,
    String? type,
    bool favoritesOnly = false,
    bool includeDeleted = false,
  }) {
    final query = select(passwordEntries);
    if (!includeDeleted) {
      query.where((t) => t.deletedAt.isNull());
    }
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

  /// [watchEntriesFiltered] 的一次性版本（默认不含回收站）。
  Future<List<PasswordEntry>> getEntriesFiltered({
    String? folderId,
    String? type,
    bool favoritesOnly = false,
    bool includeDeleted = false,
  }) {
    final query = select(passwordEntries);
    if (!includeDeleted) {
      query.where((t) => t.deletedAt.isNull());
    }
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
    await (update(passwordEntries)..where((t) => t.folderId.equals(id))).write(
      const PasswordEntriesCompanion(folderId: Value(null)),
    );
    await deleteFolder(id);
  }

  Stream<List<PasswordEntry>> watchFavoriteEntries() {
    return (select(passwordEntries)
          ..where((t) => t.isFavorite.equals(true) & t.deletedAt.isNull()))
        .watch();
  }

  /// 单行读取：**故意包含回收站**。
  ///
  /// 调用方语义由仓储层裁决（`getItem` 默认把回收站行当不存在，恢复/彻底删除
  /// 才需要看到它们）；表本身不做"看不见"的过滤，否则恢复流程没法按 id 找行。
  Future<PasswordEntry?> getEntryById(String id) {
    return (select(
      passwordEntries,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// 单条目的**监听版**：编辑弹回详情页后要立刻显示新内容（含新加的自定义字段）。
  Stream<PasswordEntry?> watchEntryById(String id) {
    return (select(
      passwordEntries,
    )..where((t) => t.id.equals(id))).watchSingleOrNull();
  }

  Future<void> insertEntry(PasswordEntriesCompanion entry) {
    return into(passwordEntries).insertOnConflictUpdate(entry);
  }

  Future<void> updateEntry(String id, PasswordEntriesCompanion entry) {
    return (update(
      passwordEntries,
    )..where((t) => t.id.equals(id))).write(entry);
  }

  /// **硬删除**：整行（连同密文）从库里消失，不可恢复。
  ///
  /// 只给两条路用：彻底删除回收站里的某一条、以及"清空全部数据"。
  /// 普通删除请用 [trashEntry]。
  Future<void> deleteEntry(String id) {
    return (delete(passwordEntries)..where((t) => t.id.equals(id))).go();
  }

  // ─── 回收站（schema 5）──────────────────────────────────

  /// 标记为已删除（软删）：只写 `deleted_at`，**不动任何密文**。
  ///
  /// 返回受影响行数（0 = 没有这条或已经在回收站里）。
  Future<int> trashEntry(String id, int at) {
    return (update(passwordEntries)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .write(PasswordEntriesCompanion(deletedAt: Value(at)));
  }

  /// 从回收站恢复：`deleted_at` 置回 NULL，行与密文原样还在。
  ///
  /// 返回受影响行数（0 = 没有这条或它本来就不在回收站）。
  Future<int> restoreEntry(String id) {
    return (update(passwordEntries)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNotNull()))
        .write(const PasswordEntriesCompanion(deletedAt: Value(null)));
  }

  /// 回收站列表（最近删除的在前）。
  Future<List<PasswordEntry>> getTrashedEntries() {
    return (select(passwordEntries)
          ..where((t) => t.deletedAt.isNotNull())
          ..orderBy([
            (t) => OrderingTerm(
                  expression: t.deletedAt,
                  mode: OrderingMode.desc,
                ),
          ]))
        .get();
  }

  /// 回收站里的行数（不取行、不解密）。
  Future<int> countTrashedEntries() {
    final count = passwordEntries.id.count();
    return (selectOnly(passwordEntries)
          ..addColumns([count])
          ..where(passwordEntries.deletedAt.isNotNull()))
        .map((row) => row.read(count) ?? 0)
        .getSingle();
  }

  /// 清空回收站（硬删除全部已删除行），返回删除条数。
  Future<int> emptyTrash() {
    return (delete(passwordEntries)
          ..where((t) => t.deletedAt.isNotNull()))
        .go();
  }

  /// 正常条目总数（**不含回收站**）。
  Future<int> getEntryCount() {
    return (selectOnly(passwordEntries)
          ..addColumns([passwordEntries.id.count()])
          ..where(passwordEntries.deletedAt.isNull()))
        .map((row) => row.read(passwordEntries.id.count()) ?? 0)
        .getSingle();
  }

  /// 条目计数（不取行，只取 count）；[type] / [folderId] 非空时只数对应的行。
  /// **不含回收站**（删文件夹前的提示不该把已删除的条目算进去）。
  ///
  /// [folderId] 用于"删文件夹前先数一数里面有多少条目"：不能为了弹个提示
  /// 就把整库解密一遍（`getItems` 会解密每个字段）。
  Future<int> countEntriesFiltered({String? type, String? folderId}) {
    final count = passwordEntries.id.count();
    final query = selectOnly(passwordEntries)
      ..addColumns([count])
      ..where(passwordEntries.deletedAt.isNull());
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
    // 数据目录的解析（含"核心在 core\ 子目录时取父目录"的判据）全在
    // `AppPaths.prepareDatabaseFile()` 里；本分支只支持 Windows。
    final file = await AppPaths.prepareDatabaseFile();
    return NativeDatabase.createInBackground(file);
  });
}
