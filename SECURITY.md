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
- The local MCP agent endpoint (`127.0.0.1:47821`): transport rules (Origin/Host/POST/
  bearer/body limits/timeouts/concurrency), pairing-key handling, the per-entry access
  switch and type hard gate, the approval flow, and the `agent_audit` trail.
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
  `easypass.db` and the only one that holds the master-password-derived key in memory.
  The desktop UI is a client: it has no database handle and never sees the key, so a
  compromised UI can read what it displays but cannot decrypt the vault on its own.
  The derived key lives only in the core's memory (`SessionDomains`) and is zeroed on
  lock. The one deliberate exception is documented under "Agent access (MCP)": when that
  opt-in is on, a second copy of the vault key is wrapped and stored DPAPI-protected so
  the `agent` domain can be unsealed without your master password.
- **Three session domains (`ui` / `bridge` / `agent`).** Locking the desktop locks
  `ui` + `bridge` (closing the window, the tray's *Exit UI Only*, the auto-lock timer);
  unlocking the desktop does **not** unlock the browser extension, because unlocking
  should stay an explicit act. Auto-lock is enforced by the core for `ui`/`bridge`
  (default 5 minutes, configurable 1–60) and the UI only reports user activity.
- **The `agent` domain has no idle auto-lock.** It is separate from `ui`/`bridge`, and
  its lifecycle is exactly four boundaries: turning agent access on unlocks it; turning
  the switch off locks it; the explicit *Lock agent session* action in
  Settings → Agent access locks it; core exit locks it. Locking the desktop does **not**
  lock the agent domain, and MCP calls do not extend `ui`/`bridge` activity. That is what
  makes opt-in "zero-interaction" agent access real — and why the settings page shows a
  persistent warning whenever the feature is on (see the MCP section).
- **Transport encryption, protocol 5.** UI ↔ core traffic is encrypted and
  authenticated: the handshake exchanges two nonces and mutual HMAC proofs, so **the
  token never crosses the wire**; every subsequent frame is AES-256-CBC + HMAC-SHA256
  (encrypt-then-MAC, four independent direction keys derived with HKDF from the token and
  both nonces). Clients that still speak the old plaintext handshake are refused with
  `unsupported` rather than silently downgraded — plaintext is accepted only for the
  `bridge` role (see the known limitations).
- **Master-password rotation is atomic.** The ciphertext, the rotation journal and the
  new salt/verifier all live in `easypass.db`; the whole re-encryption **and** the journal
  entry naming the target password are written in **one SQLite transaction**, and the
  journal is what makes the new password authoritative until the verifier is repointed
  (a failed re-point leaves the journal in place and is retried on next unlock). There is
  no window where the old password still works. The journal never contains the password,
  the derived key, or entry plaintext; its rule: a journal exists ⇒ only the journal's
  target password is valid.
- **Password verification has a single implementation** (`MasterPasswordVerifier`, running
  inside the core). No other code path compares stored salt/hash on its own; the UI asks the
  core via the `verifyMasterPassword` action.
- **Changing the master password ends the `ui` and `bridge` sessions**, so no session
  outlives the key it was opened with; the UI returns to the lock screen. The `agent`
  domain is frozen first, then either re-unlocked with the new key (agent access stayed
  on) or switched off (re-wrap failed). The new wrapped key and the rotation journal are
  written in the **same SQLite transaction** as the re-encryption, so a crash can never
  leave an old wrapped key next to a newly-encrypted database.
- **The browser bridge** reaches the core over `127.0.0.1` only. The core writes a token,
  a protocol version, its own version, its executable path and (while agent access is on)
  the MCP port into `daemon.json` (`exe` is what lets a client verify a process before
  terminating a stale core). The file is written atomically (temp file + rename) so
  clients never read a half-written JSON. The extension's native-messaging allowlist is
  pinned to a single extension ID.
- **The extension requests only** `clipboardWrite`, `nativeMessaging` and
  host permissions for `<all_urls>` (needed for autofill on any site). It stores no
  vault data itself; the unlocked session lives in the desktop app.

## Agent access (MCP) — opt-in, and what it changes

EasyPass can expose a local MCP endpoint (`POST http://127.0.0.1:47821/mcp`) so that AI
agents can read entry *metadata* and — when you allow it — create, update and delete entries.
It is **off by default** and the whole design assumes agents are compromised-by-default:
the tool surface never returns passwords, notes, TOTP seeds, SSH keys or custom-field
values. Each entry has a user-only **"Accessible to agents"** switch (existing entries
default to permanent deny). An entry **created by an agent is open to agents by default**
so it can manage what it just made; you can flip any entry to permanent deny at any time,
and the switch itself is never writable by the agent. The switch is only shown for
`login` / `secure_note` entries.

- **Only `login` and `secure_note` can ever be exposed.** identity and SSH-key entries are
  refused by the core's policy layer for every tool (read, write, delete, restore and
  clipboard) even if an `agentOpen` flag is somehow set on them; the editor hides the
  switch for those types, switching an entry to identity/SSH clears it, and the importer
  forces it closed. There is no `private_key` / `passphrase` clipboard field.

