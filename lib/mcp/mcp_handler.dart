import 'dart:convert';

import 'mcp_tools.dart';

/// 已认证的智能体身份。
class McpPrincipal {
  const McpPrincipal({required this.pairingId, required this.nickname});

  final String pairingId;

  /// 审计与错误信息里只用它（不暴露真实标识）。
  final String nickname;
}

/// 工具执行期错误（与 JSON-RPC 协议错误区分开）。
///
/// MCP 的约定：**协议错误**进 JSON-RPC 的 `error`，**工具执行错误**进 `result.isError`。
/// 客户端据此决定"是我的请求写错了"还是"工具那边失败了"。
class McpToolException implements Exception {
  McpToolException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'McpToolException($code): $message';
}

typedef McpAuthenticator = Future<McpPrincipal?> Function(String key);

typedef McpToolHandler = Future<Map<String, Object?>> Function(
  McpPrincipal principal,
  String tool,
  Map<String, Object?> arguments,
);

/// 一个 HTTP 响应（不含任何 CORS 头）。
class McpHttpResponse {
  const McpHttpResponse(this.status, {this.body = ''});

  final int status;
  final String body;

  bool get isJson => body.isNotEmpty;
}

/// MCP 的 HTTP 层与 JSON-RPC 层（**纯逻辑**，不做 socket）。
///
/// 规则编号对应 `docs/agent-mcp-spec.md` §5.4：
/// R1 拒绝任何带 `Origin` 的请求 · R2 校验 `Host` · R3（由 socket 层保证只绑 127.0.0.1）
/// R4 永不发 CORS 头 · R5 只认 `Authorization: Bearer`（**不接受 query 里的密钥**）
/// R6 请求体上限（**超时与并发上限在 [McpHttpServer]**）· R7 密钥比较常量时间
/// （在 authenticate 回调里）· R8 先 trim 首尾空白。
///
/// 为什么拆成 [preflight] / [bearerFromHeaders] / [handleAuthenticated]：
/// body 是**不可信且可能极慢**的输入。服务器必须在读 body 之前就完成所有
/// "只看请求头就能判断"的拒绝（路径/Origin/Host/方法/凭据格式）与认证；
/// 否则未认证请求就能让核心读满 256 KB、或长期占住连接（slowloris）。
/// 这三个方法就是"先校验、后读 body"的那条缝。
class McpHandler {
  McpHandler({
    required this.authenticate,
    required this.callTool,
    this.maxBodyBytes = 256 * 1024,
    this.serverName = 'easy pass',
    this.serverVersion = '3.1.0',
    this.onRejected,
  });

  final McpAuthenticator authenticate;
  final McpToolHandler callTool;
  final int maxBodyBytes;
  final String serverName;

  /// 由核心注入 `AppConstants.coreVersion`；默认值只用于单测/兼容构造。
  final String serverVersion;

  /// HTTP 层拒绝回调（预检 / 认证 / body 超限 / 超时）。
  ///
  /// 只报告**拒绝**，供核心写审计（HTTP 层拒绝也要留痕）。参数是 HTTP 状态码
  /// 与一个短原因串（不含凭据、不含请求头内容）。回调自己的异常由调用方吞掉：
  /// MCP 服务不能因为审计写失败而倒下。
  final void Function(int status, String reason)? onRejected;

  static const String endpointPath = '/mcp';

  /// 我们**实际实现**的协议修订版。
  ///
  /// 客户端请求别的版本时，按规范回这个（客户端自己决定是否继续）——
  /// DSH 的 SDK 会回退到受支持的旧修订，所以这条路径是正常路径，不是错误。
  static const Set<String> supportedProtocolVersions = {'2025-06-18'};
  static const String preferredProtocolVersion = '2025-06-18';

