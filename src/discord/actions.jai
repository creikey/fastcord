// User actions. Each mirrors what the official client sends when the user
// does the same thing (endpoint, query order, body key order, context
// properties, retries). Call them on the UI thread; they return immediately.

// ---- navigation ----

// select_channel is what CHANNEL_SELECT does on the network: it moves the
// referer, subscribes to the guild (op 37 typing/activities/threads, once per
// session), requests channel info (op 43) on guild entry, and loads messages
// if the channel has none.
// prefetch: the sidebar's mousedown preloads the channel before the route
// changes, so the first page carries the previous route as Referer
// (fixtures open_guild_and_channel, open_dm); quick switcher / create flows don't.
// source: the route change's source (transitionTo's `source`), reported as
// channel_opened's location (e.g. "Thread Browser").
set_route_scrolled_up :: (c: *Client, up: bool) {
	if c.route_scrolled_up == up return;
	locks.lock(*c.route_mu);
	c.route_scrolled_up = up;
	locks.unlock(*c.route_mu);
}

select_channel :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake, message_limit := 50, prefetch := false, source := "") {
	prev_referer := ifx prefetch then copy_string(client_route_referer(c),, temp) else "";
	locks.lock(*c.route_mu);
	prev_guild := c.route_guild;
	if c.route_channel != channel_id {
		// a Mark Unread hold ends when its channel is left (ReadStateStore CHANNEL_SELECT)
		rs := table_find_pointer(*c.store.read_states, c.route_channel);
		if rs rs.manual = false;
	}
	c.route_guild = guild_id;
	c.route_channel = channel_id;
	c.route_scrolled_up = false;
	locks.unlock(*c.route_mu);
	if guild_id && guild_id != prev_guild {
		subscribe_guild(c, guild_id);
		if prefetch c.subs.not_before = now_ms() + 2;
		c.pending_guild_open = guild_id;
	}
	if !guild_id && channel_id { c.pending_private_open = channel_id; c.pending_private_prefetch = prefetch; }
	if !guild_id && !channel_id home_open(c);
	if channel_id {
		l := message_list(*c.store, channel_id);
		if !l.loaded && !l.loading fetch_messages(c, channel_id, 0, message_limit, referer = prev_referer);
		else on_channel_page(c, channel_id, 0, false);
		analytics_channel_opened(c, guild_id, channel_id, location = source);
	}
	if guild_id && guild_id != prev_guild analytics_guild_viewed(c, guild_id, channel_id);
	frecency_select(c, guild_id, channel_id); // CHANNEL_SELECT
}

// initial_message_limit reproduces the client's page size for a channel open:
// clamp(ceil(1.05 * ceil(max(h-145,400) / (compact ? 65 : 91) * (16 / font_px))), 10, 100).
initial_message_limit :: (window_height: int, compact := false, font_px := 16) -> int {
	h := max(window_height - 145, 400);
	per := ifx compact then 65.0 else 91.0;
	rows := cast(float64) h / (per * (cast(float64) font_px / 16.0));
	n := cast(int) (1.05 * cast(float64) cast(int) (rows + 0.999999) + 0.999999);
	return clamp(n, 10, 100);
}

// ---- guild subscriptions (op 37) ----

Subscriptions :: struct {
	guilds: Table(Snowflake, bool); // typing/activities/threads sent
	channels: Table(Snowflake, [..]Member_Range); // guild -> channel list ranges (one channel at a time)
	pending: [..]Pending_Sub;
	not_before: s64; // prefetching select: op 37 follows the route change (after the fetch)
}

Member_Range :: struct {
	channel_id: Snowflake;
	ranges: [..][2]int;
}

Pending_Sub :: struct {
	guild_id: Snowflake;
	feature: bool; // typing/activities/threads
	channel_id: Snowflake;
	ranges: [..][2]int;
	member_ids: [..]Snowflake;
}

subscriptions_init :: (s: *Subscriptions, allocator := context.allocator) {
	s.guilds.allocator = allocator;
	s.channels.allocator = allocator;
	s.pending.allocator = allocator;
}

pending_for :: (c: *Client, guild_id: Snowflake) -> *Pending_Sub {
	for * c.subs.pending if it.guild_id == guild_id return it;
	p := array_add(*c.subs.pending);
	p.guild_id = guild_id;
	p.ranges.allocator = c.allocator;
	p.member_ids.allocator = c.allocator;
	return p;
}

// subscribe_guild: subscribeToGuild — typing, activities, threads (merged and
// flushed on the next poll like the client's 0 ms flush timer).
subscribe_guild :: (c: *Client, guild_id: Snowflake) {
	if table_contains(*c.subs.guilds, guild_id) return;
	table_set(*c.subs.guilds, guild_id, true);
	pending_for(c, guild_id).feature = true;
}

// subscribe_member_list subscribes to the lazy member sidebar of a channel
// (ranges of 100: [[0,99]], [[0,99],[100,199]], ...).
subscribe_member_list :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake, ranges: [][2]int) {
	p := pending_for(c, guild_id);
	p.channel_id = channel_id;
	p.ranges.count = 0;
	array_add(*p.ranges, ..ranges);
}

// subscribe_members: member presence/updates for specific users (profile popouts).
subscribe_members :: (c: *Client, guild_id: Snowflake, user_ids: []Snowflake) {
	p := pending_for(c, guild_id);
	for user_ids array_add_if_unique(*p.member_ids, it);
}

subscriptions_flush :: (c: *Client) {
	if !c.subs.pending return;
	if c.subs.not_before && now_ms() < c.subs.not_before return;
	c.subs.not_before = 0;
	defer {
		for c.subs.pending {
			array_free(it.ranges);
			array_free(it.member_ids);
		}
		c.subs.pending.count = 0;
	}
	// what each guild's member list follows, for RESUMED (one channel at a time)
	for p: c.subs.pending if p.channel_id {
		l := find_or_add(*c.subs.channels, p.guild_id);
		for l.* array_free(it.ranges);
		l.count = 0;
		l.allocator = c.allocator;
		r := array_add(l);
		r.channel_id = p.channel_id;
		r.ranges.allocator = c.allocator;
		array_add(*r.ranges, ..p.ranges);
	}
	// GUILD_SUBSCRIPTIONS_FLUSH goes out only while the session is established; what it held is
	// re-sent with READY (the route's guild) and RESUMED (every guild)
	if !c.gw || !gateway_established(c.gw) return;
	push_allocator(temp);
	subs := etf.map_builder(c.subs.pending.count);
	for p: c.subs.pending {
		g := etf.map_builder(5);
		if p.feature {
			etf.map_put(*g, "typing", etf.vbool(true));
			etf.map_put(*g, "activities", etf.vbool(true));
			etf.map_put(*g, "threads", etf.vbool(true));
		}
		if p.member_ids etf.map_put(*g, "members", snowflake_list(p.member_ids));
		if p.channel_id {
			ch := etf.map_builder(1);
			etf.map_put(*ch, snowflake_string(p.channel_id), ranges_value(p.ranges));
			etf.map_put(*g, "channels", etf.vmap(etf.map_done(*ch)));
		}
		etf.map_put(*subs, snowflake_string(p.guild_id), etf.vmap(etf.map_done(*g)));
	}
	d := etf.map_builder(1);
	etf.map_put(*d, "subscriptions", etf.vmap(etf.map_done(*subs)));
	gateway_send(c.gw, .Guild_Subscriptions_Bulk, etf.vmap(etf.map_done(*d)));
}

ranges_value :: (ranges: [][2]int) -> V {
	rl := NewArray(ranges.count, V,, temp);
	for r, i: ranges rl[i] = etf.vlist(array_copy(V.[etf.vint(r[0]), etf.vint(r[1])],, temp));
	return etf.vlist(rl);
}

// guild_subscription_value: a guild's whole subscription state, as GuildSubscriptions sends it on
// CONNECTION_OPEN and CONNECTION_RESUMED (temp).
guild_subscription_value :: (channels: []Member_Range) -> V {
	push_allocator(temp);
	gb := etf.map_builder(7);
	etf.map_put(*gb, "typing", etf.vbool(true));
	etf.map_put(*gb, "threads", etf.vbool(true));
	etf.map_put(*gb, "activities", etf.vbool(true));
	etf.map_put(*gb, "members", etf.vlist(.[]));
	etf.map_put(*gb, "member_updates", etf.vbool(false));
	ch := etf.map_builder(channels.count);
	for channels etf.map_put(*ch, snowflake_string(it.channel_id), ranges_value(it.ranges));
	etf.map_put(*gb, "channels", etf.vmap(etf.map_done(*ch)));
	etf.map_put(*gb, "thread_member_lists", etf.vlist(.[]));
	return etf.vmap(etf.map_done(*gb));
}

// subscriptions_resend: CONNECTION_RESUMED re-sends every subscribed guild in one op 37.
subscriptions_resend :: (c: *Client) {
	push_allocator(temp);
	subs := etf.map_builder(c.subs.guilds.count + c.subs.channels.count);
	for v, gid: c.subs.guilds {
		chs: []Member_Range;
		l := table_find_pointer(*c.subs.channels, gid);
		if l chs = l.*;
		etf.map_put(*subs, snowflake_string(gid), guild_subscription_value(chs));
	}
	for l, gid: c.subs.channels if !table_contains(*c.subs.guilds, gid) etf.map_put(*subs, snowflake_string(gid), guild_subscription_value(l));
	if !subs.pairs return;
	d := etf.map_builder(1);
	etf.map_put(*d, "subscriptions", etf.vmap(etf.map_done(*subs)));
	gateway_send(c.gw, .Guild_Subscriptions_Bulk, etf.vmap(etf.map_done(*d)));
}

