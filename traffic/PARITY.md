# Traffic parity: fastcord vs the official client

`src/discord/parity/run.sh <scenario>...` performs `tests/scenarios/<scenario>.scn`
with `fc:discord` against the live server as the test accounts, records our
traffic in the raw capture format, scrubs it with `tools/scrub` and diffs it
with `tools/trafficdiff traffic/<scenario>.jsonl .secrets/ours/<scenario>.jsonl`.
The runner reads each account's start route (the channel the official instance
reopened on) from the fixture, mirrors the driver's pacing (`click`, `type`,
`wait_for`, `settle` = network quiet) and marks every step on A's stream like
`tools/capture`. Two-sided scenarios were run in the order
`_reset_friendship`, `friend_request_send`, `friend_request_accept`, `send_dm`,
`friend_remove`, with 20 s between scenarios.

## Status (last run, 2026-10-26)

`all` = every difference trafficdiff reports. `core` = after
`-ignore:/science -ignore:/assets/ -ignore:collectibles-shop -ignore:latency.discord.media -ignore:/cdn-cgi/`
(telemetry, UI assets, Cloudflare challenge, RTC latency probe — see below).

| scenario | all | core | remaining core differences |
|---|---:|---:|---|
| send_message | 34 | 6 | etag values (server), op 41 init timestamp, heartbeat timing, settings-proto/2 PATCH |
| cold_start | 16 | 8 | etag values, applications/public id list (server quests), op 41 init timestamp |
| typing | 29 | 8 | etag values, config_0 (cache-dependent), op 41, first-heartbeat timing |
| delete_message | 30 | 7 | etag values, op 41, timing within ±2.5 s |
| remove_reaction | 19 | 9 | etag values, op 41, server 429s from repeated runs |
| add_reaction | 26 | 10 | etag values, op 41, settings-proto/2 timing, server 429s |
| switch_theme | 46 | 9 | settings-proto/2 timing, first-heartbeat timing |
| join_voice_channel | 51 | 13 | voice connection (UDP/RTC) not made; `preferred_region(s)` in op 4 come from the latency probe |
| upload_image | 44 | 13 | GCS PUT body is `$omitted` in DevTools vs our sha; h2 vs h3 for storage.googleapis.com (alt-svc history); media.discordapp.net preview fetch is the app's |
| edit_message | 36 | 14 | timing of the edit (driver typing speed), server 429s |
| open_dm | 48 | 16 | DM header profile requests timing; settings-proto/2 PATCH |
| reply | 37 | 19 | run hit 429 on the setup send (re-run: setup message lands in setup) |
| open_full_profile | 44 | 27 | profile-modal follow-ups that depend on profile widget data (applications/public, games, oauth2/tokens) |
| open_profile_popout | 38 | 29 | run hit 429 on the setup send (shifts the setup message into the popout window) |
| open_guild_and_channel | 64 | 31 | home-route startup timing (official instance was warm), applications/public ids |
| friend_request_send | 78 | 30 | account-B-specific startup set (see below) |
| friend_request_accept | 83 | 32 | account-B-specific startup set |
| send_dm | 83 | 52 | account-B-specific startup set; B's affinities/content-inventory |
| friend_remove | 90 | 65 | A's start route was a deleted DM (`<new:3>`, unknown to us → home route); account-B set |
| create_guild | — | — | not runnable: guild creation not implemented |
| start_group_dm | — | — | not runnable: group-DM recipient add not implemented |

## Implemented from the fixtures

- Startup schedule keyed by start route (home / private / guild) and anchored on
  the reload (`STARTUP_REQUESTS` in `src/discord/startup.odin`): lurker check
  `PUT /guilds/{g}/members/@me?lurker=true` with `x-context-properties: {}` on a
  guild route, home-only referrals/changelog/applications, settings-proto/2
  (guild route), detectables + exclusions as `fetch(cache:'no-cache')` with a
  remembered `If-None-Match`, `cache-control: max-age=0`, CORS preflight and no
  cookies; gateway open at +190 ms and fast-connect IDENTIFY +300 ms after open.
