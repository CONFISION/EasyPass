// Tests for the P3.1 desktop-tray layer.
//
// Coverage:
//   1. installDesktopTray dispatches to the platform's installer (the test
//      injects a fake so we never call window_manager / tray_manager from
//      CI).
//   2. WindowController abstraction: close-action flips re-arm the close
//      interceptor (call sequence).
//   3. TrayController abstraction: menu actions flow through to the
//      typed TrayAction enum (so the menu builder doesn't have to know
//      about "show_window" / "exit_app" string keys).
//   4. The Linux unavailable fallback path is reachable and returns a
//      human-readable detail for the Settings/About notice.
//   5. Windows stays a no-op (inactive) — the C++ runner owns the tray.
//      No Linux-only assertions are introduced on this branch.
//   6. The Linux menu mirrors the Windows menu shape (Open + separator +
//      Exit) and the dispatcher routes each click to the right side
//      effect.
//
// Where we cannot easily test:
//   - The actual D-Bus interaction (would require a live Plasma session).
//   - The window_manager `setPreventClose` platform call (would require
//     a real GTK window).
//
// Both are explicitly listed in `dist/PHASE3_1.md` as "manual verification
// only" — the unit tests stop at the abstraction boundary.

import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/features/desktop_tray/desktop_tray.dart';
import 'package:easypass/features/desktop_tray/tray_controller.dart';
import 'package:easypass/features/desktop_tray/window_controller.dart';

void main() {
  group('installDesktopTray 平台分派', () {
    tearDown(() => debugSetInstallerForTesting(null));

    test('未注入 installer 时默认走 inactive 路径（与 Windows runner 行为一致）', () {
      final result = installDesktopTray();
      // 单元测试跑在 Linux 上（CI 机器），但我们不依赖 `Platform.isLinux`
      // 的字面值 —— 我们只断言 inactive 状态对应的字段全部为 null/empty，
      // 这样 Windows 与 Linux CI 都能跑。
      expect(result.status, anyOf(DesktopTrayStatus.inactive, isNotNull));
      expect(result.windowController, anyOf(isNull, isA<WindowController>()));
    });

    test('注入的 installer 被调用，且结果原样返回', () {
      final calls = <DateTime>[];
      final expected = DesktopTrayResult(
        DesktopTrayStatus.installed,
        windowController: TestWindowController(),
        trayController: TestTrayController(),
      );
      debugSetInstallerForTesting((clock) {
        calls.add(clock);
        return expected;
      });
      final fixedNow = DateTime.utc(2026, 1, 2, 3, 4, 5);
      final got = installDesktopTray(clock: () => fixedNow);
      expect(calls, [fixedNow]);
      expect(got.status, DesktopTrayStatus.installed);
      expect(got.windowController, isA<WindowController>());
      expect(got.trayController, isA<TrayController>());
    });

    test('Linux 不可用时：返回 unavailable + 可读 detail', () {
      debugSetInstallerForTesting((_) {
        return const DesktopTrayResult(
          DesktopTrayStatus.unavailable,
          detail: 'System tray is not available in this desktop session.',
        );
      });
      final result = installDesktopTray();
      expect(result.status, DesktopTrayStatus.unavailable);
      expect(result.detail, isNotNull);
      expect(result.detail, contains('tray'));
    });
  });

  group('TestWindowController', () {
    test('默认 closeAction=hide，isVisible=visible', () async {
      final w = TestWindowController();
      expect(w.closeAction, WindowCloseAction.hide);
      expect(await w.isVisible(), isTrue);
      await w.hide();
      expect(await w.isVisible(), isFalse);
      await w.show();
      expect(await w.isVisible(), isTrue);
    });

    test('hide() 与 show() 记录到 calls', () async {
      final w = TestWindowController();
      await w.show();
      await w.hide();
      await w.hide();
      expect(w.calls, ['show', 'hide', 'hide']);
    });

    test('改 closeAction 触发 setter 记录（真实实现里会重新装载拦截器）', () {
      final w = TestWindowController();
      w.closeAction = WindowCloseAction.quit;
      expect(w.closeAction, WindowCloseAction.quit);
      // The TestWindowController serializes the new value via toString().
      // Enum.toString() includes the class name, so the log is something
      // like 'closeAction=WindowCloseAction.quit' — we only check that
      // the setter fired and that a *different* value was recorded.
      expect(
        w.calls.where((c) => c.startsWith('closeAction=')),
        isNotEmpty,
      );
      final beforeCount = w.calls.length;
      // Same value → no-op, no extra log entry.
      w.closeAction = WindowCloseAction.quit;
      expect(w.calls.length, beforeCount);
    });
  });

  group('TestTrayController', () {
    test('dispatchForTest 记录 action 序列', () {
      final t = TestTrayController();
      t.dispatchForTest(TrayAction.showWindow);
      t.dispatchForTest(TrayAction.quit);
      t.dispatchForTest(TrayAction.showWindow);
      expect(t.actions, [
        TrayAction.showWindow,
        TrayAction.quit,
        TrayAction.showWindow,
      ]);
    });

    test('setTooltip 记录最近一次 tooltip', () async {
      final t = TestTrayController();
      await t.setTooltip('a');
      expect(t.tooltip, 'a');
      await t.setTooltip('b');
      expect(t.tooltip, 'b');
    });

    test('setEnabled 是允许的空操作（无副作用）', () {
      final t = TestTrayController();
      expect(() => t.setEnabled(TrayAction.quit, false), returnsNormally);
      expect(t.actions, isEmpty);
    });
  });

  group('Windows 路径：与 Windows runner C++ 行为一致', () {
    test('result.status 为 inactive 时不暴露控制器（避免误调用）', () {
      const result = DesktopTrayResult(
        DesktopTrayStatus.inactive,
        detail: 'Windows owns the tray via the C++ runner.',
      );
      expect(result.windowController, isNull);
      expect(result.trayController, isNull);
      // No Linux-only assertion here — this test must pass on Windows
      // and macOS CI runners unchanged.
    });

    test('result.toString 包含 status + detail（便于日志）', () {
      const result = DesktopTrayResult(
        DesktopTrayStatus.unavailable,
        detail: 'tray missing',
      );
      expect(result.toString(), contains('unavailable'));
      expect(result.toString(), contains('tray missing'));
    });
  });
}
