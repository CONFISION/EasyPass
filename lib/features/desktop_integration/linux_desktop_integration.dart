// Linux 桌面集成实现：`$XDG_DATA_HOME/applications/easypass.desktop` +
// `$XDG_DATA_HOME/icons/hicolor/<W>x<H>/apps/easypass.png`。
//
// 字段依据：
//   - freedesktop.org **Desktop Entry Specification**（`[Desktop Entry]`、
//     `Type`、`Name`、`Exec`、`Icon`、`Categories`、`Terminal`、
//     `StartupWMClass`，以及 Exec 的引号/转义规则）。
//   - freedesktop.org **Base Directory Specification**：`XDG_DATA_HOME`
//     未设置或为空 → 默认 `$HOME/.local/share`（**不是** `~/.config`）。
//   - freedesktop.org **Icon Theme Specification**：应用图标按
//     `hicolor/<size>x<size>/apps/<name>.png` 存放。
//
// 全部取值的取证/推导过程见 `dist/P4-facts.md`。本文件只做机械实现。
//
// 不变量：
//   - 幂等（覆盖写，不追加）；卸载没装过也成功。
//   - 任何 IO 失败 → [DesktopIntegrationException]（basename 脱敏）。
//   - 缓存刷新 / 图标源缺失 = best-effort（warning，不影响退出码）。

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'desktop_integration.dart';

class LinuxDesktopIntegration implements DesktopIntegrationBackend {
  LinuxDesktopIntegration({
    this.homeDirectory,
    this.xdgDataHome,
    this.executablePath,
    this.appImagePath,
    this.desktopEntryPathOverride,
    this.iconSourceCandidatesOverride,
    this.environment,
    this.processRunner,
  });

  /// `.desktop` 文件名（也是 GNOME/Wayland 按 basename 匹配 app_id 的候选）。
  static const String entryFileName = 'easypass.desktop';

  /// `Name=` 字段（桌面环境显示名）。
  static const String desktopName = 'EasyPass';

  /// `Icon=` 字段与图标文件名（`hicolor/<size>/apps/easypass.png`）。
  static const String iconName = 'easypass';

  /// 仓库里图标源文件名（`assets/icons/Easypass.png`，1024×1024 RGBA）。
  static const String iconSourceFileName = 'Easypass.png';

  /// `StartupWMClass=` 取值。
  ///
  /// **依据（见 `dist/P4-facts.md` §1）**：`linux/CMakeLists.txt:10` 定义
  /// `APPLICATION_ID "com.example.easypass"`，`linux/runner/my_application.cc:143`
  /// 把它交给 `g_set_prgname()`、`:146` 作为 GTK application-id；全仓库
  /// **没有** `gtk_window_set_wmclass` / `gdk_set_program_class` 调用 ——
  /// 也就是说 WMClass 完全由 GTK/GDK 从 prgname（= application id）推导，
  /// 不是应用自己设的字符串。因此这里与之保持一致，写同一个值。
  ///
  /// **注意**：真实 X11 会话下的 `xprop WM_CLASS` 尚未实测（见 P4-facts
  /// 的"未确认 + 需要什么证据"）。若实测发现 res_class 首字母被大写
  /// （GDK 的历史行为），需要把本常量改成实测值 —— 这是唯一需要跟着改的地方。
  static const String startupWmClass = 'com.example.easypass';

  /// `Exec=` 里的 URL 占位符（`%U` = 可接受多个 URL；与桌面环境约定一致）。
  static const String execUrlPlaceholder = '%U';

  /// 注入点：`$HOME`（默认读环境变量）。
  final String? homeDirectory;

  /// 注入点：`$XDG_DATA_HOME`（默认读环境变量，未设则 `$HOME/.local/share`）。
  final String? xdgDataHome;

  /// 注入点：非 AppImage 形态下 `Exec=` 用的可执行入口（默认
  /// `Platform.resolvedExecutable`）。
  final String? executablePath;

  /// 注入点：`$APPIMAGE`（默认读环境变量）。
  final String? appImagePath;

  /// 注入点：入口文件路径（测试用；生产走 XDG 解析）。
  final String? desktopEntryPathOverride;

  /// 注入点：图标源候选列表（测试用；生产走 [iconSourceCandidates]）。
  final List<String>? iconSourceCandidatesOverride;

