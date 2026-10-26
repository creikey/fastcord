package discord

import "core:strings"
import "core:sync"

// Startup requests: the REST calls the official client makes on its own
// after launch / after READY. Kept as a table so tools/trafficdiff can check
// the schedule. Times are ms after the anchor and come from the committed
// official fixtures (traffic/*.jsonl, Discord 0.0.419): offsets relative to
// the scenario's reload mark, which for us is client_start.
//
// What the client loads depends on the route it reopens on:
//   Home    /channels/@me              (friends list: referrals, changelog, affinities...)
//   Private /channels/@me/<dm>
//   Guild   /channels/<guild>/<channel> (lurker check, guild-open set, no home widgets)

Route_Kind :: enum u8 {
	Home,
	Private,
	Guild,
}
Routes :: bit_set[Route_Kind]
ALL_ROUTES :: Routes{.Home, .Private, .Guild}

Startup_Anchor :: enum u8 {
	Launch, // client_start (= the official renderer's reload)
	Ready, // READY dispatch received
}

Startup_Kind :: enum u8 {
	Api_Get,
	Api_Post_Json,
	Api_Put_Json,
	Web_Get,
	Detectables, // cdn detectables json: fetch(cache:'no-cache') with If-None-Match (preflighted)
}

Startup_Entry :: struct {
	anchor:   Startup_Anchor,
	at_ms:    i64,
	kind:     Startup_Kind,
	host:     string, // Web_Get / Detectables
	path:     string, // Api: below /api/v9; may contain {country}, {locale}, {hb}, {ad}, {v5m}, {guild}
	body:     string, // Api_Post_Json / Api_Put_Json
	site:     Fetch_Site,
	ctx_json: string, // raw JSON for x-context-properties ("" = none)
	routes:   Routes,
	flags:    Startup_Flags,
	note:     string,
}

Startup_Flag :: enum u8 {
	Disabled,
	Etag, // remembers ETag, sends If-None-Match + cache-control: max-age=0 (fetch cache 'no-cache')
	No_Super_Props, // sent before the super properties are initialised
	Verified_Only, // account signal: READY user.verified (persisted for the next launch)
	Unverified_Only,
	Preflight_Only, // Detectables: only the CORS preflight; the request is its own entry later
}
Startup_Flags :: bit_set[Startup_Flag]

