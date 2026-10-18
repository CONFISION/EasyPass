import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'adapters/flutter_secret_store.dart';
import 'core/storage/secret_store.dart';
import 'data/services/font_discovery_service.dart';
import 'features/desktop_single_instance/desktop_single_instance.dart';
import 'features/desktop_tray/desktop_tray.dart';

Future<void> main() async {
  // 浏览器桥接 host 安装/卸载/状态 CLI（`--install-browser-host` /
  // `--uninstall-browser-host` / `--browser-host-status`）。
  //
  // **本分支只支持 Windows**：native messaging 宿主的注册由 Inno Setup 安装器的
  // `[Code]` 段写注册表（`installer/easypass_setup.iss`），Dart 侧不再生成 Linux
  // 的 wrapper / manifest。三个子命令因此是**显式的 no-op**（打印提示 + 退 0），
  // 与删除 Linux 实现之前 Windows 上的行为**逐字一致**。
  //
  // 保留它们而不是直接删掉是刻意的：开关一旦不认识，`easypass.exe
  // --install-browser-host` 就会掉进下面的 UI 启动分支 —— 脚本/文档里的调用会
  // 变成"弹一个窗口"，比打印一行说明糟得多。
  //
  // 必须在 `WidgetsFlutterBinding.ensureInitialized()` 之前拦截：CLI 不需要
  // Flutter UI、不碰数据库；先初始化 binding 只会白白拉起引擎。
  final browserHostCli = _maybeRunBrowserHostCli();
  if (browserHostCli != null) {
    // `exit()` 不会等异步 stdout 落盘。
    await stdout.flush();
    exit(browserHostCli);
  }

  // P4 桌面集成 CLI（`--install` / `--uninstall` / `--desktop-status`）。同样是
  // 显式 no-op：快捷方式与应用菜单入口由安装器负责。
  final desktopCli = _maybeRunDesktopCli();
  if (desktopCli != null) {
    await stdout.flush();
    await stderr.flush();
    exit(desktopCli);
  }

  WidgetsFlutterBinding.ensureInitialized();

  // 密钥材料存储：UI 侧用系统钥匙串（只在迁移期读旧值；核心自己用 vault_meta）。
  // 必须在任何 CryptoService 构造之前注册，否则读写密钥材料会明确抛错
  // （见 lib/core/storage/secret_store.dart 的 UnregisteredSecretStore）。
  SecretStoreRegistry.register(const FlutterSecretStore());

  // 单实例：Windows 的唯一性由 `windows/runner/main.cpp` 的 Mutex 闸门在 Dart
  // 运行之前就决定了（命中已有实例 → 抬窗 + 退出，根本走不到这里）。Dart 侧保留
  // 这个调用点是为了让"启动分支"可被测到；当前平台恒返回 notApplicable。
  final singleInstanceDecision = await acquireSingleInstance();
  if (singleInstanceDecision.role == SingleInstanceRole.secondary) {
    stderr.writeln('easypass: ${singleInstanceDecision.detail}');
    await stdout.flush();
    await stderr.flush();
    exit(0);
  }

  // UI 只是核心服务的客户端：它**不再**在自己进程里起 daemon，也不再自己
  // 打开数据库。核心由 `lib/client/core_session.dart` 在需要时拉起 / 连接。

  // Lock app in portrait mode
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Register bundled fonts (shipped next to the executable under
  // assets/fonts/) with the text engine before the UI builds.
  await FontDiscoveryService.loadBundledFonts();

  // desktop tray：Windows 上托盘图标、关窗即锁与菜单三项都在原生层
  // （`windows/runner/flutter_window.cpp`），这里恒得到 `inactive`。
  // 保留这个调用点：设置页仍用它的 status 决定是否显示"托盘不可用"提示。
  installDesktopTray();

  runApp(const ProviderScope(child: EasyPassApp()));
}

// ─── Browser-host installer CLI ─────────────────────────────────────────────
//
// 返回 null = "不是 CLI 调用，继续走 UI"；返回 int = "已处理，用它当退出码"。

int? _maybeRunBrowserHostCli() {
  final rawArgs = Platform.executableArguments.toSet();
  final isAny = rawArgs.contains('--install-browser-host') ||
      rawArgs.contains('--uninstall-browser-host') ||
      rawArgs.contains('--browser-host-status');
  if (!isAny) return null;

  stdout.writeln(
      'Skipped: browser-host CLI is not supported on ${Platform.operatingSystem}.');
  stdout.writeln(
      'On Windows, use the EasyPass installer (Inno Setup) to register the host.');
  return 0;
}

// ─── Desktop-integration installer CLI (P4) ─────────────────────────────────
//
// Windows 的快捷方式与应用菜单入口由安装器负责，Dart 侧不写任何桌面集成文件，
// 所以三个子命令同样是显式 no-op。

int? _maybeRunDesktopCli() {
  final rawArgs = Platform.executableArguments.toSet();
  final isAny = rawArgs.contains('--install') ||
      rawArgs.contains('--uninstall') ||
      rawArgs.contains('--desktop-status');
  if (!isAny) return null;

  stdout.writeln(
      'Skipped: desktop-integration CLI is not supported on ${Platform.operatingSystem}.');
  stdout.writeln(
      'On Windows, use the EasyPass installer (Inno Setup) to create shortcuts.');
  return 0;
}
