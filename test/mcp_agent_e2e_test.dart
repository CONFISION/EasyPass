import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/core/storage/secret_store.dart';
import 'package:easypass/core/crypto/totp_service.dart';
import 'package:easypass/core_service/agent_access_store.dart';
import 'package:easypass/core_service/agent_access_policy.dart';
import 'package:easypass/core_service/agent_actions.dart';
import 'package:easypass/core_service/agent_pairing_store.dart';
import 'package:easypass/core_service/session_domains.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/mcp/mcp_handler.dart';
import 'package:easypass/mcp/mcp_http_server.dart';
import 'package:easypass/mcp/mcp_tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// 端到端：真 socket + 真仓储 + 真策略 + 真配对存储。
///
/// 覆盖阶段 1 能验证的全部链路：认证 → JSON-RPC → 工具 → 策略逐条过滤 → 元数据编码。
/// 阶段 1 还没有审批 UI，所以方式 1 的配对**只能拿到拒绝**（fail closed）——
/// 这条也在这里钉住，免得以后误以为它"能用但没提示"。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const trustedKey = 'k-trusted';
  const approvalKey = 'k-approval';
  const password = 'S3cr3t-P@ssw0rd';

  late AppDatabase db;
  late CryptoService crypto;
  late SessionDomains sessions;
  late VaultRepository repository;
  late AgentPairingStore pairingStore;
  late AgentActions actions;
  late McpHttpServer server;
  late HttpClient client;
  late int port;
  late File tempBlob;
  late List<String> clipboardWrites;
  late AgentAccessStore accessStore;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    crypto = CryptoService(secureStorage: InMemorySecretStore());
    sessions = SessionDomains(idleTimeout: const Duration(minutes: 5));
    final key = Uint8List.fromList(List<int>.filled(32, 9));
    sessions.agent.unlock(key);
    tempBlob = File('${Directory.systemTemp.path}'
        '\\easypass-e2e-agent-${DateTime.now().microsecondsSinceEpoch}.dpapi');
    accessStore = AgentAccessStore(db, blobFile: tempBlob);
    // 生产环境 MCP 只在总开关打开时监听；审批后的复核会读这个开关，
    // 所以集成测试必须把它打开（"总开关关闭"的用例自己再关掉）。
    await accessStore.setEnabled(true);

    repository = VaultRepository(
      db: db,
      cryptoService: crypto,
      keyReader: () => sessions.agent.key,
    );
    await repository.saveItem(VaultItem(
      id: 'e-open',
      type: EntryType.login,
      name: 'GitHub',
      agentOpen: true,
      login: const LoginData(
        url: 'https://github.com',
        username: 'alice',
        password: password,
      ),
      notes: '这条备注不能泄露',
      createdAt: 1,
      updatedAt: 2,
    ));
    await repository.saveItem(VaultItem(
      id: 'e-closed',
      type: EntryType.login,
      name: '银行',
      login: const LoginData(username: 'bob', password: 'other-secret'),
      createdAt: 1,
      updatedAt: 2,
    ));
    // 再放一条**不同类型**的开放条目：回归"不传 type 时不能默认成 login"。
    await repository.saveItem(VaultItem(
      id: 'e-note',
      type: EntryType.secureNote,
      name: 'API 密钥备忘',
      notes: 'note-body-must-not-leak',
      agentOpen: true,
      createdAt: 1,
      updatedAt: 2,
    ));

    pairingStore = AgentPairingStore(db);
    await pairingStore.save(AgentPairing(
      id: 'p-trusted',
      nickname: 'DSH（工作机）',
      mode: AgentMode.trusted,
      trusted: true,
      keyHash: AgentPairingStore.hashKey(trustedKey),
      createdAt: 1,
    ));
    await pairingStore.save(AgentPairing(
      id: 'p-approval',
      nickname: '谨慎模式',
      mode: AgentMode.approval,
      keyHash: AgentPairingStore.hashKey(approvalKey),
      createdAt: 1,
    ));

    clipboardWrites = <String>[];
    actions = AgentActions(
      repository: repository,
      sessions: sessions,
      pairingStore: pairingStore,
      agentAccess: accessStore,
      totpService: TotpService(),
      // 注入假剪贴板：并行跑测试时不要真的去抢系统剪贴板。
      clipboardWriter: (text) async {
        clipboardWrites.add(text);
        return true;
      },
      // 审计落库（与核心装配一致：写 agent_audit 表）。
      auditSink: (entry) => db.insertAgentAudit(
        at: entry.at,
        pairingId: entry.pairingId,
        nickname: entry.nickname,
        mode: entry.mode,
        tool: entry.tool,
        op: entry.op,
        entryId: entry.entryId,
        entryName: entry.entryName,
        decision: entry.decision,
      ),
    );
    final handler = McpHandler(
      authenticate: actions.authenticate,
      callTool: actions.callTool,
    );
    server = McpHttpServer(handler: handler);
    port = await server.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await db.close();
  });

  Future<Map<String, dynamic>> rpc(
    String key,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port${McpHandler.endpointPath}'),
    );
    request.headers.contentType = ContentType.json;
    request.headers.set('authorization', 'Bearer $key');
    request.write(jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': method,
      'params': params,
    }));
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// 取 `tools/call` 的载荷（成功与失败都解析成 Map）。
  Future<Map<String, dynamic>> callToolPayload(
    String key,
    String tool, [
    Map<String, Object?> args = const {},
  ]) async {
    final response = await rpc(key, 'tools/call', {'name': tool, 'arguments': args});
    final result = response['result'] as Map<String, dynamic>;
    final text = (result['content'] as List).first['text'] as String;
    return Map<String, dynamic>.from(jsonDecode(text) as Map);
  }

  test('initialize + tools/list 走真 socket', () async {
    final init = await rpc(trustedKey, 'initialize', {'protocolVersion': '2025-06-18'});
    expect((init['result'] as Map)['protocolVersion'], '2025-06-18');

    final listed = await rpc(trustedKey, 'tools/list');
    expect(((listed['result'] as Map)['tools'] as List).length, 11);
  });

  test('未配对 / 已撤销的密钥在 HTTP 层就被 401 挡住', () async {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port${McpHandler.endpointPath}'),
    );
    request.headers.set('authorization', 'Bearer nope');
    request.write('{"jsonrpc":"2.0","id":1,"method":"ping"}');
    expect((await request.close()).statusCode, 401);
  });

  test('list_entries：只返回"开放"的条目，且响应里没有任何秘密', () async {
    final payload = await callToolPayload(trustedKey, 'list_entries');
    final entries = (payload['entries'] as List).cast<Map>();
    // 两条开放（一条登录 + 一条笔记），一条未开放被过滤。
    expect(entries.length, 2);
    expect(entries.map((e) => e['name']), containsAll(['GitHub', 'API 密钥备忘']));

    final encoded = jsonEncode(payload);
    for (final secret in [
      password,
      '这条备注不能泄露',
      'other-secret',
      'note-body-must-not-leak',
    ]) {
      expect(encoded.contains(secret), isFalse, reason: '不得泄露 $secret');
    }
  });

  test('list_entries：不传 type 不能被当成 login（真机踩到的 bug）', () async {
    final all = await callToolPayload(trustedKey, 'list_entries');
    expect((all['entries'] as List).length, 2);

    final logins =
        await callToolPayload(trustedKey, 'list_entries', {'type': 'login'});
    expect((logins['entries'] as List).map((e) => e['type']), ['login']);

    final notes = await callToolPayload(
        trustedKey, 'list_entries', {'type': 'secure_note'});
    expect((notes['entries'] as List).map((e) => e['type']), ['secure_note']);
  });

  test('get_entry：开放条目可读；永久拒绝的条目被拒', () async {
    final open = await callToolPayload(trustedKey, 'get_entry', {'id': 'e-open'});
    expect(open['name'], 'GitHub');
    expect(open.containsKey('password'), isFalse);

    final closed = await callToolPayload(trustedKey, 'get_entry', {'id': 'e-closed'});
    expect(closed['errorCode'], 'denied');
  });

  test('copy_to_clipboard：只回 ok 与字段名，绝不回传明文（也不回长度）', () async {
    final payload = await callToolPayload(
      trustedKey,
      'copy_to_clipboard',
      {'id': 'e-open', 'field': 'password'},
    );

    expect(payload['ok'], isTrue);
    expect(payload['field'], 'password');
    // 长度也是可被用来缩小密码搜索空间的旁路（D10）：不回。
    expect(payload.containsKey('length'), isFalse);
    // 整个响应里不能出现密码本身。
    expect(jsonEncode(payload).contains(password), isFalse);
    // 值确实走到了剪贴板写入器（但不在响应里）。
    expect(clipboardWrites, [password]);
  });

  test('copy_to_clipboard：未开放条目被拒（开关是硬闸）', () async {
    final payload = await callToolPayload(
      trustedKey,
      'copy_to_clipboard',
      {'id': 'e-closed', 'field': 'password'},
    );
    expect(payload['errorCode'], 'denied');
  });

  test('copy_to_clipboard：未知字段 / 空值字段给出明确错误', () async {
    final unknown = await callToolPayload(
      trustedKey,
      'copy_to_clipboard',
      {'id': 'e-open', 'field': 'nope'},
    );
    expect(unknown['errorCode'], 'invalidRequest');

    final emptyTotp = await callToolPayload(
      trustedKey,
      'copy_to_clipboard',
      {'id': 'e-open', 'field': 'totp'},
    );
    expect(emptyTotp['errorCode'], 'notFound');
  });

  test('方式 1：没有审批通道时 fail closed（读也被拒）', () async {
    final payload = await callToolPayload(approvalKey, 'list_entries');
    expect(payload['errorCode'], 'denied');

    final status = await callToolPayload(approvalKey, 'status');
    expect(status['mode'], 'approval');
  });

  group('方式 1：审批弹窗链路', () {
    late List<Map<String, Object?>> requests;

    setUp(() {
      requests = [];
      actions.onApprovalRequested = (req) {
        requests.add(req);
        // 自动同意（下一帧再回应，避免在 sink 里同步重入）。
        scheduleMicrotask(() {
          actions.respondApproval(req['approvalId'] as String, true);
        });
      };
    });

    tearDown(() => actions.onApprovalRequested = null);

    test('用户同意后能读到数据；弹窗内容含昵称/工具/操作', () async {
      final payload = await callToolPayload(approvalKey, 'list_entries');
      expect((payload['entries'] as List).length, 2);

      expect(requests, isNotEmpty);
      expect(requests.first['nickname'], '谨慎模式');
      expect(requests.first['tool'], 'list_entries');
      expect(requests.first['op'], 'read');
      expect(requests.first['allowStanding'], isTrue);
    });

    test('用户拒绝 ⇒ denied，且不返回任何条目', () async {
      actions.onApprovalRequested = (req) {
        requests.add(req);
        scheduleMicrotask(() {
          actions.respondApproval(req['approvalId'] as String, false);
        });
      };

      final payload = await callToolPayload(approvalKey, 'list_entries');
      expect(payload['errorCode'], 'denied');
      expect(payload.containsKey('entries'), isFalse);
    });

    test('「本会话内允许读取」后不再弹窗', () async {
      actions.onApprovalRequested = (req) {
        requests.add(req);
        scheduleMicrotask(() {
          actions.respondApproval(
            req['approvalId'] as String,
            true,
            allowStandingRead: true,
          );
        });
      };

      await callToolPayload(approvalKey, 'list_entries');
      expect(requests.length, 1);

      await callToolPayload(approvalKey, 'list_entries');
      expect(requests.length, 1, reason: '免询问生效后不该再弹');

      final rows = await db.recentAgentAudit();
      expect(rows.any((r) => r.decision == 'allowed'), isTrue);
    });

    test('免询问**不覆盖**敏感读：copy_to_clipboard 仍要审批', () async {
      actions.onApprovalRequested = (req) {
        requests.add(req);
        scheduleMicrotask(() {
          actions.respondApproval(
            req['approvalId'] as String,
            true,
            allowStandingRead: true,
          );
        });
      };

      // 先用一次普通读拿到免询问。
      await callToolPayload(approvalKey, 'list_entries');
      final before = requests.length;

      // 敏感读必须再弹一次（且弹窗不允许勾免询问）。
      await callToolPayload(
        approvalKey,
        'copy_to_clipboard',
        {'id': 'e-open', 'field': 'password'},
      );
      expect(requests.length, before + 1);
      expect(requests.last['op'], 'sensitiveRead');
      expect(requests.last['allowStanding'], isFalse);
    });

    test('审批里的条目 id / 名称会传给弹窗（get_entry）', () async {
      await callToolPayload(approvalKey, 'get_entry', {'id': 'e-open'});
      expect(requests.last['entryId'], 'e-open');
      expect(requests.last['entryName'], 'GitHub');
    });

    test('agent 域锁定时：同意后借用 ui 的钥匙，调用结束立刻锁回', () async {
      // ui 域用同一把钥匙解锁（能解开本测试的条目密文）。
      final key = Uint8List.fromList(List<int>.filled(32, 9));
      sessions.ui.unlock(Uint8List.fromList(key));
      sessions.agent.lock();
      expect(sessions.agent.isUnlocked, isFalse);

      final payload = await callToolPayload(approvalKey, 'list_entries');

      expect((payload['entries'] as List).length, 2, reason: '当面同意后应当能读');
      expect(sessions.agent.isUnlocked, isFalse,
          reason: '逐次审批借来的钥匙必须立刻锁回去');
    });

    test('ui 也锁着 ⇒ 同意也拿不到钥匙（fail closed）', () async {
      sessions.ui.lock();
      sessions.agent.lock();

      final payload = await callToolPayload(approvalKey, 'list_entries');
      expect(payload['errorCode'], 'locked');
    });
  });

  /// 回归（真机实测）：`end_session` 曾经无条件锁 agent 域 —— 那等于智能体
  /// 调一次就把自己永久锁死（自动解封只在核心启动/开开关时发生），
  /// 与"总开关打开 = 零介入"直接矛盾。
  test('总开关打开时：end_session 只关窗口，不锁 agent 域', () async {
    await AgentAccessStore(db, blobFile: tempBlob).setEnabled(true);

    await callToolPayload(trustedKey, 'begin_session', {'purpose': '批量'});
    await callToolPayload(trustedKey, 'end_session');

    expect(sessions.agent.isUnlocked, isTrue, reason: '零介入语义：不该自锁');

    final payload = await callToolPayload(trustedKey, 'list_entries');
    // 仍然能读（窗口已关，但访问权还在）。
    expect((payload['entries'] as List).length, 2);
  });

  test('总开关关闭时：end_session 兜底锁掉 agent 域', () async {
    await accessStore.setEnabled(false);
    await callToolPayload(trustedKey, 'end_session');
    expect(sessions.agent.isUnlocked, isFalse);
  });

  test('status 在锁定时也能用，并如实报告 locked', () async {
    sessions.agent.lock();
    final status = await callToolPayload(trustedKey, 'status');
    expect(status['locked'], isTrue);
    expect(status['entryCount'], 0);
    expect(status['nickname'], 'DSH（工作机）');
  });

  test('begin_session 记录窗口，且 purpose 必填', () async {
    final window = await callToolPayload(
      trustedKey,
      'begin_session',
      {'purpose': '整理工作区条目', 'ttlSeconds': 60},
    );
    expect(window['windowId'], isNotNull);

    final missing = await callToolPayload(trustedKey, 'begin_session');
    expect(missing['errorCode'], 'invalidRequest');
  });

  test('审计只记昵称与操作，不记密钥与明文', () async {
    await callToolPayload(trustedKey, 'list_entries');
    final entries = actions.recentAudit;
    expect(entries, isNotEmpty);
    final json = jsonEncode([for (final e in entries) e.toJson()]);
    expect(json.contains(trustedKey), isFalse);
    expect(json.contains(password), isFalse);
    expect(json.contains('DSH（工作机）'), isTrue);
  });

  test('审计落库：调用后写进 agent_audit 表，且库里没有秘密', () async {
    await callToolPayload(trustedKey, 'list_entries');
    await callToolPayload(trustedKey, 'get_entry', {'id': 'e-open'});
    await callToolPayload(
      trustedKey,
      'copy_to_clipboard',
      {'id': 'e-open', 'field': 'password'},
    );
    // sink 是旁路异步写入，等它落库。
    await Future<void>.delayed(const Duration(milliseconds: 150));

    final rows = await db.recentAgentAudit();
    expect(rows, isNotEmpty, reason: '方式 2 承诺"每次访问都留日志"');

    final tools = rows.map((r) => r.tool).toSet();
    expect(tools,
        containsAll(['list_entries', 'get_entry', 'copy_to_clipboard']));
    expect(rows.every((r) => r.nickname == 'DSH（工作机）'), isTrue);
    expect(rows.every((r) => r.decision == 'allowed'), isTrue);
    // 剪贴板审计必须带字段名（M4：文档承诺"按条目与字段名审计"，但不记值）。
    expect(
      rows.firstWhere((r) => r.tool == 'copy_to_clipboard').op,
      'clipboard:password',
    );
    expect(await db.countAgentAudit(), greaterThanOrEqualTo(3));

    // 库里不能出现密钥或明文密码。
    final dump = rows
        .map((r) => '${r.nickname}|${r.tool}|${r.op}|${r.entryId}|${r.entryName}')
        .join('\n');
    expect(dump.contains(trustedKey), isFalse);
    expect(dump.contains(password), isFalse);
  });

  // ─── 写 / 删 / 回收站（3.1.0 阶段 2）────────────────────

  group('写 / 删 / 回收站', () {
    late List<Map<String, Object?>> requests;
    late bool approve;
    late Set<String> broadcastTopics;
    late int auditTicks;

    setUp(() {
      requests = <Map<String, Object?>>[];
      approve = true;
      broadcastTopics = <String>{};
      auditTicks = 0;
      actions.onDataChanged = broadcastTopics.addAll;
      actions.onAuditRecorded = () => auditTicks++;
      actions.onApprovalRequested = (req) {
        requests.add(req);
        scheduleMicrotask(() {
          actions.respondApproval(req['approvalId'] as String, approve);
        });
      };
    });

    tearDown(() {
      actions.onApprovalRequested = null;
      actions.onDataChanged = null;
      actions.onAuditRecorded = null;
    });

    test('create_entry：落库成功，且新条目默认对智能体开放（用户可收回）', () async {
      final created = await callToolPayload(trustedKey, 'create_entry', {
        'type': 'login',
        'name': '新建的条目',
        'url': 'https://example.com',
        'username': 'carol',
        'password': 'pw-from-agent',
        'notes': '备注',
      });
      final id = created['id'] as String;
      expect(id, isNotEmpty);

      final stored = await repository.getItem(id);
      expect(stored, isNotNull);
      expect(stored!.name, '新建的条目');
      // 产品决定（2026-10-28）：智能体自己建的条目默认对智能体开放，
      // 否则它建完就读不到/改不了/删不掉；用户仍可改成永久拒绝收回。
      expect(stored.agentOpen, isTrue, reason: '新建条目默认对智能体开放');
      expect(stored.loginOrEmpty.password, 'pw-from-agent');
      expect(stored.loginOrEmpty.url, 'https://example.com');

      // 对智能体自己可见：列表里有它，也能直接读。
      final list = await callToolPayload(trustedKey, 'list_entries');
      expect((list['entries'] as List).any((e) => e['id'] == id), isTrue);
      final read = await callToolPayload(trustedKey, 'get_entry', {'id': id});
      expect(read['name'], '新建的条目');
      expect(read.containsKey('password'), isFalse);

      // UI 实时刷新的前提：写库后必须广播数据变更主题。
      expect(broadcastTopics,
          containsAll(['items', 'item', 'folders', 'search']));
      expect(auditTicks, greaterThan(0), reason: '审计页靠这个实时刷新');
    });

    test('create_entry 的 generate 模式：核心生成并加密入库，明文不回传', () async {
      final created = await callToolPayload(trustedKey, 'create_entry', {
        'name': '生成的密码',
        'password': {'generate': true, 'length': 24},
      });
      expect(created.containsKey('password'), isFalse);

      final stored = await repository.getItem(created['id'] as String);
      final generated = stored!.loginOrEmpty.password;
      expect(generated.length, 24);
      expect(jsonEncode(created).contains(generated), isFalse,
          reason: '生成的密码只能进库，不能回给模型');
    });

    test('create_entry 拒绝 identity / ssh_key 与缺失 name', () async {
      final identity = await callToolPayload(
        trustedKey,
        'create_entry',
        {'name': 'x', 'type': 'identity'},
      );
      expect(identity['errorCode'], 'invalidRequest');

      final missing = await callToolPayload(trustedKey, 'create_entry', {});
      expect(missing['errorCode'], 'invalidRequest');
    });

    test('create_entry：secure_note 传 url/username/password 显式报错（不静默忽略）',
        () async {
      for (final key in ['url', 'username', 'password']) {
        final payload = await callToolPayload(
          trustedKey,
          'create_entry',
          {'name': '笔记', 'type': 'secure_note', key: 'x'},
        );
        expect(payload['errorCode'], 'invalidRequest', reason: key);
        expect('${payload['message']}', contains('login'), reason: key);
      }

      // 不带登录字段就正常创建；notes / customFields 仍可用。
      final ok = await callToolPayload(trustedKey, 'create_entry', {
        'name': '纯笔记',
        'type': 'secure_note',
        'notes': '正文',
      });
      expect(ok['type'], 'secure_note');
      expect(ok.containsKey('password'), isFalse);
      final stored = await repository.getItem(ok['id'] as String);
      expect(stored!.notes, '正文');
    });

    test('update_entry：对 secure_note 传 password 同样被拒（与 create 一致）', () async {
      final created = await callToolPayload(trustedKey, 'create_entry', {
        'name': '笔记2',
        'type': 'secure_note',
      });
      final denied = await callToolPayload(trustedKey, 'update_entry', {
        'id': created['id'],
        'password': 'x',
      });
      expect(denied['errorCode'], 'invalidRequest');
    });

    test('update_entry：只改传入字段，返回值只有字段名与结果', () async {
      final updated = await callToolPayload(trustedKey, 'update_entry', {
        'id': 'e-open',
        'username': 'alice2',
        'password': 'new-secret',
      });
      expect(updated['ok'], isTrue);
      expect(updated['updatedFields'], containsAll(['username', 'password']));
      expect(jsonEncode(updated).contains('new-secret'), isFalse,
          reason: '写进去的值不能回显给模型');

      final stored = await repository.getItem('e-open');
      expect(stored!.loginOrEmpty.username, 'alice2');
      expect(stored.loginOrEmpty.password, 'new-secret');
    });

    test('update_entry：folder 可设置 / 移出，不存在的 id 报错', () async {
      await repository.addFolder(FoldersCompanion.insert(
        id: 'f-work',
        name: '工作',
        createdAt: 1,
        updatedAt: 1,
      ));

      final set = await callToolPayload(
        trustedKey,
        'update_entry',
        {'id': 'e-open', 'folder': 'f-work'},
      );
      expect(set['updatedFields'], ['folder']);
      expect((await repository.getItem('e-open'))!.folderId, 'f-work');

      final clear = await callToolPayload(
        trustedKey,
        'update_entry',
        {'id': 'e-open', 'folder': null},
      );
      expect(clear['ok'], isTrue);
      expect((await repository.getItem('e-open'))!.folderId, isNull);

      final bad = await callToolPayload(
        trustedKey,
        'update_entry',
        {'id': 'e-open', 'folder': 'f-nope'},
      );
      expect(bad['errorCode'], 'invalidRequest');
    });

    test('update_entry：未开放条目被拒；回收站里的条目要求先恢复', () async {
      final closed = await callToolPayload(
        trustedKey,
        'update_entry',
        {'id': 'e-closed', 'name': '改名尝试'},
      );
      expect(closed['errorCode'], 'denied');

      await callToolPayload(trustedKey, 'delete_entry', {'id': 'e-open'});
      final trashed = await callToolPayload(
        trustedKey,
        'update_entry',
        {'id': 'e-open', 'name': '改名尝试'},
      );
      expect(trashed['errorCode'], 'invalidRequest');
    });

    test('delete_entry：软删进回收站，list_entries 看不到、list_trash 看得到', () async {
      final deleted =
          await callToolPayload(trustedKey, 'delete_entry', {'id': 'e-open'});
      expect(deleted['ok'], isTrue);
      expect(deleted['trashed'], isTrue);

      // UI 实时刷新：删除成功后必须广播数据变更主题。
      expect(broadcastTopics,
          containsAll(['items', 'item', 'folders', 'search']));

      final list = await callToolPayload(trustedKey, 'list_entries');
      expect((list['entries'] as List).any((e) => e['id'] == 'e-open'), isFalse);

      final trash = await callToolPayload(trustedKey, 'list_trash');
      final trashedEntries = (trash['entries'] as List).cast<Map>();
      expect(trashedEntries.map((e) => e['id']), contains('e-open'));
      expect(
        trashedEntries.firstWhere((e) => e['id'] == 'e-open')['deletedAt'],
        isNotNull,
      );

      // 行与密文都还在：删除只是打了一个 deleted_at。
      final raw = await db.getEntryById('e-open');
      expect(raw, isNotNull);
      expect(raw!.deletedAt, isNotNull);
      expect(await db.countTrashedEntries(), 1);
    });

    test('delete_entry 对「永久拒绝」条目同样被硬闸挡住（不会被删）', () async {
      final denied =
          await callToolPayload(trustedKey, 'delete_entry', {'id': 'e-closed'});
      expect(denied['errorCode'], 'denied');
      expect(await repository.getItem('e-closed'), isNotNull);
      expect(await db.countTrashedEntries(), 0);
    });

    test('restore_entry：从回收站恢复；不在回收站时报错', () async {
      final notTrashed =
          await callToolPayload(trustedKey, 'restore_entry', {'id': 'e-open'});
      expect(notTrashed['errorCode'], 'invalidRequest');

      await callToolPayload(trustedKey, 'delete_entry', {'id': 'e-open'});
      final restored =
          await callToolPayload(trustedKey, 'restore_entry', {'id': 'e-open'});
      expect(restored['ok'], isTrue);

      expect(await repository.getItem('e-open'), isNotNull);
      final list = await callToolPayload(trustedKey, 'list_entries');
      expect((list['entries'] as List).any((e) => e['id'] == 'e-open'), isTrue);
      expect(await db.countTrashedEntries(), 0);
    });

    test('智能体没有「彻底删除」能力：软删后行还在库里', () async {
      await callToolPayload(trustedKey, 'delete_entry', {'id': 'e-open'});
      expect((await db.getAllEntries()).length, 3);
      // 工具面里根本没有 permanently_delete / empty_trash。
      expect(agentToolNames, isNot(contains('permanently_delete_entry')));
      expect(agentToolNames, isNot(contains('empty_trash')));
    });

    test('方式 1：写 / 删 / 恢复都要逐次审批，免询问不覆盖写', () async {
      // 第一次普通读就勾上「本会话内允许读取」。
      actions.onApprovalRequested = (req) {
        requests.add(req);
        scheduleMicrotask(() {
          actions.respondApproval(
            req['approvalId'] as String,
            true,
            allowStandingRead: true,
          );
        });
      };
      await callToolPayload(approvalKey, 'list_entries');
      final before = requests.length;

      final created = await callToolPayload(
        approvalKey,
        'create_entry',
        {'name': '审批创建'},
      );
      expect(requests.length, before + 1, reason: '写操作不享受免询问');
      expect(requests.last['tool'], 'create_entry');
      expect(requests.last['op'], 'write');
      expect(requests.last['allowStanding'], isFalse);
      expect(requests.last['detail'], contains('新建'));

      // 新建的条目默认就对智能体开放，可以直接继续写/删。
      final itemId = created['id'] as String;

      final updated = await callToolPayload(
        approvalKey,
        'update_entry',
        {'id': itemId, 'name': '审批改名'},
      );
      expect(updated['updatedFields'], ['name']);
      expect(requests.last['op'], 'write');
      expect(requests.last['detail'], contains('标题'));

      final deleted = await callToolPayload(
        approvalKey,
        'delete_entry',
        {'id': itemId},
      );
      expect(deleted['trashed'], isTrue);
      expect(requests.last['op'], 'delete');
      expect(requests.last['detail'], contains('回收站'));

      final restored = await callToolPayload(
        approvalKey,
        'restore_entry',
        {'id': itemId},
      );
      expect(restored['restored'], isTrue);
      expect(requests.last['op'], 'write');
    });

    test('方式 1：拒绝写操作 ⇒ denied，库里没有任何变化', () async {
      approve = false;
      final denied = await callToolPayload(
        approvalKey,
        'create_entry',
        {'name': '不该创建'},
      );
      expect(denied['errorCode'], 'denied');
      expect(await repository.getItems(), hasLength(3));
    });

    test('方式 1：对「永久拒绝」条目的调用不弹审批，直接拒绝（硬闸预检）', () async {
      final before = requests.length;

      final read = await callToolPayload(
        approvalKey,
        'get_entry',
        {'id': 'e-closed'},
      );
      expect(read['errorCode'], 'denied');

      final updated = await callToolPayload(
        approvalKey,
        'update_entry',
        {'id': 'e-closed', 'name': '改名尝试'},
      );
      expect(updated['errorCode'], 'denied');

      final deleted = await callToolPayload(
        approvalKey,
        'delete_entry',
        {'id': 'e-closed'},
      );
      expect(deleted['errorCode'], 'denied');

      final copied = await callToolPayload(
        approvalKey,
        'copy_to_clipboard',
        {'id': 'e-closed'},
      );
      expect(copied['errorCode'], 'denied');

      expect(requests.length, before,
          reason: '条目未开放是硬闸：不该先弹审批、点同意后才拒绝（审批疲劳）');

      // 拒绝仍然留审计（一次调用一行），只是不打扰用户。
      final audit = await db.recentAgentAudit(limit: 20);
      final deniedTools = audit
          .where((row) => row.decision == 'denied')
          .map((row) => row.tool)
          .toSet();
      expect(
        deniedTools,
        containsAll(
            ['get_entry', 'update_entry', 'delete_entry', 'copy_to_clipboard']),
      );
    });

    test('status.entryCount = 开放条目数（方式 1 下不再恒为 0）', () async {
      final status = await callToolPayload(approvalKey, 'status');
      expect(status['mode'], 'approval');
      expect(status['locked'], isFalse);
      expect(status['entryCount'], 2,
          reason: '两条开放条目；status 不该被自己的审批语义算成 0');
    });

    test('审计：免询问放行记 allowed_standing，与"本次点了同意"可区分', () async {
      // 第一次：批准 + 勾「本会话内允许读取」；第二次：走免询问。
      actions.onApprovalRequested = (req) {
        requests.add(req);
        scheduleMicrotask(() {
          actions.respondApproval(
            req['approvalId'] as String,
            true,
            allowStandingRead: true,
          );
        });
      };
      await callToolPayload(approvalKey, 'list_entries');
      await callToolPayload(approvalKey, 'list_entries');
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final rows = await db.recentAgentAudit();
      final decisions = rows.map((r) => r.decision).toList();
      expect(decisions, contains('allowed'), reason: '第一次是当面同意');
      expect(decisions, contains('allowed_standing'), reason: '第二次是免询问放行');
    });

    test('审计：执行失败补一条 error，且一次调用只有一行', () async {
      await callToolPayload(trustedKey, 'get_entry', {'id': 'no-such-entry'});
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final rows = await db.recentAgentAudit();
      final failed = rows.where((r) => r.tool == 'get_entry').toList();
      expect(failed, hasLength(1));
      expect(failed.single.decision, 'error');
      expect(failed.single.entryId, 'no-such-entry');
    });

    test('审计：写 / 删成功也各记一行 allowed', () async {
      await callToolPayload(trustedKey, 'create_entry', {'name': '审计创建'});
      await callToolPayload(trustedKey, 'delete_entry', {'id': 'e-open'});
      await callToolPayload(trustedKey, 'restore_entry', {'id': 'e-open'});
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final rows = await db.recentAgentAudit();
      expect(
        rows.where((r) => r.tool == 'create_entry').single.decision,
        'allowed',
      );
      final deleteRow = rows.where((r) => r.tool == 'delete_entry').single;
      expect(deleteRow.decision, 'allowed');
      expect(deleteRow.op, 'delete');
      expect(rows.where((r) => r.tool == 'restore_entry').single.decision,
          'allowed');
    });
  });

  // ─── 评审修复回归（H3 / H5 / H9 的 HTTP 链路）────────────

  test('H3：agent 域锁定时单条目工具报 locked，不报 notFound、不弹审批', () async {
    var approvals = 0;
    actions.onApprovalRequested = (request) {
      approvals++;
      scheduleMicrotask(() {
        actions.respondApproval(request['approvalId'] as String, true);
      });
    };
    addTearDown(() => actions.onApprovalRequested = null);

    // 模拟「用户显式锁定智能体会话」：ui 可用、agent 域锁。
    final uiKey = Uint8List.fromList(List<int>.filled(32, 9));
    sessions.ui.unlock(Uint8List.fromList(uiKey));
    sessions.agent.lock();

    final locked =
        await callToolPayload(approvalKey, 'get_entry', {'id': 'e-open'});
    expect(locked['errorCode'], 'locked');
    expect(approvals, 0, reason: '锁定态弹审批也借不到钥匙，不该打扰用户');

    // 对照：list_entries 仍走审批 + 借 ui 钥匙（这是窗口期内的合法路径）。
    final listed = await callToolPayload(approvalKey, 'list_entries');
    expect(approvals, 1);
    expect((listed['entries'] as List), isNotEmpty);
    expect(sessions.agent.isUnlocked, isFalse, reason: '借来的钥匙用后必须锁回');
  });

  test('H5：identity / SSH 条目即使 agentOpen 也不能被读 / 复制 / 写', () async {
    await repository.saveItem(VaultItem(
      id: 'e-ssh',
      type: EntryType.sshKey,
      name: 'prod-key',
      agentOpen: true,
      sshKey: const SshKeyData(
        privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\nSECRET\n',
        passphrase: 'ssh-pass',
      ),
      createdAt: 1,
      updatedAt: 2,
    ));

    final read = await callToolPayload(trustedKey, 'get_entry', {'id': 'e-ssh'});
    expect(read['errorCode'], 'denied');

    final list = await callToolPayload(trustedKey, 'list_entries');
    expect((list['entries'] as List).any((e) => e['id'] == 'e-ssh'), isFalse);

    // 工具面已移除 private_key，服务端仍拒绝（纵深防御）。
    final copied = await callToolPayload(
      trustedKey,
      'copy_to_clipboard',
      {'id': 'e-ssh', 'field': 'private_key'},
    );
    expect(copied['errorCode'], 'invalidRequest');
    expect(clipboardWrites, isEmpty);

    final updated = await callToolPayload(
      trustedKey,
      'update_entry',
      {'id': 'e-ssh', 'name': '改名'},
    );
    expect(updated['errorCode'], 'denied', reason: '类型硬闸：identity/SSH 不可写');
  });

  test('H9：update 审批详细展示非秘密字段 old→new，密码只显示"已修改"', () async {
    late Map<String, Object?> captured;
    actions.onApprovalRequested = (request) {
      captured = request;
      scheduleMicrotask(() {
        actions.respondApproval(request['approvalId'] as String, false);
      });
    };
    addTearDown(() => actions.onApprovalRequested = null);

    final payload = await callToolPayload(approvalKey, 'update_entry', {
      'id': 'e-open',
      'url': 'https://evil.example',
      'password': 'new-secret-value',
    });
    expect(payload['errorCode'], 'denied');
    final detail = captured['detail'] as String;
    expect(detail, contains('https://evil.example'), reason: '必须能看到新 URL');
    expect(detail, contains('→'));
    expect(detail, isNot(contains('new-secret-value')),
        reason: '秘密值不能进审批弹窗');
    expect(detail, contains('密码：已修改（值不显示）'));
  });
}