  /// 注入点：环境变量表（默认 `Platform.environment`）。
  final Map<String, String>? environment;

  /// 注入点：进程执行器（默认 `Process.run`）—— 让缓存刷新/chmod 可单测。
  final Future<ProcessResult> Function(String, List<String>)? processRunner;

  Map<String, String> get _env => environment ?? Platform.environment;

  String get _home {
    final injected = homeDirectory ?? _env['HOME'];
    if (injected == null || injected.isEmpty) {
      throw DesktopIntegrationException(
        'HOME is not set; cannot resolve the XDG data home',
      );
    }
    return injected;
  }

  /// `$XDG_DATA_HOME`；未设置/空 → `$HOME/.local/share`（Base Directory Spec）。
  String get dataHome {
    final configured = xdgDataHome ?? _env['XDG_DATA_HOME'];
    if (configured != null && configured.isNotEmpty) return configured;
    return p.join(_home, '.local', 'share');
  }

  /// 入口文件绝对路径（`<dataHome>/applications/easypass.desktop`）。
  String get desktopEntryPath =>
      desktopEntryPathOverride ?? p.join(applicationsDirectory, entryFileName);

  /// `<dataHome>/applications/`。
  String get applicationsDirectory => p.join(dataHome, 'applications');

  /// `<dataHome>/icons/hicolor/`。
  String get hicolorDirectory => p.join(dataHome, 'icons', 'hicolor');

  /// `<size>x<size>` 对应的图标绝对路径。
  String iconPathForSize(int size) =>
      p.join(hicolorDirectory, '${size}x$size', 'apps', '$iconName.png');

  /// `Exec=` 要写的可执行入口绝对路径。
  ///
  /// AppImage 形态下 `$APPIMAGE` 指向持久文件（`Platform.resolvedExecutable`
  /// 指向 AppImage 挂载的临时目录，退出即失效）——与
  /// `LinuxAutostart.resolveExecutableForDesktopEntry()` 同一套优先级。
  String resolveExecutableForDesktopEntry() {
    final appImage = appImagePath ?? _env['APPIMAGE'];
    if (appImage != null && appImage.isNotEmpty) return appImage;
    final injected = executablePath;
    if (injected != null && injected.isNotEmpty) return injected;
    return Platform.resolvedExecutable;
  }

  /// 运行中二进制的路径。
  ///
  /// 与 [resolveExecutableForDesktopEntry] **不是同一件事**：`Exec=` 要写
  /// **持久**路径（AppImage 文件），而图标要在**运行环境里**找 —— AppImage
  /// 挂载点 / 解包目录里的二进制旁边才有 `assets/icons/`。所以这里只认
  /// [executablePath]（测试注入）或 `Platform.resolvedExecutable`。
  String get _runningExecutablePath {
    final injected = executablePath;
    if (injected != null && injected.isNotEmpty) return injected;
    return Platform.resolvedExecutable;
  }

  /// 图标源的候选位置（按顺序取第一个存在的）。
  ///
  /// 每个基准目录下探两个位置：`<base>/Easypass.png`（AppDir 顶层）与
  /// `<base>/assets/icons/Easypass.png`（`linux/CMakeLists.txt` 的 install
  /// 规则，与 `assets/fonts` 同款）。基准目录按优先级：
  ///   1. `$APPDIR` —— AppImage runtime 注入的挂载根（打包时图标在顶层）。
  ///   2. 运行中二进制所在目录 —— 挂载点 `usr/bin/` 或解包目录 `usr/bin/`。
  ///   3. 开发树：`build/linux/x64/release/bundle/` 往上 4 层 = 仓库根。
  ///   4. `$APPIMAGE` 所在目录 —— 用户把 `easypass.png` 与 AppImage 放一起的场景。
  List<String> iconSourceCandidates() {
    final override = iconSourceCandidatesOverride;
    if (override != null) return override;

    final candidates = <String>[];
    void add(String path) {
      final normalized = p.normalize(path);
      if (!candidates.contains(normalized)) candidates.add(normalized);
    }

    void addBase(String base, {bool withParentIcon = false}) {
      // 两种文件名都要认：AppDir 顶层 / 已安装目录里是 `easypass.png`
      // （`Icon=easypass` 的约定，也是 appimagetool 要求的名字），
      // 仓库资产与 CMake install 规则则叫 `Easypass.png`。
      add(p.join(base, '$iconName.png'));
      add(p.join(base, iconSourceFileName));
      add(p.join(base, 'assets', 'icons', iconSourceFileName));
      if (withParentIcon) {
        add(p.join(base, '..', '$iconName.png'));
        add(p.join(base, '..', iconSourceFileName));
      }
    }

    final appDir = _env['APPDIR'];
    if (appDir != null && appDir.isNotEmpty) addBase(appDir);

    final exeDir = p.dirname(_runningExecutablePath);
    addBase(exeDir, withParentIcon: true);
    add(p.join(exeDir, '..', '..', '..', '..', 'assets', 'icons',
        iconSourceFileName));

    final appImage = appImagePath ?? _env['APPIMAGE'];
    if (appImage != null && appImage.isNotEmpty) {
      addBase(p.dirname(appImage));
    }
    return candidates;
  }

