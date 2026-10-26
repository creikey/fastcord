package discord

import "fc:locks"
import "core:crypto"
import "core:encoding/base64"
import "core:strings"

// What the official desktop client reports about itself. Defaults are the
// captured Discord 0.0.419 / Electron 42.11.15 / macOS 27 arm64 build.
Platform_Info :: struct {
	os:                  string,
	browser:             string,
	release_channel:     string,
	client_version:      string,
	os_version:          string,
	os_arch:             string,
	app_arch:            string,
	system_locale:       string,
	browser_user_agent:  string,
	browser_version:     string,
	os_sdk_version:      string,
	client_build_number: i64,
	native_build_number: i64,
	sec_ch_ua:           string,
	sec_ch_ua_platform:  string,
	accept_language:     string,
	locale:              string, // x-discord-locale (user's chosen UI locale)
	timezone:            string, // x-discord-timezone (IANA)
	debug_options:       string, // x-debug-options ("" omits the header)
	capabilities:        i64,
	api_version:         int,
}

DEFAULT_USER_AGENT :: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) discord/0.0.419 Chrome/148.0.7778.280 Electron/42.11.15 Safari/537.36"

DEFAULT_PLATFORM :: Platform_Info {
	os                  = "Mac OS X",
	browser             = "Discord Client",
	release_channel     = "stable",
	client_version      = "0.0.419",
	os_version          = "27.0.0",
	os_arch             = "arm64",
	app_arch            = "arm64",
	system_locale       = "en-US",
	browser_user_agent  = DEFAULT_USER_AGENT,
	browser_version     = "42.11.15",
	os_sdk_version      = "27",
	client_build_number = 649389,
	native_build_number = 96312,
	sec_ch_ua           = `"Not/A)Brand";v="99", "Chromium";v="148"`,
	sec_ch_ua_platform  = `"macOS"`,
	accept_language     = "en-US",
	locale              = "en-US",
	timezone            = "America/Los_Angeles",
	debug_options       = "bugReporterEnabled",
	// 1767421 when the private-channel-obfuscation localStorage key is set
	// (as on the captured install), else 1734653.
	capabilities        = 1767421,
	api_version         = 9,
}

// Analytics heartbeat session (SessionHeartbeatScheduler): a uuid persisted
// as LAST_CLIENT_HEARTBEAT_SESSION, refreshed while the app is active, and
// expired after 30 minutes without use.
HEARTBEAT_SESSION_TTL_MS :: 30 * 60 * 1000

Heartbeat_Session :: struct {
	uuid:       string,
	created_at: i64,
	last_used:  i64,
}

heartbeat_session_expired :: proc(h: Heartbeat_Session, now: i64) -> bool {
	return h.uuid == "" || HEARTBEAT_SESSION_TTL_MS + h.last_used - now <= 0
}

App_State :: enum u8 {
	Focused,
	Unfocused,
}

Identity :: struct {
	mu:                     locks.Mutex,
	platform:               Platform_Info,
	// The main bundle's client_launch_id (super properties, op 41).
	client_launch_id:       string,
	// fast-connect.js is a separate bundle with its own launch id module, so
	// the early IDENTIFY carries a different uuid than the super properties.
	fast_connect_launch_id: string,
	// Produced by libdiscore wasm (generateLaunchSignature); uuid-shaped.
	launch_signature:       string,
	installation_id:        string,
	heartbeat:              Heartbeat_Session,
	app_state:              App_State,
	// Super property key order depends on whether the heartbeat id existed
	// the first time the header was built (extendSuperProperties appends).
	hb_key_order_fixed:     bool,
	hb_before_app_state:    bool,
	nonces:                 Nonce_Gen,
	allocator:              Allocator,
}

identity_init :: proc(id: ^Identity, platform: Platform_Info, allocator := context.allocator) {
	id.platform = platform
	id.allocator = allocator
	id.client_launch_id = uuid4(allocator)
	id.fast_connect_launch_id = uuid4(allocator)
	id.launch_signature = launch_signature(allocator)
	id.app_state = .Focused
}

// identity_touch_heartbeat renews / creates the heartbeat session when the app is active.
identity_touch_heartbeat :: proc(id: ^Identity, now: i64) -> (created: bool) {
	locks.lock(&id.mu)
	defer locks.unlock(&id.mu)
	return touch_heartbeat_locked(id, now)
}

@(private)
touch_heartbeat_locked :: proc(id: ^Identity, now: i64) -> (created: bool) {
	if id.app_state != .Focused do return false
	if heartbeat_session_expired(id.heartbeat, now) {
		if id.heartbeat.uuid != "" do delete(id.heartbeat.uuid, id.allocator)
		id.heartbeat = {uuid4(id.allocator), now, now}
		created = true
	}
	id.heartbeat.last_used = now
	return
}

@(private)
current_heartbeat_locked :: proc(id: ^Identity, now: i64) -> string {
	if heartbeat_session_expired(id.heartbeat, now) do return ""
	return id.heartbeat.uuid
}

app_state_name :: proc(s: App_State) -> string {
	return "focused" if s == .Focused else "unfocused"
}

