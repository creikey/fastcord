package discord

import "fc:locks"
import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"
import "fc:http"

// ---- public configuration ----

Config :: struct {
	token:                 string,
	// Directory for persisted state (installation id, cookies, heartbeat
	// session, alt-svc cache). "" disables persistence.
	state_dir:             string,
	platform:              Platform_Info, // zero value -> DEFAULT_PLATFORM
	gateway_url:           string, // "" -> wss://gateway.discord.gg
	disable_fast_connect:  bool,
	fast_connect:          bool, // derived: !disable_fast_connect
	disable_gateway:       bool, // REST only (tests)
	disable_startup:       bool, // skip the startup_requests table
	workers:               int, // REST worker threads (default 4)
	// Called from network threads whenever events are queued: the app calls
	// platform.request_frame() (or similar) and then client_poll on its thread.
	wakeup:                proc(data: rawptr),
	wakeup_data:           rawptr,
	round_tripper:         Round_Tripper, // replaces the network (tests / replay)
	h3:                    H3_Hook, // optional h3 override (default: fc:quic/h3 via fc:quic/altsvc)
	disable_h3:            bool,
	ws_open_delay_ms:      i64, // gateway socket open after client_start (0 = 190, <0 = immediately)
	fast_identify_delay_ms: i64, // fast-connect IDENTIFY after open (0 = 300, <0 = immediately)
	voice_self_mute:       bool, // op 4 self_mute sent on READY (the client's persisted mute state)
	disable_analytics:     bool, // no /science telemetry (the official client always sends it)
	initial_guild_id:      Snowflake, // the route the window opens on (referer)
	initial_channel_id:    Snowflake,
}

// ---- events (network threads -> UI thread) ----

Event_Kind :: enum u8 {
	Dispatch,
	State,
	Rest,
}

Rest_Op :: enum u8 {
	None,
	Fetch_Messages,
	Send_Message,
	Edit_Message,
	Delete_Message,
	Add_Reaction,
	Remove_Reaction,
	Typing,
	Ack,
	Open_Dm,
	Relationship,
	Fetch_Profile,
	Upload,
	Experiments,
	Startup,
	Guild_Open,
	Media,
	Settings,
}

Rest_Result :: struct {
	op:         Rest_Op,
	ok:         bool,
	status:     int, // HTTP status, 0 = network failure
	channel_id: Snowflake,
	message_id: Snowflake,
	user_id:    Snowflake,
	nonce:      Snowflake,
	id:         Snowflake, // created object (message, DM channel...)
	limit:      int,
	before:     Snowflake,
	tag:        u64, // caller-provided correlation value
}

Event :: struct {
	kind:   Event_Kind,
	name:   string,
	data:   V,
	arena:  ^virtual.Arena,
	state:  Connection_State,
	result: Rest_Result,
}

// ---- client ----

