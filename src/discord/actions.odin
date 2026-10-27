package discord

import "fc:locks"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "fc:etf"

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
select_channel :: proc(c: ^Client, guild_id, channel_id: Snowflake, message_limit := 50, prefetch := false, source := "") {
	prev_referer := strings.clone(client_route_referer(c), context.temp_allocator) if prefetch else ""
	locks.lock(&c.route_mu)
	prev_guild := c.route_guild
	c.route_guild = guild_id
	c.route_channel = channel_id
	locks.unlock(&c.route_mu)
	if guild_id != 0 && guild_id != prev_guild {
		subscribe_guild(c, guild_id)
		if prefetch do c.subs.not_before = now_ms() + 2
		c.pending_guild_open = guild_id
	}
	if guild_id == 0 && channel_id != 0 do c.pending_private_open = channel_id
	if guild_id == 0 && channel_id == 0 do home_open(c)
	if channel_id != 0 {
		l := message_list(&c.store, channel_id)
		if !l.loaded && !l.loading {
			fetch_messages(c, channel_id, 0, message_limit, referer = prev_referer)
		} else {
			on_channel_page(c, channel_id, 0, false)
		}
		analytics_channel_opened(c, guild_id, channel_id, location = source)
	}
	if guild_id != 0 && guild_id != prev_guild do analytics_guild_viewed(c, guild_id, channel_id)
}

// initial_message_limit reproduces the client's page size for a channel open:
// clamp(ceil(1.05 * ceil(max(h-145,400) / (compact ? 65 : 91) * (16 / font_px))), 10, 100).
initial_message_limit :: proc(window_height: int, compact := false, font_px := 16) -> int {
	h := max(window_height - 145, 400)
	per := 65.0 if compact else 91.0
	rows := f64(h) / (per * (f64(font_px) / 16.0))
	n := int(1.05 * f64(int(rows + 0.999999)) + 0.999999)
	return clamp(n, 10, 100)
}

// ---- guild subscriptions (op 37) ----

Subscriptions :: struct {
	guilds:   map[Snowflake]bool, // typing/activities/threads sent
	channels: map[Snowflake][dynamic]Member_Range, // guild -> channel list ranges (one channel at a time)
	pending:  [dynamic]Pending_Sub,
	not_before: i64, // prefetching select: op 37 follows the route change (after the fetch)
}

Member_Range :: struct {
	channel_id: Snowflake,
	ranges:     [dynamic][2]int,
}

Pending_Sub :: struct {
	guild_id:      Snowflake,
	feature:       bool, // typing/activities/threads
	channel_id:    Snowflake,
	ranges:        [dynamic][2]int,
	member_ids:    [dynamic]Snowflake,
}

subscriptions_init :: proc(s: ^Subscriptions, allocator := context.allocator) {
	s.guilds = make(map[Snowflake]bool, allocator = allocator)
	s.channels = make(map[Snowflake][dynamic]Member_Range, allocator = allocator)
	s.pending = make([dynamic]Pending_Sub, allocator)
}

@(private)
pending_for :: proc(c: ^Client, guild_id: Snowflake) -> ^Pending_Sub {
	for &p in c.subs.pending do if p.guild_id == guild_id do return &p
	append(&c.subs.pending, Pending_Sub{guild_id = guild_id, ranges = make([dynamic][2]int, c.allocator), member_ids = make([dynamic]Snowflake, c.allocator)})
	return &c.subs.pending[len(c.subs.pending) - 1]
}

// subscribe_guild: subscribeToGuild — typing, activities, threads (merged and
// flushed on the next poll like the client's 0 ms flush timer).
subscribe_guild :: proc(c: ^Client, guild_id: Snowflake) {
	if c.subs.guilds[guild_id] do return
	c.subs.guilds[guild_id] = true
	pending_for(c, guild_id).feature = true
}

// subscribe_member_list subscribes to the lazy member sidebar of a channel
// (ranges of 100: [[0,99]], [[0,99],[100,199]], ...).
subscribe_member_list :: proc(c: ^Client, guild_id, channel_id: Snowflake, ranges: [][2]int) {
	p := pending_for(c, guild_id)
	p.channel_id = channel_id
	clear(&p.ranges)
	for r in ranges do append(&p.ranges, r)
}

// subscribe_members: member presence/updates for specific users (profile popouts).
subscribe_members :: proc(c: ^Client, guild_id: Snowflake, user_ids: []Snowflake) {
	p := pending_for(c, guild_id)
	for u in user_ids do if !slice.contains(p.member_ids[:], u) do append(&p.member_ids, u)
}

subscriptions_flush :: proc(c: ^Client) {
	if len(c.subs.pending) == 0 do return
	if c.subs.not_before != 0 && now_ms() < c.subs.not_before do return
	c.subs.not_before = 0
	defer {
		for &p in c.subs.pending {
			delete(p.ranges)
			delete(p.member_ids)
		}
		clear(&c.subs.pending)
	}
	if c.gw == nil do return
	context.allocator = context.temp_allocator
	subs := etf.map_builder(len(c.subs.pending))
	for p in c.subs.pending {
		g := etf.map_builder(5)
		if p.feature {
			etf.map_put(&g, "typing", true)
			etf.map_put(&g, "activities", true)
			etf.map_put(&g, "threads", true)
		}
		if len(p.member_ids) > 0 {
			ids := make([]V, len(p.member_ids))
			for u, i in p.member_ids do ids[i] = snowflake_string(u)
			etf.map_put(&g, "members", etf.List(ids))
		}
		if p.channel_id != 0 {
			rl := make([]V, len(p.ranges))
			for r, i in p.ranges do rl[i] = etf.List{i64(r[0]), i64(r[1])}
			ch := etf.map_builder(1)
			etf.map_put(&ch, snowflake_string(p.channel_id), etf.List(rl))
			etf.map_put(&g, "channels", etf.map_done(&ch))
		}
		etf.map_put(&subs, snowflake_string(p.guild_id), etf.map_done(&g))
	}
	d := etf.map_builder(1)
	etf.map_put(&d, "subscriptions", etf.map_done(&subs))
	gateway_send(c.gw, .Guild_Subscriptions_Bulk, etf.map_done(&d))
}

// request_guild_members: op 8 for unknown message authors / mentions.
request_guild_members :: proc(c: ^Client, guild_id: Snowflake, user_ids: []Snowflake, presences := false) {
	if c.gw == nil do return
	context.allocator = context.temp_allocator
	for start := 0; start < len(user_ids); start += 100 {
		chunk := user_ids[start:min(start + 100, len(user_ids))]
		ids := make([]V, len(chunk))
		for u, i in chunk do ids[i] = snowflake_string(u)
		b := etf.map_builder(5)
		etf.map_put(&b, "guild_id", etf.List{snowflake_string(guild_id)})
		etf.map_put(&b, "query", nil)
		etf.map_put(&b, "limit", nil)
		etf.map_put(&b, "user_ids", etf.List(ids))
		etf.map_put(&b, "presences", presences)
		gateway_send(c.gw, .Request_Guild_Members, etf.map_done(&b))
	}
}

