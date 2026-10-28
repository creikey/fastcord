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
//   PUT / DELETE /channels/{id}/messages/pins/{mid}              (ChannelPinsActionCreators.pinMessage / unpinMessage)
//   POST /channels/{id}/messages/{mid}/ack {manual, mention_count} (markUnread)
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
	webhook_name: string; // The name a webhook post went out under.
	mentions_me: bool;
	mention_everyone: bool;
	mention_roles: [..]Snowflake;
	attachments: int;
	embeds: int;
	sticker: bool;
	store: *Store; // The connection it came on; take_new_messages hands each client only its own.
}

// The side tables are process-wide (the app runs one client). Several clients
// at once (the parallel offline tests) share them: changes are serialized by
// extras_mu, everything in them is on the heap (context.default_allocator, not
// one client's), and they are freed when the last client goes (extras_destroy).
Extras :: struct {
	threads: Table(Snowflake, Thread_Meta);
	tags: Table(Snowflake, [..]Forum_Tag); // forum channel -> available_tags
	pins_epoch: Table(Snowflake, int); // bumped on CHANNEL_PINS_UPDATE
	new_msgs: [..]New_Message;
	my_roles: Table(Snowflake, [..]Snowflake); // guild -> our role ids
}

extras: Extras;
extras_mu: locks.Mutex;
extras_clients: int;

// ---- dispatch side (extras_mu held, heap allocator pushed) ----

note_thread :: (t: etf.Map, me: Snowflake) {
	id := fsnow(t, "id");
	if id == 0 return;
	tm, added := find_or_add(*extras.threads, id);
	if added tm.id = id;
	if vhas(t, "parent_id") tm.parent_id = fsnow(t, "parent_id");
	if vhas(t, "owner_id") tm.owner_id = fsnow(t, "owner_id");
	if vhas(t, "message_count") tm.message_count = fint(t, "message_count");
	if vhas(t, "member_count") tm.member_count = fint(t, "member_count");
	if vhas(t, "last_message_id") tm.last_message_id = fsnow(t, "last_message_id");
	md := fmap(t, "thread_metadata");
	if md {
		tm.archived = fbool(md, "archived");
		tm.locked = fbool(md, "locked");
		if vhas(md, "auto_archive_duration") tm.auto_archive_minutes = fint(md, "auto_archive_duration");
		ts := fstr(md, "create_timestamp");
		if ts && !tm.create_ts tm.create_ts = copy_string(ts);
	}
	if vhas(t, "applied_tags") {
		tm.applied_tags.count = 0;
		for flist(t, "applied_tags") array_add(*tm.applied_tags, vsnow(it));
	}
	mm := fmap(t, "member");
	if mm {
		uid := fsnow(mm, "user_id");
		if uid == 0 || uid == me tm.joined = true;
	}
}

note_tags :: (ch: etf.Map) {
	if !vhas(ch, "available_tags") return;
	list := find_or_add(*extras.tags, fsnow(ch, "id"));
	for list.* {
		free(it.name);
		free(it.emoji_name);
	}
	list.count = 0;
	for flist(ch, "available_tags") {
		tm := vmap(it);
		array_add(list, .{id = fsnow(tm, "id"), name = copy_string(fstr(tm, "name")), emoji_name = copy_string(fstr(tm, "emoji_name")), emoji_id = fsnow(tm, "emoji_id")});
	}
}

note_guild :: (g: etf.Map, me: Snowflake) {
	for flist(g, "channels") note_tags(vmap(it));
	for flist(g, "threads") note_thread(vmap(it), me);
	gid := fsnow(g, "id");
	for flist(g, "members") {
		mm := vmap(it);
		uid := fsnow(mm, "user_id");
		u := fmap(mm, "user");
		if u uid = fsnow(u, "id");
		if uid == me note_roles(gid, flist(mm, "roles"));
	}
}

