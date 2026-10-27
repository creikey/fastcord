# New features: what the official client sends

Official Discord desktop 0.0.419 (stable 650389), recorded 2026-10-26 in one
human-paced session per account (A = dingusbattle, owner of the test guild;
B = bobbles). Fixtures: `traffic/<scenario>.jsonl`, scenarios:
`tests/scenarios/<scenario>.scn`. Every fixture starts with a `setup` window
(A reload: READY etc.); only action windows are listed here.

Notation:

- `+ms` is time from the window's `mark`. The mark is written before the
  pointer starts moving, so the click itself lands about 250–700 ms after the
  mark. "On click" requests therefore show up at roughly +350..+900.
- Ids are folded to `{id}`; `{new}` = an id created in the run. Query keys only.
- `ctx` = decoded `X-Context-Properties`. `ref` = `Referer` path (all requests
  here are same-origin `https://discord.com/...`).
- Unless noted: all API requests carry the usual headers (authorization,
  x-super-properties, x-discord-locale, x-discord-timezone, x-debug-options);
  exact wire order is in the fixture (`wire`, netlog).
- `science` = `POST /api/v9/science` batch (event types listed). Heartbeats
  (op 1), op 40 QoS heartbeats, `latency.discord.media`, status page polls and
  collectibles-shop images are background noise and left out unless relevant.
- Gateway sends are given as `gw opN {shape}`; received dispatches as `<- EVENT`.

## guild_menu (`traffic/guild_menu.jsonl`)

The header dropdown in 0.0.419 (owner) has: Server Boost, Invite to Server,
Server Settings, Create Channel, Create Category, Create Event, App Directory,
Notification Settings, Privacy Settings, Edit Per-server Profile, Hide Muted
Channels (checkbox). Non-owner (B) also gets Leave Server (red, last). There is
**no Mark As Read / Mute Server in the header dropdown**; those are in the
guild icon's right-click menu (see guild_mark_read, guild_mute).

| window | traffic |
|---|---|
| open_guild_menu | +420 science `guild_dropdown_menu_viewed` only. No REST, no gateway. |
| close_guild_menu (Escape) | nothing |

## invite_people (`traffic/invite_people.jsonl`)

Every way of opening the invite modal POSTs an invite. The first open in a
session sends `validate: null`; later opens send `validate: "<code from the
first>"` and get the same code back (no new invite). The body differs per entry
point (channel row adds `target_user_id: null`).

| window | traffic |
|---|---|
| invite_from_menu (header menu → Invite to Server) | +490 `POST /api/v9/channels/{text}/invites` → 200, ctx `{"location":"Guild Header"}`, body `{"validate":null,"max_age":2592000,"max_uses":0,"target_type":null,"temporary":false,"flags":0}`; +500 `gw op8 {guild_id:[str], query:null, limit:null, user_ids:[str], presences:false}` (members for the invite suggestion list); science `open_modal` |
| copy_invite (Copy) | science `copy_instant_invite` only (clipboard) |
| close_invite (Escape) | science `keyboard_shortcut_used` |
| invite_from_header_icon (person+ icon next to the guild name) | +830 POST invites, ctx `{"location":"Guild Header Invite Button"}`, body as above with `"validate":"<code>"`; science `invite_suggestion_opened, open_modal` |
| invite_from_channel_icon (hover row → "Invite to Channel" icon) | +1480 (incl. hover) POST invites, ctx `{"location":"Guild Channels"}`, body `{"validate":"<code>","max_age":2592000,"max_uses":0,"target_user_id":null,"target_type":null,"temporary":false,"flags":0}` |

