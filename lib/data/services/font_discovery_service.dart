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

  /// Fonts registered in the system font folders (Windows for now).
  static Future<List<String>> discoverSystemFonts() async {
    final dirs = <Directory>[];
    if (Platform.isWindows) {
      dirs.add(Directory(r'C:\Windows\Fonts'));
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null) {
        dirs.add(
          Directory(p.join(localAppData, 'Microsoft', 'Windows', 'Fonts')),
        );
      }
    }
    final names = <String>{};
    for (final dir in dirs) {
      names.addAll(await _scanDirectory(dir));
    }
    return names.toList()..sort();
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

  static Future<List<String>> _scanDirectory(Directory dir) async {
    final names = <String>{};
    if (!await dir.exists()) return [];

    await for (final entity in dir.list()) {
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