  // ─── Service entry points ─────────────────────────────────────────────

  @override
  Future<DesktopEntryInstallResult> install() async {
    final warnings = <String>[];
    final created = <String>[];
    final iconPaths = <String>[];

    final entryPath = desktopEntryPath;
    final execPath = resolveExecutableForDesktopEntry();
    final execCommand = '${_escapeExecArgument(execPath)} $execUrlPlaceholder';
    final content = renderDesktopEntry(
      execPath: execPath,
      iconName: iconName,
      wmClass: startupWmClass,
      name: desktopName,
    );

    try {
      await _ensureDirectory(p.dirname(entryPath), created);
      await File(entryPath).writeAsString(content, flush: true);
    } on FileSystemException catch (e) {
      throw DesktopIntegrationException(
        'Failed to write ${p.basename(entryPath)} '
        '(${e.osError?.errorCode ?? e.runtimeType})',
        e,
      );
    }
    await _chmodBestEffort(entryPath, '0644');

    // 图标：源缺失 = warning（不阻挡 .desktop 交付），尺寸按 PNG 头部实测。
    final source = await _findIconSource();
    if (source == null) {
      warnings.add(
        'Icon source ($iconSourceFileName) not found next to the executable; '
        'the ${entryPath.split(Platform.pathSeparator).last} entry still points '
        'at Icon=$iconName, which may not resolve.',
      );
    } else {
      try {
        final bytes = await File(source).readAsBytes();
        final size = pngSquareSize(bytes);
        if (size == null) {
          warnings.add(
            'Icon source $source is not a readable PNG; skipped icon install.',
          );
        } else {
          final iconPath = iconPathForSize(size);
          await _ensureDirectory(p.dirname(iconPath), created);
          await File(iconPath).writeAsBytes(bytes, flush: true);
          await _chmodBestEffort(iconPath, '0644');
          iconPaths.add(iconPath);
        }
      } on FileSystemException catch (e) {
        warnings.add(
          'Failed to install icon from $source '
          '(${e.osError?.errorCode ?? e.runtimeType}); continuing.',
        );
      }
    }

    warnings.addAll(await _refreshCaches());

    return DesktopEntryInstallResult(
      installed: true,
      desktopEntryPath: entryPath,
      execCommand: execCommand,
      startupWmClass: startupWmClass,
      iconPaths: iconPaths,
      createdDirectories: created,
      warnings: warnings,
    );
  }

