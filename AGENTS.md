# AGENTS.md

Guidance for AI agents working in this repository.

## Project Overview

**EasyPass** is a local-first password manager (Bitwarden-like) built with Flutter.
Phase 1 (MVP: master-password vault, CRUD, folders, generator, search, auto-lock)
and Phase 2 (browser extension, native messaging, encrypted export/import, TOTP)
are implemented. Phase 3 (cloud sync, multi-platform, health reports) is planned
but not started. See `Plan.md` (Chinese) for the full roadmap.

Security model: the master password is never stored. PBKDF2-HMAC-SHA256
(100,000 iterations) derives an AES-256-CBC key; only salt + hash are persisted
via `flutter_secure_storage`. The derived key lives in a Riverpod
`StateProvider` for the session and is cleared on lock (5-minute auto-lock).

## Build / Test / Lint

Requires Flutter with Dart SDK `^3.12.2`.

```bash
flutter pub get          # install deps
dart run build_runner build --delete-conflicting-outputs   # regenerate database.g.dart (drift)
flutter gen-l10n        # regenerate app_localizations.dart after editing lib/l10n/*.arb
flutter analyze         # lint (flutter_lints)
flutter test            # 38 unit tests: crypto, TOTP (RFC 6238 vectors), generator, export/import, auth lifecycle
flutter run -d windows  # run desktop app
flutter build windows   # release build
```

- **Windows 构建命令固定为 `flutter build windows`** — 每次需要构建 Windows 发布版时都使用这条命令。
- **版本号约定（`major.minor.patch`，见下方 Versioning）** — 推进版本时同步更新 `pubspec.yaml` 的 `version` 字段与 `settings_screen.dart` 中显示的版本号。

- Regenerating code: after editing `lib/data/database/tables.drift`, you **must**
  rerun build_runner — `AppDatabase` and companions in `database.g.dart` are generated.
- Tests live in `test/` with an in-memory `FakeSecureStorage` (`test/fakes.dart`).
  `auth_test.dart` / `export_import_test.dart` override `cryptoServiceProvider`
  and `databaseProvider` with `AppDatabase.forTesting()` and set
  `driftRuntimeOptions.dontWarnAboutMultipleDatabases`.

## Architecture

```
lib/main.dart                  Entry: ProviderScope + portrait lock
lib/app.dart                   MaterialApp.router; go_router routes + auth redirect logic
├── core/
│   ├── constants/app_constants.dart    PBKDF2/AES parameters, secure-storage keys
│   └── crypto/
│       ├── crypto_service.dart         Manual PBKDF2, AES-256-CBC (IV||cipher, base64), secure storage
│       └── totp_service.dart           RFC 6238 TOTP (SHA-1, base32 secret, 30s/6-digit)
├── data/
│   ├── database/
│   │   ├── tables.drift                Schema: folders, password_entries
│   │   ├── database.dart               AppDatabase: DAO queries + streams
│   │   └── database.g.dart             GENERATED — do not edit
│   ├── repositories/vault_repository.dart  Combines db + CryptoService; defines databaseProvider/vaultRepositoryProvider
│   └── services/export_import_service.dart  JSON + encrypted export/import (export_import_provider.dart)
└── features/                           Feature-first UI layer
    ├── auth/     auth_provider.dart (AuthState/AuthNotifier), lock/set-master-password screens
    ├── vault/    vault_provider.dart (stream/future providers), vault CRUD screens, entry_card widget
    ├── generator/ generator_provider.dart, generator_screen.dart
    ├── settings/ settings_screen.dart
    └── browser_bridge/native_messaging_service.dart  stdin/stdout native messaging host
browser_extension/                      Chrome MV3 extension (see below)
windows/                                Generated Flutter Windows runner (CMake)
```

**Data flow (app):** master password → PBKDF2 key → hash verify → key stored in
`encryptionKeyProvider` → UI calls providers → `VaultRepository` → `CryptoService`
encrypts sensitive fields → drift/SQLite (`easypass.db` next to the executable).

**Browser bridge flow:** content-script/popup → `chrome.runtime` message →
`background.js` service worker → native messaging (4-byte length prefix + JSON,
host id `com.easypass.app`) → `NativeMessagingService` → DB queries. Actions:
`getCredentials`, `getAllCredentials`, `searchCredentials`, `getStatus`, `unlock`,
`generatePassword`, `getTotp`. Response always echoes `requestId`; errors come
back in an `error` field.

**Routing / auth gating** is centralized in `lib/app.dart` (`_routerProvider`
redirect): `/lock`, `/set-master-password`, `/vault`, `/vault/add`,
`/vault/edit/:id`, `/vault/entry/:id`, `/generator`, `/settings`.

## Key Files & Directories

- **`lib/core/constants/app_constants.dart`** — crypto parameters (PBKDF2
  iterations=100000, key 32B, salt 32B, IV 16B) and secure-storage key names.
  Changing these breaks stored data.
- **`lib/data/database/tables.drift`** — the schema (folders, password_entries).
  Sensitive columns are `*_encrypted` TEXT; plaintext never touches the DB.
