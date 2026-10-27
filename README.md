# EasyPass

**中文版**: [README_zh.md](README_zh.md)

A **local-first password manager for Windows** with a companion Chrome/Edge
extension: an encrypted vault on your own machine, one-click auto-fill in the
browser. Long-term goal: a self-hostable Bitwarden alternative.

![release](https://img.shields.io/badge/release-3.1.0-blue)
![platform](https://img.shields.io/badge/platform-Windows-0078D6)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

## What you get

- **Four entry types** — login, secure note, identity and SSH key (with public-key
  fingerprints), each with custom fields (text / hidden / checkbox).
- **Folders and search** — icons, rename, and a guarded delete that never deletes
  entries; search with `type:` / `folder:` / `url:` prefixes.
- **Live TOTP codes** — rotating 6-digit codes with one-click copy; the secret is
  decrypted only inside the local core process.
- **Generator and health report** — adjustable password generator; the report finds
  weak, reused and ageing passwords.
- **Import and export** — restorable encrypted backups; Bitwarden / Vaultwarden
  import (JSON + CSV) and a Bitwarden-compatible export.
- **Browser auto-fill** — Chrome / Edge (MV3); only **login** entries are offered,
  and only on pages that show a visible password field.
- **Desktop integration** — tray, close-to-tray that **locks the vault**, two exit
  levels (UI only / UI and core), start at logon, auto-lock (1 / 3 / 5 / 15 / 30 / 60
  minutes).
- **Trash** — deleting moves an entry to the trash (soft delete): restore, delete for
  good, or empty the trash; a delete also offers a one-click Undo.
- **Agent access (MCP, opt-in)** — the core can expose a loopback-only MCP endpoint so a
  paired AI agent can read metadata of entries marked *open*, create/update entries, and
  move entries to the trash (never delete permanently), and push field values to the
  **system clipboard** (plaintext never enters the model context; there is no reveal
  tool). Off by default; ask-every-time approval or trusted pass-through; every call is
  audited.
- **Local by design** — no account, no server, no telemetry; the master password is
  never stored (PBKDF2-HMAC-SHA256 + AES-256-CBC, see [SECURITY.md](SECURITY.md)).

## Architecture

The vault has exactly one owner: a standalone, always-on, windowless core service.
The Flutter app is a pure client — it never opens the database and never holds the key.

```text
browser extension ──┐
                    ├──▶ easypass_core  (owns easypass.db + the session key)
Flutter UI ─────────┘     loopback TCP · protocol 5 · encrypted frames
```

Closing the window locks the vault; the tray offers `Exit UI Only` and
`Exit UI and Stop Service`; on Windows a second launch just raises the existing
window. Details: [docs/technical-spec.md](docs/technical-spec.md).

## Install

**Windows** — download `EasypassSetup.exe` from the
[releases page](https://github.com/CONFISION/EasyPass/releases) and run it: per-user
install, no administrator rights, optional start at logon. It is **not code-signed**,
so SmartScreen may warn about an unknown publisher.

> **Windows only.** The Linux desktop port is not part of this branch — it lives in
> the `linux` branch of this repository.

The vault lives next to `easypass.exe` (`%LOCALAPPDATA%\Programs\EasyPass\`).

## Build from source

```bash
flutter build windows    # → build\windows\x64\runner\Release\easypass.exe
```

That one command also builds the x86 browser bridge and the core service. Stop a
running EasyPass first: the build replaces files the UI and the core have open.

## Browser extension

Not published to any store yet: open `chrome://extensions` (or `edge://extensions`),
enable **Developer mode**, then **Load unpacked** →
[`browser_extension/`](browser_extension). It talks to the core service, and the
bridge starts the core when it is not running — no open window required. The Windows
installer registers the native-messaging host for you.

## Where to look next

| I want to… | Read |
| --- | --- |
| understand how it runs: runtime topology, build/packaging, security boundary | [docs/technical-spec.md](docs/technical-spec.md) |
| add a protocol action, change the handshake, write a probe | [docs/protocol-api.md](docs/protocol-api.md) |
| change the schema, entry fields or import/export formats | [docs/data-model.md](docs/data-model.md) |
| read the threat model and the known limitations | [SECURITY.md](SECURITY.md) |
| set up a dev environment, run the gates, open a PR | [CONTRIBUTING.md](CONTRIBUTING.md) |
| look up repo conventions, pitfalls and debugging recipes | [AGENTS.md](AGENTS.md) |
| see what changed in each version | [CHANGELOG.md](CHANGELOG.md) |

## License

GPL-3.0 — see [LICENSE](LICENSE). Privacy: [PRIVACY.md](PRIVACY.md).
