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
	session_id: string;
	me: Snowflake;
	users: Table(Snowflake, User);
	guilds: Table(Snowflake, Guild);
	guild_order: [..]Snowflake; // READY order (see settings.guild_folders for the sidebar)
	channels: Table(Snowflake, Channel);
	private_channels: [..]Snowflake;
	members: Table(Snowflake, Table(Snowflake, Member)); // guild -> user -> member
	messages: Table(Snowflake, Message_List); // channel -> messages
	presences: Table(Snowflake, Presence);
	relationships: Table(Snowflake, Relationship);
	read_states: Table(Snowflake, Read_State);
	guild_settings: Table(Snowflake, Guild_Settings);
	voice_states: Table(Snowflake, Voice_State); // user -> state (one voice connection per user)
	typing: Table(Snowflake, [..]Typing); // channel -> typers
	member_lists: Table(Snowflake, Member_List); // guild -> member sidebar
	sessions: [..]Session_Info;
	settings: User_Settings;
	voice_server: Voice_Server;
	streams: [..]Go_Live_Stream;
	resume_gateway_url: string;
	analytics_token: string;
	qos_token: string; // READY qos_token (base64 DerivedQosData) for reconnect IDENTIFY
	country_code: string;
	// Our own reaction requests whose gateway echo hasn't come yet, per reaction_key. Those
	// echoes are skipped: the store already shows the outcome, and an old echo arriving
	// after a newer click would undo it (on, off, on ended off).
	reaction_echoes: Table(u64, int);
}

reaction_key :: (message_id: Snowflake, e: Emoji, burst: bool) -> u64 {
	h := get_hash(message_id, ifx e.id then get_hash(e.id) else get_hash(e.name));
	return (cast(u64) h << 1) | cast(u64) burst;
}

store_init :: (s: *Store, allocator := context.allocator) {
	s.allocator = allocator;
	s.reaction_echoes.allocator = allocator;
	s.users.allocator = allocator;
	s.guilds.allocator = allocator;
	s.guild_order.allocator = allocator;
	s.channels.allocator = allocator;
	s.private_channels.allocator = allocator;
	s.members.allocator = allocator;
	s.messages.allocator = allocator;
	s.presences.allocator = allocator;
	s.relationships.allocator = allocator;
	s.read_states.allocator = allocator;
	s.guild_settings.allocator = allocator;
	s.voice_states.allocator = allocator;
	s.streams.allocator = allocator;
	s.typing.allocator = allocator;
	s.member_lists.allocator = allocator;
	s.sessions.allocator = allocator;
	s.settings.guild_folders.allocator = allocator;
	s.settings.guild_positions.allocator = allocator;
}

// set_str replaces a store string with a copy of v.
set_str :: (s: *Store, dst: *string, v: string) {
	free_str(dst.*, s.allocator);
	dst.* = clone_str(v, s.allocator);
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
}

free_channel :: (s: *Store, c: *Channel) {
	a := s.allocator;
	free_str(c.name, a);
	free_str(c.topic, a);
	free_str(c.icon, a);
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
	free_str(e.provider, a);
	free_str(e.author_name, a);
}

free_message :: (s: *Store, m: *Message) {
	a := s.allocator;
	free_str(m.content, a);
	free_str(m.timestamp, a);
	free_str(m.edited_timestamp, a);
	free_str(m.call_ended, a);
	free_str(m.forward_timestamp, a);
	free_str(m.nonce, a);
	for * m.attachments free_attachment(s, it);
	array_free(m.attachments);
	for * m.embeds free_embed(s, it);
	array_free(m.embeds);
	for m.reactions free_str(it.emoji.name, a);
	array_free(m.reactions);
	array_free(m.sticker_ids);
	array_free(m.mentions);
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
	return id;
}