The channel id in the URL is the channel the modal is for (current text channel
for the header paths, the row's channel for the row icon). Response 200 is the
invite object (`code`, `expires_at`, ...).

## guild_mark_read (`traffic/guild_mark_read.jsonl`)

B posts while A is on Friends; A right-clicks the guild icon → Mark As Read.

| window | traffic |
|---|---|
| open_guild_context_menu (right-click guild icon) | +410 `GET /api/v9/channels/{text}/messages?limit=10` (ref `/channels/@me`) and +430 `gw op37 {subscriptions:{<guild>:{typing:true,activities:true,threads:true}}}`: this is the guild-icon **hover prefetch**, not the menu. |
| guild_mark_read (click "Mark As Read") | +400 `POST /api/v9/read-states/ack-bulk` → 204, body `{"read_states":[{"channel_id":str,"message_id":str,"read_state_type":0}]}` (one entry per unread channel, message_id = channel's last message); science `mark_as_read`, then `notification_action`; `<- MESSAGE_ACK` |

## guild_mute (`traffic/guild_mute.jsonl`)

Guild icon right-click → Mute Server (hover opens submenu: For 15 Minutes, For
1 Hour, For 3 Hours, For 8 Hours, For 24 Hours, Until I turn it back on) → For
15 Minutes. Then right-click → "Unmute Server" (the item id changes when muted).

| window | traffic |
|---|---|
| guild_mute_15m | on click: `PATCH /api/v9/users/@me/guilds/settings` → 200, body `{"guilds":{"<guild>":{"muted":true,"mute_config":{"selected_time_window":900,"end_time":"<ISO8601 ms Z, now+900s>"}}}}`; science `notification_settings_updated`; `<- USER_GUILD_SETTINGS_UPDATE` |
| guild_unmute (window starts at the right-click) | on click: same PATCH, body `{"guilds":{"<guild>":{"muted":false}}}` |

No X-Context-Properties on these PATCHes.

## guild_notifications (`traffic/guild_notifications.jsonl`)

Header menu → Notification Settings opens a modal ("Mute <guild>" switch, Server
Notification Settings radios All Messages / Only @mentions / Nothing, plus
suppress/highlight switches, Done). Each radio click saves immediately; Done
sends nothing.

| window | traffic |
|---|---|
| open_guild_notifications | science `guild_dropdown_menu_viewed` (opening the modal itself sends nothing) |
| guild_notify_mentions | on click: `PATCH /api/v9/users/@me/guilds/settings` body `{"guilds":{"<guild>":{"message_notifications":1}}}`; science `notification_settings_updated`; `<- USER_GUILD_SETTINGS_UPDATE` |
| guild_notifications_done | nothing (REST) |
| guild_notify_all | same PATCH with `"message_notifications":0` |

Values: 0 = All Messages, 1 = Only @mentions, 2 = Nothing (3 = inherit, used by
channel overrides).

## channel_notifications (`traffic/channel_notifications.jsonl`)

Channel header bell (aria-label "Notification Settings") opens a menu: Mute
Channel (submenu like guild mute) / Unmute Channel ("Muted until <date>"), then
radios Use Category Default (shows the inherited value), All Messages, Only
@mentions, Nothing. All writes go to the same endpoint as guild settings, under
`channel_overrides`:

| window | body of `PATCH /api/v9/users/@me/guilds/settings` |
|---|---|
| channel_mute_15m | `{"guilds":{"<guild>":{"channel_overrides":{"<channel>":{"muted":true,"mute_config":{"selected_time_window":900,"end_time":"<ISO>"}}}}}}` |
| channel_unmute | `{...{"<channel>":{"muted":false}}}` |
| channel_notify_mentions | `{...{"<channel>":{"message_notifications":1}}}` |
| channel_notify_default (Use Category Default) | `{...{"<channel>":{"message_notifications":3}}}` |

Each: science `notification_settings_updated`, `<- USER_GUILD_SETTINGS_UPDATE`.
Opening the bell menu sends nothing.

## join_leave_server (`traffic/join_leave_server.jsonl`, two-sided)

B leaves via header menu → Leave Server → confirm (an `alertdialog`: "Leave
'<guild>'", Cancel / Leave Server). A creates an invite. B: rail "+" → Join a
Server → types the link → Join Server.

| window | traffic |
|---|---|
| b_open_guild_menu | B science `guild_dropdown_menu_viewed` |
| b_leave_server (menu item) | nothing; confirm dialog opens |
| b_leave_confirm | B +600 `DELETE /api/v9/users/@me/guilds/{guild}` → 204, body `{"lurking":false}`; `<- GUILD_MEMBER_REMOVE`, `<- GUILD_DELETE`; client routes to `/channels/@me` and loads Friends (`referrals/eligibility`, `affinities/v2/users`, `applications/public`) |
| a_create_invite | A POST invites (`Guild Header Invite Button`, `validate:null`) as in invite_people |
| b_open_add_server (rail "+") | B science `impression_guild_add_landing, impression_modal_root_legacy, nuo_transition, open_modal`; no REST |
| b_join_a_server ("Join a Server") | science `impression_guild_add_join, nuo_transition, open_modal`; no REST |
| b_paste_invite (typing the link) | nothing (no resolve while typing) |
| b_join_submit ("Join Server") | +540 `GET /api/v9/invites/{code}?inputValue=<url-encoded typed text>&with_counts=true&with_expiration=true&with_permissions=true` → 200; science `invite_opened`; +830 `POST /api/v9/invites/{code}` → 200, ctx `{"location":"Join Guild","location_guild_id":str,"location_channel_id":str,"location_channel_type":0}`, body `{"session_id":"<gateway session id>"}`; +1430 `<- GUILD_CREATE`; then +1540 `gw op43 {guild_id, fields:["status","voice_start_time"]}`, `GET channels/{text}/messages?limit=10`, `gw op37` subscribe, `messages?before=&limit=20` (guild opened at its default channel) |

## guild_events (`traffic/guild_events.jsonl`)

"Events" row at the top of the channel list opens the Events modal ("There are
no upcoming events." + Create Event). Create Event wizard: Location (Voice
Channel / Somewhere Else radios) → Event Info (topic, start date/time defaulting
to the next full hour, frequency, description, cover) → Review → Create Event.

| window | traffic |
|---|---|
| open_events_empty | science `impression_modal_root_legacy, open_modal` only (events come from GUILD_CREATE / READY) |
| create_event_open / _location | nothing |
| create_event_info (typing topic, Next) | `GET /api/v9/guilds/{guild}/scheduled-events/-1/users/counts` → **400** when the Review step renders (preview with id -1) |
| create_event_submit | +350 `POST /api/v9/guilds/{guild}/scheduled-events` → 200, body `{"name":str,"description":"","privacy_level":2,"scheduled_start_time":"<ISO ms Z>","entity_type":2,"channel_id":"<voice>","recurrence_rule":null}`; `<- GUILD_SCHEDULED_EVENT_CREATE`; +1220 `GET /api/v9/users/@me/scheduled-events?guild_ids=<guild>` and `GET /api/v9/guilds/{guild}/scheduled-events/{event}/users/counts`; `<- GUILD_SCHEDULED_EVENT_USER_ADD` (creator auto-interested); +1265 `POST /api/v9/channels/{text}/invites` ctx `{"location":"Guild Events"}` body `{"max_age":604800,"max_uses":0}` (share dialog shown after creation); +4220 `POST /api/v9/guilds/{guild}/ack/1/{event}` body `{}` → `<- GUILD_FEATURE_ACK` |
| open_events_one | science only |
| event_uninterested (click "Interested" while marked) | `DELETE /api/v9/guilds/{guild}/scheduled-events/{event}/users/@me` → 204; `<- GUILD_SCHEDULED_EVENT_USER_REMOVE` |
| event_interested | `PUT .../scheduled-events/{event}/users/@me` → 200, body `{"response":1}`; `<- GUILD_SCHEDULED_EVENT_USER_ADD` |
| event_open_context_menu (right-click the card) | nothing. Menu: Add to Calendar, Start Event, Edit Event, Cancel Event, Copy Event Link, Report Event |
| event_cancel (menu item) | nothing; confirm dialog "Never Mind / Cancel Event" |
| event_cancel_confirm | `DELETE /api/v9/guilds/{guild}/scheduled-events/{event}` → 204; `<- GUILD_SCHEDULED_EVENT_DELETE` |

## create_channel (`traffic/create_channel.jsonl`)

Category "+" (aria-label "Create Channel") → modal (Text/Voice/Forum radios,
name input placeholder `new-channel`, Private switch) → Create Channel. Then row
gear ("Edit Channel") → Overview, topic → Save Changes; sidebar Delete Channel →
confirm.

| window | traffic |
|---|---|
| open_create_channel | `GET /api/v9/guilds/{guild}/profile`; science `open_modal`. (A settings-proto/2 frecency PATCH also fell in this window; unrelated.) |
| create_channel_submit | +440 `POST /api/v9/guilds/{guild}/channels` → **201**, body `{"type":0,"name":"fc-temp","permission_overwrites":[],"parent_id":"<category>"}`; `<- CHANNEL_CREATE`, `<- CHANNEL_UPDATE`; client routes to the new channel: +915 `GET /api/v9/guilds/{guild}/templates` and `GET channels/{new}/messages?limit=10`; science `network_action_channel_create, channel_opened` |
| channel_settings_open (gear) | +2250 (incl. hover) `GET /api/v9/guilds/{guild}/regions`; science `settings_pane_viewed` |
| channel_topic_type | nothing |
| channel_settings_save | `PATCH /api/v9/channels/{new}` → 200, body is the whole Overview form: `{"name":str,"type":0,"topic":str,"bitrate":64000,"user_limit":0,"nsfw":false,"flags":0,"rate_limit_per_user":0}`; `<- CHANNEL_UPDATE`; `GET guilds/{guild}/templates` |
| channel_delete_open (sidebar "Delete Channel") | `GET /api/v9/guilds/{guild}/roles/member-counts` |
| channel_delete_confirm | `DELETE /api/v9/channels/{new}` → 200; `<- CHANNEL_DELETE`; `GET guilds/{guild}/templates` |

## emoji_picker_add_emoji (`traffic/emoji_picker_add_emoji.jsonl`)

The composer smiley (aria-label "Add Emoji") opens the expression picker on the
Emoji tab. Its header has a search box, the skin-tone button and an **"Add
Emoji"** button (shown to members who can manage expressions).

| window | traffic |
|---|---|
| open_emoji_picker | +590 `GET /api/v9/guilds/{guild}/top-emojis`; +845 `GET /api/v9/users/@me/billing/subscriptions?sync_level=2`, `GET /api/v9/users/{A}/profile?with_mutual_guilds=false&with_mutual_friends=false&with_mutual_friends_count=false` (both 304/200 cached); science `open_popout, search_opened, expression_picker_opened, dismissible_content_shown`. (Static `cdn.discordapp.com/assets/content/*` art and a settings-proto/2 frecency PATCH also appear.) |
| picker_add_emoji ("Add Emoji") | **no network**. The button is a file `<input>`: it opens the OS file chooser directly (png/jpg/gif/webp/avif). After picking a file the upload is the same as `upload_custom_emoji` (`POST /api/v9/guilds/{guild}/emojis`). In the recording the chooser was cancelled. |
| close_add_emoji | science `keyboard_shortcut_used, hotspot_hidden` |

## inbox (`traffic/inbox.jsonl`, two-sided)

B sends `<@A> ...` twice (autocomplete + Tab inserts the mention: B's body
`content` is `"<@{A}> first inbox ping"`). A opens the Inbox (title-bar icon,
aria-label "Inbox"): a popout with tabs Unreads / Mentions / Bookmarks /
Reminders, "Mark All as Read", and "View Friend Requests". **The popout reopens
on the last used tab** (stored in settings-proto/1 `inbox.current_tab`).

| window | traffic |
|---|---|
| open_inbox | +1160 `GET /api/v9/users/@me/mentions?limit=25&roles=true&everyone=true` **twice** (identical, same ms); science `open_popout` |
| inbox_unreads_tab | science `open_popout` only |
| inbox_unreads_mark_read (channel card ✓ "Mark As Read") | +680 `POST /api/v9/channels/{text}/messages/{last_msg}/ack` → 200, body `{"token":null,"last_viewed":4317}` (no `flags`); `<- MESSAGE_ACK`; science `inbox_channel_acked`, `ack_messages`, `notification_action` ×2. Referer stays `/channels/@me`. |
| inbox_mentions_tab | science `open_popout` (list from the open_inbox fetch) |
| inbox_remove_mention (× = "Mark As Read" on a mention) | +460 `DELETE /api/v9/users/@me/mentions/{message}` → 204; `<- RECENT_MENTION_DELETE`; +1575 `PATCH /api/v9/users/@me/settings-proto/1` body `{"settings":"EgIIAQ=="}` = `inbox { current_tab: 1 (MENTIONS) }` (first tab switch is persisted ~1 s later) |
| inbox_jump_to_mention ("Jump to Message") | science `jump`; routes to `/channels/{guild}/{text}/{message}`. In this run the channel was already loaded (no fetch). In an earlier run where it was not: +550 `GET /api/v9/channels/{text}/messages?limit=30&around={message}` plus the guild-open set (`unclaimed-games`, `migrate-command-scope`, guild entitlements, `gw op43`, `gw op37`) |

`last_viewed` (4317 here) is the same value the client's other acks send that
day; reuse the existing ack code's value.

## threads_browser (`traffic/threads_browser.jsonl`)

Channel header "Threads" icon opens the thread browser modal (tabs Active /
Archived, "Create" button). Create opens the thread composer in the side view
(name input placeholder "New Thread", first-message box). Enter creates.
Thread rows in the sidebar sit under the parent channel; the side view does
not change the route.

| window | traffic |
|---|---|
| open_threads_popout_empty | +620 `GET /api/v9/channels/{text}/threads/search?archived=true&sort_by=last_message_time&sort_order=desc&limit=25&tag_setting=match_some&offset=0`; science `open_modal, thread_browser_tab_changed` ×2 |
| create_thread_open ("Create") | science `thread_creation_started` |
| create_thread_name (typing name + message) | `POST /api/v9/channels/{text}/typing` (typing in the composer counts as typing in the **parent** channel, every ~8–10 s) |
| create_thread_submit (Enter) | +70 `POST /api/v9/channels/{text}/threads` → 201, body `{"name":str,"type":11,"auto_archive_duration":4320,"location":"Thread Browser Toolbar"}`; `<- MESSAGE_CREATE` (thread-created system message in parent), `<- THREAD_CREATE`, `<- THREAD_MEMBER_UPDATE`; +380 `GET /api/v9/channels/{thread}/messages?limit=30`; +640 `POST /api/v9/channels/{thread}/messages` ctx `{"location":"thread_creation"}`, Referer `/channels/{guild}/{text}/threads/{thread}`, normal message body |
| close_thread_view (click parent channel) | `GET settings-proto/2` (unrelated periodic) |
| open_threads_popout (with one thread) | science only (no second threads/search: active threads are known from the gateway) |
| open_thread_from_popout (click the thread) | science `channel_opened`; no fetch (cached) |
| delete_thread_menu (right-click sidebar thread row) | `POST /api/v9/channels/{thread}/messages/{last}/ack` body `{"token":null,"last_viewed":4317,"flags":2}` (thread ack on view) |
| delete_thread (menu "Delete Thread") | `GET /api/v9/guilds/{guild}/roles/member-counts` |
| delete_thread_confirm | `DELETE /api/v9/channels/{thread}` → 200; `<- THREAD_DELETE`; `GET /api/v9/guilds/{guild}/integrations?include_applications=true&include_role_connections_metadata=true` |

## settings (`traffic/settings.jsonl`)

0.0.419 has the new settings layout: a modal with a searchable sidebar
(`data-list-item-id="settings-sidebar___<panel>"`: account_panel,
data_and_privacy_panel, notifications_panel, appearance_panel,
voice_and_video_panel, ...) and an "Edit Profiles" row that opens a separate
full-screen WYSIWYG profile editor (second dialog). The profile editor shows a
Reset / Save bar once a field differs **and the edited field lost focus**.

| window | traffic |
|---|---|
| open_settings (gear, lands on Account) | +980 `GET /__development/build_overrides`, `GET /api/v9/users/@me/billing/payment-sources`, `GET /api/v9/users/@me/billing/location-info`, `GET /api/v9/auth/sessions`, `GET /api/v9/safety-hub/@me`; science `impression_modal_root_legacy`, `dismissible_content_shown, settings_pane_viewed` |
| reveal_email ("Reveal") | **nothing** (email is already in the user object) |
| open_profiles ("Edit Profiles") | +710 `GET /api/v9/content-inventory/users/{A}/outbox`, `GET /api/v9/users/{A}/profile?type=modal&with_mutual_guilds=true&with_mutual_friends=false&with_mutual_friends_count=true`; +785 `GET users/@me/referrals/eligibility` (404), `GET /api/v9/collectibles-categories/v2?include_bundles=true&variants_return_style=2&skip_num_categories=0`, `GET users/@me/collectibles-purchases?variants_return_style=2`, `GET users/@me/notes/{A}` (404), `GET users/{A}/application-identities?with_profiles=true`, `GET widget-configs/featured`, `GET users/@me/widgets/suggested-games`; +845 `GET /api/v9/games?game_ids=...`; +976 `applications/public?application_ids=` ×3, `users/@me/activities/statistics/applications`; +1007 `oauth2/tokens?application_ids=...` |
| profile_save (pronouns + bio) | `PATCH /api/v9/users/%40me/profile` (note **`%40me`**, percent-encoded) → 200, body `{"bio":str,"pronouns":str}`; `<- USER_UPDATE` |
| profile_restore_save | same, body `{"bio":"","pronouns":""}` |
| display_name_save | `PATCH /api/v9/users/@me` (plain `@me`) → 200, body `{"global_name":str}`; `<- USER_UPDATE`, `<- GUILD_MEMBER_UPDATE` per guild |
| display_name_restore_save | same with the original name |
| close_profiles | nothing |
| open_notifications_settings | +920 `GET /api/v9/users/@me/email-settings`, `GET /api/v9/family-center/@me`; science `settings_pane_viewed`, `network_action_email_settings_fetch` |
| open_appearance | +880 `GET /api/v9/users/@me/custom-themes` → 204 |
| appearance_sync_on (theme radio "Sync with computer") | `PATCH /api/v9/users/@me/settings-proto/1` body `{"settings":"agQIARoA"}` = `appearance { theme: 1, client_theme_settings: {} }` (the OS theme resolved, here dark → proto DARK=1; the "sync" flag itself is local, not in the proto); science `client_theme_updated`; `<- USER_SETTINGS_PROTO_UPDATE` |
| appearance_sync_off (radio "Dark") | same, `{"settings":"agQIAxoA"}` = `appearance { theme: 3 (DARKER = UI "Dark") }` |

Theme radios offered: Light, Ash, Dark, Onyx, Sync with computer (+ Nitro
gradients). Username edit and Log Out were not touched (need the password).

## streamer_mode (`traffic/streamer_mode.jsonl`)

Also contains the Notifications-page toggle (settings.jsonl's attempt clicked
the hidden `<input>` and did not toggle; its windows were dropped).

There is **no Streamer Mode page** in 0.0.419's settings sidebar; it is a
section at the bottom of **Appearance** (sub-nav: Theme, App Icon, Messages,
Chat Box, Search, Streamer Mode): "Enable Streamer Mode", "Automatically
enable Streamer Mode if OBS or XSplit are running", and "If Streamer Mode is
enabled…": Hide my personal information (email, connected accounts, notes),
Hide invite links, Disable all sound effects, Disable notifications, and more.

| window | traffic |
|---|---|
| open_settings | as settings/open_settings |
| open_notifications_settings | as settings/open_notifications_settings |
| notifications_toggle_off ("Friends come online" off) | `PATCH /api/v9/users/@me/settings-proto/1` body `{"settings":"OgJiAA=="}` = `notifications { field 12: BoolValue{} (false) }`; science `ui_setting_interacted, notification_settings_updated`; `<- USER_SETTINGS_PROTO_UPDATE` |
| notifications_toggle_on | same, `{"settings":"OgRiAggB"}` = `notifications { field 12: BoolValue{value:true} }` (written explicitly, not cleared) |
| open_settings_appearance | `GET /api/v9/users/@me/custom-themes` → 204 |
| streamer_mode_on | **local only**: no REST, no gateway, only science `ui_setting_interacted, streamer_mode_toggle, app_notice_viewed` |
| streamer_mode_off | local only: science `ui_setting_interacted, streamer_mode_toggle` |
| streamer_invite_modal (while on) | same invite POST + op8 as invite_people (the link is still created) |

UI while Streamer Mode is on (screenshots in `.secrets/screens/streamer_mode/`):

- A purple app notice bar across the top: "Streamer Mode is enabled. Usernames
  have been truncated." with a "Disable" button and ×.
- Settings → Account: the whole page is replaced by an illustration and a
  "Streamer Mode Enabled" button (email/phone not shown at all).
- Invite modal: the link field reads "Hidden; Use copy button" (Copy still works).
- DM list, invite suggestions, Active Now: some users' names are truncated to
  first letter + "…" ("c…", "N…" for creikey / NoDadStillRad, both A's friends;
  in the invite list their username line is also cut). Non-friends (bobbles at
  that time, Benji), group DM names, A's own name and guild names stay whole.

## history_nav (`traffic/history_nav.jsonl`)

Title-bar arrows (aria-label "Go back" / "Go forward") and Cmd+[ / Cmd+] move
through the route history (channel ↔ Friends). No gateway traffic.

| window | traffic |
|---|---|
| history_back_key (Cmd+[ , Friends → #general) | +135 `GET /api/v9/guilds/{guild}/integrations?include_applications=true&include_role_connections_metadata=true` (sent on every open of this guild's channel route; the owner sees it); science `keyboard_shortcut_used, app_back_forward_navigated` |
| history_forward_key (Cmd+] → Friends) | science `keyboard_shortcut_used, app_back_forward_navigated`; `GET /api/v9/users/@me/entitlements?with_sku=false&with_application=false&entitlement_type=11&exclude_ended=true` (Friends view) |
| history_back_button / history_forward_button | same as the key variants without `keyboard_shortcut_used` |

Nothing history-specific is sent: the requests are what opening that route
normally sends.

## discover (`traffic/discover.jsonl`)

The compass (`guildsnav___guild-discover-button`) routes to `/discovery/servers`
inside the app.

| window | traffic |
|---|---|
| open_discover | science `global_discovery_entrypoint_clicked`; +840 `GET /api/v9/discoverable-guilds?offset=0&limit=30` and `GET /api/v9/discovery/categories?locale=en-US&primary_only=false` (Referer `/discovery/servers`); science `global_discovery_servers_viewed, global_discovery_viewed`; +1035 ~30 × (`cdn.discordapp.com/discovery-splashes/{guild}/{hash}.jpg?size=600` + `cdn.discordapp.com/icons/{guild}/{hash}.webp?size=96`) |
| leave_discover (click the test guild) | normal guild-open requests |

If fastcord opens `https://discord.com/discovery` in the browser instead, none
of this is sent by the client (the two API GETs and the CDN images are the
whole difference).

## friend_add_context_menu (`traffic/friend_add_context_menu.jsonl`, two-sided)

A right-clicks B's DM row → "Add Friend" (`#user-context-add-friend`); B accepts
from Friends → Pending.

| window | traffic |
|---|---|
| friend_request_from_dm_menu (A: Home, right-click DM row, Add Friend) | Hovering the DM row prefetches: `GET /api/v9/channels/{dm}/messages?limit=10`, `GET users/@me/notes/{B}` (404), `GET users/@me/application-command-index`; science `impression_dm_list_right_click_menu_shown`; on click: `PUT /api/v9/users/@me/relationships/{B}` → 204, ctx `{"location":"ContextMenu"}`, body `{}`; B `<- RELATIONSHIP_ADD` (type 3, incoming) |
| friend_request_accept (B) | Pending tab: `GET /api/v9/users/@me/relationships`; Accept: `PUT /api/v9/users/@me/relationships/{A}` → 204, ctx `{"location":"Friends"}`, body `{"confirm_stranger_request":false}` (mutual guild, so no stranger confirmation); `<- RELATIONSHIP_ADD` (type 1) |

## friend_nickname (`traffic/friend_nickname.jsonl`, two-sided)

A right-clicks B in the member list → "Add Friend Nickname"
(`#user-context-add-friend-nickname`; once set the item becomes "Edit Friend
Nickname", `#user-context-edit-friend-nickname`; same item in the DM row menu).
Dialog: one text input (placeholder = B's current display name), "Reset Friend
Nickname", Cancel, Save (submit). Then "Change Nickname"
(`#user-context-change-nickname`, owner/Manage Nicknames) for the server
nickname: same dialog without the reset button. Screenshots of every place:
`.secrets/screens/friend_nickname/*.png`.

| window | traffic |
|---|---|
| friend_nickname_open (right-click member row) | the right-click itself loads the member's popout data: +660 `GET /api/v9/users/{B}/profile?type=popout&with_mutual_guilds=true&with_mutual_friends=true&with_mutual_friends_count=false&guild_id={guild}`, `GET users/{B}/application-identities?with_profiles=true`, `GET users/@me/notes/{B}` (404), guild + user `application-command-index`; `gw op37 {subscriptions:{<guild>:{members:[B]}}}`. The menu item / dialog open: nothing. |
| friend_nickname_save | +330 `PATCH /api/v9/users/@me/relationships/{B}` → 204, body `{"nickname":"Bobby Nick"}`; `<- RELATIONSHIP_UPDATE` (no ctx header) |
| server_nickname_open | profile GET as above (right-click); science `open_modal` |
| server_nickname_save | +440 `PATCH /api/v9/guilds/{guild}/members/{B}` → 200, body `{"nick":"Server Bob"}`; `<- GUILD_MEMBER_UPDATE`, `<- GUILD_MEMBER_LIST_UPDATE`; science `moderation_action` |
| quick_switcher (Cmd+K, "bob") | only the usual `games/autocomplete?q=...` lookups: user/DM results are local |
| full_profile (member menu → Profile) | profile GET (`type=popout`, guild_id), `content-inventory/users/{B}/outbox` |
| home_views / open_dm | normal Friends / DM open traffic (`relationships`, `messages?limit=10`, `gw op13 {channel_id}`) |
| server_nickname_remove_save (field cleared → Save) | `PATCH /api/v9/guilds/{guild}/members/{B}` body `{"nick":""}` (empty string, not null) |
| friend_nickname_reset ("Reset Friend Nickname" clears the field, then Save) | `PATCH /api/v9/users/@me/relationships/{B}` → 204, body `{"nickname":null}`; `<- RELATIONSHIP_UPDATE` |
| hide_member_list | science `member_list_toggled` only (local) |

### Where the names show (observed, A's view)

B: username `bobbles_2345`, global name `bobbles`; friend nickname
"Bobby Nick"; server nickname "Server Bob".

| place | friend nick only | friend nick + server nick |
|---|---|---|
| DM list row (1:1 DM) | **Bobby Nick** | Bobby Nick |
| Group DM without a name (A, B, ...) in DM list / quick switcher | **Bobby Nick** (name is built from recipients' displayed names) | Bobby Nick |
| DM header, DM composer placeholder (`Message @Bobby Nick`) | Bobby Nick | Bobby Nick |
| B's messages in the DM | Bobby Nick | Bobby Nick |
| Typing indicator in the DM ("Bobby Nick is typing...") | Bobby Nick | Bobby Nick |
| DM right-side profile panel | Bobby Nick (with `bobbles_2345` under it) | Bobby Nick |
| Friends → All list | Bobby Nick | Bobby Nick |
| Quick switcher result | "Bobby Nick" + username `bobbles_2345` as the secondary text | same |
| Guild messages (author) | **bobbles** (friend nick NOT used in guilds) | **Server Bob** |
| Guild member list | bobbles | Server Bob |
| `@mention` of B in a guild message | @bobbles | @Server Bob |
| Full profile opened from the guild | (not captured) | Server Bob, `bobbles_2345` under it |

Precedence:

- Guild context (messages, member list, mentions, guild-opened profiles):
  server nick > global name > username. The friend nickname is ignored.
- Everywhere outside guilds (DMs, group DMs, DM list, Friends, typing in DMs,
  quick switcher user rows, DM profile panel): friend nickname > global name >
  username. The server nickname is ignored there.
- The username stays visible as the secondary line (quick switcher, profiles).

The profile popout from a left-click on the member row did not open in the
recording (screenshot shows the list only).

## dm_call (`traffic/dm_call.jsonl`, two-sided)

A opens the DM with B and clicks the header phone icon (aria-label "Start Voice
Call"). B's DM row shows "Incoming Call" and a ring popout with "Join Call".

| window | traffic |
|---|---|
| start_call (A click) | +790 A `gw op4 {guild_id:null, channel_id:"<dm>", self_mute:false, self_deaf:false, self_video:false, flags:2, preferred_region:"us-west", preferred_regions:[str ×5]}` (same op4 as a guild voice join, DM channel id, guild null); science `join_voice_channel`. Server: both get `<- MESSAGE_CREATE` (type 3 call message, `call:{participants:[A], ended_timestamp:null}`), `<- CALL_CREATE {channel_id, message_id, region, ringing:[], ongoing_rings:{}, voice_states:[], embedded_activities:[]}`, `<- VOICE_STATE_UPDATE`. +1110 A **`POST /api/v9/channels/{dm}/call/ring`** body `{"recipients":null}` → 204 (sent right after A's own CALL_CREATE arrives, ~320 ms after op4), Referer `/channels/@me/{dm}`; then both `<- CALL_UPDATE {ringing:[B], ongoing_rings:{B:A}}`. A: `GET /api/v9/activities/shelf` ×2, `<- VOICE_SERVER_UPDATE` (+1370) → RTC connect, `gw op31 {guild_ids:[all A's guilds]}`, `gw op40` with `reasons:["rtc_connected"]`, `GET /api/v9/soundboard-default-sounds`, `GET settings-proto/2` |
| (B, same window) incoming ring | B receives only gateway: MESSAGE_CREATE (type 3), CALL_CREATE, VOICE_STATE_UPDATE (A), CALL_UPDATE (ringing B). No REST on B for the ring. |
| b_join_from_ring (B "Join Call") | B `gw op4` (same shape as A's, DM channel id); science `ring_call_accepted, call_button_clicked, join_voice_channel`; both `<- MESSAGE_UPDATE` (call message participants += B), `<- VOICE_STATE_UPDATE`, `<- CALL_UPDATE {ringing:[], ongoing_rings:{}}`; B `GET activities/shelf`, `<- VOICE_SERVER_UPDATE`, `gw op31 {guild_ids:[B's guilds]}`, op40 `rtc_connected`, `GET soundboard-default-sounds` |
| a_hang_up (A "Disconnect") | A `gw op4 {guild_id:null, channel_id:null, self_mute:false, self_deaf:false, self_video:false, flags:2}` (no preferred_region); science `call_button_clicked, leave_voice_channel, voice_disconnect`; both `<- VOICE_STATE_UPDATE`. The call stays alive while B is in it. |
| b_leave_call | B op4 leave (same shape); both `<- VOICE_STATE_UPDATE`, `<- MESSAGE_UPDATE` (call message gets `ended_timestamp`), `<- CALL_DELETE {channel_id}` |

If nobody joins and the caller hangs up, expect the same op4 leave followed by
CALL_DELETE (not recorded). Declining the ring was not recorded.

## upload_options (`traffic/upload_options.jsonl`)

Staged-attachment card buttons (aria-labels): "Spoiler Attachment", "Modify
Attachment" (pencil), "Remove Attachment" (trash). Modify opens a dialog:
filename input, description textarea ("Add a description"), "Mark as spoiler"
checkbox, Cancel / Save.

**The upload starts as soon as a file is staged**, not on send:

| window | traffic |
|---|---|
| stage_file (file chosen) | +85 science `attachment_upload_started`; +90 `POST /api/v9/channels/{text}/attachments` → 200, body `{"files":[{"filename":"test.png","file_size":758,"id":"7","is_clip":false,"original_content_type":"image/png"}]}` (`id` is a client-side counter as a **string**, increasing per staged file in the session); response `{"attachments":[{"id":7,"upload_url":"https://discord-attachments-uploads-prd.storage.googleapis.com/<uuid>/test.png?upload_id=…","upload_filename":"<uuid>/test.png"}]}`; +310 `OPTIONS` (CORS preflight) and `PUT <upload_url>` (`Content-Type: application/octet-stream`, `Referer: https://discord.com/`, raw bytes); +835 science `attachment_upload_finished` |
| spoiler_toggle | no REST (science `media_draft_edited`) |
| modify_open / modify_edit | nothing |
| modify_save | no REST (science `media_draft_edited`) — rename/description/spoiler are applied at send |
| stage_second_file | same POST attachments (`"id":"9"`) + OPTIONS + PUT |
| remove_second_file (trash) | +445 `DELETE /api/v9/attachments/<uuid>%2F<filename>` (the `upload_filename`, `/` percent-encoded). **In this run it got 429** (`x-ratelimit-scope: shared`, `retry_after: 0.3`, `global:false`, ~3 s after the upload) and the official client did **not retry** (fire-and-forget cleanup). |
| send_with_options (Enter) | +1000 `POST /api/v9/channels/{text}/messages` ctx `{"location":"chat_input"}`, body `{"mobile_network_type":"unknown","content":"","nonce":str,"tts":false,"flags":0,"attachments":[{"id":"0","description":"a small test image","filename":"fc_renamed.png","uploaded_filename":"<uuid>/test.png","is_spoiler":true,"original_content_type":"image/png"}]}`; `<- MESSAGE_CREATE`; then the media proxy GET of the new attachment |
| paste_image | same POST attachments / PUT flow with `"filename":"image.png"` (see note) |
| send_pasted | messages POST, `attachments:[{"id":"0","filename":"image.png","uploaded_filename":"<uuid>/image.png","original_content_type":"image/png"}]` |

Attachment entry rules seen:

- `id` in the message body is the index in this message (`"0"`, `"1"`, ...),
  not the upload counter.
- `filename` = the (renamed) display name; `uploaded_filename` = the upload's
  `upload_filename` (keeps the original name).
- Spoiler: `"is_spoiler": true`; the filename is **not** prefixed with
  `SPOILER_`.
- `description` only present when set; `is_spoiler` only when true.
- Key order: id, description, filename, uploaded_filename, is_spoiler,
  original_content_type.

Paste note: the paste was a synthetic `ClipboardEvent('paste')` with a
`DataTransfer` holding a PNG `File` named `image.png` (the name Chromium gives a
pasted bitmap); the system clipboard was not used. The traffic is the normal
upload flow with that filename.

## Not captured / test-account state

- add_server_create: not re-captured (`traffic/create_guild.jsonl` still current).
- Header menu "Mark As Read" / "Mute Server": these items aren't in 0.0.419's header dropdown; captured from the guild icon menu.
- Declining a ring, and a caller hanging up before anyone joins: not recorded.
- The test guild's original `#general` (1564227670806364343) was deleted by
  mistake during this session and recreated as 1564405699197407414
  (`tests/scenarios/env` TTEXT; the old id stays allow-listed as TTEXT_OLD).
  Fixtures from before that point (guild_menu … create_channel, inbox) use the old id.
- A and B are friends again (`friend_add_context_menu`). Two invite links are
  still active in the test guild (85mC4E6zH on #general, 30 days;
  e2U5resb on the voice channel, 7 days, from event creation). They were not
  revoked: the revoke run was blocked by permissions.

## account_edits (`traffic/account_edits.jsonl`)

Passive recording of A while the user worked the UI by hand (the password was
typed by the user; scrubbed to `<token>`, verified). The route was Home
(`/channels/@me`) and the window had focus. There is no READY in the `setup`
window (the recording started on an already-running instance; the fixture's
only READY follows `login_submit`): the parity tests borrow A's READY from
`settings`. The marks were added afterwards from the request times. A's username
is now `dingusbattle2` (the change back failed: the old name was taken).

| window | traffic |
|---|---|
| open_account_settings | +84 `GET /__development/build_overrides`, `GET users/@me/billing/payment-sources`, `GET users/@me/billing/location-info`, `GET /auth/sessions`, `GET /safety-hub/@me` (as settings/open_settings; no `custom-themes`); science `impression_modal_root_legacy` (variant `renderModalSpinner`), `dismissible_content_shown` (TINY_BRONCO_NOTICE, guild_id null), `settings_pane_viewed` (no guild/channel properties on Home); +6137 "Edit" on the username: `ui_setting_interacted {key:"account_info_username_setting"}` |
| username_typing | +96 (~860 ms after the editor opened, prefilled with the current name) `POST /api/v9/users/@me/pomelo-attempt` body `{"username":"dingusbattle"}` → `{"taken":true}`: science `network_action_pomelo_attempt {status_code,url,request_method,requested_username}`, `pomelo_errors {reason:"already_taken",username_error:true,one_click_flow:false,location:"modal"}`; +6285 `{"username":"dingusbattle2"}` → `{"taken":false}`: `network_action_pomelo_attempt` only. Also `POST /api/v9/metrics/v2` (web perf metrics) and a `client_ad_heartbeat` timer |
| username_submit | +127 `PATCH /api/v9/users/@me` body `{"username":str,"password":str}` → 200 (the user object, a new `token`); +8275 "Edit" again: `ui_setting_interacted` |
| username_taken_check | +136 `pomelo-attempt` `{"username":"dingusbattle3"}` → `{"taken":false}`: `network_action_pomelo_attempt` |
| open_account_popout | `GET users/{A}/profile?type=account_popout...`, application-identities, widget-configs/featured, statistics, applications/public, `GET /users/@me` ×2; science `dismissible_content_shown, user_profile_action, dismissible_content_shown`, `impression_multi_account_switch_landing` |
| logout | `POST /api/v9/auth/logout` body `{"provider":null,"voip_provider":null}`; science `multi_account_account_remove`, `network_action_user_logout, hotspot_hidden`, `user_fingerprint_changed`; in-flight requests get 401; `GET /auth/location-metadata`; `wss://remote-auth-gateway.discord.gg/?v=2` opens (QR login); science `login_viewed` |
| login_submit | `POST /api/v9/auth/login` body `{"login":str,"password":str,"undelete":false,"login_source":null,"gift_code_sku_id":null}`; then a new gateway connection and the logged-in startup burst (webauthn credentials, survey, affinities, entitlements, quests, badges, promotions, library, billing...) with science `network_action_user_login, client_heartbeat, session_start_client, gateway_connected, experiment_*_evaluation_exposed..., ready_payload_received` |

Implemented: `logout` and `login_submit` (`src/discord/auth.odin`, QR login in
`remote_auth.odin`, the page in `src/app/view_login.odin`; tests
`parity_logout`, `parity_login_submit`; rules in `traffic/CLIENT_RULES.md`
"Login and logout").

The checks come from `UniqueUsernamesStore` / `attemptUsername` (bundle; rows in
`traffic/CLIENT_RULES.md`): an 800 ms trailing debounce on the field's text, a
60 s cache of checked names, local rules before any request.

fastcord (`src/discord/username.odin`, Settings > My Account > Username): the
same checks (`username_input_changed` on open and every edit,
`username_check` for the status line), then `update_username` (the PATCH).
Tested offline: `parity_open_account_settings`, `parity_username_typing`,
`parity_username_submit`, `parity_username_taken_check`. Not implemented here
and not tested: `open_account_popout` (multi-account switcher), `logout` and
`login_submit` (real login / Log Out are on their own branch).
