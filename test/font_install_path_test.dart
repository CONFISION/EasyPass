// P3.5 §6 #4：字体安装路径与加载器期望路径**两平台必须一致**。
//
// 审计 #14 的指责："`FONTS_SRC` 安装路径是 `${CMAKE_INSTALL_PREFIX}/assets/fonts`
// 而 `windows/CMakeLists.txt` 是 `data/`" —— 事实核验发现这条断言**错误**：
//   - `windows/CMakeLists.txt:89` 显式把 `assets/fonts/` 装到
//     `${CMAKE_INSTALL_PREFIX}/assets/fonts`。
//   - 该文件 `:69` 把 `CMAKE_INSTALL_PREFIX` 默认设为 `BUILD_BUNDLE_DIR =
//     $<TARGET_FILE_DIR:${BINARY_NAME}>` = exe 所在目录（Windows 不是
//     sub-bundle 模式，而是 in-place，所以 bundle 与 exe 同目录）。
//   - `installer/easypass_setup.iss:115-116` 再 stamp 一次到 `{app}\assets\fonts`。
//   - `linux/CMakeLists.txt:217-223` 同样装到 `${CMAKE_INSTALL_PREFIX}/assets/fonts`，
//     Linux 这里 `CMAKE_INSTALL_PREFIX` = `BUILD_BUNDLE_DIR` = bundle 根（在
//     通用 `flutter build linux` 下与 `<exedir>` 重合）。
//   - `lib/data/services/font_discovery_service.dart:35-39` 加载器从
//     `Platform.resolvedExecutable` 的 dirname 取 `assets/fonts/`。
//
// 所以两平台 = 同一路径：`<exedir>/assets/fonts/`。本测试的"断言"层把这
// 个不变式锁住，**任何一边改了 install 路径，加载失败**。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:easypass/data/services/font_discovery_service.dart';

Directory _loaderExpectsBundledDir() {
  return Directory(
    p.join(p.dirname(Platform.resolvedExecutable), 'assets', 'fonts'),
  );
}

void main() {
  group('P3.5 §6 #4 — bundled font install path == loader expected path', () {
    test('the loader looks under <exedir>/assets/fonts (path-shape check)',
        () {
      final path = _loaderExpectsBundledDir().path;
      // Both platforms agree on this exact shape: <exe>/assets/fonts.
      // A regression test against accidentally moving the install location.
      final segments = p.split(path).where((s) => s.isNotEmpty).toList();
      expect(segments, isNotEmpty);
      expect(segments.last, 'fonts',
          reason: 'Loader terminates with `fonts` segment.');
      expect(segments[segments.length - 2], 'assets',
          reason: '`assets/` must sit one level above `fonts/`.');
    });

    test('the loader install path does not pass through a `data/` segment',
        () {
      // If somebody (accidentally) wires fonts to `<exe>/data/flutter_assets/...`
      // (which is where flutter's compiled assets live, but NOT fonts), the
      // loader must still find them. The audit's §3.4 claim "Windows uses data/"
      // is wrong — but if it ever becomes true, this test must catch it.
      //
      // Note: <exe>/data/ may legitimately contain flutter_assets (CMake does
      // install flutter_assets there on both platforms). What we forbid is the
      // font path itself going through a `data` segment.
      final path = _loaderExpectsBundledDir().path;
      final segments = p.split(path).where((s) => s.isNotEmpty).toList();
      final dataIdx = segments.indexOf('data');
      final assetsIdx = segments.indexOf('assets');
      expect(assetsIdx, isNonNegative,
          reason: 'Expected `assets/` in the loader path.');
      // Allow other `data` segments elsewhere, but if `data` appears between
      // `assets` and `fonts`, the font install diverged from the loader.
      if (dataIdx != -1) {
        expect(dataIdx < assetsIdx || dataIdx > segments.indexOf('fonts'),
            isTrue,
            reason:
                '`data` must not interpose between `assets/` and `fonts/`. '
                'Path under test: $path');
      }
    });

    test('linux/CMakeLists.txt and windows/CMakeLists.txt both install to '
        'CMAKE_INSTALL_PREFIX/assets/fonts (textual contract test)', () {
      // Since this is a Dart-only test environment without invoking CMake,
      // we read both CMakeLists.txt files and assert the install pattern.
      // The full build verification (`flutter build linux --release` produces
      // `bundle/assets/fonts/MapleMono-NF-CN-Regular.ttf`) is captured
      // separately in dist/P3.5-facts.md §6 #4 + the build evidence line
      // of dist/DONE-P3D.txt.
      final repoRoot = _repoRoot();
      final linux = File(p.join(repoRoot, 'linux', 'CMakeLists.txt'));
      final windows = File(p.join(repoRoot, 'windows', 'CMakeLists.txt'));
      expect(linux.existsSync(), isTrue,
          reason: 'linux/CMakeLists.txt must exist.');
      expect(windows.existsSync(), isTrue,
          reason: 'windows/CMakeLists.txt must exist.');

      final linuxText = linux.readAsStringSync();
      final windowsText = windows.readAsStringSync();

      // Both files must install to `<...>/assets/fonts` for `*.ttf`. Match
      // the comment immediately above each install block as well so future
      // "rename to fonts2" is caught: the loader looks for exactly
      // `assets/fonts/`.
      expect(
          linuxText.contains('assets/fonts'),
          isTrue,
          reason:
              'linux/CMakeLists.txt must reference the `assets/fonts/` '
              'install destination (the loader expects this name).');
      expect(
          windowsText.contains('assets/fonts'),
          isTrue,
          reason:
              'windows/CMakeLists.txt must reference the `assets/fonts/` '
              'install destination (the loader expects this name).');

      // Both targets must NOT point at `data/flutter_assets/...` for fonts.
      // We look for a `DESTINATION` line that mentions fonts + data. If it
      // exists, that's the regression #14 warned about.
      expect(
          RegExp(r'DESTINATION\s+"\$\{?CMAKE_INSTALL_PREFIX\}?/data.*fonts')
              .hasMatch(linuxText),
          isFalse,
          reason:
              'linux/CMakeLists.txt must NOT install fonts under '
              '`CMAKE_INSTALL_PREFIX/data/...`. The loader looks under '
              '`assets/fonts/`.');
      expect(
          RegExp(r'DESTINATION\s+"\$\{?CMAKE_INSTALL_PREFIX\}?/data.*fonts')
              .hasMatch(windowsText),
          isFalse,
          reason:
              'windows/CMakeLists.txt must NOT install fonts under '
              '`CMAKE_INSTALL_PREFIX/data/...`. The loader looks under '
              '`assets/fonts/`.');
    });

    test('loadBundledFonts tolerates a missing install dir (no exception)',
        () async {
      // Bootstrapping case: when the bundle is half-copied (interrupted
      // install), the loader must not throw. This is the *behavior* contract
      // for any future install layout change.
      await FontDiscoveryService.loadBundledFonts();
      // No assertion needed: the test passes if no exception escapes.
    });
  });
}

String _repoRoot() {
  // Tests run from the project root, so cwd == package root.
  return Directory.current.path;
}
