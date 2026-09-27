// Linux 开机自启。
//
// 设计原则：
//   1. 抽象层可注入、可单测 —— 见 [LinuxAutostartBackend]。
//   2. Windows 不受影响 —— 见 [windows_autostart.dart]（no-op 桩）。
//   3. 失败 = 可读 stderr + UI 可读提示，绝不静默卡死。
//
// Linux 上"开机自启"按 freedesktop.org 桌面条目规范写到
// `~/.config/autostart/easypass.desktop`。关闭开关 = 删文件（幂等）。

import 'dart:io' show Platform;

import 'linux_autostart.dart' as linux;
import 'other_autostart.dart' as other;
import 'windows_autostart.dart' as windows;

/// 三态：当前进程平台对自启是否生效。
enum AutostartSupport {
  /// Linux 上有真实写入/读取 `.desktop` 的能力。
  supported,

  /// 非 Linux：自启归 OS 自身的机制（Windows = 注册表 / 安装器）。
  unsupported,
}

/// 自启状态机：用户视角的「打开 / 关闭」开关。
class AutostartStatus {
  const AutostartStatus({
    required this.enabled,
    this.detail,
    this.platform,
  });

  /// 当前 `.desktop` 文件存在 → enabled = true。
  final bool enabled;

  /// 读取 / 写入失败的诊断信息（写入失败时 detail 会同步抛出异常，但
  /// 读取失败只挂这里 —— 写开关永远走异常路径，便于 UI 用 SnackBar）。
  final String? detail;

  /// 平台标签（写日志 / 测试用）。
  final AutostartSupport? platform;
}

/// 后端接口：让 Linux 自启可注入、可测试。
abstract class LinuxAutostartBackend {
  /// 检查当前 `.desktop` 是否存在且内容是 EasyPass 的（防止误读同名文件）。
  Future<AutostartStatus> isEnabled();

  /// 启用：写文件。失败抛 [AutostartException]。
  Future<void> enable();

  /// 关闭：删文件（不存在 = no-op）。
  Future<void> disable();

  /// 解析 `Exec=` 字段将写入的二进制绝对路径。
  Future<String> resolveExecutableForDesktopEntry();
}

/// 启动自启出错时抛 —— UI 层捕获后用 SnackBar 提示。
class AutostartException implements Exception {
  AutostartException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message ($cause)';
}

/// 协调器：根据当前平台决定调用 Linux 真实实现 / no-op 桩。
class LinuxAutostartCoordinator {
  LinuxAutostartCoordinator({LinuxAutostartBackend? backend})
      : _backend = backend ?? _defaultBackend();

  final LinuxAutostartBackend _backend;

  static LinuxAutostartBackend _defaultBackend() {
    if (Platform.isLinux) return linux.LinuxAutostart();
    if (Platform.isWindows) return windows.WindowsAutostart();
    return other.OtherAutostart();
  }

  /// 当前自启是否启用；非 Linux 平台始终返回 disabled + platform=unsupported。
  Future<AutostartStatus> query() async {
    if (!Platform.isLinux) {
      return const AutostartStatus(
        enabled: false,
        platform: AutostartSupport.unsupported,
      );
    }
    try {
      final s = await _backend.isEnabled();
      return AutostartStatus(
        enabled: s.enabled,
        detail: s.detail,
        platform: AutostartSupport.supported,
      );
    } on Object catch (e) {
      return AutostartStatus(
        enabled: false,
        detail: 'Failed to read autostart status: $e',
        platform: AutostartSupport.supported,
      );
    }
  }

  /// 启用自启。失败抛 [AutostartException]。
  Future<void> enable() async {
    if (!Platform.isLinux) {
      throw AutostartException(
        'Autostart is managed by the OS installer on non-Linux platforms.',
      );
    }
    await _backend.enable();
  }

  /// 关闭自启。失败抛 [AutostartException]。
  Future<void> disable() async {
    if (!Platform.isLinux) {
      throw AutostartException(
        'Autostart is managed by the OS installer on non-Linux platforms.',
      );
    }
    await _backend.disable();
  }
}