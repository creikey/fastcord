package discord

import "core:encoding/base64"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:sync"
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
	mu:            sync.Mutex,
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
	next_client_hb: i64,
	next_ad_hb:    i64,
	ad_session:    string,
	ad_created:    i64,
	timers:        [dynamic]Analytics_Timer,
	roundtrips:    map[Snowflake]Roundtrip,
	allocator:     Allocator,
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
}

analytics_destroy :: proc(a: ^Analytics) {
	for e in a.queue do delete(e, a.allocator)
	delete(a.queue)
	delete(a.ad_session, a.allocator)
	delete(a.timers)
	delete(a.roundtrips)
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
analytics_track :: proc(c: ^Client, event_type, props_json: string) {
	a := &c.analytics
	if !a.enabled do return
	// Events are dropped, never sent with invented values: memory must be
	// measurable and the app must have reported viewport + accessibility state.
	mem_kb, mok := process_memory_kb()
	cpu, cok := process_cpu_percent()
	sync.mutex_lock(&a.mu)
	known := a.viewport_w > 0 && a.accessibility_known
	sync.mutex_unlock(&a.mu)
	if !mok || !cok || !known do return
	now := now_ms()
	hb := identity_heartbeat_snapshot(&c.id)
	sync.mutex_lock(&a.mu)
	defer sync.mutex_unlock(&a.mu)
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
	strings.write_int(&sb, cpu)
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
		strings.write_string(&sb, `,"client_rtc_state":"DISCONNECTED","client_app_state":`)
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

// analytics_flush posts the queued batch when due (called from client_poll).
analytics_flush :: proc(c: ^Client, now: i64, force := false) {
	a := &c.analytics
	sync.mutex_lock(&a.mu)
	// The tracker only flushes once it has the READY analytics_token (events
	// queued earlier ride along in the first batch, as in the capture).
	if len(a.queue) == 0 || c.store.analytics_token == "" || (!force && (a.flush_at == 0 || now < a.flush_at)) {
		sync.mutex_unlock(&a.mu)
		return
	}
	token := c.store.analytics_token
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"token":`)
	json_write_escaped(&sb, token)
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
	sync.mutex_unlock(&a.mu)

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
	if rand.float64() > 0.1 do return
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
analytics_on_ready :: proc(c: ^Client) {
	a := &c.analytics
	if a.user_id != 0 do return
	a.user_id = c.store.me
	now := now_ms()
	a.next_client_hb = now
	a.next_ad_hb = now
}

// AccessibilityFeatureFlags bits the platform layer can know.
A11Y_REDUCED_MOTION :: 1 << 0
A11Y_PREFERS_COLOR_SCHEME_LIGHT :: 128
A11Y_PREFERS_COLOR_SCHEME_DARK :: 256
A11Y_FORCED_COLORS :: 262144
A11Y_FORCED_COLORS_FROM_USER_SETTINGS :: 524288

// client_set_viewport: window content size in CSS px (client_viewport_width/height).
client_set_viewport :: proc(c: ^Client, w, h: int) {
	sync.mutex_lock(&c.analytics.mu)
	c.analytics.viewport_w = w
	c.analytics.viewport_h = h
	sync.mutex_unlock(&c.analytics.mu)
}

// client_set_accessibility: the AccessibilityStore bitmask (OS color scheme,
// reduced motion, user accessibility settings) as the UI knows it.
client_set_accessibility :: proc(c: ^Client, flags: u64) {
	sync.mutex_lock(&c.analytics.mu)
	c.analytics.accessibility = flags
	c.analytics.accessibility_known = true
	sync.mutex_unlock(&c.analytics.mu)
}

// Events the official client sends that we deliberately do NOT send because a
// required value cannot be measured truthfully in this client:
//   client_heartbeat                (Electron per-process memory arrays, JS heap)
//   app_native_crash                (Electron crash reporter / minidump state)
//   libdiscore_loaded               (wasm load of the web client)
//   ready_payload_received          (identify server timings / per-section byte sizes as computed by the JS store)
//   app_web_perf_startup_metrics, app_ui_viewed (web bundle loading / render metrics)
//   channel_opened, guild_viewed    (notification-preset / unread-setting resolution we don't model)
//   notification_permission_status  (OS notification permission: needs the platform layer)
//   dismissible_content_shown*, friends_list_viewed (UI-surface events: the app may send them via analytics_track)
analytics_unknowable :: [?]string{"client_heartbeat", "app_native_crash", "libdiscore_loaded", "ready_payload_received", "app_web_perf_startup_metrics", "app_ui_viewed", "channel_opened", "guild_viewed", "notification_permission_status"}
