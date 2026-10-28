import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../client/api_providers.dart';
import '../../../l10n/app_localizations.dart';

/// 设置 → 智能体访问。
///
/// 这是**唯一**能开关智能体访问、创建/撤销配对、重置专属密钥的界面。
/// 智能体自己永远调不到这些动作（只加进 `uiAllowed`）。
///
/// 设计要点（"好看"之外的真实理由）：
/// - 顶部是**总开关卡片**：开启时立刻出现醒目警示条 —— 开启意味着
///   "保险库可被自动解锁"，用户必须一眼看见，而不是埋在列表里；
/// - 状态用徽章直读（服务 / 会话分开），不用用户猜"到底开没开"；
/// - 配对卡片列出昵称、方式与调用次数；危险操作（重置密钥）单独分区。
class AgentAccessScreen extends ConsumerStatefulWidget {
  const AgentAccessScreen({super.key});

  @override
  ConsumerState<AgentAccessScreen> createState() => _AgentAccessScreenState();
}

class _AgentAccessScreenState extends ConsumerState<AgentAccessScreen> {
  bool _loading = true;
  bool _enabled = false;
  bool _unlocked = false;

  /// 真实 MCP 端点状态（M6）：`enabled` 只是"用户想开"的持久标记，不代表
  /// 端口真的在监听。徽标与错误提示必须读核心返回的运行态。
  bool _mcpRunning = false;
  int? _mcpPort;
  String? _mcpError;
  List<Map<String, dynamic>> _pairings = const [];
  String? _error;

