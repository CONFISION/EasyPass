import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/utils/font_name_parser.dart';

/// Result of font discovery: bundled (app asset) fonts take precedence over
/// system fonts, matching the user's requested search order.
class FontList {
  final List<String> bundled;
  final List<String> system;

  const FontList({required this.bundled, required this.system});

  /// All families, bundled first (deduplicated).
  List<String> get all => [
        ...bundled,
        ...system.where((f) => !bundled.contains(f)),
      ];
}

/// Discovers and loads fonts for the app.
///
/// Bundled fonts live next to the executable under `assets/fonts/` (they are
/// software assets, not embedded into the binary). System fonts are read from
/// the OS font folders. Search order is: bundled first, then system fonts.
class FontDiscoveryService {
  FontDiscoveryService._();

  /// Reading the first 1 MiB of a font file is plenty to reach its `name`
  /// table (including TrueType collections).
  static const int _maxReadBytes = 1 << 20;

  static Directory _bundledFontDir() {
    return Directory(
      p.join(p.dirname(Platform.resolvedExecutable), 'assets', 'fonts'),
    );
  }

  /// Fonts shipped next to the executable under `assets/fonts/`.
  static Future<List<String>> discoverBundledFonts() async {
    return _scanDirectory(_bundledFontDir());
  }

  /// Fonts registered in the system font folders（本分支只有 Windows）。
  ///
  /// Windows: `C:\Windows\Fonts` + `%LOCALAPPDATA%\Microsoft\Windows\Fonts`。
  /// 其它平台返回空列表 —— Linux 的 Fontconfig 目录扫描随 `linux` 分支维护。
  ///
  /// 测试可通过 [_systemFontDirectories] 的可注入替身替换路径列表，无需
  /// 真实系统字体目录也能跑。
  static Future<List<String>> discoverSystemFonts() async {
    final override = _systemFontDirectoriesOverride;
    final dirs = override ?? _systemFontDirectories();
    // 注入的候选目录（测试用临时目录）按递归扫，模拟"字体在子目录里"的真实
    // 形态；生产路径（Windows 字体目录）保持只扫顶层，以免误碰意外文件。
    final recursive = override != null;
    final names = <String>{};
    for (final dir in dirs) {
      names.addAll(await _scanDirectory(dir, recursive: recursive));
    }
    return names.toList()..sort();
  }

  /// 系统字体目录列表（按优先级顺序）。
  ///
  /// 默认实现：Windows 用 `C:\Windows\Fonts` + `%LOCALAPPDATA%\Microsoft\
  /// Windows\Fonts`（既有行为）；其他平台返回空列表（macOS / 测试 stub 都走
  /// 这条）。
  ///
  /// 测试可注入：见 `_systemFontDirectoriesOverride`；生产代码不直接调这个
  /// getter —— 走 [discoverSystemFonts]。
  static List<Directory> _systemFontDirectories() {
    if (Platform.isWindows) return _windowsSystemFontDirectories();
    return const <Directory>[];
  }

  static List<Directory> _windowsSystemFontDirectories() {
    final dirs = <Directory>[Directory(r'C:\Windows\Fonts')];
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null) {
      dirs.add(
        Directory(p.join(localAppData, 'Microsoft', 'Windows', 'Fonts')),
      );
    }
    return dirs;
  }

  /// 把字体目录列表临时替换成测试替身（仅内存）。**必须**在
  /// `addTearDown` 调 [debugResetSystemFontDirectoriesForTesting] 还原，
  /// 否则会污染跨测试的全局状态。
  static List<Directory>? _systemFontDirectoriesOverride;

  /// 测试钩子：把 [discoverSystemFonts] 的目录列表替换成 [override]。
  /// 生产代码**绝不**调这个函数；命名沿用 `desktop_tray_test.dart` 同款
  /// `debugSet…ForTesting` 风格。
  static void debugSetSystemFontDirectoriesForTesting(
      List<Directory>? override) {
    _systemFontDirectoriesOverride = override;
  }

  /// 测试钩子：还原默认的目录列表。
  static void debugResetSystemFontDirectoriesForTesting() {
    _systemFontDirectoriesOverride = null;
  }

  /// Bundled + system families; bundled entries are listed first.
  static Future<FontList> discoverAvailableFonts() async {
    final bundled = await discoverBundledFonts();
    final system = await discoverSystemFonts();
    return FontList(bundled: bundled, system: system);
  }

  /// Registers bundled fonts with the text engine via [FontLoader], so they
  /// can be referenced by their family name at runtime without being
  /// embedded into the executable.
  static Future<void> loadBundledFonts() async {
    final dir = _bundledFontDir();
    if (!await dir.exists()) return;

    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final lower = entity.path.toLowerCase();
      if (!lower.endsWith('.ttf') && !lower.endsWith('.otf')) continue;
      try {
        final bytes = await entity.readAsBytes();
        final family = FontNameParser.familyName(bytes);
        if (family == null || family.isEmpty) continue;
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      } catch (_) {
        // Skip unreadable or malformed font files.
      }
    }
  }

  static Future<List<String>> _scanDirectory(
    Directory dir, {
    bool recursive = false,
  }) async {
    final names = <String>{};
    if (!await dir.exists()) return [];

    await for (final entity in dir.list(recursive: recursive)) {
      if (entity is! File) continue;
      final lower = entity.path.toLowerCase();
      if (!lower.endsWith('.ttf') &&
          !lower.endsWith('.otf') &&
          !lower.endsWith('.ttc')) {
        continue;
      }
      final family = await _familyNameOf(entity);
      if (family != null && family.isNotEmpty) names.add(family);
    }
    return names.toList()..sort();
  }

  static Future<String?> _familyNameOf(File file) async {
    try {
      final len = await file.length();
      if (len < 12) return null;
      final raf = await file.open();
      try {
        final readLen = len < _maxReadBytes ? len : _maxReadBytes;
        final bytes = Uint8List.fromList(await raf.read(readLen));
        return FontNameParser.familyName(bytes);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }
}
