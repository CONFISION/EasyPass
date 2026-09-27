// Linux [WindowController]，只桥一个原生方法：`show`。
//
// 为什么只有 `show`：窗口归 GTK runner 所有 —— "关窗最小化"（`delete-event`
// 在 `linux/runner/my_application.cc`）与托盘菜单的 "Open EasyPass"
// （→ `easypass_window_show()`，`linux/runner/easypass_tray.cc`）都在 C++ 侧
// 实现。Dart 唯一必须自己发起的事情是**把窗口叫回来**：二次启动时
// `single_instance_raise_host.dart` 收到 raise 字节，读
// `raiseWindowControllerProvider` 调 `show()`。在此之前那条路是死的
// （provider 默认 null），于是"二次启动唤起已有窗口"只实现了一半：
// 第二个副本确实不启动了，但窗口也不会回来。
//
// 与 Windows 的分工一致（那边由 `windows/runner/flutter_window.cpp` 全权
// 负责窗口），Dart 侧不引入任何第三方窗口包。

import 'package:flutter/services.dart';

import 'window_controller.dart';

/// 必须与 `linux/runner/my_application.cc` 里 `window_channel_register()`
/// 注册的通道名一致。
const String kLinuxWindowChannelName = 'com.easypass.app/window';

/// Linux 上真实的窗口控制器（唯一实现）。
class LinuxWindowController implements WindowController {
  LinuxWindowController({
    this.channel = const MethodChannel(kLinuxWindowChannelName),
  });

  /// 与 runner 约定的通道。测试注入替身，生产用默认值。
  final MethodChannel channel;

  WindowCloseAction _closeAction = WindowCloseAction.hide;
  bool _visible = true;

  /// **runner 自己决定**关窗行为：`easypass_tray_is_active()` 为真（有
  /// StatusNotifier 宿主）才隐藏窗口，否则让 GTK 走默认行为把窗口销毁并退出
  /// —— 见 `linux/runner/easypass_tray.cc`。Dart 侧的 setter 无法影响它，
  /// 这里只记录调用方设过的值。
  @override
  WindowCloseAction get closeAction => _closeAction;

  @override
  set closeAction(WindowCloseAction action) => _closeAction = action;

  /// 把窗口显示出来并置顶（原生 `easypass_window_show()`：
  /// `gtk_widget_show` + `gtk_window_present`）。
  @override
  Future<void> show() async {
    try {
      await channel.invokeMethod<void>('show');
      _visible = true;
    } on MissingPluginException {
      // 通道不在（旧 runner / 非 Linux 宿主，例如单测环境）：降级为
      // "二次启动不唤起窗口"，托盘菜单里的 "Open EasyPass" 仍然可用。
    } on PlatformException {
      // 通道在但调用失败（极端环境）。没有可执行的补救动作，不冒泡 ——
      // raise 处理链是 fire-and-forget，抛出去只会变成未捕获异常。
    }
  }

  /// runner 尚未暴露原生 `hide`。
  ///
  /// 这里**故意抛错**而不是静默 no-op：隐藏窗口是用户可见动作，一个"点了没
  /// 反应"的实现比报错更难查（AGENTS.md：不要在桌面上留下静默失败的按钮）。
  /// 真要做隐藏（例如给托盘菜单加 "Hide EasyPass"），请先在
  /// `linux/runner/my_application.cc` 的通道里加 `hide` 分支再实现这里。
  ///
  /// `async` 是刻意的：错误通过返回的 Future 传递（调用方 `await` 时抛出），
  /// 而不是在调用点同步抛出 —— 后者会绕过 `await`/`catchError` 的常规处理。
  @override
  Future<void> hide() async {
    throw UnsupportedError(
      'LinuxWindowController.hide() 未实现：窗口归 GTK runner 所有，'
      '关窗隐藏由 runner 的 delete-event 处理。',
    );
  }

  /// 只反映 Dart 侧调用过的结果；真正的可见性由 runner 拥有（用户在 WM 上
  /// 关窗时 Dart 收不到通知）。当前没有调用方 —— 托盘菜单的标签在 C++ 侧。
  @override
  Future<bool> isVisible() async => _visible;

  /// 通道是进程级单例，没有监听器需要拆。
  @override
  Future<void> dispose() async {}
}
