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
| The tool table has only `win32` and `darwin` executables, matched against Node's `process.platform`: on Linux (`linux`) nothing is auto-detected | inferred (from the copied table) | `RunningGameStore`, `streamerTool` | `view_streamer.jai` `STREAMER_OS` |

## Online status

Captured: open_status_menu, set_idle, set_online (no duration). Durations and expiry come from the bundle.

| Rule | Kind | Anchor | fastcord |
|---|---|---|---|
| Account popout group: Edit Profile, then the status row (status name, sublabel = expiry "Until …"); hovering it opens `set-status-submenu`: Online, separator, Idle, Do Not Disturb ("You will not receive desktop notifications"), Invisible ("You will appear offline"); the current status's description is its expiry when it has one | code | `navId:"set-status-submenu"`, intl `tq/fMK`, `zPc6Mc` | `src/app/view_misc.jai` `account_actions`, `status_menu` |
| Idle / DND / Invisible submenu: For 15 Minutes, For 1 Hour, For 8 Hours, For 24 Hours, For 3 Days, Forever (no duration); Online has none; every item `dontCloseOnAction` | code | `duration:15*w.A.Millis.MINUTE`, `nz="forever"` | same, `STATUS_DURATIONS` |
| Expiry text: same day "Until 3:45 PM", next day "Until tomorrow at 3:45 PM", else "Until 10/30/26 at 3:45 PM" | code | intl `ZxxHIO`, `9OFjSe`; `kind:"today"` | `status_until` |
| setStatus: StatusSettings `status`, `status_expires_at_ms` (field 4, fixed64; `now + duration`, omitted for Forever), `status_created_at_ms` kept when the status is unchanged; INFREQUENT_USER_ACTION | code | `statusExpiresAtMs=f`, `n===t&&null!=e.statusCreatedAtMs` | `src/discord/settings.jai` `set_status` |
| `user_status_updated` gains `expire_duration_minutes` (duration / 60000) after the approx_* keys; tracked on every setStatus, even an unchanged status | code | `expire_duration_minutes:null!=A?A/6e4` | `analytics_status_updated` |
| Expiry (CustomStatusManager.manageExpiringStatus, on connect and settings updates, then a timer): a status other than Online whose expiry passed becomes Online with `location: {object: "CUSTOM_STATUS_MANAGER"}` | code | `manageExpiringStatus` | `status_expiry_tick` |
| op 3 after a timed status: same payload as an untimed one (`since: 0`) | inferred | set_idle | `presence_value` |

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
| Shift+Escape (MARK_SERVER_READ): `keyboard_shortcut_used` then, if the open guild has unreads, the guild's unread channels in one `POST /read-states/ack-bulk` and `mark_as_read {"type":"guild"}` (no source). The client also acks the guild's event and onboarding read states, chunks by 100 and jumps to present; fastcord doesn't | code + known gap | `{binds:["shift+esc"],comboKeysBindGlobal:!0` | `src/app/views.jai` `overlays`, `src/discord/guild_settings.jai` `ack_guild` |
| Voice defaults: VOICE_ACTIVITY, threshold −60 dB, … | code | `MediaEngineStore` | `src/voice/vad.jai` |
| Notification-level label for "Nothing" in `notification_settings_updated` | guess | search `notifications set to` | `src/discord/guild_settings.jai` |
| "Until I turn it back on" mute sends `selected_time_window: -1`, `end_time: null` | guess | mute config builder | same |

## Gateway, startup, identity

