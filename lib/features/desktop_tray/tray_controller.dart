// Tray controller abstraction (P3.1).
//
// The tray menu items map to one of these actions. The Linux implementation
// (see `linux_desktop_tray.dart`) wires each menu item to a callback that
// triggers a [TrayAction]; the controller owns the dispatch so the menu
// code never has to know about specific actions.
//
// Mirrors the menu shape in `windows/runner/flutter_window.cpp:137-148`:
// exactly two items, "Open EasyPass" and "Exit", separated by a divider.

import 'package:flutter/foundation.dart';

/// What the user picked from the tray menu. Kept as a sealed-style enum so
/// we can exhaustively switch in tests.
enum TrayAction {
  /// Show / bring the main window to the foreground.
  showWindow,

  /// Quit the entire process. On Linux this fires `exit(0)`; on Windows the
  /// C++ runner owns the exit path.
  quit,
}

/// Thin interface over the system tray. Real impl wraps `tray_manager`
/// (KDE / StatusNotifierItem + D-Bus); tests use [TestTrayController].
abstract class TrayController {
  /// Update which actions are enabled in the menu. We don't currently use
  /// this — kept so future items (e.g. a "Lock now" entry that only makes
  /// sense when the vault is unlocked) have an obvious home.
  void setEnabled(TrayAction action, bool enabled);

  /// Update the tooltip / hover text shown by the panel.
  Future<void> setTooltip(String text);

  /// Tear down the tray icon. Safe to call multiple times.
  Future<void> dispose();
}

/// In-memory tray controller for tests. Captures every dispatch so a unit
/// test can assert "tapping Open called windowController.show() once".
class TestTrayController implements TrayController {
  TestTrayController();

  /// Every menu click, in order.
  final List<TrayAction> actions = <TrayAction>[];

  /// Most-recent tooltip set via [setTooltip], or `null` if none.
  String? tooltip;

  @override
  void setEnabled(TrayAction action, bool enabled) {
    // No-op in tests; we model enable state via the [actions] log instead.
  }

  @override
  Future<void> setTooltip(String text) async {
    tooltip = text;
  }

  @override
  Future<void> dispose() async {}

  /// Simulate the user clicking an entry. The wiring in production is "menu
  /// item clicked → callback → controller.dispatch(action)"; in tests we
  /// skip the menu and call the controller directly.
  @visibleForTesting
  void dispatchForTest(TrayAction action) {
    actions.add(action);
  }
}