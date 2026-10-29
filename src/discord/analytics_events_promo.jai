// Promotion surfaces fastcord never shows: the Shop, Nitro and Orbs upsells, the quests bar
// and the voice invite suggestions. The official client tracks them as they load and render,
// with no user action, so fastcord sends the same telemetry and loads (traffic/CLIENT_RULES.md
// "Promotions") and draws nothing (AGENTS.md). Engagement with sponsored content (quest and
// ad impressions, hovers, clicks, video progress, enrolment, claims) is never sent.

Promo_State :: struct {
	shop_mounted: bool; // the DM list (private routes) shows its Shop entry (UI thread)
	shop_version: s64; // atomic: the Shop entry marketing's version, 0 until /collectibles-marketing loads
	quest_roundtrip_sample: float64 = 0.18; // quest_decision_roundtrip: 6 of 33 launches' decisions
	render_delay_sample: float64 = 0.1; // quest_bar_render_delay (QuestBarRenderDelayTracker: 10%)
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
	ASSET :: "https://cdn.discordapp.com/media/v1/collectibles-shop/";
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

// promo_quest_roundtrip: QuestBar's /quests/decision answered (worker thread). Sampled: 6 of the
// 33 captured launches track it, with no other difference between them.
promo_quest_roundtrip :: (c: *Client, j: *Job, r: Api_Response) {
	if random_get_zero_to_one_open() >= c.promo.quest_roundtrip_sample return;
	m := vmap(r.body);
	id := fstr(m, "request_id");
	if !promo_token_ok(id) id = "";
	served := vget(m, "quest").kind == .Map;
	w := aw_begin();
	json_kstr(*w, "endpoint", "/quests/decision");
	json_kbool(*w, "was_successful", r.ok);
	json_kint(*w, "api_latency_ms", cast(s64) (now_ms_f() - j.started_ms));
	json_kstr(*w, "mobile_network_type", "unknown");
	json_kstr(*w, "caller_source", "questBar-open");
	if id json_kstr(*w, "ad_request_id", id); else json_knull(*w, "ad_request_id");
	json_kint(*w, "fetched_at", now_ms());
	json_knull(*w, "previous_ad_request_id");
	json_knull(*w, "previous_fetched_at");
	json_kstr(*w, "transition_case", ifx served then "null_to_serve" else "null_to_no_serve");
	json_kbool(*w, "is_foregrounded", c.focused);
	aw_track(c, "quest_decision_roundtrip", *w);
}

// promo_quest_decision: QuestBar's /quests/decision answered (worker thread, after its roundtrip).
// fetchQuestToDeliver tracks a delivered quest (creative_type 1, or the bare `quest` when there
// is no creative or a bounty without its experiment) as received. The account panel's quest bar
// then mounts collapsed: its logotype loads, and once its assets have loaded the bar shows,
// tracks quest_bar_mode_changed and loads its hero art (fixture upload_custom_emoji, setup:
// decision +31 ms and +330 ms). Its render delay tracker reports 10% of the renders in a focused
// window. No-fill decisions and the get-decisions placement render nothing. The server only
// delivers live quests, so expiry is not checked. The bar's impressions (quest_content_loaded /
// _viewed / _view_time), hovers and clicks are never sent.
promo_quest_decision :: (c: *Client, r: Api_Response) {
	VISIBLE_MS :: 330; // the bar's assets loaded (logotype, hero video): its mode tracker mounts
	AT_REST_MS :: 130; // its visibility spring (tension 250, friction 10, clamped) at rest
	m := vmap(r.body);
	cr := fmap(m, "creative");
	ctype := fint(cr, "creative_type");
	q := ifx cr && ctype == 1 then fmap(cr, "creative_content") else ifx !cr || ctype == 3 then fmap(m, "quest") else .[];
	id := fsnow(q, "id");
	req := fstr(m, "request_id");
	if !id || !promo_token_ok(req) return;
	w := aw_begin();
	json_ksnow(*w, "quest_id", id);
	json_ksnow(*w, "ad_content_id", id);
	json_kint(*w, "creative_type", 1);
	json_kstr(*w, "caller_source", "questBar-open");
	json_kstr(*w, "ad_request_id", req);
	aw_track(c, "quest_decision_received", *w);

	// useQuestBarVisibility: hidden once claimed or dismissed (QUEST_BAR's bit)
	us := fmap(q, "user_status");
	if vget(us, "claimed_at").kind == .String || (fint(us, "dismissed_quest_content") & 2) return;
	now := now_ms();
	assets := fmap(q, "assets");
	promo_quest_asset(c, fstr(assets, ifx c.store.settings.theme == .Light then "logotype_light" else "logotype_dark"), 0);
	promo_quest_asset(c, fstr(assets, "hero"), now + VISIBLE_MS);

	// QuestsAnalyticsUtils: the quest, the ad session, the decision's ad identifiers, then the mode
	tasks := fmap(fmap(q, "task_config_v2"), "tasks");
	session := ad_session_id(c);
	w = aw_begin();
	json_ksnow(*w, "quest_id", id);
	json_kstr(*w, "quest_type", ifx vhas(tasks, "WATCH_VIDEO") || vhas(tasks, "WATCH_VIDEO_ON_MOBILE") then "VIDEO" else "GAMEPLAY");
	json_key(*w, "application_ids");
	json_arr(*w);
	apps: [..]Snowflake;
	apps.allocator = temp;
	for tasks for flist(vmap(it.value), "applications") {
		app := fsnow(vmap(it), "id");
		if app && apps.count < 64 && array_add_if_unique(*apps, app) json_snowflake(*w, app);
	}
	json_arr_end(*w);
	json_kstr(*w, "quest_status", ifx vget(us, "completed_at").kind == .String then "COMPLETED" else ifx vget(us, "enrolled_at").kind == .String then "ENROLLED" else "NONE");
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
	analytics_schedule(c, now + VISIBLE_MS, "quest_bar_mode_changed", json_body(json_string(*w)));

	// QuestBarRenderDelayTracker: from the decision until the bar is visible and at rest
	if c.focused && random_get_zero_to_one_open() < c.promo.render_delay_sample {
		analytics_schedule(c, now + VISIBLE_MS + AT_REST_MS, "quest_bar_render_delay", tprint("\"ad_creative_id\":\"%\",\"ad_creative_type\":1,\"timeout\":false,\"duration\":%", id, VISIBLE_MS + AT_REST_MS));
	}
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
