# Call transcription: research notes

Goal: a running, saved transcript of a voice call, labelled by speaker, covering every participant,
made on this machine. No call audio or text goes to any company's servers.

Status (2026-11-13): first version built. whisper.cpp 1.9.5 vendored (`vendor/whisper`), `src/stt`
(segmenter and worker), `src/app/transcribe.jai` (settings, model download, pane, file). Not yet tried
in a real call. Transcripts are still plain files; encryption at rest is designed below, not built.

## What was built

- **Engine:** whisper.cpp 1.9.5 with its Parakeet runner, CPU only, x86-64-v3 kernels behind a CPUID
  check. Two models offered, downloaded on first use from Hugging Face and checked by size and sha256:
  Whisper base.en q5_1 (60 MB, English) and Parakeet TDT 0.6B v3 q8_0 (669 MB, 25 European languages).
- **Benchmark** (this laptop, 4 threads, the 11 s JFK clip, best of 3; all four transcribed it right):

  | Model | Size | Time | Real-time factor |
  |---|---|---|---|
  | Whisper base.en q5_1 | 60 MB | 0.99 s | 0.09 |
  | Whisper small.en q5_1 | 190 MB | 3.7 s | 0.34 |
  | Whisper large-v3-turbo q5_0 | 574 MB | 16 s | 1.46 |
  | Parakeet TDT 0.6B v3 q8_0 | 669 MB | 1.06 s | 0.10 |

  Whisper pads every chunk to 30 s, so its cost per utterance is fixed: turbo can't keep up with one
  speaker, and was dropped. Parakeet's cost follows the audio's length.
- **Segmenter:** each speaker's 48 kHz frames go through a 48-tap low-pass to 16 kHz mono, and are cut
  into utterances at 700 ms of quiet, a 400 ms gap in frames, or 28 s. Under 300 ms of speech is
  dropped. Past 10 minutes of queued audio, new utterances are dropped and the pane says how much.
- **Consent:** op 18's flags (docs.discord.food: 1 clips, 2 allow voice recording, 4 any-viewer
  clips) are kept per user; only peers with bit 2 are transcribed unless "Transcribe Everyone" is on.
  Others show once as "not transcribed". We still send no op 18 of our own: its format for our side
  isn't confirmed. Hosted servers send no op 18, so their peers count as not consenting.
- **Storage today:** one plain markdown file per call in `<data>/transcripts`, named by date and
  channel, written by the worker. Any program can read these files, and so can Spotlight, Windows
  Search, backup and sync tools. To be replaced by the encrypted store in "Encryption at rest" below.

## What fastcord already gives us

- **Speaker labels come free.** Discord's voice server forwards one Opus stream per speaker, keyed by
  SSRC (the stream's number), and fastcord maps each SSRC to a user ID (`src/voice/conn.jai`
  `map_user`, via op 5 and op 12). So we don't need speaker diarization (guessing who spoke from a
  mixed recording): every stream already names its speaker.
- **Tap point for others:** `rx_tick` in `src/voice/conn.jai` decodes each user's frame separately
  (48 kHz stereo float, 20 ms) before it is mixed. Take the copy right after `codec.decode`, before
  the volume, local mute and self-deafen checks, so the transcript doesn't depend on what you chose
  to hear.
- **Tap point for you:** `tx_tick`, after `mic_process` and before the soundboard mix, and only for
  frames actually sent (not muted, VAD open). The transcript then holds what others heard from you.
