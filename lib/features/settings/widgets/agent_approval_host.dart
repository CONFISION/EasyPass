import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../client/api_providers.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/providers/auth_provider.dart';

/// 审批弹窗内容区宽度（逻辑像素）。测试用它确认"弹窗确实加宽了"，
/// 也方便以后调宽度时有个稳定锚点。
const Key agentApprovalContentKey = Key('agentApprovalContent');

/// 待审批队列上限。智能体是"可被提示注入驱动"的调用者：没有上限时它可以
/// 一次性灌进任意多条请求，把应用级浮层变成拒绝服务入口，也把"审批"变成
/// 连点训练。超过上限的新请求直接拒绝（fail closed）并提示用户。
const int agentApprovalQueueLimit = 20;

/// 新请求上屏后至少这么久才允许点击。
///
/// 防的是"一次双击批准两条"：`_decide` 一旦把下一条推上屏幕，鼠标的第二次
/// 点击会落在同一个坐标的按钮上 —— 用户却只看过第一条。350ms 覆盖 Windows
/// 默认双击间隔，并给用户一个"内容换了"的视觉提示窗口。
const Duration agentApprovalArmDelay = Duration(milliseconds: 350);

/// 把智能体/条目可控文本里的控制字符、双向控制符、零宽字符替换成**可见**
/// 转义。
///
/// 为什么必须做：条目名与昵称完全由用户/智能体写入，可以塞进换行、RLO
/// （U+202E）、零宽字符或同形字母，在审批弹窗与审计列表里伪装成别的条目或
/// 伪造"已授权"字样。替换成 `\n`、`\u202E` 这种可见转义后，渲染层就没有
/// "看不见的字符"了。
String sanitizeAgentDisplayText(String value) {
  if (value.isEmpty) return value;
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    switch (rune) {
      case 0x0A: // \n —— 审批界面里保留为可见转义，避免把一行拆成多行。
        buffer.write(r'\n');
      case 0x0D:
        buffer.write(r'\r');
      case 0x09:
        buffer.write(r'\t');
      case 0x2028: // LINE SEPARATOR
      case 0x2029: // PARAGRAPH SEPARATOR
      case 0x202A: // LRE
      case 0x202B: // RLE
      case 0x202C: // PDF
      case 0x202D: // LRO
      case 0x202E: // RLO
      case 0x2066: // LRI
      case 0x2067: // RLI
      case 0x2068: // FSI
      case 0x2069: // PDI
      case 0x061C: // ARABIC LETTER MARK
      case 0x200B: // ZERO WIDTH SPACE
      case 0x200C: // ZWNJ
      case 0x200D: // ZWJ
      case 0x200E: // LRM
      case 0x200F: // RLM
      case 0x2060: // WORD JOINER
      case 0xFEFF: // BOM / ZWNBSP
        buffer.write(
          '\\u${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}',
        );
      default:
        if (rune < 0x20 || (rune >= 0x7F && rune <= 0x9F)) {
          // 其余 C0/C1 控制字符：同样只以可见转义出现。
          buffer.write(
            '\\u${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}',
          );
        } else {
          buffer.writeCharCode(rune);
        }
    }
  }
  return buffer.toString();
}

/// 方式 1（逐次审批）的审批界面宿主。
///
/// 挂在 `MaterialApp.builder` 上，任何页面都会显示 —— 审批是"智能体在等你回话"，
/// 用户此刻可能停在生成器或设置页。但**锁定时绝不显示**：审批是用户当面授权，
/// 锁屏上的点击不能代替解锁（锁定时收到的请求直接拒绝，见 `_enqueue`）。
///
/// **为什么不用 `showDialog`**（真机踩过）：`builder` 的 context 位于 Navigator
/// **之上**，`showDialog` 找不到 Navigator 会抛异常，兜底逻辑就立刻回一个"拒绝"
/// —— 表现是调用 0.1 秒返回 denied、弹窗根本不出现。这里改成**自绘浮层**
/// （Stack + 遮罩 + AlertDialog 组件本身），完全不依赖 Navigator。
///
/// 其余纪律：
/// - 完整展示：来自哪个智能体、什么操作、哪个条目、哪个工具；detail 不截断，
///   且所有用户/智能体可控文本先经 [sanitizeAgentDisplayText] 清洗；
/// - 一次点击只作用于当前这一条：回话期间按钮禁用，下一条上屏后还有
///   [agentApprovalArmDelay] 的"只读窗口"，防止双击批准两条；
/// - 队列上限 [agentApprovalQueueLimit]，超出直接拒绝并提示；
/// - 关掉 = 拒绝；同一时刻只显示一个，其余排队；核心广播 resolved 后移除。
class AgentApprovalHost extends ConsumerStatefulWidget {
  const AgentApprovalHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AgentApprovalHost> createState() => _AgentApprovalHostState();
}

class _AgentApprovalHostState extends ConsumerState<AgentApprovalHost> {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  StreamSubscription<Map<String, dynamic>>? _resolvedSubscription;
  final List<Map<String, dynamic>> _queue = [];
  Map<String, dynamic>? _current;

