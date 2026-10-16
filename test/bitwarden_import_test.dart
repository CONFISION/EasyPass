import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/data/services/bitwarden_importer.dart';
import 'package:easypass/data/services/export_import_service.dart';

import 'fakes.dart';

/// Bitwarden / Vaultwarden 导入回归（v2.4）。
///
/// 测试里的样例 JSON/CSV 是按 Bitwarden 的导出**契约**手写的（字段名与类型编号
/// 见 Bitwarden 官方导出格式），刻意包含真实导出里那些"容易漏"的形状：
/// 一条登录挂多个 URI、银行卡、linked 自定义字段、密码历史、带逗号与引号的备注。
///
/// **注意**：这些是"照着契约写的"样例，不能替代拿一份真实 Bitwarden 导出跑一遍
/// 真机验收 —— 这一点在交付说明里也写明了。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late VaultRepository repo;
  late CryptoService crypto;
  late BitwardenImporter importer;

  setUp(() {
    crypto = CryptoService(secureStorage: FakeSecureStorage());
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = VaultRepository(
      db: db,
      cryptoService: crypto,
      keyReader: () => crypto.deriveKey('master', 'c2FsdA=='),
    );
    importer = BitwardenImporter(db: db, repository: repo);
  });

  tearDown(() => db.close());

  /// 一份覆盖四种类型的 Bitwarden JSON 导出。
  String sampleJson() => jsonEncode({
        'encrypted': false,
        'folders': [
          {'id': 'f-1', 'name': '工作'},
          {'id': 'f-2', 'name': '个人'},
        ],
        'items': [
          {
            'id': 'bw-1',
            'folderId': 'f-1',
            'type': 1,
            'name': 'GitHub',
            'notes': '主账号',
            'favorite': true,
            'login': {
              'uris': [
                {'uri': 'https://github.com'},
                {'uri': 'https://gist.github.com'},
              ],
              'username': 'alice',
              'password': 'p@ss,word"quoted"',
              'totp': 'JBSWY3DPEHPK3PXP',
              'passwordHistory': [
                {'lastUsedDate': '2024-01-01T00:00:00.000Z', 'password': 'old-pw-1'},
              ],
            },
            'fields': [
              {'name': 'PIN', 'value': '4321', 'type': 1},
              {'name': '启用', 'value': 'true', 'type': 2},
              {'name': '关联字段', 'value': 'whatever', 'type': 3},
            ],
          },
          {
            'id': 'bw-2',
            'folderId': 'f-2',
            'type': 2,
            'name': '保险箱密码',
            'notes': '第一行\n第二行',
            'secureNote': {'type': 0},
          },
          {
            // 银行卡：EasyPass 没有这个类型，必须降级成安全笔记而不是丢掉。
            'id': 'bw-3',
            'folderId': null,
            'type': 3,
            'name': '招行信用卡',
            'notes': '',
            'card': {
              'cardholderName': '张三',
              'brand': 'Visa',
              'number': '4111111111111111',
              'expMonth': '12',
              'expYear': '2030',
              'code': '123',
            },
          },
          {
            'id': 'bw-4',
            'folderId': 'f-1',
            'type': 4,
            'name': '我的身份',
            'identity': {
              'title': '先生',
              'firstName': '三',
              'lastName': '张',
              'email': 'zhangsan@example.com',
              'ssn': '110101199001011234',
              'passportNumber': 'E12345678',
              'city': '北京',
              'country': '中国',
              'birthDate': '1990-01-01',
              // EasyPass 身份模型里没有的项，要落到自定义字段里而不是丢掉。
              'someExtraField': '别丢了我',
            },
          },
          {
            // 未知类型 → 跳过并如实报告，而不是当成登录硬塞进去。
            'id': 'bw-5',
            'type': 99,
            'name': '未来类型',
          },
        ],
      });

  group('JSON 导入：四种类型与"不丢信息"取舍', () {
    test('登录条目：多 URI 折叠、自定义字段类型保留、密码历史进备注', () async {
      final report = await importer.importJson(sampleJson());

      expect(report.entries, 4, reason: '未知类型那条不该被写入');
      expect(report.skipped, hasLength(1));
      expect(report.skipped.single, contains('未来类型'));
      expect(report.skipped.single, contains('99'));
      expect(report.extraUris, 1, reason: '第二条 URI 应当被折叠成自定义字段');
      expect(report.cardsAsNotes, 1);

      final items = await repo.getItems();
      final github = items.firstWhere((i) => i.name == 'GitHub');

      expect(github.type, EntryType.login);
      expect(github.loginOrEmpty.url, 'https://github.com');
      expect(github.loginOrEmpty.username, 'alice');
      // 带逗号和引号的密码必须原样存活（CSV/JSON 转义都要对）。
      expect(github.loginOrEmpty.password, 'p@ss,word"quoted"');
      expect(github.loginOrEmpty.totpSecret, 'JBSWY3DPEHPK3PXP');
      expect(github.isFavorite, isTrue);
      expect(github.notes, contains('主账号'));
      expect(github.notes, contains('密码历史'));
      expect(github.notes, contains('old-pw-1'));

      // 第二条 URI 没丢。
      final url2 = github.customFields.where((f) => f.label == 'URL 2');
      expect(url2, hasLength(1));
      expect(url2.single.value, 'https://gist.github.com');

      // 自定义字段类型：hidden 保留、boolean 保留、linked 降级为 text。
      final pin = github.customFields.firstWhere((f) => f.label == 'PIN');
      expect(pin.type, CustomFieldType.hidden);
      expect(pin.value, '4321');
      final toggle = github.customFields.firstWhere((f) => f.label == '启用');
      expect(toggle.type, CustomFieldType.boolean);
      final linked = github.customFields.firstWhere((f) => f.label == '关联字段');
      expect(linked.type, CustomFieldType.text);

      // 文件夹按 id 映射到名字对应的文件夹。
      expect(github.folderId, isNotNull);
    });

    test('安全笔记：备注里的换行原样保留', () async {
      await importer.importJson(sampleJson());
      final items = await repo.getItems();
      final note = items.firstWhere((i) => i.name == '保险箱密码');
      expect(note.type, EntryType.secureNote);
      expect(note.notes, '第一行\n第二行');
    });

    test('银行卡：降级为安全笔记，卡号等进隐藏自定义字段，且备注写明来源', () async {
      await importer.importJson(sampleJson());
      final items = await repo.getItems();
      final card = items.firstWhere((i) => i.name == '招行信用卡');

      expect(card.type, EntryType.secureNote,
          reason: 'EasyPass 没有卡片类型，降级但不能丢');
      expect(card.notes, contains('Bitwarden'),
          reason: '要写明这是导入降级的结果，否则用户以为类型弄错了');

      final number = card.customFields.firstWhere((f) => f.label == '卡号');
      expect(number.value, '4111111111111111');
      expect(number.type, CustomFieldType.hidden,
          reason: '卡号与安全码应当按隐藏字段存');
      final code = card.customFields.firstWhere((f) => f.label == '安全码');
      expect(code.type, CustomFieldType.hidden);
      expect(card.customFields.any((f) => f.label == '持卡人'), isTrue);
      expect(card.customFields.any((f) => f.label == '卡组织'), isTrue);
    });

    test('身份：映射到 IdentityData，未映射的字段落到自定义字段', () async {
      await importer.importJson(sampleJson());
      final items = await repo.getItems();
      final identity = items.firstWhere((i) => i.name == '我的身份');

      expect(identity.type, EntryType.identity);
      final data = identity.identityOrEmpty;
      expect(data.title, '先生');
      expect(data.firstName, '三');
      expect(data.lastName, '张');
      expect(data.email, 'zhangsan@example.com');
      expect(data.idNumber, '110101199001011234', reason: 'ssn → idNumber');
      expect(data.passportNumber, 'E12345678');
      expect(data.city, '北京');
      expect(data.country, '中国');
      expect(data.birthday, '1990-01-01');

      final extra =
          identity.customFields.firstWhere((f) => f.label == '身份.someExtraField');
      expect(extra.value, '别丢了我');
    });

    test('文件夹：按名字建一次，两条同文件夹的条目不重复建', () async {
      final report = await importer.importJson(sampleJson());
      expect(report.folders, 2);

      final folders = await repo.getFolders();
      expect(folders.map((f) => f.name).toSet(), {'工作', '个人'});

      final items = await repo.getItems();
      final github = items.firstWhere((i) => i.name == 'GitHub');
      final identity = items.firstWhere((i) => i.name == '我的身份');
      expect(github.folderId, identity.folderId,
          reason: '同一个 Bitwarden 文件夹下的条目应当落到同一个 EasyPass 文件夹');
    });

    test('重复导入同一份文件：文件夹复用、条目不合并（追加语义）', () async {
      await importer.importJson(sampleJson());
      final second = await importer.importJson(sampleJson());

      expect(second.folders, 0, reason: '同名文件夹不该再建一遍');
      final folders = await repo.getFolders();
      expect(folders, hasLength(2));

      final items = await repo.getItems();
      expect(items, hasLength(8), reason: '重复导入是追加，不是覆盖');
    });

    test('加密的 Bitwarden 导出：明确报错并指引重新导出', () async {
      final encrypted = jsonEncode({
        'encrypted': true,
        'passwordProtected': false,
        'salt': 'x',
        'data': 'base64...',
      });

      expect(
        () => importer.importJson(encrypted),
        throwsA(isA<ImportException>().having(
          (e) => e.message,
          'message',
          contains('未加密'),
        )),
      );
    });

    test('不是 Bitwarden 导出：抛可读错误', () async {
      expect(
        () => importer.importJson('{"foo": 1}'),
        throwsA(isA<ImportException>()),
      );
      expect(
        () => importer.importJson('not json at all'),
        throwsA(isA<ImportException>()),
      );
      expect(
        () => importer.importJson('[]'),
        throwsA(isA<ImportException>()),
      );
    });
  });

  group('CSV 导入', () {
    String sampleCsv() => [
          'folder,favorite,type,name,notes,fields,reprompt,'
              'login_uri,login_username,login_password,login_totp',
          '工作,1,login,GitHub,"备注, 带逗号",PIN: 4321,0,'
              'https://github.com,alice,"p@ss,word",JBSWY3DPEHPK3PXP',
          ',0,note,纯笔记,"多行\n备注",,0,,,,',
          ',0,card,我的卡,,卡号: 4111111111111111,0,,,,',
          '个人,0,identity,身份,,,,,,,',
        ].join('\r\n');

    test('解析列并写入对应类型', () async {
      final report = await importer.importCsv(sampleCsv());

      expect(report.entries, 4);
      expect(report.skipped, isEmpty);
      expect(report.cardsAsNotes, 1);

      final items = await repo.getItems();

      final github = items.firstWhere((i) => i.name == 'GitHub');
      expect(github.type, EntryType.login);
      expect(github.loginOrEmpty.url, 'https://github.com');
      expect(github.loginOrEmpty.username, 'alice');
      expect(github.loginOrEmpty.password, 'p@ss,word',
          reason: '引号里的逗号不能被当成分隔符');
      expect(github.notes, '备注, 带逗号');
      expect(github.isFavorite, isTrue);
      expect(github.customFields.single.label, 'PIN');
      expect(github.customFields.single.value, '4321');

      final note = items.firstWhere((i) => i.name == '纯笔记');
      expect(note.type, EntryType.secureNote);
      expect(note.notes, '多行\n备注', reason: '引号内的换行属于同一个字段');

      final card = items.firstWhere((i) => i.name == '我的卡');
      expect(card.type, EntryType.secureNote);

      final identity = items.firstWhere((i) => i.name == '身份');
      expect(identity.type, EntryType.identity);
    });

    test('CSV 文件夹按名字建，且同名的只建一次', () async {
      await importer.importCsv(sampleCsv());
      final folders = await repo.getFolders();
      expect(folders.map((f) => f.name).toSet(), {'工作', '个人'});
    });

    test('未知类型与空行不会中断导入', () async {
      final csv = [
        'folder,favorite,type,name,notes,fields,reprompt,'
            'login_uri,login_username,login_password,login_totp',
        ',0,wat,奇怪类型,,,0,,,,',
        ',,, ,,,0,,,,',
        ',0,login,正常,,,0,https://a.example,u,p,',
      ].join('\n');

      final report = await importer.importCsv(csv);
      expect(report.entries, 1);
      expect(report.skipped, hasLength(1));
      expect(report.skipped.single, contains('奇怪类型'));
    });

    test('缺关键列的 CSV：抛可读错误', () async {
      expect(
        () => importer.importCsv('a,b,c\n1,2,3'),
        throwsA(isA<ImportException>().having(
          (e) => e.message,
          'message',
          contains('type'),
        )),
      );
    });
  });

  group('CSV 解析器本身（RFC 4180 边界）', () {
    test('引号转义、引号内逗号与换行、BOM', () {
      final rows = BitwardenImporter.parseCsv(
        '\uFEFFa,b\r\n"x,y","he said ""hi"""\r\n"multi\nline",z\r\n',
      );
      expect(rows, hasLength(3));
      expect(rows[0], ['a', 'b']);
      expect(rows[1], ['x,y', 'he said "hi"']);
      expect(rows[2], ['multi\nline', 'z']);
    });

    test('结尾无换行也能读出最后一行；空字段保留', () {
      final rows = BitwardenImporter.parseCsv('a,,c\n1,2');
      expect(rows, [
        ['a', '', 'c'],
        ['1', '2'],
      ]);
    });

    test('空输入返回空表', () {
      expect(BitwardenImporter.parseCsv(''), isEmpty);
    });
  });

  group('格式嗅探', () {
    test('认得出 Bitwarden JSON / CSV，且不抢 EasyPass 自己的导出', () {
      expect(BitwardenImporter.detectFormat(sampleJson()),
          ImportFormat.bitwardenJson);
      expect(
        BitwardenImporter.detectFormat(
          'folder,favorite,type,name,notes,fields,reprompt,'
          'login_uri,login_username,login_password,login_totp\n',
        ),
        ImportFormat.bitwardenCsv,
      );

      // EasyPass 自己的导出必须让位（带 app/format 字段）。
      expect(
        BitwardenImporter.detectFormat(
          '{"version":"2.0.0","app":"EasyPass","format":"plain","entries":[]}',
        ),
        isNull,
      );
      expect(BitwardenImporter.detectFormat(''), isNull);
      expect(BitwardenImporter.detectFormat('{ broken'), isNull);
      expect(BitwardenImporter.detectFormat('a,b,c\n1,2,3'), isNull);
    });
  });

  group('Bitwarden 兼容导出 + 往返', () {
    late ExportImportService exporter;

    setUp(() {
      exporter = ExportImportService(
        db,
        () => crypto.deriveKey('master', 'c2FsdA=='),
        repository: repo,
        cryptoService: crypto,
      );
    });

    /// 造一份四种类型齐全的 EasyPass 库。
    Future<void> seedVault() async {
      await repo.addFolder(FoldersCompanion.insert(
        id: 'folder-1',
        name: '工作',
        createdAt: 0,
        updatedAt: 0,
      ));

      await repo.saveItem(VaultItem(
        id: 'e-login',
        folderId: 'folder-1',
        type: EntryType.login,
        name: 'GitHub',
        notes: '备注',
        isFavorite: true,
        login: const LoginData(
          url: 'https://github.com',
          username: 'alice',
          password: 'pw',
          totpSecret: 'JBSWY3DPEHPK3PXP',
        ),
        customFields: const [
          CustomField(label: 'PIN', value: '4321', type: CustomFieldType.hidden),
          CustomField(label: '启用', value: 'true', type: CustomFieldType.boolean),
        ],
        createdAt: 0,
        updatedAt: 0,
      ));

      await repo.saveItem(VaultItem(
        id: 'e-note',
        type: EntryType.secureNote,
        name: '笔记',
        notes: '正文',
        createdAt: 0,
        updatedAt: 0,
      ));

      await repo.saveItem(VaultItem(
        id: 'e-id',
        type: EntryType.identity,
        name: '身份',
        identity: const IdentityData(
          firstName: '三',
          lastName: '张',
          email: 'z@example.com',
          idNumber: '110101199001011234',
          city: '北京',
        ),
        createdAt: 0,
        updatedAt: 0,
      ));

      await repo.saveItem(VaultItem(
        id: 'e-ssh',
        type: EntryType.sshKey,
        name: '服务器密钥',
        sshKey: const SshKeyData(
          publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@host',
          privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END...',
          fingerprint: 'SHA256:abcdef',
          keyType: 'ssh-ed25519',
          comment: 'test@host',
        ),
        createdAt: 0,
        updatedAt: 0,
      ));
    }

    test('导出形状符合 Bitwarden 契约（type 编号 / fields / uris）', () async {
      await seedVault();
      final json = await exporter.exportBitwardenJson();
      final root = jsonDecode(json) as Map<String, dynamic>;

      expect(root['encrypted'], isFalse);
      expect((root['folders'] as List).single['name'], '工作');

      final items = root['items'] as List;
      expect(items, hasLength(4));

      final login = items.firstWhere((i) => i['name'] == 'GitHub');
      expect(login['type'], 1, reason: '登录 = Bitwarden type 1');
      expect(login['favorite'], isTrue);
      expect(login['folderId'], 'folder-1');
      expect(login['login']['username'], 'alice');
      expect(login['login']['password'], 'pw');
      expect(login['login']['totp'], 'JBSWY3DPEHPK3PXP');
      expect((login['login']['uris'] as List).single['uri'], 'https://github.com');

      // 自定义字段类型编号：hidden=1、boolean=2。
      final fields = login['fields'] as List;
      expect(fields.firstWhere((f) => f['name'] == 'PIN')['type'], 1);
      expect(fields.firstWhere((f) => f['name'] == '启用')['type'], 2);

      final note = items.firstWhere((i) => i['name'] == '笔记');
      expect(note['type'], 2);
      expect(note['secureNote'], isNotNull);

      final identity = items.firstWhere((i) => i['name'] == '身份');
      expect(identity['type'], 4);
      expect(identity['identity']['ssn'], '110101199001011234');
      expect(identity['identity']['city'], '北京');

      final ssh = items.firstWhere((i) => i['name'] == '服务器密钥');
      expect(ssh['type'], 2, reason: 'Bitwarden 没有 SSH 类型，降级成安全笔记');
      expect(ssh['notes'], contains('Bitwarden 没有 SSH 密钥类型'));
      final sshFieldNames =
          (ssh['fields'] as List).map((f) => f['name']).toList();
      expect(sshFieldNames, contains('SSH 私钥'));
      expect(sshFieldNames, contains('SSH 公钥'));
    });

    test('往返：EasyPass → Bitwarden JSON → 重新导入，关键字段不丢', () async {
      await seedVault();
      final exported = await exporter.exportBitwardenJson();

      // 清库重来，模拟"导出后换一台机器导入"。
      await db.transaction(() async {
        for (final row in await db.getAllEntries()) {
          await db.deleteEntry(row.id);
        }
        for (final folder in await db.getAllFolders()) {
          await db.deleteFolder(folder.id);
        }
      });

      final report = await importer.importJson(exported);
      // SSH 会被降级成笔记，所以导入后类型分布是 1 登录 / 2 笔记 / 1 身份。
      expect(report.entries, 4);
      expect(report.skipped, isEmpty);
      expect(report.cardsAsNotes, 0);

      final items = await repo.getItems();

      final login = items.firstWhere((i) => i.name == 'GitHub');
      expect(login.type, EntryType.login);
      expect(login.loginOrEmpty.username, 'alice');
      expect(login.loginOrEmpty.password, 'pw');
      expect(login.loginOrEmpty.totpSecret, 'JBSWY3DPEHPK3PXP');
      expect(login.loginOrEmpty.url, 'https://github.com');
      expect(login.isFavorite, isTrue);
      expect(login.notes, '备注');
      expect(
        login.customFields.firstWhere((f) => f.label == 'PIN').type,
        CustomFieldType.hidden,
      );
      expect(
        login.customFields.firstWhere((f) => f.label == '启用').type,
        CustomFieldType.boolean,
      );
      expect(login.folderId, isNotNull, reason: '文件夹归属应当保住');

      final identity = items.firstWhere((i) => i.name == '身份');
      expect(identity.type, EntryType.identity);
      expect(identity.identityOrEmpty.firstName, '三');
      expect(identity.identityOrEmpty.idNumber, '110101199001011234');

      // SSH 的材料必须以自定义字段形式存活（类型丢了，但数据没丢）。
      final sshNote = items.firstWhere((i) => i.name == '服务器密钥');
      expect(sshNote.type, EntryType.secureNote);
      final values = sshNote.customFields.map((f) => f.value).join('\n');
      expect(values, contains('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI'));
      expect(values, contains('BEGIN OPENSSH PRIVATE KEY'));
      expect(values, contains('SHA256:abcdef'));
    });
  });
}
