// Promotion surfaces fastcord never shows: the Shop, Nitro and Orbs upsells, the quests bar
// and the voice invite suggestions. The official client tracks them as they load and render,
// with no user action, so fastcord sends the same telemetry and loads (traffic/CLIENT_RULES.md
// "Promotions") and draws nothing (AGENTS.md). Engagement with sponsored content (quest and
// ad impressions, hovers, clicks, video progress, enrolment, claims) is never sent.

Promo_State :: struct {
	shop_mounted: bool; // the DM list (private routes) shows its Shop entry (UI thread)
	shop_version: s64; // atomic: the Shop entry marketing's version, 0 until /collectibles-marketing loads
	quest_roundtrip_sample: float64 = 0.1; // quest_decision_roundtrip (QuestRequestTracker: 10%)
	render_delay_sample: float64 = 0.1; // quest_bar_render_delay (QuestBarRenderDelayTracker: 10%)
	bar: Quest_Bar;
	editor_held: u8; // atomic: Editor_Held of the open profile editor
}

// ad_session_id: AdSessionStore's session (getOrCreate, called on every use): a new uuid once
// 30 minutes passed since it was last extended, which only enrolment does, so a passive client
// starts a new one every 30 minutes; none after a logout until the next use. Any thread.
ad_session_id :: (c: *Client) -> id: string, created: s64 {
	a := *c.analytics;
	now := now_ms();
	locks.lock(*a.mu);
	if a.ad_session == "" || now - a.ad_created > AD_SESSION_TTL_MS || now < a.ad_created {
		free(a.ad_session,, a.allocator);
		a.ad_session = uuid4(,, a.allocator);
		a.ad_created = now;
	}
	id, created := copy_string(a.ad_session,, temp), a.ad_created;
	locks.unlock(*a.mu);
	return id, created;
}

AD_SESSION_TTL_MS :: 30 * 60 * 1000;

// promo_shop_entry: the DM list mounted its Shop entry (a private route after a guild, a launch or
// login on one): COLLECTIBLES_SHOP_ENTRY_MARKETING. delay_ms > 0: after the route's own views
// (a navigation tracks it last). Unverified accounts show no Shop entry (fixture join_leave_server, B).
promo_shop_entry :: (c: *Client, delay_ms := 0) {
	if c.promo.shop_mounted || !c.account_verified return;
	c.promo.shop_mounted = true;
	analytics_dismissible(c, "COLLECTIBLES_SHOP_ENTRY_MARKETING", 0, guild = true, version = atomic_load(*c.promo.shop_version), delay_ms = delay_ms);
}

// promo_shop_marketing: /users/@me/collectibles-marketing answered (worker thread). Placement "0"
// is the DM list's Shop entry: its art loads at once (and is dropped), and a shown entry tracks
// itself again with the marketing's version.
promo_shop_marketing :: (c: *Client, body: V) {
	ASSET :: SHOP_CDN;
	m := fmap(fmap(vmap(body), "marketings"), "0");
	v := vget(m, "version");
	if v.kind != .Int || v.i <= 0 || v.i > 1_000_000 return;
	atomic_store(*c.promo.shop_version, v.i);
	asset := fstr(m, "asset");
	ok := begins_with(asset, ASSET) && asset.count <= ASSET.count + 128;
	for cast([]u8) advance(asset, min(asset.count, ASSET.count)) if !is_alnum(it) && it != #char "/" ok = false;
	if ok fetch_media(c, .{url = asset, kind = .Image, visible = true, discard = true});
	g, _ := route_now(c);
	if g == 0 && c.account_verified analytics_dismissible(c, "COLLECTIBLES_SHOP_ENTRY_MARKETING", 0, guild = true, version = v.i);
}

// promo_call_sounds: the voice panel's call sounds picker upsell, mounted as the call opens the
// microphone (fixtures join_voice_channel, dm_call; not for unverified B).
promo_call_sounds :: (c: *Client) {
	if !c.account_verified return;
	locks.lock(*c.route_mu);
	g := c.voice_self.guild_id;
	locks.unlock(*c.route_mu);
	analytics_dismissible(c, "CUSTOM_CALL_SOUNDS_PICKER_UPSELL", ifx g then 0 else 1, guild = true, guild_id = g);
}

