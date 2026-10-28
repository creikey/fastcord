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

Route_Kind :: enum_flags u8 {
	Home;
	Private;
	Guild;
}
ALL_ROUTES :: (Route_Kind.Home | Route_Kind.Private | Route_Kind.Guild);

Startup_Anchor :: enum u8 {
	Launch; // client_start (= the official renderer's reload)
	Ready; // READY dispatch received
}

Startup_Kind :: enum u8 {
	Api_Get;
	Api_Post_Json;
	Api_Put_Json;
	Web_Get;
	Detectables; // cdn detectables json: fetch(cache:'no-cache') with If-None-Match (preflighted)
}

Startup_Entry :: struct {
	anchor: Startup_Anchor;
	at_ms: s64;
	kind: Startup_Kind;
	host: string; // Web_Get / Detectables
	path: string; // Api: below /api/v9; may contain {country}, {locale}, {x5m}, {hb}, {ad}, {guild}
	body: string; // Api_Post_Json / Api_Put_Json
	site: Fetch_Site;
	ctx_json: string; // raw JSON for x-context-properties ("" = none)
	routes: Route_Kind;
	flags: Startup_Flag;
	note: string;
}

Startup_Flag :: enum_flags u8 {
	Disabled;
	Etag; // remembers ETag, sends If-None-Match + cache-control: max-age=0 (fetch cache 'no-cache')
	No_Super_Props; // sent before the super properties are initialised
	Verified_Only; // account signal: READY user.verified (persisted for the next launch)
	Unverified_Only;
	Preflight_Only; // Detectables: only the CORS preflight; the request is its own entry later
}

STARTUP_REQUESTS :: Startup_Entry.[
	.{.Launch, 767, .Api_Get, "", "/users/@me/referrals/eligibility", "", .Same_Origin, "", (Route_Kind.Home | Route_Kind.Private), 0, ""},
	.{.Launch, 775, .Api_Get, "", "/quests/@me", "", .Same_Origin, "", ALL_ROUTES, (Startup_Flag.Verified_Only), ""},
	.{.Launch, 5500, .Api_Get, "", "/quests/@me", "", .Same_Origin, "", ALL_ROUTES, (Startup_Flag.Unverified_Only), "unverified accounts load quests late (fixtures: B 4.2-6.4 s)"},
	.{.Launch, 775, .Api_Put_Json, "", "/guilds/{guild}/members/@me?lurker=true", "{}", .Same_Origin, "{}", (Route_Kind.Guild), 0, "GuildJoinRequest lurker check"},
	.{.Launch, 776, .Api_Get, "", "/quests/decision?placement=1&client_heartbeat_session_id={hb}&client_ad_session_id={ad}", "", .Same_Origin, "{\"connection_type\":\"unknown\"}", ALL_ROUTES, (Startup_Flag.Verified_Only), "ads decision"},
	.{.Ready, 0, .Web_Get, "status.discord.com", "/api/v2/scheduled-maintenances/upcoming.json", "", .Same_Site, "", ALL_ROUTES, 0, ""},
	.{.Ready, 2, .Api_Get, "", "/users/%40me/badges", "", .Same_Origin, "", ALL_ROUTES, 0, ""},
	.{.Ready, 1, .Api_Get, "", "/users/@me/affinities/v2/users", "", .Same_Origin, "", (Route_Kind.Home), (Startup_Flag.Unverified_Only), "B (unverified) only"},
	.{.Ready, 2062, .Api_Get, "", "/users/@me/affinities/v2/users", "", .Same_Origin, "", (Route_Kind.Home), (Startup_Flag.Unverified_Only), ""},
	.{.Ready, 2385, .Api_Get, "", "/users/@me/referrals/eligibility", "", .Same_Origin, "", (Route_Kind.Home), (Startup_Flag.Unverified_Only), "re-polled ~320 ms after the cluster"},
	// DevTools shows both preflights first, then the requests in fetch order
	.{.Ready, 2060, .Detectables, "cdn.discordapp.com", "/detectables/games-v1.json", "", .Cross_Site, "", ALL_ROUTES, (Startup_Flag.Etag | Startup_Flag.Preflight_Only), ""},
	.{.Ready, 2060, .Detectables, "cdn.discordapp.com", "/detectables/non-games-v1.json", "", .Cross_Site, "", ALL_ROUTES, (Startup_Flag.Etag | Startup_Flag.Preflight_Only), ""},
	.{.Ready, 2062, .Api_Get, "", "/users/@me/mfa/webauthn/credentials", "", .Same_Origin, "", ALL_ROUTES, 0, ""},
	.{.Ready, 2062, .Api_Post_Json, "", "/users/@me/billing/user-offer", "{\"allow_triggers\":true}", .Same_Origin, "", ALL_ROUTES, (Startup_Flag.Verified_Only), ""},
	.{.Ready, 2062, .Api_Get, "", "/users/@me/billing/checkout-recovery", "", .Same_Origin, "", ALL_ROUTES, (Startup_Flag.Verified_Only), ""},
	.{.Ready, 2062, .Api_Get, "", "/users/@me/collectibles-marketing?platform=0", "", .Same_Origin, "", ALL_ROUTES, 0, ""},
	.{.Ready, 2063, .Api_Get, "", "/users/@me/library?country_code={country}", "", .Same_Origin, "", ALL_ROUTES, 0, ""},
	.{.Ready, 2063, .Detectables, "cdn.discordapp.com", "/detectables/games-v1.json", "", .Cross_Site, "", ALL_ROUTES, (Startup_Flag.Etag), ""},
	.{.Ready, 2063, .Api_Get, "", "/games/detectable/exclusions", "", .Same_Origin, "", ALL_ROUTES, (Startup_Flag.Etag), ""},
	.{.Ready, 2063, .Detectables, "cdn.discordapp.com", "/detectables/non-games-v1.json", "", .Cross_Site, "", ALL_ROUTES, (Startup_Flag.Etag), ""},
	// x is the 5-minute bucket within the hour (max-age=300): within one
	// bucket Chrome serves it from its HTTP cache, so it is often absent.
	.{.Ready, 2063, .Web_Get, "cdn.discordapp.com", "/changelogs/config_0.json?x={x5m}", "", .Cross_Site, "", ALL_ROUTES, 0, ""},
	.{.Ready, 2063, .Api_Get, "", "/promotions?locale={locale}&platform=0", "", .Same_Origin, "", (Route_Kind.Home | Route_Kind.Private), 0, "guild route: part of the guild-open set"},
	.{.Ready, 2063, .Api_Get, "", "/users/@me/saved-messages?bookmark_ids=true", "", .Same_Origin, "", ALL_ROUTES, 0, ""},
	.{.Ready, 2063, .Api_Get, "", "/partner-sdk/storefront-config", "", .Same_Origin, "", ALL_ROUTES, 0, ""},
	.{.Ready, 5130, .Api_Get, "", "/users/@me/settings-proto/2", "", .Same_Origin, "", (Route_Kind.Guild), 0, "FrecencyUserSettings lazy load (fixtures: mode READY +4.9-5.2 s, later after UI use)"},
	.{.Launch, 7577, .Api_Get, "", "/quests/get-decisions?placement=3&num_decisions_requested=1&client_heartbeat_session_id={hb}&client_ad_session_id={ad}", "", .Same_Origin, "{\"connection_type\":\"unknown\"}", ALL_ROUTES, 0, "ads decision"},
	.{.Launch, 16571, .Web_Get, "cdn.discordapp.com", "/bad-domains/current_revision.txt", "", .Cross_Site, "", ALL_ROUTES, 0, "from coldstart_a/b (outside fixture windows)"}
];

