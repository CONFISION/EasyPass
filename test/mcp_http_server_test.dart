import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easypass/mcp/mcp_handler.dart';
import 'package:easypass/mcp/mcp_http_server.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真 socket 集成：验证字节真的走通、规则在 HTTP 层生效，以及反滥用行为
/// （先校验后读 body / body 超时 / 并发上限 / 整请求超时）。
/// 规则本体在 `mcp_handler_test.dart` 里逐条覆盖。
void main() {
  const goodKey = 'k-1';
  const principal = McpPrincipal(pairingId: 'p1', nickname: 'DSH（工作机）');

  late List<(int, String)> rejections;

  setUp(() {
    rejections = [];
  });

  McpHandler buildHandler({
    Future<Map<String, Object?>> Function(
      McpPrincipal principal,
      String tool,
      Map<String, Object?> args,
    )? callTool,
  }) {
    return McpHandler(
      authenticate: (key) async => key == goodKey ? principal : null,
      callTool: callTool ?? (p, tool, args) async => {'ok': true},
      onRejected: (status, reason) => rejections.add((status, reason)),
    );
  }

  /// 发一段原始 HTTP 请求并读到连接关闭（请求里带 `Connection: close`）。
  Future<(int, String)> rawRequest({
    required int port,
    required String request,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final chunks = <int>[];
    final done = Completer<void>();
    socket.listen(
      (List<int> data) => chunks.addAll(data),
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object _) {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    socket.add(utf8.encode(request));
    await socket.flush();
    try {
      await done.future.timeout(timeout);
    } finally {
      socket.destroy();
    }
    final text = utf8.decode(chunks, allowMalformed: true);
    final match = RegExp(r'^HTTP/1\.[01] (\d{3})').firstMatch(text);
    return (match == null ? -1 : int.parse(match.group(1)!), text);
  }

  Future<void> waitFor(
    bool Function() predicate, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!predicate()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('等待条件超时');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  group('HTTP 壳：真实 socket', () {
    late McpHttpServer server;
    late HttpClient client;
    late int port;

    setUp(() async {
      server = McpHttpServer(handler: buildHandler());
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
      expect(rejections, isEmpty, reason: '正常请求不应触发拒绝审计');
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

    test('tools/list 走完整链路能拿到 11 个工具', () async {
      final res = await send(
        body: '{"jsonrpc":"2.0","id":2,"method":"tools/list"}',
      );
      final body = await utf8.decoder.bind(res).join();
      expect(res.statusCode, 200);
      final tools = (jsonDecode(body)['result'] as Map)['tools'] as List;
      expect(tools.length, 11);
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

    test('带 Origin 的请求在读 body 之前就 403（不会先等 1MB body）', () async {
      final (status, _) = await rawRequest(
        port: port,
        request: 'POST /mcp HTTP/1.1\r\n'
            'Host: 127.0.0.1:$port\r\n'
            'Origin: https://evil.example\r\n'
            'Authorization: Bearer $goodKey\r\n'
            'Content-Type: application/json\r\n'
            'Content-Length: 1048576\r\n'
            'Connection: close\r\n'
            '\r\n',
        timeout: const Duration(seconds: 3),
      );
      expect(status, 403);
      expect(rejections, contains((403, 'origin')));
    });

    test('Host 不对的请求在读 body 之前就 403', () async {
      final (status, _) = await rawRequest(
        port: port,
        request: 'POST /mcp HTTP/1.1\r\n'
            'Host: evil.example:$port\r\n'
            'Authorization: Bearer $goodKey\r\n'
            'Content-Type: application/json\r\n'
            'Content-Length: 1048576\r\n'
            'Connection: close\r\n'
            '\r\n',
        timeout: const Duration(seconds: 3),
      );
      expect(status, 403);
      expect(rejections, contains((403, 'host')));
    });

    test('没有 Bearer 的请求在读 body 之前就 401', () async {
      final (status, _) = await rawRequest(
        port: port,
        request: 'POST /mcp HTTP/1.1\r\n'
            'Host: 127.0.0.1:$port\r\n'
            'Content-Type: application/json\r\n'
            'Content-Length: 1048576\r\n'
            'Connection: close\r\n'
            '\r\n',
        timeout: const Duration(seconds: 3),
      );
      expect(status, 401);
      expect(rejections, contains((401, 'authorization')));
    });

    test('密钥错误的请求在读 body 之前就 401（认证先于 body）', () async {
      final (status, _) = await rawRequest(
        port: port,
        request: 'POST /mcp HTTP/1.1\r\n'
            'Host: 127.0.0.1:$port\r\n'
            'Authorization: Bearer wrong-key\r\n'
            'Content-Type: application/json\r\n'
            'Content-Length: 1048576\r\n'
            'Connection: close\r\n'
            '\r\n',
        timeout: const Duration(seconds: 3),
      );
      expect(status, 401);
      expect(rejections, contains((401, 'unknown_pairing')));
    });

    test('Content-Length 超过 256KB ⇒ 413，且不读 body', () async {
      final (status, _) = await rawRequest(
        port: port,
        request: 'POST /mcp HTTP/1.1\r\n'
            'Host: 127.0.0.1:$port\r\n'
            'Authorization: Bearer $goodKey\r\n'
            'Content-Type: application/json\r\n'
            'Content-Length: ${256 * 1024 + 1}\r\n'
            'Connection: close\r\n'
            '\r\n',
        timeout: const Duration(seconds: 3),
      );
      expect(status, 413);
      expect(rejections, contains((413, 'body_too_large')));
    });
  });

  group('HTTP 壳：反滥用超时与并发（参数可注入）', () {
    test('默认参数符合设计契约：body 15s / 请求 90s / 并发 16', () {
      final server = McpHttpServer(handler: buildHandler());
      expect(server.bodyReadTimeout, const Duration(seconds: 15));
      expect(server.requestTimeout, const Duration(seconds: 90));
      expect(server.maxConcurrentRequests, 16);
    });

    test('body 读取超时 ⇒ 408 并关闭连接', () async {
      final server = McpHttpServer(
        handler: buildHandler(),
        bodyReadTimeout: const Duration(milliseconds: 150),
      );
      final port = await server.start();
      try {
        final stopwatch = Stopwatch()..start();
        final (status, _) = await rawRequest(
          port: port,
          request: 'POST /mcp HTTP/1.1\r\n'
              'Host: 127.0.0.1:$port\r\n'
              'Authorization: Bearer $goodKey\r\n'
              'Content-Type: application/json\r\n'
              'Content-Length: 100\r\n'
              'Connection: close\r\n'
              '\r\n',
          timeout: const Duration(seconds: 5),
        );
        stopwatch.stop();
        expect(status, 408);
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
        expect(rejections, contains((408, 'body_timeout')));
      } finally {
        await server.stop();
      }
    });

    test('并发超过上限 ⇒ 503（不排队、不读 body）', () async {
      final server = McpHttpServer(
        handler: buildHandler(),
        maxConcurrentRequests: 1,
        bodyReadTimeout: const Duration(seconds: 5),
      );
      final port = await server.start();
      Socket? first;
      try {
        // 第一条：头合法、认证通过，然后停在等 body（占住唯一的槽位）。
        first = await Socket.connect(InternetAddress.loopbackIPv4, port);
        first.write('POST /mcp HTTP/1.1\r\n'
            'Host: 127.0.0.1:$port\r\n'
            'Authorization: Bearer $goodKey\r\n'
            'Content-Type: application/json\r\n'
            'Content-Length: 100\r\n'
            '\r\n');
        await first.flush();
        await waitFor(() => server.activeRequests == 1);

        final (status, _) = await rawRequest(
          port: port,
          request: 'POST /mcp HTTP/1.1\r\n'
              'Host: 127.0.0.1:$port\r\n'
              'Authorization: Bearer $goodKey\r\n'
              'Content-Type: application/json\r\n'
              'Content-Length: 2\r\n'
              'Connection: close\r\n'
              '\r\n{}',
        );
        expect(status, 503);
      } finally {
        first?.destroy();
        await server.stop();
      }
    });

    test('整请求超过 requestTimeout ⇒ 504 并关闭连接', () async {
      final hang = Completer<Map<String, Object?>>();
      final server = McpHttpServer(
        handler: buildHandler(callTool: (p, tool, args) => hang.future),
        requestTimeout: const Duration(milliseconds: 200),
        bodyReadTimeout: const Duration(seconds: 5),
      );
      final port = await server.start();
      try {
        final body = jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {'name': 'status'},
        });
        final (status, _) = await rawRequest(
          port: port,
          request: 'POST /mcp HTTP/1.1\r\n'
              'Host: 127.0.0.1:$port\r\n'
              'Authorization: Bearer $goodKey\r\n'
              'Content-Type: application/json\r\n'
              'Content-Length: ${utf8.encode(body).length}\r\n'
              'Connection: close\r\n'
              '\r\n$body',
        );
        expect(status, 504);
        expect(rejections, contains((504, 'request_timeout')));
      } finally {
        if (!hang.isCompleted) hang.complete(const {'ok': false});
        await server.stop();
      }
    });
  });
}
