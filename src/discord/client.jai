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
	h3: H3_Hook; // optional h3 override (default: quic via quic_altsvc)
	disable_h3: bool;
	ws_open_delay_ms: s64; // gateway socket open after client_start (0 = 190, <0 = immediately)
	fast_identify_delay_ms: s64; // fast-connect IDENTIFY after open (0 = 300, <0 = immediately)
	voice_self_mute: bool; // op 4 self_mute sent on READY (the client's persisted mute state)
	disable_analytics: bool; // no /science telemetry (the official client always sends it)
	disable_remote_auth: bool; // no QR code socket on the login page (tests)
	initial_guild_id: Snowflake; // the route the window opens on (referer)
	initial_channel_id: Snowflake;
	hosted: Hosted; // a self-hosted server instead of Discord (zero: Discord)
}

// A self-hosted server (`fastcord -serve`), spoken to with the plain profile: REST and the gateway go to
// host:port under the pinned certificate on ALPN fc/1, with the server ID as SNI. No compression, cookies,
// browser headers, super properties, telemetry or startup burst.
Hosted :: struct {
	host: string;
	port: int;
	pin: [32]u8;      // BLAKE3 of the server's certificate, from the invite.
	server_id: string; // 32 hex digits, from the invite.
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
	Auth; // login page / logout (auth.jai; result.tag = Auth_Action)
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
	route_scrolled_up: bool; // the open chat isn't at its newest message: incoming ones aren't acked
	voice_self: Voice_Self; // VoiceStateStore: the op 4 state READY and RESUMED send again (under route_mu)
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
	reaction_reqs: [..]Reaction_Req; // predicted reactions awaiting their response (actions.jai)
	reaction_seq: u64;
	focused: bool;
	// IdleStore: the last input time once the system has been idle 10 min, 0 = active. Written by the
	// gateway control thread (atomic); idle_sent is the value the last op 3 reported (UI thread).
	idle_since: s64;
	idle_sent: s64;
	presence_mirrored: Status; // the settings status last copied to the gateway (UI thread)
	settings_edit: Settings_Edit;
	analytics: Analytics;
	upload_seq: int;
	drafts: *Drafts; // staged attachment uploads (uploads.jai)
	webp_variation: s32; // atomic: upload WebP conversion experiment (webp_convert.jai)
	account_popout_opened: bool;
	quick_switcher: Quick_Switcher;
	members_requested: Snowflake_Pair_Set; // (guild, user) asked for with op 8
	rtc_regions: string; // comma list from the latency probe (under id.mu; persisted)
	rtc_probe_at: s64; // the next latency probe (under job_mu; 0: none)
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
	pomelo: Pomelo_State; // username availability checks (username.jai)
	home_opened: bool;
	session_guild_set_done: bool;
	account_verified: bool; // READY user.verified, persisted (startup set selection before READY)
	pending_guild_create: bool;
	// invites (invites.jai): first code per channel (validate on later modal opens),
	// and the guild a Join a Server accept is waiting for (set on a worker)
	invite_mu: locks.Mutex;
	invite_codes: Table(Snowflake, string);
	invite_previews: Table(string, Invite_Preview); // invite links in messages (invite_preview_key -> resolved guild)
	pending_join_guild: Snowflake;
	pending_join_channel: Snowflake;
	soundboard_loaded: bool; // the soundboard sounds were fetched this session (first RTC_CONNECTED)
	rtc_connected: bool; // our voice connection is RTC_CONNECTED (the QoS heartbeat's "rtc_connected")
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
	auth: Auth; // login / logout (auth.jai)
	hosted_mu: locks.Mutex;
	hosted_idle: [..]*http.H1_Conn; // keep-alive connections to cfg.hosted (netwrap.jai)
}

