import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/constants/app_constants.dart';
import '../../../data/services/font_discovery_service.dart';

/// All font families the user can pick from: bundled assets first, then
/// system fonts. Cached per app session.
final availableFontsProvider = FutureProvider<FontList>((ref) {
  return FontDiscoveryService.discoverAvailableFonts();
});

/// Storage used by [FontSettingsNotifier]. Exposed as an override so tests
/// can swap in [FakeSecureStorage] (mirrors `themeStorageProvider` pattern).
final fontStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage();
});

/// Selected UI font family setting.
///
/// Values:
/// - `null` — use the bundled default font ([AppConstants.defaultFontFamily])
/// - `AppConstants.systemFontOption` — follow the platform default font
/// - `AppConstants.monospaceFontOption` — use a monospace font
/// - any other string — a custom font family name installed on the system
class FontSettingsNotifier extends StateNotifier<AsyncValue<String?>> {
  final FlutterSecureStorage _storage;

  FontSettingsNotifier(FlutterSecureStorage storage)
    : _storage = storage,
      super(const AsyncLoading<String?>()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await _storage.read(key: AppConstants.fontFamilyStorageKey);
      state = AsyncData<String?>(
        value != null && value.isNotEmpty ? value : null,
      );
    } catch (error, stackTrace) {
      // A keyring error is actionable.  Publish it instead of silently
      // treating an unavailable setting as the bundled default.
      state = AsyncError<String?>(error, stackTrace);
    }
  }

  Future<void> setFontFamily(String? value) async {
    try {
      if (value == null || value.isEmpty) {
        await _storage.delete(key: AppConstants.fontFamilyStorageKey);
      } else {
        await _storage.write(
          key: AppConstants.fontFamilyStorageKey,
          value: value,
        );
      }
      // Publish the value only after persistence succeeds.
      state = AsyncData<String?>(value);
    } catch (error, stackTrace) {
      state = AsyncError<String?>(error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

final fontFamilyProvider =
    StateNotifierProvider<FontSettingsNotifier, AsyncValue<String?>>((ref) {
      return FontSettingsNotifier(ref.watch(fontStorageProvider));
    });
