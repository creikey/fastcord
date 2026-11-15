# Encryption at rest (design, 2026-11-15)

One scheme for everything fastcord keeps on disk: the client's `fastcord.db`, the transcript vault,
the token and key files, and the self-hosted server's database and backups. The transcript vault
(`TRANSCRIPTION.md`, "Encryption at rest") is its first user. This file is the general version, so
the next feature that stores something secret adds a row to the table in "Where each store goes"
instead of a new design.

Nothing here is built yet beyond what "Today" lists and C1's bindings (`crypto.scrypt`,
`xwing_generate`, `hpke_seal`, `hpke_open`).

## Goal and limits

- **Goal:** a file copied off the machine, a disk image, a backup, a cloud-synced folder, or another
  OS user reads nothing but sizes. Where the user has a secret (password, later the user secret), a
  program running as the same user reads nothing while fastcord is locked or closed.
- **Limits, stated plainly:**
  - While a store is unlocked, any program running as the same user can read fastcord's memory
    (Windows lets same-user processes read each other's memory by default). Write-only stores keep that
    window small: only what is open on screen is in memory.
  - The OS keystore is not a user secret. DPAPI unwraps for any program running as the same Windows
    user, and libsecret on Linux likewise once the login keyring is open. Only macOS's Keychain can
    bind an item to fastcord's signing identity, and only for a signed build.
  - A self-hosted server must read its channels to serve them. At-rest encryption there protects
    copies of the file (disk images, volume snapshots, backups), not the running host or its operator.
    Only E2E channels (`FEDERATED.md`) would hide messages from the host.

## Today

| Store | Protection | Gap |
|---|---|---|
| `fastcord.db` (E2E sessions, prekeys, decrypted DM history) | Secret columns sealed under `db_key` (XChaCha20-Poly1305, AD = table name and row key, `src/e2e/module.jai` `seal`), `db_key` wrapped by `keys.wrap_secret` | DPAPI only on Windows; macOS and Linux store `db_key` in the clear. Metadata (who, when, which conversation) is plain. |
| Key files (`<data>/keys`) | `keys.wrap_secret` | As above. `unwrap_secret` accepts an unwrapped blob as success. |
| `<state>/token` | None | Every saved Discord token in the clear (TODO "Security" item). |
| Transcripts (`<data>/transcripts`) | None | Plain `.md` files. Vault designed in `TRANSCRIPTION.md`. |
| `settings.json` | None | Drafts of non-E2E channels, search history, `fc://` invite codes. |
| Media cache (`<state>/cache`) | None for Discord media; E2E files are cached only as ciphertext | Ordinary DM attachments and their URLs. |
| Server database (`-serve:<file>`), its WAL, backups, trash copies, log | `0600` on macOS and Linux; nothing else | Everything: messages and their FTS5 index, attachments, users, the TLS private key, webhook tokens, invites. Deleted rows stay in free pages. DM bodies and files are already E2E ciphertext; their metadata is plain. |

## Three pieces

Everything is built from three pieces, each one small format.

### Box: a sealed value under a symmetric key

```
box = version (1 byte, 1) || nonce (24) || ciphertext || tag (16)
AEAD = XChaCha20-Poly1305
AD   = "fc-box-v1" || lp(store) || lp(table) || lp(column) || lp(row key)
lp(x) = u16 little-endian length || x
```

- The AD binds a value to its place: moved to another row, column, table or store, it won't open.
  Length prefixes keep the fields unambiguous. Today's `seal` joins table and row with no separator
  and has no column or version; it stays readable as the legacy format (its rows have no version
  byte, and every table has one sealed column), and new tables use boxes.
- Random nonces: 24 bytes, so no counter has to survive a crash.
- One code path, in `src/keys` next to `wrap_secret`, used by every store.

### Drop: a value sealed to a public key

```
drop = HPKE base mode, X-Wing / HKDF-SHA256 / ChaCha20-Poly1305 (crypto.hpke_seal)
info = "fc-drop-v1 " || purpose
```

- For stores written while locked. The writer holds only the store's public key. Each item (a call's
  transcript, a backup) gets a random 32-byte key, dropped to the public key in the item's head, and
  its records are boxes under that item key.
