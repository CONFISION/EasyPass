import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../client/api_providers.dart';
import '../../../l10n/app_localizations.dart';

/// 设置 → 智能体访问。
///
/// 这是**唯一**能创建/撤销配对、切换访问方式、解锁智能体域的界面。
/// 智能体自己永远调不到这些动作（只加进 `uiAllowed`）。
class AgentAccessScreen extends ConsumerStatefulWidget {
  const AgentAccessScreen({super.key});

  @override
  ConsumerState<AgentAccessScreen> createState() => _AgentAccessScreenState();
}

class _AgentAccessScreenState extends ConsumerState<AgentAccessScreen> {
  bool _loading = true;
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
      final unlocked = await api.agentDomainUnlocked();
      final pairings = await api.listAgentPairings();
      if (!mounted) return;
      setState(() {
        _unlocked = unlocked;
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

  /// 用主密码确认（切"可信直通"与解锁 agent 域都要）。
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
            decoration: InputDecoration(labelText: l10n.agentMasterPasswordPrompt),
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
              onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
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
      // 新建一律先给"每次询问"；要开可信直通走"切换方式"（那里有主密码确认）。
      final created = await api.createAgentPairing(
        nickname: nickname,
        mode: 'approval',
      );
      final key = created['key'] as String? ?? '';
      if (!mounted) return;
      await _showKeyOnce(key);
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
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.agentKeyOnceTitle),
        content: SelectableText(key),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: key));
              Navigator.pop(dialogContext);
            },
            child: Text(l10n.agentCopied),
          ),
        ],
      ),
    );
  }

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

  Future<void> _toggleUnlock() async {
    final api = ref.read(vaultApiProvider);
    if (_unlocked) {
      await _run(api.lockAgentDomain);
      return;
    }
    final password = await _askMasterPassword(_l10n.agentUnlock);
    if (password == null || !mounted) return;
    await _run(() => api.unlockAgentDomain(password));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.agentAccessTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      l10n.agentActionFailed(_error!),
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                ListTile(
                  leading: Icon(_unlocked ? Icons.lock_open : Icons.lock_outline),
                  title: Text(
                    _unlocked ? l10n.agentDomainUnlocked : l10n.agentDomainLocked,
                  ),
                  trailing: FilledButton.tonal(
                    onPressed: _toggleUnlock,
                    child: Text(_unlocked ? l10n.agentLock : l10n.agentUnlock),
                  ),
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    l10n.agentPairings,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_pairings.isEmpty)
                  ListTile(title: Text(l10n.agentNoPairings))
                else
                  for (final pairing in _pairings)
                    ListTile(
                      leading: const Icon(Icons.smart_toy_outlined),
                      title: Text(pairing['nickname'] as String? ?? ''),
                      subtitle: Text(
                        [
                          pairing['mode'] == 'trusted'
                              ? l10n.agentModeTrusted
                              : l10n.agentModeApproval,
                          if (pairing['revoked'] == true) l10n.agentRevoke,
                        ].join(' · '),
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'mode') _switchMode(pairing);
                          if (value == 'revoke') _revoke(pairing);
                        },
                        itemBuilder: (menuContext) => [
                          PopupMenuItem(
                            value: 'mode',
                            child: Text(l10n.agentModeSwitch),
                          ),
                          PopupMenuItem(
                            value: 'revoke',
                            child: Text(l10n.agentRevoke),
                          ),
                        ],
                      ),
                    ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: FilledButton.icon(
                    onPressed: _createPairing,
                    icon: const Icon(Icons.add_link),
                    label: Text(l10n.agentCreatePairing),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    l10n.agentAccessSubtitle,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
    );
  }
}