client_create :: (cfg: Config, allocator := context.allocator) -> *Client {
	push_allocator(allocator);
	c := New(Client);
	c.cfg = cfg;
	c.cfg.fast_connect = !cfg.disable_fast_connect;
	if c.cfg.workers <= 0 c.cfg.workers = 16; // Chrome issues the startup burst (13 requests) concurrently
	c.allocator = context.allocator;
	c.token = copy_string(cfg.token);
	c.voice_self.self_mute = cfg.voice_self_mute;
	c.launch_ms = now_ms();
	c.focused = true;
	identity_init(*c.id, ifx cfg.platform.os then cfg.platform else DEFAULT_PLATFORM, c.allocator);
	cookie_jar_init(*c.jar, c.allocator);
	transport_init(*c.transport, *c.jar, c.allocator);
	c.transport.override = cfg.round_tripper;
	c.transport.h3 = cfg.h3;
	c.transport.use_h3 = !cfg.disable_h3;
	if cfg.hosted.host {
		c.transport.override = .{c, hosted_round_trip};
		c.transport.use_h3 = false;
		c.cfg.disable_startup, c.cfg.disable_analytics, c.cfg.disable_remote_auth = true, true, true;
		c.hosted_idle.allocator = c.allocator;
	}
	rate_limiter_init(*c.limiter, c.allocator);
	store_init(*c.store, c.allocator);
	feature_pool_retain(c);
	extras_retain();
	// Workers and the gateway thread add to these: they keep the client's allocator, never a
	// thread's temp.
	c.events.allocator = c.allocator;
	c.jobs.allocator = c.allocator;
	c.workers.allocator = c.allocator;
	c.results.allocator = c.allocator;
	c.media_results.allocator = c.allocator;
	c.pending_acks.allocator = c.allocator;
	c.reaction_reqs.allocator = c.allocator;
	c.members_requested.allocator = c.allocator;
	c.started_guilds.allocator = c.allocator;
	c.left_guilds.allocator = c.allocator;
	c.command_index_guilds.allocator = c.allocator;
	c.invite_codes.allocator = c.allocator;
	c.invite_previews.allocator = c.allocator;
	c.etags.allocator = c.allocator;
	c.quick_switcher.fetched.allocator = c.allocator;
	c.preflights.allocator = c.allocator;
	subscriptions_init(*c.subs, c.allocator);
	analytics_init(*c.analytics, c.allocator);
	c.analytics.enabled = !cfg.disable_analytics;
	c.route_guild = cfg.initial_guild_id;
	c.route_channel = cfg.initial_channel_id;
	c.start_route_guild = cfg.initial_guild_id;
	c.start_route_channel = cfg.initial_channel_id;
	c.account_verified = true;
	client_load_state(c);
	auth_init(c);
	return c;
}

// client_start launches workers, the startup request schedule and the gateway.
client_start :: (c: *Client) {
	for 1..c.cfg.workers array_add(*c.workers, spawn(c, worker_proc));
	if c.focused identity_touch_heartbeat(*c.id, now_ms());
	if client_logged_out(c) {
		// the login page instead of the app (auth.jai)
		if !c.cfg.disable_startup auth_cold_start(c);
		return;
	}
	if !c.cfg.disable_startup {
		schedule_startup(c, .Launch);
	}
	if c.cfg.gateway_sink {
		c.gw = gateway_create(c); // never connects: gateway_send hands frames to the sink
	} else if !c.cfg.disable_gateway {
		c.gw = gateway_create(c);
		gateway_set_active(c.gw, qos_from_state(c.focused, false));
		gateway_start(c.gw);
	}
}

