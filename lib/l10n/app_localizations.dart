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

  /// No description provided for @errorStorageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unable to access secure storage; vault state is unavailable'**
  String get errorStorageUnavailable;

  /// No description provided for @errorFailedToSaveSettings.
  ///
  /// In en, this message translates to:
  /// **'Failed to save setting'**
  String get errorFailedToSaveSettings;

  /// No description provided for @errorUseNewMasterPassword.
  ///
  /// In en, this message translates to:
  /// **'Your master password was changed already. Unlock with the NEW password.'**
  String get errorUseNewMasterPassword;

  /// No description provided for @masterPasswordChangedStorageWarning.
  ///
  /// In en, this message translates to:
  /// **'Your master password was changed. The system key store could not be updated, so EasyPass will keep using the copy stored inside the vault — unlock with your NEW password.'**
  String get masterPasswordChangedStorageWarning;

  /// No description provided for @fontSettingsFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to load or save the font setting'**
  String get fontSettingsFailed;

  /// No description provided for @storageUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Secure storage unavailable'**
  String get storageUnavailableTitle;

  /// No description provided for @storageUnavailableBody.
  ///
  /// In en, this message translates to:
  /// **'EasyPass cannot reach the system secret store (Linux Secret Service / GNOME Keyring / KDE Wallet). The master password cannot be created or verified until this is fixed.\n\nCheck that a Secret Service provider is installed and unlocked, then retry.'**
  String get storageUnavailableBody;

  /// No description provided for @exit.
  ///
  /// In en, this message translates to:
  /// **'Exit'**
  String get exit;

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

  /// No description provided for @folderActions.
  ///
  /// In en, this message translates to:
  /// **'Folder actions'**
  String get folderActions;

  /// No description provided for @entryActions.
  ///
  /// In en, this message translates to:
  /// **'Entry actions'**
  String get entryActions;

  /// No description provided for @entryActionEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get entryActionEdit;

  /// No description provided for @deleteFolderNotEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"? It still contains {count} entries. They will NOT be deleted — they move to \"No Folder\". This cannot be undone.'**
  String deleteFolderNotEmptyMessage(String name, int count);

  /// No description provided for @deleteFolderKeepEntries.
  ///
  /// In en, this message translates to:
  /// **'Delete folder, keep entries'**
  String get deleteFolderKeepEntries;

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
  /// **'Move to Trash?'**
  String get deleteEntryTitle;

  /// No description provided for @trashMoveAction.
  ///
  /// In en, this message translates to:
  /// **'Move to Trash'**
  String get trashMoveAction;

  /// No description provided for @deleteEntryMessage.
  ///
  /// In en, this message translates to:
  /// **'Move this entry to the trash? You can restore it later.'**
  String get deleteEntryMessage;

  /// No description provided for @deleteEntryDetailMessage.
  ///
  /// In en, this message translates to:
  /// **'Move this entry to the trash? You can restore it, or delete it permanently, later.'**
  String get deleteEntryDetailMessage;

  /// No description provided for @trashTitle.
  ///
  /// In en, this message translates to:
  /// **'Trash'**
  String get trashTitle;

  /// No description provided for @trashSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Deleted entries land here first: restore them or delete them for good.'**
  String get trashSubtitle;

  /// No description provided for @trashEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Trash is empty'**
  String get trashEmptyTitle;

  /// No description provided for @trashEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Deleted entries show up here first, and can always be restored.'**
  String get trashEmptyMessage;

  /// No description provided for @trashDeletedAt.
  ///
  /// In en, this message translates to:
  /// **'Deleted {time}'**
  String trashDeletedAt(String time);

  /// No description provided for @trashRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get trashRestore;

  /// No description provided for @trashRestored.
  ///
  /// In en, this message translates to:
  /// **'Restored \"{name}\"'**
  String trashRestored(String name);

  /// No description provided for @trashDeletePermanently.
  ///
  /// In en, this message translates to:
  /// **'Delete permanently'**
  String get trashDeletePermanently;

  /// No description provided for @trashDeletePermanentlyTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete entry permanently'**
  String get trashDeletePermanentlyTitle;

  /// No description provided for @trashDeletePermanentlyMessage.
  ///
  /// In en, this message translates to:
  /// **'\"{name}\" will be permanently deleted. This cannot be undone.'**
  String trashDeletePermanentlyMessage(String name);

  /// No description provided for @trashDeletedPermanently.
  ///
  /// In en, this message translates to:
  /// **'Permanently deleted \"{name}\"'**
  String trashDeletedPermanently(String name);

  /// No description provided for @trashEmptyAction.
  ///
  /// In en, this message translates to:
  /// **'Empty trash'**
  String get trashEmptyAction;

  /// No description provided for @trashEmptyConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Empty the trash?'**
  String get trashEmptyConfirmTitle;

  /// No description provided for @trashEmptyConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'{count} entries will be permanently deleted. This cannot be undone.'**
  String trashEmptyConfirmMessage(String count);

  /// No description provided for @trashEmptied.
  ///
  /// In en, this message translates to:
  /// **'Trash emptied ({count} entries)'**
  String trashEmptied(String count);

  /// No description provided for @trashMoved.
  ///
  /// In en, this message translates to:
  /// **'Moved to Trash'**
  String get trashMoved;

  /// No description provided for @undo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undo;

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

  /// No description provided for @bitwardenJson.
  ///
  /// In en, this message translates to:
  /// **'Bitwarden-compatible JSON'**
  String get bitwardenJson;

  /// No description provided for @bitwardenJsonDesc.
  ///
  /// In en, this message translates to:
  /// **'For switching to Bitwarden or Vaultwarden (plain text)'**
  String get bitwardenJsonDesc;

  /// No description provided for @saveBitwardenExportDialog.
  ///
  /// In en, this message translates to:
  /// **'Save Bitwarden-Compatible Export'**
  String get saveBitwardenExportDialog;

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

  /// No description provided for @importSourceTitle.
  ///
  /// In en, this message translates to:
  /// **'Import From'**
  String get importSourceTitle;

  /// No description provided for @importFromBitwardenJson.
  ///
  /// In en, this message translates to:
  /// **'Bitwarden / Vaultwarden (.json)'**
  String get importFromBitwardenJson;

  /// No description provided for @importFromBitwardenJsonDesc.
  ///
  /// In en, this message translates to:
  /// **'Use the UNENCRYPTED .json export from Bitwarden'**
  String get importFromBitwardenJsonDesc;

  /// No description provided for @importFromBitwardenCsv.
  ///
  /// In en, this message translates to:
  /// **'Bitwarden / Vaultwarden (.csv)'**
  String get importFromBitwardenCsv;

  /// No description provided for @importFromBitwardenCsvDesc.
  ///
  /// In en, this message translates to:
  /// **'Cards become secure notes; SSH keys are not exported by Bitwarden'**
  String get importFromBitwardenCsvDesc;

  /// No description provided for @pickImportFileTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose the file to import'**
  String get pickImportFileTitle;

  /// No description provided for @bitwardenEncryptedHint.
  ///
  /// In en, this message translates to:
  /// **'That is Bitwarden\'s encrypted export. Re-export and choose “.json” (unencrypted).'**
  String get bitwardenEncryptedHint;

  /// No description provided for @importedSummary.
  ///
  /// In en, this message translates to:
  /// **'Imported {entries} entries, created {folders} folders'**
  String importedSummary(int entries, int folders);

  /// No description provided for @importedSkipped.
  ///
  /// In en, this message translates to:
  /// **'{count} entries were skipped (see details below)'**
  String importedSkipped(int count);

  /// No description provided for @importedSkippedDetails.
  ///
  /// In en, this message translates to:
  /// **'Skipped: {details}'**
  String importedSkippedDetails(String details);

  /// No description provided for @importedLossyNotes.
  ///
  /// In en, this message translates to:
  /// **'{cards} cards were imported as secure notes; {uris} extra URLs were kept as custom fields'**
  String importedLossyNotes(int cards, int uris);

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

  /// No description provided for @entryTypeLabel.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get entryTypeLabel;

  /// No description provided for @entryTypeLogin.
  ///
  /// In en, this message translates to:
  /// **'Login'**
  String get entryTypeLogin;

  /// No description provided for @entryTypeSecureNote.
  ///
  /// In en, this message translates to:
  /// **'Secure note'**
  String get entryTypeSecureNote;

  /// No description provided for @entryTypeIdentity.
  ///
  /// In en, this message translates to:
  /// **'Identity'**
  String get entryTypeIdentity;

  /// No description provided for @entryTypeSshKey.
  ///
  /// In en, this message translates to:
  /// **'SSH key'**
  String get entryTypeSshKey;

  /// No description provided for @entryTypeAll.
  ///
  /// In en, this message translates to:
  /// **'All types'**
  String get entryTypeAll;

  /// No description provided for @entryTypeLoginDesc.
  ///
  /// In en, this message translates to:
  /// **'Username, password, website and two-factor code'**
  String get entryTypeLoginDesc;

  /// No description provided for @entryTypeSecureNoteDesc.
  ///
  /// In en, this message translates to:
  /// **'Free-form text, stored encrypted'**
  String get entryTypeSecureNoteDesc;

  /// No description provided for @entryTypeIdentityDesc.
  ///
  /// In en, this message translates to:
  /// **'Name, ID numbers, contact details and address'**
  String get entryTypeIdentityDesc;

  /// No description provided for @entryTypeSshKeyDesc.
  ///
  /// In en, this message translates to:
  /// **'Public key, private key and fingerprint'**
  String get entryTypeSshKeyDesc;

  /// No description provided for @entryTypeFilterTooltip.
  ///
  /// In en, this message translates to:
  /// **'Filter by type'**
  String get entryTypeFilterTooltip;

  /// No description provided for @entryTypeSwitchTitle.
  ///
  /// In en, this message translates to:
  /// **'Switch entry type?'**
  String get entryTypeSwitchTitle;

  /// No description provided for @entryTypeSwitchMessage.
  ///
  /// In en, this message translates to:
  /// **'Fields that belong to \"{from}\" will be discarded. The name, notes and custom fields are kept.'**
  String entryTypeSwitchMessage(String from);

  /// No description provided for @entryTypeSwitchConfirm.
  ///
  /// In en, this message translates to:
  /// **'Switch'**
  String get entryTypeSwitchConfirm;

  /// No description provided for @entryTypeEmptyForType.
  ///
  /// In en, this message translates to:
  /// **'No {type} entries yet'**
  String entryTypeEmptyForType(String type);

  /// No description provided for @customFieldsSection.
  ///
  /// In en, this message translates to:
  /// **'Custom fields'**
  String get customFieldsSection;

  /// No description provided for @customFieldAdd.
  ///
  /// In en, this message translates to:
  /// **'Add field'**
  String get customFieldAdd;

  /// No description provided for @customFieldLabelHint.
  ///
  /// In en, this message translates to:
  /// **'Label'**
  String get customFieldLabelHint;

  /// No description provided for @customFieldValueHint.
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get customFieldValueHint;

  /// No description provided for @customFieldTypeText.
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get customFieldTypeText;

  /// No description provided for @customFieldTypeHidden.
  ///
  /// In en, this message translates to:
  /// **'Hidden'**
  String get customFieldTypeHidden;

  /// No description provided for @customFieldTypeBoolean.
  ///
  /// In en, this message translates to:
  /// **'Checkbox'**
  String get customFieldTypeBoolean;

  /// No description provided for @customFieldRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove field'**
  String get customFieldRemove;

  /// No description provided for @customFieldNoFields.
  ///
  /// In en, this message translates to:
  /// **'No custom fields'**
  String get customFieldNoFields;

  /// No description provided for @secureNoteBodyLabel.
  ///
  /// In en, this message translates to:
  /// **'Note'**
  String get secureNoteBodyLabel;

  /// No description provided for @secureNoteBodyHint.
  ///
  /// In en, this message translates to:
  /// **'Anything you want to keep encrypted'**
  String get secureNoteBodyHint;

  /// No description provided for @identityPersonalSection.
  ///
  /// In en, this message translates to:
  /// **'Personal'**
  String get identityPersonalSection;

  /// No description provided for @identityContactSection.
  ///
  /// In en, this message translates to:
  /// **'Contact'**
  String get identityContactSection;

  /// No description provided for @identityDocumentSection.
  ///
  /// In en, this message translates to:
  /// **'Documents'**
  String get identityDocumentSection;

  /// No description provided for @identityAddressSection.
  ///
  /// In en, this message translates to:
  /// **'Address'**
  String get identityAddressSection;

  /// No description provided for @identityTitleLabel.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get identityTitleLabel;

  /// No description provided for @identityTitleHint.
  ///
  /// In en, this message translates to:
  /// **'Mr / Ms / Dr'**
  String get identityTitleHint;

  /// No description provided for @identityFirstNameLabel.
  ///
  /// In en, this message translates to:
  /// **'First name'**
  String get identityFirstNameLabel;

  /// No description provided for @identityMiddleNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Middle name'**
  String get identityMiddleNameLabel;

  /// No description provided for @identityLastNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Last name'**
  String get identityLastNameLabel;

  /// No description provided for @identityCompanyLabel.
  ///
  /// In en, this message translates to:
  /// **'Company'**
  String get identityCompanyLabel;

  /// No description provided for @identityEmailLabel.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get identityEmailLabel;

  /// No description provided for @identityPhoneLabel.
  ///
  /// In en, this message translates to:
  /// **'Phone'**
  String get identityPhoneLabel;

  /// No description provided for @identityIdNumberLabel.
  ///
  /// In en, this message translates to:
  /// **'ID number'**
  String get identityIdNumberLabel;

  /// No description provided for @identityPassportLabel.
  ///
  /// In en, this message translates to:
  /// **'Passport number'**
  String get identityPassportLabel;

  /// No description provided for @identityLicenseLabel.
  ///
  /// In en, this message translates to:
  /// **'License number'**
  String get identityLicenseLabel;

  /// No description provided for @identityAddress1Label.
  ///
  /// In en, this message translates to:
  /// **'Address'**
  String get identityAddress1Label;

  /// No description provided for @identityAddress2Label.
  ///
  /// In en, this message translates to:
  /// **'Address line 2'**
  String get identityAddress2Label;

  /// No description provided for @identityCityLabel.
  ///
  /// In en, this message translates to:
  /// **'City'**
  String get identityCityLabel;

  /// No description provided for @identityStateLabel.
  ///
  /// In en, this message translates to:
  /// **'State / Province'**
  String get identityStateLabel;

  /// No description provided for @identityPostalCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Postal code'**
  String get identityPostalCodeLabel;

  /// No description provided for @identityCountryLabel.
  ///
  /// In en, this message translates to:
  /// **'Country / Region'**
  String get identityCountryLabel;

  /// No description provided for @identityBirthdayLabel.
  ///
  /// In en, this message translates to:
  /// **'Birthday'**
  String get identityBirthdayLabel;

  /// No description provided for @identityBirthdayHint.
  ///
  /// In en, this message translates to:
  /// **'YYYY-MM-DD'**
  String get identityBirthdayHint;

  /// No description provided for @identitySexLabel.
  ///
  /// In en, this message translates to:
  /// **'Gender'**
  String get identitySexLabel;

  /// No description provided for @sshKeySection.
  ///
  /// In en, this message translates to:
  /// **'Key material'**
  String get sshKeySection;

  /// No description provided for @sshPublicKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Public key'**
  String get sshPublicKeyLabel;

  /// No description provided for @sshPublicKeyHint.
  ///
  /// In en, this message translates to:
  /// **'ssh-ed25519 AAAA… user@host'**
  String get sshPublicKeyHint;

  /// No description provided for @sshPrivateKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Private key'**
  String get sshPrivateKeyLabel;

  /// No description provided for @sshPrivateKeyHint.
  ///
  /// In en, this message translates to:
  /// **'-----BEGIN OPENSSH PRIVATE KEY-----'**
  String get sshPrivateKeyHint;

  /// No description provided for @sshPassphraseLabel.
  ///
  /// In en, this message translates to:
  /// **'Key passphrase'**
  String get sshPassphraseLabel;

  /// No description provided for @sshFingerprintLabel.
  ///
  /// In en, this message translates to:
  /// **'Fingerprint'**
  String get sshFingerprintLabel;

  /// No description provided for @sshFingerprintAuto.
  ///
  /// In en, this message translates to:
  /// **'Computed from the public key'**
  String get sshFingerprintAuto;

  /// No description provided for @sshKeyTypeLabel.
  ///
  /// In en, this message translates to:
  /// **'Key type'**
  String get sshKeyTypeLabel;

  /// No description provided for @sshBitsLabel.
  ///
  /// In en, this message translates to:
  /// **'Key size'**
  String get sshBitsLabel;

  /// No description provided for @sshBitsValue.
  ///
  /// In en, this message translates to:
  /// **'{bits} bits'**
  String sshBitsValue(int bits);

  /// No description provided for @sshCommentLabel.
  ///
  /// In en, this message translates to:
  /// **'Comment'**
  String get sshCommentLabel;

  /// No description provided for @sshPrivateKeyFormatLabel.
  ///
  /// In en, this message translates to:
  /// **'Detected format'**
  String get sshPrivateKeyFormatLabel;

  /// No description provided for @sshPublicKeyInvalid.
  ///
  /// In en, this message translates to:
  /// **'Could not parse this public key'**
  String get sshPublicKeyInvalid;

  /// No description provided for @sshKeyRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a public key or a private key'**
  String get sshKeyRequired;

  /// No description provided for @sshPrivateKeyFormatValue.
  ///
  /// In en, this message translates to:
  /// **'Detected format: {format}'**
  String sshPrivateKeyFormatValue(String format);

  /// No description provided for @sshNoPrivateKey.
  ///
  /// In en, this message translates to:
  /// **'No private key stored'**
  String get sshNoPrivateKey;

  /// No description provided for @sshRevealPrivateKey.
  ///
  /// In en, this message translates to:
  /// **'Reveal private key'**
  String get sshRevealPrivateKey;

  /// No description provided for @totpCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'One-time code'**
  String get totpCodeLabel;

  /// No description provided for @totpCopyTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy code'**
  String get totpCopyTooltip;

  /// No description provided for @totpRefreshesIn.
  ///
  /// In en, this message translates to:
  /// **'Refreshes in {seconds}s'**
  String totpRefreshesIn(int seconds);

  /// No description provided for @totpNotSet.
  ///
  /// In en, this message translates to:
  /// **'Not configured'**
  String get totpNotSet;

  /// No description provided for @searchHint.
  ///
  /// In en, this message translates to:
  /// **'Search the vault'**
  String get searchHint;

  /// No description provided for @searchPrefixesHint.
  ///
  /// In en, this message translates to:
  /// **'Prefixes: type: login · folder: Work · url: example.com'**
  String get searchPrefixesHint;

  /// No description provided for @folderIconLabel.
  ///
  /// In en, this message translates to:
  /// **'Icon'**
  String get folderIconLabel;

  /// No description provided for @folderEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit folder'**
  String get folderEditTitle;

  /// No description provided for @folderRenamed.
  ///
  /// In en, this message translates to:
  /// **'Folder updated'**
  String get folderRenamed;

  /// No description provided for @renameFolder.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get renameFolder;

  /// No description provided for @healthOnlyLogins.
  ///
  /// In en, this message translates to:
  /// **'Health is scored on login entries only'**
  String get healthOnlyLogins;

  /// No description provided for @healthLoginCount.
  ///
  /// In en, this message translates to:
  /// **'{count} login entries analysed'**
  String healthLoginCount(int count);

  /// No description provided for @fieldCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get fieldCopied;

  /// No description provided for @detailsSection.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get detailsSection;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @themeApplied.
  ///
  /// In en, this message translates to:
  /// **'Theme: {value}'**
  String themeApplied(String value);

  /// No description provided for @browserBridgePromptTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable browser integration'**
  String get browserBridgePromptTitle;

  /// No description provided for @browserBridgePromptBody.
  ///
  /// In en, this message translates to:
  /// **'The browser extension talks to EasyPass through a small host registered on your system. Run this command once (no root needed), then reload the extension:'**
  String get browserBridgePromptBody;

  /// No description provided for @browserBridgePromptCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy command'**
  String get browserBridgePromptCopy;

  /// No description provided for @browserBridgePromptCopied.
  ///
  /// In en, this message translates to:
  /// **'Command copied'**
  String get browserBridgePromptCopied;

  /// No description provided for @browserBridgePromptOk.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get browserBridgePromptOk;

  /// Shown on the Settings/About screen when the Linux tray could not be created (e.g. GNOME without an AppIndicator extension). The fallback is "close exits the app" instead of "close hides to tray".
  ///
  /// In en, this message translates to:
  /// **'System tray unavailable — closing the window will quit the app. (GNOME usually needs the \"AppIndicator and KStatusNotifierItem Support\" extension; KDE Plasma supports trays out of the box.)'**
  String get trayUnavailableNotice;

  /// No description provided for @systemSection.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get systemSection;

  /// No description provided for @autostartTitle.
  ///
  /// In en, this message translates to:
  /// **'Start EasyPass when you log in'**
  String get autostartTitle;

  /// No description provided for @autostartSubtitleEnabled.
  ///
  /// In en, this message translates to:
  /// **'EasyPass starts automatically when you log in.'**
  String get autostartSubtitleEnabled;

  /// No description provided for @autostartSubtitleDisabled.
  ///
  /// In en, this message translates to:
  /// **'EasyPass does not start automatically. Toggle to launch it at login.'**
  String get autostartSubtitleDisabled;

  /// No description provided for @agentAccessSection.
  ///
  /// In en, this message translates to:
  /// **'Agent access'**
  String get agentAccessSection;

  /// No description provided for @agentEnableTitle.
  ///
  /// In en, this message translates to:
  /// **'Agent access (MCP)'**
  String get agentEnableTitle;

  /// No description provided for @agentEnabledSubtitle.
  ///
  /// In en, this message translates to:
  /// **'On — agents can read entries marked open, without you unlocking each time.'**
  String get agentEnabledSubtitle;

  /// No description provided for @agentDisabledSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Off — the MCP service is stopped and agents have no access.'**
  String get agentDisabledSubtitle;

  /// No description provided for @agentWarningBanner.
  ///
  /// In en, this message translates to:
  /// **'Agent access is ON: this vault can be unlocked automatically by EasyPass itself, for any process running as your Windows account. Turn it off to remove that ability immediately.'**
  String get agentWarningBanner;

  /// No description provided for @agentServiceOn.
  ///
  /// In en, this message translates to:
  /// **'MCP service running'**
  String get agentServiceOn;

  /// No description provided for @agentServiceOff.
  ///
  /// In en, this message translates to:
  /// **'MCP service stopped'**
  String get agentServiceOff;

  /// No description provided for @agentEnableFirst.
  ///
  /// In en, this message translates to:
  /// **'Turn on agent access first, then pair an agent.'**
  String get agentEnableFirst;

  /// No description provided for @agentAdvancedSection.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get agentAdvancedSection;

  /// No description provided for @agentResetKey.
  ///
  /// In en, this message translates to:
  /// **'Reset the agent key'**
  String get agentResetKey;

  /// No description provided for @agentResetKeySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Replaces the key that wraps the vault key. The old key stops working immediately; your entries are untouched.'**
  String get agentResetKeySubtitle;

  /// No description provided for @agentResetKeyConfirm.
  ///
  /// In en, this message translates to:
  /// **'Reset the agent key? Every agent using the old key will stop working until you pair it again.'**
  String get agentResetKeyConfirm;

  /// How many times this pairing called the MCP service.
  ///
  /// In en, this message translates to:
  /// **'{count} calls'**
  String agentCalls(String count);

  /// No description provided for @agentAccessTitle.
  ///
  /// In en, this message translates to:
  /// **'Agent access (MCP)'**
  String get agentAccessTitle;

  /// No description provided for @agentAccessSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Pair AI agents, choose how they may act, and decide per entry what they can read.'**
  String get agentAccessSubtitle;

  /// No description provided for @agentDomainLocked.
  ///
  /// In en, this message translates to:
  /// **'Agent session is locked'**
  String get agentDomainLocked;

  /// No description provided for @agentDomainUnlocked.
  ///
  /// In en, this message translates to:
  /// **'Agent session is unlocked'**
  String get agentDomainUnlocked;

  /// No description provided for @agentUnlock.
  ///
  /// In en, this message translates to:
  /// **'Unlock for agents'**
  String get agentUnlock;

  /// No description provided for @agentLock.
  ///
  /// In en, this message translates to:
  /// **'Lock agent session'**
  String get agentLock;

  /// No description provided for @agentPairings.
  ///
  /// In en, this message translates to:
  /// **'Paired agents'**
  String get agentPairings;

  /// No description provided for @agentNoPairings.
  ///
  /// In en, this message translates to:
  /// **'No agent is paired yet.'**
  String get agentNoPairings;

  /// No description provided for @agentCreatePairing.
  ///
  /// In en, this message translates to:
  /// **'Pair an agent'**
  String get agentCreatePairing;

  /// No description provided for @agentPairingNickname.
  ///
  /// In en, this message translates to:
  /// **'Nickname (shown in the audit log)'**
  String get agentPairingNickname;

  /// No description provided for @agentModeApproval.
  ///
  /// In en, this message translates to:
  /// **'Ask every time'**
  String get agentModeApproval;

  /// No description provided for @agentModeTrusted.
  ///
  /// In en, this message translates to:
  /// **'Trusted (no prompts, fully audited)'**
  String get agentModeTrusted;

  /// No description provided for @agentModeSwitch.
  ///
  /// In en, this message translates to:
  /// **'Switch mode'**
  String get agentModeSwitch;

  /// No description provided for @agentRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get agentRevoke;

  /// No description provided for @agentRevokeConfirm.
  ///
  /// In en, this message translates to:
  /// **'Revoke this pairing? The agent loses access immediately.'**
  String get agentRevokeConfirm;

  /// No description provided for @agentKeyOnceTitle.
  ///
  /// In en, this message translates to:
  /// **'Paste this key into your MCP client'**
  String get agentKeyOnceTitle;

  /// No description provided for @agentKeyOnceMessage.
  ///
  /// In en, this message translates to:
  /// **'It is shown only once. EasyPass stores just a hash.'**
  String get agentKeyOnceMessage;

  /// No description provided for @agentCopied.
  ///
  /// In en, this message translates to:
  /// **'Key copied to clipboard'**
  String get agentCopied;

  /// No description provided for @agentMasterPasswordPrompt.
  ///
  /// In en, this message translates to:
  /// **'Confirm with your master password'**
  String get agentMasterPasswordPrompt;

  /// No description provided for @agentConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get agentConfirm;

  /// Shown when an agent-access action (pair, revoke, switch mode, unlock) fails. {detail} is the diagnostic message.
  ///
  /// In en, this message translates to:
  /// **'Operation failed: {detail}'**
  String agentActionFailed(String detail);

  /// No description provided for @agentAccessEntryTitle.
  ///
  /// In en, this message translates to:
  /// **'Accessible to agents'**
  String get agentAccessEntryTitle;

  /// No description provided for @agentAccessEntryOpen.
  ///
  /// In en, this message translates to:
  /// **'Open — agents may read this entry (metadata only).'**
  String get agentAccessEntryOpen;

  /// No description provided for @agentAccessEntryDenied.
  ///
  /// In en, this message translates to:
  /// **'Permanently denied — agents can never read it.'**
  String get agentAccessEntryDenied;

  /// No description provided for @agentApprovalTitle.
  ///
  /// In en, this message translates to:
  /// **'An agent is asking for access'**
  String get agentApprovalTitle;

  /// No description provided for @agentApprovalAgent.
  ///
  /// In en, this message translates to:
  /// **'Agent'**
  String get agentApprovalAgent;

  /// No description provided for @agentApprovalOperation.
  ///
  /// In en, this message translates to:
  /// **'Action'**
  String get agentApprovalOperation;

  /// No description provided for @agentApprovalEntry.
  ///
  /// In en, this message translates to:
  /// **'Entry'**
  String get agentApprovalEntry;

  /// No description provided for @agentApprovalTool.
  ///
  /// In en, this message translates to:
  /// **'Tool'**
  String get agentApprovalTool;

  /// No description provided for @agentApprovalHint.
  ///
  /// In en, this message translates to:
  /// **'Only what is shown here will happen. Deny if you did not expect this request.'**
  String get agentApprovalHint;

  /// No description provided for @agentApprovalAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get agentApprovalAllow;

  /// No description provided for @agentApprovalDeny.
  ///
  /// In en, this message translates to:
  /// **'Deny'**
  String get agentApprovalDeny;

  /// No description provided for @agentApprovalAllowStanding.
  ///
  /// In en, this message translates to:
  /// **'Allow reads for this session'**
  String get agentApprovalAllowStanding;

  /// No description provided for @agentApprovalOpRead.
  ///
  /// In en, this message translates to:
  /// **'Read (metadata)'**
  String get agentApprovalOpRead;

  /// No description provided for @agentApprovalOpSensitiveRead.
  ///
  /// In en, this message translates to:
  /// **'Read a secret'**
  String get agentApprovalOpSensitiveRead;

  /// No description provided for @agentApprovalOpWrite.
  ///
  /// In en, this message translates to:
  /// **'Write'**
  String get agentApprovalOpWrite;

  /// No description provided for @agentApprovalOpDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get agentApprovalOpDelete;

  /// No description provided for @agentAuditTitle.
  ///
  /// In en, this message translates to:
  /// **'Agent activity'**
  String get agentAuditTitle;

  /// No description provided for @agentAuditSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Every AI agent access, with the entry and the outcome.'**
  String get agentAuditSubtitle;

  /// No description provided for @agentAuditEmpty.
  ///
  /// In en, this message translates to:
  /// **'No agent activity yet.'**
  String get agentAuditEmpty;

  /// No description provided for @agentAuditRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get agentAuditRefresh;

  /// Footer of the agent audit list.
  ///
  /// In en, this message translates to:
  /// **'{count} records shown'**
  String agentAuditCount(String count);

  /// No description provided for @agentAuditOpClipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy to clipboard'**
  String get agentAuditOpClipboard;

  /// No description provided for @agentAuditDecisionAllowed.
  ///
  /// In en, this message translates to:
  /// **'Allowed'**
  String get agentAuditDecisionAllowed;

  /// No description provided for @agentAuditDecisionDenied.
  ///
  /// In en, this message translates to:
  /// **'Denied'**
  String get agentAuditDecisionDenied;

  /// No description provided for @agentAuditDecisionTimeout.
  ///
  /// In en, this message translates to:
  /// **'Timed out'**
  String get agentAuditDecisionTimeout;

  /// No description provided for @agentAuditDecisionError.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get agentAuditDecisionError;

  /// No description provided for @agentAuditDecisionAllowedStanding.
  ///
  /// In en, this message translates to:
  /// **'Allowed (session exemption)'**
  String get agentAuditDecisionAllowedStanding;

  /// No description provided for @agentApprovalDetail.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get agentApprovalDetail;

  /// No description provided for @agentModeSwitchTitle.
  ///
  /// In en, this message translates to:
  /// **'Access mode'**
  String get agentModeSwitchTitle;

  /// No description provided for @agentSwitchToApproval.
  ///
  /// In en, this message translates to:
  /// **'Switch to “ask every time”'**
  String get agentSwitchToApproval;

  /// No description provided for @agentSwitchToTrusted.
  ///
  /// In en, this message translates to:
  /// **'Switch to trusted (no prompts)'**
  String get agentSwitchToTrusted;

  /// No description provided for @autostartUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Managed by the OS installer on this platform.'**
  String get autostartUnsupported;

  /// No description provided for @autostartEnabled.
  ///
  /// In en, this message translates to:
  /// **'EasyPass will start automatically at login.'**
  String get autostartEnabled;

  /// No description provided for @autostartDisabled.
  ///
  /// In en, this message translates to:
  /// **'EasyPass will no longer start automatically at login.'**
  String get autostartDisabled;

  /// Shown when the user toggled the autostart switch and the write/delete of ~/.config/autostart/easypass.desktop failed (perm denied, disk full, etc.). {detail} is the diagnostic message.
  ///
  /// In en, this message translates to:
  /// **'Could not change autostart: {detail}'**
  String autostartFailed(String detail);
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
