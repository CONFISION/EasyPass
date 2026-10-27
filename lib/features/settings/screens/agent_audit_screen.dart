import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../providers/agent_access_provider.dart';

/// 智能体访问审计查看页（侧边栏「智能体活动」，回收站上方）。
///
/// 为什么要有它：方式 2（可信直通）对用户的承诺是"每次访问都留日志"。
/// 日志只落在库里、没有界面的话，这个承诺对用户等于不存在。
///
/// 数据是**实时**的：核心每写一条审计都会广播 `Topics.agentAudit`，
/// 这里订阅后自动重取 —— 智能体在后台操作时不用手动刷新。
///
/// 展示纪律：**只显示库里存的东西**（昵称/工具/操作/条目/结果），
/// 不显示密钥、不显示明文 —— 表里本来就没有这些，界面也不该"顺便"拼出来。
class AgentAuditScreen extends ConsumerWidget {
  const AgentAuditScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final auditAsync = ref.watch(agentAuditEntriesProvider);
    final entries =
        auditAsync.valueOrNull ?? const <Map<String, dynamic>>[];

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.agentAuditTitle),
        actions: [
          IconButton(
            tooltip: l10n.agentAuditRefresh,
            onPressed: () => ref.invalidate(agentAuditEntriesProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: auditAsync.when(
        // 刷新期间继续显示上一份数据，不闪加载圈。
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              l10n.agentActionFailed('$error'),
              style: TextStyle(color: scheme.error),
            ),
          ),
        ),
        data: (entries) => entries.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.history, size: 40, color: scheme.outline),
                    const SizedBox(height: 12),
                    Text(l10n.agentAuditEmpty,
                        style: theme.textTheme.bodyMedium),
                  ],
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: entries.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) =>
                    _buildCard(entries[index], l10n, theme),
              ),
      ),
      bottomNavigationBar: entries.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                l10n.agentAuditCount('${entries.length}'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ),
    );
  }

  Widget _buildCard(
    Map<String, dynamic> entry,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    final scheme = theme.colorScheme;
    final decision = entry['decision'] as String? ?? '';
    final allowed = decision == 'allowed' || decision == 'allowed_standing';
    final at = (entry['at'] as num?)?.toInt() ?? 0;
    final time = DateTime.fromMillisecondsSinceEpoch(at);
    final entryName = entry['entryName'] as String?;
    final op = entry['op'] as String? ?? '';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  allowed ? Icons.check_circle_outline : Icons.block,
                  size: 18,
                  color: allowed ? scheme.tertiary : scheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${entry['nickname'] ?? ''} · ${_opLabel(l10n, op)}',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  _formatTime(time),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              [
                entry['tool'],
                ?entryName,
                _decisionLabel(l10n, decision),
              ].join(' · '),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  String _opLabel(AppLocalizations l10n, String op) {
    switch (op) {
      case 'write':
        return l10n.agentApprovalOpWrite;
      case 'delete':
        return l10n.agentApprovalOpDelete;
      case 'sensitiveRead':
        return l10n.agentApprovalOpSensitiveRead;
      case 'clipboard':
        return l10n.agentAuditOpClipboard;
      default:
        return l10n.agentApprovalOpRead;
    }
  }

  String _decisionLabel(AppLocalizations l10n, String decision) {
    switch (decision) {
      case 'allowed':
        return l10n.agentAuditDecisionAllowed;
      case 'allowed_standing':
        // 靠「本会话内允许读取」放行：必须与"这次点了同意"区分开，
        // 否则审计看不出用户有没有被免询问绕过（3.1.0 补的 decision）。
        return l10n.agentAuditDecisionAllowedStanding;
      case 'timeout':
        return l10n.agentAuditDecisionTimeout;
      case 'error':
        return l10n.agentAuditDecisionError;
      default:
        return l10n.agentAuditDecisionDenied;
    }
  }
}
