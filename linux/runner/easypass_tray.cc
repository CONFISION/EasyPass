#include "easypass_tray.h"

#include <flutter_linux/flutter_linux.h>

#ifdef HAVE_AYATANA
#include <libayatana-appindicator/app-indicator.h>
#else
#include <libappindicator/app-indicator.h>
#endif

namespace {

AppIndicator* g_indicator = nullptr;
GtkWindow* g_window = nullptr;
gboolean g_quitting = FALSE;

// Icon candidates, in order. `flutter build linux` puts bundled assets under
// `<exedir>/data/flutter_assets/`; the AppImage layout keeps them next to the
// binary in `usr/bin/assets/`. Both are checked at runtime because the same
// binary serves both layouts.
const char* kIconSuffixes[] = {
    "data/flutter_assets/assets/icons/Easypass.png",
    "assets/icons/Easypass.png",
    "../assets/icons/Easypass.png",
};

gchar* resolve_icon_path() {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) {
    return nullptr;
  }
  g_autofree gchar* exe_dir = g_path_get_dirname(exe);
  for (const char* suffix : kIconSuffixes) {
    g_autofree gchar* candidate = g_build_filename(exe_dir, suffix, nullptr);
    if (g_file_test(candidate, G_FILE_TEST_IS_REGULAR)) {
      return g_strdup(candidate);
    }
  }
  return nullptr;
}

void on_open_activate(GtkMenuItem* item, gpointer user_data) {
  if (g_window == nullptr) {
    return;
  }
  gtk_widget_show(GTK_WIDGET(g_window));
  gtk_window_present(g_window);
}

void on_exit_activate(GtkMenuItem* item, gpointer user_data) {
  g_quitting = TRUE;
  if (g_window != nullptr) {
    gtk_widget_destroy(GTK_WIDGET(g_window));
  }
  GApplication* app = g_application_get_default();
  if (app != nullptr) {
    // Drop the tray-mode hold taken in the runner so the loop can finish.
    g_application_release(app);
    g_application_quit(app);
  }
}

GtkWidget* build_menu() {
  GtkWidget* menu = gtk_menu_new();

  GtkWidget* open_item = gtk_menu_item_new_with_label("Open EasyPass");
  g_signal_connect(open_item, "activate", G_CALLBACK(on_open_activate),
                   nullptr);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), open_item);

  gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

  GtkWidget* exit_item = gtk_menu_item_new_with_label("Exit");
  g_signal_connect(exit_item, "activate", G_CALLBACK(on_exit_activate),
                   nullptr);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), exit_item);

  return menu;
}

}  // namespace

gboolean easypass_tray_install(GtkWindow* window) {
  if (g_indicator != nullptr) {
    return TRUE;
  }

  g_autofree gchar* icon_path = resolve_icon_path();
  // libayatana-appindicator resolves a bare name through the icon theme, so
  // fall back to the bundled name rather than showing nothing at all.
  const gchar* icon = icon_path != nullptr ? icon_path : "easypass";
  if (icon_path == nullptr) {
    g_warning("easypass tray: bundled icon not found; using theme name");
  }

  GtkWidget* menu = build_menu();
  gtk_widget_show_all(menu);

  // The id doubles as the StatusNotifierItem identity on the session bus.
  //
  // libayatana-appindicator 0.5.94 marks its entire GTK API deprecated in
  // favour of the separately packaged `libayatana-appindicator-glib` family,
  // which the distributions this port targets do not ship. The GTK API still
  // works (GNOME's own AppIndicator extension hosts it); the deprecation is
  // therefore localised here instead of calling into a library that may not
  // exist. `#pragma` keeps the runner clean under the template's `-Werror`.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
#ifdef HAVE_AYATANA
  g_indicator = app_indicator_new_with_path(
      "easypass", icon, APP_INDICATOR_CATEGORY_APPLICATION_STATUS, nullptr);
#else
  g_indicator = app_indicator_new("easypass", icon,
                                  APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
#endif
#pragma GCC diagnostic pop
  if (g_indicator == nullptr) {
    g_warning("easypass tray: app_indicator_new failed");
    return FALSE;
  }

  app_indicator_set_title(g_indicator, "EasyPass");
  app_indicator_set_menu(g_indicator, GTK_MENU(menu));
  app_indicator_set_status(g_indicator, APP_INDICATOR_STATUS_ACTIVE);

  g_window = window;
  return TRUE;
}

gboolean easypass_tray_is_active(void) {
  return g_indicator != nullptr && !g_quitting;
}
