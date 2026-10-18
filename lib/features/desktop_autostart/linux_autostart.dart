// Linux 真实实现：写 `~/.config/autostart/easypass.desktop`。
//
// `.desktop` 字段基于 freedesktop.org Desktop Entry Specification + autostart
// 子规范，只写桌面环境认账的最小字段集。
//
// 错误归一：所有 IO 失败 → `AutostartException`（带脱敏化的 basename，与
// `AppPaths.makePrivate` 风格一致），由 UI 层捕获后 SnackBar。

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/platform/app_paths.dart';
import 'desktop_autostart.dart';

class LinuxAutostart implements LinuxAutostartBackend {
  LinuxAutostart({
    String? desktopEntryPath,
    Directory? autostartDir,
    this.executablePath,
    this.appImagePath,
    this.appDirPath,
    this.environment,
  })  : _desktopEntryPath =
            desktopEntryPath ?? AppPaths.resolveLinuxAutostartDesktopEntryPath()!,
        _autostartDir = autostartDir ?? AppPaths.autostartDirectory;

  final String _desktopEntryPath;
  final Directory _autostartDir;

  /// 注入点：UI 二进制路径（默认 `Platform.resolvedExecutable`）。
  final String? executablePath;

  /// 注入点：`$APPIMAGE`（默认读环境变量）。
  final String? appImagePath;

  /// 注入点：`$APPDIR`（默认读环境变量）。
  final String? appDirPath;

  /// 注入点：环境变量表（默认 `Platform.environment`）。
  final Map<String, String>? environment;

  /// 我们写的 `.desktop` 文件指纹，写回读时用来排除"同名但不是我们写的"。
  static const String _marker = 'EasyPass';

  /// 核心服务可执行文件名（与 `tool/build_core.sh` / Windows 侧一致）。
  static const String coreBinaryName = 'easypass_core';

  Map<String, String> get _env => environment ?? Platform.environment;

  String? get _appImage {
    final value = appImagePath ?? _env['APPIMAGE'];
    return (value == null || value.isEmpty) ? null : value;
  }

  String? get _appDir {
    final value = appDirPath ?? _env['APPDIR'];
    return (value == null || value.isEmpty) ? null : value;
  }

  /// 运行中 UI 二进制的路径（注入优先，否则 `Platform.resolvedExecutable`）。
  String get _uiExecutablePath {
    final injected = executablePath;
    if (injected != null && injected.isNotEmpty) return injected;
    return Platform.resolvedExecutable;
  }

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
      final exec = await resolveExecCommandForDesktopEntry();
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

  /// 核心服务可执行文件的绝对路径；找不到返回 null。
  ///
  /// 解析顺序（3.0.0 核心服务布局）：
  ///   1. `<UI exe 目录>/core/easypass_core` —— 安装 / release 布局。核心必须
  ///      待在子目录里：它的原生库按 `<exe>/../lib/<name>` 解析
  ///      （见 `tool/build_core.sh`）。
  ///   2. `<UI exe 目录>/easypass_core` —— 开发态扁平布局（bundle 目录、
  ///      spike_core 之类 UI 与核心同目录的形态）。
  ///   3. `$APPDIR/usr/bin/core/easypass_core` —— 解包出来的 AppImage 树。
  ///
  /// **AppImage 例外（重要）**：跑在 AppImage 里时（`$APPIMAGE` 已设置）1/2
  /// 指向 `/tmp/.mount_*`、3 指向同一个挂载点 —— 都是**本次运行的临时路径**，
  /// 写进 `~/.config/autostart/` 后下次登录必然不存在，自启项会静默失效。所以
  /// 这种情况下直接判为"没有核心"，由 [resolveExecCommandForDesktopEntry]
  /// 降级回 UI 入口点。（真让 AppImage 开机拉核心，需要 AppRun 支持
  /// `exec "$HERE/usr/bin/core/easypass_core" --serve`，属 installer 侧改动。）
  Future<String?> resolveCoreServicePath() async {
    if (_appImage != null) return null;

    final exeDir = p.dirname(_uiExecutablePath);
    final candidates = <String>[
      p.join(exeDir, 'core', coreBinaryName),
      p.join(exeDir, coreBinaryName),
    ];
    final appDir = _appDir;
    if (appDir != null) {
      candidates.add(p.join(appDir, 'usr', 'bin', 'core', coreBinaryName));
    }
    for (final candidate in candidates) {
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  /// `Exec=` 要写的**命令行**：优先核心服务（`<core> --serve`），核心不可用时
  /// 退回 UI 二进制（不带参数）。
  ///
  /// 降级是刻意的：核心找不到（开发态只 build 了 UI），或当前路径不可持久
  /// （AppImage 挂载点，见 [resolveCoreServicePath]）时，宁可退回旧行为"开机拉起
  /// UI"，也不能写一个下次登录必定失效的自启项。降级路径不带 `--serve` —— 3.0.0
  /// 的 UI 二进制已经没有 `--serve` 模式了。
  @override
  Future<String> resolveExecCommandForDesktopEntry() async {
    final core = await resolveCoreServicePath();
    if (core != null) return '${_escapeExecArgument(core)} --serve';
    return _escapeExecArgument(await _resolveUiEntryPoint());
  }

  /// UI 入口点：AppImage 形态下 `$APPIMAGE` 指向**持久**文件（用它而不是
  /// `Platform.resolvedExecutable` —— 后者是 AppImage mount 的临时路径，移动
  /// AppImage 后会失效，但 `$APPIMAGE` 在自启后仍指向原文件）。非 AppImage
  /// 形态下没有 `$APPIMAGE`，落到 `resolvedExecutable`。
  Future<String> _resolveUiEntryPoint() async {
    final appImage = _appImage;
    if (appImage != null) {
      if (await File(appImage).exists()) return appImage;
      // APPIMAGE 指向的文件已不在 → 退到 resolvedExecutable（行为类似
      // "AppImage 移动后" 的降级：写入的 Exec 仍是当前 exe，但下次启动会
      // 找不到 —— 用户重新开关一次自启可恢复）。
    }
    return _uiExecutablePath;
  }

  /// Exec 字段的单参数转义（Desktop Entry Spec §"The Exec key"）。
  ///
  /// 与 `LinuxDesktopIntegration` 的 `Exec=` 规则一致：含保留字符（空格 /
  /// 制表 / 换行 / `"'\><~|&;$*?#()` / 反引号）的参数整体用双引号包起来，引号内
  /// `"`、`` ` ``、`$`、`\` 反斜杠转义；不含保留字符时**不加引号**（有些老解析器
  /// 对无谓的引号并不宽容）。虽然当前 Exec 里有程序名和 `--serve` 两个参数，但
  /// 整串是按这个规则逐参数拼好的，解析器会正确切分。
  static String _escapeExecArgument(String argument) {
    const reserved = ' \t\n"\'\\><~|&;\$*?#()`';
    final needsQuoting = argument.split('').any(reserved.contains);
    if (!needsQuoting) return argument;
    final escaped = argument
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('`', r'\`')
        .replaceAll(r'$', r'\$');
    return '"$escaped"';
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
  ///   - `Exec=<abs path> [args]` —— 必须**绝对路径**（相对路径被 Spec 显式
  ///     禁止）；3.0.0 起这里写的是核心服务（`<core> --serve`），核心不可用时
  ///     降级为 UI 二进制（见 [resolveExecCommandForDesktopEntry]）。
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