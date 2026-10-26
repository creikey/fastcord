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