- **`lib/features/browser_bridge/native_messaging_service.dart`** — the native
  messaging host implementation; the bridge contract lives here.
- **`browser_extension/manifest.json`** — MV3 manifest; `nativeMessaging` permission.
- **`browser_extension/native_host/com.easypass.app.json`** — host registration
  pointing at `easypass_native_host.exe`. Note: no CMake target or script in the
  repo currently produces that exe — the host build is not wired up yet.
- **`windows/`** — generated runner; binary name `easypass`; DB file is written
  next to the executable (see `_openConnection()` in `database.dart`).
- **`Plan.md`** — roadmap (Chinese); keep checklist items in sync with feature work.
- **`README.md`** — product README (features, security model, build, extension status).

## Coding Conventions

- **State management:** Riverpod, hand-written providers (`StateNotifierProvider`,
  `StreamProvider`, `StreamProvider`/`FutureProvider.family`, `StateProvider`).
  The repo declares `riverpod_generator`/`riverpod_lint` but **no `@riverpod`
  annotations are used yet** — match the existing hand-written style unless
  deliberately introducing codegen.
- **Layering:** `core` = pure logic (no widgets), `data` = persistence, `features`
  = UI + providers. Features import down into `core`/`data`; `core`/`data` never
  import `features`.
- **Naming:** feature folders contain `screens/`, `providers/`, `widgets/`;
  providers are named `*Provider`; DB companions use Drift naming.
- **Encryption discipline:** passwords/notes/TOTP secrets are always encrypted
  via `CryptoService` before persistence; derive the key from
  `encryptionKeyProvider`; never log or print secrets.
- **Comments:** mixed Chinese/English comments throughout.
- **Localization:** all UI strings live in `lib/l10n/app_en.arb` (source) and
  `app_zh.arb` (Chinese); reference them via `AppLocalizations.of(context)`.
  After adding a key to an ARB file, run `flutter gen-l10n`. The UI follows the
  system locale by default with a manual override in Settings (`localeProvider`
  in `lib/app.dart`).
- **Errors:** services return `bool` + set `errorMessage` on state (auth) or throw
  exceptions caught by callers (native messaging returns `error` field).
- **Auth errors** are error codes (`AuthErrorCodes` in `auth_provider.dart`);
  map them to localized text with `authErrorMessage(l10n, code)`.
- **Auth provider** adds `changeMasterPassword()` (verifies the current password,
  re-encrypts all entries with a fresh key) and `setAutoLockMinutes()` (persisted
  via secure storage); `AuthState.autoLockMinutes` drives the settings UI.
- **Export/import** distinguishes `format: 'encrypted'` backups (restorable) from
  plain JSON; plain imports are re-encrypted with the session key on import.

## Versioning

Semantic versioning `x.y.z`, applied to `pubspec.yaml`'s `version` field and the
in-app version shown on the Settings screen:

- **`x` (major)** — 大版本号。只在发生重大底层架构更新（例如重写加密层、
  数据库迁移、安全模型变更）时推进。
- **`y` (minor)** — 中版本号。有功能变更（新增/移除功能）时推进。
- **`z` (patch)** — 小版本号。一般用于软件优化：bug 修复、性能优化、
  UI 打磨等不改变功能的行为调整。

Rule of thumb: 功能变更 → `y`，纯优化/修复 → `z`，架构/安全模型重构 → `x`。

## Git Workflow

- Branch: `master`; commits are few and direct-to-master (no PR workflow yet).
- Commit messages are **Chinese**, `type: description` style (e.g. `add:添加了浏览器扩展的图标`, `init`).
- `.gitignore` ignores `windows/` and the whole `build/` output tree.

## CI/CD

No CI configuration exists (no `.github/` or equivalent). Tests are not run by
any pipeline; `flutter analyze` and `flutter test` are manual gates.

## Tips for AI Agents

- **After any `tables.drift` change:** run `dart run build_runner build --delete-conflicting-outputs` or the app will fail to compile against stale `database.g.dart`.
- **SQLite file location gotcha:** the DB opens at `Platform.resolvedExecutable`
  dir (`easypass.db`). Widget/unit tests that construct `AppDatabase()` will hit
  the real file — use `AppDatabase.forTesting()` with `NativeDatabase.memory()`
  and override `cryptoServiceProvider` with `FakeSecureStorage` (`test/fakes.dart`).
- **The native host exe is not built by any target.** If you touch
  `NativeMessagingService`, you cannot end-to-end test the extension unless the
  host binary is produced manually; the bridge protocol contract is the single
  source of truth on both sides — keep `background.js` actions in sync with
  `_handleMessage`'s switch.
- **Auth state is async** — `app.dart` redirects on `isLoading` by returning
  `null`; don't assume `authProvider` is resolved when a screen builds.
- **Portrait-locked** in `main.dart`; Windows desktop still respects it via
  `SystemChrome` (harmless, but relevant if adding responsive layouts).
- **Secrets in code:** never print encryption keys/passwords; follow the
  existing pattern of passing `Uint8List` keys around by reference only.
- **Plan.md** tracks Phase 1/2 checkboxes — mark them done when features land;
  Phase 3 items (sync, sharing, health report, emergency access) are not implemented.
