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
	if before query_add_snow(*q, "before", before);
	f_submit(c, .{op = .Mentions, tag = before, method = "GET", path = query_string(*q), retries = 2});
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
	f_submit(c, .{op = .Mention_Delete, tag = message_id, method = "DELETE", path = tprint("/users/@me/mentions/%", message_id)});
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
// location "thread_creation" (send_message). With message_id it starts the thread
// from that message: POST /channels/{id}/messages/{mid}/threads, without a type.
create_thread :: (c: *Client, parent_id: Snowflake, name: string, location := "Thread Browser Toolbar", tag: u64 = 0, message_id: Snowflake = 0) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "name", name);
	if !message_id json_kint(*w, "type", cast(s64) Channel_Type.Public_Thread);
	json_kint(*w, "auto_archive_duration", THREAD_AUTO_ARCHIVE_MINUTES);
	json_kstr(*w, "location", location);
	json_obj_end(*w);
	f_submit(c, .{op = .Thread_Create, tag = tag, channel_id = parent_id, method = "POST", path = ifx message_id then channel_path(parent_id, "/messages/", snowflake_string(message_id), "/threads") else channel_path(parent_id, "/threads"), body = json_string(*w)});
}

// create_forum_post: a forum's new post, POST /channels/{forum}/threads {name, auto_archive_duration,
// applied_tags, message: {content}}; the reply is the post (a thread whose starter message shares its ID).
// No capture yet (traffic/CLIENT_RULES.md "Forum posts").
create_forum_post :: (c: *Client, forum_id: Snowflake, name: string, content: string, tags: []Snowflake, tag: u64) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "name", name);
	json_kint(*w, "auto_archive_duration", 4320);
	json_key(*w, "applied_tags");
	json_arr(*w);
	for tags json_snowflake(*w, it);
	json_arr_end(*w);
	json_key(*w, "message");
	json_obj(*w);
	json_kstr(*w, "content", content);
	json_obj_end(*w);
	json_obj_end(*w);
	f_submit(c, .{op = .Thread_Create, tag = tag, channel_id = forum_id, method = "POST", path = channel_path(forum_id, "/threads"), body = json_string(*w)});
}

// apply_created_thread puts the created thread (POST reply) into the store,
// ahead of its THREAD_CREATE, and returns its id.
apply_created_thread :: (c: *Client, body: V) -> Snowflake {
	id := fsnow(vmap(body), "id");
	if id == 0 return 0;
	store_apply_dispatch(*c.store, "THREAD_CREATE", body, now_ms());
	extras_on_dispatch(c, "THREAD_CREATE", body);
	c.store.changed += 1;
	return id;
}

// fetch_role_member_counts: the Delete Thread / Delete Channel confirm loads
// the guild's role member counts (fixture threads_browser delete_thread).
fetch_role_member_counts :: (c: *Client, guild_id: Snowflake) {
	api_get_later(c, tprint("/guilds/%/roles/member-counts", guild_id), 0);
}

// Every thread (any state we know of) under parent_id, newest activity first.
channel_threads :: (s: *Store, parent_id: Snowflake, allocator := temp) -> []Snowflake {
	Keyed :: struct { key, id: Snowflake; }
	keyed: [..]Keyed;
	keyed.allocator = temp;
	for tm, id: s.extras.threads {
		if tm.parent_id == parent_id && table_contains(*s.channels, id) array_add(*keyed, .{max(tm.last_message_id, id), id});
	}
	// insertion sort, newest first (stable)
	for i: 1..keyed.count-1 {
		j := i;
		while j > 0 && keyed[j].key > keyed[j - 1].key {
			keyed[j], keyed[j - 1] = keyed[j - 1], keyed[j];
			j -= 1;
		}
	}
	out := NewArray(keyed.count, Snowflake,, allocator);
	for keyed out[it_index] = it.id;
	return out;
}

