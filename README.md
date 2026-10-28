# fastcord

A fast, native third-party Discord client written from scratch in Jai. No browser, no
webview. Metal on macOS, Direct3D 11 on Windows, OpenGL (EGL) on Linux.

## Goals

- Instant, smooth, low battery: render only when something changes or animates.
- Immediate-mode UI library written here (after Ryan Fleury's UI series).
- Pixel-faithful to the official client's layout, colors and interactions.
- **Indistinguishable on the network**: the `discord` module produces the same traffic as the official
  desktop client doing the same actions: requests, headers and their wire order, TLS ClientHello,
  HTTP/2 and HTTP/3 settings, gateway payloads, telemetry and timing. Install-specific values (ids,
  tokens) differ; what Discord's servers see of the client's health and behaviour does not. Proof:
  `traffic/` (official captures) and `traffic/PARITY.md` (tests and the last live session).

## Layout

| Path | What |
|---|---|
| `build.jai` | The whole build: C libraries, the app, tools, tests, benches, releases. |
| `src/netio` | `Stream` interface (read/write/close) + TCP. Every protocol sits on a `Stream`. |
| `src/tls`, `src/quic` | TLS and QUIC over vendored BoringSSL and ngtcp2, configured like Chrome (the official client is Electron); OS trust store. |
| `src/inflate`, `src/zstd`, `src/brotli` | Decoders (Wuffs, zstd, brotli): the gateway uses zstd-stream; HTTP responses may be gzip/br/zstd. |
| `src/crypto` | Hashes, HMAC/HKDF, AEADs, P-256, SLH-DSA, X25519 over BoringSSL; BLAKE3. |
| `src/keys` | Identity keypairs for self-hosted servers: the BLAKE3 Merkle root, durable key files beside `<state>`. |
| `src/etf` | Erlang External Term Format codec (gateway uses `encoding=etf`) and JSON. |
| `src/http` | HTTP/1.1, HTTP/2, HTTP/3, WebSocket over vendored picohttpparser, nghttp2, nghttp3, wslay. |
| `src/discord` | Unofficial Discord library: REST, gateway, telemetry, voice, state store. |
| `src/voice*`, `src/opus`, `src/audio` | Voice: RTP, DAVE/MLS end-to-end encryption, Opus, CoreAudio / WASAPI / ALSA. |
| `src/video` | Camera and screen capture and the H.264/H.265 encoder for calls and Go Live (macOS: AVFoundation, ScreenCaptureKit, VideoToolbox; Windows: Media Foundation, DXGI; Linux: V4L2 cameras and openh264, no screen capture yet). |
| `src/platform`, `src/gfx` | Window, input, display link, clipboard; the renderers (Metal, D3D11, OpenGL) and text (CoreText, DirectWrite, FreeType + HarfBuzz). |
| `src/ui` | Immediate-mode UI core: keyed boxes, layout, animation, text editing. |
| `src/app` | The client itself. |
| `src/tool_capture*`, `src/tool_scrub`, `src/tool_trafficdiff`, `src/discord_parity` | Recording the official client (DevTools protocol), scrubbing captures, diffing traffic, the live session runner. |
| `traffic/` | Committed scrubbed captures of the official client, one per scenario. |
| `tests/` | Scenarios (`scenarios/*.scn`), UI scripts (`ui/`), benches (`bench/`). |

## Build and run

Needs Jai (beta 0.2.030 or later, `jai` on `PATH`). The build downloads one pinned Zig into `build/zig` on
first use and compiles all the C with `zig cc`; there is no other C compiler. Per OS it also needs:
- macOS: the Xcode command line tools, for the SDK (headers, libc++, frameworks) and `lipo`.
- Windows: the Visual Studio Build Tools (the MSVC headers and libraries).
- Linux builds are cross-compiled from Windows or macOS with Zig (`zig cc` against glibc 2.17): append
  `linux` to any target, e.g. `jai build.jai - dev linux` writes `build/fastcord-dev` for x86_64 Linux.

```sh
jai build.jai - dev       # build/fastcord-dev: optimised with symbols, for daily use
jai build.jai             # build/fastcord: very optimised
jai build.jai - debug     # build/fastcord-debug: unoptimised, frames take ~5x longer
jai build.jai - help      # every target
./build/fastcord-dev      # logs in with $FASTCORD_TOKEN or <state>/token
```

Every build first compiles the vendored C (`vendor/`) into `build/fc_vendor.a` (BoringSSL takes
about a minute the first time); `jai build.jai - c` does only that.

`<state>` is `~/Library/Application Support/fastcord/state` (macOS), `%LOCALAPPDATA%\fastcord\state`
(Windows) or `${XDG_DATA_HOME:-~/.local/share}/fastcord/state` (Linux). With no token (or a rejected one) the app
opens the login page: email or phone number and password (with the multi-factor step), or the QR code
for the mobile app, as the official client does (`src/discord/auth.jai`, `remote_auth.jai`). The token
it gets is saved there. A small "Log in with a token" link takes a token copied from a browser instead.

## Testing

```sh
jai build.jai - check-full       # overall check, on request (~3 min): test + ui + bench budget + secrets scan
jai build.jai - test [names]     # the offline traffic-parity tests (substrings pick tests)
jai build.jai - ui               # headless UI scripts (tests/ui) and the dead-control sweep
jai build.jai - module <name>    # type-check one module, every procedure
```

Headless app runs render offscreen and write a PNG, driven by a script of input events with assertions
(`click`, `dclick`, `down`/`move`/`up`, `rclick`, `type`, `key enter cmd`, `scroll`, `wait`, `shot`,
`expect_selection`, `expect_clipboard`; attachments: `stage <path>...`, `drop <path>...`,
`paste_image <png>`, `paste_files <path>...`, `drag_enter`/`drag_leave`, `wait_attachments`,
`expect_attachments`, `upload_limit <bytes>`, `expect_notice`):

```sh
./build/fastcord-dev -shot:out.png -dpi:1 -fixture:tests/ui/chat.jsonl \
    -channel:1546820603343016006 -script:tests/ui/select_across_messages.txt
./build/fastcord-dev -shot:out.png -dpi:1 -live:12 -channel:<id>   # real network, read-only
```

`FASTCORD_STATS=1` prints the frame rate and what is animating (idle should be ~0 fps), plus per-phase
timings for frames over 25 ms, and on exit the focused field's text. A frame stuck for 5 s writes a hang
report (the lock the UI thread waits on and its holder) to stderr and to `logs/` beside `<state>`. All
mutexes go through `locks`, which panics at the faulty call on misuse instead of deadlocking.

CI (`.github/workflows/ci.yml`) builds on Windows, then macOS and Linux. Pushes don't trigger it; run it
by hand with `gh workflow run ci.yml`. Jai is private, so CI
downloads it from `ci/jai-server`, a Fly.io app (`fastcord-jai`) that serves `/data/jai.zip` only to the
`JAI_PASSWORD` repo secret; never put Jai, or a link to it, anywhere public. To rotate the password, set it
with `fly secrets set JAI_PASSWORD=...` and `gh secret set JAI_PASSWORD`. To update Jai, zip it (top folder
`jai/`) and `curl -T jai.zip -H "Authorization: Bearer <UPLOAD_PASSWORD>" https://fastcord-jai.fly.dev/jai.zip`;
the upload password is a separate Fly secret that CI never holds.

## Performance

The UI is immediate-mode and rebuilt twice per frame, so its cost is paid every frame. The app sleeps
until input arrives, so what a user feels is latency: input to the GPU finishing the frame, starting
from idle clocks. That is the headline number, not throughput. Measure before and after any UI or
rendering change:

```sh
jai build.jai - bench save       # build dev, run tests/bench/*.txt, keep it as build/bench/baseline.jsonl
jai build.jai - bench            # same, compared with the baseline, budget checked
jai build.jai - bench chat       # one script
python3 -I tools/folded.py build/bench/chat.folded top 30              # hottest procedures
python3 -I tools/folded.py build/bench/chat.folded callees 'message_row' 3
python3 -I tools/folded.py build/bench/chat.folded callers 'box_make_key' 3
```

- `tests/bench/make_bench_fixture.py` writes `build/bench/heavy.jsonl` and generated images in
  `build/bench/media` shaped like a made-up heavy account (users, avatars, guilds and folders,
  channels, roles, emoji, unreads, mutes, read states), plus a 400-message guild channel and a
  300-message DM for the chat benches. `-shape:<file>` writes a real account's shape for comparison;
  never commit it.
- `FASTCORD_MEDIA_DIR=<dir>` serves CDN images from files named by the URL's last path component, so
  fixture runs load avatars, icons and emoji like a live run, offline.
- `tests/bench/*.txt` are scripts. `bench <name>` starts a measured section, `bench_off` ends it,
  `repeat N <cmd>` repeats a command, `sweep x0 y0 x1 y1 n` moves the mouse in steps, `open <channel id>`
  or `open unread_dm` opens a channel, and `settle <seconds>` runs real-time frames so loads finish.
  `account.txt` runs unchanged on the fixture and live.
- Measured frames run at a real 60 Hz cadence and each waits for the GPU, so CPU and GPU start every
  frame from idle, as in use. Per section the report gives latency, UI pass and render CPU time,
  `ui.Stats` counters, and quads and draw calls.
- Any app run takes `-bench[:<file.jsonl>]`, `-prof:<prefix>` (samples the UI thread at ~1 kHz; writes
  `<prefix>.txt` and `<prefix>.folded` for speedscope.app; self time is exact, callers approximate),
  `-trace:<file>` (a Chrome trace of `prof.zone` scopes) and `-shape:<file>`.
- On a real account, read-only: `./build/fastcord-dev -bench -dpi:1 -live:15 -script:<s> -prof:build/bench/live`.
  Don't type in such a script: typing sends "is typing" from the account.
- `tests/bench/budget.json` caps the deterministic counters (boxes, text layouts, draw commands, draw
  calls) per section; `bench` and `check-full` fail when one grows. Timings are never checked: they vary by machine.

Keep the UI immediate-mode. Make each pass cheaper instead of caching results across frames:
- Declare only what can be seen. `ui.list_window` turns a uniform list into a spacer plus the visible
  rows. `ui.offscreen(box)` tells you a box was outside its clip last frame, so you can skip its children.
- Sort with decorated keys computed once per element, never table lookups inside a comparator.
- Look up a table entry once, by pointer (`table_find_pointer`).
- Per-pass memory comes from the UI arena or `temp` (reset every frame); nothing is freed one by one.

## Conventions

- Idiomatic Jai: Jai's own modules, `temp` only for data that dies before its thread's reset; see
  `src/STYLE.md`.
- Errors are small enums or bools, not strings.
- Secrets (tokens, passwords, raw captures) live only in `.secrets/` and `discord_credentials.txt`,
  both gitignored. Never commit them.

## Fingerprint regressions

Where our traffic still differs from the official client (Chrome 148 captures in the repo), and why.
QUIC transport parameters, ALPN and the Initial datagram envelope (two 1250-byte datagrams, 8-byte DCID,
empty SCID, no token) match exactly.

- QUIC Initial contents: Chrome fragments its CRYPTO frames and interleaves PING and PADDING frames
  ("chaos protection"), and numbers its first packets with 1- then 2-byte packet numbers; ngtcp2 builds
  its own frame layout and packet-number lengths and offers no setting for either. Fix: a patch to
  ngtcp2's packet builder, or upstream support for Chrome-style CRYPTO scrambling.
- HTTP/3 SETTINGS: nghttp3 writes 06, 01, 07, 33; Chrome writes 01, 06, 07, 33 plus a GREASE setting,
  and a GREASE frame on the control stream. nghttp3 fixes the order and has no GREASE option. Fix: an
  nghttp3 patch or upstream option.
- QPACK encoder/decoder streams: nghttp3 opens both at setup; Chrome's timing differs. PRIORITY_UPDATE
  frames follow nghttp3's scheduling, not Chrome's. Fix: an nghttp3 patch.
- No 0-RTT requests on resumed QUIC sessions (the hello still offers early data, as Chrome's does).
  Fix: replay-safe GETs through `ngtcp2_conn_open_bidi_stream` before the handshake completes.
- TLS signature_algorithms carries a GREASE value: BoringSSL ce9c15c (vendored) adds one, the revision
  Chrome 148 pins (d8be2b4a, 2026-04-06) does not. Fix: re-vendor BoringSSL at d8be2b4a; every API
  `src/tls` and ngtcp2 use exists there except `SSL_CTX_set1_tls13_ciphers` (see the next entry).
- ECH GREASE uses ChaCha20-Poly1305 where Chrome uses AES-128-GCM on AES-capable CPUs, and the TLS 1.3
  cipher order is forced: BoringSSL is built with `OPENSSL_NO_ASM`, so `EVP_has_aes_hardware()` is 0,
  and `src/tls` overrides the order with `SSL_CTX_set1_tls13_ciphers`. Fix: build BoringSSL's assembly
  and drop the override.
- HTTP/2 headers, priority and window updates follow Chrome (`h2.jai`, `hpack.jai`), except: DATA
  for a stream nghttp2 already closed is given back by nghttp2 itself (its own threshold, not Chrome's),
  and an unanswered PING never closes the connection as Chrome's does. Fix: track those in
  `h2.jai` if a server is seen to care.

## Releasing

Releases ship only when a human asks for one, usually by asking Claude. Push `main`, pick the version
after `gh release list -L 1`, and run `.github/workflows/release.yml`:

```sh
gh workflow run release.yml -f version=v0.5.0
gh run watch "$(gh run list -w release.yml -L 1 --json databaseId -q '.[0].databaseId')"
```

It drafts the release (generated notes), builds `release <tag>` on a Mac runner (the Mac app) and a
Windows runner (Windows and Linux), uploads the archives, and publishes the release once all three are in.
The version is the tag; nothing is bumped by hand. `jai build.jai - release v0.5.0` builds the same
archives into `dist/` locally (macOS: `fastcord-macos.zip`; Windows: `fastcord-windows.zip` and
`fastcord-linux-x86_64.tar.gz`).

- Windows: `Fastcord.exe` (GUI subsystem, icon from `assets/fastcord.ico`), zipped. Not code-signed, so
  SmartScreen warns on first launch.
- Linux: one x86_64 binary for every distribution. It links only glibc (2.17+) and opens everything else at
  run time with `dlopen`: libX11 (Wayland desktops through XWayland), libEGL for OpenGL 3.3, fontconfig,
  libasound (ALSA, which PipeWire and PulseAudio serve). `tools/package_linux.py` packs it with a desktop
  entry, the icon and `install.sh` (per user in `~/.local`, or system-wide as root).

The site and the in-app updater both use the latest release:
- download links: `https://github.com/creikey/fastcord/releases/latest/download/fastcord-macos.zip`,
  `fastcord-windows.zip`, `fastcord-linux-x86_64.tar.gz`
- the app checks `api.github.com/repos/creikey/fastcord/releases/latest` at launch and every 6 hours;
  when the tag is newer than its own version, an **Update** pill appears in the title bar and opens
  creikey.com/fastcord (right-click it to dismiss). Dev builds never check.

Releases are ad-hoc signed and not notarized, so macOS blocks the first launch (users click **Open
Anyway** in System Settings → Privacy & Security). Notarizing needs an Apple Developer ID; sign with
`codesign --sign "Developer ID Application: …" --options runtime` and submit with `xcrun notarytool`
before zipping.

## Website

`site/` is the page served at creikey.com/fastcord. `.github/workflows/pages.yml` deploys it on pushes to
`main` that touch `site/`. `python3 -I tools/parity_viz.py` regenerates `site/parity.json` (the wire
timeline) from `traffic/` and the last live session's scrubbed captures (`.secrets/ours/`); it keeps only
request shapes and timings.

## Licence, trademarks and credits

fastcord's own code is MIT (`LICENSE`); vendored libraries keep their own licences (`vendor/<lib>/README`).

fastcord is an unofficial client. It is not affiliated with, endorsed by or sponsored by Discord Inc.
"Discord" is a trademark of Discord Inc., used here only to say which service fastcord talks to.

The repository ships no Discord artwork. Icons are Phosphor (MIT, `assets/icons/`). Emoji images are
Twemoji (CC-BY 4.0, by Twitter and contributors), and the gg sans font and default avatars are fetched
from Discord's servers at runtime, as the official client does.
