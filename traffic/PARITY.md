# Traffic parity: fastcord vs the official client

The official client's traffic for each scenario is recorded in
`traffic/<scenario>.jsonl` (Discord desktop 0.0.419 / Chrome 148, scrubbed;
31 of 33 carry netlog wire header order and `conn` facts). Two separate ways
compare fastcord with them.

## 1. Offline parity tests (day to day, no network)

`src/discord/replay_test.odin` runs the library against a fixture with no
network:

- HTTP is answered from the recorded responses (`Config.round_tripper`). Each
  request is matched to the earliest unused recorded exchange with the same
  method and URL shape (ids folded, query values dropped).
- Gateway frames go to a sink instead of a socket (`Config.gateway_sink`).
  The fixture's READY and the action window's dispatches (`MESSAGE_CREATE`,
  `GUILD_CREATE`...) are injected with `client_inject_dispatch`.
- Scrubbed placeholders (`<new:2>`, `<user:3>`) become stable fake snowflakes,
  so the client can reuse ids across responses and dispatches.
- Each `parity_<feature>` test sets the start route, performs one action, and
  checks only that action's mark window. It compares:
  - the request set;
  - the true wire header order (netlog), with cookies and cache validators left out;
  - the body shape;
  - the gateway ops with their payload shapes (heartbeats left out).
- Gaps that are known and documented are passed per test as an allow-list.

Run all of them (they run with the rest of the discord tests, about 4 s):

    ./build.sh test discord

Run one:

    odin test src/discord -collection:fc=src -out:build/test-discord -define:ODIN_TEST_NAMES=discord.parity_send_message

There are 20 tests covering these windows:

- messages: send_message, typing, reply, edit_message, delete_message
- reactions: add_reaction, remove_reaction, emoji_picker_reaction, add_custom_reaction
- profiles: open_profile_popout, open_full_profile
- status and settings: open_status_menu, set_idle, set_custom_status, theme_light
- other: open_gif_picker, join_voice, close_dm, create_guild_submit, start_group_dm

All pass. A test that fails prints what differs from the official client
(missing / extra request, wire order, body or gateway payload shape).

`tests/run_all.sh` and CI only run these offline tests. `run_all.sh` unsets
`FASTCORD_LIVE`, so no live test runs even if the caller's environment sets it.
Nothing in `run_all.sh`, `tests/ui/run.sh` or CI calls the live session runner.

When a feature changes, update its offline test. A new feature needs a fixture
window (capture tooling) and a `parity_<feature>` test.

## 2. Live session (rare, manual)

`src/discord/parity/session.sh [scenario...]` is the only live runner, and
nothing invokes it automatically. It behaves like one person using the app:

- A launches once (that start is the `cold_start` measurement). B launches the
  first time a two-sided scenario needs it.
- The scenarios then run in turn at the capture driver's human pace: mouse
  travel, typing speed, network-quiet settles, a few seconds of reading between
  steps. There is no relaunch per scenario and no padding between scenarios.
- Each scenario is recorded separately (`.secrets/raw/ours_<s>.jsonl` plus a
  Chrome-format netlog per account).
- Each recording is scrubbed and compared with `tools/trafficdiff -actions`:
  only the action windows, because the fixtures' preludes and launches are the
  official run's own. `cold_start` is compared whole, with its connection facts
  (QUIC transport parameters, h3/h2 SETTINGS, ALPN).

When a live run is warranted:

- before a release;
- when the official client version changes;
- when the fixtures are re-captured;
- for one targeted scenario of the feature being changed: `session.sh send_message`.

Don't run full sweeps in the normal loop.

Rate limits: the earlier per-scenario fresh-launch runner made 33 cold logins
and startup bursts an hour, and the session runner replaces it. The last full
session (32 scenarios, about 35 minutes) got no 429s. Retries honour
`Retry-After` and the per-URL hold. A 429 in a session is a bug in our traffic,
not something to wait out.

### Last full session (2026-10-26)

- `all` counts every trafficdiff difference in the action windows (cold_start
  whole).
- `core` is the same with `/science`, `/assets/`, collectibles-shop images,
  `latency.discord.media` and `/cdn-cgi/` left out.

