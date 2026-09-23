// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'EasyPass';

  @override
  String get none => '无';

  @override
  String get masterPasswordLabel => '主密码';

  @override
  String get masterPasswordHint => '至少 8 个字符';

  @override
  String get confirmMasterPasswordLabel => '确认主密码';

  @override
  String get unlock => '解锁';

  @override
  String get unlockScreenSubtitle => '输入主密码以解锁';

  @override
  String get welcomeTitle => '欢迎使用 EasyPass';

  @override
  String get setPasswordSubtitle => '设置主密码以开始使用。\n此密码将加密您的所有数据。';

  @override
  String get setMasterPassword => '设置主密码';

  @override
  String get securityNote => '重要提示：主密码无法找回，请妥善保管！';

  @override
  String get errorPasswordsDoNotMatch => '两次输入的密码不一致';

  @override
  String get errorPasswordTooShort => '主密码至少需要 8 个字符';

  @override
  String get errorNoMasterPassword => '未配置主密码';

  @override
  String get errorIncorrectMasterPassword => '主密码错误';

  @override
  String get errorVaultLocked => '保险库已锁定';

  @override
  String get errorFailedToSave => '保存主密码失败';

  @override
  String get errorFailedToChange => '修改主密码失败';

  @override
  String get errorCurrentPasswordIncorrect => '当前主密码错误';

  @override
  String get errorUnlockFailed => '解锁保险库时出错';

  @override
  String get favoritesTitle => '收藏';

  @override
  String get folderTitle => '文件夹';

  @override
  String get searchTooltip => '搜索';

  @override
  String get generatorTooltip => '密码生成器';

  @override
  String get passwordGenerator => '密码生成器';

  @override
  String get lockTooltip => '锁定保险库';

  @override
  String get settings => '设置';

  @override
  String failedToLoadVault(String error) {
    return '加载保险库失败：$error';
  }

  @override
  String get retry => '重试';

  @override
  String get emptyVaultTitle => '保险库为空';

  @override
  String get emptyVaultHint => '点击 + 添加您的第一个密码';

  @override
  String get add => '添加';

  @override
  String get passwordCopied => '密码已复制到剪贴板';

  @override
  String get allItems => '全部条目';

  @override
  String get favorites => '收藏';

  @override
  String get foldersSection => '文件夹';

  @override
  String get newFolder => '新建文件夹';

  @override
  String get folderNameLabel => '文件夹名称';

  @override
  String get folderNameHint => '例如：工作、个人';

  @override
  String get cancel => '取消';

  @override
  String get create => '创建';

  @override
  String get deleteFolderTitle => '删除文件夹';

  @override
  String deleteFolderMessage(String name) {
    return '删除“$name”？其中的条目将移至“无文件夹”。此操作无法撤销。';
  }

  @override
  String folderDeleted(String name) {
    return '文件夹“$name”已删除';
  }

  @override
  String get folderActions => '文件夹操作';

  @override
  String deleteFolderNotEmptyMessage(String name, int count) {
    return '删除“$name”？里面还有 $count 个条目。**这些条目不会被删除**，它们会被移到“无文件夹”。此操作无法撤销。';
  }

  @override
  String get deleteFolderKeepEntries => '删除文件夹（保留条目）';

  @override
  String get delete => '删除';

  @override
  String get searchFailed => '搜索失败';

  @override
  String get noResultsFound => '未找到结果';

  @override
  String get editEntryTitle => '编辑条目';

  @override
  String get addEntryTitle => '添加条目';

  @override
  String get nameLabel => '名称 *';

  @override
  String get nameHint => '例如：Google、GitHub';

  @override
  String get nameRequired => '名称必填';

  @override
  String get urlLabel => '网址';

  @override
  String get urlHint => '例如：https://example.com';

  @override
  String get usernameLabel => '用户名 / 邮箱';

  @override
  String get usernameHint => '例如：user@example.com';

  @override
  String get passwordLabel => '密码 *';

  @override
  String get generatePasswordTooltip => '生成密码';

  @override
  String get totpSecretLabel => 'TOTP 密钥（两步验证）';

  @override
  String get totpSecretHint => '身份验证器的 Base32 密钥';

  @override
  String get noFolder => '无文件夹';

  @override
  String get notesLabel => '备注';

  @override
  String get notesHint => '附加备注...';

  @override
  String get favorite => '收藏';

  @override
  String get favoriteSubtitle => '将此条目标记为收藏';

  @override
  String get saveChanges => '保存更改';

  @override
  String get passwordRequired => '密码必填';

  @override
  String get entryUpdated => '条目已更新';

  @override
  String get entrySaved => '条目已保存';

  @override
  String failedToSaveEntry(String error) {
    return '保存失败：$error';
  }

  @override
  String get deleteEntryTitle => '删除条目';

  @override
  String get deleteEntryMessage => '确定要删除吗？此操作无法撤销。';

  @override
  String get deleteEntryDetailMessage => '确定要删除此条目吗？此操作无法撤销。';

  @override
  String get entryDetailsTitle => '条目详情';

  @override
  String get failedToLoadEntry => '加载条目失败';

  @override
  String get entryNotFound => '未找到条目';

  @override
  String get username => '用户名';

  @override
  String get usernameCopied => '用户名已复制';

  @override
  String get passwordField => '密码';

  @override
  String get visibleAutoHide => '可见 • 1 分钟后自动隐藏';

  @override
  String get passwordCopiedShort => '密码已复制';

  @override
  String get revealPasswordTooltip => '显示密码';

  @override
  String get hidePasswordTooltip => '隐藏密码';

  @override
  String get copyPasswordTooltip => '复制密码';

  @override
  String get urlCopied => '网址已复制';

  @override
  String copyFieldTooltip(String label) {
    return '复制$label';
  }

  @override
  String get verifyMasterPasswordTitle => '验证主密码';

  @override
  String get verify => '验证';

  @override
  String get noMasterPasswordConfigured => '未配置主密码';

  @override
  String get selectOptionsBelow => '请在下方选择选项';

  @override
  String charactersCount(int count) {
    return '$count 个字符';
  }

  @override
  String get copy => '复制';

  @override
  String get regenerate => '重新生成';

  @override
  String get passwordCopiedExcl => '密码已复制！';

  @override
  String get useThisPassword => '使用此密码';

  @override
  String lengthLabel(int length) {
    return '长度：$length';
  }

  @override
  String get uppercase => '大写字母（A-Z）';

  @override
  String get uppercaseSubtitle => '包含大写字母';

  @override
  String get lowercase => '小写字母（a-z）';

  @override
  String get lowercaseSubtitle => '包含小写字母';

  @override
  String get numbers => '数字（0-9）';

  @override
  String get numbersSubtitle => '包含数字';

  @override
  String get symbols => '符号（!@#\$...）';

  @override
  String get symbolsSubtitle => '包含特殊字符';

  @override
  String get settingsTitle => '设置';

  @override
  String get securitySection => '安全';

  @override
  String get changeMasterPassword => '修改主密码';

  @override
  String get changeMasterPasswordSubtitle => '使用新密钥重新加密所有条目';

  @override
  String get autoLockTimeout => '自动锁定超时';

  @override
  String autoLockMinutesValue(int minutes) {
    return '$minutes 分钟';
  }

  @override
  String get biometricUnlock => '生物识别解锁';

  @override
  String get biometricUnlockSubtitle => '使用指纹解锁';

  @override
  String get biometricComingSoon => '生物识别解锁将在未来更新中提供';

  @override
  String get dataSection => '数据';

  @override
  String get exportVault => '导出保险库';

  @override
  String get exportVaultSubtitle => '加密备份或纯 JSON';

  @override
  String get importVault => '导入保险库';

  @override
  String get importVaultSubtitle => '从备份或 JSON 文件恢复';

  @override
  String get dangerZoneSection => '危险区域';

  @override
  String get deleteAllData => '删除所有数据';

  @override
  String get deleteAllDataSubtitle => '此操作无法撤销';

  @override
  String get aboutSection => '关于';

  @override
  String get version => '版本';

  @override
  String get appInfo => '安全的密码管理器';

  @override
  String get languageSection => '语言';

  @override
  String get language => '语言';

  @override
  String get followSystem => '跟随系统';

  @override
  String get languageChinese => '中文';

  @override
  String get languageEnglish => 'English';

  @override
  String get appearanceSection => '外观';

  @override
  String get theme => '主题';

  @override
  String get themeComingSoon => '主题自定义将在未来更新中提供';

  @override
  String get font => '字体';

  @override
  String get fontDefault => '默认（Maple Mono NF CN）';

  @override
  String get fontSystem => '系统默认';

  @override
  String get fontMonospace => '等宽';

  @override
  String get fontAssetSection => '软件字体';

  @override
  String get fontSystemSection => '系统字体';

  @override
  String get fontSearchHint => '搜索字体...';

  @override
  String get fontNoResults => '未找到字体';

  @override
  String get fontApplied => '字体已更新';

  @override
  String get ok => '确定';

  @override
  String get exportDialogTitle => '导出保险库';

  @override
  String get encryptedBackup => '加密备份（推荐）';

  @override
  String get encryptedBackupDesc => '由主密钥加密保护';

  @override
  String get plainJson => '纯 JSON';

  @override
  String get plainJsonDesc => '解密文本 — 请妥善保管';

  @override
  String get saveEncryptedBackupDialog => '保存加密备份';

  @override
  String get savePlainExportDialog => '保存明文导出';

  @override
  String vaultExportedTo(String path) {
    return '保险库已导出至 $path';
  }

  @override
  String exportFailed(String error) {
    return '导出失败：$error';
  }

  @override
  String get importDialogTitle => '导入保险库';

  @override
  String get importDialogMessage => '导入会将备份文件中的所有条目添加到当前保险库。现有条目不会被覆盖。是否继续？';

  @override
  String get import => '导入';

  @override
  String importedCounts(int entries, int folders) {
    return '已导入 $entries 个条目和 $folders 个文件夹';
  }

  @override
  String importFailed(String error) {
    return '导入失败：$error';
  }

  @override
  String get currentMasterPasswordLabel => '当前主密码';

  @override
  String get newMasterPasswordLabel => '新主密码';

  @override
  String get confirmNewPasswordLabel => '确认新主密码';

  @override
  String get change => '修改';

  @override
  String get masterPasswordChanged => '主密码已修改';

  @override
  String failedWithError(String error) {
    return '失败：$error';
  }

  @override
  String autoLockSet(String value) {
    return '自动锁定已设为 $value';
  }

  @override
  String get deleteAllDataTitle => '删除所有数据？';

  @override
  String get deleteAllDataMessage => '这将永久删除所有已保存的密码和数据。此操作无法撤销。';

  @override
  String get deleteAll => '全部删除';

  @override
  String get allDataDeleted => '所有数据已删除';

  @override
  String get healthReport => '密码健康报告';

  @override
  String get healthScore => '健康评分';

  @override
  String get healthGood => '良好';

  @override
  String get healthFair => '一般';

  @override
  String get healthPoor => '危险';

  @override
  String get healthWeakPasswords => '弱密码';

  @override
  String get healthReusedPasswords => '重复使用的密码';

  @override
  String get healthNoTotp => '缺少两步验证';

  @override
  String get healthNoUrl => '缺少网址';

  @override
  String get healthAllHealthy => '一切正常！未发现健康问题。';

  @override
  String get healthTotalEntries => '个条目';

  @override
  String get healthTapToView => '点击条目查看详情';

  @override
  String get healthWeakTooShort => '密码过短（少于 12 个字符）';

  @override
  String get healthWeakSingleType => '密码仅使用单一字符类型';

  @override
  String get healthWeakCommonPassword => '密码属于常见弱密码';

  @override
  String healthReusedShared(int count) {
    return '被 $count 个条目共用';
  }

  @override
  String get healthNoTotpReason => '未启用两步验证';

  @override
  String get healthNoUrlReason => '未填写网站网址';

  @override
  String healthLoadFailed(String error) {
    return '加载健康报告失败：$error';
  }

  @override
  String get entryTypeLabel => '类型';

  @override
  String get entryTypeLogin => '登录';

  @override
  String get entryTypeSecureNote => '安全笔记';

  @override
  String get entryTypeIdentity => '身份信息';

  @override
  String get entryTypeSshKey => 'SSH 密钥';

  @override
  String get entryTypeAll => '全部类型';

  @override
  String get entryTypeLoginDesc => '用户名、密码、网址与两步验证';

  @override
  String get entryTypeSecureNoteDesc => '自由文本，加密保存';

  @override
  String get entryTypeIdentityDesc => '姓名、证件号、联系方式与地址';

  @override
  String get entryTypeSshKeyDesc => '公钥、私钥与指纹';

  @override
  String get entryTypeFilterTooltip => '按类型筛选';

  @override
  String get entryTypeSwitchTitle => '切换条目类型？';

  @override
  String entryTypeSwitchMessage(String from) {
    return '「$from」类型的字段会被丢弃，名称、备注与自定义字段会保留。';
  }

  @override
  String get entryTypeSwitchConfirm => '切换';

  @override
  String entryTypeEmptyForType(String type) {
    return '还没有$type条目';
  }

  @override
  String get customFieldsSection => '自定义字段';

  @override
  String get customFieldAdd => '添加字段';

  @override
  String get customFieldLabelHint => '字段名';

  @override
  String get customFieldValueHint => '字段值';

  @override
  String get customFieldTypeText => '文本';

  @override
  String get customFieldTypeHidden => '隐藏';

  @override
  String get customFieldTypeBoolean => '勾选';

  @override
  String get customFieldRemove => '删除字段';

  @override
  String get customFieldNoFields => '没有自定义字段';

  @override
  String get secureNoteBodyLabel => '笔记内容';

  @override
  String get secureNoteBodyHint => '任何需要加密保存的内容';

  @override
  String get identityPersonalSection => '个人信息';

  @override
  String get identityContactSection => '联系方式';

  @override
  String get identityDocumentSection => '证件';

  @override
  String get identityAddressSection => '地址';

  @override
  String get identityTitleLabel => '称谓';

  @override
  String get identityTitleHint => '先生 / 女士 / 博士';

  @override
  String get identityFirstNameLabel => '名';

  @override
  String get identityMiddleNameLabel => '中间名';

  @override
  String get identityLastNameLabel => '姓';

  @override
  String get identityCompanyLabel => '公司';

  @override
  String get identityEmailLabel => '邮箱';

  @override
  String get identityPhoneLabel => '电话';

  @override
  String get identityIdNumberLabel => '证件号';

  @override
  String get identityPassportLabel => '护照号';

  @override
  String get identityLicenseLabel => '驾照号';

  @override
  String get identityAddress1Label => '地址';

  @override
  String get identityAddress2Label => '地址（第二行）';

  @override
  String get identityCityLabel => '城市';

  @override
  String get identityStateLabel => '省 / 州';

  @override
  String get identityPostalCodeLabel => '邮政编码';

  @override
  String get identityCountryLabel => '国家 / 地区';

  @override
  String get identityBirthdayLabel => '生日';

  @override
  String get identityBirthdayHint => 'YYYY-MM-DD';

  @override
  String get identitySexLabel => '性别';

  @override
  String get sshKeySection => '密钥内容';

  @override
  String get sshPublicKeyLabel => '公钥';

  @override
  String get sshPublicKeyHint => 'ssh-ed25519 AAAA… 用户@主机';

  @override
  String get sshPrivateKeyLabel => '私钥';

  @override
  String get sshPrivateKeyHint => '-----BEGIN OPENSSH PRIVATE KEY-----';

  @override
  String get sshPassphraseLabel => '私钥口令';

  @override
  String get sshFingerprintLabel => '指纹';

  @override
  String get sshFingerprintAuto => '由公钥自动计算';

  @override
  String get sshKeyTypeLabel => '密钥类型';

  @override
  String get sshBitsLabel => '密钥长度';

  @override
  String sshBitsValue(int bits) {
    return '$bits 位';
  }

  @override
  String get sshCommentLabel => '注释';

  @override
  String get sshPrivateKeyFormatLabel => '识别到的格式';

  @override
  String get sshPublicKeyInvalid => '无法解析这个公钥';

  @override
  String get sshKeyRequired => '请填写公钥或私钥（至少一项）';

  @override
  String sshPrivateKeyFormatValue(String format) {
    return '识别到的格式：$format';
  }

  @override
  String get sshNoPrivateKey => '未保存私钥';

  @override
  String get sshRevealPrivateKey => '显示私钥';

  @override
  String get totpCodeLabel => '动态验证码';

  @override
  String get totpCopyTooltip => '复制验证码';

  @override
  String totpRefreshesIn(int seconds) {
    return '$seconds 秒后刷新';
  }

  @override
  String get totpNotSet => '未配置';

  @override
  String get searchHint => '搜索保险库';

  @override
  String get searchPrefixesHint =>
      '支持前缀：type: login · folder: 工作 · url: example.com';

  @override
  String get folderIconLabel => '图标';

  @override
  String get folderEditTitle => '编辑文件夹';

  @override
  String get folderRenamed => '文件夹已更新';

  @override
  String get renameFolder => '重命名';

  @override
  String get healthOnlyLogins => '健康分只统计登录条目';

  @override
  String healthLoginCount(int count) {
    return '已分析 $count 条登录条目';
  }

  @override
  String get fieldCopied => '已复制到剪贴板';

  @override
  String get detailsSection => '详细信息';

  @override
  String get themeLight => '浅色';

  @override
  String get themeDark => '深色';

  @override
  String themeApplied(String value) {
    return '主题：$value';
  }
}
