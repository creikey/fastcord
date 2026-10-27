# Rules taken from the official client

Every behaviour fastcord copies from the official client's **code** (its web
bundle, stores and action creators) rather than from a recorded fixture, plus the
ones we **inferred** or **guessed** without either. Recorded behaviour is checked by
the replay parity tests (`traffic/PARITY.md`) and needs no entry here: a new
capture shows when it changes. These rules don't fail any test when Discord
changes them, so review this list on every client update.

Baseline: Discord desktop **0.0.419**, stable build **650389** (Chrome 148,
Electron 42). The bundle is cached by the test profiles under
`.secrets/discord-profile-{a,b}/discord/Cache` (decompress the cached `web.*.js`
and chunk files; never copy them into the repo).

Kinds: **code** = read from the bundle; **inferred** = deduced from fixtures,
not read in code; **guess** = neither, best knowledge.

## Reviewing after a Discord update

1. Note the new version and build number at the top of this file.
2. Launch a test instance once (`tools/capture supervise`) so it caches the new
   bundle; decompress `web.*.js` and the chunks.
3. For each **code** row, search the new bundle for its anchor and check the
   values. For **inferred** and **guess** rows, re-capture the listed scenario
   if one is named, otherwise check the bundle.
4. Re-capture the scenarios of rows that changed (`tests/scenarios/*.scn`), then
   update the code, this file and the parity tests together.

## Uploads

| Rule | Kind | Anchor in the client | fastcord |
|---|---|---|---|
| PNG → lossless WebP before upload, gated by experiment `2025-09-image-attachment-mezzanine-v2` (READY `apex_experiments`): variation 1 = files ≤ 524288 bytes, 2 = ≤ 262144, else off | code | `maybeConvertToWebP`; `web.ad0b95d8568e0f6b.js` + chunk `6d6303f7e2be7bcd.js`; search `insufficient_savings` | `src/discord/webp_convert.jai` |
| Check order and `conversion_failure_reason`: `already_webp`, `unsupported_format` (by extension), `corrupted_file`, `has_transparency` (alpha < 255, colour type 4/6), `animated_image` (APNG), `png8_format`, `icc_non_srgb_profile` / `icc_detection_failed` | code | same | same |
| Encode `canvas.toBlob("image/webp", 1)`, decode and require identical pixels (`pixel_hash_mismatch`, `hash_time_ms`); keep unless larger than the PNG; filename and `original_content_type` unchanged | code | same | same |
| ms values in `attachment_upload_finished` printed in 0.1 ms steps, no ".0" | code | same | same |
| Variation = second element of the apex assignment entry | inferred | same | `webp_convert.jai` |
| PNG wider or taller than 16384 px reports `conversion_failed` | guess | — | same |
| `toBlob("image/webp", 1)` bytes = Chromium's: blink `ImageEncoder::ComputeWebpOptions` makes quality 1.0 lossless at quality 75; Skia `SkWebpEncoder` sets `lossless = 1`, `method = 0`, `use_argb = 1`, imports unpremultiplied RGBA (`WebPPictureImportRGBA`) and, since the canvas is sRGB, adds `SkWriteICCProfile`'s 456-byte sRGB profile with WebPMux (VP8X + ICCP + VP8L). Sure: headless Chrome 156 made the capture's exact size (758 bytes for `test.png`, as in `upload_options`) and those bytes equal ours; the ICC (not the VP8L) explains 758 vs libwebp's default 60 | code (Chromium source) + checked | Chromium `third_party/blink/renderer/platform/image-encoders/image_encoder.cc`, `core/html/canvas/canvas_async_blob_creator.cc`; Skia `src/encode/SkWebpEncoderImpl.cpp`, `src/encode/SkICC.cpp` | `vendor/libwebp/fc_libwebp.c`, `webp_convert.jai` `SKIA_SRGB_ICC` |
| PNGs Chrome colour-manages on decode (gAMA / cHRM / non-sRGB ICC that still names sRGB, 16-bit) may give the canvas other pixels than Wuffs' decode, so those WebPs can differ | known gap | — | — |
| Upload size limit 10 / 50 / 500 MB by plan, or 50 / 100 MB by boost tier 2 / 3, whichever is larger; 10 files per message | guess | search `maxFileSize`, `MAX_UPLOAD_COUNT` | `src/app` attachments |
| Drag-and-drop `origin` = `"drag_and_drop"` | guess | search `file_picker` in the upload analytics | attachments |

