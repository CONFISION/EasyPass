// LinuxWindowController：Dart ↔ runner 之间唯一的窗口通道（只有 `show`）。
//
// 覆盖：
//   1. 通道名与 `linux/runner/my_application.cc` 注册的一致 —— 写死断言，
//      改名必须两边同时改。
//   2. `show()` 真的把 `show` 发出去（二次启动唤起窗口的最后一跳）。
//   3. 通道不存在（非 Linux 宿主 / 旧 runner）→ 静默降级，不把 raise 链拖崩。
//   4. `hide()` 未实现 → 抛 UnsupportedError，**不**静默 no-op。
//   5. `closeAction` 只做记录（真正的判定在 runner 的
//      `easypass_tray_is_active()`）。
//
// 真机验证（需要 Linux 桌面会话，见交付说明）：`my_application.cc` 的
// `window_channel_register()` 与 `easypass_window_show()` 是否接通 ——
// 单测只能停在 MethodChannel 边界。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/features/desktop_tray/linux_window_controller.dart';
import 'package:easypass/features/desktop_tray/window_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'test/easypass_window';
  late MethodChannel channel;
  late List<MethodCall> calls;

  setUp(() {
    channel = const MethodChannel(channelName);
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('通道名与 runner 注册的一致', () {
    // 必须与 linux/runner/my_application.cc 里
    // `fl_method_channel_new(..., "com.easypass.app/window", ...)` 相同。
    expect(kLinuxWindowChannelName, 'com.easypass.app/window');
  });

  test('show() 走原生通道，并把窗口标记为可见', () async {
    final controller = LinuxWindowController(channel: channel);
    await controller.show();

    expect(calls.map((c) => c.method), ['show']);
    expect(await controller.isVisible(), isTrue);
  });

  test('通道不存在（非 Linux 宿主 / 旧 runner）→ 静默降级', () async {
    final controller = LinuxWindowController(
      channel: const MethodChannel('test/easypass_window_absent'),
    );
    // 没有注册 handler → invokeMethod 抛 MissingPluginException，必须被吞掉：
    // raise 处理链是 fire-and-forget，抛出去会变成未捕获异常。
    await expectLater(controller.show(), completes);
  });

  test('hide() 未实现 → 抛 UnsupportedError，不静默吞掉', () async {
    final controller = LinuxWindowController(channel: channel);
    await expectLater(controller.hide(), throwsA(isA<UnsupportedError>()));
    // 抛错前不该已经往原生发了任何东西。
    expect(calls, isEmpty);
  });

  test('closeAction 可读回（真正的判定在 runner）', () async {
    final controller = LinuxWindowController(channel: channel);
    expect(controller.closeAction, WindowCloseAction.hide);

    controller.closeAction = WindowCloseAction.quit;
    expect(controller.closeAction, WindowCloseAction.quit);
    // 记录而已，不该产生任何原生调用。
    expect(calls, isEmpty);
  });

  test('dispose() 幂等且不碰通道', () async {
    final controller = LinuxWindowController(channel: channel);
    await controller.dispose();
    await controller.dispose();
    expect(calls, isEmpty);
  });
}
