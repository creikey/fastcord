// ---- public configuration ----

Config :: struct {
	token: string;
	// Directory for persisted state (installation id, cookies, heartbeat
	// session, alt-svc cache). "" disables persistence.
	state_dir: string;
	platform: Platform_Info; // zero value -> DEFAULT_PLATFORM
	gateway_url: string; // "" -> wss://gateway.discord.gg
	disable_fast_connect: bool;
	fast_connect: bool; // derived: !disable_fast_connect
	disable_gateway: bool; // REST only (tests)
	disable_startup: bool; // skip the startup_requests table
	workers: int; // REST worker threads (default 16)
	// Called from network threads whenever events are queued: the app calls
	// platform.request_frame() (or similar) and then client_poll on its thread.
	wakeup: (data: *void);
	wakeup_data: *void;
	round_tripper: Round_Tripper; // replaces the network (tests / replay)
	// gateway_sink replaces the gateway socket (offline replay): every frame the
	// client would send goes here; dispatches are fed with client_inject_dispatch.
	gateway_sink: (data: *void, op: Op, d: V);
	gateway_sink_data: *void;
	h3: H3_Hook; // optional h3 override (default: fc:quic via fc:quic/altsvc)
	disable_h3: bool;
	ws_open_delay_ms: s64; // gateway socket open after client_start (0 = 190, <0 = immediately)
	fast_identify_delay_ms: s64; // fast-connect IDENTIFY after open (0 = 300, <0 = immediately)
	voice_self_mute: bool; // op 4 self_mute sent on READY (the client's persisted mute state)
	disable_analytics: bool; // no /science telemetry (the official client always sends it)
	disable_remote_auth: bool; // no QR code socket on the login page (tests)
	initial_guild_id: Snowflake; // the route the window opens on (referer)
	initial_channel_id: Snowflake;
}

// ---- events (network threads -> UI thread) ----

Event_Kind :: enum u8 {
	Dispatch;
	State;
	Rest;
}

Rest_Op :: enum u8 {
	None;
	Fetch_Messages;
	Send_Message;
	Edit_Message;
	Delete_Message;
	Add_Reaction;
	Remove_Reaction;
	Typing;
	Ack;
	Open_Dm;
	Relationship;
	Fetch_Profile;
	Upload;
	Experiments;
	Startup;
	Guild_Open;
	Media;
	Settings;
	Invite; // create_invite_async: channel_id, ok (the code: invite_code_for)
	Auth; // login page / logout (auth.odin; result.tag = Auth_Action)
}

Rest_Result :: struct {
	op: Rest_Op;
	ok: bool;
	status: int; // HTTP status, 0 = network failure
	channel_id: Snowflake;
	message_id: Snowflake;
	user_id: Snowflake;
	nonce: Snowflake;
	id: Snowflake; // created object (message, DM channel...)
	limit: int;
	before: Snowflake;
	tag: u64; // caller-provided correlation value
}

Event :: struct {
	kind: Event_Kind;
	name: string;
	data: V;
	arena: *Flat_Pool;
	state: Connection_State;
	result: Rest_Result;
}

// ---- client ----