  @override
  Future<DesktopEntryUninstallResult> uninstall() async {
    final warnings = <String>[];
    final pruned = <String>[];
    final removedIcons = <String>[];

    final entryPath = desktopEntryPath;
    var entryRemoved = false;
    try {
      final entry = File(entryPath);
      if (await entry.exists()) {
        await entry.delete();
        entryRemoved = true;
      }
    } on FileSystemException catch (e) {
      throw DesktopIntegrationException(
        'Failed to delete ${p.basename(entryPath)} '
        '(${e.osError?.errorCode ?? e.runtimeType})',
        e,
      );
    }

    // 图标：扫 `<hicolor>/<size>x<size>/apps/easypass.png` 的既有尺寸目录。
    // 只删精确文件名，绝不 glob 删别的应用图标。
    final hicolor = Directory(hicolorDirectory);
    final iconDirs = <String>[];
    if (await hicolor.exists()) {
      try {
        final entries = await hicolor.list().toList();
        for (final e in entries) {
          if (e is! Directory) continue;
          if (!_sizeDirName.hasMatch(p.basename(e.path))) continue;
          final iconPath = p.join(e.path, 'apps', '$iconName.png');
          if (await File(iconPath).exists()) {
            await File(iconPath).delete();
            removedIcons.add(iconPath);
          }
          iconDirs.add(p.join(e.path, 'apps'));
          iconDirs.add(e.path);
        }
      } on FileSystemException catch (e) {
        warnings.add(
          'Failed to enumerate ${p.basename(hicolorDirectory)} '
          '(${e.osError?.errorCode ?? e.runtimeType}); skipping icon cleanup.',
        );
      }
    }

    // 先刷新缓存（best-effort），**再**清空目录 —— 因为
    // `update-desktop-database` / `gtk-update-icon-cache` 会在父目录里
    // 写入/删掉 `mimeinfo.cache` / `icon-theme.cache`：先刷再删，才能看到
    // 目录的最终状态（否则可能把"刷新时会腾空"的目录当成非空而留下残渣）。
    warnings.addAll(await _refreshCaches());

    // 清空目录：只清“我们写文件的那几层”，且**必须为空**才删。
    // 顺序 = 由深到浅（先子后父）；停在 `<dataHome>` 之前。
    // 若某层还有别的应用的东西（非空）→ 自动停下，不会误删。
    await _pruneIfEmpty(Directory(applicationsDirectory), pruned, warnings);
    for (final dir in iconDirs) {
      await _pruneIfEmpty(Directory(dir), pruned, warnings);
    }
    await _pruneIfEmpty(Directory(hicolorDirectory), pruned, warnings);
    await _pruneIfEmpty(
      Directory(p.join(dataHome, 'icons')),
      pruned,
      warnings,
    );

    return DesktopEntryUninstallResult(
      uninstalled: true,
      desktopEntryPath: entryPath,
      entryRemoved: entryRemoved,
      iconsRemoved: removedIcons,
      prunedDirectories: pruned,
      warnings: warnings,
    );
  }

  @override
  Future<DesktopStatus> status() async {
    final entryPath = desktopEntryPath;
    final iconPaths = await _existingIconPaths();
    final entry = File(entryPath);
    if (!await entry.exists()) {
      return DesktopStatus(
        checked: true,
        desktopEntryPath: entryPath,
        entryExists: false,
        iconPaths: iconPaths,
        iconAvailable: iconPaths.isNotEmpty,
      );
    }

    String? execField;
    String? execTarget;
    String? wmClass;
    var looksLikeOurs = false;
    try {
      final text = await entry.readAsString();
      looksLikeOurs = text.contains('[Desktop Entry]') &&
          text.contains('Name=$desktopName') &&
          text.contains('Type=Application');
      execField = _readField(text, 'Exec');
      wmClass = _readField(text, 'StartupWMClass');
      execTarget = parseExecTarget(execField);
    } on FileSystemException catch (_) {
      // 读不了 → 视作"入口在但不可用"（execTarget 保持 null）。
    }

    var executable = false;
    if (execTarget != null) {
      try {
        final stat = await File(execTarget).stat();
        executable = stat.type == FileSystemEntityType.file &&
            (stat.mode & _anyExecuteBit) != 0;
      } on FileSystemException catch (_) {
        executable = false;
      }
    }

    return DesktopStatus(
      checked: true,
      desktopEntryPath: entryPath,
      entryExists: true,
      looksLikeOurs: looksLikeOurs,
      execField: execField,
      execTarget: execTarget,
      execTargetExecutable: executable,
      iconPaths: iconPaths,
      iconAvailable: iconPaths.isNotEmpty,
      startupWmClass: wmClass,
    );
  }

  // ─── Rendering helpers ────────────────────────────────────────────────