note_roles :: (gid: Snowflake, roles: []V) {
	list := find_or_add(*extras.my_roles, gid);
	list.count = 0;
	for roles array_add(list, vsnow(it));
}

note_joined :: (thread_id: Snowflake, joined := true) {
	tm := table_find_pointer(*extras.threads, thread_id);
	if tm tm.joined = joined;
}

note_message :: (s: *Store, d: etf.Map, me: Snowflake) {
	cid := fsnow(d, "channel_id");
	tm := table_find_pointer(*extras.threads, cid);
	if tm {
		mid := fsnow(d, "id");
		// a forum post's starter message shares the thread's id and isn't a reply
		if mid == cid {
			if !tm.first_content {
				tm.first_author = fsnow(fmap(d, "author"), "id");
				tm.first_content = copy_string(fstr(d, "content"));
			}
		} else {
			tm.message_count += 1;
		}
		tm.last_message_id = mid;
	}
	aid := fsnow(fmap(d, "author"), "id");
	if aid == me || aid == 0 || extras.new_msgs.count >= 256 return;
	nm := array_add(*extras.new_msgs);
	nm.* = .{
		id = fsnow(d, "id"),
		channel_id = cid,
		guild_id = fsnow(d, "guild_id"),
		author_id = aid,
		kind = fint(d, "type"),
		flags = cast(u64) fint(d, "flags"),
		content = copy_string(fstr(d, "content")),
		mention_everyone = fbool(d, "mention_everyone"),
		attachments = flist(d, "attachments").count,
		embeds = flist(d, "embeds").count,
		sticker = flist(d, "sticker_items").count > 0,
		store = s
	};
	for flist(d, "mentions") if fsnow(vmap(it), "id") == me nm.mentions_me = true;
	for flist(d, "mention_roles") array_add(*nm.mention_roles, vsnow(it));
	if vhas(d, "webhook_id") {
		au := fmap(d, "author");
		nm.webhook_name = copy_string(ifx fstr(au, "global_name") then fstr(au, "global_name") else fstr(au, "username"));
	}
}

free_thread_meta :: (tm: *Thread_Meta) {
	array_free(tm.applied_tags);
	free(tm.create_ts);
	free(tm.first_content);
}

// extras_on_dispatch: called by client_poll after the Store applied `name`.
extras_on_dispatch :: (c: *Client, name: string, data: V) { extras_dispatch(*c.store, c.allocator, name, data); }

extras_retain :: () {
	locks.lock(*extras_mu);
	extras_clients += 1;
	locks.unlock(*extras_mu);
}

// extras_release: c is going away (client_destroy, before store_destroy). Its
// feature jobs were already ended by feature_pool_release.
extras_release :: (c: *Client) {
	locks.lock(*extras_mu);
	if extras_clients > 0 extras_clients -= 1;
	push_allocator(context.default_allocator);
	for extras.new_msgs if it.store == *c.store {
		free(it.content);
		free(it.webhook_name);
		array_free(it.mention_roles);
		remove it;
	}
	locks.unlock(*extras_mu);
}

