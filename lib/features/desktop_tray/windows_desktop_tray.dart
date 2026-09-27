// Windows desktop-tray stub (P3.1).
//
// Windows tray + close-to-hide are owned by the C++ runner
// (`windows/runner/flutter_window.cpp:97-148`). Dart side never sees
// WM_CLOSE and never has to draw a tray icon. We therefore return an
// `inactive` result and leave the existing behaviour alone.
//
// Keeping the file around (rather than `if (Platform.isWindows)` in the
// public entrypoint) makes the platform matrix explicit at the source
// level and means a future "actually run tray from Dart on Windows" change
// has an obvious home.

import 'desktop_tray.dart';

DesktopTrayResult installWindowsDesktopTray(DateTime clock) {
  return const DesktopTrayResult(
    DesktopTrayStatus.inactive,
    detail: 'Windows owns the tray via the C++ runner.',
  );
}