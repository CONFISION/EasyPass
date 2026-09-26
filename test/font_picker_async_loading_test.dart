// P3.4 §6 #8 · `_pickFont` AsyncLoading 首帧一致性测试。
//
// 验证：用户打开"字体"对话框时，**即使** `availableFontsProvider` 还在
// `AsyncLoading`，dialog 也应展示当前字体名（避免 spinner 期间"空 dialog"
// 闪一下）。这是任务书 §6 #8 + 评审 R1 提到的"首帧字体一致性"修复点。
//
// 实现：用 ProviderContainer override 把 `availableFontsProvider` 替换成
// 一个永远不会 resolve 的 FutureProvider，模拟"正在扫盘"的真实场景。

import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/constants/app_constants.dart';
import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/data/services/font_discovery_service.dart';
import 'package:easypass/features/settings/providers/font_settings_provider.dart';
import 'package:easypass/features/settings/screens/settings_screen.dart';
import 'package:easypass/l10n/app_localizations.dart';

import 'fakes.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  /// 永不 resolve 的 [Completer]。测试用它把 [availableFontsProvider] 钉
  /// 在 `AsyncLoading` 状态（任务书 §6 #8 修复点场景）。
  late Completer<FontList> neverCompletes;
  setUp(() {
    neverCompletes = Completer<FontList>();
  });
  tearDown(() {
    if (!neverCompletes.isCompleted) {
      // 用一个 dummy value 完成，避免 Null 类型错误；测试已结束，值不
      // 会被消费（如果消费了说明测试没在异步隔离期间完成）。
      neverCompletes.complete(FontList(bundled: const [], system: const []));
    }
  });

  testWidgets(
    '_pickFont 对话框在 AsyncLoading 期间仍展示当前字体名（首帧一致性）',
    (tester) async {
      // 最小窗口尺寸（windows/runner/win32_window.cpp 的 900×600）下跑。
      tester.view.physicalSize = const Size(900, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer(
        overrides: [
          cryptoServiceProvider.overrideWithValue(
            CryptoService(secureStorage: FakeSecureStorage()),
          ),
          databaseProvider.overrideWithValue(
            AppDatabase.forTesting(NativeDatabase.memory()),
          ),
          fontStorageProvider.overrideWithValue((FakeSecureStorage()
            ..store[AppConstants.fontFamilyStorageKey] = 'Maple Mono NF CN')),
          // 关键：把可用字体 provider 替换成永不 resolve 的替身 —— 模拟
          // "正在扫盘"的真实场景（任务书 §6 #8 修复点）。
          availableFontsProvider.overrideWith((ref) {
            return neverCompletes.future;
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 找到"字体"行并点开对话框。
      final fontTile = find.ancestor(
        of: find.byIcon(Icons.font_download_outlined),
        matching: find.byType(ListTile),
      );
      await tester.ensureVisible(fontTile);
      await tester.pumpAndSettle();
      await tester.tap(fontTile);

      // pump 几次但**不 settle** —— dialog 首帧应当在 AsyncLoading 期间
      // 就已经显示当前字体名（"Maple Mono NF CN"）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      // 关键断言：dialog 打开 + 显示 spinner + 显示当前字体名。
      expect(find.byType(AlertDialog), findsOneWidget,
          reason: 'dialog 必须打开');
      expect(find.byType(CircularProgressIndicator), findsWidgets,
          reason: 'loading 状态必须展示 spinner');
      // 关键断言：dialog **内部**能找到当前字体名（不仅仅在 Settings
      // ListTile 的 subtitle 里 —— 那条会污染断言）。P3.4 §6 #8 修复点
      // 是 dialog loading 状态也要展示当前字体名（首帧一致性）。
      final dialogText = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Maple Mono NF CN'),
      );
      expect(dialogText, findsOneWidget,
          reason: 'loading 期间 dialog **内部**必须展示当前字体名（任务书'
              ' §6 #8 修复点）');

      // 反向断言：第 0 项修复前的"空 dialog"行为 ——
      // dialog**不**应只显示一个 spinner 而没有当前字体名。
      // （"任何"状态下都能找到当前字体名 = 找到至少一个 widget）
      expect(find.text('Maple Mono NF CN'), findsWidgets,
          reason: 'loading 期间 dialog 也必须展示当前字体名');
    },
  );

  testWidgets(
    '_pickFont 数据到达后展示 font list（_FontPickerList）',
    (tester) async {
      tester.view.physicalSize = const Size(900, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer(
        overrides: [
          cryptoServiceProvider.overrideWithValue(
            CryptoService(secureStorage: FakeSecureStorage()),
          ),
          databaseProvider.overrideWithValue(
            AppDatabase.forTesting(NativeDatabase.memory()),
          ),
          fontStorageProvider.overrideWithValue(FakeSecureStorage()),
          // 提供一份**立刻**可用的字体列表（带 2 个 bundle + 1 个 system）。
          availableFontsProvider.overrideWith((ref) async => const FontList(
                bundled: ['Maple Mono NF CN'],
                system: ['DejaVu Sans', 'Liberation Serif'],
              )),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final fontTile = find.ancestor(
        of: find.byIcon(Icons.font_download_outlined),
        matching: find.byType(ListTile),
      );
      await tester.ensureVisible(fontTile);
      await tester.pumpAndSettle();
      await tester.tap(fontTile);
      await tester.pumpAndSettle();

      // 数据回来后：spinner 不再显示，列表显示 3 个字体名。
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Maple Mono NF CN'), findsOneWidget);
      expect(find.text('DejaVu Sans'), findsOneWidget);
      expect(find.text('Liberation Serif'), findsOneWidget);
    },
  );
}