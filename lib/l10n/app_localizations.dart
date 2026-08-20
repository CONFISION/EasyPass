import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'EasyPass'**
  String get appTitle;

  /// No description provided for @none.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get none;

  /// No description provided for @masterPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Master Password'**
  String get masterPasswordLabel;

  /// No description provided for @masterPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'At least 8 characters'**
  String get masterPasswordHint;

  /// No description provided for @confirmMasterPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirm Master Password'**
  String get confirmMasterPasswordLabel;

  /// No description provided for @unlock.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get unlock;

  /// No description provided for @unlockScreenSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enter your master password to unlock'**
  String get unlockScreenSubtitle;

  /// No description provided for @welcomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Welcome to EasyPass'**
  String get welcomeTitle;

  /// No description provided for @setPasswordSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Set your master password to get started.\nThis password will encrypt all your data.'**
  String get setPasswordSubtitle;

  /// No description provided for @setMasterPassword.
  ///
  /// In en, this message translates to:
  /// **'Set Master Password'**
  String get setMasterPassword;

  /// No description provided for @securityNote.
  ///
  /// In en, this message translates to:
  /// **'Important: Your master password cannot be recovered if forgotten. Store it safely!'**
  String get securityNote;

  /// No description provided for @errorPasswordsDoNotMatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match'**
  String get errorPasswordsDoNotMatch;

  /// No description provided for @errorPasswordTooShort.
  ///
  /// In en, this message translates to:
  /// **'Master password must be at least 8 characters'**
  String get errorPasswordTooShort;

  /// No description provided for @errorNoMasterPassword.
  ///
  /// In en, this message translates to:
  /// **'No master password configured'**
  String get errorNoMasterPassword;

  /// No description provided for @errorIncorrectMasterPassword.
  ///
  /// In en, this message translates to:
  /// **'Incorrect master password'**
  String get errorIncorrectMasterPassword;

  /// No description provided for @errorVaultLocked.
  ///
  /// In en, this message translates to:
  /// **'Vault is locked'**
  String get errorVaultLocked;

  /// No description provided for @errorFailedToSave.
  ///
  /// In en, this message translates to:
  /// **'Failed to save master password'**
  String get errorFailedToSave;

  /// No description provided for @errorFailedToChange.
  ///
  /// In en, this message translates to:
  /// **'Failed to change master password'**
  String get errorFailedToChange;

  /// No description provided for @errorCurrentPasswordIncorrect.
  ///
  /// In en, this message translates to:
  /// **'Current master password is incorrect'**
  String get errorCurrentPasswordIncorrect;

  /// No description provided for @errorUnlockFailed.
  ///
  /// In en, this message translates to:
  /// **'Error unlocking vault'**
  String get errorUnlockFailed;

  /// No description provided for @favoritesTitle.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get favoritesTitle;

  /// No description provided for @folderTitle.
  ///
  /// In en, this message translates to:
  /// **'Folder'**
  String get folderTitle;

  /// No description provided for @searchTooltip.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get searchTooltip;

  /// No description provided for @generatorTooltip.
  ///
  /// In en, this message translates to:
  /// **'Password Generator'**
  String get generatorTooltip;

  /// No description provided for @passwordGenerator.
  ///
  /// In en, this message translates to:
  /// **'Password Generator'**
  String get passwordGenerator;

  /// No description provided for @lockTooltip.
  ///
  /// In en, this message translates to:
  /// **'Lock vault'**
  String get lockTooltip;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @failedToLoadVault.
  ///
  /// In en, this message translates to:
  /// **'Failed to load vault: {error}'**
  String failedToLoadVault(String error);

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @emptyVaultTitle.
  ///
  /// In en, this message translates to:
  /// **'Your vault is empty'**
  String get emptyVaultTitle;

  /// No description provided for @emptyVaultHint.
  ///
  /// In en, this message translates to:
  /// **'Tap + to add your first password'**
  String get emptyVaultHint;

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @passwordCopied.
  ///
  /// In en, this message translates to:
  /// **'Password copied to clipboard'**
  String get passwordCopied;

  /// No description provided for @allItems.
  ///
  /// In en, this message translates to:
  /// **'All Items'**
  String get allItems;

  /// No description provided for @favorites.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get favorites;

  /// No description provided for @foldersSection.
  ///
  /// In en, this message translates to:
  /// **'FOLDERS'**
  String get foldersSection;

  /// No description provided for @newFolder.
  ///
  /// In en, this message translates to:
  /// **'New Folder'**
  String get newFolder;

  /// No description provided for @folderNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Folder Name'**
  String get folderNameLabel;

  /// No description provided for @folderNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g., Work, Personal'**
  String get folderNameHint;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @create.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get create;

  /// No description provided for @deleteFolderTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Folder'**
  String get deleteFolderTitle;

  /// No description provided for @deleteFolderMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"? Entries inside will be moved to \"No Folder\". This cannot be undone.'**
  String deleteFolderMessage(String name);

  /// No description provided for @folderDeleted.
  ///
  /// In en, this message translates to:
  /// **'Folder \"{name}\" deleted'**
  String folderDeleted(String name);

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @searchFailed.
  ///
  /// In en, this message translates to:
  /// **'Search failed'**
  String get searchFailed;

  /// No description provided for @noResultsFound.
  ///
  /// In en, this message translates to:
  /// **'No results found'**
  String get noResultsFound;

  /// No description provided for @editEntryTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Entry'**
  String get editEntryTitle;

  /// No description provided for @addEntryTitle.
  ///
  /// In en, this message translates to:
  /// **'Add Entry'**
  String get addEntryTitle;

  /// No description provided for @nameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name *'**
  String get nameLabel;

  /// No description provided for @nameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g., Google, GitHub'**
  String get nameHint;

  /// No description provided for @nameRequired.
  ///
  /// In en, this message translates to:
  /// **'Name is required'**
  String get nameRequired;

  /// No description provided for @urlLabel.
  ///
  /// In en, this message translates to:
  /// **'URL'**
  String get urlLabel;

  /// No description provided for @urlHint.
  ///
  /// In en, this message translates to:
  /// **'e.g., https://example.com'**
  String get urlHint;

  /// No description provided for @usernameLabel.
  ///
  /// In en, this message translates to:
  /// **'Username / Email'**
  String get usernameLabel;

  /// No description provided for @usernameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g., user@example.com'**
  String get usernameHint;

  /// No description provided for @passwordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password *'**
  String get passwordLabel;

  /// No description provided for @generatePasswordTooltip.
  ///
  /// In en, this message translates to:
  /// **'Generate password'**
  String get generatePasswordTooltip;

  /// No description provided for @totpSecretLabel.
  ///
  /// In en, this message translates to:
  /// **'TOTP Secret (2FA)'**
  String get totpSecretLabel;

  /// No description provided for @totpSecretHint.
  ///
  /// In en, this message translates to:
  /// **'Base32 secret for authenticator'**
  String get totpSecretHint;

  /// No description provided for @noFolder.
  ///
  /// In en, this message translates to:
  /// **'No Folder'**
  String get noFolder;

  /// No description provided for @notesLabel.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get notesLabel;

  /// No description provided for @notesHint.
  ///
  /// In en, this message translates to:
  /// **'Additional notes...'**
  String get notesHint;

  /// No description provided for @favorite.
  ///
  /// In en, this message translates to:
  /// **'Favorite'**
  String get favorite;

  /// No description provided for @favoriteSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Mark this entry as favorite'**
  String get favoriteSubtitle;

  /// No description provided for @saveChanges.
  ///
  /// In en, this message translates to:
  /// **'Save Changes'**
  String get saveChanges;

  /// No description provided for @passwordRequired.
  ///
  /// In en, this message translates to:
  /// **'Password is required'**
  String get passwordRequired;

  /// No description provided for @entryUpdated.
  ///
  /// In en, this message translates to:
  /// **'Entry updated'**
  String get entryUpdated;

  /// No description provided for @entrySaved.
  ///
  /// In en, this message translates to:
  /// **'Entry saved'**
  String get entrySaved;

  /// No description provided for @failedToSaveEntry.
  ///
  /// In en, this message translates to:
  /// **'Failed to save: {error}'**
  String failedToSaveEntry(String error);

  /// No description provided for @deleteEntryTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Entry'**
  String get deleteEntryTitle;

  /// No description provided for @deleteEntryMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure? This cannot be undone.'**
  String get deleteEntryMessage;

  /// No description provided for @deleteEntryDetailMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this entry? This action cannot be undone.'**
  String get deleteEntryDetailMessage;

  /// No description provided for @entryDetailsTitle.
  ///
  /// In en, this message translates to:
  /// **'Entry Details'**
  String get entryDetailsTitle;

  /// No description provided for @failedToLoadEntry.
  ///
  /// In en, this message translates to:
  /// **'Failed to load entry'**
  String get failedToLoadEntry;

  /// No description provided for @entryNotFound.
  ///
  /// In en, this message translates to:
  /// **'Entry not found'**
  String get entryNotFound;

  /// No description provided for @username.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get username;

  /// No description provided for @usernameCopied.
  ///
  /// In en, this message translates to:
  /// **'Username copied'**
  String get usernameCopied;

  /// No description provided for @passwordField.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get passwordField;

  /// No description provided for @visibleAutoHide.
  ///
  /// In en, this message translates to:
  /// **'Visible • Auto-hides in 1 min'**
  String get visibleAutoHide;

  /// No description provided for @passwordCopiedShort.
  ///
  /// In en, this message translates to:
  /// **'Password copied'**
  String get passwordCopiedShort;

  /// No description provided for @revealPasswordTooltip.
  ///
  /// In en, this message translates to:
  /// **'Reveal password'**
  String get revealPasswordTooltip;

  /// No description provided for @hidePasswordTooltip.
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get hidePasswordTooltip;

  /// No description provided for @copyPasswordTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy password'**
  String get copyPasswordTooltip;

  /// No description provided for @urlCopied.
  ///
  /// In en, this message translates to:
  /// **'URL copied'**
  String get urlCopied;

  /// No description provided for @copyFieldTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy {label}'**
  String copyFieldTooltip(String label);

  /// No description provided for @verifyMasterPasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'Verify Master Password'**
  String get verifyMasterPasswordTitle;

  /// No description provided for @verify.
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get verify;

  /// No description provided for @noMasterPasswordConfigured.
  ///
  /// In en, this message translates to:
  /// **'No master password configured'**
  String get noMasterPasswordConfigured;

  /// No description provided for @selectOptionsBelow.
  ///
  /// In en, this message translates to:
  /// **'Select options below'**
  String get selectOptionsBelow;

  /// No description provided for @charactersCount.
  ///
  /// In en, this message translates to:
  /// **'{count} characters'**
  String charactersCount(int count);

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @regenerate.
  ///
  /// In en, this message translates to:
  /// **'Regenerate'**
  String get regenerate;

  /// No description provided for @passwordCopiedExcl.
  ///
  /// In en, this message translates to:
  /// **'Password copied!'**
  String get passwordCopiedExcl;

  /// No description provided for @useThisPassword.
  ///
  /// In en, this message translates to:
  /// **'Use This Password'**
  String get useThisPassword;

  /// No description provided for @lengthLabel.
  ///
  /// In en, this message translates to:
  /// **'Length: {length}'**
  String lengthLabel(int length);

  /// No description provided for @uppercase.
  ///
  /// In en, this message translates to:
  /// **'Uppercase (A-Z)'**
  String get uppercase;

  /// No description provided for @uppercaseSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Include uppercase letters'**
  String get uppercaseSubtitle;

  /// No description provided for @lowercase.
  ///
  /// In en, this message translates to:
  /// **'Lowercase (a-z)'**
  String get lowercase;

  /// No description provided for @lowercaseSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Include lowercase letters'**
  String get lowercaseSubtitle;

  /// No description provided for @numbers.
  ///
  /// In en, this message translates to:
  /// **'Numbers (0-9)'**
  String get numbers;

  /// No description provided for @numbersSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Include numbers'**
  String get numbersSubtitle;

  /// No description provided for @symbols.
  ///
  /// In en, this message translates to:
  /// **'Symbols (!@#\$...)'**
  String get symbols;

  /// No description provided for @symbolsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Include special characters'**
  String get symbolsSubtitle;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @securitySection.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get securitySection;

  /// No description provided for @changeMasterPassword.
  ///
  /// In en, this message translates to:
  /// **'Change Master Password'**
  String get changeMasterPassword;

  /// No description provided for @changeMasterPasswordSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Re-encrypts all entries with a new key'**
  String get changeMasterPasswordSubtitle;

  /// No description provided for @autoLockTimeout.
  ///
  /// In en, this message translates to:
  /// **'Auto-lock Timeout'**
  String get autoLockTimeout;

  /// No description provided for @autoLockMinutesValue.
  ///
  /// In en, this message translates to:
  /// **'{minutes} minutes'**
  String autoLockMinutesValue(int minutes);

  /// No description provided for @biometricUnlock.
  ///
  /// In en, this message translates to:
  /// **'Biometric Unlock'**
  String get biometricUnlock;

  /// No description provided for @biometricUnlockSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use fingerprint to unlock'**
  String get biometricUnlockSubtitle;

  /// No description provided for @biometricComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Biometric unlock coming in a future update'**
  String get biometricComingSoon;

  /// No description provided for @dataSection.
  ///
  /// In en, this message translates to:
  /// **'Data'**
  String get dataSection;

  /// No description provided for @exportVault.
  ///
  /// In en, this message translates to:
  /// **'Export Vault'**
  String get exportVault;

  /// No description provided for @exportVaultSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Encrypted backup or plain JSON'**
  String get exportVaultSubtitle;

  /// No description provided for @importVault.
  ///
  /// In en, this message translates to:
  /// **'Import Vault'**
  String get importVault;

  /// No description provided for @importVaultSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Restore from a backup or JSON file'**
  String get importVaultSubtitle;

  /// No description provided for @dangerZoneSection.
  ///
  /// In en, this message translates to:
  /// **'Danger Zone'**
  String get dangerZoneSection;

  /// No description provided for @deleteAllData.
  ///
  /// In en, this message translates to:
  /// **'Delete All Data'**
  String get deleteAllData;

  /// No description provided for @deleteAllDataSubtitle.
  ///
  /// In en, this message translates to:
  /// **'This action cannot be undone'**
  String get deleteAllDataSubtitle;

  /// No description provided for @aboutSection.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get aboutSection;

  /// No description provided for @version.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get version;

  /// No description provided for @appInfo.
  ///
  /// In en, this message translates to:
  /// **'A secure password manager'**
  String get appInfo;

  /// No description provided for @languageSection.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageSection;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @followSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow System'**
  String get followSystem;

  /// No description provided for @languageChinese.
  ///
  /// In en, this message translates to:
  /// **'中文'**
  String get languageChinese;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @appearanceSection.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearanceSection;

  /// No description provided for @theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get theme;

  /// No description provided for @themeComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Theme customization is coming in a future update'**
  String get themeComingSoon;

  /// No description provided for @font.
  ///
  /// In en, this message translates to:
  /// **'Font'**
  String get font;

  /// No description provided for @fontDefault.
  ///
  /// In en, this message translates to:
  /// **'Default (Maple Mono NF CN)'**
  String get fontDefault;

  /// No description provided for @fontSystem.
  ///
  /// In en, this message translates to:
  /// **'System Default'**
  String get fontSystem;

  /// No description provided for @fontMonospace.
  ///
  /// In en, this message translates to:
  /// **'Monospace'**
  String get fontMonospace;

  /// No description provided for @fontAssetSection.
  ///
  /// In en, this message translates to:
  /// **'Bundled Fonts'**
  String get fontAssetSection;

  /// No description provided for @fontSystemSection.
  ///
  /// In en, this message translates to:
  /// **'System Fonts'**
  String get fontSystemSection;

  /// No description provided for @fontSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search fonts...'**
  String get fontSearchHint;

  /// No description provided for @fontNoResults.
  ///
  /// In en, this message translates to:
  /// **'No fonts found'**
  String get fontNoResults;

  /// No description provided for @fontApplied.
  ///
  /// In en, this message translates to:
  /// **'Font updated'**
  String get fontApplied;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @exportDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Export Vault'**
  String get exportDialogTitle;

  /// No description provided for @encryptedBackup.
  ///
  /// In en, this message translates to:
  /// **'Encrypted backup (recommended)'**
  String get encryptedBackup;

  /// No description provided for @encryptedBackupDesc.
  ///
  /// In en, this message translates to:
  /// **'Password-protected by your master key'**
  String get encryptedBackupDesc;

  /// No description provided for @plainJson.
  ///
  /// In en, this message translates to:
  /// **'Plain JSON'**
  String get plainJson;

  /// No description provided for @plainJsonDesc.
  ///
  /// In en, this message translates to:
  /// **'Decrypted text — keep it safe'**
  String get plainJsonDesc;

  /// No description provided for @saveEncryptedBackupDialog.
  ///
  /// In en, this message translates to:
  /// **'Save Encrypted Backup'**
  String get saveEncryptedBackupDialog;

  /// No description provided for @savePlainExportDialog.
  ///
  /// In en, this message translates to:
  /// **'Save Plain Export'**
  String get savePlainExportDialog;

  /// No description provided for @vaultExportedTo.
  ///
  /// In en, this message translates to:
  /// **'Vault exported to {path}'**
  String vaultExportedTo(String path);

  /// No description provided for @exportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {error}'**
  String exportFailed(String error);

  /// No description provided for @importDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Import Vault'**
  String get importDialogTitle;

  /// No description provided for @importDialogMessage.
  ///
  /// In en, this message translates to:
  /// **'Importing will add all entries from the backup file to your current vault. Existing entries will not be overwritten. Continue?'**
  String get importDialogMessage;

  /// No description provided for @import.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get import;

  /// No description provided for @importedCounts.
  ///
  /// In en, this message translates to:
  /// **'Imported {entries} entries and {folders} folders'**
  String importedCounts(int entries, int folders);

  /// No description provided for @importFailed.
  ///
  /// In en, this message translates to:
  /// **'Import failed: {error}'**
  String importFailed(String error);

  /// No description provided for @currentMasterPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Current Master Password'**
  String get currentMasterPasswordLabel;

  /// No description provided for @newMasterPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'New Master Password'**
  String get newMasterPasswordLabel;

  /// No description provided for @confirmNewPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirm New Password'**
  String get confirmNewPasswordLabel;

  /// No description provided for @change.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get change;

  /// No description provided for @masterPasswordChanged.
  ///
  /// In en, this message translates to:
  /// **'Master password changed'**
  String get masterPasswordChanged;

  /// No description provided for @failedWithError.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String failedWithError(String error);

  /// No description provided for @autoLockSet.
  ///
  /// In en, this message translates to:
  /// **'Auto-lock set to {value}'**
  String autoLockSet(String value);

  /// No description provided for @deleteAllDataTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete All Data?'**
  String get deleteAllDataTitle;

  /// No description provided for @deleteAllDataMessage.
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete all your saved passwords and data. This action cannot be undone.'**
  String get deleteAllDataMessage;

  /// No description provided for @deleteAll.
  ///
  /// In en, this message translates to:
  /// **'Delete All'**
  String get deleteAll;

  /// No description provided for @allDataDeleted.
  ///
  /// In en, this message translates to:
  /// **'All data deleted'**
  String get allDataDeleted;

  /// No description provided for @healthReport.
  ///
  /// In en, this message translates to:
  /// **'Password Health Report'**
  String get healthReport;

  /// No description provided for @healthScore.
  ///
  /// In en, this message translates to:
  /// **'Health Score'**
  String get healthScore;

  /// No description provided for @healthGood.
  ///
  /// In en, this message translates to:
  /// **'Good'**
  String get healthGood;

  /// No description provided for @healthFair.
  ///
  /// In en, this message translates to:
  /// **'Fair'**
  String get healthFair;

  /// No description provided for @healthPoor.
  ///
  /// In en, this message translates to:
  /// **'Poor'**
  String get healthPoor;

  /// No description provided for @healthWeakPasswords.
  ///
  /// In en, this message translates to:
  /// **'Weak Passwords'**
  String get healthWeakPasswords;

  /// No description provided for @healthReusedPasswords.
  ///
  /// In en, this message translates to:
  /// **'Reused Passwords'**
  String get healthReusedPasswords;

  /// No description provided for @healthNoTotp.
  ///
  /// In en, this message translates to:
  /// **'Missing 2-Step Login'**
  String get healthNoTotp;

  /// No description provided for @healthNoUrl.
  ///
  /// In en, this message translates to:
  /// **'Missing URL'**
  String get healthNoUrl;

  /// No description provided for @healthAllHealthy.
  ///
  /// In en, this message translates to:
  /// **'All clear! No health issues found.'**
  String get healthAllHealthy;

  /// No description provided for @healthTotalEntries.
  ///
  /// In en, this message translates to:
  /// **'entries'**
  String get healthTotalEntries;

  /// No description provided for @healthTapToView.
  ///
  /// In en, this message translates to:
  /// **'Tap an entry to view details'**
  String get healthTapToView;

  /// No description provided for @healthWeakTooShort.
  ///
  /// In en, this message translates to:
  /// **'Password is too short (fewer than 12 characters)'**
  String get healthWeakTooShort;

  /// No description provided for @healthWeakSingleType.
  ///
  /// In en, this message translates to:
  /// **'Password uses only one character type'**
  String get healthWeakSingleType;

  /// No description provided for @healthWeakCommonPassword.
  ///
  /// In en, this message translates to:
  /// **'Password is a commonly used password'**
  String get healthWeakCommonPassword;

  /// No description provided for @healthReusedShared.
  ///
  /// In en, this message translates to:
  /// **'Shared by {count} entries'**
  String healthReusedShared(int count);

  /// No description provided for @healthNoTotpReason.
  ///
  /// In en, this message translates to:
  /// **'2-step verification is not enabled'**
  String get healthNoTotpReason;

  /// No description provided for @healthNoUrlReason.
  ///
  /// In en, this message translates to:
  /// **'No website URL saved'**
  String get healthNoUrlReason;

  /// No description provided for @healthLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load health report: {error}'**
  String healthLoadFailed(String error);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