To make agent access work without prompting you or re-entering your password, turning it
on does something the rest of this document does not do elsewhere:

- EasyPass generates a random 256-bit **agent key** and stores it protected by Windows
  **DPAPI** (current user, fixed entropy) in `agent.key.dpapi`.
- A copy of the vault key is **wrapped** with that agent key (AES-256-CBC + HMAC-SHA256,
  encrypt-then-MAC) and stored in the vault database (`vault_meta.agent.wrap`).
- The SHA-256 fingerprint of the current vault key is stored as `vault_meta.vault.keyId`.
- On startup the core unseals the wrapped key, **verifies it against `vault.keyId`**
  (or, for databases created before this field existed, against a real decryption probe;
  an empty database fails closed), and unlocks the **agent session only**. The `ui` and
  `bridge` sessions still require the master password.
- The MCP listener is **fixed to port 47821**. If that port cannot be bound, MCP does not
  start and turning the switch on fails and rolls back — it never falls back to a random
  port (a client would then deliver its bearer key to whoever occupies the port).

Consequences you should be aware of:

- **While agent access is on, the vault can be unlocked without a password** by any
  process running as your Windows account. That is the point of the feature (zero
  interaction), and it is why the switch is off by default and why the settings page
  shows a persistent warning whenever it is on.
- DPAPI keeps the blob unreadable for **other Windows users** and for copies of the files
  moved to another machine or account. It does **not** protect against malware running as
  you — the same-user boundary described under "Known limitations" applies unchanged.
- **The agent session has no idle timeout.** It stays unlocked until you turn the switch
  off, click *Lock agent session*, or the core exits. Locking the desktop does not lock it
  (that would defeat zero-interaction access), and neither does closing the UI window.
- Turning the switch off deletes the DPAPI blob and the wrapped key, **and** stops the
  local MCP listener; there is no "disabled but still listening" state. *Lock agent
  session* keeps the stored key material but drops the in-memory session and cancels all
  pending approvals.
- **Resetting the agent key** replaces it and re-wraps the vault key. The old key stops
  working immediately; the entries themselves are not re-encrypted.
- **Changing the master password re-wraps automatically**, and the new wrapped key is
  written in the **same SQLite transaction** as the re-encryption of the whole vault. If
  the re-wrap cannot be prepared, agent access is switched off rather than left with a
  stale key.
- If the DPAPI blob is missing or cannot be decrypted (different account, different
  machine, corrupted file), or the wrapped key no longer matches `vault.keyId` (for
  example after an interrupted password change), the core does **not** start the MCP
  listener — it fails closed, says so in the log, and you can recover by turning agent
  access off and on again or resetting the agent key. It never falls back to a weaker
  store.
- The MCP listener rejects any request carrying an `Origin` header, validates `Host`,
  refuses non-`POST` methods, requires a per-pairing bearer key (only its SHA-256 is
  stored), accepts no query-string credentials, and never sends CORS headers. All of that
  is checked **before the request body is read**; the body is capped at 256 KB with a 15 s
  read timeout (HTTP 408), a whole request is capped at 90 s (HTTP 504), and at most 16
  requests are handled concurrently (extra requests get HTTP 503).
- **Passwords never travel to the model.** There is no "reveal" tool: the agent can only ask
  the core to put a field value on the **system clipboard** (`copy_to_clipboard`) and learns
  whether that succeeded (no plaintext, and not even a length). The value goes from the core
  process to the clipboard and nowhere else; the call is audited by entry and by
  `op = clipboard:<field>`, never by value. See "Known limitations" for what can read the
  clipboard afterwards.