STARTUP_REQUESTS := [?]Startup_Entry {
	{.Launch, 767, .Api_Get, "", "/users/@me/referrals/eligibility", "", .Same_Origin, "", {.Home, .Private}, {}, ""},
	{.Launch, 775, .Api_Get, "", "/quests/@me", "", .Same_Origin, "", ALL_ROUTES, {.Verified_Only}, ""},
	{.Launch, 5500, .Api_Get, "", "/quests/@me", "", .Same_Origin, "", ALL_ROUTES, {.Unverified_Only}, "unverified accounts load quests late (fixtures: B 4.2-6.4 s)"},
	{.Launch, 775, .Api_Put_Json, "", "/guilds/{guild}/members/@me?lurker=true", "{}", .Same_Origin, "{}", {.Guild}, {}, "GuildJoinRequest lurker check"},
	{.Launch, 776, .Api_Get, "", "/quests/decision?placement=1&client_heartbeat_session_id={hb}&client_ad_session_id={ad}", "", .Same_Origin, `{"connection_type":"unknown"}`, ALL_ROUTES, {.Verified_Only}, "ads decision"},
	{.Ready, 0, .Web_Get, "status.discord.com", "/api/v2/scheduled-maintenances/upcoming.json", "", .Same_Site, "", ALL_ROUTES, {}, ""},
	{.Ready, 2, .Api_Get, "", "/users/%40me/badges", "", .Same_Origin, "", ALL_ROUTES, {}, ""},
	{.Ready, 1, .Api_Get, "", "/users/@me/affinities/v2/users", "", .Same_Origin, "", {.Home}, {.Unverified_Only}, "B (unverified) only"},
	{.Launch, 3177, .Api_Get, "", "/users/@me/affinities/v2/users", "", .Same_Origin, "", {.Home}, {.Unverified_Only}, ""},
	{.Launch, 3500, .Api_Get, "", "/users/@me/referrals/eligibility", "", .Same_Origin, "", {.Home}, {.Unverified_Only}, "re-polled ~320 ms after the cluster"},
	// DevTools shows both preflights first, then the requests in fetch order
	{.Launch, 3175, .Detectables, "cdn.discordapp.com", "/detectables/games-v1.json", "", .Cross_Site, "", ALL_ROUTES, {.Etag, .Preflight_Only}, ""},
	{.Launch, 3175, .Detectables, "cdn.discordapp.com", "/detectables/non-games-v1.json", "", .Cross_Site, "", ALL_ROUTES, {.Etag, .Preflight_Only}, ""},
	{.Launch, 3177, .Api_Get, "", "/users/@me/mfa/webauthn/credentials", "", .Same_Origin, "", ALL_ROUTES, {}, ""},
	{.Launch, 3177, .Api_Post_Json, "", "/users/@me/billing/user-offer", `{"allow_triggers":true}`, .Same_Origin, "", ALL_ROUTES, {.Verified_Only}, ""},
	{.Launch, 3177, .Api_Get, "", "/users/@me/billing/checkout-recovery", "", .Same_Origin, "", ALL_ROUTES, {.Verified_Only}, ""},
	{.Launch, 3177, .Api_Get, "", "/users/@me/collectibles-marketing?platform=0", "", .Same_Origin, "", ALL_ROUTES, {}, ""},
	{.Launch, 3178, .Api_Get, "", "/users/@me/library?country_code={country}", "", .Same_Origin, "", ALL_ROUTES, {}, ""},
	{.Launch, 3178, .Detectables, "cdn.discordapp.com", "/detectables/games-v1.json", "", .Cross_Site, "", ALL_ROUTES, {.Etag}, ""},
	{.Launch, 3178, .Api_Get, "", "/games/detectable/exclusions", "", .Same_Origin, "", ALL_ROUTES, {.Etag}, ""},
	{.Launch, 3178, .Detectables, "cdn.discordapp.com", "/detectables/non-games-v1.json", "", .Cross_Site, "", ALL_ROUTES, {.Etag}, ""},
	// x is the 5-minute bucket within the hour (max-age=300): within one
	// bucket Chrome serves it from its HTTP cache, so it is often absent.
	{.Launch, 3178, .Web_Get, "cdn.discordapp.com", "/changelogs/config_0.json?x={x5m}", "", .Cross_Site, "", ALL_ROUTES, {}, ""},
	{.Launch, 3178, .Api_Get, "", "/promotions?locale={locale}&platform=0", "", .Same_Origin, "", {.Home, .Private}, {}, "guild route: part of the guild-open set"},
	{.Launch, 3178, .Api_Get, "", "/users/@me/saved-messages?bookmark_ids=true", "", .Same_Origin, "", ALL_ROUTES, {}, ""},
	{.Launch, 3178, .Api_Get, "", "/partner-sdk/storefront-config", "", .Same_Origin, "", ALL_ROUTES, {}, ""},
	{.Launch, 6700, .Api_Get, "", "/users/@me/settings-proto/2", "", .Same_Origin, "", {.Guild}, {}, "FrecencyUserSettings lazy load (fixtures: 6.0-8.1 s)"},
	{.Launch, 7577, .Api_Get, "", "/quests/get-decisions?placement=3&num_decisions_requested=1&client_heartbeat_session_id={hb}&client_ad_session_id={ad}", "", .Same_Origin, `{"connection_type":"unknown"}`, ALL_ROUTES, {}, "ads decision"},
	{.Launch, 16571, .Web_Get, "cdn.discordapp.com", "/bad-domains/current_revision.txt", "", .Cross_Site, "", ALL_ROUTES, {}, "from coldstart_a/b (outside fixture windows)"},
}

@(private)
startup_expand :: proc(c: ^Client, path: string) -> string {
	out := path
	if strings.contains(out, "{country}") {
		cc := c.store.country_code if c.store.country_code != "" else "US"
		out, _ = strings.replace_all(out, "{country}", cc, context.temp_allocator)
	}
	if strings.contains(out, "{locale}") do out, _ = strings.replace_all(out, "{locale}", c.id.platform.locale, context.temp_allocator)
	if strings.contains(out, "{x5m}") do out, _ = strings.replace_all(out, "{x5m}", itoa(int(now_ms() / 300_000 % 12)), context.temp_allocator)
	if strings.contains(out, "{v5m}") do out, _ = strings.replace_all(out, "{v5m}", itoa(int(now_ms() / 300_000)), context.temp_allocator)
	if strings.contains(out, "{hb}") {
		hb := identity_heartbeat_snapshot(&c.id)
		out, _ = strings.replace_all(out, "{hb}", hb.uuid, context.temp_allocator)
	}
	if strings.contains(out, "{ad}") do out, _ = strings.replace_all(out, "{ad}", c.analytics.ad_session, context.temp_allocator)
	if strings.contains(out, "{guild}") do out, _ = strings.replace_all(out, "{guild}", snowflake_string(c.start_route_guild), context.temp_allocator)
	return out
}

client_route_kind :: proc(guild, channel: Snowflake) -> Route_Kind {
	if guild != 0 do return .Guild
	if channel != 0 do return .Private
	return .Home
}