| scenario | all | core | remaining core differences |
|---|---:|---:|---|
| cold_start | 34 | 9 | detectables ETag values (server), status page 200 vs 304, config_0 cache bucket, op 41 init timestamp, ads-decision timing, first-connection `initial_round_trip_time` |
| send_message | 1 | 1 | settings-proto/2 frecency PATCH |
| typing | 1 | 1 | first-heartbeat op 40 timing |
| add_reaction | 13 | 1 | session state: command index / emoji picker already loaded earlier in the session |
| remove_reaction | 2 | 1 | heartbeat timing |
| delete_message | 6 | 2 | session state (command index loaded) |
| edit_message | 7 | 3 | session state, settings-proto/2 |
| reply | 7 | 3 | session state, settings-proto/2 |
| upload_image | 13 | 9 | GCS `upload_id` (fixture predates the scrub fix), DevTools `$omitted` PUT body, upload timing |
| open_profile_popout | 4 | 1 | session state |
| open_full_profile | 17 | 11 | profile-widget follow-ups (applications/public, games, oauth2/tokens) not modelled |
| emoji_picker_reaction | 15 | 3 | picker data already loaded in the session |
| add_custom_reaction | 20 | 6 | picker data already loaded |
| gif_send | 5 | 0 | |
| open_image_attachment | 5 | 3 | media viewer image timing |
| scroll_history | 0 | 0 | |
| quick_switcher_nav | 46 | 39 | autocomplete throttling, Chrome HTTP-cache revalidation (`if-modified-since`) of autocomplete GETs, `/games?game_ids` lookups |
| switch_theme | 11 | 0 | |
| join_voice_channel | 13 | 2 | `preferred_regions`, voice RTC not connected |
| status_change | 6 | 0 | |
| custom_status | 19 | 8 | popout already loaded in the session, expiry timestamp value, heartbeat |
| open_guild_and_channel | 10 | 9 | session state: guild-open set already sent (a launch-time effect in the fixture) |
| open_dm | 8 | 3 | DM header profile variants |
| close_dm | 31 | 23 | quick-switcher autocomplete (as above), DM profile variants |
| start_group_dm | 11 | 4 | the official run sent no recipient PUT; session state |
| create_guild | 29 | 20 | Referer (route), op 37/43 order (fixed since, offline test passes) |
| mark_as_read | 15 | 10 | session state, heartbeats |
| voice_with_b | 32 | 8 | RTC not connected (`rtc_connected` QoS), op 31 order |
| friend_request_send | 4 | 2 | |
| friend_request_accept | 8 | 7 | B's account-state startup items |
| send_dm | 3 | 2 | |
| friend_remove | 8 | 5 | |

"Session state" differences are expected. Each official fixture was recorded
right after its own launch, so session-once loads (command indexes, emoji
picker data, account popout, guild-open sets) fall into its action window. In
one long session they already happened earlier, as they would for a real user.

## Implemented from the fixtures (this round)

### Startup timing

- The startup burst is READY-anchored: READY + about 2.06 s, plus 0.23 s on the
  home route. The burst covers detectables preflights, billing, library,
  exclusions, saved messages, storefront and config_0. The evidence is 33
  fixtures (2057–2109 ms and 2295–2329 ms after READY), against 2.7–4.4 s after
  the gateway open.
- settings-proto/2 is loaded at READY + 5.13 s.
- The 16 workers send the 13-request burst concurrently.
- Detectables preflights go first, and their GETs follow at their place in the
  burst.
- `config_0.json?x=` is the 5-minute bucket within the hour.

### IDENTIFY and presence

- The first IDENTIFY of a launch without native fast connect has
  `gateway_connect_reasons: "AppSkeleton"` and presence `"unknown"`.
- The live runner follows each fixture's fast-connect mode.
- Status and custom status send op 3 with the settings write.
- The StatusSettings proto is captured byte-exact (current status plus its
  stored created time, the custom status with its own created time; a clear
  omits custom_status).

### Request rules

- `applications/public` lists only the applications of quests with a console
  task, in first-appearance order.
- `fetch_user_offer_started` is tracked when the request starts, and analytics
  batches flush after 30 ms.
- Account popout: profile (`type=account_popout`), application identities and
  featured widgets. When those arrive it loads statistics, the featured
  applications and `/users/@me` (DevTools shows lowercase `authorization`).
- Quick switcher: autocomplete throttled to 500 ms, plus a `/games` lookup for
  icon-less shown results.
- Members (op 8, presences false) are requested for unknown authors and
  mentions of fetched guild pages.
- No acks while the window is unfocused.
- Sidebar channel opens prefetch with the previous route as Referer, and op 37
  follows.
- A new guild sends op 43 and its guild-open set at once. Integrations are only
  fetched for a new guild.

### Voice

- The RTC region probe runs once per launch, 8–25 s after start. Its region
  order is persisted and sent as `preferred_region(s)` in op 4.
- Leaving voice keeps `self_mute: false`.

### Settings default

- An absent or UNSET theme is the official UI "Dark", which is proto DARKER (3).
  The evidence is the bundle's `{[UNSET]: DARK, [DARK]: ASH, [DARKER]: DARK}`.

### Transport

- QUIC RTTs persist next to altsvc.txt (`rtt <host> <us>`), so a new process
  sends `initial_round_trip_time` on its first connection, as Chrome does.

### Recorder

- Sub-millisecond, dispatch-time request starts.
- A Chrome-format netlog per account, so our recordings carry true wire order
  and `conn` facts.

## Remaining differences and why

| Area | Difference | Reason |
|---|---|---|
| Telemetry | Fewer `/science` events | Values not measurable truthfully here, or UI-owned (`analytics_track`). |
| ETag values | detectables `If-None-Match` differ | Server content changed since the capture. |
| op 41 | `initialization_timestamp` | Per-install value. |
| op 40 | Heartbeats in windows | First heartbeat at `random() * interval` in both clients. |
| settings-proto/2 PATCH | Not sent | Frecency (emoji/gif usage) writes are not modelled. |
| Profile widgets | applications/public, games, oauth2/tokens after a full profile | Driven by profile widget data, not modelled. |
| Quick switcher | Exact autocomplete query set, HTTP-cache revalidation | Throttle model approximated. Chrome revalidates cached autocomplete GETs. |
| Voice | `rtc_connected` QoS, voice UDP | RTC/voice connection is `src/voice`'s job. |
| GCS upload | `upload_id` in the fixture | tools/scrub now scrubs it. The committed fixture predates that and needs a re-scrub. |
| conn ids | `0` / `false` | Chrome-internal. |
