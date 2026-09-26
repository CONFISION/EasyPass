// Windows 单实例 no-op 桩。
//
// 真实 Windows 单实例归 `windows/runner/*.cpp` 管（C++ 改 Mutex/ForegroundWindow
// 才合理；Dart 侧不补这个能力，与 P3.1 "Windows = inactive" 同款策略）。
//
// 当前事实（见 `dist/P3.2-facts.md` §1）：Windows runner **还没有**单实例，
// 本轮 P3.2 不动 `windows/runner/`（红线）。下一轮由小玖决定是否在 C++ 侧
// 补 Mutex + FindWindow。

import 'desktop_single_instance.dart';

Future<SingleInstanceDecision> acquireWindowsSingleInstance() async {
  return const SingleInstanceDecision(role: SingleInstanceRole.notApplicable);
}