// voice_join / voice_leave: op 4 as VoiceStateStore sends it.
voice_update :: proc(c: ^Client, guild_id, channel_id: Snowflake, self_mute, self_deaf: bool) {
	if c.gw == nil do return
	v := voice_state_value(guild_id, channel_id, self_mute, self_deaf, false, 2)
	// joining: RTCRegionStore's preferred regions (latency probe order, top 5)
	if channel_id != 0 {
		locks.lock(&c.id.mu)
		regions := strings.split(c.rtc_regions, ",", context.temp_allocator) if c.rtc_regions != "" else nil
		locks.unlock(&c.id.mu)
		if len(regions) > 0 {
			m := vmap(v)
			list := make([]V, min(len(regions), 5), context.temp_allocator)
			for r, i in regions[:len(list)] do list[i] = V(r)
			ext := make([]etf.Pair, len(m) + 2, context.temp_allocator)
			copy(ext, ([]etf.Pair)(m))
			ext[len(m)] = {key = V(string("preferred_region")), value = V(regions[0])}
			ext[len(m) + 1] = {key = V(string("preferred_regions")), value = etf.List(list)}
			v = etf.Map(ext)
		}
	}
	gateway_send(c.gw, .Voice_State_Update, v)
}

// schedule_rtc_probe: GET latency.discord.media/rtc?v=2 (RTCRegionStore);
// the fixtures see it 3-25 s after start. The response's region order is what
// op 4 sends as preferred_regions (persisted for the next launch).
schedule_rtc_probe :: proc(c: ^Client, base: i64) {
	j := job_new(.Web, .Startup)
	j.method = "GET"
	j.host = "latency.discord.media"
	j.path = "/rtc?v=2"
	j.site = .Cross_Site
	j.not_before = base + 8000 + i64(rand.uint32() % 17000)
	j.on_body = proc(c: ^Client, body: V) {
		sb := strings.builder_make(context.temp_allocator)
		for r, i in vlist(body) {
			if i > 0 do strings.write_byte(&sb, ',')
			strings.write_string(&sb, fstr(vmap(r), "region"))
		}
		if len(sb.buf) == 0 do return
		locks.lock(&c.id.mu)
		delete(c.rtc_regions, c.allocator)
		c.rtc_regions = strings.clone(strings.to_string(sb), c.allocator)
		locks.unlock(&c.id.mu)
	}
	job_submit(c, j)
}

// ---- messages ----

@(private)
channel_path :: proc(channel_id: Snowflake, rest: ..string) -> string {
	parts := make([dynamic]string, 0, 2 + len(rest), context.temp_allocator)
	append(&parts, "/channels/", snowflake_string(channel_id))
	for r in rest do append(&parts, r)
	return strings.concatenate(parts[:], context.temp_allocator)
}

// fetch_messages: GET /channels/{id}/messages?before=&limit= (retries 2).
fetch_messages :: proc(c: ^Client, channel_id: Snowflake, before: Snowflake = 0, limit := 50, tag: u64 = 0, referer := "") {
	q: Query
	query_init(&q, channel_path(channel_id, "/messages"))
	if before != 0 do query_add_snow(&q, "before", before)
	query_add_int(&q, "limit", limit)
	j := job_new(.Api, .Fetch_Messages)
	j.method = "GET"
	j.path = job_str(j, query_string(&q))
	j.retries = 2
	if referer != "" do j.referer = job_str(j, referer)
	j.result.channel_id = channel_id
	j.result.limit = limit
	j.result.before = before
	j.result.tag = tag
	message_list(&c.store, channel_id).loading = true
	job_submit(c, j)
}

Send_Options :: struct {
	reply_to:        Snowflake, // message id
	reply_guild_id:  Snowflake, // guild of the replied channel (0 for DMs)
	mention_replied: bool, // false -> allowed_mentions {parse:[...], replied_user:false}
	tts:             bool,
	flags:           u64,
	location:        string, // x-context-properties location ("" -> "chat_input")
	sticker_ids:     []Snowflake,
	files:           []Upload_File, // uploaded at send (POST /attachments + PUT each, then the message)
	attachments:     []Draft_Attachment, // already staged with upload_draft (the composer's flow)
	tag:             u64,
}

@(private)
write_message_body_prefix :: proc(w: ^Json, channel_id: Snowflake, content: string, nonce: Snowflake, opts: Send_Options) {
	json_obj(w)
	json_kstr(w, "mobile_network_type", "unknown")
	json_kstr(w, "content", content)
	json_kstr(w, "nonce", snowflake_string(nonce))
	json_kbool(w, "tts", opts.tts)
	if opts.reply_to != 0 {
		json_key(w, "message_reference")
		json_obj(w)
		if opts.reply_guild_id != 0 do json_ksnow(w, "guild_id", opts.reply_guild_id)
		json_ksnow(w, "channel_id", channel_id)
		json_ksnow(w, "message_id", opts.reply_to)
		json_obj_end(w)
		if !opts.mention_replied {
			json_key(w, "allowed_mentions")
			json_obj(w)
			json_key(w, "parse")
			json_arr(w)
			json_str(w, "users")
			json_str(w, "roles")
			json_str(w, "everyone")
			json_arr_end(w)
			json_kbool(w, "replied_user", false)
			json_obj_end(w)
		}
	}
	json_kint(w, "flags", i64(opts.flags))
	if len(opts.sticker_ids) > 0 {
		json_key(w, "sticker_ids")
		json_arr(w)
		for s in opts.sticker_ids do json_snowflake(w, s)
		json_arr_end(w)
	}
}

// message_send_body: the exact POST /messages body (JSON.stringify order).
message_send_body :: proc(channel_id: Snowflake, content: string, nonce: Snowflake, opts: Send_Options, attachments_json := "", allocator := context.temp_allocator) -> string {
	w: Json
	json_init(&w, allocator)
	write_message_body_prefix(&w, channel_id, content, nonce, opts)
	if attachments_json != "" {
		json_key(&w, "attachments")
		json_raw(&w, attachments_json)
	}
	json_obj_end(&w)
	return json_string(&w)
}

// send_message inserts an optimistic pending message (replaced by the
// MESSAGE_CREATE / response with the same nonce) and queues the POST.
send_message :: proc(c: ^Client, channel_id: Snowflake, content: string, opts := Send_Options{}) -> (nonce: Snowflake) {
	nonce = nonce_next(&c.id.nonces)
	s := &c.store
	msg := new_message(s)
	msg.id = nonce
	msg.channel_id = channel_id
	msg.author_id = s.me
	msg.content = clone_str(content, s.allocator)
	msg.nonce = clone_str(snowflake_string(nonce), s.allocator)
	msg.referenced_id = opts.reply_to
	msg.pending = true
	msg.kind = 19 if opts.reply_to != 0 else 0
	insert_message(message_list(s, channel_id), msg)
	s.changed += 1
	typing_local_stop(c, channel_id)

	location := opts.location if opts.location != "" else "chat_input"
	if len(opts.attachments) > 0 {
		j := job_new(.Upload, .Upload)
		a := job_alloc(j)
		j.path = job_str(j, channel_path(channel_id, "/messages"))
		j.context_b64 = job_str(j, context_location(location))
		atts := make([]Draft_Attachment, len(opts.attachments), a)
		for d, i in opts.attachments {
			atts[i] = Draft_Attachment{d.handle, strings.clone(d.filename, a), strings.clone(d.description, a), d.spoiler}
		}
		j.drafts = atts
		o2 := opts
		o2.files = nil
		o2.attachments = nil
		o2.sticker_ids = slice.clone(opts.sticker_ids, a)
		j.result = Rest_Result{op = .Upload, channel_id = channel_id, nonce = nonce, tag = opts.tag}
		store_upload_ctx(j, channel_id, content, nonce, o2)
		job_submit(c, j)
		c.analytics.roundtrips[nonce] = Roundtrip{channel_id = channel_id, start = now_ms(), attachments = len(atts)}
		return
	}
	if len(opts.files) > 0 {
		j := job_new(.Upload, .Upload)
		a := job_alloc(j)
		j.path = job_str(j, channel_path(channel_id, "/messages"))
		j.context_b64 = job_str(j, context_location(location))
		files := make([]Upload_File, len(opts.files), a)
		for f, i in opts.files {
			files[i] = Upload_File{strings.clone(f.filename, a), strings.clone(f.mime, a), slice.clone(f.data, a)}
		}
		j.files = files
		o2 := opts
		o2.files = nil
		o2.sticker_ids = slice.clone(opts.sticker_ids, a)
		j.body = slice.clone(transmute([]byte)message_send_body(channel_id, content, nonce, o2, "", a), a)
		j.result = Rest_Result{op = .Upload, channel_id = channel_id, nonce = nonce, tag = opts.tag}
		store_upload_ctx(j, channel_id, content, nonce, o2)
		job_submit(c, j)
		return
	}
	j := job_new(.Api, .Send_Message)
	j.method = "POST"
	j.path = job_str(j, channel_path(channel_id, "/messages"))
	j.body = transmute([]byte)job_str(j, message_send_body(channel_id, content, nonce, opts))
	j.content_type = "application/json"
	j.context_b64 = job_str(j, context_location(location))
	j.retries = 3 // N.ZG: {timeout: 60 s, retries: 3, backoff}
	j.retry_429 = 3 // MessageQueue re-sends after Retry-After
	j.result = Rest_Result{op = .Send_Message, channel_id = channel_id, nonce = nonce, tag = opts.tag}
	job_submit(c, j)
	c.analytics.roundtrips[nonce] = Roundtrip{channel_id = channel_id, start = now_ms()}
	return
}

