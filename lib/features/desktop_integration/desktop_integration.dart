// P4 桌面集成 facade。
//
// **3.0.0 起主分支只支持 Windows**：快捷方式 / 应用菜单入口由 Inno Setup
// 安装器负责（`installer/easypass_setup.iss` 的 `[Icons]`），Dart 侧一个字节都
// 不写 —— 默认后端恒为 [OtherDesktopIntegration]，`--install` /
// `--uninstall` / `--desktop-status` 三个 CLI 在 Windows 上打印"用安装器"并退 0
// （行为与 3.0.0 之前完全一致）。
//
// Linux 适配（`$XDG_DATA_HOME/applications/easypass.desktop` + hicolor 图标 +
// `linux_desktop_integration.dart`）完整保存在 git 的 `linux` 分支（`3312384`），
// 需要时可以取回。
//
// 设计原则（沿用 `desktop_autostart/` 既有风格）：
//   1. **可注入、可单测** —— 后端可注入，无需真实桌面会话即可覆盖
//      install / uninstall / status 的委派。
//   2. **失败可读** —— 全部 IO 失败归一为 `DesktopIntegrationException`。
//   3. **零写入** —— 当前平台不写任何桌面集成文件。

import 'other_desktop_integration.dart' as other;

/// 当前平台对"桌面集成"能否生效。
enum DesktopIntegrationSupport {
  /// 由 Dart 侧直接写桌面入口与图标（主分支上目前没有这种平台）。
  supported,

  /// 归 OS 自身机制（Windows = Inno Setup 安装器）。
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

/// 协调器：把调用**原样转给后端**。默认后端恒为 [OtherDesktopIntegration]
/// （Windows 的快捷方式归安装器，本模块零写入）。
///
/// 保留后端注入点：委派契约（install/uninstall/status 三条路径都真的转发）与
/// 异常传播可以在 Windows 上被测到。
class DesktopIntegration {
  DesktopIntegration({DesktopIntegrationBackend? backend})
      : _backend = backend ?? other.OtherDesktopIntegration();

  final DesktopIntegrationBackend _backend;

  Future<DesktopEntryInstallResult> install() => _backend.install();

  Future<DesktopEntryUninstallResult> uninstall() => _backend.uninstall();

  Future<DesktopStatus> status() => _backend.status();
}
