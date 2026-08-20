// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'EasyPass';

  @override
  String get masterPasswordLabel => 'Master Password';

  @override
  String get masterPasswordHint => 'At least 8 characters';

  @override
  String get confirmMasterPasswordLabel => 'Confirm Master Password';

  @override
  String get unlock => 'Unlock';

  @override
  String get unlockScreenSubtitle => 'Enter your master password to unlock';

  @override
  String get welcomeTitle => 'Welcome to EasyPass';

  @override
  String get setPasswordSubtitle =>
      'Set your master password to get started.\nThis password will encrypt all your data.';

  @override
  String get setMasterPassword => 'Set Master Password';

  @override
  String get securityNote =>
      'Important: Your master password cannot be recovered if forgotten. Store it safely!';

  @override
  String get errorPasswordsDoNotMatch => 'Passwords do not match';

  @override
  String get errorPasswordTooShort =>
      'Master password must be at least 8 characters';

  @override
  String get errorNoMasterPassword => 'No master password configured';

  @override
  String get errorIncorrectMasterPassword => 'Incorrect master password';

  @override
  String get errorVaultLocked => 'Vault is locked';

  @override
  String get errorFailedToSave => 'Failed to save master password';

  @override
  String get errorFailedToChange => 'Failed to change master password';

  @override
  String get errorCurrentPasswordIncorrect =>
      'Current master password is incorrect';

  @override
  String get errorUnlockFailed => 'Error unlocking vault';

  @override
  String get favoritesTitle => 'Favorites';

  @override
  String get folderTitle => 'Folder';

  @override
  String get searchTooltip => 'Search';

  @override
  String get generatorTooltip => 'Password Generator';

  @override
  String get passwordGenerator => 'Password Generator';

  @override
  String get lockTooltip => 'Lock vault';

  @override
  String get settings => 'Settings';

  @override
  String failedToLoadVault(String error) {
    return 'Failed to load vault: $error';
  }

  @override
  String get retry => 'Retry';

  @override
  String get emptyVaultTitle => 'Your vault is empty';

  @override
  String get emptyVaultHint => 'Tap + to add your first password';

  @override
  String get add => 'Add';

  @override
  String get passwordCopied => 'Password copied to clipboard';

  @override
  String get allItems => 'All Items';

  @override
  String get favorites => 'Favorites';

  @override
  String get foldersSection => 'FOLDERS';

  @override
  String get newFolder => 'New Folder';

  @override
  String get folderNameLabel => 'Folder Name';

  @override
  String get folderNameHint => 'e.g., Work, Personal';

  @override
  String get cancel => 'Cancel';

  @override
  String get create => 'Create';

  @override
  String get deleteFolderTitle => 'Delete Folder';

  @override
  String deleteFolderMessage(String name) {
    return 'Delete \"$name\"? Entries inside will be moved to \"No Folder\". This cannot be undone.';
  }

  @override
  String folderDeleted(String name) {
    return 'Folder \"$name\" deleted';
  }

  @override
  String get delete => 'Delete';

  @override
  String get searchFailed => 'Search failed';

  @override
  String get noResultsFound => 'No results found';

  @override
  String get editEntryTitle => 'Edit Entry';

  @override
  String get addEntryTitle => 'Add Entry';

  @override
  String get nameLabel => 'Name *';

  @override
  String get nameHint => 'e.g., Google, GitHub';

  @override
  String get nameRequired => 'Name is required';

  @override
  String get urlLabel => 'URL';

  @override
  String get urlHint => 'e.g., https://example.com';

  @override
  String get usernameLabel => 'Username / Email';

  @override
  String get usernameHint => 'e.g., user@example.com';

  @override
  String get passwordLabel => 'Password *';

  @override
  String get generatePasswordTooltip => 'Generate password';

  @override
  String get totpSecretLabel => 'TOTP Secret (2FA)';

  @override
  String get totpSecretHint => 'Base32 secret for authenticator';

  @override
  String get noFolder => 'No Folder';

  @override
  String get notesLabel => 'Notes';

  @override
  String get notesHint => 'Additional notes...';

  @override
  String get favorite => 'Favorite';

  @override
  String get favoriteSubtitle => 'Mark this entry as favorite';

  @override
  String get saveChanges => 'Save Changes';

  @override
  String get passwordRequired => 'Password is required';

  @override
  String get entryUpdated => 'Entry updated';

  @override
  String get entrySaved => 'Entry saved';

  @override
  String failedToSaveEntry(String error) {
    return 'Failed to save: $error';
  }

  @override
  String get deleteEntryTitle => 'Delete Entry';

  @override
  String get deleteEntryMessage => 'Are you sure? This cannot be undone.';

  @override
  String get deleteEntryDetailMessage =>
      'Are you sure you want to delete this entry? This action cannot be undone.';

  @override
  String get entryDetailsTitle => 'Entry Details';

  @override
  String get failedToLoadEntry => 'Failed to load entry';

  @override
  String get entryNotFound => 'Entry not found';

  @override
  String get username => 'Username';

  @override
  String get usernameCopied => 'Username copied';

  @override
  String get passwordField => 'Password';

  @override
  String get visibleAutoHide => 'Visible • Auto-hides in 1 min';

  @override
  String get passwordCopiedShort => 'Password copied';

  @override
  String get revealPasswordTooltip => 'Reveal password';

  @override
  String get hidePasswordTooltip => 'Hide password';

  @override
  String get copyPasswordTooltip => 'Copy password';

  @override
  String get urlCopied => 'URL copied';

  @override
  String copyFieldTooltip(String label) {
    return 'Copy $label';
  }

  @override
  String get verifyMasterPasswordTitle => 'Verify Master Password';

  @override
  String get verify => 'Verify';

  @override
  String get noMasterPasswordConfigured => 'No master password configured';

  @override
  String get selectOptionsBelow => 'Select options below';

  @override
  String charactersCount(int count) {
    return '$count characters';
  }

  @override
  String get copy => 'Copy';

  @override
  String get regenerate => 'Regenerate';

  @override
  String get passwordCopiedExcl => 'Password copied!';

  @override
  String get useThisPassword => 'Use This Password';

  @override
  String lengthLabel(int length) {
    return 'Length: $length';
  }

  @override
  String get uppercase => 'Uppercase (A-Z)';

  @override
  String get uppercaseSubtitle => 'Include uppercase letters';

  @override
  String get lowercase => 'Lowercase (a-z)';

  @override
  String get lowercaseSubtitle => 'Include lowercase letters';

  @override
  String get numbers => 'Numbers (0-9)';

  @override
  String get numbersSubtitle => 'Include numbers';

  @override
  String get symbols => 'Symbols (!@#\$...)';

  @override
  String get symbolsSubtitle => 'Include special characters';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get securitySection => 'Security';

  @override
  String get changeMasterPassword => 'Change Master Password';

  @override
  String get changeMasterPasswordSubtitle =>
      'Re-encrypts all entries with a new key';

  @override
  String get autoLockTimeout => 'Auto-lock Timeout';

  @override
  String autoLockMinutesValue(int minutes) {
    return '$minutes minutes';
  }

  @override
  String get biometricUnlock => 'Biometric Unlock';

  @override
  String get biometricUnlockSubtitle => 'Use fingerprint to unlock';

  @override
  String get biometricComingSoon =>
      'Biometric unlock coming in a future update';

  @override
  String get dataSection => 'Data';

  @override
  String get exportVault => 'Export Vault';

  @override
  String get exportVaultSubtitle => 'Encrypted backup or plain JSON';

  @override
  String get importVault => 'Import Vault';

  @override
  String get importVaultSubtitle => 'Restore from a backup or JSON file';

  @override
  String get dangerZoneSection => 'Danger Zone';

  @override
  String get deleteAllData => 'Delete All Data';

  @override
  String get deleteAllDataSubtitle => 'This action cannot be undone';

  @override
  String get aboutSection => 'About';

  @override
  String get version => 'Version';

  @override
  String get appInfo => 'A secure password manager';

  @override
  String get languageSection => 'Language';

  @override
  String get language => 'Language';

  @override
  String get followSystem => 'Follow System';

  @override
  String get languageChinese => '中文';

  @override
  String get languageEnglish => 'English';

  @override
  String get exportDialogTitle => 'Export Vault';

  @override
  String get encryptedBackup => 'Encrypted backup (recommended)';

  @override
  String get encryptedBackupDesc => 'Password-protected by your master key';

  @override
  String get plainJson => 'Plain JSON';

  @override
  String get plainJsonDesc => 'Decrypted text — keep it safe';

  @override
  String get saveEncryptedBackupDialog => 'Save Encrypted Backup';

  @override
  String get savePlainExportDialog => 'Save Plain Export';

  @override
  String vaultExportedTo(String path) {
    return 'Vault exported to $path';
  }

  @override
  String exportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String get importDialogTitle => 'Import Vault';

  @override
  String get importDialogMessage =>
      'Importing will add all entries from the backup file to your current vault. Existing entries will not be overwritten. Continue?';

  @override
  String get import => 'Import';

  @override
  String importedCounts(int entries, int folders) {
    return 'Imported $entries entries and $folders folders';
  }

  @override
  String importFailed(String error) {
    return 'Import failed: $error';
  }

  @override
  String get currentMasterPasswordLabel => 'Current Master Password';

  @override
  String get newMasterPasswordLabel => 'New Master Password';

  @override
  String get confirmNewPasswordLabel => 'Confirm New Password';

  @override
  String get change => 'Change';

  @override
  String get masterPasswordChanged => 'Master password changed';

  @override
  String failedWithError(String error) {
    return 'Failed: $error';
  }

  @override
  String autoLockSet(String value) {
    return 'Auto-lock set to $value';
  }

  @override
  String get deleteAllDataTitle => 'Delete All Data?';

  @override
  String get deleteAllDataMessage =>
      'This will permanently delete all your saved passwords and data. This action cannot be undone.';

  @override
  String get deleteAll => 'Delete All';

  @override
  String get allDataDeleted => 'All data deleted';
}