Client :: struct {
	cfg:              Config,
	allocator:        Allocator,
	ctx:              runtime.Context,
	token:            string,
	id:               Identity,
	jar:              Cookie_Jar,
	transport:        Transport,
	limiter:          Rate_Limiter,
	// The store is owned by the UI thread: read it freely between client_poll calls.
	store:            Store,
	gw:               ^Gateway,
	launch_ms:        i64,
	ready_ms:         i64,
	// event queue
	ev_mu:            locks.Mutex,
	events:           [dynamic]Event,
	// jobs
	job_mu:           locks.Mutex,
	job_cond:         locks.Cond,
	jobs:             [dynamic]^Job,
	workers:          [dynamic]^thread.Thread,
	quit:             bool,
	// route (referer) — written by the UI thread, read by workers
	route_mu:         locks.Mutex,
	route_guild:      Snowflake,
	route_channel:    Snowflake,
	// ack token chain (POST .../ack returns the next token)
	ack_mu:           locks.Mutex,
	ack_token:        string,
	qos_mu:           locks.Mutex,
	ready_qos_token:  string,
	// UI-thread state
	results:          [dynamic]Rest_Result,
	media_mu:         locks.Mutex,
	media_results:    [dynamic]Media_Result,
	subs:             Subscriptions,
	typing_local:     Typing_Local,
	pending_acks:     [dynamic]Pending_Ack,
	focused:          bool,
	settings_edit:    Settings_Edit,
	analytics:        Analytics,
	upload_seq:       int,
	quest_app_ids:    []Snowflake,
	start_route_guild:   Snowflake, // route the window opened on (startup table selection)
	start_route_channel: Snowflake,
	etag_mu:          locks.Mutex,
	etags:            map[string]string, // persisted If-None-Match memory
	ready_subscribed_guild: Snowflake, // op 37 already sent by the gateway on READY
	pending_guild_open: Snowflake,
	guild_open_promotions: bool, // op 43 + guild-open set wait for the first message page
	pending_private_open: Snowflake, // op 13 + recipient profile wait for the first page
	route_page_pending: bool, // first page of the start route channel not yet loaded (op 43 / guild open follow it) // from /quests/@me, for applications/public
	started_guilds:   map[Snowflake]bool,
	command_index_guilds: map[Snowflake]bool,
	command_index_user: bool,
	emoji_picker_opened: bool,
	home_opened:      bool,
	session_guild_set_done: bool,
	account_verified: bool, // READY user.verified, persisted (startup set selection before READY)
	pending_guild_create: bool,
	soundboard_loaded: bool,
	pending_soundboard_at: i64, // guilds whose open-time requests ran this session
	// traffic observers (tooling): see every gateway frame
	on_gateway_send:  proc(data: rawptr, op: Op, d: V),
	on_gateway_recv:  proc(data: rawptr, op: Op, t: string, d: V),
	on_gateway_frame: proc(data: rawptr, sent: bool, payload: V, wire_len: int), // whole {op,d,s,t} as sent/received
	on_ws_open:       proc(data: rawptr, url: string, headers: []http.Header),
	// app hook: every dispatch name as it arrives (network thread), with user_data
	on_dispatch:      proc(user_data: rawptr, name: string),
	user_data:        rawptr,
	on_ws_close:      proc(data: rawptr, code: int),
	observer_data:    rawptr,
}

client_create :: proc(cfg: Config, allocator := context.allocator) -> ^Client {
	context.allocator = allocator
	c := new(Client)
	c.cfg = cfg
	c.cfg.fast_connect = !cfg.disable_fast_connect
	if c.cfg.workers <= 0 do c.cfg.workers = 8 // Chrome issues the startup burst concurrently
	plat := cfg.platform
	if plat.os == "" do plat = DEFAULT_PLATFORM
	c.allocator = allocator
	c.ctx = context
	c.token = strings.clone(cfg.token)
	c.launch_ms = now_ms()
	c.focused = true
	identity_init(&c.id, plat, allocator)
	cookie_jar_init(&c.jar, allocator)
	transport_init(&c.transport, &c.jar, allocator)
	c.transport.override = cfg.round_tripper
	c.transport.h3 = cfg.h3
	c.transport.use_h3 = !cfg.disable_h3
	rate_limiter_init(&c.limiter, allocator)
	store_init(&c.store, allocator)
	c.events = make([dynamic]Event)
	c.jobs = make([dynamic]^Job)
	c.results = make([dynamic]Rest_Result)
	c.pending_acks = make([dynamic]Pending_Ack)
	c.started_guilds = make(map[Snowflake]bool)
	c.command_index_guilds = make(map[Snowflake]bool)
	subscriptions_init(&c.subs, allocator)
	analytics_init(&c.analytics, allocator)
	c.analytics.enabled = !cfg.disable_analytics
	c.route_guild = cfg.initial_guild_id
	c.route_channel = cfg.initial_channel_id
	c.start_route_guild = cfg.initial_guild_id
	c.start_route_channel = cfg.initial_channel_id
	c.etags = make(map[string]string)
	c.account_verified = true
	client_load_state(c)
	return c
}

// client_start launches workers, the startup request schedule and the gateway.
client_start :: proc(c: ^Client) {
	for _ in 0 ..< c.cfg.workers {
		th := thread.create_and_start_with_poly_data(c, worker_proc, c.ctx)
		append(&c.workers, th)
	}
	if c.focused do identity_touch_heartbeat(&c.id, now_ms())
	if !c.cfg.disable_startup do schedule_startup(c, .Launch)
	if !c.cfg.disable_gateway {
		c.gw = gateway_create(c)
		gateway_set_active(c.gw, qos_from_state(c.focused, false))
		gateway_start(c.gw)
	}
}

