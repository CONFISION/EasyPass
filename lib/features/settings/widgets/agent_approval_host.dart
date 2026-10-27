import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../client/api_providers.dart';
import '../../../l10n/app_localizations.dart';

/// 审批弹窗内容区宽度（逻辑像素）。测试用它确认"弹窗确实加宽了"，
/// 也方便以后调宽度时有个稳定锚点。
const Key agentApprovalContentKey = Key('agentApprovalContent');

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
/// - 弹窗做宽（内容区 520），三个动作**一排横放**：同意 / 本会话内允许读取 / 拒绝
///   —— 横排一眼读完，竖排像一张表单；「本会话内允许读取」只在普通读时出现；
/// - 拒绝 = 红色实心，是这一排里唯一带色块的按钮；
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

  /// 内容区宽度。宽度给足，三个按钮才有资格横着排；窄弹窗是当初只能竖排的
  /// 借口，而竖排读起来像一张表单，不像"现在就要你做个决定"。
  static const double _dialogWidth = 520;

  final Map<String, dynamic> request;
  final VoidCallback onAllow;
  final VoidCallback onDeny;
  final VoidCallback onAllowStanding;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final nickname = request['nickname'] as String? ?? '';
    final tool = request['tool'] as String? ?? '';
    final op = request['op'] as String? ?? 'read';
    final entryName = request['entryName'] as String?;
    // 写/删的"详细"：核心只给字段名与动作，**不会**有值。
    final detail = request['detail'] as String?;
    final allowStanding = request['allowStanding'] == true && op == 'read';

    // 模态遮罩：挡住下面的点击，避免用户误以为还能操作主界面。
    // 必须自带 Material：这个浮层是 Scaffold 的**兄弟节点**，
    // 没有 Material 祖先时 AlertDialog 会直接抛异常。
    return Material(
      type: MaterialType.transparency,
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.55),
        child: Center(
          child: AlertDialog(
            icon: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: scheme.tertiaryContainer.withValues(alpha: 0.55),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.smart_toy_outlined,
                size: 27,
                color: scheme.onTertiaryContainer,
              ),
            ),
            title: Text(
              l10n.agentApprovalTitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            content: SizedBox(
              key: agentApprovalContentKey,
              width: _dialogWidth,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 信息面板：标签左对齐成一列，值在右 —— 宽弹窗里这种
                    // "表格"比竖排卡片矮一半，一眼就能扫完四行。
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest
                            .withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: 0.6),
                        ),
                      ),
                      child: Column(
                        children: [
                          _infoRow(
                            theme: theme,
                            icon: Icons.person_outline,
                            label: l10n.agentApprovalAgent,
                            value: Text(
                              nickname,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(height: 10),
                          _infoRow(
                            theme: theme,
                            icon: Icons.bolt_outlined,
                            label: l10n.agentApprovalOperation,
                            value: Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: scheme.tertiaryContainer,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  _opLabel(l10n, op),
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: scheme.onTertiaryContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (entryName != null) ...[
                            const SizedBox(height: 10),
                            _infoRow(
                              theme: theme,
                              icon: Icons.key_outlined,
                              label: l10n.agentApprovalEntry,
                              value: Text(
                                entryName,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onSurface,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                          // 写/删的"详细"：必须让用户看清"到底要做什么"，
                          // 但这里只有字段名与动作，**没有任何值**（密码不显示）。
                          if (detail != null && detail.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            _infoRow(
                              theme: theme,
                              icon: Icons.edit_note_outlined,
                              label: l10n.agentApprovalDetail,
                              value: Text(
                                detail,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurface,
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                          const SizedBox(height: 10),
                          // 工具名不需要抢视线，但排查时要看得到。
                          _infoRow(
                            theme: theme,
                            icon: Icons.terminal_outlined,
                            label: l10n.agentApprovalTool,
                            value: Text(
                              tool,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontFamily: 'monospace',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      l10n.agentApprovalHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 三个动作**一排横放**，顺序按用户直觉：同意 → 本会话内允许读取 → 拒绝，
            // 拒绝红底白字垫最右，是一排里唯一带色块的按钮。
            // 中间那个用 Flexible：文案再长（英文 / 大字号）也只让它自己换行，
            // 绝不会把「拒绝」挤到第二排去。
            actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            actions: [
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton(
                    style: _actionStyle(),
                    onPressed: onAllow,
                    child: Text(l10n.agentApprovalAllow),
                  ),
                  if (allowStanding) ...[
                    const SizedBox(width: 12),
                    Flexible(
                      child: FilledButton.tonal(
                        style: _actionStyle(),
                        onPressed: onAllowStanding,
                        child: Text(l10n.agentApprovalAllowStanding),
                      ),
                    ),
                  ],
                  const SizedBox(width: 12),
                  FilledButton(
                    style: _actionStyle(danger: true, scheme: scheme),
                    onPressed: onDeny,
                    child: Text(l10n.agentApprovalDeny),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 三个动作按钮共用一套尺寸，保证同一排里高度/内边距一致。
  /// `danger` 只负责上色：拒绝是红色实心，红底白字，一眼能认出来。
  ButtonStyle _actionStyle({bool danger = false, ColorScheme? scheme}) {
    // 只声明尺寸/内边距，颜色留给主题（「本会话内允许读取」是 tonal 变体，
    // 显式传 null 颜色会把它变成普通实心按钮）。
    const base = ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(Size(0, 44)),
      padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 20),
      ),
    );
    if (!danger) return base;
    return base.copyWith(
      backgroundColor: WidgetStatePropertyAll<Color?>(scheme?.error),
      foregroundColor: WidgetStatePropertyAll<Color?>(scheme?.onError),
    );
  }

  /// 一行「图标 + 标签 + 值」，标签固定宽度对齐成一列。
  Widget _infoRow({
    required ThemeData theme,
    required IconData icon,
    required String label,
    required Widget value,
  }) {
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Icon(icon, size: 15, color: scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: value),
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
