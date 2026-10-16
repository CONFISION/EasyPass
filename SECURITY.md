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
  `SHA-256(derivedKey)` verifier are persisted, via `flutter_secure_storage` (Windows
  Credential Manager / Linux Secret Service).
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
- **CBC without a MAC** means ciphertext tampering is detectable only as a decryption
  failure, not as an authentication error. This is a known weakness of the current
  format and is on the roadmap for the key-hierarchy rework; it is why the rotation
  path refuses to proceed when any row fails to decrypt.
- **Master-password rotation keeps a journal inside the vault database.** Changing the
  master password must update two stores that have no common transaction: the entry
  ciphertext (SQLite) and the salt + verifier (`flutter_secure_storage`). To make that
  all-or-nothing, the *target* salt and verifier are written into a `vault_meta` row in
  the **same transaction** as the re-encryption. The deliberate consequence: while a
  rotation is incomplete — i.e. when the OS keychain cannot be written (Linux Secret
  Service unavailable or locked) — that verifier lives in `easypass.db` rather than in
  the keychain, and it is served from there until the keychain writes succeed. It is
  still `SHA-256(PBKDF2(masterPassword, salt, 100_000))`, so guessing the password
  offline costs the full PBKDF2 work per attempt, but it is not protected by the OS
  keychain during that window. Removing this trade-off requires the key-hierarchy
  rework (v3.0). The journal is deleted as soon as the keychain write succeeds, and it
  never contains the password, the derived key, or any entry plaintext.
- **Password verification has a single implementation** (`MasterPasswordVerifier`) and
  its rule is "a rotation journal exists ⇒ only the journal's target password is
  valid". Any code path that compared stored salt/hash on its own would disagree with
  the vault's actual key during that window — that was a real bug in 2.4.0, where the
  browser bridge kept accepting the old master password.
- **The derived key lives in memory** for the session (a Riverpod `StateProvider`) and
  is cleared on lock. Auto-lock defaults to 5 minutes. Changing the master password
  ends the session (the vault returns to the lock screen), so no session outlives the
  key it was opened with.
- **The browser bridge** listens on `127.0.0.1` only, and the daemon writes a token
  plus a protocol version into `daemon.json`. The extension's native-messaging
  allowlist is pinned to a single extension ID.
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

## Hardening advice for users

- Choose a long, unique master password; it cannot be recovered.
- Keep `easypass.db` and your exports out of cloud folders and shared directories.
- Prefer the encrypted backup format for backups; treat plain-JSON and
  Bitwarden-compatible exports as secrets and delete them after use.
- On Linux, make sure a Secret Service provider is installed and unlocked — without
  one, EasyPass cannot create or verify a master password and will say so.
