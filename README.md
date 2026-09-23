# EasyPass

**中文版**: [README_zh.md](README_zh.md)

A **local-first password manager for Windows** with a companion Chrome/Edge
extension: an encrypted vault on your own machine, a background service that keeps
it available, and one-click auto-fill in the browser. The long-term goal is a
**self-hostable Bitwarden alternative** — same convenience, no cloud you don't
control.

![release](https://img.shields.io/badge/release-2.3.2-blue)
![platform](https://img.shields.io/badge/platform-Windows-0078D6)
![tests](https://img.shields.io/badge/tests-412%20passing-brightgreen)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

> **Current release: 2.3.2** — the vault holds **four entry types** (login, secure
> note, identity, SSH key) with custom fields; the detail page shows live TOTP
> codes; folders can be created, renamed, re-iconed and deleted; and everything you
> edit shows up immediately. 2.3.1/2.3.2 fixed what real use turned up: a folder
> picker that only ever offered the first folder, screens that kept showing stale
> data after an edit, and folder rename/delete being reachable only by a long-press.

---

## Why EasyPass?

- **Your data stays on your device.** The vault is a local SQLite file; every
  sensitive field is AES-256-CBC encrypted with a key derived from your master
  password, which is never stored. No account, no server, no telemetry.
- **A real background service, not a frozen app.** Since 2.0 the vault core runs as
  a windowless daemon (`easypass.exe --service`) that the extension talks to through
  a local bridge — auto-fill works without the UI being open.
- **Auto-fill that respects the page.** Nothing is injected unless the page has a
  visible password field; the extension never asks for your master password inside
  a web page, and **only login entries** are ever offered for filling.
- **Secrets stay in the desktop process.** TOTP secrets are decrypted in the daemon,
  which computes the 6-digit code; the browser only ever sees the code.
- **More than logins.** Secure notes, identity documents and SSH keys (with
  fingerprint parsing) live in the same encrypted vault, with custom fields on every
  type.
- **Fully open source and auditable.** Crypto, storage, the bridge protocol and the
  extension are all in this repository under GPL-3.0.
- **No admin rights required.** The installer is per-user and lands in your own
  `%LOCALAPPDATA%`.

## Features

### Vault (desktop)

- **Four entry types** — *login*, *secure note*, *identity* (name, ID numbers,
  contact, address), *SSH key* (public key, private key, passphrase, fingerprint) —
  plus **custom fields** (text / hidden / checkbox) on every type.
- **Cryptography** — PBKDF2-HMAC-SHA256 (100,000 iterations) derives the
  AES-256-CBC key; the derived key lives in memory for the session only and is
  cleared on lock. Backups use the same encryption.
- **Live TOTP** — the detail page shows the rotating 6-digit code with a countdown
  and one-click copy. The secret itself is never shown as plain text and never
  leaves the process.
- **SSH keys** — paste an OpenSSH public key and the fingerprint (SHA256 + MD5), key
  type, key size and comment are derived locally. The private key is masked and the
  master password is required before it is shown or copied.
- **Folders** — custom icons, rename, and delete-with-a-guard: deleting a folder
  that still holds entries tells you how many and keeps every entry (they move to
  “No Folder”). Entries are never deleted together with a folder.
- **Search** — instant, case-insensitive, across names, notes, identity/SSH fields
  and custom-field labels, with `type:` / `folder:` / `url:` prefixes. Passwords,
  TOTP secrets, SSH private keys and hidden values are deliberately **not**
  searchable.
- **List** — per-type icons and badges, plus a type filter that composes with
  folders and favourites.
- **Password generator** — length 4–128, character classes, with a fresh suggestion
  pre-filled on every new entry.
- **Auto-lock** — 1 / 3 / 5 / 15 / 30 / 60 minutes (default 5); **theme** follows
  the system or is pinned to light/dark; UI in Chinese or English; bundled font.
- **Password health report** — weak (short, single character class, common), reused,
  missing 2FA and missing URL issues with a 0–100 score, scored **over login
  entries only**.
- **Export / import** — plain JSON for review, encrypted JSON for backups (no
  plaintext inside). Format 2.0.0 carries types and custom fields; 1.x exports still
  import as logins.

### Browser extension (Chrome MV3 / Edge)

- **Auto-fill** — an EasyPass icon is injected *inside* a password field when the
  page has one. Clicking it checks the vault state, matches entries by **domain**
  (exact host, then sub-domain in either direction), then fills directly (one match)
  or shows its own picker (several matches). Locked vault and “no match” are
  reported in a bubble instead of failing silently.
- Works with React/Vue/Angular controlled inputs (native value setter plus
  `input`/`change` events), open shadow roots, iframes (all frames) and SPA route
  changes.
- **Popup, three tabs**:
  - *Vault* — search (debounced) and a type filter; fill a login, copy username /
    password / URL / TOTP, reveal passwords, copy a secure note’s body, an
    identity’s fields, or an SSH key’s public key / fingerprint / private key (the
    private key only on an explicit click).
  - *Generator* — length 8–64 and character classes, using the desktop generator
    logic; usable while the vault is locked.
  - *Health* — the score plus the four issue counts.
- **Unlock once** — the session lives in the daemon’s memory, so closing the popup
  or restarting the browser does not ask for the master password again. It is
  cleared on the idle timeout, when you press **Lock**, or as soon as you lock the
  desktop app.
- **Auto-fill stays login-only** — secure notes, identities and SSH keys are visible
  and copyable, but never appear in the fill list.

### Desktop & system integration

- Background daemon (`easypass.exe --service`): windowless, cold-started on demand
  by the native-messaging bridge, exits by itself after 10 minutes idle.
- Tray icon: closing the window hides EasyPass instead of quitting.
- Start at logon (HKCU Run key), optional in the installer.
- Architecture: browser → `easypass_native_host.exe` (x86 bridge) → loopback TCP
  with a random per-run token handshake → daemon → encrypted SQLite.
- Native minimum window size 900×600; persistent sidebar.

## How it compares

Honest snapshot. “Planned” means it is on the roadmap, not that it works now.

| | **EasyPass 2.3.2** | **Bitwarden + Vaultwarden** | **KeePassXC** |
|---|---|---|---|
| Where data lives | Your PC (encrypted SQLite) | Your server (Vaultwarden) or Bitwarden cloud | Your PC (encrypted `.kdbx`) |
| Server required | No | Yes (for self-hosting) | No |
| Entry types | Login, secure note, identity, SSH key (+ custom fields) | Login, card, identity, note, SSH key | Login, group, note, card, identity |
| Browser auto-fill | Yes (Chrome/Edge) | Yes (all major browsers) | Yes (KeePassXC-Browser) |
| Multi-device sync | **No** — *planned for 3.0* | Yes | Only via your own file sync |
| Mobile apps | **No** — *planned* | Yes | Companion apps (not KeePassXC itself) |
| Sharing / organizations | **No** — *planned* | Yes | No |
| Self-hosting effort | Not applicable yet (no server) | Vaultwarden: low (single container) | Not applicable (file-based) |
| License | GPL-3.0 | Clients GPL-3.0 / server AGPL-3.0 | GPL-2.0/3.0 |

Where EasyPass wins today: single-machine Windows users who want a native app, a
real background service for browser auto-fill, and no server or subscription.
Where it clearly loses: anything multi-device.

## Installation

### Option 1 — Installer (recommended)

Download `EasypassSetup.exe` from the releases page and run it. It installs
**per-user** (no administrator rights) into `%LOCALAPPDATA%\Programs\EasyPass`,
bundles the VC++ runtime and the x86 native-messaging bridge, registers the browser
host for Chrome and Edge, and can start EasyPass at logon.

> ⚠️ The installer is **not code-signed yet**, so SmartScreen may warn about an
> unknown publisher. Verify the SHA-256 of the file if you have the checksum.

### Option 2 — Build from source

| Requirement | Notes |
|---|---|
| Windows | 10 or 11, 64-bit |
| Flutter SDK | stable channel, Dart `^3.12.2`, on your `PATH` |
| Visual Studio | 2022+ with **Desktop development with C++** (builds the runner and the x86 bridge) |
| Inno Setup 7 | only for packaging the installer |

```powershell
git clone https://github.com/CONFISION/EasyPass.git
cd EasyPass
flutter pub get
flutter build windows        # also builds the x86 bridge + copies the MSVC runtime
# → build\windows\x64\runner\Release\easypass.exe

# optional: package the installer
& "C:\Program Files\Inno Setup 7\ISCC.exe" installer\easypass_setup.iss
# → build\installer\EasypassSetup.exe
```

Code generation is only needed after schema/localization changes:

```powershell
dart run build_runner build --delete-conflicting-outputs   # after editing lib/data/database/tables.drift
flutter gen-l10n                                           # after editing lib/l10n/*.arb
```

> Note: `drift`/`drift_dev`/`build_runner` are pinned to versions whose `analyzer`
> understands the installed Dart SDK. With an older analyzer, code generation dies
> with `Missing implementation of visitDotShorthandPropertyAccess` and writes
> nothing — bump all three together (see the comments in `pubspec.yaml`).

## Browser extension

The installer registers the native host automatically; in the browser open
`chrome://extensions` (or `edge://extensions`), enable **Developer mode** and choose
**Load unpacked** → `browser_extension/`. The extension is not published to any
store yet, so this manual step is required.

If the popup reports *“Unknown action”* or a stale background service, an older
daemon is still running: quit EasyPass completely (including the tray) and start it
again — protocol version 3 retires the old process.

## Development & testing

```powershell
flutter analyze --no-pub
flutter test --no-pub                 # 412 unit/integration tests
```

Extension checks (no browser needed; `jsdom` must be installed):

```powershell
node browser_extension/tools/check_extension.mjs   # syntax, i18n parity, protocol actions, 4-way version sync
node browser_extension/tools/smoke_content.mjs     # 19 assertions: autofill behaviour
node browser_extension/tools/smoke_popup.mjs       # 71 assertions: popup rendering/actions
node browser_extension/tools/smoke_popup_extra.mjs # 58 assertions: failure paths, a11y, DOM contract
```

Live debugging helpers: `node browser_extension/tools/probe_daemon.mjs` (talk to a
running daemon) and `probe_bridge.mjs` (spawn the bridge end-to-end) tell you
whether the daemon, the bridge or the extension is at fault.

`cmd /c windows\runner\check_syntax.bat` compiles `windows/runner/*.cpp` with the
same warning flags as the real build (`/W4 /WX`) without invoking MSBuild.

## Data & security model

- **Vault database** — `easypass.db`, stored next to the executable (per-user
  install → writable, no admin rights).
- **Master password** — never stored; PBKDF2-HMAC-SHA256 (100,000 iterations,
  32-byte salt) derives the AES-256-CBC key. Only the salt and a verification hash
  are kept in `flutter_secure_storage` (DPAPI on Windows).
- **Session** — the derived key lives in memory only; locking clears it. The browser
  session key is held by the daemon and wiped after the idle timeout.
- **Encryption coverage** — passwords, TOTP secrets, notes, identity/SSH blocks and
  custom fields are all encrypted before they reach SQLite; plaintext never touches
  the database.
- **TOTP secrets never reach the browser** — the daemon computes the code and sends
  only that.
- **Local channel only** — credentials travel over loopback TCP guarded by a per-run
  random token; nothing is uploaded anywhere.
- **Backups** — encrypted exports encrypt the whole payload; plain exports exist for
  review and are clearly labelled.

## Roadmap

**2.4 — distribution & migration.** Publish the extension to the Chrome Web Store
and Edge Add-ons, Bitwarden/Vaultwarden import, GitHub Actions CI, checksums and
code signing.

**3.0 — self-hosted sync.** A two-layer key hierarchy (account key → user key →
organization key), a Docker-deployable server, an offline-first sync engine, then
sharing, organizations and emergency access — the step that turns EasyPass into a
Bitwarden alternative you host yourself.

**Later (not scheduled).** Attachments, passkeys, biometric unlock, SQLCipher,
payment cards, Steam Guard TOTP, breach checks (opt-in), a CLI, Android-first mobile
app, macOS/Linux, Firefox extension.

## Known limitations

- **Windows only** — no macOS, Linux or mobile client yet.
- **No sync** — one machine per vault; copying the database file is the only way to
  move it, and it must not be copied while EasyPass is running.
- **The extension is not published**, so it must be loaded unpacked.
- **The installer is not code-signed**, so SmartScreen warns about an unknown
  publisher.
- **No CI** — `flutter analyze`, `flutter test` and the extension checks are run
  manually.
- **Auto-fill gaps** — two-step sign-in flows (username page first) only fill the
  page that carries the password field, closed shadow roots are invisible to the
  content script, and some bank/payment widgets may need manual filling.
- **No biometric unlock yet** (the settings entry is a placeholder), and the desktop
  app cannot show the extension session’s remaining time (that state lives in the
  daemon process).
- No sharing, organizations, attachments or passkeys yet.

## License

GPL-3.0 — see [LICENSE](LICENSE).

## Acknowledgements

Built with [Flutter](https://flutter.dev), [drift](https://drift.simonbinder.eu),
[encrypt](https://pub.dev/packages/encrypt), [Riverpod](https://riverpod.dev) and
[go_router](https://pub.dev/packages/go_router). Thanks to the Bitwarden and
Vaultwarden projects for setting the bar this project aims at.
