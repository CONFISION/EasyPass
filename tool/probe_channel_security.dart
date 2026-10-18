/// 通道安全探针（协议 5）：证明"核心 ↔ 客户端之间没有明文"。
///
/// 用法：
/// ```
/// dart run tool/probe_channel_security.dart --core build\qa5\core\easypass_core.exe
/// ```
///
/// 它做四件事，任何一条失败就退 1：
/// 1. **抓原始字节**：在一条正常连接上发真实请求（含 `unlock` 这种关键词），
///    在 socket 层旁路记录所有进出的原始字节，断言**捕获到的字节里不含**
///    `action` / `unlock` / `password` / `requestId` 这些明文关键词 —— 也就是
///    "业务帧确实是密文"。
/// 2. **拒绝明文 v4 握手**：直接发一帧 `{token: ...}`（旧协议形状），断言被拒。
/// 3. **拒绝错误令牌**：nonce + 证明用错令牌算，断言 `clientProof` 被拒。
/// 4. **令牌不上线**：断言从第 1 步捕获的字节里**找不到令牌本身**。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easypass/core_service/core_client.dart';
import 'package:easypass/core_service/core_info.dart';
import 'package:easypass/protocol/protocol.dart';

int _passed = 0;
int _failed = 0;

void _check(String name, bool ok, [Object? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  PASS  $name');
  } else {
    _failed++;
    stdout.writeln('  FAIL  $name${detail == null ? '' : ' -> $detail'}');
  }
}

/// 把捕获到的字节按 UTF-8 尽力解码（用于关键词搜索）。
String _asText(List<int> bytes) =>
    utf8.decode(bytes, allowMalformed: true).toLowerCase();

Future<void> main(List<String> args) async {
  final coreIndex = args.indexOf('--core');
  final corePath =
      (coreIndex >= 0 && coreIndex + 1 < args.length) ? args[coreIndex + 1] : null;
  if (corePath == null || !File(corePath).existsSync()) {
    stderr.writeln('用法：dart run tool/probe_channel_security.dart --core <核心路径>');
    exit(2);
  }

  stdout.writeln('== 通道安全探针（协议 $coreProtocolVersion）==');
  await Process.start(
    corePath,
    const ['--serve'],
    mode: ProcessStartMode.detached,
    workingDirectory: File(corePath).parent.path,
  );

  // 等核心就绪。
  CoreInfo? info;
  for (var i = 0; i < 50 && info == null; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    info = await CoreDiscovery.read();
  }
  if (info == null) {
    stderr.writeln('FAIL: 核心未就绪');
    exit(1);
  }
  stdout.writeln('核心：$info');

  try {
    await _verifyCiphertextOnTheWire(info);
    await _verifyPlaintextClientIsRejected(info);
    await _verifyWrongTokenIsRejected(info);
  } finally {
    // 收尾：让核心退出，不在用户机器上留进程。
    try {
      final client = await CoreClient.connect(info, role: 'ui');
      await client.request(Actions.shutdownCore);
    } catch (_) {
      // 忽略：下面的轮询/清理会兜底。
    }
    for (var i = 0; i < 50; i++) {
      if (await CoreDiscovery.read() == null) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await CoreDiscovery.removeAny();
  }

  stdout.writeln('\n== 结果：$_passed 通过 / $_failed 失败 ==');
  exit(_failed == 0 ? 0 : 1);
}

/// 步骤 1 + 4：抓一条正常连接的全部原始字节，检查没有明文。
Future<void> _verifyCiphertextOnTheWire(CoreInfo info) async {
  stdout.writeln('\n-- 链路字节检查 --');
  final captured = <int>[];
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    info.port,
    timeout: const Duration(seconds: 5),
  );
  // 在最底层旁路记录：用 asBroadcastStream 同时喂给解析器和捕获器。
  final broadcast = socket.asBroadcastStream();
  final reader = NativeMessageReader(
    StreamIterator<List<int>>(broadcast.map((chunk) {
      captured.addAll(chunk);
      return chunk;
    })),
  );

  // 走真实握手。
  final clientNonce = SecureChannelCrypto.randomNonce();
  socket.add(encodeMessage({
    'hello': 'easypass',
    'clientNonce': clientNonce,
    'role': 'ui',
    'protocolVersion': coreProtocolVersion,
  }));
  final step2 = await reader.read();
  if (step2 == null) {
    _check('握手第 2 步有响应', false);
    socket.destroy();
    return;
  }
  final serverNonce = step2['serverNonce'] as String;
  socket.add(encodeMessage({
    'clientProof': SecureChannelCrypto.clientProof(
      token: info.token,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
    ),
  }));
  final channel = SecureChannel(SecureChannelCrypto.deriveKeys(
    token: info.token,
    clientNonce: clientNonce,
    serverNonce: serverNonce,
  ));
  final step4Frame = await reader.readBytes();
  final step4 = step4Frame == null ? null : channel.open(step4Frame, fromClient: false);
  _check('握手成功（双向证明，末帧已加密）', step4?['ok'] == true, step4);

  // 发一个带"敏感关键词"的真实请求：即使库是空的，请求里也含这些词。
  socket.add(encodePayload(channel.seal({
    'requestId': 'probe-security-1',
    'action': Actions.unlock,
    'password': 'super-secret-probe-password',
  }, fromClient: true)));
  final frame = await reader.readBytes();
  final response =
      frame == null ? null : channel.open(frame, fromClient: false);
  _check('加密请求得到加密响应', response?['requestId'] == 'probe-security-1',
      response);
  socket.destroy();

  // 关键断言：链路字节里不该出现任何业务明文。
  final text = _asText(captured);
  for (final keyword in [
    'action',
    'unlock',
    'password',
    'super-secret-probe-password',
    'requestId',
  ]) {
    _check('链路字节不含明文 "$keyword"', !text.contains(keyword));
  }
  _check('链路字节不含令牌本身', !text.contains(info.token.toLowerCase()));
  stdout.writeln('  （本次共捕获 ${captured.length} 字节）');
}

