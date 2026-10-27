// What the official desktop client reports about itself. Defaults are the
// captured Discord 0.0.419 / Electron 42.11.15 / macOS 27 arm64 build.
Platform_Info :: struct {
	os: string;
	browser: string;
	release_channel: string;
	client_version: string;
	os_version: string;
	os_arch: string;
	app_arch: string;
	system_locale: string;
	browser_user_agent: string;
	browser_version: string;
	os_sdk_version: string;
	client_build_number: s64;
	native_build_number: s64;
	sec_ch_ua: string;
	sec_ch_ua_platform: string;
	accept_language: string;
	locale: string; // x-discord-locale (user's chosen UI locale)
	timezone: string; // x-discord-timezone (IANA)
	debug_options: string; // x-debug-options ("" omits the header)
	capabilities: s64;
	api_version: int;
}

DEFAULT_USER_AGENT :: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) discord/0.0.419 Chrome/148.0.7778.280 Electron/42.11.15 Safari/537.36";

DEFAULT_PLATFORM :: Platform_Info.{
	os = "Mac OS X",
	browser = "Discord Client",
	release_channel = "stable",
	client_version = "0.0.419",
	os_version = "27.0.0",
	os_arch = "arm64",
	app_arch = "arm64",
	system_locale = "en-US",
	browser_user_agent = DEFAULT_USER_AGENT,
	browser_version = "42.11.15",
	os_sdk_version = "27",
	client_build_number = 649389,
	native_build_number = 96312,
	sec_ch_ua = "\"Not/A)Brand\";v=\"99\", \"Chromium\";v=\"148\"",
	sec_ch_ua_platform = "\"macOS\"",
	accept_language = "en-US",
	locale = "en-US",
	timezone = "America/Los_Angeles",
	debug_options = "bugReporterEnabled",
	// 1767421 when the private-channel-obfuscation localStorage key is set
	// (as on the captured install), else 1734653.
	capabilities = 1767421,
	api_version = 9
};

// Analytics heartbeat session (SessionHeartbeatScheduler): a uuid persisted
// as LAST_CLIENT_HEARTBEAT_SESSION, refreshed while the app is active, and
// expired after 30 minutes without use.
HEARTBEAT_SESSION_TTL_MS :: 30 * 60 * 1000;

Heartbeat_Session :: struct {
	uuid: string;
	created_at: s64;
	last_used: s64;
}

heartbeat_session_expired :: (h: Heartbeat_Session, now: s64) -> bool {
	return h.uuid == "" || HEARTBEAT_SESSION_TTL_MS + h.last_used - now <= 0;
}

App_State :: enum u8 {
	Focused;
	Unfocused;
}

Identity :: struct {
	mu: locks.Mutex;
	platform: Platform_Info;
	// The main bundle's client_launch_id (super properties, op 41).
	client_launch_id: string;
	// fast-connect.js is a separate bundle with its own launch id module, so
	// the early IDENTIFY carries a different uuid than the super properties.
	fast_connect_launch_id: string;
	// Produced by libdiscore wasm (generateLaunchSignature); uuid-shaped.
	launch_signature: string;
	installation_id: string;
	heartbeat: Heartbeat_Session;
	app_state: App_State;
	// Super property key order depends on whether the heartbeat id existed
	// the first time the header was built (extendSuperProperties appends).
	hb_key_order_fixed: bool;
	hb_before_app_state: bool;
	// logged out: no heartbeat session. identify_hb_stale: logged in from the
	// login page, the super properties object IDENTIFY copies has not been
	// refreshed with the new session id yet (the HTTP util refreshes it per request)
	logged_out: bool;
	identify_hb_stale: bool;
	nonces: Nonce_Gen;
	allocator: Allocator;
}

