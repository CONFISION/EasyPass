#include "easypass_tray.h"

#include <flutter_linux/flutter_linux.h>
// WIFEXITED / WEXITSTATUS：`g_spawn_sync` 回的是 `waitpid()` 原始状态。
// 刻意**不用** `g_spawn_check_wait_status()`（GLib 2.70+ 才有）：AppImage 不
// 打包 GLib，用的是发行版运行时，多要一个新符号就多一类"老发行版上点菜单即
// 崩"的失败模式；这个文件其余 API 也都在很旧的 GLib 里就有。
#include <sys/wait.h>

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

// 核心可执行文件名。安装布局把它放在 UI 旁边的 `core/` 子目录（核心按
// `<exe>/../lib/<name>` 解析自己的原生库，见 tool/build_core.sh），开发态的扁平
// 布局（build/linux/.../bundle、spike_core）则与 UI 同目录。核心不是 GTK 程序，
// 这里只负责按路径把它拉起来。
const char* kCoreBinaryName = "easypass_core";

// 核心可执行文件相对 UI 目录的候选位置，按顺序取第一个存在的。
const char* kCoreRelativePaths[] = {
    "core/easypass_core",
    "easypass_core",
};

// `g_spawn_sync` 需要 `gchar**`（非 const），但不会改写实参，所以给可写的数组
// 而不是对字符串字面量做 const_cast。
gchar kShutdownArgument[] = "--shutdown";
gchar kLockArgument[] = "--lock";

// 本进程 exe 所在目录；`/proc/self/exe` 是 Linux 上唯一可靠的自身路径（cwd 和
// argv[0] 都可能被调用方改写）。失败返回 nullptr，调用方必须兜底。
gchar* resolve_exe_dir() {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) {
    return nullptr;
  }
  return g_path_get_dirname(exe);
}

// 核心服务的绝对路径（`<UI 目录>/core/easypass_core` → `<UI 目录>/easypass_core`）。
// 找不到返回 nullptr —— 开发态（`flutter run` / 只 build 了 UI）就是这个分支，
// 调用方必须静默跳过而不是报错。
gchar* resolve_core_executable() {
  g_autofree gchar* exe_dir = resolve_exe_dir();
  if (exe_dir == nullptr) {
    return nullptr;
  }
  for (const char* relative : kCoreRelativePaths) {
    g_autofree gchar* candidate = g_build_filename(exe_dir, relative, nullptr);
    if (g_file_test(candidate, G_FILE_TEST_IS_EXECUTABLE)) {
      return g_strdup(candidate);
    }
  }
  return nullptr;
}

gchar* resolve_icon_path() {
  g_autofree gchar* exe_dir = resolve_exe_dir();
  if (exe_dir == nullptr) {
    return nullptr;
  }
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

// 弹一个模态错误框。父窗口**不可见时不挂父窗口**：窗口此时多半藏在托盘里，
// 把 dialog 设成不可见窗口的 transient 会让部分窗口管理器把提示也一起藏起来
// —— 用户点了"完整退出服务"却什么都没发生，正是最坏的结果。
void show_error_dialog(const gchar* primary, const gchar* detail) {
  GtkWindow* parent = nullptr;
  if (g_window != nullptr && gtk_widget_get_visible(GTK_WIDGET(g_window))) {
    parent = g_window;
  }
  GtkWidget* dialog = gtk_message_dialog_new(
      parent,
      static_cast<GtkDialogFlags>(GTK_DIALOG_MODAL |
                                  GTK_DIALOG_DESTROY_WITH_PARENT),
      GTK_MESSAGE_ERROR, GTK_BUTTONS_CLOSE, "%s", primary);
  if (detail != nullptr) {
    gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dialog), "%s",
                                             detail);
  }
  gtk_dialog_run(GTK_DIALOG(dialog));
  gtk_widget_destroy(dialog);
}

