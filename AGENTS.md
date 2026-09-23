# AGENTS.md

Guidance for AI agents working in this repository.

## Project Overview

**EasyPass** is a local-first password manager (Bitwarden-like) built with Flutter.
Phase 1 (MVP: master-password vault, CRUD, folders, generator, search, auto-lock)
and Phase 2 (browser extension, native messaging, encrypted export/import, TOTP)
are implemented. **2.3.x** adds four entry types (login / secure note / identity /
SSH key) with custom fields, live TOTP codes, folder management (icons, rename,
guarded delete), type filtering and `type:`/`folder:`/`url:` search prefixes.
Phase 3 (cloud sync, sharing, emergency access, multi-platform) is still planned.

> **Local-only docs (NOT in a fresh clone — `.gitignore` excludes them):** the
> roadmap `Plan.md`, the working agreement/pitfalls `HANDOFF.md`, the 2.3.x
> interface contract `docs/entry-types.md`, the acceptance checklist
> `docs/acceptance-2.3.0.md` and release notes under `docs/`. Never write a
> committed file that *depends* on them; this file and the READMEs must stand alone.

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
flutter test            # 412 unit/integration tests: crypto, TOTP, generator, entry types, export/import, auth, daemon, bridge, vault UI
flutter run -d windows  # run desktop app
flutter build windows   # release build
```

- **Windows 构建命令固定为 `flutter build windows`** — 每次需要构建 Windows 发布版时都使用这条命令。
- **C++ runner 改动可以不用 MSBuild 验证** — `windows\runner\check_syntax.bat` 用与真实构建相同的开关
  （`/W4 /WX`、`cl /Zs`）对 `windows/runner/*.cpp` 做语法与类型检查，不产出任何文件、不调用 MSBuild。
  改过 `windows/runner/**` 后先跑它，别把编译错误留给用户。
- **窗口最小尺寸在原生层强制** — `windows/runner/win32_window.cpp` 的 `WM_GETMINMAXINFO`
  （`kMinWindowWidth/kMinWindowHeight` = 900×600 逻辑像素，按 DPI 缩放，并夹到显示器工作区内）。
  这两个常量必须与 `lib/features/vault/screens/vault_screen.dart` 里侧边栏的固定宽度保持一致，
  否则窄窗又会溢出。
- **构建分工（重要约定）** — Windows 原生构建（`flutter build windows` / `flutter run -d windows`）
  由用户亲自执行；agent 负责到构建前的完整测试与 debug（`flutter analyze`、`flutter test`、
  代码审查与修复）。agent 的执行环境与 MSBuild 存在兼容问题（FileTracker 崩溃），
  不要尝试在 agent 侧执行原生构建，也不要将其结果作为交付依据。
- **同理：凡是产出最终交付物的构建/打包，都交给用户** —— 安装包（ISCC）、`docker build`、
  `npm run build`、代码签名、发布上传等，agent 一律不自行执行；交付前把**确切命令**与
  验收要点写清楚即可。只读/轻量验证（测试、lint、语法检查、协议探针）agent 应当自己跑。
- **版本号约定（`major.minor.patch`，见下方 Versioning）** — 推进版本时同步更新 `pubspec.yaml` 的
  `version` 字段、`settings_screen.dart` 中显示的版本号、扩展 `manifest.json` 的 `version`
  与 `installer/easypass_setup.iss` 的 `MyAppVersion` / `VersionInfoVersion`
  （`browser_extension/tools/check_extension.mjs` 会校验这四处一致）。
- **打包安装包** — `& "C:\Program Files\Inno Setup 7\ISCC.exe" installer\easypass_setup.iss`
  （用户执行；产物在 `build\installer\EasypassSetup.exe`）。安装包需要 app-local 的
  MSVC 运行时（`msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll`），而 Flutter 生成的
  runner **不会**把它拷进 `build\windows\x64\runner\Release`（`windows/CMakeLists.txt` 的 `install()`
  只带 app/ICU/插件 DLL/字体/资源）：`installer/copy_vc_runtime.bat` 负责拷贝，并由
  `windows/runner/CMakeLists.txt` 的 POST_BUILD 调用（**该文件入库受版本控制，别把这段 hook 删了**）；
  `.iss` 里还有一层系统目录兜底，缺文件时不会中止编译。

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
│   │   ├── tables.drift                Schema: folders, password_entries (schemaVersion 2)
│   │   ├── database.dart               AppDatabase: DAO queries + streams + migrations
│   │   └── database.g.dart             GENERATED — do not edit
│   ├── models/                         Entry types + payload models (2.3.0)
│   │   ├── entry_type.dart             EntryType enum (login/secure_note/identity/ssh_key) + wire names
│   │   ├── entry_fields.dart           LoginData / IdentityData / SshKeyData / CustomField / EntryPayload
│   │   ├── vault_item.dart             VaultItem: the single decrypted domain model used by UI/bridge/export
│   │   └── vault_item_mapper.dart      VaultItem ↔ DB row: the ONLY place that encrypts/decrypts entry fields
│   ├── repositories/vault_repository.dart  Item API (watchItems/saveItem/searchItems/reencryptAll) + legacy row API
│   ├── state/session_key.dart          encryptionKeyProvider (data layer so the repo can read the key)
│   └── services/export_import_service.dart  JSON + encrypted export/import (export_import_provider.dart)
├── core/crypto/ssh_key_service.dart    OpenSSH public-key parsing + SHA256/MD5 fingerprints (pure)
└── features/                           Feature-first UI layer
    ├── auth/     auth_provider.dart (AuthState/AuthNotifier), lock/set-master-password screens
    ├── vault/    vault_provider.dart (stream/future providers), vault CRUD screens,
    │             widgets/{entry_card,entry_type_bits,custom_fields_editor,custom_fields_view}.dart
    ├── generator/ generator_provider.dart, generator_screen.dart
    ├── settings/ settings_screen.dart, providers/{font_settings,theme}_provider.dart
    └── browser_bridge/  native_messaging_service.dart (protocol), vault_session.dart (session),
                         url_matcher.dart (URL↔entry), browser_session_registry.dart, easypass_daemon.dart
browser_extension/                      Chrome MV3 extension (see below)
docs/entry-types.md                     2.3.x interface contract (LOCAL ONLY — gitignored)
docs/acceptance-2.3.0.md                Manual acceptance checklist (LOCAL ONLY — gitignored)
windows/                                Generated Flutter Windows runner (CMake)
```

**Data flow (app):** master password → PBKDF2 key → hash verify → key stored in
`encryptionKeyProvider` (defined in `lib/data/state/session_key.dart`) → UI calls
providers → `VaultRepository` → `VaultItemMapper` → `CryptoService` encrypts
sensitive fields → drift/SQLite (`easypass.db` next to the executable).

**Entry types (2.3.x):** one row can be `login`, `secure_note`, `identity` or
`ssh_key`. Login fields stay in the legacy columns (`url`, `username`,
`password_encrypted`, `totp_secret_encrypted`) so old data needs no rewrite; the
type-specific blocks for identity/SSH **and the custom fields of every type** are
serialised as `EntryPayload` JSON and stored encrypted in `data_encrypted`.

**Browser bridge flow:** content-script/popup → `chrome.runtime` message →
`background.js` service worker → native messaging (4-byte length prefix + JSON,
host id `com.easypass.app`) → bridge exe → daemon (`easypass.exe --service`) →
`NativeMessagingService` → repository queries. Actions: `getStatus`, `unlock`,
`lock`, `getCredentials`, `getAllCredentials`, `searchCredentials`,
`generatePassword`, `getTotp`, `getHealthReport`. Response always echoes
`requestId`; errors come back in an `error` field. Since protocol 3 the entry JSON
carries `type` + per-type blocks (`identity` / `sshKey` / `customFields`);
`hasTotp` replaces the TOTP secret, and `getCredentials` (autofill candidates)
returns **login entries only**.

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
  pointing at `easypass_native_host.exe`; the installer rewrites the equivalent
  manifest under `%LOCALAPPDATA%\EasyPass\` to point at the install directory.
- **`windows/`** — generated runner; binary name `easypass`; DB file is written
  next to the executable (see `_openConnection()` in `database.dart`).
- **`Plan.md`** — roadmap (Chinese, **local-only**; not in a fresh clone).
- **`README.md`** / **`README_zh.md`** — product READMEs (features, security model, build, extension status).

## Coding Conventions

- **State management:** Riverpod, hand-written providers (`StateNotifierProvider`,
  `StreamProvider`, `StreamProvider`/`FutureProvider.family`, `StateProvider`).
  **No `@riverpod` codegen** — match the existing hand-written style. (2.3.0 removed the
  unused `riverpod_generator` / `riverpod_lint` / `custom_lint` dev-dependencies: they
  produced nothing here, and `custom_lint ^0.7` pinned `analyzer ^7`, which is what broke
  drift code generation on the current Dart SDK. Re-adding them means upgrading the whole
  riverpod family and re-checking codegen — see the comments in `pubspec.yaml`.)
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
- `.gitignore` ignores the whole `build/` output tree; `windows/flutter/ephemeral/` is
  ignored by `windows/.gitignore`. **The rest of `windows/` IS tracked** (runner sources,
  CMake files, icon) — treat it as normal source, not as disposable generated output.

## CI/CD

No CI configuration exists (no `.github/` or equivalent). Tests are not run by
any pipeline; `flutter analyze` and `flutter test` are manual gates.

## Tips for AI Agents

- **After any `tables.drift` change:** run `dart run build_runner build --delete-conflicting-outputs` or the app will fail to compile against stale `database.g.dart`.
  Codegen needs an `analyzer` that understands the installed Dart SDK: with a too-old
  analyzer, `drift_dev` dies with `Missing implementation of visitDotShorthandPropertyAccess`
  and **writes nothing** (while `--delete-conflicting-outputs` has already deleted the old
  file, leaving the repo uncompilable). If that happens, bump `drift`/`drift_dev`/
  `build_runner` together (see `pubspec.yaml`) before touching the schema.
- **Schema changes need a migration, not just a column.** `schemaVersion` is 2 and
  `AppDatabase.migration.onUpgrade` implements 1→2 for real; every new column must be added
  there too, or existing installs fail to open with "no such column". `test/migration_test.dart`
  builds a v1 database by hand and asserts the upgrade — extend it when you add a column.
  Also: drift does **not** enable SQLite foreign keys, so `ON DELETE SET NULL` never fires —
  `deleteFolderAndUnassign()` clears `folder_id` explicitly.
- **SQLite file location gotcha:** the DB opens at `Platform.resolvedExecutable`
  dir (`easypass.db`). Widget/unit tests that construct `AppDatabase()` will hit
  the real file — use `AppDatabase.forTesting()` with `NativeDatabase.memory()`
  and override `cryptoServiceProvider` with `FakeSecureStorage` (`test/fakes.dart`).
- **The native host exe IS built by the Windows build.** `windows/runner/CMakeLists.txt`
  (tracked in git) has a POST_BUILD step that runs `browser_extension/native_host/build_bridge.bat`
  (cl.exe, x86, no MSBuild) next to `easypass.exe`; a second POST_BUILD step copies the MSVC
  runtime DLLs via `installer/copy_vc_runtime.bat`. Keep both hooks when touching that file.
  The bridge protocol contract is the single source of truth on both sides —
  keep `background.js` actions in sync with `handleRequest`'s switch.
- **Auth state is async** — `app.dart` redirects on `isLoading` by returning
  `null`; don't assume `authProvider` is resolved when a screen builds.
- **Portrait-locked** in `main.dart`; Windows desktop still respects it via
  `SystemChrome` (harmless, but relevant if adding responsive layouts).
- **Secrets in code:** never print encryption keys/passwords; follow the
  existing pattern of passing `Uint8List` keys around by reference only.
- **Plan.md** (local-only) holds the roadmap: v2.4 = extension store listing + Bitwarden import + CI +
  release engineering; v3.0 = key-hierarchy rework + self-hosted sync. Sync is **not** implemented, and the
  health report is (login entries only).
- **Protocol versioning (2.2.1+):** the daemon stamps `protocolVersion` + `pid` into
  `daemon.json` and returns `protocolVersion` from `getStatus`.
  `AppConstants.bridgeProtocolVersion` (`lib/core/constants/app_constants.dart`) and
  `EXPECTED_PROTOCOL_VERSION` (`browser_extension/background.js`) **must be bumped
  together** whenever the bridge protocol changes incompatibly. This is what lets the app
  retire a stale daemon after an upgrade — without it the extension keeps talking to the
  old process and reports `Unknown action: …`.
- **Debug tools (no browser needed):** `node browser_extension/tools/probe_bridge.mjs`
  (end-to-end: spawns the bridge, talks to the real daemon) and
  `node browser_extension/tools/probe_daemon.mjs` (talks to an already-running daemon)
  tell you whether the bridge, the daemon or the extension is at fault. The jsdom smoke
  scripts plus `check_extension.mjs` are the regression net for extension changes.

## Pitfalls we already paid for

Each of these cost real debugging time — do not re-introduce them. The Chinese long-form
version lives in the local `HANDOFF.md` (section 4, "踩过的坑").

- **`Text` inside a `Row` needs `Expanded`/`Flexible`** — otherwise `overflow: ellipsis`
  never engages (the Text asks for its intrinsic width in unbounded space) and the row
  overflows: that was the narrow-window yellow/black stripes.
- **Never fake alignment with padding.** Both column headers share `_topBarHeight`, and a
  widget test asserts the two divider `dy` values are equal (mutation-tested). The same
  coupling applies to `_sidebarWidth` ↔ the native minimum window size.
- **Frame reads must share one stateful reader.** A single TCP chunk can carry several
  frames; a per-call buffer silently drops the rest (that made the extension freeze for
  30 seconds). Use `NativeMessageReader` for the handshake *and* the serve loop.
- **`getCredentials` returns an array** — treating it as a single object fails silently
  (the old in-field icon filled nothing while looking like it worked).
- **A frame without a login form must not answer `fillCredentials`** — the popup takes the
  first response, so an empty iframe answering `success:false` makes a successfully filled
  page look "restricted" (and the popup overwrites the clipboard).
- **In jsdom, `textContent` includes `hidden` subtrees**, so it cannot assert that
  something is invisible — walk the ancestor chain for the `hidden` attribute instead.
  jsdom also does no layout (`offsetParent` is always null, `getBoundingClientRect` always
  zero), so visibility APIs must be stubbed when testing the content script.
- **Verify numbers against the code before writing them into docs** — "auto-lock 1–60 min"
  was wrong (the UI offers 1/3/5/15/30), and `^3.12.2` is the *Dart* SDK constraint, not a
  Flutter version.
- **When a CLI takes long text from PowerShell, put it in a file** — embedded double quotes
  break argument parsing (`git commit -F msg.txt`; the same bit `ov add-memory`).
- **`Select-Object -First N` closes the pipeline early**, so the upstream command can be
  reported as `exit 1` even when it succeeded — do not use it when the exit code matters.
- **Never hand-build `PasswordEntriesCompanion` for entry data.** Since 2.3.0 all entry
  reads/writes go through `VaultItem` + `VaultItemMapper`; writing the `*_encrypted` columns
  yourself is how you get a column that the master-password rotation (`reencryptAll`) and the
  export path silently miss. The legacy row-level `VaultRepository` methods are `@Deprecated`
  migration bridges only.
- **Two agents running `flutter test` in the same checkout collide** on
  `build\native_assets\windows\sqlite3.dll` ("Flutter failed to delete file … cannot access
  the file"). It is not a code failure — serialize test runs, or retry after the other run
  finishes. Same class of problem: `dart run build_runner` in two shells at once.
- **Read vault data through streams, never one-shot futures + manual `ref.invalidate`.**
  The 2.3.1 user-visible bugs (the folder picker offering only the first folder; the detail
  page still showing the old entry — and therefore no new custom field — after an edit) both
  came from `FutureProvider` caches that some write path forgot to invalidate.
  `foldersProvider`, `entryItemProvider`, `searchResultsProvider` and `healthReportProvider`
  are `StreamProvider`s over drift (`watchFolders` / `watchItem` / `watchSearch` /
  `watchItems`): a write pushes, so "forgot to invalidate" cannot happen. Give any new read
  provider a stream too.
- **A dropdown whose choice can be rejected must be controlled.** `DropdownButtonFormField`
  holds its own state, so "pick a new value → confirm dialog → cancel" leaves the control
  showing the value the user just rejected while the form still has the old one.
  `EntryTypeSelector` therefore wraps a plain `DropdownButton(value: ...)` in an
  `InputDecorator`; the custom-fields type dropdown keeps the FormField (no cancel path) but
  keys each row by its row object so deleting a row cannot shift the next row's selection.
- **Form controls in a row must share the same decoration.** A bare dropdown (no label, no
  outline) next to two labelled `OutlineInputBorder` fields sits half a line higher and reads
  as "misaligned"; `test/custom_fields_editor_test.dart` asserts the top edges are within 4px.
- **Never leave a desktop feature behind a touch gesture only.** Folder delete/rename lived
  exclusively on `onLongPress`, so mouse users concluded "folders can only be added, never
  deleted" (2.3.2). Anything a desktop user must be able to do needs a *visible* affordance
  (a `more_vert` button) **and** the mouse-native gesture (`onSecondaryTap`); long-press stays
  as a third path, never the only one.
- **Destructive actions state their blast radius.** Deleting a non-empty folder now counts the
  entries first (`countItemsInFolder`) and switches both the message ("it still contains N
  entries — they will NOT be deleted") and the confirm label ("Delete folder, keep entries").
  Never let a destructive confirm read the same for "empty" and "has data".
- **A dialog that silently swallows a failure looks like a dead button.** The delete path wraps
  both the count and the delete in try/catch and reports the error in a SnackBar; without that,
  a failed write leaves the user staring at an unchanged list.
