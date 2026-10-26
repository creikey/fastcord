package discord

import "core:slice"
import "core:strings"
import "core:sync"
import "fc:etf"

// User actions. Each mirrors what the official client sends when the user
// does the same thing (endpoint, query order, body key order, context
// properties, retries). Call them on the UI thread; they return immediately.

// ---- navigation ----

// select_channel is what CHANNEL_SELECT does on the network: it moves the
// referer, subscribes to the guild (op 37 typing/activities/threads, once per
// session), requests channel info (op 43) on guild entry, and loads messages
// if the channel has none.
select_channel :: proc(c: ^Client, guild_id, channel_id: Snowflake, message_limit := 50) {
	sync.mutex_lock(&c.route_mu)
	prev_guild := c.route_guild
	c.route_guild = guild_id
	c.route_channel = channel_id
	sync.mutex_unlock(&c.route_mu)
	if guild_id != 0 && guild_id != prev_guild {
		subscribe_guild(c, guild_id)
		c.pending_guild_open = guild_id
	}
	if guild_id == 0 && channel_id != 0 do c.pending_private_open = channel_id
	if channel_id != 0 {
		l := message_list(&c.store, channel_id)
		if !l.loaded && !l.loading {
			fetch_messages(c, channel_id, 0, message_limit)
		} else {
			on_channel_page(c, channel_id, 0, false)
		}
	}
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
	gateway_send(c.gw, .Voice_State_Update, voice_state_value(guild_id, channel_id, self_mute, self_deaf, false, 2))
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
fetch_messages :: proc(c: ^Client, channel_id: Snowflake, before: Snowflake = 0, limit := 50, tag: u64 = 0) {
	q: Query
	query_init(&q, channel_path(channel_id, "/messages"))
	if before != 0 do query_add_snow(&q, "before", before)
	query_add_int(&q, "limit", limit)
	j := job_new(.Api, .Fetch_Messages)
	j.method = "GET"
	j.path = job_str(j, query_string(&q))
	j.retries = 2
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
	files:           []Upload_File,
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
}

// ack_message schedules the read-state ack like ReadState.ack(): sent after 3 s
// (immediately when `immediate`), body {token, last_viewed[, flags]}.
ack_message :: proc(c: ^Client, channel_id, message_id: Snowflake, immediate := false) {
	due := now_ms() + (0 if immediate else ACK_DELAY_MS)
	for &p in c.pending_acks {
		if p.channel_id == channel_id {
			p.message_id = max(p.message_id, message_id)
			if immediate do p.due = due
			return
		}
	}
	append(&c.pending_acks, Pending_Ack{channel_id, message_id, due})
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
		send_ack(c, p.channel_id, p.message_id, now)
	}
}

