#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "easypass_tray.h"

// ─── Dart → runner window channel ───────────────────────────────────────────
//
// 窗口归本 runner 所有（托盘菜单、关窗最小化都在 C++ 侧），但"二次启动唤起
// 已有窗口"的起点在 Dart：`single_instance_raise_host.dart` 收到 raise 字节
// 后调 `WindowController.show()`。这里只提供那一个原生方法。通道名必须与
// `lib/features/desktop_tray/linux_window_controller.dart` 的
// `kLinuxWindowChannelName` 一致。
static FlMethodChannel* g_window_channel = nullptr;

static void window_method_call_cb(FlMethodChannel* channel,
                                  FlMethodCall* method_call,
                                  gpointer user_data) {
  // 与同文件其它回调一致：显式标注未使用参数，避免将来开启 -Wextra 时被
  // `-Wunused-parameter` + `-Werror` 断掉构建。
  (void)channel;
  (void)user_data;
  g_autoptr(GError) error = nullptr;
  if (g_strcmp0(fl_method_call_get_name(method_call), "show") == 0) {
    easypass_window_show();
    if (!fl_method_call_respond_success(method_call, nullptr, &error)) {
      // `@error` 是 (allow-none)：引擎有"返回 FALSE 但不设 error"的路径
      // （fl_binary_messenger.cc 的 g_return_val_if_fail 分支），直接取
      // error->message 会空指针解引用。
      g_warning("easypass window channel: failed to respond: %s",
                error != nullptr ? error->message : "unknown");
    }
    return;
  }
  if (!fl_method_call_respond_not_implemented(method_call, &error)) {
    g_warning("easypass window channel: failed to respond: %s",
              error != nullptr ? error->message : "unknown");
  }
}

// 注册一次、进程内复用：`activate` 只跑一次（`G_APPLICATION_NON_UNIQUE`
// 加单实例闸门），所以静态持有是安全的；`fl_method_channel_new` 返回的是
// 非浮动引用（messenger 自己也持一份），进程退出时随进程回收。
static void window_channel_register(FlView* view) {
  if (g_window_channel != nullptr) {
    return;
  }
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "com.easypass.app/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_window_channel,
                                            window_method_call_cb, nullptr,
                                            nullptr);
}

// 窗口最小尺寸，与 Windows runner 的 kMinWindowWidth / kMinWindowHeight
// (windows/runner/win32_window.cpp) 对齐；那两个常量又是按
// `lib/features/vault/screens/vault_screen.dart` 的固定侧边栏宽度
// (_sidebarWidth = 248) 定的。少了它，Linux 上窄窗会像当年 Windows 那样溢出
// （见 AGENTS.md「窗口最小尺寸在原生层强制」）。
//
// GTK 的 size request 用**逻辑像素**，所以这里不需要像 Win32 那样自己乘 DPI
// 缩放、也不需要手动夹到显示器工作区 —— 由 GTK / 窗口管理器处理。
static const int kMinWindowWidth = 900;
static const int kMinWindowHeight = 600;

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Quits the application once its window is really gone. Needed because the
// window is a plain toplevel (see `my_application_activate`), so nothing else
// would end the main loop after "close without tray".
static void my_application_window_destroyed(GtkWidget* widget,
                                            gpointer user_data) {
  g_application_quit(G_APPLICATION(user_data));
}

// CI / smoke-test hook callback — see `EASYPASS_DEBUG_AUTO_CLOSE_MS` in
// `my_application_activate`. `gtk_widget_event(widget, GDK_DELETE_event)`
// is the exact dispatch path GTK uses when forwarding a window-manager close
// request (Wayland `xdg_toplevel::close`, X11 `WM_DELETE_WINDOW`) — those
// arrive as `GDK_DELETE` events through `gtk_main_do_event`. Without a real
// graphical session we cannot click the close button, so the hook synthesises
// the same GDK event and feeds it through `gtk_widget_event`, exercising the
// close-to-tray path end-to-end.
static gboolean debug_auto_close_cb(gpointer user_data) {
  GtkWidget* window = GTK_WIDGET(user_data);
  GdkEvent* event = gdk_event_new(GDK_DELETE);
  event->any.window = gtk_widget_get_window(window);
  if (event->any.window != nullptr) {
    g_object_ref(event->any.window);
  }
  gtk_widget_event(window, event);
  if (event->any.window != nullptr) {
    g_object_unref(event->any.window);
  }
  gdk_event_free(event);
  return G_SOURCE_REMOVE;
}

// CI / smoke-test hook callback — see `EASYPASS_DEBUG_AUTO_SHOW_AFTER_MS` in
// `my_application_activate`. Mirrors the tray "Open EasyPass" code path so a
// headless / unattended run can verify that the window can be restored after
// being hidden.
static gboolean debug_auto_show_cb(gpointer user_data) {
  (void)user_data;
  easypass_window_show();
  return G_SOURCE_REMOVE;
}

