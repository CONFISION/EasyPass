import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/features/generator/providers/generator_provider.dart';
import 'package:easypass/features/generator/screens/generator_screen.dart';
import 'package:easypass/l10n/app_localizations.dart';

void main() {
  test('default password is 16 characters', () {
    final notifier = GeneratorNotifier();
    expect(notifier.state.length, 16);
    expect(notifier.state.generatedPassword.length, 16);
  });

  test('setLength controls the generated length', () {
    final notifier = GeneratorNotifier();
    notifier.setLength(20);
    expect(notifier.state.generatedPassword.length, 20);
  });

  test('respects character set toggles (numbers only)', () {
    final notifier = GeneratorNotifier();
    notifier.toggleUppercase();
    notifier.toggleLowercase();
    notifier.toggleSymbols();

    final password = notifier.state.generatedPassword;
    expect(password, isNotEmpty);
    expect(RegExp(r'^\d+$').hasMatch(password), isTrue);
    expect(password.length, notifier.state.length);
  });

  test('empty character sets produce an empty password', () {
    final notifier = GeneratorNotifier();
    notifier.toggleUppercase();
    notifier.toggleLowercase();
    notifier.toggleNumbers();
    notifier.toggleSymbols();
    expect(notifier.state.generatedPassword, isEmpty);
  });

  test('each selected character set contributes at least one character', () {
    final notifier = GeneratorNotifier();
    notifier.setLength(64);
    final password = notifier.state.generatedPassword;

    expect(RegExp(r'[A-Z]').hasMatch(password), isTrue);
    expect(RegExp(r'[a-z]').hasMatch(password), isTrue);
    expect(RegExp(r'[0-9]').hasMatch(password), isTrue);
    expect(RegExp(r'[^A-Za-z0-9]').hasMatch(password), isTrue);
  });

  test('regenerate produces a different password (probabilistic)', () {
    final notifier = GeneratorNotifier();
    final first = notifier.state.generatedPassword;
    notifier.generate();
    expect(notifier.state.generatedPassword, isNot(first));
  });

  // ─── 长度上限回归 ────────────────────────────────────────
  // `setLength` 夹在 4..128，而 UI 的 Slider 曾经只到 64 —— 65..128 这段
  // 用户永远滑不到（滑块与 clamp 脱节）。下面两个测试把两端钉死。

  test('setLength clamps to 4..128 (boundaries accepted, beyond clamped)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(generatorProvider.notifier);

    notifier.setLength(4);
    expect(container.read(generatorProvider).length, 4);
    expect(container.read(generatorProvider).generatedPassword.length, 4);

    notifier.setLength(128);
    expect(container.read(generatorProvider).length, 128);
    expect(container.read(generatorProvider).generatedPassword.length, 128);

    notifier.setLength(129);
    expect(container.read(generatorProvider).length, 128);
    notifier.setLength(3);
    expect(container.read(generatorProvider).length, 4);
    notifier.setLength(0);
    expect(container.read(generatorProvider).length, 4);
    notifier.setLength(-1000);
    expect(container.read(generatorProvider).length, 4);
    notifier.setLength(1000000);
    expect(container.read(generatorProvider).length, 128);
  });

  testWidgets('length slider spans the whole 4..128 clamp and reaches 128',
      (tester) async {
    // 最小窗口尺寸下跑（900×600），顺手守住不溢出
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const GeneratorScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final sliderFinder = find.byType(Slider);
    final slider = tester.widget<Slider>(sliderFinder);
    expect(slider.min, 4);
    expect(slider.max, 128, reason: '滑块上限必须跟 setLength 的 clamp 一致');
    expect(slider.divisions, 124, reason: '每一格 1 个字符');

    // 拖到最右：max=64 的旧实现到这里只能得到 64
    await tester.ensureVisible(sliderFinder);
    await tester.pumpAndSettle();
    await tester.drag(sliderFinder, const Offset(2000, 0));
    await tester.pumpAndSettle();

    expect(container.read(generatorProvider).length, 128);
    expect(container.read(generatorProvider).generatedPassword.length, 128);

    // 拖回最左：4 是下限，不会掉到 0。
    // 注意 128 个字符的密码会把滑块顶到屏幕外，先滚回可见再拖。
    await tester.ensureVisible(sliderFinder);
    await tester.pumpAndSettle();
    await tester.drag(sliderFinder, const Offset(-2000, 0));
    await tester.pumpAndSettle();

    expect(container.read(generatorProvider).length, 4);
    expect(container.read(generatorProvider).generatedPassword.length, 4);
    expect(tester.takeException(), isNull, reason: '900×600 下不应有溢出');
  });
}
