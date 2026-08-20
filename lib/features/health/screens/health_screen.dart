import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../health_provider.dart';
import '../health_service.dart';

/// 密码健康报告页面。
///
/// 顶部显示总分与健康等级（良好/一般/危险，颜色区分），下方按问题分类
/// 列出条目（名称 + 问题原因），点击条目跳转到对应详情页。
class HealthScreen extends ConsumerWidget {
  const HealthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reportAsync = ref.watch(healthReportProvider);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.healthReport)),
      body: reportAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.health_and_safety_outlined,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  l10n.healthLoadFailed(error.toString()),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => ref.invalidate(healthReportProvider),
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
        data: (report) => RefreshIndicator(
          onRefresh: () => ref.refresh(healthReportProvider.future),
          child: _buildReport(context, report),
        ),
      ),
    );
  }

  Widget _buildReport(BuildContext context, HealthReport report) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final levelColor = _levelColor(report.level);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ─── 总分卡片 ─────────────────────────────────────
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text(
                  l10n.healthScore,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: 140,
                  height: 140,
                  child: Stack(
                    fit: StackFit.expand,
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: report.score / 100,
                        strokeWidth: 12,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                        color: levelColor,
                      ),
                      Center(
                        child: Text(
                          '${report.score}',
                          style: theme.textTheme.displayMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: levelColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _levelLabel(l10n, report.level),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: levelColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${report.totalEntries} ${l10n.healthTotalEntries}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),

        // ─── 全绿提示 ────────────────────────────────────
        if (report.isHealthy && report.totalEntries > 0) ...[
          Card(
            color: Colors.green.withAlpha(24),
            child: ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: Text(l10n.healthAllHealthy),
            ),
          ),
          const SizedBox(height: 8),
        ],

        // ─── 弱密码 ──────────────────────────────────────
        if (report.weakPasswords.isNotEmpty)
          _buildSection(
            context,
            icon: Icons.warning_amber,
            title: l10n.healthWeakPasswords,
            count: report.weakPasswordCount,
            items: [
              for (final issue in report.weakPasswords)
                _IssueTile(
                  entryId: issue.entryId,
                  entryName: issue.entryName,
                  icon: Icons.warning_amber,
                  subtitle: _weakReasonLabel(l10n, issue.reason),
                ),
            ],
          ),

        // ─── 重复密码 ────────────────────────────────────
        if (report.reusedPasswords.isNotEmpty)
          _buildSection(
            context,
            icon: Icons.content_copy,
            title: l10n.healthReusedPasswords,
            count: report.reusedEntryCount,
            items: [
              for (final issue in report.reusedPasswords)
                _IssueTile(
                  entryId: issue.entryId,
                  entryName: issue.entryName,
                  icon: Icons.content_copy,
                  subtitle: l10n.healthReusedShared(issue.sharedCount),
                ),
            ],
          ),

        // ─── 无两步验证 ──────────────────────────────────
        if (report.noTotpEntries.isNotEmpty)
          _buildSection(
            context,
            icon: Icons.mobile_friendly,
            title: l10n.healthNoTotp,
            count: report.noTotpCount,
            items: [
              for (final issue in report.noTotpEntries)
                _IssueTile(
                  entryId: issue.entryId,
                  entryName: issue.entryName,
                  icon: Icons.mobile_friendly,
                  subtitle: l10n.healthNoTotpReason,
                ),
            ],
          ),

        // ─── 无网址 ──────────────────────────────────────
        if (report.noUrlEntries.isNotEmpty)
          _buildSection(
            context,
            icon: Icons.link_off,
            title: l10n.healthNoUrl,
            count: report.noUrlCount,
            items: [
              for (final issue in report.noUrlEntries)
                _IssueTile(
                  entryId: issue.entryId,
                  entryName: issue.entryName,
                  icon: Icons.link_off,
                  subtitle: l10n.healthNoUrlReason,
                ),
            ],
          ),

        const SizedBox(height: 8),
        Center(
          child: Text(
            l10n.healthTapToView,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required IconData icon,
    required String title,
    required int count,
    required List<Widget> items,
  }) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$count',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          ...items,
          const Divider(height: 1),
        ],
      ),
    );
  }

  Color _levelColor(HealthLevel level) {
    switch (level) {
      case HealthLevel.good:
        return Colors.green;
      case HealthLevel.fair:
        return Colors.orange;
      case HealthLevel.poor:
        return Colors.red;
    }
  }

  String _levelLabel(AppLocalizations l10n, HealthLevel level) {
    switch (level) {
      case HealthLevel.good:
        return l10n.healthGood;
      case HealthLevel.fair:
        return l10n.healthFair;
      case HealthLevel.poor:
        return l10n.healthPoor;
    }
  }

  String _weakReasonLabel(AppLocalizations l10n, WeakPasswordReason reason) {
    switch (reason) {
      case WeakPasswordReason.tooShort:
        return l10n.healthWeakTooShort;
      case WeakPasswordReason.singleCharType:
        return l10n.healthWeakSingleType;
      case WeakPasswordReason.commonPassword:
        return l10n.healthWeakCommonPassword;
    }
  }
}

class _IssueTile extends StatelessWidget {
  final String entryId;
  final String entryName;
  final IconData icon;
  final String subtitle;

  const _IssueTile({
    required this.entryId,
    required this.entryName,
    required this.icon,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
      title: Text(entryName),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/vault/entry/$entryId'),
    );
  }
}
