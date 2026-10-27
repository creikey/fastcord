// Client telemetry (AnalyticsTrackingStore): events are queued with
//   {client_track_timestamp, client_heartbeat_session_id, event_sequence_number,
//    ...event properties, ...expandEventProperties decorations, client_uuid?}
// and flushed as POST /api/v9/science {"token": analytics_token, "events": [...]}
// with client_send_timestamp stamped at flush (one timestamp per batch).
// The first batch carries `x-science-test: <uuid>`. Flush runs on an idle
// callback with a 1.5 s timeout after an event is queued (observed ≈0.4 s).
// client_uuid (after CONNECTION_OPEN) is base64 of 24 bytes:
//   userId(i64 LE) | randomPrefix(u32) | creationTime(i64 LE ms) | seq(u32)
// Events tracked before READY have no client_uuid, and the first ones (before
// the RTC/app-state/viewport decorators register) omit those fields too.

ANALYTICS_FLUSH_DELAY_MS :: 30; // fixtures: batches leave 21-49 ms after the event
ANALYTICS_MAX_FLUSH_MS :: 1500;
CLIENT_HEARTBEAT_INTERVAL_MS :: 15 * 60 * 1000;
AD_HEARTBEAT_INTERVAL_MS :: 5 * 60 * 1000;

Analytics :: struct {
	mu: locks.Mutex;
	enabled: bool;
	queue: [..]string; // {"type":..,"properties":{... (no closing brace)
	seq: int;
	flush_at: s64;
	sent_first: bool;
	uuid_random: u32;
	uuid_created: s64;
	uuid_seq: u32;
	user_id: Snowflake;
	decorated: bool; // late decorators (rtc state, app state, viewport) registered
	viewport_w: int; // CSS px of the window content (client_set_viewport)
	viewport_h: int;
	accessibility: u64; // AccessibilityFeatureFlags (client_set_accessibility)
	accessibility_known: bool;
	rtc_state: Rtc_State; // the voice connection's state (client_set_rtc_state)
	roundtrip_sample: float64; // send_message_roundtrip sample rate (MessageRoundtripTrackerStore: 10%)
	next_client_hb: s64;
	next_ad_hb: s64;
	ad_session: string;
	ad_created: s64;
	timers: [..]Analytics_Timer;
	roundtrips: Table(Snowflake, Roundtrip);
	throttled: Table(string, s64); // throttle key -> until (ms), analytics_throttled
	allocator: Allocator;
	// UI-owned event state (analytics_events.jai; UI thread)
	menu: Message_Menu;
	picker: Picker_Search;
	profile: Profile_View;
	join_voice_id: string;
	gdm_entry: Gdm_Entry;
	gdm_searches: int;
	gdm_pending: bool;
	guild_create_step_ms: s64;
	last_notification_ms, last_mention_ms, last_role_mention_ms, last_everyone_mention_ms: s64;
	shown: [..]Shown_Notification; // desktop notifications not acked yet (UI thread)
}

Shown_Notification :: struct {
	message_id, channel_id, author_id: Snowflake;
	kind: int;
	badge: bool;
}

Analytics_Timer :: struct {
	at: s64;
	event_type: string; // static strings only
	props: string;
}

Roundtrip :: struct {
	channel_id: Snowflake;
	start: s64;
	api: s64;
	gateway: s64;
	attachments: int;
}

analytics_init :: (a: *Analytics, allocator := context.allocator) {
	// workers queue events too: every container keeps the client's allocator
	a.allocator = allocator;
	a.queue.allocator = allocator;
	a.timers.allocator = allocator;
	a.roundtrips.allocator = allocator;
	a.throttled.allocator = allocator;
	a.shown.allocator = allocator;
	a.enabled = true;
	a.uuid_random = cast(u32) random_get();
	a.uuid_created = now_ms();
	// The ad session (AdSessionStore) exists from launch: quests/decision uses it before READY.
	a.ad_session = uuid4(,, allocator);
	a.ad_created = now_ms();
	a.roundtrip_sample = 0.1;
}

