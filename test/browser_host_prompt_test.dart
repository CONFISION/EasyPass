import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/features/browser_bridge/browser_host_prompt.dart';

void main() {
  group('首次启动浏览器集成提示（方案 B，纯逻辑）', () {
    test('Linux + 未登记 + 未提示过 → 提示', () {
      expect(
        shouldShowBrowserHostPrompt(
            isLinux: true, alreadyRegistered: false, alreadyPrompted: false),
        isTrue,
      );
    });

    test('非 Linux 一律不提示', () {
      expect(
        shouldShowBrowserHostPrompt(
            isLinux: false, alreadyRegistered: false, alreadyPrompted: false),
        isFalse,
      );
    });

    test('已登记过 → 不提示（哪怕没提示过）', () {
      expect(
        shouldShowBrowserHostPrompt(
            isLinux: true, alreadyRegistered: true, alreadyPrompted: false),
        isFalse,
      );
    });

    test('提示过 → 不再提示（哪怕还没登记）', () {
      expect(
        shouldShowBrowserHostPrompt(
            isLinux: true, alreadyRegistered: false, alreadyPrompted: true),
        isFalse,
      );
    });

    test('命令：AppImage 优先用持久路径', () {
      expect(
        browserHostInstallCommand(
          appImagePath: '/opt/apps/EasyPass-2.3.2.AppImage',
          executablePath: '/tmp/.mount_xyz/usr/bin/easypass',
        ),
        '/opt/apps/EasyPass-2.3.2.AppImage --install-browser-host',
      );
    });

    test('命令：没有 APPIMAGE 时用当前可执行文件', () {
      expect(
        browserHostInstallCommand(
          appImagePath: null,
          executablePath: '/home/u/.local/bin/easypass',
        ),
        '/home/u/.local/bin/easypass --install-browser-host',
      );
      expect(
        browserHostInstallCommand(
          appImagePath: '',
          executablePath: '/home/u/.local/bin/easypass',
        ),
        '/home/u/.local/bin/easypass --install-browser-host',
      );
    });
  });
}
