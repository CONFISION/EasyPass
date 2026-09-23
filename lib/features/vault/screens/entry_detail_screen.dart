import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/crypto/ssh_key_service.dart';
import '../../../core/crypto/totp_service.dart';
import '../../../data/models/entry_fields.dart';
import '../../../data/models/entry_type.dart';
import '../../../data/models/vault_item.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../l10n/app_localizations.dart';
import '../providers/entry_item_provider.dart';
import '../widgets/custom_fields_view.dart';
import '../widgets/entry_type_bits.dart';

/// 条目详情页（四种类型共用一页）。
///
/// 字段分工见 `docs/entry-types.md` §4「详情页」：
/// - login：用户名 · 密码（验证主密码后显示） · 网址 · **TOTP 动态码 + 倒计时**；
/// - secure_note：正文（可选文字、可复制）；
/// - identity：按 个人 / 联系方式 / 证件 / 地址 分组展示非空字段；
/// - ssh_key：公钥 · 私钥（验证后显示） · 口令 · 指纹 · 类型 / 长度 / 注释 / 格式；
/// - 所有类型：备注（若有） · 自定义字段（若有） · 收藏开关。
///
/// 安全纪律：
/// - 密码与 SSH 私钥默认打码，**必须**通过主密码验证才显示，显示后 1 分钟自动隐藏；
/// - TOTP 只显示 6 位动态码与倒计时，**永不**把原始密钥当普通字段渲染；
/// - 复制只发生在用户显式点击之后，且机密值未显示时同样要求先验证主密码。
///
/// 数据来源：[entryItemProvider]（`VaultRepository.getItem`）——详情页不再自己
/// 解密 `*_encrypted` 列，[VaultItem] 交到 UI 时已经是明文。
class EntryDetailScreen extends ConsumerWidget {
  final String entryId;

  const EntryDetailScreen({super.key, required this.entryId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entryAsync = ref.watch(entryItemProvider(entryId));
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.entryDetailsTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: l10n.editEntryTitle,
            onPressed: () => context.push('/vault/edit/$entryId'),
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: l10n.delete,
            onPressed: () => _confirmDelete(context, ref),
          ),
        ],
      ),
      body: entryAsync.when(
        // 刷新期间继续显示上一份数据，**绝不**退回进度圈：
        // entryItemProvider 是 drift 单行查询的流，写入即推送；只有依赖被重建
        // （例如重新解锁）时才会先来一个带 previous 的 AsyncLoading，这里必须
        // 把它当数据渲染，否则每次刷新整页都会闪一下加载态。
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(child: Text(l10n.failedToLoadEntry)),
        data: (entry) {
          if (entry == null) {
            return Center(child: Text(l10n.entryNotFound));
          }
          return _EntryDetailBody(entry: entry);
        },
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // 先把 repository 取出来：弹窗回调里 await 之后不再碰 ref。
    final repository = ref.read(vaultRepositoryProvider);

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deleteEntryTitle),
        content: Text(l10n.deleteEntryDetailMessage),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(l10n.cancel)),
          FilledButton(
            onPressed: () async {
              await repository.deleteItem(entryId);
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              if (context.mounted) Navigator.pop(context);
            },
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }
}

// ─── 页面主体 ────────────────────────────────────────────

class _EntryDetailBody extends ConsumerWidget {
  const _EntryDetailBody({required this.entry});

