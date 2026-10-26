package discord

import "core:strings"

// Startup requests: the REST calls the official client makes on its own
// after launch / after READY (coldstart captures, Discord 0.0.419). Kept as a
// table so tools/trafficdiff can check the schedule. Times are ms after the
// anchor. Analytics (/science) and ads/quests telemetry are listed but
// disabled by default: they carry client-generated event payloads we don't
// reproduce.

Startup_Anchor :: enum u8 {
	Launch, // client_start (the official renderer starts these ~0.8 s after navigation)
	Ready, // READY dispatch received
}

Startup_Kind :: enum u8 {
	Api_Get,
	Api_Post_Json,
	Web_Get,
}

Startup_Entry :: struct {
	anchor:  Startup_Anchor,
	at_ms:   i64,
	kind:    Startup_Kind,
	host:    string, // Web_Get
	path:    string, // Api: below /api/v9; may contain {country}, {locale}, {hb}, {ad}, {v5m}
	body:    string, // Api_Post_Json
	site:    Fetch_Site,
	ctx_json: string, // raw JSON for x-context-properties ("" = none)
	enabled: bool,
	note:    string,
}

// Offsets measured on coldstart_a/b. Launch-anchored entries fire on timers
// started at app init (identical in both captures: ~5.58 s, ~16.57 s);
// READY-anchored ones follow CONNECTION_OPEN.
STARTUP_REQUESTS := [?]Startup_Entry {
	{.Launch, 155, .Api_Get, "", "/users/@me/referrals/eligibility", "", .Same_Origin, "", true, "before READY (IDENTIFY+155ms)"},
	{.Launch, 158, .Api_Get, "", "/quests/@me", "", .Same_Origin, "", true, ""},
	{.Launch, 158, .Api_Get, "", "/quests/decision?placement=1&client_heartbeat_session_id={hb}&client_ad_session_id={ad}", "", .Same_Origin, `{"connection_type":"unknown"}`, false, "ads decision"},
	{.Ready, 0, .Web_Get, "status.discord.com", "/api/v2/scheduled-maintenances/upcoming.json", "", .Same_Site, "", true, ""},
	{.Ready, 1, .Api_Get, "", "/users/%40me/badges", "", .Same_Origin, "", true, ""},
	{.Ready, 1, .Api_Get, "", "/users/@me/affinities/v2/users", "", .Same_Origin, "", true, "seen in coldstart_b"},
	{.Ready, 59, .Api_Post_Json, "", "/science", "", .Same_Origin, "", false, "analytics batch"},
	{.Launch, 5579, .Api_Get, "", "/users/@me/mfa/webauthn/credentials", "", .Same_Origin, "", true, ""},
	{.Launch, 5579, .Api_Post_Json, "", "/users/@me/billing/user-offer", `{"allow_triggers":true}`, .Same_Origin, "", true, ""},
	{.Launch, 5580, .Api_Get, "", "/users/@me/billing/checkout-recovery", "", .Same_Origin, "", true, ""},
	{.Launch, 5580, .Api_Get, "", "/users/@me/collectibles-marketing?platform=0", "", .Same_Origin, "", true, ""},
	{.Launch, 5580, .Api_Get, "", "/users/@me/library?country_code={country}", "", .Same_Origin, "", true, ""},
	{.Launch, 5580, .Api_Get, "", "/games/detectable/exclusions", "", .Same_Origin, "", true, ""},
	{.Launch, 5580, .Web_Get, "cdn.discordapp.com", "/changelogs/config_0.json?x=5", "", .Cross_Site, "", true, ""},
	{.Launch, 5580, .Api_Get, "", "/promotions?locale={locale}&platform=0", "", .Same_Origin, "", true, ""},
	{.Launch, 5580, .Api_Get, "", "/users/@me/saved-messages?bookmark_ids=true", "", .Same_Origin, "", true, ""},
	{.Launch, 5580, .Api_Get, "", "/partner-sdk/storefront-config", "", .Same_Origin, "", true, ""},
	{.Launch, 5840, .Web_Get, "discord.com", "/assets/version.stable.json?_={v5m}", "", .Same_Origin, "", true, "Date.now()/300000"},
	{.Launch, 13571, .Api_Get, "", "/quests/get-decisions?placement=3&num_decisions_requested=1&client_heartbeat_session_id={hb}&client_ad_session_id={ad}", "", .Same_Origin, `{"connection_type":"unknown"}`, false, "ads decision"},
	{.Launch, 16571, .Web_Get, "cdn.discordapp.com", "/bad-domains/current_revision.txt", "", .Cross_Site, "", true, ""},
}

