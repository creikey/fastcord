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
./build.sh debug      # build/fastcord-debug
./build/fastcord      # logs in with $FASTCORD_TOKEN or ~/Library/Application Support/fastcord/state/token
```

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

`FASTCORD_STATS=1` prints the frame rate and what is animating (idle should be ~0 fps).
Run `python3 -I tools/check_secrets.py` before committing.

All code imports siblings through the `fc` collection: `import "fc:netio"`.

## Conventions

- `-vet-shadowing -strict-style` must pass.
- Errors are small enums, not strings. No exceptions-style control flow.
- Allocations: explicit allocators on long-lived things; `context.temp_allocator` per frame.
- Secrets (tokens, passwords, raw captures) live only in `.secrets/` and
  `discord_credentials.txt`, both gitignored. Never commit them.

## Releasing

1. Bump nothing by hand: the version comes from the tag.
2. `git tag v0.1.0 && git push origin v0.1.0` (or publish a release with that tag in the GitHub UI).
3. `.github/workflows/release.yml` creates the GitHub release for the tag and builds `fastcord-macos.zip` (universal `Fastcord.app`,
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