  final VaultItem entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context),
              const SizedBox(height: 20),
              ..._buildTypeSections(context),
              // 安全笔记的正文就是 notes，已经在上面的类型区块里渲染过了。
              if (entry.type != EntryType.secureNote &&
                  entry.notes.trim().isNotEmpty)
                _FieldCard(
                  label: l10n.notesLabel,
                  text: entry.notes,
                  multiline: true,
                  onCopy: () => _copyToClipboard(context, entry.notes),
                ),
              if (entry.effectiveCustomFields.isNotEmpty)
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: CustomFieldsView(
                      fields: entry.effectiveCustomFields,
                      onCopy: (value) => _copyToClipboard(context, value),
                    ),
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.favorite),
                subtitle: Text(l10n.favoriteSubtitle),
                value: entry.isFavorite,
                onChanged: (value) => _toggleFavorite(context, ref, value),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 标题行：条目名 + 类型徽章（名称过长时省略，不撑破最小窗口）。
  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            entry.name,
            style: theme.textTheme.headlineSmall,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        EntryTypeBits.badge(context, entry.type),
      ],
    );
  }

  List<Widget> _buildTypeSections(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    switch (entry.type) {
      case EntryType.login:
        final login = entry.loginOrEmpty;
        return [
          _FieldCard(
            label: l10n.username,
            text: login.username,
            emptyText: l10n.none,
            onCopy: () => _copyToClipboard(context, login.username),
          ),
          _SecretCard(
            label: l10n.passwordField,
            secret: login.password,
            revealTooltip: l10n.revealPasswordTooltip,
            copyTooltip: l10n.copyPasswordTooltip,
            emptyText: l10n.none,
          ),
          _FieldCard(
            label: l10n.urlLabel,
            text: login.url,
            emptyText: l10n.none,
            onCopy: () => _copyToClipboard(context, login.url),
          ),
          _TotpCard(secret: login.totpSecret),
        ];

      case EntryType.secureNote:
        return [
          _FieldCard(
            label: l10n.secureNoteBodyLabel,
            text: entry.notes,
            emptyText: l10n.none,
            multiline: true,
            onCopy: () => _copyToClipboard(context, entry.notes),
          ),
        ];

      case EntryType.identity:
        return _identitySections(context);

      case EntryType.sshKey:
        return _sshSections(context);
    }
  }

  // ─── identity ─────────────────────────────────────────

  /// 四个分组按顺序渲染；**空分组整块不渲染**（不留空标题）。
  List<Widget> _identitySections(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final data = entry.identityOrEmpty;

    return [
      ..._group(context, l10n.identityPersonalSection, [
        (l10n.identityTitleLabel, data.title),
        (l10n.identityFirstNameLabel, data.firstName),
        (l10n.identityMiddleNameLabel, data.middleName),
        (l10n.identityLastNameLabel, data.lastName),
        (l10n.usernameLabel, data.username),
        (l10n.identityCompanyLabel, data.company),
        (l10n.identityBirthdayLabel, data.birthday),
        (l10n.identitySexLabel, data.sex),
      ]),
      ..._group(context, l10n.identityContactSection, [
        (l10n.identityEmailLabel, data.email),
        (l10n.identityPhoneLabel, data.phone),
      ]),
      ..._group(context, l10n.identityDocumentSection, [
        (l10n.identityIdNumberLabel, data.idNumber),
        (l10n.identityPassportLabel, data.passportNumber),
        (l10n.identityLicenseLabel, data.licenseNumber),
      ]),
      ..._group(context, l10n.identityAddressSection, [
        (l10n.identityAddress1Label, data.address1),
        (l10n.identityAddress2Label, data.address2),
        (l10n.identityCityLabel, data.city),
        (l10n.identityStateLabel, data.state),
        (l10n.identityPostalCodeLabel, data.postalCode),
        (l10n.identityCountryLabel, data.country),
      ]),
    ];
  }

  List<Widget> _group(
    BuildContext context,
    String title,
    List<(String, String)> rows,
  ) {
    final visible = rows.where((row) => row.$2.trim().isNotEmpty).toList();
    if (visible.isEmpty) return const [];

    return [
      _SectionHeader(title: title),
      for (final (label, value) in visible)
        _FieldCard(
          label: label,
          text: value,
          onCopy: () => _copyToClipboard(context, value),
        ),
    ];
  }

  // ─── ssh_key ──────────────────────────────────────────

  List<Widget> _sshSections(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final data = entry.sshKeyOrEmpty;
    // 由私钥内容识别格式（OpenSSH / PEM / PPK…），识别不出就不显示这一行。
    final format = SshKeyService.privateKeyFormat(data.privateKey);

    return [
      _SectionHeader(title: l10n.sshKeySection),
      _FieldCard(
        label: l10n.sshPublicKeyLabel,
        text: data.publicKey,
        emptyText: l10n.none,
        monospace: true,
        multiline: true,
        onCopy: () => _copyToClipboard(context, data.publicKey),
      ),
      _SecretCard(
        label: l10n.sshPrivateKeyLabel,
        secret: data.privateKey,
        revealTooltip: l10n.sshRevealPrivateKey,
        copyTooltip: l10n.copyFieldTooltip(l10n.sshPrivateKeyLabel),
        emptyText: l10n.sshNoPrivateKey,
        multiline: true,
      ),
      // 口令：没有就不渲染（它是"可选机密"，不是布局里固定的一行）。
      if (data.passphrase.trim().isNotEmpty)
        _SecretCard(
          label: l10n.sshPassphraseLabel,
          secret: data.passphrase,
          revealTooltip: l10n.revealPasswordTooltip,
          copyTooltip: l10n.copyFieldTooltip(l10n.sshPassphraseLabel),
        ),
      if (_hasSshDetails(data, format)) ...[
        _SectionHeader(title: l10n.detailsSection),
        if (data.fingerprint.trim().isNotEmpty)
          _FieldCard(
            label: l10n.sshFingerprintLabel,
            text: data.fingerprint,
            monospace: true,
            onCopy: () => _copyToClipboard(context, data.fingerprint),
          ),
        if (data.keyType.trim().isNotEmpty)
          _FieldCard(
            label: l10n.sshKeyTypeLabel,
            text: data.keyType,
            monospace: true,
            onCopy: () => _copyToClipboard(context, data.keyType),
          ),
        if (data.bits != null)
          _FieldCard(
            label: l10n.sshBitsLabel,
            text: l10n.sshBitsValue(data.bits!),
          ),
        if (data.comment.trim().isNotEmpty)
          _FieldCard(
            label: l10n.sshCommentLabel,
            text: data.comment,
            onCopy: () => _copyToClipboard(context, data.comment),
          ),
        if (format.isNotEmpty)
          _FieldCard(
            label: l10n.sshPrivateKeyFormatLabel,
            text: format,
            monospace: true,
          ),
      ],
    ];
  }

  bool _hasSshDetails(SshKeyData data, String format) =>
      data.fingerprint.trim().isNotEmpty ||
      data.keyType.trim().isNotEmpty ||
      data.bits != null ||
      data.comment.trim().isNotEmpty ||
      format.isNotEmpty;

  // ─── 通用动作 ─────────────────────────────────────────

  /// 显式用户动作触发的复制；空值不复制，也不弹提示。
  void _copyToClipboard(BuildContext context, String value) {
    if (value.trim().isEmpty) return;
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).fieldCopied)),
    );
  }

  /// 收藏走 `repo.saveItem(item.copyWith(...))`（契约 §3：UI 不许自己拼
  /// companion）。
  ///
  /// **不需要任何手动失效**：[entryItemProvider] 监听的是 drift 的单行查询
  /// （`repository.watchItem`），这次写入落库后流会自己推新值；旧代码在这里
  /// `ref.invalidate(entryItemProvider(...))` 既多余，又会让整页闪一次加载态。
  Future<void> _toggleFavorite(
    BuildContext context,
    WidgetRef ref,
    bool value,
  ) async {
    final l10n = AppLocalizations.of(context);
    final repository = ref.read(vaultRepositoryProvider);
    try {
      await repository.saveItem(entry.copyWith(isFavorite: value));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.failedWithError('$error'))),
      );
    }
  }
}

