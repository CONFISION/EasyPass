// 其他桌面平台 no-op 桩。

import 'dart:io' show Platform;

import 'desktop_autostart.dart';

class OtherAutostart implements LinuxAutostartBackend {
  @override
  Future<AutostartStatus> isEnabled() async {
    return const AutostartStatus(
      enabled: false,
      platform: AutostartSupport.unsupported,
    );
  }

  @override
  Future<void> enable() async {
    throw AutostartException(
      'Autostart is not supported on ${Platform.operatingSystem}.',
    );
  }

  @override
  Future<void> disable() async {
    throw AutostartException(
      'Autostart is not supported on ${Platform.operatingSystem}.',
    );
  }

  @override
  Future<String> resolveExecutableForDesktopEntry() async {
    throw AutostartException('Not applicable on ${Platform.operatingSystem}');
  }
}