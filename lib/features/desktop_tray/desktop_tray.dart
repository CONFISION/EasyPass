// Linux 桌面体验对等（P3.1）· 关窗最小化到托盘 + 托盘菜单/图标。
//
// 设计原则：
//   1. 抽象层可注入、单测不依赖真实桌面会话 —— 见 [WindowController] /
//      [TrayController] / [MenuAction]。
//   2. Windows 不受影响：Windows 上 `windows/runner/flutter_window.cpp` 已经在原生
//      层处理托盘 + WM_CLOSE，这里只暴露 Linux 路径。
//   3. 检测不到可用托盘宿主时降级为"关窗即退出"，并在设置页给可读说明。
//
// 文件清单（全部在 `lib/features/desktop_tray/`）：
//   - desktop_tray.dart            ：本文件，公共 API + 安装入口 + 平台分派
//   - window_controller.dart       ：WindowController 抽象 + 测试桩
//   - tray_controller.dart         ：TrayController 抽象 + 测试桩
//   - linux_desktop_tray.dart      ：Linux 实现（window_manager + tray_manager）
//   - windows_desktop_tray.dart    ：Windows no-op 桩（保持现有 runner C++ 路径不变）
//   - macos_desktop_tray.dart      ：其他桌面平台 no-op 桩
//
// 三态：
//   - installed：托盘已装 + 关窗隐藏
//   - unavailable：托盘不可用（GNOME 无 AppIndicator 扩展等），降级为"关窗即退出"
//   - inactive：非 Linux（Windows 现有 C++ 实现接管，或 macOS 不在本轮范围）

import 'dart:io' show Platform;

import 'linux_desktop_tray.dart' as linux;
import 'macos_desktop_tray.dart' as other;
import 'tray_controller.dart';
import 'window_controller.dart';
import 'windows_desktop_tray.dart' as windows;

/// Aggregate state of the desktop-tray installation.
///
/// We don't surface the raw `bool` from the install call: callers (the UI in
/// particular) want to distinguish "everything OK" from "we explicitly fell
/// back to close-to-quit" — both could in principle succeed, but only one of
/// them provides the Bitwarden-style close-to-hide behaviour we want.
enum DesktopTrayStatus {
  /// Tray icon is up and close-to-hide is active (Linux with KDE / GNOME +
  /// AppIndicator / etc.).
  installed,

  /// Tray could not be created; close now exits the app. The caller must
  /// show a non-fatal notice on the Settings/About screen so the user knows
  /// why the window no longer hides on close.
  unavailable,

  /// The desktop layer is a no-op for this platform (Windows: the C++ runner
  /// owns the tray and close interception; macOS: out of scope for P3.1).
  inactive,
}

class DesktopTrayResult {
  const DesktopTrayResult(
    this.status, {
    this.detail,
    this.windowController,
    this.trayController,
  });

  final DesktopTrayStatus status;

  /// Human-readable detail for the settings/About notice. Empty unless
  /// [status] is [DesktopTrayStatus.unavailable].
  final String? detail;

  /// Controllers the caller can use to drive menu actions (only meaningful
  /// when [status] == [DesktopTrayStatus.installed]). `null` otherwise so
  /// callers can't accidentally surface menu-driven UI on platforms where
  /// the menu doesn't exist.
  final WindowController? windowController;
  final TrayController? trayController;

  @override
  String toString() => 'DesktopTrayResult($status, detail=$detail)';
}

/// Default installer chosen by the current platform. Tests override via
/// [debugSetInstallerForTesting].
typedef DesktopTrayInstaller = DesktopTrayResult Function(
  DateTime clock,
);

DesktopTrayInstaller? _installerOverride;

/// Set the installer used by [installDesktopTray]. Pass `null` to fall back
/// to the platform default. Used by unit tests to swap in a fake without
/// needing a real desktop session.
void debugSetInstallerForTesting(DesktopTrayInstaller? installer) {
  _installerOverride = installer;
}

/// Installs the desktop tray + close interception for the current platform.
///
/// Returns:
///   - [DesktopTrayStatus.installed] when the tray icon is up and close-to-hide
///     is wired up. The returned [DesktopTrayResult.windowController] and
///     [DesktopTrayResult.trayController] are usable for tests.
///   - [DesktopTrayStatus.unavailable] when the tray could not be created
///     (e.g. GNOME without an AppIndicator extension); close now exits the
///     app, [DesktopTrayResult.detail] explains why.
///   - [DesktopTrayStatus.inactive] on platforms where the layer is a no-op
///     (Windows: the C++ runner owns the tray; macOS: out of scope for P3.1).
DesktopTrayResult installDesktopTray({DateTime Function()? clock}) {
  final at = (clock ?? DateTime.now)();
  final installer = _installerOverride ?? _defaultInstallerForPlatform();
  return installer(at);
}

DesktopTrayInstaller _defaultInstallerForPlatform() {
  if (Platform.isLinux) return linux.installLinuxDesktopTray;
  if (Platform.isWindows) return windows.installWindowsDesktopTray;
  return other.installOtherDesktopTray;
}