// extras_dispatch: the same for a bare Store (offline fixtures).
extras_dispatch :: (s: *Store, allocator: Allocator, name: string, data: V) {
	locks.lock(*extras_mu);
	defer locks.unlock(*extras_mu);
	account_dispatch(s, allocator, name, data);
	push_allocator(context.default_allocator); // the side tables are shared by every live client
	me := s.me;
	d := vmap(data);
	events_dispatch(context.default_allocator, me, name, d);
	if name == {
		case "READY";
			guilds := flist(d, "guilds");
			for guilds note_guild(vmap(it), me);
			// user READY: merged_members[i] holds our member object for guilds[i]
			for lv, i: flist(d, "merged_members") {
				if i >= guilds.count break;
				for vlist(lv) {
					mm := vmap(it);
					if fsnow(mm, "user_id") == me note_roles(fsnow(vmap(guilds[i]), "id"), flist(mm, "roles"));
				}
			}
		case "GUILD_CREATE";
			note_guild(d, me);
		case "CHANNEL_CREATE"; #through;
		case "CHANNEL_UPDATE";
			note_tags(d);
		case "THREAD_CREATE"; #through;
		case "THREAD_UPDATE";
			note_thread(d, me);
			// creating a thread (or being added on create) makes us a member
			if name == "THREAD_CREATE" && fsnow(d, "owner_id") == me note_joined(fsnow(d, "id"));
		case "THREAD_LIST_SYNC";
			for flist(d, "threads") note_thread(vmap(it), me);
			for flist(d, "members") {
				mm := vmap(it);
				if fsnow(mm, "user_id") == me note_joined(fsnow(mm, "id"));
			}
		case "THREAD_MEMBER_UPDATE";
			note_joined(fsnow(d, "id"));
		case "THREAD_MEMBERS_UPDATE";
			tm := table_find_pointer(*extras.threads, fsnow(d, "id"));
			if tm {
				if vhas(d, "member_count") tm.member_count = fint(d, "member_count");
				for flist(d, "added_members") if fsnow(vmap(it), "user_id") == me tm.joined = true;
				for flist(d, "removed_member_ids") if vsnow(it) == me tm.joined = false;
			}
		case "THREAD_DELETE";
			found, tm := table_remove(*extras.threads, fsnow(d, "id"));
			if found free_thread_meta(*tm);
		case "CHANNEL_PINS_UPDATE";
			find_or_add(*extras.pins_epoch, fsnow(d, "channel_id")).* += 1;
		case "GUILD_MEMBER_UPDATE";
			if fsnow(fmap(d, "user"), "id") == me note_roles(fsnow(d, "guild_id"), flist(d, "roles"));
		case "MESSAGE_CREATE";
			note_message(s, d, me);
	}
}

// feature_pool_retain / feature_pool_release: client_create / client_destroy.
// Release drops the client's queued jobs and unread results and waits for its
// running ones, so other live clients keep the pool and the side tables.
feature_pool_retain :: (c: *Client) {
	locks.lock(*fpool.mu);
	fpool.clients += 1;
	locks.unlock(*fpool.mu);
}

feature_pool_release :: (c: *Client) {
	locks.lock(*fpool.mu);
	fpool.clients -= 1;
	if fpool.owner == c fpool.owner = null;
	i := 0;
	while i < fpool.jobs.count {
		if fpool.jobs[i].client != c {
			i += 1;
			continue;
		}
		f_job_free(*fpool.jobs[i]);
		array_ordered_remove_by_index(*fpool.jobs, i);
	}
	i = 0;
	while i < fpool.results.count {
		if fpool.results[i].client != c {
			i += 1;
			continue;
		}
		feature_result_free(*fpool.results[i]);
		array_ordered_remove_by_index(*fpool.results, i);
	}
	locks.cond_broadcast(*fpool.cond);
	while array_find(fpool.inflight, c) {
		locks.unlock(*fpool.mu);
		sleep_milliseconds(2);
		locks.lock(*fpool.mu);
	}
	locks.unlock(*fpool.mu);
}

// extras_destroy frees the side tables and stops the feature workers (called
// from store_destroy, after the client has set quit). Nothing while another
// client is alive (feature_pool_release).
extras_destroy :: () {
	push_allocator(context.default_allocator);
	locks.lock(*extras_mu);
	defer locks.unlock(*extras_mu);
	if extras_clients > 0 return; // another client still uses them
	locks.lock(*fpool.mu);
	if fpool.clients > 0 {
		locks.unlock(*fpool.mu);
		return;
	}
	threads := fpool.threads;
	fpool.threads.count = 0; // the workers stop; threads keeps the array until fpool is reset below
	fpool.owner = null;
	locks.cond_broadcast(*fpool.cond);
	locks.unlock(*fpool.mu);
	for threads locks.join(it);
	array_free(threads);
	for * fpool.jobs f_job_free(it);
	array_free(fpool.jobs);
	for * fpool.results feature_result_free(it);
	array_free(fpool.results);
	array_free(fpool.inflight);
	fpool = .{};
	events_destroy();

	for * extras.threads free_thread_meta(it);
	deinit(*extras.threads);
	for list: extras.tags {
		for list {
			free(it.name);
			free(it.emoji_name);
		}
		array_free(list);
	}
	deinit(*extras.tags);
	deinit(*extras.pins_epoch);
	for extras.new_msgs {
		free(it.content);
		free(it.webhook_name);
		array_free(it.mention_roles);
	}
	array_free(extras.new_msgs);
	for extras.my_roles array_free(it);
	deinit(*extras.my_roles);
	extras = .{};
}

