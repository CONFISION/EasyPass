import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/models/vault_item_mapper.dart';
import 'package:easypass/data/repositories/vault_repository.dart';

import 'fakes.dart';

/// [VaultRepository] 的条目级 API（2.3.0 主入口）契约测试。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late CryptoService crypto;
  late Uint8List key;
  late Uint8List? sessionKey;
  late VaultRepository repo;

  VaultItem loginItem({
    String id = 'login-1',
    String name = 'GitHub',
    String url = 'https://github.com',
    String username = 'alice',
    String password = 'pw',
    bool favorite = false,
    String? folderId,
    List<CustomField> customFields = const [],
  }) {
    return VaultItem(
      id: id,
      folderId: folderId,
      type: EntryType.login,
      name: name,
      isFavorite: favorite,
      login: LoginData(
        url: url,
        username: username,
        password: password,
      ),
      customFields: customFields,
      createdAt: 0,
      updatedAt: 0,
    );
  }

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    crypto = CryptoService(secureStorage: FakeSecureStorage());
    key = crypto.deriveKey('master', crypto.generateSalt());
    sessionKey = key;
    repo = VaultRepository(
      db: db,
      cryptoService: crypto,
      keyReader: () => sessionKey,
    );
  });

  tearDown(() => db.close());

  group('条目 CRUD', () {
    test('保存后能读回，且时间戳被规范化', () async {
      await repo.saveItem(loginItem());

      final item = await repo.getItem('login-1');
      expect(item, isNotNull);
      expect(item!.name, 'GitHub');
      expect(item.loginOrEmpty.password, 'pw');
      expect(item.loginOrEmpty.url, 'https://github.com');
      expect(item.createdAt, greaterThan(0));
      expect(item.updatedAt, greaterThanOrEqualTo(item.createdAt));
    });

    test('再次保存同一 id 是更新：createdAt 不变，updatedAt 前进', () async {
      await repo.saveItem(loginItem());
      final first = (await repo.getItem('login-1'))!;

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repo.saveItem(
        first.copyWith(login: first.loginOrEmpty.copyWith(password: 'new-pw')),
      );

      final updated = (await repo.getItem('login-1'))!;
      expect(updated.loginOrEmpty.password, 'new-pw');
      expect(updated.createdAt, first.createdAt);
      expect(updated.updatedAt, greaterThanOrEqualTo(first.updatedAt));
      expect(await repo.countItems(), 1);
    });

    test('四种类型都能存能读，类型过滤只返回对应类型', () async {
      await repo.saveItem(loginItem());
      await repo.saveItem(VaultItem(
        id: 'note-1',
        type: EntryType.secureNote,
        name: 'WiFi',
        notes: '正文',
        createdAt: 0,
        updatedAt: 0,
      ));
      await repo.saveItem(VaultItem(
        id: 'id-1',
        type: EntryType.identity,
        name: '身份证',
        identity: const IdentityData(idNumber: '110101199001011234'),
        createdAt: 0,
        updatedAt: 0,
      ));
      await repo.saveItem(VaultItem(
        id: 'ssh-1',
        type: EntryType.sshKey,
        name: 'server',
        sshKey: const SshKeyData(publicKey: 'ssh-ed25519 AAAA'),
        createdAt: 0,
        updatedAt: 0,
      ));

      expect(await repo.countItems(), 4);
      expect(await repo.countItemsByType(EntryType.login), 1);
      expect(await repo.countItemsByType(EntryType.sshKey), 1);

      final logins = await repo.getItems(type: EntryType.login);
      expect(logins.map((i) => i.id), ['login-1']);
      final notes = await repo.getItems(type: EntryType.secureNote);
      expect(notes.single.notes, '正文');
      final identities = await repo.getItems(type: EntryType.identity);
      expect(identities.single.identityOrEmpty.idNumber, '110101199001011234');
      final ssh = await repo.getItems(type: EntryType.sshKey);
      expect(ssh.single.sshKeyOrEmpty.publicKey, 'ssh-ed25519 AAAA');
    });

    test('删除后再读为 null', () async {
      await repo.saveItem(loginItem());
      await repo.deleteItem('login-1');
      expect(await repo.getItem('login-1'), isNull);
      expect(await repo.countItems(), 0);
    });

    test('收藏过滤', () async {
      await repo.saveItem(loginItem(id: 'a', name: 'A', favorite: true));
      await repo.saveItem(loginItem(id: 'b', name: 'B'));

      final favorites = await repo.getItems(favoritesOnly: true);
      expect(favorites.map((i) => i.id), ['a']);
      expect((await repo.watchItems(favoritesOnly: true).first).length, 1);
    });

    test('文件夹过滤与解除归属', () async {
      await repo.addFolder(FoldersCompanion.insert(
        id: 'folder-1',
        name: '工作',
        createdAt: 0,
        updatedAt: 0,
      ));
      await repo.saveItem(loginItem(id: 'a', name: 'A', folderId: 'folder-1'));
      await repo.saveItem(loginItem(id: 'b', name: 'B'));

      expect((await repo.getItems(folderId: 'folder-1')).map((i) => i.id), ['a']);

      // 删文件夹必须把条目的 folder_id 清掉（drift 默认不开外键）
      await repo.removeFolder('folder-1');
      final survivors = await repo.getItems();
      expect(survivors.map((i) => i.id), containsAll(['a', 'b']));
      expect(survivors.every((i) => i.folderId == null), isTrue);
    });

    test('watchItems 会推新数据（stream 契约）', () async {
      final stream = repo.watchItems();
      final emissions = <List<VaultItem>>[];
      final sub = stream.listen(emissions.add);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await repo.saveItem(loginItem());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();

      expect(emissions.first, isEmpty);
      expect(emissions.last.length, 1);
    });

    // ── 2.3.1：把"一次性读取 + 手写失效"换成流，以下三条守着这个契约 ──

    test('watchItem：任何写入都会推新值（详情页不再需要手动 invalidate）', () async {
      await repo.saveItem(loginItem(id: 'w1'));

      final seen = <VaultItem?>[];
      final sub = repo.watchItem('w1').listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final current = (await repo.getItem('w1'))!;
      await repo.saveItem(current.copyWith(
        name: '改过的名字',
        customFields: const [CustomField(label: 'PIN', value: '4321')],
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();

      expect(seen.first?.name, 'GitHub');
      expect(seen.last?.name, '改过的名字');
      expect(seen.last?.customFields.single.value, '4321',
          reason: '"新加的自定义字段不显示"就是这个断言在守的回归');
    });

    test('watchItem：未解锁给 null；不存在的 id 也是 null', () async {
      sessionKey = null;
      expect(await repo.watchItem('w1').first, isNull);

      sessionKey = key;
      expect(await repo.watchItem('nope').first, isNull);
    });

    test('watchFolders：新增文件夹后立刻推新列表（表单里只能看到第一个文件夹的回归）',
        () async {
      await repo.addFolder(FoldersCompanion.insert(
        id: 'f1',
        name: '邮箱',
        createdAt: 0,
        updatedAt: 0,
      ));

      final seen = <List<Folder>>[];
      final sub = repo.watchFolders().listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(seen.last.map((f) => f.name), ['邮箱']);

      await repo.addFolder(FoldersCompanion.insert(
        id: 'f2',
        name: '工作',
        createdAt: 0,
        updatedAt: 0,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();

      expect(seen.last.map((f) => f.name), containsAll(['邮箱', '工作']));
    });

    test('watchSearch：编辑条目后同一个查询词给新结果', () async {
      await repo.saveItem(loginItem(id: 's1', name: 'GitHub'));

      final seen = <List<VaultItem>>[];
      final sub = repo.watchSearch('github').listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(seen.last.single.name, 'GitHub');

      final current = (await repo.getItem('s1'))!;
      await repo.saveItem(current.copyWith(name: 'GitHub 工作号'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();

      expect(seen.last.single.name, 'GitHub 工作号',
          reason: 'FutureProvider 版本的搜索会把同一个词永久缓存住');
    });
  });

  group('锁定状态', () {
    test('未解锁：读返回空 / null，写抛 VaultLockedException', () async {
      sessionKey = null;

      expect(await repo.getItems(), isEmpty);
      expect(await repo.getItem('nope'), isNull);
      expect(await repo.searchItems('x'), isEmpty);
      expect(repo.isUnlocked, isFalse);
      expect(
        () => repo.saveItem(loginItem()),
        throwsA(isA<VaultLockedException>()),
      );
    });

    test('解锁后立刻能读到（keyReader 是现读的，不需要重建 repository）', () async {
      sessionKey = null;
      final stream = repo.watchItems();
      expect(await stream.first, isEmpty);

      sessionKey = key;
      await repo.saveItem(loginItem());
      expect((await repo.getItems()).length, 1);
      expect(repo.isUnlocked, isTrue);
    });
  });

  group('搜索', () {
    setUp(() async {
      await repo.saveItem(loginItem(
        id: 'gh',
        name: 'GitHub',
        url: 'https://github.com',
        username: 'alice',
        customFields: const [CustomField(label: 'PIN', value: '7788')],
      ));
      await repo.saveItem(loginItem(
        id: 'gl',
        name: 'GitLab',
        url: 'https://gitlab.example.com',
        username: 'bob',
      ));
      await repo.saveItem(VaultItem(
        id: 'note',
        type: EntryType.secureNote,
        name: 'WiFi 密码',
        notes: '家里路由器',
        createdAt: 0,
        updatedAt: 0,
      ));
      await repo.saveItem(VaultItem(
        id: 'ssh',
        type: EntryType.sshKey,
        name: 'server key',
        sshKey: const SshKeyData(
          publicKey: 'ssh-ed25519 AAAA',
          fingerprint: 'SHA256:abcdef',
          comment: 'root@server',
        ),
        createdAt: 0,
        updatedAt: 0,
      ));
      await repo.saveItem(VaultItem(
        id: 'idcard',
        type: EntryType.identity,
        name: '我的身份证',
        identity: const IdentityData(firstName: '三', idNumber: '110101199001011234'),
        createdAt: 0,
        updatedAt: 0,
      ));
      await repo.addFolder(FoldersCompanion.insert(
        id: 'folder-work',
        name: '工作',
        createdAt: 0,
        updatedAt: 0,
      ));
      await repo.saveItem(loginItem(
        id: 'work',
        name: '公司邮箱',
        url: 'https://mail.corp.example',
        username: 'carol',
        folderId: 'folder-work',
      ));
    });

    test('自由词匹配名称 / 用户名 / URL / 备注 / 自定义字段', () async {
      expect((await repo.searchItems('github')).single.id, 'gh');
      expect((await repo.searchItems('alice')).single.id, 'gh');
      expect((await repo.searchItems('7788')).single.id, 'gh');
      expect((await repo.searchItems('路由器')).single.id, 'note');
      expect((await repo.searchItems('GITHUB')).single.id, 'gh');
    });

    test('type: 前缀（含中文别名）', () async {
      final notes = await repo.searchItems('type:note');
      expect(notes.map((i) => i.id), ['note']);
      expect((await repo.searchItems('type:ssh')).map((i) => i.id), ['ssh']);
      expect((await repo.searchItems('type:密钥')).map((i) => i.id), ['ssh']);
      expect((await repo.searchItems('type:identity')).map((i) => i.id), ['idcard']);
      expect(
        (await repo.searchItems('type:login')).map((i) => i.id),
        containsAll(['gh', 'gl', 'work']),
      );
      // type:all 等于不过滤
      expect((await repo.searchItems('type:all')).length, 6);
    });

    test('folder: 与 url: 前缀', () async {
      expect((await repo.searchItems('folder:工作')).map((i) => i.id), ['work']);
      expect((await repo.searchItems('url:gitlab')).map((i) => i.id), ['gl']);
      expect(await repo.searchItems('folder:不存在'), isEmpty);
      // 非登录条目的 url 视为空 → url: 过滤不命中
      expect(
        (await repo.searchItems('url:example')).map((i) => i.id),
        ['gl', 'work'],
      );
    });

    test('多条件是与关系，结果按名称排序', () async {
      final result = await repo.searchItems('type:login example');
      expect(result.map((i) => i.id), ['gl', 'work']);
      expect(result.map((i) => i.name), ['GitLab', '公司邮箱']);
    });

    test('空查询 / 只有空白 → 空结果（不是全量）', () async {
      expect(await repo.searchItems(''), isEmpty);
      expect(await repo.searchItems('   '), isEmpty);
    });

    test('type: 拼错时不静默回退成"只搜登录"，而是干净地搜不到', () async {
      // 老行为：EntryType.fromWire 未知值 → login，于是 type:identiy 会
      // 返回一堆登录条目，看着像筛选生效了。现在按自由词处理 → 空结果。
      expect(await repo.searchItems('type:identiy'), isEmpty);
      expect(await repo.searchItems('type:nonsense'), isEmpty);
      // 正确的写法仍然照常工作（含别名与中文）
      expect((await repo.searchItems('type:ssh_key')).map((i) => i.id), ['ssh']);
      expect((await repo.searchItems('type:ssh')).map((i) => i.id), ['ssh']);
    });

    test('搜不到就空', () async {
      expect(await repo.searchItems('zzz-not-exist'), isEmpty);
    });
  });

  group('旧行级 API 仍在（迁移期兼容）', () {
    test('saveEntry / watchEntries 还能用', () async {
      final uuid = const Uuid().v4();
      // ignore: deprecated_member_use_from_same_package
      await repo.saveEntry(PasswordEntriesCompanion.insert(
        id: uuid,
        name: 'legacy',
        passwordEncrypted: crypto.encryptData('pw', key),
        createdAt: 0,
        updatedAt: 0,
      ));
      // ignore: deprecated_member_use_from_same_package
      final rows = await repo.getAllEntries();
      expect(rows.single.name, 'legacy');
      // 默认 type 就是 login，能被新 API 读到
      final item = await repo.getItem(uuid);
      expect(item!.type, EntryType.login);
      expect(item.loginOrEmpty.password, 'pw');
    });
  });
}
