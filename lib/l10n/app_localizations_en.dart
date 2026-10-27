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
  String get none => 'None';

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
  String get errorStorageUnavailable =>
      'Unable to access secure storage; vault state is unavailable';

  @override
  String get errorFailedToSaveSettings => 'Failed to save setting';

  @override
  String get errorUseNewMasterPassword =>
      'Your master password was changed already. Unlock with the NEW password.';

  @override
  String get masterPasswordChangedStorageWarning =>
      'Your master password was changed. The system key store could not be updated, so EasyPass will keep using the copy stored inside the vault — unlock with your NEW password.';

  @override
  String get fontSettingsFailed => 'Unable to load or save the font setting';

  @override
  String get storageUnavailableTitle => 'Secure storage unavailable';

  @override
  String get storageUnavailableBody =>
      'EasyPass cannot reach the system secret store (Linux Secret Service / GNOME Keyring / KDE Wallet). The master password cannot be created or verified until this is fixed.\n\nCheck that a Secret Service provider is installed and unlocked, then retry.';

  @override
  String get exit => 'Exit';

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
  String get folderActions => 'Folder actions';

  @override
  String deleteFolderNotEmptyMessage(String name, int count) {
    return 'Delete \"$name\"? It still contains $count entries. They will NOT be deleted — they move to \"No Folder\". This cannot be undone.';
  }

  @override
  String get deleteFolderKeepEntries => 'Delete folder, keep entries';

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
  String get appearanceSection => 'Appearance';

  @override
  String get theme => 'Theme';

  @override
  String get themeComingSoon =>
      'Theme customization is coming in a future update';

  @override
  String get font => 'Font';

  @override
  String get fontDefault => 'Default (Maple Mono NF CN)';

  @override
  String get fontSystem => 'System Default';

  @override
  String get fontMonospace => 'Monospace';

  @override
  String get fontAssetSection => 'Bundled Fonts';

  @override
  String get fontSystemSection => 'System Fonts';

  @override
  String get fontSearchHint => 'Search fonts...';

  @override
  String get fontNoResults => 'No fonts found';

  @override
  String get fontApplied => 'Font updated';

  @override
  String get ok => 'OK';

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
  String get bitwardenJson => 'Bitwarden-compatible JSON';

  @override
  String get bitwardenJsonDesc =>
      'For switching to Bitwarden or Vaultwarden (plain text)';

  @override
  String get saveBitwardenExportDialog => 'Save Bitwarden-Compatible Export';

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
  String get importSourceTitle => 'Import From';

  @override
  String get importFromBitwardenJson => 'Bitwarden / Vaultwarden (.json)';

  @override
  String get importFromBitwardenJsonDesc =>
      'Use the UNENCRYPTED .json export from Bitwarden';

  @override
  String get importFromBitwardenCsv => 'Bitwarden / Vaultwarden (.csv)';

  @override
  String get importFromBitwardenCsvDesc =>
      'Cards become secure notes; SSH keys are not exported by Bitwarden';

  @override
  String get pickImportFileTitle => 'Choose the file to import';

  @override
  String get bitwardenEncryptedHint =>
      'That is Bitwarden\'s encrypted export. Re-export and choose “.json” (unencrypted).';

  @override
  String importedSummary(int entries, int folders) {
    return 'Imported $entries entries, created $folders folders';
  }

  @override
  String importedSkipped(int count) {
    return '$count entries were skipped (see details below)';
  }

  @override
  String importedSkippedDetails(String details) {
    return 'Skipped: $details';
  }

  @override
  String importedLossyNotes(int cards, int uris) {
    return '$cards cards were imported as secure notes; $uris extra URLs were kept as custom fields';
  }

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

  @override
  String get healthReport => 'Password Health Report';

  @override
  String get healthScore => 'Health Score';

  @override
  String get healthGood => 'Good';

  @override
  String get healthFair => 'Fair';

  @override
  String get healthPoor => 'Poor';

  @override
  String get healthWeakPasswords => 'Weak Passwords';

  @override
  String get healthReusedPasswords => 'Reused Passwords';

  @override
  String get healthNoTotp => 'Missing 2-Step Login';

  @override
  String get healthNoUrl => 'Missing URL';

  @override
  String get healthAllHealthy => 'All clear! No health issues found.';

  @override
  String get healthTotalEntries => 'entries';

  @override
  String get healthTapToView => 'Tap an entry to view details';

  @override
  String get healthWeakTooShort =>
      'Password is too short (fewer than 12 characters)';

  @override
  String get healthWeakSingleType => 'Password uses only one character type';

  @override
  String get healthWeakCommonPassword => 'Password is a commonly used password';

  @override
  String healthReusedShared(int count) {
    return 'Shared by $count entries';
  }

  @override
  String get healthNoTotpReason => '2-step verification is not enabled';

  @override
  String get healthNoUrlReason => 'No website URL saved';

  @override
  String healthLoadFailed(String error) {
    return 'Failed to load health report: $error';
  }

  @override
  String get entryTypeLabel => 'Type';

  @override
  String get entryTypeLogin => 'Login';

  @override
  String get entryTypeSecureNote => 'Secure note';

  @override
  String get entryTypeIdentity => 'Identity';

  @override
  String get entryTypeSshKey => 'SSH key';

  @override
  String get entryTypeAll => 'All types';

  @override
  String get entryTypeLoginDesc =>
      'Username, password, website and two-factor code';

  @override
  String get entryTypeSecureNoteDesc => 'Free-form text, stored encrypted';

  @override
  String get entryTypeIdentityDesc =>
      'Name, ID numbers, contact details and address';

  @override
  String get entryTypeSshKeyDesc => 'Public key, private key and fingerprint';

  @override
  String get entryTypeFilterTooltip => 'Filter by type';

  @override
  String get entryTypeSwitchTitle => 'Switch entry type?';

  @override
  String entryTypeSwitchMessage(String from) {
    return 'Fields that belong to \"$from\" will be discarded. The name, notes and custom fields are kept.';
  }

  @override
  String get entryTypeSwitchConfirm => 'Switch';

  @override
  String entryTypeEmptyForType(String type) {
    return 'No $type entries yet';
  }

  @override
  String get customFieldsSection => 'Custom fields';

  @override
  String get customFieldAdd => 'Add field';

  @override
  String get customFieldLabelHint => 'Label';

  @override
  String get customFieldValueHint => 'Value';

  @override
  String get customFieldTypeText => 'Text';

  @override
  String get customFieldTypeHidden => 'Hidden';

  @override
  String get customFieldTypeBoolean => 'Checkbox';

  @override
  String get customFieldRemove => 'Remove field';

  @override
  String get customFieldNoFields => 'No custom fields';

  @override
  String get secureNoteBodyLabel => 'Note';

  @override
  String get secureNoteBodyHint => 'Anything you want to keep encrypted';

  @override
  String get identityPersonalSection => 'Personal';

  @override
  String get identityContactSection => 'Contact';

  @override
  String get identityDocumentSection => 'Documents';

  @override
  String get identityAddressSection => 'Address';

  @override
  String get identityTitleLabel => 'Title';

  @override
  String get identityTitleHint => 'Mr / Ms / Dr';

  @override
  String get identityFirstNameLabel => 'First name';

  @override
  String get identityMiddleNameLabel => 'Middle name';

  @override
  String get identityLastNameLabel => 'Last name';

  @override
  String get identityCompanyLabel => 'Company';

  @override
  String get identityEmailLabel => 'Email';

  @override
  String get identityPhoneLabel => 'Phone';

  @override
  String get identityIdNumberLabel => 'ID number';

  @override
  String get identityPassportLabel => 'Passport number';

  @override
  String get identityLicenseLabel => 'License number';

  @override
  String get identityAddress1Label => 'Address';

  @override
  String get identityAddress2Label => 'Address line 2';

  @override
  String get identityCityLabel => 'City';

  @override
  String get identityStateLabel => 'State / Province';

  @override
  String get identityPostalCodeLabel => 'Postal code';

  @override
  String get identityCountryLabel => 'Country / Region';

  @override
  String get identityBirthdayLabel => 'Birthday';

  @override
  String get identityBirthdayHint => 'YYYY-MM-DD';

  @override
  String get identitySexLabel => 'Gender';

  @override
  String get sshKeySection => 'Key material';

  @override
  String get sshPublicKeyLabel => 'Public key';

  @override
  String get sshPublicKeyHint => 'ssh-ed25519 AAAA… user@host';

  @override
  String get sshPrivateKeyLabel => 'Private key';

  @override
  String get sshPrivateKeyHint => '-----BEGIN OPENSSH PRIVATE KEY-----';

  @override
  String get sshPassphraseLabel => 'Key passphrase';

  @override
  String get sshFingerprintLabel => 'Fingerprint';

  @override
  String get sshFingerprintAuto => 'Computed from the public key';

  @override
  String get sshKeyTypeLabel => 'Key type';

  @override
  String get sshBitsLabel => 'Key size';

  @override
  String sshBitsValue(int bits) {
    return '$bits bits';
  }

  @override
  String get sshCommentLabel => 'Comment';

  @override
  String get sshPrivateKeyFormatLabel => 'Detected format';

  @override
  String get sshPublicKeyInvalid => 'Could not parse this public key';

  @override
  String get sshKeyRequired => 'Enter a public key or a private key';

  @override
  String sshPrivateKeyFormatValue(String format) {
    return 'Detected format: $format';
  }

  @override
  String get sshNoPrivateKey => 'No private key stored';

  @override
  String get sshRevealPrivateKey => 'Reveal private key';

  @override
  String get totpCodeLabel => 'One-time code';

  @override
  String get totpCopyTooltip => 'Copy code';

  @override
  String totpRefreshesIn(int seconds) {
    return 'Refreshes in ${seconds}s';
  }

  @override
  String get totpNotSet => 'Not configured';

  @override
  String get searchHint => 'Search the vault';

  @override
  String get searchPrefixesHint =>
      'Prefixes: type: login · folder: Work · url: example.com';

  @override
  String get folderIconLabel => 'Icon';

  @override
  String get folderEditTitle => 'Edit folder';

  @override
  String get folderRenamed => 'Folder updated';

  @override
  String get renameFolder => 'Rename';

  @override
  String get healthOnlyLogins => 'Health is scored on login entries only';

  @override
  String healthLoginCount(int count) {
    return '$count login entries analysed';
  }

  @override
  String get fieldCopied => 'Copied to clipboard';

  @override
  String get detailsSection => 'Details';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String themeApplied(String value) {
    return 'Theme: $value';
  }

  @override
  String get browserBridgePromptTitle => 'Enable browser integration';

  @override
  String get browserBridgePromptBody =>
      'The browser extension talks to EasyPass through a small host registered on your system. Run this command once (no root needed), then reload the extension:';

  @override
  String get browserBridgePromptCopy => 'Copy command';

  @override
  String get browserBridgePromptCopied => 'Command copied';

  @override
  String get browserBridgePromptOk => 'Got it';

  @override
  String get trayUnavailableNotice =>
      'System tray unavailable — closing the window will quit the app. (GNOME usually needs the \"AppIndicator and KStatusNotifierItem Support\" extension; KDE Plasma supports trays out of the box.)';

  @override
  String get systemSection => 'System';

  @override
  String get autostartTitle => 'Start EasyPass when you log in';

  @override
  String get autostartSubtitleEnabled =>
      'EasyPass starts automatically when you log in.';

  @override
  String get autostartSubtitleDisabled =>
      'EasyPass does not start automatically. Toggle to launch it at login.';

  @override
  String get agentAccessSection => 'Agent access';

  @override
  String get agentAccessTitle => 'Agent access (MCP)';

  @override
  String get agentAccessSubtitle =>
      'Pair AI agents, choose how they may act, and decide per entry what they can read.';

  @override
  String get agentDomainLocked => 'Agent session is locked';

  @override
  String get agentDomainUnlocked => 'Agent session is unlocked';

  @override
  String get agentUnlock => 'Unlock for agents';

  @override
  String get agentLock => 'Lock agent session';

  @override
  String get agentPairings => 'Paired agents';

  @override
  String get agentNoPairings => 'No agent is paired yet.';

  @override
  String get agentCreatePairing => 'Pair an agent';

  @override
  String get agentPairingNickname => 'Nickname (shown in the audit log)';

  @override
  String get agentModeApproval => 'Ask every time';

  @override
  String get agentModeTrusted => 'Trusted (no prompts, fully audited)';

  @override
  String get agentModeSwitch => 'Switch mode';

  @override
  String get agentRevoke => 'Revoke';

  @override
  String get agentRevokeConfirm =>
      'Revoke this pairing? The agent loses access immediately.';

  @override
  String get agentKeyOnceTitle => 'Paste this key into your MCP client';

  @override
  String get agentKeyOnceMessage =>
      'It is shown only once. EasyPass stores just a hash.';

  @override
  String get agentCopied => 'Key copied to clipboard';

  @override
  String get agentMasterPasswordPrompt => 'Confirm with your master password';

  @override
  String get agentConfirm => 'Confirm';

  @override
  String agentActionFailed(String detail) {
    return 'Operation failed: $detail';
  }

  @override
  String get agentAccessEntryTitle => 'Accessible to agents';

  @override
  String get agentAccessEntryOpen =>
      'Open — agents may read this entry (metadata only).';

  @override
  String get agentAccessEntryDenied =>
      'Permanently denied — agents can never read it.';

  @override
  String get autostartUnsupported =>
      'Managed by the OS installer on this platform.';

  @override
  String get autostartEnabled => 'EasyPass will start automatically at login.';

  @override
  String get autostartDisabled =>
      'EasyPass will no longer start automatically at login.';

  @override
  String autostartFailed(String detail) {
    return 'Could not change autostart: $detail';
  }
}
