// raise 目标 provider —— 主进程上，让 raise handler 能拿到
// `WindowController` 来恢复窗口。
//
// 为什么不在 `lib/features/desktop_tray/desktop_tray.dart` 里加：
//   - 引入 tray 时没把 `installDesktopTray()` 的结果接到 Riverpod
//     （`main.dart` 里调完即丢，曾经提过的 `desktopTrayResultProvider`
//     在代码里并不存在）：本轮要避免再添一个"声明但未接线"的
//     Riverpod provider）。
//   - 本轮仅借用 WindowController 这一种最小职责，把它放本模块里，
//     主进程上由 `main.dart` 注入 override；非 Linux / 没用上 = `null`。
//
// 升级路径：把 `installDesktopTray()` 的结果真正接到
// `desktopTrayResultProvider` 后，本文件可删，`raise_host` 直接读那个
// provider。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop_tray/window_controller.dart';

/// 主进程的 `WindowController`：raise handler 用来 `show()`。
///
/// 默认 `null` —— 主进程必须用 `ProviderScope.overrides` 注入一个真实值
/// （见 `lib/main.dart`）。非 Linux / 没装 tray 时是 null，raise handler
/// 静默 return。
final raiseWindowControllerProvider = Provider<WindowController?>((ref) => null);