@(private)
Upload_Ctx :: struct {
	channel_id: Snowflake,
	content:    string,
	nonce:      Snowflake,
	opts:       Send_Options,
}

@(private)
store_upload_ctx :: proc(j: ^Job, channel_id: Snowflake, content: string, nonce: Snowflake, opts: Send_Options) {
	a := job_alloc(j)
	ctx := new(Upload_Ctx, a)
	ctx^ = Upload_Ctx{channel_id, strings.clone(content, a), nonce, opts}
	j.upload_ctx = ctx
	j.message_json = proc(j: ^Job, attachments_json: string) -> []byte {
		u := cast(^Upload_Ctx)j.upload_ctx
		return transmute([]byte)message_send_body(u.channel_id, u.content, u.nonce, u.opts, attachments_json)
	}
}

// edit_message: PATCH {content} (retries 1).
edit_message :: proc(c: ^Client, channel_id, message_id: Snowflake, content: string) {
	w: Json
	json_init(&w)
	json_obj(&w)
	json_kstr(&w, "content", content)
	json_obj_end(&w)
	j := job_new(.Api, .Edit_Message)
	j.method = "PATCH"
	j.path = job_str(j, channel_path(channel_id, "/messages/", snowflake_string(message_id)))
	j.body = transmute([]byte)job_str(j, json_string(&w))
	j.content_type = "application/json"
	j.retries = 1
	j.result = Rest_Result{op = .Edit_Message, channel_id = channel_id, message_id = message_id}
	job_submit(c, j)
}

// delete_message: DELETE (no retries).
delete_message :: proc(c: ^Client, channel_id, message_id: Snowflake) {
	j := job_new(.Api, .Delete_Message)
	j.method = "DELETE"
	j.path = job_str(j, channel_path(channel_id, "/messages/", snowflake_string(message_id)))
	j.result = Rest_Result{op = .Delete_Message, channel_id = channel_id, message_id = message_id}
	job_submit(c, j)
}

// emoji_route: "name" for unicode, "name:id" for custom, URI-encoded like Rsh's wrapper.
emoji_route :: proc(name: string, id: Snowflake) -> string {
	if id == 0 do return uri_component(name)
	return uri_component(strings.concatenate({name, ":", snowflake_string(id)}, context.temp_allocator))
}

// add_reaction: PUT /channels/{c}/messages/{m}/reactions/{emoji}/%40me?location=..&type=0|1
add_reaction :: proc(c: ^Client, channel_id, message_id: Snowflake, emoji_name: string, emoji_id: Snowflake = 0, burst := false, location := "Message") {
	q: Query
	query_init(&q, channel_path(channel_id, "/messages/", snowflake_string(message_id), "/reactions/", emoji_route(emoji_name, emoji_id), "/%40me"))
	query_add(&q, "location", location)
	query_add_int(&q, "type", 1 if burst else 0)
	j := job_new(.Api, .Add_Reaction)
	j.method = "PUT"
	j.path = job_str(j, query_string(&q))
	j.retry_429 = 1 // retried once after Retry-After
	j.result = Rest_Result{op = .Add_Reaction, channel_id = channel_id, message_id = message_id}
	job_submit(c, j)
}

// remove_reaction: DELETE .../reactions/{emoji}/{type}/%40me?location=..&burst=
remove_reaction :: proc(c: ^Client, channel_id, message_id: Snowflake, emoji_name: string, emoji_id: Snowflake = 0, burst := false, location := "Message") {
	q: Query
	query_init(&q, channel_path(channel_id, "/messages/", snowflake_string(message_id), "/reactions/", emoji_route(emoji_name, emoji_id), "/", "1" if burst else "0", "/%40me"))
	query_add(&q, "location", location)
	query_add_bool(&q, "burst", burst)
	j := job_new(.Api, .Remove_Reaction)
	j.method = "DELETE"
	j.path = job_str(j, query_string(&q))
	j.retry_429 = 1
	j.result = Rest_Result{op = .Remove_Reaction, channel_id = channel_id, message_id = message_id}
	job_submit(c, j)
}

// ---- typing (TypingStore TYPING_START_LOCAL) ----

TYPING_SEND_DELAY_MS :: 1500
TYPING_RESEND_MS :: 8000 // 0.8 * 10 s

Typing_Local :: struct {
	channel_id: Snowflake,
	fire_at:    i64, // 0 = no timer pending
	prev_send:  i64,
	active:     bool,
}

// typing_keystroke: call on each input change; sends POST /typing like the client
// (1.5 s debounce when it typed recently, at most every 8 s).
typing_keystroke :: proc(c: ^Client, channel_id: Snowflake) {
	t := &c.typing_local
	now := now_ms()
	if t.active && t.channel_id != channel_id do t^ = {}
	if t.active && (t.fire_at != 0 || t.prev_send + TYPING_RESEND_MS > now) do return
	delay: i64 = TYPING_SEND_DELAY_MS if (!t.active || t.prev_send > now - 2 * TYPING_RESEND_MS) else 0
	t^ = {channel_id = channel_id, fire_at = now + delay, prev_send = now, active = true}
}

typing_local_stop :: proc(c: ^Client, channel_id: Snowflake) {
	t := &c.typing_local
	if t.active && t.channel_id == channel_id && t.fire_at != 0 do t^ = {}
}

@(private)
flush_typing_local :: proc(c: ^Client, now: i64) {
	t := &c.typing_local
	if !t.active || t.fire_at == 0 || now < t.fire_at do return
	t.fire_at = 0
	send_typing(c, t.channel_id)
}

// send_typing: POST /channels/{id}/typing (empty body).
send_typing :: proc(c: ^Client, channel_id: Snowflake) {
	j := job_new(.Api, .Typing)
	j.method = "POST"
	j.path = job_str(j, channel_path(channel_id, "/typing"))
	j.result = Rest_Result{op = .Typing, channel_id = channel_id}
	job_submit(c, j)
}

// ---- acks (ReadStateStore) ----

ACK_DELAY_MS :: 3000

Pending_Ack :: struct {
	channel_id: Snowflake,
	message_id: Snowflake,
	due:        i64,
	location:   Ack_Location,
}

