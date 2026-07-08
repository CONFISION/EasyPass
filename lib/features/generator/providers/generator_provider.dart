import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class GeneratorState {
  final int length;
  final bool useUppercase;
  final bool useLowercase;
  final bool useNumbers;
  final bool useSymbols;
  final String generatedPassword;

  const GeneratorState({
    this.length = 16,
    this.useUppercase = true,
    this.useLowercase = true,
    this.useNumbers = true,
    this.useSymbols = true,
    this.generatedPassword = '',
  });

  GeneratorState copyWith({
    int? length,
    bool? useUppercase,
    bool? useLowercase,
    bool? useNumbers,
    bool? useSymbols,
    String? generatedPassword,
  }) {
    return GeneratorState(
      length: length ?? this.length,
      useUppercase: useUppercase ?? this.useUppercase,
      useLowercase: useLowercase ?? this.useLowercase,
      useNumbers: useNumbers ?? this.useNumbers,
      useSymbols: useSymbols ?? this.useSymbols,
      generatedPassword: generatedPassword ?? this.generatedPassword,
    );
  }
}

class GeneratorNotifier extends StateNotifier<GeneratorState> {
  GeneratorNotifier() : super(const GeneratorState()) {
    generate();
  }

  void setLength(int length) {
    state = state.copyWith(length: length.clamp(4, 128));
    generate();
  }

  void toggleUppercase() {
    state = state.copyWith(useUppercase: !state.useUppercase);
    generate();
  }

  void toggleLowercase() {
    state = state.copyWith(useLowercase: !state.useLowercase);
    generate();
  }

  void toggleNumbers() {
    state = state.copyWith(useNumbers: !state.useNumbers);
    generate();
  }

  void toggleSymbols() {
    state = state.copyWith(useSymbols: !state.useSymbols);
    generate();
  }

  void generate() {
    final random = Random.secure();
    final charSets = <String>[];

    if (state.useUppercase) charSets.add('ABCDEFGHIJKLMNOPQRSTUVWXYZ');
    if (state.useLowercase) charSets.add('abcdefghijklmnopqrstuvwxyz');
    if (state.useNumbers) charSets.add('0123456789');
    if (state.useSymbols) charSets.add('!@#\$%^&*()-_=+[]{}|;:,.<>?');

    if (charSets.isEmpty) {
      state = state.copyWith(generatedPassword: '');
      return;
    }

    final allChars = charSets.join();

    // Ensure at least one character from each selected set
    final password = StringBuffer();
    for (final set in charSets) {
      password.write(set[random.nextInt(set.length)]);
    }

    // Fill the rest with random characters
    while (password.length < state.length) {
      password.write(allChars[random.nextInt(allChars.length)]);
    }

    // Shuffle the password
    final shuffled = password.toString().split('')..shuffle(random);

    state = state.copyWith(generatedPassword: shuffled.join());
  }
}

final generatorProvider =
    StateNotifierProvider<GeneratorNotifier, GeneratorState>((ref) {
  return GeneratorNotifier();
});