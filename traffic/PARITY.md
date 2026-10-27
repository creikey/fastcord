# Traffic parity: fastcord vs the official client

The official client's traffic for each scenario is recorded in
`traffic/<scenario>.jsonl` (Discord desktop 0.0.419 / Chrome 148, scrubbed;
31 of 33 carry netlog wire header order and `conn` facts). Two separate ways
compare fastcord with them.

## 1. Offline parity tests (day to day, no network)

`src/discord/replay_test.jai` runs the library against a fixture with no
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
  - the gateway ops with their payload shapes (heartbeats left out);
  - the telemetry (`/science` batches), see below.
- After the mark, each HTTP response is held for its recorded latency (capped at
  1 s), so response-time events land as far apart as they did officially.
- Gaps that are known and documented are passed per test as an allow-list.

Run all of them (about 4 s):

    jai build.jai - test

Run one (names are substrings):

    jai build.jai - test parity_send_message

The tests cover these windows:

- messages: send_message, typing, reply, edit_message, delete_message
- reactions: add_reaction, remove_reaction, emoji_picker_reaction, add_custom_reaction; prediction
  and rollback without a fixture (`reaction_prediction`); Mark Unread and pin/unpin requests from
  the bundle, no capture yet (`mark_unread_and_pins`, rules in CLIENT_RULES.md)
- profiles: open_profile_popout, open_full_profile
- status and settings: open_status_menu, set_idle, set_custom_status, theme_light
- inbox: open_inbox, inbox_unreads_tab, inbox_mentions_tab, inbox_unreads_mark_read,
  inbox_remove_mention, inbox_jump_to_mention
- threads browser (one test, every window): open_threads_popout_empty, create_thread_open,
  create_thread_name, create_thread_submit, close_thread_view, open_threads_popout,
  open_thread_from_popout, delete_thread_menu, delete_thread, delete_thread_confirm
- back/forward: history_back_key, history_forward_key, history_back_button, history_forward_button
- discover (documents the gap): open_discover, leave_discover
- other: open_gif_picker, join_voice, close_dm, create_guild_submit, start_group_dm
- server notifications (also compare `/science`: event types in order and their
  property names in order, per-event decorations left out; `Replay_Run.science`):
  open_guild_menu, guild_mark_read, guild_mute_15m, guild_unmute,
  guild_notify_mentions, guild_notify_all, channel_mute_15m, channel_unmute,
  channel_notify_mentions, channel_notify_default