// Ack_Location: where an ack came from, as ack_messages reports it ({} = no event).
Ack_Location :: struct {
	section:     string,
	object:      string,
	object_type: string, // "ack_automatic" / "ack_semi_automatic" / "ack_manual"
}

// the Inbox's per-channel "Mark As Read" (fixture inbox, inbox_unreads_mark_read)
ACK_INBOX :: Ack_Location{"Inbox", "Ack - Inbox Newest Unread Message", "ack_automatic"}

// ack_message schedules the read-state ack like ReadState.ack(): sent after 3 s
// (immediately when `immediate`), body {token, last_viewed[, flags]}.
// location: reported in ack_messages when the ack completes ({}: none).
ack_message :: proc(c: ^Client, channel_id, message_id: Snowflake, immediate := false, location := Ack_Location{}) {
	due := now_ms() + (0 if immediate else ACK_DELAY_MS)
	for &p in c.pending_acks {
		if p.channel_id == channel_id {
			p.message_id = max(p.message_id, message_id)
			if immediate do p.due = due
			if location.section != "" do p.location = location
			return
		}
	}
	append(&c.pending_acks, Pending_Ack{channel_id, message_id, due, location})
	rs := c.store.read_states[channel_id]
	rs.channel_id = channel_id
	rs.last_message_id = max(rs.last_message_id, message_id)
	rs.mention_count = 0
	c.store.read_states[channel_id] = rs
}

@(private)
flush_due_acks :: proc(c: ^Client, now: i64) {
	for i := len(c.pending_acks) - 1; i >= 0; i -= 1 {
		p := c.pending_acks[i]
		if p.due > now do continue
		ordered_remove(&c.pending_acks, i)
		send_ack(c, p.channel_id, p.message_id, now, p.location)
	}
}

@(private)
send_ack :: proc(c: ^Client, channel_id, message_id: Snowflake, now: i64, location := Ack_Location{}) {
	ch := c.store.channels[channel_id]
	rs := c.store.read_states[channel_id]
	// recalculateFlags: 2 thread, 1 guild channel, 0 private; sent only when it changed.
	flags: u64 = 0
	if ch.kind == .Public_Thread || ch.kind == .Private_Thread || ch.kind == .Announcement_Thread {
		flags = 2
	} else if ch.guild_id != 0 {
		flags = 1
	}
	w: Json
	json_init(&w)
	json_obj(&w)
	locks.lock(&c.ack_mu)
	if c.ack_token != "" do json_kstr(&w, "token", c.ack_token)
	else do json_knull(&w, "token")
	locks.unlock(&c.ack_mu)
	lv := rs.last_viewed if rs.last_viewed > 0 else days_since_epoch(now)
	json_kint(&w, "last_viewed", i64(lv))
	if flags != rs.flags {
		json_kint(&w, "flags", i64(flags))
		rs.flags = flags
		c.store.read_states[channel_id] = rs
	}
	json_obj_end(&w)
	j := job_new(.Api, .Ack)
	j.method = "POST"
	j.path = job_str(j, channel_path(channel_id, "/messages/", snowflake_string(message_id), "/ack"))
	j.body = transmute([]byte)job_str(j, json_string(&w))
	j.content_type = "application/json"
	j.result = Rest_Result{op = .Ack, channel_id = channel_id, message_id = message_id}
	if location.section != "" {
		// the read states are already moved: the statuses are those after the ack
		j.track_props = job_str(j, analytics_ack_props(c, channel_id, location))
		j.on_done = analytics_ack_done
	}
	job_submit(c, j)
}

// ---- DMs ----

// open_dm returns the existing DM channel if cached (no request, like
// _openCachedDMChannel), else POST /users/@me/channels {recipients:[id]}.
open_dm :: proc(c: ^Client, user_id: Snowflake, location := "Profile", tag: u64 = 0) -> (existing: Snowflake) {
	for cid in c.store.private_channels {
		ch := c.store.channels[cid]
		if ch.kind == .DM && len(ch.recipient_ids) == 1 && ch.recipient_ids[0] == user_id do return cid
	}
	ids := [1]Snowflake{user_id}
	create_private_channel(c, ids[:], location, tag)
	return 0
}

// create_private_channel: group DM (or DM) creation.
create_private_channel :: proc(c: ^Client, user_ids: []Snowflake, location := "Profile", tag: u64 = 0) {
	w: Json
	json_init(&w)
	json_obj(&w)
	json_key(&w, "recipients")
	json_arr(&w)
	for u in user_ids do json_snowflake(&w, u)
	json_arr_end(&w)
	json_obj_end(&w)
	j := job_new(.Api, .Open_Dm)
	j.method = "POST"
	j.path = "/users/@me/channels"
	j.body = transmute([]byte)job_str(j, json_string(&w))
	j.content_type = "application/json"
	j.context_b64 = job_str(j, context_location(location))
	j.retries = 3
	j.result = Rest_Result{op = .Open_Dm, tag = tag, user_id = user_ids[0] if len(user_ids) > 0 else 0}
	job_submit(c, j)
}

// ---- relationships ----

// send_friend_request (Add Friend by username): POST /users/@me/relationships
// {"username":..,"discriminator":null} (parseInt(undefined) is NaN -> null).
send_friend_request :: proc(c: ^Client, username: string, location := "Add Friend") {
	w: Json
	json_init(&w)
	json_obj(&w)
	name := username
	disc := ""
	if h := strings.index_byte(username, '#'); h >= 0 {
		name = username[:h]
		disc = username[h + 1:]
	}
	json_kstr(&w, "username", name)
	if disc != "" {
		json_key(&w, "discriminator")
		json_raw(&w, disc)
	} else {
		json_knull(&w, "discriminator")
	}
	json_obj_end(&w)
	j := job_new(.Api, .Relationship)
	j.method = "POST"
	j.path = "/users/@me/relationships"
	j.body = transmute([]byte)job_str(j, json_string(&w))
	j.content_type = "application/json"
	j.context_b64 = job_str(j, context_location(location))
	job_submit(c, j)
}

// add_relationship: PUT /users/@me/relationships/{id} {} — accept a request,
// or send one from a profile.
add_relationship :: proc(c: ^Client, user_id: Snowflake, location := "Friends") {
	j := job_new(.Api, .Relationship)
	j.method = "PUT"
	j.path = job_str(j, strings.concatenate({"/users/@me/relationships/", snowflake_string(user_id)}, context.temp_allocator))
	j.body = transmute([]byte)job_str(j, "{}")
	j.content_type = "application/json"
	j.context_b64 = job_str(j, context_location(location))
	j.result.user_id = user_id
	job_submit(c, j)
}

// accept_friend_request: Friends > Pending > Accept. A mutual-guild request
// needs no stranger confirmation: {"confirm_stranger_request":false}
// (fixtures friend_request_accept, friend_add_context_menu).
accept_friend_request :: proc(c: ^Client, user_id: Snowflake) {
	j := job_new(.Api, .Relationship)
	j.method = "PUT"
	j.path = job_str(j, strings.concatenate({"/users/@me/relationships/", snowflake_string(user_id)}, context.temp_allocator))
	j.body = transmute([]byte)job_str(j, `{"confirm_stranger_request":false}`)
	j.content_type = "application/json"
	j.context_b64 = job_str(j, context_location("Friends"))
	j.result.user_id = user_id
	job_submit(c, j)
}