// ─── 通用卡片 ────────────────────────────────────────────

/// 详情卡片外壳：标签（+ 可选后缀徽章）在上，值在左、动作按钮在右。
///
/// 所有 [Text] 都在 [Flexible]/[Expanded] 里，长值走省略号 —— 900×600
/// 是原生最小窗口，任何一行都不允许溢出（踩过的坑见 AGENTS.md）。
Widget _detailCard(
  BuildContext context, {
  required String label,
  required Widget value,
  Widget? labelSuffix,
  List<Widget> actions = const [],
}) {
  final theme = Theme.of(context);
  return Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  label,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (labelSuffix != null) ...[
                const SizedBox(width: 8),
                Flexible(child: labelSuffix),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: value),
              ...actions,
            ],
          ),
        ],
      ),
    ),
  );
}

/// 分组标题（identity 的四个分组 / ssh_key 的"密钥材料 + 详情"）。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

/// 只读字段卡片：单行省略；[multiline] 时是可选择的多行文本块。
class _FieldCard extends StatelessWidget {
  const _FieldCard({
    required this.label,
    required this.text,
    this.emptyText,
    this.monospace = false,
    this.multiline = false,
    this.onCopy,
  });

  final String label;
  final String text;

  /// 值为空时展示的文案（登录 / 身份这类布局里固定存在的行用 `none`）。
  final String? emptyText;
  final bool monospace;
  final bool multiline;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isEmpty = text.trim().isEmpty;
    final display = isEmpty ? (emptyText ?? '') : text;

