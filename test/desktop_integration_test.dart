// P4 桌面集成测试（Linux 生效的 `.desktop` 入口 + hicolor 图标）。
//
// 覆盖：
//   1. XDG 解析：`$XDG_DATA_HOME` 优先；未设置 → `$HOME/.local/share`
//      （Base Directory Spec，**不是** `~/.config`）。
//   2. install：入口路径/字段齐全、Exec 用 `$APPIMAGE` 优先、引号转义、
//      图标按源 PNG 实测尺寸落到 `hicolor/<size>x<size>/apps/easypass.png`。
//   3. 幂等：重复 install 内容一致；uninstall 没装过也成功。
//   4. uninstall：删自己的文件 + 只清空的自家目录；别的应用的图标不动。
//   5. status：未安装 / 已安装 / 指向失效 三态 + `toExitCode()` 0/1/2。
//   6. best-effort：缓存刷新命令缺失/非零退出 → warning，不影响结果。
//   7. 非 Linux 桩：install/uninstall skipped、status !checked。
//
// 不可自动化的项（需手工确认）：真实 GNOME/KDE
// 桌面里应用菜单出现条目、图标显示正确、点击能拉起应用；以及
// `StartupWMClass` 与 `xprop WM_CLASS` 的实测对拍。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:easypass/features/desktop_integration/desktop_integration.dart';
import 'package:easypass/features/desktop_integration/linux_desktop_integration.dart';
import 'package:easypass/features/desktop_integration/other_desktop_integration.dart';

/// 构造一个"足够真"的 PNG 头：签名 + IHDR(宽高) + 若干填充字节。
/// `pngSquareSize` 只读前 24 字节，所以这里不需要真图。
Uint8List fakePng(int width, int height) {
  final bytes = Uint8List(64);
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < signature.length; i++) {
    bytes[i] = signature[i];
  }
  bytes[12] = 0x49; // 'I'
  bytes[13] = 0x48; // 'H'
  bytes[14] = 0x44; // 'D'
  bytes[15] = 0x52; // 'R'
  bytes[16] = (width >> 24) & 0xFF;
  bytes[17] = (width >> 16) & 0xFF;
  bytes[18] = (width >> 8) & 0xFF;
  bytes[19] = width & 0xFF;
  bytes[20] = (height >> 24) & 0xFF;
  bytes[21] = (height >> 16) & 0xFF;
  bytes[22] = (height >> 8) & 0xFF;
  bytes[23] = height & 0xFF;
  return bytes;
}

/// Linux 语义用例的 `skip` 参数：`chmod` 与文件 mode 的执行位是 POSIX 概念，
/// 在 Windows 上 `Process.run('chmod', …)` 直接抛 `ProcessException`、
/// `File.stat().mode` 也永远没有 x 位。
///
/// 用 `skip:` 而不是在用例里静默 `return` —— 跳过的用例必须出现在测试报告里，
/// 否则"Windows 上绿"会被误读成"这些行为验证过了"。
Object? get _needsPosixExecBits => Platform.isLinux
    ? null
    : '需要 POSIX 执行位 / chmod（Windows 不适用）';