client_destroy :: proc(c: ^Client) {
	if c.gw != nil do gateway_stop(c.gw)
	locks.lock(&c.job_mu)
	c.quit = true
	locks.cond_broadcast(&c.job_cond)
	locks.unlock(&c.job_mu)
	for th in c.workers {
		thread.join(th)
		thread.destroy(th)
	}
	delete(c.workers)
	expr_pool_stop(c)
	client_save_state(c)
	for j in c.jobs do job_free(j)
	delete(c.jobs)
	for &e in c.events do event_free(&e)
	delete(c.events)
	transport_destroy(&c.transport)
	cookie_jar_destroy(&c.jar)
	rate_limiter_destroy(&c.limiter)
	delete(c.results)
	for &m in c.media_results do media_result_free(c, &m)
	delete(c.media_results)
	delete(c.pending_acks)
	delete(c.started_guilds)
	delete(c.command_index_guilds)
	delete(c.quest_app_ids)
	for k, v in c.etags {
		delete(k)
		delete(v)
	}
	delete(c.etags)
	store_destroy(&c.store)
	analytics_destroy(&c.analytics)
	delete(c.subs.guilds)
	for _, l in c.subs.channels do delete(l)
	delete(c.subs.channels)
	delete(c.subs.pending)
	delete(c.ack_token)
	delete(c.ready_qos_token)
	delete(c.token)
	id := &c.id
	delete(id.client_launch_id)
	delete(id.fast_connect_launch_id)
	delete(id.launch_signature)
	delete(id.installation_id)
	delete(id.heartbeat.uuid)
	free(c)
}

// ---- events ----

client_push_event :: proc(c: ^Client, ev: Event) {
	locks.lock(&c.ev_mu)
	append(&c.events, ev)
	locks.unlock(&c.ev_mu)
	if c.cfg.wakeup != nil do c.cfg.wakeup(c.cfg.wakeup_data)
}

client_push_state :: proc(c: ^Client, s: Connection_State) {
	client_push_event(c, Event{kind = .State, state = s})
}

@(private)
event_free :: proc(e: ^Event) {
	if e.arena != nil {
		virtual.arena_destroy(e.arena)
		free(e.arena)
		e.arena = nil
	}
}

// client_poll applies queued network events to the store. Call it on the UI
// thread (each frame, or after the wakeup callback). Returns true when the
// store changed (store.changed was bumped).
client_poll :: proc(c: ^Client) -> bool {
	locks.lock(&c.ev_mu)
	evs := c.events
	c.events = make([dynamic]Event, 0, max(len(evs), 8), c.allocator)
	locks.unlock(&c.ev_mu)
	defer delete(evs)
	changed := false
	now := now_ms()
	context.allocator = c.allocator
	for &e in evs {
		switch e.kind {
		case .Dispatch:
			if store_apply_dispatch(&c.store, e.name, e.data, now) do changed = true
			client_after_dispatch(c, e.name, e.data)
			extras_on_dispatch(c, e.name, e.data)
		case .State:
			c.store.connection = e.state
			changed = true
		case .Rest:
			client_apply_rest(c, &e)
			append(&c.results, e.result)
			changed = true
		}
		event_free(&e)
	}
	if store_expire_typing(&c.store, now) do changed = true
	subscriptions_flush(c)
	flush_due_acks(c, now)
	flush_typing_local(c, now)
	flush_settings(c, now)
	flush_soundboard(c, now)
	analytics_tick(c, now)
	analytics_flush(c, now)
	if changed do c.store.changed += 1
	return changed
}

// client_take_results returns REST completions since the last call (UI thread).
client_take_results :: proc(c: ^Client, allocator := context.temp_allocator) -> []Rest_Result {
	out := make([]Rest_Result, len(c.results), allocator)
	copy(out, c.results[:])
	clear(&c.results)
	return out
}

// ---- route / focus ----

client_route_referer :: proc(c: ^Client, allocator := context.temp_allocator) -> string {
	locks.lock(&c.route_mu)
	g, ch := c.route_guild, c.route_channel
	locks.unlock(&c.route_mu)
	return referer_for_route(g, ch, allocator)
}

