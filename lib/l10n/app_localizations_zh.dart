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
}
