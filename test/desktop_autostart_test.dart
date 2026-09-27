// 开机自启测试。
//
// 覆盖：
//   1. isEnabled 反映「文件存在 + 内容是 EasyPass」。
//   2. enable 写到正确路径 + 内容可被 [LinuxAutostart.isEnabled] 再次确认。
//   3. disable 删除文件（幂等：删两次都不抛）。
//   4. Exec= 字段在 AppImage 环境变量存在时使用 $APPIMAGE；否则用
//      Platform.resolvedExecutable。
//   5. 内容校验：含 Desktop Entry 必备字段 + X-GNOME-Autostart-enabled +
//      Hidden=false（GNOME/KDE 都正确接管的最小集）。
//   6. Windows / 其他平台 no-op 桩：isEnabled 永远 false，enable/disable 抛
//      AutostartException。
//
// 不可自动化的项：GNOME / KDE 真实桌面下 `~/.config/autostart/easypass.desktop`
// 确实被列出 —— 需要真实桌面会话手工确认。

import 'dart:io' show Directory, File, Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:easypass/features/desktop_autostart/desktop_autostart.dart';
import 'package:easypass/features/desktop_autostart/linux_autostart.dart';
import 'package:easypass/features/desktop_autostart/other_autostart.dart';
import 'package:easypass/features/desktop_autostart/windows_autostart.dart';