identity_init :: (id: *Identity, platform: Platform_Info, allocator := context.allocator) {
	id.platform = platform;
	id.allocator = allocator;
	id.client_launch_id = uuid4(,, allocator);
	id.fast_connect_launch_id = uuid4(,, allocator);
	id.launch_signature = launch_signature(allocator);
	id.app_state = .Focused;
}

// identity_touch_heartbeat renews / creates the heartbeat session when the app is active.
identity_touch_heartbeat :: (id: *Identity, now: s64) -> bool {
	created: bool;
	locks.lock(*id.mu);
	defer locks.unlock(*id.mu);
	return touch_heartbeat_locked(id, now);
}
#scope_module

touch_heartbeat_locked :: (id: *Identity, now: s64) -> bool {
	created: bool;
	if id.app_state != .Focused || id.logged_out { return false; }
	if heartbeat_session_expired(id.heartbeat, now) {
		if id.heartbeat.uuid != "" { delete(id.heartbeat.uuid, id.allocator); }
		id.heartbeat = .{uuid4(,, id.allocator), now, now};
		created = true;
	}
	id.heartbeat.last_used = now;
	return created;
}

current_heartbeat_locked :: (id: *Identity, now: s64) -> string {
	if id.logged_out || heartbeat_session_expired(id.heartbeat, now) { return ""; }
	return id.heartbeat.uuid;
}
#scope_export

app_state_name :: (s: App_State) -> string {
	return ifx s == .Focused then "focused" else "unfocused";
}
#scope_module

// write_base_properties writes the device properties shared by IDENTIFY and
// x-super-properties, in the client's key order.
write_base_properties :: (w: *Json, p: Platform_Info, launch_id: string) {
	json_kstr(w, "os", p.os);
	json_kstr(w, "browser", p.browser);
	json_kstr(w, "release_channel", p.release_channel);
	json_kstr(w, "client_version", p.client_version);
	json_kstr(w, "os_version", p.os_version);
	json_kstr(w, "os_arch", p.os_arch);
	json_kstr(w, "app_arch", p.app_arch);
	json_kstr(w, "system_locale", p.system_locale);
	json_kbool(w, "has_client_mods", false);
	json_kstr(w, "client_launch_id", launch_id);
	json_kstr(w, "browser_user_agent", p.browser_user_agent);
	json_kstr(w, "browser_version", p.browser_version);
	json_kstr(w, "os_sdk_version", p.os_sdk_version);
	json_kint(w, "client_build_number", p.client_build_number);
	json_kint(w, "native_build_number", p.native_build_number);
	json_knull(w, "client_event_source");
}
#scope_export

// super_properties_json is the decoded x-super-properties header.
super_properties_json :: (id: *Identity, now: s64, allocator := temp) -> string {
	locks.lock(*id.mu);
	defer locks.unlock(*id.mu);
	touch_heartbeat_locked(id, now);
	hb := current_heartbeat_locked(id, now);
	if !id.hb_key_order_fixed {
		id.hb_key_order_fixed = true;
		id.hb_before_app_state = hb != "";
	}
	w: Json;
	json_init(*w, allocator);
	json_obj(*w);
	write_base_properties(*w, id.platform, id.client_launch_id);
	json_kstr(*w, "launch_signature", id.launch_signature);
	if id.hb_before_app_state {
		if hb != "" { json_kstr(*w, "client_heartbeat_session_id", hb); }
		json_kstr(*w, "client_app_state", app_state_name(id.app_state));
	} else {
		json_kstr(*w, "client_app_state", app_state_name(id.app_state));
		if hb != "" { json_kstr(*w, "client_heartbeat_session_id", hb); }
	}
	json_obj_end(*w);
	return json_string(*w);
}

super_properties_b64 :: (id: *Identity, now: s64, allocator := temp) -> string {
	js := super_properties_json(id, now, temp);
	return base64.encode(transmute([]u8, js), allocator = allocator);
}

