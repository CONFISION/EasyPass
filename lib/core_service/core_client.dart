import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easypass/core/constants/app_constants.dart';
import 'package:easypass/protocol/protocol.dart';

import 'core_info.dart';

/// 握手失败（token 不对、协议不兼容、核心拒绝服务）。
class CoreHandshakeException implements Exception {
  CoreHandshakeException(this.message);

  final String message;

  @override
  String toString() => 'CoreHandshakeException: $message';
}

/// 与核心服务的一条连接：握手 + 请求/响应 + 事件订阅。
///
/// UI 客户端、`--shutdown` / `--status` 这类 CLI 都走这一个实现，
/// 避免"探针一套、客户端一套"的分叉（历史教训：帧读取必须共用有状态 reader）。
class CoreClient {
  CoreClient._(this._socket, this.info, this.role) {
    _reader = NativeMessageReader(
      StreamIterator<List<int>>(_socket.cast<List<int>>()),
    );
  }

  final Socket _socket;
  late final NativeMessageReader _reader;

  /// 握手完成后建立；为 null 表示仍在明文握手阶段。
  SecureChannel? _channel;

  /// 连接时用的发现信息（含 token）。
  final CoreInfo info;

  /// 本次连接的角色：`ui` / `bridge` / `agent`。
  final String role;

  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  int _seq = 0;
  bool _closed = false;

  /// 服务端推送的事件流（`changed` / `sessionLocked` / `coreShuttingDown` …）。
  Stream<Map<String, dynamic>> get events => _events.stream;

  bool get isClosed => _closed;

  /// 连接 `daemon.json` 里记录的核心并完成握手。
  ///
  /// 抛 [CoreHandshakeException]（协议/鉴权问题）或 [SocketException] /
  /// [TimeoutException]（连不上）。
  static Future<CoreClient> connect(
    CoreInfo info, {
    String role = 'ui',
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      info.port,
      timeout: timeout,
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    final client = CoreClient._(socket, info, role);
    try {
      await client._handshake(timeout: timeout);
    } catch (_) {
      client.close();
      rethrow;
    }
    client._startReadLoop();
    return client;
  }

  /// 读取发现文件并连接；没有核心 / 连不上 / 握手失败都返回 null。
  static Future<CoreClient?> connectToRunning({
    String role = 'ui',
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final info = await CoreDiscovery.read();
    if (info == null) return null;
    try {
      return await connect(info, role: role, timeout: timeout);
    } catch (_) {
      return null;
    }
  }

  /// 协议 5 的四步握手：
  ///
  /// 1. 客户端 → `{hello, clientNonce, role, protocolVersion}`
  /// 2. 核心   → `{serverNonce, serverProof, coreVersion, protocolVersion}`
  /// 3. 客户端 → `{clientProof}`
  /// 4. 核心   → `{ok, capabilities}`
  ///
  /// **令牌一个字节都不上线**：双方只交换 nonce 与 HMAC 证明。第 2 步验
  /// `serverProof` 是关键 —— 没有它，本机任何进程都能先占住端口冒充核心。
  Future<void> _handshake({required Duration timeout}) async {
    final clientNonce = SecureChannelCrypto.randomNonce();
    _socket.add(encodeMessage({
      'hello': 'easypass',
      'clientNonce': clientNonce,
      'role': role,
      'protocolVersion': coreProtocolVersion,
      'clientVersion': AppConstants.coreVersion,
    }));

    final step2 = await _reader.read().timeout(timeout);
    if (step2 == null) {
      throw CoreHandshakeException('核心在握手后立即关闭了连接');
    }
    if (step2['ok'] == false) {
      throw CoreHandshakeException(
        '核心拒绝连接：${step2['error'] ?? 'unknown'} '
        '(core=${step2['protocolVersion'] ?? '?'})',
      );
    }
    final serverNonce = step2['serverNonce'] as String?;
    final serverProof = step2['serverProof'] as String?;
    if (serverNonce == null || serverProof == null) {
      throw CoreHandshakeException('核心握手响应缺少 nonce/proof');
    }
    final expected = SecureChannelCrypto.serverProof(
      token: info.token,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
    );
    if (!SecureChannelCrypto.constantTimeEquals(
      utf8.encode(serverProof),
      utf8.encode(expected),
    )) {
      // 对端不知道令牌 ⇒ 不是我们的核心（端口被别的进程抢占 / 令牌过期）。
      throw CoreHandshakeException('核心身份校验失败（serverProof 不匹配）');
    }

    _socket.add(encodeMessage({
      'clientProof': SecureChannelCrypto.clientProof(
        token: info.token,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
      ),
    }));
    // 第 4 步已经是密文：先派生密钥，再解这一帧。
    final channel = SecureChannel(SecureChannelCrypto.deriveKeys(
      token: info.token,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
    ));
    final step4Frame = await _reader.readBytes().timeout(timeout);
    if (step4Frame == null) {
      throw CoreHandshakeException('核心在握手最后一步关闭了连接');
    }
    final step4 = channel.open(step4Frame, fromClient: false);
    if (step4['ok'] != true) {
      throw CoreHandshakeException(
        '核心拒绝了本次连接：${step4['error'] ?? 'unknown'}',
      );
    }
    _channel = channel;
  }

  void _startReadLoop() {
    unawaited(_readLoop());
  }

  Future<void> _readLoop() async {
    try {
      while (true) {
        final frame = await _reader.readBytes();
        if (frame == null) break;
        final channel = _channel;
        if (channel == null) break;
        // 解不开的帧一律断开（认证失败 = 有人在改链路），绝不降级成空消息。
        final message = channel.open(frame, fromClient: false);
        _dispatch(message);
      }
    } catch (_) {
      // 连接异常/协议错误都按"连接结束"处理，由调用方决定重连。
    }
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          CoreHandshakeException('核心连接已断开（请求未完成）'),
        );
      }
    }
    _pending.clear();
    if (!_events.isClosed) await _events.close();
  }

  void _dispatch(Map<String, dynamic> message) {
    final event = message['event'];
    if (event is String) {
      if (!_events.isClosed) _events.add(message);
      return;
    }
    final requestId = message['requestId'];
    if (requestId is String) {
      final completer = _pending.remove(requestId);
      if (completer != null && !completer.isCompleted) {
        completer.complete(message);
      }
    }
  }

  /// 发一个请求并等响应。参数**平铺**进请求对象（与桥接协议一致）。
  ///
  /// 响应里的 `error` 是字符串（兼容扩展侧 `gradeDaemonError`），
  /// `errorCode` 是结构化补充。抛 [CoreRequestException] 表示核心回了错误。
  Future<Map<String, dynamic>> request(
    String action, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (_closed) {
      throw CoreHandshakeException('核心连接已断开');
    }
    final requestId = '${++_seq}-${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;
    final channel = _channel;
    if (channel == null) {
      _pending.remove(requestId);
      throw CoreHandshakeException('连接尚未完成安全握手');
    }
    _socket.add(encodePayload(channel.seal({
      'requestId': requestId,
      'action': action,
      ...params,
    }, fromClient: true)));
    final response = await completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _pending.remove(requestId);
        throw TimeoutException('核心请求超时：$action');
      },
    );
    final error = response['error'];
    if (error is String && error.isNotEmpty) {
      throw CoreRequestException(
        error,
        code: response['errorCode'] as String? ?? ErrorCodes.internal,
      );
    }
    final data = response['data'];
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  void close() {
    _closed = true;
    try {
      _socket.destroy();
    } catch (_) {
      // 已经断开。
    }
    if (!_events.isClosed) unawaited(_events.close());
  }
}

