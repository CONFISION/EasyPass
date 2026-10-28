import 'dart:async';
import 'dart:io';

import 'package:easypass/core/constants/app_constants.dart';
import 'package:easypass/protocol/protocol.dart';

import 'core_info.dart';

/// native messaging 宿主（`--bridge`）。
///
/// Linux 的包装脚本 `exec easypass_core --bridge`；Windows 由 x86 C++ 桥承担
/// （32 位浏览器需要一个 32 位 stdio 宿主，Dart AOT 出不了 ia32）。
///
/// 职责只有两件：**发现/拉起核心**，然后把浏览器与核心之间的帧双向搬运。
/// 它自己不碰数据库、不持密钥 —— 这样"扩展每次连接都起一个新核心实例"
/// 那个老问题从结构上消失。
Future<int> runBridgeForwarder() async {
  // daemon.json 存在但损坏属于"发现信息不可信"：拉起新核心会与仍在运行的
  // 核心抢单实例/数据库，所以这里 fail closed（与 UI 侧同一口径）。
  final CoreInfo? initial;
  try {
    initial = await CoreDiscovery.read();
  } on CoreDiscoveryException catch (error) {
    stderr.writeln('easypass_core: --bridge 发现文件损坏：$error');
    return 1;
  }
  var info = initial;
  if (info == null) {
    if (!await launchCoreIfPresent()) {
      stderr.writeln('easypass_core: --bridge 找不到核心，也找不到核心可执行文件');
      return 1;
    }
    try {
      info = await waitForCore();
    } on CoreDiscoveryException catch (error) {
      stderr.writeln('easypass_core: --bridge 等待核心时发现文件损坏：$error');
      return 1;
    }
    if (info == null) {
      stderr.writeln('easypass_core: --bridge 等待核心就绪超时');
      return 1;
    }
  }

  Socket socket;
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      info.port,
      timeout: const Duration(seconds: 3),
    );
  } catch (_) {
    // 发现文件陈旧（核心已退出）：清掉它，拉起一个新核心再连一次。
    await CoreDiscovery.removeAny();
    if (!await launchCoreIfPresent()) {
      stderr.writeln('easypass_core: --bridge 无法拉起核心');
      return 1;
    }
    try {
      info = await waitForCore();
    } on CoreDiscoveryException catch (error) {
      stderr.writeln('easypass_core: --bridge 等待核心时发现文件损坏：$error');
      return 1;
    }
    if (info == null) {
      stderr.writeln('easypass_core: --bridge 等待核心就绪超时');
      return 1;
    }
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        info.port,
        timeout: const Duration(seconds: 3),
      );
    } catch (error) {
      stderr.writeln('easypass_core: --bridge 连不上核心：$error');
      return 1;
    }
  }

  socket.setOption(SocketOption.tcpNoDelay, true);
  final socketReader =
      NativeMessageReader(StreamIterator<List<int>>(socket.cast<List<int>>()));

  // 握手：由本进程做（浏览器看不到这些帧）。
  //
  // Linux 的桥是 Dart 写的 ⇒ 直接走 v5 **加密**握手，与 UI 同等级：
  // 桥↔核心之间也没有明文（Windows 的 x86 C++ 桥走 v4 明文 + 令牌，
  // 那是 32 位 stdio 限制下的取舍，见 core_service.dart 的说明）。
  final clientNonce = SecureChannelCrypto.randomNonce();
  socket.add(encodeMessage({
    'hello': 'easypass',
    'clientNonce': clientNonce,
    'role': 'bridge',
    'protocolVersion': coreProtocolVersion,
    'clientVersion': AppConstants.coreVersion,
  }));
  final step2 = await socketReader.read();
  final serverNonce = step2?['serverNonce'] as String?;
  if (serverNonce == null) {
    stderr.writeln('easypass_core: --bridge 握手失败：${step2?['error'] ?? '无响应'}');
    socket.destroy();
    return 1;
  }
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
  final step4Frame = await socketReader.readBytes();
  final step4 = step4Frame == null ? null : channel.open(step4Frame, fromClient: false);
  if (step4?['ok'] != true) {
    stderr.writeln('easypass_core: --bridge 握手失败：${step4?['error'] ?? '无响应'}');
    socket.destroy();
    return 1;
  }

  final done = Completer<void>();
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  // 核心 → 浏览器
  unawaited(() async {
    try {
      while (true) {
        final frame = await socketReader.readBytes();
        if (frame == null) break;
        // 核心 → 浏览器：解出明文 native-messaging 帧。
        stdout.add(encodeMessage(channel.open(frame, fromClient: false)));
      }
    } catch (_) {
      // 连接结束。
    }
    finish();
  }());

  // 浏览器 → 核心
  final stdinReader = NativeMessageReader(StreamIterator<List<int>>(stdin));
  unawaited(() async {
    try {
      while (true) {
        final message = await stdinReader.read();
        if (message == null) break;
        // 浏览器 → 核心：加密后转发（核心只接受密文业务帧）。
        socket.add(encodePayload(channel.seal(message, fromClient: true)));
      }
    } catch (_) {
      // 连接结束。
    }
    finish();
  }());

  await done.future;
  try {
    socket.destroy();
  } catch (_) {
    // 已经断开。
  }
  return 0;
}

/// 同目录（或 `core\` 子目录）下的核心可执行文件路径（找不到返回 null）。
///
/// 生产布局是 `<app>\core\easypass_core[.exe]`（原生资产要求库在
/// `<exe>/../lib`，即 `<app>\lib`）；开发态/扁平布局下核心就在同目录。
String? coreExecutablePath() {
  final dir = File(Platform.resolvedExecutable).parent.path;
  final name = Platform.isWindows ? 'easypass_core.exe' : 'easypass_core';
  final candidates = [
    Platform.isWindows ? '$dir\\core\\$name' : '$dir/core/$name',
    Platform.isWindows ? '$dir\\$name' : '$dir/$name',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

/// 若同目录有核心可执行文件则后台拉起（分离进程，不阻塞调用方）。
Future<bool> launchCoreIfPresent() async {
  final path = coreExecutablePath();
  if (path == null) return false;
  try {
    await Process.start(
      path,
      const ['--serve'],
      mode: ProcessStartMode.detached,
      workingDirectory: File(path).parent.path,
    );
    return true;
  } catch (error) {
    stderr.writeln('easypass_core: 拉起核心失败：$error');
    return false;
  }
}

/// 轮询发现文件直到核心就绪（上限 10 秒）。
Future<CoreInfo?> waitForCore({
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final info = await CoreDiscovery.read();
    if (info != null) return info;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return null;
}
