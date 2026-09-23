import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/crypto/ssh_key_service.dart';
import '../../../data/database/database.dart' show Folder;
import '../../../data/models/entry_fields.dart';
import '../../../data/models/entry_type.dart';
import '../../../data/models/vault_item.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../l10n/app_localizations.dart';
import '../../generator/providers/generator_provider.dart';
import '../providers/entry_item_provider.dart';
import '../providers/vault_provider.dart';
import '../widgets/custom_fields_editor.dart';
import '../widgets/entry_type_bits.dart';

/// 表单里各字段的稳定 Key。
///
/// 2.3.0 起表单顶部多了类型选择器，字段顺序随类型变化——
/// **widget test 一律按 key 找字段**，不要再依赖"第 N 个 TextFormField"
/// 这种顺序假设（旧测试就是这么写的，加类型选择器后必然失效）。
class EntryFormKeys {
  const EntryFormKeys._();

  static const Key name = Key('entry-form-name');
  static const Key url = Key('entry-form-url');
  static const Key username = Key('entry-form-username');
  static const Key password = Key('entry-form-password');
  static const Key totpSecret = Key('entry-form-totp-secret');
  static const Key notes = Key('entry-form-notes');
  static const Key folder = Key('entry-form-folder');
  static const Key favorite = Key('entry-form-favorite');
  static const Key customFields = Key('entry-form-custom-fields');
  static const Key save = Key('entry-form-save');
  static const Key delete = Key('entry-form-delete');
  static const Key notFound = Key('entry-form-not-found');

  /// 身份字段：`EntryFormKeys.identity('first_name')`。
  static Key identity(String field) => Key('entry-form-identity-$field');

  /// SSH 字段：`EntryFormKeys.ssh('public_key')`。
  static Key ssh(String field) => Key('entry-form-ssh-$field');
}

/// 新增 / 编辑条目（登录 · 安全笔记 · 身份 · SSH 密钥）。
///
/// 文件夹列表来自**共享的** `foldersProvider`（`vault_provider.dart`）。
/// 这里曾经有一份私有的 `FutureProvider`，它把首次打开表单时的文件夹列表**永久
/// 缓存**住，而且没有任何人 invalidate 它 —— 于是"添加条目时只能选到无文件夹 +
/// 第一个文件夹"（用户报的 bug）。`foldersProvider` 是 drift 的流：谁写入都会
/// 推到所有正在读它的地方，新增 / 改名 / 删除当场可见。
///
/// 数据纪律（契约 §4）：
/// - 保存只走 `repo.saveItem(VaultItem)`，**不碰** `*_encrypted` 列；
/// - 只提交当前类型对应的字段块，切换类型时先 `withoutTypeData()` 丢弃旧块；
/// - 加密失败一律冒泡成错误提示，绝不退化成写明文。
class AddEditEntryScreen extends ConsumerStatefulWidget {
  final String? entryId;

  const AddEditEntryScreen({super.key, this.entryId});

  bool get isEditing => entryId != null;

  @override
  ConsumerState<AddEditEntryScreen> createState() => _AddEditEntryScreenState();
}

class _AddEditEntryScreenState extends ConsumerState<AddEditEntryScreen> {
  final _formKey = GlobalKey<FormState>();

  // ── 通用 ──────────────────────────────────────────────
  final _nameController = TextEditingController();
  final _notesController = TextEditingController();

  // ── 登录 ──────────────────────────────────────────────
  final _urlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _totpSecretController = TextEditingController();

  // ── 身份（与 IdentityData 的字段一一对应）──────────────
  final _identityTitle = TextEditingController();
  final _identityFirstName = TextEditingController();
  final _identityMiddleName = TextEditingController();
  final _identityLastName = TextEditingController();
  final _identityUsername = TextEditingController();
  final _identityCompany = TextEditingController();
  final _identityEmail = TextEditingController();
  final _identityPhone = TextEditingController();
  final _identityIdNumber = TextEditingController();
  final _identityPassport = TextEditingController();
  final _identityLicense = TextEditingController();
  final _identityAddress1 = TextEditingController();
  final _identityAddress2 = TextEditingController();
  final _identityCity = TextEditingController();
  final _identityState = TextEditingController();
  final _identityPostalCode = TextEditingController();
  final _identityCountry = TextEditingController();
  final _identityBirthday = TextEditingController();
  final _identitySex = TextEditingController();

