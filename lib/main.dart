import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/crypto/crypto_service.dart';
import 'core/crypto/totp_service.dart';
import 'data/database/database.dart';
import 'data/services/font_discovery_service.dart';
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
