import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/features/vault/screens/add_edit_entry_screen.dart';
import 'package:easypass/l10n/app_localizations.dart';

import 'fakes.dart';

/// Regression test: the suggested password pre-filled on the add-entry screen
/// must be regenerated on every open, not frozen for the whole app session.
///
/// Root cause (fixed): `generatorProvider` is a session-wide singleton whose
/// notifier only generates once at construction; the screen used to read the
/// cached value without calling `generate()`, so the same password appeared
/// until the app was restarted.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        cryptoServiceProvider.overrideWithValue(
          CryptoService(secureStorage: FakeSecureStorage()),
        ),
        databaseProvider.overrideWithValue(
          AppDatabase.forTesting(NativeDatabase.memory()),
        ),
      ],
    );
  });

  tearDown(() => container.dispose());

  Future<void> pumpAddEntryScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const AddEditEntryScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  /// The password field is the 4th TextFormField (name, url, username,
  /// password).
  String readPasswordField(WidgetTester tester) {
    final field = tester.widget<TextFormField>(
      find.byType(TextFormField).at(3),
    );
    return field.controller?.text ?? '';
  }

  testWidgets('open add-entry twice in one session yields different passwords',
      (tester) async {
    // First open.
    await pumpAddEntryScreen(tester);
    final firstPassword = readPasswordField(tester);
    expect(firstPassword, isNotEmpty,
        reason: 'add screen pre-fills a password');

    // Close the screen (unmount), then open it again — same ProviderScope,
    // simulating the user adding another entry without restarting the app.
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpAddEntryScreen(tester);
    final secondPassword = readPasswordField(tester);
    expect(secondPassword, isNotEmpty);

    expect(
      secondPassword,
      isNot(equals(firstPassword)),
      reason: 'each add-entry screen open must pre-fill a fresh password',
    );
  });
}
