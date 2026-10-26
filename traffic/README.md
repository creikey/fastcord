# Traffic fixtures

Each `<scenario>.jsonl` is the scrubbed network traffic of the **official**
desktop client performing one scenario (see `tests/scenarios/*.scn`). Our client
runs the same scenario and `tools/trafficdiff` checks the traffic matches.
They also drive offline tests: a replay server answers our library with the
recorded responses.

## Pipeline

```sh
./build.sh tool capture && ./build.sh tool scrub && ./build.sh tool trafficdiff
build/capture supervise 60 &                      # launches + memory-polices the test instances
build/capture run tests/scenarios/send_message.scn   # -> .secrets/raw/send_message.jsonl (secret!)
build/scrub .secrets/raw/send_message.jsonl traffic/send_message.jsonl   # scrubs + verifies
build/trafficdiff traffic/send_message.jsonl ours.jsonl
```

`scrub` refuses to write a fixture if any secret found in the raw capture
(auth token, identify token, cookie values, emails, phones, fingerprint,
installation id, analytics/session tokens, any token-shaped string) still
appears in the output; `scrub verify <raw> <fixture>` re-checks a file.

## Format

One JSON object per line, sorted by `t` = milliseconds since the recording
started. `acct` is present only for account B (`"b"`); absent means A.

| `k` | Fields |
|---|---|
| `mark` | `name` — scenario step boundary (e.g. `"send_message"`; `"setup"` = prelude) |
| `req` | `id`, `proto` (`h2`/`h3`/`http/1.1`, from the response), `method`, `url`, `conn` (Chrome connection id), `reused` (connection reuse), `headers`, `wire` (optional), `body` |
| `resp` | `id`, `status`, `headers`, `body` |
| `ws_open` | `id`, `url`, `headers` |
| `ws_send` / `ws_recv` | `id`, `op`, `ev` (dispatch name), `seq`, `d` (decoded ETF → JSON; zstd-stream inflated) |
| `ws_close` | `id`, `code` (CDP does not report it: `null`) |

Headers are ordered `[[name, value], ...]`:

- `headers` is Chrome's request header list in Chrome's own order (as the
  renderer/fetch layer built it), always present.
- `wire` is what the network stack actually sent (pseudo-headers, `cookie`,
  `accept-encoding`, ...) when DevTools reports it. **DevTools sorts these by
  name**, so it tells you the set and values, not the order. The true wire
  order for h2/h3 is only in a Chrome netlog (`--log-net-log`).

Bodies are JSON when the content is JSON, else `{"$b64": "...", "len": n}`
(≤ 4 KiB; text is scrubbed first), else `{"$sha256": "...", "len": n}`. JSON bodies over 256 KiB (static catalogs such as game detectables) are also reduced to a hash.
`{"$omitted": true}` means the request had a body DevTools did not expose.

Included requests: network traffic a native client could also produce —
XHR/fetch/beacons/preflights, CDN images (avatars, attachments), WebSocket.
Excluded: the web-app bundle (`/assets/*`, scripts, styles, fonts, the HTML
document), cache hits, and browser-internal schemes (`blob:`, `sentry-ipc:`).

## Scrubbing

Secrets and per-run randomness are replaced by stable placeholders (numbered
per fixture in order of first appearance) so runs diff cleanly and nothing
sensitive is committed. `trafficdiff` compares placeholders by kind only.

- `authorization`, identify `token`, any token-shaped string → `<token>`
- `cookie`, `set-cookie` → `<cookie>`
- `x-super-properties`, `x-context-properties` → `{"$b64json": {...decoded, scrubbed}}`
- `client_launch_id`, `launch_signature`, `client_heartbeat_session_id`,
  `analytics_token`, `qos_token`, `installation_id`, `x-fingerprint`, ... → `<id:<key>:N>`
- other UUIDs → `<uuid:N>`; `nonce` → `<nonce:N>`; session ids → `<sid:N>`
- snowflakes created during the run (messages, channels, attachments) → `<new:N>`
- emails / phones / IPs / country codes → `<email>` / `<phone>` / `<ip>` / `<geo>`
- people who are not test accounts: id → `<user:N>`, names → `<user:N>`,
  avatars/bios dropped; their message `content` → `<content>`, attachments/embeds `[]`

Snowflakes of the two test accounts and their private test guild/channels
(`tests/scenarios/env`) are kept: they are public identifiers of throwaway
accounts, and keeping them makes fixtures readable.
