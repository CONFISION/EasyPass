import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/vault_item.dart';
import '../../../protocol/events.dart';
import 'core_stream.dart';

/// 单个条目（表单 / 详情页共用）—— **流式**，任何写操作后自动刷新。
///
/// 为什么必须是 StreamProvider（2.3.1 的 bug 修复）：
/// 详情页原先读一次性 `FutureProvider.family`，provider 会把结果缓存住；
/// 而"编辑条目保存 → 弹回详情页"这条路径上没有人去 `ref.invalidate`，
/// 于是详情页一直显示旧条目 —— 用户新增的自定义字段死活不出现。
/// 现在核心在写库后推 `Topics.item`，这条流立刻重取快照，"忘记失效"这类 bug
/// 从根上消失。
///
/// 契约不变：未解锁或条目不存在时给 `null`；`.future` 依旧可用。
/// 未解锁（核心抛 `locked`）由 [coreSnapshotStream] 降级成 `null` + 轮询等解锁。
final entryItemProvider =
    StreamProvider.autoDispose.family<VaultItem?, String>((ref, id) {
  return coreSnapshotStream(
    ref,
    topic: Topics.item,
    lockedValue: null,
    fetch: (api) => fetchItem(api, id),
  );
});
