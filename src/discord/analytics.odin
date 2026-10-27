package discord

import "fc:locks"
import "core:encoding/base64"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import "fc:etf"
import "fc:http"

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

ANALYTICS_FLUSH_DELAY_MS :: 30 // fixtures: batches leave 21-49 ms after the event
ANALYTICS_MAX_FLUSH_MS :: 1500
CLIENT_HEARTBEAT_INTERVAL_MS :: 15 * 60 * 1000
AD_HEARTBEAT_INTERVAL_MS :: 5 * 60 * 1000

Analytics :: struct {
	mu:            locks.Mutex,
	enabled:       bool,
	queue:         [dynamic]string, // {"type":..,"properties":{... (no closing brace)
	seq:           int,
	flush_at:      i64,
	sent_first:    bool,
	uuid_random:   u32,
	uuid_created:  i64,
	uuid_seq:      u32,
	user_id:       Snowflake,
	decorated:     bool, // late decorators (rtc state, app state, viewport) registered
	viewport_w:    int, // CSS px of the window content (client_set_viewport)
	viewport_h:    int,
	accessibility: u64, // AccessibilityFeatureFlags (client_set_accessibility)
	accessibility_known: bool,
	rtc_state:     Rtc_State, // the voice connection's state (client_set_rtc_state)
	roundtrip_sample: f64, // send_message_roundtrip sample rate (MessageRoundtripTrackerStore: 10%)
	next_client_hb: i64,
	next_ad_hb:    i64,
	ad_session:    string,
	ad_created:    i64,
	timers:        [dynamic]Analytics_Timer,
	roundtrips:    map[Snowflake]Roundtrip,
	throttled:     map[string]i64, // throttle key -> until (ms), analytics_throttled
	allocator:     Allocator,
	// UI-owned event state (analytics_events.odin; UI thread)
	menu:          Message_Menu,
	picker:        Picker_Search,
	profile:       Profile_View,
	join_voice_id: string,
	gdm_entry:     Gdm_Entry,
	gdm_searches:  int,
	gdm_pending:   bool,
	guild_create_step_ms: i64,
	last_notification_ms, last_mention_ms, last_role_mention_ms, last_everyone_mention_ms: i64,
	shown:         [dynamic]Shown_Notification, // desktop notifications not acked yet (UI thread)
}

Shown_Notification :: struct {
	message_id, channel_id, author_id: Snowflake,
	kind:                              int,
	badge:                             bool,
}

Analytics_Timer :: struct {
	at:         i64,
	event_type: string, // static strings only
	props:      string,
}

Roundtrip :: struct {
	channel_id:  Snowflake,
	start:       i64,
	api:         i64,
	gateway:     i64,
	attachments: int,
}

analytics_init :: proc(a: ^Analytics, allocator := context.allocator) {
	a.allocator = allocator
	a.enabled = true
	a.queue = make([dynamic]string, allocator)
	a.uuid_random = rand.uint32()
	a.uuid_created = now_ms()
	a.timers = make([dynamic]Analytics_Timer, allocator)
	// The ad session (AdSessionStore) exists from launch: quests/decision uses it before READY.
	a.ad_session = uuid4(allocator)
	a.ad_created = now_ms()
	a.roundtrips = make(map[Snowflake]Roundtrip, allocator = allocator)
	a.throttled = make(map[string]i64, allocator = allocator)
	a.shown = make([dynamic]Shown_Notification, allocator)
	a.roundtrip_sample = 0.1
}

analytics_destroy :: proc(a: ^Analytics) {
	for e in a.queue do delete(e, a.allocator)
	delete(a.queue)
	delete(a.ad_session, a.allocator)
	delete(a.timers)
	delete(a.roundtrips)
	for k in a.throttled do delete(k, a.allocator)
	delete(a.throttled)
	delete(a.shown)
	delete(a.picker.load_id, a.allocator)
	delete(a.picker.query, a.allocator)
	delete(a.profile.session, a.allocator)
	delete(a.profile.source_session, a.allocator)
	delete(a.join_voice_id, a.allocator)
}