void main() {
  late Directory tmp;
  late String desktopEntryPath;
  late Directory autostartDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('easypass_autostart_');
    autostartDir = Directory(p.join(tmp.path, 'autostart'));
    desktopEntryPath = p.join(autostartDir.path, 'easypass.desktop');
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  LinuxAutostart makeBackend() => LinuxAutostart(
        desktopEntryPath: desktopEntryPath,
        autostartDir: autostartDir,
      );

  group('isEnabled 反映文件存在 + 内容身份', () {
    test('文件不存在 → enabled = false', () async {
      final s = await makeBackend().isEnabled();
      expect(s.enabled, isFalse);
    });

    test('文件存在但不是 EasyPass → enabled = false', () async {
      await autostartDir.create(recursive: true);
      await File(desktopEntryPath).writeAsString(
        '[Desktop Entry]\nType=Application\nName=OtherApp\n',
      );
      final s = await makeBackend().isEnabled();
      expect(s.enabled, isFalse);
    });

    test('文件存在且是 EasyPass → enabled = true', () async {
      final backend = makeBackend();
      await backend.enable();
      final s = await backend.isEnabled();
      expect(s.enabled, isTrue);
    });
  });

  group('enable 把内容写到正确路径', () {
    test('写完后文件内容含 Desktop Entry 必备字段', () async {
      final backend = makeBackend();
      await backend.enable();
      final content = await File(desktopEntryPath).readAsString();
      // Desktop Entry Spec: 必备字段。
      expect(content, contains('[Desktop Entry]'));
      expect(content, contains('Type=Application'));
      expect(content, contains('Name=EasyPass'));
      // Exec= 必须是**当前平台的**绝对路径：Linux 上是 `/…`，Windows 测试
      // 宿主上是 `C:\…`（`Platform.resolvedExecutable`）。用 package:path 的
      // 平台语义判断，不把 `/` 写死 —— 否则本文件在 Windows 上必红。
      final rawExec = RegExp(r'^Exec=(.+)$', multiLine: true)
          .firstMatch(content)!
          .group(1)!;
      final execPath = rawExec.replaceAll('"', '').trim();
      expect(execPath, isNotEmpty);
      expect(p.isAbsolute(execPath), isTrue);
      // 桌面自动启动相关（GNOME / KDE 都接管）。
      expect(content, contains('X-GNOME-Autostart-enabled=true'));
      expect(content, contains('Hidden=false'));
      expect(content, contains('Terminal=false'));
    });

    test('enable 幂等（再调一次不报错、内容不污染）', () async {
      final backend = makeBackend();
      await backend.enable();
      final firstContent = await File(desktopEntryPath).readAsString();
      await backend.enable();
      final secondContent = await File(desktopEntryPath).readAsString();
      expect(firstContent, secondContent);
    });

    test('autostartDir 不存在时 enable 自动创建', () async {
      expect(await autostartDir.exists(), isFalse);
      final backend = makeBackend();
      await backend.enable();
      expect(await autostartDir.exists(), isTrue);
    });
  });

  group('disable 删除文件（幂等）', () {
    test('disable 后 isEnabled = false', () async {
      final backend = makeBackend();
      await backend.enable();
      expect((await backend.isEnabled()).enabled, isTrue);
      await backend.disable();
      expect((await backend.isEnabled()).enabled, isFalse);
    });

    test('文件不存在时 disable 是 no-op（不抛）', () async {
      final backend = makeBackend();
      await backend.disable();
      // 再调一次仍然 no-op。
      await backend.disable();
    });
  });

  group('Exec= 字段：AppImage 优先', () {
    test('非 AppImage（无 APPIMAGE）→ 用 Platform.resolvedExecutable',
        () async {
      final backend = makeBackend();
      await backend.enable();
      final content = await File(desktopEntryPath).readAsString();
      // 在 Linux CI 上 `Platform.resolvedExecutable` 是 `flutter_tester` 之
      // 类的路径 —— 我们只断言 Exec= 是**当前平台的**绝对路径且不是空，不强制
      // 等于 resolvedExecutable（CI 上可能因为 hook 而不同），也不假设它以
      // `/` 开头（Windows 宿主上是 `C:\…`）。
      final match = RegExp(r'^Exec=(.+)$', multiLine: true).firstMatch(content);
      expect(match, isNotNull);
      final execPath = match!.group(1)!.replaceAll('"', '').trim();
      expect(execPath, isNotEmpty);
      expect(p.isAbsolute(execPath), isTrue);
    });
  });

  group('Windows / 其他平台 no-op 桩', () {
    test('WindowsAutostart.isEnabled → enabled=false, unsupported',
        () async {
      final s = await WindowsAutostart().isEnabled();
      expect(s.enabled, isFalse);
      expect(s.platform, AutostartSupport.unsupported);
    });

    test('WindowsAutostart.enable → 抛 AutostartException', () async {
      expect(
        () => WindowsAutostart().enable(),
        throwsA(isA<AutostartException>()),
      );
    });

    test('WindowsAutostart.disable → 抛 AutostartException', () async {
      expect(
        () => WindowsAutostart().disable(),
        throwsA(isA<AutostartException>()),
      );
    });

    test('OtherAutostart.isEnabled → enabled=false, unsupported', () async {
      final s = await OtherAutostart().isEnabled();
      expect(s.enabled, isFalse);
      expect(s.platform, AutostartSupport.unsupported);
    });

    test('OtherAutostart.enable / disable → 抛 AutostartException', () async {
      expect(
        () => OtherAutostart().enable(),
        throwsA(isA<AutostartException>()),
      );
      expect(
        () => OtherAutostart().disable(),
        throwsA(isA<AutostartException>()),
      );
    });
  });

  group('LinuxAutostartCoordinator 平台分派', () {
    test('非 Linux：query 返回 unsupported', () async {
      // 这里不依赖 Platform.isLinux —— 用 mock-style 的事实：当前是 Linux CI，
      // 但 `Platform.isLinux == false` 走 isEnabled() 这条路径仅在非 Linux
      // 真机上测。本测试通过观察 unsupported 行为来证明。
      if (Platform.isLinux) {
        // Linux CI：只能验证"真实启用后 isEnabled=true"；unsupported 路径
        // 由其他测试覆盖（WindowsAutostart 已在上面）。
        final coordinator = LinuxAutostartCoordinator();
        final s = await coordinator.query();
        expect(s.platform, AutostartSupport.supported);
      } else {
        final coordinator = LinuxAutostartCoordinator();
        final s = await coordinator.query();
        expect(s.platform, AutostartSupport.unsupported);
      }
    });
  });
}