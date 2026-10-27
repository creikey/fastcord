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
//   GET  /channels/{id}/messages?limit=30&around={mid}           (jump to message; query order before,after,limit,around; fixture inbox)
//   POST /channels/{forum}/post-data {"thread_ids":[..]}         (ForumPostMessagesManager, batches of 10)
//   GET  /channels/{forum}/threads/search?archived=true&sort_by=last_message_time&sort_order=desc&limit=25&tag_setting=match_some&offset=0
//   GET  /guilds/{id}/messages/search?... /channels/{id}/messages/search?...   (search: see search_messages)

Thread_Meta :: struct {
	id: Snowflake;
	parent_id: Snowflake;
	owner_id: Snowflake;
	message_count: int;
	member_count: int;
	archived: bool;
	locked: bool;
	auto_archive_minutes: int; // thread_metadata.auto_archive_duration
	joined: bool; // we are a thread member (shown in the sidebar)
	applied_tags: [..]Snowflake;
	create_ts: string; // thread_metadata.create_timestamp
	last_message_id: Snowflake;
	// forum post previews (post-data / threads/search first_messages)
	first_author: Snowflake;
	first_content: string;
}

Forum_Tag :: struct {
	id: Snowflake;
	name: string;
	emoji_name: string;
	emoji_id: Snowflake;
}

// A MESSAGE_CREATE kept for the notification logic (UI thread).
New_Message :: struct {
	id: Snowflake;
	channel_id: Snowflake;
	guild_id: Snowflake;
	author_id: Snowflake;
	kind: int;
	flags: u64;
	content: string;
	mentions_me: bool;
	mention_everyone: bool;
	mention_roles: [..]Snowflake;
	attachments: int;
	embeds: int;
	sticker: bool;
}

Extras :: struct {
	threads: Map(Snowflake, Thread_Meta);
	tags: Map(Snowflake, [..]Forum_Tag); // forum channel -> available_tags
	pins_epoch: Map(Snowflake, int); // bumped on CHANNEL_PINS_UPDATE
	new_msgs: [..]New_Message;
	my_roles: Map(Snowflake, [..]Snowflake); // guild -> our role ids
}

extras: Extras;
#scope_file

// ---- dispatch side ----

// ---- dispatch side ----

x_allocator: Allocator;

x_alloc :: () -> Allocator {return x_allocator;}

note_thread :: (t: etf.Map, me: Snowflake) {
	if t == null { return; }
	id := fsnow(t, "id");
	if id == 0 { return; }
	a := x_alloc();
	tm, had := map_find(extras.threads, id);
	if !had {
		tm.id = id;
		tm.applied_tags = make_dynamic(Snowflake, a, a);
	}
	if vhas(t, "parent_id") { tm.parent_id = fsnow(t, "parent_id"); }
	if vhas(t, "owner_id") { tm.owner_id = fsnow(t, "owner_id"); }
	if vhas(t, "message_count") { tm.message_count = cast(int)(fint(t, "message_count")); }
	if vhas(t, "member_count") { tm.member_count = cast(int)(fint(t, "member_count")); }
	if vhas(t, "last_message_id") { tm.last_message_id = fsnow(t, "last_message_id"); }
	{ md := fmap(t, "thread_metadata");
	if md != null {
		tm.archived = fbool(md, "archived");
		tm.locked = fbool(md, "locked");
		if vhas(md, "auto_archive_duration") { tm.auto_archive_minutes = cast(int)(fint(md, "auto_archive_duration")); }
		{ ts := fstr(md, "create_timestamp");
		if ts != "" && tm.create_ts == "" { tm.create_ts = clone(ts, a); } }
	} }
	if vhas(t, "applied_tags") {
		clear(*tm.applied_tags);
		for tv: flist(t, "applied_tags") { append(*tm.applied_tags, vsnow(tv)); }
	}
	{ mm := fmap(t, "member");
	if mm != null {
		uid := fsnow(mm, "user_id");
		if uid == 0 || uid == me { tm.joined = true; }
	} }
	at(*extras.threads, id).* = tm;
}

