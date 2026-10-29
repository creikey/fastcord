// Store is the client-side cache the UI reads directly every frame.
// It is only mutated on the UI thread (client_poll drains the event queue),
// so readers need no locks. `changed` increases after every mutation batch.
// Everything it holds (strings, arrays, tables) lives in s.allocator: containers are given it
// explicitly, so a first append made under another context.allocator (temp) cannot capture that.
Store :: struct {
	allocator: Allocator;
	changed: u64;
	connection: Connection_State;
	ready: bool;
	readies: u64; // READY count: a new one is a new gateway session (voice must rejoin)
	voice_elsewhere: u64; // joins by our account from other sessions (another device took the call)
	session_id: string;
	me: Snowflake;
	users: Table(Snowflake, User);
	guilds: Table(Snowflake, Guild);
	guild_order: [..]Snowflake; // READY order (see settings.guild_folders for the sidebar)
	channels: Table(Snowflake, Channel);
	private_channels: [..]Snowflake;
	members: Table(Snowflake, Table(Snowflake, Member)); // guild -> user -> member
	extras: Extras; // thread metadata, forum tags, our roles (features.jai), under extras_mu
	extras_mu: locks.Mutex;
	messages: Table(Snowflake, Message_List); // channel -> messages
	presences: Table(Snowflake, Presence);
	relationships: Table(Snowflake, Relationship);
	notes: Table(Snowflake, string); // user -> our note about them, once loaded (fetch_note, USER_NOTE_UPDATE)
	read_states: Table(Snowflake, Read_State);
	guild_settings: Table(Snowflake, Guild_Settings);
	voice_states: Table(Snowflake, Voice_State); // user -> state (one voice connection per user)
	typing: Table(Snowflake, [..]Typing); // channel -> typers
	member_lists: Table(string, Member_List); // "<guild>:<list id>" -> member sidebar (member_list_get)
	sessions: [..]Session_Info;
	settings: User_Settings;
	frecency: Frecency_State; // FrecencyUserSettings (settings-proto/2) uses and writes, expressions.jai
	voice_server: Voice_Server;
	streams: [..]Go_Live_Stream;
	resume_gateway_url: string;
	analytics_token: string;
	auth_session_hash: string; // READY auth_session_id_hash: this login among GET /auth/sessions
	qos_token: string; // READY qos_token (base64 DerivedQosData) for reconnect IDENTIFY
	country_code: string;
	// Our own reaction requests whose gateway echo hasn't come yet, per reaction_key. Those
	// echoes are skipped: the store already shows the outcome, and an old echo arriving
	// after a newer click would undo it (on, off, on ended off).
	reaction_echoes: Table(u64, int);
	soundboard: [..]Soundboard_Sound; // every guild's sounds and the default ones (soundboard.jai)
	soundboard_epoch: u64; // bumped when they change
	effects: [..]Voice_Effect; // sounds others played, for the app (take_voice_effects)
	interactions: Table(Snowflake, Interaction_State); // message -> our pending or failed component click
}

reaction_key :: (message_id: Snowflake, e: Emoji, burst: bool) -> u64 {
	h := get_hash(message_id, ifx e.id then get_hash(e.id) else get_hash(e.name));
	return (cast(u64) h << 1) | cast(u64) burst;
}

store_init :: (s: *Store, allocator := context.allocator) {
	s.allocator = allocator;
	s.reaction_echoes.allocator = allocator;
	s.interactions.allocator = allocator;
	s.users.allocator = allocator;
	s.guilds.allocator = allocator;
	s.guild_order.allocator = allocator;
	s.channels.allocator = allocator;
	s.private_channels.allocator = allocator;
	s.members.allocator = allocator;
	s.messages.allocator = allocator;
	s.presences.allocator = allocator;
	s.relationships.allocator = allocator;
	s.notes.allocator = allocator;
	s.read_states.allocator = allocator;
	s.guild_settings.allocator = allocator;
	s.voice_states.allocator = allocator;
	s.streams.allocator = allocator;
	s.typing.allocator = allocator;
	s.member_lists.allocator = allocator;
	s.sessions.allocator = allocator;
	s.settings.guild_folders.allocator = allocator;
	s.settings.guild_positions.allocator = allocator;
	s.soundboard.allocator = allocator;
	s.effects.allocator = allocator;
}

// The note about a user: "" for none; loaded false until fetch_note asked for it.
note_get :: (s: *Store, user_id: Snowflake) -> note: string, loaded: bool {
	p := table_find_pointer(*s.notes, user_id);
	return ifx p then p.* else "", p != null;
}

note_set_local :: (s: *Store, user_id: Snowflake, note: string) {
	if !user_id return;
	p := find_or_add(*s.notes, user_id);
	set_str(s, p, slice(note, 0, min(note.count, NOTE_MAX * 4))); // a server's note is capped like ours
	s.changed += 1;
}

NOTE_MAX :: 256; // characters

// set_str replaces a store string with a copy of v.
set_str :: (s: *Store, dst: *string, v: string) {
	free_str(dst.*, s.allocator);
	dst.* = clone_str(v, s.allocator);
}

// A voice channel status: Discord caps it at 500 characters; cut longer ones on a UTF-8 boundary.
set_channel_status :: (s: *Store, c: *Channel, v: string) {
	t := v;
	if t.count > 2000 {
		t.count = 2000;
		while t.count > 0 && (t.data[t.count] & 0xC0) == 0x80 t.count -= 1;
	}
	set_str(s, *c.status, t);
}

// ---- freeing ----

free_user :: (s: *Store, u: *User) {
	a := s.allocator;
	free_str(u.username, a);
	free_str(u.global_name, a);
	free_str(u.discriminator, a);
	free_str(u.avatar, a);
	free_str(u.banner, a);
	free_str(u.bio, a);
	free_str(u.pronouns, a);
	free_str(u.badges, a);
	free_str(u.badge_icons, a);
}

free_channel :: (s: *Store, c: *Channel) {
	a := s.allocator;
	free_str(c.name, a);
	free_str(c.topic, a);
	free_str(c.icon, a);
	free_str(c.status, a);
	free_str(c.rtc_region, a);
	array_free(c.recipient_ids);
	array_free(c.overwrites);
}

free_role :: (s: *Store, r: *Role) {
	free_str(r.name, s.allocator);
	free_str(r.icon, s.allocator);
	free_str(r.unicode_emoji, s.allocator);
}

free_guild :: (s: *Store, g: *Guild) {
	a := s.allocator;
	free_str(g.name, a);
	free_str(g.icon, a);
	free_str(g.banner, a);
	free_str(g.joined_at, a);
	free_str(g.description, a);
	free_str(g.vanity_url_code, a);
	free_str(g.preferred_locale, a);
	free_str(g.invites_disabled_until, a);
	free_str(g.owner_offer, a);
	free_str(g.fc_address, a);
	array_free(g.channels);
	for * g.roles free_role(s, it);
	array_free(g.roles);
	for g.emojis free_str(it.name, a);
	array_free(g.emojis);
	for g.stickers {
		free_str(it.name, a);
		free_str(it.description, a);
	}
	array_free(g.stickers);
	for g.features free_str(it, a);
	array_free(g.features);
}

free_member :: (s: *Store, m: *Member) {
	free_str(m.nick, s.allocator);
	free_str(m.avatar, s.allocator);
	free_str(m.bio, s.allocator);
	free_str(m.pronouns, s.allocator);
	free_str(m.banner, s.allocator);
	free_str(m.joined_at, s.allocator);
	array_free(m.roles);
}

free_attachment :: (s: *Store, at: *Attachment) {
	a := s.allocator;
	free_str(at.filename, a);
	free_str(at.content_type, a);
	free_str(at.url, a);
	free_str(at.proxy_url, a);
	free_str(at.waveform, a);
	free_str(at.description, a);
}

free_embed :: (s: *Store, e: *Embed) {
	a := s.allocator;
	free_str(e.kind, a);
	free_str(e.title, a);
	free_str(e.description, a);
	free_str(e.url, a);
	free_str(e.thumbnail_url, a);
	free_str(e.image_url, a);
	free_str(e.video_url, a);
	for string.[e.provider, e.provider_url, e.author_name, e.author_url, e.author_icon, e.footer, e.footer_icon] free_str(it, a);
	for e.fields { free_str(it.name, a); free_str(it.value, a); }
	if e.fields.data free(e.fields.data,, a);
}

free_message :: (s: *Store, m: *Message) {
	a := s.allocator;
	free_str(m.content, a);
	free_str(m.timestamp, a);
	free_str(m.edited_timestamp, a);
	free_str(m.call_ended, a);
	free_str(m.command_name, a);
	free_str(m.forward_timestamp, a);
	free_str(m.nonce, a);
	free_str(m.webhook_name, a);
	for * m.attachments free_attachment(s, it);
	array_free(m.attachments);
	for * m.embeds free_embed(s, it);
	array_free(m.embeds);
	for m.reactions free_str(it.emoji.name, a);
	array_free(m.reactions);
	array_free(m.sticker_ids);
	array_free(m.mentions);
	free_poll(s, m.poll);
	free_components(s, m.components);
}

free_message_list :: (s: *Store, l: *Message_List) {
	for * l.messages free_message(s, it);
	array_free(l.messages);
}

// ---- parsers (ETF or JSON value -> model, strings cloned into the store) ----

parse_user_into :: (s: *Store, m: etf.Map) -> Snowflake {
	id := fsnow(m, "id");
	if id == 0 return 0;
	u, added := find_or_add(*s.users, id);
	if added u.* = .{id = id, mutual_guilds = -1, mutual_friends = -1};
	// Partial user objects (presence updates) only carry what changed.
	if vhas(m, "username") set_str(s, *u.username, fstr(m, "username"));
	if vhas(m, "global_name") set_str(s, *u.global_name, fstr(m, "global_name"));
	if vhas(m, "discriminator") set_str(s, *u.discriminator, fstr(m, "discriminator"));
	if vhas(m, "avatar") set_str(s, *u.avatar, fstr(m, "avatar"));
	if vhas(m, "banner") set_str(s, *u.banner, fstr(m, "banner"));
	if vhas(m, "bio") set_str(s, *u.bio, fstr(m, "bio"));
	if vhas(m, "pronouns") set_str(s, *u.pronouns, fstr(m, "pronouns"));
	if vhas(m, "accent_color") {
		ac := vget(m, "accent_color");
		u.has_accent_color = !vis_null(ac);
		u.accent_color = ifx u.has_accent_color then cast(u32) vint(ac) else 0;
	}
	if vhas(m, "bot") u.bot = fbool(m, "bot");
	if vhas(m, "public_flags") u.flags = cast(u64) fint(m, "public_flags");
	if vhas(m, "flags") u.flags = cast(u64) fint(m, "flags");
	if vhas(m, "premium_type") u.premium_type = fint(m, "premium_type");
	if vhas(m, "primary_guild") {
		// the server tag: at most 4 characters in Discord's own rule; anything odd shows nothing
		pg := fmap(m, "primary_guild");
		on := fbool(pg, "identity_enabled");
		tag, badge := fstr(pg, "tag"), fstr(pg, "badge");
		if !on || tag.count > 16 || !is_hash(badge) tag, badge = "", "";
		set_str(s, *u.tag, tag);
		set_str(s, *u.tag_badge, badge);
		u.tag_guild = ifx tag then fsnow(pg, "identity_guild_id") else 0;
	}
	return id;
}