// client_set_focused reports window focus: drives client_app_state in the
// super properties, the heartbeat session and the op 40 QoS payload.
client_set_focused :: proc(c: ^Client, focused: bool) {
	if c.focused == focused do return
	c.focused = focused
	identity_set_app_state(&c.id, .Focused if focused else .Unfocused)
	if focused do identity_touch_heartbeat(&c.id, now_ms())
	if c.gw != nil do gateway_set_active(c.gw, qos_from_state(focused, false))
}

// ---- persistence ----

@(private)
state_path :: proc(c: ^Client, name: string) -> string {
	return strings.concatenate({c.cfg.state_dir, "/", name}, context.temp_allocator)
}

client_load_state :: proc(c: ^Client) {
	if c.cfg.state_dir == "" do return
	_ = os.make_directory_all(c.cfg.state_dir)
	now := now_ms()
	cookie_jar_load(&c.jar, state_path(c, "cookies.tsv"), now)
	transport_set_altsvc_path(&c.transport, state_path(c, "altsvc.txt"))
	if data, err := os.read_entire_file(state_path(c, "etags.tsv"), context.temp_allocator); err == nil {
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			tab := strings.index_byte(line, '\t')
			if tab > 0 do c.etags[strings.clone(line[:tab], c.allocator)] = strings.clone(line[tab + 1:], c.allocator)
		}
	}
	if data, err := os.read_entire_file(state_path(c, "identity.tsv"), context.temp_allocator); err == nil {
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			tab := strings.index_byte(line, '\t')
			if tab < 0 do continue
			k, v := line[:tab], line[tab + 1:]
			switch k {
			case "installation_id":
				c.id.installation_id = strings.clone(v, c.allocator)
			case "verified":
				c.account_verified = v == "1"
			case "heartbeat_session":
				f := strings.split(v, "\t", context.temp_allocator)
				if len(f) == 3 {
					created, _ := strconv.parse_i64(f[1])
					last, _ := strconv.parse_i64(f[2])
					h := Heartbeat_Session{strings.clone(f[0], c.allocator), created, last}
					if !heartbeat_session_expired(h, now) {
						c.id.heartbeat = h
					} else {
						delete(h.uuid, c.allocator)
					}
				}
			}
		}
	}
}

client_save_state :: proc(c: ^Client) {
	if c.cfg.state_dir == "" do return
	_ = os.make_directory_all(c.cfg.state_dir)
	now := now_ms()
	cookie_jar_save(&c.jar, state_path(c, "cookies.tsv"), now)
	{
		eb := strings.builder_make(context.temp_allocator)
		locks.lock(&c.etag_mu)
		for k, v in c.etags {
			strings.write_string(&eb, k)
			strings.write_byte(&eb, '\t')
			strings.write_string(&eb, v)
			strings.write_byte(&eb, '\n')
		}
		locks.unlock(&c.etag_mu)
		write_file_atomic(state_path(c, "etags.tsv"), transmute([]byte)strings.to_string(eb))
	}
	sb := strings.builder_make(context.temp_allocator)
	locks.lock(&c.id.mu)
	strings.write_string(&sb, "verified\t")
	strings.write_string(&sb, "1" if c.account_verified else "0")
	strings.write_byte(&sb, '\n')
	if c.id.installation_id != "" {
		strings.write_string(&sb, "installation_id\t")
		strings.write_string(&sb, c.id.installation_id)
		strings.write_byte(&sb, '\n')
	}
	if c.id.heartbeat.uuid != "" {
		strings.write_string(&sb, "heartbeat_session\t")
		strings.write_string(&sb, c.id.heartbeat.uuid)
		strings.write_byte(&sb, '\t')
		strings.write_i64(&sb, c.id.heartbeat.created_at)
		strings.write_byte(&sb, '\t')
		strings.write_i64(&sb, c.id.heartbeat.last_used)
		strings.write_byte(&sb, '\n')
	}
	locks.unlock(&c.id.mu)
	write_file_atomic(state_path(c, "identity.tsv"), transmute([]byte)strings.to_string(sb))
}

// ---- READY hook (gateway thread) ----

client_on_ready :: proc(c: ^Client) {
	locks.lock(&c.job_mu)
	first := c.ready_ms == 0
	c.ready_ms = now_ms()
	locks.unlock(&c.job_mu)
	if first && !c.cfg.disable_startup {
		schedule_startup(c, .Ready)
		schedule_applications_public(c, c.ready_ms)
	}
}