- Opening needs the store's private key, which is itself a value behind slots (below).
- X-Wing holds against a later quantum computer, so today's files stay closed.

### Slots: ways to unlock one key

A store's key (its symmetric key, or its private key's 32-byte seed) is wrapped once per way to
unlock it, like LUKS key slots. Any one slot opens it; adding or removing a slot never re-encrypts
data.

```
slot(store, id, kind, params, wrapped)
wrapped = box under the slot's KEK, AD = "fc-slot-v1" || lp(store) || lp(kind) || lp(id)
```

| Kind | KEK from | Unlocks without asking? | Stops a same-user program? |
|---|---|---|---|
| `keystore` | DPAPI / Keychain / libsecret | Yes | No (Keychain with an app ACL: partly) |
| `password` | `scrypt(password, salt, N, r, p)`, params in `params`; N=2^17, r=8, p=1 today | No | Yes, while locked |
| `user_secret` | The user secret (TODO "Keys: one user secret", G1) | No | Yes, while locked |
| `host` | A key the server operator supplies (key file or environment, e.g. a Fly secret) | Yes | No |
| `recovery` | A printed random code, no stretching needed | No | Yes |

- Slots live in the same file as the data they unlock, so a backup carries them and a restore needs
  nothing else.
- A slot whose kind this build doesn't know is kept untouched: a newer build's slot survives an older
  build opening the file.
- `scrypt` parameters come from the file, so `crypto.scrypt` refuses shapes past 1 GiB.
- G2 (the user secret) becomes a slot kind; moving a store over adds a `user_secret` slot and removes
  the MVP `password` slot, both on unlock, never re-encrypting data.

## Two kinds of store

- **Read-write** (the app reads whenever it runs): `fastcord.db`, the token, key files, the server
  database. One symmetric store key behind slots; values are boxes.
- **Write-only** (written while locked, read only after unlock): transcripts, server backups, and
  any future archive (a call recording, a message history export). An X-Wing keypair whose seed is
  behind slots; items are drops. A stolen running app or a later compromise gets nothing written
  before its last unlock.

The choice is one question: must fastcord write it while the user hasn't unlocked? Then it is
write-only.

## Whole-file encryption for SQLite

Boxes hide values, not shape: row counts, timestamps, who wrote what, and the server's FTS5 index,
which must hold searchable text. The server needs queries and search over its messages, so boxing
its columns would break both. The fix is to encrypt the file's pages instead, beneath SQLite:

- Each 4 KiB page is sealed with an AEAD under the store key, page number in the AD. The WAL is
  sealed the same way; temp files stay in memory (`temp_store=MEMORY`).
- Freed pages hold only ciphertext, so deleted rows become unreadable to anyone without the key, which
  also covers the server's missing `secure_delete`.
- Backups made with `VACUUM INTO` come out under the same key; a backup meant to leave the machine is
  a drop to the owner's backup key instead (below).