// remove_relationship: DELETE — ignore/cancel a request, unfriend, unblock.
remove_relationship :: proc(c: ^Client, user_id: Snowflake, location := "Friends") {
	j := job_new(.Api, .Relationship)
	j.method = "DELETE"
	j.path = job_str(j, strings.concatenate({"/users/@me/relationships/", snowflake_string(user_id)}, context.temp_allocator))
	j.context_b64 = job_str(j, context_location(location))
	j.result.user_id = user_id
	job_submit(c, j)
}

ignore_friend_request :: proc(c: ^Client, user_id: Snowflake) {remove_relationship(c, user_id, "Friends")}

// ---- profiles ----

// fetch_profile: GET /users/{id}/profile?type=popout&with_mutual_guilds=true&with_mutual_friends=true&with_mutual_friends_count=false[&guild_id=]
fetch_profile :: proc(c: ^Client, user_id: Snowflake, guild_id: Snowflake = 0, tag: u64 = 0) {
	q: Query
	query_init(&q, strings.concatenate({"/users/", snowflake_string(user_id), "/profile"}, context.temp_allocator))
	query_add(&q, "type", "popout")
	query_add_bool(&q, "with_mutual_guilds", true)
	query_add_bool(&q, "with_mutual_friends", true)
	query_add_bool(&q, "with_mutual_friends_count", false)
	if guild_id != 0 do query_add_snow(&q, "guild_id", guild_id)
	j := job_new(.Api, .Fetch_Profile)
	j.method = "GET"
	j.path = job_str(j, query_string(&q))
	j.result = Rest_Result{op = .Fetch_Profile, user_id = user_id, tag = tag}
	job_submit(c, j)
}

// ---- dispatch side effects (UI thread) ----

// client_after_dispatch: requests the official client makes in response to
// events (e.g. op 8 for unknown message authors in a subscribed guild).
client_after_dispatch :: proc(c: ^Client, name: string, data: V) {
	calls_dispatch(c, name, data)
	switch name {
	case "READY":
		first := analytics_on_ready(c)
		note_webp_experiment(c, data)
		c.account_verified = fbool(fmap(vmap(data), "user"), "verified")
		// The window reopens on its last route: the guild is subscribed and its
		// channel info requested on CONNECTION_OPEN, as when it was selected.
		locks.lock(&c.route_mu)
		g, ch := c.route_guild, c.route_channel
		locks.unlock(&c.route_mu)
		// the route's views render on CONNECTION_OPEN: channel_opened, guild_viewed
		// (fixtures' setup windows, right after ready_payload_received)
		if first && ch != 0 do analytics_channel_opened(c, g, ch)
		if first && g != 0 do analytics_guild_viewed(c, g, ch)
		if first && g == 0 && ch == 0 do friends_page_viewed(c) // fixture cold_start
		if ch != 0 {
			l := message_list(&c.store, ch)
			h := c.analytics.viewport_h if c.analytics.viewport_h > 0 else 720
			if !l.loaded && !l.loading do fetch_messages(c, ch, 0, initial_message_limit(h))
		}
		if g != 0 {
			locks.lock(&c.job_mu)
			already := c.ready_subscribed_guild == g
			locks.unlock(&c.job_mu)
			if already do c.subs.guilds[g] = true
			else do subscribe_guild(c, g)
			c.pending_guild_open = g
			c.guild_open_promotions = true
		}
	case "GUILD_DELETE":
		// left (or removed): a rejoin subscribes again and refetches
		d := vmap(data)
		if !fbool(d, "unavailable") {
			gid := fsnow(d, "id")
			delete_key(&c.subs.guilds, gid)
			c.left_guilds[gid] = true // a rejoin sends op 43 again, but not the guild-open set
			locks.lock(&c.job_mu)
			if c.ready_subscribed_guild == gid do c.ready_subscribed_guild = 0
			locks.unlock(&c.job_mu)
		}
	case "GUILD_CREATE":
		if joined_guild_created(c, vmap(data)) do break
		if c.pending_guild_create {
			c.pending_guild_create = false
			d := vmap(data)
			gid := fsnow(d, "id")
			g := guild_get(&c.store, gid)
			ch: Snowflake = 0
			if g != nil {
				ch = g.system_channel_id
				if ch == 0 {
					for cid in guild_channels_sorted(&c.store, gid) {
						if c.store.channels[cid].kind == .Guild_Text {
							ch = cid
							break
						}
					}
				}
			}
			guild_created_followups(c, gid)
			h := c.analytics.viewport_h if c.analytics.viewport_h > 0 else 720
			// the new guild renders at once: op 43 and its guild-open set go out with the
			// page fetch, the subscription right after (fixture create_guild)
			select_channel(c, gid, ch, initial_message_limit(h), prefetch = true)
			if c.pending_guild_open == gid do guild_open_now(c, gid)
		}
	case "MESSAGE_ACK":
		d := vmap(data)
		analytics_notifications_acked(c, fsnow(d, "channel_id"), fsnow(d, "message_id"))
	case "MESSAGE_CREATE":
		analytics_note_message(c, data)
		d := vmap(data)
		if nv := fstr(d, "nonce"); nv != "" {
			if rt, ok := &c.analytics.roundtrips[parse_snowflake(nv)]; ok && rt.gateway == 0 do rt.gateway = now_ms()
		}
		gid := fsnow(d, "guild_id")
		locks.lock(&c.route_mu)
		viewing := c.route_channel == fsnow(d, "channel_id")
		locks.unlock(&c.route_mu)
		if viewing && c.focused {
			aid := fsnow(fmap(d, "author"), "id")
			if aid != c.store.me do ack_message(c, fsnow(d, "channel_id"), fsnow(d, "id"))
		}
		_ = gid
	}
}

// ---- voice hand-off (src/voice) ----

// Voice_Server_Info is everything voice.voice_connect needs, assembled from
// our VOICE_STATE_UPDATE (session_id, channel) and VOICE_SERVER_UPDATE
// (endpoint, token, guild or private channel id).
Voice_Server_Info :: struct {
	endpoint:            string, // host[:port] without scheme, as sent by Discord
	token:               string,
	guild_or_channel_id: Snowflake, // server_id: guild id, or the DM/group channel for calls
	user_id:             Snowflake,
	session_id:          string,
	channel_id:          Snowflake,
}

// voice_server_info returns the current voice connection parameters once both
// events for our session arrived (strings point into the store: copy them if
// they must outlive the next client_poll). `version` changes on every
// VOICE_SERVER_UPDATE so the app can reconnect when the server moves.
voice_server_info :: proc(c: ^Client) -> (info: Voice_Server_Info, version: u64, ok: bool) {
	s := &c.store
	vs, have := s.voice_states[s.me]
	if !have || s.voice_server.token == "" || s.voice_server.endpoint == "" do return {}, 0, false
	server := s.voice_server.guild_id if s.voice_server.guild_id != 0 else s.voice_server.channel_id
	if server != (vs.guild_id if vs.guild_id != 0 else vs.channel_id) do return {}, 0, false
	return Voice_Server_Info{
		endpoint = s.voice_server.endpoint,
		token = s.voice_server.token,
		guild_or_channel_id = server,
		user_id = s.me,
		session_id = vs.session_id,
		channel_id = vs.channel_id,
	}, s.voice_server.version, true
}