Client :: struct {
	cfg: Config;
	allocator: Allocator;
	ctx: type_of(context);
	token: string;
	id: Identity;
	jar: Cookie_Jar;
	transport: Transport;
	limiter: Rate_Limiter;
	// The store is owned by the UI thread: read it freely between client_poll calls.
	store: Store;
	gw: *Gateway;
	launch_ms: s64;
	ready_ms: s64;
	// event queue
	ev_mu: locks.Mutex;
	events: [..]Event;
	// jobs
	job_mu: locks.Mutex;
	job_cond: locks.Cond;
	jobs: [..]*Job;
	jobs_running: int; // jobs taken off the queue and not finished (under job_mu)
	workers: [..]*Thread;
	quit: bool;
	// route (referer) — written by the UI thread, read by workers
	route_mu: locks.Mutex;
	route_guild: Snowflake;
	route_channel: Snowflake;
	// ack token chain (POST .../ack returns the next token)
	ack_mu: locks.Mutex;
	ack_token: string;
	qos_mu: locks.Mutex;
	ready_qos_token: string;
	// UI-thread state
	results: [..]Rest_Result;
	media_mu: locks.Mutex;
	media_results: [..]Media_Result;
	subs: Subscriptions;
	typing_local: Typing_Local;
	pending_acks: [..]Pending_Ack;
	focused: bool;
	settings_edit: Settings_Edit;
	analytics: Analytics;
	upload_seq: int;
	drafts: *Drafts; // staged attachment uploads (uploads.odin)
	webp_variation: s32; // atomic: upload WebP conversion experiment (webp_convert.odin)
	account_popout_opened: bool;
	quick_switcher: Quick_Switcher;
	members_requested: Snowflake_Pair_Set; // (guild, user) asked for with op 8
	rtc_regions: string; // comma list from the latency probe (under id.mu; persisted)
	quest_app_ids: []Snowflake;
	start_route_guild: Snowflake; // route the window opened on (startup table selection)
	start_route_channel: Snowflake;
	etag_mu: locks.Mutex;
	etags: Table(string, string); // persisted If-None-Match memory
	// CORS preflights sent ahead of their request (url -> 1 pending, 2 done)
	preflight_mu: locks.Mutex;
	preflight_cond: locks.Cond;
	preflights: Table(string, int);
	ready_subscribed_guild: Snowflake; // op 37 already sent by the gateway on READY
	pending_guild_open: Snowflake;
	guild_open_promotions: bool; // op 43 + guild-open set wait for the first message page
	pending_private_open: Snowflake; // op 13 + recipient profile wait for the first page
	route_page_pending: bool; // first page of the start route channel not yet loaded (op 43 / guild open follow it) // from /quests/@me, for applications/public
	started_guilds: Table(Snowflake, bool);
	left_guilds: Table(Snowflake, bool); // left this session: the next entry re-sends op 43
	command_index_guilds: Table(Snowflake, bool);
	command_index_user: bool;
	emoji_picker_opened: bool;
	social_mu: locks.Mutex; // social.nick_mod_props (worker reads)
	social: Social_State; // settings / calls / nickname UI analytics state (UI thread)
	pomelo: Pomelo_State; // username availability checks (username.odin)
	home_opened: bool;
	session_guild_set_done: bool;
	account_verified: bool; // READY user.verified, persisted (startup set selection before READY)
	pending_guild_create: bool;
	// invites (invites.odin): first code per channel (validate on later modal opens),
	// and the guild a Join a Server accept is waiting for (set on a worker)
	invite_mu: locks.Mutex;
	invite_codes: Table(Snowflake, string);
	pending_join_guild: Snowflake;
	pending_join_channel: Snowflake;
	soundboard_loaded: bool;
	pending_soundboard_at: s64; // guilds whose open-time requests ran this session
	// traffic observers (tooling): see every gateway frame
	on_gateway_send: (data: *void, op: Op, d: V);
	on_gateway_recv: (data: *void, op: Op, t: string, d: V);
	on_gateway_frame: (data: *void, sent: bool, payload: V, wire_len: int); // whole {op,d,s,t} as sent/received
	on_ws_open: (data: *void, url: string, headers: []http.Header);
	// app hook: every dispatch name as it arrives (network thread), with user_data
	on_dispatch: (user_data: *void, name: string);
	user_data: *void;
	on_ws_close: (data: *void, code: int);
	observer_data: *void;
	auth: Auth; // login / logout (auth.odin)
}

