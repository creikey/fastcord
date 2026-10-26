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

## Build

```sh
./build.sh            # build/fastcord
./build.sh test tls   # odin test src/tls
./build.sh tool capture
```

All code imports siblings through the `fc` collection: `import "fc:netio"`.

## Conventions

- `-vet-shadowing -strict-style` must pass.
- Errors are small enums, not strings. No exceptions-style control flow.
- Allocations: explicit allocators on long-lived things; `context.temp_allocator` per frame.
- Secrets (tokens, passwords, raw captures) live only in `.secrets/` and
  `discord_credentials.txt`, both gitignored. Never commit them.