// 跑一次核心 CLI（`--shutdown` / `--lock`）并等它结束。
//
// 成功（退出码 0）返回 TRUE；失败返回 FALSE 并把可读原因写进 *error_detail
// （调用方负责提示 —— 两个动作的文案不同，这里不弹框）。同步等待
// （`g_spawn_sync`）会短暂阻塞主循环：这是托盘菜单里的显式动作，核心侧 CLI 自带
// 超时，卡住的窗口只是"点了没反应"而不是数据风险；换成异步需要把菜单回调拆成
// 状态机，收益不足。
gboolean run_core_command(gchar* core, gchar* argument, gchar** error_detail) {
  g_autofree gchar* exe_dir = resolve_exe_dir();
  if (exe_dir == nullptr) {
    *error_detail =
        g_strdup("The EasyPass installation directory could not be determined.");
    return FALSE;
  }

  gchar* argv[] = {core, argument, nullptr};
  g_autoptr(GError) error = nullptr;
  gint wait_status = 0;
  // 核心是控制台程序，stdout/stderr 丢进 /dev/null：桌面启动的 UI 没有终端，
  // 让输出继承父进程只会污染日志或阻塞。
  const GSpawnFlags flags = static_cast<GSpawnFlags>(
      G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL);
  if (!g_spawn_sync(exe_dir, argv, nullptr, flags, nullptr, nullptr, nullptr,
                    nullptr, &wait_status, &error)) {
    *error_detail = g_strdup_printf(
        "Could not run:\n%s %s\n\n%s", core, argument,
        error != nullptr ? error->message : "unknown error");
    return FALSE;
  }

  // 核心 CLI 契约：成功 0 / 无核心、超时或失败 1。非 0 一律当失败处理，并把
  // 退出码放进提示，方便用户/我们判断是"没找到核心"还是"停机超时"。
  if (!WIFEXITED(wait_status) || WEXITSTATUS(wait_status) != 0) {
    if (WIFEXITED(wait_status)) {
      *error_detail = g_strdup_printf("`easypass_core %s` exited with code %d.",
                                      argument, WEXITSTATUS(wait_status));
    } else {
      *error_detail = g_strdup_printf(
          "`easypass_core %s` was terminated abnormally (status %d).", argument,
          wait_status);
    }
    return FALSE;
  }

  return TRUE;
}

// "完整退出服务"：拉起 `<UI 目录>/core/easypass_core --shutdown` 并等它结束。
// 返回 TRUE 表示核心已经不在（CLI 退出码 0 —— 契约：无核心运行时也是 0）。
gboolean stop_core_service() {
  g_autofree gchar* core = resolve_core_executable();
  if (core == nullptr) {
    // 开发态（`flutter run` / 只 build 了 UI）就是这个分支：必须**说清楚**
    // 找不到核心，而不是静默失败或假装成功退出。文件在但不可执行（例如从
    // 压缩包解出来丢了权限位）也要说清楚，否则用户会以为"文件明明在"。
    g_autofree gchar* exe_dir = resolve_exe_dir();
    g_autofree gchar* expected = exe_dir != nullptr
                                     ? g_build_filename(exe_dir, "core",
                                                        kCoreBinaryName, nullptr)
                                     : g_strdup("<EasyPass directory>");
    const gchar* reason = g_file_test(expected, G_FILE_TEST_EXISTS)
                              ? "It exists but is not executable."
                              : "The file was not found.";
    g_autofree gchar* detail = g_strdup_printf(
        "Expected the core executable at:\n%s\n\n%s The service was not "
        "stopped.",
        expected, reason);
    show_error_dialog("EasyPass core executable not found.", detail);
    return FALSE;
  }

  g_autofree gchar* detail = nullptr;
  if (!run_core_command(core, kShutdownArgument, &detail)) {
    g_autofree gchar* message = g_strdup_printf(
        "%s\n\nThe service may still be running; the UI stays open so you can "
        "retry.",
        detail != nullptr ? detail : "unknown error");
    show_error_dialog("The EasyPass background service did not stop.", message);
    return FALSE;
  }

  return TRUE;
}

