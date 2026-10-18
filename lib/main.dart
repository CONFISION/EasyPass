import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'adapters/flutter_secret_store.dart';
import 'core/storage/secret_store.dart';
import 'data/services/font_discovery_service.dart';
import 'features/browser_bridge/browser_host_installer.dart';
import 'features/desktop_integration/desktop_integration.dart';
import 'features/desktop_integration/linux_desktop_integration.dart';
import 'features/desktop_single_instance/desktop_single_instance.dart';
import 'features/desktop_single_instance/raise_target_provider.dart';
import 'features/desktop_tray/desktop_tray.dart';

Future<void> main() async {
  // 浏览器桥接 host 安装/卸载/状态 CLI（Linux 生效）。
  // 必须在 `WidgetsFlutterBinding.ensureInitialized()` 之前拦截：这些
  // CLI 不需要 Flutter UI、不需要起 daemon、不需要碰数据库；如果先初
  // 始化 binding，没有 display 时 Gtk 会直接报错并退出 —— 阻止 CLI
  // 子命令运行。Windows 上运行这些 CLI 会得到明确的"Windows 用安装器"
  // 提示，原注册表逻辑（早前的装机 + PowerShell 脚本）完全不变。
  final browserHostCli = await _maybeRunBrowserHostCli();
  if (browserHostCli != null) {
    // 防御性：`exit()` 不会等异步 stdout 落盘（红队评审 #6）。
    await stdout.flush();
    exit(browserHostCli.exitCode);
  }

  // P4 桌面集成 CLI（Linux 生效）：`--install` / `--uninstall` /
  // `--desktop-status`。与上面同款：必须在
  // `WidgetsFlutterBinding.ensureInitialized()` 之前拦截 —— 这些子命令只写
  // `$XDG_DATA_HOME` 下的 `.desktop` / 图标，不需要 Flutter UI、不需要
  // display、不起 daemon、不碰数据库。Windows 上打印"用安装器"提示并退 0
  // （快捷方式由 Inno Setup 负责，`windows/` 零改动）。
  final desktopCli = await _maybeRunDesktopCli();
  if (desktopCli != null) {
    await stdout.flush();
    await stderr.flush();
    exit(desktopCli.exitCode);
  }

  WidgetsFlutterBinding.ensureInitialized();

  // 密钥材料存储：UI 侧用系统钥匙串（只在迁移期读旧值；核心自己用 vault_meta）。
  // 必须在任何 CryptoService 构造之前注册，否则读写密钥材料会明确抛错
  // （见 lib/core/storage/secret_store.dart 的 UnregisteredSecretStore）。
  SecretStoreRegistry.register(const FlutterSecretStore());

  // 单实例：UI 模式才需要"唤起已有窗口"语义。`--native-host` / `--service`
  // 进程是浏览器 / 桥接按需拉起的，不能被"二次启动唤起"拦截 —— 否则桥接
  // 每连一次都被踢掉。`--install-browser-host` 等 CLI 子命令在
  // `_maybeRunBrowserHostCli()` 早期已拦截，不会到这里。
  //
  // 二次启动：stderr 给一条可读诊断 + exit(0)（不阻断 CI / debug）；
  // 主实例：拿到 backend，等 UI 准备好后启动 raise 监听。
  final singleInstanceDecision = await acquireSingleInstance();
  if (singleInstanceDecision.role == SingleInstanceRole.secondary) {
    stderr.writeln('easypass: ${singleInstanceDecision.detail}');
    await stdout.flush();
    await stderr.flush();
    exit(0);
  }
  // 主实例：保留 backend，挂到 runApp 的 ProviderScope 里给 UI 用。
  final singleInstanceBackend = singleInstanceDecision.backend;

  // UI 只是核心服务的客户端：它**不再**在自己进程里起 daemon，也不再自己
  // 打开数据库。核心由 `lib/client/core_session.dart` 在需要时拉起 / 连接。
  //
  // 旧实现（v2.4 及以前）在这里 probe 已有 daemon，没有就在本进程
  // `startInProcessDaemon` 并与 Riverpod 共用同一个 AppDatabase —— 那正是

  // "双核心 / 双 SQLite 句柄"的来源，也是本次架构改造要消除的东西。
  // Lock app in portrait mode
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Register bundled fonts (shipped next to the executable under
  // assets/fonts/) with the text engine before the UI builds.
  await FontDiscoveryService.loadBundledFonts();

  // desktop tray (Linux 关窗最小化 + 托盘菜单)。单实例 raise 复用其
  // [WindowController]：二次启动 raise 时 `show()` 窗口。`windowController`
  // 通过 [raiseWindowControllerProvider] 暴露给 UI（见
  // `lib/features/desktop_single_instance/raise_target_provider.dart`）。
  final desktopTray = installDesktopTray();

  runApp(
    ProviderScope(
      overrides: [
        if (singleInstanceBackend != null)
          singleInstanceBackendProvider.overrideWithValue(singleInstanceBackend),
        if (desktopTray.windowController != null)
          raiseWindowControllerProvider.overrideWithValue(
            desktopTray.windowController!,
          ),
      ],
      child: const EasyPassApp(),
    ),
  );
}

/// Reads the process command-line arguments directly from `/proc/self/cmdline`.
///
/// `Platform.executableArguments` is unreliable on Flutter desktop:
/// - On Windows, the runner mirrors CLI args into `EASYPASS_NATIVE_HOST` /
///   `EASYPASS_SERVICE` env vars (see `windows/runner/main.cpp`); we keep the
///   env-var + `Platform.executableArguments` check as a belt-and-braces.
/// - On Linux, the Flutter runner does NOT propagate `argv` to Dart
///   ([Platform.executableArguments](https://api.dart.dev/stable/dart-io/Platform/executableArguments.html)
///   returns Dart's own internal flags instead). The only reliable source
///   is `/proc/self/cmdline` — which we read here and cache for the lifetime
///   of the process.
///
/// Returns an empty list if `/proc` is unavailable (macOS, Windows) or the
/// process is not running on Linux.
List<String> _readCommandLineArguments() {
  if (!Platform.isLinux) return const [];
  try {
    final file = File('/proc/self/cmdline');
    if (!file.existsSync()) return const [];
    final raw = file.readAsStringSync();
    // /proc/self/cmdline is NUL-separated; first token is the binary path.
    final parts = raw.split('\u0000')
      ..removeWhere((s) => s.isEmpty);
    if (parts.length <= 1) return const [];
    return parts.sublist(1);
  } catch (_) {
    return const [];
  }
}

// ─── Browser-host installer CLI ─────────────────────────────────────────────
//
// Linux 上的 `--install-browser-host` / `--uninstall-browser-host` /
// `--browser-host-status` 三个子命令在这里路由。Windows 上输出明确提示
// "On Windows, use the EasyPass installer..."（返回 0）—— 原注册表逻
// 辑（Inno Setup + PowerShell 脚本）零改动。
//
// 设计点：
// - 返回值是一个"该进程要不要继续走到 UI / daemon"的握手对象；null = 走默认
//   路径，非 null = 已经做完 CLI 任务并以 [exitCode] 退出。
// - 任何错误都进 stderr（CLI 不在原生消息协议里，但保持一致更安全 —— 万一
//   wrapper 误转发了也立刻能区分）。
// - **S1**：先判平台再读 HOME —— Windows 没有 HOME（也根本不需要解析
//   Linux manifest 路径），之前在 HOME 检查前先 `Platform.environment['HOME']`
//   会出现"cannot resolve Linux manifest paths"误报并以退出码 2 退出，与
//   "Windows 用安装器 → 0"的承诺自相矛盾。修复后：先 `Platform.isLinux`，
//   非 Linux 直接打印 skipped 提示并退 0。
// - 不开数据库、不碰 secure storage、不起 UI；只动文件系统。
class _BrowserHostCliResult {
  final int exitCode;
  const _BrowserHostCliResult(this.exitCode);
}

/// `--browser-host-status` 退出码语义抽到 `BrowserHostStatus.toExitCode()`，
/// 见 `lib/features/browser_bridge/browser_host_installer.dart`。这样
/// 单测不需要拉整个 Flutter UI（main.dart），否则 `import` 会触发
/// `main()` 的副作用。

Future<_BrowserHostCliResult?> _maybeRunBrowserHostCli() async {
  // arg parsing: 优先用 `/proc/self/cmdline`（Linux 上唯一可靠的 argv
  // 来源），与 `Platform.executableArguments` 取并集 —— Windows 用后者，
  // macOS 既不在这条路径上（任务不涉及）也不必处理。
  final rawArgs = <String>{
    ..._readCommandLineArguments(),
    ...Platform.executableArguments,
  };

  if (!rawArgs.contains('--install-browser-host') &&
      !rawArgs.contains('--uninstall-browser-host') &&
      !rawArgs.contains('--browser-host-status')) {
    return null;
  }

  // **先判平台**再读 HOME（S1 修复）：Windows 上根本没有 Linux manifest
  // 路径要解析，HOME 也常常不存在 —— 之前在 HOME 检查之前先读 `HOME`
  // 会让 Windows 用户拿到一条假的"cannot resolve Linux manifest paths"
  // 报错，并且退出码 2 与"skipped-on-Windows → 0"的承诺自相矛盾。
  if (!Platform.isLinux) {
    stdout.writeln(
        'Skipped: browser-host CLI is not supported on ${Platform.operatingSystem}.');
    stdout.writeln(
        'On Windows, use the EasyPass installer (Inno Setup) to register the host.');
    return const _BrowserHostCliResult(0);
  }

  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    stderr.writeln(
        'easypass: HOME is not set; cannot resolve Linux manifest paths.');
    return const _BrowserHostCliResult(2);
  }

  final installer = BrowserHostInstaller();
  final xdgDataHome = Platform.environment['XDG_DATA_HOME'];

  if (rawArgs.contains('--install-browser-host')) {
    final result = await installer.install(
      homeDir: home,
      xdgDataHome: xdgDataHome,
    );
    if (!result.installed) {
      stdout.writeln(
          'Skipped: browser-host install is not supported on ${result.platform}.');
      stdout.writeln(
          'On Windows, use the EasyPass installer (Inno Setup) to register the host.');
      return const _BrowserHostCliResult(0);
    }
    stdout.writeln(
        'Installed EasyPass browser host wrapper at: ${result.wrapperPath}');
    for (final entry in result.manifests!.entries) {
      stdout.writeln('  ${entry.key.displayName}: ${entry.value}');
    }
    if (result.skippedVendors.isNotEmpty) {
      stdout.writeln('Skipped vendors (root directory not detected):');
      for (final entry in result.skippedVendors.entries) {
        stdout.writeln('  - ${entry.key.displayName}: ${entry.value}');
      }
    }
    stdout.writeln('Restart your browser, then reload the EasyPass extension.');
    return const _BrowserHostCliResult(0);
  }

  if (rawArgs.contains('--uninstall-browser-host')) {
    final result = await installer.uninstall(
      homeDir: home,
      xdgDataHome: xdgDataHome,
    );
    if (!result.uninstalled) {
      stdout.writeln(
          'Skipped: browser-host uninstall is not supported on ${result.platform}.');
      stdout.writeln(
          'On Windows, use the EasyPass installer to remove the host registration.');
      return const _BrowserHostCliResult(0);
    }
    stdout.writeln('Removed EasyPass browser host manifests:');
    for (final vendor in result.removed) {
      stdout.writeln('  - ${vendor.displayName}');
    }
    if (result.missing.isNotEmpty) {
      stdout.writeln('Already absent (no-op):');
      for (final vendor in result.missing) {
        stdout.writeln('  - ${vendor.displayName}');
      }
    }
    if (result.wrapperStillExists) {
      stdout.writeln(
          'Wrapper retained at: ${result.wrapperPath} (run --install-browser-host to recreate).');
    }
    return const _BrowserHostCliResult(0);
  }

  if (rawArgs.contains('--browser-host-status')) {
    final status = await installer.status(
      homeDir: home,
      xdgDataHome: xdgDataHome,
    );
    if (!status.checked) {
      stdout.writeln(
          'Skipped: browser-host status is not supported on ${status.platform}.');
      stdout.writeln(
          'On Windows, check the Inno Setup task "registerhost" state.');
      return const _BrowserHostCliResult(0);
    }
    stdout.writeln(
        'Wrapper: ${status.wrapperPath} (${status.wrapperExists ? "exists" : "missing"})');
    if (!status.resolutionChainBroken) {
      stdout.writeln(
          'Wrapper resolution chain: at least one candidate binary is reachable.');
      // 评审建议：OK 时也把命中的候选打出来（通常 1-2 条），便于取证。
      for (final entry in status.resolutionProbes.entries) {
        if (entry.value) stdout.writeln('    [ok] ${entry.key}');
      }
    } else {
      stdout.writeln(
          'Wrapper resolution chain: BROKEN (no candidate binary reachable).');
      for (final entry in status.resolutionProbes.entries) {
        stdout.writeln('    ${entry.value ? "[ok]" : "[--]"} ${entry.key}');
      }
    }
    for (final entry in status.vendorReports.entries) {
      final r = entry.value;
      final state = !r.vendorDetected
          ? 'not detected (N/A)'
          : !r.manifestExists
              ? 'no manifest'
              : r.wrapperUsable
                  ? 'OK'
                  : (r.wrapperPath == null
                      ? 'manifest invalid'
                      : 'wrapper missing or not executable');
      stdout.writeln('  ${entry.key.displayName}: $state');
      if (r.manifestExists && r.wrapperPath != null) {
        stdout.writeln('    manifest=${r.manifestPath}');
        stdout.writeln('    wrapper=${r.wrapperPath}');
      } else {
        stdout.writeln('    manifest=${r.manifestPath}');
      }
    }
    if (status.resolutionChainBroken) {
      stdout.writeln(
          'Status: broken. The wrapper cannot reach any EasyPass binary, so the '
          'browser host will fail to start.');
      stdout.writeln('Re-run --install-browser-host to repair.');
    } else if (status.isFullyInstalled) {
      stdout.writeln(status.detectedVendors.isEmpty
          ? 'Status: installed, but no supported browser was detected '
              '(nothing to configure yet).'
          : 'Status: installed (all detected browsers ready).');
    } else if (status.isPartiallyInstalled) {
      final missing =
          status.missingDetectedVendors.map((v) => v.displayName).join(', ');
      stdout.writeln(missing.isEmpty
          ? 'Status: partially installed.'
          : 'Status: partially installed. Missing for detected browsers: '
              '$missing');
      stdout.writeln('Re-run --install-browser-host to repair.');
    } else {
      stdout.writeln(
          'Status: not installed. Run --install-browser-host to set up.');
    }
    // 退出码通过 [BrowserHostStatus.toExitCode] 映射（可单测，见
    // `test/browser_host_installer_test.dart`）。MF1 之后"未装"的语义
    // 从"manifest 不在"扩展为"manifest 在但 wrapper 解析链全断"，仍
    // 映射到 2。详细链状态见 `resolutionChainBroken` 字段。
    return _BrowserHostCliResult(status.toExitCode());
  }

  return null; // 不会走到这里（上面 contains 已确保命中其一）。
}

