// 开机自启测试。
//
// 覆盖：
//   1. isEnabled 反映「文件存在 + 内容是 EasyPass」。
//   2. enable 写到正确路径 + 内容可被 [LinuxAutostart.isEnabled] 再次确认。
//   3. disable 删除文件（幂等：删两次都不抛）。
//   4. Exec= 字段：优先核心服务（`<core> --serve`，候选 core/ → 同目录 →
//      $APPDIR），核心不可用时退回 UI 二进制；AppImage 挂载点不写进自启项。
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
import 'package:easypass/features/desktop_integration/linux_desktop_integration.dart';

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

  /// 测试用后端。`environment` 默认给空表：让 APPIMAGE / APPDIR 的判定与宿主
  /// 环境无关（生产代码不传时读 `Platform.environment`）。
  LinuxAutostart makeBackend({
    String? executablePath,
    String? appImagePath,
    String? appDirPath,
    Map<String, String> environment = const <String, String>{},
  }) =>
      LinuxAutostart(
        desktopEntryPath: desktopEntryPath,
        autostartDir: autostartDir,
        executablePath: executablePath,
        appImagePath: appImagePath,
        appDirPath: appDirPath,
        environment: environment,
      );

  /// 读出 `.desktop` 里 `Exec=` 那一行的值。
  String readExecField(String content) =>
      RegExp(r'^Exec=(.+)$', multiLine: true).firstMatch(content)!.group(1)!;

  /// 按 Desktop Entry Spec 解析出 Exec 的**程序**参数（去掉引号与反斜杠转义）。
  ///
  /// 不能直接拿字符串做 `contains(path)`：Spec 要求含保留字符的参数整体加引号并
  /// 转义 `\`，而 Windows 测试宿主上的临时路径**每个反斜杠都会被写成两个** ——
  /// 复用生产代码的解析器（[LinuxDesktopIntegration.parseExecTarget]）才能拿到
  /// 原样的路径。
  String execProgram(String execField) =>
      LinuxDesktopIntegration.parseExecTarget(execField)!;

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

  group('Exec= 字段：核心服务优先（3.0.0）', () {
    /// 造一个"UI 目录"，返回 (uiDir, uiExe) 两个路径。
    Future<(String, String)> makeUiDir(Directory parent, String name) async {
      final uiDir = Directory(p.join(parent.path, name));
      await uiDir.create(recursive: true);
      final uiExe = p.join(uiDir.path, 'easypass');
      await File(uiExe).writeAsString('ui');
      return (uiDir.path, uiExe);
    }

    test('安装布局：<UI 目录>/core/easypass_core 命中，Exec 带 --serve',
        () async {
      final (uiDir, uiExe) = await makeUiDir(tmp, 'app');
      final coreDir = Directory(p.join(uiDir, 'core'));
      await coreDir.create(recursive: true);
      final core = p.join(coreDir.path, LinuxAutostart.coreBinaryName);
      await File(core).writeAsString('core');

      final backend = makeBackend(executablePath: uiExe);
      final resolved = await backend.resolveCoreServicePath();
      expect(resolved, core);

      final exec = await backend.resolveExecCommandForDesktopEntry();
      expect(execProgram(exec), core);
      expect(exec.trim(), endsWith('--serve'));
    });

    test('开发态扁平布局：<UI 目录>/easypass_core 命中（core/ 不存在）',
        () async {
      final (uiDir, uiExe) = await makeUiDir(tmp, 'flat');
      final core = p.join(uiDir, LinuxAutostart.coreBinaryName);
      await File(core).writeAsString('core');

      final backend = makeBackend(executablePath: uiExe);
      expect(await backend.resolveCoreServicePath(), core);
      final exec = await backend.resolveExecCommandForDesktopEntry();
      expect(execProgram(exec), core);
      expect(exec.trim(), endsWith('--serve'));
    });

    test('候选顺序：core/ 与同目录同时存在时取 core/ 子目录', () async {
      final (uiDir, uiExe) = await makeUiDir(tmp, 'both');
      final coreDir = Directory(p.join(uiDir, 'core'));
      await coreDir.create(recursive: true);
      final nested = p.join(coreDir.path, LinuxAutostart.coreBinaryName);
      await File(nested).writeAsString('core');
      await File(p.join(uiDir, LinuxAutostart.coreBinaryName))
          .writeAsString('core');

      expect(await makeBackend(executablePath: uiExe).resolveCoreServicePath(),
          nested);
    });

    test(r'$APPDIR/usr/bin/core/easypass_core 作为最后一档候选（非 AppImage）',
        () async {
      final (_, uiExe) = await makeUiDir(tmp, 'plain');
      final appDir = Directory(p.join(tmp.path, 'squashfs-root'));
      final coreDir = Directory(p.join(appDir.path, 'usr', 'bin', 'core'));
      await coreDir.create(recursive: true);
      final core = p.join(coreDir.path, LinuxAutostart.coreBinaryName);
      await File(core).writeAsString('core');

      final backend = makeBackend(executablePath: uiExe, appDirPath: appDir.path);
      expect(await backend.resolveCoreServicePath(), core);
    });

    test('都找不到 → 退回 UI 二进制（不带 --serve，自启项不失效）', () async {
      final (_, uiExe) = await makeUiDir(tmp, 'ui-only');
      final backend = makeBackend(executablePath: uiExe);

      expect(await backend.resolveCoreServicePath(), isNull);
      expect(execProgram(await backend.resolveExecCommandForDesktopEntry()),
          uiExe);
    });

    test(r'AppImage：挂载点里的 core 不写进自启项，退回 $APPIMAGE', () async {
      final (uiDir, uiExe) = await makeUiDir(tmp, 'mounted');
      // AppImage 挂载点里确实有核心……
      final coreDir = Directory(p.join(uiDir, 'core'));
      await coreDir.create(recursive: true);
      await File(p.join(coreDir.path, LinuxAutostart.coreBinaryName))
          .writeAsString('core');
      // ……但那是 /tmp/.mount_* 形态的临时路径。
      final appImage = File(p.join(tmp.path, 'EasyPass-3.0.0-x86_64.AppImage'));
      await appImage.writeAsString('appimage');

      final backend =
          makeBackend(executablePath: uiExe, appImagePath: appImage.path);
      expect(await backend.resolveCoreServicePath(), isNull);
      expect(execProgram(await backend.resolveExecCommandForDesktopEntry()),
          appImage.path);
    });

    test('enable() 写出的 Exec= 就是解析出来的核心命令', () async {
      final (uiDir, uiExe) = await makeUiDir(tmp, 'install');
      final coreDir = Directory(p.join(uiDir, 'core'));
      await coreDir.create(recursive: true);
      final core = p.join(coreDir.path, LinuxAutostart.coreBinaryName);
      await File(core).writeAsString('core');

      final backend = makeBackend(executablePath: uiExe);
      await backend.enable();

      final content = await File(desktopEntryPath).readAsString();
      final exec = readExecField(content);
      expect(execProgram(exec), core);
      expect(exec.trim(), endsWith('--serve'));
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