client_destroy :: (c: *Client) {
	push_allocator(c.allocator);
	client_flush_on_quit(c);
	if c.gw gateway_stop(c.gw);
	auth_shutdown(c);
	locks.lock(*c.job_mu);
	c.quit = true;
	locks.cond_broadcast(*c.job_cond);
	locks.unlock(*c.job_mu);
	for c.workers locks.join(it);
	array_free(c.workers);
	feature_pool_release(c); // its feature jobs end before the transport goes
	expr_pool_stop(c);
	client_save_state(c);
	for c.jobs job_free(it);
	array_free(c.jobs);
	drafts_destroy(c);
	pomelo_destroy(c);
	for * c.events event_free(it);
	array_free(c.events);
	transport_destroy(*c.transport);
	for c.hosted_idle { http.h1_destroy(it); free(it); }
	array_free(c.hosted_idle);
	cookie_jar_destroy(*c.jar);
	rate_limiter_destroy(*c.limiter);
	array_free(c.results);
	for * c.media_results media_result_free(c, it);
	array_free(c.media_results);
	array_free(c.pending_acks);
	for c.reaction_reqs { free(it.emoji.name); free(it.location); }
	array_free(c.reaction_reqs);
	deinit(*c.started_guilds);
	deinit(*c.left_guilds);
	deinit(*c.command_index_guilds);
	array_free(c.quest_app_ids);
	for c.invite_codes free(it);
	deinit(*c.invite_codes);
	for * v, k: c.invite_previews { free(k,, c.allocator); free(v.name,, c.allocator); free(v.icon,, c.allocator); free(v.error,, c.allocator); event_free(*v.event, c.allocator); }
	deinit(*c.invite_previews);
	for v, k: c.etags { free(k); free(v); }
	deinit(*c.etags);
	quick_switcher_destroy(c);
	deinit(*c.members_requested);
	free(c.rtc_regions);
	for v, k: c.preflights free(k);
	deinit(*c.preflights);
	extras_release(c);
	store_destroy(*c.store);
	auth_destroy(c);
	analytics_destroy(*c.analytics);
	social_destroy(c);
	subscriptions_clear(c);
	deinit(*c.subs.guilds);
	deinit(*c.subs.channels);
	array_free(c.subs.pending);
	free(c.ack_token);
	free(c.ready_qos_token);
	free(c.token);
	using c.id;
	free(client_launch_id);
	free(fast_connect_launch_id);
	free(launch_signature);
	free(installation_id);
	free(heartbeat.uuid);
	free(c);
}

// client_flush_on_quit: what the user did still reaches Discord when the client goes (quit, log out):
// acks waiting out their delay and the debounced settings write go now, and requests already due get
// up to 2 s before the workers stop. Later timers (startup loads) are dropped.
client_flush_on_quit :: (c: *Client) {
	now := now_ms();
	for * c.pending_acks it.due = 0;
	flush_due_acks(c, now);
	if c.settings_edit.due c.settings_edit.due = now;
	flush_settings(c, now);
	locks.lock(*c.job_mu);
	while now_ms() < now + 2000 {
		busy := c.jobs_running > 0;
		for c.jobs if it.not_before <= now busy = true;
		if !busy break;
		locks.cond_wait_with_timeout(*c.job_cond, *c.job_mu, 20);
	}
	locks.unlock(*c.job_mu);
}

// ---- events ----

client_push_event :: (c: *Client, ev: Event) {
	locks.lock(*c.ev_mu);
	array_add(*c.events, ev);
	locks.unlock(*c.ev_mu);
	if c.cfg.wakeup c.cfg.wakeup(c.cfg.wakeup_data);
}

// client_inject_dispatch delivers a gateway dispatch as if received (offline
// replay with Config.gateway_sink). data must outlive the next client_poll.
client_inject_dispatch :: (c: *Client, name: string, data: V) {
	client_push_event(c, .{kind = .Dispatch, name = name, data = data});
}

client_push_state :: (c: *Client, s: Connection_State) {
	client_push_event(c, .{kind = .State, state = s});
}

event_free :: (e: *Event) {
	if !e.arena return;
	fini(e.arena);
	free(e.arena);
	e.arena = null;
}

