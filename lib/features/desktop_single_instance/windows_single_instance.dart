// Windows 单实例 no-op 桩。
//
// 真实 Windows 单实例归 `windows/runner/*.cpp` 管（C++ 改 Mutex/ForegroundWindow
// 才合理；Dart 侧不补这个能力，桌面托盘在 Windows 上同样是 inactive 策略）。
//
// 当前事实：Windows runner **还没有**单实例，本轮不动 `windows/runner/`
// （红线）。下一轮由小玖决定是否在 C++ 侧补 Mutex + FindWindow。

import 'desktop_single_instance.dart';

Future<SingleInstanceDecision> acquireWindowsSingleInstance() async {
  return const SingleInstanceDecision(role: SingleInstanceRole.notApplicable);
}