- READY on a guild route: op 4, op 37 (full form: `members: []`,
  `member_updates: false`, `channels: {}`, `thread_member_lists: []`), op 41, op 40;
  first page `limit=10` (720 px), op 43 + guild-open set when it arrives, an
  older page of 20 when the first was full, integrations ~470 ms later. Private
  route: op 13 call connect. Interactive guild select: short op 37 then op 43.
- Channel open follow-ups: DM recipient profiles (`with_mutual_*` variants,
  `type=sidebar`), notes, ack after 3 s when unread.
- UI surfaces: message context menu (application-command-index), emoji picker
  (top-emojis, billing/subscriptions, own profile), profile popout
  (application-identities, featured widgets, referral eligibility, note), full
  profile modal (outbox, collectibles, statistics, suggested games), settings
  modal (build_overrides, payment-sources, location-info, sessions, safety hub,
  custom themes), voice join (text-in-voice page, activity shelf, soundboard
  default sounds + op 31).
- Reaction locations (`Message Reaction Picker`, `Message Context Menu`,
  `Message Inline Button`), reply `allowed_mentions`, attachment
  `original_content_type`, theme deltas (`agQIAhoA` = Light; the UI's Dark is
  proto DARKER = 3), op 4 `self_mute` from config (false in the fixtures).
- Chrome HTTP cache for unauthenticated GETs (status page, changelog,
  bad-domains): fresh entries served locally, stale ones revalidated with the
  stored validators appended after the request headers; cross-origin XHR sends no
  cookies.
- Recorder: DevTools-style renderer header list (cache validators are not
  renderer-visible), ExtraInfo `wire` sorted by name as DevTools reports it.

## Remaining differences and why

| Area | Difference | Reason |
|---|---|---|
| Telemetry | Fewer `/science` batches; no `libdiscore_loaded`, `app_native_crash`, `client_heartbeat`, `ready_payload_received`, `app_web_perf_startup_metrics`, `app_ui_viewed`, `dm_list_viewed`, `friends_list_viewed`, `dismissible_content_*`, `app_notice_viewed` | Values not measurable truthfully in this client (Electron/JS-heap metrics, web bundle timings) or UI-owned (the app can emit them via `analytics_track`). |
| ETag values | `If-None-Match` values differ for detectables | Server content changed since the capture; and Chrome's cache keeps the weak `W/` tag of the compressed 200 while our first 200 carried a strong tag. |
| op 41 | `initialization_timestamp` differs | The persisted analytics heartbeat session of the official install vs ours (a per-install value, not scrubbed). |
| op 40 | Extra/missing heartbeat inside a window | First heartbeat is at `random() * interval` in both clients. |
| Account B | B's startup has no billing calls / ads decision, adds affinities and later quests/eligibility | Server/account-state dependent (B is an unverified account); we use one table for both accounts. |
| config_0.json `x=` | Present in some guild-route fixtures, absent in others | Changelog cache-busting/state in the official client's localStorage. |
| settings-proto/2 PATCH | Not sent | Frecency (emoji/gif usage) migration writes we do not model. |
| applications/public | Different id list / count | Built from `/quests/@me`, which the server changes over time. |
| latency.discord.media/rtc | Not sent | RTC region latency probe (h2, timing varies 2–27 s); voice region selection is `src/voice`'s job. |
| cdn-cgi challenge | Not sent | Cloudflare JS challenge run by the web page. |
| `/assets/`, collectibles images | Not fetched | UI assets; the app loads what it renders via `fetch_media`. |
| HTTP/3 0-RTT | Disabled (`Transport.h3_no_0rtt`) | Resuming a QUIC session with 0-RTT fails in `fc:quic` (second connection in a process), which then marks h3 broken and falls back to h2; Chrome uses 0-RTT. Reported to the QUIC owner. |
| Server 429s | Some status codes differ | Repeated test runs hit rate limits (application-command-index, guild entitlements). |
| conn / reused | `0` / `false` | Chrome connection ids are internal to Chrome. |
| Timing | Several requests ±1.5–3.5 s | The official driver's UI waits (DOM polling, mouse moves) are approximated. |
