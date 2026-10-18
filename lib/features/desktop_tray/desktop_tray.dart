// Desktop tray facade.
//
// **3.0.0 起主分支只支持 Windows**：托盘图标、关窗隐藏/关窗即锁、菜单三项都在
// 原生层（`windows/runner/flutter_window.cpp` 的 CreateTrayIcon / WM_CLOSE /
// TaskbarCreated），Dart 侧永远是 [DesktopTrayStatus.inactive] —— 这里保留
// facade 只是为了给调用方（`lib/main.dart`、设置页）一个稳定的入口，不再做平台
// 分派。
//
// Linux 适配（GTK runner + libayatana-appindicator + 本目录下的
// `linux_desktop_tray.dart` / `linux_window_controller.dart`）完整保存在 git 的
// `linux` 分支（`3312384`），需要时可以取回。
//
// 三态（保留给调用方做文案判断）：
//   - installed：托盘已装 + 关窗隐藏（Linux 曾有；Windows 由 C++ 承担，不经过这里）
//   - unavailable：托盘不可用，降级为"关窗即退出"
//   - inactive：本平台由原生层接管（Windows 现状）

import 'windows_desktop_tray.dart' as windows;

/// Aggregate state of the desktop-tray installation.
///
/// We don't surface the raw `bool` from the install call: callers (the UI in
/// particular) want to distinguish "everything OK" from "we explicitly fell
/// back to close-to-quit" — both could in principle succeed, but only one of
/// them provides the Bitwarden-style close-to-hide behaviour we want.
enum DesktopTrayStatus {
  /// Tray icon is up and close-to-hide is active.
  installed,

  /// Tray could not be created; close now exits the app. The caller must
  /// show a non-fatal notice on the Settings/About screen so the user knows
  /// why the window no longer hides on close.
  unavailable,

  /// The desktop layer is a no-op for this platform (Windows: the C++ runner
  /// owns the tray and close interception).
  inactive,
}

class DesktopTrayResult {
  const DesktopTrayResult(this.status, {this.detail});

  final DesktopTrayStatus status;

  /// Human-readable detail for the settings/About notice. Empty unless
  /// [status] is [DesktopTrayStatus.unavailable].
  final String? detail;

  @override
  String toString() => 'DesktopTrayResult($status, detail=$detail)';
}

/// Default installer. Tests override via [debugSetInstallerForTesting].
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
/// On Windows this is a no-op that reports [DesktopTrayStatus.inactive]: the
/// C++ runner owns the tray icon and the close interceptor, so the Dart side
/// never sees a window-close event.
///
/// The `clock` parameter is part of the historical API (the Linux installer
/// needed a timestamp); it is passed through to the installer so tests can
/// keep injecting it.
DesktopTrayResult installDesktopTray({DateTime Function()? clock}) {
  final at = (clock ?? DateTime.now)();
  final installer = _installerOverride ?? windows.installWindowsDesktopTray;
  return installer(at);
}
