// P4 桌面集成（Linux 生效）：`.desktop` 入口 + hicolor 图标 + 平台协调器。
//
// 设计原则（沿用 `desktop_autostart/` / `browser_bridge/` 既有风格）：
//   1. **可注入、可单测** —— home / XDG 变量 / 入口路径 / 图标源 / 进程执行
//      器全部可注入，无需真实桌面会话即可覆盖 install / uninstall / status。
//   2. **幂等** —— 重复 install 内容一致（整体覆盖写，不追加）；卸载"没装过"
//      也成功；顺手清掉自己建出来的**空**目录，不留残渣。
//   3. **失败可读** —— 全部 IO 失败归一为 `DesktopIntegrationException`
//      （带 basename，不泄漏完整 home 路径），由 CLI 层转成非零退出码。
//   4. **Windows 零影响** —— Windows 的快捷方式由 Inno Setup 安装器负责，
//      本模块在非 Linux 上只返回 `unsupported`，一个字节都不写。

import 'dart:io' show Platform;

import 'linux_desktop_integration.dart' as linux;
import 'other_desktop_integration.dart' as other;

/// 当前平台对"桌面集成"能否生效。
enum DesktopIntegrationSupport {
  /// Linux：写 `$XDG_DATA_HOME/applications/easypass.desktop` + hicolor 图标。
  supported,

  /// 非 Linux：归 OS 自身机制（Windows = Inno Setup 安装器）。
  unsupported,
}

/// `--install` 结果。
class DesktopEntryInstallResult {
  const DesktopEntryInstallResult({
    required this.installed,
    this.platform,
    this.desktopEntryPath,
    this.execCommand,
    this.startupWmClass,
    this.iconPaths = const [],
    this.createdDirectories = const [],
    this.warnings = const [],
  });

  /// Linux 上恒为 true（写文件成功）；非 Linux 恒为 false。
  final bool installed;

  /// 非 Linux 时的平台名（`unsupported` 分支的说明用）。
  final String? platform;

  /// 写入的 `.desktop` 绝对路径。
  final String? desktopEntryPath;

  /// 写进 `Exec=` 的完整命令行（含 `%U`）。
  final String? execCommand;

  /// 写进 `StartupWMClass=` 的值。
  final String? startupWmClass;

  /// 实际安装的图标文件绝对路径（源图缺失时为空）。
  final List<String> iconPaths;

  /// 本次新建的目录（卸载时可用来判断"哪些空目录是我建出来的"）。
  final List<String> createdDirectories;

  /// 非致命的 best-effort 失败（图标源缺失、缓存刷新命令不存在/失败）。
  final List<String> warnings;

  factory DesktopEntryInstallResult.skipped({required String platform}) =>
      DesktopEntryInstallResult(installed: false, platform: platform);

  @override
  String toString() => installed
      ? 'DesktopEntryInstallResult(installed entry=$desktopEntryPath '
          'exec=$execCommand icons=$iconPaths warnings=$warnings)'
      : 'DesktopEntryInstallResult(skipped on $platform)';
}

/// `--uninstall` 结果。
class DesktopEntryUninstallResult {
  const DesktopEntryUninstallResult({
    required this.uninstalled,
    this.platform,
    this.desktopEntryPath,
    this.entryRemoved = false,
    this.iconsRemoved = const [],
    this.prunedDirectories = const [],
    this.warnings = const [],
  });

  /// Linux 上恒为 true（"卸载完成"——没装过也算，幂等）。
  final bool uninstalled;

  final String? platform;
  final String? desktopEntryPath;

  /// 入口文件是否真的被删（false = 本来就不在，no-op）。
  final bool entryRemoved;

  /// 被删掉的图标文件。
  final List<String> iconsRemoved;

  /// 顺手清掉的空目录（只为不留残渣）。
  final List<String> prunedDirectories;

  /// 非致命失败（缓存刷新命令不存在/失败、空目录删不掉）。
  final List<String> warnings;

  factory DesktopEntryUninstallResult.skipped({required String platform}) =>
      DesktopEntryUninstallResult(uninstalled: false, platform: platform);

  @override
  String toString() => uninstalled
      ? 'DesktopEntryUninstallResult(entryRemoved=$entryRemoved '
          'iconsRemoved=$iconsRemoved pruned=$prunedDirectories)'
      : 'DesktopEntryUninstallResult(skipped on $platform)';
}

