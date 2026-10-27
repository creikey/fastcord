FRIEND_NICKNAME_MAX :: 32;

// user_name: the name the client shows for a user (fixture friend_nickname, "Where
// the names show"):
//   in a guild (messages, member list, mentions, guild-opened profiles):
//     server nickname > global name > username; the friend nickname is ignored
//   everywhere else (DMs, group DMs, DM list, Friends, quick switcher, DM profile):
//     friend nickname > global name > username; the server nickname is ignored
// `unknown` is returned when nothing is known. One or two map lookups, no allocation.
user_name :: (s: *Store, uid: Snowflake, guild_id: Snowflake = 0, unknown := "") -> string {
	if guild_id != 0 {
		{ m := member_get(s, guild_id, uid);
		if m != null && m.nick != "" { return m.nick; } }
	} else { r, ok := map_find_ptr(*s.relationships, uid);
if ok && r.nickname != "" {
		return r.nickname;
	} }
	{ u := user_get(s, uid);
	if u != null { return display_name(u); } }
	return unknown;
}

// friend_nickname: the private nickname you gave this user ("" if none).
friend_nickname :: (s: *Store, uid: Snowflake) -> string {
	{ r, ok := map_find_ptr(*s.relationships, uid);
	if ok { return r.nickname; } }
	return "";
}

// store_set_friend_nickname: the optimistic, local half of set_friend_nickname.
store_set_friend_nickname :: (s: *Store, uid: Snowflake, nickname: string) {
	r, ok := map_find_ptr(*s.relationships, uid);
	if !ok { return; }
	free_str(r.nickname, s.allocator);
	r.nickname = clone_str(nickname, s.allocator);
	s.changed += 1;
}

// set_friend_nickname: PATCH /users/@me/relationships/{id} {"nickname":"…"}, or
// {"nickname":null} to clear it. Applied to the store now; RELATIONSHIP_UPDATE confirms.
set_friend_nickname :: (c: *Client, user_id: Snowflake, nickname: string) {
	nick := strings.trim_space(nickname);
	store_set_friend_nickname(*c.store, user_id, nick);
	w: Json;
	json_init(*w);
	json_obj(*w);
	if nick == "" { json_knull(*w, "nickname"); } else { json_kstr(*w, "nickname", nick); }
	json_obj_end(*w);
	j := job_new(.Api, .Relationship);
	j.method = "PATCH";
	j.path = job_str(j, strings.concatenate(.{"/users/@me/relationships/", snowflake_string(user_id)}, temp));
	j.body = transmute([]u8, job_str(j, json_string(*w)));
	j.content_type = "application/json";
	j.result.user_id = user_id;
	job_submit(c, j);
}

// ---- server nicknames ("Change Nickname" in a guild's user menu) ----

SERVER_NICKNAME_MAX :: 32;

// open_change_nickname: the "Change Server Identity" modal opened from the user menu.
open_change_nickname :: (c: *Client) {
	w := aw_begin();
	json_kstr(*w, "type", "Change Server Identity");
	json_kstr(*w, "location", "Guild Channel");
	json_kstr(*w, "source_page", "Guild Channel");
	json_kstr(*w, "source_section", "Chat Username");
	json_kstr(*w, "source_object", "Context Menu Item");
	aw_track(c, "open_modal", *w);
}

// store_set_server_nickname: the optimistic half of set_server_nickname.
store_set_server_nickname :: (s: *Store, guild_id: Snowflake, user_id: Snowflake, nick: string) {
	m := member_get(s, guild_id, user_id);
	if m == null { return; }
	free_str(m.nick, s.allocator);
	m.nick = clone_str(nick, s.allocator);
	s.changed += 1;
}

