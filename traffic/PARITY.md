# Traffic parity: fastcord vs the official client

How to check: `src/discord/parity/run.sh <scenario>...` performs
`tests/scenarios/<scenario>.scn` with `fc:discord` against the live server as
the test accounts (A, and B where the scenario uses it), records our traffic in
the raw capture format (`.secrets/raw/ours_<scenario>.jsonl`), scrubs it with
`tools/scrub` into `.secrets/ours/<scenario>.jsonl`, and runs
`tools/trafficdiff traffic/<scenario>.jsonl .secrets/ours/<scenario>.jsonl`.

Status: harness in place; official fixtures (`traffic/*.jsonl`) have not
landed yet, so no scenario has been diffed. Differences known in advance are
listed below and will be extended per scenario once fixtures exist.

## Known, documented differences

| Area | Difference | Reason |
|---|---|---|
| `req.headers` | Ours is derived from our wire header list (Blink order, JS casing) via `renderer_view` in `src/discord/recorder.odin`; the official one is DevTools' renderer list. | We have no renderer; the wire order itself is verified against netlog captures. |
| `conn` / `reused` | Always `0` / `false` in ours. | Chrome connection ids are internal to Chrome. |
| Telemetry (`/science`) | We do not send `client_heartbeat`, `app_native_crash`, `libdiscore_loaded`, `ready_payload_received`, `app_web_perf_startup_metrics`, `app_ui_viewed`, `channel_opened`, `guild_viewed`, `notification_permission_status`, `dismissible_content_*`, `friends_list_viewed` (unless the app sends UI events via `analytics_track`). | Their values can't be measured truthfully in a native client (Electron process/heap metrics, web-bundle timings, JS-store-internal sizes, UI surfaces we don't own); see `analytics_unknowable` in `src/discord/analytics.odin`. |
| Telemetry values | `client_performance_memory`/`_cpu`, `uptime_process_renderer` are this process's real values. | They describe the running client. |
| Assets | No `discord.com/assets/*` (bundle, fonts, svgs). | Excluded from fixtures as well. |
| Detectables | No `cdn.discordapp.com/detectables/*` preflight + GET, no `network_action_detectable_*` events. | Game detection is not implemented. |
| `create_guild`, `start_group_dm`, `open_full_profile`, `soak` | Not runnable by `parity` yet. | Guild creation / group-DM recipient add / full-profile requests not implemented. |
| Voice | `join_voice_channel` sends op 4 and receives VOICE_SERVER_UPDATE but makes no voice-server connection. | Voice transport lives in `src/voice`. |
| Timing | Setup reload of ours is a fresh process start; the official one is a renderer reload with the HTTP/QUIC sessions possibly warm. | Different process model. |
