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
	// our thread member settings: flags (THREAD_NOTIFY_*), muted until mute_end_ms (0: until unmuted)
	member_flags: int;
	muted: bool;
	mute_end_ms: s64;
	applied_tags: [..]Snowflake;
	create_ts: string; // thread_metadata.create_timestamp
	last_message_id: Snowflake;
	// forum post previews (post-data / threads/search first_messages)
	first_author: Snowflake;
	first_content: string;
	first_media: string; // its first image or video attachment (proxy url), a media channel card's picture
	first_media_w, first_media_h: int;
}

// note_first_media: a post's first message's first image or video, for a media channel's grid. extras_mu is
// held; the side table's allocator.
note_first_media :: (tm: *Thread_Meta, msg: etf.Map) {
	free(tm.first_media);
	tm.first_media, tm.first_media_w, tm.first_media_h = "", 0, 0;
	for flist(msg, "attachments") {
		a := vmap(it);
		ct := fstr(a, "content_type");
		w, h := fint(a, "width"), fint(a, "height");
		url := ifx fstr(a, "proxy_url") then fstr(a, "proxy_url") else fstr(a, "url");
		if (!begins_with(ct, "image/") && !begins_with(ct, "video/")) || w <= 0 || h <= 0 || w > 16384 || h > 16384 || !url || url.count > 2048 continue;
		tm.first_media, tm.first_media_w, tm.first_media_h = copy_string(url), w, h;
		return;
	}
}

Forum_Tag :: struct {
	id: Snowflake;
	name: string;
	emoji_name: string;
	emoji_id: Snowflake;
	moderated: bool;
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
	store: *Store; // The connection it came on.
}

// Each Store keeps its own side tables (Store.extras), so two connections' ids never mix. Changes
// are serialized by Store.extras_mu, everything in them is on the heap (context.default_allocator),
// and store_destroy frees them (extras_destroy).
Extras :: struct {
	threads: Table(Snowflake, Thread_Meta);
	tags: Table(Snowflake, [..]Forum_Tag); // forum channel -> available_tags
	pins_epoch: Table(Snowflake, int); // bumped on CHANNEL_PINS_UPDATE
	new_msgs: [..]New_Message;
	my_roles: Table(Snowflake, [..]Snowflake); // guild -> our role ids
}

// ---- dispatch side (extras_mu held, heap allocator pushed) ----

note_thread :: (extras: *Extras, t: etf.Map, me: Snowflake) {
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
		if uid == 0 || uid == me note_thread_member(tm, mm);
	}
}

// Our thread member object (READY's, a thread's `member`, THREAD_MEMBER_UPDATE): joined, and its settings.
note_thread_member :: (tm: *Thread_Meta, mm: etf.Map) {
	tm.joined = true;
	if vhas(mm, "flags") tm.member_flags = fint(mm, "flags");
	if vhas(mm, "muted") tm.muted = fbool(mm, "muted");
	if vhas(mm, "mute_config") tm.mute_end_ms = iso_to_ms(fstr(fmap(mm, "mute_config"), "end_time"));
}

note_tags :: (extras: *Extras, ch: etf.Map) {
	if !vhas(ch, "available_tags") return;
	list := find_or_add(*extras.tags, fsnow(ch, "id"));
	for list.* {
		free(it.name);
		free(it.emoji_name);
	}
	list.count = 0;
	for flist(ch, "available_tags") {
		tm := vmap(it);
		array_add(list, .{id = fsnow(tm, "id"), name = copy_string(fstr(tm, "name")), emoji_name = copy_string(fstr(tm, "emoji_name")), emoji_id = fsnow(tm, "emoji_id"), moderated = fbool(tm, "moderated")});
	}
}

note_guild :: (extras: *Extras, g: etf.Map, me: Snowflake) {
	for flist(g, "channels") note_tags(extras, vmap(it));
	for flist(g, "threads") note_thread(extras, vmap(it), me);
	gid := fsnow(g, "id");
	for flist(g, "members") {
		mm := vmap(it);
		uid := fsnow(mm, "user_id");
		u := fmap(mm, "user");
		if u uid = fsnow(u, "id");
		if uid == me note_roles(extras, gid, flist(mm, "roles"));
	}
}