  AppLocalizations get _l10n => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final api = ref.read(vaultApiProvider);
    try {
      final state = await api.agentAccessState();
      final pairings = await api.listAgentPairings();
      if (!mounted) return;
      setState(() {
        _enabled = state['enabled'] == true;
        _unlocked = state['agentUnlocked'] == true;
        _mcpRunning = state['mcpRunning'] == true;
        _mcpPort = (state['mcpPort'] as num?)?.toInt();
        _mcpError = state['mcpError'] as String?;
        _pairings = pairings;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      // 失败后也要刷一次：核心可能已经回滚了状态（例如 enable 失败会
      // wipe+lock），徽标必须显示真实状态，而不是用户点开关之前的样子。
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l10n.agentActionFailed('$error'))),
      );
    }
  }

  Future<String?> _askMasterPassword(String title) {
    // controller 由弹窗自己的 State 持有：`showDialog` 的 Future 在路由
    // pop 时就返回，但 TextField 还要等退场动画结束才 unmount。在这里
    // dispose 会让 EditableText 用到已销毁的 controller（真机/测试都会抛
    // "A TextEditingController was used after being disposed"）。
    return showDialog<String>(
      context: context,
      builder: (_) => _MasterPasswordDialog(title: title),
    );
  }

  Future<void> _toggleEnabled(bool value) async {
    final api = ref.read(vaultApiProvider);
    if (!value) {
      await _run(api.disableAgentAccess);
      return;
    }
    // 打开开关要拿 ui 域的 vaultKey 去包裹；先让用户用主密码确认一次。
    //
    // 只做 `verifyMasterPassword`，**不再调用 `unlock`**：重新 unlock 会改变
    // AuthNotifier 状态，进而重建 GoRouter（本页是 Navigator.push 进来的），
    // 用户会在开关生效前被弹回 /vault，看不到结果。
    final password = await _askMasterPassword(_l10n.agentAccessTitle);
    if (password == null || !mounted) return;
    final bool verified;
    try {
      verified = await api.verifyMasterPassword(password);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l10n.agentActionFailed('$error'))),
      );
      return;
    }
    if (!mounted) return;
    if (!verified) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l10n.errorIncorrectMasterPassword)),
      );
      return;
    }
    await _run(api.enableAgentAccess);
  }

  Future<void> _createPairing() async {
    // 昵称 controller 同样交给弹窗自己的 State 管理（见 `_askMasterPassword`）。
    final nickname = await showDialog<String>(
      context: context,
      builder: (_) => const _PairingNicknameDialog(),
    );
    if (nickname == null || nickname.isEmpty || !mounted) return;

    // 建"可信直通"配对必须用主密码确认一次（核心据此置 trusted）。
    final password = await _askMasterPassword(_l10n.agentCreatePairing);
    if (password == null || !mounted) return;

    final api = ref.read(vaultApiProvider);
    try {
      final created = await api.createAgentPairing(
        nickname: nickname,
        mode: 'trusted',
        password: password,
      );
      await _showKeyOnce(created['key'] as String? ?? '');
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l10n.agentActionFailed('$error'))),
      );
    }
  }

  /// 密钥**只显示这一次**（库里只有 SHA-256）。
  ///
  /// **不自动复制到剪贴板**（M10）：配对密钥是 MCP 的 Bearer 凭据，自动复制
  /// 会让它在用户没点"复制"时进入剪贴板历史/云剪贴板/同会话进程可见的通道。
  /// 只有用户显式点"复制"才写，并当场提示剪贴板的风险。
  Future<void> _showKeyOnce(String key) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        var copied = false;
        return StatefulBuilder(
          builder: (builderContext, setDialogState) {
            final l10n = AppLocalizations.of(builderContext);
            final theme = Theme.of(builderContext);
            return AlertDialog(
              title: Text(l10n.agentKeyOnceTitle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.agentKeyOnceMessage,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      key,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.agentKeyClipboardHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (copied) ...[
                    const SizedBox(height: 8),
                    Text(
                      l10n.agentKeyCopiedHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: key));
                    if (builderContext.mounted) {
                      setDialogState(() => copied = true);
                    }
                  },
                  icon: Icon(copied ? Icons.check : Icons.copy, size: 18),
                  label: Text(l10n.agentCopy),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(l10n.agentConfirm),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _revoke(Map<String, dynamic> pairing) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext);
        return AlertDialog(
          title: Text(l10n.agentRevoke),
          content: Text(l10n.agentRevokeConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10n.agentRevoke),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    final api = ref.read(vaultApiProvider);
    await _run(() => api.revokeAgentPairing(pairing['id'] as String? ?? ''));
  }

  Future<void> _resetKey() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext);
        return AlertDialog(
          title: Text(l10n.agentResetKey),
          content: Text(l10n.agentResetKeyConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10n.agentResetKey),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    final api = ref.read(vaultApiProvider);
    await _run(api.resetAgentKey);
  }

  /// 撤销某个配对的「本会话内允许读取」（D3：UI 必须给撤销入口）。
  Future<void> _revokeStandingRead(Map<String, dynamic> pairing) async {
    final id = pairing['id'] as String? ?? '';
    if (id.isEmpty) return;
    final nickname = pairing['nickname'] as String? ?? '';
    final api = ref.read(vaultApiProvider);
    try {
      await api.clearStandingRead(id);
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l10n.agentStandingReadRevoked(nickname))),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l10n.agentActionFailed('$error'))),
      );
    }
  }

  /// 一次性撤销所有配对的免询问读取。
  Future<void> _revokeAllStandingRead() async {
    final api = ref.read(vaultApiProvider);
    final ids = [
      for (final pairing in _standingPairings)
        if ((pairing['id'] as String? ?? '').isNotEmpty) pairing['id'] as String,
    ];
    for (final id in ids) {
      try {
        await api.clearStandingRead(id);
      } catch (_) {
        // 单个失败不阻塞其余撤销；最后统一刷新真实状态。
      }
    }
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_l10n.agentStandingReadRevokedAll)),
    );
  }

  Future<void> _lockAgentSession() async {
    final api = ref.read(vaultApiProvider);
    await _run(api.lockAgentDomain);
  }

  Future<void> _unlockAgentSession() async {
    final password = await _askMasterPassword(_l10n.agentUnlock);
    if (password == null || !mounted) return;
    final api = ref.read(vaultApiProvider);
    try {
      await api.unlockAgentDomain(password);
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l10n.agentActionFailed('$error'))),
      );
    }
  }

  /// 处于「本会话内免询问读取」的配对。
  List<Map<String, dynamic>> get _standingPairings => [
        for (final pairing in _pairings)
          if (pairing['standingRead'] == true) pairing,
      ];

  /// 服务徽标文案：读的是真实 MCP 运行态，而不是"用户想开"的开关标记。
  String _serviceLabel(AppLocalizations l10n) {
    if (!_enabled) return l10n.agentServiceOff;
    if (_mcpRunning) {
      final port = _mcpPort;
      return port == null
          ? l10n.agentServiceOn
          : l10n.agentServiceRunning('$port');
    }
    return l10n.agentServiceUnavailable;
  }

  Color _serviceColor(ColorScheme scheme) {
    if (!_enabled) return scheme.outline;
    return _mcpRunning ? scheme.primary : scheme.error;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.agentAccessTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  Card(
                    color: scheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        l10n.agentActionFailed(_error!),
                        style: TextStyle(color: scheme.onErrorContainer),
                      ),
                    ),
                  ),
                _buildToggleCard(l10n, theme),
                if (_enabled) ...[
                  const SizedBox(height: 12),
                  _buildWarningBanner(l10n, theme),
                ],
                // 常驻的免询问指示（D3）：用户点过「本会话内允许读取」后必须
                // 一直看得见、随时能撤销 —— 否则就是无痕授权。
                if (_enabled && _standingPairings.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildStandingReadBanner(l10n, theme),
                ],
                const SizedBox(height: 20),
                _sectionTitle(l10n.agentPairings, theme),
                const SizedBox(height: 8),
                if (_pairings.isEmpty)
                  _buildEmptyPairings(l10n, theme)
                else
                  for (final pairing in _pairings) ...[
                    _buildPairingCard(pairing, l10n, theme),
                    const SizedBox(height: 8),
                  ],
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    onPressed: _enabled ? _createPairing : null,
                    icon: const Icon(Icons.add_link),
                    label: Text(l10n.agentCreatePairing),
                  ),
                ),
                if (!_enabled)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      l10n.agentEnableFirst,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                if (_enabled) ...[
                  const SizedBox(height: 24),
                  _sectionTitle(l10n.agentAdvancedSection, theme),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(
                      children: [
                        // 智能体会话锁定/解锁（D1 / M6）：agent 域不再随空闲
                        // 自动锁定，但用户必须有一个显式开关能立即收回访问权。
                        ListTile(
                          leading: Icon(
                            _unlocked ? Icons.lock_outline : Icons.lock_open,
                            color: _unlocked ? scheme.primary : null,
                          ),
                          title: Text(
                            _unlocked ? l10n.agentLock : l10n.agentUnlock,
                          ),
                          subtitle: Text(
                            _unlocked
                                ? l10n.agentSessionLockSubtitle
                                : l10n.agentSessionUnlockSubtitle,
                          ),
                          onTap:
                              _unlocked ? _lockAgentSession : _unlockAgentSession,
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: Icon(Icons.key_off_outlined,
                              color: scheme.error),
                          title: Text(l10n.agentResetKey),
                          subtitle: Text(l10n.agentResetKeySubtitle),
                          onTap: _resetKey,
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  l10n.agentAccessSubtitle,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
    );
  }

  Widget _sectionTitle(String text, ThemeData theme) => Text(
        text,
        style: theme.textTheme.titleSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );

  Widget _buildToggleCard(AppLocalizations l10n, ThemeData theme) {
    final scheme = theme.colorScheme;
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            secondary: Icon(
              _enabled ? Icons.lock_open : Icons.lock_outline,
              color: _enabled ? scheme.primary : null,
            ),
            title: Text(l10n.agentEnableTitle),
            subtitle: Text(
              _enabled ? l10n.agentEnabledSubtitle : l10n.agentDisabledSubtitle,
            ),
            value: _enabled,
            onChanged: _toggleEnabled,
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            // 左对齐 + 可换行：Column 的默认 crossAxisAlignment 是 center，
            // Wrap 只占内容宽度会被居中；外面包一层 Align 才能保持和原来
            // Row 一样的靠左视觉。窄窗口（900×600 最小窗口、150% DPI）下
            // 仍然换行而不是 overflow，也不靠 padding 硬凑。
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.start,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _badge(
                    label: _serviceLabel(l10n),
                    color: _serviceColor(scheme),
                  ),
                  _badge(
                    label: _unlocked
                        ? l10n.agentDomainUnlocked
                        : l10n.agentDomainLocked,
                    color: _unlocked ? scheme.tertiary : scheme.outline,
                  ),
                ],
              ),
            ),
          ),
          // 开关开着但端点没起来：必须把核心给出的真实原因显示出来，
          // 不能让用户以为"MCP 正常"。
          if (_enabled && !_mcpRunning)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, size: 16, color: scheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _mcpError == null
                          ? l10n.agentServiceUnavailable
                          : l10n.agentServiceError(_mcpError!),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.error),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _badge({required String label, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: color),
          const SizedBox(width: 6),
          // Flexible + ellipsis：单个徽标也不允许把父级撑爆（测试字体/150%
          // 缩放下文案都比中文更长）。
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWarningBanner(AppLocalizations l10n, ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.agentWarningBanner,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }

  /// 免询问读取的常驻指示 + 一键撤销（D3）。
  Widget _buildStandingReadBanner(AppLocalizations l10n, ThemeData theme) {
    final scheme = theme.colorScheme;
    final names = _standingPairings
        .map((pairing) => pairing['nickname'] as String? ?? '')
        .where((name) => name.isNotEmpty)
        .join('、');
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.tertiary.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.visibility_outlined,
            color: scheme.onTertiaryContainer,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.agentStandingReadTitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onTertiaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.agentStandingReadBanner(names),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onTertiaryContainer,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _revokeAllStandingRead,
            child: Text(l10n.agentStandingReadRevokeAll),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyPairings(AppLocalizations l10n, ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.smart_toy_outlined,
                size: 32, color: theme.colorScheme.outline),
            const SizedBox(height: 8),
            Text(l10n.agentNoPairings, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  Widget _buildPairingCard(
    Map<String, dynamic> pairing,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    final nickname = pairing['nickname'] as String? ?? '';
    final trusted = pairing['mode'] == 'trusted';
    final calls = pairing['calls'];
    final standingRead = pairing['standingRead'] == true;
    final scheme = theme.colorScheme;

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.smart_toy_outlined,
                  color: scheme.onPrimaryContainer, size: 20),
            ),
            title: Text(nickname),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text([
                trusted ? l10n.agentModeTrusted : l10n.agentModeApproval,
                if (calls != null) l10n.agentCalls('$calls'),
                if (standingRead) l10n.agentStandingReadActive,
              ].join(' · ')),
            ),
            trailing: PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'mode') {
                  _switchMode(pairing);
                } else if (value == 'revoke') {
                  _revoke(pairing);
                }
              },
              itemBuilder: (menuContext) => [
                PopupMenuItem(
                  value: 'mode',
                  child: Text(
                    trusted
                        ? l10n.agentSwitchToApproval
                        : l10n.agentSwitchToTrusted,
                  ),
                ),
                PopupMenuItem(
                  value: 'revoke',
                  child: Text(l10n.agentRevoke),
                ),
              ],
            ),
          ),
          // 「本会话内允许读取」是可撤销的会话级放行：卡片上必须有可见的
          // 撤销按钮，不能只藏在菜单里（D3）。
          if (standingRead)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.agentStandingReadHint,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _revokeStandingRead(pairing),
                    icon: const Icon(Icons.visibility_off_outlined, size: 18),
                    label: Text(l10n.agentStandingReadRevoke),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 切换访问方式。
  ///
  /// 切到"可信直通"必须输入主密码（核心会二次校验并顺带解锁智能体会话）；
  /// 切回"每次询问"不需要密码，也不再锁智能体会话（D1：agent 域生命周期只由
  /// 总开关 / 显式锁定 / 核心退出决定）。
  Future<void> _switchMode(Map<String, dynamic> pairing) async {
    final id = pairing['id'] as String? ?? '';
    final isTrusted = pairing['mode'] == 'trusted';
    final api = ref.read(vaultApiProvider);
    if (isTrusted) {
      await _run(() => api.setAgentAccessMode(id: id, mode: 'approval'));
      return;
    }
    final password = await _askMasterPassword(_l10n.agentModeSwitch);
    if (password == null || !mounted) return;
    await _run(() => api.setAgentAccessMode(
          id: id,
          mode: 'trusted',
          password: password,
        ));
  }
}

