import 'dart:io';

import 'package:easypass/core/constants/app_constants.dart';

/// 核心服务的**单实例闸门**。
///
/// 手段：独占绑定固定回环端口（[AppConstants.coreFixedPort]）。
/// 为什么不只用 `daemon.json` 探测：两个核心可能同时启动，都读到"没有核心"，
/// 于是双双开库 —— 那正是要消灭的"双核心"。
///
/// 为什么不用文件锁：Dart 的 `RandomAccessFile.lock` 在锁被占用时是**阻塞**的
/// （没有非阻塞的重试语义），第二个核心会挂死而不是干净退出。
/// 端口绑定由内核保证原子性，失败立刻返回 `SocketException`。
///
/// 端口被别的程序占用时退化为临时端口（`isPrimary` 只能靠 `daemon.json` 判断），
/// 这是可接受的降级：真正的唯一性判据是"发现文件里的核心能握手成功"。
class CoreSingleton {
  CoreSingleton._(this._socket, this.usedFixedPort);

  final ServerSocket _socket;

  /// 是否抢到了固定端口 —— 抢到就意味着"本进程是唯一核心"。
  final bool usedFixedPort;

  ServerSocket get socket => _socket;

  int get port => _socket.port;

  /// 尝试独占固定端口；被占用时退化为临时端口并返回 `usedFixedPort=false`。
  static Future<CoreSingleton> bind() async {
    try {
      final socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        AppConstants.coreFixedPort,
        shared: false,
      );
      return CoreSingleton._(socket, true);
    } on SocketException {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      return CoreSingleton._(socket, false);
    }
  }

  /// 另一个核心是否已经在跑：**先看固定端口能不能连上**。
  ///
  /// 调用方（`--serve` 启动路径、拉起器）用它来避免"两核心同时开库"。
  static Future<bool> isAnotherCoreListening({
    Duration timeout = const Duration(milliseconds: 400),
  }) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        AppConstants.coreFixedPort,
        timeout: timeout,
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> close() => _socket.close();
}
