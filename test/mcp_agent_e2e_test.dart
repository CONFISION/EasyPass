import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/core/storage/secret_store.dart';
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

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    crypto = CryptoService(secureStorage: InMemorySecretStore());
    sessions = SessionDomains(idleTimeout: const Duration(minutes: 5));
    final key = Uint8List.fromList(List<int>.filled(32, 9));
    sessions.agent.unlock(key);

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

    actions = AgentActions(
      repository: repository,
      sessions: sessions,
      pairingStore: pairingStore,
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
    expect(((listed['result'] as Map)['tools'] as List).length, 5);
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

  test('方式 1（逐次审批）在阶段 1 fail closed：读也被拒', () async {
    final payload = await callToolPayload(approvalKey, 'list_entries');
    expect(payload['errorCode'], 'denied');

    final status = await callToolPayload(approvalKey, 'status');
    expect(status['mode'], 'approval');
  });

  test('end_session 立即锁 agent 域，之后读操作报 locked', () async {
    await callToolPayload(trustedKey, 'end_session');
    expect(sessions.agent.isUnlocked, isFalse);

    final payload = await callToolPayload(trustedKey, 'list_entries');
    expect(payload['errorCode'], 'locked');
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
}