analytics_destroy :: (a: *Analytics) {
	push_allocator(a.allocator);
	for a.queue free(it);
	array_free(a.queue);
	free(a.ad_session);
	array_free(a.timers);
	deinit(*a.roundtrips);
	for v, k: a.throttled free(k);
	deinit(*a.throttled);
	array_free(a.shown);
	free(a.picker.load_id);
	free(a.picker.query);
	free(a.profile.session);
	free(a.profile.source_session);
	free(a.join_voice_id);
}

// client_uuid_next: the next client_uuid (see the top), in temp.
client_uuid_next :: (a: *Analytics) -> string {
	b: [24]u8;
	put :: (b: []u8, v: u64, n: int) { for 0..n-1 b[it] = cast(u8) (v >> (8 * it)); }
	put(b, a.user_id, 8);
	put(array_view(b, 8), a.uuid_random, 4);
	put(array_view(b, 12), cast(u64) a.uuid_created, 8);
	put(array_view(b, 20), a.uuid_seq, 4);
	a.uuid_seq += 1;
	return base64_encode(to_string(b.data, b.count),, temp);
}

// analytics_track queues one event. props_json is the event's own properties as
// a JSON object *body* (e.g. `"channel_id":"1","channel_view":"messages"`, may be "").
// Safe from worker threads (response-time events); typed helpers for UI events
// are in analytics_events.jai.
analytics_track :: (c: *Client, event_type: string, props_json: string) {
	a := *c.analytics;
	if !a.enabled return;
	// Events are dropped, never sent with invented values: memory must be
	// measurable and the app must have reported viewport + accessibility state.
	mem_kb, mok := process_memory_kb();
	cpu, cok := process_cpu_percent();
	locks.lock(*a.mu);
	known := a.viewport_w > 0 && a.accessibility_known;
	locks.unlock(*a.mu);
	if !mok || !cok || !known return;
	now := now_ms();
	hb := identity_heartbeat_snapshot(*c.id);
	locks.lock(*a.mu);
	defer locks.unlock(*a.mu);
	if analytics_throttled(a, event_type, props_json, now) return;
	a.seq += 1;
	b: [..]u8;
	b.allocator = temp;
	put :: (key: string, value: Any) #expand { append_string(*`b, tprint(",\"%\":%", key, value)); }
	put_str :: (key: string, value: string) #expand {
		append_string(*`b, tprint(",\"%\":", key));
		json_write_escaped(*`b, value);
	}
	append_string(*b, "{\"type\":");
	json_write_escaped(*b, event_type);
	append_string(*b, tprint(",\"properties\":{\"client_track_timestamp\":%", now));
	if hb.uuid put_str("client_heartbeat_session_id", hb.uuid);
	put("event_sequence_number", a.seq);
	if props_json append_string(*b, tprint(",%", props_json));
	// expandEventProperties — only measured values; see analytics_unknowable.
	put("client_performance_cpu", js_number(cpu));
	put("client_performance_memory", mem_kb);
	put("cpu_core_count", get_number_of_processors());
	put("accessibility_features", a.accessibility);
	put_str("rendered_locale", c.id.platform.locale);
	put("uptime_app", (now - c.launch_ms) / 1000);
	put("uptime_process_renderer", process_uptime_seconds());
	put_str("launch_signature", c.id.launch_signature);
	if a.decorated {
		put_str("client_rtc_state", rtc_state_name(a.rtc_state));
		put_str("client_app_state", app_state_name(c.id.app_state));
		put("client_viewport_width", a.viewport_w);
		put("client_viewport_height", a.viewport_h);
	}
	if a.user_id != 0 put_str("client_uuid", client_uuid_next(a));
	array_add(*a.queue, copy_string(cast(string) b,, a.allocator));
	if a.flush_at == 0 a.flush_at = now + ANALYTICS_FLUSH_DELAY_MS;
	a.decorated = true;
}

// Per-event throttles of the official tracker (analyticEventConfigs in the
// AnalyticsTrackingStore module: search `throttlePeriod:` / `throttleKeys:`):
// an event whose key (the type plus these properties' values) was tracked less
// than period_ms ago is dropped. Only the events fastcord sends are listed.
Sci_Throttle :: struct {
	event: string;
	period_ms: s64;
	keys: []string;
}