// client_poll applies queued network events to the store. Call it on the UI
// thread (each frame, or after the wakeup callback). Returns true when the
// store changed (store.changed was bumped).
client_poll :: (c: *Client) -> bool {
	locks.lock(*c.ev_mu);
	evs := array_copy(c.events,, temp);
	c.events.count = 0;
	locks.unlock(*c.ev_mu);
	changed := false;
	now := now_ms();
	push_allocator(c.allocator);
	for * e: evs {
		if e.kind == {
			case .Dispatch;
				if store_apply_dispatch(*c.store, e.name, e.data, now) changed = true;
				client_after_dispatch(c, e.name, e.data);
				extras_on_dispatch(c, e.name, e.data);
			case .State;
				c.store.connection = e.state;
				changed = true;
			case .Rest;
				client_apply_rest(c, e);
				array_add(*c.results, e.result);
				changed = true;
		}
		event_free(e);
	}
	if store_expire_typing(*c.store, now) changed = true;
	subscriptions_flush(c);
	flush_due_acks(c, now);
	flush_typing_local(c, now);
	flush_quick_switcher(c, now);
	status_expiry_tick(c, now);
	flush_settings(c, now);
	flush_presence(c);
	rtc_probe_tick(c, now);
	guild_admin_tick(c, now);
	auth_tick(c, now);
	flush_user_menu(c, now);
	flush_username_check(c, now);
	analytics_tick(c, now);
	analytics_flush(c, now);
	if changed c.store.changed += 1;
	return changed;
}

// client_take_results returns REST completions since the last call (UI thread).
client_take_results :: (c: *Client, allocator := temp) -> []Rest_Result {
	out := array_copy(c.results,, allocator);
	c.results.count = 0;
	return out;
}

// ---- route / focus ----

client_route_referer :: (c: *Client, allocator := temp) -> string {
	r := auth_referer(c, allocator);
	if r return r; // logged out: the login page
	locks.lock(*c.route_mu);
	g, ch := c.route_guild, c.route_channel;
	locks.unlock(*c.route_mu);
	return referer_for_route(g, ch, allocator);
}

// client_set_focused reports window focus: drives client_app_state in the
// super properties, the heartbeat session and the op 40 QoS payload.
client_set_focused :: (c: *Client, focused: bool) {
	if c.focused == focused return;
	c.focused = focused;
	identity_set_app_state(*c.id, ifx focused then .Focused else .Unfocused);
	if focused identity_touch_heartbeat(*c.id, now_ms());
	if c.gw gateway_set_active(c.gw, qos_from_state(focused, c.rtc_connected));
}

// flush_presence: SelfPresenceStore on IDLE / AFK. With the default AFK timeout (600 s) both flip at
// the same 10 min, and the store recomputes after each dispatch (IDLE first): two op 3s, the first
// with the old afk. Also keeps the gateway's copy of the status for a reconnect's IDENTIFY.
flush_presence :: (c: *Client) {
	if !c.gw return;
	st := c.store.settings.status;
	if st != .Offline && st != c.presence_mirrored {
		c.presence_mirrored = st;
		locks.lock(*c.gw.mu);
		c.gw.presence_status = st;
		locks.unlock(*c.gw.mu);
	}
	since := atomic_load(*c.idle_since);
	if since == c.idle_sent return;
	c.idle_sent = since;
	if c.store.connection != .Ready return; // shouldCommit: isSessionEstablished
	gateway_send(c.gw, .Presence_Update, presence_value(c, old_afk = true,, temp));
	gateway_send(c.gw, .Presence_Update, presence_value(c,, temp));
}

// idle_poll: IdleStore's powerMonitor poll (every 10 s, gateway control thread). Idle once the
// last input anywhere is over 10 min old; idleSince is that input's time (not before launch).
IDLE_AFTER_MS :: 600_000;
idle_poll :: (c: *Client, now: s64) {
	ms, ok := system_idle_ms();
	if !ok return;
	last_input := max(now - ms, c.launch_ms);
	idle := now - last_input > IDLE_AFTER_MS;
	if idle == (atomic_load(*c.idle_since) != 0) return;
	atomic_store(*c.idle_since, ifx idle then last_input else 0);
	if c.cfg.wakeup c.cfg.wakeup(c.cfg.wakeup_data);
}

