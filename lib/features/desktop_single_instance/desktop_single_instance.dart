// Single-instance facade.
//
// **3.0.0 起主分支只支持 Windows**：UI 单实例由原生层负责 ——
// `windows/runner/main.cpp` 的 `CreateMutexW(L"Local\\EasyPass.UI")` 闸门，
// 命中 `ERROR_ALREADY_EXISTS` 时 `FindWindowW` + `SW_RESTORE` 把已有窗口抬到
// 前台然后退出。Dart 侧永远拿不到锁，所以这里恒为
// [SingleInstanceRole.notApplicable]，`main()` 照常走 UI 启动。
//
// Linux 适配（`easypass.lock` flock + unix socket raise，以及
// `linux_single_instance.dart` / `single_instance_raise_host.dart` /
// `raise_channel.dart` 这套二次启动唤起链路）完整保存在 git 的 `linux` 分支
// （`3312384`），需要时可以取回。
//
// 保留 facade 与 [debugSetSingleInstanceFactoryForTesting]：`main()` 的调用姿势
// 不变，单测仍可注入替身验证启动分支。

import 'windows_single_instance.dart' as windows;

/// 描述应用是否为「唯一正在运行的实例」，以及二次启动该如何处理。
enum SingleInstanceRole {
  /// 当前进程拿到了锁，是 UI 的主实例。
  ///
  /// 主分支上没有平台会返回它（Windows 的闸门在进程真正启动 Dart 之前就
  /// 决定了去留）；保留枚举值是为了不破坏调用方与测试的形态。
  primary,

  /// 当前进程**没有**拿到锁，应该唤起已有实例后 `exit(0)`，不进入 UI。
  secondary,

  /// 本平台不在 Dart 侧做单实例 —— 保持默认 UI 启动路径（Windows 现状）。
  notApplicable,
}

/// 二次启动的最终结论。
class SingleInstanceDecision {
  const SingleInstanceDecision({required this.role, this.detail});

  final SingleInstanceRole role;

  /// 可读诊断信息（写 stderr 用）。通常只有 secondary 才带。
  final String? detail;
}

/// 单实例协调器的工厂类型（可被测试覆盖）。
typedef SingleInstanceFactory = Future<SingleInstanceDecision> Function();

SingleInstanceFactory? _factoryOverride;

/// 注入单实例工厂（仅测试用）。传 `null` 还原默认。
void debugSetSingleInstanceFactoryForTesting(SingleInstanceFactory? factory) {
  _factoryOverride = factory;
}

/// 默认实现：Windows 的闸门在原生层，Dart 侧恒为 no-op。
SingleInstanceFactory _defaultSingleInstanceFactory() =>
    windows.acquireWindowsSingleInstance;

/// 决定当前进程是不是 UI 主实例。
///
/// 调用点（`lib/main.dart` 的 `main()` 早段，在 `runApp()` 之前）：
///   - `notApplicable` → Windows 现状，继续走 UI 启动（单实例由 C++ runner 守门）。
///   - `secondary` → 把 [decision.detail] 输出到 stderr 并 `exit(0)`。
Future<SingleInstanceDecision> acquireSingleInstance({
  SingleInstanceFactory? factory,
}) async {
  final effectiveFactory =
      factory ?? _factoryOverride ?? _defaultSingleInstanceFactory();
  return effectiveFactory();
}