SCI_THROTTLES :: Sci_Throttle.[
	.{"ack_messages", 900_000, .["guild_id", "channel_id", "location_section"]}, // not for location_object_type "ack_manual"
	.{"guild_viewed", 900_000, .["guild_id", "is_pending"]},
	.{"friends_list_viewed", 900_000, .["tab_opened"]},
	.{"now_playing_card_hovered", 900_000, .["tab_opened"]},
	.{"start_speaking", 900_000, .["server"]},
	.{"start_listening", 900_000, .["server"]},
	.{"channel_opened", 900_000, .["channel_id", "channel_view"]}, // channel_static_route: not used by fastcord
	.{"text_in_voice_opened", 86_400_000, .["channel_id"]},
	.{"member_list_viewed", 900_000, .["channel_id"]},
	.{"dm_list_viewed", 900_000, .["channel_id"]},
	.{"keyboard_shortcut_used", 120_000, .["shortcut_name", "location_object", "source_class_list"]},
	.{"quickswitcher_opened", 10_000, .[]},
	.{"audio_input_initialized", 300_000, .[]},
	.{"video_input_initialized", 300_000, .[]},
	.{"premium_upsell_viewed", 60_000, .["type"]},
	.{"search_bar_viewed", 3_600_000, .["search_type"]}
];

// analytics_throttled: the tracker's throttle check (a.mu held). JS joins
// [type, ...values] with "_": null / undefined print as "", arrays spread.
analytics_throttled :: (a: *Analytics, event_type: string, props_json: string, now: s64) -> bool {
	th: Sci_Throttle;
	for SCI_THROTTLES if it.event == event_type { th = it; break; }
	if !th.event return false;
	props: etf.Map;
	if th.keys {
		v, err := etf.from_json(tprint("{%}", props_json),, temp);
		if err == .None props = vmap(v);
	}
	if event_type == "ack_messages" && fstr(props, "location_object_type") == "ack_manual" return false;
	key_part :: (v: V) -> string {
		if v.kind == {
			case .String; return v.s;
			case .Int;    return tprint("%", v.i);
			case .Float;  return js_number(v.f);
			case .Bool;   return ifx v.b then "true" else "false";
		}
		return "";
	}
	parts: [..]string;
	parts.allocator = temp;
	array_add(*parts, event_type);
	for k: th.keys {
		v := vget(props, k);
		if v.kind == .Nil && k == "source_class_list" continue; // `...(list ?? [])`
		if v.kind == .List {
			for v.list array_add(*parts, key_part(it));
		} else {
			array_add(*parts, key_part(v));
		}
	}
	key := join(..parts, separator = "_",, temp);
	until := table_find_pointer(*a.throttled, key);
	if until {
		if until.* > now return true;
		until.* = now + th.period_ms;
		return false;
	}
	table_set(*a.throttled, copy_string(key,, a.allocator), now + th.period_ms);
	return false;
}

