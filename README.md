# EasyPass

**中文版**: [README_zh.md](README_zh.md)

EasyPass is a **local-first, open-source password manager** for Windows, built
with Flutter. It keeps your credentials safe on your own machine — nothing is
ever uploaded to the cloud. A companion browser extension auto-fills your
logins in Chrome and Edge.

> **Current release: 2.2.1** — the browser extension is now usable: login-form
> auto-fill, a popup password generator, TOTP codes, clipboard actions and a
> password-health overview, all backed by the background daemon.

---

## Why EasyPass?

- **Your data stays on your device.** The vault is encrypted (PBKDF2 +
  AES-256-CBC) and stored in a local SQLite database. There is no server, no
  account, no subscription — your passwords are yours, offline.
- **Open source.** Every byte of the crypto and storage logic is in this
  repository, auditable by anyone.
- **A real background service.** Since 2.0 the vault core runs as a daemon
  that starts with your system. The browser extension connects instantly,
  with no cold-start delay, and keeps working after you close the app window.
- **Tray-first desktop UX.** Closing the window hides EasyPass to the system
  tray instead of quitting; the daemon keeps serving in the background.
- **Native Windows app.** Built with Flutter for a fast, familiar desktop
  experience, shipped as a per-user installer with no admin rights needed.

## Features (v2.2.1)

**Vault**

- Master-password protection (PBKDF2-HMAC-SHA256, 100k iterations; the
  password itself is never stored)
- Entries with name, URL, username, password, notes and TOTP secret —
  every sensitive field AES-256-CBC encrypted
- Folders, favorites, instant search
- Configurable password generator with a fresh suggestion on every new entry
- Auto-lock (1–30 min) and change-master-password with full re-encryption
- Password health report: weak/reused passwords, missing TOTP/URL, 0–100 score

**Browser extension** (Chrome MV3 / Edge) — usable:

- **Auto-fill**: a small EasyPass icon appears inside login fields; click it to
  fill the matching entry, pick from a list when several entries match, and get
  a clear hint when the vault is locked or nothing matches
- **Popup**: search the vault, copy username / password / URL, reveal
  passwords, show TOTP codes with a live countdown, fill the current tab
- **Password generator** using the desktop generator (length 8–64, character
  sets), plus a **password health overview** (score and weak/reused/missing
  2-step/missing URL counts)
- **Unlock once**: the session lives in the daemon and is cleared after the
  auto-lock idle timeout, when you press Lock in the popup, or as soon as you
  lock the desktop app

**Desktop**

- Chinese / English UI, custom fonts, persistent sidebar, dark theme
- Encrypted backup export/import (restorable) and plain JSON export
- Background daemon + system tray (2.0)

## Installation

### Option 1 — Windows users: download the installer (recommended)

