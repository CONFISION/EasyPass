// Windows 自启 no-op 桩 —— Windows 归安装器管（见
// `installer/easypass_setup.iss:198-214`）。设置页开关在 Windows 上**不显
// 示**（与 `trayUnavailableNotice` 同款 "关掉开关" 风格，避免误导用户）。

import 'dart:io' show Platform;

import 'desktop_autostart.dart';

class WindowsAutostart implements LinuxAutostartBackend {
  @override
  Future<AutostartStatus> isEnabled() async {
    if (!Platform.isWindows) {
      return const AutostartStatus(
        enabled: false,
        platform: AutostartSupport.unsupported,
      );
    }
    // Future improvement: read HKCU\…\Run\EasyPass via ProcessRegistry. Out
    // of scope — Windows autostart remains "managed by the
    // installer". The Settings UI hides the toggle on non-Linux.
    return const AutostartStatus(
      enabled: false,
      platform: AutostartSupport.unsupported,
    );
  }

  @override
  Future<void> enable() async {
    throw AutostartException(
      'Autostart on Windows is managed by the installer. '
      'Re-run the installer and tick the "launch at login" option.',
    );
  }

  @override
  Future<void> disable() async {
    throw AutostartException(
      'Autostart on Windows is managed by the installer. '
      'Uninstall EasyPass or untick the "launch at login" option there.',
    );
  }

  @override
  Future<String> resolveExecutableForDesktopEntry() async {
    throw AutostartException('Not applicable on Windows');
  }
}