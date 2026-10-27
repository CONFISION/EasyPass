import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'core_actions_harness.dart';

/// 回收站（schema 5）的**核心侧**回归：删除 = 软删、可恢复、彻底删只在 UI 动作面。
///
/// 这里守的是几条不变量：
/// 1. 删除只写 `deleted_at`，行与密文都不动（恢复零成本）；
/// 2. 列表 / 搜索 / 计数 / 导出默认全部排除回收站；
/// 3. **主密码轮换必须覆盖回收站里的行** —— 漏掉就会让那些密文留在旧钥匙上，
///    恢复后永久解不开（这是本轮最危险的一处，专门有断言）；
/// 4. 清库连回收站一起清。
void main() {
  late CoreVault vault;
  late CoreHarness core;

  const password = 'master-pw';
  var seq = 0;

  setUp(() async {
    seq = 0;
    vault = CoreVault.create();
    core = await vault.boot();
    await core.call(Actions.setMasterPassword, {
      'password': password,
      'confirmPassword': password,
    });
  });

  tearDown(() => vault.close());

  Future<String> seed({
    String name = 'GitHub',
    String secret = 'pw-123',
    String? folderId,
    bool favorite = false,
  }) async {
    final id = 'e${seq++}';
    await core.call(Actions.saveItem, {
      'item': VaultItem(
        id: id,
        folderId: folderId,
        type: EntryType.login,
        name: name,
        notes: '备注',
        isFavorite: favorite,
        login: LoginData(
          url: 'https://example.com',
          username: 'alice',
          password: secret,
        ),
        createdAt: 1,
        updatedAt: 1,
      ).toJson(),
    });
    return id;
  }

  Future<List<Map<String, dynamic>>> listItems() async {
    final result = await core.call(Actions.listItems);
    return (result['items'] as List).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> listTrash() async {
    final result = await core.call(Actions.listTrash);
    return (result['items'] as List).cast<Map<String, dynamic>>();
  }

  test('删除 = 软删：列表里消失、回收站里出现、库里行还在', () async {
    final id = await seed();
    final result = await core.call(Actions.deleteItem, {'id': id});
    expect(result['trashed'], isTrue);

    expect(await listItems(), isEmpty);
    final trash = await listTrash();
    expect(trash.single['id'], id);
    expect(trash.single['name'], 'GitHub');
    expect(trash.single['deleted_at'], isNotNull);

    // 行与密文都还在（软删只改 deleted_at）。
    final row = (await core.vault.db.getAllEntries()).single;
    expect(row.id, id);
    expect(row.deletedAt, isNotNull);
    expect(row.passwordEncrypted, isNotEmpty);

    // 广播了 items 主题（UI 的流才会重取）。
    expect(core.changedTopics, contains(Topics.items));
  });

  test('重复删除 / 删除不存在的条目 ⇒ notFound（不会二次写 deleted_at）', () async {
    final id = await seed();
    await core.call(Actions.deleteItem, {'id': id});

    await expectLater(
      core.call(Actions.deleteItem, {'id': id}),
      throwsA(anything),
    );
    await expectLater(
      core.call(Actions.deleteItem, {'id': 'nope'}),
      throwsA(anything),
    );
    expect((await core.vault.db.getAllEntries()).single.deletedAt, isNotNull);
  });

  test('恢复：回到列表，回收站清空；连恢复两次第二次 notFound', () async {
    final id = await seed();
    await core.call(Actions.deleteItem, {'id': id});

    final restored = await core.call(Actions.restoreItem, {'id': id});
    expect(restored['ok'], isTrue);
    expect(await listTrash(), isEmpty);
    expect((await listItems()).single['id'], id);
    expect((await core.call(Actions.getItem, {'id': id}))['item']['name'],
        'GitHub');

    await expectLater(
      core.call(Actions.restoreItem, {'id': id}),
      throwsA(anything),
    );
  });

  test('彻底删除：只能删回收站里的条目，删完行真的没了', () async {
    final id = await seed();

    // 正常条目不能一步彻底删除（必须先删进回收站）。
    await expectLater(
      core.call(Actions.permanentlyDeleteItem, {'id': id}),
      throwsA(anything),
    );

    await core.call(Actions.deleteItem, {'id': id});
    final removed = await core.call(Actions.permanentlyDeleteItem, {'id': id});
    expect(removed['ok'], isTrue);
    expect(await core.vault.db.getAllEntries(), isEmpty);
    expect(await listTrash(), isEmpty);
  });

  test('清空回收站：返回删除条数，正常条目不受影响', () async {
    final keep = await seed(name: '留下');
    final a = await seed(name: '删 A');
    final b = await seed(name: '删 B');
    await core.call(Actions.deleteItem, {'id': a});
    await core.call(Actions.deleteItem, {'id': b});

    final result = await core.call(Actions.emptyTrash);
    expect(result['deleted'], 2);
    expect(await listTrash(), isEmpty);

    final items = await listItems();
    expect(items.single['id'], keep);
    expect((await core.vault.db.getAllEntries()).single.id, keep);
  });

  test('列表 / 搜索 / 计数 / 文件夹计数都排除回收站', () async {
    await core.vault.db.insertFolder(FoldersCompanion.insert(
      id: 'f1',
      name: '工作',
      createdAt: 1,
      updatedAt: 1,
    ));
    final live = await seed(name: '活着', folderId: 'f1');
    final trashed = await seed(name: '要删的', folderId: 'f1');
    await core.call(Actions.deleteItem, {'id': trashed});

    expect((await listItems()).single['id'], live);
    final searched = await core.call(Actions.searchItems, {'query': '要删'});
    expect(searched['items'], isEmpty);
    final folderCount = await core.call(
      Actions.countItemsInFolder,
      {'folderId': 'f1'},
    );
    expect(folderCount['count'], 1, reason: '删文件夹前的提示不该算回收站');
    final status = await core.call(Actions.getStatus);
    expect(status['entryCount'], 1);
    final health = await core.call(Actions.getHealthReport);
    expect(health['totalEntries'], 1);
  });

  test('导出不包含回收站条目（备份只含当前条目）', () async {
    await seed(name: '活着');
    final trashed = await seed(name: '已删除的秘密');
    await core.call(Actions.deleteItem, {'id': trashed});

    final plain = await core.exporter.exportPlainJson();
    expect(plain.contains('活着'), isTrue);
    expect(plain.contains('已删除的秘密'), isFalse);

    final encrypted = await core.exporter.exportEncrypted();
    expect(encrypted, isNotEmpty);
  });

  test('清库（deleteAllData）连回收站一起清空', () async {
    await core.call(Actions.deleteItem, {'id': await seed(name: 'a')});
    await seed(name: 'b');

    final result = await core.call(Actions.deleteAllData, {'confirm': true});
    expect(result['entries'], 2);
    expect(await core.vault.db.getAllEntries(), isEmpty);
    expect(await core.vault.db.countTrashedEntries(), 0);
  });

  test('主密码轮换必须覆盖回收站里的行（否则恢复后密文永久解不开）', () async {
    final id = await seed(name: '回收站里的条目', secret: 'trashed-secret');
    await core.call(Actions.deleteItem, {'id': id});

    // 轮换：整库 re-encrypt（getAllEntries 包含回收站行）。
    await core.changeMasterPassword(current: password, next: 'next-pass');

    // 重启核心：全新会话，用新密码解锁。
    final reborn = await vault.boot();
    await reborn.unlock('next-pass');

    final trash = await reborn.call(Actions.listTrash);
    final rows = (trash['items'] as List).cast<Map<String, dynamic>>();
    expect(rows.single['id'], id);

    // 恢复后密码必须是原值 —— 如果轮换漏了回收站，这里会解出空串（宽容解密）。
    await reborn.call(Actions.restoreItem, {'id': id});
    final item = (await reborn.call(Actions.getItem, {'id': id}))['item'];
    expect((item['login'] as Map)['password'], 'trashed-secret');
  });
}