| Rule | Kind | Anchor | fastcord |
|---|---|---|---|
| Identify payload and reconnect behaviour | code | `GatewaySocket._doIdentify`, `_handleHello` | `src/discord/gateway.jai` |
| Reconnect: close 4004 stops; otherwise `Backoff(1 s, 60 s)`, after more than 4 failures the session is dropped (IDENTIFY); op 7 reconnects at once; op 9 resumes if `d` else identifies; RESUME only with an ACK in the last 3 min; no ACK by the next interval closes 4000 and backs off | code | `_handleClose`, `_handleHeartbeatTimeout`, `_doResumeOrIdentify` | `gateway.jai` |
| Waking from sleep (powerMonitor `resume`): `expeditedHeartbeat(5000)`: heartbeat at once, no ACK in 5 s = heartbeat timeout; if not connected, reset the backoff and connect at once. fastcord sees the wake as a gap of over 15 s between its 1 s timer rounds | code + inferred (detection) | `power monitor resumed`, `expeditedHeartbeat(e){` | `gateway.jai` `gateway_expedited_heartbeat_locked` |
| Not modelled: network online / offline (`networkStateChange(5000 / 15000)`), suspend (IdleStore idles and the client disconnects), lock screen (idle) | known gap | `network detected online.`, `powerMonitor.on("suspend"` | — |
| Idle: the system idle time (`powerMonitor.getSystemIdleTimeMs`, polled every 10 s) over 10 min (`6e5`) dispatches IDLE with idleSince = the last input; AFK at `min(afkTimeout, 10 min)`, afkTimeout default 600 s, so both at once | code | `getSystemIdleTimeMs`, `type:"IDLE",idle:!0,idleSince` | `client.jai` `idle_poll`, `procinfo_*.jai` `system_idle_ms` |
| Presence while idle (`getLocalPresence`): an online status becomes `idle`; `since` = idleSince for every status (0 when active); `afk` = isAFK. SelfPresenceStore recomputes after IDLE and again after AFK: two op 3s per change, the first with the old `afk`; IDENTIFY carries the same presence | code | `S===m.clD.ONLINE&&C>0&&(S=m.clD.IDLE)` | `settings.jai` `presence_value`, `client.jai` `flush_presence`, `gateway.jai` `identify_value` |
| Op 3 is client-limited to 5 per 20 s (later ones wait) | code | `n.length<5?(n.push(l+2e4)` | not needed yet: fastcord sends at most 2 per user action |
| No automatic ack while idle (incoming message, scroll to bottom, channel open); explicit acks (Inbox, banner) still go | code | `"Is idle"` in `shouldAutomaticallyAck` | `actions.jai` MESSAGE_CREATE, `select_channel`; `view_chat.jai` `chat_view` |
| Reconnect IDENTIFY uses the settings status (the gateway keeps a copy) | code | `presence:V.getInitialState()` | `client.jai` `flush_presence` |
| `installation_id_v3` from READY `apex_experiments.installation` | code | `AuthenticationStore` CONNECTION_OPEN | `gateway.jai` |
| `client_launch_id`; fast-connect.js has its own launch id | code | super-properties module | `src/discord/identity.jai` |
| After READY: op 4 (VoiceStateStore reset), op 41 | code | `VoiceStateStore` | `gateway.jai` |
| op 4 `preferred_region(s)` = RTC latency probe order, top 5 | code | `RTCRegionStore` | `src/discord/actions.jai` |
| Initial page size: `clamp(ceil(1.05 * ceil(max(h-145,400) / (compact ? 65 : 91) * (16 / font_px))), 10, 100)` | code | message fetch limit | `actions.jai` `initial_message_limit` |
| Typing: `TypingStore TYPING_START_LOCAL` timing | code | `TypingStore` | `actions.jai` |
| Quests: application ids of every quest loaded after `/quests/@me` | code | `QuestsStore` | `src/discord/rest.jai` |
| Unverified account loads `affinities/v2/users` instead of premium entitlements on Friends | inferred | fixtures `join_leave_server` vs `open_dm` | `actions.jai` `home_open` |
| Linux super properties (IDENTIFY and `x-super-properties`): `os` "Linux", `os_version` = kernel release (`uname -r`), `os_arch`/`app_arch` "x64", no `os_sdk_version`, then `window_manager` "`$XDG_CURRENT_DESKTOP`,`$GDMSESSION`" ("unknown" for unset), `distro` = os-release `PRETTY_NAME` unquoted, `runtime_environment` "native", `display_server` = `$XDG_SESSION_TYPE`, after `browser_version`; `native_build_number` null | guess (no Linux capture) | super-properties module (`getSuperProperties`) | `src/discord/procinfo_linux.jai` `linux_platform`, `identity.jai` `write_base_properties`, `gateway.jai` `put_base_properties` |
| Linux user agent `Mozilla/5.0 (X11; Linux x86_64) … discord/<linux version> Chrome/… Electron/…`, `sec-ch-ua-platform` "Linux"; Linux client version `LINUX_CLIENT_VERSION` (0.0.125: its own version line; the Electron and web build are the macOS baseline's) | guess | `navigator.userAgent` | same |

## Video and Go Live

None of this is captured: the voice gateway and its UDP media are native (not in the DevTools captures),
and no capture of the main gateway has a camera or a stream. Re-check every row with a live camera call
and a Go Live on a test account.

| Rule | Kind | Anchor in the client | fastcord |
|---|---|---|---|
| Camera on/off: op 4 with `self_video` set, otherwise unchanged (mute / deafen toggles keep it) | guess | `VoiceStateStore`, `selfVideo` | `dc.voice_set_state`, `video_call.jai` `send_voice_state` |
| Voice op 12 VIDEO when our video starts / stops: `audio_ssrc`, `video_ssrc`, `rtx_ssrc` (0 when off), one `streams` entry `{type:"video", rid:"100", ssrc, active, quality:100, rtx_ssrc, max_bitrate, max_framerate, max_resolution:{type:"fixed",width,height}}`; SSRCs from READY `streams[0]` | guess (open-source Go Live streamers) | `VIDEO` opcode in the RTC connection | `voice.msg_video`, `voice.set_video` |
| Server op 12 maps `user_id` to `video_ssrc` / each active `streams[].ssrc`; inactive or 0 = stopped | guess | same | `conn.jai` `on_remote_video` |
| Voice op 15 MEDIA_SINK_WANTS `{"any":100}` after SESSION_DESCRIPTION (all video at full quality) | guess | `MEDIA_SINK_WANTS` | `conn.jai` `MSG_MEDIA_SINK_WANTS_ANY` |
| Video codec = SESSION_DESCRIPTION / SESSION_UPDATE `video_codec`; H264 (PT 105) and H265 (PT 103) are sent and decoded; VP8 / AV1 frames are dropped | guess | `CODECS_JSON` | `voice/video.jai`, `video_call.jai` |
| Video RTP: 90 kHz, marker on the frame's last packet, RFC 6184 mode 1 (single NAL / FU-A) and RFC 7798 FU, 1100-byte payloads, one-byte extension playout-delay (id 5) = 0, no RTX, no NACK handling; keyframes on PLI / FIR; receivers send a PLI (≤ 2/s) until a keyframe | guess | WebRTC defaults | `voice/video.jai`, `conn.jai` |
| DAVE video frames: 4-byte start codes; clear ranges per libdave `codec_utils` (start codes, H.264 slice NAL header + first three slice-header exp-Golomb values, H.265 VCL 2-byte header, other NAL units whole) | code (libdave) | `ProcessFrameH264`, `ProcessFrameH265`, `BytesCoveringH264PPS` | `voice.dave_clear_ranges`, `voice_dave.encrypt_frame` |
| Go Live: op 18 `{type:"guild"/"call", guild_id, channel_id, preferred_region:null}`; op 20 `{stream_key}` to watch; op 19 `{stream_key}` to end ours or stop watching; keys `guild:<g>:<c>:<u>` / `call:<c>:<u>` | guess | `STREAM_CREATE`, `STREAM_WATCH`, `STREAM_DELETE` | `dc.stream_create`, `dc.stream_watch`, `dc.stream_delete` |
| A stream's voice connection: STREAM_CREATE `rtc_server_id` as `server_id`, STREAM_SERVER_UPDATE endpoint + token, our voice session id; IDENTIFY with `streams:[{type:"screen",rid:"100",quality:100}]`; the streamer sends no audio (no soundshare yet) | guess | same | `dc.stream_server_info`, `voice.Voice_Server_Info.stream` |
| Camera 1280x720 30 fps 2.5 Mbps; screen ≤ 720p 30 fps 4 Mbps (the non-Nitro limit) | guess | — | `video_call.jai` |
| Clicking a voice channel joins it and opens its call view (no separate channel select) | inferred | — | `views.jai` `join_voice` |
| Call view: black, 16:9 tiles with 8 px gaps in the grid that makes them largest, last row centered; avatar on the banner / accent / dominant color, green 2 px border while speaking; streams first with a LIVE badge and "Watch Stream"; click focuses a tile | inferred (screenshot) | — | `view_call.jai` |

## HTTP, retries, rate limits

For features that load or send (and their retry / loading states): every REST call goes through
`api_call` (`src/discord/rest.jai`), which already does what HTTPUtils does. A feature only picks the
call's `retries` (the bundle's value for that call: search the endpoint) and, for user-retried sends,
`retry_429`. Never add a retry loop of your own.