note_tags :: (ch: etf.Map) {
	if ch == null || !vhas(ch, "available_tags") { return; }
	id := fsnow(ch, "id");
	a := x_alloc();
	list, had := map_find(extras.tags, id);
	if !had { list = make_dynamic(Forum_Tag, a, a); }
	for t: list {
		delete(t.name, a);
		delete(t.emoji_name, a);
	}
	clear(*list);
	for tv: flist(ch, "available_tags") {
		tm := vmap(tv);
		append(*list, Forum_Tag.{id = fsnow(tm, "id"), name = clone(fstr(tm, "name"), a), emoji_name = clone(fstr(tm, "emoji_name"), a), emoji_id = fsnow(tm, "emoji_id")});
	}
	at(*extras.tags, id).* = list;
}

note_guild :: (g: etf.Map, me: Snowflake) {
	if g == null { return; }
	for cv: flist(g, "channels") { note_tags(vmap(cv)); }
	for tv: flist(g, "threads") { note_thread(vmap(tv), me); }
	gid := fsnow(g, "id");
	for mv: flist(g, "members") {
		mm := vmap(mv);
		uid := fsnow(mm, "user_id");
		{ u := fmap(mm, "user");
		if u != null { uid = fsnow(u, "id"); } }
		if uid == me { note_roles(gid, flist(mm, "roles")); }
	}
}

note_roles :: (gid: Snowflake, roles: []V) {
	list, had := map_find(extras.my_roles, gid);
	if !had { list = make_dynamic(Snowflake, 0, 0, x_alloc()); }
	clear(*list);
	for r: roles { append(*list, vsnow(r)); }
	at(*extras.my_roles, gid).* = list;
}
#scope_export

// extras_on_dispatch: called by client_poll after the Store applied `name`.
extras_on_dispatch :: (c: *Client, name: string, data: V) {
	extras_dispatch(*c.store, c.allocator, name, data);
}
#scope_file

// The side tables are process-wide (the app runs one client). Several clients
// at once (the parallel offline tests) share them: dispatches and teardown are
// serialized, the tables live on the heap allocator (not one client's), and
// they are freed when the last client goes (extras_retain / extras_release).
// The side tables are process-wide (the app runs one client). Several clients
// at once (the parallel offline tests) share them: dispatches and teardown are
// serialized, the tables live on the heap allocator (not one client's), and
// they are freed when the last client goes (extras_retain / extras_release).
extras_mu: locks.Mutex;
extras_clients: int;
#scope_export

extras_retain :: () {
	locks.lock(*extras_mu);
	extras_clients += 1;
	locks.unlock(*extras_mu);
}

// extras_release: c is going away (client_destroy, before store_destroy). Its
// feature jobs were already ended by feature_pool_release.
extras_release :: (c: *Client) {
	locks.lock(*extras_mu);
	if extras_clients > 0 { extras_clients -= 1; }
	locks.unlock(*extras_mu);
}