  /// 正在等核心回包：三个按钮全部禁用，防止同一请求被重复回应。
  bool _responding = false;

  /// 当前请求是否已过"只读窗口"（见 [agentApprovalArmDelay]）。
  bool _armed = false;
  Timer? _armTimer;

  /// 因队列满而被自动拒绝的请求数（提示用；几秒后自动清除）。
  int _dropped = 0;
  Timer? _droppedTimer;

  /// 锁定清理只调度一次（build 里发现锁定时用 post-frame 做副作用）。
  bool _lockCleanupScheduled = false;

  @override
  void initState() {
    super.initState();
    final api = ref.read(vaultApiProvider);
    _subscription = api.agentApprovalRequests.listen(_enqueue);
    // 核心在审批结束（同意/拒绝/超时/取消）时广播 resolved。UI 必须跟着移除，
    // 否则用户会对一条已经失效的请求点"同意"，而核心早已按超时拒绝。
    _resolvedSubscription = api.agentApprovalResolved.listen(_onResolved);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_resolvedSubscription?.cancel());
    _armTimer?.cancel();
    _droppedTimer?.cancel();
    super.dispose();
  }

  /// 只有保险库处于"已解锁"态才允许弹审批。`loading` / `firstRun` /
  /// `locked` 一律按锁屏处理（fail closed）：审批按钮代表用户当面授权，
  /// 不能在用户还没解锁的时候被点。
  bool get _vaultUnlocked =>
      ref.read(authProvider).status == AuthStatus.unlocked;

  void _enqueue(Map<String, dynamic> request) {
    if (!mounted) return;
    if (!_vaultUnlocked) {
      // 锁屏/首启/加载中：不渲染浮层，直接拒绝耗尽这条请求。
      _deny(request);
      return;
    }
    final pending = _queue.length + (_current == null ? 0 : 1);
    if (pending >= agentApprovalQueueLimit) {
      _dropped++;
      _deny(request);
      setState(() {});
      _droppedTimer?.cancel();
      _droppedTimer = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _dropped = 0);
      });
      return;
    }
    setState(() {
      if (_current == null) {
        _present(request);
      } else {
        _queue.add(request);
      }
    });
  }

  /// 把请求推上屏幕并开始"只读窗口"计时。
  void _present(Map<String, dynamic> request) {
    _current = request;
    _responding = false;
    _armed = false;
    _armTimer?.cancel();
    _armTimer = Timer(agentApprovalArmDelay, () {
      if (!mounted) return;
      setState(() => _armed = true);
    });
  }

  /// 当前请求结束（已回话 / 核心已 resolved）：显示下一条。
  void _advance() {
    _responding = false;
    _armed = false;
    _armTimer?.cancel();
    _current = _queue.isEmpty ? null : _queue.removeAt(0);
    if (_current != null) {
      _present(_current!);
    }
  }

  void _deny(Map<String, dynamic> request) {
    final approvalId = request['approvalId'] as String? ?? '';
    if (approvalId.isEmpty) return;
    unawaited(
      ref
          .read(vaultApiProvider)
          .respondAgentApproval(approvalId: approvalId, allow: false)
          .catchError((Object _) => false),
    );
  }

  Future<void> _decide({required bool allow, bool standing = false}) async {
    final request = _current;
    // `_armed` / `_responding` 是防双击与防重复回话的硬闸：不在窗口内的点击
    // 一律丢弃，不产生任何副作用。
    if (request == null || _responding || !_armed) return;
    final approvalId = request['approvalId'] as String? ?? '';
    if (approvalId.isEmpty) return;
    setState(() {
      _responding = true;
      _armed = false;
      _armTimer?.cancel();
    });
    final api = ref.read(vaultApiProvider);
    // 用户正在审批界面交互：先续期 UI 空闲计时（核心的自动锁不看 overlay 的
    // 点击，只能由这里上报），避免读到一半被自动锁定。
    try {
      await ref.read(authProvider.notifier).touchActivity();
    } catch (_) {
      // 续期失败不影响审批本身；核心仍会按自己的超时处理。
    }
    try {
      await api.respondAgentApproval(
        approvalId: approvalId,
        allow: allow,
        allowStandingRead: standing,
      );
    } catch (_) {
      // 回话失败：核心会按超时拒绝，UI 不再重试（避免重复回应）。
    }
    if (!mounted) return;
    setState(_advance);
  }

  /// 核心结算了某条审批（同意/拒绝/超时/取消）：按 approvalId 移除。
  void _onResolved(Map<String, dynamic> event) {
    if (!mounted) return;
    final approvalId = event['approvalId'] as String? ?? '';
    if (approvalId.isEmpty) return;
    final isCurrent = _current?['approvalId'] == approvalId;
    if (!isCurrent) {
      if (_queue.any((r) => r['approvalId'] == approvalId)) {
        setState(() {
          _queue.removeWhere((r) => r['approvalId'] == approvalId);
        });
      }
      return;
    }
    // 正在回话时不要抢先推进：`_decide` 拿到结果后会自己 `_advance`，
    // 这里抢跑会让下一条被跳过。等 `_decide` 收尾即可。
    if (_responding) return;
    setState(_advance);
  }

  /// 锁定/首启时把当前与排队的请求全部拒绝并清空：不能让它们在解锁后
  /// 重新冒出来 —— 那等于让用户批准一条"锁屏期间发出的旧请求"。
  void _denyAllAndClear() {
    final pending = <Map<String, dynamic>>[
      ?_current,
      ..._queue,
    ];
    setState(() {
      _queue.clear();
      _current = null;
      _responding = false;
      _armed = false;
      _armTimer?.cancel();
    });
    for (final request in pending) {
      _deny(request);
    }
  }

  @override
  Widget build(BuildContext context) {
    final unlocked = ref.watch(
      authProvider.select((state) => state.status == AuthStatus.unlocked),
    );
    final request = _current;

    // 锁定发生在审批显示期间：本轮 build 立即不渲染浮层（fail closed），
    // 并在帧后清理队列把待审批请求全部拒绝。
    if (!unlocked &&
        (request != null || _queue.isNotEmpty) &&
        !_lockCleanupScheduled) {
      _lockCleanupScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _lockCleanupScheduled = false;
        if (mounted) _denyAllAndClear();
      });
    }

    return Stack(
      children: [
        widget.child,
        if (unlocked && request != null)
          Positioned.fill(
            child: _ApprovalOverlay(
              request: request,
              enabled: _armed && !_responding,
              queueTotal: _queue.length + 1,
              droppedCount: _dropped,
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
    required this.enabled,
    required this.queueTotal,
    required this.droppedCount,
    required this.onAllow,
    required this.onDeny,
    required this.onAllowStanding,
  });

  /// 内容区宽度。宽度给足，三个按钮才有资格横着排；窄弹窗是当初只能竖排的
  /// 借口，而竖排读起来像一张表单，不像"现在就要你做个决定"。
  static const double _dialogWidth = 520;

  final Map<String, dynamic> request;

  /// 过了"只读窗口"且没有回话在途时，三个按钮才可点。
  final bool enabled;

  /// 队列里还有几条（含当前这条）。
  final int queueTotal;

  /// 因队列满而被自动拒绝的请求数（>0 时显示警示行）。
  final int droppedCount;

  final VoidCallback onAllow;
  final VoidCallback onDeny;
  final VoidCallback onAllowStanding;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // 所有用户/智能体可控文本都先清洗：条目名、昵称可以带换行/RLO/零宽字符，
    // 不清洗就能在详情区伪造"已授权"之类的文本。
    final nickname = sanitizeAgentDisplayText(
      request['nickname'] as String? ?? '',
    );
    final tool = sanitizeAgentDisplayText(request['tool'] as String? ?? '');
    final op = request['op'] as String? ?? 'read';
    final rawEntryName = request['entryName'] as String?;
    final entryName =
        rawEntryName == null ? null : sanitizeAgentDisplayText(rawEntryName);
    // 写/删的"详细"：核心只给字段名与动作（以及 update 的 old → new 文本），
    // **不会**有秘密值。
    final rawDetail = request['detail'] as String?;
    final detail = rawDetail == null ? null : sanitizeAgentDisplayText(rawDetail);
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
                    // "表格"比竖排卡片矮一半，一眼就能扫完几行。
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
                          if (entryName != null && entryName.isNotEmpty) ...[
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
                              ),
                            ),
                          ],
                          // 写/删的"详细"：必须让用户看清"到底要做什么"。
                          // 不截断（内容区可滚动）：任何被省略号藏起来的部分
                          // 都可能藏着真实目标/新值。清洗后的转义保证换行不会
                          // 伪装成额外的信息行。
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
                                  height: 1.35,
                                ),
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
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (queueTotal > 1) ...[
                      const SizedBox(height: 10),
                      Text(
                        l10n.agentApprovalQueuePosition('1', '$queueTotal'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (droppedCount > 0) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              size: 18,
                              color: scheme.onErrorContainer,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                l10n.agentApprovalQueueFull('$droppedCount'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onErrorContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
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
                    onPressed: enabled ? onAllow : null,
                    child: Text(l10n.agentApprovalAllow),
                  ),
                  if (allowStanding) ...[
                    const SizedBox(width: 12),
                    Flexible(
                      child: FilledButton.tonal(
                        style: _actionStyle(),
                        onPressed: enabled ? onAllowStanding : null,
                        child: Text(l10n.agentApprovalAllowStanding),
                      ),
                    ),
                  ],
                  const SizedBox(width: 12),
                  FilledButton(
                    style: _actionStyle(danger: true, scheme: scheme),
                    onPressed: enabled ? onDeny : null,
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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 15, color: scheme.onSurfaceVariant),
        ),
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