/// 步骤 2：旧式明文握手（协议 4 形状）必须被拒。
Future<void> _verifyPlaintextClientIsRejected(CoreInfo info) async {
  stdout.writeln('\n-- 旧协议明文握手 --');
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, info.port,
      timeout: const Duration(seconds: 5));
  final reader =
      NativeMessageReader(StreamIterator<List<int>>(socket.cast<List<int>>()));
  socket.add(encodeMessage({
    'token': info.token,
    'role': 'ui',
    'protocolVersion': 4,
  }));
  final reply = await reader.read().timeout(const Duration(seconds: 5),
      onTimeout: () => null);
  socket.destroy();
  _check('明文 v4 握手被拒绝', reply?['ok'] == false, reply);
  _check('拒绝理由为 unsupported',
      reply?['error'] == ErrorCodes.unsupported, reply?['error']);
}

/// 步骤 3：令牌不对（证明算错）必须被拒。
Future<void> _verifyWrongTokenIsRejected(CoreInfo info) async {
  stdout.writeln('\n-- 错误令牌 --');
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, info.port,
      timeout: const Duration(seconds: 5));
  final reader =
      NativeMessageReader(StreamIterator<List<int>>(socket.cast<List<int>>()));
  final clientNonce = SecureChannelCrypto.randomNonce();
  socket.add(encodeMessage({
    'hello': 'easypass',
    'clientNonce': clientNonce,
    'role': 'ui',
    'protocolVersion': coreProtocolVersion,
  }));
  final step2 = await reader.read();
  final serverNonce = step2?['serverNonce'] as String?;
  if (serverNonce == null) {
    _check('错误令牌：拿到 serverNonce', false, step2);
    socket.destroy();
    return;
  }
  socket.add(encodeMessage({
    'clientProof': SecureChannelCrypto.clientProof(
      token: 'deadbeef' * 8,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
    ),
  }));
  final step4 = await reader.read().timeout(const Duration(seconds: 5),
      onTimeout: () => null);
  socket.destroy();
  _check('错误令牌被拒绝', step4?['ok'] != true, step4);
}


