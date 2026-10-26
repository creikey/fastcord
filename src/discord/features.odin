package discord

import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "fc:etf"

// Threads, forum posts, pins, search and notification inputs.
//
// Side tables kept next to the Store (the Store's structs carry no thread
// metadata), fed from gateway dispatches by extras_on_dispatch (called from
// client_poll right after the Store applied the event), and REST calls whose
// bodies go to the UI instead of the Store (feature_take), shaped like the
// official client's (web bundle routes / action creators):
//
//   GET  /channels/{id}/messages/pins?limit=25[&before=<iso>]   (ChannelPinsActionCreators.fetchPins)
//   POST /channels/{id}/pins/ack                                 (ReadStateStore.ackPins, opening pins)
//   GET  /channels/{id}/messages?limit=50&around={mid}           (jump to message; query order before,after,limit,around)
//   POST /channels/{forum}/post-data {"thread_ids":[..]}         (ForumPostMessagesManager, batches of 10)
//   GET  /channels/{forum}/threads/search?archived=true&sort_by=last_message_time&sort_order=desc&limit=25&tag_setting=match_some&offset=0
//   GET  /guilds/{id}/messages/search?... /channels/{id}/messages/search?...   (search: see search_messages)

Thread_Meta :: struct {
	id:              Snowflake,
	parent_id:       Snowflake,
	owner_id:        Snowflake,
	message_count:   int,
	member_count:    int,
	archived:        bool,
	locked:          bool,
	joined:          bool, // we are a thread member (shown in the sidebar)
	applied_tags:    [dynamic]Snowflake,
	create_ts:       string, // thread_metadata.create_timestamp
	last_message_id: Snowflake,
	// forum post previews (post-data / threads/search first_messages)
	first_author:    Snowflake,
	first_content:   string,
}

Forum_Tag :: struct {
	id:         Snowflake,
	name:       string,
	emoji_name: string,
	emoji_id:   Snowflake,
}

// A MESSAGE_CREATE kept for the notification logic (UI thread).
New_Message :: struct {
	id:               Snowflake,
	channel_id:       Snowflake,
	guild_id:         Snowflake,
	author_id:        Snowflake,
	kind:             int,
	flags:            u64,
	content:          string,
	mentions_me:      bool,
	mention_everyone: bool,
	mention_roles:    [dynamic]Snowflake,
	attachments:      int,
	embeds:           int,
	sticker:          bool,
}

Extras :: struct {
	threads:    map[Snowflake]Thread_Meta,
	tags:       map[Snowflake][dynamic]Forum_Tag, // forum channel -> available_tags
	pins_epoch: map[Snowflake]int, // bumped on CHANNEL_PINS_UPDATE
	new_msgs:   [dynamic]New_Message,
	my_roles:   map[Snowflake][dynamic]Snowflake, // guild -> our role ids
}

extras: Extras

// ---- dispatch side ----

@(private = "file")
x_allocator: Allocator

@(private = "file")
x_alloc :: proc() -> Allocator {return x_allocator}

@(private = "file")
note_thread :: proc(t: etf.Map, me: Snowflake) {
	if t == nil do return
	id := fsnow(t, "id")
	if id == 0 do return
	a := x_alloc()
	tm, had := extras.threads[id]
	if !had {
		tm.id = id
		tm.applied_tags = make([dynamic]Snowflake, a)
	}
	if vhas(t, "parent_id") do tm.parent_id = fsnow(t, "parent_id")
	if vhas(t, "owner_id") do tm.owner_id = fsnow(t, "owner_id")
	if vhas(t, "message_count") do tm.message_count = int(fint(t, "message_count"))
	if vhas(t, "member_count") do tm.member_count = int(fint(t, "member_count"))
	if vhas(t, "last_message_id") do tm.last_message_id = fsnow(t, "last_message_id")
	if md := fmap(t, "thread_metadata"); md != nil {
		tm.archived = fbool(md, "archived")
		tm.locked = fbool(md, "locked")
		if ts := fstr(md, "create_timestamp"); ts != "" && tm.create_ts == "" do tm.create_ts = strings.clone(ts, a)
	}
	if vhas(t, "applied_tags") {
		clear(&tm.applied_tags)
		for tv in flist(t, "applied_tags") do append(&tm.applied_tags, vsnow(tv))
	}
	if mm := fmap(t, "member"); mm != nil {
		uid := fsnow(mm, "user_id")
		if uid == 0 || uid == me do tm.joined = true
	}
	extras.threads[id] = tm
}

