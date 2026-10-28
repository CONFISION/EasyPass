import 'dart:convert';

import 'package:easypass/mcp/mcp_handler.dart';
import 'package:easypass/mcp/mcp_tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// MCP 的规则层（反 DNS rebinding R1/R2、认证 R5/R8、JSON-RPC 语义、
/// "预检/认证先于读 body"的缝、以及工具面 v3 的 schema/annotations 契约）。
///
/// 这些规则全部用普通单测覆盖，不必起真服务器 —— 起 socket 的那一层在
/// `mcp_http_server_test.dart` 里验证字节与反滥用行为。
void main() {
  const goodKey = 'good-key';
  const principal = McpPrincipal(pairingId: 'p1', nickname: 'DSH（工作机）');
  const port = 50123;

  late List<String> called;
  late bool failNext;
  late int authenticateCalls;
  late List<(int, String)> rejections;
  late McpHandler handler;

  setUp(() {
    called = [];
    failNext = false;
    authenticateCalls = 0;
    rejections = [];
    handler = McpHandler(
      authenticate: (key) async {
        authenticateCalls++;
        return key == goodKey ? principal : null;
      },
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
      onRejected: (status, reason) => rejections.add((status, reason)),
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

  /// 直接调预检（不认证、不读 body）。
  McpHttpResponse? preflight({
    String method = 'POST',
    String path = McpHandler.endpointPath,
    Map<String, String>? extraHeaders,
    int localPort = port,
  }) {
    return handler.preflight(
      method: method,
      path: path,
      headers: extraHeaders ?? headers(),
      localPort: localPort,
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

  group('preflight：只看请求头就能拒绝（不认证、不读 body）', () {
    test('合法请求返回 null，且没有拒绝回调', () {
      expect(preflight(), isNull);
      expect(rejections, isEmpty);
      expect(authenticateCalls, 0);
    });

    test('非端点路径 ⇒ 404', () {
      final r = preflight(path: '/other');
      expect(r?.status, 404);
      expect(rejections, contains((404, 'path')));
    });

    test('任何 Origin（含空值/同源）⇒ 403', () {
      for (final origin in const ['https://evil.example', '', 'http://127.0.0.1:47821']) {
        rejections.clear();
        final r = preflight(extraHeaders: headers(origin: origin));
        expect(r?.status, 403, reason: origin);
        expect(rejections, contains((403, 'origin')));
      }
    });

    test('Host 非回环 / 端口不符 / 多值 / 缺失 ⇒ 403', () {
      for (final host in <String>[
        'evil.example:$port',
        '127.0.0.1:${port + 1}',
        '127.0.0.1:$port,evil.example:$port',
      ]) {
        rejections.clear();
        final r = preflight(extraHeaders: headers(host: host));
        expect(r?.status, 403, reason: host);
        expect(rejections, contains((403, 'host')));
      }
      rejections.clear();
      final missingHost = handler.preflight(
        method: 'POST',
        path: McpHandler.endpointPath,
        headers: {'authorization': 'Bearer $goodKey'},
        localPort: port,
      );
      expect(missingHost?.status, 403);
      expect(rejections, contains((403, 'host')));
    });

    test('非 POST ⇒ 405，且拒绝也要留痕', () {
      for (final method in const ['GET', 'HEAD', 'OPTIONS', 'DELETE', 'PUT']) {
        rejections.clear();
        final r = preflight(method: method);
        expect(r?.status, 405, reason: method);
        expect(r?.body, isEmpty);
        expect(rejections, contains((405, 'method')));
      }
    });

    test('缺 Bearer / 空 Bearer / 非 Bearer 形态 ⇒ 401', () {
      for (final auth in <String?>[null, 'Basic abc', 'Bearer', 'Bearer   ']) {
        rejections.clear();
        final r = preflight(extraHeaders: headers(authorization: auth));
        expect(r?.status, 401, reason: '$auth');
        expect(rejections, contains((401, 'authorization')));
      }
    });

    test('预检失败不会触发认证，也不会执行工具', () async {
      final r = await handler.handle(
        method: 'POST',
        path: McpHandler.endpointPath,
        headers: headers(origin: 'https://evil.example'),
        body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
        localPort: port,
      );
      expect(r.status, 403);
      expect(authenticateCalls, 0);
      expect(called, isEmpty);
    });
  });

  group('bearerFromHeaders', () {
    test('只认 header 里的 Bearer：大小写不敏感、trim 首尾空白', () {
      expect(handler.bearerFromHeaders({'authorization': 'Bearer $goodKey'}), goodKey);
      expect(handler.bearerFromHeaders({'authorization': 'bearer $goodKey'}), goodKey);
      expect(handler.bearerFromHeaders({'authorization': '  BEARER   $goodKey  '}), goodKey);
      expect(handler.bearerFromHeaders({'authorization': 'Basic abc'}), isNull);
      expect(handler.bearerFromHeaders({'authorization': 'Bearer'}), isNull);
      expect(handler.bearerFromHeaders(const {}), isNull);
    });
  });

  group('onRejected：HTTP 层拒绝都要留痕（供核心写审计）', () {
    test('预检拒绝（Origin）', () async {
      final r = await post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
          extraHeaders: headers(origin: 'https://evil.example'));
      expect(r.status, 403);
      expect(rejections, contains((403, 'origin')));
      expect(called, isEmpty);
      expect(authenticateCalls, 0);
    });

    test('认证拒绝（错误密钥）', () async {
      final r = await post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
          extraHeaders: headers(authorization: 'Bearer wrong'));
      expect(r.status, 401);
      expect(rejections, contains((401, 'unknown_pairing')));
      expect(called, isEmpty);
    });

    test('body 超限', () async {
      final big = 'x' * (handler.maxBodyBytes + 10);
      final r = await post({}, bodyOverride: big);
      expect(r.status, 413);
      expect(rejections, contains((413, 'body_too_large')));
      expect(called, isEmpty);
    });

    test('成功请求不触发拒绝回调', () async {
      final r = await post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'});
      expect(r.status, 200);
      expect(rejections, isEmpty);
    });
  });

  group('handleAuthenticated：已认证后的纯逻辑入口', () {
    test('正常 ping 返回 200', () async {
      final r = await handler.handleAuthenticated(
        principal: principal,
        body: '{"jsonrpc":"2.0","id":9,"method":"ping"}',
      );
      expect(r.status, 200);
      expect(jsonDecode(r.body)['id'], 9);
    });

    test('body 超限仍然拒绝（纵深防御）', () async {
      final big = 'x' * (handler.maxBodyBytes + 10);
      final r = await handler.handleAuthenticated(principal: principal, body: big);
      expect(r.status, 413);
      expect(rejections, contains((413, 'body_too_large')));
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
    test('initialize 回能力表、协商后的协议版本与工具面版本', () async {
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
      final serverInfo = result['serverInfo'] as Map<String, dynamic>;
      expect(serverInfo['name'], isNotEmpty);
      expect(serverInfo['version'], isNotEmpty);
      // 工具面版本必须能被客户端/审计对上（surface v3）。
      expect(serverInfo['surfaceVersion'], agentToolSurfaceVersion);
      expect(serverInfo['surfaceVersion'], '3');
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
    test('tools/list 返回 11 个工具，且都带 annotations', () async {
      final r = await post({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'});
      final tools = (jsonDecode(r.body)['result'] as Map)['tools'] as List;
      expect(tools.length, 11);
      expect(agentToolNames, {
        'status',
        'begin_session',
        'end_session',
        'list_entries',
        'get_entry',
        'create_entry',
        'update_entry',
        'delete_entry',
        'list_trash',
        'restore_entry',
        'copy_to_clipboard',
      });
      final byName = {
        for (final tool in tools.cast<Map>()) tool['name'] as String: tool,
      };
      for (final tool in tools.cast<Map>()) {
        expect(tool['annotations'], isNotNull);
        expect(tool['inputSchema'], isNotNull);
      }
      // annotations 是给客户端审批层看的：写/删必须显式标出来。
      Map<String, Object?> annotationsOf(String name) =>
          byName[name]!['annotations'] as Map<String, Object?>;
      expect(annotationsOf('list_entries')['readOnlyHint'], isTrue);
      expect(annotationsOf('list_trash')['readOnlyHint'], isTrue);
      expect(annotationsOf('get_entry')['readOnlyHint'], isTrue);
      expect(annotationsOf('status')['readOnlyHint'], isTrue);
      expect(annotationsOf('create_entry')['readOnlyHint'], isFalse);
      expect(annotationsOf('update_entry')['readOnlyHint'], isFalse);
      expect(annotationsOf('restore_entry')['readOnlyHint'], isFalse);
      expect(annotationsOf('delete_entry')['readOnlyHint'], isFalse);
      expect(annotationsOf('delete_entry')['destructiveHint'], isTrue);
      // 写/删工具的 schema 必须把"能不能凭空改别人的条目"钉死：id 必填。
      final deleteSchema = byName['delete_entry']!['inputSchema'] as Map;
      expect(deleteSchema['required'], ['id']);
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

  group('工具面 v3：schema / annotations 契约', () {
    Map<String, Map<String, dynamic>> toolsByName() => {
          for (final tool in agentTools)
            tool.name: Map<String, dynamic>.from(tool.toJson()),
        };

    test('工具面版本 = 3', () {
      expect(agentToolSurfaceVersion, '3');
    });

    test('begin_session / end_session 是写工具（readOnlyHint=false）', () {
      final byName = toolsByName();
      expect(byName['begin_session']!['annotations'], {
        'readOnlyHint': false,
        'destructiveHint': false,
      });
      expect(byName['end_session']!['annotations'], {
        'readOnlyHint': false,
        'destructiveHint': false,
      });
    });

    test('begin/end_session 描述不再承诺空闲豁免，且明确不参与授权/不锁会话域', () {
      final byName = toolsByName();
      final begin = byName['begin_session']!['description'] as String;
      final end = byName['end_session']!['description'] as String;
      expect(begin, contains('不参与授权'));
      expect(begin, isNot(contains('空闲锁定')));
      expect(end, contains('不锁定'));
    });

    test('create_entry / update_entry 的 password 声明 string 或生成对象', () {
      final byName = toolsByName();
      for (final name in const ['create_entry', 'update_entry']) {
        final schema = byName[name]!['inputSchema'] as Map;
        final password = (schema['properties'] as Map)['password'] as Map;
        final oneOf = password['oneOf'] as List;
        expect(oneOf, hasLength(2), reason: name);
        expect(oneOf[0], {'type': 'string'}, reason: name);
        final object = oneOf[1] as Map;
        expect(object['type'], 'object', reason: name);
        expect(object['required'], ['generate'], reason: name);
        final props = object['properties'] as Map;
        for (final field in const [
          'length',
          'useUpper',
          'useLower',
          'useNumbers',
          'useSymbols',
        ]) {
          expect(props.containsKey(field), isTrue, reason: '$name 缺少参数 $field');
        }
        expect(props['length'], containsPair('type', 'integer'), reason: name);
      }
    });

    test('copy_to_clipboard 不再暴露 identity/SSH 专属字段', () {
      final byName = toolsByName();
      final schema = byName['copy_to_clipboard']!['inputSchema'] as Map;
      final field = (schema['properties'] as Map)['field'] as Map;
      final values = (field['enum'] as List).cast<String>();
      expect(values, containsAll(['password', 'totp', 'notes', 'custom']));
      expect(values, isNot(contains('private_key')));
      expect(values, isNot(contains('passphrase')));
    });
  });
}