  /// 渲染 `.desktop` 全文（尾随换行，LF）。
  ///
  /// 字段说明：
  ///   - `Type=Application` —— 启动的是应用。
  ///   - `Exec=<绝对路径> %U` —— Spec 显式禁止相对路径；`%U` 表示可接受 URL。
  ///   - `Icon=easypass` —— 名字型引用，由 hicolor 主题解析（见 install()）。
  ///   - `Categories=Utility;Security;` —— 任务书点名。
  ///   - `Terminal=false` —— 不起终端。
  ///   - `StartupWMClass=` —— 让桌面环境把运行中的窗口归到本入口
  ///     （取值依据见 [startupWmClass]）。
  ///   - **不写** `StartupNotify`：Spec 缺省 false，Flutter 的 GTK runner
  ///     没有 `gtk_window_present_with_time` 握手，显式 `true` 反而会让
  ///     启动指示器等超时。
  static String renderDesktopEntry({
    required String execPath,
    required String iconName,
    required String wmClass,
    required String name,
    String comment = 'EasyPass password manager',
  }) {
    return [
      '[Desktop Entry]',
      'Type=Application',
      'Version=1.0',
      'Name=$name',
      'Comment=$comment',
      'Exec=${_escapeExecArgument(execPath)} $execUrlPlaceholder',
      'Icon=$iconName',
      'Terminal=false',
      'Categories=Utility;Security;',
      'StartupWMClass=$wmClass',
      '',
    ].join('\n');
  }

  /// Exec 字段的单参数转义（Desktop Entry Spec §"The Exec key"）。
  ///
  /// 含保留字符（空格 / 制表 / 换行 / `"'\><~|&;$*?#()` / 反引号）的参数必须
  /// 整体用双引号包起来；双引号内 `"`、`` ` ``、`$`、`\` 需要反斜杠转义。
  /// 不含保留字符时**不加引号** —— 有些老解析器对无谓的引号并不宽容。
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