// subscriptions_clear forgets every subscription (logout; a fresh READY keeps only its route's guild).
subscriptions_clear :: (c: *Client) {
	table_reset(*c.subs.guilds);
	for l: c.subs.channels {
		for l array_free(it.ranges);
		array_free(l);
	}
	table_reset(*c.subs.channels);
}

// snowflake_list: ids as a list of decimal strings, in temp (how the client sends ids over ETF).
snowflake_list :: (ids: []Snowflake) -> V {
	l := NewArray(ids.count, V,, temp);
	for ids l[it_index] = etf.vstring(snowflake_string(it));
	return etf.vlist(l);
}

// request_guild_members: op 8 for unknown message authors / mentions.
request_guild_members :: (c: *Client, guild_id: Snowflake, user_ids: []Snowflake, presences := false) {
	if !c.gw return;
	push_allocator(temp);
	start := 0;
	while start < user_ids.count {
		b := etf.map_builder(5);
		etf.map_put(*b, "guild_id", etf.vlist(array_copy(V.[etf.vstring(snowflake_string(guild_id))])));
		etf.map_put(*b, "query", V.{});
		etf.map_put(*b, "limit", V.{});
		etf.map_put(*b, "user_ids", snowflake_list(array_view(user_ids, start, min(100, user_ids.count - start))));
		etf.map_put(*b, "presences", etf.vbool(presences));
		gateway_send(c.gw, .Request_Guild_Members, etf.vmap(etf.map_done(*b)));
		start += 100;
	}
}

// search_guild_members: op 8 for the "@" autocomplete (GuildMemberRequesterStore.requestMembers):
// {guild_id: [gid], query, limit: 10, presences: true}; the caller debounces it.
search_guild_members :: (c: *Client, guild_id: Snowflake, query: string) {
	if !c.gw return;
	push_allocator(temp);
	b := etf.map_builder(4);
	etf.map_put(*b, "guild_id", etf.vlist(array_copy(V.[etf.vstring(snowflake_string(guild_id))])));
	etf.map_put(*b, "query", etf.vstring(to_lower_copy(query)));
	etf.map_put(*b, "limit", etf.vint(10));
	etf.map_put(*b, "presences", etf.vbool(true));
	gateway_send(c.gw, .Request_Guild_Members, etf.vmap(etf.map_done(*b)));
}

// VoiceStateStore's state: what op 4 last asked for. Kept while the gateway is down (shouldCommit is
// isSessionEstablished) and sent again with READY and RESUMED, so a join or leave is never lost.
Voice_Self :: struct {
	guild_id, channel_id: Snowflake;
	self_mute, self_deaf, self_video: bool;
}

// voice_self_value: op 4 for a voice state; joining adds RTCRegionStore's preferred regions
// (latency probe order, top 5).
voice_self_value :: (c: *Client, vs: Voice_Self) -> V {
	v := voice_state_value(vs.guild_id, vs.channel_id, vs.self_mute, vs.self_deaf, vs.self_video, 2);
	if !vs.channel_id return v;
	// copied under the lock: the probe's worker replaces rtc_regions
	locks.lock(*c.id.mu);
	joined := copy_string(c.rtc_regions,, temp);
	locks.unlock(*c.id.mu);
	if !joined return v;
	regions := split(joined, ",",, temp);
	list := NewArray(min(regions.count, 5), V,, temp);
	for * list it.* = etf.vstring(regions[it_index]);
	ext: [..]etf.Pair;
	ext.allocator = temp;
	array_add(*ext, ..vmap(v));
	array_add(*ext, .{etf.vstring("preferred_region"), etf.vstring(regions[0])}, .{etf.vstring("preferred_regions"), etf.vlist(list)});
	return etf.vmap(ext);
}

// voice_join / voice_leave: op 4 as VoiceStateStore sends it.
voice_update :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake, self_mute: bool, self_deaf: bool, self_video := false) {
	if !c.gw return;
	vs := Voice_Self.{guild_id, channel_id, self_mute, self_deaf, self_video};
	locks.lock(*c.route_mu);
	c.voice_self = vs;
	locks.unlock(*c.route_mu);
	if gateway_established(c.gw) gateway_send(c.gw, .Voice_State_Update, voice_self_value(c, vs));
}

// rtc_probe_tick: GET latency.discord.media/rtc?v=2 (RTCLatencyTestManager): 3-33 s after every
// READY (client_on_ready), then every 6 hours. The response's region order is what op 4 sends as
// preferred_regions (persisted for the next launch).
rtc_probe_tick :: (c: *Client, now: s64) {
	locks.lock(*c.job_mu);
	due := c.rtc_probe_at && now >= c.rtc_probe_at;
	if due c.rtc_probe_at = now + 6 * 3600_000;
	locks.unlock(*c.job_mu);
	if !due return;
	j := job_new(.Web, .Startup);
	j.method = "GET";
	j.host = "latency.discord.media";
	j.path = "/rtc?v=2";
	j.site = .Cross_Site;
	j.on_body = (c: *Client, body: V) {
		regions: [..]string;
		regions.allocator = temp;
		for vlist(body) array_add(*regions, fstr(vmap(it), "region"));
		joined := join(..regions, separator = ",",, temp);
		if !joined return;
		locks.lock(*c.id.mu);
		free(c.rtc_regions,, c.allocator);
		c.rtc_regions = copy_string(joined,, c.allocator);
		locks.unlock(*c.id.mu);
	};
	job_submit(c, j);
}

// ---- messages ----

channel_path :: (channel_id: Snowflake, rest: ..string) -> string {
	return join("/channels/", snowflake_string(channel_id), join(..rest,, temp),, temp);
}

// fetch_messages: GET /channels/{id}/messages?before=&limit= (retries 2).
fetch_messages :: (c: *Client, channel_id: Snowflake, before: Snowflake = 0, limit := 50, tag: u64 = 0, referer := "") {
	q: Query;
	query_init(*q, channel_path(channel_id, "/messages"));
	if before query_add_snow(*q, "before", before);
	query_add_int(*q, "limit", limit);
	j := job_new(.Api, .Fetch_Messages);
	j.method = "GET";
	j.path = job_str(j, query_string(*q));
	j.retries = 2;
	if referer j.referer = job_str(j, referer);
	j.result.channel_id = channel_id;
	j.result.limit = limit;
	j.result.before = before;
	j.result.tag = tag;
	message_list(*c.store, channel_id).loading = true;
	job_submit(c, j);
}

Send_Options :: struct {
	reply_to: Snowflake; // message id
	reply_guild_id: Snowflake; // guild of the replied channel (0 for DMs)
	mention_replied: bool; // false -> allowed_mentions {parse:[...], replied_user:false}
	tts: bool;
	flags: u64;
	location: string; // x-context-properties location ("" -> "chat_input")
	sticker_ids: []Snowflake;
	files: []Upload_File; // uploaded at send (POST /attachments + PUT each, then the message)
	attachments: []Draft_Attachment; // already staged with upload_draft (the composer's flow)
	tag: u64;
}

write_message_body_prefix :: (w: *Json, channel_id: Snowflake, content: string, nonce: Snowflake, opts: Send_Options) {
	json_obj(w);
	json_kstr(w, "mobile_network_type", "unknown");
	json_kstr(w, "content", content);
	json_kstr(w, "nonce", snowflake_string(nonce));
	json_kbool(w, "tts", opts.tts);
	if opts.reply_to {
		json_key(w, "message_reference");
		json_obj(w);
		if opts.reply_guild_id json_ksnow(w, "guild_id", opts.reply_guild_id);
		json_ksnow(w, "channel_id", channel_id);
		json_ksnow(w, "message_id", opts.reply_to);
		json_obj_end(w);
		if !opts.mention_replied {
			json_key(w, "allowed_mentions");
			json_obj(w);
			json_key(w, "parse");
			json_arr(w);
			json_str(w, "users");
			json_str(w, "roles");
			json_str(w, "everyone");
			json_arr_end(w);
			json_kbool(w, "replied_user", false);
			json_obj_end(w);
		}
	}
	json_kint(w, "flags", cast(s64) opts.flags);
	if opts.sticker_ids {
		json_key(w, "sticker_ids");
		json_arr(w);
		for opts.sticker_ids json_snowflake(w, it);
		json_arr_end(w);
	}
}

// message_send_body: the exact POST /messages body (JSON.stringify order).
message_send_body :: (channel_id: Snowflake, content: string, nonce: Snowflake, opts: Send_Options, attachments_json := "", allocator := temp) -> string {
	w: Json;
	json_init(*w, allocator);
	write_message_body_prefix(*w, channel_id, content, nonce, opts);
	if attachments_json {
		json_key(*w, "attachments");
		json_raw(*w, attachments_json);
	}
	json_obj_end(*w);
	return json_string(*w);
}

