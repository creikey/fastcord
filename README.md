# fastcord

A fast, native Discord client written from scratch in Odin. No browser, no
webview. Metal on macOS, D3D11 on Windows (later: iOS/Android).

## Goals

- Instant, smooth, low battery: render only when something changes or animates.
- Immediate-mode UI library written here (after Ryan Fleury's UI series).
- Pixel-faithful to the official client's layout, colors and interactions.
- **Well-behaved on the network**: the `discord` library is tested end to end
  to produce the same traffic (requests, headers, header order, TLS
  ClientHello, HTTP/2 settings, gateway payloads, timing) as the official
  desktop client doing the same actions.

## Layout

| Path | What |
|---|---|
| `src/netio` | `Stream` interface (read/write/close) + TCP. Every protocol sits on a `Stream`. |
| `src/tls` | TLS 1.3 client, ClientHello byte-identical in shape to Chrome (the official client is Electron). |
| `src/zstd`, `src/brotli` | Decoders (gateway uses zstd-stream; HTTP responses may be br/zstd/gzip). |
| `src/etf` | Erlang External Term Format codec (gateway uses `encoding=etf`). |
| `src/http` | HTTP/1.1, HTTP/2 + HPACK, WebSocket client. |
| `src/discord` | Unofficial Discord library: REST, gateway, voice, state store. |
| `src/platform` | Window, input, display-link, clipboard. `darwin/` and `windows/`. |
| `src/gfx` | Renderer: rects/rounded rects/borders/shadows/glyphs/images. Metal / D3D11. |
| `src/ui` | Immediate-mode UI core: keyed boxes, layout, animation, text editing. |
| `src/app` | The client itself. |
| `tools/capture` | Records the official client's traffic via the DevTools protocol. |
| `tools/scrub` | Turns raw captures into committable, secret-free fixtures. |
| `traffic/` | Committed scrubbed captures, one per e2e scenario. |
| `tests/` | End-to-end scenarios driving both the official client and ours. |

## Build and run

```sh
./build.sh            # build/fastcord (-o:speed)
./build.sh debug      # build/fastcord-debug (unoptimised: frames take ~5x longer)
./build.sh dev        # build/fastcord-dev (debug checks and symbols, optimised; for daily use)
./build/fastcord      # logs in with $FASTCORD_TOKEN or <state>/token
```

`<state>` is `~/Library/Application Support/fastcord/state` on macOS and `%LOCALAPPDATA%\fastcord\state`
on Windows. With no token (or a rejected one) the app opens an intro screen that explains how to copy
the token from a browser and saves it there.

## Testing

```sh
tests/run_all.sh                 # every package's unit tests + headless UI scripts
FASTCORD_LIVE=1 ./build.sh test discord   # live tests against Discord as the test accounts
tests/ui/run.sh                  # just the UI scripts (tests/ui/*.txt) against tests/ui/chat.jsonl
```

Headless app runs render offscreen and write a PNG, driven by a script of
input events with assertions (`click`, `dclick`, `down`/`move`/`up`, `rclick`,
`type`, `key enter cmd`, `scroll`, `wait`, `shot`, `expect_selection`,
`expect_clipboard`):

```sh
./build/fastcord-debug -shot:out.png -dpi:1 -fixture:tests/ui/chat.jsonl \
    -channel:1546820603343016006 -script:tests/ui/select_across_messages.txt
./build/fastcord-debug -shot:out.png -dpi:1 -live:12 -channel:<id>   # real network
```

`FASTCORD_STATS=1` prints the frame rate and what is animating (idle should be ~0 fps), plus
per-phase timings for frames over 25 ms, and on exit the focused field's text. A frame stuck for 5 s writes a hang report (the lock the UI
thread waits on, its holder, and on Windows every thread's stack) to stderr and to `logs/` beside `<state>`.
All mutexes go through `fc:locks`, which panics at the faulty call on misuse instead of deadlocking.
Run `python3 -I tools/check_secrets.py` before committing.

All code imports siblings through the `fc` collection: `import "fc:netio"`.

## Performance

The UI is immediate-mode and rebuilt twice per frame, so its cost is paid every frame. Measure before
and after any UI change:

```sh
tools/bench.sh           # build dev, run tests/bench/*.txt on a heavy fixture, compare, check budget
tools/bench.sh --save    # same, then keep this run as build/bench/baseline.jsonl
tools/bench.sh chat      # one script
python3 -I tools/folded.py build/bench/chat.folded top 30              # hottest procedures
python3 -I tools/folded.py build/bench/chat.folded callees 'message_row' 3
python3 -I tools/folded.py build/bench/chat.folded callers 'box_make_key' 3
```

- `tests/bench/make_bench_fixture.py` writes `build/bench/heavy.jsonl`: 60 guilds, 120 DMs, 150
  friends, and long channels with every kind of markdown. It is synthetic and deterministic.
- `tests/bench/*.txt` are scripts. `bench <name>` starts a measured section and `repeat N <cmd>` repeats a
  command. `sweep x0 y0 x1 y1 n` moves the mouse in steps, and `open <channel id>` opens a channel.
- Any app run takes `-bench[:<file.jsonl>]` (per-section median/p95 of each UI pass, plus `ui.Stats`
  counters) and `-prof:<prefix>` (samples the UI thread at ~1 kHz during UI passes; writes
  `<prefix>.txt` and `<prefix>.folded` for speedscope.app; on macOS self time is exact but callers are
  approximate). It also takes `-trace:<file>` (a Chrome
  trace of `prof.zone` scopes).
- On a real account, read-only: `./build/fastcord-dev -bench -dpi:1 -live:15 -script:<s> -prof:build/bench/live`.
  Don't type in such a script: typing sends "is typing" from the account.
- `tests/bench/budget.json` caps the deterministic counters (boxes, text layouts, draw commands)
  per section; `tests/run_all.sh` fails when one grows. Timings are never checked: they vary by machine.
- `prof.zone("name")` times a scope (one thread-local check when no section is measuring). Zones show in
  the bench report and the trace. The sampler (`fc:prof`) also backs the hang watchdog's stacks.

Keep the UI immediate-mode. Make each pass cheaper instead of caching results across frames:
- Declare only what can be seen. `ui.list_window` turns a uniform list into a spacer plus the visible
  rows. `ui.offscreen(box)` tells you a box was outside its clip last frame, so you can skip its children.
- Sort with decorated keys computed once per element, never map lookups inside a comparator.
- Look up a map entry once, by pointer (`&m[k]`): `m[k]` copies the whole struct.
- Per-pass memory comes from the UI arena or `context.temp_allocator`; nothing is freed one by one.

## Conventions

- `-vet-shadowing -strict-style` must pass.
- Errors are small enums, not strings. No exceptions-style control flow.
- Allocations: explicit allocators on long-lived things; `context.temp_allocator` per frame.
- Secrets (tokens, passwords, raw captures) live only in `.secrets/` and
  `discord_credentials.txt`, both gitignored. Never commit them.

## Releasing

1. Bump nothing by hand: the version comes from the tag.
2. `git tag v0.1.0 && git push origin v0.1.0` (or publish a release with that tag in the GitHub UI).
3. `.github/workflows/release.yml` first runs `check.yml` (debug build + unit tests on macOS and
   Windows, also run on every push to main) on the tagged commit; only if that passes does it create
   the GitHub release for the tag and build `fastcord-macos.zip` (universal `Fastcord.app`,
   ad-hoc signed, not notarized) and attaches it to the release. Windows and Linux are
   not built yet; the site shows them as coming soon.
4. The site and the in-app updater both use the latest release:
   - download link: `https://github.com/creikey/fastcord/releases/latest/download/fastcord-macos.zip`
   - the app checks `api.github.com/repos/creikey/fastcord/releases/latest` at launch and every
     6 hours; when the tag is newer than its own `FASTCORD_VERSION`, an **Update** pill appears
     in the title bar and opens creikey.com/fastcord (right-click it to dismiss). Dev builds never check.

### macOS signing

Without Apple credentials releases are ad-hoc signed and macOS blocks the first
launch (users click **Open Anyway** in System Settings → Privacy & Security).
To ship notarized builds, join the Apple Developer Program and add these repo
secrets (Settings → Secrets and variables → Actions); the release workflow then
signs, notarizes and staples automatically (`scripts/notarize_macos.sh`):

| Secret | Value |
|---|---|
| `MACOS_CERT_P12_BASE64` | your "Developer ID Application" certificate + key exported as .p12, base64 |
| `MACOS_CERT_PASSWORD` | the .p12 export password |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: Cameron Reikes (TEAMID)` |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | App Store Connect API key id and issuer id |
| `ASC_KEY_P8_BASE64` | the downloaded AuthKey_XXXX.p8, base64 |

Local package: `scripts/package_macos.sh v0.1.0` → `dist/fastcord-macos.zip`.

## Website

`site/` is the page served at creikey.com/fastcord. `.github/workflows/pages.yml` deploys it on
pushes to `main` that touch `site/`. One-time setup: repo Settings → Pages → Source: **GitHub Actions**.
Because creikey.com is the custom domain of the creikey.github.io user site, this project's
Pages site is served at creikey.com/fastcord automatically.
