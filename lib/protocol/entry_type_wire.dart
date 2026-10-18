import 'package:easypass/data/models/entry_type.dart';

/// `EntryType` 在协议层的一层**别名**，让 `codecs.dart` 不必直接依赖数据层
/// 的模型文件路径（将来拆包时只改这一处）。
typedef WireEntryType = EntryType;