client_create :: (cfg: Config, allocator := context.allocator) -> *Client {
	push_allocator(allocator);
	c := new(Client);
	c.cfg = cfg;
	c.cfg.fast_connect = !cfg.disable_fast_connect;
	if c.cfg.workers <= 0 { c.cfg.workers = 16; } // Chrome issues the startup burst (13 requests) concurrently
	plat := cfg.platform;
	if plat.os == "" { plat = DEFAULT_PLATFORM; }
	c.allocator = allocator;
	c.ctx = context;
	c.token = clone(cfg.token);
	c.launch_ms = now_ms();
	c.focused = true;
	identity_init(*c.id, plat, allocator);
	cookie_jar_init(*c.jar, allocator);
	transport_init(*c.transport, *c.jar, allocator);
	c.transport.override = cfg.round_tripper;
	c.transport.h3 = cfg.h3;
	c.transport.use_h3 = !cfg.disable_h3;
	rate_limiter_init(*c.limiter, allocator);
	store_init(*c.store, allocator);
	feature_pool_retain(c);
	extras_retain();
	c.events = make_dynamic(Event, 0, 0);
	c.jobs = make_dynamic(*Job, 0, 0);
	c.results = make_dynamic(Rest_Result, 0, 0);
	c.pending_acks = make_dynamic(Pending_Ack, 0, 0);
	c.started_guilds.allocator = context.allocator;
	c.left_guilds.allocator = context.allocator;
	c.command_index_guilds.allocator = context.allocator;
	c.invite_codes.allocator = context.allocator;
	subscriptions_init(*c.subs, allocator);
	analytics_init(*c.analytics, allocator);
	c.analytics.enabled = !cfg.disable_analytics;
	c.route_guild = cfg.initial_guild_id;
	c.route_channel = cfg.initial_channel_id;
	c.start_route_guild = cfg.initial_guild_id;
	c.start_route_channel = cfg.initial_channel_id;
	c.etags.allocator = context.allocator;
	c.quick_switcher.fetched.allocator = c.allocator;
	c.preflights.allocator = c.allocator;
	c.account_verified = true;
	client_load_state(c);
	auth_init(c);
	return c;
}

// client_start launches workers, the startup request schedule and the gateway.
client_start :: (c: *Client) {
	for _: 0..cast(int)(c.cfg.workers)-1 {
		th := spawn(c, worker_proc);
		append(*c.workers, th);
	}
	if c.focused { identity_touch_heartbeat(*c.id, now_ms()); }
	if client_logged_out(c) {
		// the login page instead of the app (auth.odin)
		if !c.cfg.disable_startup { auth_cold_start(c); }
		return;
	}
	if !c.cfg.disable_startup { schedule_startup(c, .Launch); }
	if !c.cfg.disable_startup { schedule_rtc_probe(c, c.launch_ms); }
	if c.cfg.gateway_sink != null {
		c.gw = gateway_create(c); // never connects: gateway_send hands frames to the sink
	} else if !c.cfg.disable_gateway {
		c.gw = gateway_create(c);
		gateway_set_active(c.gw, qos_from_state(c.focused, false));
		gateway_start(c.gw);
	}
}

client_destroy :: (c: *Client) {
	if c.gw != null { gateway_stop(c.gw); }
	auth_shutdown(c);
	locks.lock(*c.job_mu);
	c.quit = true;
	locks.cond_broadcast(*c.job_cond);
	locks.unlock(*c.job_mu);
	for th: c.workers {
		locks.join(th);
	}
	delete(c.workers);
	feature_pool_release(c); // its feature jobs end before the transport goes
	expr_pool_stop(c);
	client_save_state(c);
	for j: c.jobs { job_free(j); }
	delete(c.jobs);
	drafts_destroy(c);
	pomelo_destroy(c);
	for * e: c.events { event_free(e); }
	delete(c.events);
	transport_destroy(*c.transport);
	cookie_jar_destroy(*c.jar);
	rate_limiter_destroy(*c.limiter);
	delete(c.results);
	for * m: c.media_results { media_result_free(c, m); }
	delete(c.media_results);
	delete(c.pending_acks);
	deinit(*c.started_guilds);
	deinit(*c.left_guilds);
	deinit(*c.command_index_guilds);
	delete(c.quest_app_ids);
	for v: c.invite_codes { delete(v); }
	deinit(*c.invite_codes);
	for v, k: c.etags {
		delete(k);
		delete(v);
	}
	deinit(*c.etags);
	quick_switcher_destroy(c);
	deinit(*c.members_requested);
	delete(c.rtc_regions, c.allocator);
	for v_, k: c.preflights { delete(k, c.allocator); }
	deinit(*c.preflights);
	extras_release(c);
	store_destroy(*c.store);
	auth_destroy(c);
	analytics_destroy(*c.analytics);
	social_destroy(c);
	deinit(*c.subs.guilds);
	for l: c.subs.channels { delete(l); }
	deinit(*c.subs.channels);
	delete(c.subs.pending);
	delete(c.ack_token);
	delete(c.ready_qos_token);
	delete(c.token);
	id := *c.id;
	delete(id.client_launch_id);
	delete(id.fast_connect_launch_id);
	delete(id.launch_signature);
	delete(id.installation_id);
	delete(id.heartbeat.uuid);
	free(c);
}

