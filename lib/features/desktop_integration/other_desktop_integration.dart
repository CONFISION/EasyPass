// 非 Linux 平台的桌面集成桩。
//
// Windows 的快捷方式 / 开始菜单项由 Inno Setup 安装器负责（见
// `installer/easypass_setup.iss`），本模块在 Windows 上一个字节都不写 ——
// `windows/` 目录零改动、Windows 正常路径行为不变。
//
// 与 `desktop_autostart/other_autostart.dart` 同款：协调器在非 Linux 上
// 直接返回 `unsupported`，这里的实现只是让"后端接口"在任何平台都可构造。

import 'dart:io' show Platform;

import 'desktop_integration.dart';

class OtherDesktopIntegration implements DesktopIntegrationBackend {
  @override
  Future<DesktopEntryInstallResult> install() async {
    return DesktopEntryInstallResult.skipped(
      platform: Platform.operatingSystem,
    );
  }

  @override
  Future<DesktopEntryUninstallResult> uninstall() async {
    return DesktopEntryUninstallResult.skipped(
      platform: Platform.operatingSystem,
    );
  }

  @override
  Future<DesktopStatus> status() async {
    return DesktopStatus(checked: false, platform: Platform.operatingSystem);
  }
}