// send_message inserts an optimistic pending message (replaced by the
// MESSAGE_CREATE / response with the same nonce) and queues the POST.
send_message :: (c: *Client, channel_id: Snowflake, content: string, opts := Send_Options.{}) -> Snowflake {
	nonce := nonce_next(*c.id.nonces);
	s := *c.store;
	msg := new_message(s);
	msg.id = nonce;
	msg.channel_id = channel_id;
	msg.author_id = s.me;
	msg.content = clone_str(content, s.allocator);
	msg.nonce = clone_str(snowflake_string(nonce), s.allocator);
	msg.referenced_id = opts.reply_to;
	msg.pending = true;
	msg.kind = ifx opts.reply_to then 19 else 0;
	insert_message(message_list(s, channel_id), msg);
	s.changed += 1;
	typing_local_stop(c, channel_id);

	location := ifx opts.location then opts.location else "chat_input";
	if opts.attachments || opts.files {
		j := job_new(.Upload, .Upload);
		a := job_alloc(j);
		j.path = job_str(j, channel_path(channel_id, "/messages"));
		j.context_b64 = job_str(j, context_location(location));
		// the upload context keeps opts (a job-owned copy) for the message body
		o2 := opts;
		o2.files = .[];
		o2.attachments = .[];
		o2.location = "";
		o2.sticker_ids = array_copy(opts.sticker_ids,, a);
		if opts.attachments {
			j.drafts = NewArray(opts.attachments.count, Draft_Attachment,, a);
			for opts.attachments j.drafts[it_index] = .{it.handle, copy_string(it.filename,, a), copy_string(it.description,, a), it.spoiler};
		} else {
			j.files = NewArray(opts.files.count, Upload_File,, a);
			for opts.files j.files[it_index] = .{copy_string(it.filename,, a), copy_string(it.mime,, a), array_copy(it.data,, a)};
			j.body = cast([]u8) message_send_body(channel_id, content, nonce, o2, allocator = a);
		}
		j.result = .{op = .Upload, channel_id = channel_id, nonce = nonce, tag = opts.tag};
		store_upload_ctx(j, channel_id, content, nonce, o2);
		job_submit(c, j);
		if opts.attachments table_set(*c.analytics.roundtrips, nonce, .{channel_id = channel_id, start = now_ms(), attachments = opts.attachments.count});
		return nonce;
	}
	j := job_new(.Api, .Send_Message);
	j.method = "POST";
	j.path = job_str(j, channel_path(channel_id, "/messages"));
	j.body = cast([]u8) message_send_body(channel_id, content, nonce, opts, allocator = job_alloc(j));
	j.content_type = "application/json";
	j.context_b64 = job_str(j, context_location(location));
	j.retries = 3; // N.ZG: {timeout: 60 s, retries: 3, backoff}
	j.retry_429 = 3; // MessageQueue re-sends after Retry-After
	j.result = .{op = .Send_Message, channel_id = channel_id, nonce = nonce, tag = opts.tag};
	job_submit(c, j);
	table_set(*c.analytics.roundtrips, nonce, .{channel_id = channel_id, start = now_ms()});
	return nonce;
}

Upload_Ctx :: struct {
	channel_id: Snowflake;
	content: string;
	nonce: Snowflake;
	opts: Send_Options;
}

store_upload_ctx :: (j: *Job, channel_id: Snowflake, content: string, nonce: Snowflake, opts: Send_Options) {
	a := job_alloc(j);
	ctx := New(Upload_Ctx,, a);
	ctx.* = .{channel_id, copy_string(content,, a), nonce, opts};
	j.upload_ctx = ctx;
	j.message_json = (j: *Job, attachments_json: string) -> []u8 {
		u := cast(*Upload_Ctx) j.upload_ctx;
		return cast([]u8) message_send_body(u.channel_id, u.content, u.nonce, u.opts, attachments_json);
	};
}

// edit_message: PATCH {content} (retries 1).
edit_message :: (c: *Client, channel_id: Snowflake, message_id: Snowflake, content: string) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "content", content);
	json_obj_end(*w);
	j := job_new(.Api, .Edit_Message);
	j.method = "PATCH";
	j.path = job_str(j, channel_path(channel_id, "/messages/", snowflake_string(message_id)));
	j.body = cast([]u8) job_str(j, json_string(*w));
	j.content_type = "application/json";
	j.retries = 1;
	j.result = .{op = .Edit_Message, channel_id = channel_id, message_id = message_id};
	job_submit(c, j);
}

// suppress_embeds: PATCH the message's flags with SUPPRESS_EMBEDS (1 << 2) added; the reply replaces the message.
suppress_embeds :: (c: *Client, channel_id: Snowflake, message_id: Snowflake, flags: u64) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kint(*w, "flags", cast(s64) (flags | 4));
	json_obj_end(*w);
	j := job_new(.Api, .Edit_Message);
	j.method = "PATCH";
	j.path = job_str(j, channel_path(channel_id, "/messages/", snowflake_string(message_id)));
	j.body = cast([]u8) job_str(j, json_string(*w));
	j.content_type = "application/json";
	j.retries = 1;
	j.result = .{op = .Edit_Message, channel_id = channel_id, message_id = message_id};
	job_submit(c, j);
}

// delete_message: DELETE (no retries).
delete_message :: (c: *Client, channel_id: Snowflake, message_id: Snowflake) {
	j := job_new(.Api, .Delete_Message);
	j.method = "DELETE";
	j.path = job_str(j, channel_path(channel_id, "/messages/", snowflake_string(message_id)));
	j.result = .{op = .Delete_Message, channel_id = channel_id, message_id = message_id};
	job_submit(c, j);
}

// emoji_route: "name" for unicode, "name:id" for custom, URI-encoded like Rsh's wrapper.
emoji_route :: (name: string, id: Snowflake) -> string {
	return uri_component(ifx id then tprint("%:%", name, id) else name);
}

// Reactions are predicted like ReactionActionCreators: the store changes first and the
// request is sent. Requests for one message+emoji go one at a time, in click order (on
// one HTTP/2 connection the server could otherwise apply on, off, on as off), and the
// gateway echoes of our own requests are skipped (Store.reaction_echoes). A failure is
// retried once (a 429 after Retry-After, in api_call), then rolled back unless a newer
// click on the same reaction is queued; a 403 is not retried.
Reaction_Req :: struct {
	seq: u64;
	channel_id: Snowflake;
	message_id: Snowflake;
	emoji: Emoji; // name owned (c.allocator)
	location: string; // owned
	add: bool;
	burst: bool;
	retried: bool;
	sent: bool;
}

// add_reaction: PUT /channels/{c}/messages/{m}/reactions/{emoji}/%40me?location=..&type=0|1.
// Refused (false, nothing sent) when the message already has the emoji as the other kind
// (normal vs burst): the client's "Oops!" modal.
add_reaction :: (c: *Client, channel_id: Snowflake, message_id: Snowflake, emoji_name: string, emoji_id: Snowflake = 0, burst := false, location := "Message", animated := false) -> bool {
	l := table_find_pointer(*c.store.messages, channel_id);
	i := ifx l then message_index(l, message_id) else -1;
	if i >= 0 for l.messages[i].reactions if emoji_matches(it.emoji, emoji_id, emoji_name) && (ifx burst then it.me else it.me_burst) return false;
	reaction_send(c, .{channel_id = channel_id, message_id = message_id, emoji = .{id = emoji_id, name = emoji_name, animated = animated, available = true}, location = location, add = true, burst = burst});
	return true;
}

// remove_reaction: DELETE .../reactions/{emoji}/{type}/%40me?location=..&burst=
remove_reaction :: (c: *Client, channel_id: Snowflake, message_id: Snowflake, emoji_name: string, emoji_id: Snowflake = 0, burst := false, location := "Message") {
	reaction_send(c, .{channel_id = channel_id, message_id = message_id, emoji = .{id = emoji_id, name = emoji_name, available = true}, location = location, burst = burst});
}

// A click: predict it now, send it when the reaction has no request in flight.
reaction_send :: (c: *Client, req: Reaction_Req) {
	c.reaction_seq += 1;
	r := req;
	r.seq = c.reaction_seq;
	r.sent = false;
	// copied first: the caller's name may be the reaction the store is about to drop
	r.emoji.name = copy_string(req.emoji.name,, c.allocator);
	r.location = copy_string(req.location,, c.allocator);
	store_reaction(*c.store, r.channel_id, r.message_id, r.emoji, true, r.add, r.burst);
	c.store.changed += 1;
	busy := false;
	for c.reaction_reqs if same_reaction(it, r) busy = true;
	array_add(*c.reaction_reqs, r);
	if !busy reaction_submit(c, *c.reaction_reqs[c.reaction_reqs.count - 1]);
}

same_reaction :: (a: Reaction_Req, b: Reaction_Req) -> bool {
	return a.message_id == b.message_id && a.burst == b.burst && emoji_matches(a.emoji, b.emoji.id, b.emoji.name);
}

reaction_submit :: (c: *Client, r: *Reaction_Req) {
	r.sent = true;
	n := find_or_add(*c.store.reaction_echoes, reaction_key(r.message_id, r.emoji, r.burst));
	n.* += 1;
	base := channel_path(r.channel_id, "/messages/", snowflake_string(r.message_id), "/reactions/", emoji_route(r.emoji.name, r.emoji.id));
	q: Query;
	j := job_new(.Api, ifx r.add then Rest_Op.Add_Reaction else .Remove_Reaction);
	if r.add {
		query_init(*q, join(base, "/%40me",, temp));
		query_add(*q, "location", r.location);
		query_add_int(*q, "type", ifx r.burst then 1 else 0);
		j.method = "PUT";
	} else {
		query_init(*q, join(base, ifx r.burst then "/1" else "/0", "/%40me",, temp));
		query_add(*q, "location", r.location);
		query_add_bool(*q, "burst", r.burst);
		j.method = "DELETE";
	}
	j.path = job_str(j, query_string(*q));
	j.retry_429 = 1; // retried once after Retry-After
	j.result = .{op = j.op, channel_id = r.channel_id, message_id = r.message_id, tag = r.seq};
	job_submit(c, j);
}

// reaction_result: a reaction request finished (UI thread, from client_apply_rest).
reaction_result :: (c: *Client, res: Rest_Result) {
	for * c.reaction_reqs {
		if it.seq != res.tag continue;
		if !res.ok {
			// no echo will come for it
			n := table_find_pointer(*c.store.reaction_echoes, reaction_key(it.message_id, it.emoji, it.burst));
			if n && n.* > 0 n.* -= 1;
			if !it.retried && res.status != 403 && res.status != 429 {
				it.retried = true;
				reaction_submit(c, it);
				return;
			}
		}
		req := it.*;
		array_ordered_remove_by_index(*c.reaction_reqs, it_index);
		next: *Reaction_Req;
		for * c.reaction_reqs if same_reaction(it, req) { next = it; break; }
		// a failed click is undone unless a newer click on the reaction decides it
		if !res.ok && !next {
			store_reaction(*c.store, req.channel_id, req.message_id, req.emoji, true, !req.add, req.burst);
			c.store.changed += 1;
		}
		if next reaction_submit(c, next);
		free(req.emoji.name,, c.allocator);
		free(req.location,, c.allocator);
		return;
	}
}

