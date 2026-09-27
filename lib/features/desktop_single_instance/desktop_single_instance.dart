// Single-instance + secondary-launch "raise" for the desktop app (P3.2).
//
// 设计原则：
//   1. 抽象层可注入、可单测 —— 真实桌面会话、Network namespace、真实 flock
//      都不需要；测试用 [InMemorySingleInstanceBackend]。
//   2. Windows 不受影响 —— 见 `windows_single_instance.dart`（no-op 桩）。
//   3. 失败 = 可读 stderr + UI 可读提示，绝不静默卡死。
//
// 锁选型 / IPC 选型理由：`dist/P3.2-facts.md` §4.3 / §5。
//   - 进程内互斥用 `flock`（`dart:io` 的 [File.lock]），崩溃时内核自动释放，
//     跨进程可见，无 pid 复用风险。
//   - 二次启动唤起用 unix socket：socket 文件紧邻锁文件，由首个进程 bind/
//     listen；二次启动 connect → 写 1 字节 → close → exit(0)。首个进程
//     收到字节 → 通过 [RaiseHandler] 把窗口恢复。
//
// 文件清单：
//   - desktop_single_instance.dart   : 本文件，公共 API + 三态 + 工厂
//   - single_instance_backend.dart   : [SingleInstanceBackend] 抽象 + InMemory 桩
//   - raise_channel.dart             : [RaiseChannel] 抽象 + 替身（send/receive）
//   - linux_single_instance.dart     : Linux 实现（flock + unix socket）
//   - windows_single_instance.dart   : Windows no-op 桩
//   - other_single_instance.dart     : 其他桌面平台 no-op 桩

import 'dart:io' show Platform;

import 'linux_single_instance.dart' as linux;
import 'other_single_instance.dart' as other;
import 'raise_channel.dart';
import 'single_instance_backend.dart';
import 'windows_single_instance.dart' as windows;

/// 描述应用是否为「唯一正在运行的实例」，以及二次启动该如何处理。
enum SingleInstanceRole {
  /// 当前进程拿到了锁，是 UI 的主实例，需要开始监听 raise 请求。
  primary,

  /// 当前进程**没有**拿到锁（说明有别的实例在跑）；它应该发出 raise 请求
  /// 给主实例，然后 `exit(0)`。这条返回路径不进入 UI 启动。
  secondary,

  /// 不在 Linux 上 —— 本特性非本平台范围，返回 no-op（直接走默认 UI 路径）。
  notApplicable,
}

/// 二次启动的最终结论。
class SingleInstanceDecision {
  const SingleInstanceDecision({
    required this.role,
    this.detail,
    this.backend,
  });

  final SingleInstanceRole role;

  /// 可读诊断信息（写 stderr / SnackBar 用）。仅 secondary 时常带。
  final String? detail;

  /// 当 [role] 是 [SingleInstanceRole.primary] 时，给主实例用的 backend。
  /// 退出时必须 [SingleInstanceBackend.dispose] —— 否则内核持有的 `flock`
  /// 会一直挂到进程退出（崩溃场景下内核会自动释放，所以 best-effort）。
  final SingleInstanceBackend? backend;
}

/// 单实例协调器的工厂类型（可被测试覆盖）。
typedef SingleInstanceFactory = Future<SingleInstanceDecision> Function();

SingleInstanceFactory? _factoryOverride;

/// 注入单实例工厂（仅测试用）。传 `null` 还原默认。
void debugSetSingleInstanceFactoryForTesting(SingleInstanceFactory? factory) {
  _factoryOverride = factory;
}

/// 默认平台分派。
SingleInstanceFactory _defaultSingleInstanceFactory() {
  if (Platform.isLinux) return linux.acquireLinuxSingleInstanceAsync;
  if (Platform.isWindows) return windows.acquireWindowsSingleInstance;
  return other.acquireOtherSingleInstance;
}

/// 决定当前进程是不是 UI 主实例。
///
/// 调用点（`lib/main.dart` 的 `main()` 早段，在 `runApp()` 之前）：
///   - `primary` → 继续走 UI 启动；保留 [SingleInstanceDecision.backend]，
///     待 `runApp` 之后立刻 `backend.startRaising(handler)`。
///   - `secondary` → 通过 [decision.detail] 把"已经在跑"的提示输出到 stderr，
///     并 `exit(0)`（不允许 UI 启动；与任务书"二次启动唤起已有窗口"对齐）。
///   - `notApplicable` → 不在 Linux 上，行为不变（Windows 由 C++ runner 守门）。
///
/// [injectedBackend] / [injectedChannel] 是测试用 —— 只能在 `_factoryOverride`
/// 未注入的前提下使用（混用会抛错，与现有 `debugSetInstallerForTesting` 风格
/// 一致）。
Future<SingleInstanceDecision> acquireSingleInstance({
  SingleInstanceFactory? factory,
  SingleInstanceBackend? injectedBackend,
  RaiseChannel? injectedChannel,
}) async {
  final effectiveFactory =
      factory ?? _factoryOverride ?? _defaultSingleInstanceFactory();
  if (injectedBackend != null || injectedChannel != null) {
    if (factory != null || _factoryOverride != null) {
      throw StateError(
        'acquireSingleInstance: cannot mix factory override and backend/channel injection',
      );
    }
    return linux.acquireLinuxSingleInstanceAsync(
      injectedBackend: injectedBackend,
      injectedChannel: injectedChannel,
    );
  }
  return effectiveFactory();
}