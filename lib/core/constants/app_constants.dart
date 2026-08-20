class AppConstants {
  AppConstants._();

  static const String appName = 'EasyPass';
  static const String secureStorageKey = 'easypass_master_key';
  static const String masterPasswordHashKey = 'easypass_master_pw_hash';
  static const String firstRunKey = 'easypass_first_run';
  static const String autoLockStorageKey = 'easypass_auto_lock_minutes';

  // PBKDF2 settings
  static const int pbkdf2Iterations = 100000;
  static const int pbkdf2KeyLength = 32; // 256-bit
  static const int pbkdf2SaltLength = 32;

  // AES settings
  static const int aesKeySize = 256;
  static const int aesIvLength = 16;

  // Auto-lock timeout (minutes)
  static const int autoLockTimeoutMinutes = 5;
}