startup_expand :: (c: *Client, path: string) -> string {
	push_allocator(temp);
	out := path;
	if contains(out, "{country}") out = replace(out, "{country}", ifx c.store.country_code then c.store.country_code else "US");
	if contains(out, "{locale}") out = replace(out, "{locale}", c.id.platform.locale);
	if contains(out, "{x5m}") out = replace(out, "{x5m}", tprint("%", now_ms() / 300_000 % 12));
	if contains(out, "{hb}") out = replace(out, "{hb}", identity_heartbeat_snapshot(*c.id).uuid);
	if contains(out, "{ad}") out = replace(out, "{ad}", c.analytics.ad_session);
	if contains(out, "{guild}") out = replace(out, "{guild}", tprint("%", c.start_route_guild));
	return out;
}

client_route_kind :: (guild: Snowflake, channel: Snowflake) -> Route_Kind {
	if guild != 0 return .Guild;
	if channel != 0 return .Private;
	return .Home;
}

// schedule_startup queues every enabled entry for an anchor and the start route.
schedule_startup :: (c: *Client, anchor: Startup_Anchor) {
	base := ifx anchor == .Launch then c.launch_ms else now_ms();
	route := client_route_kind(c.start_route_guild, c.start_route_channel);
	// The post-READY burst (detectables, billing, library...) comes READY +
	// ~2.06 s, ~0.23 s later on the home route (33 fixtures: 2057-2109 vs 2295-2329).
	for e: STARTUP_REQUESTS {
		if e.anchor != anchor || (e.flags & .Disabled) || !(e.routes & route) continue;
		if (e.flags & .Verified_Only) && !c.account_verified continue;
		if (e.flags & .Unverified_Only) && c.account_verified continue;
		j: *Job;
		if e.kind == .Web_Get || e.kind == .Detectables {
			j = job_new(.Web, .Startup);
			j.method = "GET";
			j.host = job_str(j, e.host);
			j.path = job_str(j, startup_expand(c, e.path));
			j.site = e.site;
			j.etag = (e.flags & .Etag) != 0;
			j.preflight_if_etag = e.kind == .Detectables;
			j.preflight_only = (e.flags & .Preflight_Only) != 0;
			if e.kind == .Detectables preflight_note(c, j.host, j.path, j.preflight_only);
			j.no_cookies = e.kind == .Detectables; // fetch(credentials:"omit")
		} else {
			j = job_new(.Api, .Startup);
			j.method = ifx e.kind == .Api_Get then "GET" else ifx e.kind == .Api_Post_Json then "POST" else "PUT";
			j.path = job_str(j, startup_expand(c, e.path));
			if e.kind != .Api_Get {
				j.body = cast([]u8) job_str(j, e.body);
				j.content_type = "application/json";
			}
			if e.ctx_json j.context_b64 = job_str(j, context_b64(e.ctx_json));
			j.no_super_props = (e.flags & .No_Super_Props) != 0;
			j.etag = (e.flags & .Etag) != 0;
		}
		j.not_before = base + e.at_ms;
		if anchor == .Ready && route == .Home && e.at_ms >= 2000 j.not_before += 230;
		// PremiumManager tracks the fetch as it starts (fixtures: batch +21-49 ms)
		if begins_with(e.path, "/users/@me/billing/user-offer") {
			analytics_schedule(c, j.not_before, "fetch_user_offer_started", "\"call_location\":\"PremiumManager\"");
			// NotificationPermissionStore reads the OS permission in the same step; fastcord
			// asks for it on its first notification (synthesized: enabled)
			analytics_schedule(c, j.not_before, "notification_permission_status", "\"os_enabled\":true");
		}
		job_submit(c, j);
	}
}