  /// 预检：path / Origin / Host / 方法 / Bearer 头格式。
  ///
  /// 返回 `null` = 可以继续（下一步交给调用方：认证 → 读 body）；
  /// 非 `null` = 直接把这个响应回给客户端，**不要读 body**。
  /// 所有拒绝都会触发 [onRejected]。
  McpHttpResponse? preflight({
    required String method,
    required String path,
    required Map<String, String> headers,
    required int localPort,
  }) {
    // ① 路径（单端点）。
    if (path != endpointPath) {
      return _rejected(
          404, 'path', McpErrorCodes.methodNotFound, 'Not found');
    }

    // R1：浏览器跨源请求必带 Origin；原生 MCP 客户端不带。
    // 直接拒绝比"校验白名单"更难写错，也顺带挡住 DNS rebinding 的绝大部分场景。
    if (headers.containsKey('origin')) {
      return _rejected(403, 'origin', McpErrorCodes.invalidRequest,
          'Origin header is not allowed');
    }

    // R2：Host 必须是回环地址本身（攻击者域名会出现在这里）。
    if (!_hostAllowed(headers['host'], localPort)) {
      return _rejected(403, 'host', McpErrorCodes.invalidRequest,
          'Unexpected Host header');
    }

    // 单端点只支持 POST；GET 走 405（规范允许不提供 SSE）。
    if (method != 'POST') {
      onRejected?.call(405, 'method');
      return const McpHttpResponse(405);
    }

    // R5：Bearer 必须来自 header，**不接受 query string**。
    if (bearerFromHeaders(headers) == null) {
      return _rejected(401, 'authorization', McpErrorCodes.invalidRequest,
          'Missing or malformed Authorization header');
    }
    return null;
  }

  /// 从请求头取 Bearer 密钥；缺失或格式不对返回 `null`。
  ///
  /// 单独暴露的原因：服务器要先做"头格式校验"再认证，认证之后才读 body。
  String? bearerFromHeaders(Map<String, String> headers) =>
      _bearer(headers['authorization']);

  /// 兼容入口：完整走一遍"预检 → 认证 → body 上限 → JSON-RPC"。
  ///
  /// 真实链路里服务器不用它（服务器自己 preflight → 认证 → 读 body → 再进
  /// [handleAuthenticated]）；保留给单测和"已经有完整 body"的调用方。
  Future<McpHttpResponse> handle({
    required String method,
    required String path,
    required Map<String, String> headers,
    required String body,
    required int localPort,
  }) async {
    final rejection =
        preflight(method: method, path: path, headers: headers, localPort: localPort);
    if (rejection != null) return rejection;

    // preflight 已保证 Bearer 格式正确；这里再取一次只是拿值。
    final key = bearerFromHeaders(headers);
    if (key == null) {
      return _rejected(401, 'authorization', McpErrorCodes.invalidRequest,
          'Missing or malformed Authorization header');
    }

    // **先认证再返回任何业务信息**；认证失败不区分"未知"与"已撤销"。
    final principal = await authenticate(key);
    if (principal == null) {
      return _rejected(401, 'unknown_pairing', McpErrorCodes.invalidRequest,
          'Unknown or revoked pairing');
    }

    return handleAuthenticated(principal: principal, body: body);
  }

  /// 已认证后的 JSON-RPC 处理。
  ///
  /// 调用前提：调用方已经验证过 Origin/Host/方法/凭据格式，并且
  /// [authenticate] 返回了非 null 的 principal。body 上限在这里再查一次
  /// （纵深防御；socket 层是按字节限的，这里按字符限恒不更宽松）。
  Future<McpHttpResponse> handleAuthenticated({
    required McpPrincipal principal,
    required String body,
  }) async {
    // R6：请求体上限（socket 层可能已经按字节拒绝过，这里是纯逻辑层的兜底）。
    if (body.length > maxBodyBytes) {
      return _rejected(413, 'body_too_large', McpErrorCodes.invalidRequest,
          'Request body too large');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return _json(400, _rpcError(null, McpErrorCodes.parseError, 'Parse error'));
    }
    if (decoded is! Map) {
      return _json(400, _rpcError(null, McpErrorCodes.invalidRequest,
          'Request must be a JSON object'));
    }
    final message = Map<String, Object?>.from(decoded);

    final rpcMethod = message['method'];
    if (rpcMethod is! String || rpcMethod.isEmpty) {
      return _json(400, _rpcError(message['id'], McpErrorCodes.invalidRequest,
          'Missing method'));
    }

    // 通知（没有 id）：按规范回 202 且没有 body，不返回结果。
    final isNotification = !message.containsKey('id');
    if (isNotification) {
      return const McpHttpResponse(202);
    }

    final id = message['id'];
    final params = message['params'];
    final paramsMap = params is Map ? Map<String, Object?>.from(params) : <String, Object?>{};

    try {
      switch (rpcMethod) {
        case 'initialize':
          return _json(200, _rpcResult(id, _initializeResult(paramsMap)));
        case 'ping':
          return _json(200, _rpcResult(id, const <String, Object?>{}));
        case 'tools/list':
          return _json(200, _rpcResult(id, {
            'tools': [for (final tool in agentTools) tool.toJson()],
          }));
        case 'tools/call':
          return _json(200, await _callTool(id, principal, paramsMap));
        default:
          return _json(404, _rpcError(id, McpErrorCodes.methodNotFound,
              'Method not found: $rpcMethod'));
      }
    } catch (_) {
      return _json(500, _rpcError(id, McpErrorCodes.internalError,
          'Internal error'));
    }
  }