// is_hash: "" or a CDN asset hash (hex, an optional a_ prefix), safe to put in a URL.
is_hash :: (h: string) -> bool {
	if h.count > 64 return false;
	for cast([]u8) h if !is_alnum(it) && it != #char "_" return false;
	return true;
}

// parse_channel_into creates or updates a channel (guild_id may be implied by the container).
parse_channel_into :: (s: *Store, m: etf.Map, guild_id: Snowflake = 0) -> Snowflake {
	id := fsnow(m, "id");
	if id == 0 return 0;
	c, added := find_or_add(*s.channels, id);
	if added {
		c.* = .{id = id, sort_order = -1};
		c.recipient_ids.allocator = s.allocator;
		c.overwrites.allocator = s.allocator;
	}
	if vhas(m, "type") c.kind = cast(Channel_Type) fint(m, "type");
	gid := fsnow(m, "guild_id");
	if gid c.guild_id = gid;
	else if guild_id c.guild_id = guild_id;
	if vhas(m, "parent_id") c.parent_id = fsnow(m, "parent_id");
	if vhas(m, "name") set_str(s, *c.name, fstr(m, "name"));
	if vhas(m, "topic") set_str(s, *c.topic, fstr(m, "topic"));
	if vhas(m, "icon") set_str(s, *c.icon, fstr(m, "icon"));
	if vhas(m, "position") c.position = fint(m, "position");
	if vhas(m, "nsfw") c.nsfw = fbool(m, "nsfw");
	if vhas(m, "last_message_id") c.last_message_id = fsnow(m, "last_message_id");
	if vhas(m, "rate_limit_per_user") c.rate_limit_per_user = fint(m, "rate_limit_per_user");
	if vhas(m, "bitrate") c.bitrate = fint(m, "bitrate");
	if vhas(m, "user_limit") c.user_limit = fint(m, "user_limit");
	if vhas(m, "rtc_region") set_str(s, *c.rtc_region, fstr(m, "rtc_region"));
	if vhas(m, "video_quality_mode") c.video_quality_mode = fint(m, "video_quality_mode");
	if vhas(m, "default_auto_archive_duration") c.default_auto_archive = fint(m, "default_auto_archive_duration");
	if vhas(m, "default_forum_layout") c.forum_layout = fint(m, "default_forum_layout");
	if vhas(m, "default_sort_order") c.sort_order = ifx vget(m, "default_sort_order").kind == .Int then fint(m, "default_sort_order") else -1;
	if vhas(m, "owner_id") c.owner_id = fsnow(m, "owner_id");
	if vhas(m, "flags") c.flags = cast(u64) fint(m, "flags");
	if vhas(m, "status") set_channel_status(s, c, fstr(m, "status"));
	if vhas(m, "is_message_request") c.msg_request = fbool(m, "is_message_request");
	if vhas(m, "is_spam") c.spam = fbool(m, "is_spam");
	if vhas(m, "permission_overwrites") {
		c.overwrites.count = 0;
		for flist(m, "permission_overwrites") {
			if it_index >= MAX_OVERWRITES break;
			om := vmap(it);
			array_add(*c.overwrites, .{id = fsnow(om, "id"), kind = cast(u8) fint(om, "type"), allow = cast(u64) fint(om, "allow"), deny = cast(u64) fint(om, "deny")});
		}
	}
	if vhas(m, "recipient_ids") {
		c.recipient_ids.count = 0;
		for flist(m, "recipient_ids") array_add(*c.recipient_ids, vsnow(it));
	} else if vhas(m, "recipients") {
		c.recipient_ids.count = 0;
		for flist(m, "recipients") {
			uid := parse_user_into(s, vmap(it));
			if uid array_add(*c.recipient_ids, uid);
		}
	}
	return id;
}

parse_role :: (s: *Store, m: etf.Map) -> Role {
	a := s.allocator;
	r := Role.{
		id = fsnow(m, "id"),
		name = clone_str(fstr(m, "name"), a),
		color = cast(u32) fint(m, "color"),
		position = fint(m, "position"),
		permissions = cast(u64) fint(m, "permissions"),
		hoist = fbool(m, "hoist"),
		mentionable = fbool(m, "mentionable"),
		icon = clone_str(fstr(m, "icon"), a),
		unicode_emoji = clone_str(fstr(m, "unicode_emoji"), a),
		managed = fbool(m, "managed")
	};
	colors := fmap(m, "colors");
	if vhas(colors, "primary_color") r.color = cast(u32) fint(colors, "primary_color");
	return r;
}

parse_emojis :: (s: *Store, g: *Guild, l: []V) {
	for g.emojis free_str(it.name, s.allocator);
	g.emojis.count = 0;
	for l {
		em := vmap(it);
		array_add(*g.emojis, .{
			id = fsnow(em, "id"),
			name = clone_str(fstr(em, "name"), s.allocator),
			animated = fbool(em, "animated"),
			available = !vhas(em, "available") || fbool(em, "available"),
			guild_id = g.id
		});
	}
}

parse_stickers :: (s: *Store, g: *Guild, l: []V) {
	for g.stickers {
		free_str(it.name, s.allocator);
		free_str(it.description, s.allocator);
	}
	g.stickers.count = 0;
	for l {
		sm := vmap(it);
		array_add(*g.stickers, .{
			id = fsnow(sm, "id"),
			name = clone_str(fstr(sm, "name"), s.allocator),
			format_type = fint(sm, "format_type"),
			guild_id = g.id,
			description = clone_str(fstr(sm, "description"), s.allocator)
		});
	}
}

// parse_guild_props applies guild-level fields (READY nests them in `properties`).
parse_guild_props :: (s: *Store, g: *Guild, p: etf.Map) {
	if vhas(p, "name") set_str(s, *g.name, fstr(p, "name"));
	if vhas(p, "icon") set_str(s, *g.icon, fstr(p, "icon"));
	if vhas(p, "banner") set_str(s, *g.banner, fstr(p, "banner"));
	if vhas(p, "owner_id") g.owner_id = fsnow(p, "owner_id");
	if vhas(p, "system_channel_id") g.system_channel_id = fsnow(p, "system_channel_id");
	if vhas(p, "default_message_notifications") g.default_message_notifications = fint(p, "default_message_notifications");
	if vhas(p, "description") set_str(s, *g.description, fstr(p, "description"));
	if vhas(p, "system_channel_flags") g.system_channel_flags = fint(p, "system_channel_flags");
	if vhas(p, "afk_channel_id") g.afk_channel_id = fsnow(p, "afk_channel_id");
	if vhas(p, "afk_timeout") g.afk_timeout = fint(p, "afk_timeout");
	if vhas(p, "verification_level") g.verification_level = fint(p, "verification_level");
	if vhas(p, "explicit_content_filter") g.explicit_content_filter = fint(p, "explicit_content_filter");
	if vhas(p, "mfa_level") g.mfa_level = fint(p, "mfa_level");
	if vhas(p, "vanity_url_code") set_str(s, *g.vanity_url_code, fstr(p, "vanity_url_code"));
	if vhas(p, "rules_channel_id") g.rules_channel_id = fsnow(p, "rules_channel_id");
	if vhas(p, "public_updates_channel_id") g.public_updates_channel_id = fsnow(p, "public_updates_channel_id");
	if vhas(p, "safety_alerts_channel_id") g.safety_alerts_channel_id = fsnow(p, "safety_alerts_channel_id");
	if vhas(p, "preferred_locale") set_str(s, *g.preferred_locale, fstr(p, "preferred_locale"));
	if vhas(p, "incidents_data") set_str(s, *g.invites_disabled_until, fstr(fmap(p, "incidents_data"), "invites_disabled_until"));
	if vhas(p, "pending_owner_id") g.pending_owner_id = fsnow(p, "pending_owner_id");
	if vhas(p, "fc_owner_offer") set_str(s, *g.owner_offer, fstr(p, "fc_owner_offer"));
	if vhas(p, "fc_address") set_str(s, *g.fc_address, fstr(p, "fc_address"));
	if vhas(p, "features") {
		for g.features free_str(it, s.allocator);
		g.features.count = 0;
		for flist(p, "features") array_add(*g.features, clone_str(vstr(it), s.allocator));
	}
}

parse_guild_into :: (s: *Store, m: etf.Map) -> Snowflake {
	id := fsnow(m, "id");
	if id == 0 return 0;
	g, added := find_or_add(*s.guilds, id);
	if added {
		g.* = .{id = id};
		g.channels.allocator = s.allocator;
		g.roles.allocator = s.allocator;
		g.emojis.allocator = s.allocator;
		g.stickers.allocator = s.allocator;
		g.features.allocator = s.allocator;
		array_add(*s.guild_order, id);
	}
	g.unavailable = fbool(m, "unavailable");
	props := fmap(m, "properties");
	parse_guild_props(s, g, ifx props then props else m);
	if vhas(m, "member_count") g.member_count = fint(m, "member_count");
	if vhas(m, "premium_tier") g.premium_tier = fint(m, "premium_tier");
	if vhas(props, "premium_tier") g.premium_tier = fint(props, "premium_tier");
	if vhas(m, "lazy") g.lazy = fbool(m, "lazy");
	if vhas(m, "joined_at") set_str(s, *g.joined_at, fstr(m, "joined_at"));
	if vhas(m, "roles") {
		for * g.roles free_role(s, it);
		g.roles.count = 0;
		for flist(m, "roles") array_add(*g.roles, parse_role(s, vmap(it)));
	}
	if vhas(m, "emojis") parse_emojis(s, g, flist(m, "emojis"));
	if vhas(m, "stickers") parse_stickers(s, g, flist(m, "stickers"));
	if vhas(m, "soundboard_sounds") soundboard_set_guild(s, id, flist(m, "soundboard_sounds")); // self-hosted READY
	if vhas(m, "channels") {
		g.channels.count = 0;
		for flist(m, "channels") {
			cid := parse_channel_into(s, vmap(it), id);
			if cid array_add(*g.channels, cid);
		}
	}
	for flist(m, "threads") {
		cid := parse_channel_into(s, vmap(it), id);
		if cid array_add_if_unique(*g.channels, cid);
	}
	for flist(m, "voice_states") apply_voice_state(s, vmap(it), id);
	for flist(m, "members") parse_member_into(s, id, vmap(it));
	for flist(m, "presences") apply_presence(s, vmap(it));
	return id;
}

