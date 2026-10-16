# Changelog

All notable changes to EasyPass are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — architecture or security-model change (crypto layer rewrite, database
  migration, key hierarchy rework)
- **minor** — new or removed features
- **patch** — bug fixes, performance and UI polish that do not change features

> Version numbers are kept in sync in **four** places: `pubspec.yaml`,
> `lib/features/settings/screens/settings_screen.dart`,
> `browser_extension/manifest.json`, and `installer/easypass_setup.iss`.
> `node browser_extension/tools/check_extension.mjs` fails if they disagree.

---

## [Unreleased] — 2.4.0

### Added

- **Bitwarden / Vaultwarden import** (`lib/data/services/bitwarden_importer.dart`).
  Reads the *unencrypted* Bitwarden JSON export and the CSV export. Folders are
  recreated by name and reused on re-import. Cards (which EasyPass has no type for)
  are imported as secure notes with the card data preserved in custom fields; extra
  URIs on a login are kept as custom fields; password history and the fields
  Bitwarden has but EasyPass does not are appended to the notes. The import reports
  exactly how many entries were skipped and why — never a silent partial import.
- **Bitwarden-compatible export** (`ExportImportService.exportBitwardenJson`), so a
  migration is not a one-way door. SSH keys, which Bitwarden has no type for, are
  exported as secure notes with the key material in custom fields and an explicit
  note explaining the downgrade.
- **Master-password rotation journal** (`vault_meta` table, schema **3**). Rotating
  the master password now writes the target salt + verifier and the whole-vault
  re-encryption in **one SQLite transaction**, so the two can no longer disagree.
- **CI** (GitHub Actions): `flutter analyze`, `flutter test`, the browser-extension
  self-checks and the native-runner syntax check on every push and pull request;
  tagged releases build the installer and the AppImage and publish them with
  `SHA256SUMS.txt`.
- **Release tooling**: `installer/release/collect_artifacts.mjs` generates the
  checksum file and a machine-readable artifact manifest, instead of recalling the
  artifact list by hand.
- `SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md`.

### Fixed

- **Data-loss class: a failed master-password change could lock the vault
  permanently.** The old sequence was "re-encrypt the whole vault, *then* write the
  new salt + verifier to the OS keychain". `storeKeyMaterial` itself writes two
  values (salt first, hash second), so a failure in between left the ciphertext on
  the new key while the stored verifier belonged to the old salt — **neither the old
  nor the new master password could open the vault**, and the entries decrypted to
  empty strings. This is reachable in practice on Linux (Secret Service unavailable
  or locked) and on Windows (a process demoted to Low integrity cannot write
  `%APPDATA%`). The vault is now all-or-nothing: the journal and the re-encryption
  commit together, a keychain failure leaves the new password usable via the
  journal, and the journal is retried and cleared on the next successful unlock.
  See `test/master_password_rotation_atomicity_test.dart`.
- **The old master password kept working after a change** (found on the first real
  hardware run, after the fix above had already landed). "Verify the master password"
  had **three** separate implementations (`AuthNotifier.unlock`,
  `NativeMessagingService._unlock` for the browser extension, and
  `EntryDetailScreen._verify` for the reveal-private-key prompt), and only the first
  knew about the rotation journal. Whenever a rotation did not get its verifier into
  the OS keychain, the other two kept accepting the old password — its hash still
  matched the stale keychain copy — and rejected the new one. All three now go
  through a single `MasterPasswordVerifier`, whose rule is: **a rotation journal
  exists ⇒ only the journal's target password is valid; the keychain copy is stale.**
- **Changing the master password left the vault unlocked**, returning straight to the
  vault instead of to the lock screen. That made a broken rotation undetectable —
  nothing forced the user to prove the new password worked. The app now clears the
  session key, locks the browser-bridge session too, and returns to `/lock`.
- A failed keychain write during rotation now says so on the lock screen instead of
  leaving the user at an unexplained prompt (the new password is still valid; the
  verifier is served from the in-vault journal).
- `encryptionProbeWorks` only inspected the first row, so one corrupt row made a
  working key look wrong — which broke the deliberate "a single undecryptable entry
  must not affect the whole report" property.

### Changed

- Unlock consults the rotation journal as well as secure storage.
- The browser extension no longer requests the `storage`, `scripting` or `activeTab`
  permissions — no code path used them.

---

## [2.3.3] — Linux desktop port

### Added

- **Linux desktop support (AppImage)**: tray icon and close-to-tray via
  GTK/AppIndicator, single instance (`easypass.db.lock` + unix socket wake-up),
  XDG autostart, desktop-entry CLI (`--install` / `--uninstall` /
  `--desktop-status`) and native-messaging host registration
  (`--install-browser-host` / `--uninstall-browser-host` / `--browser-host-status`).
- The vault lives in `$XDG_DATA_HOME/easypass/` on Linux (permissions tightened to
  `0700`/`0600`), with migration of a legacy database file next to the executable.
- The native-messaging host on Linux is the app binary itself
  (`easypass --native-host`); there is no separate x86 bridge.

### Fixed

- Settings screens surface font-setting load/save failures instead of silently
  falling back.
- The storage-unavailable state stays visible with Retry/Exit instead of deadlocking.
- The daemon persists `daemon.json` only after it is listening, validates pid
  liveness, and redacts error details.
- Linux tray: the embedder delete-event is disconnected so the tray survives close.
- The AppImage bundles `libsqlite3` and fails loudly when the sqlite plugin target is
  missing.

---

## [2.3.0] — entry types

### Added

- Four entry types: login, secure note, identity and SSH key, plus custom fields on
  every type.
- Folder management (icons, rename, guarded delete), `type:` / `folder:` / `url:`
  search prefixes, live TOTP codes.
- `EntryPayload` JSON (identity + SSH blocks and all custom fields) encrypted into the
  new `data_encrypted` column; schema **2** with a real 1→2 migration.
- Bridge protocol **3**: entry JSON carries `type` / `identity` / `sshKey` /
  `customFields`; `hasTotp` replaces the raw TOTP secret; `getCredentials` returns
  login entries only.

### Removed

- Unused `riverpod_generator` / `riverpod_lint` / `custom_lint` dev-dependencies
  (they produced nothing here and pinned `analyzer ^7`, which broke drift codegen).

---

## [2.2.2] and earlier

See the git history. Highlights: the browser extension became functional
(autofill, session keep-alive, protocol extension) in 2.2.0; encrypted export/import
and TOTP in Phase 2; the Phase 1 MVP (master-password vault, CRUD, folders,
generator, search, auto-lock) came first.

[Unreleased]: https://github.com/CONFISION/EasyPass/compare/v2.3.3...HEAD
[2.3.3]: https://github.com/CONFISION/EasyPass/releases/tag/v2.3.3