- **Library:** SQLite3 Multiple Ciphers (MIT, a maintained SQLite amalgamation with page ciphers,
  including ChaCha20-Poly1305 and SQLCipher's AES-256 scheme) is the vetted path AGENTS.md prefers.
  The alternative is our own VFS shim over BoringSSL's AEAD (a few hundred lines, no fork of SQLite).
  **Recommendation:** SQLite3 Multiple Ciphers, pinned and vendored per AGENTS.md, with a raw 32-byte
  key (never its passphrase KDF), and a test that opens a page-tampered file and gets an error.
- Cost to measure before committing: about 5-15% on page-bound queries in published numbers; check
  the server's bench and the client's E2E tests.

Page encryption and boxes stack: the transcript vault lives inside `fastcord.db` but stays write-only,
since its items are drops whose private key the running app doesn't hold while locked.

## Where each store goes

| Store | Kind | Slots | Granularity | Step |
|---|---|---|---|---|
| Transcript vault (`vault*` tables in `fastcord.db`) | Write-only | `password` (MVP), later `user_secret` | Drops per call, boxes per line | C2-C3 in `TRANSCRIPTION.md` |
| `fastcord.db` | Read-write | `keystore`; `user_secret` optional once G1 exists | Boxed columns today, whole file later | S3 |
| Key files | Read-write | `keystore`; their passphrase export stays separate (Keys item) | Whole file | S2 |
| `<state>/token` | Read-write | `keystore` | Whole file | S2 |
| Drafts and search history | Move from `settings.json` into `fastcord.db`, boxed | Through `fastcord.db` | Rows | S3 |
| Media cache | Leave plain | | | Not planned: Discord's CDN serves the same bytes to anyone with the URL. E2E files are already ciphertext. |
| Logs | Leave plain | | | Already no tokens, cookies or message text by policy. |
| Server database and WAL | Read-write | `host`, plus `keystore` when the host is a desktop | Whole file | S4 |
| Server backups and trash copies | Write-only, to the owner's backup key | The owner's `password` or `user_secret` | Drop per backup | S4 |
| Server DMs | Already E2E ciphertext | | | Their metadata is hidden by S4's whole-file encryption. |

## Memory

- Unlocked keys and open plaintext stay in memory locked against paging (`VirtualLock`, `mlock`;
  neither is bound yet), and are zeroed on Lock, on quit, and after an idle timeout the user sets.
- Hibernation still writes locked pages to disk on Windows; say so in the Lock help rather than claim
  otherwise.
- Crash reports stay text only (`crash.jai`), never a memory dump.

## Migration rules (from AGENTS.md)

- A schema change only adds tables or columns. Slots, boxes and drops are new tables or new columns.
- Back up a file before migrating it, and never overwrite the backup. **Conflict to settle:**
  encrypting a plain server database leaves its pre-migration backup in the clear, and the rules
  forbid deleting it. Proposal: keep it, and have the host print where it is and offer to replace it
  with a drop to the owner's backup key; deleting it stays the owner's choice.
- A file that won't open or unlock is set aside, never reset (today's `.sealed-<ms>` path).
- Every format here starts with a version, and a build reads every version an earlier release wrote,
  including today's unversioned `seal`.

## Steps

- **S1** (with C2): `box` and `drop` helpers in `src/keys`, with known-answer tests and fuzz targets
  beside `scrypt` and `hpke` (every changed byte, place or version fails to open).
- **S2** (with C3): the `slot` table and the `keystore` and `password` kinds. The token and key files
  move behind a `keystore` slot; `unwrap_secret` stops accepting unwrapped input once nothing writes
  it. Keychain and libsecret land here, which closes today's macOS and Linux gap.
- **S3:** drafts and search history move into `fastcord.db`; whole-file encryption for
  `fastcord.db`, which hides E2E metadata.
- **S4:** the server: whole-file encryption under a `host` slot, backups as drops to the owner's
  backup key, and the migration of existing server files.
- **S5** (G2): the `user_secret` slot kind, then each store adds one on unlock.

## Open questions

- Whether `fastcord.db` should ever require the user secret at startup, or only offer it (it holds
  E2E sessions, so a forgotten secret would lose every encrypted DM). Default proposal: `keystore`
  always, `user_secret` optional.
- Which key the owner's server backups drop to before G1 exists: a per-server backup password set at
  `-serve` setup is the MVP.
- Whether the server's `host` key may live beside the database at all (it then only protects copies
  of the database file alone). On Fly it lives in secrets, apart from the volume; on a desktop host,
  in the OS keystore.
