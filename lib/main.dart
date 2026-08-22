import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/crypto/crypto_service.dart';
import 'core/crypto/totp_service.dart';
import 'data/database/database.dart';
import 'data/services/font_discovery_service.dart';
import 'features/browser_bridge/easypass_daemon.dart';
import 'features/browser_bridge/native_messaging_service.dart';

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
  // while the daemon keeps serving the browser extension. If a daemon is
  // already running (e.g. launched by the bridge earlier), reuse it instead
  // of spawning a second one.
  final daemonRunning = await EasypassDaemon.isRunning();
  if (!daemonRunning) {
    // A stale daemon.json (previous daemon exited/crashed) makes bridges hit
    // a dead port and time out; remove it before starting fresh.
    await EasypassDaemon.clearStaleInfo();
    final uiDaemon =
        EasypassDaemon(AppDatabase(), CryptoService(), TotpService());
    try {
      await uiDaemon.start();
    } catch (_) {
      // Daemon failure must never block the UI from starting.
    }
  } else {
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
/// The daemon exits itself when idle; the browser host bridge relaunches it
/// on demand.
Future<void> runDaemon() async {
  final db = AppDatabase();
  final daemon = EasypassDaemon(db, CryptoService(), TotpService());
  try {
    await daemon.start();
  } finally {
    await db.close();
  }
}
