import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../protocol/events.dart';
import '../vault/providers/core_stream.dart';
import 'health_service.dart';

/// 密码健康报告 provider。
///
/// **报告由核心计算**（`VaultApi.healthReport()` → 核心的
/// `CoreActions._getHealthReport`，用的是同一套 `HealthService.analyze`）。
/// UI 只接收统计数字（条数 / 分数 / 各项问题条目的 id 与名字）——
/// 3.0.0 起**明文密码与 TOTP 种子不再经过 IPC**，比"把登录条目取回本地算"
/// 少暴露一条链路。模型仍是 [HealthReport]，整页 UI 不受影响。
///
/// **流式**：核心推 `Topics.items`（任何写入后都会推）→ 重取报告；
/// 未解锁时核心抛 `locked`，这里回 [HealthReport.empty]（0 条 / 满分，
/// 与"没有可分析的登录条目"一致），不冒泡成红屏。
final healthReportProvider = StreamProvider.autoDispose<HealthReport>((ref) {
  return coreSnapshotStream(
    ref,
    topic: Topics.items,
    lockedValue: null,
    fetch: fetchHealthReport,
  ).map((report) => report == null ? HealthReport.empty : HealthReport.fromJson(report));
});
