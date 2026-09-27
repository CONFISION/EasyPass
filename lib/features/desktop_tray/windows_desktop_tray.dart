// Windows desktop-tray stub.
//
// Windows tray + close-to-hide are owned by the C++ runner
// (`windows/runner/flutter_window.cpp`: CreateTrayIcon / WM_CLOSE /
// TaskbarCreated). The Dart side never sees WM_CLOSE and never has to draw a
// tray icon, so we return an `inactive` result and leave that behaviour alone.
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