@(private)
client_uuid_next :: proc(a: ^Analytics) -> string {
	b: [24]byte
	put32 :: proc(b: []byte, v: u32) {for i in 0 ..< 4 do b[i] = byte(v >> (8 * uint(i)))}
	uid := u64(a.user_id)
	put32(b[0:], u32(uid))
	put32(b[4:], u32(uid >> 32))
	put32(b[8:], a.uuid_random)
	put32(b[12:], u32(u64(a.uuid_created)))
	put32(b[16:], u32(u64(a.uuid_created) >> 32))
	put32(b[20:], a.uuid_seq)
	a.uuid_seq += 1
	return base64.encode(b[:], allocator = context.temp_allocator)
}

// analytics_track queues one event. props_json is the event's own properties as
// a JSON object *body* (e.g. `"channel_id":"1","channel_view":"messages"`, may be "").
// Safe from worker threads (response-time events); typed helpers for UI events
// are in analytics_events.odin.
analytics_track :: proc(c: ^Client, event_type, props_json: string) {
	a := &c.analytics
	if !a.enabled do return
	// Events are dropped, never sent with invented values: memory must be
	// measurable and the app must have reported viewport + accessibility state.
	mem_kb, mok := process_memory_kb()
	cpu, cok := process_cpu_percent()
	locks.lock(&a.mu)
	known := a.viewport_w > 0 && a.accessibility_known
	locks.unlock(&a.mu)
	if !mok || !cok || !known do return
	now := now_ms()
	hb := identity_heartbeat_snapshot(&c.id)
	locks.lock(&a.mu)
	defer locks.unlock(&a.mu)
	if analytics_throttled(a, event_type, props_json, now) do return
	a.seq += 1
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"type":`)
	json_write_escaped(&sb, event_type)
	strings.write_string(&sb, `,"properties":{"client_track_timestamp":`)
	strings.write_i64(&sb, now)
	if hb.uuid != "" {
		strings.write_string(&sb, `,"client_heartbeat_session_id":`)
		json_write_escaped(&sb, hb.uuid)
	}
	strings.write_string(&sb, `,"event_sequence_number":`)
	strings.write_int(&sb, a.seq)
	if props_json != "" {
		strings.write_byte(&sb, ',')
		strings.write_string(&sb, props_json)
	}
	// expandEventProperties — only measured values; see analytics_unknowable.
	strings.write_string(&sb, `,"client_performance_cpu":`)
	write_js_number(&sb, cpu)
	strings.write_string(&sb, `,"client_performance_memory":`)
	strings.write_i64(&sb, mem_kb)
	strings.write_string(&sb, `,"cpu_core_count":`)
	strings.write_int(&sb, os.get_processor_core_count())
	strings.write_string(&sb, `,"accessibility_features":`)
	strings.write_u64(&sb, a.accessibility)
	strings.write_string(&sb, `,"rendered_locale":`)
	json_write_escaped(&sb, c.id.platform.locale)
	strings.write_string(&sb, `,"uptime_app":`)
	strings.write_i64(&sb, (now - c.launch_ms) / 1000)
	strings.write_string(&sb, `,"uptime_process_renderer":`)
	strings.write_i64(&sb, process_uptime_seconds())
	strings.write_string(&sb, `,"launch_signature":`)
	json_write_escaped(&sb, c.id.launch_signature)
	if a.decorated {
		strings.write_string(&sb, `,"client_rtc_state":`)
		json_write_escaped(&sb, rtc_state_name(a.rtc_state))
		strings.write_string(&sb, `,"client_app_state":`)
		json_write_escaped(&sb, app_state_name(c.id.app_state))
		strings.write_string(&sb, `,"client_viewport_width":`)
		strings.write_int(&sb, a.viewport_w)
		strings.write_string(&sb, `,"client_viewport_height":`)
		strings.write_int(&sb, a.viewport_h)
	}
	if a.user_id != 0 {
		strings.write_string(&sb, `,"client_uuid":`)
		json_write_escaped(&sb, client_uuid_next(a))
	}
	append(&a.queue, strings.clone(strings.to_string(sb), a.allocator))
	if a.flush_at == 0 do a.flush_at = now + ANALYTICS_FLUSH_DELAY_MS
	a.decorated = true
}

// Per-event throttles of the official tracker (analyticEventConfigs in the
// AnalyticsTrackingStore module: search `throttlePeriod:` / `throttleKeys:`):
// an event whose key (the type plus these properties' values) was tracked less
// than period_ms ago is dropped. Only the events fastcord sends are listed.
@(private = "file")
Sci_Throttle :: struct {
	event:     string,
	period_ms: i64,
	keys:      []string,
}

@(private = "file")
SCI_THROTTLES := [?]Sci_Throttle {
	{"ack_messages", 900_000, {"guild_id", "channel_id", "location_section"}}, // not for location_object_type "ack_manual"
	{"guild_viewed", 900_000, {"guild_id", "is_pending"}},
	{"friends_list_viewed", 900_000, {"tab_opened"}},
	{"now_playing_card_hovered", 900_000, {"tab_opened"}},
	{"start_speaking", 900_000, {"server"}},
	{"start_listening", 900_000, {"server"}},
	{"channel_opened", 900_000, {"channel_id", "channel_view"}}, // channel_static_route: not used by fastcord
	{"text_in_voice_opened", 86_400_000, {"channel_id"}},
	{"member_list_viewed", 900_000, {"channel_id"}},
	{"dm_list_viewed", 900_000, {"channel_id"}},
	{"keyboard_shortcut_used", 120_000, {"shortcut_name", "location_object", "source_class_list"}},
	{"quickswitcher_opened", 10_000, {}},
	{"audio_input_initialized", 300_000, {}},
	{"video_input_initialized", 300_000, {}},
	{"premium_upsell_viewed", 60_000, {"type"}},
	{"search_bar_viewed", 3_600_000, {"search_type"}},
}

// analytics_throttled: the tracker's throttle check (a.mu held). JS joins
// [type, ...values] with "_": null / undefined print as "", arrays spread.
@(private = "file")
analytics_throttled :: proc(a: ^Analytics, event_type, props_json: string, now: i64) -> bool {
	th: ^Sci_Throttle
	for &x in SCI_THROTTLES do if x.event == event_type {th = &x; break}
	if th == nil do return false
	props: etf.Map
	if len(th.keys) > 0 {
		v, err := etf.from_json(strings.concatenate({"{", props_json, "}"}, context.temp_allocator), context.temp_allocator)
		if err == .None do props = vmap(v)
	}
	if event_type == "ack_messages" && fstr(props, "location_object_type") == "ack_manual" do return false
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, event_type)
	key_part :: proc(sb: ^strings.Builder, v: V) {
		#partial switch x in v {
		case string:
			strings.write_string(sb, x)
		case i64:
			strings.write_i64(sb, x)
		case f64:
			write_js_number(sb, x)
		case bool:
			strings.write_string(sb, "true" if x else "false")
		}
	}
	for k in th.keys {
		v := vget(props, k)
		if v == nil && k == "source_class_list" do continue // `...(list ?? [])`
		if l, ok := v.(etf.List); ok {
			for e in l {strings.write_byte(&sb, '_'); key_part(&sb, e)}
			continue
		}
		strings.write_byte(&sb, '_')
		key_part(&sb, v)
	}
	key := strings.to_string(sb)
	if until, ok := a.throttled[key]; ok {
		if until > now do return true
		a.throttled[key] = now + th.period_ms
		return false
	}
	a.throttled[strings.clone(key, a.allocator)] = now + th.period_ms
	return false
}

// analytics_flush posts the queued batch when due (called from client_poll).
analytics_flush :: proc(c: ^Client, now: i64, force := false) {
	a := &c.analytics
	locks.lock(&a.mu)
	// The tracker only flushes once it has the READY analytics_token (events
	// queued earlier ride along in the first batch, as in the capture).
	// Logged out (auth.odin) the batches carry "token": null; the batch with the
	// events queued before a logout still carries the old token.
	logged_out := client_logged_out(c)
	if len(a.queue) == 0 || (c.store.analytics_token == "" && !logged_out) || (!force && (a.flush_at == 0 || now < a.flush_at)) {
		locks.unlock(&a.mu)
		return
	}
	token := c.store.analytics_token
	if c.auth.logout_batch_token != "" {
		token = strings.clone(c.auth.logout_batch_token, context.temp_allocator)
		delete(c.auth.logout_batch_token, c.allocator)
		c.auth.logout_batch_token = ""
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"token":`)
	if token == "" && logged_out do strings.write_string(&sb, "null")
	else do json_write_escaped(&sb, token)
	strings.write_string(&sb, `,"events":[`)
	for e, i in a.queue {
		if i > 0 do strings.write_byte(&sb, ',')
		strings.write_string(&sb, e)
		strings.write_string(&sb, `,"client_send_timestamp":`)
		strings.write_i64(&sb, now)
		strings.write_string(&sb, "}}")
		delete(e, a.allocator)
	}
	strings.write_string(&sb, "]}")
	clear(&a.queue)
	a.flush_at = 0
	first := !a.sent_first
	a.sent_first = true
	locks.unlock(&a.mu)

	j := job_new(.Api, .None)
	j.method = "POST"
	j.path = "/science"
	j.body = transmute([]byte)job_str(j, strings.to_string(sb))
	j.content_type = "application/json"
	j.retries = 3
	if first {
		hdr := make([]http.Header, 1, job_alloc(j))
		hdr[0] = {"x-science-test", job_str(j, uuid4(context.temp_allocator))}
		j.extra = hdr
	}
	job_submit(c, j)
}

