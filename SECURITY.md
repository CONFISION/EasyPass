# Security Policy

EasyPass is a local-first password manager. Your vault never leaves your machine
unless you explicitly export it, so a security bug here can mean losing secrets
rather than "just" an outage. Reports are taken seriously and answered honestly.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting:
[**Security → Report a vulnerability**](https://github.com/CONFISION/EasyPass/security/advisories/new)
on this repository. If you cannot use that channel, email the maintainer and say so
in a public issue *without details*, so a private channel can be arranged.

Helpful reports include:

- the version (`pubspec.yaml` / the Settings screen) and platform (Windows / Linux),
- what an attacker gains and what they need to start (local file access? a malicious
  web page? a browser extension? physical access to an unlocked session?),
- the smallest reproduction you have, and any log output — **with secrets redacted**.

**Never include a real master password, vault export, private key or TOTP secret in
a report.** A synthetic vault reproduces almost every issue.

## What to expect

This is a spare-time project, so these are good-faith targets rather than an SLA:

| Stage | Target |
| --- | --- |
| Acknowledgement | within 7 days |
| Initial assessment (severity + affected versions) | within 14 days |
| Fix or a documented mitigation | depends on severity; data-loss and key-handling issues come first |

You will be credited in the release notes unless you ask not to be. There is no bug
bounty.

## Supported versions

Only the latest release receives security fixes. Fixes land on `master` and ship in
the next tagged release; there are no backports to older minor versions.

## Scope

**In scope**

- The cryptographic design and its implementation (`lib/core/crypto/`), including
  master-password verification, key derivation and the rotation path.
- The vault database: what is written in plaintext, file permissions, and whether
  ciphertext columns can be correlated with each other.
- The browser bridge: the native-messaging protocol (`com.easypass.app`), the daemon
  (`--service`) and its local TCP listener, and the extension's content script
  (autofill injection, URL matching, origin checks).
- The bridge's trust boundary — e.g. whether a web page or another local process can
  obtain credentials it should not.
- Local privilege issues: writing outside the intended data directory, symlink
  handling, or a less-privileged process influencing the app.

**Out of scope** (these are known, accepted properties — see below)

- An attacker who already has your master password, your unlocked session, or
  administrator/root on your machine.
- Malware, keyloggers, memory scrapers, or a compromised OS or browser.
- The absence of features that are not implemented yet (see "Known limitations").
- SmartScreen warnings caused by the unsigned Windows installer.
- Reports that amount to "the database file is not encrypted as a whole" — this is a
  documented design property, not an oversight.

## Security model (what the code actually does)

Being precise here is more useful than a reassuring sentence, so:

- **The master password is never stored.** `PBKDF2-HMAC-SHA256(masterPassword, salt,
  100_000 iterations)` derives a 32-byte AES-256 key. Only the salt and a
  `SHA-256(derivedKey)` verifier are persisted — **since 3.0.0 inside the vault database
  itself** (`vault_meta`, keys prefixed `secret.`), not in the OS keychain. This is not a
  downgrade: deriving the key and checking the verifier cost the same PBKDF2 work, so
  anyone holding `easypass.db` could already brute-force the password at that cost, and
  the rotation journal had been storing the same material in that table since 2.4.0. The
  upside is that the core process needs no OS keychain and the verifier lives in the same
  SQLite transaction domain as the data it protects. Upgrading from 2.4.x hands the old
  keychain values to the core **once** (`adoptLegacyKeyMaterial`); the old keychain entries
  are deliberately left in place so you can roll back.
- **Entry fields are encrypted individually** with AES-256-CBC as `base64(IV ‖
  ciphertext)`, a fresh random IV per value. All encryption goes through
  `VaultItemMapper`.
- **What is *not* encrypted**: entry titles, usernames, URLs, folder names, the entry
  type, favourite flags and timestamps are stored as plaintext columns, because the
  list, search and autofill paths need them without decrypting everything. Treat the
  database file as metadata-bearing, not as an opaque blob.
- **The SQLite database itself is not encrypted** (no SQLCipher). File permissions are
  tightened to `0600` and the data directory to `0700` on Linux; on Windows the
  database sits next to the executable (or in the install directory) and relies on the
  user profile's ACLs.
- **CBC without a MAC** (for the stored entry fields) means ciphertext tampering is
  detectable only as a decryption failure, not as an authentication error. This is a
  known weakness of the storage format and is on the roadmap for the key-hierarchy
  rework; it is why the rotation path refuses to proceed when any row fails to decrypt.
  (The **transport** is authenticated — see the channel-encryption bullet below.)
- **One process owns the vault (3.0.0).** `easypass_core` is the only process that opens
  `easypass.db` and the only one that holds the derived key. The desktop UI is a client:
  it has no database handle and never sees the key, so a compromised UI can read what it
  displays but cannot decrypt the vault on its own. The key lives only in the core's
  memory (`SessionDomains`) and is zeroed on lock.
- **Two session domains.** The core keeps separate `ui` and `bridge` sessions. Locking
  from the desktop locks **both** (closing the window, the tray's *Exit UI Only*, the
  auto-lock timer); unlocking the desktop does **not** unlock the browser extension,
  because unlocking should stay an explicit act. Auto-lock is enforced by the core
  (default 5 minutes, configurable 1–60) and the UI only reports user activity.
- **Transport encryption, protocol 5.** UI ↔ core traffic is encrypted and
  authenticated: the handshake exchanges two nonces and mutual HMAC proofs, so **the
  token never crosses the wire**; every subsequent frame is AES-256-CBC + HMAC-SHA256
  (encrypt-then-MAC, four independent direction keys derived with HKDF from the token and
  both nonces). Clients that still speak the old plaintext handshake are refused with
  `unsupported` rather than silently downgraded — plaintext is accepted only for the
  `bridge` role (see the known limitations).
- **Master-password rotation is atomic.** Since 3.0.0 the ciphertext, the rotation
  journal and the new salt/verifier all live in `easypass.db`, and the whole re-encryption
  plus the new verifier are written in **one SQLite transaction**. The 2.4.x window where
  the verifier could sit in the database because the OS keychain write failed no longer
  exists. The journal never contains the password, the derived key, or entry plaintext,
  and its rule is unchanged: a journal exists ⇒ only the journal's target password is
  valid.
- **Password verification has a single implementation** (`MasterPasswordVerifier`, now
  running inside the core). Any code path that compared stored salt/hash on its own would
  disagree with the vault's actual key during a rotation window — that was a real bug in
  2.4.0, where the browser bridge kept accepting the old master password.
- **Changing the master password ends both sessions**, so no session outlives the key it
  was opened with; the UI returns to the lock screen.
- **The browser bridge** reaches the core over `127.0.0.1` only. The core writes a token,
  a protocol version, its own version and its executable path into `daemon.json`
  (`exe` is what lets a client verify a process before terminating a stale core). The
  extension's native-messaging allowlist is pinned to a single extension ID.
- **The extension requests only** `clipboardWrite`, `nativeMessaging` and
  host permissions for `<all_urls>` (needed for autofill on any site). It stores no
  vault data itself; the unlocked session lives in the desktop app.

## Known limitations (please don't report these as vulnerabilities)

These are deliberate, documented gaps rather than bugs. They are tracked in the
roadmap and will change in future releases:

- No multi-device sync, no sharing/organisations, no emergency access — there is no
  server at all.
- No attachment support, no passkeys, no biometric unlock.
- Health checks (weak/reused passwords) only look at **login** entries.
- Plaintext export writes your secrets to disk unencrypted; that is the point of the
  option, but the file is your responsibility.
- No code signing on Windows yet, so SmartScreen warns on first run.
- macOS, mobile and Firefox are not supported.
- The default OK for a `data/` write failure is a visible error, not a retry queue —
  if a write fails, the change did not happen and the UI says so.
- **The x86 bridge → core hop is not encrypted.** On Windows the browser's native-messaging
  host must be a 32-bit console program (a 64-bit host gets a non-pipe stdin from 32-bit
  Edge), and such a program cannot reasonably implement AES/HMAC. That hop therefore uses
  loopback TCP with token authentication only. The bridge is a byte forwarder on
  `127.0.0.1`, and whatever it carries (including plaintext passwords for autofill) is
  already visible to the browser extension itself. On Linux the wrapper runs
  `easypass_core --bridge`, which *does* use the encrypted handshake.
- **The threat boundary is the OS user account, not cryptography.** Another process
  running as the same user can read `daemon.json` (and therefore the token), connect to
  the core, or attach a debugger to the UI/core process — and the UI has to display
  plaintext passwords by design. Transport encryption protects against passive capture
  and unauthenticated impostors, not against same-user malware.
- **Linux is not verified for 3.0.0.** The Linux runner, tray, `--bridge` host and
  AppImage layout compile-check only (clang `-fsyntax-only` against stub headers); they
  have not been built or exercised on a Linux desktop. Windows is the verified platform.
- **Upgrading from 2.4.x leaves the old `--service` process alive for up to 10 minutes.**
  It exits on its own idle timer and will not delete the new core's `daemon.json`
  (port + pid are checked), and the installer asks it to close first; during that window
  two processes may touch the same SQLite file (SQLite tolerates this; the old process
  serves nothing new).

## Hardening advice for users

- Choose a long, unique master password; it cannot be recovered.
- Keep `easypass.db` and your exports out of cloud folders and shared directories.
- Prefer the encrypted backup format for backups; treat plain-JSON and
  Bitwarden-compatible exports as secrets and delete them after use.
- On Linux, make sure a Secret Service provider is installed and unlocked — without
  one, EasyPass cannot create or verify a master password and will say so.
