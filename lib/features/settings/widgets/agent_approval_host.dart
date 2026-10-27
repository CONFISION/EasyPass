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
        color: Colors.black.withValues(alpha: 0.5),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: AlertDialog(
            icon: Icon(Icons.smart_toy_outlined,
                color: theme.colorScheme.tertiary),
            title: Text(l10n.agentApprovalTitle),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row(l10n.agentApprovalAgent, nickname, theme),
                  const SizedBox(height: 8),
                  _row(l10n.agentApprovalOperation, _opLabel(l10n, op), theme,
                      emphasize: true),
                  if (entryName != null) ...[
                    const SizedBox(height: 8),
                    _row(l10n.agentApprovalEntry, entryName, theme,
                        emphasize: true),
                  ],
                  const SizedBox(height: 8),
                  _row(l10n.agentApprovalTool, tool, theme),
                  const SizedBox(height: 12),
                  Text(
                    l10n.agentApprovalHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            // 三个按钮交给 AlertDialog 的 OverflowBar 自己排：
            // 嵌套 Row 在窄宽度 + 长文案（英文「Allow reads this session」）时
            // 会直接溢出 —— 这是仓库里记过的同类坑，别再包一层 Row。
            actions: [
              TextButton(
                onPressed: onDeny,
                child: Text(l10n.agentApprovalDeny),
              ),
              if (allowStanding)
                TextButton(
                  onPressed: onAllowStanding,
                  child: Text(l10n.agentApprovalAllowStanding),
                ),
              FilledButton(
                onPressed: onAllow,
                child: Text(l10n.agentApprovalAllow),
              ),
            ],
          ),
        ),
      ),
      ),
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
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: emphasize
                ? theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)
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