@(private = "file")
note_tags :: proc(ch: etf.Map) {
	if ch == nil || !vhas(ch, "available_tags") do return
	id := fsnow(ch, "id")
	a := x_alloc()
	list, had := extras.tags[id]
	if !had do list = make([dynamic]Forum_Tag, a)
	for t in list {
		delete(t.name, a)
		delete(t.emoji_name, a)
	}
	clear(&list)
	for tv in flist(ch, "available_tags") {
		tm := vmap(tv)
		append(&list, Forum_Tag{id = fsnow(tm, "id"), name = strings.clone(fstr(tm, "name"), a), emoji_name = strings.clone(fstr(tm, "emoji_name"), a), emoji_id = fsnow(tm, "emoji_id")})
	}
	extras.tags[id] = list
}

@(private = "file")
note_guild :: proc(g: etf.Map, me: Snowflake) {
	if g == nil do return
	for cv in flist(g, "channels") do note_tags(vmap(cv))
	for tv in flist(g, "threads") do note_thread(vmap(tv), me)
	gid := fsnow(g, "id")
	for mv in flist(g, "members") {
		mm := vmap(mv)
		uid := fsnow(mm, "user_id")
		if u := fmap(mm, "user"); u != nil do uid = fsnow(u, "id")
		if uid == me do note_roles(gid, flist(mm, "roles"))
	}
}

@(private = "file")
note_roles :: proc(gid: Snowflake, roles: []V) {
	list, had := extras.my_roles[gid]
	if !had do list = make([dynamic]Snowflake, x_alloc())
	clear(&list)
	for r in roles do append(&list, vsnow(r))
	extras.my_roles[gid] = list
}

// extras_on_dispatch: called by client_poll after the Store applied `name`.
extras_on_dispatch :: proc(c: ^Client, name: string, data: V) {
	extras_dispatch(&c.store, c.allocator, name, data)
}

// extras_dispatch: the same for a bare Store (offline fixtures).
extras_dispatch :: proc(s: ^Store, allocator: Allocator, name: string, data: V) {
	x_allocator = allocator
	if extras.threads == nil {
		a := x_alloc()
		extras.threads = make(map[Snowflake]Thread_Meta, 64, a)
		extras.tags = make(map[Snowflake][dynamic]Forum_Tag, 16, a)
		extras.pins_epoch = make(map[Snowflake]int, 16, a)
		extras.new_msgs = make([dynamic]New_Message, a)
		extras.my_roles = make(map[Snowflake][dynamic]Snowflake, 16, a)
	}
	me := s.me
	d := vmap(data)
	switch name {
	case "READY":
		guilds := flist(d, "guilds")
		for gv in guilds do note_guild(vmap(gv), me)
		// user READY: merged_members[i] holds our member object for guilds[i]
		for lv, i in flist(d, "merged_members") {
			if i >= len(guilds) do break
			for mv in vlist(lv) {
				mm := vmap(mv)
				if fsnow(mm, "user_id") == me do note_roles(fsnow(vmap(guilds[i]), "id"), flist(mm, "roles"))
			}
		}
	case "GUILD_CREATE":
		note_guild(d, me)
	case "CHANNEL_CREATE", "CHANNEL_UPDATE":
		note_tags(d)
	case "THREAD_CREATE", "THREAD_UPDATE":
		note_thread(d, me)
		// creating a thread (or being added on create) makes us a member
		if name == "THREAD_CREATE" && fsnow(d, "owner_id") == me {
			if tm, ok := &extras.threads[fsnow(d, "id")]; ok do tm.joined = true
		}
	case "THREAD_LIST_SYNC":
		for tv in flist(d, "threads") do note_thread(vmap(tv), me)
		for mv in flist(d, "members") {
			mm := vmap(mv)
			if fsnow(mm, "user_id") == me {
				if tm, ok := &extras.threads[fsnow(mm, "id")]; ok do tm.joined = true
			}
		}
	case "THREAD_MEMBER_UPDATE":
		if tm, ok := &extras.threads[fsnow(d, "id")]; ok do tm.joined = true
	case "THREAD_MEMBERS_UPDATE":
		tid := fsnow(d, "id")
		if tm, ok := &extras.threads[tid]; ok {
			if vhas(d, "member_count") do tm.member_count = int(fint(d, "member_count"))
			for mv in flist(d, "added_members") do if fsnow(vmap(mv), "user_id") == me do tm.joined = true
			for uv in flist(d, "removed_member_ids") do if vsnow(uv) == me do tm.joined = false
		}
	case "THREAD_DELETE":
		if tid := fsnow(d, "id"); tid in extras.threads {
			_, tm := delete_key(&extras.threads, tid)
			free_thread_meta(&tm)
		}
	case "CHANNEL_PINS_UPDATE":
		cid := fsnow(d, "channel_id")
		extras.pins_epoch[cid] = extras.pins_epoch[cid] + 1
	case "GUILD_MEMBER_UPDATE":
		if fsnow(fmap(d, "user"), "id") == me do note_roles(fsnow(d, "guild_id"), flist(d, "roles"))
	case "MESSAGE_CREATE":
		cid := fsnow(d, "channel_id")
		if tm, ok := &extras.threads[cid]; ok {
			mid := fsnow(d, "id")
			// a forum post's starter message shares the thread's id and isn't a reply
			if mid == cid {
				if tm.first_content == "" {
					tm.first_author = fsnow(fmap(d, "author"), "id")
					tm.first_content = strings.clone(fstr(d, "content"), x_alloc())
				}
			} else {
				tm.message_count += 1
			}
			tm.last_message_id = mid
		}
		au := fmap(d, "author")
		aid := fsnow(au, "id")
		if aid == me || aid == 0 || len(extras.new_msgs) >= 256 do break
		nm := New_Message {
			id               = fsnow(d, "id"),
			channel_id       = cid,
			guild_id         = fsnow(d, "guild_id"),
			author_id        = aid,
			kind             = int(fint(d, "type")),
			flags            = u64(fint(d, "flags")),
			content          = strings.clone(fstr(d, "content"), x_alloc()),
			mention_everyone = fbool(d, "mention_everyone"),
			attachments      = len(flist(d, "attachments")),
			embeds           = len(flist(d, "embeds")),
			sticker          = len(flist(d, "sticker_items")) > 0,
			mention_roles    = make([dynamic]Snowflake, x_alloc()),
		}
		for mv in flist(d, "mentions") do if fsnow(vmap(mv), "id") == me do nm.mentions_me = true
		for rv in flist(d, "mention_roles") do append(&nm.mention_roles, vsnow(rv))
		append(&extras.new_msgs, nm)
	}
}