// ---- guild open (CHANNEL_SELECT into a guild / reopening on a guild route) ----
// When the first message page of the channel arrives: op 43 and this set;
// promotions joins the set on a guild start route.
// Session-once (first guild shown) and per-guild sets, issued when the first
// message page of a guild channel arrives (fixtures send_message, create_guild).
SESSION_GUILD_REQUESTS :: string.[
	"/users/@me/unclaimed-games",
	"/users/@me/entitlements?with_sku=false&with_application=false&entitlement_type=11&exclude_ended=true",
	"/users/@me/applications/521842831262875670/entitlements?exclude_consumed=true"
];

PER_GUILD_REQUESTS :: string.[
	"POST /guilds/{guild}/migrate-command-scope", // only when we own/administer the guild
	"/guilds/{guild}/entitlements?with_sku=true&with_application=true"
];

// schedule_guild_open: per-guild requests on first open in a session.
schedule_guild_open :: (c: *Client, guild_id: Snowflake, with_promotions := false) {
	now := now_ms();
	g := guild_get(*c.store, guild_id);
	owner := g && g.owner_id == c.store.me && c.store.me != 0;
	if !c.session_guild_set_done {
		c.session_guild_set_done = true;
		for SESSION_GUILD_REQUESTS api_get_later(c, it, 0);
		if with_promotions api_get_later(c, startup_expand(c, "/promotions?locale={locale}&platform=0"), 0);
	}
	for p: PER_GUILD_REQUESTS {
		path := p;
		method := "GET";
		if begins_with(path, "POST ") {
			if !owner continue; // useShouldShowChannelNotice: administrators only, once a day
			method = "POST";
			path = advance(path, 5);
		}
		j := job_new(.Api, .Guild_Open);
		j.method = method;
		j.path = job_str(j, replace(path, "{guild}", tprint("%", guild_id),, temp));
		j.not_before = now;
		job_submit(c, j);
	}
}

// ---- ETag memory for no-cache fetches (detectables, exclusions) ----

etag_get :: (c: *Client, url: string) -> string {
	locks.lock(*c.etag_mu);
	defer locks.unlock(*c.etag_mu);
	_, v := table_find(*c.etags, url);
	return copy_string(v,, temp);
}

etag_put :: (c: *Client, url: string, etag: string) {
	if !etag return;
	locks.lock(*c.etag_mu);
	defer locks.unlock(*c.etag_mu);
	push_allocator(c.allocator);
	old := table_find_pointer(*c.etags, url);
	if old {
		if old.* == etag return;
		free(old.*);
		old.* = copy_string(etag);
	} else {
		table_set(*c.etags, copy_string(url), copy_string(etag));
	}
}
