# EasyPass

**中文版**: [README_zh.md](README_zh.md)

A local-first, Bitwarden-like password manager for Windows, built with Flutter.
All data stays on your machine; nothing is ever sent to the network.

Current version: **1.2.0** (`pubspec.yaml: 1.2.0+4`).

## Features

### Phase 1 — MVP core

- **Master password protection** — PBKDF2-HMAC-SHA256 (100,000 iterations)
  derives an AES-256-CBC key; the master password itself is never stored
- **Vault CRUD** — entries with name, URL, username, password, notes and
  TOTP secret, organized into folders with favorites
- **Search** — instant search across name, URL and username
- **Password generator** — configurable length and character sets; the
  add-entry screen pre-fills a fresh generated password on every open
- **Auto-lock** — configurable 1–30 minute timeout clears the session key
  from memory
- **Change master password** — verifies the current password and re-encrypts
  the whole vault with a freshly derived key

### Phase 2 — Extension & portability

- **Browser extension** (Chrome MV3) with login-form auto-fill over Chrome
  Native Messaging
- **Encrypted backup export/import** (restorable) and plain JSON export
- **TOTP** (RFC 6238) codes for two-factor logins

### v1.3.0 — This release

- **Browser extension connectivity overhaul** — the native messaging host
  now launches reliably: the runner detects browser launches from stdio pipes
  and `start_hidden` startup flags (no CLI args are passed by Chrome/Edge),
  the frame codec buffers arbitrary chunk boundaries, responses are flushed,
  and the host process exits when the browser disconnects (no process leaks).
  The host manifest is registered in both 64-bit and 32-bit (WOW6432Node)
  registry views with the concrete extension ID
  (`hlkbbdlgaocmnjlgpafkimobnkfniike`) in `chrome-extension://` form only.
  Popup loading is now state-machine driven with an 8s diagnostic timeout.
- **Installer hardening** — host registration moved from silently running
  PowerShell into the installer's own script (`[Code]` section), eliminating
  the `Trojan:Win32/Wacatac.B!ml` false positives from unsigned installers
  that silently execute scripts. `install_host.ps1` remains for manual use.
- **Known limitation** — 32-bit Edge has a cross-bitness handle-passing issue
  that prevents the host from receiving the browser's stdio pipes; use the
  64-bit Edge, or the planned 2.0 daemon architecture (see Plan.md).

### v1.2.0 — This release

- **Native messaging host wired up** — the host runs as the desktop
  executable itself (`easypass.exe --native-host`, see `lib/main.dart`), so
  no separate binary is needed; it shares the same database and secure
  storage as the UI. Register it with Chrome/Edge via
  `browser_extension/native_host/install_host.ps1`
- **Bilingual extension UI** — the browser extension is now localized
  (Chinese / English) through `chrome.i18n`, following the browser language
- **Password health report** — weak passwords, reused passwords, entries
  without TOTP and entries without a URL, plus a 0–100 score (vault screen →
  health icon → `/health`)
- **Bilingual desktop UI** — Chinese / English following the system locale,
  with a manual override in Settings
- **Custom fonts** — Maple Mono NF CN ships next to the executable
  (`assets/fonts/`), and Settings lets you pick any detected font
- **Sidebar & polish** — persistent sidebar (2:8 split, max 300px), full
  entry detail view, app icon (`windows/runner/resources/app_icon.ico`)

## Security model

- Only the salt and a master-password hash are persisted, via
  `flutter_secure_storage` (DPAPI on Windows).
- Every sensitive field (password, notes, TOTP secret) is AES-256-CBC
  encrypted with the session-derived key before it touches SQLite.
- The derived key lives only in memory and is cleared when the vault locks
  (5 minutes by default).
- Never log or print secrets; pass keys by reference only.

## Where your data lives

EasyPass stores two kinds of data in two different places. **Deleting the
`build/` directory does not reset the app** — it only removes compiled
output; your vault data and your master-password state survive.

### 1. The vault database — next to the executable