@(private = "file")
free_thread_meta :: proc(tm: ^Thread_Meta) {
	a := x_alloc()
	delete(tm.applied_tags)
	delete(tm.create_ts, a)
	delete(tm.first_content, a)
}

// extras_destroy frees the side tables and stops the feature workers (called
// from store_destroy, after the client has set quit).
extras_destroy :: proc() {
	sync.mutex_lock(&fpool.mu)
	threads := fpool.threads
	fpool.threads = {}
	fpool.owner = nil
	sync.cond_broadcast(&fpool.cond)
	sync.mutex_unlock(&fpool.mu)
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
	delete(threads)
	for j in fpool.jobs {
		delete(j.method)
		delete(j.path)
		delete(j.body)
	}
	delete(fpool.jobs)
	for &r in fpool.results do feature_result_free(&r)
	delete(fpool.results)
	fpool = {}

	if extras.threads == nil do return
	a := x_alloc()
	for _, &tm in extras.threads do free_thread_meta(&tm)
	delete(extras.threads)
	for _, list in extras.tags {
		for t in list {
			delete(t.name, a)
			delete(t.emoji_name, a)
		}
		delete(list)
	}
	delete(extras.tags)
	delete(extras.pins_epoch)
	for &m in extras.new_msgs {
		delete(m.content, a)
		delete(m.mention_roles)
	}
	delete(extras.new_msgs)
	for _, list in extras.my_roles do delete(list)
	delete(extras.my_roles)
	extras = {}
}

// take_new_messages returns MESSAGE_CREATEs (from others) since the last call.
// Free with new_messages_free.
take_new_messages :: proc(c: ^Client, allocator := context.temp_allocator) -> []New_Message {
	out := make([]New_Message, len(extras.new_msgs), allocator)
	copy(out, extras.new_msgs[:])
	clear(&extras.new_msgs)
	return out
}

new_messages_free :: proc(c: ^Client, msgs: []New_Message) {
	for &m in msgs {
		delete(m.content, c.allocator)
		delete(m.mention_roles)
	}
}

thread_meta :: proc(id: Snowflake) -> ^Thread_Meta {
	if tm, ok := &extras.threads[id]; ok do return tm
	return nil
}