// ─── Desktop-integration installer CLI (P4) ─────────────────────────────────
//
// Linux 上的 `--install` / `--uninstall` / `--desktop-status` 三个子命令在这里
// 路由。Windows 上输出明确提示 "On Windows, use the EasyPass installer..."
// 并返回 0 —— 快捷方式由 Inno Setup 负责，`windows/` 零改动。
//
// 设计点（与上面的 browser-host CLI 完全同构）：
// - 返回值是"该进程要不要继续走到 UI"的握手对象；null = 走默认路径。
// - **先判平台再读 HOME**：Windows 没有 HOME，也不该去解析 Linux 的
//   `$XDG_DATA_HOME`。
// - 失败一律可读 stderr + 非零退出码；绝不未捕获异常。
// - 不初始化 binding（没有 display 时 Gtk 会直接报错并退出）。
class _DesktopCliResult {
  final int exitCode;
  const _DesktopCliResult(this.exitCode);
}

/// `--desktop-status` 的退出码语义来自 [DesktopStatus.toExitCode]
/// （0 = 已安装可用 / 1 = 入口在但指向失效 / 2 = 未安装），可单测。
Future<_DesktopCliResult?> _maybeRunDesktopCli() async {
  final rawArgs = <String>{
    ..._readCommandLineArguments(),
    ...Platform.executableArguments,
  };

  if (!rawArgs.contains('--install') &&
      !rawArgs.contains('--uninstall') &&
      !rawArgs.contains('--desktop-status')) {
    return null;
  }

  if (!Platform.isLinux) {
    stdout.writeln(
        'Skipped: desktop-integration CLI is not supported on ${Platform.operatingSystem}.');
    stdout.writeln(
        'On Windows, use the EasyPass installer (Inno Setup) to create shortcuts.');
    return const _DesktopCliResult(0);
  }

  final service = LinuxDesktopIntegration();

  if (rawArgs.contains('--install')) {
    try {
      final result = await service.install();
      stdout.writeln(
          'Installed EasyPass desktop entry: ${result.desktopEntryPath}');
      stdout.writeln('  Exec=${result.execCommand}');
      stdout.writeln('  StartupWMClass=${result.startupWmClass}');
      if (result.iconPaths.isEmpty) {
        stdout.writeln('  icons: none installed (see warnings)');
      } else {
        for (final icon in result.iconPaths) {
          stdout.writeln('  icon: $icon');
        }
      }
      for (final warning in result.warnings) {
        stderr.writeln('easypass: warning: $warning');
      }
      stdout.writeln(
          'The launcher should appear in the application menu on the next refresh.');
      return const _DesktopCliResult(0);
    } on DesktopIntegrationException catch (e) {
      stderr.writeln('easypass: $e');
      return const _DesktopCliResult(2);
    } on Object catch (e) {
      stderr.writeln('easypass: desktop integration failed: $e');
      return const _DesktopCliResult(2);
    }
  }

  if (rawArgs.contains('--uninstall')) {
    try {
      final result = await service.uninstall();
      stdout.writeln('Removed EasyPass desktop entry: '
          '${result.desktopEntryPath} '
          '(${result.entryRemoved ? "deleted" : "was not present"})');
      for (final icon in result.iconsRemoved) {
        stdout.writeln('  removed icon: $icon');
      }
      for (final dir in result.prunedDirectories) {
        stdout.writeln('  pruned empty dir: $dir');
      }
      for (final warning in result.warnings) {
        stderr.writeln('easypass: warning: $warning');
      }
      stdout.writeln('Status: uninstalled.');
      return const _DesktopCliResult(0);
    } on DesktopIntegrationException catch (e) {
      stderr.writeln('easypass: $e');
      return const _DesktopCliResult(2);
    } on Object catch (e) {
      stderr.writeln('easypass: desktop integration failed: $e');
      return const _DesktopCliResult(2);
    }
  }

  if (rawArgs.contains('--desktop-status')) {
    try {
      final status = await service.status();
      stdout.writeln('Desktop entry: ${status.desktopEntryPath} '
          '(${status.entryExists ? "exists" : "missing"})');
      if (status.entryExists) {
        stdout.writeln('  Exec=${status.execField ?? "(none)"}');
        stdout.writeln('  target=${status.execTarget ?? "(unparseable)"} '
            '(${status.execTargetExecutable ? "executable" : "MISSING or not executable"})');
        stdout.writeln(
            '  StartupWMClass=${status.startupWmClass ?? "(none)"}');
        stdout.writeln('  icon=${status.iconAvailable ? status.iconPaths.join(", ") : "missing"}');
        if (!status.looksLikeOurs) {
          stdout.writeln(
              '  note: this file does not look like an EasyPass entry '
              '(no "Name=EasyPass" / "Type=Application"); leaving it alone.');
        }
      }
      if (status.isInstalled) {
        stdout.writeln(status.iconAvailable
            ? 'Status: installed.'
            : 'Status: installed, but the icon is missing; re-run --install.');
      } else if (status.entryExists) {
        stdout.writeln(
            'Status: broken. The desktop entry does not point at a usable '
            'EasyPass executable. Re-run --install to repair (or --uninstall to remove).');
      } else {
        stdout.writeln(
            'Status: not installed. Run --install to create the desktop entry.');
      }
      // 退出码语义见 [DesktopStatus.toExitCode]（可单测，
      // 见 test/desktop_integration_test.dart）。
      return _DesktopCliResult(status.toExitCode());
    } on DesktopIntegrationException catch (e) {
      stderr.writeln('easypass: $e');
      return const _DesktopCliResult(2);
    } on Object catch (e) {
      stderr.writeln('easypass: desktop integration status failed: $e');
      return const _DesktopCliResult(2);
    }
  }

  return null; // 不会走到这里（上面 contains 已确保命中其一）。
}
