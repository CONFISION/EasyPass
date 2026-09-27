import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/features/browser_bridge/browser_host_installer.dart';
import 'package:easypass/features/browser_bridge/browser_host_prompt.dart';

/// 造一个 [BrowserHostStatus]，只关心"磁盘上有什么"。
BrowserHostStatus _status({
  required bool wrapperExists,
  bool chainBroken = false,
  bool anyManifest = false,
}) {
  final reports = <BrowserVendor, BrowserHostVendorReport>{};
  if (anyManifest) {
    reports[BrowserVendor.chrome] = const BrowserHostVendorReport(
      manifestPath: '/home/u/.config/google-chrome/NativeMessagingHosts/'
          'com.easypass.app.json',
      manifestExists: true,
      wrapperPath: '/home/u/.config/easypass/native-host/easypass-host.sh',
      wrapperUsable: true,
    );
  }
  return BrowserHostStatus(
    wrapperPath: '/home/u/.config/easypass/native-host/easypass-host.sh',
    wrapperExists: wrapperExists,
    resolutionChainBroken: chainBroken,
    vendorReports: reports,
  );
}

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

  // ─── "是否已登记"的判据（本次修复） ─────────────────────────────────────
  //
  // 旧实现把 `resolutionChainBroken` 也算作"已登记"。从应用菜单启动的
  // AppImage 在 `status()` 的环境里没有 `$APPIMAGE`，解析链必然报断 ——
  // 那正是"从未登记过"的典型形态，于是**最该提示的用户反而看不到提示**。
  group('alreadyRegisteredFromStatus（首启提示的判据）', () {
    test('从未登记 + 链断（AppImage 从菜单启动）→ 未登记 → 会提示', () {
      final status = _status(wrapperExists: false, chainBroken: true);
      expect(alreadyRegisteredFromStatus(status), isFalse);
      expect(
        shouldShowBrowserHostPrompt(
          isLinux: true,
          alreadyRegistered: alreadyRegisteredFromStatus(status),
          alreadyPrompted: false,
        ),
        isTrue,
      );
    });

    test('wrapper 在但链断（装了、二进制没了）→ 算登记过，不再打扰', () {
      // 解析链断是"需要修复"，不是"没装过"：修复入口是
      // `--browser-host-status` / 重跑 install，而不是首启提示。
      final status = _status(wrapperExists: true, chainBroken: true);
      expect(alreadyRegisteredFromStatus(status), isTrue);
    });

    test('只有 manifest 在（wrapper 被删）→ 也算登记过', () {
      final status = _status(wrapperExists: false, anyManifest: true);
      expect(alreadyRegisteredFromStatus(status), isTrue);
    });

    test('checked=false（非 Linux / 探测跳过）→ 不算登记过', () {
      final status = BrowserHostStatus.skipped(platform: 'windows');
      expect(status.checked, isFalse);
      expect(alreadyRegisteredFromStatus(status), isFalse);
      // 但非 Linux 仍然不会弹（isLinux 门在外层）。
      expect(
        shouldShowBrowserHostPrompt(
          isLinux: false,
          alreadyRegistered: alreadyRegisteredFromStatus(status),
          alreadyPrompted: false,
        ),
        isFalse,
      );
    });
  });
}