- **DAVE (Discord's end-to-end encryption) is no obstacle:** fastcord decrypts frames before decoding.
  Doing the work locally keeps E2EE meaningful; a cloud service would not.
- **Utterance boundaries:** each user's speaking flag (op 5) plus fastcord's own VAD
  (`src/voice/vad.jai`) cut speech into utterances, so the model only runs on speech. This also stops
  Whisper-style models from inventing text in silence.
- **Hosted servers:** their voice uses the same client stack (`call_client`), so the same tap works.

## Engine candidates (all local, all MIT/Apache)

| Engine | Why | Cost |
|---|---|---|
| whisper.cpp (ggml-org) | Plain C/C++, vendorable like our other libs, no extra runtime. CPU, Vulkan, Metal, CUDA. Silero VAD built in. Many languages. | Chunked, not true streaming (seconds of delay). Models: tiny 75 MB, base 142 MB, small 466 MB, medium 1.5 GB. |
| Moonshine v2 (moonshine-ai) | Built for live streaming (~50 ms claimed on an M3). MIT for streaming models. C API. Has its own speaker-ID API we wouldn't need. | Fewer languages (en, es, de, zh, ja, ko, vi, tl, uk, ar). Runtime is probably ONNX Runtime (a large native dependency); unconfirmed. Non-English legacy models are non-commercial. |
| sherpa-onnx (k2-fsa) | One C API over many models: Parakeet TDT 0.6B, streaming Zipformer, Whisper, Moonshine. | Needs ONNX Runtime. Parakeet isn't streaming and needs ~2 GB RAM. |

Leaning: **whisper.cpp first**, because it vendors cleanly with no runtime and already handles many
languages; utterance-chunked delay of a few seconds is fine for a transcript. Revisit Moonshine if
live captions need to feel instant. Decide by measuring on this laptop (step 1 below), not by blog
benchmarks, which disagree.

Sources: [whisper.cpp](https://github.com/ggml-org/whisper.cpp),
[Moonshine](https://github.com/moonshine-ai/moonshine),
[Moonshine v2 paper](https://arxiv.org/abs/2602.12241),
[sherpa-onnx](https://k2-fsa.github.io/sherpa/onnx/),
[a 2026 comparison (vendor blog)](https://openwhispr.com/blog/parakeet-vs-whisper-vs-nemotron).

## Constraints from AGENTS.md

- **Download size (under 25 MB):** no model ships in the binary. The model downloads on first enable
  from a pinned URL checked against a pinned sha256, or the user points at a file they have. That is
  data, not a self-update; the binary never changes. The download only tells the host that someone
  fetched a model, never anything about a call.
- **Threads:** the voice thread only copies samples into a per-speaker ring buffer (no lock, no
  allocation). One worker resamples 48 kHz to 16 kHz mono and runs the model. If it falls behind, it
  drops or delays utterances; it never stalls audio. The UI only reads finished lines.
- **Storage:** transcripts go in `fastcord.db` (added tables), not a new file, encrypted as described
  in "Encryption at rest". Plain text reaches the disk only through Export.
- **Vendoring:** the library goes in `vendor/<lib>/` unmodified, with `fc_<lib>.c` and a README, as
  for codecs.

## Encryption at rest (design, 2026-11-15)

Requirement: a transcript's plain text exists only in fastcord's memory. On disk it is ciphertext that
another program can't read without the user's help, and plain text reaches the disk only when the user
exports it through fastcord.

The vault is the first user of the general scheme in `AT_REST.md` (boxes, drops and key slots for every
store, servers included): a write-only store with a password slot.

### What fastcord has today, and why it isn't enough

- `fastcord.db` seals its secret columns per row with XChaCha20-Poly1305 under a random `db_key`
  (`src/e2e/module.jai` `seal`). `db_key` sits in the database's `meta` table, wrapped by
  `keys.wrap_secret`.
- `wrap_secret` is DPAPI on Windows, with no extra entropy. Any program running as the same user can
  call `CryptUnprotectData` and get the key back. That is how infostealers read Chrome's cookies, and
  why Chrome added App-Bound Encryption. On macOS and Linux, `wrap_secret` passes bytes through
  unchanged (`src/keys/module.jai` "@Todo: Keychain/libsecret"), so the key lies beside the data.
- So the OS keystore stops disk indexers, sync and backup tools, other OS users and a stolen powered-off
  disk (Windows only). It doesn't stop a program running as you. Nothing in fastcord holds a secret
  that only the user knows: no passphrase, PIN or seed phrase exists. Meeting the requirement takes
  one, so this design adds the smallest possible one.

### The idea: write-only encryption

Transcripts are encrypted to a **public key**, and only its **private key** is behind the password.
- Recording never needs the password. The worker encrypts each line as it comes, whether the vault is
  locked or not. No prompt appears at startup or when joining a call.
- Reading past transcripts needs the password: the browser, search and export.
- A program that reads fastcord's memory while the vault is locked gets only the current call's lines.
  Those are on screen anyway. It gets no past call: their keys are gone and the private key isn't
  loaded.

This is the shape of `age` and of HPKE (RFC 9180). Both parts come from the vendored BoringSSL,
bound in `src/crypto`: `hpke_seal` / `hpke_open` with the **X-Wing** KEM (X25519 plus ML-KEM-768, so
a quantum computer later doesn't open today's files), and `scrypt`.

### Keys

| Key | What it is | Where it lives |
|---|---|---|
| Password | Chosen by the user, at least 8 characters, "a few words" suggested | Nowhere. Typed to unlock. |
| KEK (key-encryption key) | `scrypt(password, salt, N=2^17, r=8, p=1)`, 32 bytes, 128 MiB and about 0.3-0.5 s, on a thread | RAM, only while unlocking |
| Vault keypair | X-Wing: 32-byte private seed, 1216-byte public key | Public key in `fastcord.db`, in the clear. Private seed sealed by the KEK. In RAM only while unlocked. |
| Item key | Random 32 bytes, one per call | Sealed to the vault's public key in the call's row. In RAM only during the call, then `crypto.zero`. |

Changing the password reseals one 32-byte seed. Transcripts are never re-encrypted.

When the later user-secret system arrives (the TODO item "Keys: one user secret"), it replaces only
the password-and-scrypt step. It wraps the same vault seed under its own key hierarchy, so existing
transcripts need nothing.

### Format (in `fastcord.db`, added by `MIGRATIONS`)

- `vault`: one row per vault.
  - `id`, `created_ms`, `version` = 1
  - `pub` (X-Wing public key)
  - `salt` (16 bytes) and the scrypt parameters
  - `sealed_seed`: XChaCha20-Poly1305 under the KEK, with nonce, ciphertext and tag stored as `seal`
    stores them. AD (the authenticated, unencrypted extra data) is `"fc-vault-v1 seed" || id || pub`.
  - A wrong password fails the tag check, so no separate "check" value is needed.
  - Rows are never deleted: "start over" adds a new vault and keeps the old one.
- `vault_items`: one row per call.
  - `id`, `vault`, `kind` (1 = transcript), `created_ms`
  - `enc`: the HPKE encapsulation, 1120 bytes.
  - `head`: HPKE base mode, X-Wing / HKDF-SHA256 / ChaCha20-Poly1305, with info `"fc-vault-v1 item"`
    and AD `id || kind`. It seals the item key plus the call's details: channel and server name,
    participants, model.
- `vault_records`: one row per line, keyed `(item, seq)`.
  - XChaCha20-Poly1305 under the item key, with a random 24-byte nonce and AD
    `"fc-vault-v1 rec" || item || seq`.
  - The plaintext is the line: time, user ID and name, then the text, or the "not transcribed" or
    "fell behind" note.
  - The call's last record has kind "end". A transcript without one says it ended unexpectedly
    (fastcord quit or crashed mid-call).

Left in the clear: how many calls there are, when each started, and its number and size of lines. That
is the same as `fastcord.db`'s E2E tables leave. Channel names, participants and text are all inside.

**Why `fastcord.db` and not files:**
- AGENTS.md wants the fewest files.
- `fastcord.db` already has write durability (WAL, `synchronous=FULL`), add-only migrations with
  backups, `secure_delete=ON` (deleted rows are zeroed), and a job thread that app code already uses
  (`#as e2e.Job`).
- The planned device sync carries `fastcord.db`, so transcripts would move with it.

The vault tables don't use `db_key`, so the weak outer wrap doesn't matter to them. The tables name
nothing about Discord, so `src/e2e`'s carrier rule still holds. Changing `src/e2e` needs a new release
fixture (README).

### Flows

- **First enable:** turning on Transcribe Calls asks for a password twice, with one line of warning:
  "If you forget it, these transcripts can't be read. Nobody can recover it." It makes the vault on a
  thread.
- **Calls:** the worker makes the item key and `head` at the first line, appends a sealed record per
  line through a database job, and writes "end" at hang-up, then zeroes the item key. The pane shows
  the live call from memory, as now.
- **Unlock:** the transcript browser asks for the password. scrypt runs on a thread and opens the
  seed. The seed stays in memory until Lock or quit, locked into RAM (`VirtualLock` / `mlock`) and
  zeroed afterwards. Decrypted transcripts are freed and zeroed when the browser closes.
- **Export:** "Export…" on a call writes today's markdown format through `platform.save_file_dialog`
  to wherever the user picks. "Copy" puts it on the clipboard. These are the only ways plain text
  leaves memory.
- **Forgotten password:** "Start over" makes a new vault. The old one's transcripts stay, unopened, and
  open again if the old password turns up. Nothing is deleted.
- **Delete:** a call's rows are deleted only at the user's request, and `secure_delete` zeroes them.
- **Plain files from earlier builds:** if `<data>/transcripts/*.md` exist when the vault is made, offer
  "Encrypt N earlier transcripts". It imports each file as one item, reads it back to check, and only
  then deletes the `.md`. It never runs unasked.

### Threats

| Who | Result |
|---|---|
| Disk indexers (Spotlight, Windows Search), backup and sync tools, AI agents and scripts that read files | Stopped: ciphertext only |
| Another OS user, a stolen or imaged disk, a copied backup | Stopped, down to the password's strength against offline guessing through scrypt |
| A program running as you while fastcord is closed or locked | Stopped for past calls; same password-strength caveat |
| A program running as you while unlocked, or a keylogger | Not stopped. It can read memory or the typed password, and nothing short of OS isolation stops it. |
| A future quantum computer reading copied files | Stopped by X-Wing's ML-KEM half |
| Someone editing the database | AEAD with AD catches forged, swapped or reordered records, and `seq` gaps or a missing "end" show cut ones. Deleting a whole call goes unnoticed. |

### Leaks to close in the same change

- **Logs:** no transcript text in logs, hang reports or crash reports (`watchdog.jai`, `crash.jai`).
  fastcord writes no memory dumps today. Keep it that way.
- **Memory:** lock the seed and item keys into RAM. Transcript text itself can still reach the page
  file, the hibernation file or an OS crash dump, as for every app. Accepted, and documented here.
- **Search:** no index on disk. After unlock, everything is decrypted into memory and searched there:
  a thousand hours is about 60 MB of text, and a linear scan of that is fast. A semantic search's
  vectors are sealed inside each record, since vectors can be inverted back into text.
- **The clipboard** and **"Open Transcripts Folder"**: the folder link goes away; Copy stays the
  user's choice.

### Bindings (done, C1)

- `fc_boringssl.c`: `fc_scrypt` (over `EVP_PBE_scrypt`), `fc_xwing_generate`, and `fc_hpke_seal` /
  `fc_hpke_open`, single-shot base mode with X-Wing, HKDF-SHA256 and ChaCha20-Poly1305.
- `src/crypto`: `scrypt` (refuses shapes past 1 GiB, since the vault's parameters come from disk),
  `xwing_generate`, `hpke_seal`, `hpke_open`.
- Tests: RFC 7914's vectors and DAVE's shape in `src/tests/keys.jai`, with HPKE's round trip and
  tamper cases. DAVE's fingerprints now use `crypto.scrypt`; its old pure-Jai scrypt lives on as the
  fuzzer's reference (`scrypt_reference`), which the `scrypt` target diffs against.

## Consent (the real risk)

- Transcribing others is recording them. About a dozen US states (California among them) and many
  countries require every party's consent. Keeping it local doesn't change that.
- Discord already has a per-user consent signal: "Allow my voice to be recorded in Clips". The client
  sends its own flags on the voice gateway's op 18, and the server relays each peer's. My
  unconfirmed memory of the bits: 1 = clips enabled, 2 = allow voice recording, 4 = allow any viewer
  clips. fastcord ignores op 18 today (`conn.jai` lists `OP_FLAGS` as informational) and never sends
  its own. Confirm against the 0.0.420 bundle (the test profiles' cache, not on this laptop) and
  record the rule in `traffic/CLIENT_RULES.md`.
- Proposed default: transcribe only peers whose flags allow voice recording, and show the others as
  "not transcribed". Whether to also tell the call (a chat line, a status) is the user's call: it is
  outward-facing and the official client sends nothing like it.

## Order of work (2026-11-15)

Done: the benchmark, the vendored engine, the tap, segmenter and worker, op 18 consent, settings, the
pane, the stt test and fuzz targets. C1. Half of A2: a call with one person talking works; several
people are still to try. A1 waits until a Mac is at hand, and Linux is batched with it.

Each step names what it needs. Steps in different lanes can run at the same time; within a lane, go
in order. One lane, the critical path, decides when the feature is finished: **A1 → C1 → C2 → C3 → D2**.

| Step | What | Needs | Why here |
|---|---|---|---|
| **A1** | macOS and Linux builds of `vendor/whisper` (clang `-arch arm64`/`x86_64`, the Linux cross build) | none | A release builds all three platforms. Until this passes, any release may fail. Highest risk, smallest job. |
| **A2** | A real call with several people talking, run by a human: line quality, cut points, op 18 consent, CPU use | none | Agents may not join voice (AGENTS.md live runs). It checks that the feature is worth securing and searching. Findings may change the segmenter, not the steps below. |
| **B1** | Stop plain files now: write nothing to disk until C2, with the pane only | none | A one-line stopgap so no more plain transcripts pile up. Skip it if C2 is days away. |
| **C1** | Bind `EVP_PBE_scrypt` and single-shot HPKE (X-Wing) in `fc_boringssl.c` / `src/crypto`, with known-answer tests; move DAVE's pure-Jai scrypt onto it | none | Pure crypto with no UI, so it is testable on its own. Everything secret builds on it. |
| **C2** | The vault: tables in `MIGRATIONS` plus a release fixture, sealed records written by the worker through a database job, "end" records | C1 | The format is frozen once users have data, so give the record plaintext tagged fields now: a later embedding vector (F2) then adds a field, not a version. |
| **C3** | Password set and unlock dialogs, Lock, keys locked into RAM, "Start over" | C2 | It works by itself: transcripts are encrypted and readable again, with no reader yet. |
| **C4** | User-started import of the old `.md` files | C3 | Ends the plain-file era for anyone who used a build before C2. |
| **E1** | One text module: Unicode case and accent folding, tokenizer (from `gif_words`), scorers, highlighter. Move the switcher, emoji, GIF and E2E search onto it. | none | Independent of encryption. It fixes the "É" versus "é" misses for every search now, and D2 needs it. |
| **D1** | Transcript reader: list, open, Export (`save_file_dialog`), Copy, Delete | C3 | Read-only first. It needs only the unlocked vault. |
| **D2** | Word search in the reader | D1, E1 | The first search users get. |
| **F1** | A shared "local models" piece: pinned download, size and sha256 check, CPU check, worker, taken out of `transcribe.jai` and `stt` | A1 | It is refactoring alone, best done once the engine builds everywhere, and before a second model arrives. |
| **F2** | A sentence-embedding model on ggml (llama.cpp's embedding path or a small BERT graph); the worker seals a vector into each record | F1, C2 | Lines written before F2 have no vector, so embed them once, on first unlock. |
| **F3** | Meaning search in the reader: embed the query, rank by cosine similarity in memory, alongside word search | F2, D2 | The "semantic" goal. It comes last because it costs the most and rests on everything else. |
| **G1** | Design the one user secret (the TODO item "Keys: one user secret") | none | Only a design doc, so it can start any time. It has to be settled before a second feature wants a secret, e.g. the token or key backups. |
| **G2** | Build G1. The vault moves over by resealing its key on first unlock. | G1, C3 | It replaces the MVP password, and transcripts are never re-encrypted. |

Lanes:
- Engine: **A1 → F1 → F2 → F3**.
- Secrecy: **C1 → C2 → C3 → C4**, then **G2** once **G1** is designed.
- Search: **E1** now, then **D1 → D2**, which wait for C3.
- A2 and B1 stand alone.

Don't skip ahead:
- No reader before C3: it would only show plain files that C2 replaces.
- No embeddings before C2: vectors stored outside the vault would leak the text.