// analytics_flush posts the queued batch when due (called from client_poll).
analytics_flush :: (c: *Client, now: s64, force := false) {
	a := *c.analytics;
	locks.lock(*a.mu);
	// The tracker only flushes once it has the READY analytics_token (events
	// queued earlier ride along in the first batch, as in the capture).
	// Logged out (auth.jai) the batches carry "token": null; the batch with the
	// events queued before a logout still carries the old token.
	logged_out := client_logged_out(c);
	if !a.queue || (c.store.analytics_token == "" && !logged_out) || (!force && (a.flush_at == 0 || now < a.flush_at)) {
		locks.unlock(*a.mu);
		return;
	}
	token := c.store.analytics_token;
	if c.auth.logout_batch_token {
		token = copy_string(c.auth.logout_batch_token,, temp);
		free(c.auth.logout_batch_token,, c.allocator);
		c.auth.logout_batch_token = "";
	}
	b: [..]u8;
	b.allocator = temp;
	append_string(*b, "{\"token\":");
	if token == "" && logged_out append_string(*b, "null"); else json_write_escaped(*b, token);
	append_string(*b, ",\"events\":[");
	for a.queue {
		if it_index > 0 array_add(*b, #char ",");
		append_string(*b, tprint("%,\"client_send_timestamp\":%}}", it, now));
		free(it,, a.allocator);
	}
	append_string(*b, "]}");
	a.queue.count = 0;
	a.flush_at = 0;
	first := !a.sent_first;
	a.sent_first = true;
	locks.unlock(*a.mu);

	j := job_new(.Api, .None);
	j.method = "POST";
	j.path = "/science";
	j.body = cast([]u8) job_str(j, cast(string) b);
	j.content_type = "application/json";
	j.retries = 3;
	if first {
		j.extra = NewArray(1, http.Header,, job_alloc(j));
		j.extra[0] = .{"x-science-test", job_str(j, uuid4(,, temp))};
	}
	job_submit(c, j);
}

// ---- events the library emits itself ----

// analytics_gateway_connected: GATEWAY_CONNECTED (GatewaySocket._handleHello).
analytics_gateway_connected :: (c: *Client, failed_attempts: int, url: string, is_reconnect: bool, is_fast_connect: bool, since_first: s64, since_attempt: s64) {
	w := aw_begin();
	json_kint(*w, "num_failed_connect_attempts", failed_attempts);
	json_kstr(*w, "gateway_url", url);
	json_kbool(*w, "is_reconnect", is_reconnect);
	json_kbool(*w, "is_fast_connect", is_fast_connect);
	json_kint(*w, "duration_ms_since_first_connect_attempt", since_first);
	json_kint(*w, "duration_ms_since_connect_attempt_start", since_attempt);
	aw_track(c, "gateway_connected", *w);
}

// js_number: a double as JSON.stringify writes it (integers without a fraction,
// otherwise the shortest round-trip decimal), in temp.
js_number :: (v: float64) -> string {
	if v == cast(float64) cast(s64) v && abs(v) < 1_000_000_000_000_000 return tprint("%", cast(s64) v);
	s := tprint("%", formatFloat(v, trailing_width = -1, zero_removal = .YES));
	return ifx begins_with(s, "+") then advance(s) else s;
}

// json_body strips the outer braces of an object.
json_body :: (obj: string) -> string {
	if obj.count < 2 return "";
	body := advance(obj);
	body.count -= 1;
	return body;
}

// analytics_tick runs periodic heartbeats and scheduled events (UI thread, from client_poll).
analytics_tick :: (c: *Client, now: s64) {
	a := *c.analytics;
	if !a.enabled return;
	i := 0;
	while i < a.timers.count {
		tm := a.timers[i];
		if tm.at > now {
			i += 1;
			continue;
		}
		array_ordered_remove_by_index(*a.timers, i);
		analytics_track(c, tm.event_type, tm.props);
	}
	for rt, nonce: a.roundtrips {
		if (rt.api != 0 && rt.gateway != 0) || now - rt.start > 30_000 {
			analytics_message_roundtrip(c, rt.channel_id, ifx rt.api then rt.api - rt.start else -1, ifx rt.gateway then rt.gateway - rt.start else -1, rt.attachments);
			table_remove(*a.roundtrips, nonce);
			break; // the table changed
		}
	}
	if a.user_id == 0 return; // heartbeats start on CONNECTION_OPEN
	if c.focused && now >= a.next_ad_hb {
		a.next_ad_hb = now + AD_HEARTBEAT_INTERVAL_MS;
		if a.ad_session == "" || now - a.ad_created > 12 * 3600 * 1000 {
			free(a.ad_session,, a.allocator);
			a.ad_session = uuid4(,, a.allocator);
			a.ad_created = now;
		}
		w := aw_begin();
		json_kstr(*w, "client_ad_session_id", a.ad_session);
		json_kint(*w, "client_heartbeat_initialization_timestamp", a.ad_created);
		json_kint(*w, "client_heartbeat_version", 3);
		aw_track(c, "client_ad_heartbeat", *w);
	}
}

// send_message_roundtrip: MessageRoundtripTrackerStore, sampled at 10%.
analytics_message_roundtrip :: (c: *Client, channel_id: Snowflake, api_ms: s64, gateway_ms: s64, attachments: int) {
	if random_get_zero_to_one_open() >= c.analytics.roundtrip_sample return;
	s := *c.store;
	_, ch := table_find(*s.channels, channel_id);
	w := aw_begin();
	if api_ms >= 0 json_kint(*w, "api_latency_ms", api_ms); else json_knull(*w, "api_latency_ms");
	if gateway_ms >= 0 json_kint(*w, "gateway_latency_ms", gateway_ms); else json_knull(*w, "gateway_latency_ms");
	json_ksnow(*w, "channel_id", channel_id);
	json_kint(*w, "channel_type", xx ch.kind);
	if ch.guild_id != 0 {
		json_ksnow(*w, "guild_id", ch.guild_id);
		_, g := table_find(*s.guilds, ch.guild_id);
		json_kint(*w, "guild_size", g.member_count);
	}
	json_kstr(*w, "mobile_network_type", "unknown");
	json_kint(*w, "num_attachments", attachments);
	aw_track(c, "send_message_roundtrip", *w);
}

analytics_schedule :: (c: *Client, at: s64, event_type: string, props: string) {
	array_add(*c.analytics.timers, .{at, event_type, props});
}

// analytics_on_ready: CONNECTION_OPEN hooks (UI thread); true the first time.
analytics_on_ready :: (c: *Client) -> bool {
	a := *c.analytics;
	if a.user_id != 0 return false;
	a.user_id = c.store.me;
	a.next_client_hb = now_ms();
	a.next_ad_hb = a.next_client_hb;
	return true;
}

// AccessibilityFeatureFlags bits the platform layer can know.
A11Y_REDUCED_MOTION :: 2; // (1 is SCREENREADER)
A11Y_HIGH_CONTRAST :: 8;
A11Y_INVERT_COLORS :: 64;
A11Y_PREFERS_COLOR_SCHEME_LIGHT :: 128;
A11Y_PREFERS_COLOR_SCHEME_DARK :: 256;
A11Y_REDUCED_MOTION_FROM_USER_SETTINGS :: 65536;
A11Y_FORCED_COLORS :: 262144;
A11Y_FORCED_COLORS_FROM_USER_SETTINGS :: 524288;

// A11y_Inputs: what fastcord knows of the AccessibilityStore's sources: the OS
// appearance and display accommodations (Chromium's media queries) and the
// app's own settings. fastcord has no reduced-motion, forced-colors, font
// scale, zoom, spacing, saturation, role-style or UI-density setting, so those
// keep the store's defaults.
A11y_Inputs :: struct {
	os_dark: bool; // prefers-color-scheme: dark (else light)
	reduce_motion: bool; // prefers-reduced-motion: reduce
	contrast_more: bool; // prefers-contrast: more
	invert_colors: bool; // inverted-colors: inverted
	forced_colors: bool; // forced-colors: active
}

// accessibility_flags: AccessibilityFeatureFlags as the client computes them
// (bundle: `handlePrefersColorSchemeLightChanged`, `handleAccessibilityStoreChanged`):
//   media queries: PREFERS_COLOR_SCHEME_LIGHT / _DARK, HIGH_CONTRAST, FORCED_COLORS, INVERT_COLORS;
//   AccessibilityStore (defaults): REDUCED_MOTION = prefersReducedMotion "auto" -> the
//   system's; FORCED_COLORS_FROM_USER_SETTINGS = syncForcedColors (default true).
// The store's bits join on its first change, before the gateway connects (the
// official 128 -> 524416 in every fixture); fastcord sends nothing that early.
accessibility_flags :: (in_: A11y_Inputs) -> u64 {
	f: u64 = A11Y_FORCED_COLORS_FROM_USER_SETTINGS | cast(u64) (ifx in_.os_dark then A11Y_PREFERS_COLOR_SCHEME_DARK else A11Y_PREFERS_COLOR_SCHEME_LIGHT);
	if in_.contrast_more f |= A11Y_HIGH_CONTRAST;
	if in_.forced_colors f |= A11Y_FORCED_COLORS;
	if in_.invert_colors f |= A11Y_INVERT_COLORS;
	if in_.reduce_motion f |= A11Y_REDUCED_MOTION;
	return f;
}

// analytics_queued: events waiting for the next /science flush (tests).
analytics_queued :: (c: *Client) -> int {
	locks.lock(*c.analytics.mu);
	defer locks.unlock(*c.analytics.mu);
	return c.analytics.queue.count;
}

// client_set_viewport: window content size in CSS px (client_viewport_width/height).
client_set_viewport :: (c: *Client, w: int, h: int) {
	locks.lock(*c.analytics.mu);
	c.analytics.viewport_w = w;
	c.analytics.viewport_h = h;
	locks.unlock(*c.analytics.mu);
}

// RTCConnectionStates as client_rtc_state reports them.
Rtc_State :: enum u8 {
	Disconnected;
	Awaiting_Endpoint;
	Authenticating;
	Connecting;
	Rtc_Disconnected;
	Rtc_Connecting;
	Rtc_Connected;
	No_Route;
	Ice_Checking;
}

rtc_state_name :: (s: Rtc_State) -> string {
	NAMES :: string.["DISCONNECTED", "AWAITING_ENDPOINT", "AUTHENTICATING", "CONNECTING", "RTC_DISCONNECTED", "RTC_CONNECTING", "RTC_CONNECTED", "NO_ROUTE", "ICE_CHECKING"];
	return NAMES[cast(int) s];
}

// client_set_rtc_state: the app reports its voice connection (src/voice) state.
client_set_rtc_state :: (c: *Client, s: Rtc_State) {
	locks.lock(*c.analytics.mu);
	c.analytics.rtc_state = s;
	locks.unlock(*c.analytics.mu);
}

// client_set_accessibility: the AccessibilityStore bitmask (OS color scheme,
// reduced motion, user accessibility settings) as the UI knows it.
client_set_accessibility :: (c: *Client, flags: u64) {
	locks.lock(*c.analytics.mu);
	c.analytics.accessibility = flags;
	c.analytics.accessibility_known = true;
	locks.unlock(*c.analytics.mu);
}

// Events the official client sends that fastcord deliberately does NOT send,
// because a value cannot be produced truthfully by this client (UI-owned events
// fastcord does send are in analytics_events.jai; traffic/PARITY.md "Telemetry"):
//   client_heartbeat                     Electron per-process memory arrays, JS heap
//   app_native_crash                     Electron crash reporter / minidump state
//   libdiscore_loaded                    the web client's wasm load
//   ready_payload_received               identify server timings / per-section sizes as the JS store computes them
//   app_web_perf_startup_metrics, app_ui_viewed   web bundle load / render metrics
//   notification_permission_status       OS notification permission (needs the platform layer)
//   dismissible_content_shown*, hotspot_hidden, premium_upsell_viewed,
//   impression_custom_themes_*           NUX tooltips and upsells fastcord never shows
//   quest_hover, quest_hover_off         the quests entry point (fastcord has none)
//   experiment_guild_triggered*, experiment_user_evaluation_exposed
//                                        exposures named after the official UI components that read them
//   quickswitcher_closed, quickswitcher_result_selected   Discord's search scores (top_result_score...)
//   voice_connection_*, audio_input_initialized, media_session_joined, start_speaking,
//   start_listening, voice_codec_detected, voice_disconnect, secure_frames_transition
//                                        the official media engine's versions and internals (src/voice is not it)
//   leave_voice_channel                  the media engine's per-call statistics (packets, listener counts, durations)
//   video_layout_toggled                 the official call view's layout state (fastcord's call view has none)
//   impression_voice_invite_suggestions_*, emoji_studio_ended, open_modal "Emoji Studio"
//                                        UI fastcord does not have
analytics_unknowable :: string.["client_heartbeat", "app_native_crash", "libdiscore_loaded", "ready_payload_received", "app_web_perf_startup_metrics", "app_ui_viewed", "notification_permission_status", "dismissible_content_shown", "dismissible_content_shown_before_connection_open", "hotspot_hidden", "premium_upsell_viewed", "quest_hover", "quest_hover_off", "experiment_guild_triggered", "experiment_guild_triggered_fallback", "experiment_user_evaluation_exposed", "quickswitcher_closed", "quickswitcher_result_selected", "emoji_studio_ended", "voice_connection_connecting", "voice_connection_remote_streams_created", "voice_connection_success", "voice_connection_ttc_collected", "audio_input_initialized", "media_session_joined", "start_speaking", "start_listening", "voice_codec_detected", "voice_disconnect", "secure_frames_transition", "leave_voice_channel", "video_layout_toggled"];