// ---- typing (TypingStore TYPING_START_LOCAL) ----

TYPING_SEND_DELAY_MS :: 1500;
TYPING_RESEND_MS :: 8000; // 0.8 * 10 s

Typing_Local :: struct {
	channel_id: Snowflake;
	fire_at: s64; // 0 = no timer pending
	prev_send: s64;
	active: bool;
}

// typing_keystroke: call on each input change; sends POST /typing like the client
// (1.5 s debounce when it typed recently, at most every 8 s).
typing_keystroke :: (c: *Client, channel_id: Snowflake) {
	t := *c.typing_local;
	now := now_ms();
	if t.active && t.channel_id != channel_id t.* = .{};
	if t.active && (t.fire_at != 0 || t.prev_send + TYPING_RESEND_MS > now) return;
	delay: s64 = ifx (!t.active || t.prev_send > now - 2 * TYPING_RESEND_MS) then TYPING_SEND_DELAY_MS else 0;
	t.* = .{channel_id = channel_id, fire_at = now + delay, prev_send = now, active = true};
}

typing_local_stop :: (c: *Client, channel_id: Snowflake) {
	t := *c.typing_local;
	if t.active && t.channel_id == channel_id && t.fire_at != 0 t.* = .{};
}

flush_typing_local :: (c: *Client, now: s64) {
	t := *c.typing_local;
	if !t.active || t.fire_at == 0 || now < t.fire_at return;
	t.fire_at = 0;
	send_typing(c, t.channel_id);
}

// send_typing: POST /channels/{id}/typing (empty body).
send_typing :: (c: *Client, channel_id: Snowflake) {
	j := job_new(.Api, .Typing);
	j.method = "POST";
	j.path = job_str(j, channel_path(channel_id, "/typing"));
	j.result = .{op = .Typing, channel_id = channel_id};
	job_submit(c, j);
}

// ---- acks (ReadStateStore) ----

ACK_DELAY_MS :: 3000;

Pending_Ack :: struct {
	channel_id: Snowflake;
	message_id: Snowflake;
	due: s64;
	location: Ack_Location;
}

// Ack_Location: where an ack came from, as ack_messages reports it ({} = no event).
Ack_Location :: struct {
	section: string;
	object: string;
	object_type: string; // "ack_automatic" / "ack_semi_automatic" / "ack_manual"
}

// the Inbox's per-channel "Mark As Read" (fixture inbox, inbox_unreads_mark_read)
ACK_INBOX :: Ack_Location.{"Inbox", "Ack - Inbox Newest Unread Message", "ack_automatic"};
// the chat's new-messages bar "Mark As Read"
ACK_NEW_MESSAGES_BANNER :: Ack_Location.{"New Messages Banner", "Mark Channel as Read Button", "ack_manual"};

// automatic acks (shouldAutomaticallyAck), tracked like the client's
ACK_INCOMING_MESSAGE :: Ack_Location.{"Channel", "Ack - Incoming Message", "ack_automatic"};
ACK_CHANNEL_SCROLL :: Ack_Location.{"Channel", "Ack - Channel Scroll", "ack_automatic"};
ACK_WINDOW_FOCUS :: Ack_Location.{"Channel", "Ack - Window Focus", "ack_automatic"};
ACK_VOICE_CHANNEL_SELECT :: Ack_Location.{"Channel", "Ack - Voice Channel Select", "ack_semi_automatic"};

// ack_message moves the read state at once and schedules the POST like ReadState.ack():
// one timer per channel, due in 3 s, or at once when `immediate` or the channel had
// mentions. Later acks before it fires only move the message id (the timer and the
// first ack's location stay). Body {token, last_viewed[, flags]}.
// location: reported in ack_messages when the ack completes ({}: none).
ack_message :: (c: *Client, channel_id: Snowflake, message_id: Snowflake, immediate := false, location := Ack_Location.{}) {
	rs := find_or_add(*c.store.read_states, channel_id);
	had_mentions := rs.mention_count > 0;
	rs.channel_id = channel_id;
	rs.last_message_id = max(rs.last_message_id, message_id);
	rs.mention_count = 0;
	rs.manual = false;
	for * c.pending_acks {
		if it.channel_id == channel_id {
			it.message_id = max(it.message_id, message_id);
			return;
		}
	}
	due := now_ms() + (ifx immediate || had_mentions then 0 else ACK_DELAY_MS);
	array_add(*c.pending_acks, .{channel_id, message_id, due, location});
}

flush_due_acks :: (c: *Client, now: s64) {
	for < c.pending_acks {
		if it.due > now continue;
		p := it;
		array_ordered_remove_by_index(*c.pending_acks, it_index);
		send_ack(c, p.channel_id, p.message_id, now, p.location);
	}
}

send_ack :: (c: *Client, channel_id: Snowflake, message_id: Snowflake, now: s64, location := Ack_Location.{}) {
	_, ch := table_find(*c.store.channels, channel_id);
	_, rs := table_find(*c.store.read_states, channel_id);
	// recalculateFlags: 2 thread, 1 guild channel, 0 private; sent only when it changed.
	flags: u64 = xx ifx is_thread(*ch) then 2 else ifx ch.guild_id then 1 else 0;
	w: Json;
	json_init(*w);
	json_obj(*w);
	locks.lock(*c.ack_mu);
	if c.ack_token json_kstr(*w, "token", c.ack_token);
	else json_knull(*w, "token");
	locks.unlock(*c.ack_mu);
	lv := ifx rs.last_viewed > 0 then rs.last_viewed else days_since_epoch(now);
	json_kint(*w, "last_viewed", lv);
	if flags != rs.flags {
		json_kint(*w, "flags", cast(s64) flags);
		rs.flags = flags;
		table_set(*c.store.read_states, channel_id, rs);
	}
	json_obj_end(*w);
	j := job_new(.Api, .Ack);
	j.method = "POST";
	j.path = job_str(j, channel_path(channel_id, "/messages/", snowflake_string(message_id), "/ack"));
	j.body = cast([]u8) job_str(j, json_string(*w));
	j.content_type = "application/json";
	j.result = .{op = .Ack, channel_id = channel_id, message_id = message_id};
	if location.section {
		// the read states are already moved: the statuses are those after the ack
		j.track_props = job_str(j, analytics_ack_props(c, channel_id, location));
		j.on_done = analytics_ack_done;
	}
	job_submit(c, j);
}

// ---- DMs ----

// open_dm returns the existing DM channel if cached (no request, like
// _openCachedDMChannel), else POST /users/@me/channels {recipients:[id]}.
open_dm :: (c: *Client, user_id: Snowflake, location := "Profile", tag: u64 = 0) -> Snowflake {
	for cid: c.store.private_channels {
		ch := table_find_pointer(*c.store.channels, cid);
		if ch && ch.kind == .DM && ch.recipient_ids.count == 1 && ch.recipient_ids[0] == user_id return cid;
	}
	create_private_channel(c, Snowflake.[user_id], location, tag);
	return 0;
}

// create_private_channel: group DM (or DM) creation.
create_private_channel :: (c: *Client, user_ids: []Snowflake, location := "Profile", tag: u64 = 0) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_key(*w, "recipients");
	json_arr(*w);
	for user_ids json_snowflake(*w, it);
	json_arr_end(*w);
	json_obj_end(*w);
	j := job_new(.Api, .Open_Dm);
	j.method = "POST";
	j.path = "/users/@me/channels";
	j.body = cast([]u8) job_str(j, json_string(*w));
	j.content_type = "application/json";
	j.context_b64 = job_str(j, context_location(location));
	j.retries = 3;
	j.result = .{op = .Open_Dm, tag = tag, user_id = ifx user_ids then user_ids[0] else 0};
	job_submit(c, j);
}

// ---- relationships ----

