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
	os_sdk_version: string; // "" omits the key (Linux)
	// Linux only ("" omits them): "$XDG_CURRENT_DESKTOP,$GDMSESSION", os-release PRETTY_NAME, native/flatpak, x11/wayland
	window_manager: string;
	distro: string;
	runtime_environment: string;
	display_server: string;
	client_build_number: s64;
	native_build_number: s64; // 0 = null (Linux has no native build)
	sec_ch_ua: string;
	sec_ch_ua_platform: string;
	accept_language: string;
	locale: string; // x-discord-locale (user's chosen UI locale)
	timezone: string; // x-discord-timezone (IANA)
	debug_options: string; // x-debug-options ("" omits the header)
	capabilities: s64;
	api_version: int;
}

// The host app updates through Discord's updater (not captured), so its versions are pinned: bump them
// together from a new capture's super properties. The web build is only the fallback: each launch learns
// the current one from the /app document (startup.jai `app_document_loaded`).
HOST_VERSION :: "0.0.419"; // macOS client_version
NATIVE_BUILD :: 96312; // macOS native_build_number (the updater's metadata_version)
WEB_BUILD :: 649389; // client_build_number
CHROME_VERSION :: "148.0.7778.280";
CHROME_MAJOR :: "148";
ELECTRON_VERSION :: "42.11.15";
// Guessed, no capture (traffic/CLIENT_RULES.md "Gateway, startup, identity").
WINDOWS_HOST_VERSION :: "1.0.9272";
WINDOWS_NATIVE_BUILD :: 96312;
LINUX_HOST_VERSION :: "0.0.125";

// electron_user_agent: Chrome's reduced user agent, whose OS token is frozen (every Mac is "Intel Mac OS X
// 10_15_7", every Windows "Windows NT 10.0; Win64; x64"), with Electron's insertions.
electron_user_agent :: (os_token: string, host_version: string) -> string {
	return join("Mozilla/5.0 (", os_token, ") AppleWebKit/537.36 (KHTML, like Gecko) discord/", host_version, " Chrome/", CHROME_VERSION, " Electron/", ELECTRON_VERSION, " Safari/537.36");
}

DEFAULT_USER_AGENT :: #run electron_user_agent("Macintosh; Intel Mac OS X 10_15_7", HOST_VERSION);

