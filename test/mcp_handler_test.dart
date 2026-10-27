import 'dart:convert';

import 'package:easypass/mcp/mcp_handler.dart';
import 'package:easypass/mcp/mcp_tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// MCP 的规则层（反 DNS rebinding R1/R2、认证 R5/R8、JSON-RPC 语义）。
///
/// 这些规则全部用普通单测覆盖，不必起真服务器 —— 起 socket 的那一层在
/// `mcp_http_server_test.dart` 里只验证"字节真的走通了"。
void main() {
  const goodKey = 'good-key';
  const principal = McpPrincipal(pairingId: 'p1', nickname: 'DSH（工作机）');
  const port = 50123;

  late List<String> called;
  late bool failNext;
  late McpHandler handler;

  setUp(() {
    called = [];
    failNext = false;
    handler = McpHandler(
      authenticate: (key) async => key == goodKey ? principal : null,
      callTool: (p, tool, args) async {
        called.add('$tool@${p.nickname}');
        if (failNext) {
          throw McpToolException('locked', '保险库已锁定');
        }
        if (tool == 'get_entry') {
          return {'id': args['id'], 'name': 'GitHub'};
        }
        if (tool == 'list_entries') {
          return {'entries': <Object?>[]};
        }
        return {'ok': true};
      },
    );
  });

  Map<String, String> headers({
    String host = '127.0.0.1:$port',
    String? authorization = 'Bearer $goodKey',
    String? origin,
  }) =>
      {
        'host': host,
        'authorization': ?authorization,
        'origin': ?origin,
      };

  Future<McpHttpResponse> post(
    Map<String, Object?> message, {
    Map<String, String>? extraHeaders,
    String bodyOverride = '',
  }) {
    final h = extraHeaders ?? headers();
    return handler.handle(
      method: 'POST',
      path: McpHandler.endpointPath,
      headers: h,
      body: bodyOverride.isNotEmpty ? bodyOverride : jsonEncode(message),
      localPort: port,
    );
  }

  group('R1/R2：反 DNS rebinding', () {
    test('带 Origin 的请求一律 403', () {
      return expectLater(
        post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
            extraHeaders: headers(origin: 'https://evil.example')),
        completion(predicate<McpHttpResponse>((r) => r.status == 403)),
      );
    });

    test('Host 不是回环地址 ⇒ 403', () {
      return expectLater(
        post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
            extraHeaders: headers(host: 'evil.example:$port')),
        completion(predicate<McpHttpResponse>((r) => r.status == 403)),
      );
    });

    test('localhost 与 127.0.0.1 都接受（端口必须一致）', () async {
      expect(
        (await post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
                extraHeaders: headers(host: 'localhost:$port')))
            .status,
        200,
      );
      expect(
        (await post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
                extraHeaders: headers(host: '127.0.0.1:${port + 1}')))
            .status,
        403,
      );
    });
  });

  group('R5/R8：只接受 header 里的 Bearer', () {
    test('没有 Authorization ⇒ 401', () async {
      expect(
        (await post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
                extraHeaders: headers(authorization: null)))
            .status,
        401,
      );
    });

    test('不是 Bearer 形态 ⇒ 401', () async {
      expect(
        (await post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
                extraHeaders: headers(authorization: 'Basic abc')))
            .status,
        401,
      );
    });

    test('密钥不对（已撤销/未配对）⇒ 401', () async {
      expect(
        (await post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
                extraHeaders: headers(authorization: 'Bearer wrong')))
            .status,
        401,
      );
    });

    test('accept 大小写与首尾空白（客户端常把换行一起粘过来）', () async {
      final r = await post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
          extraHeaders: headers(authorization: '  bearer   $goodKey  '));
      expect(r.status, 200);
    });

    test('query string 里的密钥不被接受（只认 header）', () async {
      final r = await handler.handle(
        method: 'POST',
        path: '${McpHandler.endpointPath}?token=$goodKey',
        headers: headers(authorization: null),
        body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
        localPort: port,
      );
      // 路径不匹配 ⇒ 404（单端点，不接受带查询串的变体）；无论如何不会放行。
      expect(r.status, isNot(200));
    });
  });

  group('传输形态', () {
    test('GET ⇒ 405（不提供 SSE）', () async {
      final r = await handler.handle(
        method: 'GET',
        path: McpHandler.endpointPath,
        headers: headers(),
        body: '',
        localPort: port,
      );
      expect(r.status, 405);
    });

    test('非端点路径 ⇒ 404', () async {
      final r = await handler.handle(
        method: 'POST',
        path: '/other',
        headers: headers(),
        body: '{}',
        localPort: port,
      );
      expect(r.status, 404);
    });

    test('请求体超上限 ⇒ 413', () async {
      final big = 'x' * (handler.maxBodyBytes + 10);
      final r = await handler.handle(
        method: 'POST',
        path: McpHandler.endpointPath,
        headers: headers(),
        body: big,
        localPort: port,
      );
      expect(r.status, 413);
    });
  });

  group('JSON-RPC：initialize / 通知 / 错误', () {
    test('initialize 回能力表与协商后的协议版本', () async {
      final r = await post({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': '2025-06-18', 'capabilities': {}},
      });
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      expect(body['jsonrpc'], '2.0');
      expect(body['id'], 1);
      final result = body['result'] as Map<String, dynamic>;
      expect(result['protocolVersion'], '2025-06-18');
      expect((result['capabilities'] as Map)['tools'], isNotNull);
      expect(result['serverInfo'], isNotNull);
    });

    test('客户端要更新的修订版 ⇒ 回我们能实现的版本（让它自己回退）', () async {
      final r = await post({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': '2026-07-28'},
      });
      final result = jsonDecode(r.body)['result'] as Map<String, dynamic>;
      expect(result['protocolVersion'], McpHandler.preferredProtocolVersion);
      expect(McpHandler.supportedProtocolVersions, contains(result['protocolVersion']));
    });

    test('通知（无 id）⇒ 202 且无 body', () async {
      final r = await post({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
      expect(r.status, 202);
      expect(r.body, isEmpty);
    });

    test('坏 JSON ⇒ 400 parse error', () async {
      final r = await post({}, bodyOverride: '{oops');
      expect(r.status, 400);
      expect(jsonDecode(r.body)['error']['code'], McpErrorCodes.parseError);
    });

    test('缺 method ⇒ 400', () async {
      final r = await post({'jsonrpc': '2.0', 'id': 1});
      expect(r.status, 400);
      expect(jsonDecode(r.body)['error']['code'], McpErrorCodes.invalidRequest);
    });

    test('未知方法 ⇒ methodNotFound', () async {
      final r = await post({'jsonrpc': '2.0', 'id': 7, 'method': 'resources/list'});
      expect(jsonDecode(r.body)['error']['code'], McpErrorCodes.methodNotFound);
    });
  });

  group('工具面', () {
    test('tools/list 返回 6 个工具，且都带 annotations', () async {
      final r = await post({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'});
      final tools = (jsonDecode(r.body)['result'] as Map)['tools'] as List;
      expect(tools.length, 6);
      expect(agentToolNames, {
        'status',
        'begin_session',
        'end_session',
        'list_entries',
        'get_entry',
        'copy_to_clipboard',
      });
      for (final tool in tools.cast<Map>()) {
        expect(tool['annotations'], isNotNull);
        expect(tool['inputSchema'], isNotNull);
      }
    });

    test('tools/call 正常：结果是 text 内容 + isError=false', () async {
      final r = await post({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {
          'name': 'get_entry',
          'arguments': {'id': 'e1'},
        },
      });
      final result = jsonDecode(r.body)['result'] as Map<String, dynamic>;
      expect(result['isError'], isFalse);
      final text = (result['content'] as List).first['text'] as String;
      expect(jsonDecode(text)['id'], 'e1');
      expect(called, ['get_entry@DSH（工作机）']);
    });

    test('未知工具 ⇒ 协议错误 invalidParams', () async {
      final r = await post({
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/call',
        'params': {'name': 'unlock'},
      });
      expect(jsonDecode(r.body)['error']['code'], McpErrorCodes.invalidParams);
    });

    test('执行错误 ⇒ isError=true 且带 errorCode（不是协议错误）', () async {
      failNext = true;
      final r = await post({
        'jsonrpc': '2.0',
        'id': 5,
        'method': 'tools/call',
        'params': {'name': 'status'},
      });
      final result = jsonDecode(r.body)['result'] as Map<String, dynamic>;
      expect(result['isError'], isTrue);
      final payload = jsonDecode((result['content'] as List).first['text'] as String);
      expect(payload['errorCode'], 'locked');
    });
  });
}