// send_friend_request (Add Friend by username): POST /users/@me/relationships
// {"username":..,"discriminator":null} (parseInt(undefined) is NaN -> null).
send_friend_request :: (c: *Client, username: string, location := "Add Friend") {
	w: Json;
	json_init(*w);
	json_obj(*w);
	name, disc := username, "";
	found, left, right := split_from_left(username, #char "#");
	if found name, disc = left, right;
	json_kstr(*w, "username", name);
	if disc {
		json_key(*w, "discriminator");
		json_raw(*w, disc);
	} else {
		json_knull(*w, "discriminator");
	}
	json_obj_end(*w);
	j := job_new(.Api, .Relationship);
	j.method = "POST";
	j.path = "/users/@me/relationships";
	j.body = cast([]u8) job_str(j, json_string(*w));
	j.content_type = "application/json";
	j.context_b64 = job_str(j, context_location(location));
	job_submit(c, j);
}

// add_relationship: PUT /users/@me/relationships/{id} {} — accept a request,
// or send one from a profile.
add_relationship :: (c: *Client, user_id: Snowflake, location := "Friends") {
	j := job_new(.Api, .Relationship);
	j.method = "PUT";
	j.path = job_str(j, tprint("/users/@me/relationships/%", user_id));
	j.body = cast([]u8) job_str(j, "{}");
	j.content_type = "application/json";
	j.context_b64 = job_str(j, context_location(location));
	j.result.user_id = user_id;
	job_submit(c, j);
}

// accept_friend_request: Friends > Pending > Accept. A mutual-guild request
// needs no stranger confirmation: {"confirm_stranger_request":false}
// (fixtures friend_request_accept, friend_add_context_menu).
accept_friend_request :: (c: *Client, user_id: Snowflake) {
	j := job_new(.Api, .Relationship);
	j.method = "PUT";
	j.path = job_str(j, tprint("/users/@me/relationships/%", user_id));
	j.body = cast([]u8) job_str(j, "{\"confirm_stranger_request\":false}");
	j.content_type = "application/json";
	j.context_b64 = job_str(j, context_location("Friends"));
	j.result.user_id = user_id;
	job_submit(c, j);
}

// remove_relationship: DELETE — ignore/cancel a request, unfriend, unblock.
remove_relationship :: (c: *Client, user_id: Snowflake, location := "Friends") {
	j := job_new(.Api, .Relationship);
	j.method = "DELETE";
	j.path = job_str(j, tprint("/users/@me/relationships/%", user_id));
	j.context_b64 = job_str(j, context_location(location));
	j.result.user_id = user_id;
	job_submit(c, j);
}

ignore_friend_request :: (c: *Client, user_id: Snowflake) { remove_relationship(c, user_id, "Friends"); }

// ---- profiles ----

// fetch_profile: GET /users/{id}/profile?type=popout&with_mutual_guilds=true&with_mutual_friends=true&with_mutual_friends_count=false[&guild_id=]
fetch_profile :: (c: *Client, user_id: Snowflake, guild_id: Snowflake = 0, tag: u64 = 0) {
	q: Query;
	query_init(*q, tprint("/users/%/profile", user_id));
	query_add(*q, "type", "popout");
	query_add_bool(*q, "with_mutual_guilds", true);
	query_add_bool(*q, "with_mutual_friends", true);
	query_add_bool(*q, "with_mutual_friends_count", false);
	if guild_id query_add_snow(*q, "guild_id", guild_id);
	j := job_new(.Api, .Fetch_Profile);
	j.method = "GET";
	j.path = job_str(j, query_string(*q));
	j.result = .{op = .Fetch_Profile, user_id = user_id, tag = tag};
	job_submit(c, j);
}

// ---- dispatch side effects (UI thread) ----

// client_after_dispatch: requests the official client makes in response to
// events (e.g. op 8 for unknown message authors in a subscribed guild).
client_after_dispatch :: (c: *Client, name: string, data: V) {
	calls_dispatch(c, name, data);
	if name == {
	case "READY";
		launch := c.analytics.identify_ms != 0; // this launch's first READY (fast connect)
		first := analytics_on_ready(c);
		analytics_ready_experiments(c, data);
		analytics_ready_payload(c, data, !first);
		analytics_ad_heartbeat(c, now_ms()); // AdSessionStore's CONNECTION_OPEN handler runs here
		analytics_exposures_after_ready(c);
		if launch c.analytics.first_render_at = now_ms() + 60; // app_ui_viewed (fixtures: READY +60 ms)
		note_webp_experiment(c, data);
		c.account_verified = fbool(fmap(vmap(data), "user"), "verified");
		// The window reopens on its last route: the guild is subscribed and its
		// channel info requested on CONNECTION_OPEN, as when it was selected.
		locks.lock(*c.route_mu);
		g, ch := c.route_guild, c.route_channel;
		locks.unlock(*c.route_mu);
		// the route's views render on CONNECTION_OPEN: channel_opened, guild_viewed
		// (fixtures' setup windows, right after ready_payload_received)
		if first && ch analytics_channel_opened(c, g, ch);
		if first && g analytics_guild_viewed(c, g, ch);
		if first && !g && !ch friends_page_viewed(c); // fixture cold_start
		if ch {
			l := message_list(*c.store, ch);
			if !l.loaded && !l.loading fetch_messages(c, ch, 0, initial_message_limit(viewport_h(c)));
		}
		// CONNECTION_OPEN: GuildSubscriptions drops the other guilds' subscriptions (a later visit
		// subscribes again); the route's guild went out with READY
		if !first subscriptions_clear(c);
		if g {
			locks.lock(*c.job_mu);
			already := c.ready_subscribed_guild == g;
			locks.unlock(*c.job_mu);
			if already table_set(*c.subs.guilds, g, true);
			else subscribe_guild(c, g);
			c.pending_guild_open = g;
			c.guild_open_promotions = true;
		}
	case "RESUMED";
		// SelfPresenceStore and VoiceStateStore force-commit (op 3, op 4), then GuildSubscriptions
		// re-sends every guild (op 37): what changed while the socket was down reaches the server
		if c.gw {
			gateway_send(c.gw, .Presence_Update, presence_value(c,, temp));
			locks.lock(*c.route_mu);
			vs := c.voice_self;
			locks.unlock(*c.route_mu);
			gateway_send(c.gw, .Voice_State_Update, voice_self_value(c, vs));
			subscriptions_resend(c);
		}
	case "GUILD_DELETE";
		// left (or removed): a rejoin subscribes again and refetches
		d := vmap(data);
		if !fbool(d, "unavailable") {
			gid := fsnow(d, "id");
			table_remove(*c.subs.guilds, gid);
			table_set(*c.left_guilds, gid, true); // a rejoin sends op 43 again, but not the guild-open set
			locks.lock(*c.job_mu);
			if c.ready_subscribed_guild == gid c.ready_subscribed_guild = 0;
			locks.unlock(*c.job_mu);
		}
	case "GUILD_CREATE";
		if joined_guild_created(c, vmap(data)) || !c.pending_guild_create return;
		c.pending_guild_create = false;
		gid := fsnow(vmap(data), "id");
		g := guild_get(*c.store, gid);
		ch: Snowflake = ifx g then g.system_channel_id else 0;
		if g && !ch for cid: guild_channels_sorted(*c.store, gid) {
			chan := table_find_pointer(*c.store.channels, cid);
			if chan && chan.kind == .Guild_Text {
				ch = cid;
				break;
			}
		}
		guild_created_followups(c, gid);
		// a new guild shows its setup progress: the sidebar's action rows, then the
		// channel's welcome area (fixture create_guild)
		analytics_exposed(c, "useGuildActionRows", "2026-09-server-onboarding-setup-progress");
		analytics_exposed(c, "useWelcomeAreaSteps", "2026-09-server-onboarding-setup-progress", delay_ms = 650);
		// the new guild renders at once: op 43 and its guild-open set go out with the
		// page fetch, the subscription right after (fixture create_guild)
		select_channel(c, gid, ch, initial_message_limit(viewport_h(c)), prefetch = true);
		if c.pending_guild_open == gid guild_open_now(c, gid);
	case "MESSAGE_ACK";
		d := vmap(data);
		analytics_notifications_acked(c, fsnow(d, "channel_id"), fsnow(d, "message_id"));
	case "MESSAGE_CREATE";
		analytics_note_message(c, data);
		d := vmap(data);
		nv := fstr(d, "nonce");
		rt := ifx nv then table_find_pointer(*c.analytics.roundtrips, parse_snowflake(nv)) else null;
		if rt && rt.gateway == 0 rt.gateway = now_ms();
		gid := fsnow(d, "guild_id");
		locks.lock(*c.route_mu);
		viewing := c.route_channel == fsnow(d, "channel_id") && !c.route_scrolled_up; // shouldAutomaticallyAck: "Not at bottom"
		locks.unlock(*c.route_mu);
		cid, mid := fsnow(d, "channel_id"), fsnow(d, "id");
		if fsnow(fmap(d, "author"), "id") == c.store.me return;
		if viewing && c.focused && !c.idle_sent { // shouldAutomaticallyAck: never while idle
			ack_message(c, cid, mid, location = ACK_INCOMING_MESSAGE);
			return;
		}
		// otherwise a message that would notify us raises the mention count (every message
		// in a private channel; in a guild @me / @everyone; role mentions not modelled)
		ch := channel_get(*c.store, cid);
		mentions_me := fbool(d, "mention_everyone");
		for flist(d, "mentions") if fsnow(vmap(it), "id") == c.store.me mentions_me = true;
		if !(ch && ch.guild_id == 0) && !mentions_me return;
		rs := find_or_add(*c.store.read_states, cid);
		rs.channel_id = cid;
		if mid > rs.last_message_id rs.mention_count += 1;
	}
}

// viewport_h: the window height the message page size follows (720 until the app reports one).
viewport_h :: (c: *Client) -> int { return ifx c.analytics.viewport_h > 0 then c.analytics.viewport_h else 720; }

// ---- voice hand-off (src/voice) ----

// Voice_Server_Info is everything voice.voice_connect needs, assembled from
// our VOICE_STATE_UPDATE (session_id, channel) and VOICE_SERVER_UPDATE
// (endpoint, token, guild or private channel id).
Voice_Server_Info :: struct {
	endpoint: string; // host[:port] without scheme, as sent by Discord
	token: string;
	guild_or_channel_id: Snowflake; // server_id: guild id, or the DM/group channel for calls
	user_id: Snowflake;
	session_id: string;
	channel_id: Snowflake;
}

// voice_server_info returns the current voice connection parameters once both
// events for our session arrived (strings point into the store: copy them if
// they must outlive the next client_poll). `version` changes on every
// VOICE_SERVER_UPDATE so the app can reconnect when the server moves.
voice_server_info :: (c: *Client) -> Voice_Server_Info, u64, bool {
	s := *c.store;
	vs := table_find_pointer(*s.voice_states, s.me);
	if !vs || !s.voice_server.token || !s.voice_server.endpoint return .{}, 0, false;
	server := ifx s.voice_server.guild_id then s.voice_server.guild_id else s.voice_server.channel_id;
	if server != (ifx vs.guild_id then vs.guild_id else vs.channel_id) return .{}, 0, false;
	return .{
		endpoint = s.voice_server.endpoint,
		token = s.voice_server.token,
		guild_or_channel_id = server,
		user_id = s.me,
		session_id = vs.session_id,
		channel_id = vs.channel_id
	}, s.voice_server.version, true;
}

// voice_join: op 4 (flags 2) plus what selecting a voice channel loads: its
// text-in-voice page and the activity shelf (~155 ms).
// track = false: the caller sends join_voice_channel itself, after its own events (DM calls).
voice_join :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake, self_mute := false, self_deaf := false, track := true) {
	voice_update(c, guild_id, channel_id, self_mute, self_deaf);
	frecency_select(c, guild_id, channel_id); // VOICE_CHANNEL_SELECT
	// the voice channel's text view opens with the call
	analytics_channel_opened(c, guild_id, channel_id, selected_guild = false);
	if track analytics_join_voice(c, guild_id, channel_id);
	// Joining acks the channel's text chat unless it holds mentions.
	ch := channel_get(*c.store, channel_id);
	rs := table_find_pointer(*c.store.read_states, channel_id);
	if ch && ch.last_message_id > (ifx rs then rs.last_message_id else 0) && !(rs && rs.mention_count > 0) {
		ack_message(c, channel_id, ch.last_message_id, location = ACK_VOICE_CHANNEL_SELECT);
	}
	l := message_list(*c.store, channel_id);
	if !l.loaded && !l.loading fetch_messages(c, channel_id, 0, initial_message_limit(viewport_h(c)));
	if guild_id {
		j := job_new(.Api, .None);
		j.method = "GET";
		j.path = job_str(j, tprint("/activities/shelf?guild_id=%", guild_id));
		j.not_before = now_ms() + 155;
		j.on_done = analytics_shelf_fetched;
		job_submit(c, j);
	}
}

