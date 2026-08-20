import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'data/services/font_discovery_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
