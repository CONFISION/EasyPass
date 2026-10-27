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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l10n.agentActionFailed('$error'))),
      );
    }
  }

  Future<String?> _askMasterPassword(String title) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext);
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            decoration:
                InputDecoration(labelText: l10n.agentMasterPasswordPrompt),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: Text(l10n.agentConfirm),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  Future<void> _toggleEnabled(bool value) async {
    final api = ref.read(vaultApiProvider);
    if (!value) {
      await _run(api.disableAgentAccess);
      return;
    }
    // 打开需要解锁保险库（要拿 vaultKey 来包裹）——先让 ui 域确认一次主密码。
    final password = await _askMasterPassword(_l10n.agentAccessTitle);
    if (password == null || !mounted) return;
    try {
      await api.unlock(password);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l10n.agentActionFailed('$error'))),
      );
      return;
    }
    await _run(api.enableAgentAccess);
  }

  Future<void> _createPairing() async {
    final controller = TextEditingController();
    final nickname = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext);
        return AlertDialog(
          title: Text(l10n.agentCreatePairing),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: l10n.agentPairingNickname),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: Text(l10n.agentCreatePairing),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (nickname == null || nickname.isEmpty || !mounted) return;

    final api = ref.read(vaultApiProvider);
    try {
      final created = await api.createAgentPairing(
        nickname: nickname,
        mode: 'trusted',
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
  Future<void> _showKeyOnce(String key) async {
    await Clipboard.setData(ClipboardData(text: key));
    if (!mounted) return;
    final l10n = _l10n;
    final theme = Theme.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.agentKeyOnceTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.agentKeyOnceMessage, style: theme.textTheme.bodySmall),
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
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: key));
              Navigator.pop(dialogContext);
            },
            icon: const Icon(Icons.copy, size: 18),
            label: Text(l10n.agentCopied),
          ),
        ],
      ),
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
                _buildToggleCard(l10n, scheme),
                if (_enabled) ...[
                  const SizedBox(height: 12),
                  _buildWarningBanner(l10n, theme),
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
                    child: ListTile(
                      leading:
                          Icon(Icons.key_off_outlined, color: scheme.error),
                      title: Text(l10n.agentResetKey),
                      subtitle: Text(l10n.agentResetKeySubtitle),
                      onTap: _resetKey,
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

  Widget _buildToggleCard(AppLocalizations l10n, ColorScheme scheme) {
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
            child: Row(
              children: [
                _badge(
                  label: _enabled ? l10n.agentServiceOn : l10n.agentServiceOff,
                  color: _enabled ? scheme.primary : scheme.outline,
                ),
                const SizedBox(width: 8),
                _badge(
                  label: _unlocked
                      ? l10n.agentDomainUnlocked
                      : l10n.agentDomainLocked,
                  color: _unlocked ? scheme.tertiary : scheme.outline,
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
          Text(label, style: TextStyle(fontSize: 12, color: color)),
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
    final scheme = theme.colorScheme;

    return Card(
      child: ListTile(
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
          ].join(' · ')),
        ),
        trailing: IconButton(
          tooltip: l10n.agentRevoke,
          icon: Icon(Icons.link_off, color: scheme.error),
          onPressed: () => _revoke(pairing),
        ),
      ),
    );
  }
}
