import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mcp_handler.dart';

/// MCP 的 HTTP 壳：**只做 socket 层面的读、写、超时与并发控制**，所有规则在
/// [McpHandler] 里。
///
/// 绑定纪律（R3）：只绑 `127.0.0.1`，绝不 `0.0.0.0`。固定端口由调用方传入
/// （被占用时由核心决定不启动，本类不做端口回退）。
///
/// 请求处理顺序（M1 修复的核心）：**先做"只看请求头"的预检与认证，再读 body**。
/// 未认证请求不能让我们读满 256 KB，也不能长期占住连接（slowloris 的另一半由
/// body 读取超时兜住）。
class McpHttpServer {
  McpHttpServer({
    required this.handler,
    this.maxConcurrentRequests = 16,
    this.bodyReadTimeout = const Duration(seconds: 15),
    this.requestTimeout = const Duration(seconds: 90),
  })  : assert(maxConcurrentRequests > 0, '并发上限必须为正'),
        assert(bodyReadTimeout > Duration.zero, 'body 超时必须为正'),
        assert(requestTimeout > Duration.zero, '请求超时必须为正');

  final McpHandler handler;

  /// 同时处理的请求上限；超出的**不排队**（排队会变成内存放大器），直接回 503。
  final int maxConcurrentRequests;

  /// 单个请求读 body 的超时；超时回 408 并关闭连接。
  ///
  /// 15s 足够传完 256 KB JSON，又能挡住"先发头再慢速滴字节"的慢连接。
  final Duration bodyReadTimeout;

  /// 整个请求（认证 + 读 body + 工具执行/审批等待）的超时。
  ///
  /// 必须大于审批超时（45s），90s 覆盖一次完整的"弹窗 → 用户点同意"链路。
  final Duration requestTimeout;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _sub;
  int _activeRequests = 0;

  int get port => _server?.port ?? 0;

  bool get isRunning => _server != null;

  /// 当前正在处理的请求数（诊断与测试用；不含空闲 keep-alive 连接）。
  int get activeRequests => _activeRequests;

  /// 启动并返回实际端口（`port: 0` = 临时端口，仅测试使用；生产传固定端口）。
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
    // 并发上限：超出的请求不读 body、不认证，直接 503（无 body）。
    if (_activeRequests >= maxConcurrentRequests) {
      try {
        _discardRequestBody(request);
        await _respond(
          request,
          const _ServerReply(McpHttpResponse(503), closeConnection: true),
        );
      } catch (_) {
        // 连接已断。
      }
      return;
    }

    _activeRequests++;
    try {
      _ServerReply reply;
      try {
        reply = await _process(request).timeout(requestTimeout);
      } on TimeoutException {
        // 90s 都没结束：回 504 并断开，避免同一个请求无限占着槽位。
        handler.notifyRejected(504, 'request_timeout');
        _discardRequestBody(request);
        reply = const _ServerReply(McpHttpResponse(504), closeConnection: true);
      }
      await _respond(request, reply);
    } catch (_) {
      // 单个请求失败不该让服务倒下。
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } catch (_) {
        // 连接已断。
      }
    } finally {
      _activeRequests--;
    }
  }

  /// 预检 → 认证 → 读 body → 已认证处理。**不写响应**，只算出响应。
  Future<_ServerReply> _process(HttpRequest request) async {
    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(',');
    });

    // ① 路径 / Origin / Host / 方法 / Bearer 头格式：全部只看头，先拒绝。
    final rejection = handler.preflight(
      method: request.method,
      path: request.uri.path,
      headers: headers,
      localPort: port,
    );
    if (rejection != null) {
      _discardRequestBody(request);
      return _ServerReply(rejection, closeConnection: true);
    }

    final key = handler.bearerFromHeaders(headers);
    if (key == null) {
      // preflight 已保证格式正确，这里是防御性兜底。
      handler.notifyRejected(401, 'authorization');
      _discardRequestBody(request);
      return const _ServerReply(McpHttpResponse(401), closeConnection: true);
    }

    // ② 认证也在读 body 之前：拿错密钥的请求不应该让我们读 256 KB。
    final principal = await handler.authenticate(key);
    if (principal == null) {
      handler.notifyRejected(401, 'unknown_pairing');
      _discardRequestBody(request);
      return const _ServerReply(McpHttpResponse(401), closeConnection: true);
    }

    // ③ 最后才读 body，且带超时。超时就回 408 并关闭连接。
    final bodyFuture = _readBody(request);
    String? body;
    try {
      body = await bodyFuture.timeout(bodyReadTimeout);
    } on TimeoutException {
      // 已经放弃这次读取，不能再 await 它（否则请求会再挂很久）；
      // 挂一个 onError 是为了连接关闭时不要产生未处理的异步异常。
      unawaited(bodyFuture.then<void>((_) {}, onError: (Object _) {}));
      handler.notifyRejected(408, 'body_timeout');
      return const _ServerReply(McpHttpResponse(408), closeConnection: true);
    }
    if (body == null) {
      // 超过 256 KB（Content-Length 直接拒 / chunked 边读边计）。
      handler.notifyRejected(413, 'body_too_large');
      _discardRequestBody(request);
      return const _ServerReply(McpHttpResponse(413), closeConnection: true);
    }

    final response = await handler.handleAuthenticated(
      principal: principal,
      body: body,
    );
    return _ServerReply(response);
  }

  /// 读掉并丢弃请求体（不缓冲、不等待完整读完）。
  ///
  /// 为什么需要它：Dart 的 `HttpResponse.close()` 在写响应头前，若发现请求体
  /// 还没有订阅者，会**先把整个请求体 drain 完再发响应**（`writeHeaders` 的
  /// `drainRequest` 逻辑）。拒绝路径如果不订阅请求体，一个"声明 1 MB 但一个
  /// 字节都不发"的客户端就能把响应和连接一起挂住 —— 这比 slowloris 更省事。
  /// 这里主动挂一个消费者，让 SDK 认为"有人读 body"，响应立刻能发出；拒绝
  /// 响应一律 close，连接销毁后这次 drain 也随之结束。
  void _discardRequestBody(HttpRequest request) {
    try {
      unawaited(
        request.drain<void>().then<void>((_) {}, onError: (Object _) {}),
      );
    } catch (_) {
      // 已经有消费者（正常 body 读取中）：不需要、也不能再 listen 一次。
    }
  }

  Future<void> _respond(HttpRequest request, _ServerReply reply) async {
    final response = request.response;
    if (reply.closeConnection) response.persistentConnection = false;
    response.statusCode = reply.response.status;
    if (reply.response.isJson) {
      response.headers.contentType = ContentType.json;
      response.write(reply.response.body);
    }
    await response.close();
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

/// `_process` 的返回值：响应本体 + 是否要在这条连接上顺便关闭。
class _ServerReply {
  const _ServerReply(this.response, {this.closeConnection = false});

  final McpHttpResponse response;
  final bool closeConnection;
}