// voice_join: op 4 (flags 2) plus what selecting a voice channel loads: its
// text-in-voice page, the activity shelf (~155 ms), soundboard sounds with
// op 31 for every guild (~700 ms, once per session).
// track = false: the caller sends join_voice_channel itself, after its own events (DM calls).
voice_join :: proc(c: ^Client, guild_id, channel_id: Snowflake, self_mute := false, self_deaf := false, track := true) {
	voice_update(c, guild_id, channel_id, self_mute, self_deaf)
	// the voice channel's text view opens with the call
	analytics_channel_opened(c, guild_id, channel_id, selected_guild = false)
	if track do analytics_join_voice(c, guild_id, channel_id)
	l := message_list(&c.store, channel_id)
	h := c.analytics.viewport_h if c.analytics.viewport_h > 0 else 720
	if !l.loaded && !l.loading do fetch_messages(c, channel_id, 0, initial_message_limit(h))
	if guild_id != 0 {
		j := job_new(.Api, .None)
		j.method = "GET"
		j.path = job_str(j, strings.concatenate({"/activities/shelf?guild_id=", snowflake_string(guild_id)}, context.temp_allocator))
		j.not_before = now_ms() + 155
		j.on_done = analytics_shelf_fetched
		job_submit(c, j)
	}
	if !c.soundboard_loaded {
		c.soundboard_loaded = true
		c.pending_soundboard_at = now_ms() + 705
		api_get_later(c, "/soundboard-default-sounds", 705)
	}
}

// flush_soundboard: op 31 REQUEST_SOUNDBOARD_SOUNDS for all guilds (READY order).
@(private)
flush_soundboard :: proc(c: ^Client, now: i64) {
	if c.pending_soundboard_at == 0 || now < c.pending_soundboard_at do return
	c.pending_soundboard_at = 0
	if c.gw == nil do return
	ids := make([]V, len(c.store.guild_order), context.temp_allocator)
	for g, i in c.store.guild_order do ids[i] = snowflake_string(g)
	b := etf.map_builder(1, context.temp_allocator)
	etf.map_put(&b, "guild_ids", etf.List(ids))
	gateway_send(c.gw, .Request_Soundboard_Sounds, etf.map_done(&b))
}

voice_leave :: proc(c: ^Client) {
	voice_update(c, 0, 0, c.cfg.voice_self_mute, false)
}

// guild_channel_info: op 43 sent when a guild's channel is shown.
guild_channel_info :: proc(c: ^Client, guild_id: Snowflake) {
	if c.gw == nil do return
	b := etf.map_builder(2, context.temp_allocator)
	etf.map_put(&b, "guild_id", snowflake_string(guild_id))
	etf.map_put(&b, "fields", etf.List{string("status"), string("voice_start_time")})
	gateway_send(c.gw, .Request_Channel_Info, etf.map_done(&b))
}

// guild_open_now: op 43 and the guild-open set for the guild entered first in
// the session. Re-entering a guild sends neither (fixtures history_nav: Friends
// -> back to the guild; discover: discovery -> the guild).
guild_open_now :: proc(c: ^Client, g: Snowflake) {
	c.pending_guild_open = 0
	if !c.started_guilds[g] {
		c.started_guilds[g] = true
		guild_channel_info(c, g)
		schedule_guild_open(c, g, c.guild_open_promotions)
	} else if c.left_guilds[g] {
		// rejoined after leaving (fixture join_leave_server): op 43 only
		delete_key(&c.left_guilds, g)
		guild_channel_info(c, g)
	}
	c.guild_open_promotions = false
}

// guild_channel_notice_check: a guild text channel route rendering, for a member
// who can manage the guild, when the guild has no system channel, loads the
// guild's integrations (every such render: fixtures history_nav, discover,
// threads_browser, settings, streamer_mode; never with a system channel set).
guild_channel_notice_check :: proc(c: ^Client, ch: ^Channel) {
	if ch.guild_id == 0 || is_thread(ch) || (ch.kind != .Guild_Text && ch.kind != .Guild_Announcement) do return
	g := guild_get(&c.store, ch.guild_id)
	if g == nil || g.system_channel_id != 0 || guild_permissions(&c.store, g.id) & PERM_MANAGE_GUILD == 0 do return
	api_get_later(c, strings.concatenate({"/guilds/", snowflake_string(g.id), "/integrations?include_applications=true&include_role_connections_metadata=true"}, context.temp_allocator), 0)
}

// on_channel_page runs when the first page of a selected channel arrives
// (or immediately when cached): the follow-ups the official client issues
// once the channel renders.
on_channel_page :: proc(c: ^Client, channel_id: Snowflake, got: int, full: bool) {
	ch := c.store.channels[channel_id]
	if g := c.pending_guild_open; g != 0 && (ch.guild_id == g || ch.guild_id == 0) do guild_open_now(c, g)
	locks.lock(&c.route_mu)
	on_route := c.route_channel == channel_id
	locks.unlock(&c.route_mu)
	if on_route do guild_channel_notice_check(c, &ch)
	if full {
		// Fill the viewport: one older page of 20.
		msgs := messages_get(&c.store, channel_id)
		if len(msgs) > 0 do fetch_messages(c, channel_id, msgs[0].id, 20)
	}
	if pc := c.pending_private_open; pc != 0 && pc == channel_id {
		c.pending_private_open = 0
		if c.gw != nil {
			cb := etf.map_builder(1, context.temp_allocator)
			etf.map_put(&cb, "channel_id", snowflake_string(channel_id))
			gateway_send(c.gw, .Call_Connect, etf.map_done(&cb))
		}
		if ch.kind == .DM && len(ch.recipient_ids) == 1 {
			u := ch.recipient_ids[0]
			// the profile sidebar renders with the third (sidebar) profile response
			profile_view_begin(c, .Sidebar, u, 0, channel_id, 0, wait = 3)
			fetch_profile_ex(c, u, {mutual_guilds = false, mutual_friends = false, mutual_friends_count = false})
			fetch_profile_ex(c, u, {mutual_guilds = true, mutual_friends = false, mutual_friends_count = false, delay_ms = 223})
			fetch_note(c, u, 223)
			fetch_profile_ex(c, u, {kind = "sidebar", mutual_guilds = true, mutual_friends = true, mutual_friends_count = false, delay_ms = 476})
		}
	}
	// Viewing a channel with unread messages acks it (ReadState, 3 s timer),
	// only while the window has focus (fixtures, unfocused: mark_as_read sends no ack).
	if channel_unread(&c.store, channel_id) && identity_app_state(&c.id) == .Focused {
		msgs := messages_get(&c.store, channel_id)
		if len(msgs) > 0 do ack_message(c, channel_id, msgs[len(msgs) - 1].id)
	}
}

Profile_Options :: struct {
	kind:                 string, // "" (DM header), "popout", "sidebar", "modal"
	mutual_guilds:        bool,
	mutual_friends:       bool,
	mutual_friends_count: bool,
	guild_id:             Snowflake,
	delay_ms:             i64,
}

// fetch_profile_ex: GET /users/{id}/profile?[type=]&with_mutual_guilds=&with_mutual_friends=&with_mutual_friends_count=[&guild_id=]
fetch_profile_ex :: proc(c: ^Client, user_id: Snowflake, o: Profile_Options, tag: u64 = 0) {
	q: Query
	query_init(&q, strings.concatenate({"/users/", snowflake_string(user_id), "/profile"}, context.temp_allocator))
	if o.kind != "" do query_add(&q, "type", o.kind)
	query_add_bool(&q, "with_mutual_guilds", o.mutual_guilds)
	query_add_bool(&q, "with_mutual_friends", o.mutual_friends)
	query_add_bool(&q, "with_mutual_friends_count", o.mutual_friends_count)
	if o.guild_id != 0 do query_add_snow(&q, "guild_id", o.guild_id)
	j := job_new(.Api, .Fetch_Profile)
	j.method = "GET"
	j.path = job_str(j, query_string(&q))
	j.not_before = now_ms() + o.delay_ms
	j.result = Rest_Result{op = .Fetch_Profile, user_id = user_id, tag = tag}
	job_submit(c, j)
}