DEFAULT_PLATFORM :: Platform_Info.{
	os = "Mac OS X",
	browser = "Discord Client",
	release_channel = "stable",
	client_version = HOST_VERSION,
	os_version = "27.0.0",
	os_arch = "arm64",
	app_arch = "arm64",
	system_locale = "en-US",
	browser_user_agent = DEFAULT_USER_AGENT,
	browser_version = ELECTRON_VERSION,
	os_sdk_version = "27",
	client_build_number = WEB_BUILD,
	native_build_number = NATIVE_BUILD,
	sec_ch_ua = #run join("\"Not/A)Brand\";v=\"99\", \"Chromium\";v=\"", CHROME_MAJOR, "\""),
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

// host_platform: what the official client reports on this machine (procinfo_<os>.jai): the OS version and
// architecture, the system locale and timezone. The offline tests always use DEFAULT_PLATFORM.
#if OS == .LINUX host_platform :: linux_platform;
else #if OS == .WINDOWS host_platform :: windows_platform;
else host_platform :: darwin_platform;

// with_system: Electron's app locale (the OS's first preferred language resolved to a Chromium UI locale)
// is navigator.languages[0] and Accept-Language; the intl locale (x-discord-locale) starts as its Discord
// match until the user's language setting is known. timezone = Intl's resolved IANA zone ("" omits it).
with_system :: (p: *Platform_Info, os_language: string, timezone: string) {
	p.system_locale = chromium_locale(os_language);
	p.accept_language = p.system_locale;
	p.locale = discord_locale(p.system_locale);
	p.timezone = timezone;
}

// chromium_locale: l10n_util::CheckAndResolveLocale as Electron's app.getLocale() returns it ("de_DE.UTF-8"
// and "de-DE" -> "de", "en-AU" -> "en-GB", "es-MX" -> "es-419", "zh-Hant-TW" -> "zh-TW").
chromium_locale :: (tag: string) -> string {
	t := replace(tag, "_", "-",, temp);
	for u8.[#char ".", #char "@"] { i := find_index_from_left(t, it); if i >= 0 t = slice(t, 0, i); }
	parts := split(t, "-",, temp);
	lang := to_lower_copy(parts[0],, temp);
	region := ifx parts.count > 1 then to_upper_copy(parts[parts.count - 1],, temp) else "";
	script := ifx parts.count > 2 then parts[1] else "";
	if lang == {
		case "en"; return ifx array_find(string.["AU", "CA", "GB", "IE", "IN", "NZ", "ZA"], region) then "en-GB" else "en-US";
		case "es"; return ifx region == "" || region == "ES" then "es" else "es-419";
		case "pt"; return ifx region == "PT" then "pt-PT" else "pt-BR";
		case "fr"; return ifx region == "CA" then "fr-CA" else "fr";
		case "zh";
			if region == "HK" || region == "MO" return "zh-HK";
			return ifx region == "TW" || script == "Hant" then "zh-TW" else "zh-CN";
		case "sr"; if script == "Latn" return "sr-Latn";
		case "no"; lang = "nb";
		case "nn"; lang = "nb";
		case "iw"; lang = "he";
		case "tl"; lang = "fil";
	}
	for CHROMIUM_LOCALES if it == lang return it;
	return "en-US";
}

// discord_locale: the bundle's intl matcher (`getAvailableLocales` module) over the enabled UI locales in
// its order: exact, the language alone, es / nb / nn aliases, zh-Hant, then the first of the same language.
discord_locale :: (tag: string) -> string {
	for DISCORD_LOCALES if it == tag return it;
	parts := split(tag, "-",, temp);
	lang := parts[0];
	for DISCORD_LOCALES if it == lang return it;
	if parts.count == 1 && lang == "es" return "es-ES";
	if parts.count == 1 && (lang == "nb" || lang == "nn") return "no";
	if lang == "zh" && parts.count > 1 && parts[1] == "Hant" return "zh-TW";
	for DISCORD_LOCALES if begins_with(it, lang) && it.count > lang.count && it[lang.count] == #char "-" return it;
	return "en-US";
}

DISCORD_LOCALES :: string.["en-US", "en-GB", "zh-CN", "zh-TW", "cs", "da", "nl", "fr", "de", "el", "hu", "it", "ja", "ko", "pl", "pt-BR", "ru", "es-419", "es-ES", "sv-SE", "tr", "bg", "uk", "fi", "no", "hr", "ro", "lt", "th", "vi", "hi"];

CHROMIUM_LOCALES :: string.["af", "am", "ar", "as", "az", "be", "bg", "bn", "bs", "ca", "cs", "cy", "da", "de", "el", "et", "eu", "fa", "fi", "fil", "fr", "gl", "gu", "he", "hi", "hr", "hu", "hy", "id", "is", "it", "ja", "ka", "kk", "km", "kn", "ko", "ky", "lo", "lt", "lv", "mk", "ml", "mn", "mr", "ms", "my", "nb", "ne", "nl", "or", "pa", "pl", "ro", "ru", "si", "sk", "sl", "sq", "sr", "sv", "sw", "ta", "te", "th", "tr", "uk", "ur", "uz", "vi", "zu"];

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
	// The super properties went out: client_build_number stays as it is for the launch.
	build_sealed: bool;
	web_build: s64; // the last /app document's build (identity.tsv), 0 = none yet
	nonces: Nonce_Gen;
	allocator: Allocator;
}

identity_init :: (id: *Identity, platform: Platform_Info, allocator := context.allocator) {
	id.platform = platform;
	id.allocator = allocator;
	id.client_launch_id = uuid4(,, allocator);
	id.fast_connect_launch_id = uuid4(,, allocator);
	id.launch_signature = launch_signature(,, allocator);
	id.app_state = .Focused;
}

// identity_touch_heartbeat renews / creates the heartbeat session when the app is active.
identity_touch_heartbeat :: (id: *Identity, now: s64) -> bool {
	locks.lock(*id.mu);
	defer locks.unlock(*id.mu);
	return touch_heartbeat_locked(id, now);
}

touch_heartbeat_locked :: (id: *Identity, now: s64) -> bool {
	if id.app_state != .Focused || id.logged_out return false;
	created := heartbeat_session_expired(id.heartbeat, now);
	if created {
		free_str(id.heartbeat.uuid, id.allocator);
		id.heartbeat = .{uuid4(,, id.allocator), now, now};
	}
	id.heartbeat.last_used = now;
	return created;
}

current_heartbeat_locked :: (id: *Identity, now: s64) -> string {
	if id.logged_out || heartbeat_session_expired(id.heartbeat, now) return "";
	return id.heartbeat.uuid;
}

app_state_name :: (s: App_State) -> string { return ifx s == .Focused then "focused" else "unfocused"; }

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
	if p.os_sdk_version json_kstr(w, "os_sdk_version", p.os_sdk_version);
	if p.window_manager {
		json_kstr(w, "window_manager", p.window_manager);
		json_kstr(w, "distro", p.distro);
		json_kstr(w, "runtime_environment", p.runtime_environment);
		json_kstr(w, "display_server", p.display_server);
	}
	json_kint(w, "client_build_number", p.client_build_number);
	if p.native_build_number json_kint(w, "native_build_number", p.native_build_number);
	else json_knull(w, "native_build_number");
	json_knull(w, "client_event_source");
}