- invites and servers: invite_from_menu, invite_from_header_icon, invite_from_channel_icon,
  copy_invite, b_leave_confirm, b_join_submit (two-sided fixture: `replay_begin(..., acct = "b")`
  runs account B's side)
- other: open_gif_picker, join_voice, close_dm, create_guild_submit, start_group_dm, upload_emoji
- telemetry only (their request differences are session state, table below):
  open_guild, open_unread_channel, open_dm, set_online, close_profile_popout
  (Escape), switch_to_dm (quick switcher keybind), friend_request_send
  (friends tab)

All pass. A test that fails prints what differs from the official client
- other: open_gif_picker, join_voice, close_dm, create_guild_submit, start_group_dm, upload_emoji
- guild events (`parity_guild_events`, one session, every window): open_events_empty,
  create_event_open, create_event_location, create_event_info, create_event_submit,
  open_events_one, event_uninterested, event_interested, event_open_context_menu,
  event_cancel, event_cancel_confirm
- channels: open_create_channel + create_channel_submit (`parity_create_channel`),
  channel_settings_open + channel_topic_type + channel_settings_save
  (`parity_channel_settings`), channel_delete_open + channel_delete_confirm
  (`parity_channel_delete`)

All pass. A test can compare several windows of one session (`replay_compare`
per window, `replay_end` once). Feature-pool results are applied with
`guild_admin_apply`, as the app does, so result-driven follow-ups are checked too.
The feature pool and the side tables are shared by every live client (tests run
in parallel): they use the heap allocator and are torn down with the last client. A test that fails prints what differs from the official client
- user settings (`parity_settings_*`): open_settings (Account pane), open_profiles
  (Edit Profiles), profile_save, display_name_save, open_notifications_settings,
  open_appearance, appearance_sync_on / _off, notifications_toggle_off / _on
- `parity_streamer_mode`: streamer_mode_on (no network), streamer_view_account
  (Account replaced: no fetches), open_settings_appearance
- `parity_friend_nickname`, `parity_server_nickname`: friend_nickname_open
  (user menu prefetch), friend_nickname_save / _reset, server_nickname_open /
  _save / _remove_save
- `parity_friend_add_context_menu`: friend_request_from_dm_menu, and B's
  friend_request_accept
- `parity_dm_call`: start_call (ring after CALL_CREATE), B's b_join_from_ring,
  a_hang_up
- `parity_logout`, `parity_login_submit` (account_edits; the fixture has no READY
  before them, so the login window's READY of the same account stands in):
  logout (POST /auth/logout, the logged-out loads, fingerprint, login page),
  login_submit (POST /auth/login, IDENTIFY, the login burst). The QR socket is
  off offline; its protocol is unit-tested (`test_remote_auth_fake_server`).

`replay_begin(..., acct = "b")` replays a two-sided fixture as B (B's READY and
windows). All pass. A test that fails prints what differs from the official client
(missing / extra request, wire order, body or gateway payload shape).

`jai build.jai - check` runs only these offline tests; nothing in it calls the
live session runner.

When a feature changes, update its offline test. A new feature needs a fixture
window (capture tooling) and a `parity_<feature>` test.

### Telemetry (`/science`)

Per window, `r_science_check` compares our batches with the official ones:

- the sequence of event `type`s (aligned, so a missing or extra event is named);
- each event's property keys and their order, the decorations included;
- every value's JSON type, and the value of constant-valued properties:
  strings that are not ids / uuids / timestamps / queries (locations, enums,
  names), booleans, nulls, and numeric enums (`channel_type`,
  `relationship_type`, `status_code`...). Counts, durations and ids differ by nature;
- batching: events the official client queued in one step (same batch, within
  3 ms) must share a batch in ours; events it sent in batches more than 100 ms
  apart must not; our flush delay (send - first queued event) must stay within
  the window's official maximum (+50 ms);
- the header order of every science POST (no `x-science-test` after a launch's
  first batch).

Allow-list entries for telemetry:

- `science:<type>`: an event we do not send (or send extra);
- `science:<type>.<key>`: one property's type or value;
- `science:<type>/<key>=<constant>`: the events of that type with that value
  (e.g. one `profile_action`);
- `science:batching`.

`R_SCI_NEVER` (applied by `replay_check` to every window) lists events fastcord
never sends: NUX / upsell / quest events, experiment exposures and the official
media engine's voice events (`voice_connection_*`, `start_speaking`,
`leave_voice_channel`...); they and the other unsendable events are in
`analytics_unknowable` (analytics.jai) with the reason. `send_message_roundtrip`
is sampled at 10 % and disabled offline.

Every event needs the window's viewport and the accessibility flags: the
library drops events until both are reported. The app reports them right after
creating the client and then every frame (`src/app/analytics_env.jai`);
`app.test_analytics_env_lets_events_through` guards that (the replay tests set
them themselves).

The tracker's per-event throttles are the library's (`SCI_THROTTLES` in
analytics.jai, from the bundle's `throttlePeriod` table): `channel_opened` per
channel and view for 15 min, `guild_viewed` per guild, `friends_list_viewed` per
tab, `keyboard_shortcut_used` per shortcut for 2 min, `ack_messages`... So
returning to a channel opened earlier sends nothing, as officially; a test that
starts on a channel has already sent its `channel_opened` (the launch route's
`channel_opened` / `guild_viewed` / Friends views go out on READY).

Reporting a UI event (`src/discord/analytics_events.jai`): one typed helper
per event, which builds the event's own properties in the fixture's key order
and hands them to `analytics_track` (the decorations are added there):

```jai
analytics_<event> :: (c: *Client, ...) {
	w := aw_begin();
	json_kstr(*w, "location", ...);   // the event's own keys, in fixture order
	aw_guild(*w, c, guild_id);        // shared groups: guild / channel decorations
	aw_channel(*w, c, channel_id);
	aw_track(c, "<event>", *w);
}
```

- Call it from the library action the official client tracks it in (e.g.
  `set_status` -> `user_status_updated`), from a response (`Job.on_done`, worker
  thread: `analytics_track` is locked), or from the app where the UI event
  happens (`dc.message_menu_opened`, `dc.expression_picker_opened`...).
- Every value must be measured by fastcord (store state, our own timings, ids we
  generated). If one cannot be, the event is not sent: add it to
  `analytics_unknowable` with the reason instead.
- Add the event to the feature's offline test (the window's official events are
  then compared automatically), mirroring the app's calls in the test.

Events sent now, by scenario:

| scenario / window | events |
|---|---|
| message context menu (reply, edit, delete, reactions) | message_popout_menu_opened_desktop, application_command_cache_fetch ×2, application_command_performance (per index response), message_menu_time_to_close / _to_select |
| reaction / emoji picker | reaction_picker_opened, open_popout, search_opened, expression_picker_opened, search_started, search_result_viewed (query at rest 300 ms), search_result_selected |
| gif picker | search_opened, expression_picker_opened (width) |
| profiles | user_profile_action (POPOUT, PRESS_VIEW_PROFILE, MODAL_V2, ACCOUNT_POPOUT, SIDEBAR), impression_modal_root_legacy |
| status / custom status / theme | user_status_updated, custom_status_updated, client_theme_updated |
| channel / guild / DM open | channel_opened (guild, DM, group DM, voice, thread; throttled), guild_viewed; the launch route's on READY |
| voice / DM calls | channel_opened, join_voice_channel, permissions_requested (app, mic opened), network_action_embedded_activities_fetch_shelf (calls: guild_id "" / null), ring_call_accepted, call_button_clicked; `client_rtc_state` from the app's voice connection |
| create guild | network_action_guild_create, nuo_transition |
| group DM | open_popout, private_channel_invite_modal_opened, create_dm_user_list_clicked, channel_opened, gdm_edit_interacted |
| DM list right click | impression_dm_list_right_click_menu_shown, application_command_performance |
| user menu (right click a user) | application_command_cache_fetch ×2 (~40 ms after each open), application_command_performance |
| home | dm_list_viewed, friends_list_viewed (route change, READY), friends_list_clicked + friends_list_viewed (tab click) |
| inbox | open_popout, inbox_channel_acked, ack_messages (on the ack's response), notification_action ACK (on MESSAGE_ACK, per desktop notification shown), jump |
| keybinds | keyboard_shortcut_used (Escape, mod+k, back / forward), quickswitcher_opened, app_back_forward_navigated |
| settings | settings_pane_viewed, dismissible_content_shown, ui_setting_interacted, network_action_email_settings_fetch, streamer_mode_toggle, update_streamer_mode_settings, app_notice_* |
| username editor | ui_setting_interacted, network_action_pomelo_attempt, pomelo_errors |

## 2. Live session (rare, manual)

`jai build.jai - parity && build/parity session [scenario...]` is the only live runner, and
nothing invokes it automatically. It behaves like one person using the app:

- A launches once (that start is the `cold_start` measurement). B launches the
  first time a two-sided scenario needs it.
- The scenarios then run in turn at the capture driver's human pace: mouse
  travel, typing speed, network-quiet settles, a few seconds of reading between
  steps. There is no relaunch per scenario and no padding between scenarios.
- Each scenario is recorded separately (`.secrets/raw/ours_<s>.jsonl` plus a
  Chrome-format netlog per account).
- Each recording is scrubbed and compared with `build/trafficdiff -actions`:
  only the action windows, because the fixtures' preludes and launches are the
  official run's own. `cold_start` is compared whole, with its connection facts
  (QUIC transport parameters, h3/h2 SETTINGS, ALPN).

When a live run is warranted:

- before a release;
- when the official client version changes;
- when the fixtures are re-captured;
- for one targeted scenario of the feature being changed: `build/parity session send_message`.

Don't run full sweeps in the normal loop.

Rate limits: the earlier per-scenario fresh-launch runner made 33 cold logins
and startup bursts an hour, and the session runner replaces it. The last full
session (32 scenarios, about 35 minutes) got no 429s. Retries honour
`Retry-After` and the per-URL hold. A 429 in a session is a bug in our traffic,
not something to wait out.

### Last full session (2026-10-27, Jai build)

32 scenarios in 14 minutes, no 429s. Totals: 438 all / 189 core (the last Odin session: 404 / 196).

- `all` counts every trafficdiff difference in the action windows (cold_start
  whole).
- `core` is the same with `/science`, `/assets/`, collectibles-shop images,
  `latency.discord.media` and `/cdn-cgi/` left out.

| scenario | all | core | remaining core differences |
|---|---:|---:|---|
| cold_start | 18 | 8 | detectables ETag values (server), status page 200 vs 304, config_0 cache bucket, op 41 init timestamp, ads-decision timing, first-connection `initial_round_trip_time` |
| send_message | 2 | 1 | settings-proto/2 frecency PATCH |
| typing | 1 | 1 | first-heartbeat op 40 timing |
| add_reaction | 19 | 0 | session state: command index / emoji picker already loaded earlier in the session |
| remove_reaction | 2 | 1 | heartbeat timing |
| delete_message | 8 | 2 | session state (command index loaded) |
| edit_message | 8 | 2 | session state, settings-proto/2 |
| reply | 8 | 2 | session state, settings-proto/2 |
| upload_image | 10 | 6 | GCS `upload_id` (fixture predates the scrub fix), DevTools `$omitted` PUT body, upload timing |
| open_profile_popout | 5 | 0 | session state |
| open_full_profile | 17 | 8 | profile-widget follow-ups (applications/public, games, oauth2/tokens) not modelled |
| emoji_picker_reaction | 15 | 3 | picker data already loaded in the session |
| add_custom_reaction | 25 | 5 | picker data already loaded |
| gif_send | 6 | 1 | |
| open_image_attachment | 4 | 2 | media viewer image timing |
| scroll_history | 1 | 1 | |
| quick_switcher_nav | 57 | 41 | autocomplete throttling, Chrome HTTP-cache revalidation (`if-modified-since`) of autocomplete GETs, `/games?game_ids` lookups |
| switch_theme | 12 | 1 | |
| join_voice_channel | 15 | 2 | `preferred_regions`, voice RTC not connected |
| status_change | 10 | 0 | |
| custom_status | 23 | 9 | popout already loaded in the session, expiry timestamp value, heartbeat |
| open_guild_and_channel | 11 | 10 | session state: guild-open set already sent (a launch-time effect in the fixture) |
| open_dm | 9 | 4 | DM header profile variants |
| close_dm | 32 | 23 | quick-switcher autocomplete (as above), DM profile variants |
| start_group_dm | 16 | 4 | the official run sent no recipient PUT; session state |
| create_guild | 31 | 21 | Referer (route), op 37/43 order (fixed since, offline test passes) |
| mark_as_read | 16 | 11 | session state, heartbeats |
| voice_with_b | 36 | 6 | RTC not connected (`rtc_connected` QoS), op 31 order |
| friend_request_send | 3 | 1 | |
| friend_request_accept | 5 | 4 | B's account-state startup items |
| send_dm | 5 | 4 | |
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

### Invites, joining and leaving servers

- Every invite modal open POSTs an invite (`max_age` 30 days, `flags`, `target_type`; the row icon adds
  `target_user_id`). `validate` is null on the channel's first open in a session, then the code that
  open got. The context location names the entry point.
- The first open per guild sends op 8 for the suggested users (friends, DM partners, members of other
  servers) whose membership is unknown. Later opens track `invite_suggestion_opened`.
- Join a Server resolves only on submit (`inputValue` = the typed text, `with_permissions`), then
  accepts with the gateway session id. Its GUILD_CREATE opens the guild at the invite's channel (op 43,
  first page, op 37). Leaving drops the guild's subscription and message lists so a rejoin starts fresh.
- Leave Server routes to Friends on GUILD_DELETE. An unverified account's Friends render loads
  affinities instead of the premium entitlements.
- Not modelled: `experiment_user_evaluation_exposed` after a join (experiment exposure), the quest
  `quest_hover` events (pointer passing over the quest entry).

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

### Inbox, threads browser, back/forward (fixtures inbox, threads_browser, history_nav)

- The Mentions tab's first render asks for `/users/@me/mentions?limit=25&roles=true&everyone=true`
  twice, as the client does. The popout reopens on `inbox.current_tab` (settings-proto/1 field 2);
  a tab switch is saved with the 10 s FREQUENT_USER_ACTION timer started by the first switch.
- The Inbox "Mark As Read" acks at once with the usual ack body.
- The thread browser's search adds `tag_setting=match_some`, and runs on the first open per
  channel only. Its "Create" posts `/channels/{id}/threads` with `"location":"Thread Browser Toolbar"`
  and sends the first message with `location: thread_creation`. Typing in the form is typing in
  the parent. Delete Thread loads `/guilds/{id}/roles/member-counts`.
- Op 43 and the guild-open set are sent on the first entry into a guild per session only
  (history_nav, discover: re-entering sends neither).
- A guild text channel route render loads `/guilds/{id}/integrations?...` when we can manage the
  guild and it has no system channel. Every fixture agrees: all owner fixtures with the system channel
  unset send it, and none with it set does.
- Every Friends open after the first loads the premium-guild entitlements again.
- A jump loads `messages?limit=30&around=` (was 50; the value is not compared).
- UI science via `analytics_track`, with the official property order (guild and channel metadata
  spread after the event's own keys): `open_popout`, `inbox_channel_acked`, `notification_action`,
  `jump`, `open_modal`, `thread_browser_tab_changed`, `thread_creation_started`,
  `keyboard_shortcut_used`, `app_back_forward_navigated`.
## Guild events and channels (guild_events.jsonl, create_channel.jsonl)

Implemented from the fixtures: no REST when the Events modal opens; the review
step's `scheduled-events/-1/users/counts` (400 like the client); the create POST
body; after create `users/@me/scheduled-events?guild_ids`, `users/counts`, the
invite POST to the event's channel (ctx `Guild Events`, `{"max_age":604800,"max_uses":0}`)
and `POST /guilds/{id}/ack/1/{event} {}` 3 s later; Interested PUT `{"response":1}` /
DELETE; Cancel Event DELETE. Channels: `GET profile` on Create Channel, 201 POST,
then `GET templates` and the new channel's messages; `GET regions` on settings,
the whole Overview form on Save, `GET roles/member-counts` on Delete, `GET templates`
after save and delete. Science per window (types, property keys and order, values):

| window | fixture | ours |
|---|---|---|
| open_events_empty / open_events_one | impression_modal_root_legacy (GuildEventsModal), open_modal (Guild Events Modal) | same |
| create_event_open | impression_modal_root_legacy (ScheduleEventModal) | same |
| open_create_channel | open_modal (Create Channel) | same |
| create_channel_submit | network_action_channel_create, channel_opened | network_action_channel_create (channel_opened is in `analytics_unknowable`) |
| channel_settings_open | settings_pane_viewed | same |
| other windows | none | none |

Not captured, so inferred: the external ("Somewhere Else") create body
(`scheduled_end_time` after the start, `entity_metadata.location` where
`channel_id` goes), Start Event (`PATCH .../scheduled-events/{id} {"status":2}`),
the card's Share button (same invite POST as after create), the interested
counts of events already listed when the modal opens (one `users/counts` each,
once), Forum / Voice create follow-ups and the Overview form of non-text channels.
Left out because they would be dead or unverified: Edit Event, Add to Calendar,
Report Event, Event Frequency, cover image, the Private Channel switch, and the
settings tabs other than Overview.

## Remaining differences and why

| Area | Difference | Reason |
|---|---|---|
| Telemetry | Not sent: NUX / upsell / quest events, experiment exposures, Electron and web-bundle metrics (`/metrics/v2` too), media-engine voice events and `leave_voice_channel`, `video_layout_toggled`, quick switcher scores | No truthful value in this client (`analytics_unknowable`). |
| Telemetry | Settings modal `impression_modal_root_legacy` (variant `renderModalSpinner`) | The settings chunk's lazy-load spinner; allow-listed in parity_settings_open / parity_open_account_settings. |
| Telemetry | Discover: no `global_discovery_*` | fastcord's compass opens the web page, not the in-app discovery entry point (allow-listed in parity_discover). |
| Telemetry | New thread: `channel_opened` without `channel_view: "Split View"` | fastcord opens the new thread as the main view (see Threads below): its main-view event goes out on create and throttles the popout's reopen (allow-listed in parity_threads_browser; the main-view shape is checked by parity_thread_open_main). |
| Telemetry | `user_profile_action` only for profiles without bio, pronouns, badges, activity or guild identity | The official enum values of the profile property lists are not known. |
| Telemetry | `custom_status_updated.prompt_type` is null | fastcord's custom status modal shows no prompt. |
| Telemetry | No `VIEW_WIDGETS_EMPTY_STATE` profile action | No widgets section. |
| Telemetry | `client_performance_cpu` / `_memory` | Our own process, measured (values differ by nature). |
| ETag values | detectables `If-None-Match` differ | Server content changed since the capture. |
| op 41 | `initialization_timestamp` | Per-install value. |
| op 40 | Heartbeats in windows | First heartbeat at `random() * interval` in both clients. |
| settings-proto/2 PATCH | Not sent | Frecency (emoji/gif usage) writes are not modelled. |
| Profile widgets | applications/public, games, oauth2/tokens after a full profile | Driven by profile widget data, not modelled. |
| Quick switcher | Exact autocomplete query set, HTTP-cache revalidation | Throttle model approximated. Chrome revalidates cached autocomplete GETs. |
| Voice | `rtc_connected` QoS, voice UDP | RTC/voice connection is `src/voice`'s job. |
| GCS upload | `upload_id` in the fixture | tools/scrub now scrubs it. The committed fixture predates that and needs a re-scrub. |
| conn ids | `0` / `false` | Chrome-internal. |
| Inbox | No Bookmarks / Reminders tabs | No saved-message flows yet. Mark All as Read uses `/read-states/ack-bulk`, which is not captured for the Inbox. |
| Inbox science | `ack_messages.guild_unread_statuses` reports every guild's unread setting as 1 (all messages) | The unread-setting resolution is not modelled (CLIENT_RULES guess). |
| Threads | New thread opens as the main view, not a side view | The Referer is `/channels/{g}/{thread}` instead of `.../{parent}/threads/{thread}`. Returning to the parent re-renders it, which adds integrations to close_thread_view (allow-listed). |
| Threads | First-view thread ack (`flags: 2`) | Fastcord acks only unread channels in a focused window (allow-listed in delete_thread_menu). |
| History science | `dismissible_content_shown` | The Friends-surface marketing card is not built (R_SCI_NEVER). |
| Discover | No `discoverable-guilds`, `discovery/categories` or CDN splashes and icons; no integrations on return | The compass opens https://discord.com/servers in the browser and the app never leaves the channel (allow-listed in parity_discover). |
| Jump to an unloaded channel | Normal page plus `around=`, instead of `around=` alone | Not captured as an action window. Only the loaded-channel jump is tested. |
| Settings open | `impression_modal_root_legacy` (variant `renderModalSpinner`) | The settings chunk's lazy-load spinner: in `settings` but not in `streamer_mode`'s identical open. |
| Edit Profiles | `games?game_ids`, `applications/public`, `oauth2/tokens` | Driven by profile widget data (as for full profiles). |
| DM row menu | hover prefetch `messages?limit=10`, `settings-proto/2` | DM-row hover prefetch and the session's lazy settings-proto/2 load are not modelled. `friend_add_context_menu` has no READY for A: the test borrows A's READY from `friend_request_send` (A and B not friends either). |
| Friend accept | B's `GET relationships` | The Pending tab's refresh is not modelled (its clicked / viewed science is). |
| DM calls | RTC science (`voice_connection_*`, `start_speaking`, `leave_voice_channel`, ...), `settings-proto/2` | The official media engine's internals (R_SCI_NEVER); the settings-proto/2 load is the session's lazy load. The tests report the app's `client_rtc_state` (awaiting endpoint, then connected). |
| DM calls | Declining a ring, caller hang-up before answer | Not recorded. Decline dismisses the ring locally and sends nothing. |
| Streamer Mode | Username truncation ("c…") in DM list / invite suggestions | UI only; not implemented yet. |
| Account (`account_edits`) | `open_account_popout`, `logout`, `login_submit` windows not tested | The multi-account switcher is not built; real login and Log Out are implemented on their own branch. The username windows are tested. |
