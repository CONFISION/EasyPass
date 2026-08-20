import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/features/generator/providers/generator_provider.dart';

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
}