    final style = theme.textTheme.bodyLarge?.copyWith(
      fontFamily: monospace ? 'monospace' : null,
      color: isEmpty ? theme.colorScheme.onSurfaceVariant : null,
      fontStyle: isEmpty ? FontStyle.italic : null,
    );

    // 空值给纯 Text（斜体提示），有值且多行时给可选择文本块。
    final Widget value = (multiline && !isEmpty)
        ? SelectableText(display, style: style)
        : Text(
            display,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );

    return _detailCard(
      context,
      label: label,
      value: value,
      actions: [
        if (onCopy != null && !isEmpty)
          IconButton(
            icon: const Icon(Icons.copy, size: 20),
            tooltip: l10n.copyFieldTooltip(label),
            onPressed: onCopy,
          ),
      ],
    );
  }
}

// ─── 机密字段（密码 / SSH 私钥 / 口令）────────────────────

/// 打码的机密字段：默认只显示圆点，点眼睛需先验证主密码，显示后 1 分钟自动隐藏。
///
/// 明文来自内存里的 [VaultItem]（已解密），本组件只负责"显示 / 隐藏"，
/// 不做任何解密，也不把明文写进日志或剪贴板以外的任何地方。
class _SecretCard extends StatefulWidget {
  const _SecretCard({
    required this.label,
    required this.secret,
    required this.revealTooltip,
    required this.copyTooltip,
    this.emptyText,
    this.multiline = false,
  });

  final String label;
  final String secret;
  final String revealTooltip;
  final String copyTooltip;

  /// 没有机密可显示时的文案（如 `sshNoPrivateKey`）。
  final String? emptyText;

  /// 私钥这类多行材料：显示后按多行可选中文本块渲染。
  final bool multiline;

  @override
  State<_SecretCard> createState() => _SecretCardState();
}

class _SecretCardState extends State<_SecretCard> {
  static const String _mask = '••••••••••••';

  bool _revealed = false;
  Timer? _hideTimer;

  bool get _hasValue => widget.secret.trim().isNotEmpty;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _reveal() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(minutes: 1), () {
      if (mounted) setState(() => _revealed = false);
    });
    setState(() => _revealed = true);
  }

  void _hide() {
    _hideTimer?.cancel();
    setState(() => _revealed = false);
  }

  /// 主密码验证弹窗；通过返回 true。
  Future<bool> _verifyMasterPassword() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const _MasterPasswordDialog(),
    );
    return ok ?? false;
  }

  Future<void> _onRevealPressed() async {
    if (!_hasValue) return;
    if (_revealed) {
      _hide();
      return;
    }
    if (await _verifyMasterPassword() && mounted) _reveal();
  }

  Future<void> _onCopyPressed() async {
    if (!_hasValue) return;
    // 复制机密与显示机密同级：没显示过就先验证主密码。
    if (!_revealed && !await _verifyMasterPassword()) return;
    if (!mounted) return;
    await Clipboard.setData(ClipboardData(text: widget.secret));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).fieldCopied)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    final String display;
    if (!_hasValue) {
      display = widget.emptyText ?? l10n.none;
    } else if (_revealed) {
      display = widget.secret;
    } else {
      display = _mask;
    }

    final style = theme.textTheme.bodyLarge?.copyWith(
      fontFamily: 'monospace',
      color: !_hasValue ? theme.colorScheme.onSurfaceVariant : null,
      fontStyle: !_hasValue ? FontStyle.italic : null,
    );

    final Widget value = (_revealed && widget.multiline)
        ? SelectableText(display, style: style)
        : Text(
            display,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );

    return _detailCard(
      context,
      label: widget.label,
      labelSuffix: _revealed ? _VisibleChip(text: l10n.visibleAutoHide) : null,
      value: value,
      actions: [
        if (_hasValue)
          IconButton(
            icon: const Icon(Icons.copy, size: 20),
            tooltip: widget.copyTooltip,
            onPressed: _onCopyPressed,
          ),
        if (_hasValue)
          IconButton(
            icon: Icon(
              _revealed ? Icons.visibility_off : Icons.visibility,
              size: 20,
            ),
            tooltip: _revealed ? l10n.hidePasswordTooltip : widget.revealTooltip,
            onPressed: _onRevealPressed,
          ),
      ],
    );
  }
}

