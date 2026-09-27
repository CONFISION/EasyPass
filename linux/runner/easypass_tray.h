#ifndef RUNNER_EASYPASS_TRAY_H_
#define RUNNER_EASYPASS_TRAY_H_

#include <gtk/gtk.h>

// StatusNotifierItem tray icon for the EasyPass Linux runner.
//
// Mirrors what `windows/runner/flutter_window.cpp` does natively on Windows:
// the tray icon, its menu ("Open EasyPass" | separator | "Exit") and the
// close-to-hide behaviour all live in the runner instead of a Dart plugin.
// That keeps the Dart side free of third-party tray packages, whose Linux
// implementations were measured to be broken (tray_manager 0.7.0 never
// exported the D-Bus menu; 0.5.x never registered the item).
//
// [window] must be the application window. Returns TRUE when a tray icon was
// installed. FALSE means "do not rely on the tray": no StatusNotifier host is
// registered (the icon would be invisible) or the debug hook disabled it — in
// both cases the caller keeps the platform default of "closing the window
// quits the app".
gboolean easypass_tray_install(GtkWindow* window);

// Whether closing the window should hide it instead of quitting: the icon is
// installed AND a StatusNotifier host is actually registered. A live
// AppIndicator object on its own does not prove the icon is visible.
gboolean easypass_tray_is_active(void);

// Restore + raise the application window. Used by the tray's "Open EasyPass"
// menu entry. Safe to call when no window is registered yet (no-op).
void easypass_window_show(void);

// CI / smoke-test hook only. Marks the tray state as quitting so the runner's
// `delete-event` handler does not try to hide the window during the headless
// `EASYPASS_DEBUG_AUTO_EXIT_AFTER_MS` flow. Do not call from product code.
void g_quitting_set_for_test(void);

#endif  // RUNNER_EASYPASS_TRAY_H_