- **Every agent call is recorded** in the `agent_audit` table (nickname, tool, entry,
  decision). Calls rejected at the HTTP layer (bad Origin/Host/method, missing or unknown
  bearer key, oversized or stalled body, request timeout) are recorded too, as
  `nickname = 未认证 / tool = http` rows. The key, the real client identity, plaintext
  arguments and field values are never written there.
- **Two access modes.** A pairing is either *ask every time* or *trusted pass-through*.
  Trusted requires your master password when you create or switch to it, and the settings
  page keeps a persistent warning while agent access is on; in trusted mode there is no
  per-call prompt for reads/writes/deletes, but every call is audited. In ask-every-time
  mode every write, delete, restore and clipboard call is confirmed by you; ordinary
  metadata reads can be exempted for the session via the "allow reads this session" button.
- **The exemption is visible and revocable.** While any pairing holds a session read
  exemption, the desktop sidebar shows a persistent indicator and the pairing card has a
  revoke button (plus a revoke-all action). The exemption is cleared when agent access is
  turned on or off, the access mode is switched, the master password changes, the agent
  session is locked, the agent key is reset, or the pairing is revoked.
- **Approval decisions are re-validated after you approve.** The core re-reads the pairing,
  the entry and the master switch, re-runs the full policy (entry open, type exposed, scope,
  revoked/expired, mode, master switch), and only then executes. Updates use an
  `updated_at` compare-and-swap, and delete/restore are conditional single statements, so a
  user edit, trashing or revocation during the 45 s approval window cannot be overwritten
  by a stale approval. Pending approvals are cancelled on lock/disable/mode-switch/revoke.
  Approval requests are rate-limited (3 pending per pairing, 8 globally); the dialog shows
  **non-secret values** (new URL/username/name/folder, clipboard field, window purpose/TTL)
  and only says "modified" for secrets. The desktop queues at most 20 requests, disables
  buttons while answering, arms the next request after a short delay, and refuses to render
  approvals while the vault is locked (only denial is possible).
- **No spurious approval prompts.** Hard gates (entry closed, type not exposed, outside the
  pairing scope, pairing revoked/expired) are evaluated **before** the dialog is shown, so
  an agent cannot use the approval UI to train you into approving blindly; the denial is
  still audited. Invalid arguments are also rejected before prompting.
- **Agent deletion is recoverable.** `delete_entry` only moves the entry to the **trash**
  (a `deleted_at` timestamp; the ciphertext is not touched). There is no
  "delete permanently" tool: emptying the trash or deleting an entry for good is a UI-only
  action, so a user can always undo an agent's deletion. Trashed entries still get
  re-encrypted when the master password rotates. "Delete all data" also clears the agent
  audit table, all pairings, the wrapped key, the DPAPI blob, and stops the MCP listener.
- Audit rows are kept to the most recent **1000** (pruned at startup in the background and
  then after every 100 new rows); one call produces at most one row, and rejected/timed-out
  approvals are recorded once.

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
- **Copied secrets are readable from the clipboard.** `copy_to_clipboard` writes the value
  to the normal Windows clipboard; any process running as you (including the agent host
  itself), clipboard history (`Win+V`), clipboard-manager tools and cloud clipboard sync
  can read it until something else overwrites it. There is no auto-clear timer and no
  "clipboard is now clean" promise. The clipboard write uses a short-lived PowerShell
  subprocess started by absolute path with read-back verification — a deliberate
  exception to the project's "no extra process" design goal, because a native helper would
  be far more code for the same effect.
- **Agent access is an explicit trust decision.** In trusted mode an agent can create,
  update and soft-delete any *open* `login`/`secure_note` entry without a per-call prompt;
  the audit trail records it, but nothing asks you in the moment. Keep trusted mode for
  agents you actually trust, or use ask-every-time mode.
- **Pairing usage counters are not maintained.** `calls` / `lastUsedAt` exist in the pairing
  record format but nothing updates them (they stay `0` / `null`); the audit table is the
  authoritative record of what a pairing did.
- **A corrupted `daemon.json` fails closed.** `--lock` / `--shutdown` report failure and
  exit non-zero instead of assuming "no core"; the desktop app reports the core as
  unavailable rather than silently deleting the file and launching a second core.
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
