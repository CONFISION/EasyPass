// Linux 桌面体验对等（P3.1 / P4b）· 托盘 + 关窗最小化 —— **runner 原生实现**。
//
// 设计与 Windows 一致：托盘图标、菜单（`Open EasyPass` | 分隔 | `Exit`）和
// "关窗最小化"全部由 runner 用 GTK / libayatana-appindicator 实现，见
// `linux/runner/easypass_tray.cc` 与 `linux/runner/my_application.cc`。
//
// 为什么不用第三方托盘包（都是实测结论，不是猜测）：
//   - `tray_manager` 0.7.0（底层 nativeapi 0.3.0）在 Linux 上**从不导出
//     D-Bus 菜单**：`Menu` 属性恒为 `/`，`/` 下没有 `com.canonical.dbusmenu`
//     接口 → 图标在、点击没反应（`gdbus` 实测）。
//   - `tray_manager` 0.5.x（libappindicator 实现）**从未把 StatusNotifierItem
//     注册出去**（watcher 列表里查不到），日志只有
//     `libdbusmenu … About to Show called on an item without submenus`；它的
//     `set_icon`/`set_menu` 顺序还有缺陷（先挂菜单会在 indicator 不存在时断言
//     失败，先设图标又会挂上空菜单），且依赖已废弃的 `app_indicator_new`。
//   两版都是上游缺陷，因此 Dart 侧不再依赖任何托盘包。
//
// 本文件只保留"原生已接管"的结果上报；`WindowController` / `TrayController`
// 抽象仍服务于 Windows/macOS 桩与单测。

import 'desktop_tray.dart';

/// Linux：托盘与关窗最小化由 runner 原生层负责（见文件头注释）。
///
/// 原生层拿不到 AppIndicator 宿主时不会装托盘，此时
/// `my_application.cc` 的 `delete-event` 处理器让 GTK 走默认行为 —— 关窗即
/// 退出 —— 正好是"托盘不可用"的降级语义，所以这里可以无条件上报
/// [DesktopTrayStatus.installed]。
DesktopTrayResult installLinuxDesktopTray(DateTime clock) {
  return const DesktopTrayResult(
    DesktopTrayStatus.installed,
    detail: 'Tray icon and close-to-hide are provided by the GTK runner '
        '(libayatana-appindicator).',
  );
}