// promo_voice_invite_entrypoint: the voice invite suggestions in the guild's channel list, shown
// once our voice connection is up while that guild is the route (fixtures join_voice_channel, voice_with_b).
promo_voice_invite_entrypoint :: (c: *Client, voice_channel: Snowflake) {
	ch := channel_get(*c.store, voice_channel);
	g, rc := route_now(c);
	if !ch || !ch.guild_id || ch.guild_id != g return;
	w := aw_begin();
	json_kstr(*w, "impression_type", "view");
	aw_route_props(*w, c, g, rc);
	json_ksnow(*w, "voice_channel_id", voice_channel);
	json_ksnow(*w, "voice_guild_id", g);
	aw_strs(*w, "location_stack", string.["guild channel list", "voice invite suggestions"]);
	json_kstr(*w, "location_section", "impression_voice_invite_suggestions_entrypoint");
	aw_track(c, "impression_voice_invite_suggestions_entrypoint", *w);
}

// promo_profile_upsells: the Nitro / Shop entry points of a profile surface as it renders
// (USER_PROFILE_PREMIUM_AND_SHOP_ENTRY_POINTS: 1 on our account popout and profile editor, 0 on
// popouts and the full profile, as captured).
promo_profile_upsells :: (c: *Client, count: int) {
	analytics_dismissible(c, "USER_PROFILE_PREMIUM_AND_SHOP_ENTRY_POINTS", count);
}

// ---- the quest bar (account panel, placement 1) ----
// AdDeliveryStore keeps the placement's decision; the bar renders its quest. useQuestBarFetch
// asks at mount ("questBar-open", the launch or login request) and every 30 s, restarted when
// the decision changes, checks it: once older than its TTL it refetches (/quests/@me, then the
// decision, "questBar-interval") in a focused window, or clears it when unfocused, which
// unmounts a shown bar. A failed request is retried no sooner than a 30 s .. 10 min backoff.
// The bar's mode tracker reports its mount (collapsed) and unmount (null); nothing else of it
// is sent without engagement. Shared by the workers and the UI thread (mu).

Quest_Bar :: struct {
	mu: locks.Mutex;
	started: bool; // the placement asked once (launch, login): the bar is mounted
	fetching: bool;
	caller: string; // the pending request's caller_source (a literal)
	visible_guilds: bool; // the last request listed the sidebar's guilds (the login's form)
	fetched_at: s64; // the decision's fetchedAt (its request's start; a cleared one: when cleared), 0 = none
	ttl_ms: s64;
	decision: [64]u8; // its request_id ("" when cleared)
	decision_len: int;
	quest: Snowflake; // the quest it serves, 0 = none
	shown_at: s64; // when the bar's mode tracker mounts (assets loaded), 0 = no bar
	props: [..]u8; // the shown quest's leading properties (quest_id .. quest_status)
	check_at: s64; // the next 30 s check
	retry_at: s64; // canRefreshAd after a failure
	backoff_ms: s64;
	delay_at: s64; // QuestBarRenderDelayTracker reports (stop or its 30 s timeout), 0 = idle
	delay_quest: Snowflake;
	delay_ms: s64; // the duration it reports
}

QUEST_CHECK_MS :: 30_000;
QUEST_TTL_MAX_MS :: 6 * 3600 * 1000;
QUEST_VISIBLE_MS :: 330; // the bar's assets loaded (logotype, hero video): its mode tracker mounts
QUEST_AT_REST_MS :: 130; // its visibility spring (tension 250, friction 10, clamped) at rest