// extras_dispatch: the same for a bare Store (offline fixtures).
extras_dispatch :: (s: *Store, allocator: Allocator, name: string, data: V) {
	// heap, not the client's allocator: the side tables are shared by every live client
	locks.lock(*extras_mu);
	defer locks.unlock(*extras_mu);
	x_allocator = runtime.heap_allocator();
	if extras.threads == null {
		a := x_alloc();
		extras.threads = Map(Snowflake, Thread_Meta).{};
		extras.tags = Map(Snowflake, [..]Forum_Tag).{};
		extras.pins_epoch = Map(Snowflake, int).{};
		extras.new_msgs = make_dynamic(New_Message, a, a);
		extras.my_roles = Map(Snowflake, [..]Snowflake).{};
	}
	account_dispatch(s, allocator, name, data);
	me := s.me;
	d := vmap(data);
	events_dispatch(x_alloc(), me, name, d);
	for __sw1: 0..0 { if name == {
	case "READY";
		guilds := flist(d, "guilds");
		for gv: guilds { note_guild(vmap(gv), me); }
		// user READY: merged_members[i] holds our member object for guilds[i]
		for lv, i: flist(d, "merged_members") {
			if i >= len(guilds) { break; }
			for mv: vlist(lv) {
				mm := vmap(mv);
				if fsnow(mm, "user_id") == me { note_roles(fsnow(vmap(get(guilds, i)), "id"), flist(mm, "roles")); }
			}
		}
	case "GUILD_CREATE";
		note_guild(d, me);
	case "CHANNEL_CREATE"; #through; case "CHANNEL_UPDATE";
		note_tags(d);
	case "THREAD_CREATE"; #through; case "THREAD_UPDATE";
		note_thread(d, me);
		// creating a thread (or being added on create) makes us a member
		if name == "THREAD_CREATE" && fsnow(d, "owner_id") == me {
			{ tm, ok := map_find_ptr(*extras.threads, fsnow(d, "id"));
			if ok { tm.joined = true; } }
		}
	case "THREAD_LIST_SYNC";
		for tv: flist(d, "threads") { note_thread(vmap(tv), me); }
		for mv: flist(d, "members") {
			mm := vmap(mv);
			if fsnow(mm, "user_id") == me {
				{ tm, ok := map_find_ptr(*extras.threads, fsnow(mm, "id"));
				if ok { tm.joined = true; } }
			}
		}
	case "THREAD_MEMBER_UPDATE";
		{ tm, ok := map_find_ptr(*extras.threads, fsnow(d, "id"));
		if ok { tm.joined = true; } }
	case "THREAD_MEMBERS_UPDATE";
		tid := fsnow(d, "id");
		{ tm, ok := map_find_ptr(*extras.threads, tid);
		if ok {
			if vhas(d, "member_count") { tm.member_count = cast(int)(fint(d, "member_count")); }
			for mv: flist(d, "added_members") { if fsnow(vmap(mv), "user_id") == me { tm.joined = true; } }
			for uv: flist(d, "removed_member_ids") { if vsnow(uv) == me { tm.joined = false; } }
		} }
	case "THREAD_DELETE";
		{ tid := fsnow(d, "id");
		if has(extras.threads, tid) {
			_, tm := delete_key(*extras.threads, tid);
			free_thread_meta(*tm);
		} }
	case "CHANNEL_PINS_UPDATE";
		cid := fsnow(d, "channel_id");
		at(*extras.pins_epoch, cid).* = __MAPIDX__(extras.pins_epoch|cid) + 1;
	case "GUILD_MEMBER_UPDATE";
		if fsnow(fmap(d, "user"), "id") == me { note_roles(fsnow(d, "guild_id"), flist(d, "roles")); }
	case "MESSAGE_CREATE";
		cid := fsnow(d, "channel_id");
		{ tm, ok := map_find_ptr(*extras.threads, cid);
		if ok {
			mid := fsnow(d, "id");
			// a forum post's starter message shares the thread's id and isn't a reply
			if mid == cid {
				if tm.first_content == "" {
					tm.first_author = fsnow(fmap(d, "author"), "id");
					tm.first_content = clone(fstr(d, "content"), x_alloc());
				}
			} else {
				tm.message_count += 1;
			}
			tm.last_message_id = mid;
		} }
		au := fmap(d, "author");
		aid := fsnow(au, "id");
		if aid == me || aid == 0 || len(extras.new_msgs) >= 256 { break __sw1; }
		nm := New_Message.{
			id = fsnow(d, "id"),
			channel_id = cid,
			guild_id = fsnow(d, "guild_id"),
			author_id = aid,
			kind = cast(int)(fint(d, "type")),
			flags = cast(u64)(fint(d, "flags")),
			content = clone(fstr(d, "content"), x_alloc()),
			mention_everyone = fbool(d, "mention_everyone"),
			attachments = len(flist(d, "attachments")),
			embeds = len(flist(d, "embeds")),
			sticker = len(flist(d, "sticker_items")) > 0,
			mention_roles = make_dynamic(Snowflake, 0, 0, x_alloc())
		};
		for mv: flist(d, "mentions") { if fsnow(vmap(mv), "id") == me { nm.mentions_me = true; } }
		for rv: flist(d, "mention_roles") { append(*nm.mention_roles, vsnow(rv)); }
		append(*extras.new_msgs, nm);
	} }
}
#scope_file

free_thread_meta :: (tm: *Thread_Meta) {
	a := x_alloc();
	delete(tm.applied_tags);
	delete(tm.create_ts, a);
	delete(tm.first_content, a);
}
#scope_export