// take_new_messages returns c's MESSAGE_CREATEs (from others) since the last call; other
// connections' stay queued for them. Free with new_messages_free.
take_new_messages :: (c: *Client, allocator := temp) -> []New_Message {
	locks.lock(*extras_mu);
	defer locks.unlock(*extras_mu);
	out: [..]New_Message;
	out.allocator = allocator;
	k := 0;
	for extras.new_msgs {
		if it.store == *c.store {
			array_add(*out, it);
		} else {
			extras.new_msgs[k] = it;
			k += 1;
		}
	}
	extras.new_msgs.count = k;
	return out;
}

new_messages_free :: (c: *Client, msgs: []New_Message) {
	push_allocator(context.default_allocator); // they were the side table's
	for msgs {
		free(it.content);
		free(it.webhook_name);
		array_free(it.mention_roles);
	}
}

thread_meta :: (id: Snowflake) -> *Thread_Meta { return table_find_pointer(*extras.threads, id); }

forum_tags :: (forum_id: Snowflake) -> []Forum_Tag {
	_, l := table_find(*extras.tags, forum_id);
	return l;
}

pins_epoch :: (channel_id: Snowflake) -> int {
	_, n := table_find(*extras.pins_epoch, channel_id);
	return n;
}

// my_guild_roles: our role ids in the guild (a temp copy).
my_guild_roles :: (guild_id: Snowflake) -> []Snowflake {
	locks.lock(*extras_mu);
	defer locks.unlock(*extras_mu);
	_, l := table_find(*extras.my_roles, guild_id);
	return array_copy(l,, temp);
}

is_thread :: (ch: *Channel) -> bool {
	return ch && (ch.kind == .Public_Thread || ch.kind == .Private_Thread || ch.kind == .Announcement_Thread);
}

// Active threads under parent_id we're a member of, oldest first (the sidebar's order).
joined_threads :: (s: *Store, parent_id: Snowflake, allocator := temp) -> []Snowflake {
	out: [..]Snowflake;
	out.allocator = allocator;
	for tm, id: extras.threads {
		if tm.parent_id == parent_id && tm.joined && !tm.archived && table_contains(*s.channels, id) array_add(*out, id);
	}
	for i: 1..out.count-1 {
		j := i;
		while j > 0 && out[j] < out[j - 1] {
			swap(*out[j], *out[j - 1]);
			j -= 1;
		}
	}
	return out;
}

// Threads (any state we know of) whose parent is the forum, newest activity first.
forum_threads :: (s: *Store, forum_id: Snowflake, allocator := temp) -> []Snowflake {
	out: [..]Snowflake;
	out.allocator = allocator;
	for tm, id: extras.threads if tm.parent_id == forum_id array_add(*out, id);
	key :: (id: Snowflake) -> Snowflake {
		_, tm := table_find(*extras.threads, id);
		return max(tm.last_message_id, id);
	}
	for i: 1..out.count-1 {
		j := i;
		while j > 0 && key(out[j]) > key(out[j - 1]) {
			swap(*out[j], *out[j - 1]);
			j -= 1;
		}
	}
	return out;
}