## Streamer Mode

| Rule | Kind | Anchor | fastcord |
|---|---|---|---|
| Defaults: off, auto-detect on, hide personal info / hide invites / disable sounds / disable notifications on, hide-from-capture off | code | `StreamerModeStore` | `src/app/view_streamer.jai` |
| Auto-detect = `RunningGameStore` entries with `streamerTool: true` (OBS, XSplit, Bebo, Streamlabs Desktop, Twitch Studio); a manual toggle sticks until the next start or stop | code | `RunningGameStore`, `streamerTool` | same |
| Analytics `streamer_mode_toggle {enabled, automatic}`, `update_streamer_mode_settings` with `old_*` copies, `app_notice_*` with `notice_type` `STREAMER_MODE` | code | search `streamer_mode_toggle` | same |
| UI strings, and the notice "…Usernames have been truncated." | code | intl strings | same |

## Settings, theme, sounds, notifications

| Rule | Kind | Anchor | fastcord |
|---|---|---|---|
| Username change body `{"username","password"}` on `PATCH /users/@me` | code (now also captured: `traffic/account_edits.jsonl`) | `UserSettingsAccountActionCreators.saveAccountChanges` | `src/discord/account.jai` |
| Username availability: `POST /users/@me/pomelo-attempt {"username"}` 800 ms after the field's text last changed (lodash trailing debounce; also for the prefilled current name), not for "" | code | `attemptUsername`, `debounce(...,800)` next to `UniqueUsernamesStore` | `src/discord/username.jai` |
| A checked name is not checked again for 60 s (LRU `maxAge:6e4`); a 429 marks it rate limited for `retry_after` (default 7 s) | code | `UniqueUsernamesStore` `validations` | same |
| Local rules before any request, with `pomelo_errors {reason:<message>}`: `^[A-Za-z0-9_.]*$`, no `..`, 2-32 characters; English messages | code | `attemptUsername`; intl `z7c4bP`, `C7G+gr`, `IpijXA` | same |
| `pomelo_errors` key order `reason, username_error, one_click_flow, location` (the capture; the bundle writes `location` before `one_click_flow`), also used for the uncaptured local-rule errors | inferred | fixture `account_edits` | same |
| A failed attempt (4xx other than 429) reports the server's first error message as `pomelo_errors.reason`; network failures report nothing | guess | `attemptUsername` catch | same |
| Status line: "Username is available. Nice!", "Username is unavailable. Try adding…", "Too fast! Wait a bit and try again."; none for the current name | code | intl `PgfBSx`, `mCrAUb`, `T15lqn` | `src/app/view_settings_account.jai` |
| "Edit" on the username sends `ui_setting_interacted {key:"account_info_username_setting"}` | inferred | fixture `account_edits` | same |
| Opening settings loads no `custom-themes` (that is the Appearance pane's) | inferred | fixtures `settings`, `streamer_mode`, `account_edits` | `src/discord/actions.jai` `open_user_settings` |
| Settings-proto writes (`PreloadedUserSettings`) batched like `UserSettingsProtoStore.updateAsync` | code | `UserSettingsProtoStore` | `src/discord/settings.jai` |
| Theme map: proto DARKER → `{[UNSET]: DARK, [DARK]: ASH, [DARKER]: DARK, …}` | code | theme enum map | `src/discord/store.jai` |
| Inbox last tab = settings-proto/1 `inbox.current_tab` (field 2) | inferred | fixture `inbox` | `src/discord/inbox.jai`, `settings.jai` |
| "Friends come online" = proto field 7.12, sent explicitly both ways | inferred | fixture `streamer_mode` | `settings.jai` |
| Sound asset hashes, `NotificationSettingsStore` defaults, the "classic" sound-pack remaps | code | `./<name>.mp3` modules, `NotificationSettingsStore` | `src/app/sounds.jai`, `settings_store.jai` |
| Voice defaults: VOICE_ACTIVITY, threshold −60 dB, … | code | `MediaEngineStore` | `src/voice/vad.jai` |
| Notification-level label for "Nothing" in `notification_settings_updated` | guess | search `notifications set to` | `src/discord/guild_settings.jai` |
| "Until I turn it back on" mute sends `selected_time_window: -1`, `end_time: null` | guess | mute config builder | same |

## Gateway, startup, identity

| Rule | Kind | Anchor | fastcord |
|---|---|---|---|
| Identify payload and reconnect behaviour | code | `GatewaySocket._doIdentify`, `_handleHello` | `src/discord/gateway.jai` |
| `installation_id_v3` from READY `apex_experiments.installation` | code | `AuthenticationStore` CONNECTION_OPEN | `gateway.jai` |
| `client_launch_id`; fast-connect.js has its own launch id | code | super-properties module | `src/discord/identity.jai` |
| After READY: op 4 (VoiceStateStore reset), op 41 | code | `VoiceStateStore` | `gateway.jai` |
| op 4 `preferred_region(s)` = RTC latency probe order, top 5 | code | `RTCRegionStore` | `src/discord/actions.jai` |
| Initial page size: `clamp(ceil(1.05 * ceil(max(h-145,400) / (compact ? 65 : 91) * (16 / font_px))), 10, 100)` | code | message fetch limit | `actions.jai` `initial_message_limit` |
| Typing: `TypingStore TYPING_START_LOCAL` timing | code | `TypingStore` | `actions.jai` |
| Quests: application ids of every quest loaded after `/quests/@me` | code | `QuestsStore` | `src/discord/rest.jai` |
| Unverified account loads `affinities/v2/users` instead of premium entitlements on Friends | inferred | fixtures `join_leave_server` vs `open_dm` | `actions.jai` `home_open` |

## Analytics (`/science`)

| Rule | Kind | Anchor | fastcord |
|---|---|---|---|
| Event envelope and `expandEventProperties` decorations, batching and flush delay | code | `expandEventProperties`, analytics tracker | `src/discord/analytics.jai` |
| Events left out because their values can't be produced honestly (`analytics_unknowable`, with reasons) | code | per event | `analytics.jai` |
| Owner / ALL permissions value in `*_member_perms` = 17873661021126655 | code | permissions ALL constant | `src/discord/analytics_events.jai`, `guild_settings.jai` |
| `client_performance_cpu` formatted like `JSON.stringify` of a float | code | — | `analytics.jai` |
| `user_profile_action` only for profiles without bio / pronouns / badges / activity / guild identity (enum values for those lists unknown) | known gap | search `user_profile_action` | `analytics_events.jai` |
| `accessibility_features` (AccessibilityFeatureFlags): media-query bits PREFERS_COLOR_SCHEME_LIGHT 128 / DARK 256 (OS appearance; light when unknown), HIGH_CONTRAST 8 (prefers-contrast: more), FORCED_COLORS 262144, INVERT_COLORS 64; AccessibilityStore bits from its defaults, as fastcord has none of those settings: REDUCED_MOTION 2 = the system's reduce-motion (`prefersReducedMotion` "auto"), FORCED_COLORS_FROM_USER_SETTINGS 524288 (`syncForcedColors` default true); font scale, zoom, spacing, saturation, role style, dark sidebar, profile-theme sync, contrast level, UI density: off | code | `handlePrefersColorSchemeLightChanged`, `handleAccessibilityStoreChanged`, enum `REDUCED_MOTION_FROM_USER_SETTINGS=65536` | `src/discord/analytics.jai` `accessibility_flags`, `src/app/analytics_env.jai` |
| The store bits join on the AccessibilityStore's first change, before the gateway connects (128 on the first pre-connection events, 524416 from `gateway_connected` on); fastcord sends nothing before that, so it always reports them | inferred | fixtures `cold_start`, every `setup` | same |
| OS sources of the media queries: macOS NSWorkspace `accessibilityDisplayShouldReduceMotion` / `…IncreaseContrast` / `…InvertColors` (no forced colors); Windows `SPI_GETCLIENTAREAANIMATION` off = reduced motion, High Contrast = forced colors + contrast more (as Chromium maps them); polled twice a second | inferred (Chromium behaviour) | — | `src/platform/appearance_*.jai` `system_a11y` |
| `client_viewport_width` / `_height` = the window content size in points (CSS px at zoom 100 %, Chrome's innerWidth / innerHeight), reported before the first event and on every resize | inferred | fixtures (1280 x 720 style values) | `src/app/analytics_env.jai` |
| Per-event throttles (`channel_opened` 15 min per channel + `channel_view`, `guild_viewed` per guild, `friends_list_viewed` per tab, `keyboard_shortcut_used` 2 min per shortcut, `ack_messages` unless `ack_manual`, `quickswitcher_opened` 10 s, ...): only the events fastcord sends are listed | code | `throttlePeriod:` / `throttleKeys:` table (AnalyticsTrackingStore module) | `src/discord/analytics.jai` `SCI_THROTTLES` |
| Guild / channel decorations: text = text, announcement, forum, media; voice = voice, stage; `num_voice_channels_active` = the guild's voice states (users); `channel_size_total` = recipients of a private channel, else 0; `channel_hidden` = @everyone overwrite denies VIEW_CHANNEL (a thread: its parent's); perms "0" for private channels | code | `getGuildAnalyticsProperties` / `getChannelAnalyticsProperties` (module with `trackWithMetadata`) | `analytics_events.jai` `aw_guild`, `aw_channel` |
| The launch route's views on READY: `channel_opened` + `guild_viewed` (guild route), dm_list / friends views (Home) | inferred | fixtures' `setup` windows, `cold_start` | `src/discord/actions.jai` READY |
| Thread `channel_opened`: the thread properties first (counts, archived, locked, auto-archive minutes, creation date, can_send_message, parent_channel_type), then the channel properties; split view adds `channel_view` and no `selected_guild_id`; a route source ("Thread Browser") goes last as `location` (the bundle puts it first) | code + inferred | `ThreadAnalytics` (`thread_approximate_member_count`), fixture `threads_browser` | `analytics_events.jai` `analytics_channel_opened` |
| fastcord opens a new thread as the main view: its `channel_opened` has `selected_guild_id`, not `channel_view: "Split View"` | known gap | fixture `threads_browser` | same |
| Our own message is read at once (local ack, nothing sent), except type 46 | code | `ReadStateStore` MESSAGE_CREATE, `SELF_MENTIONABLE_SYSTEM` | `src/discord/store.jai` |
| `ack_messages` (Inbox "Mark As Read"): location `{section:"Inbox", object:"Ack - Inbox Newest Unread Message", object_type:"ack_automatic"}`, `guild_unread_statuses` = `"id,hasUnread,mentions,muted,unreadSetting"` per guild in READY order; tracked when the ack's POST completes | code (format) + inferred (timing, order) | `guild_unread_statuses` chunk | `actions.jai` `ACK_INBOX`, `analytics_events.jai` `analytics_ack_props` |
| Unread setting reported as 1 (all messages) for every guild / channel | guess | `resolveGuildUnreadSetting` | same, `analytics_channel_opened` |
| `notification_action {action:"ACK"}` for each desktop notification still shown when its channel's `MESSAGE_ACK` arrives | inferred | fixture `inbox` (inbox_unreads_mark_read) | `analytics_events.jai` `analytics_notifications_acked` |
| User context menu: `application_command_cache_fetch {miss,size}` twice ~40 ms after every open (as the message menu) | inferred | fixture `friend_nickname` | `src/discord/friend_nickname.jai` |
| Friends tab click: `friends_list_clicked` then `friends_list_viewed` (the view is throttled per tab) | code + inferred | `FRIENDS_LIST_VIEWED` effect; fixture `friend_add_context_menu` | `src/app/view_home.jai` |
| `dm_list_viewed` on the Friends page counts every DM list row as visible (the official counts the virtualized rows on screen) | guess | `DM_LIST_VIEWED` | `src/discord/invites.jai` `friends_page_viewed` |
| DM call shelf loads: `network_action_embedded_activities_fetch_shelf` with `guild_id: ""` for the first load (and the callee's), `null` for the second | inferred | fixture `dm_call` | `src/discord/calls.jai` |

## Pickers, profiles, invites

| Rule | Kind | Anchor | fastcord |
|---|---|---|---|
| Emoji spritesheets, emoji data, search (`EmojiStore.searchWithoutFetchingLatest`) | code | `EmojiStore`, spritesheet modules | `src/app/pickers_emoji.jai`, `pickers_data.jai` |
| GIF picker requests and layout (bundle module 497685 "GIF actions", `GIFPickerSearchResults`, `GIFPickerCategories`) | code | same | `src/discord/expressions.jai`, `src/app/pickers_gif.jai` |
| Full profile requests (`UserProfileModalActionCreators`) | code | same | `expressions.jai`, `view_profile_full.jai` |
| Pins (`ChannelPinsActionCreators.fetchPins`, `ReadStateStore.ackPins`) | code | same | `src/discord/features.jai` |
| Invites (`InstantInviteActionCreators`) | code | same | `src/discord/invites.jai` |
| Invite from the server icon right-click menu uses context location "Guild Header" | guess | not captured | `src/app/view_guild_menu.jai` |
| Inbox "Mark All as Read" = `POST /read-states/ack-bulk` | guess | not captured | `inbox.jai` |
| Thread browser Archived tab sends `thread_browser_tab_changed` | guess | not captured | `view_threads_browser.jai` |
| External-location event body (`scheduled_end_time`, `entity_metadata.location`), Start Event (`PATCH {"status":2}`) | guess | not captured | `src/discord/guild_admin.jai` |
| Declining a DM call sends nothing (dismissed locally) | guess | not captured | `src/discord/calls.jai` |
| Message menu with text selected (desktop): a "Copy" item (copy icon, ⌘C) heads it and the quick-reaction row is hidden (`""===textSelection?quickReactions:null`) | code | `MessageContextMenu`: search `textSelection:` and `id:"copy",label` | `src/app/view_message_actions.jai` `message_menu` |
| Text field right-click menu: Cut and Copy with a selection, Paste always (spellcheck items not implemented) | guess | `textarea-context` (menu chunk not cached) | `src/app/view_misc.jai` `edit_menu` |

## Login and logout

Fixture: `traffic/account_edits.jsonl` windows `logout` and `login_submit`
(tests `parity_logout`, `parity_login_submit`). Bundle anchors: the login chunk
(search `LOGIN_VIEWED`, `useAuthWebsocket`), `AuthenticationActionCreators`
(search `isPasswordAttempt`, `loginMFAv2`, `forgotPassword`, `logout(e){`),
`AuthenticationStore` (search `getMFAMethods(){`, `FINGERPRINT:function`).

| Rule | Kind | Anchor | fastcord |
|---|---|---|---|
| `POST /auth/login` body `{login, password, undelete: false, login_source: null, gift_code_sku_id: null}`, retries 2 | code (body also captured) | `isPasswordAttempt` | `src/discord/auth.jai` `auth_login` |
| A login of 3+ characters matching `/^[-() \d]+$/` is a phone number: the country's dialing code (location-metadata `country_code`, default United States) is prepended; the field shows the country pill | code | `phoneCountryCodes`, `PhoneStore`, `function i(e,t){return"phone"===e` | `auth_login_value`, `DIALING_CODES` |
| `network_action_*` (trackNetworkAction): `{status_code, error_code?, error_message?, url, request_method, ...}`, url without `/api/v9` | code (+ captured for login / logout) | `trackNetworkAction` | `src/discord/analytics_events_auth.jai` |
| From the login attempt (LOGIN) until READY, events carry no `client_uuid` | inferred | fixture login_submit (`network_action_user_login`) | `auth_login_dispatched` |
| Field errors: `errors.<field>._errors[0].message` (or the old `<field>[0]`) under EMAIL OR PHONE NUMBER (`login`/`email`) and PASSWORD; else `message` | code | `oldFormErrors`, `lg("login",u)??lg("email",u)` | `auth_form_errors`, `src/app/view_login.jai` |
| Error rendering: the label turns red and reads "LABEL - message" | guess | not captured | `view_login.jai` `field_label` |
| `captcha_key` in the response: fastcord never shows or solves the captcha; it says "Discord asked for a captcha, which fastcord can't show. Log in with the QR code instead." | fastcord | — | `login_events` |
| MFA: `{mfa: true, ticket, totp, backup, sms, webauthn, login_instance_id}`; methods in the order webauthn, totp, backup, sms; the step opens on the first one | code | `getMFAMethods(){`, `LOGIN_MFA_STEP` | `auth_login_result`, `login_mfa_begin` |
| `POST /auth/mfa/{totp\|backup\|sms}` `{code, ticket, login_source: null, gift_code_sku_id: null, login_instance_id?}`, retries 2, tracked `network_action_user_login_mfa`; backup codes lose their dashes | code | `loginMFAv2`, `mfaType:"backup",data:h.replace(/-/g,"")` | `auth_mfa` |
| SMS slide: `POST /auth/mfa/sms/send {ticket}` on open and on "Resend SMS?", answer `{phone}`; codes of 6 characters | code | `LOGIN_SMS_SEND` | `auth_mfa_sms_send` |
| Backup codes come after "Slow down! Are you sure?" with a 10 s countdown; 8-11 characters | code | `c5J7O0` slide, `Zp=8,i=11` | `view_login.jai` |
| Passkeys / security keys (webauthn MFA, "Or sign in with a passkey", conditional mediation) are not offered: the MFA step starts on the next method, or tells the user to use the QR code | known gap | `authenticatePasswordless`, `isConditionalMediationAvailable` | `login_mfa_begin` |
| Forgot your password?: `POST /auth/forgot {login}` (phone prefix applied), tracked `network_action_forgot_password`; then "Instructions Sent", or "Check your email for a login link" when `method` is `one_time_login` | code | `forgotPassword`, `ONE_TIME_LOGIN` | `auth_forgot`, `login_notice_modal` |
| "Register" opens https://discord.com/register in the browser (the client routes to /register in-app) | fastcord | — | `view_login.jai` |
| "Log in with a token" (a pasted token connects like a launch with a saved token) | fastcord only | — | `view_login.jai` `login_with_token` |
| Login page mount: `login_viewed {login_source: null, authenticated: false, location: "Non-Invite Login Page"}` flushed at once, `GET /auth/location-metadata` (retries 2), the remote auth socket | code + captured | `LOGIN_VIEWED`, `getLocationMetadata` | `auth_login_page_loads` |
| After a logout the page mounts 300 ms after the logout response (route chunk load) | inferred | fixture logout | `auth_after_logout` |
| Logged out: no gateway, no heartbeat session (the super properties lose `client_heartbeat_session_id`), `/science` batches with `"token": null`; the batch holding events queued before LOGOUT still carries the old token | captured | fixture logout | `auth.jai`, `analytics.jai` `analytics_flush`, `identity.jai` |
| Fingerprint: unauthenticated `GET /experiments?with_guild_experiments=true` (X-Context-Properties location = the path, retries 3); its `fingerprint` is kept (persisted as `<state>/fingerprint`) and sent as X-Fingerprint while logged out; `user_fingerprint_changed {old_fingerprint: null, new_fingerprint: <id part>}`; LOGOUT and LOGIN_SUCCESS forget it; a different one later tracks `external_fingerprint_dropped` | code + captured | `FINGERPRINT:function`, `getFingerprint()`, `"fingerprint"` storage key | `auth_set_fingerprint`, `auth_fetch_experiments` |
| X-Fingerprint goes after Content-Type in the header list | inferred | fixture login_submit (DevTools order; no netlog) | `src/discord/headers.jai` |
| Cold start without a token: `/experiments` with context location `/app` and Referer https://discord.com/app, then the login page with Referer https://discord.com/login?redirect_to=%2Fapp | guess | not captured | `auth_cold_start`, `auth_init` |
| Settings > Log Out: confirm "Log Out" / "Are you sure you want to logout?", then `logout("settings")` | code | `LOGOUT_SIDEBAR_ITEM` | `src/app/view_settings_account.jai` |
| `POST /auth/logout {"provider":null,"voip_provider":null}` (token / voip_token undefined on desktop) | code + captured | `logout(e){` | `client_logout` |
| When it settles (any status): `network_action_user_logout {…, logout_source}` and `hotspot_hidden {hotspot_location: "VOICE_PANEL_INTRODUCTION"}` (VOICE_CHANNEL_SELECT without a channel), then LOGOUT | code + captured | `Dw.sF(vR._.VOICE_PANEL_INTRODUCTION)` | `auth_after_logout` |
| `hotspot_hidden` also follows every voice leave in the client; fastcord sends it only on logout | known gap | same | — |
| `multi_account_account_remove {location_section: "Manage Accounts Modal"}` only for the account switcher's "Remove account" (logout_source `multi_accounts_list`); fastcord has no switcher, the library takes the source | code | `MULTI_ACCOUNT_ACCOUNT_REMOVE` | `client_logout` |
| After LOGOUT: `/experiments` from the old route (Referer and context location = old path); components still mounted refetch without a token and get 401: referrals eligibility ×3 (Home route), settings-proto/2 15 ms later from the login page; 401s are ignored | inferred | fixture logout (other routes not captured) | `auth_after_logout` |
| Login page Referer: `https://discord.com/login?redirect_to=<encodeURIComponent(old path)>` | captured | fixture logout | `auth_after_logout` |
| LOGIN_SUCCESS: a new heartbeat session at once (op 41's initialization time is the login's); IDENTIFY's properties still carry the stale id (null where the key was); the gateway opens at once without fast connect, `gateway_connect_reasons: "AppSkeleton"`, presence `"online"`, capabilities 1734653 (the logout cleared localStorage) | inferred | fixture login_submit | `client_login_token`, `gateway.jai` `identify_value` |
| After a login's READY: the login burst replaces the launch tables (READY + 0: survey (Referer /app, `network_action_user_survey_fetch` location `impression_friends`), status page, guild affinities (/app), webauthn credentials (/app), referrals, entitlements, app entitlements, quests, badges, user affinities, promotions, ads decision with `visible_guild_ids`; promotions → app entitlements `exclude_consumed=false`; quests → applications/public; + 2081 ms: library, saved messages, storefront, user offer, checkout recovery, collectibles marketing; + 7774 ms: get-decisions) | inferred | fixture login_submit | `auth.jai` `LOGIN_BURST` |
| `visible_guild_ids` in sidebar order (guilds outside folders first, then the folders') | inferred | fixture login_submit | `sidebar_guild_ids` |
| Not modelled after login: the Friends activity feed (`applications/public?application_ids=<game>`, `games?game_ids`), `session_start_client`, `game_profile_entry_point_available` | known gap | fixture login_submit | `parity_login_submit` allow-list |
| Remote auth v2: `wss://remote-auth-gateway.discord.gg/?v=2`, RSA-OAEP 2048 / e 65537 / SHA-256; `init {encoded_public_key: base64(SPKI)}`; `nonce_proof` answered with base64url of the decrypted nonce (not its hash); fingerprint = base64url(SHA-256(SPKI)), checked against `pending_remote_init`; `pending_ticket` user `/^(\d+):(\d{1,4}):([a-zA-Z0-9_]+):(.*)$/` (avatar `0` = none); `pending_login` ticket → `POST /users/@me/remote-auth/login {ticket}` → `encrypted_token` | code | `useAuthWebsocket`, `pending_remote_init`, `decryptNonce` | `src/discord/remote_auth.jai` |
| Remote auth heartbeats: `{"op":"heartbeat"}` first at random() × `heartbeat_interval` after hello, then every interval; a missing ack reconnects | code | `heartbeat timeout, reconnecting` | `ra_session_loop` |
| A close, error, heartbeat timeout or bad message starts over with a new key pair after Backoff(1500, 30000) (reset by `pending_remote_init`); `cancel` and "Not me, start over" start over at once; the server's `timeout_ms` close refreshes the QR code that way | code | `new w.A(1500,3e4)` | `ra_sessions` |
| QR code: `https://discord.com/ra/<fingerprint>`, qrcode.react 1 (qr.js), level M, 160 px, logo on top; fastcord draws whole-pixel modules | code | module `414121` `level:"M"`, qr.js `getLostPoint` | `src/qr/qr.jai`, `view_login.jai` |
| QR login success: `login_successful {source: "QR Code Login", login_source: null, gift_code_sku_id: null, is_new_user: false, login_method: "remote_auth", login_instance_id: <key fingerprint>}` | code | `login_method:"remote_auth"` | `analytics_login_successful_qr` |
| The client makes the key pair after the socket opens (WebCrypto, tens of ms); fastcord's keygen (BoringSSL without assembly, usually tens to hundreds of ms) runs before the dial so `init` follows the open at once | known gap | `generateRsaKeyPair` | `ra_run_socket` |
| The socket's upgrade request is the gateway's (Chrome's headers, `permessage-deflate` offered); if the server accepts deflate, fastcord inflates what it receives and sends stored DEFLATE blocks (Chrome compresses) | guess | not captured whether the server negotiates it | `src/http/ws.jai` |
| "Document not visible" (reconnect deferred while the window is hidden) is not modelled | known gap | `document is not visible` | — |

