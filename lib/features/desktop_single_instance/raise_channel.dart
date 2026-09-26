// raise 通道的最小抽象 —— 当前实现就是 unix socket（见
// `linux_single_instance.dart`），但保留抽象方便未来切换 / 测试。
//
// 为什么不像 `single_instance_backend.dart` 那样写「替身」？
//   - raise 通道的全部责任就是「发一个字节」+「收一个字节」。语义已经够薄
//     了，再抽一层只会增加阅读负担。测试由 [InMemorySingleInstanceBackend]
//     接管，raise 通道的"成功 / 失败"通过 backend 的 [simulateRaiseDelivered]
//     直接表达。

import 'dart:async';

/// raise 消息接收端回调：一次「字节」触发一次回调（窗口恢复）。
typedef RaiseHandler = FutureOr<void> Function();

/// raise 通道的最小接口（不暴露底层 socket）。
///
/// 主实例（primary）：[bindAndListen] + [stop]。
/// 二次实例（secondary）：通过 [SingleInstanceBackend.sendRaiseToPrimary] 间接
/// 发送 —— 这条接口的 split 是因为：发送端**不需要**直接持有通道对象；
/// backend 把"先 connect socket → 写 1 字节 → close"包成一个原子动作。
///
/// 把 bind/listen 留作 raise 通道的职责，是为了让 [LinuxRaiseChannel] 用同
/// 一个 `ServerSocket` 对象做 accept 循环；后续要换成 D-Bus 时只换实现。
abstract class RaiseChannel {
  /// 监听 raise 消息；每收到一条触发一次 [handler]。
  Future<void> bindAndListen(RaiseHandler handler);

  /// 停止监听并释放资源。幂等。
  Future<void> stop();

  /// 通道监听地址 —— 仅日志 / 诊断用。
  String get diagnosticLocation;
}