forum_tags :: proc(forum_id: Snowflake) -> []Forum_Tag {
	if l, ok := extras.tags[forum_id]; ok do return l[:]
	return nil
}

pins_epoch :: proc(channel_id: Snowflake) -> int {return extras.pins_epoch[channel_id]}

my_guild_roles :: proc(guild_id: Snowflake) -> []Snowflake {
	if l, ok := extras.my_roles[guild_id]; ok do return l[:]
	return nil
}

is_thread :: proc(ch: ^Channel) -> bool {
	return ch != nil && (ch.kind == .Public_Thread || ch.kind == .Private_Thread || ch.kind == .Announcement_Thread)
}

// Active threads under parent_id we're a member of, oldest first (the sidebar's order).
joined_threads :: proc(s: ^Store, parent_id: Snowflake, allocator := context.temp_allocator) -> []Snowflake {
	out := make([dynamic]Snowflake, allocator)
	for id, tm in extras.threads {
		if tm.parent_id != parent_id || !tm.joined || tm.archived do continue
		if id not_in s.channels do continue
		append(&out, id)
	}
	for i in 1 ..< len(out) {
		for j := i; j > 0 && out[j] < out[j - 1]; j -= 1 do out[j], out[j - 1] = out[j - 1], out[j]
	}
	return out[:]
}

// Threads (any state we know of) whose parent is the forum, newest activity first.
forum_threads :: proc(s: ^Store, forum_id: Snowflake, allocator := context.temp_allocator) -> []Snowflake {
	out := make([dynamic]Snowflake, allocator)
	for id, tm in extras.threads {
		if tm.parent_id == forum_id do append(&out, id)
	}
	key :: proc(id: Snowflake) -> Snowflake {
		tm := extras.threads[id]
		return max(tm.last_message_id, id)
	}
	for i in 1 ..< len(out) {
		for j := i; j > 0 && key(out[j]) > key(out[j - 1]); j -= 1 do out[j], out[j - 1] = out[j - 1], out[j]
	}
	return out[:]
}

// Applies forum post bodies (post-data / threads/search) to the side tables and Store.
apply_forum_threads :: proc(c: ^Client, body: V) {
	s := &c.store
	m := vmap(body)
	me := s.me
	// threads/search: {threads:[...], members:[...], first_messages:[...]}
	for tv in flist(m, "threads") {
		tmap := vmap(tv)
		cid := parse_channel_into(s, tmap, fsnow(tmap, "guild_id"))
		if g, ok := &s.guilds[fsnow(tmap, "guild_id")]; ok && cid != 0 {
			found := false
			for x in g.channels do if x == cid do found = true
			if !found do append(&g.channels, cid)
		}
		note_thread(tmap, me)
	}
	for mv in flist(m, "members") {
		mm := vmap(mv)
		if fsnow(mm, "user_id") == me {
			if tm, ok := &extras.threads[fsnow(mm, "id")]; ok do tm.joined = true
		}
	}
	note_first :: proc(c: ^Client, msg: etf.Map) {
		if msg == nil do return
		tid := fsnow(msg, "channel_id")
		tm, ok := &extras.threads[tid]
		if !ok do return
		if au := fmap(msg, "author"); au != nil do tm.first_author = parse_user_into(&c.store, au)
		delete(tm.first_content, c.allocator)
		tm.first_content = strings.clone(fstr(msg, "content"), c.allocator)
	}
	for fv in flist(m, "first_messages") do note_first(c, vmap(fv))
	// post-data: {threads: {"<id>": {first_message: {...}, owner: {...}}}}
	if tobj := fmap(m, "threads"); tobj != nil {
		for pr in tobj {
			pm := vmap(pr.value)
			note_first(c, fmap(pm, "first_message"))
		}
	}
}

// Parses a REST message object without inserting it into the channel's list
// (search results, pins): authors are added to the Store.
parse_loose_message :: proc(s: ^Store, m: etf.Map, allocator := context.temp_allocator) -> Message {
	msg := Message {
		id         = fsnow(m, "id"),
		channel_id = fsnow(m, "channel_id"),
		kind       = int(fint(m, "type")),
		content    = strings.clone(fstr(m, "content"), allocator),
		timestamp  = strings.clone(fstr(m, "timestamp"), allocator),
		flags      = u64(fint(m, "flags")),
	}
	if au := fmap(m, "author"); au != nil do msg.author_id = parse_user_into(s, au)
	msg.attachments = make([dynamic]Attachment, allocator)
	for av in flist(m, "attachments") {
		am := vmap(av)
		append(&msg.attachments, Attachment{id = fsnow(am, "id"), filename = strings.clone(fstr(am, "filename"), allocator), url = strings.clone(fstr(am, "url"), allocator), proxy_url = strings.clone(fstr(am, "proxy_url"), allocator), width = int(fint(am, "width")), height = int(fint(am, "height")), size = int(fint(am, "size")), content_type = strings.clone(fstr(am, "content_type"), allocator)})
	}
	return msg
}

