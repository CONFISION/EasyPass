import '../core/constants/app_constants.dart';

/// 协议版本：**单一来源**是 [AppConstants.bridgeProtocolVersion]
/// （`background.js` 的 `EXPECTED_PROTOCOL_VERSION` 与
/// `browser_extension/tools/check_extension.mjs` 的校验都与它同步）。
///
/// 这里只是给协议层一个不依赖"常量类在哪"的稳定名字。
const int coreProtocolVersion = AppConstants.bridgeProtocolVersion;

/// 能力标记：客户端据此判断核心是否支持事件推送等 v4 特性。
class CoreCapabilities {
  CoreCapabilities._();

  /// 服务端推送变更事件（`changed` / `sessionLocked` / …）。
  static const String events = 'events';

  /// 多条目类型（协议 3 起）。
  static const String multiType = 'multiType';

  /// UI 域动作面（`listItems` / `saveItem` / `exportVault` / …）。
  static const String uiActions = 'uiActions';

  /// 核心停机通道（`shutdownCore`）。
  static const String shutdown = 'shutdown';

  static const List<String> all = [events, multiType, uiActions, shutdown];
}
