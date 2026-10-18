// Windows 单实例由 `windows/runner/main.cpp` 的闸门负责，Dart 侧不参与。
//
// 机制（3.0.0 起）：`wWinMain` 里 `CreateMutexW(nullptr, FALSE, L"Local\\EasyPass.UI")`；
// `ERROR_ALREADY_EXISTS` ⇒ 已有实例 ⇒ `FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW",
// L"EasyPass")` → `ShowWindow(SW_RESTORE)` + `SetForegroundWindow` → `return 0`
// （不建窗口、不注册第二个托盘图标）。窗口还没建好时重试 20×100ms。
//
// 三条必须记住的约定：
// - **带任何 `--` 开关的 CLI 调用跳过闸门**（`--install` / `--desktop-status` /
//   `--install-browser-host` …），否则 CLI 会被"已有实例"静默吞掉。
// - **窗口标题是契约的一部分**：`kRunnerWindowTitle` 必须与
//   `window.Create(L"EasyPass", …)` 一致，`kRunnerWindowClass` 必须与
//   `win32_window.cpp` 的 `kWindowClassName` 一致。改了标题又不改常量，双击会退化成
//   "没反应"（mutex 确认有实例，却找不到它的窗口）。
// - **互斥量是应用级、不按构建路径区分**：同时开 dev 构建与已安装版时，后启动的会被
//   抬到先运行的那个窗口上。这是"UI 只允许一个实例"的直接后果，不是 bug。

import 'desktop_single_instance.dart';

Future<SingleInstanceDecision> acquireWindowsSingleInstance() async {
  return const SingleInstanceDecision(role: SingleInstanceRole.notApplicable);
}