/// "可见 · 1 分钟后自动隐藏"提示条（只在机密已显示时出现）。
class _VisibleChip extends StatelessWidget {
  const _VisibleChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.orange.withAlpha(50),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.orange.withAlpha(100)),
      ),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: Colors.orange, fontSize: 10),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// 显示机密前的主密码验证弹窗（沿用既有安全流程，只把错误提示改为表单内联）。
class _MasterPasswordDialog extends ConsumerStatefulWidget {
  const _MasterPasswordDialog();

  @override
  ConsumerState<_MasterPasswordDialog> createState() =>
      _MasterPasswordDialogState();
}

class _MasterPasswordDialogState extends ConsumerState<_MasterPasswordDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _checking = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final l10n = AppLocalizations.of(context);
    final password = _controller.text;
    if (password.isEmpty || _checking) return;

    setState(() {
      _checking = true;
      _error = null;
    });

    final crypto = ref.read(cryptoServiceProvider);
    final salt = await crypto.getStoredSalt();
    final hash = await crypto.getStoredPasswordHash();
    if (!mounted) return;

    if (salt == null || hash == null) {
      setState(() {
        _checking = false;
        _error = l10n.noMasterPasswordConfigured;
      });
      return;
    }

    if (crypto.hashMasterPassword(password, salt) == hash) {
      Navigator.pop(context, true);
      return;
    }

    setState(() {
      _checking = false;
      _error = l10n.errorIncorrectMasterPassword;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.verifyMasterPasswordTitle),
      content: TextField(
        controller: _controller,
        obscureText: true,
        autofocus: true,
        enabled: !_checking,
        decoration: InputDecoration(
          labelText: l10n.masterPasswordLabel,
          errorText: _error,
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.key),
        ),
        onSubmitted: (_) => _verify(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _checking ? null : _verify,
          child: Text(l10n.verify),
        ),
      ],
    );
  }
}

// ─── TOTP 动态码 ─────────────────────────────────────────

/// 登录条目的 TOTP：6 位动态码 + 剩余秒数 + 复制。
///
/// 每秒重算一次：周期（30s）翻转时 `generateTotp` 自然产出新码。
/// **原始密钥永远不出现在界面上**（只显示动态码），没有密钥时显示 `totpNotSet`。
class _TotpCard extends StatefulWidget {
  const _TotpCard({required this.secret});

  final String secret;

  @override
  State<_TotpCard> createState() => _TotpCardState();
}

class _TotpCardState extends State<_TotpCard> {
  static const int _period = 30;

  Timer? _timer;
  String _code = '';
  int _remaining = _period;

  bool get _hasSecret => widget.secret.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_hasSecret) {
      _recompute();
      _startTimer();
    }
  }

  @override
  void didUpdateWidget(_TotpCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.secret == widget.secret) return;
    _timer?.cancel();
    _timer = null;
    if (_hasSecret) {
      _recompute();
      _startTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    setState(_recompute);
  }

  void _recompute() {
    final service = TotpService();
    _code = service.generateTotp(widget.secret, period: _period);
    _remaining = service.getRemainingSeconds(period: _period);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    if (!_hasSecret) {
      return _detailCard(
        context,
        label: l10n.totpCodeLabel,
        value: Text(
          l10n.totpNotSet,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    return _detailCard(
      context,
      label: l10n.totpCodeLabel,
      value: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pin,
                  size: 20, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _code,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontFamily: 'monospace',
                    letterSpacing: 4,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 56,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: _remaining / _period,
                    minHeight: 4,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.totpRefreshesIn(_remaining),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.copy, size: 20),
          tooltip: l10n.totpCopyTooltip,
          onPressed: () {
            Clipboard.setData(ClipboardData(text: _code));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.fieldCopied)),
            );
          },
        ),
      ],
    );
  }
}