/// 主密码确认弹窗。
///
/// controller 必须由弹窗自己的 [State] 持有：`showDialog` 的 Future 在路由 pop
/// 时就完成，而 TextField 要等退场动画结束才 unmount。在 `await showDialog`
/// 之后立刻 dispose，会让 EditableText 在下一帧用到已销毁的 controller
/// （测试里就是 "A TextEditingController was used after being disposed"）。
class _MasterPasswordDialog extends StatefulWidget {
  const _MasterPasswordDialog({required this.title});

  final String title;

  @override
  State<_MasterPasswordDialog> createState() => _MasterPasswordDialogState();
}

class _MasterPasswordDialogState extends State<_MasterPasswordDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        obscureText: true,
        autofocus: true,
        decoration:
            InputDecoration(labelText: l10n.agentMasterPasswordPrompt),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(l10n.agentConfirm),
        ),
      ],
    );
  }
}

/// 新建配对的昵称输入框（controller 生命周期与 [_MasterPasswordDialog] 同理）。
class _PairingNicknameDialog extends StatefulWidget {
  const _PairingNicknameDialog();

  @override
  State<_PairingNicknameDialog> createState() => _PairingNicknameDialogState();
}

class _PairingNicknameDialogState extends State<_PairingNicknameDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.agentCreatePairing),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: l10n.agentPairingNickname),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(l10n.agentCreatePairing),
        ),
      ],
    );
  }
}