// write_base_properties writes the device properties shared by IDENTIFY and
// x-super-properties, in the client's key order.
@(private)
write_base_properties :: proc(w: ^Json, p: Platform_Info, launch_id: string) {
	json_kstr(w, "os", p.os)
	json_kstr(w, "browser", p.browser)
	json_kstr(w, "release_channel", p.release_channel)
	json_kstr(w, "client_version", p.client_version)
	json_kstr(w, "os_version", p.os_version)
	json_kstr(w, "os_arch", p.os_arch)
	json_kstr(w, "app_arch", p.app_arch)
	json_kstr(w, "system_locale", p.system_locale)
	json_kbool(w, "has_client_mods", false)
	json_kstr(w, "client_launch_id", launch_id)
	json_kstr(w, "browser_user_agent", p.browser_user_agent)
	json_kstr(w, "browser_version", p.browser_version)
	json_kstr(w, "os_sdk_version", p.os_sdk_version)
	json_kint(w, "client_build_number", p.client_build_number)
	json_kint(w, "native_build_number", p.native_build_number)
	json_knull(w, "client_event_source")
}

// super_properties_json is the decoded x-super-properties header.
super_properties_json :: proc(id: ^Identity, now: i64, allocator := context.temp_allocator) -> string {
	locks.lock(&id.mu)
	defer locks.unlock(&id.mu)
	touch_heartbeat_locked(id, now)
	hb := current_heartbeat_locked(id, now)
	if !id.hb_key_order_fixed {
		id.hb_key_order_fixed = true
		id.hb_before_app_state = hb != ""
	}
	w: Json
	json_init(&w, allocator)
	json_obj(&w)
	write_base_properties(&w, id.platform, id.client_launch_id)
	json_kstr(&w, "launch_signature", id.launch_signature)
	if id.hb_before_app_state {
		if hb != "" do json_kstr(&w, "client_heartbeat_session_id", hb)
		json_kstr(&w, "client_app_state", app_state_name(id.app_state))
	} else {
		json_kstr(&w, "client_app_state", app_state_name(id.app_state))
		if hb != "" do json_kstr(&w, "client_heartbeat_session_id", hb)
	}
	json_obj_end(&w)
	return json_string(&w)
}

super_properties_b64 :: proc(id: ^Identity, now: i64, allocator := context.temp_allocator) -> string {
	js := super_properties_json(id, now, context.temp_allocator)
	return base64.encode(transmute([]byte)js, allocator = allocator)
}

// context_properties encodes x-context-properties: base64(JSON.stringify(ctx)).
context_location :: proc(location: string, allocator := context.temp_allocator) -> string {
	if location == "" do return ""
	w: Json
	json_init(&w)
	json_obj(&w)
	json_kstr(&w, "location", location)
	json_obj_end(&w)
	return base64.encode(transmute([]byte)json_string(&w), allocator = allocator)
}

context_b64 :: proc(json_text: string, allocator := context.temp_allocator) -> string {
	return base64.encode(transmute([]byte)json_text, allocator = allocator)
}

identity_set_app_state :: proc(id: ^Identity, s: App_State) {
	locks.lock(&id.mu)
	id.app_state = s
	locks.unlock(&id.mu)
}

identity_heartbeat_snapshot :: proc(id: ^Identity, allocator := context.temp_allocator) -> Heartbeat_Session {
	locks.lock(&id.mu)
	defer locks.unlock(&id.mu)
	h := id.heartbeat
	h.uuid = strings.clone(h.uuid, allocator)
	return h
}

// launch_signature reproduces libdiscore's generateLaunchSignature(globalThis)
// (derived by running the captured wasm and probing it): a random uuid whose
// version nibble is 4 and variant 8/9, with one "detection" bit per client-mod
// family (BetterDiscord, rambox, revenge/vendetta/bunny/kettu, Vencord/Vesktop,
// replugged, legcord, Dorion, GCDP, openasar, shelter, moonlight) that is set
// when the family's global exists. A clean client has all of them cleared:
//   sig = random & ~LAUNCH_SIG_ZERO | LAUNCH_SIG_ONE
LAUNCH_SIG_ZERO := [16]byte{0x00, 0x80, 0x10, 0x10, 0x08, 0x10, 0xb8, 0x00, 0x60, 0x81, 0x00, 0x40, 0x01, 0x00, 0x08, 0x00}
LAUNCH_SIG_ONE := [16]byte{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}

launch_signature :: proc(allocator := context.allocator) -> string {
	b: [16]byte
	crypto.rand_bytes(b[:])
	for i in 0 ..< 16 do b[i] = (b[i] & ~LAUNCH_SIG_ZERO[i]) | LAUNCH_SIG_ONE[i]
	return uuid_format(b, allocator)
}

launch_signature_is_clean :: proc(sig: string) -> bool {
	b, ok := uuid_parse(sig)
	if !ok do return false
	for i in 0 ..< 16 do if b[i] & LAUNCH_SIG_ZERO[i] != 0 || b[i] & LAUNCH_SIG_ONE[i] != LAUNCH_SIG_ONE[i] do return false
	return true
}