  /// 供服务器在"已认证但 body 读失败/超时/过大"等场景补记审计。
  void notifyRejected(int status, String reason) => onRejected?.call(status, reason);

  Map<String, Object?> _initializeResult(Map<String, Object?> params) {
    final requested = params['protocolVersion'];
    final negotiated = requested is String &&
            supportedProtocolVersions.contains(requested)
        ? requested
        : preferredProtocolVersion;
    return {
      'protocolVersion': negotiated,
      'capabilities': {
        'tools': {'listChanged': false},
      },
      'serverInfo': {
        'name': serverName,
        'version': serverVersion,
        // 工具面版本让客户端/审计能对上"当时那套工具定义"，不靠客户端猜。
        'surfaceVersion': agentToolSurfaceVersion,
      },
      'instructions':
          'EasyPass 本地保险库。工具只返回条目元数据；只有用户显式标记为“开放”'
              '的条目可见，每个条目都可以被“永久拒绝”。',
    };
  }

  /// `tools/call`：**协议错误**（未知工具 / 参数不对）走 JSON-RPC error；
  /// **执行错误**（未解锁、条目拒绝…）走 `result.isError`，把 `errorCode` 放进文本里。
  Future<Map<String, Object?>> _callTool(
    Object? id,
    McpPrincipal principal,
    Map<String, Object?> params,
  ) async {
    final name = params['name'];
    if (name is! String || !agentToolNames.contains(name)) {
      return _rpcError(id, McpErrorCodes.invalidParams, 'Unknown tool: $name');
    }
    final rawArgs = params['arguments'];
    final args = rawArgs is Map
        ? Map<String, Object?>.from(rawArgs)
        : <String, Object?>{};

    try {
      final result = await callTool(principal, name, args);
      return _rpcResult(id, {
        'content': [
          {'type': 'text', 'text': jsonEncode(result)},
        ],
        'isError': false,
      });
    } on McpToolException catch (e) {
      return _rpcResult(id, {
        'content': [
          {'type': 'text', 'text': jsonEncode({'errorCode': e.code, 'message': e.message})},
        ],
        'isError': true,
      });
    } catch (e) {
      return _rpcResult(id, {
        'content': [
          {'type': 'text', 'text': jsonEncode({'errorCode': 'internal', 'message': '$e'})},
        ],
        'isError': true,
      });
    }
  }

  static bool _hostAllowed(String? host, int port) {
    if (host == null) return false;
    final normalized = host.trim().toLowerCase();
    return normalized == '127.0.0.1:$port' || normalized == 'localhost:$port';
  }

  /// R5 + R8：只认 `Bearer`，取出的密钥先 trim（客户端常把粘贴的换行一起发来）。
  static String? _bearer(String? header) {
    if (header == null) return null;
    final value = header.trim();
    if (value.length <= 7) return null;
    if (value.substring(0, 7).toLowerCase() != 'bearer ') return null;
    final key = value.substring(7).trim();
    return key.isEmpty ? null : key;
  }

  /// 拒绝响应：先通知审计回调，再回 JSON-RPC 错误。
  McpHttpResponse _rejected(int status, String reason, int code, String message) {
    notifyRejected(status, reason);
    return _json(status, _rpcError(null, code, message));
  }

  static McpHttpResponse _json(int status, Map<String, Object?> body) =>
      McpHttpResponse(status, body: jsonEncode(body));

  static Map<String, Object?> _rpcResult(Object? id, Map<String, Object?> result) => {
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      };

  static Map<String, Object?> _rpcError(Object? id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };
}
