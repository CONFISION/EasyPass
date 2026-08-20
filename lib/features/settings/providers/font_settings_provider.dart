import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/constants/app_constants.dart';
import '../../../data/services/font_discovery_service.dart';

/// All font families the user can pick from: bundled assets first, then
/// system fonts. Cached per app session.
final availableFontsProvider = FutureProvider<FontList>((ref) {
  return FontDiscoveryService.discoverAvailableFonts();
});

/// Selected UI font family setting.
///
/// Values:
/// - `null` — use the bundled default font ([AppConstants.defaultFontFamily])
/// - `AppConstants.systemFontOption` — follow the platform default font
/// - `AppConstants.monospaceFontOption` — use a monospace font
/// - any other string — a custom font family name installed on the system
class FontSettingsNotifier extends StateNotifier<String?> {
  final FlutterSecureStorage _storage;

  FontSettingsNotifier()
      : _storage = const FlutterSecureStorage(),
        super(null) {
    _load();
  }

  Future<void> _load() async {
    final value = await _storage.read(key: AppConstants.fontFamilyStorageKey);
    if (value != null && value.isNotEmpty) {
      state = value;
    }
  }

  Future<void> setFontFamily(String? value) async {
    state = value;
    if (value == null || value.isEmpty) {
      await _storage.delete(key: AppConstants.fontFamilyStorageKey);
    } else {
      await _storage.write(
        key: AppConstants.fontFamilyStorageKey,
        value: value,
      );
    }
  }
}

final fontFamilyProvider =
    StateNotifierProvider<FontSettingsNotifier, String?>((ref) {
  return FontSettingsNotifier();
});
