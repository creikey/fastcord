// Inbox (recent mentions) and the channel threads browser. Bodies go to the UI
// through feature_take (see features.odin):
//
//   GET    /users/@me/mentions?limit=25&roles=true&everyone=true[&before=<id>]   (Inbox, Mentions tab)
//   DELETE /users/@me/mentions/{message_id}                                       (Inbox "x" on a mention)
//   GET    /channels/{id}/threads/search?archived=true&sort_by=last_message_time&sort_order=desc&limit=25&tag_setting=match_some&offset=N
//          (threads browser, first open per channel; same shape as the forum's archived list)
//   POST   /channels/{id}/threads {"name","type":11,"auto_archive_duration":4320,"location":"Thread Browser Toolbar"}
//   GET    /guilds/{id}/roles/member-counts                                      (Delete Thread confirm)
//
// Fixtures inbox and threads_browser (traffic/FEATURES_NEW.md).

// fetch_mentions: one page of recent mentions, newest first; before = 0 for the first page.
fetch_mentions :: (c: *Client, before: Snowflake = 0) {
	q: Query;
	query_init(*q, "/users/@me/mentions");
	query_add_int(*q, "limit", 25);
	query_add(*q, "roles", "true");
	query_add(*q, "everyone", "true");
	if before != 0 { query_add_snow(*q, "before", before); }
	f_submit(c, .{op = .Mentions, tag = cast(u64)(before), method = "GET", path = query_string(*q), retries = 2});
}

// MENTIONS_DUP_TAG marks the second, identical first-page request (dropped by the UI).
MENTIONS_DUP_TAG :: U64_MAX;

// open_mentions: the Mentions tab's first render asks for the first page twice
// in the same millisecond (two components subscribe to the same store; fixture
// inbox open_inbox). Only the first reply carries the list.
open_mentions :: (c: *Client) {
	fetch_mentions(c);
	q: Query;
	query_init(*q, "/users/@me/mentions");
	query_add_int(*q, "limit", 25);
	query_add(*q, "roles", "true");
	query_add(*q, "everyone", "true");
	f_submit(c, .{op = .Mentions, tag = MENTIONS_DUP_TAG, method = "GET", path = query_string(*q), retries = 2});
}

// delete_mention removes a message from the recent mentions list.
delete_mention :: (c: *Client, message_id: Snowflake) {
	path := strings.concatenate(string.["/users/@me/mentions/", snowflake_string(message_id)], temp);
	f_submit(c, .{op = .Mention_Delete, tag = cast(u64)(message_id), method = "DELETE", path = path});
}

// fetch_channel_threads: archived threads of a text channel, newest activity first.
// Apply the body with apply_forum_threads.
fetch_channel_threads :: (c: *Client, channel_id: Snowflake, offset := 0) {
	q: Query;
	query_init(*q, channel_path(channel_id, "/threads/search"));
	query_add(*q, "archived", "true");
	query_add(*q, "sort_by", "last_message_time");
	query_add(*q, "sort_order", "desc");
	query_add_int(*q, "limit", 25);
	query_add(*q, "tag_setting", "match_some");
	query_add_int(*q, "offset", offset);
	f_submit(c, .{op = .Thread_Browse, channel_id = channel_id, method = "GET", path = query_string(*q), retries = 2});
}

THREAD_AUTO_ARCHIVE_MINUTES :: 4320;

// create_thread: the thread browser's "Create" form (Enter). The reply (201) is
// the thread channel; the app opens it and sends the first message with
// location "thread_creation" (send_message).
create_thread :: (c: *Client, parent_id: Snowflake, name: string, location := "Thread Browser Toolbar", tag: u64 = 0) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "name", name);
	json_kint(*w, "type", cast(s64)(Channel_Type.Public_Thread));
	json_kint(*w, "auto_archive_duration", THREAD_AUTO_ARCHIVE_MINUTES);
	json_kstr(*w, "location", location);
	json_obj_end(*w);
	f_submit(c, .{op = .Thread_Create, tag = tag, channel_id = parent_id, method = "POST", path = channel_path(parent_id, "/threads"), body = json_string(*w)});
}

// apply_created_thread puts the created thread (POST reply) into the store,
// ahead of its THREAD_CREATE, and returns its id.
apply_created_thread :: (c: *Client, body: V) -> Snowflake {
	m := vmap(body);
	if is_null(m) { return 0; }
	id := fsnow(m, "id");
	if id == 0 { return 0; }
	store_apply_dispatch(*c.store, "THREAD_CREATE", body, now_ms());
	extras_on_dispatch(c, "THREAD_CREATE", body);
	c.store.changed += 1;
	return id;
}

// fetch_role_member_counts: the Delete Thread / Delete Channel confirm loads
// the guild's role member counts (fixture threads_browser delete_thread).
fetch_role_member_counts :: (c: *Client, guild_id: Snowflake) {
	api_get_later(c, strings.concatenate(string.["/guilds/", snowflake_string(guild_id), "/roles/member-counts"], temp), 0);
}

// Every thread (any state we know of) under parent_id, newest activity first.
channel_threads :: (s: *Store, parent_id: Snowflake, allocator := temp) -> []Snowflake {
	out := make_dynamic(Snowflake, 0, 0, allocator);
	for tm, id: extras.threads {
		if tm.parent_id == parent_id && table_contains(*s.channels, id) { append(*out, id); }
	}
	Keyed :: struct {
		key, id: Snowflake;
	}
	keyed := make_slice(Keyed, len(out), temp);
	for id, i: out { _, tm := table_find(*extras.threads, id); keyed[i] = .{max(tm.last_message_id, id), id}; }
	for i: 1..len(keyed)-1 {
		{ j := i;
		while j > 0 && keyed[j].key > keyed[j - 1].key { swap(*keyed[j], *keyed[j - 1]);  j -= 1; } }
	}
	for k, i: keyed { at(*out, i).* = k.id; }
	return view(out);
}