// voice_rtc_changed: RTC_CONNECTION_STATE (client_set_rtc_state). The QoS heartbeat's reasons follow
// RTC_CONNECTED; the first RTC_CONNECTED of a session fetches the soundboard: the default sounds and
// op 31 for every guild (READY order), op 31 before the QoS heartbeat (fixtures join_voice_channel,
// voice_with_b, dm_call).
voice_rtc_changed :: (c: *Client, connected: bool) {
	if c.rtc_connected == connected return;
	c.rtc_connected = connected;
	if connected && !c.soundboard_loaded {
		c.soundboard_loaded = true;
		api_get_later(c, "/soundboard-default-sounds", 0);
		if c.gw {
			b := etf.map_builder(1,, temp);
			etf.map_put(*b, "guild_ids", snowflake_list(c.store.guild_order));
			gateway_send(c.gw, .Request_Soundboard_Sounds, etf.vmap(etf.map_done(*b)));
		}
	}
	if c.gw gateway_set_active(c.gw, qos_from_state(c.focused, connected));
}

// voice_followed: VOICE_STATE_UPDATES for our own call (RTCConnectionStore, GatewayConnectionStore).
// `seen` is our voice state's channel at the last call. Once the server confirmed the channel we asked
// for (`call`), so our own joins and moves don't count, a change is the server's: moved by a moderator
// (the call and VoiceStateStore's state follow, nothing is sent) or removed (0: kicked, channel
// deleted, call ended). Returns the call's channel.
voice_followed :: (c: *Client, call: Snowflake, seen: *Snowflake) -> Snowflake {
	vs := table_find_pointer(*c.store.voice_states, c.store.me);
	now_in := ifx vs then vs.channel_id else 0;
	defer seen.* = now_in;
	if !seen.* || seen.* != call || now_in == call return call;
	locks.lock(*c.route_mu);
	c.voice_self.channel_id = now_in;
	c.voice_self.guild_id = ifx now_in then vs.guild_id else 0;
	locks.unlock(*c.route_mu);
	return now_in;
}

voice_leave :: (c: *Client) {
	voice_update(c, 0, 0, c.cfg.voice_self_mute, false);
	analytics_voice_leave(c);
	frecency_select(c, 0, 0); // VOICE_CHANNEL_SELECT
}

// voice_set_state: op 4 in the current channel without the join side effects
// (mute / deafen / camera toggles).
voice_set_state :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake, self_mute: bool, self_deaf: bool, self_video: bool) {
	voice_update(c, guild_id, channel_id, self_mute, self_deaf, self_video);
}

// ---- Go Live (op 18-22). Guessed from the gateway's documented opcodes and
// what Discord's own streamers send; see traffic/CLIENT_RULES.md. ----

stream_key :: (guild_id: Snowflake, channel_id: Snowflake, user_id: Snowflake, allocator := temp) -> string {
	if guild_id return sprint("guild:%:%:%", guild_id, channel_id, user_id,, allocator);
	return sprint("call:%:%", channel_id, user_id,, allocator);
}

// stream_create: start our own stream in the voice channel we are in.
stream_create :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake) {
	if !c.gw return;
	b := etf.map_builder(4,, temp);
	etf.map_put(*b, "type", etf.vstring(ifx guild_id then "guild" else "call"));
	etf.map_put(*b, "guild_id", ifx guild_id then etf.vstring(snowflake_string(guild_id)) else V.{});
	etf.map_put(*b, "channel_id", etf.vstring(snowflake_string(channel_id)));
	etf.map_put(*b, "preferred_region", V.{});
	gateway_send(c.gw, .Stream_Create, etf.vmap(etf.map_done(*b)));
}

stream_key_op :: (c: *Client, op: Op, key: string, paused := -1) {
	if !c.gw return;
	b := etf.map_builder(2,, temp);
	etf.map_put(*b, "stream_key", etf.vstring(key));
	if paused >= 0 etf.map_put(*b, "paused", etf.vbool(paused == 1));
	gateway_send(c.gw, op, etf.vmap(etf.map_done(*b)));
}

stream_watch :: (c: *Client, key: string) { stream_key_op(c, .Stream_Watch, key); }
// stream_delete ends our stream, or stops watching someone else's.
stream_delete :: (c: *Client, key: string) { stream_key_op(c, .Stream_Delete, key); }
stream_set_paused :: (c: *Client, key: string, paused: bool) { stream_key_op(c, .Stream_Set_Paused, key, xx paused); }

// stream_server_info: the voice connection for a stream once STREAM_CREATE and
// STREAM_SERVER_UPDATE arrived; version changes per STREAM_SERVER_UPDATE.
stream_server_info :: (c: *Client, key: string) -> Voice_Server_Info, u64, bool {
	s := *c.store;
	vs := table_find_pointer(*s.voice_states, s.me);
	if !vs return .{}, 0, false;
	for s.streams {
		if it.key != key || !it.token || !it.endpoint || !it.rtc_server_id continue;
		return .{endpoint = it.endpoint, token = it.token, guild_or_channel_id = it.rtc_server_id, user_id = s.me,
			session_id = vs.session_id, channel_id = vs.channel_id}, it.version, true;
	}
	return .{}, 0, false;
}


// guild_channel_info: op 43 sent when a guild's channel is shown.
guild_channel_info :: (c: *Client, guild_id: Snowflake) {
	if !c.gw return;
	b := etf.map_builder(2,, temp);
	etf.map_put(*b, "guild_id", etf.vstring(snowflake_string(guild_id)));
	etf.map_put(*b, "fields", etf.vlist(array_copy(V.[etf.vstring("status"), etf.vstring("voice_start_time")],, temp)));
	gateway_send(c.gw, .Request_Channel_Info, etf.vmap(etf.map_done(*b)));
}

// guild_open_now: op 43 and the guild-open set for the guild entered first in
// the session. Re-entering a guild sends neither (fixtures history_nav: Friends
// -> back to the guild; discover: discovery -> the guild).
guild_open_now :: (c: *Client, g: Snowflake) {
	c.pending_guild_open = 0;
	if !table_contains(*c.started_guilds, g) {
		table_set(*c.started_guilds, g, true);
		guild_channel_info(c, g);
		schedule_guild_open(c, g, c.guild_open_promotions);
	} else if table_contains(*c.left_guilds, g) {
		// rejoined after leaving (fixture join_leave_server): op 43 only
		table_remove(*c.left_guilds, g);
		guild_channel_info(c, g);
	}
	c.guild_open_promotions = false;
}

// guild_channel_notice_check: a guild text channel route rendering, for a member
// who can manage the guild, when the guild has no system channel, loads the
// guild's integrations (every such render: fixtures history_nav, discover,
// threads_browser, settings, streamer_mode; never with a system channel set).
guild_channel_notice_check :: (c: *Client, ch: *Channel) {
	if !ch.guild_id || is_thread(ch) || (ch.kind != .Guild_Text && ch.kind != .Guild_Announcement) return;
	g := guild_get(*c.store, ch.guild_id);
	if !g || g.system_channel_id || (guild_permissions(*c.store, g.id) & PERM_MANAGE_GUILD) == 0 return;
	api_get_later(c, tprint("/guilds/%/integrations?include_applications=true&include_role_connections_metadata=true", g.id), 0);
}