/// `--desktop-status` 结果（只读，不写任何文件）。
class DesktopStatus {
  const DesktopStatus({
    required this.checked,
    this.platform,
    this.desktopEntryPath = '',
    this.entryExists = false,
    this.looksLikeOurs = false,
    this.execField,
    this.execTarget,
    this.execTargetExecutable = false,
    this.iconPaths = const [],
    this.iconAvailable = false,
    this.startupWmClass,
  });

  /// false = 非 Linux（跳过检查）。
  final bool checked;

  final String? platform;

  /// 本模块**会**写入的入口路径（用于"没装时"提示用户装到哪）。
  final String desktopEntryPath;

  final bool entryExists;

  /// 入口文件是否由 EasyPass 写（含 `[Desktop Entry]` + `Name=EasyPass`）。
  /// 同名但别人写的文件不会被误判成"已安装"。
  final bool looksLikeOurs;

  /// 文件里的 `Exec=` 原始字面量。
  final String? execField;

  /// `Exec=` 解析出的第一个参数（可执行入口）。
  final String? execTarget;

  /// [execTarget] 存在且带任一 execute 位。
  final bool execTargetExecutable;

  /// 探测到存在的图标文件（可能有多个尺寸）。
  final List<String> iconPaths;

  final bool iconAvailable;

  /// 文件里的 `StartupWMClass=` 值。
  final String? startupWmClass;

  /// 已安装且入口可用。
  bool get isInstalled => checked && entryExists && looksLikeOurs && execTargetExecutable;

  /// 入口在、但指向失效（`Exec` 目标不存在/不可执行，或同名文件不是我们写的）。
  bool get pointsAtBrokenTarget =>
      checked && entryExists && !isInstalled;

  /// CLI 退出码语义（与 `--browser-host-status` 的 0/1/2 对齐）：
  ///
  /// - 0 = 已安装且入口可用
  /// - 1 = 入口在但失效（`Exec` 目标丢了 / 同名文件不是我们写的）
  /// - 2 = 未安装（没有入口文件；也包含"非 Linux 跳过"）
  ///
  /// 非 Linux 的 CLI 分支会先把"跳过"打成可读提示并退 0（与
  /// `--install-browser-host` 的 Windows 行为一致），不会走到这里。
  int toExitCode() {
    if (!checked) return 2;
    if (isInstalled) return 0;
    if (entryExists) return 1;
    return 2;
  }

  @override
  String toString() => checked
      ? 'DesktopStatus(entry=$desktopEntryPath exists=$entryExists '
          'ours=$looksLikeOurs exec=$execTarget ok=$execTargetExecutable '
          'icon=$iconAvailable wmClass=$startupWmClass)'
      : 'DesktopStatus(skipped on $platform)';
}

/// 后端接口：让桌面集成可注入、可测试。
abstract class DesktopIntegrationBackend {
  /// 写入口 + 图标（幂等）。
  Future<DesktopEntryInstallResult> install();

  /// 删入口 + 自己装的图标（幂等），并清理空的自家目录。
  Future<DesktopEntryUninstallResult> uninstall();

  /// 只读状态检查。
  Future<DesktopStatus> status();
}

/// 安装/卸载出错时抛 —— CLI 层捕获后打 stderr + 非零退出码。
class DesktopIntegrationException implements Exception {
  DesktopIntegrationException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message ($cause)';
}

/// 协调器：把调用**原样转给后端**。默认后端按平台选 Linux 真实实现 /
/// 非 Linux 桩。
///
/// **本类不再自带 `Platform.isLinux` 闸门**：那个闸门与
/// [OtherDesktopIntegration] 的返回值逐字相同（`…skipped(platform:
/// Platform.operatingSystem)` / `DesktopStatus(checked: false, …)`），却让
/// **注入的后端在非 Linux 上永远收不到调用** —— 委派契约因此没法在 Windows
/// 上测，非 Linux 行为也有了第二条真理来源。默认后端本身就是那个桩。
class DesktopIntegration {
  DesktopIntegration({DesktopIntegrationBackend? backend})
      : _backend = backend ?? _defaultBackend();

  final DesktopIntegrationBackend _backend;

  static DesktopIntegrationBackend _defaultBackend() {
    if (Platform.isLinux) return linux.LinuxDesktopIntegration();
    return other.OtherDesktopIntegration();
  }

  Future<DesktopEntryInstallResult> install() => _backend.install();

  Future<DesktopEntryUninstallResult> uninstall() => _backend.uninstall();

  Future<DesktopStatus> status() => _backend.status();
}
