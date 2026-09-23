import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/constants/app_constants.dart';

/// 主题模式在安全存储里的序列化值：`'system'` / `'light'` / `'dark'`
/// （即 [ThemeMode.name]）。
String themeModeToStorageValue(ThemeMode mode) => mode.name;

/// 容错解析存储里的主题值。
///
/// 缺失（`null`）、空串、以及任何未知值（旧版本 / 写坏的数据）一律回退到
/// [ThemeMode.system] —— 这个函数**不抛异常**，是启动路径上的安全网。
ThemeMode themeModeFromStorageValue(String? value) {
  switch (value) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}

/// 主题设置（跟随系统 / 浅色 / 深色），持久化在 `flutter_secure_storage` 里。
///
/// 与 `FontSettingsNotifier`（字体设置）同一套路数：构造时异步读取，读取期间先用默认值
/// （[ThemeMode.system]）渲染，读到之后再更新 —— 因此启动永远不会因为存储
/// 不可用 / 值损坏而卡住或崩溃。
class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  final FlutterSecureStorage _storage;

  /// 首次读取存储的 Future。
  ///
  /// UI 不需要等它（默认值已经是跟随系统），但测试可以 `await ready` 消除
  /// 竞态，不必猜延时。
  late final Future<void> ready;

  ThemeModeNotifier(FlutterSecureStorage storage)
      : _storage = storage,
        super(ThemeMode.system) {
    ready = _load();
  }

  Future<void> _load() async {
    ThemeMode loaded;
    try {
      final stored = await _storage.read(key: AppConstants.themeModeStorageKey);
      loaded = themeModeFromStorageValue(stored);
    } catch (_) {
      // 存储读不出来（无原生实现 / 权限问题）时不能拖垮启动。
      loaded = ThemeMode.system;
    }
    if (!mounted) return;
    state = loaded;
  }

  /// 切换主题模式并落盘。写失败只影响"下次启动的恢复"，不回滚内存状态，
  /// 也不向上抛 —— 主题切换不该让 UI 报错。
  Future<void> setThemeMode(ThemeMode mode) async {
    if (!mounted) return;
    state = mode;
    try {
      await _storage.write(
        key: AppConstants.themeModeStorageKey,
        value: themeModeToStorageValue(mode),
      );
    } catch (_) {
      // 忽略：内存里已经生效，下次启动退回默认值。
    }
  }
}

/// 主题设置使用的安全存储实例；测试用 `FakeSecureStorage` 覆盖它。
final themeStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage();
});

/// 当前主题模式，驱动 `MaterialApp.router` 的 `themeMode`。
final themeModeProvider =
    StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  return ThemeModeNotifier(ref.watch(themeStorageProvider));
});