// on_channel_page runs when the first page of a selected channel arrives
// (or immediately when cached): the follow-ups the official client issues
// once the channel renders.
on_channel_page :: (c: *Client, channel_id: Snowflake, got: int, full: bool) {
	_, ch := table_find(*c.store.channels, channel_id);
	g := c.pending_guild_open;
	if g && (ch.guild_id == g || !ch.guild_id) guild_open_now(c, g);
	locks.lock(*c.route_mu);
	on_route := c.route_channel == channel_id;
	locks.unlock(*c.route_mu);
	if on_route guild_channel_notice_check(c, *ch);
	if full {
		// Fill the viewport: one older page of 20.
		msgs := messages_get(*c.store, channel_id);
		if msgs fetch_messages(c, channel_id, msgs[0].id, 20);
	}
	if channel_id && c.pending_private_open == channel_id {
		c.pending_private_open = 0;
		if c.gw {
			cb := etf.map_builder(1,, temp);
			etf.map_put(*cb, "channel_id", etf.vstring(snowflake_string(channel_id)));
			gateway_send(c.gw, .Call_Connect, etf.vmap(etf.map_done(*cb)));
		}
		if ch.kind == .DM && ch.recipient_ids.count == 1 {
			u := ch.recipient_ids[0];
			// the profile sidebar renders with the last (sidebar) profile response
			profile_view_begin(c, .Sidebar, u, 0, channel_id, 0, wait = ifx c.pending_private_prefetch then 2 else 3);
			fetch_profile_ex(c, u, .{mutual_guilds = false, mutual_friends = false, mutual_friends_count = false});
			// the mutual-guilds-only fetch: not on a sidebar open (fixtures open_dm, close_dm: two
			// profiles; quick_switcher_nav, start_group_dm: three)
			if !c.pending_private_prefetch fetch_profile_ex(c, u, .{mutual_guilds = true, mutual_friends = false, mutual_friends_count = false, delay_ms = 223});
			fetch_note(c, u, 223);
			fetch_profile_ex(c, u, .{kind = "sidebar", mutual_guilds = true, mutual_friends = true, mutual_friends_count = false, delay_ms = 476});
		}
	}
	// Viewing a channel with unread messages acks it (ReadState, 3 s timer),
	// only while the window has focus (fixtures, unfocused: mark_as_read sends no ack).
	if channel_unread(*c.store, channel_id) && identity_app_state(*c.id) == .Focused && !c.idle_sent {
		if messages_get(*c.store, channel_id) ack_message(c, channel_id, ch.last_message_id, location = ACK_CHANNEL_SCROLL);
	}
}

Profile_Options :: struct {
	kind: string; // "" (DM header), "popout", "sidebar", "modal"
	mutual_guilds: bool;
	mutual_friends: bool;
	mutual_friends_count: bool;
	guild_id: Snowflake;
	delay_ms: s64;
}

// fetch_profile_ex: GET /users/{id}/profile?[type=]&with_mutual_guilds=&with_mutual_friends=&with_mutual_friends_count=[&guild_id=]
fetch_profile_ex :: (c: *Client, user_id: Snowflake, o: Profile_Options, tag: u64 = 0) {
	q: Query;
	query_init(*q, tprint("/users/%/profile", user_id));
	if o.kind query_add(*q, "type", o.kind);
	query_add_bool(*q, "with_mutual_guilds", o.mutual_guilds);
	query_add_bool(*q, "with_mutual_friends", o.mutual_friends);
	query_add_bool(*q, "with_mutual_friends_count", o.mutual_friends_count);
	if o.guild_id query_add_snow(*q, "guild_id", o.guild_id);
	j := job_new(.Api, .Fetch_Profile);
	j.method = "GET";
	j.path = job_str(j, query_string(*q));
	j.not_before = now_ms() + o.delay_ms;
	j.result = .{op = .Fetch_Profile, user_id = user_id, tag = tag};
	job_submit(c, j);
}

// fetch_note: GET /users/@me/notes/{id} (profile popouts/sidebars).
fetch_note :: (c: *Client, user_id: Snowflake, delay_ms: s64 = 0) {
	j := job_new(.Api, .None);
	j.method = "GET";
	j.path = job_str(j, tprint("/users/@me/notes/%", user_id));
	j.not_before = now_ms() + delay_ms;
	job_submit(c, j);
}

// open_profile_popout: what clicking a username does: profile, application
// identities and featured widgets at once, referral eligibility ~460 ms and
// the note ~720 ms later (fixture open_profile_popout).
// channel_id / message_id: where the username was clicked (telemetry).
open_profile_popout :: (c: *Client, user_id: Snowflake, guild_id: Snowflake, channel_id: Snowflake = 0, message_id: Snowflake = 0) {
	profile_view_begin(c, .Popout, user_id, guild_id, channel_id, message_id);
	fetch_profile_ex(c, user_id, .{kind = "popout", guild_id = guild_id});
	api_get_later(c, tprint("/users/%/application-identities?with_profiles=true", user_id), 0);
	api_get_later(c, "/widget-configs/featured", 0);
	api_get_later(c, "/users/@me/referrals/eligibility", 463);
	fetch_note(c, user_id, 723);
}

// open_user_settings: requests the settings modal makes when it opens.
open_user_settings :: (c: *Client) {
	j := job_new(.Web, .None);
	j.method = "GET";
	j.host = API_HOST;
	j.path = "/__development/build_overrides";
	j.site = .Same_Origin;
	job_submit(c, j);
	api_get_later(c, "/users/@me/billing/payment-sources", 0);
	api_get_later(c, "/users/@me/billing/location-info", 0);
	api_get_later(c, "/auth/sessions", 0);
	api_get_later(c, "/safety-hub/@me", 0);
	// no custom-themes: that is the Appearance pane's load (settings_pane_shown);
	// fixtures settings, streamer_mode, account_edits open without it
}

// api_get_later: a plain authenticated GET (fire and forget).
api_get_later :: (c: *Client, path: string, delay_ms: s64) {
	j := job_new(.Api, .None);
	j.method = "GET";
	j.path = job_str(j, path);
	j.not_before = now_ms() + delay_ms;
	job_submit(c, j);
}

// open_full_profile: "View Full Profile" from a popout (fixture open_full_profile).
// The applications/public, games and oauth2/tokens follow-ups depend on the
// profile's widget/app data and are not issued (see traffic/PARITY.md).
// via: the popout element clicked to open it ("avatar"), "" when not from a popout.
open_full_profile :: (c: *Client, user_id: Snowflake, guild_id: Snowflake, via := "avatar") {
	v := *c.analytics.profile;
	if via && v.layout == .Popout && v.user_id == user_id && v.session != "" {
		profile_action(c, v, string.["username", "user profile popout", via], "PRESS_VIEW_PROFILE");
	}
	profile_view_begin(c, .Modal, user_id, guild_id, ifx v.user_id == user_id then v.channel_id else 0, ifx v.user_id == user_id then v.message_id else 0);
	api_get_later(c, tprint("/content-inventory/users/%/outbox", user_id), 0);
	fetch_profile_ex(c, user_id, .{kind = "modal", mutual_guilds = true, mutual_friends_count = true, guild_id = guild_id});
	api_get_later(c, "/collectibles-categories/v2?include_bundles=true&variants_return_style=2&skip_num_categories=0", 100);
	api_get_later(c, "/users/@me/collectibles-purchases?variants_return_style=2", 100);
	api_get_later(c, "/users/@me/activities/statistics/applications", 100);
	api_get_later(c, "/users/@me/widgets/suggested-games", 100);
	api_get_later(c, tprint("/users/%/application-identities?with_profiles=true", user_id), 100);
}

// open_message_context_menu: right-clicking a message loads the application
// command indexes (guild once per guild, user once per session). From the message
// menu they leave about 80 ms after it opens, after its science batch (fixture
// add_reaction 38 ms, site recording 72 ms after the batch, which leaves 30 ms after
// the click), and a guild miss tracks its two cache_fetch events as the fetch starts.
COMMAND_INDEX_DELAY_MS :: 80;
open_message_context_menu :: (c: *Client, guild_id: Snowflake, message_menu := false) {
	delay: s64 = ifx message_menu then COMMAND_INDEX_DELAY_MS else 0;
	if guild_id && !table_contains(*c.command_index_guilds, guild_id) {
		table_set(*c.command_index_guilds, guild_id, true);
		j := job_new(.Api, .None);
		j.method = "GET";
		j.path = job_str(j, tprint("/guilds/%/application-command-index", guild_id));
		j.not_before = now_ms() + delay;
		if message_menu j.on_start = (c: *Client, j: *Job) { // the two cache_fetch misses, around the fetch's start
			n := c.command_index_guilds.count;
			analytics_command_cache_fetch(c, true, n - 1);
			analytics_command_cache_fetch(c, true, n);
		};
		j.on_done = analytics_command_index_loaded;
		job_submit(c, j);
	}
	if !c.command_index_user {
		c.command_index_user = true;
		j := job_new(.Api, .None);
		j.method = "GET";
		j.path = "/users/@me/application-command-index";
		j.not_before = now_ms() + delay;
		j.on_done = analytics_command_index_loaded;
		job_submit(c, j);
	}
}

// open_emoji_picker: the reaction/emoji picker's first open in a session.
open_emoji_picker :: (c: *Client, guild_id: Snowflake) {
	if c.emoji_picker_opened return;
	c.emoji_picker_opened = true;
	if guild_id guild_top_emojis(c, guild_id); // through the picker pool: the UI gets the result
	b := job_new(.Api, .None);
	b.method = "GET";
	b.path = "/users/@me/billing/subscriptions?sync_level=2";
	job_submit(c, b);
	fetch_profile_ex(c, c.store.me, .{});
}

// ---- UserAffinitiesV2Store (bundle module 427358) ----
// Persisted. shouldFetch: no fetch in flight and more than 8 h since the last success; a
// failure (B's 404) leaves lastFetched, so it is asked again at the next trigger. Each
// user's communication_probability / _rank go into user_profile_action.
Affinity :: struct { probability: string; rank: s64; } // probability: JSON number text, as received
Affinities :: struct {
	users: Table(Snowflake, Affinity);
	fetched_ms: s64;
	fetching: bool;
}
AFFINITIES_STALE_MS :: 8 * 3_600_000;

affinities_job :: (j: *Job) {
	j.skip_if = (c: *Client) -> bool {
		locks.lock(*c.job_mu);
		defer locks.unlock(*c.job_mu);
		a := *c.affinities;
		if a.fetching || now_ms() - a.fetched_ms <= AFFINITIES_STALE_MS return true;
		a.fetching = true;
		return false;
	};
	j.on_response = (c: *Client, j: *Job, status: int, body: V) {
		locks.lock(*c.job_mu);
		defer locks.unlock(*c.job_mu);
		a := *c.affinities;
		a.fetching = false;
		if status != 200 return;
		a.fetched_ms = now_ms();
		for a.users free(it.probability,, c.allocator);
		table_reset(*a.users);
		for flist(vmap(body), "user_affinities") {
			m := vmap(it);
			table_set(*a.users, fsnow(m, "other_user_id"), .{copy_string(js_number(vf64(vget(m, "communication_probability"))),, c.allocator), fint(m, "communication_rank")});
		}
	};
}