// Applies forum post bodies (post-data / threads/search) to the side tables and Store.
apply_forum_threads :: (c: *Client, body: V) {
	s := *c.store;
	m := vmap(body);
	me := s.me;
	// threads/search: {threads:[...], members:[...], first_messages:[...]}
	for flist(m, "threads") {
		tmap := vmap(it);
		cid := parse_channel_into(s, tmap, fsnow(tmap, "guild_id"));
		g := table_find_pointer(*s.guilds, fsnow(tmap, "guild_id"));
		if g && cid != 0 && !array_find(g.channels, cid) array_add(*g.channels, cid);
		locks.lock(*extras_mu);
		note_thread(tmap, me,, context.default_allocator);
		locks.unlock(*extras_mu);
	}
	locks.lock(*extras_mu);
	for flist(m, "members") {
		mm := vmap(it);
		if fsnow(mm, "user_id") == me note_joined(fsnow(mm, "id"));
	}
	locks.unlock(*extras_mu);
	note_first :: (c: *Client, msg: etf.Map) {
		if !msg return;
		au := fmap(msg, "author");
		author := ifx au then parse_user_into(*c.store, au) else 0;
		locks.lock(*extras_mu);
		defer locks.unlock(*extras_mu);
		tm := table_find_pointer(*extras.threads, fsnow(msg, "channel_id"));
		if !tm return;
		if au tm.first_author = author;
		push_allocator(context.default_allocator); // the side table's
		free(tm.first_content);
		tm.first_content = copy_string(fstr(msg, "content"));
	}
	for flist(m, "first_messages") note_first(c, vmap(it));
	// post-data: {threads: {"<id>": {first_message: {...}, owner: {...}}}}
	for fmap(m, "threads") note_first(c, fmap(vmap(it.value), "first_message"));
}

// Parses a REST message object without inserting it into the channel's list
// (search results, pins): authors are added to the Store.
parse_loose_message :: (s: *Store, m: etf.Map, allocator := temp) -> Message {
	msg := Message.{
		id = fsnow(m, "id"),
		channel_id = fsnow(m, "channel_id"),
		kind = fint(m, "type"),
		content = copy_string(fstr(m, "content"),, allocator),
		timestamp = copy_string(fstr(m, "timestamp"),, allocator),
		flags = cast(u64) fint(m, "flags")
	};
	au := fmap(m, "author");
	if au msg.author_id = parse_user_into(s, au);
	msg.attachments.allocator, msg.embeds.allocator, msg.sticker_ids.allocator = allocator, allocator, allocator;
	for flist(m, "attachments") array_add(*msg.attachments, parse_attachment(vmap(it), allocator));
	for flist(m, "embeds") array_add(*msg.embeds, parse_embed(vmap(it), allocator));
	items := flist(m, "sticker_items");
	for items array_add(*msg.sticker_ids, fsnow(vmap(it), "id"));
	note_sticker_items(s, items);
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
	Thread_Browse; // inbox.jai
	Mentions;
	Mention_Delete;
	Thread_Create;
	User_Patch; // account.jai
	Profile_Patch;
	// guild_admin.jai (guild_admin_apply first)
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
	Guild_Edit;
	Avatar_Edit;
	Emoji_Upload;
	Mark_Unread;
	Pin;
	Unpin;
	Reactors;
}

Feature_Result :: struct {
	op: Feature_Op;
	tag: u64;
	channel_id: Snowflake;
	ok: bool;
	status: int;
	body: V;
	arena: *Flat_Pool;
	client: *Client; // the client that submitted it
}

// F_Job: one queued feature request; f_submit copies its strings to the heap.
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

f_job_free :: (j: *F_Job) {
	push_allocator(context.default_allocator);
	free(j.method);
	free(j.path);
	free(j.body);
	free(j.context_b64);
	free(j.file);
}