// schedule_startup queues every enabled entry for an anchor and the start route.
schedule_startup :: proc(c: ^Client, anchor: Startup_Anchor) {
	base := now_ms()
	if anchor == .Launch do base = c.launch_ms
	route := client_route_kind(c.start_route_guild, c.start_route_channel)
	for e in STARTUP_REQUESTS {
		if e.anchor != anchor || .Disabled in e.flags || route not_in e.routes do continue
		if .Verified_Only in e.flags && !c.account_verified do continue
		if .Unverified_Only in e.flags && c.account_verified do continue
		j: ^Job
		switch e.kind {
		case .Api_Get, .Api_Post_Json, .Api_Put_Json:
			j = job_new(.Api, .Startup)
			switch e.kind {
			case .Api_Get:
				j.method = "GET"
			case .Api_Post_Json:
				j.method = "POST"
			case .Api_Put_Json:
				j.method = "PUT"
			case .Web_Get, .Detectables:
			}
			j.path = job_str(j, startup_expand(c, e.path))
			if e.kind != .Api_Get {
				j.body = transmute([]byte)job_str(j, e.body)
				j.content_type = "application/json"
			}
			if e.ctx_json != "" do j.context_b64 = job_str(j, context_b64(e.ctx_json))
			j.no_super_props = .No_Super_Props in e.flags
			j.etag = .Etag in e.flags
		case .Web_Get, .Detectables:
			j = job_new(.Web, .Startup)
			j.method = "GET"
			j.host = job_str(j, e.host)
			j.path = job_str(j, startup_expand(c, e.path))
			j.site = e.site
			j.etag = .Etag in e.flags
			j.preflight_if_etag = e.kind == .Detectables
			j.preflight_only = .Preflight_Only in e.flags
			if e.kind == .Detectables do preflight_note(c, j.host, j.path, j.preflight_only)
			j.no_cookies = e.kind == .Detectables // fetch(credentials:"omit")
		}
		j.not_before = base + e.at_ms
		// PremiumManager tracks the fetch as it starts (fixtures: batch +21-49 ms)
		if strings.has_prefix(e.path, "/users/@me/billing/user-offer") do analytics_schedule(c, j.not_before, "fetch_user_offer_started", `"call_location":"PremiumManager"`)
		job_submit(c, j)
	}
}

// ---- guild open (CHANNEL_SELECT into a guild / reopening on a guild route) ----
// When the first message page of the channel arrives: op 43 and this set;
// promotions joins the set on a guild start route.
// Session-once (first guild shown) and per-guild sets, issued when the first
// message page of a guild channel arrives (fixtures send_message, create_guild).
SESSION_GUILD_REQUESTS := [?]string {
	"/users/@me/unclaimed-games",
	"/users/@me/entitlements?with_sku=false&with_application=false&entitlement_type=11&exclude_ended=true",
	"/users/@me/applications/521842831262875670/entitlements?exclude_consumed=true",
}

PER_GUILD_REQUESTS := [?]string {
	"POST /guilds/{guild}/migrate-command-scope", // only when we own/administer the guild
	"/guilds/{guild}/entitlements?with_sku=true&with_application=true",
}

// schedule_guild_open: per-guild requests on first open in a session.
schedule_guild_open :: proc(c: ^Client, guild_id: Snowflake, with_promotions := false) {
	now := now_ms()
	g := guild_get(&c.store, guild_id)
	owner := g != nil && g.owner_id == c.store.me && c.store.me != 0
	gs := snowflake_string(guild_id)
	if !c.session_guild_set_done {
		c.session_guild_set_done = true
		for p in SESSION_GUILD_REQUESTS do api_get_later(c, p, 0)
		if with_promotions do api_get_later(c, startup_expand(c, "/promotions?locale={locale}&platform=0"), 0)
	}
	for p in PER_GUILD_REQUESTS {
		path := p
		method := "GET"
		if strings.has_prefix(path, "POST ") {
			if !owner do continue // useShouldShowChannelNotice: administrators only, once a day
			method = "POST"
			path = path[5:]
		}
		j := job_new(.Api, .Guild_Open)
		j.method = method
		expanded, _ := strings.replace_all(path, "{guild}", gs, context.temp_allocator)
		j.path = job_str(j, expanded)
		j.not_before = now
		job_submit(c, j)
	}
}

// schedule_experiments_fetch: kept for logged-out flows (the installation id
// of a logged-in client comes from READY.apex_experiments).
schedule_experiments_fetch :: proc(c: ^Client) {
	j := job_new(.Api, .Experiments)
	j.method = "GET"
	j.path = "/experiments?with_guild_experiments=true"
	j.retries = 3
	j.no_auth = true
	job_submit(c, j)
}

// ---- ETag memory for no-cache fetches (detectables, exclusions) ----

etag_get :: proc(c: ^Client, url: string) -> string {
	sync.mutex_lock(&c.etag_mu)
	defer sync.mutex_unlock(&c.etag_mu)
	v, ok := c.etags[url]
	return strings.clone(v, context.temp_allocator) if ok else ""
}

etag_put :: proc(c: ^Client, url, etag: string) {
	if etag == "" do return
	sync.mutex_lock(&c.etag_mu)
	defer sync.mutex_unlock(&c.etag_mu)
	if old, ok := c.etags[url]; ok {
		if old == etag do return
		delete(old, c.allocator)
		c.etags[url] = strings.clone(etag, c.allocator)
	} else {
		c.etags[strings.clone(url, c.allocator)] = strings.clone(etag, c.allocator)
	}
}