parse_member_into :: (s: *Store, guild_id: Snowflake, m: etf.Map) -> Snowflake {
	if !m return 0;
	uid := fsnow(m, "user_id");
	um := fmap(m, "user");
	if um uid = parse_user_into(s, um);
	if uid == 0 return 0;
	parse_member_with_id(s, guild_id, uid, m);
	pm := fmap(m, "presence");
	if pm apply_presence(s, pm, uid);
	return uid;
}

parse_member_with_id :: (s: *Store, guild_id: Snowflake, uid: Snowflake, m: etf.Map) {
	gm, new_guild := find_or_add(*s.members, guild_id);
	if new_guild gm.* = .{allocator = s.allocator};
	member, added := find_or_add(gm, uid);
	if added {
		member.* = .{user_id = uid};
		member.roles.allocator = s.allocator;
	}
	if vhas(m, "nick") set_str(s, *member.nick, fstr(m, "nick"));
	if vhas(m, "avatar") set_str(s, *member.avatar, fstr(m, "avatar"));
	if vhas(m, "banner") set_str(s, *member.banner, fstr(m, "banner"));
	if vhas(m, "joined_at") set_str(s, *member.joined_at, fstr(m, "joined_at"));
	if vhas(m, "flags") member.flags = cast(u64) fint(m, "flags");
	if vhas(m, "pending") member.pending = fbool(m, "pending");
	if vhas(m, "communication_disabled_until") member.timeout_until_ms = iso_to_ms(fstr(m, "communication_disabled_until"));
	if vhas(m, "roles") {
		member.roles.count = 0;
		for flist(m, "roles") array_add(*member.roles, vsnow(it));
	}
}

parse_emoji_ref :: (s: *Store, m: etf.Map) -> Emoji {
	return .{id = fsnow(m, "id"), name = clone_str(fstr(m, "name"), s.allocator), animated = fbool(m, "animated"), available = true};
}

parse_attachment :: (m: etf.Map, a: Allocator) -> Attachment {
	return .{
		id = fsnow(m, "id"),
		filename = clone_str(fstr(m, "filename"), a),
		content_type = clone_str(fstr(m, "content_type"), a),
		size = fint(m, "size"),
		url = clone_str(fstr(m, "url"), a),
		proxy_url = clone_str(fstr(m, "proxy_url"), a),
		width = fint(m, "width"),
		height = fint(m, "height"),
		duration_secs = cast(float32) vf64(vget(m, "duration_secs")),
		waveform = clone_str(fstr(m, "waveform"), a),
		description = clone_str(fstr(m, "description"), a),
		flags = cast(u64) fint(m, "flags")
	};
}

MAX_EMBED_FIELDS :: 25; // Discord's own limit.

parse_embed :: (m: etf.Map, a: Allocator) -> Embed {
	e := Embed.{
		kind = clone_str(fstr(m, "type"), a),
		title = clone_str(fstr(m, "title"), a),
		description = clone_str(fstr(m, "description"), a),
		url = clone_str(fstr(m, "url"), a),
		color = cast(u32) fint(m, "color"),
		flags = cast(u64) fint(m, "flags")
	};
	t := fmap(m, "thumbnail");
	if t {
		e.thumbnail_url = clone_str(ifx vhas(t, "proxy_url") then fstr(t, "proxy_url") else fstr(t, "url"), a);
		e.thumbnail_w = fint(t, "width");
		e.thumbnail_h = fint(t, "height");
	}
	im := fmap(m, "image");
	if im {
		e.image_url = clone_str(ifx vhas(im, "proxy_url") then fstr(im, "proxy_url") else fstr(im, "url"), a);
		e.image_w = fint(im, "width");
		e.image_h = fint(im, "height");
	}
	vd := fmap(m, "video");
	if vd {
		e.video_url = clone_str(ifx vhas(vd, "proxy_url") then fstr(vd, "proxy_url") else fstr(vd, "url"), a);
		e.video_w = fint(vd, "width");
		e.video_h = fint(vd, "height");
	}
	p := fmap(m, "provider");
	icon :: (o: etf.Map, a: Allocator) -> string { return clone_str(ifx vhas(o, "proxy_icon_url") then fstr(o, "proxy_icon_url") else fstr(o, "icon_url"), a); }
	if p { e.provider = clone_str(fstr(p, "name"), a); e.provider_url = clone_str(fstr(p, "url"), a); }
	au := fmap(m, "author");
	if au { e.author_name = clone_str(fstr(au, "name"), a); e.author_url = clone_str(fstr(au, "url"), a); e.author_icon = icon(au, a); }
	ft := fmap(m, "footer");
	if ft { e.footer = clone_str(fstr(ft, "text"), a); e.footer_icon = icon(ft, a); }
	e.timestamp_ms = iso_to_ms(fstr(m, "timestamp"));
	fields := flist(m, "fields");
	if fields.count {
		e.fields = NewArray(min(fields.count, MAX_EMBED_FIELDS), Embed_Field,, a);
		for * e.fields {
			f := vmap(fields[it_index]);
			it.* = .{clone_str(fstr(f, "name"), a), clone_str(fstr(f, "value"), a), fbool(f, "inline")};
		}
	}
	return e;
}

parse_reactions :: (s: *Store, msg: *Message, l: []V) {
	for msg.reactions free_str(it.emoji.name, s.allocator);
	msg.reactions.count = 0;
	for l {
		rm := vmap(it);
		r := Reaction.{
			emoji = parse_emoji_ref(s, fmap(rm, "emoji")),
			count = fint(rm, "count"),
			burst_count = fint(rm, "burst_count"),
			me = fbool(rm, "me"),
			me_burst = fbool(rm, "me_burst")
		};
		cd := fmap(rm, "count_details");
		if cd r.burst_count = fint(cd, "burst");
		bc := flist(rm, "burst_colors");
		if bc {
			h := vstr(bc[0]);
			if begins_with(h, "#") h = advance(h, 1);
			v, ok := string_to_int(h, 16);
			if ok r.burst_color = cast(u32) v;
		}
		array_add(*msg.reactions, r);
	}
}

// nonce_text: a message nonce as sent (string) or echoed back (ETF integer); "" otherwise.
nonce_text :: (v: V) -> string {
	if v.kind == .String return v.s;
	if v.kind == .Int || v.kind == .Big return snowflake_string(vsnow(v));
	return "";
}

// parse_message_fields fills msg from a full or partial (MESSAGE_UPDATE) object.
parse_message_fields :: (s: *Store, msg: *Message, m: etf.Map) {
	if vhas(m, "channel_id") msg.channel_id = fsnow(m, "channel_id");
	au := fmap(m, "author");
	if au msg.author_id = parse_user_into(s, au);
	if au && vhas(m, "webhook_id") set_str(s, *msg.webhook_name, ifx fstr(au, "global_name") then fstr(au, "global_name") else fstr(au, "username"));
	if vhas(m, "type") msg.kind = fint(m, "type");
	if vhas(m, "timestamp") set_str(s, *msg.timestamp, fstr(m, "timestamp"));
	if vhas(m, "edited_timestamp") set_str(s, *msg.edited_timestamp, fstr(m, "edited_timestamp"));
	call := fmap(m, "call");
	if call {
		set_str(s, *msg.call_ended, fstr(call, "ended_timestamp"));
		msg.call_joined = false;
		for flist(call, "participants") if vsnow(it) == s.me msg.call_joined = true;
	}
	if vhas(m, "nonce") set_str(s, *msg.nonce, nonce_text(vget(m, "nonce")));
	if vhas(m, "flags") msg.flags = cast(u64) fint(m, "flags");
	if vhas(m, "mention_everyone") msg.mention_everyone = fbool(m, "mention_everyone");
	if vhas(m, "pinned") msg.pinned = fbool(m, "pinned");
	parse_message_content(s, msg, m);
	ref := fmap(m, "message_reference");
	if ref && fint(ref, "type") == 1 {
		// a forward: shows the snapshot's content (the forwarding message's own is empty)
		msg.forwarded = true;
		msg.forward_channel_id = fsnow(ref, "channel_id");
		msg.forward_message_id = fsnow(ref, "message_id");
		snaps := flist(m, "message_snapshots");
		if snaps {
			snap := fmap(vmap(snaps[0]), "message");
			parse_message_content(s, msg, snap);
			set_str(s, *msg.forward_timestamp, fstr(snap, "timestamp"));
		}
	} else if ref {
		msg.referenced_id = fsnow(ref, "message_id");
		if msg.kind == 18 msg.forward_channel_id = fsnow(ref, "channel_id"); // THREAD_CREATED: the thread
		// THREAD_STARTER_MESSAGE: the parent message shown as itself, by its author; without it, a notice
		rm := fmap(m, "referenced_message");
		if msg.kind == 21 && rm {
			parse_message_content(s, msg, rm);
			ra := fmap(rm, "author");
			if ra msg.author_id = parse_user_into(s, ra);
			msg.referenced_id = 0;
		}
	}
	rs := fmap(m, "role_subscription_data");
	if rs {
		tier := fstr(rs, "tier_name");
		set_str(s, *msg.content, slice(tier, 0, min(tier.count, 100)));
		msg.sub_months = clamp(fint(rs, "total_months_subscribed"), 0, 10_000);
		msg.sub_renewal = fbool(rs, "is_renewal");
	}
	// "X used /command": interaction_metadata (its name when the API sends one), else the older interaction
	im, old := fmap(m, "interaction_metadata"), fmap(m, "interaction");
	if im || old {
		u := fmap(ifx im then im else old, "user");
		if !u && old u = fmap(old, "user");
		if u msg.command_user = parse_user_into(s, u);
		name := ifx im then fstr(im, "name") else "";
		if !name && old name = fstr(old, "name");
		set_str(s, *msg.command_name, slice(name, 0, min(name.count, 128)));
	}
	// Keep the referenced author resolvable for reply previews.
	rau := fmap(fmap(m, "referenced_message"), "author");
	if rau parse_user_into(s, rau);
	gid := fsnow(m, "guild_id");
	// The thread started from this message (its id is the message's): archived ones are known only from here.
	th := fmap(m, "thread");
	if th {
		parse_channel_into(s, th, gid);
		locks.lock(*s.extras_mu);
		note_thread(*s.extras, th, s.me,, context.default_allocator);
		locks.unlock(*s.extras_mu);
	}
	mm := fmap(m, "member");
	if mm && gid && msg.author_id {
		// MESSAGE_CREATE members omit `user`; attach to the author.
		if !vhas(mm, "user") && !vhas(mm, "user_id") parse_member_with_id(s, gid, msg.author_id, mm);
		else parse_member_into(s, gid, mm);
	}
}