// parse_channel_into creates or updates a channel (guild_id may be implied by the container).
parse_channel_into :: (s: *Store, m: etf.Map, guild_id: Snowflake = 0) -> Snowflake {
	id := fsnow(m, "id");
	if id == 0 return 0;
	c, added := find_or_add(*s.channels, id);
	if added {
		c.* = .{id = id};
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
	if vhas(m, "owner_id") c.owner_id = fsnow(m, "owner_id");
	if vhas(m, "flags") c.flags = cast(u64) fint(m, "flags");
	if vhas(m, "permission_overwrites") {
		c.overwrites.count = 0;
		for flist(m, "permission_overwrites") {
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
		unicode_emoji = clone_str(fstr(m, "unicode_emoji"), a)
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
	if vhas(m, "joined_at") set_str(s, *member.joined_at, fstr(m, "joined_at"));
	if vhas(m, "flags") member.flags = cast(u64) fint(m, "flags");
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

parse_embed :: (m: etf.Map, a: Allocator) -> Embed {
	e := Embed.{
		kind = clone_str(fstr(m, "type"), a),
		title = clone_str(fstr(m, "title"), a),
		description = clone_str(fstr(m, "description"), a),
		url = clone_str(fstr(m, "url"), a),
		color = cast(u32) fint(m, "color")
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
	if p e.provider = clone_str(fstr(p, "name"), a);
	au := fmap(m, "author");
	if au e.author_name = clone_str(fstr(au, "name"), a);
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
	if vhas(m, "type") msg.kind = fint(m, "type");
	if vhas(m, "timestamp") set_str(s, *msg.timestamp, fstr(m, "timestamp"));
	if vhas(m, "edited_timestamp") set_str(s, *msg.edited_timestamp, fstr(m, "edited_timestamp"));
	call := fmap(m, "call");
	if call set_str(s, *msg.call_ended, fstr(call, "ended_timestamp"));
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
	}
	// Keep the referenced author resolvable for reply previews.
	rau := fmap(fmap(m, "referenced_message"), "author");
	if rau parse_user_into(s, rau);
	gid := fsnow(m, "guild_id");
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
		if it.pending && it.nonce == nonce {
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
	if old free_str(old.activity, s.allocator);
	for flist(m, "activities") {
		am := vmap(it);
		txt := ifx fint(am, "type") == 4 then fstr(am, "state") else fstr(am, "name");
		if txt {
			p.activity = clone_str(txt, s.allocator);
			break;
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
	// diagnostics for our own voice state going missing mid-call (TODO.md); session ids cut to 4 chars
	if uid == s.me {
		tail :: (x: string) -> string { return ifx x.count > 4 then slice(x, x.count - 4, 4) else x; }
		print("[voice] own state: channel % session % (stored % %, gateway %)\n", cid, tail(sid), ifx old then old.channel_id else 0, tail(ifx old then old.session_id else ""), tail(s.session_id), to_standard_error = true);
	}
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
		self_stream = fbool(m, "self_stream")
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

// apply_settings_proto decodes the fields the UI uses: status (11), localization
// (12), appearance/theme (13), guild folders (14).
apply_settings_proto :: (s: *Store, b64: string) {
	decoded, ok := base64_decode(b64,, temp);
	if !ok return;
	raw := cast([]u8) decoded;
	st := *s.settings;
	a := s.allocator;
	f: protobuf.Field;
	found: bool;
	f, found = protobuf.find_path(raw, 2, 1);
	if found st.inbox_tab = ifx f.value <= cast(u64) enum_highest_value(Inbox_Tab) then cast(Inbox_Tab) f.value else .Unspecified;
	f, found = protobuf.find_path(raw, 11, 1, 1);
	if found st.status = status_from_string(cast(string) f.bytes);
	f, found = protobuf.find_path(raw, 11, 2, 1);
	if found set_str(s, *st.custom_status_text, cast(string) f.bytes);
	f, found = protobuf.find_path(raw, 11, 2, 3);
	if found set_str(s, *st.custom_status_emoji, cast(string) f.bytes);
	f, found = protobuf.find_path(raw, 11, 2, 2);
	if found st.custom_status_emoji_id = f.value;
	f, found = protobuf.find_path(raw, 11, 2, 4);
	if found st.custom_status_expires_ms = cast(s64) f.value;
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
	if found st.developer_mode = f.value != 0;
	_, found = protobuf.find_path(raw, 7, 12);
	if found {
		f, found = protobuf.find_path(raw, 7, 12, 1);
		st.friend_online_off = !found || f.value == 0;
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
	s.readies += 1;
	set_str(s, *s.session_id, fstr(d, "session_id"));
	set_str(s, *s.resume_gateway_url, fstr(d, "resume_gateway_url"));
	set_str(s, *s.analytics_token, fstr(d, "analytics_token"));
	set_str(s, *s.qos_token, fstr(d, "qos_token"));
	set_str(s, *s.country_code, fstr(d, "country_code"));
	s.me = parse_user_into(s, fmap(d, "user"));
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

apply_member_list_update :: (s: *Store, d: etf.Map) {
	gid := fsnow(d, "guild_id");
	ml, added := find_or_add(*s.member_lists, gid);
	if added {
		ml.* = .{};
		ml.items.allocator = s.allocator;
		ml.groups.allocator = s.allocator;
	}
	id := fstr(d, "id");
	if ml.id != id set_str(s, *ml.id, id);
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
	}
	for opv: flist(d, "ops") {
		op := vmap(opv);
		if fstr(op, "op") == {
			case "SYNC";
				r := flist(op, "range");
				start := ifx r.count == 2 then vint(r[0]) else 0;
				items := flist(op, "items");
				if ml.items.count < start + items.count array_resize(*ml.items, start + items.count);
				for items {
					free_str(ml.items[start + it_index].group_id, s.allocator);
					ml.items[start + it_index] = member_list_item(s, gid, vmap(it));
				}
			case "INSERT";
				idx := fint(op, "index");
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
				k := vint(r[0]);
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
		case "MESSAGE_REACTION_ADD";
			apply_reaction(s, d, true);
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
			if sm && fint(sm, "type") == 1 apply_settings_proto(s, fstr(sm, "proto"));
		case "USER_GUILD_SETTINGS_UPDATE";
			apply_guild_settings(s, d);
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
			return false;
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

messages_get :: (s: *Store, channel_id: Snowflake) -> []Message {
	l := table_find_pointer(*s.messages, channel_id);
	if !l return .[];
	return l.messages;
}

channel_unread :: (s: *Store, channel_id: Snowflake) -> bool {
	c := table_find_pointer(*s.channels, channel_id);
	if !c return false;
	rs := table_find_pointer(*s.read_states, channel_id);
	return c.last_message_id > (ifx rs then rs.last_message_id else 0);
}

// guild_channels_sorted returns channel ids in sidebar order: uncategorized
// first, then each category followed by its children, by (position, id).
guild_channels_sorted :: (s: *Store, guild_id: Snowflake, allocator := temp) -> []Snowflake {
	g := table_find_pointer(*s.guilds, guild_id);
	if !g return .[];
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
	ids := NewArray(keyed.count, Snowflake,, allocator);
	for keyed ids[it_index] = it.id;
	return ids;
}

// private_channels_sorted: DMs by last activity, newest first.
private_channels_sorted :: (s: *Store, allocator := temp) -> []Snowflake {
	Keyed :: struct { last, id: Snowflake; }
	keyed := NewArray(s.private_channels.count, Keyed,, temp);
	for id, i: s.private_channels {
		c := table_find_pointer(*s.channels, id);
		keyed[i] = .{ifx c then max(c.last_message_id, id) else id, id};
	}
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
store_destroy :: (s: *Store) {
	push_allocator(s.allocator);
	deinit(*s.reaction_echoes);
	extras_destroy();
	a := s.allocator;
	for * s.users free_user(s, it);
	deinit(*s.users);
	for * s.guilds free_guild(s, it);
	deinit(*s.guilds);
	array_free(s.guild_order);
	for * s.channels free_channel(s, it);
	deinit(*s.channels);
	array_free(s.private_channels);
	for * gm: s.members {
		for * gm free_member(s, it);
		deinit(gm);
	}
	deinit(*s.members);
	for * s.messages free_message_list(s, it);
	deinit(*s.messages);
	for s.presences free_str(it.activity, a);
	deinit(*s.presences);
	for s.relationships {
		free_str(it.nickname, a);
		free_str(it.since, a);
	}
	deinit(*s.relationships);
	deinit(*s.read_states);
	for s.guild_settings {
		array_free(it.muted_channels);
		array_free(it.collapsed_channels);
		array_free(it.overrides);
	}
	deinit(*s.guild_settings);
	for s.voice_states free_str(it.session_id, a);
	deinit(*s.voice_states);
	for s.typing array_free(it);
	deinit(*s.typing);
	for ml: s.member_lists {
		for ml.items free_str(it.group_id, a);
		array_free(ml.items);
		for ml.groups free_str(it.id, a);
		array_free(ml.groups);
		free_str(ml.id, a);
	}
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
	for * s.streams stream_free(s, it);
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