// CI / smoke-test hook callback — see `EASYPASS_DEBUG_AUTO_EXIT_AFTER_MS` in
// `my_application_activate`. Mirrors the tray "Exit" code path so a
// headless / unattended run can verify that quit actually tears down the
// process and the tray entry.
static gboolean debug_auto_exit_cb(gpointer user_data) {
  GtkWindow* window = GTK_WINDOW(user_data);
  // Mark quitting first so `easypass_tray_is_active()` returns FALSE — this
  // mirrors `on_exit_activate` in easypass_tray.cc.
  g_quitting_set_for_test();
  gtk_widget_destroy(GTK_WIDGET(window));
  GApplication* app = g_application_get_default();
  if (app != nullptr) {
    g_application_release(app);
    g_application_quit(app);
  }
  return G_SOURCE_REMOVE;
}

// Close-to-tray: mirrors `windows/runner/flutter_window.cpp`. When a tray
// icon is live, closing the window hides it and the app keeps running;
// without a tray host the default GTK behaviour (destroy → quit) is kept so
// the app never becomes unreachable.
//
// The Flutter Linux embedder (engine 3.47+) registers its own `delete-event`
// handler on the toplevel in `fl_view::realize_cb` and calls
// `fl_engine_request_app_exit` → `System.requestAppExit` (CANCELABLE) on the
// platform channel; Dart's `WidgetsBinding` answers it by default with
// `SystemNavigator.pop`, which the embedder turns into `quit_application()`
// → `g_application_quit` → process exit. Returning TRUE from this handler
// only suppresses GTK's default destruction, not the other handlers on the
// signal — so just returning TRUE here is not enough; the embedder's
// `delete-event` handler must be disconnected at startup (see
// `my_application_activate`). With that disconnect in place, this handler
// becomes the only one observing the close and the window can be hidden
// without the embedder noticing.
static gboolean my_application_window_delete(GtkWidget* widget,
                                             GdkEvent* event,
                                             gpointer user_data) {
  if (!easypass_tray_is_active()) {
    return FALSE;
  }
  gtk_widget_hide(widget);
  // Returning TRUE also blocks GTK's default `gtk_widget_destroy` fallback for
  // the same signal; both belts and braces. The Flutter embedder's
  // `delete-event` handler was disconnected in `my_application_activate` so
  // it never observes this close at all.
  return TRUE;
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  // Deliberately **not** `gtk_application_window_new`: GTK keeps a per-application
  // window list and ends the main loop as soon as the last window in it is
  // hidden — which is exactly what "close to tray" does, so the tray icon and
  // the whole process disappeared with the window (measured: exit code 0 right
  // after `gtk_widget_hide`). A plain toplevel keeps the loop alive; the app
  // lifetime is managed explicitly below (hold while the tray is up, quit when
  // the window is really destroyed).
  GtkWindow* window = GTK_WINDOW(gtk_window_new(GTK_WINDOW_TOPLEVEL));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "easypass");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "easypass");
  }

  gtk_window_set_default_size(window, 1280, 720);
  // 最小尺寸（见 kMinWindowWidth/kMinWindowHeight），并**夹到显示器工作区**：
  // 在 1920x1080@200% 这类缩放下逻辑工作区只有 960x540，硬要 600 逻辑像素的
  // 高度会让窗口比屏幕还高，底部 UI 永远够不到。Windows runner 同样要夹
  // （AGENTS.md「窗口最小尺寸在原生层强制 … 并夹到显示器工作区内」），这里
  // 用 GTK 的等价物。`gdk_monitor_get_workarea` 给的是应用（逻辑）像素，与
  // size request 同单位，所以直接比较即可 —— 不需要像 Win32 那样自己乘 DPI。
  // 取不到显示器 / 工作区不可信（0）时保持原值：宁可尺寸大一点，也不要因为
  // 探测失败把最小值设成 0 而失去保护。
  gint min_width = kMinWindowWidth;
  gint min_height = kMinWindowHeight;
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  GdkMonitor* monitor =
      display != nullptr ? gdk_display_get_monitor(display, 0) : nullptr;
  if (monitor != nullptr) {
    GdkRectangle workarea = {0, 0, 0, 0};
    gdk_monitor_get_workarea(monitor, &workarea);
    if (workarea.width > 0 && min_width > workarea.width) {
      min_width = workarea.width;
    }
    if (workarea.height > 0 && min_height > workarea.height) {
      min_height = workarea.height;
    }
  }
  gtk_widget_set_size_request(GTK_WIDGET(window), min_width, min_height);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // Dart 侧调 `WindowController.show()` 的入口（二次启动唤起窗口）。
  window_channel_register(view);

  // Tray icon + close-to-hide live in the runner (like Windows), which keeps
  // the Dart side free of third-party tray packages whose Linux plugins were
  // measured to be broken.
  g_signal_connect(window, "delete-event",
                   G_CALLBACK(my_application_window_delete), nullptr);
  g_signal_connect(window, "destroy",
                   G_CALLBACK(my_application_window_destroyed), application);

  // The Flutter Linux embedder registers its own `delete-event` handler on
  // the toplevel in `fl_view::realize_cb` (which runs from
  // `gtk_widget_realize(GTK_WIDGET(view))` above, before this point). It calls
  // `fl_engine_request_app_exit` → `System.requestAppExit` (CANCELABLE) on
  // the platform channel; Dart's `WidgetsBinding` answers it by default with
  // `SystemNavigator.pop`, which the embedder turns into `quit_application()`
  // → `g_application_quit` → process exit. The runner's hide-on-close handler
  // is connected *after* the embedder's, so under FIFO emission the embedder
  // runs first and the process dies before our handler sees the close. We
  // disconnect the embedder's handler instead: its connection was made with
  // `g_signal_connect_object(... G_CONNECT_SWAPPED, self=view, ...)` so its
  // user-data is the FlView. `g_signal_handlers_disconnect_matched` keyed by
  // user-data is the precise teardown — the only `delete-event` handler that
  // captures the FlView is the embedder's. (The trampoline function is a
  // private static symbol in libflutter_linux_gtk.so and not exported.)
  //
  // 已对 engine 源码核实（`shell/platform/linux/fl_view.cc` 的 realize_cb）：
  // toplevel 上只连了 `delete-event`，它其余的信号连接都挂在 view 自己的子
  // 部件上。即便如此这里仍把匹配**收窄到 delete-event**：传 signal_id = 0 会
  // 摘掉"这个窗口上所有 user-data 为 view 的处理器"，今天只有 embedder 那
  // 一个，但收窄过的匹配不会在将来悄悄让某个新处理器失效。若
  // `g_signal_lookup` 返回 0（找不到），id 退化为 0 = 旧行为，不会更糟。
  const guint delete_event_signal =
      g_signal_lookup("delete-event", GTK_TYPE_WIDGET);
  g_signal_handlers_disconnect_matched(
      window,
      G_SIGNAL_MATCH_DATA,
      delete_event_signal, 0, nullptr, nullptr, view);

  easypass_tray_install(window);
  if (easypass_tray_is_active()) {
    // A tray-style app must survive having no visible window: without this
    // hold, GApplication drops its use count once the last window is hidden
    // and quits, taking the tray icon with it (measured: the process exited
    // right after `gtk_widget_hide` even though delete-event was handled).
    g_application_hold(application);
  }

  // CI / smoke-test hook. Without a real Wayland/X session to click the
  // title-bar close button, an unattended run cannot trigger the delete-event
  // path this code is meant to handle. Setting `EASYPASS_DEBUG_AUTO_CLOSE_MS`
  // to a positive millisecond count schedules a `gtk_window_close` against the
  // toplevel — which is the same code path the window manager uses (it emits
  // `delete-event` on the window) — so headless / remote CI runs can verify
  // "close to tray" end-to-end. Setting `EASYPASS_DEBUG_AUTO_SHOW_AFTER_MS`
  // schedules a call into the tray's "Open EasyPass" path (`easypass_window_show`)
  // at the given offset, used by the CI flow to verify the "restore window from
  // tray" code path. Off by default; ignored when the variable is unset /
  // non-positive / greater than five minutes.
  {
    const gchar* auto_close_ms = g_getenv("EASYPASS_DEBUG_AUTO_CLOSE_MS");
    if (auto_close_ms != nullptr) {
      gchar* end = nullptr;
      glong ms = g_ascii_strtoll(auto_close_ms, &end, 10);
      if (end != auto_close_ms && ms > 0 && ms <= 5 * 60 * 1000) {
        g_timeout_add((guint)ms, debug_auto_close_cb, window);
      }
    }
    const gchar* auto_show_ms = g_getenv("EASYPASS_DEBUG_AUTO_SHOW_AFTER_MS");
    if (auto_show_ms != nullptr) {
      gchar* end = nullptr;
      glong ms = g_ascii_strtoll(auto_show_ms, &end, 10);
      if (end != auto_show_ms && ms > 0 && ms <= 5 * 60 * 1000) {
        g_timeout_add((guint)ms, debug_auto_show_cb, window);
      }
    }
    const gchar* auto_exit_ms = g_getenv("EASYPASS_DEBUG_AUTO_EXIT_AFTER_MS");
    if (auto_exit_ms != nullptr) {
      gchar* end = nullptr;
      glong ms = g_ascii_strtoll(auto_exit_ms, &end, 10);
      if (end != auto_exit_ms && ms > 0 && ms <= 5 * 60 * 1000) {
        g_timeout_add((guint)ms, debug_auto_exit_cb, window);
      }
    }
  }


  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