note_roles :: (extras: *Extras, gid: Snowflake, roles: []V) {
	list := find_or_add(*extras.my_roles, gid);
	list.count = 0;
	for roles array_add(list, vsnow(it));
}

note_joined :: (extras: *Extras, thread_id: Snowflake, joined := true) {
	tm := table_find_pointer(*extras.threads, thread_id);
	if tm tm.joined = joined;
}

note_message :: (extras: *Extras, s: *Store, d: etf.Map, me: Snowflake) {
	cid := fsnow(d, "channel_id");
	tm := table_find_pointer(*extras.threads, cid);
	if tm {
		mid := fsnow(d, "id");
		// a forum post's starter message shares the thread's id and isn't a reply
		if mid == cid {
			if !tm.first_content {
				tm.first_author = fsnow(fmap(d, "author"), "id");
				tm.first_content = copy_string(fstr(d, "content"));
				note_first_media(tm, d);
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
	free(tm.first_media);
}

// extras_on_dispatch: called by client_poll after the Store applied `name`.
extras_on_dispatch :: (c: *Client, name: string, data: V) { extras_dispatch(*c.store, c.allocator, name, data); }

// extras_dispatch: the same for a bare Store (offline fixtures).
extras_dispatch :: (s: *Store, allocator: Allocator, name: string, data: V) {
	locks.lock(*s.extras_mu);
	defer locks.unlock(*s.extras_mu);
	account_dispatch(s, allocator, name, data);
	push_allocator(context.default_allocator); // the side tables' allocator
	extras := *s.extras;
	me := s.me;
	d := vmap(data);
	events_dispatch(context.default_allocator, me, name, d);
	if name == {
		case "READY";
			guilds := flist(d, "guilds");
			for guilds note_guild(extras, vmap(it), me);
			// user READY: merged_members[i] holds our member object for guilds[i]
			for lv, i: flist(d, "merged_members") {
				if i >= guilds.count break;
				for vlist(lv) {
					mm := vmap(it);
					if fsnow(mm, "user_id") == me note_roles(extras, fsnow(vmap(guilds[i]), "id"), flist(mm, "roles"));
				}
			}
		case "GUILD_CREATE";
			note_guild(extras, d, me);
		case "CHANNEL_CREATE"; #through;
		case "CHANNEL_UPDATE";
			note_tags(extras, d);
		case "THREAD_CREATE"; #through;
		case "THREAD_UPDATE";
			note_thread(extras, d, me);
			// creating a thread (or being added on create) makes us a member
			if name == "THREAD_CREATE" && fsnow(d, "owner_id") == me note_joined(extras, fsnow(d, "id"));
		case "THREAD_LIST_SYNC";
			for flist(d, "threads") note_thread(extras, vmap(it), me);
			for flist(d, "members") {
				mm := vmap(it);
				if fsnow(mm, "user_id") != me continue;
				tm := table_find_pointer(*extras.threads, fsnow(mm, "id"));
				if tm note_thread_member(tm, mm);
			}
		case "THREAD_MEMBER_UPDATE";
			tm := table_find_pointer(*extras.threads, fsnow(d, "id"));
			if tm note_thread_member(tm, d);
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
			if fsnow(fmap(d, "user"), "id") == me note_roles(extras, fsnow(d, "guild_id"), flist(d, "roles"));
		case "MESSAGE_CREATE";
			note_message(extras, s, d, me);
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

// extras_destroy frees s's side tables and, when no client is left (feature_pool_release), stops
// the feature workers (called from store_destroy, after the client has set quit).
extras_destroy :: (s: *Store) {
	push_allocator(context.default_allocator);
	locks.lock(*s.extras_mu);
	extras := *s.extras;
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
	new_messages_free(null, extras.new_msgs);
	array_free(extras.new_msgs);
	for extras.my_roles array_free(it);
	deinit(*extras.my_roles);
	extras.* = .{};
	locks.unlock(*s.extras_mu);
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
}

// take_new_messages returns c's MESSAGE_CREATEs (from others) since the last call. Free with
// new_messages_free.
take_new_messages :: (c: *Client, allocator := temp) -> []New_Message {
	locks.lock(*c.store.extras_mu);
	defer locks.unlock(*c.store.extras_mu);
	out := array_copy(c.store.extras.new_msgs,, allocator);
	c.store.extras.new_msgs.count = 0;
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

thread_meta :: (s: *Store, id: Snowflake) -> *Thread_Meta { return table_find_pointer(*s.extras.threads, id); }

forum_tags :: (s: *Store, forum_id: Snowflake) -> []Forum_Tag {
	_, l := table_find(*s.extras.tags, forum_id);
	return l;
}

pins_epoch :: (s: *Store, channel_id: Snowflake) -> int {
	_, n := table_find(*s.extras.pins_epoch, channel_id);
	return n;
}

// my_guild_roles: our role ids in the guild (a temp copy).
my_guild_roles :: (s: *Store, guild_id: Snowflake) -> []Snowflake {
	locks.lock(*s.extras_mu);
	defer locks.unlock(*s.extras_mu);
	_, l := table_find(*s.extras.my_roles, guild_id);
	return array_copy(l,, temp);
}

is_thread :: (ch: *Channel) -> bool {
	return ch && (ch.kind == .Public_Thread || ch.kind == .Private_Thread || ch.kind == .Announcement_Thread);
}

// Active threads under parent_id we're a member of, oldest first (the sidebar's order).
joined_threads :: (s: *Store, parent_id: Snowflake, allocator := temp) -> []Snowflake {
	out: [..]Snowflake;
	out.allocator = allocator;
	for tm, id: s.extras.threads {
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
	for tm, id: s.extras.threads if tm.parent_id == forum_id array_add(*out, id);
	key :: (s: *Store, id: Snowflake) -> Snowflake {
		_, tm := table_find(*s.extras.threads, id);
		return max(tm.last_message_id, id);
	}
	for i: 1..out.count-1 {
		j := i;
		while j > 0 && key(s, out[j]) > key(s, out[j - 1]) {
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
		locks.lock(*s.extras_mu);
		note_thread(*s.extras, tmap, me,, context.default_allocator);
		locks.unlock(*s.extras_mu);
	}
	locks.lock(*s.extras_mu);
	for flist(m, "members") {
		mm := vmap(it);
		if fsnow(mm, "user_id") == me note_joined(*s.extras, fsnow(mm, "id"));
	}
	locks.unlock(*s.extras_mu);
	note_first :: (c: *Client, msg: etf.Map) {
		if !msg return;
		au := fmap(msg, "author");
		author := ifx au then parse_user_into(*c.store, au) else 0;
		locks.lock(*c.store.extras_mu);
		defer locks.unlock(*c.store.extras_mu);
		tm := table_find_pointer(*c.store.extras.threads, fsnow(msg, "channel_id"));
		if !tm return;
		if au tm.first_author = author;
		push_allocator(context.default_allocator); // the side table's
		free(tm.first_content);
		tm.first_content = copy_string(fstr(msg, "content"));
		note_first_media(tm, msg);
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
	Banner_Edit; // PATCH /users/%40me/profile {"banner"} from an image file
	User_Settings; // a User Settings page's load or change (tag: the page's request kind)
	Mfa_Finish; // POST /mfa/finish (account.jai mfa_finish)
	// guild_admin.jai (guild_admin_apply first)
	Event_Create;
	Event_Edit; // PATCH /guilds/{g}/scheduled-events/{id} (tag = event)
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
	Sound_Upload; // soundboard.jai
	Sound_Edit;
	Sound_Delete;
	Mark_Unread;
	Pin;
	Unpin;
	Reactors;
	Guild_Settings; // server_settings.jai
	Sticker_Upload;
	Channel_Order; // guild_admin.jai reorder_channels
	E2E_Bundle; // e2e_bundle_call
	Onboarding; // a server's own pages (view_onboarding.jai): its onboarding, guide and their answers; channel_id = guild
	Member_Verify; // the rules screen: GET /guilds/{id}/member-verification (tag 0), PUT /guilds/{id}/requests/@me (1)
}

// e2e_bundle_call: a hosted server's prekey bundles, PUT /users/@me/e2e-bundle or GET /users/{id}/e2e-bundle.
e2e_bundle_call :: (c: *Client, method: string, path: string, body := "", tag: u64 = 0) {
	f_submit(c, .{op = .E2E_Bundle, tag = tag, method = method, path = path, body = body});
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
	reason: string; // X-Audit-Log-Reason
	mfa_token: string; // X-Discord-MFA-Authorization: the retry after a multi-factor check (mfa_retry)
}

// f_job_copy: the job with its strings on the heap.
f_job_copy :: (j: F_Job) -> F_Job {
	push_allocator(context.default_allocator);
	jj := j;
	jj.method = copy_string(j.method);
	jj.path = copy_string(j.path);
	jj.body = copy_string(j.body);
	jj.context_b64 = copy_string(j.context_b64);
	jj.file = copy_string(j.file);
	jj.reason = copy_string(trim(j.reason));
	jj.mfa_token = copy_string(j.mfa_token);
	return jj;
}

f_job_free :: (j: *F_Job) {
	push_allocator(context.default_allocator);
	free(j.mfa_token);
	free(j.method);
	free(j.path);
	free(j.body);
	free(j.context_b64);
	free(j.file);
	free(j.reason);
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
	mfa_job: F_Job; // the last job a server answered with MFA_REQUIRED (mfa_retry sends it again)
	has_mfa_job: bool;
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
			if j.file body, extra, file_status = file_job_body(j.file, j.body, j.op, j.client.cfg.hosted.host != "");
			if j.reason {
				with := NewArray(extra.count + 1, http.Header,, temp);
				for extra with[it_index] = it;
				with[extra.count] = .{"x-audit-log-reason", uri_component(j.reason)};
				extra = with;
			}
			if j.mfa_token {
				with := NewArray(extra.count + 1, http.Header,, temp);
				for extra with[it_index] = it;
				with[extra.count] = .{"x-discord-mfa-authorization", j.mfa_token};
				extra = with;
			}
			r: Api_Response;
			ct := ifx j.op == .Sticker_Upload then multipart_type(body) else ifx body then "application/json" else "";
			if file_status == 0 r = api_call(j.client, j.method, j.path, cast([]u8) body, ct, j.context_b64, extra, j.retries, 1);
			res := Feature_Result.{op = j.op, tag = j.tag, channel_id = j.channel_id, ok = r.ok, status = r.status, body = r.body, arena = r.arena, client = j.client};
			if file_status != 0 res.status = file_status; // the file couldn't be read / is too large
			locks.lock(*fpool.mu);
			if mfa_required(*res) && !j.mfa_token {
				if fpool.has_mfa_job f_job_free(*fpool.mfa_job);
				fpool.mfa_job, fpool.has_mfa_job = f_job_copy(j), true;
			}
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
	jj := f_job_copy(j);
	jj.client = c;
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
// Thread membership (threads you join show in the sidebar and notify by their settings):
//   PUT / DELETE /channels/{id}/thread-members/@me                      Join Thread / Leave Thread
//   PATCH /channels/{id}/thread-members/@me/settings {"flags":4} or {"muted":true,"mute_config":{...}}
// The change shows at once; THREAD_MEMBER_UPDATE / THREAD_MEMBERS_UPDATE confirm it. No capture yet
// (traffic/CLIENT_RULES.md "Thread membership").
THREAD_NOTIFY_ALL :: 1 << 1;
THREAD_NOTIFY_MENTIONS :: 1 << 2;
THREAD_NOTIFY_NOTHING :: 1 << 3;

thread_join :: (c: *Client, thread_id: Snowflake, join: bool) {
	locks.lock(*c.store.extras_mu);
	note_joined(*c.store.extras, thread_id, join);
	locks.unlock(*c.store.extras_mu);
	c.store.changed += 1;
	f_submit(c, .{op = .Guild_Aux, channel_id = thread_id, method = ifx join then "PUT" else "DELETE", path = channel_path(thread_id, "/thread-members/@me")});
}

// level: 0 all messages, 1 only @mentions, 2 nothing (the menus' NOTIFY_NAMES order).
thread_set_notify :: (c: *Client, thread_id: Snowflake, level: int) {
	locks.lock(*c.store.extras_mu);
	tm := table_find_pointer(*c.store.extras.threads, thread_id);
	flags := 0;
	if tm {
		tm.member_flags = (tm.member_flags & ~(THREAD_NOTIFY_ALL | THREAD_NOTIFY_MENTIONS | THREAD_NOTIFY_NOTHING)) | (THREAD_NOTIFY_ALL << clamp(level, 0, 2));
		flags = tm.member_flags;
	}
	locks.unlock(*c.store.extras_mu);
	f_submit(c, .{op = .Guild_Aux, channel_id = thread_id, method = "PATCH", path = channel_path(thread_id, "/thread-members/@me/settings"), body = tprint("{\"flags\":%}", flags)});
}

// seconds: how long (MUTE_FOREVER: until unmuted); muted false unmutes.
thread_set_muted :: (c: *Client, thread_id: Snowflake, muted: bool, seconds := 0, now_ms: s64 = 0) {
	end: s64 = ifx muted && seconds != MUTE_FOREVER then now_ms + seconds * 1000 else 0;
	locks.lock(*c.store.extras_mu);
	tm := table_find_pointer(*c.store.extras.threads, thread_id);
	if tm tm.muted, tm.mute_end_ms = muted, end;
	locks.unlock(*c.store.extras_mu);
	body := ifx !muted then "{\"muted\":false}"
		else tprint("{\"muted\":true,\"mute_config\":{\"selected_time_window\":%,\"end_time\":%}}", seconds, ifx end then tprint("\"%\"", ms_to_iso(end)) else "null");
	f_submit(c, .{op = .Guild_Aux, channel_id = thread_id, method = "PATCH", path = channel_path(thread_id, "/thread-members/@me/settings"), body = body});
}

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
fetch_messages_around :: (c: *Client, channel_id: Snowflake, message_id: Snowflake) {
	q: Query;
	query_init(*q, channel_path(channel_id, "/messages"));
	query_add_int(*q, "limit", 30);
	query_add_snow(*q, "around", message_id);
	f_submit(c, .{op = .Around, tag = message_id, channel_id = channel_id, method = "GET", path = query_string(*q), retries = 2});
}

apply_around :: (c: *Client, r: *Feature_Result) {
	push_allocator(c.store.allocator);
	if !r.ok {
		message_list(*c.store, r.channel_id).failed = true; // "Messages Failed To Load"
		c.store.changed += 1;
		return;
	}
	// The official fetchMessages' hasMoreBefore / hasMoreAfter for an around page (limit 30): the
	// target's index among the page's ids decides whether older and newer messages remain.
	l := message_list(*c.store, r.channel_id);
	target := cast(Snowflake) r.tag;
	items := vlist(r.body);
	lo, hi := target, target;
	i := 0; // the target's index, ascending
	for items {
		id := fsnow(vmap(it), "id");
		lo, hi = min(lo, id), max(hi, id);
		if id < target i += 1;
	}
	LIMIT :: 30;
	more_before := i >= LIMIT / 2 + LIMIT % 2 - 1;
	ch := channel_get(*c.store, r.channel_id);
	more_after := items.count - i >= LIMIT / 2 && !(ch && hi == ch.last_message_id);
	// Keep one jumped stretch at most: a page reaching the stored present joins it, else the old stretch goes
	present := present_oldest(l);
	reaches := present && hi >= present;
	if !reaches || lo > l.gap_after drop_jumped_stretch(*c.store, l);
	for items upsert_message(*c.store, vmap(it));
	if reaches {
		l.gap_after = 0;
	} else {
		l.gap_after = ifx present || more_after then hi else 0;
		l.has_more_before = more_before;
	}
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
	min_id: Snowflake; // after: / during: (0 = none)
	max_id: Snowflake; // before: / during:
	offset: int;
	sort: Search_Sort;
}

Search_Sort :: enum u8 { Newest; Oldest; Most_Relevant; }

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
	if sq.min_id query_add_snow(*q, "min_id", sq.min_id);
	if sq.max_id query_add_snow(*q, "max_id", sq.max_id);
	if sq.content query_add(*q, "content", sq.content);
	// the client's sort options: relevance / desc, timestamp / asc, timestamp / desc
	query_add(*q, "sort_by", ifx sq.sort == .Most_Relevant then "relevance" else "timestamp");
	query_add(*q, "sort_order", ifx sq.sort == .Oldest then "asc" else "desc");
	if sq.offset > 0 query_add_int(*q, "offset", sq.offset);
	f_submit(c, .{op = .Search, tag = tag, channel_id = channel_id, method = "GET", path = query_string(*q), retries = 0});
}