// promo_quest_decision: the placement's /quests/decision answered (worker thread).
// recordQuestRequestApiResponse (quest_decision_roundtrip, 10 %), then for a served quest
// quest_decision_received, and the bar: the previous quest's unmounts, a new one mounts.
promo_quest_decision :: (c: *Client, j: *Job, r: Api_Response) {
	b := *c.promo.bar;
	now := now_ms();
	start := cast(s64) j.started_ms;
	m := vmap(r.body);
	// fetchQuestToDeliver: a quest creative, or the bare quest when there is no creative or a
	// bounty without its experiment; no-fill and other creatives serve nothing
	cr := fmap(m, "creative");
	ctype := fint(cr, "creative_type");
	q := ifx cr && ctype == 1 then fmap(cr, "creative_content") else ifx !cr || ctype == 3 then fmap(m, "quest") else .[];
	req := fstr(m, "request_id");
	if !promo_token_ok(req) req = "";
	id := ifx r.ok && req then fsnow(q, "id") else 0;
	us := fmap(q, "user_status");
	shows := id && vget(us, "claimed_at").kind != .String && !(fint(us, "dismissed_quest_content") & 2); // useQuestBarVisibility

	locks.lock(*b.mu);
	prev := ifx b.fetched_at == 0 then "null" else ifx b.quest then "quest" else "no_serve";
	prev_id := copy_string(string.{b.decision_len, b.decision.data},, temp);
	prev_at, prev_quest, caller := b.fetched_at, b.quest, ifx b.caller then b.caller else "questBar-open";
	b.started, b.fetching, b.caller = true, false, "";
	b.visible_guilds = contains(j.path, "&visible_guild_ids=");
	if b.check_at == 0 b.check_at = now + QUEST_CHECK_MS;
	unmount: string;
	mount := false;
	if !r.ok {
		// AdDeliveryStore FAILURE: the decision stays; Backoff(30 s, 10 min) with jitter
		if b.backoff_ms == 0 b.backoff_ms = QUEST_CHECK_MS;
		b.backoff_ms = min(b.backoff_ms + cast(s64) (2 * b.backoff_ms * random_get_zero_to_one_open()), 600_000);
		b.retry_at = now + b.backoff_ms;
	} else {
		t := fint(m, "response_ttl_seconds") * 1000;
		b.fetched_at, b.ttl_ms = start, ifx t > 0 && t < QUEST_TTL_MAX_MS then t else QUEST_TTL_MAX_MS;
		b.decision_len = min(req.count, b.decision.count);
		memcpy(b.decision.data, req.data, b.decision_len);
		b.backoff_ms, b.retry_at = 0, 0;
		b.check_at = now + QUEST_CHECK_MS; // the decision changed: the interval restarts
		if prev_quest != id || !b.shown_at {
			unmount = quest_bar_unmount_locked(c, now);
			if shows {
				mount = true;
				b.shown_at = now + QUEST_VISIBLE_MS;
				b.delay_at, b.delay_ms = now + QUEST_VISIBLE_MS + QUEST_AT_REST_MS, QUEST_VISIBLE_MS + QUEST_AT_REST_MS;
			}
		} else if id {
			b.delay_at, b.delay_ms = now + QUEST_CHECK_MS, QUEST_CHECK_MS; // the same bar: the tracker times out
		}
		if !id b.delay_at = 0; // no bar: the tracker is cleared
		b.quest = id;
		b.delay_quest = id;
	}
	locks.unlock(*b.mu);

	if random_get_zero_to_one_open() < c.promo.quest_roundtrip_sample {
		cur := ifx id then "quest" else "no_serve";
		w := aw_begin();
		json_kstr(*w, "endpoint", "/quests/decision");
		json_kbool(*w, "was_successful", r.ok);
		json_kint(*w, "api_latency_ms", now - start);
		json_kstr(*w, "mobile_network_type", "unknown");
		json_kstr(*w, "caller_source", caller);
		if r.ok && req json_kstr(*w, "ad_request_id", req); else json_knull(*w, "ad_request_id");
		json_kint(*w, "fetched_at", start);
		if prev_id json_kstr(*w, "previous_ad_request_id", prev_id); else json_knull(*w, "previous_ad_request_id");
		if prev_at json_kint(*w, "previous_fetched_at", prev_at); else json_knull(*w, "previous_fetched_at");
		json_kstr(*w, "transition_case", ifx prev == "quest" && cur == "quest" then (ifx prev_quest == id then "same_quest" else "different_quest") else tprint("%_to_%", prev, cur));
		json_kbool(*w, "is_foregrounded", c.focused);
		aw_track(c, "quest_decision_roundtrip", *w);
	}
	if !id return;
	w := aw_begin();
	json_ksnow(*w, "quest_id", id);
	json_ksnow(*w, "ad_content_id", id);
	json_kint(*w, "creative_type", 1);
	json_kstr(*w, "caller_source", caller);
	json_kstr(*w, "ad_request_id", req);
	aw_track(c, "quest_decision_received", *w);
	if unmount analytics_track(c, "quest_bar_mode_changed", unmount);
	if !mount return;

	assets := fmap(q, "assets");
	promo_quest_asset(c, fstr(assets, ifx c.store.settings.theme == .Light then "logotype_light" else "logotype_dark"), 0);
	promo_quest_asset(c, fstr(assets, "hero"), now + QUEST_VISIBLE_MS);
	// QuestsAnalyticsUtils: the quest, the ad session, the decision's ad identifiers, then the mode
	tasks := fmap(fmap(q, "task_config_v2"), "tasks");
	lead := aw_begin();
	json_ksnow(*lead, "quest_id", id);
	json_kstr(*lead, "quest_type", ifx vhas(tasks, "WATCH_VIDEO") || vhas(tasks, "WATCH_VIDEO_ON_MOBILE") then "VIDEO" else "GAMEPLAY");
	json_key(*lead, "application_ids");
	json_arr(*lead);
	apps: [..]Snowflake;
	apps.allocator = temp;
	for tasks for flist(vmap(it.value), "applications") {
		app := fsnow(vmap(it), "id");
		if app && apps.count < 64 && array_add_if_unique(*apps, app) json_snowflake(*lead, app);
	}
	json_arr_end(*lead);
	json_kstr(*lead, "quest_status", ifx vget(us, "completed_at").kind == .String then "COMPLETED" else ifx vget(us, "enrolled_at").kind == .String then "ENROLLED" else "NONE");
	json_obj_end(*lead);
	props := json_body(json_string(*lead));
	locks.lock(*b.mu);
	if b.quest == id {
		b.props.allocator, b.props.count = c.allocator, 0;
		append_string(*b.props, props);
	}
	locks.unlock(*b.mu);

	session := ad_session_id(c);
	w = aw_begin();
	json_raw_props(*w, props);
	json_kstr(*w, "client_ad_session_id", session);
	json_kstr(*w, "billing_session_id", session); // the quest bar's placement bills to the ad session
	json_ksnow(*w, "ad_content_id", id);
	ids := vget(m, "ad_identifiers");
	for k: string.["ad_id", "adset_id", "ad_set_id", "campaign_id", "creative_id"] {
		v := fsnow(vmap(ids), k);
		if v json_ksnow(*w, k, v);
	}
	t := fint(vmap(ids), "creative_type");
	json_kint(*w, "creative_type", ifx t >= 1 && t <= 16 then t else 1);
	json_kstr(*w, "decision_id", req);
	json_kbool(*w, "is_targeted", ids.kind == .Map);
	json_kint(*w, "content_id", 10);
	json_kstr(*w, "content_name", "QUEST_BAR_V2");
	json_kstr(*w, "mode", "collapsed");
	json_knull(*w, "previous_mode");
	json_obj_end(*w);
	analytics_schedule(c, now + QUEST_VISIBLE_MS, "quest_bar_mode_changed", json_body(json_string(*w)));
}

