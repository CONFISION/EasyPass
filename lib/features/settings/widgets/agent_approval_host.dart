import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../client/api_providers.dart';
import '../../../l10n/app_localizations.dart';

/// 方式 1（逐次审批）的审批界面宿主。
///
/// 挂在 `MaterialApp.builder` 上，任何页面都会显示 —— 审批是"智能体在等你回话"，
/// 用户此刻可能停在生成器或设置页。
///
/// **为什么不用 `showDialog`**（真机踩过）：`builder` 的 context 位于 Navigator
/// **之上**，`showDialog` 找不到 Navigator 会抛异常，兜底逻辑就立刻回一个"拒绝"
/// —— 表现是调用 0.1 秒返回 denied、弹窗根本不出现。这里改成**自绘浮层**
/// （Stack + 遮罩 + AlertDialog 组件本身），完全不依赖 Navigator。
///
/// 其余纪律：
/// - 完整展示：来自哪个智能体、什么操作、哪个条目、哪个工具；
/// - 只有「同意 / 拒绝」，外加「本会话内允许读取」（只在普通读时出现）；
/// - 关掉 = 拒绝；同一时刻只显示一个，其余排队。
class AgentApprovalHost extends ConsumerStatefulWidget {
  const AgentApprovalHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AgentApprovalHost> createState() => _AgentApprovalHostState();
}

class _AgentApprovalHostState extends ConsumerState<AgentApprovalHost> {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  final List<Map<String, dynamic>> _queue = [];
  Map<String, dynamic>? _current;

  @override
  void initState() {
    super.initState();
    _subscription = ref
        .read(vaultApiProvider)
        .agentApprovalRequests
        .listen(_enqueue);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _enqueue(Map<String, dynamic> request) {
    if (!mounted) return;
    setState(() {
      _queue.add(request);
      _current ??= _queue.removeAt(0);
    });
  }

  Future<void> _decide({required bool allow, bool standing = false}) async {
    final request = _current;
    if (request == null) return;
    setState(() {
      _current = _queue.isEmpty ? null : _queue.removeAt(0);
    });
    final approvalId = request['approvalId'] as String? ?? '';
    if (approvalId.isEmpty) return;
    try {
      await ref.read(vaultApiProvider).respondAgentApproval(
            approvalId: approvalId,
            allow: allow,
            allowStandingRead: standing,
          );
    } catch (_) {
      // 回话失败：核心会按超时拒绝，不需要 UI 再做什么。
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = _current;
    return Stack(
      children: [
        widget.child,
        if (request != null)
          Positioned.fill(
            child: _ApprovalOverlay(
              request: request,
              onAllow: () => _decide(allow: true),
              onDeny: () => _decide(allow: false),
              onAllowStanding: () => _decide(allow: true, standing: true),
            ),
          ),
      ],
    );
  }
}

class _ApprovalOverlay extends StatelessWidget {
  const _ApprovalOverlay({
    required this.request,
    required this.onAllow,
    required this.onDeny,
    required this.onAllowStanding,
  });

  final Map<String, dynamic> request;
  final VoidCallback onAllow;
  final VoidCallback onDeny;
  final VoidCallback onAllowStanding;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    final nickname = request['nickname'] as String? ?? '';
    final tool = request['tool'] as String? ?? '';
    final op = request['op'] as String? ?? 'read';
    final entryName = request['entryName'] as String?;
    final allowStanding = request['allowStanding'] == true && op == 'read';

    // 模态遮罩：挡住下面的点击，避免用户误以为还能操作主界面。
    // 必须自带 Material：这个浮层是 Scaffold 的**兄弟节点**，
    // 没有 Material 祖先时 AlertDialog 会直接抛异常。
    return Material(
      type: MaterialType.transparency,
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.55),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: AlertDialog(
              icon: Icon(Icons.smart_toy_outlined,
                  size: 28, color: theme.colorScheme.tertiary),
              title: Text(
                l10n.agentApprovalTitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 竖排卡片式信息：标签在上、值在下，比"左标签右值"更好读。
                    _field(
                      l10n.agentApprovalAgent,
                      nickname,
                      theme,
                      icon: Icons.person_outline,
                    ),
                    const SizedBox(height: 10),
                    _field(
                      l10n.agentApprovalOperation,
                      _opLabel(l10n, op),
                      theme,
                      icon: Icons.bolt_outlined,
                      emphasize: true,
                      color: theme.colorScheme.tertiary,
                    ),
                    if (entryName != null) ...[
                      const SizedBox(height: 10),
                      _field(
                        l10n.agentApprovalEntry,
                        entryName,
                        theme,
                        icon: Icons.key_outlined,
                        emphasize: true,
                      ),
                    ],
                    const SizedBox(height: 14),
                    Text(
                      l10n.agentApprovalHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    // 工具名放在最下面一行小字：排查时有用，但不该抢视线。
                    Text(
                      tool,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              // 按钮**竖排**、每个占满宽度：横排时英文长文案容易挤，
              // 而且"拒绝"必须显眼 —— 红色实心 + 最下面，符合危险动作的位置直觉。
              actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              actions: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: onAllow,
                    child: Text(l10n.agentApprovalAllow),
                  ),
                ),
                if (allowStanding) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonal(
                      onPressed: onAllowStanding,
                      child: Text(l10n.agentApprovalAllowStanding),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                      foregroundColor: theme.colorScheme.onError,
                    ),
                    onPressed: onDeny,
                    child: Text(l10n.agentApprovalDeny),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 竖排字段：图标 + 标签一行，值另起一行。
  Widget _field(
    String label,
    String value,
    ThemeData theme, {
    IconData? icon,
    bool emphasize = false,
    Color? color,
  }) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: (emphasize
                    ? theme.textTheme.titleSmall
                    : theme.textTheme.bodyMedium)
                ?.copyWith(
              fontWeight: emphasize ? FontWeight.w600 : FontWeight.w400,
              color: color,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
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