// "仅退出 UI"的锁定前置步骤：核心常驻，"仅退出 UI" 之后保险库不能还开着。
// 尽力而为 —— 锁定失败只提示、照样退出（把用户困在界面里比一个未锁的保险库更
// 糟，而且用户还有任务管理器）。核心不存在（开发态）时静默跳过。
void lock_vault_before_exit() {
  g_autofree gchar* core = resolve_core_executable();
  if (core == nullptr) {
    g_message("easypass tray: no core executable found; skipping the vault lock");
    return;
  }

  g_autofree gchar* detail = nullptr;
  if (!run_core_command(core, kLockArgument, &detail)) {
    g_autofree gchar* message = g_strdup_printf(
        "%s\n\nThe vault may still be unlocked.",
        detail != nullptr ? detail : "unknown error");
    show_error_dialog("Could not lock the vault before closing the UI.",
                      message);
    return;
  }

  g_message("easypass tray: vault locked before closing the UI");
}

// 退出 UI 进程本身（不含锁定）：先置 quitting（关窗处理器据此不再藏窗口），再
// 销毁窗口（destroy → g_application_quit），最后还回 runner 在托盘模式下持有的
// g_application_hold，否则主循环不会结束。
static void quit_ui_only() {
  g_quitting = TRUE;
  if (g_window != nullptr) {
    gtk_widget_destroy(GTK_WIDGET(g_window));
  }
  GApplication* app = g_application_get_default();
  if (app != nullptr) {
    g_application_release(app);
    g_application_quit(app);
  }
}

// "仅退出 UI"：先锁保险库，再只结束 UI 进程（核心照常运行，扩展照常可用）。
void on_quit_ui_activate(GtkMenuItem* item, gpointer user_data) {
  lock_vault_before_exit();
  quit_ui_only();
}

void on_quit_service_activate(GtkMenuItem* item, gpointer user_data) {
  // 核心没停成功就**不退出**：让用户能重试，也让提示框有机会被看到。
  // 这里**不**再锁库：核心已经退出，密钥随进程一起没了，再跑 `--lock` 只会
  // 因为没有核心而报错。
  if (stop_core_service()) {
    quit_ui_only();
  }
}

GtkWidget* build_menu() {
  GtkWidget* menu = gtk_menu_new();

  GtkWidget* open_item = gtk_menu_item_new_with_label("Open EasyPass");
  g_signal_connect(open_item, "activate", G_CALLBACK(on_open_activate),
                   nullptr);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), open_item);

  gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

  // 两档退出语义见 docs/core-service-refactor.md §3.8：UI 与核心各自有生命
  // 周期，所以"离开界面"和"连服务一起停"必须是两个明确的选择。文案与 Windows
  // runner 保持一致（英文，托盘不做 l10n）。
  GtkWidget* quit_ui_item = gtk_menu_item_new_with_label("Exit UI Only");
  g_signal_connect(quit_ui_item, "activate", G_CALLBACK(on_quit_ui_activate),
                   nullptr);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), quit_ui_item);

  GtkWidget* quit_service_item =
      gtk_menu_item_new_with_label("Exit UI and Stop Service");
  g_signal_connect(quit_service_item, "activate",
                   G_CALLBACK(on_quit_service_activate), nullptr);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), quit_service_item);

  return menu;
}

}  // namespace

gboolean easypass_tray_install(GtkWindow* window) {
  // 无论托盘是否真的装得上，runner 的窗口都先登记：`easypass_window_show()`
  // 与 `easypass_quit_ui()` 必须对"没有托盘的降级形态"同样有效（那条路径下
  // 关窗即退出，退出时同样要销毁窗口并还回 hold）。托盘**可用性**仍由
  // `easypass_tray_is_active()` 三个条件决定，与这里无关。
  g_window = window;

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

void easypass_quit_ui(void) {
  // 与托盘 "Exit UI Only" 完全同一条路径（含"先锁库"这一步）：CI 的
  // `EASYPASS_DEBUG_AUTO_EXIT_AFTER_MS` 钩子跑的就是用户在菜单里点的东西。
  lock_vault_before_exit();
  quit_ui_only();
}

void easypass_window_show(void) {
  if (g_window == nullptr) {
    return;
  }
  gtk_widget_show(GTK_WIDGET(g_window));
  gtk_window_present(g_window);
}