// ---- events the library emits itself ----

// analytics_on_hello: GATEWAY_CONNECTED (GatewaySocket._handleHello).
analytics_gateway_connected :: proc(c: ^Client, failed_attempts: int, url: string, is_reconnect, is_fast_connect: bool, since_first, since_attempt: i64) {
	w: Json
	json_init(&w)
	json_obj(&w)
	json_kint(&w, "num_failed_connect_attempts", i64(failed_attempts))
	json_kstr(&w, "gateway_url", url)
	json_kbool(&w, "is_reconnect", is_reconnect)
	json_kbool(&w, "is_fast_connect", is_fast_connect)
	json_kint(&w, "duration_ms_since_first_connect_attempt", since_first)
	json_kint(&w, "duration_ms_since_connect_attempt_start", since_attempt)
	json_obj_end(&w)
	analytics_track(c, "gateway_connected", json_body(json_string(&w)))
}

// write_js_number writes a double as JSON.stringify does (integers without a
// fraction, otherwise the shortest round-trip decimal).
write_js_number :: proc(sb: ^strings.Builder, v: f64) {
	if v == f64(i64(v)) && abs(v) < 1e15 {
		strings.write_i64(sb, i64(v))
		return
	}
	buf: [64]byte
	s := strconv.write_float(buf[:], v, 'f', -1, 64)
	strings.write_string(sb, strings.trim_prefix(s, "+"))
}