Grab `EasypassSetup.exe` from the
[Releases](https://github.com/CONFISION/EasyPass/releases) page of this repository.

- Per-user install to `%LOCALAPPDATA%\Programs\EasyPass` — **no admin rights**
- Bundles the VC++ runtime and the native messaging bridge
- Optional: register the browser host and start EasyPass at logon
  (the vault daemon then runs in the background, tray-accessible)

### Option 2 — Build your own from source

Building from source lets you review the code, patch it, or fork your own
version.

**Prerequisites**

| Requirement | Version / Notes |
|-------------|-----------------|
| Windows | 10 or 11, 64-bit |
| Git | any recent |
| Flutter SDK | `^3.12.2` (with Dart 3.12+), on your `PATH` |
| Visual Studio | 2022 or newer, **"Desktop development with C++"** workload (for the Windows runner and the x86 bridge) |

**Steps**

```powershell
# 1. Clone the repository
git clone https://github.com/CONFISION/EasyPass.git
cd easypass

# 2. Fetch dependencies
flutter pub get

# 3. Build the Windows release
#    NOTE: this also compiles the x86 native-messaging bridge
#    (easypass_native_host.exe) automatically as a POST_BUILD step.
flutter build windows --release
```

The app lands in `build\windows\x64\runner\Release\` — run
`easypass.exe` directly, or package an installer with Inno Setup:

```powershell
# Optional: build the per-user installer (requires Inno Setup 7)
& "C:\Program Files\Inno Setup 7\ISCC.exe" installer\easypass_setup.iss
# output: build\installer\EasypassSetup.exe
```

> If you modified the source after cloning, the generated files
> (`database.g.dart`, `app_localizations*.dart`) are already committed, so a
> plain clone builds as-is. When you change `tables.drift` run
> `dart run build_runner build --delete-conflicting-outputs`; when you change
> `lib/l10n/*.arb` run `flutter gen-l10n`.

**Browser extension**

The extension is in `browser_extension/` (not needed for the desktop app
alone):

1. Build once (above) so `easypass_native_host.exe` exists next to
   `easypass.exe`
2. Register the native host with your browser:
   ```powershell
   powershell -ExecutionPolicy Bypass -File browser_extension/native_host/install_host.ps1
   # optional: -ExePath "C:\path\to\your\easypass.exe"
   ```
3. Open `edge://extensions` (or `chrome://extensions`), enable **Developer
   mode**, and **Load unpacked** the `browser_extension/` folder
4. Restart the browser. Verify the extension ID is
   `hlkbbdlgaocmnjlgpafkimobnkfniike` (fixed by the manifest `key`)

**Using it**: unlock the vault once — either in the desktop app or in the
popup (the toolbar icon) — then click the EasyPass icon inside any login field
to fill it. The vault stays unlocked in the daemon until the auto-lock idle
timeout (Settings → auto-lock) expires, you press **Lock** in the popup, or you
lock the desktop app. The extension never injects a master-password box into a
web page and only reads credentials on your click.

**Extension development checks** (no browser required):

```bash
node browser_extension/tools/check_extension.mjs   # syntax, i18n keys, manifest, protocol coverage, version parity
node browser_extension/tools/smoke_popup.mjs       # drives the popup in jsdom against a fake native host
node browser_extension/tools/smoke_popup_extra.mjs # guardrails: lock failure paths, a11y, DOM hooks
node browser_extension/tools/smoke_content.mjs     # drives the content script on a fake login page in jsdom
node browser_extension/tools/probe_bridge.mjs      # end-to-end: spawns the bridge and talks to the real daemon
node browser_extension/tools/probe_daemon.mjs      # talks to an already-running daemon (see daemon.json)
```

The two smoke scripts need `jsdom` (development only):
`cd %TEMP% && mkdir easypass-smoke && cd easypass-smoke && npm i jsdom`

**Troubleshooting**: if the popup reports `Unknown action: …`, the extension is
talking to an **older daemon** that is still running after an upgrade — quit
EasyPass from the tray icon, start it again, then retry. `probe_bridge.mjs`
tells you which layer is at fault (bridge, daemon or extension).

**Tests**

```bash
flutter analyze
flutter test      # unit/integration tests (crypto, TOTP, generator, export/import, auth, daemon, bridge)
```

## Data & security model

- **Vault database**: `easypass.db`, stored **next to the executable**
  (in the install dir, or in `build\windows\x64\runner\Release\` for source
  builds). Keep backups (Settings → export, or copy the file).
- **Master-password state & settings**: `%APPDATA%\easypass.com\easypass\`
  (DPAPI-protected): salt + hash for unlock verification and preferences.
- Sensitive fields are AES-256-CBC encrypted before touching SQLite; the
  derived key lives in memory only and is cleared on lock.
- **Browser session**: unlocking from the extension derives the key again and
  keeps it in the daemon process memory only. It is cleared on the auto-lock
  idle timeout (default 5 min, following Settings → auto-lock), on **Lock** in
  the popup, and whenever the desktop vault is locked. TOTP secrets never reach
  the browser: the daemon computes codes and sends only the 6-digit values.
- Nothing ever leaves your machine.
