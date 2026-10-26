# Traffic fixtures

Each `<scenario>.jsonl` is the scrubbed network traffic of the **official**
desktop client performing one scenario (see `tests/scenarios/`). Our client
runs the same scenario and `tools/trafficdiff` checks the traffic matches.
They also drive offline tests: a replay server answers our library with the
recorded responses.

## Format

One JSON object per line, `t` = milliseconds since scenario start.

| `k` | Fields |
|---|---|
| `mark` | `name` — scenario step boundary (e.g. `"send_message"`) |
| `req` | `id`, `proto` (`h2`/`h3`/`http/1.1`), `method`, `url`, `headers` (ordered `[[name, value], ...]`), `body` |
| `resp` | `id`, `status`, `headers`, `body` |
| `ws_open` | `id`, `url`, `headers` |
| `ws_send` / `ws_recv` | `id`, `op`, `ev` (dispatch name), `seq`, `d` (decoded ETF → JSON) |
| `ws_close` | `id`, `code` |

Bodies are JSON when the content is JSON, else `{"$b64": "...", "len": n}`
(large binary bodies are truncated to a hash: `{"$sha256": "...", "len": n}`).

## Scrubbing

Secrets and per-run randomness are replaced by stable placeholders so runs
diff cleanly and nothing sensitive is committed:

- `authorization`, `cookie`, `set-cookie`, identify `token` → `<token>` / `<cookie>`
- `x-super-properties` → decoded JSON with `client_launch_id`, `launch_signature`,
  `client_heartbeat_session_id`, `client_app_state` etc. → `<uuid:N>`
- `x-installation-id`, `x-fingerprint`, analytics tokens → `<id:name>`
- nonces, session ids, message ids created during the run → `<nonce:N>`, `<sid:N>`, `<new:N>`
- user emails/phones → `<email>` / `<phone>`

Snowflakes of the two test accounts and their test guild are kept: they are
public identifiers, and keeping them makes fixtures readable.