// ---- REST (bodies to the UI) ----

Feature_Op :: enum u8 {
	Pins,
	Pins_Ack,
	Around,
	Forum_Posts,
	Thread_Search,
	Search,
}

Feature_Result :: struct {
	op:         Feature_Op,
	tag:        u64,
	channel_id: Snowflake,
	ok:         bool,
	status:     int,
	body:       V,
	arena:      ^virtual.Arena,
}

@(private = "file")
F_Job :: struct {
	op:         Feature_Op,
	tag:        u64,
	channel_id: Snowflake,
	method:     string,
	path:       string,
	body:       string,
	retries:    int,
	client:     ^Client,
}

@(private = "file")
F_Pool :: struct {
	mu:      sync.Mutex,
	cond:    sync.Cond,
	jobs:    [dynamic]F_Job,
	results: [dynamic]Feature_Result,
	threads: [dynamic]^thread.Thread,
	owner:   ^Client,
}

@(private = "file")
fpool: F_Pool

@(private = "file")
f_worker :: proc(_: rawptr) {
	for {
		sync.mutex_lock(&fpool.mu)
		for len(fpool.jobs) == 0 {
			if fpool.owner == nil || fpool.owner.quit {
				sync.mutex_unlock(&fpool.mu)
				return
			}
			sync.cond_wait_with_timeout(&fpool.cond, &fpool.mu, 500 * time.Millisecond)
		}
		j := fpool.jobs[0]
		ordered_remove(&fpool.jobs, 0)
		sync.mutex_unlock(&fpool.mu)
		if !j.client.quit {
			ctype := "application/json" if j.body != "" else ""
			r := api_call(j.client, j.method, j.path, transmute([]byte)j.body, ctype, "", nil, j.retries, 1)
			res := Feature_Result{op = j.op, tag = j.tag, channel_id = j.channel_id, ok = r.ok, status = r.status, body = r.body, arena = r.arena}
			sync.mutex_lock(&fpool.mu)
			append(&fpool.results, res)
			sync.mutex_unlock(&fpool.mu)
			if j.client.cfg.wakeup != nil do j.client.cfg.wakeup(j.client.cfg.wakeup_data)
		}
		delete(j.method)
		delete(j.path)
		delete(j.body)
		free_all(context.temp_allocator)
	}
}

@(private = "file")
f_submit :: proc(c: ^Client, j: F_Job) {
	sync.mutex_lock(&fpool.mu)
	defer sync.mutex_unlock(&fpool.mu)
	if fpool.owner != c {
		fpool.owner = c
		clear(&fpool.threads)
	}
	if len(fpool.threads) == 0 {
		for _ in 0 ..< 2 do append(&fpool.threads, thread.create_and_start_with_data(nil, f_worker, c.ctx))
	}
	jj := j
	jj.client = c
	jj.method = strings.clone(j.method)
	jj.path = strings.clone(j.path)
	jj.body = strings.clone(j.body)
	append(&fpool.jobs, jj)
	sync.cond_signal(&fpool.cond)
}

// feature_take returns finished feature requests (UI thread). Free each with feature_result_free.
feature_take :: proc(c: ^Client, allocator := context.temp_allocator) -> []Feature_Result {
	sync.mutex_lock(&fpool.mu)
	defer sync.mutex_unlock(&fpool.mu)
	out := make([]Feature_Result, len(fpool.results), allocator)
	copy(out, fpool.results[:])
	clear(&fpool.results)
	return out
}

feature_result_free :: proc(r: ^Feature_Result) {
	if r.arena != nil {
		virtual.arena_destroy(r.arena)
		free(r.arena)
		r.arena = nil
	}
}

// GET /channels/{id}/messages/pins?limit=25[&before=<pinned_at ISO>]
fetch_pins :: proc(c: ^Client, channel_id: Snowflake, before_iso := "", tag: u64 = 0) {
	q: Query
	query_init(&q, channel_path(channel_id, "/messages/pins"))
	query_add_int(&q, "limit", 25)
	if before_iso != "" do query_add(&q, "before", before_iso)
	f_submit(c, {op = .Pins, tag = tag, channel_id = channel_id, method = "GET", path = query_string(&q), retries = 2})
}

