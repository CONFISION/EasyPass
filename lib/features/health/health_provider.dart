import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/entry_type.dart';
import '../../data/models/vault_item.dart';
import '../../protocol/events.dart';
import '../vault/providers/core_stream.dart';
import 'health_service.dart';

/// 密码健康报告 provider。
///
/// 装配流程：经 [VaultApi.listItems]（`type: EntryType.login`）取**登录条目**
/// —— 安全笔记 / 身份 / SSH 密钥不参与评分 —— 再交给纯函数
/// [HealthService.analyze] 计算 [HealthReport]。密码/种子从核心取回后只存在于
/// 内存，报告本身不含任何明文密码。
///
/// **流式**：核心推 `Topics.items`（任何写入后都会推）→ 重取 + 重算；
/// 未解锁时核心抛 `locked`，这里当成"空列表"（分数 100 / 0 条，与界面上的
/// "没有可分析的登录条目"一致），不冒泡成红屏。
///
/// 备选口径：核心也提供 `healthReport()`（同一套 `HealthService.analyze`，
/// 在核心内算完只回统计数字，密码不必过线）。本轮仍走 `listItems` 是为了
/// 保住 [HealthReport] 这个既有模型与整页 UI 不动；要不要切到 `healthReport()`
/// 由 lead 决定（见 M4 报告）。
final healthReportProvider = StreamProvider.autoDispose<HealthReport>((ref) {
  return coreSnapshotStream(
    ref,
    topic: Topics.items,
    lockedValue: const <VaultItem>[],
    fetch: (api) => fetchItems(api, type: EntryType.login),
  ).map(
    (items) => HealthService.analyze([
      for (final item in items) HealthEntry.fromItem(item),
    ]),
  );
});