  /// 从 `Exec=` 字面量里取出第一个参数（可执行入口）。
  ///
  /// 支持 `"…"` 双引号形态（含 `\"` / `` \` `` / `\$` / `\\` 转义）；
  /// 不加引号时按空白切分。空/非法返回 null。
  static String? parseExecTarget(String? execField) {
    if (execField == null) return null;
    final value = execField.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('"')) {
      final buf = StringBuffer();
      var i = 1;
      while (i < value.length) {
        final ch = value[i];
        if (ch == r'\' && i + 1 < value.length) {
          buf.write(value[i + 1]);
          i += 2;
          continue;
        }
        if (ch == '"') {
          final parsed = buf.toString();
          return parsed.isEmpty ? null : parsed;
        }
        buf.write(ch);
        i++;
      }
      // 没有收尾引号 → 非法。
      return null;
    }
    final first = value.split(RegExp(r'[ \t]')).first;
    return first.isEmpty ? null : first;
  }

  /// 读 `Key=Value` 形式的字段（第一个匹配）。
  static String? _readField(String text, String key) {
    for (final line in text.split('\n')) {
      if (line.startsWith('$key=')) return line.substring(key.length + 1);
    }
    return null;
  }

  /// 从 PNG 头部（IHDR）读尺寸；要求正方形。
  ///
  /// 不做缩放、不伪造尺寸：非方形 / 非 PNG → null（调用方记 warning）。
  /// 只读前 24 字节，不需要解码整张图。
  static int? pngSquareSize(Uint8List bytes) {
    if (bytes.length < 24) return null;
    const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return null;
    }
    // IHDR 必须紧跟签名：长度(4) + 类型(4) + width(4) + height(4)。
    if (bytes[12] != 0x49 || bytes[13] != 0x48 ||
        bytes[14] != 0x44 || bytes[15] != 0x52) {
      return null;
    }
    final width = (bytes[16] << 24) | (bytes[17] << 16) |
        (bytes[18] << 8) | bytes[19];
    final height = (bytes[20] << 24) | (bytes[21] << 16) |
        (bytes[22] << 8) | bytes[23];
    if (width <= 0 || width != height) return null;
    return width;
  }

  // ─── IO helpers ───────────────────────────────────────────────────────

  static final RegExp _sizeDirName = RegExp(r'^\d+x\d+$');

  /// POSIX 任一 execute 位：S_IXUSR|S_IXGRP|S_IXOTH = 0o111。
  static const int _anyExecuteBit = 0x49;

  Future<String?> _findIconSource() async {
    for (final candidate in iconSourceCandidates()) {
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  Future<List<String>> _existingIconPaths() async {
    final out = <String>[];
    final hicolor = Directory(hicolorDirectory);
    if (!await hicolor.exists()) return out;
    try {
      for (final entity in await hicolor.list().toList()) {
        if (entity is! Directory) continue;
        if (!_sizeDirName.hasMatch(p.basename(entity.path))) continue;
        final iconPath = p.join(entity.path, 'apps', '$iconName.png');
        if (await File(iconPath).exists()) out.add(iconPath);
      }
    } on FileSystemException catch (_) {
      // 只读检查：列不出来就当作"没有图标"。
    }
    return out;
  }

  /// 建目录并记录"本次新建的"（卸载时只清这些层的空目录）。
  Future<void> _ensureDirectory(String path, List<String> created) async {
    final dir = Directory(path);
    if (await dir.exists()) return;
    await dir.create(recursive: true);
    // 记录我们从深到浅新建的每一层（用于 prune 只碰自家目录）。
    var current = dir;
    final home = p.normalize(dataHome);
    while (p.normalize(current.path) != home) {
      final normalized = p.normalize(current.path);
      if (!normalized.startsWith(home + Platform.pathSeparator)) break;
      if (!created.contains(normalized)) created.add(normalized);
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
  }

  /// 删空目录（递归向上到 `<dataHome>` 之前）。非空/不存在 → no-op。
  Future<void> _pruneIfEmpty(
    Directory dir,
    List<String> pruned,
    List<String> warnings,
  ) async {
    final target = p.normalize(dir.path);
    final home = p.normalize(dataHome);
    // 安全闸：只碰 `<dataHome>` 之下的目录，且绝不碰 `<dataHome>` 自身。
    if (target == home ||
        !target.startsWith(home + Platform.pathSeparator)) {
      return;
    }
    if (!await dir.exists()) return;
    try {
      final children = await dir.list().toList();
      if (children.isNotEmpty) return;
      await dir.delete();
      pruned.add(target);
    } on FileSystemException catch (e) {
      warnings.add(
        'Could not remove empty directory ${p.basename(target)} '
        '(${e.osError?.errorCode ?? e.runtimeType}); continuing.',
      );
    }
  }

  /// 刷新桌面数据库 / 图标缓存 —— 只允许 best-effort。
  ///
  /// 命令不存在、spawn 失败、非零退出码一律只记 warning；**不影响**流程
  /// 结果与退出码（任务书：命令不存在或失败不得让流程失败）。
  Future<List<String>> _refreshCaches() async {
    final warnings = <String>[];
    await _runBestEffort(
      'update-desktop-database',
      [applicationsDirectory],
      warnings,
    );
    // gtk-update-icon-cache 需要目录里有 index.theme；用户级 hicolor 通常
    // 没有 → 会非零退出，这里按 best-effort 记 warning 即可。
    final hicolor = Directory(hicolorDirectory);
    if (await hicolor.exists()) {
      await _runBestEffort(
        'gtk-update-icon-cache',
        ['-f', '-t', hicolorDirectory],
        warnings,
      );
    }
    return warnings;
  }

  Future<void> _runBestEffort(
    String executable,
    List<String> arguments,
    List<String> warnings,
  ) async {
    try {
      final result = await _run(executable, arguments);
      if (result.exitCode != 0) {
        warnings.add(
          '$executable ${arguments.join(' ')} exited with '
          '${result.exitCode} (cache refresh is best-effort); continuing.',
        );
      }
    } on ProcessException catch (e) {
      warnings.add(
        '$executable is unavailable (${e.errorCode}); '
        'cache refresh is best-effort; continuing.',
      );
    }
  }

  Future<void> _chmodBestEffort(String path, String mode) async {
    try {
      await _run('chmod', [mode, path]);
    } on ProcessException catch (_) {
      // 与 AppPaths.makePrivate / BrowserHostInstaller 同款 best-effort：
      // 没有 chmod 的环境不能让安装失败。
    }
  }

  Future<ProcessResult> _run(String executable, List<String> arguments) {
    final runner = processRunner;
    if (runner != null) return runner(executable, arguments);
    return Process.run(executable, arguments);
  }
}
