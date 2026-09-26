// Window controller abstraction (P3.1).
//
// The desktop-tray layer needs three things from the host window:
//   1. Interception of the native close button so we can choose between
//      "hide to tray" and "quit the app" at runtime.
//   2. `show()` / `hide()` for the "Open EasyPass" menu item and the
//      daemon-driven "display the locked window" path.
//   3. A way to ask "are we visible right now?" so the menu can label itself
//      "Open" vs "Hide EasyPass" (Windows uses the latter; Linux P3.1 uses
//      the former because the menu also lacks a "Hide" item, mirroring
//      `windows/runner/flutter_window.cpp:137-148`).
//
// Splitting these out as an interface keeps `lib/main.dart` and the Linux
// implementation free of any `window_manager` symbols, which in turn makes
// unit tests trivial — `TestWindowController` below is enough to exercise
// every branch without ever opening a GTK window.

import 'package:flutter/foundation.dart';

/// Choice for what `WindowController` should do when the OS asks the window
/// to close (Linux: `delete_event` from the WM; Windows: WM_CLOSE — but
/// Windows goes through the runner C++ and never reaches us).
enum WindowCloseAction {
  /// Hide the window without terminating the process. The tray icon stays
  /// alive and the daemon keeps serving the browser extension. This is the
  /// Bitwarden-style behaviour the existing Windows runner already
  /// implements.
  hide,

  /// Terminate the process. Used when the tray could not be created (e.g.
  /// GNOME without an AppIndicator extension) — there is nowhere to hide to.
  quit,
}

/// Thin interface over the host window. The real implementation lives in
/// `linux_desktop_tray.dart` and wraps `window_manager`; tests can pass a
/// [TestWindowController] without ever touching a real window.
abstract class WindowController {
  /// Choose what should happen when the OS asks the window to close.
  /// Called once at install time; changing it later is allowed but rare.
  /// The setter must take effect immediately — implementations re-arm the
  /// platform close interceptor behind the scenes.
  WindowCloseAction get closeAction;
  set closeAction(WindowCloseAction action);

  /// Make the window visible and bring it to the front.
  Future<void> show();

  /// Hide the window. Calling twice is a no-op.
  Future<void> hide();

  /// Whether the window is currently visible to the user. Used by menu
  /// code to pick between "Open" and "Hide EasyPass".
  Future<bool> isVisible();

  /// Tear down any listeners the controller registered. Safe to call
  /// multiple times.
  Future<void> dispose();
}

/// In-memory window controller for tests. Records every call so assertions
/// can inspect the sequence (e.g. "on close we called hide, not quit").
class TestWindowController implements WindowController {
  TestWindowController({
    WindowCloseAction initialAction = WindowCloseAction.hide,
    bool initialVisible = true,
  })  : _closeAction = initialAction,
        _visible = initialVisible;

  WindowCloseAction _closeAction;

  @override
  WindowCloseAction get closeAction => _closeAction;
  @override
  set closeAction(WindowCloseAction action) {
    if (_closeAction == action) return;
    _closeAction = action;
    calls.add('closeAction=$action');
  }

  bool _visible;

  /// Every method call, in order. Used to assert that "close → hide, not
  /// quit" and "show → setVisible(true)" without depending on real platform
  /// behaviour.
  final List<String> calls = <String>[];

  @override
  Future<void> show() async {
    calls.add('show');
    _visible = true;
  }

  @override
  Future<void> hide() async {
    calls.add('hide');
    _visible = false;
  }

  @override
  Future<bool> isVisible() async {
    calls.add('isVisible');
    return _visible;
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
  }

  @visibleForTesting
  void setVisibleForTest(bool value) {
    _visible = value;
  }
}