// POST /channels/{id}/pins/ack (no body).
ack_pins :: proc(c: ^Client, channel_id: Snowflake) {
	f_submit(c, {op = .Pins_Ack, channel_id = channel_id, method = "POST", path = channel_path(channel_id, "/pins/ack")})
}

// GET /channels/{id}/messages?limit=50&around={mid}; the page is merged into
// the channel's message list by apply_around (UI thread).
fetch_messages_around :: proc(c: ^Client, channel_id, message_id: Snowflake, tag: u64 = 0) {
	q: Query
	query_init(&q, channel_path(channel_id, "/messages"))
	query_add_int(&q, "limit", 50)
	query_add_snow(&q, "around", message_id)
	f_submit(c, {op = .Around, tag = tag, channel_id = channel_id, method = "GET", path = query_string(&q), retries = 2})
}

apply_around :: proc(c: ^Client, r: ^Feature_Result) {
	if !r.ok do return
	context.allocator = c.store.allocator
	for mv in vlist(r.body) do upsert_message(&c.store, vmap(mv))
	c.store.changed += 1
}

// POST /channels/{forum}/post-data {"thread_ids":[...]} (up to 10 per request, like the client).
fetch_forum_posts :: proc(c: ^Client, forum_id: Snowflake, thread_ids: []Snowflake) {
	for start := 0; start < len(thread_ids); start += 10 {
		w: Json
		json_init(&w)
		json_obj(&w)
		json_key(&w, "thread_ids")
		json_arr(&w)
		for id in thread_ids[start:min(start + 10, len(thread_ids))] do json_snowflake(&w, id)
		json_arr_end(&w)
		json_obj_end(&w)
		f_submit(c, {op = .Forum_Posts, channel_id = forum_id, method = "POST", path = channel_path(forum_id, "/post-data"), body = json_string(&w)})
	}
}

// GET /channels/{forum}/threads/search?archived=true&sort_by=last_message_time&sort_order=desc&limit=25&tag_setting=match_some&offset=N
fetch_archived_forum_threads :: proc(c: ^Client, forum_id: Snowflake, offset := 0) {
	q: Query
	query_init(&q, channel_path(forum_id, "/threads/search"))
	query_add(&q, "archived", "true")
	query_add(&q, "sort_by", "last_message_time")
	query_add(&q, "sort_order", "desc")
	query_add_int(&q, "limit", 25)
	query_add(&q, "tag_setting", "match_some")
	query_add_int(&q, "offset", offset)
	f_submit(c, {op = .Thread_Search, channel_id = forum_id, method = "GET", path = query_string(&q), retries = 2})
}

Search_Query :: struct {
	content:    string,
	author_ids: []Snowflake,
	mentions:   []Snowflake,
	has:        []string, // link, embed, file, image, video, sound, sticker, poll, forward
	channel_ids: []Snowflake,
	pinned:     bool,
	offset:     int,
}

// GET /guilds/{id}/messages/search (guild) or /channels/{id}/messages/search (DMs):
// filter keys in the client's search-token order (author_id, mentions, has,
// channel_id, pinned), then content, then the default sort.
search_messages :: proc(c: ^Client, guild_id, channel_id: Snowflake, sq: Search_Query, tag: u64 = 0) {
	q: Query
	if guild_id != 0 {
		query_init(&q, strings.concatenate({"/guilds/", snowflake_string(guild_id), "/messages/search"}, context.temp_allocator))
	} else {
		query_init(&q, channel_path(channel_id, "/messages/search"))
	}
	for id in sq.author_ids do query_add_snow(&q, "author_id", id)
	for id in sq.mentions do query_add_snow(&q, "mentions", id)
	for h in sq.has do query_add(&q, "has", h)
	for id in sq.channel_ids do query_add_snow(&q, "channel_id", id)
	if sq.pinned do query_add(&q, "pinned", "true")
	if sq.content != "" do query_add(&q, "content", sq.content)
	query_add(&q, "sort_by", "timestamp")
	query_add(&q, "sort_order", "desc")
	if sq.offset > 0 do query_add_int(&q, "offset", sq.offset)
	f_submit(c, {op = .Search, tag = tag, channel_id = channel_id, method = "GET", path = query_string(&q), retries = 0})
}
