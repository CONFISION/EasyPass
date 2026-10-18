// 开机自启 facade。
//
// **3.0.0 起主分支只支持 Windows**：自启项由安装器写 `HKCU\…\Run\EasyPass`
// （`installer/easypass_setup.iss` 的 `[Code]`，指向
// `{app}\core\easypass_core.exe --serve`）。Dart 侧不写任何自启配置，所以这里
// 恒为 [AutostartSupport.unsupported]，开关在设置页显示为"由安装器管理"。
//
// Linux 适配（XDG `~/.config/autostart/easypass.desktop` + `Exec=<核心> --serve`
// 的路径解析，以及 `linux_autostart.dart`）完整保存在 git 的 `linux` 分支
// （`3312384`），需要时可以取回。
//
// 保留这层 facade 的理由：调用方（`lib/app.dart` 的 provider、设置页的
// `_AutostartTile`）不必关心平台；将来若真有第二个平台，只需在
// [AutostartCoordinator] 里换实现，调用姿势不变。

/// 三态：当前进程平台对自启是否生效。
enum AutostartSupport {
  /// 本平台由 Dart 侧直接读写自启配置（主分支上目前没有这种平台）。
  supported,

  /// 自启归 OS 自身的机制（Windows = 注册表 / 安装器）。
  unsupported,
}

/// 自启状态机：用户视角的「打开 / 关闭」开关。
class AutostartStatus {
  const AutostartStatus({
    required this.enabled,
    this.detail,
    this.platform,
  });

  /// 当前自启是否启用。
  final bool enabled;

  /// 读取 / 写入失败的诊断信息（写入失败时 detail 会同步抛出异常，但
  /// 读取失败只挂这里 —— 写开关永远走异常路径，便于 UI 用 SnackBar）。
  final String? detail;

  /// 平台标签（写日志 / 测试用）。
  final AutostartSupport? platform;
}

/// 启用/关闭自启出错时抛 —— UI 层捕获后用 SnackBar 提示。
class AutostartException implements Exception {
  AutostartException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message ($cause)';
}

/// 自启协调器：主分支上恒为"由安装器管理"。
class AutostartCoordinator {
  const AutostartCoordinator();

  /// 当前自启是否启用。
  ///
  /// Windows 上自启由安装器的 `[Code]` 段写注册表，Dart 侧不去读它（也不该
  /// 读：注册表项的存活与卸载由安装器负责），所以这里恒报未启用 + 未支持，
  /// 设置页据此把开关显示成不可操作并说明原因。
  Future<AutostartStatus> query() async {
    return const AutostartStatus(
      enabled: false,
      platform: AutostartSupport.unsupported,
    );
  }

  /// 启用自启。失败抛 [AutostartException]。
  Future<void> enable() async {
    throw AutostartException(
      'Autostart on Windows is managed by the installer. '
      'Re-run the installer and tick the "launch at login" option.',
    );
  }

  /// 关闭自启。失败抛 [AutostartException]。
  Future<void> disable() async {
    throw AutostartException(
      'Autostart on Windows is managed by the installer. '
      'Uninstall EasyPass or untick the "launch at login" option there.',
    );
  }
}