// ---- events ----

client_push_event :: (c: *Client, ev: Event) {
	locks.lock(*c.ev_mu);
	append(*c.events, ev);
	locks.unlock(*c.ev_mu);
	if c.cfg.wakeup != null { c.cfg.wakeup(c.cfg.wakeup_data); }
}

// client_inject_dispatch delivers a gateway dispatch as if received (offline
// replay with Config.gateway_sink). data must outlive the next client_poll.
client_inject_dispatch :: (c: *Client, name: string, data: V) {
	client_push_event(c, Event.{kind = .Dispatch, name = name, data = data});
}

client_push_state :: (c: *Client, s: Connection_State) {
	client_push_event(c, Event.{kind = .State, state = s});
}
#scope_module

event_free :: (e: *Event) {
	if e.arena != null {
		fini(e.arena);
		free(e.arena);
		e.arena = null;
	}
}
#scope_export

// client_poll applies queued network events to the store. Call it on the UI
// thread (each frame, or after the wakeup callback). Returns true when the
// store changed (store.changed was bumped).
client_poll :: (c: *Client) -> bool {
	locks.lock(*c.ev_mu);
	evs := c.events;
	c.events = make_dynamic(Event, 0, max(len(evs), 8), c.allocator);
	locks.unlock(*c.ev_mu);
	defer delete(evs);
	changed := false;
	now := now_ms();
	push_allocator(c.allocator);
	for * e: evs {
		if e.kind == {
		case .Dispatch;
			if store_apply_dispatch(*c.store, e.name, e.data, now) { changed = true; }
			client_after_dispatch(c, e.name, e.data);
			extras_on_dispatch(c, e.name, e.data);
		case .State;
			c.store.connection = e.state;
			changed = true;
		case .Rest;
			client_apply_rest(c, e);
			append(*c.results, e.result);
			changed = true;
		}
		event_free(e);
	}
	if store_expire_typing(*c.store, now) { changed = true; }
	subscriptions_flush(c);
	flush_due_acks(c, now);
	flush_typing_local(c, now);
	flush_quick_switcher(c, now);
	flush_settings(c, now);
	flush_soundboard(c, now);
	guild_admin_tick(c, now);
	auth_tick(c, now);
	flush_user_menu(c, now);
	flush_username_check(c, now);
	analytics_tick(c, now);
	analytics_flush(c, now);
	if changed { c.store.changed += 1; }
	return changed;
}

// client_take_results returns REST completions since the last call (UI thread).
client_take_results :: (c: *Client, allocator := temp) -> []Rest_Result {
	out := make_slice(Rest_Result, len(c.results), allocator);
	copy(out, view(c.results));
	clear(*c.results);
	return out;
}

// ---- route / focus ----

client_route_referer :: (c: *Client, allocator := temp) -> string {
	{ r := auth_referer(c, allocator);
	if r != "" { return r; } } // logged out: the login page
	locks.lock(*c.route_mu);
	g, ch := c.route_guild, c.route_channel;
	locks.unlock(*c.route_mu);
	return referer_for_route(g, ch, allocator);
}

// client_set_focused reports window focus: drives client_app_state in the
// super properties, the heartbeat session and the op 40 QoS payload.
client_set_focused :: (c: *Client, focused: bool) {
	if c.focused == focused { return; }
	c.focused = focused;
	identity_set_app_state(*c.id, ifx focused then .Focused else .Unfocused);
	if focused { identity_touch_heartbeat(*c.id, now_ms()); }
	if c.gw != null { gateway_set_active(c.gw, qos_from_state(focused, false)); }
}
#scope_module

// ---- persistence ----

state_path :: (c: *Client, name: string) -> string {
	return strings.concatenate(string.[c.cfg.state_dir, "/", name], temp);
}
#scope_export