// The feature pool outlives the client that started it: its threads, jobs and
// results are on the heap.
F_Pool :: struct {
	mu: locks.Mutex;
	cond: locks.Cond;
	jobs: [..]F_Job;
	results: [..]Feature_Result;
	threads: [..]*Thread;
	owner: *Client;
	clients: int; // live clients (tests run several at once); the pool and side tables outlive all but the last
	inflight: [..]*Client; // clients of the jobs being run now
}

fpool: F_Pool;

f_worker :: (_: *void) {
	context.allocator = context.default_allocator;
	while true {
		locks.lock(*fpool.mu);
		while !fpool.jobs {
			// stop only in extras_destroy (no live client): a test client going
			// away must not take the workers from the clients still running
			if !fpool.threads {
				locks.unlock(*fpool.mu);
				return;
			}
			locks.cond_wait_with_timeout(*fpool.cond, *fpool.mu, 500);
		}
		j := fpool.jobs[0];
		array_ordered_remove_by_index(*fpool.jobs, 0);
		array_add(*fpool.inflight, j.client);
		locks.unlock(*fpool.mu);
		if !j.client.quit {
			body, file_status := j.body, 0;
			extra: []http.Header;
			if j.file body, extra, file_status = file_job_body(j.file, j.body, j.op);
			r: Api_Response;
			if file_status == 0 r = api_call(j.client, j.method, j.path, cast([]u8) body, ifx body then "application/json" else "", j.context_b64, extra, j.retries, 1);
			res := Feature_Result.{op = j.op, tag = j.tag, channel_id = j.channel_id, ok = r.ok, status = r.status, body = r.body, arena = r.arena, client = j.client};
			if file_status != 0 res.status = file_status; // the file couldn't be read / is too large
			locks.lock(*fpool.mu);
			array_add(*fpool.results, res);
			locks.unlock(*fpool.mu);
			if j.client.cfg.wakeup j.client.cfg.wakeup(j.client.cfg.wakeup_data);
		}
		locks.lock(*fpool.mu);
		found, i := array_find(fpool.inflight, j.client);
		if found array_unordered_remove_by_index(*fpool.inflight, i);
		locks.unlock(*fpool.mu);
		f_job_free(*j);
		reset_temporary_storage();
	}
}

f_submit :: (c: *Client, j: F_Job) {
	push_allocator(context.default_allocator);
	locks.lock(*fpool.mu);
	defer locks.unlock(*fpool.mu);
	fpool.owner = c; // the workers serve every client's jobs (j.client); they stop in extras_destroy
	if !fpool.threads for 1..2 array_add(*fpool.threads, spawn(null, f_worker));
	jj := j;
	jj.client = c;
	jj.method = copy_string(j.method);
	jj.path = copy_string(j.path);
	jj.body = copy_string(j.body);
	jj.context_b64 = copy_string(j.context_b64);
	jj.file = copy_string(j.file);
	array_add(*fpool.jobs, jj);
	locks.cond_signal(*fpool.cond);
}

// feature_submit queues a REST call whose result comes back through feature_take
// (for feature files outside this one). `file`: read and encoded on the worker.
feature_submit :: (c: *Client, op: Feature_Op, method: string, path: string, body := "", channel_id: Snowflake = 0, tag: u64 = 0, retries := 0, context_b64 := "", file := "") {
	f_submit(c, .{op = op, tag = tag, channel_id = channel_id, method = method, path = path, body = body, retries = retries, context_b64 = context_b64, file = file});
}

// feature_take returns finished feature requests (UI thread). Free each with feature_result_free.
feature_take :: (c: *Client, allocator := temp) -> []Feature_Result {
	locks.lock(*fpool.mu);
	defer locks.unlock(*fpool.mu);
	out: [..]Feature_Result;
	out.allocator = allocator;
	k := 0;
	for fpool.results {
		if it.client == c || !it.client {
			array_add(*out, it);
		} else {
			fpool.results[k] = it; // another client's (tests run several at once)
			k += 1;
		}
	}
	fpool.results.count = k;
	return out;
}