// fetch_note: GET /users/@me/notes/{id} (profile popouts/sidebars).
fetch_note :: proc(c: ^Client, user_id: Snowflake, delay_ms: i64 = 0) {
	j := job_new(.Api, .None)
	j.method = "GET"
	j.path = job_str(j, strings.concatenate({"/users/@me/notes/", snowflake_string(user_id)}, context.temp_allocator))
	j.not_before = now_ms() + delay_ms
	job_submit(c, j)
}

// open_profile_popout: what clicking a username does: profile, application
// identities and featured widgets at once, referral eligibility ~460 ms and
// the note ~720 ms later (fixture open_profile_popout).
// channel_id / message_id: where the username was clicked (telemetry).
open_profile_popout :: proc(c: ^Client, user_id, guild_id: Snowflake, channel_id: Snowflake = 0, message_id: Snowflake = 0) {
	profile_view_begin(c, .Popout, user_id, guild_id, channel_id, message_id)
	fetch_profile_ex(c, user_id, {kind = "popout", guild_id = guild_id})
	api_get_later(c, strings.concatenate({"/users/", snowflake_string(user_id), "/application-identities?with_profiles=true"}, context.temp_allocator), 0)
	api_get_later(c, "/widget-configs/featured", 0)
	api_get_later(c, "/users/@me/referrals/eligibility", 463)
	fetch_note(c, user_id, 723)
}

// open_user_settings: requests the settings modal makes when it opens.
open_user_settings :: proc(c: ^Client) {
	j := job_new(.Web, .None)
	j.method = "GET"
	j.host = API_HOST
	j.path = "/__development/build_overrides"
	j.site = .Same_Origin
	job_submit(c, j)
	api_get_later(c, "/users/@me/billing/payment-sources", 0)
	api_get_later(c, "/users/@me/billing/location-info", 0)
	api_get_later(c, "/auth/sessions", 0)
	api_get_later(c, "/safety-hub/@me", 0)
	// no custom-themes: that is the Appearance pane's load (settings_pane_shown);
	// fixtures settings, streamer_mode, account_edits open without it
}

// api_get_later: a plain authenticated GET (fire and forget).
api_get_later :: proc(c: ^Client, path: string, delay_ms: i64) {
	j := job_new(.Api, .None)
	j.method = "GET"
	j.path = job_str(j, path)
	j.not_before = now_ms() + delay_ms
	job_submit(c, j)
}

// open_full_profile: "View Full Profile" from a popout (fixture open_full_profile).
// The applications/public, games and oauth2/tokens follow-ups depend on the
// profile's widget/app data and are not issued (see traffic/PARITY.md).
// via: the popout element clicked to open it ("avatar"), "" when not from a popout.
open_full_profile :: proc(c: ^Client, user_id, guild_id: Snowflake, via := "avatar") {
	us := snowflake_string(user_id)
	v := &c.analytics.profile
	if via != "" && v.layout == .Popout && v.user_id == user_id && v.session != "" && profile_shows_nothing_extra(c, user_id, v.guild_id) {
		profile_action(c, v, {"username", "user profile popout", via}, "PRESS_VIEW_PROFILE")
	}
	profile_view_begin(c, .Modal, user_id, guild_id, v.channel_id if v.user_id == user_id else 0, v.message_id if v.user_id == user_id else 0)
	api_get_later(c, strings.concatenate({"/content-inventory/users/", us, "/outbox"}, context.temp_allocator), 0)
	fetch_profile_ex(c, user_id, {kind = "modal", mutual_guilds = true, mutual_friends_count = true, guild_id = guild_id})
	api_get_later(c, "/collectibles-categories/v2?include_bundles=true&variants_return_style=2&skip_num_categories=0", 100)
	api_get_later(c, "/users/@me/collectibles-purchases?variants_return_style=2", 100)
	api_get_later(c, "/users/@me/activities/statistics/applications", 100)
	api_get_later(c, "/users/@me/widgets/suggested-games", 100)
	api_get_later(c, strings.concatenate({"/users/", us, "/application-identities?with_profiles=true"}, context.temp_allocator), 100)
}

// open_message_context_menu: right-clicking a message loads the application
// command indexes (guild once per guild, user once per session).
open_message_context_menu :: proc(c: ^Client, guild_id: Snowflake) {
	if guild_id != 0 && !c.command_index_guilds[guild_id] {
		c.command_index_guilds[guild_id] = true
		j := job_new(.Api, .None)
		j.method = "GET"
		j.path = job_str(j, strings.concatenate({"/guilds/", snowflake_string(guild_id), "/application-command-index"}, context.temp_allocator))
		j.on_done = analytics_command_index_loaded
		job_submit(c, j)
	}
	if !c.command_index_user {
		c.command_index_user = true
		j := job_new(.Api, .None)
		j.method = "GET"
		j.path = "/users/@me/application-command-index"
		j.on_done = analytics_command_index_loaded
		job_submit(c, j)
	}
}

// open_emoji_picker: the reaction/emoji picker's first open in a session.
open_emoji_picker :: proc(c: ^Client, guild_id: Snowflake) {
	if c.emoji_picker_opened do return
	c.emoji_picker_opened = true
	if guild_id != 0 {
		j := job_new(.Api, .None)
		j.method = "GET"
		j.path = job_str(j, strings.concatenate({"/guilds/", snowflake_string(guild_id), "/top-emojis"}, context.temp_allocator))
		job_submit(c, j)
	}
	b := job_new(.Api, .None)
	b.method = "GET"
	b.path = "/users/@me/billing/subscriptions?sync_level=2"
	job_submit(c, b)
	fetch_profile_ex(c, c.store.me, {})
}

// home_open: the friends/home surface's first render in a session (when the
// client did not start on it): referral eligibility, quest applications and
// the premium-guild entitlements, together (fixture open_dm, ~6.9 s). An
// unverified account loads user affinities instead of the entitlements
// (fixture join_leave_server, B after Leave Server).
// Every later open of Friends loads the premium-guild entitlements again
// (fixture history_nav: each forward to Friends).
home_open :: proc(c: ^Client) {
	if c.home_opened {
		api_get_later(c, "/users/@me/entitlements?with_sku=false&with_application=false&entitlement_type=11&exclude_ended=true", 0)
		return
	}
	c.home_opened = true
	if client_route_kind(c.start_route_guild, c.start_route_channel) == .Home do return // startup table covers it
	api_get_later(c, "/users/@me/referrals/eligibility", 0)
	if !c.account_verified do api_get_later(c, "/users/@me/affinities/v2/users", 0)
	locks.lock(&c.job_mu)
	ready := c.ready_ms
	locks.unlock(&c.job_mu)
	saved := c.start_route_guild
	c.start_route_guild = 0
	c.start_route_channel = 0
	schedule_applications_public(c, ready)
	c.start_route_guild = saved
	if c.account_verified do api_get_later(c, "/users/@me/entitlements?with_sku=false&with_application=false&entitlement_type=11&exclude_ended=true", 0)
}

// ---- guilds ----

// GUILD_TEMPLATE_FRIENDS: "Create My Own" -> "For me and my friends".
GUILD_TEMPLATE_FRIENDS :: "2TffvPucqHkN"