// feature_pool_retain / feature_pool_release: client_create / client_destroy.
// Release drops the client's queued jobs and unread results and waits for its
// running ones, so other live clients keep the pool and the side tables.
feature_pool_retain :: (c: *Client) {
	locks.lock(*fpool.mu);
	fpool.clients += 1;
	locks.unlock(*fpool.mu);
}

feature_pool_release :: (c: *Client) {
	context.allocator = runtime.heap_allocator();
	locks.lock(*fpool.mu);
	fpool.clients -= 1;
	if fpool.owner == c { fpool.owner = null; }
	{ i := 0;
	while i < len(fpool.jobs) {
		j := get(fpool.jobs, i);
		if j.client != c {
			i += 1;
			continue;
		}
		delete(j.method);
		delete(j.path);
		delete(j.body);
		delete(j.context_b64);
		delete(j.file);
		ordered_remove(*fpool.jobs, i);
	} }
	{ i := 0;
	while i < len(fpool.results) {
		if __MAPIDX__(fpool.results|i).client != c {
			i += 1;
			continue;
		}
		feature_result_free(at(*fpool.results, i));
		ordered_remove(*fpool.results, i);
	} }
	locks.cond_broadcast(*fpool.cond);
	while true {
		busy := false;
		for x: fpool.inflight { if x == c { busy = true; } }
		if !busy { break; }
		locks.unlock(*fpool.mu);
		time.sleep(2 * time.Millisecond);
		locks.lock(*fpool.mu);
	}
	locks.unlock(*fpool.mu);
}

// extras_destroy frees the side tables and stops the feature workers (called
// from store_destroy, after the client has set quit). Nothing while another
// client is alive (feature_pool_release).
extras_destroy :: () {
	context.allocator = runtime.heap_allocator();
	locks.lock(*extras_mu);
	defer locks.unlock(*extras_mu);
	if extras_clients > 0 { return; } // another client still uses them
	locks.lock(*fpool.mu);
	if fpool.clients > 0 {
		locks.unlock(*fpool.mu);
		return;
	}
	threads := fpool.threads;
	fpool.threads = .{};
	fpool.owner = null;
	locks.cond_broadcast(*fpool.cond);
	locks.unlock(*fpool.mu);
	for t: threads {
		locks.join(t);
	}
	delete(threads);
	for j: fpool.jobs {
		delete(j.method);
		delete(j.path);
		delete(j.body);
		delete(j.context_b64);
		delete(j.file);
	}
	delete(fpool.jobs);
	for * r: fpool.results { feature_result_free(*r); }
	delete(fpool.results);
	delete(fpool.inflight);
	fpool = .{};
	events_destroy();

	if extras.threads == null { return; }
	a := x_alloc();
	for * _, tm: extras.threads { free_thread_meta(*tm); }
	delete(extras.threads);
	for _, list: extras.tags {
		for t: list {
			delete(t.name, a);
			delete(t.emoji_name, a);
		}
		delete(list);
	}
	delete(extras.tags);
	delete(extras.pins_epoch);
	for * m: extras.new_msgs {
		delete(m.content, a);
		delete(m.mention_roles);
	}
	delete(extras.new_msgs);
	for _, list: extras.my_roles { delete(list); }
	delete(extras.my_roles);
	extras = .{};
}

// take_new_messages returns MESSAGE_CREATEs (from others) since the last call.
// Free with new_messages_free.
take_new_messages :: (c: *Client, allocator := temp) -> []New_Message {
	out := make_slice(New_Message, len(extras.new_msgs), allocator);
	copy(out, view(extras.new_msgs));
	clear(*extras.new_msgs);
	return out;
}

new_messages_free :: (c: *Client, msgs: []New_Message) {
	for * m: msgs {
		delete(m.content, c.allocator);
		delete(m.mention_roles);
	}
}

thread_meta :: (id: Snowflake) -> *Thread_Meta {
	{ tm, ok := map_find_ptr(*extras.threads, id);
	if ok { return tm; } }
	return null;
}

forum_tags :: (forum_id: Snowflake) -> []Forum_Tag {
	{ l, ok := map_find(extras.tags, forum_id);
	if ok { return view(l); } }
	return .{};
}