client_load_state :: (c: *Client) {
	if c.cfg.state_dir == "" { return; }
	os.make_directory_all(c.cfg.state_dir);
	now := now_ms();
	cookie_jar_load(*c.jar, state_path(c, "cookies.tsv"), now);
	transport_set_altsvc_path(*c.transport, state_path(c, "altsvc.txt"));
	{ data, err := os.read_entire_file(state_path(c, "etags.tsv"), temp);
	if err == null {
		text := as_string(data);
		while true { line, __ok2 := strings.split_lines_iterator(*text); if !__ok2 break;
			tab := strings.index_byte(line, 9);
			if tab > 0 { table_set(*c.etags, clone(sub(line, 0, tab), c.allocator), clone(sub_from(line, tab + 1), c.allocator)); }
		}
	} }
	{ data, err := os.read_entire_file(state_path(c, "identity.tsv"), temp);
	if err == null {
		text := as_string(data);
		while true { line, __ok3 := strings.split_lines_iterator(*text); if !__ok3 break;
			tab := strings.index_byte(line, 9);
			if tab < 0 { continue; }
			k, v := sub(line, 0, tab), sub_from(line, tab + 1);
			if k == {
			case "installation_id";
				c.id.installation_id = clone(v, c.allocator);
			case "verified";
				c.account_verified = v == "1";
			case "rtc_regions";
				c.rtc_regions = clone(v, c.allocator);
			case "heartbeat_session";
				f := strings.split(v, "\t", temp);
				if len(f) == 3 {
					created, _ := strconv.parse_i64(f[1]);
					last, _ := strconv.parse_i64(f[2]);
					h := Heartbeat_Session.{clone(f[0], c.allocator), created, last};
					if !heartbeat_session_expired(h, now) {
						c.id.heartbeat = h;
					} else {
						delete(h.uuid, c.allocator);
					}
				}
			}
		}
	} }
}

client_save_state :: (c: *Client) {
	if c.cfg.state_dir == "" { return; }
	os.make_directory_all(c.cfg.state_dir);
	now := now_ms();
	cookie_jar_save(*c.jar, state_path(c, "cookies.tsv"), now);
	{
		eb := strings.builder_make(temp);
		locks.lock(*c.etag_mu);
		for v, k: c.etags {
			strings.write_string(*eb, k);
			strings.write_byte(*eb, 9);
			strings.write_string(*eb, v);
			strings.write_byte(*eb, 10);
		}
		locks.unlock(*c.etag_mu);
		write_file_atomic(state_path(c, "etags.tsv"), transmute([]u8, strings.to_string(eb)));
	}
	sb := strings.builder_make(temp);
	locks.lock(*c.id.mu);
	strings.write_string(*sb, "verified\t");
	strings.write_string(*sb, ifx c.account_verified then "1" else "0");
	strings.write_byte(*sb, 10);
	if c.rtc_regions != "" {
		strings.write_string(*sb, "rtc_regions\t");
		strings.write_string(*sb, c.rtc_regions);
		strings.write_byte(*sb, 10);
	}
	if c.id.installation_id != "" {
		strings.write_string(*sb, "installation_id\t");
		strings.write_string(*sb, c.id.installation_id);
		strings.write_byte(*sb, 10);
	}
	if c.id.heartbeat.uuid != "" {
		strings.write_string(*sb, "heartbeat_session\t");
		strings.write_string(*sb, c.id.heartbeat.uuid);
		strings.write_byte(*sb, 9);
		strings.write_i64(*sb, c.id.heartbeat.created_at);
		strings.write_byte(*sb, 9);
		strings.write_i64(*sb, c.id.heartbeat.last_used);
		strings.write_byte(*sb, 10);
	}
	locks.unlock(*c.id.mu);
	write_file_atomic(state_path(c, "identity.tsv"), transmute([]u8, strings.to_string(sb)));
}

// ---- READY hook (gateway thread) ----

client_on_ready :: (c: *Client) {
	locks.lock(*c.job_mu);
	first := c.ready_ms == 0;
	c.ready_ms = now_ms();
	locks.unlock(*c.job_mu);
	if first && auth_on_ready(c, c.ready_ms) { return; } // logged in from the login page: its own burst
	if first && !c.cfg.disable_startup {
		schedule_startup(c, .Ready);
		schedule_applications_public(c, c.ready_ms);
	}
}


