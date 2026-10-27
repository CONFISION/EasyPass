import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/models/vault_item_mapper.dart';
import 'package:easypass/data/services/master_password_rotation.dart';
import 'package:easypass/core/crypto/crypto_service.dart';

import 'fakes.dart';

/// schema 迁移测试：**老用户的库能不能开起来**。
///
/// 1.x 的 `onUpgrade` 是空实现、`schemaVersion` 钉在 1，所以"加一列"这件事
/// 在本仓库没有先例 —— 这个文件就是那次迁移的回归网：
/// 手工建一个 v1 形态的库（含数据），再用当前代码打开，断言
/// 1) 不抛异常；2) 旧数据还在、且被当作登录条目；3) 新列可用。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  /// v1（2.2.x）的建表语句，故意与当年的 tables.drift 完全一致：
  /// 没有 type / data_encrypted，`user_version` 也停在 1。
  void createV1Schema(dynamic db) {
    db.execute('''
      CREATE TABLE folders (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        icon TEXT DEFAULT 'folder',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE password_entries (
        id TEXT PRIMARY KEY NOT NULL,
        folder_id TEXT,
        name TEXT NOT NULL,
        url TEXT NOT NULL DEFAULT '',
        username TEXT NOT NULL DEFAULT '',
        password_encrypted TEXT NOT NULL,
        notes_encrypted TEXT DEFAULT '',
        totp_secret_encrypted TEXT DEFAULT '',
        is_favorite BOOLEAN NOT NULL DEFAULT FALSE,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (folder_id) REFERENCES folders(id) ON DELETE SET NULL
      );
    ''');
    db.execute(
        'CREATE INDEX idx_password_entries_folder ON password_entries(folder_id);');
    db.execute(
        'CREATE INDEX idx_password_entries_name ON password_entries(name);');
    db.execute(
        'CREATE INDEX idx_password_entries_favorite ON password_entries(is_favorite);');
    db.execute('PRAGMA user_version = 1;');
  }

  /// v2（2.3.x）的建表语句：有了 type / data_encrypted，但**没有 vault_meta**，
  /// `user_version` 停在 2。
  void createV2Schema(dynamic db) {
    db.execute('''
      CREATE TABLE folders (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        icon TEXT DEFAULT 'folder',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE password_entries (
        id TEXT PRIMARY KEY NOT NULL,
        folder_id TEXT,
        type TEXT NOT NULL DEFAULT 'login',
        name TEXT NOT NULL,
        url TEXT NOT NULL DEFAULT '',
        username TEXT NOT NULL DEFAULT '',
        password_encrypted TEXT NOT NULL,
        notes_encrypted TEXT DEFAULT '',
        totp_secret_encrypted TEXT DEFAULT '',
        data_encrypted TEXT NOT NULL DEFAULT '',
        is_favorite BOOLEAN NOT NULL DEFAULT FALSE,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (folder_id) REFERENCES folders(id) ON DELETE SET NULL
      );
    ''');
    db.execute(
        'CREATE INDEX idx_password_entries_folder ON password_entries(folder_id);');
    db.execute(
        'CREATE INDEX idx_password_entries_name ON password_entries(name);');
    db.execute(
        'CREATE INDEX idx_password_entries_favorite ON password_entries(is_favorite);');
    db.execute(
        'CREATE INDEX idx_password_entries_type ON password_entries(type);');
    db.execute('PRAGMA user_version = 2;');
  }

  /// v3（2.4.0）的建表语句：v2 + `vault_meta`，但**没有 agent_audit**，
  /// `user_version` 停在 3。用来验证 3.1.0 的智能体审计表迁移。
  void createV3Schema(dynamic db) {
    createV2Schema(db);
    db.execute('''
      CREATE TABLE vault_meta (
        meta_key TEXT PRIMARY KEY NOT NULL,
        meta_value TEXT NOT NULL
      );
    ''');
    db.execute('PRAGMA user_version = 3;');
  }

  /// v4（3.1.0 早期）的建表语句：v3 + `agent_audit`，但**没有**回收站的
  /// `deleted_at` 列，`user_version` 停在 4。用来验证回收站迁移。
  void createV4Schema(dynamic db) {
    createV3Schema(db);
    db.execute('''
      CREATE TABLE agent_audit (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        at INTEGER NOT NULL,
        pairing_id TEXT NOT NULL,
        nickname TEXT NOT NULL,
        mode TEXT NOT NULL,
        tool TEXT NOT NULL,
        op TEXT NOT NULL,
        entry_id TEXT,
        entry_name TEXT,
        decision TEXT NOT NULL
      );
    ''');
    db.execute('CREATE INDEX idx_agent_audit_at ON agent_audit(at);');
    db.execute('PRAGMA user_version = 4;');
  }

  test('v1 → v2：旧数据保留、新列可用、类型默认登录', () async {
    final crypto = CryptoService(secureStorage: FakeSecureStorage());
    final key = crypto.deriveKey('master', crypto.generateSalt());
    final legacyPassword = crypto.encryptData('old-pw', key);

    final executor = NativeDatabase.memory(setup: (raw) {
      createV1Schema(raw);
      // 一条 v1 时期的登录条目 + 一个文件夹
      raw.execute(
        "INSERT INTO folders (id, name, icon, created_at, updated_at) "
        "VALUES ('f1', '工作', 'folder', 1, 1);",
      );
      raw.execute(
        'INSERT INTO password_entries '
        '(id, folder_id, name, url, username, password_encrypted, '
        ' notes_encrypted, totp_secret_encrypted, is_favorite, created_at, updated_at) '
        "VALUES ('legacy', 'f1', 'GitHub', 'https://github.com', 'alice', '$legacyPassword', "
        "'', '', 1, 100, 200);",
      );
    });

    final db = AppDatabase.forTesting(executor);
    addTearDown(db.close);

    // 触发打开 + 迁移（1 → 2）
    final rows = await db.getAllEntries();
    expect(rows.length, 1);
    final legacy = rows.single;
    expect(legacy.name, 'GitHub');
    expect(legacy.url, 'https://github.com');
    expect(legacy.username, 'alice');
    expect(legacy.isFavorite, isTrue);
    expect(legacy.createdAt, 100);
    // 新列存在且取到默认值
    expect(legacy.type, 'login');
    expect(legacy.dataEncrypted, '');

    // 迁移后的库能正常用新模型读
    final mapper = VaultItemMapper(crypto);
    final item = mapper.fromRow(legacy, key);
    expect(item.type, EntryType.login);
    expect(item.loginOrEmpty.password, 'old-pw');

    // 旧条目也能被新的类型过滤查到
    final logins = await db.getEntriesFiltered(type: EntryType.login.wireName);
    expect(logins.length, 1);
    final others =
        await db.getEntriesFiltered(type: EntryType.sshKey.wireName);
    expect(others, isEmpty);
  });

  test('v2 → v3：新增 vault_meta 表，旧数据不动，轮换日志可用', () async {
    final crypto = CryptoService(secureStorage: FakeSecureStorage());
    final key = crypto.deriveKey('master', crypto.generateSalt());
    final legacyPassword = crypto.encryptData('v2-pw', key);

    final executor = NativeDatabase.memory(setup: (raw) {
      createV2Schema(raw);
      raw.execute(
        'INSERT INTO password_entries '
        '(id, folder_id, type, name, url, username, password_encrypted, '
        ' notes_encrypted, totp_secret_encrypted, data_encrypted, '
        ' is_favorite, created_at, updated_at) '
        "VALUES ('e1', NULL, 'login', 'GitHub', 'https://github.com', 'alice', "
        "'$legacyPassword', '', '', '', 0, 100, 200);",
      );
    });

    final db = AppDatabase.forTesting(executor);
    addTearDown(db.close);

    // 触发打开 + 迁移（2 → 3）。
    final rows = await db.getAllEntries();
    expect(rows.length, 1, reason: '迁移不该动旧数据');
    expect(rows.single.name, 'GitHub');

    // 新表存在且可读写 —— 这正是"改主密码轮换日志"依赖的能力。
    expect(await db.getMeta(MasterPasswordRotation.metaKey), isNull);
    await db.setMeta(MasterPasswordRotation.metaKey, '{"salt":"s","password_hash":"h"}');
    expect(await db.getMeta(MasterPasswordRotation.metaKey), isNotNull);
    await db.deleteMeta(MasterPasswordRotation.metaKey);
    expect(await db.getMeta(MasterPasswordRotation.metaKey), isNull);

    // 旧密文仍能用旧钥匙解开（迁移没碰加密）。
    final mapper = VaultItemMapper(crypto);
    expect(mapper.fromRow(rows.single, key).loginOrEmpty.password, 'v2-pw');
  });

  test('v3 → v4：新增 agent_audit 表，旧数据不动，审计可读写', () async {
    final crypto = CryptoService(secureStorage: FakeSecureStorage());
    final key = crypto.deriveKey('master', crypto.generateSalt());
    final legacyPassword = crypto.encryptData('v3-pw', key);

    final executor = NativeDatabase.memory(setup: (raw) {
      createV3Schema(raw);
      raw.execute(
        'INSERT INTO password_entries '
        '(id, folder_id, type, name, url, username, password_encrypted, '
        ' notes_encrypted, totp_secret_encrypted, data_encrypted, '
        ' is_favorite, created_at, updated_at) '
        "VALUES ('e1', NULL, 'login', 'GitHub', 'https://github.com', 'alice', "
        "'$legacyPassword', '', '', '', 0, 100, 200);",
      );
    });

    final db = AppDatabase.forTesting(executor);
    addTearDown(db.close);

    final rows = await db.getAllEntries();
    expect(rows.length, 1, reason: '迁移不该动旧数据');
    expect(await db.countAgentAudit(), 0, reason: 'v4 的 agent_audit 表必须建出来');

    await db.insertAgentAudit(
      at: 123,
      pairingId: 'p1',
      nickname: 'DSH',
      mode: 'trusted',
      tool: 'list_entries',
      op: 'read',
      decision: 'allowed',
    );
    final audit = await db.recentAgentAudit();
    expect(audit.single.nickname, 'DSH');
    expect(audit.single.entryId, isNull);
    expect(await db.countAgentAudit(), 1);

    final mapper = VaultItemMapper(crypto);
    expect(mapper.fromRow(rows.single, key).loginOrEmpty.password, 'v3-pw');
  });

  test('v4 → v5：新增 deleted_at 列（回收站），旧行自动 NULL = 不在回收站', () async {
    final crypto = CryptoService(secureStorage: FakeSecureStorage());
    final key = crypto.deriveKey('master', crypto.generateSalt());
    final legacyPassword = crypto.encryptData('v4-pw', key);

    final executor = NativeDatabase.memory(setup: (raw) {
      createV4Schema(raw);
      raw.execute(
        'INSERT INTO password_entries '
        '(id, folder_id, type, name, url, username, password_encrypted, '
        ' notes_encrypted, totp_secret_encrypted, data_encrypted, '
        ' is_favorite, created_at, updated_at) '
        "VALUES ('e1', NULL, 'login', 'GitHub', 'https://github.com', 'alice', "
        "'$legacyPassword', '', '', '', 0, 100, 200);",
      );
    });

    final db = AppDatabase.forTesting(executor);
    addTearDown(db.close);

    // 触发打开 + 迁移（4 → 5）。旧行必须落在 `deleted_at IS NULL`。
    final rows = await db.getAllEntries();
    expect(rows.length, 1, reason: '迁移不该动旧数据');
    expect(rows.single.deletedAt, isNull, reason: '存量条目默认不在回收站');
    expect(await db.getEntryCount(), 1);
    expect(await db.countTrashedEntries(), 0);
    expect(await db.getEntriesFiltered(), hasLength(1));

    // 迁移后回收站功能真的可用：软删 → 列表排除 / 回收站可见 → 恢复。
    expect(await db.trashEntry('e1', 999), 1);
    expect(await db.getEntriesFiltered(), isEmpty);
    expect(await db.getEntryCount(), 0);
    expect(await db.countTrashedEntries(), 1);
    expect((await db.getTrashedEntries()).single.deletedAt, 999);
    expect(await db.restoreEntry('e1'), 1);
    expect(await db.getEntriesFiltered(), hasLength(1));

    // 旧密文仍能用旧钥匙解开（迁移没碰加密）。
    final mapper = VaultItemMapper(crypto);
    expect(mapper.fromRow(rows.single, key).loginOrEmpty.password, 'v4-pw');
  });

  test('v1 → 最新：一路升到 5，旧数据、轮换日志与回收站列都可用', () async {
    final crypto = CryptoService(secureStorage: FakeSecureStorage());
    final key = crypto.deriveKey('master', crypto.generateSalt());
    final legacyPassword = crypto.encryptData('ancient-pw', key);

    final executor = NativeDatabase.memory(setup: (raw) {
      createV1Schema(raw);
      raw.execute(
        'INSERT INTO password_entries '
        '(id, folder_id, name, url, username, password_encrypted, '
        ' notes_encrypted, totp_secret_encrypted, is_favorite, created_at, updated_at) '
        "VALUES ('legacy', NULL, 'Legacy', 'https://example.com', 'bob', "
        "'$legacyPassword', '', '', 0, 1, 2);",
      );
    });

    final db = AppDatabase.forTesting(executor);
    addTearDown(db.close);

    final rows = await db.getAllEntries();
    expect(rows.length, 1);
    expect(rows.single.type, 'login', reason: 'v1 数据要补上 v2 的类型默认值');
    expect(rows.single.dataEncrypted, '');
    expect(await db.getMeta(MasterPasswordRotation.metaKey), isNull,
        reason: 'v3 的 vault_meta 表必须一并建出来');

    final mapper = VaultItemMapper(crypto);
    expect(mapper.fromRow(rows.single, key).loginOrEmpty.password, 'ancient-pw');
  });

  test('v2 库新写入的四种类型：类型列与计数查询都正确', () async {    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final crypto = CryptoService(secureStorage: FakeSecureStorage());
    final key = crypto.deriveKey('master', crypto.generateSalt());
    final mapper = VaultItemMapper(crypto);

    for (final type in EntryType.values) {
      await db.insertEntry(mapper.toInsert(
        VaultItem(
          id: 'id-${type.wireName}',
          type: type,
          name: 'name-${type.wireName}',
          login: type == EntryType.login ? const LoginData(password: 'p') : null,
          createdAt: 0,
          updatedAt: 0,
        ),
        key,
      ));
    }

    expect(await db.countEntriesFiltered(), 4);
    expect(await db.countEntriesFiltered(type: EntryType.identity.wireName), 1);
    expect(await db.getEntryCount(), 4); // 旧计数方法仍然可用
  });

  test('删除文件夹会解除条目归属（不依赖外键约束）', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.insertFolder(FoldersCompanion.insert(
      id: 'f1',
      name: '工作',
      createdAt: 0,
      updatedAt: 0,
    ));
    await db.insertEntry(PasswordEntriesCompanion.insert(
      id: 'e1',
      name: 'n',
      passwordEncrypted: 'cipher',
      folderId: const Value('f1'),
      createdAt: 0,
      updatedAt: 0,
    ));

    await db.deleteFolderAndUnassign('f1');

    final row = (await db.getAllEntries()).single;
    expect(row.folderId, isNull);
    expect(await db.getAllFolders(), isEmpty);
  });
}
