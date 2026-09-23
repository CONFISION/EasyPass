import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/models/vault_item_mapper.dart';
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

  test('v2 库新写入的四种类型：类型列与计数查询都正确', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
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