  // ── SSH ───────────────────────────────────────────────
  final _sshPublicKey = TextEditingController();
  final _sshPrivateKey = TextEditingController();
  final _sshPassphrase = TextEditingController();
  final _sshFingerprint = TextEditingController();
  final _sshKeyType = TextEditingController();
  final _sshBits = TextEditingController();
  final _sshComment = TextEditingController();

  /// 用户手改过的推导字段：公钥再变也不覆盖（契约 §4"允许手改"）。
  bool _sshFingerprintTouched = false;
  bool _sshKeyTypeTouched = false;
  bool _sshBitsTouched = false;
  bool _sshCommentTouched = false;

  /// 公钥文本质非空但解析不了 → 显示警告（不阻止保存）。
  bool _sshPublicKeyInvalid = false;

  /// 公钥与私钥都为空时的内联错误。
  bool _sshKeyMissing = false;

  /// 最近一次从公钥推导出的位数（用于 `sshBitsValue` 提示文案）。
  int? _derivedSshBits;

  EntryType _type = EntryType.login;

  /// 已存在的条目（编辑态 / 类型确认切换后）。新建时为 null。
  VaultItem? _baseItem;

  List<CustomField> _customFields = const [];
  String? _selectedFolderId;
  bool _obscurePassword = true;
  bool _obscurePrivateKey = true;
  bool _obscurePassphrase = true;
  bool _isFavorite = false;
  bool _isSaving = false;
  bool _isLoading = false;
  bool _notFound = false;

  /// 条目加载完成后自增：用来强制重建自定义字段编辑器（它的 `initialFields`
  /// 只在 `initState` 里读一次），否则它会保留旧的初始值。
  ///
  /// 文件夹下拉不需要它了 —— 2.3.1 起它是完全受控的（只认父层 `_selectedFolderId`）。
  int _revision = 0;

  late final List<TextEditingController> _identityControllers = [
    _identityTitle,
    _identityFirstName,
    _identityMiddleName,
    _identityLastName,
    _identityUsername,
    _identityCompany,
    _identityEmail,
    _identityPhone,
    _identityIdNumber,
    _identityPassport,
    _identityLicense,
    _identityAddress1,
    _identityAddress2,
    _identityCity,
    _identityState,
    _identityPostalCode,
    _identityCountry,
    _identityBirthday,
    _identitySex,
  ];

  late final List<TextEditingController> _sshControllers = [
    _sshPublicKey,
    _sshPrivateKey,
    _sshPassphrase,
    _sshFingerprint,
    _sshKeyType,
    _sshBits,
    _sshComment,
  ];

  late final List<TextEditingController> _allControllers = [
    _nameController,
    _notesController,
    _urlController,
    _usernameController,
    _passwordController,
    _totpSecretController,
    ..._identityControllers,
    ..._sshControllers,
  ];

