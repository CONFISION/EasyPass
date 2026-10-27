import 'dart:convert';
import 'dart:io';

import 'package:easypass/mcp/mcp_handler.dart';
import 'package:easypass/mcp/mcp_http_server.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真 socket 集成：只验证"字节真的走通了 + 规则在 HTTP 层也生效"。
/// 规则本身在 `mcp_handler_test.dart` 里逐条覆盖。
void main() {
  const goodKey = 'k-1';
  late McpHttpServer server;
  late HttpClient client;
  late int port;

  setUp(() async {
    final handler = McpHandler(
      authenticate: (key) async => key == goodKey
          ? const McpPrincipal(pairingId: 'p1', nickname: 'DSH（工作机）')
          : null,
      callTool: (p, tool, args) async => {'ok': true},
    );
    server = McpHttpServer(handler: handler);
    port = await server.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
  });

  Future<HttpClientResponse> send({
    String method = 'POST',
    String? origin,
    String? authorization = 'Bearer $goodKey',
    String body = '{"jsonrpc":"2.0","id":1,"method":"ping"}',
  }) async {
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port${McpHandler.endpointPath}'),
    );
    req.headers.contentType = ContentType.json;
    if (authorization != null) req.headers.set('authorization', authorization);
    if (origin != null) req.headers.set('origin', origin);
    if (method == 'POST') req.write(body);
    return req.close();
  }

  test('只绑回环：端口非 0，正常请求 200', () async {
    expect(port, greaterThan(0));
    final res = await send();
    final text = await utf8.decoder.bind(res).join();
    expect(res.statusCode, 200);
    expect(jsonDecode(text)['jsonrpc'], '2.0');
  });

  test('响应里没有任何 CORS 头、也不暴露 Server 头（R4）', () async {
    final res = await send();
    await res.drain<void>();
    final headerNames = <String>[];
    res.headers.forEach((name, values) => headerNames.add(name.toLowerCase()));
    for (final name in headerNames) {
      expect(name.startsWith('access-control-'), isFalse, reason: '不该出现 $name');
    }
    expect(res.headers.value('server'), isNull);
  });

  test('带 Origin ⇒ 403（真实 HTTP 解析后仍然生效）', () async {
    final res = await send(origin: 'https://evil.example');
    await res.drain<void>();
    expect(res.statusCode, 403);
  });

  test('GET ⇒ 405', () async {
    final res = await send(method: 'GET');
    await res.drain<void>();
    expect(res.statusCode, 405);
  });

  test('没有 Bearer ⇒ 401', () async {
    final res = await send(authorization: null);
    await res.drain<void>();
    expect(res.statusCode, 401);
  });

  test('tools/list 走完整链路能拿到 5 个工具', () async {
    final res = await send(
      body: '{"jsonrpc":"2.0","id":2,"method":"tools/list"}',
    );
    final body = await utf8.decoder.bind(res).join();
    expect(res.statusCode, 200);
    final tools = (jsonDecode(body)['result'] as Map)['tools'] as List;
    expect(tools.length, 5);
  });

  test('stop 后端口不再接受连接', () async {
    await server.stop();
    await expectLater(
      client
          .openUrl('POST', Uri.parse('http://127.0.0.1:$port/mcp'))
          .then((r) => r.close()),
      throwsA(anything),
    );
  });
}
