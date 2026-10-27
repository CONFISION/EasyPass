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

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    crypto = CryptoService(secureStorage: InMemorySecretStore());
    sessions = SessionDomains(idleTimeout: const Duration(minutes: 5));
    final key = Uint8List.fromList(List<int>.filled(32, 9));
    sessions.agent.unlock(key);
    tempBlob = File('${Directory.systemTemp.path}'
        '\\easypass-e2e-agent-${DateTime.now().microsecondsSinceEpoch}.dpapi');

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
      agentAccess: AgentAccessStore(db, blobFile: tempBlob),
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
    expect(((listed['result'] as Map)['tools'] as List).length, 6);
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

  test('copy_to_clipboard：只回 ok 与长度，绝不回传明文', () async {
    final payload = await callToolPayload(
      trustedKey,
      'copy_to_clipboard',
      {'id': 'e-open', 'field': 'password'},
    );

    expect(payload['ok'], isTrue);
    expect(payload['field'], 'password');
    expect(payload['length'], password.length);
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

  test('方式 1（逐次审批）在阶段 1 fail closed：读也被拒', () async {
    final payload = await callToolPayload(approvalKey, 'list_entries');
    expect(payload['errorCode'], 'denied');

    final status = await callToolPayload(approvalKey, 'status');
    expect(status['mode'], 'approval');
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
    expect(await db.countAgentAudit(), greaterThanOrEqualTo(3));

    // 库里不能出现密钥或明文密码。
    final dump = rows
        .map((r) => '${r.nickname}|${r.tool}|${r.op}|${r.entryId}|${r.entryName}')
        .join('\n');
    expect(dump.contains(trustedKey), isFalse);
    expect(dump.contains(password), isFalse);
  });
}
