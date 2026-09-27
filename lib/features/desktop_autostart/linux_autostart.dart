// Linux 真实实现：写 `~/.config/autostart/easypass.desktop`。
//
// `.desktop` 字段基于 freedesktop.org Desktop Entry Specification + autostart
// 子规范。最小可用字段见 `dist/P3.2-facts.md` §4.2。
//
// 错误归一：所有 IO 失败 → `AutostartException`（带脱敏化的 basename，与
// `AppPaths.makePrivate` 风格一致），由 UI 层捕获后 SnackBar。

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/platform/app_paths.dart';
import 'desktop_autostart.dart';

class LinuxAutostart implements LinuxAutostartBackend {
  LinuxAutostart({String? desktopEntryPath, Directory? autostartDir})
      : _desktopEntryPath =
            desktopEntryPath ?? AppPaths.resolveLinuxAutostartDesktopEntryPath()!,
        _autostartDir = autostartDir ?? AppPaths.autostartDirectory;

  final String _desktopEntryPath;
  final Directory _autostartDir;

  /// 我们写的 `.desktop` 文件指纹，写回读时用来排除"同名但不是我们写的"。
  static const String _marker = 'EasyPass';

  @override
  Future<AutostartStatus> isEnabled() async {
    final file = File(_desktopEntryPath);
    if (!await file.exists()) {
      return const AutostartStatus(enabled: false);
    }
    try {
      final content = await file.readAsString();
      // 内容不一定完全一致（用户可能改过），但至少要含 `Name=EasyPass`
      // （避免误把"别的应用也叫 easypass.desktop"的情况认作我们的）。
      final looksOurs = content.contains('Name=$_marker') &&
          content.contains('Type=Application') &&
          content.contains('[Desktop Entry]');
      return AutostartStatus(enabled: looksOurs);
    } on FileSystemException catch (e) {
      return AutostartStatus(
        enabled: false,
        detail: 'Failed to read ${p.basename(_desktopEntryPath)} '
            '(${e.osError?.errorCode ?? e.runtimeType})',
      );
    }
  }

  @override
  Future<void> enable() async {
    try {
      if (!await _autostartDir.exists()) {
        await _autostartDir.create(recursive: true);
      }
      final exec = await resolveExecutableForDesktopEntry();
      final icon = _resolveIconLine();
      // Desktop Entry Spec: 换行必须用 LF（不要 CRLF）。
      final content = _renderDesktopEntry(exec: exec, icon: icon);
      final file = File(_desktopEntryPath);
      await file.writeAsString(content, flush: true);
      // 0o644 即可 —— autostart 目录的权限由用户管理；我们要的是写得进 + 不
      // 因换 umask 而变成 0600（那样桌面会话读不到）。
      // ignore: avoid_print
      // Print is intentionally suppressed; the autostart install is silent.
      // A future debugging flag could surface this via --verbose.
    } on FileSystemException catch (e) {
      throw AutostartException(
        'Failed to write ${p.basename(_desktopEntryPath)} '
            '(${e.osError?.errorCode ?? e.runtimeType})',
        e,
      );
    } catch (e) {
      throw AutostartException(
        'Failed to enable autostart: $e',
        e,
      );
    }
  }

  @override
  Future<void> disable() async {
    final file = File(_desktopEntryPath);
    if (!await file.exists()) return; // idempotent
    try {
      await file.delete();
    } on FileSystemException catch (e) {
      throw AutostartException(
        'Failed to delete ${p.basename(_desktopEntryPath)} '
            '(${e.osError?.errorCode ?? e.runtimeType})',
        e,
      );
    } catch (e) {
      throw AutostartException('Failed to disable autostart: $e', e);
    }
  }

  @override
  Future<String> resolveExecutableForDesktopEntry() async {
    // AppImage 形态下：启动时 `$APPIMAGE` 会被注入到进程环境；用它而不是
    // `Platform.resolvedExecutable`（后者是 AppImage mount 的临时路径，移动
    // AppImage 后会失效，但 `$APPIMAGE` 在自启后仍指向原文件）。非 AppImage
    // 形态下没有 `$APPIMAGE`，落到 `resolvedExecutable`。
    final appImage = Platform.environment['APPIMAGE'];
    if (appImage != null && appImage.isNotEmpty) {
      final f = File(appImage);
      if (await f.exists()) return appImage;
      // APPIMAGE 指向的文件已不在 → 退到 resolvedExecutable（行为类似
      // "AppImage 移动后" 的降级：写入的 Exec 仍是当前 exe，但下次启动会
      // 找不到 —— 用户重新开关一次自启可恢复）。
    }
    return Platform.resolvedExecutable;
  }

  String _resolveIconLine() {
    // 不试图安装图标到 hicolor（那是 P4 桌面集成的活）。`Icon=easypass` 在
    // autostart 上用不到（托盘上才用），但 Spec 要求 Icon 字段；写一个名字
    // 让桌面数据库若未来装了图标能匹配上。
    return 'easypass';
  }

  /// 把多行内容渲染成符合 Desktop Entry Spec 的 `.desktop` 文件。
  ///
  /// 关键字段说明：
  ///   - `Type=Application` —— 启动的是应用，不是 link / dir。
  ///   - `Exec=<abs path>` —— 必须**绝对路径**（相对路径被 Spec 显式禁止）。
  ///   - `Terminal=false` —— 后台静默启动，不开终端。
  ///   - `X-GNOME-Autostart-enabled=true` —— GNOME 上 autostart 必须显式启用
  ///     此 key（默认不启用）。
  ///   - `Hidden=false` —— 显式声明不在 autostart 中隐藏（与
  ///     `X-GNOME-Autostart-enabled` 互补，KDE Plasma 读 Hidden）。
  String _renderDesktopEntry({required String exec, required String icon}) {
    return [
      '[Desktop Entry]',
      'Type=Application',
      'Version=1.0',
      'Name=$_marker',
      'Comment=$_marker password manager',
      'Exec=$exec',
      'Icon=$icon',
      'Terminal=false',
      'Categories=Utility;Security;',
      'StartupNotify=false',
      'X-GNOME-Autostart-enabled=true',
      'Hidden=false',
      '',
    ].join('\n');
  }
}