// quest_bar_unmount_locked: the shown bar goes (mu held): its mode tracker's cleanup, mode null.
// The decision no longer matches the quest, so the ad ids are the defaults (is_targeted false).
// Returns the event's properties ("" when no tracker had mounted).
quest_bar_unmount_locked :: (c: *Client, now: s64) -> string {
	b := *c.promo.bar;
	shown := b.shown_at && b.shown_at <= now && b.props.count;
	props := copy_string(cast(string) b.props,, temp);
	b.shown_at, b.props.count = 0, 0;
	if !shown return "";
	session := ad_session_id(c);
	w := aw_begin();
	json_raw_props(*w, props);
	json_kstr(*w, "client_ad_session_id", session);
	json_kstr(*w, "billing_session_id", session);
	json_ksnow(*w, "ad_content_id", b.quest);
	json_kbool(*w, "is_targeted", false);
	json_kint(*w, "creative_type", 1);
	json_kint(*w, "content_id", 10);
	json_kstr(*w, "content_name", "QUEST_BAR_V2");
	json_knull(*w, "mode");
	json_kstr(*w, "previous_mode", "collapsed");
	json_obj_end(*w);
	return json_body(json_string(*w));
}

// json_raw_props appends pre-encoded `"k":v,...` properties to an open object.
json_raw_props :: (w: *Json, props: string) {
	if !props return;
	if w.comma[w.depth] array_add(*w.buf, #char ",");
	w.comma[w.depth] = true;
	append_string(*w.buf, props);
}

// promo_quest_tick: the bar's 30 s check and its render delay tracker (UI thread, client_poll).
promo_quest_tick :: (c: *Client, now: s64) {
	b := *c.promo.bar;
	if !b.started return;
	locks.lock(*b.mu);
	delay: s64;
	delay_quest: Snowflake;
	if b.delay_at && now >= b.delay_at {
		delay, delay_quest, b.delay_at = b.delay_ms, b.delay_quest, 0;
	}
	unmount: string;
	fetch, visible := false, false;
	if now >= b.check_at {
		b.check_at = now + QUEST_CHECK_MS;
		if b.fetched_at == 0 || b.fetched_at + b.ttl_ms < now {
			if !c.focused {
				if b.fetched_at { // QUESTS_CLEAR_EXPIRED_QUEST_TO_DELIVER: nothing served for another TTL
					unmount = quest_bar_unmount_locked(c, now);
					b.fetched_at, b.decision_len, b.quest, b.delay_at = now, 0, 0, 0;
				}
			} else if !b.fetching && now >= b.retry_at {
				b.fetching, b.caller, fetch, visible = true, "questBar-interval", true, b.visible_guilds;
			}
		}
	}
	locks.unlock(*b.mu);
	// QuestBarRenderDelayTracker.stopTracking: only a focused window reports, 10 % of the time
	if delay && c.focused && random_get_zero_to_one_open() < c.promo.render_delay_sample {
		analytics_track(c, "quest_bar_render_delay", tprint("\"ad_creative_id\":\"%\",\"ad_creative_type\":1,\"timeout\":%,\"duration\":%", delay_quest, ifx delay == QUEST_CHECK_MS then "true" else "false", delay));
	}
	if unmount analytics_track(c, "quest_bar_mode_changed", unmount);
	if !fetch return;
	api_get_later(c, "/quests/@me", 0); // fetchCurrentQuests, then the decision
	path := "/quests/decision?placement=1&client_heartbeat_session_id={hb}&client_ad_session_id={ad}";
	if visible {
		sb: String_Builder;
		sb.allocator = temp;
		append(*sb, path);
		for sidebar_guild_ids(*c.store) print_to_builder(*sb, "&visible_guild_ids=%", it);
		path = builder_to_string(*sb,, temp);
	}
	j := job_new(.Api, .Startup);
	j.method = "GET";
	j.path = job_str(j, startup_expand(c, path));
	j.context_b64 = job_str(j, context_b64("{\"connection_type\":\"unknown\"}"));
	job_submit(c, j);
}

// promo_quest_reset: logging out unmounts the account panel and resets AdDeliveryStore; the
// next login asks again.
promo_quest_reset :: (c: *Client) {
	b := *c.promo.bar;
	locks.lock(*b.mu);
	array_reset(*b.props);
	b.started, b.fetching, b.caller, b.visible_guilds = false, false, "", false;
	b.fetched_at, b.ttl_ms, b.decision_len, b.quest, b.shown_at = 0, 0, 0, 0, 0;
	b.check_at, b.retry_at, b.backoff_ms, b.delay_at = 0, 0, 0, 0;
	locks.unlock(*b.mu);
}

// promo_quest_asset: a quest asset ("quests/<id>/<id>.<ext>" on the CDN) loaded as the bar renders
// it, then dropped. at: when (0 = now).
promo_quest_asset :: (c: *Client, path: string, at: s64) {
	if !begins_with(path, "quests/") || path.count > 96 || contains(path, "..") return;
	for cast([]u8) path if !is_alnum(it) && it != #char "/" && it != #char "." && it != #char "_" return;
	j := job_new(.Web, .Media);
	j.media = .{url = job_str(j, tprint("https://cdn.discordapp.com/%", path)), kind = .Image, visible = true, discard = true};
	j.not_before = at;
	job_submit(c, j);
}

// promo_token_ok: a uuid-like id from the server, safe to echo in telemetry.
promo_token_ok :: (s: string) -> bool {
	if !s || s.count > 64 return false;
	for cast([]u8) s if !is_alnum(it) && it != #char "-" return false;
	return true;
}

// ---- Edit Profiles' collectible previews ----
// Each empty Nameplate, Avatar Decoration, Profile Effect and Profile Frame field of the profile
// editor previews Shop items (useCyclingPreview): once the shop's categories load it shuffles
// the field's items (lodash shuffle, first 25) and preloads the first; it shows one, and
// preloads the next, only while hovered (not sent). So one random item per empty field loads,
// in that order (fixture settings, open_profiles). A field's items: the categories' products
// (variant groups flattened, bundles' items included) of its item type, one per sku; the
// decorations with an asset. The official lists put the user's purchases first; fastcord
// leaves them out (they are in the shop too).

SHOP_CDN :: "https://cdn.discordapp.com/media/v1/collectibles-shop/";

// Editor_Held: the fields the profile already fills (the editor's profile answer), by item type.
Editor_Held :: enum_flags u8 { Decoration; Effect; Nameplate; Frame; }

// editor_preview_items: each item type's items in the categories answer (0 decoration,
// 1 effect, 2 nameplate, 3 frame).
editor_preview_items :: (body: V) -> [4][..]etf.Map {
	out: [4][..]etf.Map;
	for * out it.allocator = temp;
	seen: Table(Snowflake, bool);
	seen.allocator = temp;
	add :: (items: []V) #expand {
		for v: items {
			it := vmap(v);
			t, sku := fint(it, "type"), fsnow(it, "sku_id");
			if t < 0 || t > 3 || !sku || `out[t].count >= 5000 continue;
			if t == 0 && !fstr(it, "asset") continue;
			if table_find_pointer(*`seen, sku) continue;
			table_set(*`seen, sku, true);
			array_add(*`out[t], it);
		}
	}
	for cat: flist(vmap(body), "categories") for p: flist(vmap(cat), "products") {
		pm := vmap(p);
		variants := flist(pm, "variants");
		if fint(pm, "type") == 2000 && variants for variants add(flist(vmap(it), "items"));
		else add(flist(pm, "items"));
	}
	return out;
}