// ---- persistence ----

state_path :: (c: *Client, name: string) -> string { return tprint("%/%", c.cfg.state_dir, name); }

client_load_state :: (c: *Client) {
	if !c.cfg.state_dir return;
	make_directory_if_it_does_not_exist(c.cfg.state_dir, recursive = true);
	now := now_ms();
	cookie_jar_load(*c.jar, state_path(c, "cookies.tsv"), now);
	transport_set_altsvc_path(*c.transport, state_path(c, "altsvc.txt"));
	text, ok := read_entire_file(state_path(c, "etags.tsv"), log_errors = false,, temp);
	if ok for line: split(text, "\n",, temp) {
		found, k, v := split_from_left(line, #char "\t");
		if found && k table_set(*c.etags, copy_string(k,, c.allocator), copy_string(v,, c.allocator));
	}
	text, ok = read_entire_file(state_path(c, "identity.tsv"), log_errors = false,, temp);
	if ok for line: split(text, "\n",, temp) {
		found, k, v := split_from_left(line, #char "\t");
		if !found continue;
		if k == {
			case "installation_id"; c.id.installation_id = copy_string(v,, c.allocator);
			case "verified";        c.account_verified = v == "1";
			case "rtc_regions";     c.rtc_regions = copy_string(v,, c.allocator);
			case "heartbeat_session";
				f := split(v, "\t",, temp);
				if f.count == 3 {
					h := Heartbeat_Session.{f[0], parse_s64(f[1]), parse_s64(f[2])};
					if !heartbeat_session_expired(h, now) {
						h.uuid = copy_string(h.uuid,, c.allocator);
						c.id.heartbeat = h;
					}
				}
		}
	}
}

client_save_state :: (c: *Client) {
	if !c.cfg.state_dir return;
	make_directory_if_it_does_not_exist(c.cfg.state_dir, recursive = true);
	cookie_jar_save(*c.jar, state_path(c, "cookies.tsv"), now_ms());
	sb: String_Builder;
	sb.allocator = temp;
	locks.lock(*c.etag_mu);
	for v, k: c.etags print_to_builder(*sb, "%\t%\n", k, v);
	locks.unlock(*c.etag_mu);
	write_file_atomic(state_path(c, "etags.tsv"), cast([]u8) builder_to_string(*sb,, temp));
	locks.lock(*c.id.mu);
	print_to_builder(*sb, "verified\t%\n", ifx c.account_verified then "1" else "0");
	if c.rtc_regions print_to_builder(*sb, "rtc_regions\t%\n", c.rtc_regions);
	if c.id.installation_id print_to_builder(*sb, "installation_id\t%\n", c.id.installation_id);
	using c.id.heartbeat;
	if uuid print_to_builder(*sb, "heartbeat_session\t%\t%\t%\n", uuid, created_at, last_used);
	locks.unlock(*c.id.mu);
	write_file_atomic(state_path(c, "identity.tsv"), cast([]u8) builder_to_string(*sb,, temp));
}

// ---- READY hook (gateway thread) ----

client_on_ready :: (c: *Client) {
	locks.lock(*c.job_mu);
	first := c.ready_ms == 0;
	c.ready_ms = now_ms();
	// RTCLatencyTestManager: POST_CONNECTION_OPEN (2 s after every READY), then 1-31 s later
	if !c.cfg.disable_startup c.rtc_probe_at = c.ready_ms + 3000 + cast(s64) (random_get_zero_to_one_open() * 30_000);
	locks.unlock(*c.job_mu);
	if first && auth_on_ready(c, c.ready_ms) return; // logged in from the login page: its own burst
	if first && !c.cfg.disable_startup {
		schedule_startup(c, .Ready);
		schedule_applications_public(c, c.ready_ms);
	}
}