// feature_take_for: like feature_take, only the results of client c (tests run
// several clients at once; the others' results stay queued).
feature_take_for :: (c: *Client, allocator := temp) -> []Feature_Result {
	locks.lock(*fpool.mu);
	defer locks.unlock(*fpool.mu);
	out: [..]Feature_Result;
	out.allocator = allocator;
	i := 0;
	while i < fpool.results.count {
		if fpool.results[i].client == c {
			array_add(*out, fpool.results[i]);
			array_ordered_remove_by_index(*fpool.results, i);
		} else {
			i += 1;
		}
	}
	return out;
}

feature_result_free :: (r: *Feature_Result) {
	if !r.arena return;
	fini(r.arena);
	free(r.arena,, context.default_allocator);
	r.arena = null;
}

// GET /channels/{id}/messages/pins?limit=25[&before=<pinned_at ISO>]
fetch_pins :: (c: *Client, channel_id: Snowflake, before_iso := "", tag: u64 = 0) {
	q: Query;
	query_init(*q, channel_path(channel_id, "/messages/pins"));
	query_add_int(*q, "limit", 25);
	if before_iso query_add(*q, "before", before_iso);
	f_submit(c, .{op = .Pins, tag = tag, channel_id = channel_id, method = "GET", path = query_string(*q), retries = 2});
}

// Who reacted: GET /channels/{c}/messages/{m}/reactions/{emoji}?limit=100[&after=<user id>]&type=0|1 (1 = super reactions).
fetch_reactors :: (c: *Client, channel_id: Snowflake, message_id: Snowflake, emoji_name: string, emoji_id: Snowflake, burst: bool, tag: u64, after: Snowflake = 0) {
	q: Query;
	query_init(*q, channel_path(channel_id, "/messages/", snowflake_string(message_id), "/reactions/", emoji_route(emoji_name, emoji_id)));
	query_add_int(*q, "limit", 100);
	if after query_add(*q, "after", snowflake_string(after));
	query_add_int(*q, "type", ifx burst then 1 else 0);
	f_submit(c, .{op = .Reactors, tag = tag, channel_id = channel_id, method = "GET", path = query_string(*q), retries = 1});
}

// A moderator removing someone's reaction: DELETE .../reactions/{emoji}/{0|1}/{user id}?burst=. The count
// follows from MESSAGE_REACTION_REMOVE.
remove_user_reaction :: (c: *Client, channel_id: Snowflake, message_id: Snowflake, emoji_name: string, emoji_id: Snowflake, burst: bool, user_id: Snowflake) {
	q: Query;
	query_init(*q, channel_path(channel_id, "/messages/", snowflake_string(message_id), "/reactions/", emoji_route(emoji_name, emoji_id), ifx burst then "/1/" else "/0/", snowflake_string(user_id)));
	query_add_bool(*q, "burst", burst);
	f_submit(c, .{op = .Guild_Aux, channel_id = channel_id, method = "DELETE", path = query_string(*q)});
}

// POST /channels/{id}/pins/ack (no body).
ack_pins :: (c: *Client, channel_id: Snowflake) {
	f_submit(c, .{op = .Pins_Ack, channel_id = channel_id, method = "POST", path = channel_path(channel_id, "/pins/ack")});
}

// PUT (pin) / DELETE (unpin) /channels/{id}/messages/pins/{mid}, no body. The message,
// the system message and the pins list follow from the gateway (MESSAGE_UPDATE,
// MESSAGE_CREATE type 6, CHANNEL_PINS_UPDATE).
pin_message :: (c: *Client, channel_id: Snowflake, message_id: Snowflake, pin: bool) {
	f_submit(c, .{op = ifx pin then Feature_Op.Pin else .Unpin, tag = message_id, channel_id = channel_id, method = ifx pin then "PUT" else "DELETE", path = channel_path(channel_id, "/messages/pins/", snowflake_string(message_id))});
}

