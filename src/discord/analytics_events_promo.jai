// Promotion surfaces fastcord never shows: the Shop, Nitro and Orbs upsells, the quests bar
// and the voice invite suggestions. The official client tracks them as they render, with no
// user action, so fastcord sends the same telemetry and loads (traffic/CLIENT_RULES.md
// "Promotions") and draws nothing (AGENTS.md). Engagement with sponsored content (quest and
// ad impressions, hovers, clicks, video progress, enrolment, claims) is never sent.

Promo_State :: struct {
	shop_mounted: bool; // the DM list (private routes) shows its Shop entry (UI thread)
	shop_version: s64; // atomic: the Shop entry marketing's version, 0 until /collectibles-marketing loads
	quest_roundtrip_sample: float64 = 0.18; // quest_decision_roundtrip: 6 of 33 launches' decisions
}

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
	if id.count > 64 id = "";
	for cast([]u8) id if !is_alnum(it) && it != #char "-" id = "";
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
