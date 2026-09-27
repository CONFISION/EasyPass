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

// 总线上是否真的有 StatusNotifier 宿主（面板/托盘实现）。`app_indicator_new*()`
// 在**没有宿主时也照样返回活对象**，所以"indicator 存在"不等于"图标可见"。
// 见 [status_notifier_host_available]。
gboolean g_tray_host_available = FALSE;

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

// 总线上是否注册了 StatusNotifier 宿主 —— KDE 面板、GNOME 的 AppIndicator
// 扩展、Ubuntu 的 indicator 栈都通过 `org.kde.StatusNotifierWatcher` 暴露这个
// 属性（StatusNotifierItem 规范）。
//
// 为什么必须自己问：`app_indicator_new_with_path()` 在没有宿主时**也会成功**，
// 图标只是永远不显示。若据此认定"托盘可用"，关窗就会把**唯一**的窗口藏进一个
// 看不见的托盘里 —— 用户再也拿不回窗口（GNOME 默认不启用该扩展就是这个形态）。
// 这正是 README 承诺的"没有宿主时降级为关窗即退出"，之前只是没实现。
//
// 任何失败（没有会话总线 / watcher 不在 / 超时 / 属性类型不符）一律当作"没有
// 宿主"：退路是 GTK 默认的"关窗即退出"，属良性降级；反过来判错才会把窗口弄丢。
gboolean status_notifier_host_available() {
  g_autoptr(GError) error = nullptr;
  // GApplication / GTK 已经在用会话总线，这里拿的是进程内缓存的连接 —— 正常
  // 桌面下即时返回；只有总线本身挂死才会阻塞，而那时整个桌面都已不可用。
  g_autoptr(GDBusConnection) bus =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (bus == nullptr) {
    g_message("easypass tray: no session bus (%s); assuming no tray host",
              error != nullptr ? error->message : "unknown");
    return FALSE;
  }

  // 250ms 超时：install() 跑在 activate 里、首帧之前，所以这是启动路径上的同
  // 步调用。面板正常时只是本地总线的一次往返（亚毫秒）；只有"名字在但不答"
  // 的病态面板才会等满，代价也只是把首帧推迟 250ms —— 换来的是"判不出来就当
  // 没有宿主"这个安全默认值。若将来真出现启动卡顿，可改成
  // `g_dbus_connection_call` 异步：届时旗标在应答前保持 FALSE，方向同样安全。
  g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
      bus, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
      "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", "org.kde.StatusNotifierWatcher",
                    "IsStatusNotifierHostRegistered"),
      G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 250, nullptr, &error);
  if (reply == nullptr) {
    g_message("easypass tray: StatusNotifierWatcher not reachable (%s); "
              "assuming no tray host",
              error != nullptr ? error->message : "unknown");
    return FALSE;
  }

  g_autoptr(GVariant) value = g_variant_get_child_value(reply, 0);
  if (value == nullptr ||
      !g_variant_is_of_type(value, G_VARIANT_TYPE_VARIANT)) {
    return FALSE;
  }
  g_autoptr(GVariant) unwrapped = g_variant_get_variant(value);
  if (unwrapped == nullptr ||
      !g_variant_is_of_type(unwrapped, G_VARIANT_TYPE_BOOLEAN)) {
    return FALSE;
  }
  return g_variant_get_boolean(unwrapped);
}

void on_open_activate(GtkMenuItem* item, gpointer user_data) {
  easypass_window_show();
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
    // 幂等：已经装过就沿用上次的宿主判定。
    return g_tray_host_available;
  }

  // CI / smoke-test hook. The runner honours `EASYPASS_DEBUG_NO_TRAY` to
  // simulate a desktop with no StatusNotifier host — used by the T4
  // verification flow ("no tray host, close -> quit"). Off by default.
  if (g_getenv("EASYPASS_DEBUG_NO_TRAY") != nullptr) {
    g_warning("easypass tray: EASYPASS_DEBUG_NO_TRAY set; skipping install");
    return FALSE;
  }

  // 有宿主才算"托盘可用"。只算一次：宿主一般在登录时就已注册；用户在启动之后
  // 才启用 GNOME 扩展的情况要重启应用才会开始"关窗隐藏"。这是**安全**的方向
  // —— 宁可关窗退出，也不要把窗口藏进看不见的托盘。
  g_tray_host_available = status_notifier_host_available();
  if (!g_tray_host_available) {
    g_warning("easypass tray: no StatusNotifier host registered; the icon "
              "would be invisible, so closing the window quits the app "
              "instead of hiding to the tray");
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
  // 返回"托盘是否真的可用"而不是"indicator 对象是否建起来了"：没有宿主时图标
  // 不可见，调用方**不该**依赖托盘（头文件里写明了这个契约）。当前调用点
  // （`my_application.cc`）忽略返回值、用 `easypass_tray_is_active()` 决策，
  // 所以这里只是把语义修正到与文档一致。
  return g_tray_host_available;
}

gboolean easypass_tray_is_active(void) {
  // 三个条件缺一不可：indicator 建起来了、总线上真有宿主（否则图标不可见，
  // 藏窗口等于把应用弄丢）、且不是正在退出。
  return g_indicator != nullptr && g_tray_host_available && !g_quitting;
}

// CI / smoke-test hook only. Marks the tray state as quitting so the
// `delete-event` handler does not try to hide the window during the headless
// `EASYPASS_DEBUG_AUTO_EXIT_AFTER_MS` flow — which is just a CI helper, never
// triggered in normal user paths.
void g_quitting_set_for_test(void) {
  g_quitting = TRUE;
}

void easypass_window_show(void) {
  if (g_window == nullptr) {
    return;
  }
  gtk_widget_show(GTK_WIDGET(g_window));
  gtk_window_present(g_window);
}