// set_server_nickname: PATCH /guilds/{g}/members/{id} {"nick":"…"} ("" clears it;
// fixture friend_nickname), or /members/@me for our own. GUILD_MEMBER_UPDATE confirms.
// Someone else's: moderation_action {action_type:"change_nickname"} once it succeeds.
set_server_nickname :: (c: *Client, guild_id: Snowflake, user_id: Snowflake, nickname: string) {
	nick := strings.trim_space(nickname);
	store_set_server_nickname(*c.store, guild_id, user_id, nick);
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "nick", nick);
	json_obj_end(*w);
	j := job_new(.Api, .None);
	j.method = "PATCH";
	who := ifx user_id == c.store.me then "@me" else snowflake_string(user_id);
	j.path = job_str(j, strings.concatenate(.{"/guilds/", snowflake_string(guild_id), "/members/", who}, temp));
	j.body = transmute([]u8, job_str(j, json_string(*w)));
	j.content_type = "application/json";
	if user_id != c.store.me {
		p := aw_begin();
		json_kstr(*p, "action_type", "change_nickname");
		json_ksnow(*p, "mod_user_id", c.store.me);
		json_ksnow(*p, "guild_id", guild_id);
		json_ksnow(*p, "target_user_id", user_id);
		if guild_get(*c.store, guild_id) != null { aw_guild(*p, c, guild_id, with_id = false); }
		json_kstr(*p, "location", "member list");
		json_obj_end(*p);
		locks.lock(*c.social_mu);
		delete(c.social.nick_mod_props, c.allocator);
		c.social.nick_mod_props = clone(json_body(json_string(*p)), c.allocator);
		locks.unlock(*c.social_mu);
		j.on_body = (c: *Client, _: V) {
			locks.lock(*c.social_mu);
			props := clone(c.social.nick_mod_props, temp);
			locks.unlock(*c.social_mu);
			analytics_track(c, "moderation_action", props);
		};
	}
	job_submit(c, j);
}

// ---- user context menus ----

// open_user_context_menu: right-clicking a member / author in a guild loads the
// popout's data (fixture friend_nickname/friend_nickname_open): the profile every
// time; application identities, the note, the command indexes and an op 37
// member subscription once per user (or guild) in a session.
open_user_context_menu :: (c: *Client, user_id: Snowflake, guild_id: Snowflake) {
	fetch_profile_ex(c, user_id, .{kind = "popout", mutual_guilds = true, mutual_friends = true, guild_id = guild_id});
	// every open reads the command cache ~40 ms later (flush_user_menu)
	c.social.cmd_index_at = now_ms() + 40;
	c.social.cmd_index_guild = guild_id;
	if c.social.menu_loaded == null { c.social.menu_loaded = Map(Snowflake, bool).{}; }
	if get(c.social.menu_loaded, user_id) { return; }
	at(*c.social.menu_loaded, user_id).* = true;
	api_get_later(c, strings.concatenate(.{"/users/", snowflake_string(user_id), "/application-identities?with_profiles=true"}, temp), 0);
	fetch_note(c, user_id, 40);
	if guild_id != 0 { subscribe_members(c, guild_id, .{user_id}); }
}

// open_dm_row_menu: right-clicking a 1:1 DM row (fixture friend_add_context_menu):
// the note and the user command index once, and the menu's impression.
open_dm_row_menu :: (c: *Client, user_id: Snowflake) {
	if c.social.menu_loaded == null { c.social.menu_loaded = Map(Snowflake, bool).{}; }
	if !get(c.social.notes_loaded, user_id) {
		if c.social.notes_loaded == null { c.social.notes_loaded = Map(Snowflake, bool).{}; }
		at(*c.social.notes_loaded, user_id).* = true;
		fetch_note(c, user_id);
	}
	open_message_context_menu(c, 0);
	w := aw_begin();
	json_kstr(*w, "impression_type", "menu");
	json_kstr(*w, "location", "impression_friends");
	json_kstr(*w, "location_page", "impression_friends");
	json_kstr(*w, "location_section", "impression_dm_list_right_click_menu_shown");
	aw_track(c, "impression_dm_list_right_click_menu_shown", *w);
}

// flush_user_menu: the deferred command-index loads of open_user_context_menu (client_poll).
flush_user_menu :: (c: *Client, now: s64) {
	if c.social.cmd_index_at == 0 || now < c.social.cmd_index_at { return; }
	c.social.cmd_index_at = 0;
	// the command cache is read before and after the index loads start (as for
	// the message menu): application_command_cache_fetch {miss, size} twice
	gid := c.social.cmd_index_guild;
	if gid == 0 {
		open_message_context_menu(c, 0);
		return;
	}
	miss := !get(c.command_index_guilds, gid);
	analytics_command_cache_fetch(c, miss, len(c.command_index_guilds));
	open_message_context_menu(c, gid);
	analytics_command_cache_fetch(c, miss, len(c.command_index_guilds));
}

