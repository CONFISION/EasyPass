/// EasyPass 协议层（v4）：核心服务与所有客户端共用的线格式定义。
///
/// 这里**不得** import 任何 Flutter 库 —— 核心服务是无 Flutter 的 AOT
/// 可执行文件（`dart build cli`，入口 `bin/easypass_core.dart`）。
library;

export 'actions.dart';
export 'codecs.dart';
export 'entry_type_wire.dart';
export 'errors.dart';
export 'events.dart';
export 'frames.dart';
export 'secure_channel.dart';
export 'version.dart';
