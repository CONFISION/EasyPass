import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../protocol/events.dart';
import '../../vault/providers/core_stream.dart';

/// 智能体访问总开关是否开启。
///
/// 用途：侧边栏「智能体活动」入口**只在开启时出现**。核心在
/// 打开/关闭/重置/改密重包裹时会广播 `Topics.agentAccess`，这里跟着重取，
/// 不需要 UI 手动 invalidate。
final agentAccessEnabledProvider = StreamProvider.autoDispose<bool>((ref) {
  return coreSnapshotStream(
    ref,
    topic: Topics.agentAccess,
    lockedValue: false,
    fetch: fetchAgentAccessEnabled,
  );
});

/// 最近的智能体审计记录（新的在前）。
///
/// 每次写入审计核心都会广播 `Topics.agentAudit`，所以这个页面是**实时**的：
/// 智能体在后台读/写/被拒绝时，用户在这里能直接看到新记录冒出来。
final agentAuditEntriesProvider =
    StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return coreSnapshotStream(
    ref,
    topic: Topics.agentAudit,
    lockedValue: const <Map<String, dynamic>>[],
    fetch: fetchAgentAudit,
  );
});