void main() {
  late Directory tmp;
  late String home;
  late String dataHome;
  late String iconSource;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('easypass_desktop_');
    home = p.join(tmp.path, 'home');
    dataHome = p.join(home, '.local', 'share');
    await Directory(home).create(recursive: true);
    iconSource = p.join(tmp.path, 'Easypass.png');
    await File(iconSource).writeAsBytes(fakePng(1024, 1024));
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  /// 默认构造：环境变量表为**空**（不读真实 HOME/XDG），全部走注入。
  LinuxDesktopIntegration make({
    String? xdgDataHome,
    String? executablePath,
    String? appImagePath,
    String? desktopEntryPath,
    List<String>? iconSourceCandidates,
    Map<String, String>? environment,
    Future<ProcessResult> Function(String, List<String>)? processRunner,
  }) {
    return LinuxDesktopIntegration(
      homeDirectory: home,
      xdgDataHome: xdgDataHome,
      executablePath: executablePath ?? '/opt/easypass/easypass',
      appImagePath: appImagePath,
      desktopEntryPathOverride: desktopEntryPath,
      iconSourceCandidatesOverride: iconSourceCandidates ?? [iconSource],
      environment: environment ?? const <String, String>{},
      processRunner: processRunner ?? _okRunner,
    );
  }

  group('XDG 解析（Base Directory Specification）', () {
    test('XDG_DATA_HOME 未设置 → \$HOME/.local/share（不是 ~/.config）', () {
      final service = make();
      expect(service.dataHome, p.join(home, '.local', 'share'));
      expect(
        service.desktopEntryPath,
        p.join(home, '.local', 'share', 'applications', 'easypass.desktop'),
      );
      expect(service.dataHome.contains('${p.separator}.config'), isFalse);
    });

    test('XDG_DATA_HOME 已设置 → 优先使用', () {
      final custom = p.join(tmp.path, 'xdg');
      final service = make(xdgDataHome: custom);
      expect(service.dataHome, custom);
      expect(
        service.desktopEntryPath,
        p.join(custom, 'applications', 'easypass.desktop'),
      );
    });

    test('HOME 缺失 → 抛 DesktopIntegrationException（不写 /tmp）', () async {
      final service = LinuxDesktopIntegration(
        environment: const <String, String>{},
        iconSourceCandidatesOverride: [iconSource],
      );
      await expectLater(
        service.install(),
        throwsA(isA<DesktopIntegrationException>()),
      );
    });
  });

  group('install', () {
    test('写入口文件 + 必备字段齐全（含 Exec %U / StartupWMClass）', () async {
      final service = make();
      final result = await service.install();

      expect(result.installed, isTrue);
      final file = File(result.desktopEntryPath!);
      expect(await file.exists(), isTrue);
      final text = await file.readAsString();

      expect(text, startsWith('[Desktop Entry]\n'));
      expect(text, contains('Type=Application'));
      expect(text, contains('Name=EasyPass'));
      expect(text, contains('Exec=/opt/easypass/easypass %U'));
      expect(text, contains('Icon=easypass'));
      expect(text, contains('Categories=Utility;Security;'));
      expect(text, contains('Terminal=false'));
      expect(
        text,
        contains('StartupWMClass=${LinuxDesktopIntegration.startupWmClass}'),
      );
      expect(text.endsWith('\n'), isTrue);
    });

    test('图标按源图实测尺寸装到 hicolor/<size>x<size>/apps/easypass.png',
        () async {
      final service = make();
      final result = await service.install();

      expect(result.iconPaths.length, 1);
      expect(
        result.iconPaths.single,
        p.join(dataHome, 'icons', 'hicolor', '1024x1024', 'apps',
            'easypass.png'),
      );
      final icon = File(result.iconPaths.single);
      expect(await icon.exists(), isTrue);
      // 逐字节等于源文件（不重编码、不伪造尺寸）。
      expect(await icon.readAsBytes(), await File(iconSource).readAsBytes());
    });

    test('源图是 48x48 → 落到 48x48 目录（不伪造尺寸）', () async {
      final small = p.join(tmp.path, 'small.png');
      await File(small).writeAsBytes(fakePng(48, 48));
      final service = make(iconSourceCandidates: [small]);
      final result = await service.install();
      expect(
        result.iconPaths.single,
        p.join(dataHome, 'icons', 'hicolor', '48x48', 'apps', 'easypass.png'),
      );
    });

    test('AppImage 形态：Exec 用 \$APPIMAGE（而非临时挂载路径）', () async {
      // 用**字面量 POSIX 路径**，不用 `p.join(tmp.path, …)`：真机上 AppImage
      // 就是 `/…/EasyPass-x86_64.AppImage`，而 Windows 临时目录路径带反斜杠，
      // 会被 [_escapeExecArgument] 合法地整体加引号。本用例要断言的是"写持久
      // 路径而不是临时挂载点"，与路径形状无关。
      const appImage = '/opt/apps/EasyPass-2.3.2-linux-x86_64.AppImage';
      final service = make(
        appImagePath: appImage,
        environment: const <String, String>{},
      );
      expect(service.resolveExecutableForDesktopEntry(), appImage);
      final result = await service.install();
      expect(result.execCommand, '$appImage %U');
    });

    test('路径含空格 → Exec 加双引号（Desktop Entry Spec）', () async {
      final service = make(executablePath: '/opt/my apps/easypass');
      final result = await service.install();
      final text = await File(result.desktopEntryPath!).readAsString();
      expect(text, contains('Exec="/opt/my apps/easypass" %U'));
    });

    test('AppImage 形态：图标取运行二进制的 assets/icons，Exec 仍写 AppImage 文件',
        () async {
      // 模拟真机：`--appimage-extract-and-run` 下运行二进制在解包目录
      // `<unpacked>/usr/bin/easypass`，而 `$APPIMAGE` 指向持久的大文件。
      final unpacked = p.join(tmp.path, 'unpacked');
      final binDir = p.join(unpacked, 'usr', 'bin');
      await Directory(p.join(binDir, 'assets', 'icons')).create(recursive: true);
      await File(p.join(binDir, 'assets', 'icons', 'Easypass.png'))
          .writeAsBytes(fakePng(256, 256));
      final appImage = '/opt/apps/EasyPass-2.3.2-linux-x86_64.AppImage';
      // AppImage 文件本身不需要存在：它只参与 Exec 字符串与"图标候选目录"的
      // 推导，候选不存在就跳过。这样本用例在非 Linux 上也能跑（也避免去写
      // `/opt`）。

      final service = LinuxDesktopIntegration(
        homeDirectory: home,
        environment: const <String, String>{},
        executablePath: p.join(binDir, 'easypass'),
        appImagePath: appImage,
        processRunner: _okRunner,
      );

      final result = await service.install();

      // Exec = 持久路径；图标 = 运行环境里的源图，尺寸照抄。
      expect(result.execCommand, '$appImage %U');
      expect(
        result.iconPaths.single,
        p.join(dataHome, 'icons', 'hicolor', '256x256', 'apps', 'easypass.png'),
      );
      expect(result.warnings, isEmpty);
    });

    test('AppImage 形态：\$APPDIR 顶层的 easypass.png 也认得', () async {
      final appDir = p.join(tmp.path, 'mount');
      await Directory(appDir).create(recursive: true);
      await File(p.join(appDir, 'easypass.png')).writeAsBytes(fakePng(512, 512));

      final service = LinuxDesktopIntegration(
        homeDirectory: home,
        environment: {'APPDIR': appDir},
        executablePath: p.join(appDir, 'usr', 'bin', 'easypass'),
        processRunner: _okRunner,
      );
      final result = await service.install();
      expect(
        result.iconPaths.single,
        p.join(dataHome, 'icons', 'hicolor', '512x512', 'apps', 'easypass.png'),
      );
    });

    test('幂等：重复 install 内容逐字节一致、不追加', () async {
      final service = make();
      final first = await service.install();
      final text1 = await File(first.desktopEntryPath!).readAsString();
      final second = await service.install();
      final text2 = await File(second.desktopEntryPath!).readAsString();
      expect(text2, text1);
      expect('Exec='.allMatches(text2).length, 1);
    });

    test('图标源缺失 → warning，但入口文件照写、不伪造图标', () async {
      final service = make(iconSourceCandidates: [p.join(tmp.path, 'nope.png')]);
      final result = await service.install();
      expect(result.installed, isTrue);
      expect(result.iconPaths, isEmpty);
      expect(result.warnings, isNotEmpty);
      expect(await File(result.desktopEntryPath!).exists(), isTrue);
      expect(await Directory(p.join(dataHome, 'icons')).exists(), isFalse);
    });

    test('源文件不是 PNG → warning，不建任何尺寸目录', () async {
      final bogus = p.join(tmp.path, 'bogus.png');
      await File(bogus).writeAsString('not a png at all');
      final service = make(iconSourceCandidates: [bogus]);
      final result = await service.install();
      expect(result.iconPaths, isEmpty);
      expect(result.warnings, isNotEmpty);
      expect(await Directory(p.join(dataHome, 'icons')).exists(), isFalse);
    });

    test('best-effort：刷新命令 spawn 失败/非零退出 → 只记 warning', () async {
      Future<ProcessResult> failing(String exe, List<String> args) async {
        throw ProcessException(exe, args, 'not found', 2);
      }

      final service = make(processRunner: failing);
      final result = await service.install();
      expect(result.installed, isTrue);
      expect(result.warnings.where((w) => w.contains('unavailable')), isNotEmpty);
    });

    test('best-effort：刷新命令非零退出 → 只记 warning', () async {
      Future<ProcessResult> nonzero(String exe, List<String> args) async =>
          ProcessResult(1, 1, '', 'boom');

      final service = make(processRunner: nonzero);
      final result = await service.install();
      expect(result.installed, isTrue);
      expect(result.warnings.where((w) => w.contains('best-effort')), isNotEmpty);
    });
  });

  group('uninstall', () {
    test('删入口 + 图标 + 清空目录（不留残渣）', () async {
      final service = make();
      final install = await service.install();
      expect(await File(install.desktopEntryPath!).exists(), isTrue);

      final result = await service.uninstall();
      expect(result.entryRemoved, isTrue);
      expect(result.iconsRemoved.length, 1);
      expect(await File(install.desktopEntryPath!).exists(), isFalse);
      expect(await File(result.iconsRemoved.single).exists(), isFalse);
      // 空目录被清掉（包括空的共享主题根），但 <dataHome> 本身保留。
      expect(await Directory(p.join(dataHome, 'applications')).exists(), isFalse);
      expect(await Directory(p.join(dataHome, 'icons')).exists(), isFalse);
      expect(await Directory(p.join(dataHome, 'icons', 'hicolor')).exists(),
          isFalse);
      expect(await Directory(dataHome).exists(), isTrue);
      expect(await Directory(home).exists(), isTrue);
    });

    test('幂等：没装过也成功；重复卸载不抛', () async {
      final service = make();
      final first = await service.uninstall();
      expect(first.uninstalled, isTrue);
      expect(first.entryRemoved, isFalse);
      final second = await service.uninstall();
      expect(second.uninstalled, isTrue);
      expect(second.entryRemoved, isFalse);
    });

    test('只删自己的图标：别的应用图标 / 非空目录不动', () async {
      final service = make();
      await service.install();
      final otherIcon = p.join(dataHome, 'icons', 'hicolor', '256x256', 'apps',
          'otherapp.png');
      await File(otherIcon).create(recursive: true);
      final otherEntry = p.join(dataHome, 'applications', 'otherapp.desktop');
      await File(otherEntry).writeAsString('[Desktop Entry]\nName=Other\n');

      final result = await service.uninstall();

      expect(await File(otherIcon).exists(), isTrue);
      expect(await File(otherEntry).exists(), isTrue);
      // 只删了我们那个尺寸的空目录链（先子后父）。
      expect(
        result.prunedDirectories,
        [
          p.join(dataHome, 'icons', 'hicolor', '1024x1024', 'apps'),
          p.join(dataHome, 'icons', 'hicolor', '1024x1024'),
        ],
      );
      expect(
        await Directory(p.join(dataHome, 'applications')).exists(),
        isTrue,
      );
      expect(
        await Directory(p.join(dataHome, 'icons', 'hicolor')).exists(),
        isTrue,
      );
    });
  });

  group('status + 退出码', () {
    test('未安装 → entryExists=false / exit 2', () async {
      final service = make();
      final status = await service.status();
      expect(status.checked, isTrue);
      expect(status.entryExists, isFalse);
      expect(status.isInstalled, isFalse);
      expect(status.toExitCode(), 2);
      expect(
        status.desktopEntryPath,
        p.join(dataHome, 'applications', 'easypass.desktop'),
      );
    });

    test('已安装（Exec 目标可执行）→ isInstalled / exit 0', () async {
      final exe = p.join(tmp.path, 'easypass');
      await File(exe).writeAsString('#!/bin/sh\n');
      await Process.run('chmod', ['755', exe]);

      final service = make(executablePath: exe);
      await service.install();
      final status = await service.status();

      expect(status.entryExists, isTrue);
      expect(status.looksLikeOurs, isTrue);
      expect(status.execTarget, exe);
      expect(status.execTargetExecutable, isTrue);
      expect(status.isInstalled, isTrue);
      expect(status.iconAvailable, isTrue);
      expect(status.startupWmClass, LinuxDesktopIntegration.startupWmClass);
      expect(status.toExitCode(), 0);
    }, skip: _needsPosixExecBits);

    test('入口在但指向失效（目标被删）→ exit 1', () async {
      final exe = p.join(tmp.path, 'easypass');
      await File(exe).writeAsString('#!/bin/sh\n');
      await Process.run('chmod', ['755', exe]);
      final service = make(executablePath: exe);
      await service.install();

      await File(exe).delete();
      final status = await service.status();

      expect(status.entryExists, isTrue);
      expect(status.execTargetExecutable, isFalse);
      expect(status.pointsAtBrokenTarget, isTrue);
      expect(status.toExitCode(), 1);
    }, skip: _needsPosixExecBits);

    test('同名但不是我们写的文件 → 不算已安装（exit 1）', () async {
      final service = make();
      await Directory(p.dirname(service.desktopEntryPath)).create(recursive: true);
      await File(service.desktopEntryPath).writeAsString(
        '[Desktop Entry]\nType=Application\nName=OtherApp\n'
        'Exec=/bin/true %U\n',
      );
      final status = await service.status();
      expect(status.entryExists, isTrue);
      expect(status.looksLikeOurs, isFalse);
      expect(status.isInstalled, isFalse);
      expect(status.toExitCode(), 1);
    });

    test('path override：status 只看注入的路径', () async {
      final custom = p.join(tmp.path, 'custom', 'easypass.desktop');
      final service = make(desktopEntryPath: custom);
      final status = await service.status();
      expect(status.desktopEntryPath, custom);
      expect(status.entryExists, isFalse);
    });
  });

  group('纯函数', () {
    test('renderDesktopEntry 字段与示例', () {
      final text = LinuxDesktopIntegration.renderDesktopEntry(
        execPath: '/opt/easypass/easypass',
        iconName: 'easypass',
        wmClass: 'com.easypass.app',
        name: 'EasyPass',
      );
      expect(text, contains('Exec=/opt/easypass/easypass %U'));
      expect(text, contains('StartupWMClass=com.easypass.app'));
      // 不写 StartupNotify（缺省 false 更稳，见实现注释）。
      expect(text.contains('StartupNotify'), isFalse);
    });

    test('parseExecTarget：无引号 / 双引号带空格 / 转义 / 非法', () {
      expect(
        LinuxDesktopIntegration.parseExecTarget('/opt/easypass/easypass %U'),
        '/opt/easypass/easypass',
      );
      expect(
        LinuxDesktopIntegration.parseExecTarget('"/opt/my apps/easypass" %U'),
        '/opt/my apps/easypass',
      );
      expect(
        LinuxDesktopIntegration.parseExecTarget(r'"/opt/a\"b/easypass" %U'),
        '/opt/a"b/easypass',
      );
      expect(LinuxDesktopIntegration.parseExecTarget(null), isNull);
      expect(LinuxDesktopIntegration.parseExecTarget('   '), isNull);
      expect(LinuxDesktopIntegration.parseExecTarget('"/unterminated'), isNull);
    });

    test('pngSquareSize：合法 / 非方形 / 垃圾输入', () {
      expect(LinuxDesktopIntegration.pngSquareSize(fakePng(1024, 1024)), 1024);
      expect(LinuxDesktopIntegration.pngSquareSize(fakePng(64, 32)), isNull);
      expect(
        LinuxDesktopIntegration.pngSquareSize(
          Uint8List.fromList(List<int>.filled(32, 0)),
        ),
        isNull,
      );
      expect(
        LinuxDesktopIntegration.pngSquareSize(Uint8List(8)),
        isNull,
      );
    });
  });

  group('平台桩与协调器', () {
    test('OtherDesktopIntegration：全部 skipped / !checked', () async {
      final stub = OtherDesktopIntegration();
      final install = await stub.install();
      expect(install.installed, isFalse);
      final uninstall = await stub.uninstall();
      expect(uninstall.uninstalled, isFalse);
      final status = await stub.status();
      expect(status.checked, isFalse);
      expect(status.toExitCode(), 2);
    });

    test('协调器把调用转给注入的后端', () async {
      final backend = _RecordingBackend();
      final coordinator = DesktopIntegration(backend: backend);
      await coordinator.install();
      await coordinator.uninstall();
      await coordinator.status();
      expect(backend.calls, ['install', 'uninstall', 'status']);
    });
  });
}

/// 常量式 `Process.run` 替身：所有命令"成功且无输出"。
Future<ProcessResult> _okRunner(String executable, List<String> arguments) async =>
    ProcessResult(0, 0, '', '');

class _RecordingBackend implements DesktopIntegrationBackend {
  final List<String> calls = [];

  @override
  Future<DesktopEntryInstallResult> install() async {
    calls.add('install');
    return const DesktopEntryInstallResult(installed: true);
  }

  @override
  Future<DesktopEntryUninstallResult> uninstall() async {
    calls.add('uninstall');
    return const DesktopEntryUninstallResult(uninstalled: true);
  }

  @override
  Future<DesktopStatus> status() async {
    calls.add('status');
    return const DesktopStatus(checked: true);
  }
}