// json_body strips the outer braces of an object.
json_body :: proc(obj: string) -> string {
	if len(obj) < 2 do return ""
	return obj[1:len(obj) - 1]
}

// analytics_tick runs periodic heartbeats and scheduled events (UI thread, from client_poll).
analytics_tick :: proc(c: ^Client, now: i64) {
	a := &c.analytics
	if !a.enabled do return
	for i := 0; i < len(a.timers); {
		tm := a.timers[i]
		if tm.at > now {
			i += 1
			continue
		}
		ordered_remove(&a.timers, i)
		analytics_track(c, tm.event_type, tm.props)
	}
	for nonce, rt in a.roundtrips {
		done := rt.api != 0 && rt.gateway != 0
		if done || now - rt.start > 30_000 {
			analytics_message_roundtrip(c, rt.channel_id, rt.api - rt.start if rt.api != 0 else -1, rt.gateway - rt.start if rt.gateway != 0 else -1, rt.attachments)
			delete_key(&a.roundtrips, nonce)
			break // map changed
		}
	}
	if a.user_id == 0 do return // heartbeats start on CONNECTION_OPEN
	if c.focused && now >= a.next_ad_hb {
		a.next_ad_hb = now + AD_HEARTBEAT_INTERVAL_MS
		if a.ad_session == "" || now - a.ad_created > 12 * 3600 * 1000 {
			delete(a.ad_session, a.allocator)
			a.ad_session = uuid4(a.allocator)
			a.ad_created = now
		}
		w: Json
		json_init(&w)
		json_obj(&w)
		json_kstr(&w, "client_ad_session_id", a.ad_session)
		json_kint(&w, "client_heartbeat_initialization_timestamp", a.ad_created)
		json_kint(&w, "client_heartbeat_version", 3)
		json_obj_end(&w)
		analytics_track(c, "client_ad_heartbeat", json_body(json_string(&w)))
	}
}