| Item | Location |
|------|----------|
| `easypass.db` | Same directory as `easypass.exe` (e.g. `build\windows\x64\runner\Release\`) |

Contains all password entries, encrypted with the session key. Because it
sits next to the executable, deleting the `build/` directory deletes your
entries too. **Keep a backup** (Settings → export, or copy `easypass.db`)
before wiping build output.

### 2. Master-password state & settings — in Windows AppData

| Item | Location |
|------|----------|
| `flutter_secure_storage.dat` | `%APPDATA%\easypass.com\easypass\` |

A DPAPI-encrypted file holding the master-password **salt + hash** (for
verifying unlocks) plus persisted settings (auto-lock minutes, font
choice). It is *not* tied to the build directory, which is why rebuilding
from scratch still asks for the existing master password instead of
re-running the first-run setup.

> Note: this path derives from the `CompanyName` in
> `windows/runner/Runner.rc` (`easypass.com`). Changing it relocates the
> AppData path above — the old directory is not migrated automatically.

### Reset / factory wipe

- **In-app**: Settings → *Delete all data* clears the vault and the secure
  storage, returning the app to first-run state.
- **Manual**: close the app, delete `%APPDATA%\easypass.com\easypass\`
  (resets master-password state) and/or the `easypass.db` next to the exe
  (resets entries). Restart to see the first-run setup.

## Build & run

Requires Flutter with Dart SDK `^3.12.2`.

```bash
flutter pub get                                  # install dependencies
dart run build_runner build --delete-conflicting-outputs  # after tables.drift changes
flutter gen-l10n                                 # after editing lib/l10n/*.arb
flutter run -d windows                           # run the desktop app
flutter test                                     # run the test suite
flutter build windows                            # release build
```

## Browser extension

The extension in `browser_extension/` (Chrome MV3) talks to the desktop app
through Chrome Native Messaging. The host runs as the desktop executable
itself (`easypass.exe --native-host`, see `lib/main.dart`), so no separate
binary is needed — it shares the same `easypass.db` and secure storage as the
UI. The Dart protocol implementation lives in
`lib/features/browser_bridge/native_messaging_service.dart` (lock/unlock,
credential queries, search, password generation, TOTP).

To register the host with Chrome/Edge:

```powershell
# after building, from the repo root:
powershell -ExecutionPolicy Bypass -File browser_extension/native_host/install_host.ps1
# (optionally pass -ExePath "C:\path\to\easypass.exe")
```

Then restart the browser and load `browser_extension/` (developer mode).
The extension has a **fixed ID** (`hlkbbdlgaocmnjlgpafkimobnkfniike`) derived
from the `key` field in `manifest.json` (the private key
`keys/easypass_extension_private_key.pem` is gitignored) — the generated
host manifest only allows that ID to connect, so check the ID shown in
`chrome://extensions` matches. `uninstall_host.ps1` removes the registration.
Keep `background.js` actions in sync with
`NativeMessagingService.handleRequest`'s switch.

## Installer

An Inno Setup script (`installer/easypass_setup.iss`) builds a per-user
installer. Because `easypass.db` is written next to the executable, the app
installs to `%LOCALAPPDATA%\Programs\EasyPass` (user-writable) instead of
`Program Files` — no admin rights are required. The installer bundles the
VC++ runtime (`msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`)
app-locally, so target machines do not need the VC++ Redistributable.

```powershell
# after building (flutter build windows):
& "C:\Program Files\Inno Setup 7\ISCC.exe" installer\easypass_setup.iss
# output: build\installer\EasypassSetup.exe
```

The installer offers an optional "register browser host" step. Registration is
done natively by the installer's own script (Inno Setup `[Code]` section) —
it writes the host manifest and the HKCU registry keys directly and
**spawns no PowerShell**, keeping Defender heuristics quiet (an unsigned
installer silently running `powershell.exe -ExecutionPolicy Bypass` is a
classic false-positive trigger). Uninstall cleans up the same way.
`install_host.ps1` / `uninstall_host.ps1` remain available for manual use.

## Testing

`flutter test` — 89 unit/widget tests covering the crypto round-trip,
RFC 6238 TOTP vectors, the password generator, export/import round-trips
(encrypted and plain), the auth lifecycle (set / unlock / change master
password, auto-lock settings), the native messaging host protocol
(lock/unlock, credential decryption, TOTP, frame codec chunking), the password health report
analysis, and the add-entry screen's fresh-password behavior.

## Versioning

This project follows a `major.minor.patch` scheme (see `pubspec.yaml`):

- **Major (`x`)** — advanced only on significant underlying architecture
  changes (e.g. crypto-layer rewrite, schema migration, security-model change).
- **Minor (`y`)** — advanced when features are added, removed, or changed.
- **Patch (`z`)** — used for optimizations: bug fixes, performance tweaks,
  and UI polish that do not alter behavior.

## Roadmap

See `Plan.md` (Chinese) for the full roadmap. Phase 1 (MVP) and Phase 2
(extension, TOTP, export/import) are complete; the password health report
(scheduled under Phase 3) landed in v1.2.0 as a fully local feature. Cloud
sync, password sharing, emergency access and cross-platform releases remain
planned for Phase 3.