// The fields a forward's snapshot carries too: content, attachments, embeds, mentions, stickers.
parse_message_content :: (s: *Store, msg: *Message, m: etf.Map) {
	if vhas(m, "content") set_str(s, *msg.content, fstr(m, "content"));
	if vhas(m, "attachments") {
		for * msg.attachments free_attachment(s, it);
		msg.attachments.count = 0;
		for flist(m, "attachments") array_add(*msg.attachments, parse_attachment(vmap(it), s.allocator));
	}
	if vhas(m, "embeds") {
		for * msg.embeds free_embed(s, it);
		msg.embeds.count = 0;
		for flist(m, "embeds") array_add(*msg.embeds, parse_embed(vmap(it), s.allocator));
	}
	if vhas(m, "reactions") parse_reactions(s, msg, flist(m, "reactions"));
	if vhas(m, "mentions") {
		msg.mentions.count = 0;
		for flist(m, "mentions") {
			uid := parse_user_into(s, vmap(it));
			if uid array_add(*msg.mentions, uid);
		}
	}
	if vhas(m, "sticker_items") {
		items := flist(m, "sticker_items");
		msg.sticker_ids.count = 0;
		for items array_add(*msg.sticker_ids, fsnow(vmap(it), "id"));
		note_sticker_items(s, items);
	}
	if vhas(m, "poll") parse_poll(s, msg, fmap(m, "poll"));
	if vhas(m, "components") {
		app := fsnow(m, "application_id");
		if !app app = fsnow(fmap(m, "author"), "id"); // a bot user's ID is its application's
		parse_components(s, msg, flist(m, "components"), ifx app then app else ifx msg.components then msg.components.app_id else 0);
	}
}

new_message :: (s: *Store) -> Message {
	m: Message;
	m.attachments.allocator = s.allocator;
	m.embeds.allocator = s.allocator;
	m.reactions.allocator = s.allocator;
	m.sticker_ids.allocator = s.allocator;
	m.mentions.allocator = s.allocator;
	return m;
}

message_list :: (s: *Store, channel_id: Snowflake) -> *Message_List {
	l, added := find_or_add(*s.messages, channel_id);
	if added {
		l.* = .{has_more_before = true};
		l.messages.allocator = s.allocator;
	}
	return l;
}

// message_search: the index of id in l (ascending by id), or where it would be inserted.
message_search :: (l: *Message_List, id: Snowflake) -> int, bool {
	lo, hi := 0, l.messages.count;
	while lo < hi {
		mid := (lo + hi) / 2;
		if l.messages[mid].id < id lo = mid + 1;
		else hi = mid;
	}
	return lo, lo < l.messages.count && l.messages[lo].id == id;
}

// message_index finds a message by id (binary search; pending messages sort by nonce id).
message_index :: (l: *Message_List, id: Snowflake) -> int {
	i, found := message_search(l, id);
	return ifx found then i else -1;
}

insert_message :: (l: *Message_List, msg: Message) {
	i := message_search(l, msg.id);
	array_insert_at(*l.messages, msg, i);
}

// upsert_message handles MESSAGE_CREATE / REST message objects, replacing a
// pending optimistic message with the same nonce.
upsert_message :: (s: *Store, m: etf.Map) -> Snowflake {
	id := fsnow(m, "id");
	cid := fsnow(m, "channel_id");
	if id == 0 || cid == 0 return 0;
	l := message_list(s, cid);
	i := message_index(l, id);
	if i >= 0 {
		msg := *l.messages[i];
		parse_message_fields(s, msg, m);
		msg.pending = false;
		msg.failed = false;
		return id;
	}
	nonce := nonce_text(vget(m, "nonce"));
	if nonce for * l.messages {
		if (it.pending || it.failed) && it.nonce == nonce { // a send marked failed whose echo came late
			free_message(s, it);
			array_ordered_remove_by_index(*l.messages, it_index);
			break;
		}
	}
	msg := new_message(s);
	msg.id = id;
	parse_message_fields(s, *msg, m);
	insert_message(l, msg);
	c := table_find_pointer(*s.channels, cid);
	if c && id > c.last_message_id c.last_message_id = id;
	return id;
}

// ---- presence / voice / misc ----

free_presence :: (s: *Store, p: *Presence) {
	a := s.allocator;
	free_str(p.activity, a);
	free_str(p.custom, a);
	free_str(p.game, a);
	r := *p.rich;
	for string.[r.name, r.details, r.state, r.large_image, r.large_text, r.small_image, r.small_text, r.sync_id] free_str(it, a);
}

