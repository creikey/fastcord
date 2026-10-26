package discord

import "core:encoding/base64"
import "core:math/rand"
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

ANALYTICS_FLUSH_DELAY_MS :: 400
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
	viewport_w:    int,
	viewport_h:    int,
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
	a.viewport_w = 1280
	a.viewport_h = 720
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
	// expandEventProperties
	strings.write_string(&sb, `,"client_performance_cpu":0,"client_performance_memory":`)
	strings.write_int(&sb, 1_100_000 + int(rand.uint32() % 60_000))
	strings.write_string(&sb, `,"cpu_core_count":`)
	strings.write_int(&sb, c.cfg.cpu_core_count if c.cfg.cpu_core_count > 0 else 14)
	strings.write_string(&sb, `,"accessibility_features":`)
	strings.write_int(&sb, 524416 if a.user_id != 0 else 128)
	strings.write_string(&sb, `,"rendered_locale":`)
	json_write_escaped(&sb, c.id.platform.locale)
	strings.write_string(&sb, `,"uptime_app":`)
	strings.write_i64(&sb, (now - c.launch_ms) / 1000)
	strings.write_string(&sb, `,"uptime_process_renderer":`)
	strings.write_i64(&sb, (now - c.launch_ms) / 1000 + 286)
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
	if len(a.queue) == 0 || (!force && (a.flush_at == 0 || now < a.flush_at)) {
		sync.mutex_unlock(&a.mu)
		return
	}
	token := c.store.analytics_token
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"token":`)
	if token != "" do json_write_escaped(&sb, token)
	else do strings.write_string(&sb, "null")
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
	if c.focused && now >= a.next_client_hb {
		a.next_client_hb = now + CLIENT_HEARTBEAT_INTERVAL_MS
		hb := identity_heartbeat_snapshot(&c.id)
		w: Json
		json_init(&w)
		json_obj(&w)
		json_kint(&w, "client_heartbeat_initialization_timestamp", hb.created_at)
		json_kint(&w, "client_heartbeat_version", 31)
		json_kint(&w, "client_heartbeat_renderer_memory", 520_000 + i64(rand.uint32() % 20_000))
		json_kint(&w, "client_heartbeat_renderer_memory_used_heap", 130_000 + i64(rand.uint32() % 10_000))
		json_key(&w, "electron_process_memory_private")
		json_raw(&w, "[-1,-1,-1,-1,-1,-1,-1]")
		json_key(&w, "electron_process_memory_private_and_shared")
		json_raw(&w, "[-1,279984,528208,111152,-1,201312,-1]")
		json_kbool(&w, "is_idle", false)
		json_kint(&w, "idle_duration_ms", now) // Date.now() - 0 when never idle, as captured
		json_kbool(&w, "is_afk", false)
		json_kbool(&w, "is_system_suspended", false)
		json_kbool(&w, "is_system_locked", false)
		json_obj_end(&w)
		analytics_track(c, "client_heartbeat", json_body(json_string(&w)))
	}
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

// channel_opened (ChannelHeader / chat view mount) with ChannelAnalytics props.
analytics_channel_opened :: proc(c: ^Client, channel_id: Snowflake, channel_view := "chat") {
	s := &c.store
	ch, ok := s.channels[channel_id]
	w: Json
	json_init(&w)
	json_obj(&w)
	json_ksnow(&w, "channel_id", channel_id)
	if ok && ch.guild_id != 0 {
		rs := s.read_states[channel_id]
		gs := s.guild_settings[ch.guild_id]
		muted := false
		for m in gs.muted_channels do if m == channel_id do muted = true
		preset := "all_messages" if gs.message_notifications == 0 else ("mentions" if gs.message_notifications == 1 else "nothing")
		json_kbool(&w, "channel_was_unread", channel_unread(s, channel_id))
		json_kint(&w, "channel_mention_count", i64(rs.mention_count))
		json_kbool(&w, "channel_is_muted", muted)
		json_kbool(&w, "channel_is_nsfw", ch.nsfw)
		json_kbool(&w, "channel_is_spoiler", false)
		json_kint(&w, "channel_resolved_unread_setting", 1)
		json_kstr(&w, "channel_preset", preset)
		json_ksnow(&w, "guild_id", ch.guild_id)
		json_kbool(&w, "guild_was_unread", false)
		json_kint(&w, "guild_mention_count", 0)
		json_kbool(&w, "guild_is_muted", gs.muted)
		json_kint(&w, "guild_resolved_unread_setting", 1)
		json_kstr(&w, "guild_preset", preset)
		if ch.parent_id != 0 do json_ksnow(&w, "parent_id", ch.parent_id)
		else do json_knull(&w, "parent_id")
		json_kbool(&w, "has_pending_member_action", false)
		json_kbool(&w, "can_send_message", true)
		json_kbool(&w, "is_app_dm", false)
	} else if ok {
		is_bot := false
		if len(ch.recipient_ids) > 0 {
			if u := user_get(s, ch.recipient_ids[0]); u != nil do is_bot = u.bot
		}
		json_kbool(&w, "is_app_dm", is_bot)
		friends := 0
		for r in ch.recipient_ids do if rel, rok := s.relationships[r]; rok && rel.kind == .Friend do friends += 1
		json_kint(&w, "friend_recipient_count", i64(friends))
		json_kint(&w, "non_friend_recipient_count", i64(len(ch.recipient_ids) - friends))
	}
	json_kstr(&w, "channel_view", channel_view)
	json_obj_end(&w)
	analytics_track(c, "channel_opened", json_body(json_string(&w)))
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
	// Launch-anchored events seen in coldstart captures (PremiumManager, notification check).
	analytics_schedule(c, c.launch_ms + 5579, "fetch_user_offer_started", `"call_location":"PremiumManager"`)
	analytics_schedule(c, c.launch_ms + 5581, "notification_permission_status", `"os_enabled":true`)
}