pins_epoch :: (channel_id: Snowflake) -> int {return get(extras.pins_epoch, channel_id);}

my_guild_roles :: (guild_id: Snowflake) -> []Snowflake {
	locks.lock(*extras_mu);
	defer locks.unlock(*extras_mu);
	{ l, ok := map_find(extras.my_roles, guild_id);
	if ok { return slice_clone_temp(view(l)); } }
	return .{};
}
#scope_file

slice_clone_temp :: (l: []Snowflake) -> []Snowflake {
	out := make_slice(Snowflake, len(l), temp);
	copy(out, l);
	return out;
}
#scope_export

is_thread :: (ch: *Channel) -> bool {
	return ch != null && (ch.kind == .Public_Thread || ch.kind == .Private_Thread || ch.kind == .Announcement_Thread);
}

// Active threads under parent_id we're a member of, oldest first (the sidebar's order).
joined_threads :: (s: *Store, parent_id: Snowflake, allocator := temp) -> []Snowflake {
	out := make_dynamic(Snowflake, 0, 0, allocator);
	for id, tm: extras.threads {
		if tm.parent_id != parent_id || !tm.joined || tm.archived { continue; }
		if !has(s.channels, id) { continue; }
		append(*out, id);
	}
	for i: 1..len(out)-1 {
		for < j: i..(0 && __MAPIDX__(out|j) < __MAPIDX__(out|j - 1))+1 { __MAPIDX__(out|j), __MAPIDX__(out|j - 1) = map_find(out|j - 1), __MAPIDX__(out, j); }
	}
	return view(out);
}

// Threads (any state we know of) whose parent is the forum, newest activity first.
forum_threads :: (s: *Store, forum_id: Snowflake, allocator := temp) -> []Snowflake {
	out := make_dynamic(Snowflake, 0, 0, allocator);
	for id, tm: extras.threads {
		if tm.parent_id == forum_id { append(*out, id); }
	}
	key :: (id: Snowflake) -> Snowflake {
		tm := get(extras.threads, id);
		return max(tm.last_message_id, id);
	}
	for i: 1..len(out)-1 {
		for < j: i..(0 && key(__MAPIDX__(out|j)) > key(__MAPIDX__(out|j - 1)))+1 { __MAPIDX__(out|j), __MAPIDX__(out|j - 1) = map_find(out|j - 1), __MAPIDX__(out, j); }
	}
	return view(out);
}

// Applies forum post bodies (post-data / threads/search) to the side tables and Store.
apply_forum_threads :: (c: *Client, body: V) {
	s := *c.store;
	m := vmap(body);
	me := s.me;
	// threads/search: {threads:[...], members:[...], first_messages:[...]}
	for tv: flist(m, "threads") {
		tmap := vmap(tv);
		cid := parse_channel_into(s, tmap, fsnow(tmap, "guild_id"));
		{ g, ok := map_find_ptr(*s.guilds, fsnow(tmap, "guild_id"));
		if ok && cid != 0 {
			found := false;
			for x: g.channels { if x == cid { found = true; } }
			if !found { append(*g.channels, cid); }
		} }
		note_thread(tmap, me);
	}
	for mv: flist(m, "members") {
		mm := vmap(mv);
		if fsnow(mm, "user_id") == me {
			{ tm, ok := map_find_ptr(*extras.threads, fsnow(mm, "id"));
			if ok { tm.joined = true; } }
		}
	}
	note_first :: (c: *Client, msg: etf.Map) {
		if msg == null { return; }
		tid := fsnow(msg, "channel_id");
		tm, ok := map_find_ptr(*extras.threads, tid);
		if !ok { return; }
		{ au := fmap(msg, "author");
		if au != null { tm.first_author = parse_user_into(*c.store, au); } }
		delete(tm.first_content, c.allocator);
		tm.first_content = clone(fstr(msg, "content"), c.allocator);
	}
	for fv: flist(m, "first_messages") { note_first(c, vmap(fv)); }
	// post-data: {threads: {"<id>": {first_message: {...}, owner: {...}}}}
	{ tobj := fmap(m, "threads");
	if tobj != null {
		for pr: tobj {
			pm := vmap(pr.value);
			note_first(c, fmap(pm, "first_message"));
		}
	} }
}