// super_properties_json is the decoded x-super-properties header.
super_properties_json :: (id: *Identity, now: s64, allocator := temp) -> string {
	locks.lock(*id.mu);
	defer locks.unlock(*id.mu);
	touch_heartbeat_locked(id, now);
	hb := current_heartbeat_locked(id, now);
	id.build_sealed = true;
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
		if hb json_kstr(*w, "client_heartbeat_session_id", hb);
		json_kstr(*w, "client_app_state", app_state_name(id.app_state));
	} else {
		json_kstr(*w, "client_app_state", app_state_name(id.app_state));
		if hb json_kstr(*w, "client_heartbeat_session_id", hb);
	}
	json_obj_end(*w);
	return json_string(*w);
}

super_properties_b64 :: (id: *Identity, now: s64, allocator := temp) -> string {
	return context_b64(super_properties_json(id, now), allocator);
}

// context_properties encodes x-context-properties: base64(JSON.stringify(ctx)).
context_location :: (location: string, allocator := temp) -> string {
	if !location return "";
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "location", location);
	json_obj_end(*w);
	return context_b64(json_string(*w), allocator);
}

context_b64 :: (json_text: string, allocator := temp) -> string { return base64_encode(json_text,, allocator); }

// identity_set_logged_out: LOGOUT drops the heartbeat session; LOGIN_SUCCESS
// starts a new one at once (fixture login_submit: op 41's initialization
// timestamp is the login's), which IDENTIFY does not carry yet.
identity_set_logged_out :: (id: *Identity, logged_out: bool, now: s64 = 0) {
	locks.lock(*id.mu);
	defer locks.unlock(*id.mu);
	id.logged_out = logged_out;
	if logged_out && id.heartbeat.uuid {
		free(id.heartbeat.uuid,, id.allocator);
		id.heartbeat = .{};
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

// identity_learn_build: the web build the /app document names, persisted for the next launch (web_build)
// and, with adopt, used at once while no super properties went out (the official client keeps a launch's
// build until it reloads).
identity_learn_build :: (id: *Identity, build: s64, adopt: bool) {
	locks.lock(*id.mu);
	id.web_build = build;
	if adopt && !id.build_sealed id.platform.client_build_number = build;
	locks.unlock(*id.mu);
}

// identity_load_build: the persisted web build, unless this fastcord pins a newer one.
identity_load_build :: (id: *Identity, build: s64) {
	id.web_build = build;
	id.platform.client_build_number = max(id.platform.client_build_number, build);
}

// identity_set_locale: x-discord-locale (LocaleStore). locale must be static (a DISCORD_LOCALES entry):
// workers copy the platform while the UI thread changes it.
identity_set_locale :: (id: *Identity, locale: string) {
	locks.lock(*id.mu);
	id.platform.locale = locale;
	locks.unlock(*id.mu);
}

// identity_platform: a consistent copy for another thread (the locale changes at run time).
identity_platform :: (id: *Identity) -> Platform_Info {
	locks.lock(*id.mu);
	defer locks.unlock(*id.mu);
	return id.platform;
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
	h.uuid = copy_string(h.uuid,, allocator);
	return h;
}

// launch_signature reproduces libdiscore's generateLaunchSignature(globalThis)
// (derived by running the captured wasm and probing it): a random uuid whose
// version nibble is 4 and variant 8/9, with one "detection" bit per client-mod
// family (BetterDiscord, rambox, revenge/vendetta/bunny/kettu, Vencord/Vesktop,
// replugged, legcord, Dorion, GCDP, openasar, shelter, moonlight) that is set
// when the family's global exists. A clean client has all of them cleared:
//   sig = random & ~LAUNCH_SIG_ZERO | LAUNCH_SIG_ONE
LAUNCH_SIG_ZERO :: u8.[0x00, 0x80, 0x10, 0x10, 0x08, 0x10, 0xb8, 0x00, 0x60, 0x81, 0x00, 0x40, 0x01, 0x00, 0x08, 0x00];
LAUNCH_SIG_ONE :: u8.[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];

launch_signature :: () -> string {
	b: [16]u8;
	crypto.random_bytes(b);
	for * b it.* = (it.* & ~LAUNCH_SIG_ZERO[it_index]) | LAUNCH_SIG_ONE[it_index];
	return uuid_format(b);
}

identity_app_state :: (id: *Identity) -> App_State {
	locks.lock(*id.mu);
	defer locks.unlock(*id.mu);
	return id.app_state;
}