// editor_preview_urls: what a field preloads for its item (type as above).
editor_preview_urls :: (item: etf.Map, type: int) -> []string {
	urls: [..]string;
	urls.allocator = temp;
	sku := fsnow(item, "sku_id");
	if type == {
		case 0; array_add(*urls, tprint("%1%2/animated", SHOP_CDN, sku)); // the decoration, animated
		case 2; array_add(*urls, tprint("%1%2/static", SHOP_CDN, sku));
		case 1;
			src := fstr(item, "thumbnailPreviewSrc");
			ok := begins_with(src, SHOP_CDN) && src.count <= SHOP_CDN.count + 128;
			for cast([]u8) advance(src, min(src.count, SHOP_CDN.count)) if !is_alnum(it) && it != #char "/" ok = false;
			if ok array_add(*urls, src);
		case 3; // the frame's layers that are not responsive
			for flist(item, "layers") {
				l := vmap(it);
				id := fsnow(l, "id");
				if id && !fbool(l, "responsive") && urls.count < 16 array_add(*urls, tprint("%1%2/%3/static", SHOP_CDN, sku, id));
			}
	}
	return urls;
}

// promo_editor_previews: the editor's categories answered (worker thread).
promo_editor_previews :: (c: *Client, body: V) {
	held := cast(Editor_Held) atomic_load(*c.promo.editor_held);
	lists := editor_preview_items(body);
	for type: int.[2, 0, 1, 3] {
		if held & cast(Editor_Held) (1 << type) || !lists[type] continue;
		pick := lists[type][random_get() % cast(u64) lists[type].count];
		for editor_preview_urls(pick, type) fetch_media(c, .{url = it, kind = .Image, visible = true, discard = true});
	}
}

// promo_editor_held: the editor's profile answered (worker thread): the fields it fills.
promo_editor_held :: (c: *Client, body: V) {
	m := vmap(body);
	user, profile := fmap(m, "user"), fmap(m, "user_profile");
	h: Editor_Held;
	if fmap(user, "avatar_decoration_data") h |= .Decoration;
	if fmap(fmap(user, "collectibles"), "nameplate") h |= .Nameplate;
	if fmap(profile, "profile_effect") h |= .Effect;
	for flist(profile, "collectibles") {
		t := fint(vmap(it), "type");
		if t == 1 h |= .Effect;
		if t == 3 h |= .Frame;
	}
	atomic_store(*c.promo.editor_held, cast(u8) h);
}
