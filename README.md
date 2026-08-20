# EasyPass

A local-first, Bitwarden-like password manager for Windows, built with Flutter.
All data stays on your machine; nothing is ever sent to the network.

## Features

Phase 1 (MVP):

- **Master password protection** — PBKDF2-HMAC-SHA256 (100,000 iterations)
  derives an AES-256-CBC key; the master password itself is never stored
- **Vault CRUD** — entries with name, URL, username, password, notes and
  TOTP secret, organized into folders with favorites
- **Search** — instant search across name, URL and username
- **Password generator** — configurable length and character sets
- **Auto-lock** — configurable 1–30 minute timeout clears the session key
  from memory
- **Change master password** — verifies the current password and re-encrypts
  the whole vault with a freshly derived key

Phase 2:

- **Browser extension** (Chrome MV3) with login-form auto-fill over Chrome
  Native Messaging
- **Encrypted backup export/import** (restorable) and plain JSON export
- **TOTP** (RFC 6238) codes for two-factor logins

## Security model

- Only the salt and a master-password hash are persisted, via
  `flutter_secure_storage` (DPAPI on Windows).
- Every sensitive field (password, notes, TOTP secret) is AES-256-CBC
  encrypted with the session-derived key before it touches SQLite.
- The derived key lives only in memory and is cleared when the vault locks
  (5 minutes by default).
- Never log or print secrets; pass keys by reference only.

## Build & run

Requires Flutter with Dart SDK `^3.12.2`.

```bash
flutter pub get                                  # install dependencies
dart run build_runner build --delete-conflicting-outputs  # after tables.drift changes
flutter run -d windows                           # run the desktop app
flutter test                                     # run the test suite
flutter build windows                            # release build
```

The SQLite database (`easypass.db`) is created next to the executable.

## Browser extension

The extension in `browser_extension/` (Chrome MV3) talks to the desktop app
through Chrome Native Messaging. The host runs as the desktop executable
itself (`easypass.exe --native-host`, see `lib/main.dart`), so no separate
binary is needed — it shares the same `easypass.db` and secure storage as the
UI. The Dart protocol implementation lives in
`lib/features/browser_bridge/native_messaging_service.dart` (lock/unlock,
credential queries, search, password generation, TOTP).

To register the host with Chrome/Edge, run
`browser_extension/native_host/install_host.ps1` after building
(`uninstall_host.ps1` removes it). Keep `background.js` actions in sync with
`NativeMessagingService.handleRequest`'s switch.

## Testing

Unit tests cover the crypto round-trip, RFC 6238 TOTP vectors, the password
generator, export/import round-trips (encrypted and plain), the auth
lifecycle (set / unlock / change master password, auto-lock settings), the
native messaging host protocol (lock/unlock, credential decryption, TOTP),
and the password health report analysis. Run with `flutter test`.

## Versioning

This project follows a `major.minor.patch` scheme (see `pubspec.yaml`):

- **Major (`x`)** — advanced only on significant underlying architecture
  changes (e.g. crypto-layer rewrite, schema migration, security-model change).
- **Minor (`y`)** — advanced when features are added, removed, or changed.
- **Patch (`z`)** — used for optimizations: bug fixes, performance tweaks,
  and UI polish that do not alter behavior.

## Roadmap

See `Plan.md` (Chinese) for the full roadmap. Cloud sync, password sharing,
health reports and emergency access are planned for Phase 3.