// parse_activity: one rich presence activity, every string capped (another user's, so untrusted).
parse_activity :: (s: *Store, m: etf.Map) -> Activity {
	str :: (m: etf.Map, k: string) -> string #expand {
		v := fstr(m, k);
		if v.count > 128 {
			v.count = 128;
			while v.count > 0 && (v.data[v.count] & 0xC0) == 0x80 v.count -= 1; // on a UTF-8 boundary
		}
		return clone_str(v, `s.allocator);
	}
	ts := fmap(m, "timestamps");
	as := fmap(m, "assets");
	size := flist(fmap(m, "party"), "size");
	return .{
		kind = fint(m, "type"),
		name = str(m, "name"), details = str(m, "details"), state = str(m, "state"),
		app_id = fsnow(m, "application_id"),
		start_ms = fint(ts, "start"), end_ms = fint(ts, "end"),
		large_image = str(as, "large_image"), large_text = str(as, "large_text"),
		small_image = str(as, "small_image"), small_text = str(as, "small_text"),
		party = .[ifx size.count == 2 then clamp(vint(size[0]), 0, 1_000_000) else 0, ifx size.count == 2 then clamp(vint(size[1]), 0, 1_000_000) else 0],
		sync_id = str(m, "sync_id"),
	};
}

apply_presence :: (s: *Store, m: etf.Map, user_hint: Snowflake = 0) {
	uid := user_hint;
	um := fmap(m, "user");
	if um {
		u := parse_user_into(s, um);
		if u uid = u;
	}
	u := fsnow(m, "user_id");
	if u uid = u;
	if uid == 0 return;
	p := Presence.{user_id = uid, status = status_from_string(fstr(m, "status"))};
	cs := fmap(m, "client_status");
	if cs {
		p.desktop = status_from_string(fstr(cs, "desktop"));
		p.mobile = status_from_string(fstr(cs, "mobile"));
		p.web = status_from_string(fstr(cs, "web"));
	}
	old := table_find_pointer(*s.presences, uid);
	if old free_presence(s, old);
	for flist(m, "activities") {
		am := vmap(it);
		if fint(am, "type") != 4 && p.rich.kind < 0 && fint(am, "type") >= 0 && fint(am, "type") <= 5 p.rich = parse_activity(s, am);
		if it_index < 8 p.activity_types |= cast(u32) ((fint(am, "type") + 1) & 0xF) << (4 * it_index);
		txt := ifx fint(am, "type") == 4 then fstr(am, "state") else fstr(am, "name");
		if txt && !p.activity p.activity = clone_str(txt, s.allocator);
		VERBS :: string.["Playing", "Streaming", "Listening to", "Watching", "", "Competing in"];
		kind := fint(am, "type");
		if kind >= 0 && kind < VERBS.count && kind != 4 && txt && !p.game p.game = clone_str(tprint("% %", VERBS[kind], slice(txt, 0, min(txt.count, 128))), s.allocator);
		if fint(am, "type") == 4 && !p.custom {
			em := fmap(am, "emoji");
			emoji := ifx em && !fsnow(em, "id") then fstr(em, "name"); // custom emoji images aren't drawn here
			if emoji.count > 32 emoji = ""; // a unicode emoji is a few code points; the state is capped like Discord's
			state := slice(txt, 0, min(txt.count, 512));
			if emoji || state p.custom = clone_str(ifx emoji && state then tprint("% %", emoji, state) else ifx emoji then emoji else state, s.allocator);
		}
	}
	table_set(*s.presences, uid, p);
}

apply_voice_state :: (s: *Store, m: etf.Map, guild_hint: Snowflake = 0) {
	uid := fsnow(m, "user_id");
	gid := fsnow(m, "guild_id");
	if gid == 0 gid = guild_hint;
	mm := fmap(m, "member");
	if mm {
		u := parse_member_into(s, gid, mm);
		if uid == 0 uid = u;
	}
	if uid == 0 return;
	old := table_find_pointer(*s.voice_states, uid);
	cid := fsnow(m, "channel_id");
	// a late leave for an older session (ours before a gateway reconnect) doesn't end the newer one
	sid := fstr(m, "session_id");
	// our account joined a call on another device: Discord keeps one call per user, so ours ended
	if uid == s.me && cid && sid && sid != s.session_id && !(old && sid == old.session_id) s.voice_elsewhere += 1;
	if cid == 0 && old && sid && old.session_id && sid != old.session_id return;
	if old free_str(old.session_id, s.allocator);
	if cid == 0 {
		table_remove(*s.voice_states, uid);
		return;
	}
	table_set(*s.voice_states, uid, .{
		user_id = uid,
		channel_id = cid,
		guild_id = gid,
		session_id = clone_str(sid, s.allocator),
		self_mute = fbool(m, "self_mute"),
		self_deaf = fbool(m, "self_deaf"),
		mute = fbool(m, "mute"),
		deaf = fbool(m, "deaf"),
		self_video = fbool(m, "self_video"),
		self_stream = fbool(m, "self_stream"),
		suppress = fbool(m, "suppress"),
		requested_to_speak = vget(m, "request_to_speak_timestamp").kind == .String
	});
}

apply_relationship :: (s: *Store, m: etf.Map) {
	uid := fsnow(m, "user_id");
	um := fmap(m, "user");
	if um uid = parse_user_into(s, um);
	if uid == 0 uid = fsnow(m, "id");
	if uid == 0 return;
	r, added := find_or_add(*s.relationships, uid);
	if added r.* = .{user_id = uid};
	if vhas(m, "type") r.kind = cast(Relationship_Type) fint(m, "type");
	if vhas(m, "nickname") set_str(s, *r.nickname, fstr(m, "nickname"));
	if vhas(m, "user_ignored") r.ignored = fbool(m, "user_ignored");
	if vhas(m, "since") set_str(s, *r.since, fstr(m, "since"));
}

apply_read_state :: (s: *Store, m: etf.Map) {
	if vhas(m, "read_state_type") && fint(m, "read_state_type") != 0 return;
	cid := fsnow(m, "id");
	if cid == 0 cid = fsnow(m, "channel_id");
	if cid == 0 return;
	rs := find_or_add(*s.read_states, cid);
	rs.channel_id = cid;
	if vhas(m, "last_message_id") rs.last_message_id = fsnow(m, "last_message_id");
	if vhas(m, "message_id") rs.last_message_id = fsnow(m, "message_id");
	if vhas(m, "mention_count") rs.mention_count = fint(m, "mention_count");
	if vhas(m, "last_viewed") rs.last_viewed = fint(m, "last_viewed");
	if vhas(m, "flags") rs.flags = cast(u64) fint(m, "flags");
}

apply_guild_settings :: (s: *Store, m: etf.Map) {
	gid := fsnow(m, "guild_id");
	gs, added := find_or_add(*s.guild_settings, gid);
	if added {
		gs.* = .{guild_id = gid};
		gs.muted_channels.allocator = s.allocator;
		gs.collapsed_channels.allocator = s.allocator;
		gs.overrides.allocator = s.allocator;
	}
	gs.muted = fbool(m, "muted");
	gs.message_notifications = fint(m, "message_notifications");
	gs.suppress_everyone = fbool(m, "suppress_everyone");
	gs.suppress_roles = fbool(m, "suppress_roles");
	gs.muted_channels.count = 0;
	gs.collapsed_channels.count = 0;
	for flist(m, "channel_overrides") {
		om := vmap(it);
		if fbool(om, "muted") array_add(*gs.muted_channels, fsnow(om, "channel_id"));
		if fbool(om, "collapsed") array_add(*gs.collapsed_channels, fsnow(om, "channel_id"));
	}
	apply_guild_settings_extra(s, gs, m);
}

// ---- user_settings_proto (PreloadedUserSettings) ----

// apply_settings_proto keeps the whole proto and decodes the fields the UI uses: status (11),
// localization (12), appearance/theme (13), guild folders (14). A partial update (another
// device's delta) replaces only the categories it holds, as each delta is a whole category.
apply_settings_proto :: (s: *Store, b64: string, partial := false) {
	decoded, ok := base64_decode(b64,, temp);
	if !ok return;
	raw := cast([]u8) decoded;
	if partial {
		r := protobuf.Reader.{buf = raw};
		merged := s.settings.proto;
		while true {
			start := r.pos;
			f, more := protobuf.next(*r);
			if !more break;
			merged = protobuf.with_field(merged, f.num, array_view(raw, start, r.pos - start),, temp);
		}
		raw = merged;
	}
	// categories with an edit not yet saved keep it (sent again after a failed PATCH)
	for n: 1..63 if s.settings.unsent & ((cast(u64) 1) << n) raw = protobuf.with_field(raw, xx n, pb_categories(s.settings.proto, (cast(u64) 1) << n),, temp);
	settings_proto_set(s, raw);
}

// settings_proto_set replaces the kept proto with raw and decodes it.
settings_proto_set :: (s: *Store, new_proto: []u8) {
	st := *s.settings;
	a := s.allocator;
	if new_proto.data != st.proto.data {
		old := st.proto;
		st.proto = NewArray(new_proto.count, u8, false,, a);
		memcpy(st.proto.data, new_proto.data, new_proto.count);
		free(old.data,, a);
	}
	raw := st.proto;
	f: protobuf.Field;
	found: bool;
	f, found = protobuf.find_path(raw, 2, 1);
	st.inbox_tab = ifx found && f.value <= cast(u64) enum_highest_value(Inbox_Tab) then cast(Inbox_Tab) f.value else .Unspecified;
	f, found = protobuf.find_path(raw, 11, 1, 1);
	if found st.status = status_from_string(cast(string) f.bytes);
	// an absent field is the default: a cleared custom status leaves 11.2 out
	f, found = protobuf.find_path(raw, 11, 2, 1);
	set_str(s, *st.custom_status_text, ifx found then cast(string) f.bytes);
	f, found = protobuf.find_path(raw, 11, 2, 3);
	set_str(s, *st.custom_status_emoji, ifx found then cast(string) f.bytes);
	f, found = protobuf.find_path(raw, 11, 2, 2);
	st.custom_status_emoji_id = ifx found then f.value;
	f, found = protobuf.find_path(raw, 11, 2, 4);
	st.custom_status_expires_ms = ifx found then cast(s64) f.value;
	f, found = protobuf.find_path(raw, 11, 4);
	st.status_expires_ms = ifx found then cast(s64) f.value else 0;
	f, found = protobuf.find_path(raw, 11, 5, 1);
	if found st.status_created_ms = cast(s64) f.value;
	f, found = protobuf.find_path(raw, 12, 1, 1);
	if found set_str(s, *st.locale, cast(string) f.bytes);
	f, found = protobuf.find_path(raw, 12, 2, 1);
	if found st.timezone_offset = cast(s32) f.value;
	// The official client maps an absent/UNSET theme to its UI "Dark", which is
	// proto DARKER (bundle: {[UNSET]: DARK, [DARK]: ASH, [DARKER]: DARK, ...}).
	f, found = protobuf.find_path(raw, 13, 1);
	st.theme = ifx found && f.value != 0 then cast(Theme) f.value else .Darker;
	f, found = protobuf.find_path(raw, 13, 2);
	st.developer_mode = found && f.value != 0;
	f, found = protobuf.find_path(raw, 13, 9);
	st.hour_cycle = ifx found && f.value <= 2 then cast(Hour_Cycle) f.value else .Auto;
	_, found = protobuf.find_path(raw, 7, 12);
	if found {
		f, found = protobuf.find_path(raw, 7, 12, 1);
		st.friend_online_off = !found || f.value == 0;
	}
	for harm: 0..1 for kind: 0..2 {
		f, found = protobuf.find_path(raw, 6, cast(u32) ifx harm then 32 else 29, cast(u32) kind + 1);
		st.media_redaction[harm][kind] = ifx found then f.value else 0;
	}
	gf, has_folders := protobuf.find(raw, 14);
	if !has_folders return;
	for * st.guild_folders {
		free_str(it.name, a);
		array_free(it.guild_ids);
	}
	st.guild_folders.count = 0;
	st.guild_positions.count = 0;
	r := protobuf.Reader.{buf = gf.bytes};
	while true {
		fld, more := protobuf.next(*r);
		if !more break;
		if fld.num == {
			case 1;
				fo: Guild_Folder;
				fo.guild_ids.allocator = a;
				ids, has_ids := protobuf.find(fld.bytes, 1);
				if has_ids for protobuf.packed_fixed64(ids.bytes,, temp) array_add(*fo.guild_ids, it);
				v, vok := protobuf.find_path(fld.bytes, 2, 1);
				if vok fo.id = cast(s64) v.value;
				v, vok = protobuf.find_path(fld.bytes, 3, 1);
				if vok fo.name = clone_str(cast(string) v.bytes, a);
				v, vok = protobuf.find_path(fld.bytes, 4, 1);
				if vok {
					fo.color = v.value;
					fo.has_color = true;
				}
				array_add(*st.guild_folders, fo);
			case 2;
				for protobuf.packed_fixed64(fld.bytes,, temp) array_add(*st.guild_positions, it);
		}
	}
}

// ---- READY / READY_SUPPLEMENTAL ----

// merged_members[i] lists members (ourselves) of guilds[i].
apply_merged_members :: (s: *Store, d: etf.Map, guilds: []V) {
	for ml, i: flist(d, "merged_members") {
		if i >= guilds.count break;
		gid := fsnow(vmap(guilds[i]), "id");
		for vlist(ml) parse_member_into(s, gid, vmap(it));
	}
}

apply_ready :: (s: *Store, d: etf.Map) {
	if s.readies store_reset_session(s); // a new session: its READY is the whole state, not a delta
	s.readies += 1;
	set_str(s, *s.session_id, fstr(d, "session_id"));
	set_str(s, *s.resume_gateway_url, fstr(d, "resume_gateway_url"));
	set_str(s, *s.analytics_token, fstr(d, "analytics_token"));
	set_str(s, *s.auth_session_hash, fstr(d, "auth_session_id_hash"));
	set_str(s, *s.qos_token, fstr(d, "qos_token"));
	set_str(s, *s.country_code, fstr(d, "country_code"));
	s.me = parse_user_into(s, fmap(d, "user"));
	nsfw := vget(fmap(d, "user"), "nsfw_allowed");
	s.settings.nsfw_blocked = nsfw.kind == .Bool && !nsfw.b;
	for flist(d, "users") parse_user_into(s, vmap(it));
	guilds := flist(d, "guilds");
	for guilds parse_guild_into(s, vmap(it));
	apply_merged_members(s, d, guilds);
	s.private_channels.count = 0;
	for flist(d, "private_channels") {
		cid := parse_channel_into(s, vmap(it));
		if cid array_add(*s.private_channels, cid);
	}
	for flist(d, "relationships") apply_relationship(s, vmap(it));
	for flist(fmap(d, "read_state"), "entries") apply_read_state(s, vmap(it));
	for flist(fmap(d, "user_guild_settings"), "entries") apply_guild_settings(s, vmap(it));
	sp := fstr(d, "user_settings_proto");
	if sp apply_settings_proto(s, sp);
	apply_sessions(s, flist(d, "sessions"));
	s.ready = true;
	s.connection = .Ready;
}

apply_ready_supplemental :: (s: *Store, d: etf.Map) {
	guilds := flist(d, "guilds");
	for guilds {
		gm := vmap(it);
		gid := fsnow(gm, "id");
		for flist(gm, "voice_states") apply_voice_state(s, vmap(it), gid);
	}
	apply_merged_members(s, d, guilds);
	mp := fmap(d, "merged_presences");
	for flist(mp, "friends") apply_presence(s, vmap(it));
	for gl: flist(mp, "guilds") for vlist(gl) apply_presence(s, vmap(it));
	for flist(d, "lazy_private_channels") {
		cid := parse_channel_into(s, vmap(it));
		if cid array_add_if_unique(*s.private_channels, cid);
	}
}

apply_sessions :: (s: *Store, l: []V) {
	for s.sessions {
		free_str(it.session_id, s.allocator);
		free_str(it.client, s.allocator);
		free_str(it.os, s.allocator);
	}
	s.sessions.count = 0;
	for l {
		sm := vmap(it);
		ci := fmap(sm, "client_info");
		array_add(*s.sessions, .{
			session_id = clone_str(fstr(sm, "session_id"), s.allocator),
			status = status_from_string(fstr(sm, "status")),
			client = clone_str(fstr(ci, "client"), s.allocator),
			os = clone_str(fstr(ci, "os"), s.allocator)
		});
	}
}

// ---- member list (op 37 channels → GUILD_MEMBER_LIST_UPDATE) ----

member_list_item :: (s: *Store, guild_id: Snowflake, iv: etf.Map) -> Member_List_Item {
	g := fmap(iv, "group");
	if g {
		gid, rid := group_id_of(vget(g, "id"));
		return .{is_group = true, group_id = clone_str(gid, s.allocator), role_id = rid, count = fint(g, "count")};
	}
	mm := fmap(iv, "member");
	if mm return .{user_id = parse_member_into(s, guild_id, mm)};
	return .{};
}

// group ids are "online"/"offline" strings or role snowflakes (ETF integers).
group_id_of :: (v: V) -> string, Snowflake {
	if v.kind == {
		case .String; return v.s, parse_snowflake(v.s);
		case .Atom;   return v.s, 0;
		case .Int; #through;
		case .Big;    r := vsnow(v); return snowflake_string(r), r;
	}
	return "", 0;
}

// A guild keeps one member list per list id ("everyone", or a private channel's member_list_id).
member_list_get :: (s: *Store, guild_id: Snowflake, list_id := "everyone") -> *Member_List {
	return table_find_pointer(*s.member_lists, tprint("%:%", guild_id, list_id));
}

apply_member_list_update :: (s: *Store, d: etf.Map) {
	gid := fsnow(d, "guild_id");
	id := fstr(d, "id");
	ml := member_list_get(s, gid, id);
	if !ml {
		// any server's ids: a short string, and a bounded number of lists
		if id.count > 32 || s.member_lists.count >= 256 return;
		ml = table_set(*s.member_lists, sprint("%:%", gid, id,, s.allocator), .{});
		ml.items.allocator = s.allocator;
		ml.groups.allocator = s.allocator;
		ml.id = clone_str(id, s.allocator);
	}
	ml.member_count = fint(d, "member_count");
	ml.online_count = fint(d, "online_count");
	if vhas(d, "groups") {
		for ml.groups free_str(it.id, s.allocator);
		ml.groups.count = 0;
		for flist(d, "groups") {
			gm := vmap(it);
			group, rid := group_id_of(vget(gm, "id"));
			array_add(*ml.groups, .{clone_str(group, s.allocator), rid, fint(gm, "count")});
		}
	}
	defer {
		// Group header items carry their size from the top-level groups array.
		for * item: ml.items {
			if !item.is_group continue;
			for ml.groups if it.id == item.group_id item.count = it.count;
		}
		// The groups size the list: a header per non-empty group plus its rows. A shorter list (a member
		// went online, so the Offline header left) drops its stale tail, which would show as a duplicate.
		if vhas(d, "groups") {
			rows := 0;
			for ml.groups if it.count > 0 rows += 1 + it.count;
			while ml.items.count > rows {
				free_str(ml.items[ml.items.count - 1].group_id, s.allocator);
				ml.items.count -= 1;
			}
		}
	}
	MAX_MEMBER_LIST_ITEMS :: 1 << 17;
	for opv: flist(d, "ops") {
		op := vmap(opv);
		if fstr(op, "op") == {
			case "SYNC";
				r := flist(op, "range");
				start := ifx r.count == 2 then vint(r[0]) else 0;
				items := flist(op, "items");
				// any server's indexes: inside the list, which stays under MAX_MEMBER_LIST_ITEMS
				if start < 0 || start > MAX_MEMBER_LIST_ITEMS - items.count continue;
				if ml.items.count < start + items.count array_resize(*ml.items, start + items.count);
				for items {
					free_str(ml.items[start + it_index].group_id, s.allocator);
					ml.items[start + it_index] = member_list_item(s, gid, vmap(it));
				}
			case "INSERT";
				idx := fint(op, "index");
				if idx < 0 || ml.items.count >= MAX_MEMBER_LIST_ITEMS continue;
				item := member_list_item(s, gid, fmap(op, "item"));
				if idx >= ml.items.count array_add(*ml.items, item);
				else array_insert_at(*ml.items, item, idx);
			case "UPDATE";
				idx := fint(op, "index");
				if idx >= 0 && idx < ml.items.count {
					free_str(ml.items[idx].group_id, s.allocator);
					ml.items[idx] = member_list_item(s, gid, fmap(op, "item"));
				}
			case "DELETE";
				idx := fint(op, "index");
				if idx >= 0 && idx < ml.items.count {
					free_str(ml.items[idx].group_id, s.allocator);
					array_ordered_remove_by_index(*ml.items, idx);
				}
			case "INVALIDATE";
				r := flist(op, "range");
				if r.count != 2 continue;
				k := max(vint(r[0]), 0);
				while k <= vint(r[1]) && k < ml.items.count {
					free_str(ml.items[k].group_id, s.allocator);
					ml.items[k] = .{};
					k += 1;
				}
		}
	}
}

// ---- typing ----

TYPING_DURATION_MS :: 10_000;

store_expire_typing :: (s: *Store, now: s64) -> bool {
	changed := false;
	for * l: s.typing {
		for < l.* {
			if it.until <= now {
				array_ordered_remove_by_index(l, it_index);
				changed = true;
			}
		}
	}
	return changed;
}

apply_typing :: (s: *Store, d: etf.Map, now: s64) {
	cid := fsnow(d, "channel_id");
	uid := fsnow(d, "user_id");
	mm := fmap(d, "member");
	gid := fsnow(d, "guild_id");
	if mm && gid {
		u := parse_member_into(s, gid, mm);
		if uid == 0 uid = u;
	}
	if cid == 0 || uid == 0 return;
	l, added := find_or_add(*s.typing, cid);
	if added l.allocator = s.allocator;
	for * l.* {
		if it.user_id == uid {
			it.until = now + TYPING_DURATION_MS;
			return;
		}
	}
	array_add(l, .{uid, now + TYPING_DURATION_MS});
}

remove_typing :: (s: *Store, cid: Snowflake, uid: Snowflake) {
	l := table_find_pointer(*s.typing, cid);
	if l for l.* if it.user_id == uid {
		array_ordered_remove_by_index(l, it_index);
		return;
	}
}

// ---- reactions ----

emoji_matches :: (e: Emoji, id: Snowflake, name: string) -> bool {
	if id return e.id == id;
	return e.id == 0 && e.name == name;
}

apply_reaction :: (s: *Store, d: etf.Map, add: bool) {
	em := fmap(d, "emoji");
	e := Emoji.{id = fsnow(em, "id"), name = fstr(em, "name"), animated = fbool(em, "animated"), available = true};
	mine := fsnow(d, "user_id") == s.me;
	if mine {
		n := table_find_pointer(*s.reaction_echoes, reaction_key(fsnow(d, "message_id"), e, fbool(d, "burst")));
		if n && n.* > 0 { n.* -= 1; return; } // the echo of a request we predicted
	}
	store_reaction(s, fsnow(d, "channel_id"), fsnow(d, "message_id"), e, mine, add, fbool(d, "burst"));
}

// store_reaction: MessageRecord.addReaction / removeReaction. Our own add or remove
// is idempotent, so the gateway echo of a predicted change does nothing; in a DM
// another user's add doesn't grow a count they already fill. Burst only moves
// burst_count. e.name is copied when a reaction is added.
store_reaction :: (s: *Store, channel_id: Snowflake, message_id: Snowflake, e: Emoji, mine: bool, add: bool, burst: bool) {
	l := table_find_pointer(*s.messages, channel_id);
	if !l return;
	i := message_index(l, message_id);
	if i < 0 return;
	msg := *l.messages[i];
	for * r: msg.reactions {
		if !emoji_matches(r.emoji, e.id, e.name) continue;
		if add {
			ch := channel_get(s, channel_id);
			if ch && ch.kind == .DM && !mine && (ifx burst then r.burst_count - cast(int) r.me_burst else r.count - cast(int) r.me) >= 1 return;
			if burst {
				if mine && r.me_burst return;
				r.burst_count += 1;
				if mine r.me_burst = true;
			} else {
				if mine && r.me return;
				r.count += 1;
				if mine r.me = true;
			}
		} else if burst {
			if !(mine && !r.me_burst) r.burst_count -= 1;
			if mine r.me_burst = false;
		} else {
			if !(mine && !r.me) r.count -= 1;
			if mine r.me = false;
		}
		if r.count <= 0 && r.burst_count <= 0 {
			free_str(r.emoji.name, s.allocator);
			array_ordered_remove_by_index(*msg.reactions, it_index);
		}
		return;
	}
	if !add return;
	r := Reaction.{emoji = e, count = xx !burst, burst_count = xx burst, me = mine && !burst, me_burst = mine && burst};
	r.emoji.name = clone_str(e.name, s.allocator);
	array_add(*msg.reactions, r);
}

// ---- dispatch application ----

remove_messages :: (s: *Store, cid: Snowflake) {
	l := table_find_pointer(*s.messages, cid);
	if !l return;
	free_message_list(s, l);
	table_remove(*s.messages, cid);
}

// drop_message: forget one message locally (a failed send the user discards); nothing is sent.
drop_message :: (s: *Store, cid: Snowflake, id: Snowflake) {
	l := table_find_pointer(*s.messages, cid);
	i := ifx l then message_index(l, id) else -1;
	if i < 0 return;
	free_message(s, *l.messages[i]);
	array_ordered_remove_by_index(*l.messages, i);
	s.changed += 1;
}

remove_guild :: (s: *Store, gid: Snowflake) {
	g := table_find_pointer(*s.guilds, gid);
	if !g return;
	for cid: g.channels {
		c := table_find_pointer(*s.channels, cid);
		if c {
			free_channel(s, c);
			table_remove(*s.channels, cid);
		}
		remove_messages(s, cid); // a rejoin loads the channels again from scratch
	}
	free_guild(s, g);
	table_remove(*s.guilds, gid);
	array_ordered_remove_by_value(*s.guild_order, gid);
	if gid soundboard_drop_guild(s, gid);
	gm := table_find_pointer(*s.members, gid);
	if gm {
		for * gm.* free_member(s, it);
		deinit(gm);
		table_remove(*s.members, gid);
	}
}

remove_channel :: (s: *Store, cid: Snowflake) {
	c := table_find_pointer(*s.channels, cid);
	if !c return;
	g := table_find_pointer(*s.guilds, c.guild_id);
	if g array_ordered_remove_by_value(*g.channels, cid);
	array_ordered_remove_by_value(*s.private_channels, cid);
	free_channel(s, c);
	table_remove(*s.channels, cid);
	remove_messages(s, cid);
}

// array_ordered_remove_by_value drops the first x from a, keeping order.
array_ordered_remove_by_value :: (a: *[..]Snowflake, x: Snowflake) {
	found, i := array_find(a.*, x);
	if found array_ordered_remove_by_index(a, i);
}

// store_apply_dispatch applies one gateway dispatch. Returns false for events it ignores.
store_apply_dispatch :: (s: *Store, name: string, data: V, now: s64) -> bool {
	d := vmap(data);
	if name == {
		case "READY";
			table_reset(*s.reaction_echoes); // a new session: echoes of the old one won't come
			apply_ready(s, d);
		case "READY_SUPPLEMENTAL";
			apply_ready_supplemental(s, d);
		case "RESUMED";
			s.connection = .Ready;
		case "MESSAGE_CREATE";
			upsert_message(s, d);
			cid, author := fsnow(d, "channel_id"), fsnow(fmap(d, "author"), "id");
			remove_typing(s, cid, author);
			// our own message is read at once (ReadStateStore MESSAGE_CREATE: a local
			// ack, nothing sent; not type 46, SELF_MENTIONABLE_SYSTEM)
			if author && author == s.me && fint(d, "type") != 46 {
				rs := find_or_add(*s.read_states, cid);
				rs.channel_id = cid;
				rs.last_message_id = max(rs.last_message_id, fsnow(d, "id"));
			}
		case "MESSAGE_UPDATE";
			l := table_find_pointer(*s.messages, fsnow(d, "channel_id"));
			i := ifx l then message_index(l, fsnow(d, "id")) else -1;
			if i >= 0 parse_message_fields(s, *l.messages[i], d);
		case "MESSAGE_DELETE";
			l := table_find_pointer(*s.messages, fsnow(d, "channel_id"));
			i := ifx l then message_index(l, fsnow(d, "id")) else -1;
			if i >= 0 {
				free_message(s, *l.messages[i]);
				array_ordered_remove_by_index(*l.messages, i);
			}
		case "MESSAGE_DELETE_BULK";
			l := table_find_pointer(*s.messages, fsnow(d, "channel_id"));
			if l for flist(d, "ids") {
				i := message_index(l, vsnow(it));
				if i >= 0 {
					free_message(s, *l.messages[i]);
					array_ordered_remove_by_index(*l.messages, i);
				}
			}
		case "INTERACTION_SUCCESS"; #through;
		case "INTERACTION_FAILURE";
			apply_interaction_result(s, d, name == "INTERACTION_SUCCESS");
		case "MESSAGE_POLL_VOTE_ADD"; #through;
		case "MESSAGE_POLL_VOTE_REMOVE";
			apply_poll_vote(s, d, name == "MESSAGE_POLL_VOTE_ADD");
		case "MESSAGE_REACTION_ADD";
			apply_reaction(s, d, true);
		case "MESSAGE_REACTION_ADD_MANY";
			// big servers batch reactions: addReactionBatch, each listed user adds one
			cid, mid := fsnow(d, "channel_id"), fsnow(d, "message_id");
			for flist(d, "reactions") {
				rm := vmap(it);
				em := fmap(rm, "emoji");
				e := Emoji.{id = fsnow(em, "id"), name = fstr(em, "name"), animated = fbool(em, "animated"), available = true};
				burst := fint(rm, "reactionType") == 1 || fint(rm, "reaction_type") == 1;
				for flist(rm, "users") store_reaction(s, cid, mid, e, vsnow(it) == s.me, true, burst);
			}
		case "PASSIVE_UPDATE_V2";
			// a server whose events aren't subscribed: its channels' newest messages (unreads), voice
			// states and changed members, in one dispatch
			gid := fsnow(d, "guild_id");
			for flist(d, "updated_channels") {
				cm := vmap(it);
				ch := channel_get(s, fsnow(cm, "id"));
				if ch && ch.guild_id == gid ch.last_message_id = fsnow(cm, "last_message_id");
			}
			for flist(d, "updated_voice_states") apply_voice_state(s, vmap(it), gid);
			for flist(d, "removed_voice_states") {
				vs := table_find_pointer(*s.voice_states, vsnow(it));
				if !vs || vs.guild_id != gid continue;
				free_str(vs.session_id, s.allocator);
				table_remove(*s.voice_states, vsnow(it));
			}
			for flist(d, "updated_members") parse_member_into(s, gid, vmap(it));
		case "MESSAGE_REACTION_REMOVE";
			apply_reaction(s, d, false);
		case "MESSAGE_REACTION_REMOVE_ALL"; #through;
		case "MESSAGE_REACTION_REMOVE_EMOJI";
			l := table_find_pointer(*s.messages, fsnow(d, "channel_id"));
			i := ifx l then message_index(l, fsnow(d, "message_id")) else -1;
			if i >= 0 {
				msg := *l.messages[i];
				em := fmap(d, "emoji");
				for < msg.reactions {
					if !em || emoji_matches(it.emoji, fsnow(em, "id"), fstr(em, "name")) {
						free_str(it.emoji.name, s.allocator);
						array_ordered_remove_by_index(*msg.reactions, it_index);
					}
				}
			}
		case "MESSAGE_ACK";
			cid := fsnow(d, "channel_id");
			rs := find_or_add(*s.read_states, cid);
			rs.channel_id = cid;
			rs.last_message_id = fsnow(d, "message_id");
			rs.mention_count = fint(d, "mention_count");
			rs.manual = fbool(d, "manual");
		case "TYPING_START";
			apply_typing(s, d, now);
		case "PRESENCE_UPDATE";
			apply_presence(s, d);
		case "SESSIONS_REPLACE";
			apply_sessions(s, vlist(data));
		case "GUILD_CREATE"; #through;
		case "GUILD_UPDATE";
			parse_guild_into(s, d);
		case "GUILD_DELETE";
			gid := fsnow(d, "id");
			if fbool(d, "unavailable") {
				g := table_find_pointer(*s.guilds, gid);
				if g g.unavailable = true;
			} else {
				remove_guild(s, gid);
			}
		case "GUILD_ROLE_CREATE"; #through;
		case "GUILD_ROLE_UPDATE";
			g := table_find_pointer(*s.guilds, fsnow(d, "guild_id"));
			if !g return true;
			r := parse_role(s, fmap(d, "role"));
			for * old: g.roles {
				if old.id == r.id {
					free_role(s, old);
					old.* = r;
					return true;
				}
			}
			array_add(*g.roles, r);
		case "GUILD_ROLE_DELETE";
			g := table_find_pointer(*s.guilds, fsnow(d, "guild_id"));
			rid := fsnow(d, "role_id");
			if g for * g.roles {
				if it.id == rid {
					free_role(s, it);
					array_ordered_remove_by_index(*g.roles, it_index);
					break;
				}
			}
		case "GUILD_EMOJIS_UPDATE";
			g := table_find_pointer(*s.guilds, fsnow(d, "guild_id"));
			if g parse_emojis(s, g, flist(d, "emojis"));
		case "GUILD_STICKERS_UPDATE";
			g := table_find_pointer(*s.guilds, fsnow(d, "guild_id"));
			if g parse_stickers(s, g, flist(d, "stickers"));
		case "GUILD_MEMBER_ADD"; #through;
		case "GUILD_MEMBER_UPDATE";
			parse_member_into(s, fsnow(d, "guild_id"), d);
		case "GUILD_MEMBER_REMOVE";
			uid := fsnow(fmap(d, "user"), "id");
			gm := table_find_pointer(*s.members, fsnow(d, "guild_id"));
			m := ifx gm then table_find_pointer(gm, uid) else null;
			if m {
				free_member(s, m);
				table_remove(gm, uid);
			}
		case "GUILD_MEMBERS_CHUNK";
			gid := fsnow(d, "guild_id");
			for flist(d, "members") parse_member_into(s, gid, vmap(it));
			for flist(d, "presences") apply_presence(s, vmap(it));
		case "GUILD_MEMBER_LIST_UPDATE";
			apply_member_list_update(s, d);
		case "CHANNEL_CREATE"; #through;
		case "CHANNEL_UPDATE"; #through;
		case "THREAD_CREATE";  #through;
		case "THREAD_UPDATE";
			cid := parse_channel_into(s, d);
			c := table_find_pointer(*s.channels, cid);
			if c && c.guild_id {
				g := table_find_pointer(*s.guilds, c.guild_id);
				if g array_add_if_unique(*g.channels, cid);
			} else {
				array_add_if_unique(*s.private_channels, cid);
			}
		case "CHANNEL_DELETE"; #through;
		case "THREAD_DELETE";
			remove_channel(s, fsnow(d, "id"));
		case "CHANNEL_RECIPIENT_ADD";
			c := table_find_pointer(*s.channels, fsnow(d, "channel_id"));
			if c {
				uid := parse_user_into(s, fmap(d, "user"));
				if uid array_add_if_unique(*c.recipient_ids, uid);
			}
		case "CHANNEL_RECIPIENT_REMOVE";
			c := table_find_pointer(*s.channels, fsnow(d, "channel_id"));
			if c array_ordered_remove_by_value(*c.recipient_ids, fsnow(fmap(d, "user"), "id"));
		case "RELATIONSHIP_ADD"; #through;
		case "RELATIONSHIP_UPDATE";
			apply_relationship(s, d);
		case "USER_NOTE_UPDATE";
			note_set_local(s, fsnow(d, "id"), fstr(d, "note"));
		case "RELATIONSHIP_REMOVE";
			uid := fsnow(d, "id");
			r := table_find_pointer(*s.relationships, uid);
			if r {
				free_str(r.nickname, s.allocator);
				free_str(r.since, s.allocator);
				table_remove(*s.relationships, uid);
			}
		case "USER_UPDATE";
			parse_user_into(s, d);
		case "USER_SETTINGS_PROTO_UPDATE";
			sm := fmap(d, "settings");
			if sm && fint(sm, "type") == 1 apply_settings_proto(s, fstr(sm, "proto"), fbool(d, "partial"));
			if sm && fint(sm, "type") == FRECENCY_SETTINGS_TYPE frecency_remote_update(s, fstr(sm, "proto"), fbool(d, "partial"));
		case "USER_GUILD_SETTINGS_UPDATE";
			apply_guild_settings(s, d);
		case "CHANNEL_INFO"; // op 43's reply: {guild_id, channels: [{id, status?, voice_start_time?}]}
			gid := fsnow(d, "guild_id");
			for flist(d, "channels") {
				cm := vmap(it);
				c := table_find_pointer(*s.channels, fsnow(cm, "id"));
				if c && c.guild_id == gid && vhas(cm, "status") set_channel_status(s, c, fstr(cm, "status"));
			}
		case "VOICE_CHANNEL_STATUS_UPDATE"; // {id, guild_id, status}
			c := table_find_pointer(*s.channels, fsnow(d, "id"));
			if c && c.guild_id == fsnow(d, "guild_id") set_channel_status(s, c, fstr(d, "status"));
		case "VOICE_STATE_UPDATE";
			apply_voice_state(s, d);
		case "VOICE_SERVER_UPDATE";
			vs := *s.voice_server;
			vs.guild_id = fsnow(d, "guild_id");
			vs.channel_id = fsnow(d, "channel_id");
			set_str(s, *vs.token, fstr(d, "token"));
			set_str(s, *vs.endpoint, fstr(d, "endpoint"));
			vs.version += 1;
		case "STREAM_CREATE"; #through;
		case "STREAM_UPDATE";
			st := stream_find_or_add(s, fstr(d, "stream_key"));
			if vhas(d, "rtc_server_id") st.rtc_server_id = fsnow(d, "rtc_server_id");
			st.paused = fbool(d, "paused");
		case "STREAM_SERVER_UPDATE";
			st := stream_find_or_add(s, fstr(d, "stream_key"));
			set_str(s, *st.token, fstr(d, "token"));
			set_str(s, *st.endpoint, fstr(d, "endpoint"));
			st.version += 1;
		case "STREAM_DELETE";
			key := fstr(d, "stream_key");
			for * s.streams if it.key == key {
				stream_free(s, it);
				array_unordered_remove_by_index(*s.streams, it_index);
				break;
			}
		case;
			return soundboard_dispatch(s, name, d);
	}
	return true;
}

// ---- REST results ----

// store_apply_messages merges a GET /channels/{id}/messages page (newest first).
store_apply_messages :: (s: *Store, channel_id: Snowflake, data: V, limit: int, before: bool) {
	l := message_list(s, channel_id);
	items := vlist(data);
	for items upsert_message(s, vmap(it));
	l.loaded = true;
	l.loading = false;
	l.has_more_before = items.count >= limit;
}

// ---- read helpers for the UI ----

user_get :: (s: *Store, id: Snowflake) -> *User { return table_find_pointer(*s.users, id); }
channel_get :: (s: *Store, id: Snowflake) -> *Channel { return table_find_pointer(*s.channels, id); }
guild_get :: (s: *Store, id: Snowflake) -> *Guild { return table_find_pointer(*s.guilds, id); }

member_get :: (s: *Store, guild_id: Snowflake, user_id: Snowflake) -> *Member {
	gm := table_find_pointer(*s.members, guild_id);
	return ifx gm then table_find_pointer(gm, user_id) else null;
}

// The messages shown: after a jump to an older stretch, that stretch (not the stored present side).
messages_get :: (s: *Store, channel_id: Snowflake) -> []Message {
	l := table_find_pointer(*s.messages, channel_id);
	if !l return .[];
	if l.gap_after return array_view(l.messages, 0, message_search(l, l.gap_after + 1));
	return l.messages;
}

// The oldest stored (sent) message on the present side of a jump's gap, 0 for none.
present_oldest :: (l: *Message_List) -> Snowflake {
	for i: message_search(l, l.gap_after + 1)..l.messages.count - 1 if !l.messages[i].pending && !l.messages[i].failed return l.messages[i].id;
	return 0;
}

// Drops the stretch a jump showed (the messages up to gap_after), so the present side shows again.
drop_jumped_stretch :: (s: *Store, l: *Message_List) {
	if !l.gap_after return;
	n := message_search(l, l.gap_after + 1);
	for i: 0..n - 1 free_message(s, *l.messages[i]);
	for i: n..l.messages.count - 1 l.messages[i - n] = l.messages[i];
	l.messages.count -= n;
	l.gap_after = 0;
	l.has_more_before = true;
}

channel_unread :: (s: *Store, channel_id: Snowflake) -> bool {
	c := table_find_pointer(*s.channels, channel_id);
	if !c return false;
	rs := table_find_pointer(*s.read_states, channel_id);
	return c.last_message_id > (ifx rs then rs.last_message_id else 0);
}

// guild_channels_sorted returns channel ids in sidebar order: uncategorized
// first, then each category followed by its children, by (position, id).
// The channels we may see (View Channel), in sidebar order. Discord sends every channel of a server; the
// client lists only those, and a category only while it shows one (or is empty, or we manage channels).
// A server whose roles haven't arrived hides nothing.
guild_channels_sorted :: (s: *Store, guild_id: Snowflake, allocator := temp) -> []Snowflake {
	g := table_find_pointer(*s.guilds, guild_id);
	if !g return .[];
	roles := my_roles(s, guild_id);
	base := compute_base_permissions(g, s.me, roles);
	hidden :: (s: *Store, g: *Guild, c: *Channel, base: u64, roles: []Snowflake) -> bool {
		return g.roles.count > 0 && !(compute_overwrites(base, g.id, s.me, roles, c.overwrites) & PERM_VIEW_CHANNEL);
	}
	// Keys are computed once per channel, not per comparison: map lookups dominate otherwise.
	Keyed :: struct {
		parent_pos: int;
		parent_id: Snowflake;
		is_cat: bool;
		voiceish: bool;
		pos: int;
		id: Snowflake;
	}
	keyed := NewArray(g.channels.count, Keyed,, temp);
	for id, i: g.channels {
		k := *keyed[i];
		k.id = id;
		c := table_find_pointer(*s.channels, id);
		if !c continue;
		k.voiceish = c.kind == .Guild_Voice || c.kind == .Guild_Stage_Voice;
		if c.kind == .Guild_Category {
			k.parent_pos, k.parent_id, k.is_cat, k.voiceish, k.pos = c.position, c.id, true, false, -1;
		} else if c.parent_id == 0 {
			k.parent_pos, k.pos = -1, c.position;
		} else {
			p := table_find_pointer(*s.channels, c.parent_id);
			if p k.parent_pos, k.parent_id = p.position, p.id;
			k.pos = c.position;
		}
	}
	quick_sort(keyed, (a: Keyed, b: Keyed) -> s64 {
		if a.parent_pos != b.parent_pos return ifx a.parent_pos < b.parent_pos then -1 else 1;
		if a.parent_id != b.parent_id return ifx a.parent_id < b.parent_id then -1 else 1;
		if a.is_cat != b.is_cat return ifx a.is_cat then -1 else 1;
		if a.voiceish != b.voiceish return ifx b.voiceish then -1 else 1;
		if a.pos != b.pos return ifx a.pos < b.pos then -1 else 1;
		return ifx a.id < b.id then -1 else ifx a.id > b.id then 1 else 0;
	});
	out: [..]Snowflake;
	out.allocator = allocator;
	array_reserve(*out, keyed.count);
	for k: keyed {
		c := table_find_pointer(*s.channels, k.id);
		if !c { array_add(*out, k.id); continue; }
		if hidden(s, g, c, base, roles) continue;
		if k.is_cat && !(base & PERM_MANAGE_CHANNELS) {
			// a category whose channels are all hidden from us goes too
			children, shown := 0, 0;
			for keyed if it.parent_id == k.id && !it.is_cat {
				children += 1;
				ch := table_find_pointer(*s.channels, it.id);
				if ch && !hidden(s, g, ch, base, roles) shown += 1;
			}
			if children && !shown continue;
		}
		array_add(*out, k.id);
	}
	return out;
}

// private_channels_sorted: DMs by last activity, newest first.
private_channels_sorted :: (s: *Store, allocator := temp, requests := false) -> []Snowflake {
	Keyed :: struct { last, id: Snowflake; }
	keyed := NewArray(s.private_channels.count, Keyed,, temp);
	n := 0;
	for id: s.private_channels {
		c := table_find_pointer(*s.channels, id);
		if c && (c.msg_request || c.spam) != requests continue;
		if !c && requests continue;
		keyed[n] = .{ifx c then max(c.last_message_id, id) else id, id};
		n += 1;
	}
	keyed.count = n;
	quick_sort(keyed, (a: Keyed, b: Keyed) -> s64 { return ifx a.last > b.last then -1 else ifx a.last < b.last then 1 else 0; });
	ids := NewArray(keyed.count, Snowflake,, allocator);
	for keyed ids[it_index] = it.id;
	return ids;
}

typing_users :: (s: *Store, channel_id: Snowflake) -> []Typing {
	l := table_find_pointer(*s.typing, channel_id);
	if !l return .[];
	return l.*;
}

// store_destroy frees everything the store owns.
// store_reset_session: what a fresh READY replaces (the official stores reset on CONNECTION_OPEN): servers,
// channels, members, presences, friends, read states, voice states. Users stay cached; loaded message
// lists go stale, so the next view refetches them (MessageStore CONNECTION_OPEN: ready = false).
store_reset_session :: (s: *Store) {
	push_allocator(s.allocator);
	a := s.allocator;
	for * s.guilds free_guild(s, it);
	table_reset(*s.guilds);
	s.guild_order.count = 0;
	for * s.channels free_channel(s, it);
	table_reset(*s.channels);
	s.private_channels.count = 0;
	for * gm: s.members {
		for * gm free_member(s, it);
		deinit(gm);
	}
	table_reset(*s.members);
	for * s.presences free_presence(s, it);
	table_reset(*s.presences);
	for s.relationships {
		free_str(it.nickname, a);
		free_str(it.since, a);
	}
	table_reset(*s.relationships);
	table_reset(*s.read_states);
	for s.guild_settings {
		array_free(it.muted_channels);
		array_free(it.collapsed_channels);
		array_free(it.overrides);
	}
	table_reset(*s.guild_settings);
	for s.voice_states free_str(it.session_id, a);
	table_reset(*s.voice_states);
	for s.typing array_free(it);
	table_reset(*s.typing);
	for ml, key: s.member_lists {
		for ml.items free_str(it.group_id, a);
		array_free(ml.items);
		for ml.groups free_str(it.id, a);
		array_free(ml.groups);
		free_str(ml.id, a);
		free_str(key, a);
	}
	table_reset(*s.member_lists);
	for * s.streams stream_free(s, it);
	s.streams.count = 0;
	for * s.messages if it.loaded {
		it.loaded = false;
		it.stale = true;
	}
}

store_destroy :: (s: *Store) {
	push_allocator(s.allocator);
	store_reset_session(s);
	frecency_free(s);
	soundboard_free(s);
	deinit(*s.reaction_echoes);
	extras_destroy(s);
	a := s.allocator;
	for * s.users free_user(s, it);
	deinit(*s.users);
	deinit(*s.guilds);
	array_free(s.guild_order);
	deinit(*s.channels);
	array_free(s.private_channels);
	deinit(*s.members);
	for * s.messages free_message_list(s, it);
	deinit(*s.messages);
	deinit(*s.presences);
	deinit(*s.relationships);
	deinit(*s.read_states);
	deinit(*s.guild_settings);
	deinit(*s.voice_states);
	deinit(*s.typing);
	deinit(*s.member_lists);
	for s.sessions {
		free_str(it.session_id, a);
		free_str(it.client, a);
		free_str(it.os, a);
	}
	array_free(s.sessions);
	st := *s.settings;
	free_str(st.custom_status_text, a);
	free_str(st.custom_status_emoji, a);
	free_str(st.locale, a);
	for st.guild_folders {
		free_str(it.name, a);
		array_free(it.guild_ids);
	}
	array_free(st.guild_folders);
	array_free(st.guild_positions);
	free_str(s.voice_server.token, a);
	free_str(s.voice_server.endpoint, a);
	array_free(s.streams);
	free_str(s.session_id, a);
	free_str(s.resume_gateway_url, a);
	free_str(s.analytics_token, a);
	free_str(s.qos_token, a);
	free_str(s.country_code, a);
	s.* = .{};
}

stream_find_or_add :: (s: *Store, key: string) -> *Go_Live_Stream {
	for * s.streams if it.key == key return it;
	st := array_add(*s.streams);
	st.key = clone_str(key, s.allocator);
	return st;
}

stream_free :: (s: *Store, st: *Go_Live_Stream) {
	free_str(st.key, s.allocator);
	free_str(st.endpoint, s.allocator);
	free_str(st.token, s.allocator);
}