| Rule | Kind | Anchor | fastcord |
|---|---|---|---|
| `retries: N` retries only network errors (not aborts) and statuses 502, 504, 507, 522, 523, 524, 598, 599; each retry waits `Backoff()` (500 ms min, 5 s max, jitter: `current += 2*current*random()`), carries `X-Failed-Requests: <n>` and skips the URL queue (calls `I`, not `g`). Other 4xx / 5xx are never retried by HTTPUtils | code | `E=new Set([502,504,507,598,599,522,523,524])`, `X-Failed-Requests` | `ratelimit.jai`, `rest.jai` `api_call` |
| Per-call retry counts in the bundle: `retries:3` ×26, `:2` ×13, `:1` ×12, `:0` ×3 (search the endpoint constant to find a call's) | code | `retries:` | per call site |
| 429 / 503: hold keyed by the request URL, `now + max(Backoff(1 s, 60 s).fail(), retry_after*1000)`, retry_after = `parseInt(Retry-After)` (whole seconds) else body `retry_after` (float s) else 5; a longer existing hold is kept but its backoff still fails | code | `retryAfterTimestamp`, `cleanupRequestEntry` | `ratelimit.jai` `rate_note_response` |
| Requests to a held URL queue FIFO; the hold's timer releases one (or drops the entry when none waits); each later non-429 response for that URL after expiry releases the next. No burst after a 429 | code | `rateLimitExpirationHandler`, `makeRequest: queueing` | `ratelimit.jai` `rate_acquire` |
| HTTPUtils does not retry a 429 itself; callers that do (MessageQueue for sends) wait `retry_after` and re-enter the queue. `failImmediatelyWhenRateLimited` calls reject at once with the hold's remaining seconds | code | `failImmediatelyWhenRateLimited` | `rest.jai` `retry_429` |
| No proactive use of `X-RateLimit-*` headers | code | (absent) | — |
| Message send failure: 4xx with code SLOWMODE_RATE_LIMITED sets the slowmode cooldown from body `retry_after`; automod / explicit-content codes have their own dispatches; a 429 shows no Clyde error | code | `Failed to send message`, `SLOWMODE_SET_COOLDOWN` | not modelled |
| Attachment PUT (CloudUpload, desktop): up to 12 attempts, 1 h timeout, `Backoff()` between them, only for retryable errors; from the 2nd attempt a `Content-Range: bytes */*` status check (308 + `Range` gives the resume offset) and a fresh upload URL when stale | code | `uploadFileWithResumption`, `getResumePosition` | known gap: `upload_put` tries 3 times, no resume check |

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
| Ack timing (`ReadState.ack`): the read state moves at once; one POST timer per channel, 3 s, or 0 when the channel had mentions or the ack is `immediate`; later acks before it fires only change the message id (no restart, no shortening, the first ack's location kept); leaving the channel neither cancels nor flushes it | code | `o\|\|a?0:3e3`, `outgoingAckTimer=setTimeout` | `actions.jai` `ack_message`, `flush_due_acks` |
| Automatic acks track `ack_messages` (15 min throttle): incoming message `{Channel, "Ack - Incoming Message", ack_automatic}`; scrolled to the bottom / opened `{Channel, "Ack - Channel Scroll", ack_automatic}`; on the frame the window regains focus `{Channel, "Ack - Window Focus", ack_automatic}`. Scroll and focus acks carry no message id, so they ack the read state's `lastMessageId` (the channel's newest) | code | `ACK_INCOMING_MESSAGE="Ack - Incoming Message"`, `ACK_WINDOW_FOCUS=`, `ACK_CHANNEL_SCROLL=` | `actions.jai` `ACK_*`, `on_channel_page`; `view_chat.jai` `chat_view` |
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
| Member join (type 7) text: 13 lines picked by the message's snowflake time (ms) mod 13, in the bundle's order | code | `getSystemMessageUserJoin:function(e)` | `src/app/view_chat.jai` `system_notice` |
| "Wave to say hi!" under a member join is not implemented | known gap | `getSystemMessageUserJoin` | — |
| New member sprout after the author's name: member joined ≤ 7 days ago, no DID_REJOIN flag, not a bot, guild ≥ 7 days old; tooltip "I'm new here, say hi!" (fastcord: no popout) | code | `},"new-member")`, module with `maxDaysOld:7` | `view_chat.jai` `new_member_badge` |
| Invite links in messages get a card (one per distinct code, none with SUPPRESS_EMBEDS), resolved once per code like the embed's `resolveInvite(code, undefined, {inviteInstanceId})`: `invite_opened` {invite_code, invite_instance_id = "<message id>:<code>"}, `GET /invites/{code}?with_counts&with_expiration&with_permissions` (no `inputValue`), then `network_action_invite_resolve` without `location` (so no `resolve_invite`) | code | `function h(e,t,n){let{baseCode:c`, module 21599 `_U` | `src/discord/invites.jai` `invite_preview` |
| `network_action_invite_resolve` on failure: `resolved:false`, `code`, `authenticated`, `user_banned`, `user_is_member:false`; the null/undefined fields (`invite_type` among them) are left out | guess | same | same |
| Resolve failure: banned (40007) or expired, never retried; card views "Resolving Invite", "You've been invited, but" / "You sent an invite, but" + "Invalid Invite" + "Ask for a new invite" / "Uh-oh. Looks like you've been banned." / "Try sending a new invite" | code | `INVITE_RESOLVE_FAILURE:_`, `function di(e)`, `function oU(` | `src/app/view_invites.jai` `invite_card` |
| Card: icon, name, "N Online" / "N Members", "Est. <Mon YYYY>" (guild id time), "Join Server" / "Go to Server" | code (strings) + guess (layout, plain banner) | `zb2Q56`, `IRoQXr`, `eb9gDG` | same |
| Accept (`acceptInvite`): body `{"session_id","invite_instance_id"}`, context = location, location_guild_id, location_channel_id, location_channel_type, invite_instance_id; locations "Invite Button Embed" (card) and "Desktop Invite Modal" (modal); the GUILD_CREATE opens the invite's channel | code (body, locations) + guess (instance id in the embed's context: getAcceptInviteContext not found) | `acceptInvite(e){var t`, `getInviteContext("Desktop Invite Modal"` | `invites.jai` `join_invite_preview`, `accept_parts` |
| Errors stay in their widget (no toast): a failed accept sets the invite to ERROR (INVITE_ACCEPT_FAILURE), so the card shows "You received an invite, but..." (or "You sent...") with module 4274 `g`'s title/description for 30001 / 30019 / 400002, else "Invalid Invite" + the server's message; the modal shows module 4274 `d`'s line above its button (30001, 30019, 50095, 40069, else "Unable to accept invite"). The age-gate codes are not mapped | code + known gap | `INVITE_ACCEPT_FAILURE:function`, `INVITE_MODAL_ERROR`, module 4274 | `view_invites.jai` `invite_error_info`, `invite_modal_error` |
| A click on an invite link: a guild we're in (and the invite resolved) opens at the invite's channel; otherwise INVITE_MODAL_OPEN. fastcord does not re-resolve with "Markdown Link" (the card already resolved it), so no `resolve_invite` | code + known gap | `resolveInvite(n,"Markdown Link",{inviteInstanceId:i})` | `view_invites.jai` `invite_link_clicked` |
| Invite modal: dismissing (X, Escape, outside, "Okay") sends `invite_accept_dismissed` {invite_code, guild_id}; closing after a join sends nothing. Layout (icon, "You've been invited to join", name, counts, "Accept Invite"), the "Invite Invalid" view and the missing join settings (nickname, DMs) are guesses: the modal chunk wasn't cached | code (event) + guess | `INVITE_ACCEPT_DISMISSED,{invite_code:e,guild_id:t}` | `view_invites.jai` `invite_accept_overlay` |
| Event invite links (`discord.gg/<code>?event=<id>`): resolve adds `guild_scheduled_event_id` after `with_expiration`, before `with_permissions` (query order `inputValue, with_counts, with_expiration, guild_scheduled_event_id, target_channel_id, target_message_id, with_permissions`); the event card replaces the guild card while `guild_scheduled_event` is set and not completed / canceled | code | `let I={inputValue:n?.inputValue,with_counts:!0`, `let s="event",l="channel",o="message"` | `src/discord/invites.jai` `invite_preview`, `src/app/view_invites.jai` |
| Event card: start ("Starting in Nm", "Happening Now" external / "Live Now" voice), creator avatar, interested pill, name, description, then guild icon, name and place. The count is `getUserCount` (`GET .../users/counts`), never the invite's `user_count`: 0 until it arrives; fastcord asks only inside the guild. No cover image, "Starting soon", "Ends", guild badge or tooltips | code + known gap | `{name:n.name,description:n.description??void 0,descriptionClassName`, `GUILD_EVENT_USER_COUNTS:(e,t)=>` | `src/app/view_events.jai` `event_invite_card`, `guild_admin.jai` `event_ask_counts` |
| Event card button: outside the guild Join (accepts); inside: Interested before the start, live external "View Details" (no handler; fastcord opens Events), live voice "Go To Channel" when we're in it else Join (the invite's channel), ended "Event is over". Clicking the card opens the event details (fastcord: the Events list); recurring events' series picker not implemented | code + guess (View Details, card click) | `return u?s?d?(0,i.jsx)(m.$,{text:L.intl.string(L.t.GoCQxU)` | same |
| Text field right-click menu: Cut and Copy with a selection, Paste always (spellcheck items not implemented) | guess | `textarea-context` (menu chunk not cached) | `src/app/view_misc.jai` `edit_menu` |