// send_message_roundtrip: MessageRoundtripTrackerStore, sampled at 10%.
analytics_message_roundtrip :: proc(c: ^Client, channel_id: Snowflake, api_ms, gateway_ms: i64, attachments: int) {
	if rand.float64() >= c.analytics.roundtrip_sample do return
	s := &c.store
	ch := s.channels[channel_id]
	w: Json
	json_init(&w)
	json_obj(&w)
	if api_ms >= 0 do json_kint(&w, "api_latency_ms", api_ms)
	else do json_knull(&w, "api_latency_ms")
	if gateway_ms >= 0 do json_kint(&w, "gateway_latency_ms", gateway_ms)
	else do json_knull(&w, "gateway_latency_ms")
	json_ksnow(&w, "channel_id", channel_id)
	json_kint(&w, "channel_type", i64(ch.kind))
	if ch.guild_id != 0 {
		json_ksnow(&w, "guild_id", ch.guild_id)
		g := s.guilds[ch.guild_id]
		json_kint(&w, "guild_size", i64(g.member_count))
	}
	json_kstr(&w, "mobile_network_type", "unknown")
	json_kint(&w, "num_attachments", i64(attachments))
	json_obj_end(&w)
	analytics_track(c, "send_message_roundtrip", json_body(json_string(&w)))
}

analytics_schedule :: proc(c: ^Client, at: i64, event_type, props: string) {
	append(&c.analytics.timers, Analytics_Timer{at, event_type, props})
}

// analytics_on_ready: CONNECTION_OPEN hooks (UI thread).
analytics_on_ready :: proc(c: ^Client) -> (first: bool) {
	a := &c.analytics
	if a.user_id != 0 do return false
	first = true
	a.user_id = c.store.me
	now := now_ms()
	a.next_client_hb = now
	a.next_ad_hb = now
	return
}

// AccessibilityFeatureFlags bits the platform layer can know.
A11Y_REDUCED_MOTION :: 2 // (1 is SCREENREADER)
A11Y_PREFERS_COLOR_SCHEME_LIGHT :: 128
A11Y_PREFERS_COLOR_SCHEME_DARK :: 256
A11Y_FORCED_COLORS :: 262144
A11Y_FORCED_COLORS_FROM_USER_SETTINGS :: 524288

// A11y_Inputs: what fastcord knows of the AccessibilityStore's sources: the OS
// appearance and display accommodations (Chromium's media queries) and the
// app's own settings. fastcord has no reduced-motion, forced-colors, font
// scale, zoom, spacing, saturation, role-style or UI-density setting, so those
// keep the store's defaults.
A11y_Inputs :: struct {
	os_dark:       bool, // prefers-color-scheme: dark (else light)
	reduce_motion: bool, // prefers-reduced-motion: reduce
	contrast_more: bool, // prefers-contrast: more
	invert_colors: bool, // inverted-colors: inverted
	forced_colors: bool, // forced-colors: active
}

A11Y_HIGH_CONTRAST :: 8
A11Y_INVERT_COLORS :: 64
A11Y_REDUCED_MOTION_FROM_USER_SETTINGS :: 65536