affinity_get :: (c: *Client, user_id: Snowflake) -> Affinity, bool {
	locks.lock(*c.job_mu);
	defer locks.unlock(*c.job_mu);
	ok, a := table_find(*c.affinities.users, user_id);
	return .{copy_string(a.probability,, temp), a.rank}, ok;
}

// home_open: the friends/home surface's first render in a session (when the
// client did not start on it): referral eligibility, quest applications and
// the premium-guild entitlements, together (fixture open_dm, ~6.9 s). An
// unverified account loads user affinities instead of the entitlements
// (fixture join_leave_server, B after Leave Server).
// Every later open of Friends loads the premium-guild entitlements again
// (fixture history_nav: each forward to Friends).
home_open :: (c: *Client) {
	if c.home_opened {
		api_get_later(c, "/users/@me/entitlements?with_sku=false&with_application=false&entitlement_type=11&exclude_ended=true", 0);
		return;
	}
	c.home_opened = true;
	if client_route_kind(c.start_route_guild, c.start_route_channel) == .Home return; // startup table covers it
	api_get_later(c, "/users/@me/referrals/eligibility", 0);
	{ j := job_new(.Api, .None); j.method = "GET"; j.path = "/users/@me/affinities/v2/users"; affinities_job(j); job_submit(c, j); }
	locks.lock(*c.job_mu);
	ready := c.ready_ms;
	locks.unlock(*c.job_mu);
	saved := c.start_route_guild;
	c.start_route_guild = 0;
	c.start_route_channel = 0;
	schedule_applications_public(c, ready);
	c.start_route_guild = saved;
	if c.account_verified api_get_later(c, "/users/@me/entitlements?with_sku=false&with_application=false&entitlement_type=11&exclude_ended=true", 0);
}

// ---- guilds ----

// GUILD_TEMPLATE_FRIENDS: "Create My Own" -> "For me and my friends".
GUILD_TEMPLATE_FRIENDS :: "2TffvPucqHkN";

// create_guild: POST /guilds as the create-guild modal sends it
// ({name, icon, channels: [], system_channel_id, guild_template_code}); when
// GUILD_CREATE arrives the client navigates into it (select_channel) and loads
// the new-guild extras (guild_created_followups).
// step_shown_ms: when the modal's last step ("Customize your server") was shown (telemetry).
create_guild :: (c: *Client, name: string, icon_data_uri := "", template := GUILD_TEMPLATE_FRIENDS, step_shown_ms: s64 = 0) {
	c.analytics.guild_create_step_ms = step_shown_ms;
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "name", name);
	if icon_data_uri json_kstr(*w, "icon", icon_data_uri);
	else json_knull(*w, "icon");
	json_key(*w, "channels");
	json_raw(*w, "[]");
	json_knull(*w, "system_channel_id");
	json_kstr(*w, "guild_template_code", template);
	json_obj_end(*w);
	j := job_new(.Api, .None);
	j.method = "POST";
	j.path = "/guilds";
	j.body = cast([]u8) job_str(j, json_string(*w));
	j.content_type = "application/json";
	j.on_done = (c: *Client, j: *Job, status: int) {
		if status analytics_guild_create_result(c, status, c.analytics.guild_create_step_ms);
	};
	job_submit(c, j);
	c.pending_guild_create = true;
}

// guild_created_followups: requests seen right after creating a guild
// (boost/premium panels of the new guild): payment sources and
// subscriptions (twice, from two components), the server-shop listing ~310 ms
// and powerups ~650 ms later.
guild_created_followups :: (c: *Client, guild_id: Snowflake) {
	api_get_later(c, "/users/@me/billing/payment-sources", 0);
	api_get_later(c, "/users/@me/billing/subscriptions?sync_level=2", 0);
	api_get_later(c, "/users/@me/billing/payment-sources", 1);
	api_get_later(c, "/users/@me/billing/subscriptions?sync_level=2", 1);
	cc := ifx c.store.country_code then c.store.country_code else "US";
	api_get_later(c, tprint("/store/published-listings/skus?country_code=%&application_id=1340102344645283891&guild_id=%", cc, guild_id), 313);
	api_get_later(c, tprint("/guilds/%/integrations?include_applications=true&include_role_connections_metadata=true", guild_id), 649);
	api_get_later(c, tprint("/guilds/%/powerups?country_code=%&include_ends_at=true", guild_id, cc), 650);
}

// ---- group DMs ----

// create_group_dm: "New Group DM" with no one selected: POST /users/@me/channels
// {"recipients":[]} (location "New Group DM"); the new channel opens.
create_group_dm :: (c: *Client, user_ids: []Snowflake = .[], tag: u64 = 0) {
	analytics_create_dm_clicked(c, user_ids);
	create_private_channel(c, user_ids, "New Group DM", tag);
}

// create_group_dm_invite: opening "Invite to Group DM" creates an invite link:
// POST /channels/{id}/invites {"max_age":86400} (location "Group DM Invite Create").
create_group_dm_invite :: (c: *Client, channel_id: Snowflake) {
	j := job_new(.Api, .None);
	j.method = "POST";
	j.path = job_str(j, channel_path(channel_id, "/invites"));
	j.body = cast([]u8) job_str(j, "{\"max_age\":86400}");
	j.content_type = "application/json";
	j.context_b64 = job_str(j, context_location("Group DM Invite Create"));
	job_submit(c, j);
}

// add_group_recipient: PUT /channels/{id}/recipients/{user} (friends only).
add_group_recipient :: (c: *Client, channel_id: Snowflake, user_id: Snowflake) {
	j := job_new(.Api, .None);
	j.method = "PUT";
	j.path = job_str(j, channel_path(channel_id, "/recipients/", snowflake_string(user_id)));
	job_submit(c, j);
}

remove_group_recipient :: (c: *Client, channel_id: Snowflake, user_id: Snowflake) {
	j := job_new(.Api, .None);
	j.method = "DELETE";
	j.path = job_str(j, channel_path(channel_id, "/recipients/", snowflake_string(user_id)));
	job_submit(c, j);
}

// delete_guild: POST /guilds/{id}/delete {} (owner).
delete_guild :: (c: *Client, guild_id: Snowflake) {
	j := job_new(.Api, .None);
	j.method = "POST";
	j.path = job_str(j, tprint("/guilds/%/delete", guild_id));
	j.body = cast([]u8) job_str(j, "{}");
	j.content_type = "application/json";
	job_submit(c, j);
}


// open_account_popout: the account panel's popout (status / custom status).
// First open in a session: own profile (type=account_popout), application
// identities and the featured widget configs; when those arrive the popout
// loads activity statistics, the featured applications and /users/@me.
// Later opens only refresh /users/@me (fixtures status_change, custom_status).
open_account_popout :: (c: *Client) {
	profile_view_begin(c, .Account_Popout, c.store.me, 0, 0, 0);
	if c.account_popout_opened {
		analytics_on_profile(c, c.store.me); // the profile is loaded: it shows at once
		users_me_refresh(c, 650);
		return;
	}
	c.account_popout_opened = true;
	fetch_profile_ex(c, c.store.me, .{kind = "account_popout"});
	api_get_later(c, tprint("/users/%/application-identities?with_profiles=true", c.store.me), 0);
	j := job_new(.Api, .None);
	j.method = "GET";
	j.path = "/widget-configs/featured";
	j.on_body = (c: *Client, body: V) {
		api_get_later(c, "/users/@me/activities/statistics/applications", 55);
		q: Query;
		query_init(*q, "/applications/public");
		n := 0;
		for flist(vmap(body), "applications") {
			id := fsnow(vmap(it), "id");
			if !id continue;
			query_add_snow(*q, "application_ids", id);
			n += 1;
		}
		if n api_get_later(c, query_string(*q), 55);
		users_me_refresh(c, 55);
	};
	job_submit(c, j);
}

// users_me_refresh: the popout's GET /users/@me (its fetch spells the header
// "authorization" in lowercase).
users_me_refresh :: (c: *Client, delay_ms: s64) {
	j := job_new(.Api, .None);
	j.method = "GET";
	j.path = "/users/@me";
	j.js_lower_auth = true;
	j.not_before = now_ms() + delay_ms;
	job_submit(c, j);
}

// request_page_members: GuildMemberRequester. Authors and mentioned users of a
// fetched guild page with no known member are asked for at once with op 8
// (presences false), each once (fixture scroll_history: the older page's one
// unknown author).
request_page_members :: (c: *Client, channel_id: Snowflake, items: []V) {
	ch := channel_get(*c.store, channel_id);
	if !ch || !ch.guild_id return;
	gid := ch.guild_id;
	ids: [..]Snowflake;
	ids.allocator = temp;
	want :: (c: *Client, gid: Snowflake, uid: Snowflake, ids: *[..]Snowflake) {
		if !uid || member_get(*c.store, gid, uid) return;
		key := Snowflake.[gid, uid];
		if table_contains(*c.members_requested, key) return;
		table_set(*c.members_requested, key, true);
		array_add(ids, uid);
	}
	for items {
		m := vmap(it);
		if vis_null(vget(m, "webhook_id")) want(c, gid, fsnow(fmap(m, "author"), "id"), *ids);
		for flist(m, "mentions") want(c, gid, fsnow(vmap(it), "id"), *ids);
	}
	if ids request_guild_members(c, gid, ids);
}