## Message actions: reactions, Mark Unread, pins

| Rule | Kind | Anchor | fastcord |
|---|---|---|---|
| Reactions are predicted: an optimistic `MESSAGE_REACTION_ADD/REMOVE` is dispatched before the request, and the request goes at once (no per-message/emoji queue: add → remove sends PUT then DELETE right away) | code | `optimistic:!0,colors:`, `"MESSAGE_REACTION_ADD",e,t,n,{burst:O,colors:y}` | `src/discord/actions.jai` `add_reaction`, `reaction_send` |
| Our own add / remove is idempotent (`addReaction` returns the reaction unchanged when `me` is already set; `removeReaction` keeps the count when `me` is clear), so the gateway echo of a predicted change does nothing; a quick add → remove shows the add echo briefly, then the remove echo, as officially | code | `addReaction(e){let t=arguments`, `removeReaction(e){` | `src/discord/store.jai` `store_reaction` |
| In a DM another user's add doesn't grow a count they already fill (`isDMChannel`); burst reactions move only `burst_count` | code | same | same |
| Failure: 429 → retried once after Retry-After; 403 → rolled back (TOO_MANY_REACTIONS shows "We appreciate the enthusiasm, but...", REACTION_BLOCKED shakes the app); any other failure (network included) → retried once at once, then rolled back. fastcord rolls back but shows neither the modal nor the shake | code + known gap | `function S(e,t,n){let{headers:i,status:r,body:a}=e;if(429===r)` | `actions.jai` `reaction_result` |
| A 429 followed by a non-429 failure: officially rolled back; fastcord's api_call does the 429 retry itself, so it retries once more | known gap | same | same |
| Adding a normal reaction where we have the burst one (or the reverse) sends nothing ("Oops!" modal; fastcord sends nothing, no modal) | code | `userHasReactedWithEmoji` | `add_reaction` |
| Locations: reaction pill and the reaction picker opened from the "+" after the reactions = `Message Inline Button`; hover bar quick reactions = `Message Hover Bar` (toggle: remove when we reacted); context menu quick reactions = `Message Context Menu`; the picker from the toolbar / menu "Add Reaction" = `Message Reaction Picker` | code | `MESSAGE_INLINE_BUTTON`, `MESSAGE_HOVER_BAR`, `location:t1.qN.MESSAGE_REACTION_PICKER` | `src/app/view_message_actions.jai` `react`, `view_chat.jai`, `pickers_emoji.jai` |
| Mark Unread: `POST /channels/{c}/messages/{before}/ack` `{"manual":true,"mention_count":n}` (no token, retries none), before = the newest loaded message older than the target, else the target's previous millisecond; n = loaded messages after it that would notify (every message in a private channel; in a guild @me / @everyone, suppress settings and role mentions not modelled); no telemetry of its own | code (+ guess for the mention test) | `new d.A("markUnread")`, `body:{manual:!0,mention_count:m}` | `src/discord/features.jai` `mark_unread` |
| The read state moves only on the `MESSAGE_ACK` echo; `manual` holds the open channel unread (no auto-ack) until it is left, and drops the pending outgoing ack | code | `function e1(e){let{channelId:t,messageId:n,manual:i,newMentionCount:r}` | `store.jai` MESSAGE_ACK, `actions.jai` `select_channel`, `view_chat.jai` |
| Menu: "Mark Unread" for any channel but a locked archived thread (fastcord: always); "Pin Message" / "Unpin Message" for user messages (types 0,19,20,23,26,41,45,47,68) not failed, in a private channel or with PIN_MESSAGES + READ_MESSAGE_HISTORY, not voice / stage / media threads; group order Copy Text, Pin, Apps, Mark Unread, Copy Message Link; shift skips the confirmation | code | `id:"mark-unread"`, `id:"pin",action:function(e){e.shiftKey`, `USER_MESSAGE:new Set` | `src/discord/permissions.jai` `can_pin_message`, `view_message_actions.jai` |
| Pin: `PUT /channels/{c}/messages/pins/{m}`, unpin `DELETE` same (no body); confirmations "Pin It. Pin It Good." (primary, "Oh yeah. Pin it") and "Unpin Message" (critical, "Remove it please!", shift protip), each with a message preview; failures "Error" / "The Pin Is Stuck!" (fastcord: Okay only, no Try Again, no TOO_MANY_PINS text) | code | `PIN:(e,t)=>`, `confirmPin:function`, `confirmUnpin:function` | `features.jai` `pin_message`, `view_message_actions.jai` `confirm_modal`, `view_threads.jai` |
| The pinned flag, the type 6 system message and the pins list follow from the gateway (MESSAGE_UPDATE, MESSAGE_CREATE, CHANNEL_PINS_UPDATE); nothing is predicted | inferred | — | `store.jai`, `view_chat.jai` `system_notice`, `view_pins.jai` |
| "N new messages since <time>" bar: counts the messages after the read marker the channel was opened with (the "NEW" divider's), shown while that divider is above the view or Mark Unread holds the channel; the channel is still acked underneath. Marker re-read on every visit. The time format and "50+" cap are guesses | guess | not captured | `view_chat.jai` `new_messages_bar`, `views.jai` `go_to` |
| Bar "Mark As Read": `ack(channel, {section:"New Messages Banner", object:"Mark Channel as Read Button", objectType:"ack_manual"})` (the normal ack request, plus `ack_messages` with that location); the rest of the bar jumps to the first new message (`jumpToMessage` at `ackMessageId`, offset 1). fastcord also drops the divider | code (+ guess for the divider) | `NewMessagesBarJumpToNewMessages_`, `NEW_MESSAGES_BANNER,object:` | `actions.jai` `ACK_NEW_MESSAGES_BANNER`, `view_chat.jai` `new_messages_bar` |

## Message rendering

| Rule | Kind | Anchor | fastcord |
|---|---|---|---|
| Consecutive `> ` lines are one blockquote (one bar down all its lines, wrapped ones included); `>>> ` quotes the rest of the message | guess (matches a screenshot of the client) | — | `markdown.jai` `md_parse`, `view_chat.jai` `quote_bar_draw` |
| Forward = `message_reference.type` 1 (`MessageReferenceTypes.FORWARD`): no reply preview; content, attachments, embeds, stickers come from `message_snapshots[0].message`, under "Forwarded" behind a quote bar, with "#channel • time" of the original below (jumps there); a forward can't be edited | code (type) + guess (layout) | `messageReference?.type===D.SH7.FORWARD` | `store.jai` `parse_message_fields`, `view_chat.jai` `forward_block` |

## Composer emoji

The autocomplete's type definitions (sentinel, query rules, row layout) live in a
chunk the test profiles had not cached; only the store search and the analytics
module were read.

| Rule | Kind | Anchor | fastcord |
|---|---|---|---|
| Emoji autocomplete search = `EmojiStore.searchWithoutFetchingLatest` (same as the picker), `maxCount` 10 unlocked results (`queryEmojiResults`, constant `rs7` = 10); locked results are counted, not listed | code | `queryEmojiResults(e){`, `getSearchResultsOrder` | `src/app/emoji_autocomplete.jai`, `pickers_emoji.jai` `emoji_search` |
| Usable custom emoji: unavailable → locked; without Nitro only the current guild's non-animated ones (none in DMs). `USE_EXTERNAL_EMOJIS` and role-restricted emoji are not checked | code (picker rule) + known gap | `getEmojiUnavailableReason` | `pickers_emoji.jai` `custom_locked` |
| `channel_autocomplete_open` when the popup goes from hidden to shown: channel then guild decorations, `autocomplete_type` "EMOJIS_AND_STICKERS", `num_emoji_results`, `num_locked_emoji_results`, `num_sticker_results` (0); no `game_mentions_available` | code (fields) + inferred (order, from the MENTIONS captures in `inbox`) | `CHANNEL_AUTOCOMPLETE_OPEN,{` | `src/discord/analytics_events.jai` `autocomplete_emoji_open` |
| `channel_autocomplete_selected` on a pick: `selection_type` "EMOJI", `emoji_id` (custom only), counts, `emoji_name` = the emoji's name, `is_custom`, `is_animated` | code (fields) + guess (`emoji_name`, `selection_type` values) | `CHANNEL_AUTOCOMPLETE_SELECTED,{` | same, `autocomplete_emoji_selected` |
| Trigger: a word starting with ':' plus 2+ non-space, non-':' characters before the caret; Up/Down wrap, Tab/Enter pick, Escape hides until the query changes; the first row starts selected | guess | — | `emoji_autocomplete.jai` |
| A pick inserts the emoji plus a space; unicode in the user's skin tone, custom as `<:name:id>` / `<a:name:id>` (the composer shows it as the image) | guess | — | same, `pickers_emoji.jai` `emoji_item_text` |
| Typing the closing ':' of a known `:name:` converts it in place (no space, no skin tone, no analytics); `:name:` left in the text converts on send. Unicode names win over custom ones (the client renames clashing custom emoji `name~1`) | guess | `getDisambiguatedEmojiContext` | `emoji.jai` `emoji_for_name`, `emoji_convert_shortcodes` |
| Stickers are not offered in the emoji autocomplete (the client's EMOJIS_AND_STICKERS also lists matching stickers) | known gap | — | — |

## Composer mentions

| Rule | Kind | Anchor | fastcord |
|---|---|---|---|
| Trigger: the word at the caret starts with '@' (no minimum length) | code | `e5={sentinel:"@"` | `src/app/mention_autocomplete.jai` |
| Rows: members, divider, @everyone / @here, roles; 10 rows shared (`rs7`). Members: joined and able to VIEW_CHANNEL; prefix of username, global name or nick, sorted by name; with no query the channel's recent authors. @everyone / @here only in guilds with MENTION_EVERYONE; roles if mentionable (all with MENTION_EVERYONE), not @everyone | code | `function eC(e){let{query:t,members:n,limit:i`, `MENTION_EVERYONE:()=>({test:"everyone"` | same, `mention_items` |
| Not implemented: diacritic folding and the fuzzy (subsequence) member and role matches that fill leftover rows, match-sorter role order, `@game` / `@time` rows, "Options…" / "Roles…" headers, the role colour dot (fastcord colours the name), mentions as pills in the composer | known gap | same | — |
| Header "Members" / "Members matching @q"; rows: 24 px avatar with status, name, username right; role rows "Notify users with this role who have permission to view this channel.", @everyone "Notify everyone who has permission to view this channel.", @here "Notify everyone online who has permission to view this channel." | code | `/91tbr` | same |
| A pick inserts "@username " / "@Role " (trailing space); on send `@username` of a member (recipient in DMs) becomes `<@id>` and `@Role Name` `<@&id>`, outside code | code (insert) + guess (send-side parse) | `addSpace:n=!0` | same, `mentions_convert` |
| Up/Down wrap, Tab/Enter pick, Escape hides until the query changes | inferred | — | same |
| Member search: op 8 `{guild_id:[g], query: lowercased, limit: 10, presences: true}` after the query is still for 200 ms, once a minute per guild and query (not for an empty query) | code (+ guess: empty query) | `setTimeout(()=>{let i=[];function r(e){i.push(e.id)}` | `src/discord/actions.jai` `search_guild_members` |
| `channel_autocomplete_open` (`MENTIONS`, emoji counts 0, `game_mentions_available` true) on show; `channel_autocomplete_selected` (`selection_type` "MENTION", `emoji_name` "", false flags) on a pick | code + captured (fixture `inbox`) | `CHANNEL_AUTOCOMPLETE_OPEN,{` | `analytics_events.jai` `autocomplete_mentions_open`, `autocomplete_mention_selected` |
| Popup look: above the form with an 8 px gap, header "EMOJI MATCHING :query", 32 px rows with a 20 px emoji, `:name:` and the custom emoji's guild name on the right | guess | — | `emoji_autocomplete.jai` |
| Unicode emoji in any text (messages, composer, names, statuses) draw as the bundled Twemoji svg (`/assets/<hash>.svg`), 1.375em, margin `0 .05em 0 .1em`; inline code keeps the system font; ™ © ® stay text | code (URLs, no-image set) + guess (sizes) | module 350593 `getURL` | `emoji.jai` `emoji_split_text`, `emoji_text_spans` |
| Jumbo (emoji-only, ≤ 27): images 48 px (`.emoji.jumboable` 3rem), spaces between keep the text size | guess | — | `src/app/view_chat.jai` |

## Media in messages

| Rule | Kind | Anchor | fastcord |
|---|---|---|---|
| Inline attachment image URL: an animated source (GIF) gets no `format` (the proxy sends the GIF); others `format=webp` + `width`/`height` | code | `getSrcWithWidthAndHeight`, `getFormatQuality` (`srcIsAnimated`) | `src/app/images.jai` `attachment_image_url` |
| GIFV embeds (Tenor, Klipy) play `video.proxy_url` muted and looping, poster = thumbnail; only while on screen | inferred | embed `"type":"gifv"` in `traffic/gif_send.jsonl` | `src/app/view_media.jai` `media_box` |
| Embeds with a proxied `video` (`proxy_url` on the media proxy, e.g. FxTwitter) draw the video in the card (max 400x300, poster = thumbnail, no side thumbnail) and play it on click with sound; YouTube's iframe `video.url` isn't playable | inferred (screenshot of the official client) | `embedVideo`, `renderVideo` | `src/app/view_media.jai` `embeds_view`, `video_player` |
| Masked links `[text](url)`: text with balanced brackets on one line, url http(s), optional `<>` and a `"title"`; the text keeps its inline styles; not decorated in the composer | inferred (simple-markdown's link rule) | `maskedLink`, `\[((?:\[[^\]]*\]` | `src/app/markdown.jai` `masked_link` |
| Video player: poster + centre play button and a control bar (play/pause, `0:00 / duration`, seek, volume, fullscreen) before playing; while playing the bar shows only on hover; the volume slider pops out on hovering the speaker; double-click toggles fullscreen; one volume for all videos | inferred (official client screenshots) | `mediaBarInteraction`, `VolumeButton` | `src/app/view_media.jai` `video_player` |
| Embeds sharing a `url` merge: the first card takes the later embeds' images as a mosaic (2 side by side, 3 = one tall + two stacked, 4 = 2x2, cropped) | inferred | `getEmbedGroup`, `mosaic` | `view_media.jai` `embeds_view` |
| Non-proxied video embeds (YouTube) show the thumbnail large with a play button; fastcord opens `embed.url` (the client plays the iframe in place) | inferred | `EmbedVideo`, `renderVideo` | `view_media.jai` `embeds_view` |
| Embed side thumbnail: fit in 80x80 keeping its aspect | inferred (IMDb screenshot) | `embedThumbnail` | `view_media.jai` `embeds_view` |
| Media context menu: Copy Image if the URL's extension is jpg/jpeg/jfif/png/webp/avif, Save Image for those + gif/tiff/bmp (or none), both only for Discord-hosted media; then Copy/Open Link, "Image Link" for cdn.discordapp.com png/jpg/webp/avif/bmp/svg, "Media Link" for other image/gif/mp4/webm/mov URLs | code | `"copy-image"`, `"save-image"`, `"copy-native-link"`, `canCopyImage`, `canSaveImage` | `view_media.jai` `media_menu` |
| Copy/Save Image fetch the `XW` URL: media.discordapp.net → cdn.discordapp.com, drop width/height/quality/size/format, add `format=png` without an extension | code | module 803316 (`XW`) | `view_media.jai` `media_action` |
| Save Image writes to ~/Downloads without a dialog; a GIFV video offers only the link items; the items stand in their own menu (the client appends them to the message menu) | guess | `NativeUtils.saveImage` | `view_media.jai` |

## Tray (Windows)

| Rule | Kind | Anchor in the client | fastcord |
|---|---|---|---|
| Closing the window hides it to the tray (the client's "Minimize to Tray", on by default; fastcord has no setting); a left click on the tray icon shows it; the right-click menu has Open and Quit (the client's also has Mute, Deafen, voice settings and update check); the icon gets a red dot while there are unread mentions | guess | desktop core `app.asar` (not the web bundle) | `platform_windows.jai` `tray_menu`, `set_badge` |

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


## Layout: scrollbars, column borders, resizable columns

| Rule | Kind | Anchor in the client | fastcord |
|---|---|---|---|
| Scrollbars are the scroller CSS's webkit ones (Electron has `::-webkit-scrollbar`): `.thin` 8px, thumb inset 2px (border, `background-clip:padding-box`), radius 4px, `--scrollbar-thin-thumb`; `.auto` 16px, track and thumb inset 4px, radius 8px, `--scrollbar-auto-track` / `--scrollbar-auto-thumb`; thumb `min-height:40px`; `.fade` hides thumb and track until the scroller is hovered | code | CSS `.scrollerBase_`, `.thin_`, `.auto_`, `.fade_` | `src/ui/core.jai` `scrollbar` |
| Thumb length `view * view / content` (min 40); pressing the track pages 87.5% of the view, repeating after 250 ms then every 50 ms until the thumb reaches the pointer | code (Chromium source) | `ScrollableArea::PageStep` `kMinFractionToStepWhenPaging`, `ScrollbarTheme` autoscroll delays | same |
| Which scrollers are `.auto` (chat, settings content) and which `.thin` + fade (everything else); the guild rail shows none | guess | — | `view_chat.jai`, `view_settings_prefs.jai`, `view_misc.jai`, `view_voice_settings.jai`, `view_rail_folders.jai` |
| Member list column: 1px `--border-subtle` left border (`border-inline-start`) before the 264px list (`--custom-member-list-width`); search results: 1px `--app-frame-border` left border only | code | CSS `.container_` with `.membersWrap_`; `.searchResultsWrap_` | `view_home.jai` `members_column`, `view_search.jai` |
| Channel sidebar drag-resize: width is `--custom-guild-sidebar-width` (guild rail included, default 375), clamped 264..432, 4px handle at its right edge (`ew-resize`, `--background-mod-strong` on hover/drag); saved to localStorage `resizable-sidebar-width-2` and `channel_sidebar_resized {width}` tracked when the drag ends | code | `minDimension:264,maxDimension:432`, `CHANNEL_SIDEBAR_RESIZED`, `.sidebarResizeHandle_` | `views.jai` `resize_handle`, `settings_store.jai` `sidebar_width`, `dc.track_channel_sidebar_resized` |
| Not copied: the handle's 0.1 s delayed colour fade, the overdrag stretch, `e-resize`/`w-resize` cursors at the limits, arrow-key resizing | known gap | same | — |
| Member list drag-resize (224..400, left edge, saved as `member_list_width`): the official member list is a fixed width; added on request | guess | — | `view_home.jai` `members_column` |

## Loading states and request feedback

| Rule | Kind | Anchor in the client | fastcord |
|---|---|---|---|
| A failed message page (`LOAD_MESSAGES_FAILURE`, once `api_call` has used the endpoint's `retries`) sets the channel's `error` and stops loading; the UI adds no retry of its own. A bar reads "Messages Failed To Load" with "Try Again"; while the retry runs, `PULSING_ELLIPSIS` replaces "Try Again" | code | `LOAD_MESSAGES_FAILURE:function`, string `1zUvlw`; component with `"1zUvlw"` and `PULSING_ELLIPSIS` | `view_chat.jai` `history_failed_bar`, `history_retry`; `rest.jai` `Message_List.failed` |
| Older pages are not re-requested by scrolling after a failure (only Try Again) | guess | — | `message_list` (`older` gate) |
| A failed jump (`around=`) shows the same bar | guess | — | `features.jai` `apply_around` |
| Bar colour (danger red), 32px, under the header | guess | — | `history_failed_bar` |
| Loading placeholders (first page, older history, DM list, friends, member list, own user panel before READY): grey static shapes, no shimmer | guess (shape only) | — | `requests.jai` `skel`, `view_chat.jai` `skeleton_message` |
| A button waiting on its request shows `PULSING_ELLIPSIS` in place of its label and ignores presses (Button `submitting`) | code | `PULSING_ELLIPSIS`, Button `submitting` | `requests.jai` `req_button` |
| Add Friend page: failure text "Hm, didn’t work. Double check that the username is correct." (generic; the client picks a per-error-code text) under a red field; success "Success! Your friend request to **name** was sent." under a green field | code (strings `paDJBM`, `Rtl1Ep`); per-code texts not ported | `sendRequest`, `RELATIONSHIP_ALREADY_FRIENDS` | `view_home.jai` `add_friend_view` |
| Other failed requests: a red toast "Something went wrong. Try again." (429: "You're doing that too fast. Try again in a moment.") for 5 s; the client shows a "Friend request failed" alert for relationship errors | guess (toast); code (alert, `6moJ8s`) not ported | `6moJ8s` | `requests.jai` `req_toast` |


## Spoilers and scrollbar fade

| Rule | Kind | Anchor in the client | fastcord |
|---|---|---|---|
| A `||spoiler||` run is one block (`--spoiler-hidden-background`, text and emoji hidden); a click reveals the whole run (`--spoiler-revealed-background`) and is not followed as a link; revealed state lasts while the message is kept | inferred | `spoilerContent_`, `hidden_` | `view_chat.jai` `spoiler_revealed`, `handle_span_clicks` |
| Scrollbars fade (overlay style): shown while scrolling, held, or with the pointer over the bar's strip (thin ones also while the scroller is hovered), then hidden after 1 s with a 0.25 s fade. The official chat scroller (`.auto`) is always visible; changed on request | guess | — | `src/ui/core.jai` `scrollbar` |
| Message type 67 (FRIEND_REQUEST_ACCEPTED) renders as a notice: "You accepted <name>'s friend request." when you sent it, "<name> accepted your friend request." otherwise, with " They said: / You said: <note>" when content is set; green icon; DMs only | code | `FRIEND_REQUEST_ACCEPTED]:function`, strings `S6PRsh`, `H/9Tlj`, `IquUXd`, `ZOZy2q` | `view_chat.jai` `system_notice` |
| While the chat scrollbar's thumb is dragged, the content height from the grab is kept; history loaded or rows measured mid-drag apply on release | inferred | — | `src/ui/core.jai` `scrollbar` |
| Group DM system messages render as notices: 1 "<a> added <b> to the group." (green arrow), 2 "<a> removed <b> from the group." / "<a> left the group." (red arrow; b = first mention), 4 "<a> changed the group name: <name>." / "removed the custom group name.", 5 "<a> changed the group icon." (pencil). The trailing "Edit Group" link is not drawn (no group edit screen yet) | code | `RECIPIENT_ADD]:function`, strings `MMN2Jq`, `L2FyVq`, `5v2xa8`, `geP3rU`, `AI1ZZr`, `4wLp25` | `view_chat.jai` `system_notice` |
| Type 67 in a group DM: the client draws nothing (its component returns null unless the channel is a 1:1 DM); fastcord draws the notice | known gap | `if(!i.isDM()||null==o||null==d)return null` | `view_chat.jai` `system_notice` |
| Names in system notices (added / removed / pinned / call / friend accepted) open the user's profile on click (the client's `usernameHook`) | code | `usernameHook:d` in `RECIPIENT_ADD]:function` | `view_chat.jai` `system_notice` |
| A message's hover toolbar keeps that message hovered while the pointer is over it, though it overhangs the row above | inferred | — | `view_chat.jai` `chat_toolbar` |
| The typing line ("X is typing...") overlays the bottom 24px of the message list; the list runs to the composer and its bottom padding (8 + 24) keeps the newest message clear of it at the bottom | inferred | `.typing_` absolutely positioned in the form | `view_chat.jai` `typing_line`, `BOTTOM_PAD` |
| Reaction requests for one message+emoji go one at a time in click order (the next is sent when the previous answers), and the gateway echoes of our own requests are skipped while expected; a failed click is rolled back only if no newer click on that reaction is queued. The client sends each click at once; serialising keeps the same requests and order but stops the server applying on/off/on out of order | inferred (deviation) | `ReactionActionCreators` | `actions.jai` `reaction_send`, `store.jai` `reaction_echoes` |


## Code blocks and the composer's markdown

| Rule | Kind | Anchor in the client | fastcord |
|---|---|---|---|
| Message code block: `` ```(lang\n)?\n*(body)\n*``` ``, lang `[a-z0-9_+\-.#]+` (any case); a body of only newlines is no block | code | `codeBlock:{order:`, `/^```(?:([a-z0-9_+\-.#]+?)\n)?\n*([^\n][^]*?)\n*```/i` | `markdown.jai` `md_parse`, `is_lang_name` |
| Highlighting is tree-sitter (arborium) with 99 grammars: ada agda asciidoc asm awk bash batch c c-sharp caddy capnp cedar cedarschema clojure cmake commonlisp cpp css d dart devicetree diff dockerfile dot elisp elixir elm erlang fish fsharp gleam glsl go graphql groovy haskell hcl hlsl html idris ini java javascript jinja2 jq json julia kotlin lean lua markdown matlab meson ninja nix objc ocaml perl php postscript powershell prolog python query r rego rescript ron ruby rust scala scheme scss solidity sparql sql ssh-config starlark styx svelte swift textproto thrift tlaplus toml tsx typescript typst verilog vhdl vim vue wit x86asm xml yaml yuri zig zsh, plus `ansi` | code | grammar table `languageId:"ada",languageExport:"tree_sitter_ada"` (chunk `851061.*.js`, module 728806) | `highlight.jai` `LANGS` |
| Lang lookup: lower-case, must match `[a-z0-9_+\-.#]+`, a grammar name or `ansi`, else the alias table (`js`→javascript, `py`→python, `rs`→rust, `sh`/`shell`/`console`→bash, `yml`→yaml, `patch`→diff, `h`/`hpp`/`cc`→cpp, …, 130 aliases); anything else is plain text | code | `f={h:"cpp",hpp:"cpp"`, `function T(e){if(null==e)return;let t=e.toLowerCase()` | `highlight.jai` `hl_lang`, `HL_ALIASES` |
| No highlighting when any line of the block is over 1000 characters | code | `t.length>1e3` in the highlight hook | `highlight.jai` `hl_range` |
| Token colours: arborium capture elements styled with `--text-code-*`: keyword (a-k, a-kd…), number (a-n, a-cn, a-kc, a-l), title (a-f, a-t, a-pr, a-tg, a-kt…), builtin (a-fb, a-vb), operator (a-o), string (a-s, a-ss…), regexp (a-rx), escape (a-se), comment (a-c), decorator (a-at), namespace (a-m, a-ns), variable / punctuation plain; diff: a-s on `--background-code-addition` / `--text-code-addition`, a-k deletion likewise | code (CSS) | `490743.*.css`: `a-k,a-kd,…{color:var(--text-code-keyword)`, `.language-diff a-s` | `highlight.jai` `Hl`, `HL_TOKENS` |
| Which words get which capture: per-language keyword / type / builtin / literal lists and comment, string and number syntax, a hand-written lexer standing in for the tree-sitter queries; diff headers (`@@` namespace, `+++`/`---`/`diff`/`index` title) | guess | — | `highlight.jai` `LANGS`, `token`, `hl_diff` |
| `--text-code-decorator` (attributes, decorators) uses the same palette steps as `--text-code-builtin` in every theme; the resolved theme files lack it, so builtin's value is used | inferred (CSS) | `--text-code-decorator:var(--yellow-new-…)` | `highlight.jai` `HL_TOKENS` |
| `ansi`: SGR 0 reset, 4/24 underline, 9/29 strike, 30–37 / 90–97 fg, 40–47 / 100–107 bg, 39/49 default, 38/48;5;n (n < 16) and ;2;r;g;b; colours `--custom-ansi-color-N` = `--ansi-<name>`. Bold (1) is not drawn (no bold code face) | code; bold a known gap | `setForegroundColor`, `--custom-ansi-color-0:var(--ansi-black)` | `highlight.jai` `hl_ansi` |
| Diff line backgrounds cover the text only, not the full block width | known gap | — | `highlight.jai` `put` |
| Composer Enter: a newline instead of sending when Shift or Alt is held or the ``` count before the selection start is odd (`Q9`) | code | `e.key!==x.dh.ENTER\|\|(e.altKey\|\|e.shiftKey\|\|i&&!e.ctrlKey\|\|(0,ee.Q9)(t))&&c\|\|`, `match(/```/g)` | `view_chat.jai` `markdown_key`, `markdown.jai` `md_in_code_block` |
| Composer Tab: when every line of the selection is inside a code block, a collapsed caret gets two spaces; a selection (or Shift) indents (outdents) each line by two spaces | code | `case _.Ks6.TAB:if(null!=e.selection` … `insertText(e,"  ")` | `view_chat.jai` `markdown_key` |
| Composer code lines: ``` counted per line (a backslash skips the next byte); a line is in a block when the previous line opened one or was in one and it has no ```; it opens one when its ``` count (less a closing one) is odd; the lang is the text after its last ``` when that is `[a-z0-9_+\-.#]+`. Lines in a block: code font at 85%, highlighted as one block | code | `withCodeBlocks`, `isInCodeBlock`, `codeLine_` | `markdown.jai` `md_code_lines`, `view_chat.jai` `composer_spans` |
| Composer markdown styling (Slate decorations): strong, em, u, s, inlineCode, spoiler, url/autolink, escape, subtext styled with markers kept: markers `--textbox-markdown-syntax`, semibold; ~~ \|\| __ markers normal weight, __ underlined; ` markers code font and `--background-code`; ``` in the syntax colour, the lang `--text-feedback-positive`; urls `--text-link`; `-# ` bold muted 13px with the line muted 13px. Links (masked), headings, lists and block quotes are not decorated inline | code | `syntaxBefore:eo.syntaxBefore`, `link:{type:"skip"},…heading:{type:"skip"}`, `.syntaxAfter_ada32f,.syntaxBefore_ada32f{font-weight:var(--font-weight-semibold)` | `view_chat.jai` `composer_spans`, `composer_inline` |
| Composer `> ` line: the client turns it into a quote block (bar, the `> ` removed, restored on send); fastcord draws the bar over the kept `> `. `>>> ` (quote the rest) is not done | code; `>>>` a known gap | `s.text.match(/^\s*> /)`, `type:"blockQuote"` | `view_chat.jai` `composer_spans`, `images.jai` `draw_custom_emoji` |
| Composer: Cmd/Ctrl+B / I / U / Shift+S wrap the selection in markdown | code, not ported | `case _.Ks6.B:` … `(0,d.Px)(e,"bold")` | — |