// accessibility_flags: AccessibilityFeatureFlags as the client computes them
// (bundle: `handlePrefersColorSchemeLightChanged`, `handleAccessibilityStoreChanged`):
//   media queries: PREFERS_COLOR_SCHEME_LIGHT / _DARK, HIGH_CONTRAST, FORCED_COLORS, INVERT_COLORS;
//   AccessibilityStore (defaults): REDUCED_MOTION = prefersReducedMotion "auto" -> the
//   system's; FORCED_COLORS_FROM_USER_SETTINGS = syncForcedColors (default true).
// The store's bits join on its first change, before the gateway connects (the
// official 128 -> 524416 in every fixture); fastcord sends nothing that early.
accessibility_flags :: proc(in_: A11y_Inputs) -> (f: u64) {
	f |= A11Y_PREFERS_COLOR_SCHEME_DARK if in_.os_dark else A11Y_PREFERS_COLOR_SCHEME_LIGHT
	if in_.contrast_more do f |= A11Y_HIGH_CONTRAST
	if in_.forced_colors do f |= A11Y_FORCED_COLORS
	if in_.invert_colors do f |= A11Y_INVERT_COLORS
	if in_.reduce_motion do f |= A11Y_REDUCED_MOTION
	f |= A11Y_FORCED_COLORS_FROM_USER_SETTINGS
	return
}

// analytics_queued: events waiting for the next /science flush (tests).
analytics_queued :: proc(c: ^Client) -> int {
	locks.lock(&c.analytics.mu)
	defer locks.unlock(&c.analytics.mu)
	return len(c.analytics.queue)
}

// client_set_viewport: window content size in CSS px (client_viewport_width/height).
client_set_viewport :: proc(c: ^Client, w, h: int) {
	locks.lock(&c.analytics.mu)
	c.analytics.viewport_w = w
	c.analytics.viewport_h = h
	locks.unlock(&c.analytics.mu)
}

// RTCConnectionStates as client_rtc_state reports them.
Rtc_State :: enum u8 {
	Disconnected,
	Awaiting_Endpoint,
	Authenticating,
	Connecting,
	Rtc_Disconnected,
	Rtc_Connecting,
	Rtc_Connected,
	No_Route,
	Ice_Checking,
}

rtc_state_name :: proc(s: Rtc_State) -> string {
	switch s {
	case .Disconnected:
		return "DISCONNECTED"
	case .Awaiting_Endpoint:
		return "AWAITING_ENDPOINT"
	case .Authenticating:
		return "AUTHENTICATING"
	case .Connecting:
		return "CONNECTING"
	case .Rtc_Disconnected:
		return "RTC_DISCONNECTED"
	case .Rtc_Connecting:
		return "RTC_CONNECTING"
	case .Rtc_Connected:
		return "RTC_CONNECTED"
	case .No_Route:
		return "NO_ROUTE"
	case .Ice_Checking:
		return "ICE_CHECKING"
	}
	return "DISCONNECTED"
}

// client_set_rtc_state: the app reports its voice connection (src/voice) state.
client_set_rtc_state :: proc(c: ^Client, s: Rtc_State) {
	locks.lock(&c.analytics.mu)
	c.analytics.rtc_state = s
	locks.unlock(&c.analytics.mu)
}

// client_set_accessibility: the AccessibilityStore bitmask (OS color scheme,
// reduced motion, user accessibility settings) as the UI knows it.
client_set_accessibility :: proc(c: ^Client, flags: u64) {
	locks.lock(&c.analytics.mu)
	c.analytics.accessibility = flags
	c.analytics.accessibility_known = true
	locks.unlock(&c.analytics.mu)
}

// Events the official client sends that fastcord deliberately does NOT send,
// because a value cannot be produced truthfully by this client (UI-owned events
// fastcord does send are in analytics_events.odin; traffic/PARITY.md "Telemetry"):
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
analytics_unknowable :: [?]string{"client_heartbeat", "app_native_crash", "libdiscore_loaded", "ready_payload_received", "app_web_perf_startup_metrics", "app_ui_viewed", "notification_permission_status", "dismissible_content_shown", "dismissible_content_shown_before_connection_open", "hotspot_hidden", "premium_upsell_viewed", "quest_hover", "quest_hover_off", "experiment_guild_triggered", "experiment_guild_triggered_fallback", "experiment_user_evaluation_exposed", "quickswitcher_closed", "quickswitcher_result_selected", "emoji_studio_ended", "voice_connection_connecting", "voice_connection_remote_streams_created", "voice_connection_success", "voice_connection_ttc_collected", "audio_input_initialized", "media_session_joined", "start_speaking", "start_listening", "voice_codec_detected", "voice_disconnect", "secure_frames_transition", "leave_voice_channel", "video_layout_toggled"}