// Parses a REST message object without inserting it into the channel's list
// (search results, pins): authors are added to the Store.
parse_loose_message :: (s: *Store, m: etf.Map, allocator := temp) -> Message {
	msg := Message.{
		id = fsnow(m, "id"),
		channel_id = fsnow(m, "channel_id"),
		kind = cast(int)(fint(m, "type")),
		content = clone(fstr(m, "content"), allocator),
		timestamp = clone(fstr(m, "timestamp"), allocator),
		flags = cast(u64)(fint(m, "flags"))
	};
	{ au := fmap(m, "author");
	if au != null { msg.author_id = parse_user_into(s, au); } }
	msg.attachments = make_dynamic(Attachment, 0, 0, allocator);
	for av: flist(m, "attachments") {
		am := vmap(av);
		append(*msg.attachments, Attachment.{id = fsnow(am, "id"), filename = clone(fstr(am, "filename"), allocator), url = clone(fstr(am, "url"), allocator), proxy_url = clone(fstr(am, "proxy_url"), allocator), width = cast(int)(fint(am, "width")), height = cast(int)(fint(am, "height")), size = cast(int)(fint(am, "size")), content_type = clone(fstr(am, "content_type"), allocator)});
	}
	return msg;
}

// ---- REST (bodies to the UI) ----

Feature_Op :: enum u8 {
	Pins;
	Pins_Ack;
	Around;
	Forum_Posts;
	Thread_Search;
	Search;
	Thread_Browse; // inbox.odin
	Mentions;
	Mention_Delete;
	Thread_Create;
	User_Patch; // account.odin
	Profile_Patch;
	// guild_admin.odin (guild_admin_apply first)
	Event_Create;
	Event_Counts;
	Event_Rsvps;
	Event_Interest;
	Event_Invite;
	Event_Delete;
	Event_Start;
	Guild_Aux; // GETs / acks whose bodies nothing reads
	Channel_Create;
	Channel_Edit;
	Channel_Delete;
	Emoji_Upload;
}

Feature_Result :: struct {
	op: Feature_Op;
	tag: u64;
	channel_id: Snowflake;
	ok: bool;
	status: int;
	body: V;
	arena: *virtual.Arena;
	client: *Client; // the client that submitted it
}
#scope_module

F_Job :: struct {
	op: Feature_Op;
	tag: u64;
	channel_id: Snowflake;
	method: string;
	path: string;
	body: string;
	retries: int;
	client: *Client;
	context_b64: string; // x-context-properties
	file: string; // read and encoded on the worker (file_job_body)
}
#scope_file

F_Pool :: struct {
	mu: locks.Mutex;
	cond: locks.Cond;
	jobs: [..]F_Job;
	results: [..]Feature_Result;
	threads: [..]*thread.Thread;
	owner: *Client;
	clients: int; // live clients (tests run several at once); the pool and side tables outlive all but the last
	inflight: [..]*Client; // clients of the jobs being run now
}

fpool: F_Pool;

f_worker :: (_: *void) {
	context.allocator = runtime.heap_allocator(); // the pool outlives the client that started it
	while true {
		locks.lock(*fpool.mu);
		while len(fpool.jobs) == 0 {
			// stop only in extras_destroy (no live client): a test client going
			// away must not take the workers from the clients still running
			if len(fpool.threads) == 0 {
				locks.unlock(*fpool.mu);
				return;
			}
			locks.cond_wait_with_timeout(*fpool.cond, *fpool.mu, 500 * time.Millisecond);
		}
		j := get(fpool.jobs, 0);
		ordered_remove(*fpool.jobs, 0);
		append(*fpool.inflight, j.client);
		locks.unlock(*fpool.mu);
		if !j.client.quit {
			body, file_status := j.body, 0;
			extra: []http.Header;
			if j.file != "" { body, extra, file_status = file_job_body(j.file, j.body); }
			ctype := ifx body != "" then "application/json" else "";
			r: Api_Response;
			if file_status == 0 { r = api_call(j.client, j.method, j.path, transmute([]u8, body), ctype, j.context_b64, extra, j.retries, 1); }
			res := Feature_Result.{op = j.op, tag = j.tag, channel_id = j.channel_id, ok = r.ok, status = r.status, body = r.body, arena = r.arena, client = j.client};
			if file_status != 0 { res.status = file_status; } // the file couldn't be read / is too large
			locks.lock(*fpool.mu);
			append(*fpool.results, res);
			locks.unlock(*fpool.mu);
			if j.client.cfg.wakeup != null { j.client.cfg.wakeup(j.client.cfg.wakeup_data); }
		}
		locks.lock(*fpool.mu);
		for x, i: fpool.inflight { if x == j.client {unordered_remove(*fpool.inflight, i); break;} }
		locks.unlock(*fpool.mu);
		delete(j.method);
		delete(j.path);
		delete(j.body);
		delete(j.context_b64);
		delete(j.file);
		free_all(temp);
	}
}
#scope_module

