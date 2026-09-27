# EasyPass

**中文版**: [README_zh.md](README_zh.md)

A **local-first password manager for Windows and Linux** with a companion
Chrome/Edge extension: an encrypted vault on your own machine, a background service
that keeps it available, and one-click auto-fill in the browser. The long-term goal
is a **self-hostable Bitwarden alternative** — same convenience, no cloud you don't
control.

![release](https://img.shields.io/badge/release-2.3.3-blue)
![platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux-0078D6)
![tests](https://img.shields.io/badge/tests-536%20passing-brightgreen)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

> **Current release: 2.3.3 — the Linux desktop port.** 2.3.3 adds a native Linux
> build (AppImage): tray icon and close-to-tray, single instance with "raise the
> existing window", XDG autostart, desktop-entry CLI and browser-host registration,
> with the vault moved to `$XDG_DATA_HOME/easypass/` under `0700`/`0600` POSIX
> permissions. It also hardens the Windows runner's tray handling. The vault itself
> keeps the 2.3.0 feature set: **four entry types** (login, secure note, identity,
> SSH key) with custom fields, live TOTP codes, folder management, and instant UI
> updates after every edit.

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
- **No admin rights required.** Windows installs per-user into `%LOCALAPPDATA%`, and
  the Linux AppImage is a single file in your home directory — nothing needs `sudo`.

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

| | Windows | Linux |
|---|---|---|
| Tray icon + close-to-tray | `windows/runner` (Win32 `Shell_NotifyIcon`) | `linux/runner` (GTK + libayatana-appindicator) |
| Single instance | not implemented (no gate) | locks `easypass.db.lock` and wakes the running instance over a unix socket, so a second launch raises the existing window |
| Start at logon | `HKCU\…\Run` entry, optional in the installer | `$XDG_CONFIG_HOME/autostart/easypass.desktop`, toggled in Settings |
| Application menu entry | Inno Setup shortcut | `--install` (desktop entry + hicolor icon), `--desktop-status`, `--uninstall` |
| Browser host registration | Inno Setup writes the registry keys | `--install-browser-host` writes the per-browser manifests |

- Background daemon (`easypass.exe --service`): windowless, cold-started on demand
  by the native-messaging bridge, exits by itself after 10 minutes idle.
- Architecture (Windows): browser → `easypass_native_host.exe` (x86 bridge) →
  loopback TCP with a random per-run token handshake → daemon → encrypted SQLite.
  On Linux the native-messaging host is the main binary itself
  (`easypass --native-host`), started by the generated wrapper script.
- Native minimum window size 900×600 on both platforms (enforced in the runner), with
  a persistent sidebar.

## Installation

### Option 1 — Installer (Windows, recommended)

Download `EasypassSetup.exe` from the releases page and run it. It installs
**per-user** (no administrator rights) into `%LOCALAPPDATA%\Programs\EasyPass`,
bundles the VC++ runtime and the x86 native-messaging bridge, registers the browser
host for Chrome and Edge, and can start EasyPass at logon.

> ⚠️ The installer is **not code-signed yet**, so SmartScreen may warn about an
> unknown publisher. Verify the SHA-256 of the file if you have the checksum.

### Option 2 — Build from source (Windows)

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

## Linux (desktop, AppImage)

The Linux build ships as a **single-file AppImage**. It has feature parity with the
Windows desktop app (vault, tray, autostart, browser host); the Windows installer and
the `windows/` sources are untouched by it.

### Install in three steps

```bash
chmod +x EasyPass-2.3.3-linux-x86_64.AppImage    # 1. make it executable
./EasyPass-2.3.3-linux-x86_64.AppImage           # 2. run it once (creates the vault)
./EasyPass-2.3.3-linux-x86_64.AppImage --install # 3. add it to the application menu
```

> **Ubuntu / AppImage without FUSE 2.** If the AppImage refuses to start because
> `libfuse2` is missing, either install it yourself (`sudo apt install libfuse2` —
> EasyPass never runs `sudo` or installs packages for you), or unpack and run it in
> place, which needs no FUSE at all:
>
> ```bash
> ./EasyPass-2.3.3-linux-x86_64.AppImage --appimage-extract-and-run
> ./EasyPass-2.3.3-linux-x86_64.AppImage --appimage-extract-and-run --install
> ```

Build it yourself with `installer/appimage/build_appimage.sh <bundle_dir>
<output_appimage>` after `flutter build linux --release`; the script reads the
version from `pubspec.yaml` and needs `appimagetool` (override its location with
`$APPIMAGETOOL`).

### Where your data lives (XDG)

| What | Path on Linux |
|---|---|
| Vault database | `$XDG_DATA_HOME/easypass/easypass.db` (default `~/.local/share/easypass/easypass.db`) |
| Daemon registration | `$XDG_DATA_HOME/easypass/daemon.json` |
| Native-host wrapper | `$XDG_DATA_HOME/easypass/easypass-native-host.sh` |
| Desktop entry (written by `--install`) | `$XDG_DATA_HOME/applications/easypass.desktop` |
| Icon (written by `--install`) | `$XDG_DATA_HOME/icons/hicolor/1024x1024/apps/easypass.png` |
| Autostart entry (Settings toggle) | `$XDG_CONFIG_HOME/autostart/easypass.desktop` (default `~/.config/autostart/`) |

`$XDG_DATA_HOME` unset or empty means `~/.local/share` (XDG Base Directory
Specification). The data directory is `0700` and the database `0600`.

**Migrating an old layout.** Older builds kept `easypass.db` *next to the
executable*. On the first Linux start that file is **copied** to
`$XDG_DATA_HOME/easypass/easypass.db`; the original is **left in place** (copy,
never move or delete), so nothing is lost if you go back to the old build.

### Desktop integration

```bash
./EasyPass-2.3.3-linux-x86_64.AppImage --install         # desktop entry + icon (idempotent)
./EasyPass-2.3.3-linux-x86_64.AppImage --desktop-status  # exit 0 = installed, 1 = points at a dead target, 2 = not installed
./EasyPass-2.3.3-linux-x86_64.AppImage --uninstall       # removes only what it wrote, then empty directories
```

`--install` bakes the AppImage's real path (`$APPIMAGE`) into `Exec=`, so moving
the AppImage afterwards means re-running `--install`.

The GTK application id is `com.easypass.app` (2.3.3+; earlier builds used the
Flutter template default `com.example.easypass`). A desktop entry written by an
older build therefore carries a stale `StartupWMClass` — run `--install` once after
upgrading, otherwise window grouping and icon lookup in the taskbar/dock use the
old class.

### Browser extension on Linux

1. Run the host installer once:
   `./EasyPass-2.3.3-linux-x86_64.AppImage --install-browser-host` (writes the
   Chrome/Chromium/Brave/Edge and Firefox native-messaging manifests;
   `--browser-host-status` reports each browser). Then load the unpacked extension.
2. **Chrome / Chromium / Brave / Edge** — open `chrome://extensions` (or the
   browser's equivalent), enable **Developer mode**, then **Load unpacked** →
   `browser_extension/`.
3. **Firefox** — open `about:debugging#/runtime/this-firefox`, **Load Temporary
   Add-on…** → `browser_extension/manifest.json`; then check `about:addons` →
   EasyPass → **Permissions** for native-messaging access. Firefox is **not
   verified end-to-end yet** — see the limitations below.

### Autostart

The Settings toggle **“Start EasyPass when you log in”** is the only switch: it
writes/removes `$XDG_CONFIG_HOME/autostart/easypass.desktop`.

### Linux limitations

- **The tray needs a StatusNotifier host** (KDE Plasma, or GNOME with the
  AppIndicator extension — Ubuntu ships it enabled). When no host is registered on
  the session bus, EasyPass keeps the icons out of the way and makes **closing the
  window quit the app** instead of hiding it, so the window can never end up hidden
  with no tray icon to bring it back.
- **Firefox support is untested end-to-end**: the manifests and the native-host
  wrapper are in place, but Firefox versions that still expect an MV3 event page
  instead of `background.service_worker` may need a follow-up manifest variant.
- **Not code-signed**, and the AppImage needs FUSE 2 unless you use
  `--appimage-extract-and-run`.

## Browser extension

The Windows installer registers the native host automatically; on Linux run
`--install-browser-host` once (see above). Then open `chrome://extensions` (or
`edge://extensions`), enable **Developer mode** and choose **Load unpacked** →
`browser_extension/`. The extension is not published to any store yet, so this
manual step is required.

If the popup reports *“Unknown action”* or a stale background service, an older
daemon is still running: quit EasyPass completely (including the tray) and start it
again — protocol version 3 retires the old process.

## Development & testing

```powershell
flutter analyze --no-pub
flutter test --no-pub      # 536 passed / 9 skipped on Windows (545 cases)
flutter build linux --release   # Linux desktop bundle (needs GTK 3 + libayatana-appindicator3-dev)
```

The 9 skipped cases are the Linux-only suites (`browser_host_installer_test.dart`
and friends): they register their cases only on Linux, so a Windows run reports them
as skipped instead of silently passing.

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

Two native pre-build checks, neither of which needs MSBuild:

```powershell
cmd /c windows\runner\check_syntax.bat      # compiles windows/runner/*.cpp with the real flags (/W4 /WX)
cmd /c windows\runner\check_integrity.bat   # Low integrity label on the workspace? (see Troubleshooting)
```

### Troubleshooting

| Symptom | First thing to check |
|---|---|
| Windows: no tray icon after closing/reopening, or settings that do not stick | `cmd /c windows\runner\check_integrity.bat`. A **Low mandatory integrity label** on the workspace (e.g. left behind by an agent sandbox in *workspace-write* mode) makes every process started from `build\` run at Low integrity: no tray icon, and silent write failures under `%TEMP%` / `%LOCALAPPDATA%` / `%APPDATA%`. Fix with `check_integrity.bat /fix`. |
| Extension: “Unknown action”, timeouts, empty popup | Old daemon still running — quit EasyPass (tray included) and start it again; then `node browser_extension/tools/probe_bridge.mjs`. |
| Windows: `flutter test` fails to load `sqlite3.dll` | `pubspec.yaml` must keep the sqlite3 hook scoped to Linux (`source: {linux: system}`); unscoped it also changes how Windows loads SQLite. |
| Linux: app starts but the tray icon never appears | No StatusNotifier host on the session bus — see *Linux limitations*. |

## Data & security model

- **Vault database** — `easypass.db`, next to the executable on Windows and in
  `$XDG_DATA_HOME/easypass/` on Linux (per-user, writable, no admin rights).
- **Master password** — never stored; PBKDF2-HMAC-SHA256 (100,000 iterations,
  32-byte salt) derives the AES-256-CBC key. Only the salt and a verification hash
  are kept in `flutter_secure_storage` (DPAPI on Windows, Secret Service on Linux).
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
app, macOS, Firefox extension.

## Release notes

### 2.3.3 — Linux desktop support

**New platform.** A native Linux build (`flutter build linux` → AppImage) with the
same vault as Windows: tray icon and close-to-tray implemented in the GTK runner
(`libayatana-appindicator`), single instance with a unix-socket wake-up so a second
launch raises the existing window, XDG autostart, the desktop-entry CLI
(`--install` / `--uninstall` / `--desktop-status`) and browser-host registration
(`--install-browser-host` / `--uninstall-browser-host` / `--browser-host-status`).

Four notes that come with the port:

1. **The vault moved on Linux.** It now lives in `$XDG_DATA_HOME/easypass/` instead
   of next to the executable; an old exe-adjacent `easypass.db` is **copied** on
   first start and the original is kept as a fallback.
2. **Linux-only permissions.** Data directory `0700`, database and migration
   temporaries `0600`, native-host wrapper `0700`, browser manifests `0644` inside
   `0700` directories. These POSIX bits are Linux hardening only; Windows keeps its
   `%LOCALAPPDATA%` ACL behaviour.
3. **The Linux native-messaging host is the app binary itself**
   (`easypass --native-host`, started by the generated wrapper). Windows keeps its
   separate x86 bridge executable and the `--service` daemon contract.
4. **Windows tray handling was hardened at the same time**: the runner now checks
   that the icon was really registered (and would rather quit on close than hide a
   window nobody can restore), re-adds the icon when Explorer restarts
   (`TaskbarCreated`), and enforces the 900×600 minimum window size on Linux too.

### 2.3.0–2.3.2 — the vault grew up

Four entry types (login / secure note / identity / SSH key) with custom fields,
live TOTP codes, folder management (icons, rename, guarded delete), `type:` /
`folder:` / `url:` search prefixes, and the fixes real use turned up in 2.3.1/2.3.2:
a folder picker that only offered the first folder, screens that kept showing stale
data after an edit, and folder rename/delete reachable only by a long-press.

## Known limitations

- **Windows and Linux desktop only** — no macOS, no mobile, and the extension is
  Chrome/Edge (Firefox not verified).
- **No sync** — one machine per vault; copying the database file is the only way to
  move it, and it must not be copied while EasyPass is running.
- **The extension is not published**, so it must be loaded unpacked.
- **Neither the installer nor the AppImage is code-signed**, so SmartScreen may warn
  about an unknown publisher on Windows.
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