  @override
  void initState() {
    super.initState();
    if (widget.isEditing) {
      _isLoading = true;
      _loadEntry();
    } else {
      // The generator provider is a session-wide singleton that only
      // generates a password once at construction. Regenerate after the first
      // frame so every new entry gets a fresh suggested password instead of
      // the same one for the whole session (it used to stay fixed until
      // restart). Deferred because mutating a provider during initState
      // (widget tree build) is not allowed by Riverpod.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(generatorProvider.notifier).generate();
        final generatedPassword = ref.read(generatorProvider).generatedPassword;
        if (generatedPassword.isNotEmpty) {
          _passwordController.text = generatedPassword;
        }
      });
    }
  }

  @override
  void dispose() {
    for (final controller in _allControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  // ─── 加载既有条目 ──────────────────────────────────────

  Future<void> _loadEntry() async {
    final item = await ref.read(entryItemProvider(widget.entryId!).future);
    if (!mounted) return;

    if (item == null) {
      setState(() {
        _isLoading = false;
        _notFound = true;
      });
      return;
    }

    setState(() {
      _baseItem = item;
      _type = item.type;
      _selectedFolderId = item.folderId;
      _isFavorite = item.isFavorite;
      _nameController.text = item.name;
      _notesController.text = item.notes;
      _customFields = item.customFields;
      _isLoading = false;
      _revision++;

      // 只填该条目自己类型的字段（其它类型的控制器保持为空）。
      switch (item.type) {
        case EntryType.login:
          final login = item.loginOrEmpty;
          _urlController.text = login.url;
          _usernameController.text = login.username;
          _passwordController.text = login.password;
          _totpSecretController.text = login.totpSecret;
        case EntryType.secureNote:
          // 安全笔记的正文就是 notes，上面已经填好。
          break;
        case EntryType.identity:
          final identity = item.identityOrEmpty;
          _identityTitle.text = identity.title;
          _identityFirstName.text = identity.firstName;
          _identityMiddleName.text = identity.middleName;
          _identityLastName.text = identity.lastName;
          _identityUsername.text = identity.username;
          _identityCompany.text = identity.company;
          _identityEmail.text = identity.email;
          _identityPhone.text = identity.phone;
          _identityIdNumber.text = identity.idNumber;
          _identityPassport.text = identity.passportNumber;
          _identityLicense.text = identity.licenseNumber;
          _identityAddress1.text = identity.address1;
          _identityAddress2.text = identity.address2;
          _identityCity.text = identity.city;
          _identityState.text = identity.state;
          _identityPostalCode.text = identity.postalCode;
          _identityCountry.text = identity.country;
          _identityBirthday.text = identity.birthday;
          _identitySex.text = identity.sex;
        case EntryType.sshKey:
          final ssh = item.sshKeyOrEmpty;
          _sshPublicKey.text = ssh.publicKey;
          _sshPrivateKey.text = ssh.privateKey;
          _sshPassphrase.text = ssh.passphrase;
          _sshFingerprint.text = ssh.fingerprint;
          _sshKeyType.text = ssh.keyType;
          _sshBits.text = ssh.bits?.toString() ?? '';
          _sshComment.text = ssh.comment;
          _derivedSshBits = ssh.bits;
      }
    });
  }

  // ─── 类型切换 ──────────────────────────────────────────

  Future<void> _onTypeSelected(EntryType next) async {
    if (next == _type) return;
    final l10n = AppLocalizations.of(context);

    // 新建时随便挑：切回去还是原来那份输入，什么都不会被丢弃。
    if (!widget.isEditing) {
      setState(() => _type = next);
      return;
    }

    final from = _baseItem?.type ?? _type;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.entryTypeSwitchTitle),
        content: Text(
          l10n.entryTypeSwitchMessage(EntryTypeBits.label(l10n, from)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.entryTypeSwitchConfirm),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      // 契约 §2：切换类型必须丢掉原类型的字段块，避免身份/SSH 数据
      // 混进别的类型。名称 / 备注 / 收藏 / 自定义字段保留。
      _baseItem = _baseItem?.withoutTypeData();
      _type = next;
      _resetTypeSpecificFields();
    });
  }

  void _resetTypeSpecificFields() {
    _urlController.clear();
    _usernameController.clear();
    _passwordController.clear();
    _totpSecretController.clear();
    for (final controller in _identityControllers) {
      controller.clear();
    }
    for (final controller in _sshControllers) {
      controller.clear();
    }
    _sshFingerprintTouched = false;
    _sshKeyTypeTouched = false;
    _sshBitsTouched = false;
    _sshCommentTouched = false;
    _sshPublicKeyInvalid = false;
    _sshKeyMissing = false;
    _derivedSshBits = null;
  }

  // ─── SSH 推导 ──────────────────────────────────────────

  /// 边输公钥边推导指纹 / 类型 / 位数 / 注释。
  ///
  /// 只填"用户没手改过"的字段；解析不了就亮警告（不阻断保存）。
  void _onPublicKeyChanged(String value) {
    final info = SshKeyService.parsePublicKey(value);
    _sshPublicKeyInvalid = value.trim().isNotEmpty && info == null;
    if (value.trim().isNotEmpty) _sshKeyMissing = false;

    if (info != null) {
      if (!_sshFingerprintTouched) {
        _sshFingerprint.text = info.fingerprintSha256;
      }
      if (!_sshKeyTypeTouched) _sshKeyType.text = info.keyType;
      if (!_sshBitsTouched) _sshBits.text = info.bits?.toString() ?? '';
      if (!_sshCommentTouched) _sshComment.text = info.comment;
      _derivedSshBits = info.bits;
    }

    if (mounted) setState(() {});
  }

  // ─── 保存 ─────────────────────────────────────────────

  VaultItem _buildItem() {
    final base = _baseItem;
    return VaultItem(
      id: base?.id ?? widget.entryId ?? const Uuid().v4(),
      // 同样按实时列表校验：文件夹在下拉里显示成"无文件夹"时，
      // 落库的也必须是 null，不能把表单打开时的旧 id 写回去。
      folderId: _folderIdIn(ref.read(foldersProvider).valueOrNull),
      type: _type,
      name: _nameController.text.trim(),
      notes: _notesController.text,
      isFavorite: _isFavorite,
      // 只给当前类型挂字段块：其它类型一律 null，
      // mapper 归一化后不会往库里写出任何"外来"数据。
      login: _type == EntryType.login
          ? LoginData(
              url: _urlController.text.trim(),
              username: _usernameController.text.trim(),
              password: _passwordController.text,
              totpSecret: _totpSecretController.text.trim(),
            )
          : null,
      identity: _type == EntryType.identity
          ? IdentityData(
              title: _identityTitle.text.trim(),
              firstName: _identityFirstName.text.trim(),
              middleName: _identityMiddleName.text.trim(),
              lastName: _identityLastName.text.trim(),
              username: _identityUsername.text.trim(),
              company: _identityCompany.text.trim(),
              email: _identityEmail.text.trim(),
              phone: _identityPhone.text.trim(),
              idNumber: _identityIdNumber.text.trim(),
              passportNumber: _identityPassport.text.trim(),
              licenseNumber: _identityLicense.text.trim(),
              address1: _identityAddress1.text.trim(),
              address2: _identityAddress2.text.trim(),
              city: _identityCity.text.trim(),
              state: _identityState.text.trim(),
              postalCode: _identityPostalCode.text.trim(),
              country: _identityCountry.text.trim(),
              birthday: _identityBirthday.text.trim(),
              sex: _identitySex.text.trim(),
            )
          : null,
      sshKey: _type == EntryType.sshKey
          ? SshKeyData(
              publicKey: _sshPublicKey.text.trim(),
              privateKey: _sshPrivateKey.text.trim(),
              // 口令不做 trim：前后空格是合法口令的一部分。
              passphrase: _sshPassphrase.text,
              fingerprint: _sshFingerprint.text.trim(),
              keyType: _sshKeyType.text.trim(),
              bits: int.tryParse(_sshBits.text.trim()),
              comment: _sshComment.text.trim(),
            )
          : null,
      customFields: _customFields,
      // createdAt / updatedAt 交给仓储规范化（0 = 现在）。
      createdAt: base?.createdAt ?? 0,
      updatedAt: base?.updatedAt ?? 0,
    );
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);

    if (!(_formKey.currentState?.validate() ?? false)) return;

    // SSH：公钥 / 私钥至少填一个（契约 §4）。
    if (_type == EntryType.sshKey &&
        _sshPublicKey.text.trim().isEmpty &&
        _sshPrivateKey.text.trim().isEmpty) {
      setState(() => _sshKeyMissing = true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.sshKeyRequired),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      await ref.read(vaultRepositoryProvider).saveItem(_buildItem());
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(widget.isEditing ? l10n.entryUpdated : l10n.entrySaved),
        ),
      );
      context.pop();
    } catch (e) {
      if (!mounted) return;
      // 加密 / 写库失败就报错，绝不退化成写明文（契约 §2）。
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.failedToSaveEntry(e.toString())),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _confirmDelete(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deleteEntryTitle),
        content: Text(l10n.deleteEntryMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () async {
              await ref
                  .read(vaultRepositoryProvider)
                  .deleteItem(widget.entryId!);
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) context.pop();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }

  // ─── 字段构造 ──────────────────────────────────────────

  Widget _field({
    required Key key,
    required TextEditingController controller,
    required String label,
    String? hint,
    IconData? icon,
    String? helperText,
    String? errorText,
    Widget? suffixIcon,
    int maxLines = 1,
    bool obscureText = false,
    bool dense = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
    ValueChanged<String>? onChanged,
  }) {
    return TextFormField(
      key: key,
      controller: controller,
      // 被遮蔽的输入框不允许 maxLines > 1（EditableText 的断言）。
      maxLines: obscureText ? 1 : maxLines,
      obscureText: obscureText,
      keyboardType: keyboardType,
      validator: validator,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helperText,
        errorText: errorText,
        isDense: dense,
        border: const OutlineInputBorder(),
        prefixIcon: icon == null ? null : Icon(icon),
        suffixIcon: suffixIcon,
      ),
    );
  }

  /// 一行两个字段（900×600 下每个仍有约 300 逻辑像素，不会溢出）。
  Widget _pair(Widget left, Widget right) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 12),
        Expanded(child: right),
      ],
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }

  Widget _identityField(
    String fieldName,
    TextEditingController controller,
    String label, {
    String? hint,
    TextInputType? keyboardType,
  }) {
    return _field(
      key: EntryFormKeys.identity(fieldName),
      controller: controller,
      label: label,
      hint: hint,
      dense: true,
      keyboardType: keyboardType,
    );
  }

  Widget _passwordField(AppLocalizations l10n) {
    return _field(
      key: EntryFormKeys.password,
      controller: _passwordController,
      label: l10n.passwordLabel,
      icon: Icons.lock,
      obscureText: _obscurePassword,
      validator: (value) {
        if (value == null || value.isEmpty) return l10n.passwordRequired;
        return null;
      },
      suffixIcon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: _obscurePassword
                ? l10n.revealPasswordTooltip
                : l10n.hidePasswordTooltip,
            icon: Icon(
              _obscurePassword ? Icons.visibility_off : Icons.visibility,
            ),
            onPressed: () =>
                setState(() => _obscurePassword = !_obscurePassword),
          ),
          IconButton(
            icon: const Icon(Icons.auto_fix_high),
            tooltip: l10n.generatePasswordTooltip,
            onPressed: () async {
              final result = await context.push<String>('/generator');
              if (result != null && mounted) {
                _passwordController.text = result;
              }
            },
          ),
        ],
      ),
    );
  }

  /// 安全笔记的正文 = 通用 `notes` 字段，这里是主输入区。
  Widget _noteBodyField(AppLocalizations l10n) {
    return _field(
      key: EntryFormKeys.notes,
      controller: _notesController,
      label: l10n.secureNoteBodyLabel,
      hint: l10n.secureNoteBodyHint,
      icon: Icons.sticky_note_2_outlined,
      maxLines: 10,
    );
  }

  Widget _buildLoginFields(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(
          key: EntryFormKeys.url,
          controller: _urlController,
          label: l10n.urlLabel,
          hint: l10n.urlHint,
          icon: Icons.link,
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 12),
        _field(
          key: EntryFormKeys.username,
          controller: _usernameController,
          label: l10n.usernameLabel,
          hint: l10n.usernameHint,
          icon: Icons.person,
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 12),
        _passwordField(l10n),
        const SizedBox(height: 12),
        _field(
          key: EntryFormKeys.totpSecret,
          controller: _totpSecretController,
          label: l10n.totpSecretLabel,
          hint: l10n.totpSecretHint,
          icon: Icons.pin,
        ),
      ],
    );
  }

  Widget _buildIdentityFields(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(l10n.identityPersonalSection),
        _pair(
          _identityField(
            'title',
            _identityTitle,
            l10n.identityTitleLabel,
            hint: l10n.identityTitleHint,
          ),
          _identityField(
            'first_name',
            _identityFirstName,
            l10n.identityFirstNameLabel,
          ),
        ),
        const SizedBox(height: 12),
        _pair(
          _identityField(
            'middle_name',
            _identityMiddleName,
            l10n.identityMiddleNameLabel,
          ),
          _identityField(
            'last_name',
            _identityLastName,
            l10n.identityLastNameLabel,
          ),
        ),
        const SizedBox(height: 12),
        _pair(
          _identityField('username', _identityUsername, l10n.usernameLabel),
          _identityField(
            'company',
            _identityCompany,
            l10n.identityCompanyLabel,
          ),
        ),
        const SizedBox(height: 12),
        _pair(
          _identityField(
            'birthday',
            _identityBirthday,
            l10n.identityBirthdayLabel,
            hint: l10n.identityBirthdayHint,
          ),
          _identityField('sex', _identitySex, l10n.identitySexLabel),
        ),
        const SizedBox(height: 20),
        _sectionHeader(l10n.identityContactSection),
        _pair(
          _identityField(
            'email',
            _identityEmail,
            l10n.identityEmailLabel,
            keyboardType: TextInputType.emailAddress,
          ),
          _identityField(
            'phone',
            _identityPhone,
            l10n.identityPhoneLabel,
            keyboardType: TextInputType.phone,
          ),
        ),
        const SizedBox(height: 20),
        _sectionHeader(l10n.identityDocumentSection),
        _pair(
          _identityField(
            'id_number',
            _identityIdNumber,
            l10n.identityIdNumberLabel,
          ),
          _identityField(
            'passport_number',
            _identityPassport,
            l10n.identityPassportLabel,
          ),
        ),
        const SizedBox(height: 12),
        _identityField(
          'license_number',
          _identityLicense,
          l10n.identityLicenseLabel,
        ),
        const SizedBox(height: 20),
        _sectionHeader(l10n.identityAddressSection),
        _pair(
          _identityField(
            'address1',
            _identityAddress1,
            l10n.identityAddress1Label,
          ),
          _identityField(
            'address2',
            _identityAddress2,
            l10n.identityAddress2Label,
          ),
        ),
        const SizedBox(height: 12),
        _pair(
          _identityField('city', _identityCity, l10n.identityCityLabel),
          _identityField('state', _identityState, l10n.identityStateLabel),
        ),
        const SizedBox(height: 12),
        _pair(
          _identityField(
            'postal_code',
            _identityPostalCode,
            l10n.identityPostalCodeLabel,
          ),
          _identityField(
            'country',
            _identityCountry,
            l10n.identityCountryLabel,
          ),
        ),
      ],
    );
  }

  Widget _buildSshFields(AppLocalizations l10n) {
    final format = SshKeyService.privateKeyFormat(_sshPrivateKey.text);
    final derivedBits = _derivedSshBits;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(l10n.sshKeySection),
        _field(
          key: EntryFormKeys.ssh('public_key'),
          controller: _sshPublicKey,
          label: l10n.sshPublicKeyLabel,
          hint: l10n.sshPublicKeyHint,
          icon: Icons.vpn_key,
          maxLines: 3,
          errorText: _sshKeyMissing ? l10n.sshKeyRequired : null,
          helperText: !_sshKeyMissing && _sshPublicKeyInvalid
              ? l10n.sshPublicKeyInvalid
              : null,
          onChanged: _onPublicKeyChanged,
        ),
        const SizedBox(height: 12),
        _field(
          key: EntryFormKeys.ssh('private_key'),
          controller: _sshPrivateKey,
          label: l10n.sshPrivateKeyLabel,
          hint: l10n.sshPrivateKeyHint,
          icon: Icons.password,
          maxLines: 6,
          obscureText: _obscurePrivateKey,
          helperText: format.isEmpty
              ? null
              : l10n.sshPrivateKeyFormatValue(format),
          suffixIcon: IconButton(
            tooltip: _obscurePrivateKey
                ? l10n.sshRevealPrivateKey
                : l10n.hidePasswordTooltip,
            icon: Icon(
              _obscurePrivateKey ? Icons.visibility_off : Icons.visibility,
            ),
            onPressed: () => setState(
              () => _obscurePrivateKey = !_obscurePrivateKey,
            ),
          ),
          onChanged: (value) {
            if (value.trim().isNotEmpty && _sshKeyMissing) {
              setState(() => _sshKeyMissing = false);
            } else {
              setState(() {});
            }
          },
        ),
        const SizedBox(height: 12),
        _field(
          key: EntryFormKeys.ssh('passphrase'),
          controller: _sshPassphrase,
          label: l10n.sshPassphraseLabel,
          icon: Icons.lock_outline,
          obscureText: _obscurePassphrase,
          suffixIcon: IconButton(
            tooltip: _obscurePassphrase
                ? l10n.revealPasswordTooltip
                : l10n.hidePasswordTooltip,
            icon: Icon(
              _obscurePassphrase ? Icons.visibility_off : Icons.visibility,
            ),
            onPressed: () => setState(
              () => _obscurePassphrase = !_obscurePassphrase,
            ),
          ),
        ),
        const SizedBox(height: 20),
        // 由公钥推导出来的展示字段，允许手改（改过就不再被覆盖）。
        _pair(
          _field(
            key: EntryFormKeys.ssh('fingerprint'),
            controller: _sshFingerprint,
            label: l10n.sshFingerprintLabel,
            hint: l10n.sshFingerprintAuto,
            helperText: _sshFingerprintTouched ? null : l10n.sshFingerprintAuto,
            dense: true,
            onChanged: (_) => _sshFingerprintTouched = true,
          ),
          _field(
            key: EntryFormKeys.ssh('key_type'),
            controller: _sshKeyType,
            label: l10n.sshKeyTypeLabel,
            dense: true,
            onChanged: (_) => _sshKeyTypeTouched = true,
          ),
        ),
        const SizedBox(height: 12),
        _pair(
          _field(
            key: EntryFormKeys.ssh('bits'),
            controller: _sshBits,
            label: l10n.sshBitsLabel,
            hint: derivedBits == null ? null : l10n.sshBitsValue(derivedBits),
            dense: true,
            keyboardType: TextInputType.number,
            onChanged: (_) => _sshBitsTouched = true,
          ),
          _field(
            key: EntryFormKeys.ssh('comment'),
            controller: _sshComment,
            label: l10n.sshCommentLabel,
            dense: true,
            onChanged: (_) => _sshCommentTouched = true,
          ),
        ),
      ],
    );
  }

  Widget _buildTypeFields(AppLocalizations l10n) {
    switch (_type) {
      case EntryType.login:
        return _buildLoginFields(l10n);
      case EntryType.secureNote:
        return _noteBodyField(l10n);
      case EntryType.identity:
        return _buildIdentityFields(l10n);
      case EntryType.sshKey:
        return _buildSshFields(l10n);
    }
  }

  /// 当前选中的文件夹 id —— 先按**实时**文件夹列表校验，再交给下拉框。
  ///
  /// 表单打开期间文件夹可能被删除 / 改名 / 整体替换（列表读的是 drift 流，
  /// 任何一处写入都会推过来）。此时若仍把这个 id 交给下拉框：
  /// - `DropdownButton` 会因为"value 不在 items 里"直接断言崩溃（红屏）；
  /// - 就算不崩，保存也会把条目挂到一个已经不存在的文件夹上。
  /// 所以解析不出来就回退成"无文件夹"。
  ///
  /// [folders] 为 null = 列表还没到（首帧）：保留原选择，
  /// 否则"页面刚打开就保存"会把文件夹静默丢掉。
  String? _folderIdIn(List<Folder>? folders) {
    final selected = _selectedFolderId;
    if (selected == null || folders == null) return selected;
    for (final folder in folders) {
      if (folder.id == selected) return selected;
    }
    return null;
  }

  /// 文件夹下拉 —— 与类型选择器同款：`InputDecorator` + **完全受控**的
  /// `DropdownButton`（不自己存状态），所以列表一变、选中项一失效，
  /// 显示立刻跟着父层状态走。
  Widget _buildFolderDropdown(AppLocalizations l10n) {
    final foldersAsync = ref.watch(foldersProvider);
    return foldersAsync.when(
      loading: () => const SizedBox.shrink(),
      // 文件夹读不出来不该挡住整个表单（表单主体是条目，不是文件夹）。
      error: (_, _) => const SizedBox.shrink(),
      data: (folders) => InputDecorator(
        decoration: InputDecoration(
          labelText: l10n.folderTitle,
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.folder),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String?>(
            key: EntryFormKeys.folder,
            value: _folderIdIn(folders),
            isExpanded: true,
            isDense: true,
            icon: const Icon(Icons.arrow_drop_down),
            items: [
              DropdownMenuItem<String?>(value: null, child: Text(l10n.noFolder)),
              for (final folder in folders)
                DropdownMenuItem<String?>(
                  value: folder.id,
                  child: Text(folder.name),
                ),
            ],
            onChanged: (value) => setState(() => _selectedFolderId = value),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    if (_notFound) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.editEntryTitle)),
        body: Center(
          key: EntryFormKeys.notFound,
          child: Text(l10n.entryNotFound),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? l10n.editEntryTitle : l10n.addEntryTitle),
        actions: [
          if (widget.isEditing)
            IconButton(
              key: EntryFormKeys.delete,
              icon: const Icon(Icons.delete),
              onPressed: () => _confirmDelete(context),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: _isLoading
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 类型选择器现在是**下拉**（2.3.1）：外观与其它字段同款
                        // （OutlineInputBorder + label + 彩色前缀图标），所以这里
                        // 用普通的分区间距，不再需要原来给"四张卡片"留的 20。
                        EntryTypeSelector(
                          value: _type,
                          onChanged: _onTypeSelected,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          key: EntryFormKeys.name,
                          controller: _nameController,
                          decoration: InputDecoration(
                            labelText: l10n.nameLabel,
                            hintText: l10n.nameHint,
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.label),
                          ),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return l10n.nameRequired;
                            }
                            return null;
                          },
                          autofocus: !widget.isEditing,
                        ),
                        const SizedBox(height: 12),
                        _buildTypeFields(l10n),
                        const SizedBox(height: 16),
                        // 完全受控，不再需要 KeyedSubtree 去"重挂"它。
                        _buildFolderDropdown(l10n),
                        if (_type != EntryType.secureNote) ...[
                          const SizedBox(height: 12),
                          _field(
                            key: EntryFormKeys.notes,
                            controller: _notesController,
                            label: l10n.notesLabel,
                            hint: l10n.notesHint,
                            icon: Icons.note,
                            maxLines: 3,
                          ),
                        ],
                        const SizedBox(height: 16),
                        SwitchListTile(
                          key: EntryFormKeys.favorite,
                          title: Text(l10n.favorite),
                          subtitle: Text(l10n.favoriteSubtitle),
                          value: _isFavorite,
                          onChanged: (value) =>
                              setState(() => _isFavorite = value),
                        ),
                        const SizedBox(height: 8),
                        KeyedSubtree(
                          key: ValueKey('entry-form-custom-fields-$_revision'),
                          child: CustomFieldsEditor(
                            key: EntryFormKeys.customFields,
                            initialFields: _customFields,
                            onChanged: (fields) => _customFields = fields,
                          ),
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          height: 48,
                          child: FilledButton.icon(
                            key: EntryFormKeys.save,
                            onPressed: _isSaving ? null : _save,
                            icon: _isSaving
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Icon(
                                    widget.isEditing ? Icons.save : Icons.add,
                                  ),
                            label: Text(
                              widget.isEditing ? l10n.saveChanges : l10n.create,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