/// 核心返回的业务错误（`error` 字符串 + `errorCode`）。
class CoreRequestException implements Exception {
  CoreRequestException(this.message, {this.code = ErrorCodes.internal});

  final String message;
  final String code;

  bool get isLocked => code == ErrorCodes.locked;

  bool get needsKeyMigration => code == ErrorCodes.needsKeyMigration;

  @override
  String toString() => message;
}

/// 请求正在运行的核心锁定保险库（托盘"仅退出 UI"、CLI `--lock`）。
///
/// 返回 true 表示核心确认已锁定；没有核心在跑时返回 true（无事可做）。
Future<bool> lockRunningCore({
  Duration timeout = const Duration(seconds: 5),
}) async {
  final info = await CoreDiscovery.read();
  if (info == null) return true;
  CoreClient? client;
  try {
    client = await CoreClient.connect(info, role: 'ui',
        timeout: const Duration(seconds: 3));
    await client.request(Actions.lock).timeout(timeout);
    return true;
  } catch (_) {
    return false;
  } finally {
    client?.close();
  }
}

/// 请求正在运行的核心退出（托盘"完整退出服务"、安装器、`--shutdown` 都用它）。
///
/// 返回 true 表示核心确认退出（或本来就没在跑）。实现上先发 `shutdownCore`，
/// 再轮询发现文件是否消失 —— 那才是"核心真的退出了"的证据。
Future<bool> shutdownRunningCore({
  Duration timeout = const Duration(seconds: 10),
}) async {
  final info = await CoreDiscovery.read();
  if (info == null) return true;

  CoreClient? client;
  try {
    client = await CoreClient.connect(info, role: 'ui',
        timeout: const Duration(seconds: 3));
    // 核心在回复后立即退出，连接会先断 —— 因此不 await 响应体。
    unawaited(client.request(Actions.shutdownCore).catchError(
          (Object _) => <String, dynamic>{},
        ));
  } catch (_) {
    // 连不上：可能是刚退出，也可能是陈旧文件 —— 交给下面的轮询判定。
  }

  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final current = await CoreDiscovery.read();
    if (current == null || current.pid != info.pid) {
      client?.close();
      return true;
    }
  }
  client?.close();
  return false;
}
