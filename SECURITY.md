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

- the version (`pubspec.yaml` / the Settings screen) and platform (Windows),
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
- The browser bridge: the native-messaging protocol (`com.easypass.app`), the core service
  and its local TCP listener, and the extension's content script
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
  `SHA-256(derivedKey)` verifier are persisted — **inside the vault database itself**
  (`vault_meta`, keys prefixed `secret.`), not in the OS keychain. Deriving and checking
  cost the same PBKDF2 work either way; keeping the verifier in the DB puts it in the same
  SQLite transaction domain as the data it protects. On first upgrade from an older
  install, the old keychain values are handed to the core **once**
  (`adoptLegacyKeyMaterial`); the old keychain entries are left in place so a rollback
  still works.
- **Entry fields are encrypted individually** with AES-256-CBC as `base64(IV ‖
  ciphertext)`, a fresh random IV per value. All encryption goes through
  `VaultItemMapper`.
- **What is *not* encrypted**: entry titles, usernames, URLs, folder names, the entry
  type, favourite flags and timestamps are stored as plaintext columns, because the
  list, search and autofill paths need them without decrypting everything. Treat the
  database file as metadata-bearing, not as an opaque blob.
- **The SQLite database itself is not encrypted** (no SQLCipher). The database sits next
  to the executable in the per-user install directory
  (`%LOCALAPPDATA%\Programs\EasyPass\`) and relies on the user profile's ACLs.
- **CBC without a MAC** (for the stored entry fields) means ciphertext tampering is
  detectable only as a decryption failure, not as an authentication error. This is a
  known weakness of the storage format and is on the roadmap for the key-hierarchy
  rework; it is why the rotation path refuses to proceed when any row fails to decrypt.
  (The **transport** is authenticated — see the channel-encryption bullet below.)
- **One process owns the vault.** `easypass_core` is the only process that opens
  `easypass.db` and the only one that holds the derived key. The desktop UI is a client:
  it has no database handle and never sees the key, so a compromised UI can read what it
  displays but cannot decrypt the vault on its own. The key lives only in the core's
  memory (`SessionDomains`) and is zeroed on lock.
- **Three session domains (`ui` / `bridge` / `agent`).** Locking the desktop locks
  `ui` + `bridge` (closing the window, the tray's *Exit UI Only*, the auto-lock timer);
  unlocking the desktop does **not** unlock the browser extension, because unlocking
  should stay an explicit act. The `agent` domain is separate and auto-unsealed only
  while agent access is on (see the MCP section). Auto-lock is enforced by the core
  (default 5 minutes, configurable 1–60) and the UI only reports user activity.
- **Transport encryption, protocol 5.** UI ↔ core traffic is encrypted and
  authenticated: the handshake exchanges two nonces and mutual HMAC proofs, so **the
  token never crosses the wire**; every subsequent frame is AES-256-CBC + HMAC-SHA256
  (encrypt-then-MAC, four independent direction keys derived with HKDF from the token and
  both nonces). Clients that still speak the old plaintext handshake are refused with
  `unsupported` rather than silently downgraded — plaintext is accepted only for the
  `bridge` role (see the known limitations).
- **Master-password rotation is atomic.** The ciphertext, the rotation journal and the
  new salt/verifier all live in `easypass.db`, and the whole re-encryption plus the new
  verifier are written in **one SQLite transaction** — there is no window where the old
  password still works. The journal never contains the password, the derived key, or entry
  plaintext; its rule: a journal exists ⇒ only the journal's target password is valid.
- **Password verification has a single implementation** (`MasterPasswordVerifier`, running
  inside the core). No other code path compares stored salt/hash on its own; the UI asks the
  core via the `verifyMasterPassword` action.
- **Changing the master password ends both sessions**, so no session outlives the key it
  was opened with; the UI returns to the lock screen.
- **The browser bridge** reaches the core over `127.0.0.1` only. The core writes a token,
  a protocol version, its own version and its executable path into `daemon.json`
  (`exe` is what lets a client verify a process before terminating a stale core). The
  extension's native-messaging allowlist is pinned to a single extension ID.
- **The extension requests only** `clipboardWrite`, `nativeMessaging` and
  host permissions for `<all_urls>` (needed for autofill on any site). It stores no
  vault data itself; the unlocked session lives in the desktop app.

## Agent access (MCP) — opt-in, and what it changes

EasyPass can expose a local MCP endpoint (`POST http://127.0.0.1:47821/mcp`) so that AI
agents can read entry *metadata* and — when you allow it — create, update and delete entries.
It is **off by default** and the whole design assumes agents are compromised-by-default:
the tool surface never returns passwords, notes, TOTP seeds, SSH keys or custom-field
values. Each entry has a user-only **"Accessible to agents"** switch (existing entries
default to permanent deny). An entry **created by an agent is open to that agent by
default** so it can manage what it just made; you can flip any entry to permanent deny at
any time, and the switch itself is never writable by the agent.

To make agent access work without prompting you every five minutes, turning it on does
something the rest of this document does not do elsewhere:

- EasyPass generates a random 256-bit **agent key** and stores it protected by Windows
  **DPAPI** (current user, fixed entropy) in `agent.key.dpapi`.
- A copy of the vault key is **wrapped** with that agent key (AES-256-CBC + HMAC-SHA256,
  encrypt-then-MAC) and stored in the vault database (`vault_meta.agent.wrap`).
- On startup the core unseals that wrapped key and unlocks the **agent session only**.
  The `ui` and `bridge` sessions still require the master password.

Consequences you should be aware of:

- **While agent access is on, the vault can be unlocked without a password** by any
  process running as your Windows account. That is the point of the feature (zero
  interaction), and it is why the switch is off by default and why the settings page
  shows a persistent warning whenever it is on.
- DPAPI keeps the blob unreadable for **other Windows users** and for copies of the files
  moved to another machine or account. It does **not** protect against malware running as
  you — the same-user boundary described under "Known limitations" applies unchanged.
- Turning the switch off deletes the DPAPI blob, the wrapped key **and** stops the local
  MCP listener; there is no "disabled but still listening" state.
- **Resetting the agent key** replaces it and re-wraps the vault key. The old key stops
  working immediately; the entries themselves are not re-encrypted.
- **Changing the master password re-wraps automatically** in the same operation. If that
  re-wrap fails, agent access is switched off rather than left with a stale key.
- If the DPAPI blob is missing or cannot be decrypted (different account, different
  machine, corrupted file), the core does **not** start the MCP listener — it fails
  closed and says so in the log. It never falls back to a weaker store.
- The MCP listener rejects any request carrying an `Origin` header, validates `Host`,
  refuses non-`POST` methods, requires a per-pairing bearer key (only its SHA-256 is
  stored), accepts no query-string credentials, and never sends CORS headers.
- **Passwords never travel to the model.** There is no "reveal" tool: the agent can only ask
  the core to put a field value on the **system clipboard** (`copy_to_clipboard`) and learns
  whether that succeeded. The value goes from the core process to the clipboard and nowhere
  else; the call is audited by entry and field name, never by value.
- **Every agent call is recorded** in the `agent_audit` table (nickname, tool, entry,
  decision). The key, the real client identity, plaintext arguments and field values are
  never written there.
- **Write access is deliberately narrow.** `create_entry` / `update_entry` only cover
  `login` and `secure_note` fields; **identity and SSH-key entries are never exposed to
  agents** (product decision — agents do not need them and should not reach them), and
  there is no TOTP-code tool (the clipboard path below covers that need). In the
  ask-every-time mode every write, delete and restore is confirmed by you — the "allow
  reads this session" exemption covers reads only. The approval dialog lists **field
  names and the action**, never values.
- **No spurious approval prompts.** Hard gates (entry closed, outside the pairing scope,
  pairing revoked/expired) are evaluated **before** the dialog is shown, so an agent
  cannot use the approval UI to train you into approving blindly; the denial is still
  audited.
- **Agent deletion is recoverable.** `delete_entry` only moves the entry to the **trash**
  (a `deleted_at` timestamp; the ciphertext is not touched). There is no
  "delete permanently" tool: emptying the trash or deleting an entry for good is a UI-only
  action, so a user can always undo an agent's deletion. Trashed entries still get
  re-encrypted when the master password rotates.

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
  already visible to the browser extension itself.
- **The threat boundary is the OS user account, not cryptography.** Another process
  running as the same user can read `daemon.json` (and therefore the token), connect to
  the core, or attach a debugger to the UI/core process — and the UI has to display
  plaintext passwords by design. Transport encryption protects against passive capture
  and unauthenticated impostors, not against same-user malware.
- **This branch ships Windows only.** The Linux desktop port lives in the `linux` branch
  and is **not** covered by the security guarantees in this document. Windows is the
  supported and verified platform.
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