@(private)
startup_expand :: proc(c: ^Client, path: string) -> string {
	out := path
	if strings.contains(out, "{country}") {
		cc := "US"
		out, _ = strings.replace_all(out, "{country}", cc, context.temp_allocator)
	}
	if strings.contains(out, "{locale}") do out, _ = strings.replace_all(out, "{locale}", c.id.platform.locale, context.temp_allocator)
	if strings.contains(out, "{v5m}") do out, _ = strings.replace_all(out, "{v5m}", itoa(int(now_ms() / 300_000)), context.temp_allocator)
	if strings.contains(out, "{hb}") {
		hb := identity_heartbeat_snapshot(&c.id)
		out, _ = strings.replace_all(out, "{hb}", hb.uuid, context.temp_allocator)
	}
	if strings.contains(out, "{ad}") do out, _ = strings.replace_all(out, "{ad}", uuid4(context.temp_allocator), context.temp_allocator)
	return out
}

// schedule_startup queues every enabled entry for an anchor.
schedule_startup :: proc(c: ^Client, anchor: Startup_Anchor) {
	base := now_ms()
	if anchor == .Launch do base = c.launch_ms
	for e in STARTUP_REQUESTS {
		if e.anchor != anchor || !e.enabled do continue
		j: ^Job
		switch e.kind {
		case .Api_Get, .Api_Post_Json:
			j = job_new(.Api, .Startup)
			j.method = "GET" if e.kind == .Api_Get else "POST"
			j.path = job_str(j, startup_expand(c, e.path))
			if e.kind == .Api_Post_Json {
				j.body = transmute([]byte)job_str(j, e.body)
				j.content_type = "application/json"
			}
			if e.ctx_json != "" do j.context_b64 = job_str(j, context_b64(e.ctx_json))
		case .Web_Get:
			j = job_new(.Web, .Startup)
			j.method = "GET"
			j.host = job_str(j, e.host)
			j.path = job_str(j, startup_expand(c, e.path))
			j.site = e.site
		}
		j.not_before = base + e.at_ms
		job_submit(c, j)
	}
}

// schedule_experiments_fetch: a fresh install has no installation id; the
// client gets one from the logged-out GET /experiments (AuthenticationStore
// fetches it before login; response field `installation`, persisted as
// installation_id_v3). Sent without authorization like the login screen does.
schedule_experiments_fetch :: proc(c: ^Client) {
	j := job_new(.Api, .Experiments)
	j.method = "GET"
	j.path = "/experiments?with_guild_experiments=true"
	j.retries = 3
	j.no_auth = true
	job_submit(c, j)
}

// schedule_guild_open: per-guild requests on first open in a session.
schedule_guild_open :: proc(c: ^Client, guild_id: Snowflake) {
	j := job_new(.Api, .Guild_Open)
	j.method = "GET"
	j.path = job_str(j, strings.concatenate({"/guilds/", snowflake_string(guild_id), "/entitlements?with_sku=true&with_application=true"}, context.temp_allocator))
	j.not_before = now_ms() + 28
	job_submit(c, j)
	g := guild_get(&c.store, guild_id)
	if g != nil && g.owner_id == c.store.me && c.store.me != 0 {
		// useShouldShowChannelNotice: administrators POST migrate-command-scope once a day.
		m := job_new(.Api, .Guild_Open)
		m.method = "POST"
		m.path = job_str(m, strings.concatenate({"/guilds/", snowflake_string(guild_id), "/migrate-command-scope"}, context.temp_allocator))
		m.not_before = now_ms() + 27
		job_submit(c, m)
	}
}