// create_guild: POST /guilds as the create-guild modal sends it
// ({name, icon, channels: [], system_channel_id, guild_template_code}); when
// GUILD_CREATE arrives the client navigates into it (select_channel) and loads
// the new-guild extras (guild_created_followups).
// step_shown_ms: when the modal's last step ("Customize your server") was shown (telemetry).
create_guild :: proc(c: ^Client, name: string, icon_data_uri := "", template := GUILD_TEMPLATE_FRIENDS, step_shown_ms: i64 = 0) {
	c.analytics.guild_create_step_ms = step_shown_ms
	w: Json
	json_init(&w)
	json_obj(&w)
	json_kstr(&w, "name", name)
	if icon_data_uri != "" do json_kstr(&w, "icon", icon_data_uri)
	else do json_knull(&w, "icon")
	json_key(&w, "channels")
	json_raw(&w, "[]")
	json_knull(&w, "system_channel_id")
	json_kstr(&w, "guild_template_code", template)
	json_obj_end(&w)
	j := job_new(.Api, .None)
	j.method = "POST"
	j.path = "/guilds"
	j.body = transmute([]byte)job_str(j, json_string(&w))
	j.content_type = "application/json"
	j.on_done = proc(c: ^Client, j: ^Job, status: int) {
		if status != 0 do analytics_guild_create_result(c, status, c.analytics.guild_create_step_ms)
	}
	job_submit(c, j)
	c.pending_guild_create = true
}

// guild_created_followups: requests seen right after creating a guild
// (boost/premium panels of the new guild): payment sources and
// subscriptions (twice, from two components), the server-shop listing ~310 ms
// and powerups ~650 ms later.
guild_created_followups :: proc(c: ^Client, guild_id: Snowflake) {
	gs := snowflake_string(guild_id)
	api_get_later(c, "/users/@me/billing/payment-sources", 0)
	api_get_later(c, "/users/@me/billing/subscriptions?sync_level=2", 0)
	api_get_later(c, "/users/@me/billing/payment-sources", 1)
	api_get_later(c, "/users/@me/billing/subscriptions?sync_level=2", 1)
	cc := c.store.country_code if c.store.country_code != "" else "US"
	api_get_later(c, strings.concatenate({"/store/published-listings/skus?country_code=", cc, "&application_id=1340102344645283891&guild_id=", gs}, context.temp_allocator), 313)
	api_get_later(c, strings.concatenate({"/guilds/", gs, "/integrations?include_applications=true&include_role_connections_metadata=true"}, context.temp_allocator), 649)
	api_get_later(c, strings.concatenate({"/guilds/", gs, "/powerups?country_code=", cc, "&include_ends_at=true"}, context.temp_allocator), 650)
}

// ---- group DMs ----

// create_group_dm: "New Group DM" with no one selected: POST /users/@me/channels
// {"recipients":[]} (location "New Group DM"); the new channel opens.
create_group_dm :: proc(c: ^Client, user_ids: []Snowflake = nil, tag: u64 = 0) {
	analytics_create_dm_clicked(c, user_ids)
	create_private_channel(c, user_ids, "New Group DM", tag)
}

// create_group_dm_invite: opening "Invite to Group DM" creates an invite link:
// POST /channels/{id}/invites {"max_age":86400} (location "Group DM Invite Create").
create_group_dm_invite :: proc(c: ^Client, channel_id: Snowflake) {
	j := job_new(.Api, .None)
	j.method = "POST"
	j.path = job_str(j, channel_path(channel_id, "/invites"))
	j.body = transmute([]byte)job_str(j, `{"max_age":86400}`)
	j.content_type = "application/json"
	j.context_b64 = job_str(j, context_location("Group DM Invite Create"))
	job_submit(c, j)
}

// add_group_recipient: PUT /channels/{id}/recipients/{user} (friends only).
add_group_recipient :: proc(c: ^Client, channel_id, user_id: Snowflake) {
	j := job_new(.Api, .None)
	j.method = "PUT"
	j.path = job_str(j, channel_path(channel_id, "/recipients/", snowflake_string(user_id)))
	job_submit(c, j)
}

remove_group_recipient :: proc(c: ^Client, channel_id, user_id: Snowflake) {
	j := job_new(.Api, .None)
	j.method = "DELETE"
	j.path = job_str(j, channel_path(channel_id, "/recipients/", snowflake_string(user_id)))
	job_submit(c, j)
}

// delete_guild: POST /guilds/{id}/delete {} (owner).
delete_guild :: proc(c: ^Client, guild_id: Snowflake) {
	j := job_new(.Api, .None)
	j.method = "POST"
	j.path = job_str(j, strings.concatenate({"/guilds/", snowflake_string(guild_id), "/delete"}, context.temp_allocator))
	j.body = transmute([]byte)job_str(j, "{}")
	j.content_type = "application/json"
	job_submit(c, j)
}


// open_account_popout: the account panel's popout (status / custom status).
// First open in a session: own profile (type=account_popout), application
// identities and the featured widget configs; when those arrive the popout
// loads activity statistics, the featured applications and /users/@me.
// Later opens only refresh /users/@me (fixtures status_change, custom_status).
open_account_popout :: proc(c: ^Client) {
	profile_view_begin(c, .Account_Popout, c.store.me, 0, 0, 0)
	if c.account_popout_opened {
		analytics_on_profile(c, c.store.me) // the profile is loaded: it shows at once
		users_me_refresh(c, 650)
		return
	}
	c.account_popout_opened = true
	fetch_profile_ex(c, c.store.me, {kind = "account_popout"})
	api_get_later(c, strings.concatenate({"/users/", snowflake_string(c.store.me), "/application-identities?with_profiles=true"}, context.temp_allocator), 0)
	j := job_new(.Api, .None)
	j.method = "GET"
	j.path = "/widget-configs/featured"
	j.on_body = proc(c: ^Client, body: V) {
		api_get_later(c, "/users/@me/activities/statistics/applications", 55)
		q: Query
		query_init(&q, "/applications/public")
		n := 0
		for a in flist(vmap(body), "applications") {
			if id := fsnow(vmap(a), "id"); id != 0 {
				query_add_snow(&q, "application_ids", id)
				n += 1
			}
		}
		if n > 0 do api_get_later(c, query_string(&q), 55)
		users_me_refresh(c, 55)
	}
	job_submit(c, j)
}

// users_me_refresh: the popout's GET /users/@me (its fetch spells the header
// "authorization" in lowercase).
@(private = "file")
users_me_refresh :: proc(c: ^Client, delay_ms: i64) {
	j := job_new(.Api, .None)
	j.method = "GET"
	j.path = "/users/@me"
	j.js_lower_auth = true
	j.not_before = now_ms() + delay_ms
	job_submit(c, j)
}

// request_page_members: GuildMemberRequester. Authors and mentioned users of a
// fetched guild page with no known member are asked for at once with op 8
// (presences false), each once (fixture scroll_history: the older page's one
// unknown author).
request_page_members :: proc(c: ^Client, channel_id: Snowflake, items: []V) {
	ch := channel_get(&c.store, channel_id)
	if ch == nil || ch.guild_id == 0 do return
	gid := ch.guild_id
	ids := make([dynamic]Snowflake, context.temp_allocator)
	want :: proc(c: ^Client, gid, uid: Snowflake, ids: ^[dynamic]Snowflake) {
		if uid == 0 || member_get(&c.store, gid, uid) != nil do return
		key := [2]Snowflake{gid, uid}
		if c.members_requested[key] do return
		c.members_requested[key] = true
		append(ids, uid)
	}
	for mv in items {
		m := vmap(mv)
		if vget(m, "webhook_id") == nil do want(c, gid, fsnow(fmap(m, "author"), "id"), &ids)
		for u in flist(m, "mentions") do want(c, gid, fsnow(vmap(u), "id"), &ids)
	}
	if len(ids) > 0 do request_guild_members(c, gid, ids[:])
}