// context_properties encodes x-context-properties: base64(JSON.stringify(ctx)).
context_location :: (location: string, allocator := temp) -> string {
	if location == "" { return ""; }
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "location", location);
	json_obj_end(*w);
	return base64.encode(transmute([]u8, json_string(*w)), allocator = allocator);
}

context_b64 :: (json_text: string, allocator := temp) -> string {
	return base64.encode(transmute([]u8, json_text), allocator = allocator);
}

// identity_set_logged_out: LOGOUT drops the heartbeat session; LOGIN_SUCCESS
// starts a new one at once (fixture login_submit: op 41's initialization
// timestamp is the login's), which IDENTIFY does not carry yet.
identity_set_logged_out :: (id: *Identity, logged_out: bool, now: s64 = 0) {
	locks.lock(*id.mu);
	defer locks.unlock(*id.mu);
	id.logged_out = logged_out;
	if logged_out && id.heartbeat.uuid != "" {
		delete(id.heartbeat.uuid, id.allocator);
		id.heartbeat = zero(type_of(id.heartbeat));
	}
	if !logged_out {
		touch_heartbeat_locked(id, now);
		id.identify_hb_stale = true;
	}
}

// identity_take_identify_hb_stale: true once after a login from the login page (IDENTIFY).
identity_take_identify_hb_stale :: (id: *Identity) -> bool {
	locks.lock(*id.mu);
	defer locks.unlock(*id.mu);
	v := id.identify_hb_stale;
	id.identify_hb_stale = false;
	return v;
}

// identity_hb_key_before_app_state: the super properties gained the heartbeat key before client_app_state.
identity_hb_key_before_app_state :: (id: *Identity) -> bool {
	locks.lock(*id.mu);
	defer locks.unlock(*id.mu);
	return id.hb_key_order_fixed && id.hb_before_app_state;
}

identity_set_app_state :: (id: *Identity, s: App_State) {
	locks.lock(*id.mu);
	id.app_state = s;
	locks.unlock(*id.mu);
}

identity_heartbeat_snapshot :: (id: *Identity, allocator := temp) -> Heartbeat_Session {
	locks.lock(*id.mu);
	defer locks.unlock(*id.mu);
	h := id.heartbeat;
	h.uuid = clone(h.uuid, allocator);
	return h;
}

// launch_signature reproduces libdiscore's generateLaunchSignature(globalThis)
// (derived by running the captured wasm and probing it): a random uuid whose
// version nibble is 4 and variant 8/9, with one "detection" bit per client-mod
// family (BetterDiscord, rambox, revenge/vendetta/bunny/kettu, Vencord/Vesktop,
// replugged, legcord, Dorion, GCDP, openasar, shelter, moonlight) that is set
// when the family's global exists. A clean client has all of them cleared:
//   sig = random & ~LAUNCH_SIG_ZERO | LAUNCH_SIG_ONE
LAUNCH_SIG_ZERO := u8.[0x00, 0x80, 0x10, 0x10, 0x08, 0x10, 0xb8, 0x00, 0x60, 0x81, 0x00, 0x40, 0x01, 0x00, 0x08, 0x00];
LAUNCH_SIG_ONE := u8.[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];

launch_signature :: (allocator := context.allocator) -> string {
	b: [16]u8;
	crypto.random_bytes(b);
	for i: 0..15 { b[i] = (b[i] & ~LAUNCH_SIG_ZERO[i]) | LAUNCH_SIG_ONE[i]; }
	return uuid_format(b,, allocator);
}

launch_signature_is_clean :: (sig: string) -> bool {
	b, ok := uuid_parse(sig);
	if !ok { return false; }
	for i: 0..15 { if (b[i] & LAUNCH_SIG_ZERO[i]) != 0 || (b[i] & LAUNCH_SIG_ONE[i]) != LAUNCH_SIG_ONE[i] { return false; } }
	return true;
}

identity_app_state :: (id: *Identity) -> App_State {
	locks.lock(*id.mu);
	defer locks.unlock(*id.mu);
	return id.app_state;
}

