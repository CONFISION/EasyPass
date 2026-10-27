import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../client/api_providers.dart';
import '../../../l10n/app_localizations.dart';

/// 方式 1（逐次审批）的审批弹窗宿主。
///
/// 挂在 `MaterialApp.builder` 上，任何页面都会弹出来 —— 因为审批是"智能体在等
/// 你回话"，用户此刻可能停在生成器或设置页，不能要求他必须打开某个页面。
///
/// 设计纪律（都是踩过的坑）：
/// - **完整展示**参数：操作类型（读/写/删）、来自哪个智能体、哪个条目。
///   截断/摘要式对话框等于没做（已有实例证明藏起参数的弹窗照样被利用）；
/// - 只有"同意 / 拒绝"，外加「本会话内允许读取」——**只在普通读时出现**；
/// - 关闭对话框 = 拒绝（不提供"稍后再说"这种模糊态）；
/// - 同一时刻只弹一个，避免叠加。
class AgentApprovalHost extends ConsumerStatefulWidget {
  const AgentApprovalHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AgentApprovalHost> createState() => _AgentApprovalHostState();
}

class _AgentApprovalHostState extends ConsumerState<AgentApprovalHost> {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    _subscription = ref
        .read(vaultApiProvider)
        .agentApprovalRequests
        .listen(_onRequest);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<void> _onRequest(Map<String, dynamic> request) async {
    if (_showing || !mounted) return;
    _showing = true;
    final api = ref.read(vaultApiProvider);
    final approvalId = request['approvalId'] as String? ?? '';
    final allowStandingOption = request['allowStanding'] == true;

    var allow = false;
    var allowStanding = false;
    try {
      final choice = await showDialog<_ApprovalChoice>(
        context: context,
        barrierDismissible: false, // 关掉对话框算拒绝，但别让它被误触关掉
        builder: (dialogContext) => _ApprovalDialog(
          request: request,
          allowStandingOption: allowStandingOption,
        ),
      );
      allow = choice != null && choice.allow;
      allowStanding = choice?.standing ?? false;
    } catch (_) {
      allow = false;
    } finally {
      _showing = false;
    }

    // 无论同意与否都要回话，否则核心那条调用会一直挂到超时。
    try {
      await api.respondAgentApproval(
        approvalId: approvalId,
        allow: allow,
        allowStandingRead: allowStanding,
      );
    } catch (_) {
      // 回话失败：核心会按超时拒绝，不需要 UI 再做什么。
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ApprovalChoice {
  const _ApprovalChoice({required this.allow, this.standing = false});

  final bool allow;
  final bool standing;
}

class _ApprovalDialog extends StatelessWidget {
  const _ApprovalDialog({
    required this.request,
    required this.allowStandingOption,
  });

  final Map<String, dynamic> request;
  final bool allowStandingOption;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final nickname = request['nickname'] as String? ?? '';
    final tool = request['tool'] as String? ?? '';
    final op = request['op'] as String? ?? 'read';
    final entryName = request['entryName'] as String?;
    final isRead = op == 'read';

    return AlertDialog(
      icon: Icon(Icons.smart_toy_outlined, color: scheme.tertiary),
      title: Text(l10n.agentApprovalTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(l10n.agentApprovalAgent, nickname, theme),
          const SizedBox(height: 8),
          _row(l10n.agentApprovalOperation, _opLabel(l10n, op), theme,
              emphasize: true),
          if (entryName != null) ...[
            const SizedBox(height: 8),
            _row(l10n.agentApprovalEntry, entryName, theme, emphasize: true),
          ],
          const SizedBox(height: 8),
          _row(l10n.agentApprovalTool, tool, theme),
          const SizedBox(height: 12),
          Text(
            l10n.agentApprovalHint,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, const _ApprovalChoice(allow: false)),
          child: Text(l10n.agentApprovalDeny),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (allowStandingOption && isRead)
              TextButton(
                onPressed: () => Navigator.pop(
                  context,
                  const _ApprovalChoice(allow: true, standing: true),
                ),
                child: Text(l10n.agentApprovalAllowStanding),
              ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, const _ApprovalChoice(allow: true)),
              child: Text(l10n.agentApprovalAllow),
            ),
          ],
        ),
      ],
    );
  }

  Widget _row(
    String label,
    String value,
    ThemeData theme, {
    bool emphasize = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: emphasize
                ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)
                : theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }

  String _opLabel(AppLocalizations l10n, String op) {
    switch (op) {
      case 'write':
        return l10n.agentApprovalOpWrite;
      case 'delete':
        return l10n.agentApprovalOpDelete;
      case 'sensitiveRead':
        return l10n.agentApprovalOpSensitiveRead;
      default:
        return l10n.agentApprovalOpRead;
    }
  }
}
