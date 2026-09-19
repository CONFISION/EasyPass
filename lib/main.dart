import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/constants/app_constants.dart';
import 'core/crypto/crypto_service.dart';
import 'core/crypto/totp_service.dart';
import 'data/database/database.dart';
import 'data/services/font_discovery_service.dart';
import 'features/browser_bridge/browser_session_registry.dart';
import 'features/browser_bridge/easypass_daemon.dart';
import 'features/browser_bridge/native_messaging_service.dart';
import 'features/browser_bridge/vault_session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Native messaging host mode: launched by the browser extension
  // (`easypass.exe --native-host`, see browser_extension/native_host/).
  // Serves the stdin/stdout JSON protocol instead of the UI.
  // The runner (windows/runner/main.cpp) mirrors the flag into the
  // EASYPASS_NATIVE_HOST environment variable because
  // Platform.executableArguments is not reliably populated on Flutter
  // Windows; keep both checks for safety.
  final isNativeHost = Platform.environment['EASYPASS_NATIVE_HOST'] == '1' ||
      Platform.executableArguments.contains('--native-host');
  if (isNativeHost) {
    await runNativeHost();
    return;
  }

  // Background daemon mode (`easypass.exe --service`, launched on demand by
  // the native host bridge). Serves the protocol over TCP localhost so the
  // extension works regardless of browser bitness and without the UI open.
  final isDaemon = Platform.environment['EASYPASS_SERVICE'] == '1' ||
      Platform.executableArguments.contains('--service');
  if (isDaemon) {
    await runDaemon();
    return;
  }

  // UI mode: keep the background daemon (extension backend) alive in this
  // process, Bitwarden style -- closing the window hides the app to the tray
  // while the daemon keeps serving the browser extension.
  //
  // 注意不能只看"端口能不能连上"：升级后**旧的 daemon 进程**可能仍在服务扩展，
  // 它不认识新动作（扩展侧表现为"未知操作/无法连接"）。所以这里做协议版本
  // 探测：能应答且版本一致才复用；陈旧则尽力结束旧进程 + 清掉 daemon.json，
  // 由本进程接管；残留文件（端口已死）直接清掉。
  final probe = await EasypassDaemon.probe();
  if (!probe.isUsable) {
    await EasypassDaemon.retire(probe);
    try {
      await startInProcessDaemon();
    } catch (_) {
      // Daemon failure must never block the UI from starting.
    }
  }

  // Lock app in portrait mode
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Register bundled fonts (shipped next to the executable under
  // assets/fonts/) with the text engine before the UI builds.
  await FontDiscoveryService.loadBundledFonts();

  runApp(
    const ProviderScope(
      child: EasyPassApp(),
    ),
  );
}

/// Runs the native messaging host loop. Shares the same database file and
/// secure storage as the UI (same executable directory), so the browser
/// extension can query credentials while the desktop app is closed.
Future<void> runNativeHost() async {
  final db = AppDatabase();
  final cryptoService = CryptoService();
  final service = NativeMessagingService(db, cryptoService, TotpService());
  try {
    await service.start();
  } finally {
    await db.close();
    // The runner keeps its (hidden) window and message loop alive after Dart
    // main() returns, so without an explicit exit the host process would
    // linger every time the browser closes the pipe (stdin EOF). Exit here so
    // each host process lives exactly as long as the browser connection.
    exit(0);
  }
}

/// Runs the background daemon: owns the vault database and serves the
/// native messaging protocol over loopback TCP (see [EasypassDaemon]).
/// The browser host bridge relaunches it on demand.
Future<void> runDaemon() async {
  final db = AppDatabase();
  try {
    await startInProcessDaemon(
      database: db,
      // 空闲自退：桥接按需拉起的 `--service` 进程不能赖着不走 —— 升级后旧
      // 进程一直服务扩展、对新动作一律回 `Unknown action: xxx` 正是这次的
      // 根因。退出前会删掉自己写的 daemon.json（见 maybeExitWhenIdle）。
      // UI 模式不传这个开关：daemon 与 UI 同进程，退出等于把用户踢出应用。
      exitWhenIdle: true,
      onIdleExit: () async {
        await db.close();
        exit(0);
      },
    );
  } catch (_) {
    // Nothing will serve: release the database handle and let the failure
    // surface (the bridge will relaunch the daemon on the next request).
    await db.close();
    rethrow;
  }
  // On success the daemon keeps serving until the process exits, so the
  // database connection must stay open -- closing it here would race with the
  // first bridge connection and break every query after it.
}

/// Creates the daemon's [VaultSession] with the idle timeout the user
/// configured for auto-lock (Settings, 1-60 min; default 5), registers it so
/// locking the desktop app also locks the browser session immediately, and
/// starts the daemon.
///
/// The session is seeded from the persisted auto-lock preference at startup;
/// changing the setting takes effect for the browser session on next launch
/// (the desktop timer itself updates immediately).
///
/// [exitWhenIdle] / [onIdleExit] 只给 `--service` 模式用：空闲自退是"升级后
/// 旧 daemon 让位"的自愈机制，与 [EasypassDaemon.probe] 的版本判定互补
/// （前者覆盖"没人打开应用、只有浏览器在用"的场景）。
Future<EasypassDaemon> startInProcessDaemon({
  AppDatabase? database,
  CryptoService? cryptoService,
  bool exitWhenIdle = false,
  Future<void> Function()? onIdleExit,
}) async {
  final db = database ?? AppDatabase();
  final crypto = cryptoService ?? CryptoService();
  final session = VaultSession(idleTimeout: await _sessionIdleTimeout(crypto));
  BrowserSessionRegistry.register(session);

  final daemon = EasypassDaemon(db, crypto, TotpService(),
      session: session, exitWhenIdle: exitWhenIdle, onIdleExit: onIdleExit);
  await daemon.start();
  return daemon;
}

/// Idle timeout for the browser session: mirrors the desktop auto-lock setting
/// (clamped to the same 1-60 minute range as the settings UI).
Future<Duration> _sessionIdleTimeout(CryptoService cryptoService) async {
  try {
    final minutes = await cryptoService.getAutoLockMinutes();
    return Duration(minutes: minutes.clamp(1, 60));
  } catch (_) {
    // Secure storage unavailable: fall back to the shipped default (5 min).
    return const Duration(minutes: AppConstants.autoLockTimeoutMinutes);
  }
}
