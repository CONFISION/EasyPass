// 单实例 raise 监听宿主。
//
// 职责：
//   - 当 [singleInstanceBackendProvider] 非空（说明当前进程是主实例），在
//     UI 第一次 build 完成后调一次 `backend.startRaising(handler)`。
//   - 收到 raise → 调 `LinuxWindowController.show()`（托盘层已提供）。
//   - 在 dispose 时调 `backend.stopRaising()`，避免 IPC 监听漏掉 fd。
//
// 设计点：
//   - 用 `ConsumerStatefulWidget` 而非在 `main.dart` 调，是因为主进程下
//     [desktopTrayResultProvider]（由托盘层注入）也要 `ref.read` 才能拿到
//     `WindowController`。`runApp` 之后 ProviderScope 已就绪，比 `main()`
//     里同步调用更稳。
//   - handler 用 fire-and-forget：handler 抛异常不能让 raise 监听崩。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import 'raise_target_provider.dart';

class SingleInstanceRaiseHost extends ConsumerStatefulWidget {
  const SingleInstanceRaiseHost({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<SingleInstanceRaiseHost> createState() =>
      _SingleInstanceRaiseHostState();
}

class _SingleInstanceRaiseHostState
    extends ConsumerState<SingleInstanceRaiseHost> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    // Defer to post-frame so the first build of the router is not blocked on
    // the platform IPC bind.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStartRaising());
  }

  Future<void> _maybeStartRaising() async {
    if (_started) return;
    _started = true;
    final backend = ref.read(singleInstanceBackendProvider);
    if (backend == null) return;
    try {
      await backend.startRaising(_onRaiseReceived);
    } on Object catch (_) {
      // raise channel bind failure must not crash the UI; the lock is still
      // held, so subsequent secondary launches will time out trying to
      // connect, but the app keeps running.
    }
  }

  Future<void> _onRaiseReceived() async {
    // 二次启动触发：把窗口 show 出来 + focus。Linux 上没有原生"置顶"语义，
    // 但 `WindowManager.show()` 足以让最小化/隐藏的窗口重新出现。
    final w = ref.read(raiseWindowControllerProvider);
    if (w == null) return;
    try {
      await w.show();
    } on Object catch (_) {
      // 平台调用失败 = 异常环境（X server 挂了等），静默吞掉；UI 不崩。
    }
  }

  @override
  void dispose() {
    final backend = ref.read(singleInstanceBackendProvider);
    if (backend != null) {
      // fire-and-forget; dispose() itself is sync.
      // ignore: unawaited_futures
      backend.stopRaising();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}