// Mark Unread (markUnread): POST /channels/{id}/messages/{before}/ack {"manual":true,"mention_count":n}
// where before = the loaded message just older than message_id, else message_id's previous
// millisecond, and n = the loaded messages after it that would notify us. No token and no
// local change: the read state moves on the MESSAGE_ACK echo (manual).
mark_unread :: (c: *Client, channel_id: Snowflake, message_id: Snowflake) {
	before: Snowflake = ((message_id >> 22) - 1) << 22; // SnowflakeUtils.atPreviousMillisecond
	n := 0;
	l := table_find_pointer(*c.store.messages, channel_id);
	ch := channel_get(*c.store, channel_id);
	if l {
		for l.messages if it.id < message_id && !it.pending before = it.id; // ascending
		for l.messages {
			if it.id <= before || it.pending continue;
			if (ch && ch.guild_id == 0) || it.mention_everyone || array_find(it.mentions, c.store.me) n += 1; // private: every message
		}
	}
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kbool(*w, "manual", true);
	json_kint(*w, "mention_count", n);
	json_obj_end(*w);
	for c.pending_acks if it.channel_id == channel_id remove it; // clearOutgoingAck
	f_submit(c, .{op = .Mark_Unread, channel_id = channel_id, method = "POST", path = channel_path(channel_id, "/messages/", snowflake_string(before), "/ack"), body = json_string(*w)});
}

// GET /channels/{id}/messages?limit=30&around={mid}; the page is merged into
// the channel's message list by apply_around (UI thread).
fetch_messages_around :: (c: *Client, channel_id: Snowflake, message_id: Snowflake, tag: u64 = 0) {
	q: Query;
	query_init(*q, channel_path(channel_id, "/messages"));
	query_add_int(*q, "limit", 30);
	query_add_snow(*q, "around", message_id);
	f_submit(c, .{op = .Around, tag = tag, channel_id = channel_id, method = "GET", path = query_string(*q), retries = 2});
}

apply_around :: (c: *Client, r: *Feature_Result) {
	push_allocator(c.store.allocator);
	if !r.ok {
		message_list(*c.store, r.channel_id).failed = true; // "Messages Failed To Load"
		c.store.changed += 1;
		return;
	}
	for vlist(r.body) upsert_message(*c.store, vmap(it));
	c.store.changed += 1;
}

// POST /channels/{forum}/post-data {"thread_ids":[...]} (up to 10 per request, like the client).
fetch_forum_posts :: (c: *Client, forum_id: Snowflake, thread_ids: []Snowflake) {
	for start: 0..thread_ids.count-1 {
		if start % 10 continue;
		w: Json;
		json_init(*w);
		json_obj(*w);
		json_key(*w, "thread_ids");
		json_arr(*w);
		for array_view(thread_ids, start, min(10, thread_ids.count - start)) json_snowflake(*w, it);
		json_arr_end(*w);
		json_obj_end(*w);
		f_submit(c, .{op = .Forum_Posts, channel_id = forum_id, method = "POST", path = channel_path(forum_id, "/post-data"), body = json_string(*w)});
	}
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
	if guild_id != 0 query_init(*q, tprint("/guilds/%/messages/search", guild_id));
	else query_init(*q, channel_path(channel_id, "/messages/search"));
	for sq.author_ids query_add_snow(*q, "author_id", it);
	for sq.mentions query_add_snow(*q, "mentions", it);
	for sq.has query_add(*q, "has", it);
	for sq.channel_ids query_add_snow(*q, "channel_id", it);
	if sq.pinned query_add(*q, "pinned", "true");
	if sq.content query_add(*q, "content", sq.content);
	query_add(*q, "sort_by", "timestamp");
	query_add(*q, "sort_order", "desc");
	if sq.offset > 0 query_add_int(*q, "offset", sq.offset);
	f_submit(c, .{op = .Search, tag = tag, channel_id = channel_id, method = "GET", path = query_string(*q), retries = 0});
}