f_submit :: (c: *Client, j: F_Job) {
	context.allocator = runtime.heap_allocator();
	locks.lock(*fpool.mu);
	defer locks.unlock(*fpool.mu);
	fpool.owner = c; // the workers serve every client's jobs (j.client); they stop in extras_destroy
	if len(fpool.threads) == 0 {
		for _: 0..1 { append(*fpool.threads, thread.create_and_start_with_data(null, f_worker, c.ctx)); }
	}
	jj := j;
	jj.client = c;
	jj.method = clone(j.method);
	jj.path = clone(j.path);
	jj.body = clone(j.body);
	jj.context_b64 = clone(j.context_b64);
	jj.file = clone(j.file);
	append(*fpool.jobs, jj);
	locks.cond_signal(*fpool.cond);
}
#scope_export

// feature_submit queues a REST call whose result comes back through feature_take
// (for feature files outside this one). `file`: read and encoded on the worker.
feature_submit :: (c: *Client, op: Feature_Op, method: string, path: string, body := "", channel_id: Snowflake = 0, tag: u64 = 0, retries := 0, context_b64 := "", file := "") {
	f_submit(c, .{op = op, tag = tag, channel_id = channel_id, method = method, path = path, body = body, retries = retries, context_b64 = context_b64, file = file});
}

// feature_take returns finished feature requests (UI thread). Free each with feature_result_free.
feature_take :: (c: *Client, allocator := temp) -> []Feature_Result {
	locks.lock(*fpool.mu);
	defer locks.unlock(*fpool.mu);
	out := make_dynamic(Feature_Result, 0, len(fpool.results), allocator);
	k := 0;
	for r: fpool.results {
		if r.client == c || r.client == null {
			append(*out, r);
		} else {
			at(*fpool.results, k).* = r; // another client's (tests run several at once)
			k += 1;
		}
	}
	resize(*fpool.results, k);
	return view(out);
}

// feature_take_for: like feature_take, only the results of client c (tests run
// several clients at once; the others' results stay queued).
feature_take_for :: (c: *Client, allocator := temp) -> []Feature_Result {
	locks.lock(*fpool.mu);
	defer locks.unlock(*fpool.mu);
	out := make_dynamic(Feature_Result, 0, 0, allocator);
	{ i := 0;
	while i < len(fpool.results) {
		if __MAPIDX__(fpool.results|i).client == c {
			append(*out, get(fpool.results, i));
			ordered_remove(*fpool.results, i);
		} else {
			i += 1;
		}
	} }
	return view(out);
}

feature_result_free :: (r: *Feature_Result) {
	context.allocator = runtime.heap_allocator();
	if r.arena != null {
		virtual.arena_destroy(r.arena);
		free(r.arena);
		r.arena = null;
	}
}

// GET /channels/{id}/messages/pins?limit=25[&before=<pinned_at ISO>]
fetch_pins :: (c: *Client, channel_id: Snowflake, before_iso := "", tag: u64 = 0) {
	q: Query;
	query_init(*q, channel_path(channel_id, "/messages/pins"));
	query_add_int(*q, "limit", 25);
	if before_iso != "" { query_add(*q, "before", before_iso); }
	f_submit(c, .{op = .Pins, tag = tag, channel_id = channel_id, method = "GET", path = query_string(*q), retries = 2});
}