@(private)
send_ack :: proc(c: ^Client, channel_id, message_id: Snowflake, now: i64) {
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
	sync.mutex_lock(&c.ack_mu)
	if c.ack_token != "" do json_kstr(&w, "token", c.ack_token)
	else do json_knull(&w, "token")
	sync.mutex_unlock(&c.ack_mu)
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

accept_friend_request :: proc(c: ^Client, user_id: Snowflake) {add_relationship(c, user_id, "Friends")}

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
	switch name {
	case "READY":
		analytics_on_ready(c)
		// The window reopens on its last route: the guild is subscribed and its
		// channel info requested on CONNECTION_OPEN, as when it was selected.
		sync.mutex_lock(&c.route_mu)
		g, ch := c.route_guild, c.route_channel
		sync.mutex_unlock(&c.route_mu)
		if ch != 0 {
			l := message_list(&c.store, ch)
			h := c.analytics.viewport_h if c.analytics.viewport_h > 0 else 720
			if !l.loaded && !l.loading do fetch_messages(c, ch, 0, initial_message_limit(h))
		}
		if g != 0 {
			sync.mutex_lock(&c.job_mu)
			already := c.ready_subscribed_guild == g
			sync.mutex_unlock(&c.job_mu)
			if already do c.subs.guilds[g] = true
			else do subscribe_guild(c, g)
			c.pending_guild_open = g
			c.guild_open_promotions = true
		}
	case "MESSAGE_CREATE":
		d := vmap(data)
		if nv := fstr(d, "nonce"); nv != "" {
			if rt, ok := &c.analytics.roundtrips[parse_snowflake(nv)]; ok && rt.gateway == 0 do rt.gateway = now_ms()
		}
		gid := fsnow(d, "guild_id")
		sync.mutex_lock(&c.route_mu)
		viewing := c.route_channel == fsnow(d, "channel_id")
		sync.mutex_unlock(&c.route_mu)
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

// voice_join / voice_leave: op 4 the way VoiceStateStore sends it (flags 2).
voice_join :: proc(c: ^Client, guild_id, channel_id: Snowflake, self_mute := false, self_deaf := false) {
	voice_update(c, guild_id, channel_id, self_mute, self_deaf)
}

voice_leave :: proc(c: ^Client) {
	voice_update(c, 0, 0, true, false)
}

// guild_channel_info: op 43 sent when a guild's channel is shown.
guild_channel_info :: proc(c: ^Client, guild_id: Snowflake) {
	if c.gw == nil do return
	b := etf.map_builder(2, context.temp_allocator)
	etf.map_put(&b, "guild_id", snowflake_string(guild_id))
	etf.map_put(&b, "fields", etf.List{string("status"), string("voice_start_time")})
	gateway_send(c.gw, .Request_Channel_Info, etf.map_done(&b))
}

// on_channel_page runs when the first page of a selected channel arrives
// (or immediately when cached): the follow-ups the official client issues
// once the channel renders.
on_channel_page :: proc(c: ^Client, channel_id: Snowflake, got: int, full: bool) {
	ch := c.store.channels[channel_id]
	if g := c.pending_guild_open; g != 0 && (ch.guild_id == g || ch.guild_id == 0) {
		c.pending_guild_open = 0
		guild_channel_info(c, g)
		if !c.started_guilds[g] {
			c.started_guilds[g] = true
			schedule_guild_open(c, g, c.guild_open_promotions)
		}
		c.guild_open_promotions = false
	}
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
			fetch_profile_ex(c, u, {mutual_guilds = false, mutual_friends = false, mutual_friends_count = false})
			fetch_profile_ex(c, u, {mutual_guilds = true, mutual_friends = false, mutual_friends_count = false, delay_ms = 223})
			fetch_note(c, u, 223)
			fetch_profile_ex(c, u, {kind = "sidebar", mutual_guilds = true, mutual_friends = true, mutual_friends_count = false, delay_ms = 476})
		}
	}
	// Viewing a channel with unread messages acks it (ReadState, 3 s timer).
	if channel_unread(&c.store, channel_id) {
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

// open_profile_popout: what clicking a username does (popout + note ~300 ms later).
open_profile_popout :: proc(c: ^Client, user_id, guild_id: Snowflake) {
	fetch_profile_ex(c, user_id, {kind = "popout", guild_id = guild_id})
	fetch_note(c, user_id, 300)
}

// open_full_profile: "View Full Profile" from a popout.
open_full_profile :: proc(c: ^Client, user_id, guild_id: Snowflake) {
	fetch_profile_ex(c, user_id, {kind = "modal", mutual_guilds = true, mutual_friends_count = true, guild_id = guild_id})
}

// open_message_context_menu: right-clicking a message loads the application
// command indexes (guild once per guild, user once per session).
open_message_context_menu :: proc(c: ^Client, guild_id: Snowflake) {
	if guild_id != 0 && !c.command_index_guilds[guild_id] {
		c.command_index_guilds[guild_id] = true
		j := job_new(.Api, .None)
		j.method = "GET"
		j.path = job_str(j, strings.concatenate({"/guilds/", snowflake_string(guild_id), "/application-command-index"}, context.temp_allocator))
		job_submit(c, j)
	}
	if !c.command_index_user {
		c.command_index_user = true
		j := job_new(.Api, .None)
		j.method = "GET"
		j.path = "/users/@me/application-command-index"
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
