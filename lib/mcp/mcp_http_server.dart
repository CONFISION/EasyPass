import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mcp_handler.dart';

/// MCP 的 HTTP 壳：**只做 socket 读写**，所有规则在 [McpHandler] 里。
///
/// 绑定纪律（R3）：只绑 `127.0.0.1`，绝不 `0.0.0.0`。端口默认取临时端口，
/// 由调用方写进 `daemon.json` 的 `mcpPort`，客户端从那里发现（R9）。
class McpHttpServer {
  McpHttpServer({required this.handler});

  final McpHandler handler;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _sub;

  int get port => _server?.port ?? 0;

  bool get isRunning => _server != null;

  /// 启动并返回实际端口（`port: 0` = 临时端口）。
  Future<int> start({int port = 0}) async {
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
      shared: false,
    );
    _server = server;
    // 不暴露实现细节；也**绝不**注册任何 CORS 头（R4）。
    server.serverHeader = null;
    server.autoCompress = false;
    _sub = server.listen(_onRequest, onError: (Object _) {});
    return server.port;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _onRequest(HttpRequest request) async {
    try {
      final body = await _readBody(request);
      if (body == null) {
        request.response.statusCode = 413;
        await request.response.close();
        return;
      }

      final headers = <String, String>{};
      request.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(',');
      });

      final result = await handler.handle(
        method: request.method,
        path: request.uri.path,
        headers: headers,
        body: body,
        localPort: port,
      );

      final response = request.response;
      response.statusCode = result.status;
      if (result.isJson) {
        response.headers.contentType = ContentType.json;
        response.write(result.body);
      }
      await response.close();
    } catch (_) {
      // 单个请求失败不该让服务倒下。
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } catch (_) {
        // 连接已断。
      }
    }
  }

  /// 读请求体；超过上限返回 `null`（调用方回 413）。
  ///
  /// 两条路径都要管：给了 `Content-Length` 的直接拒绝；chunked 的一边读一边计。
  Future<String?> _readBody(HttpRequest request) async {
    final limit = handler.maxBodyBytes;
    final declared = request.contentLength;
    if (declared > limit) return null;

    final chunks = <int>[];
    var total = 0;
    await for (final chunk in request) {
      total += chunk.length;
      if (total > limit) return null;
      chunks.addAll(chunk);
    }
    return utf8.decode(chunks, allowMalformed: true);
  }
}