// POST /channels/{id}/pins/ack (no body).
ack_pins :: (c: *Client, channel_id: Snowflake) {
	f_submit(c, .{op = .Pins_Ack, channel_id = channel_id, method = "POST", path = channel_path(channel_id, "/pins/ack")});
}

// GET /channels/{id}/messages?limit=50&around={mid}; the page is merged into
// the channel's message list by apply_around (UI thread).
fetch_messages_around :: (c: *Client, channel_id: Snowflake, message_id: Snowflake, tag: u64 = 0) {
	q: Query;
	query_init(*q, channel_path(channel_id, "/messages"));
	query_add_int(*q, "limit", 30);
	query_add_snow(*q, "around", message_id);
	f_submit(c, .{op = .Around, tag = tag, channel_id = channel_id, method = "GET", path = query_string(*q), retries = 2});
}

apply_around :: (c: *Client, r: *Feature_Result) {
	if !r.ok { return; }
	context.allocator = c.store.allocator;
	for mv: vlist(r.body) { upsert_message(*c.store, vmap(mv)); }
	c.store.changed += 1;
}

// POST /channels/{forum}/post-data {"thread_ids":[...]} (up to 10 per request, like the client).
fetch_forum_posts :: (c: *Client, forum_id: Snowflake, thread_ids: []Snowflake) {
	{ start := 0;
	while start < len(thread_ids) {
		w: Json;
		json_init(*w);
		json_obj(*w);
		json_key(*w, "thread_ids");
		json_arr(*w);
		for id: sub(thread_ids, start, min(start + 10, len(thread_ids))) { json_snowflake(*w, id); }
		json_arr_end(*w);
		json_obj_end(*w);
		f_submit(c, .{op = .Forum_Posts, channel_id = forum_id, method = "POST", path = channel_path(forum_id, "/post-data"), body = json_string(*w)});
		start += 10;
} }
}

// GET /channels/{forum}/threads/search?archived=true&sort_by=last_message_time&sort_order=desc&limit=25&tag_setting=match_some&offset=N
fetch_archived_forum_threads :: (c: *Client, forum_id: Snowflake, offset := 0) {
	q: Query;
	query_init(*q, channel_path(forum_id, "/threads/search"));
	query_add(*q, "archived", "true");
	query_add(*q, "sort_by", "last_message_time");
	query_add(*q, "sort_order", "desc");
	query_add_int(*q, "limit", 25);
	query_add(*q, "tag_setting", "match_some");
	query_add_int(*q, "offset", offset);
	f_submit(c, .{op = .Thread_Search, channel_id = forum_id, method = "GET", path = query_string(*q), retries = 2});
}

Search_Query :: struct {
	content: string;
	author_ids: []Snowflake;
	mentions: []Snowflake;
	has: []string; // link, embed, file, image, video, sound, sticker, poll, forward
	channel_ids: []Snowflake;
	pinned: bool;
	offset: int;
}

// GET /guilds/{id}/messages/search (guild) or /channels/{id}/messages/search (DMs):
// filter keys in the client's search-token order (author_id, mentions, has,
// channel_id, pinned), then content, then the default sort.
search_messages :: (c: *Client, guild_id: Snowflake, channel_id: Snowflake, sq: Search_Query, tag: u64 = 0) {
	q: Query;
	if guild_id != 0 {
		query_init(*q, strings.concatenate(.{"/guilds/", snowflake_string(guild_id), "/messages/search"}, temp));
	} else {
		query_init(*q, channel_path(channel_id, "/messages/search"));
	}
	for id: sq.author_ids { query_add_snow(*q, "author_id", id); }
	for id: sq.mentions { query_add_snow(*q, "mentions", id); }
	for h: sq.has { query_add(*q, "has", h); }
	for id: sq.channel_ids { query_add_snow(*q, "channel_id", id); }
	if sq.pinned { query_add(*q, "pinned", "true"); }
	if sq.content != "" { query_add(*q, "content", sq.content); }
	query_add(*q, "sort_by", "timestamp");
	query_add(*q, "sort_order", "desc");
	if sq.offset > 0 { query_add_int(*q, "offset", sq.offset); }
	f_submit(c, .{op = .Search, tag = tag, channel_id = channel_id, method = "GET", path = query_string(*q), retries = 0});
}

