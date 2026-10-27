// Store is the client-side cache the UI reads directly every frame.
// It is only mutated on the UI thread (client_poll drains the event queue),
// so readers need no locks. `changed` increases after every mutation batch.
Store :: struct {
	allocator: Allocator;
	changed: u64;
	connection: Connection_State;
	ready: bool;
	session_id: string;
	me: Snowflake;
	users: Map(Snowflake, User);
	guilds: Map(Snowflake, Guild);
	guild_order: [..]Snowflake; // READY order (see settings.guild_folders for the sidebar)
	channels: Map(Snowflake, Channel);
	private_channels: [..]Snowflake;
	members: Map(Snowflake, Map(Snowflake, Member)); // guild -> user -> member
	messages: Map(Snowflake, Message_List); // channel -> messages
	presences: Map(Snowflake, Presence);
	relationships: Map(Snowflake, Relationship);
	read_states: Map(Snowflake, Read_State);
	guild_settings: Map(Snowflake, Guild_Settings);
	voice_states: Map(Snowflake, Voice_State); // user -> state (one voice connection per user)
	typing: Map(Snowflake, [..]Typing); // channel -> typers
	member_lists: Map(Snowflake, Member_List); // guild -> member sidebar
	sessions: [..]Session_Info;
	settings: User_Settings;
	voice_server: Voice_Server;
	resume_gateway_url: string;
	analytics_token: string;
	qos_token: string; // READY qos_token (base64 DerivedQosData) for reconnect IDENTIFY
	country_code: string;
}

store_init :: (s: *Store, allocator := context.allocator) {
	s.allocator = allocator;
	push_allocator(allocator);
	s.users = Map(Snowflake, User).{};
	s.guilds = Map(Snowflake, Guild).{};
	s.guild_order = make_dynamic(Snowflake, 0, 0);
	s.channels = Map(Snowflake, Channel).{};
	s.private_channels = make_dynamic(Snowflake, 0, 0);
	s.members = Map(Snowflake, Map(Snowflake, Member)).{};
	s.messages = Map(Snowflake, Message_List).{};
	s.presences = Map(Snowflake, Presence).{};
	s.relationships = Map(Snowflake, Relationship).{};
	s.read_states = Map(Snowflake, Read_State).{};
	s.guild_settings = Map(Snowflake, Guild_Settings).{};
	s.voice_states = Map(Snowflake, Voice_State).{};
	s.typing = Map(Snowflake, [..]Typing).{};
	s.member_lists = Map(Snowflake, Member_List).{};
	s.sessions = make_dynamic(Session_Info, 0, 0);
}
#scope_module

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
	delete(c.recipient_ids);
	delete(c.overwrites);
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
	delete(g.channels);
	for * r: g.roles { free_role(s, *r); }
	delete(g.roles);
	for e: g.emojis { free_str(e.name, a); }
	delete(g.emojis);
	for st: g.stickers {
		free_str(st.name, a);
		free_str(st.description, a);
	}
	delete(g.stickers);
	for f: g.features { free_str(f, a); }
	delete(g.features);
}

free_member :: (s: *Store, m: *Member) {
	free_str(m.nick, s.allocator);
	free_str(m.avatar, s.allocator);
	free_str(m.joined_at, s.allocator);
	delete(m.roles);
}

free_attachment :: (s: *Store, at: *Attachment) {
	a := s.allocator;
	free_str(at.filename, a);
	free_str(at.content_type, a);
	free_str(at.url, a);
	free_str(at.proxy_url, a);
	free_str(at.waveform, a);
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
	free_str(m.nonce, a);
	for * at: m.attachments { free_attachment(s, *at); }
	delete(m.attachments);
	for * e: m.embeds { free_embed(s, *e); }
	delete(m.embeds);
	for r: m.reactions { free_str(r.emoji.name, a); }
	delete(m.reactions);
	delete(m.sticker_ids);
	delete(m.mentions);
}
#scope_export

// ---- parsers (ETF or JSON value -> model, strings cloned into the store) ----

parse_user_into :: (s: *Store, m: etf.Map) -> Snowflake {
	if m == null { return 0; }
	id := fsnow(m, "id");
	if id == 0 { return 0; }
	a := s.allocator;
	u, exists := map_find_ptr(*s.users, id);
	if !exists {
		at(*s.users, id).* = User.{id = id, mutual_guilds = -1, mutual_friends = -1};
		u = at(*s.users, id);
	}
	// Partial user objects (presence updates) only carry what changed.
	if vhas(m, "username") {free_str(u.username, a); u.username = clone_str(fstr(m, "username"), a);}
	if vhas(m, "global_name") {free_str(u.global_name, a); u.global_name = clone_str(fstr(m, "global_name"), a);}
	if vhas(m, "discriminator") {free_str(u.discriminator, a); u.discriminator = clone_str(fstr(m, "discriminator"), a);}
	if vhas(m, "avatar") {free_str(u.avatar, a); u.avatar = clone_str(fstr(m, "avatar"), a);}
	if vhas(m, "banner") {free_str(u.banner, a); u.banner = clone_str(fstr(m, "banner"), a);}
	if vhas(m, "bio") {free_str(u.bio, a); u.bio = clone_str(fstr(m, "bio"), a);}
	if vhas(m, "pronouns") {free_str(u.pronouns, a); u.pronouns = clone_str(fstr(m, "pronouns"), a);}
	if vhas(m, "accent_color") {
		ac := vget(m, "accent_color");
		u.accent_color = ifx ac == null then null else cast(u32)(vint(ac));
	}
	if vhas(m, "bot") { u.bot = fbool(m, "bot"); }
	if vhas(m, "public_flags") { u.flags = cast(u64)(fint(m, "public_flags")); }
	if vhas(m, "flags") { u.flags = cast(u64)(fint(m, "flags")); }
	if vhas(m, "premium_type") { u.premium_type = cast(int)(fint(m, "premium_type")); }
	return id;
}
#scope_module

parse_overwrites :: (out: *[..]Overwrite, l: []V) {
	clear(out);
	for ov: l {
		om := vmap(ov);
		append(out, Overwrite.{
			id = fsnow(om, "id"),
			kind = cast(u8)(fint(om, "type")),
			allow = cast(u64)(fint(om, "allow")),
			deny = cast(u64)(fint(om, "deny"))
		});
	}
}
#scope_export

// parse_channel_into creates or updates a channel (guild_id may be implied by the container).
parse_channel_into :: (s: *Store, m: etf.Map, guild_id: Snowflake = 0) -> Snowflake {
	id := fsnow(m, "id");
	if id == 0 { return 0; }
	a := s.allocator;
	c, exists := map_find_ptr(*s.channels, id);
	if !exists {
		at(*s.channels, id).* = Channel.{id = id};
		c = at(*s.channels, id);
		c.recipient_ids = make_dynamic(Snowflake, a, a);
		c.overwrites = make_dynamic(Overwrite, a, a);
	}
	if vhas(m, "type") { c.kind = cast(Channel_Type)(fint(m, "type")); }
	gid := fsnow(m, "guild_id");
	if gid != 0 { c.guild_id = gid; } else if guild_id != 0 { c.guild_id = guild_id; }
	if vhas(m, "parent_id") { c.parent_id = fsnow(m, "parent_id"); }
	if vhas(m, "name") {free_str(c.name, a); c.name = clone_str(fstr(m, "name"), a);}
	if vhas(m, "topic") {free_str(c.topic, a); c.topic = clone_str(fstr(m, "topic"), a);}
	if vhas(m, "icon") {free_str(c.icon, a); c.icon = clone_str(fstr(m, "icon"), a);}
	if vhas(m, "position") { c.position = cast(int)(fint(m, "position")); }
	if vhas(m, "nsfw") { c.nsfw = fbool(m, "nsfw"); }
	if vhas(m, "last_message_id") { c.last_message_id = fsnow(m, "last_message_id"); }
	if vhas(m, "rate_limit_per_user") { c.rate_limit_per_user = cast(int)(fint(m, "rate_limit_per_user")); }
	if vhas(m, "bitrate") { c.bitrate = cast(int)(fint(m, "bitrate")); }
	if vhas(m, "user_limit") { c.user_limit = cast(int)(fint(m, "user_limit")); }
	if vhas(m, "owner_id") { c.owner_id = fsnow(m, "owner_id"); }
	if vhas(m, "flags") { c.flags = cast(u64)(fint(m, "flags")); }
	if vhas(m, "permission_overwrites") { parse_overwrites(*c.overwrites, flist(m, "permission_overwrites")); }
	if vhas(m, "recipient_ids") {
		clear(*c.recipient_ids);
		for r: flist(m, "recipient_ids") { append(*c.recipient_ids, vsnow(r)); }
	} else if vhas(m, "recipients") {
		clear(*c.recipient_ids);
		for r: flist(m, "recipients") {
			uid := parse_user_into(s, vmap(r));
			if uid != 0 { append(*c.recipient_ids, uid); }
		}
	}
	return id;
}
#scope_module

parse_role :: (s: *Store, m: etf.Map) -> Role {
	a := s.allocator;
	r := Role.{
		id = fsnow(m, "id"),
		name = clone_str(fstr(m, "name"), a),
		color = cast(u32)(fint(m, "color")),
		position = cast(int)(fint(m, "position")),
		permissions = cast(u64)(fint(m, "permissions")),
		hoist = fbool(m, "hoist"),
		icon = clone_str(fstr(m, "icon"), a),
		unicode_emoji = clone_str(fstr(m, "unicode_emoji"), a)
	};
	{ colors := fmap(m, "colors");
	if colors != null && vhas(colors, "primary_color") { r.color = cast(u32)(fint(colors, "primary_color")); } }
	return r;
}

parse_emojis :: (s: *Store, g: *Guild, l: []V) {
	for e: g.emojis { free_str(e.name, s.allocator); }
	clear(*g.emojis);
	for ev: l {
		em := vmap(ev);
		append(*g.emojis, Emoji.{
			id = fsnow(em, "id"),
			name = clone_str(fstr(em, "name"), s.allocator),
			animated = fbool(em, "animated"),
			available = !vhas(em, "available") || fbool(em, "available"),
			guild_id = g.id
		});
	}
}

parse_stickers :: (s: *Store, g: *Guild, l: []V) {
	for st: g.stickers {
		free_str(st.name, s.allocator);
		free_str(st.description, s.allocator);
	}
	clear(*g.stickers);
	for sv: l {
		sm := vmap(sv);
		append(*g.stickers, Sticker.{
			id = fsnow(sm, "id"),
			name = clone_str(fstr(sm, "name"), s.allocator),
			format_type = cast(int)(fint(sm, "format_type")),
			guild_id = g.id,
			description = clone_str(fstr(sm, "description"), s.allocator)
		});
	}
}

// parse_guild_props applies guild-level fields (READY nests them in `properties`).
parse_guild_props :: (s: *Store, g: *Guild, p: etf.Map) {
	a := s.allocator;
	if vhas(p, "name") {free_str(g.name, a); g.name = clone_str(fstr(p, "name"), a);}
	if vhas(p, "icon") {free_str(g.icon, a); g.icon = clone_str(fstr(p, "icon"), a);}
	if vhas(p, "banner") {free_str(g.banner, a); g.banner = clone_str(fstr(p, "banner"), a);}
	if vhas(p, "owner_id") { g.owner_id = fsnow(p, "owner_id"); }
	if vhas(p, "system_channel_id") { g.system_channel_id = fsnow(p, "system_channel_id"); }
	if vhas(p, "default_message_notifications") { g.default_message_notifications = cast(int)(fint(p, "default_message_notifications")); }
	if vhas(p, "features") {
		for f: g.features { free_str(f, a); }
		clear(*g.features);
		for f: flist(p, "features") { append(*g.features, clone_str(vstr(f), a)); }
	}
}
#scope_export

parse_guild_into :: (s: *Store, m: etf.Map) -> Snowflake {
	id := fsnow(m, "id");
	if id == 0 { return 0; }
	a := s.allocator;
	g, exists := map_find_ptr(*s.guilds, id);
	if !exists {
		at(*s.guilds, id).* = Guild.{id = id};
		g = at(*s.guilds, id);
		g.channels = make_dynamic(Snowflake, a, a);
		g.roles = make_dynamic(Role, a, a);
		g.emojis = make_dynamic(Emoji, a, a);
		g.stickers = make_dynamic(Sticker, a, a);
		g.features = make_dynamic(string, a, a);
		append(*s.guild_order, id);
	}
	g.unavailable = fbool(m, "unavailable");
	{ props := fmap(m, "properties");
	if props != null {
		parse_guild_props(s, g, props);
	} else {
		parse_guild_props(s, g, m);
	} }
	if vhas(m, "member_count") { g.member_count = cast(int)(fint(m, "member_count")); }
	if vhas(m, "premium_tier") { g.premium_tier = cast(int)(fint(m, "premium_tier")); }
	{ props := fmap(m, "properties");
	if props != null && vhas(props, "premium_tier") { g.premium_tier = cast(int)(fint(props, "premium_tier")); } }
	if vhas(m, "lazy") { g.lazy = fbool(m, "lazy"); }
	if vhas(m, "joined_at") {free_str(g.joined_at, a); g.joined_at = clone_str(fstr(m, "joined_at"), a);}
	if vhas(m, "roles") {
		for * r: g.roles { free_role(s, *r); }
		clear(*g.roles);
		for rv: flist(m, "roles") { append(*g.roles, parse_role(s, vmap(rv))); }
	}
	if vhas(m, "emojis") { parse_emojis(s, g, flist(m, "emojis")); }
	if vhas(m, "stickers") { parse_stickers(s, g, flist(m, "stickers")); }
	if vhas(m, "channels") {
		clear(*g.channels);
		for cv: flist(m, "channels") {
			cid := parse_channel_into(s, vmap(cv), id);
			if cid != 0 { append(*g.channels, cid); }
		}
	}
	for tv: flist(m, "threads") {
		cid := parse_channel_into(s, vmap(tv), id);
		if cid != 0 && !slice.contains(view(g.channels), cid) { append(*g.channels, cid); }
	}
	for vs: flist(m, "voice_states") { apply_voice_state(s, vmap(vs), id); }
	for mv: flist(m, "members") { parse_member_into(s, id, vmap(mv)); }
	for pv: flist(m, "presences") { apply_presence(s, vmap(pv)); }
	return id;
}

parse_member_into :: (s: *Store, guild_id: Snowflake, m: etf.Map) -> Snowflake {
	if m == null { return 0; }
	uid := fsnow(m, "user_id");
	{ um := fmap(m, "user");
	if um != null { uid = parse_user_into(s, um); } }
	if uid == 0 { return 0; }
	a := s.allocator;
	gm, gok := map_find_ptr(*s.members, guild_id);
	if !gok {
		at(*s.members, guild_id).* = Map(Snowflake, Member).{};
		gm = at(*s.members, guild_id);
	}
	mem_, exists := *gm[uid];
	if !exists {
		gm[uid] = Member.{user_id = uid, roles = make_dynamic(Snowflake, a, a)};
		mem_ = *gm[uid];
	}
	if vhas(m, "nick") {free_str(mem_.nick, a); mem_.nick = clone_str(fstr(m, "nick"), a);}
	if vhas(m, "avatar") {free_str(mem_.avatar, a); mem_.avatar = clone_str(fstr(m, "avatar"), a);}
	if vhas(m, "joined_at") {free_str(mem_.joined_at, a); mem_.joined_at = clone_str(fstr(m, "joined_at"), a);}
	if vhas(m, "roles") {
		clear(*mem_.roles);
		for r: flist(m, "roles") { append(*mem_.roles, vsnow(r)); }
	}
	{ pm := fmap(m, "presence");
	if pm != null { apply_presence(s, pm, uid); } }
	return uid;
}
#scope_module

parse_emoji_ref :: (s: *Store, m: etf.Map) -> Emoji {
	return Emoji.{id = fsnow(m, "id"), name = clone_str(fstr(m, "name"), s.allocator), animated = fbool(m, "animated"), available = true};
}

parse_attachment :: (s: *Store, m: etf.Map) -> Attachment {
	a := s.allocator;
	return Attachment.{
		id = fsnow(m, "id"),
		filename = clone_str(fstr(m, "filename"), a),
		content_type = clone_str(fstr(m, "content_type"), a),
		size = cast(int)(fint(m, "size")),
		url = clone_str(fstr(m, "url"), a),
		proxy_url = clone_str(fstr(m, "proxy_url"), a),
		width = cast(int)(fint(m, "width")),
		height = cast(int)(fint(m, "height")),
		duration_secs = cast(float32)(vf64(vget(m, "duration_secs"))),
		waveform = clone_str(fstr(m, "waveform"), a),
		flags = cast(u64)(fint(m, "flags"))
	};
}

parse_embed :: (s: *Store, m: etf.Map) -> Embed {
	a := s.allocator;
	e := Embed.{
		kind = clone_str(fstr(m, "type"), a),
		title = clone_str(fstr(m, "title"), a),
		description = clone_str(fstr(m, "description"), a),
		url = clone_str(fstr(m, "url"), a),
		color = cast(u32)(fint(m, "color"))
	};
	{ t := fmap(m, "thumbnail");
	if t != null {
		e.thumbnail_url = clone_str(ifx vhas(t, "proxy_url") then fstr(t, "proxy_url") else fstr(t, "url"), a);
		e.thumbnail_w = cast(int)(fint(t, "width"));
		e.thumbnail_h = cast(int)(fint(t, "height"));
	} }
	{ im := fmap(m, "image");
	if im != null {
		e.image_url = clone_str(ifx vhas(im, "proxy_url") then fstr(im, "proxy_url") else fstr(im, "url"), a);
		e.image_w = cast(int)(fint(im, "width"));
		e.image_h = cast(int)(fint(im, "height"));
	} }
	{ vd := fmap(m, "video");
	if vd != null { e.video_url = clone_str(fstr(vd, "url"), a); } }
	{ p := fmap(m, "provider");
	if p != null { e.provider = clone_str(fstr(p, "name"), a); } }
	{ au := fmap(m, "author");
	if au != null { e.author_name = clone_str(fstr(au, "name"), a); } }
	return e;
}

parse_reactions :: (s: *Store, msg: *Message, l: []V) {
	for r: msg.reactions { free_str(r.emoji.name, s.allocator); }
	clear(*msg.reactions);
	for rv: l {
		rm := vmap(rv);
		r := Reaction.{
			emoji = parse_emoji_ref(s, fmap(rm, "emoji")),
			count = cast(int)(fint(rm, "count")),
			burst_count = cast(int)(fint(rm, "burst_count")),
			me = fbool(rm, "me"),
			me_burst = fbool(rm, "me_burst")
		};
		{ cd := fmap(rm, "count_details");
		if cd != null { r.burst_count = cast(int)(fint(cd, "burst")); } }
		append(*msg.reactions, r);
	}
}

// parse_message_fields fills msg from a full or partial (MESSAGE_UPDATE) object.
parse_message_fields :: (s: *Store, msg: *Message, m: etf.Map) {
	a := s.allocator;
	if vhas(m, "channel_id") { msg.channel_id = fsnow(m, "channel_id"); }
	{ au := fmap(m, "author");
	if au != null { msg.author_id = parse_user_into(s, au); } }
	if vhas(m, "type") { msg.kind = cast(int)(fint(m, "type")); }
	if vhas(m, "content") {free_str(msg.content, a); msg.content = clone_str(fstr(m, "content"), a);}
	if vhas(m, "timestamp") {free_str(msg.timestamp, a); msg.timestamp = clone_str(fstr(m, "timestamp"), a);}
	if vhas(m, "edited_timestamp") {free_str(msg.edited_timestamp, a); msg.edited_timestamp = clone_str(fstr(m, "edited_timestamp"), a);}
	{ c := fmap(m, "call");
	if c != null {free_str(msg.call_ended, a); msg.call_ended = clone_str(fstr(c, "ended_timestamp"), a);} }
	if vhas(m, "nonce") {
		free_str(msg.nonce, a);
		nv := vget(m, "nonce");
		if nv.kind == {
		case .String; x := nv.s;
			msg.nonce = clone_str(x, a);
		case .Int; #through; case .Big; x := nv;
			msg.nonce = clone_str(snowflake_string(vsnow(nv)), a);
		case; x := nv;
			msg.nonce = "";
		}
	}
	if vhas(m, "flags") { msg.flags = cast(u64)(fint(m, "flags")); }
	if vhas(m, "mention_everyone") { msg.mention_everyone = fbool(m, "mention_everyone"); }
	if vhas(m, "attachments") {
		for * at: msg.attachments { free_attachment(s, *at); }
		clear(*msg.attachments);
		for av: flist(m, "attachments") { append(*msg.attachments, parse_attachment(s, vmap(av))); }
	}
	if vhas(m, "embeds") {
		for * e: msg.embeds { free_embed(s, *e); }
		clear(*msg.embeds);
		for ev: flist(m, "embeds") { append(*msg.embeds, parse_embed(s, vmap(ev))); }
	}
	if vhas(m, "reactions") { parse_reactions(s, msg, flist(m, "reactions")); }
	if vhas(m, "mentions") {
		clear(*msg.mentions);
		for uv: flist(m, "mentions") {
			uid := parse_user_into(s, vmap(uv));
			if uid != 0 { append(*msg.mentions, uid); }
		}
	}
	if vhas(m, "sticker_items") {
		clear(*msg.sticker_ids);
		for sv: flist(m, "sticker_items") { append(*msg.sticker_ids, fsnow(vmap(sv), "id")); }
		note_sticker_items(s, flist(m, "sticker_items"));
	}
	{ ref := fmap(m, "message_reference");
	if ref != null { msg.referenced_id = fsnow(ref, "message_id"); } }
	{ rm := fmap(m, "referenced_message");
	if rm != null {
		// Keep the referenced author resolvable for reply previews.
		{ au := fmap(rm, "author");
		if au != null { parse_user_into(s, au); } }
	} }
	gid := fsnow(m, "guild_id");
	{ mm := fmap(m, "member");
	if mm != null && gid != 0 && msg.author_id != 0 {
		// MESSAGE_CREATE members omit `user`; attach to the author.
		if !vhas(mm, "user") && !vhas(mm, "user_id") {
			parse_member_with_id(s, gid, msg.author_id, mm);
		} else {
			parse_member_into(s, gid, mm);
		}
	} }
}

parse_member_with_id :: (s: *Store, guild_id: Snowflake, uid: Snowflake, m: etf.Map) {
	a := s.allocator;
	gm, gok := map_find_ptr(*s.members, guild_id);
	if !gok {
		at(*s.members, guild_id).* = Map(Snowflake, Member).{};
		gm = at(*s.members, guild_id);
	}
	mem_, exists := *gm[uid];
	if !exists {
		gm[uid] = Member.{user_id = uid, roles = make_dynamic(Snowflake, a, a)};
		mem_ = *gm[uid];
	}
	if vhas(m, "nick") {free_str(mem_.nick, a); mem_.nick = clone_str(fstr(m, "nick"), a);}
	if vhas(m, "avatar") {free_str(mem_.avatar, a); mem_.avatar = clone_str(fstr(m, "avatar"), a);}
	if vhas(m, "joined_at") {free_str(mem_.joined_at, a); mem_.joined_at = clone_str(fstr(m, "joined_at"), a);}
	if vhas(m, "roles") {
		clear(*mem_.roles);
		for r: flist(m, "roles") { append(*mem_.roles, vsnow(r)); }
	}
}
#scope_export

new_message :: (s: *Store) -> Message {
	a := s.allocator;
	return Message.{
		attachments = make_dynamic(Attachment, a, a),
		embeds = make_dynamic(Embed, a, a),
		reactions = make_dynamic(Reaction, a, a),
		sticker_ids = make_dynamic(Snowflake, a, a),
		mentions = make_dynamic(Snowflake, a, a)
	};
}
#scope_module

message_list :: (s: *Store, channel_id: Snowflake) -> *Message_List {
	l, ok := map_find_ptr(*s.messages, channel_id);
	if !ok {
		at(*s.messages, channel_id).* = Message_List.{messages = make_dynamic(Message, 0, 0, s.allocator), has_more_before = true};
		l = at(*s.messages, channel_id);
	}
	return l;
}
#scope_export

// message_index finds a message by id (binary search; pending messages sort by nonce id).
message_index :: (l: *Message_List, id: Snowflake) -> int {
	i, found := slice.binary_search_by(view(l.messages), id, (m: Message, id: Snowflake) -> slice.Ordering {
		if m.id < id { return .Less; }
		if m.id > id { return .Greater; }
		return .Equal;
	});
	return ifx found then i else -1;
}
#scope_module

insert_message :: (l: *Message_List, msg: Message) {
	i, _ := slice.binary_search_by(view(l.messages), msg.id, (m: Message, id: Snowflake) -> slice.Ordering {
		if m.id < id { return .Less; }
		if m.id > id { return .Greater; }
		return .Equal;
	});
	inject_at(*l.messages, i, msg);
}
#scope_export

// upsert_message handles MESSAGE_CREATE / REST message objects, replacing a
// pending optimistic message with the same nonce.
upsert_message :: (s: *Store, m: etf.Map) -> Snowflake {
	id := fsnow(m, "id");
	cid := fsnow(m, "channel_id");
	if id == 0 || cid == 0 { return 0; }
	l := message_list(s, cid);
	{ i := message_index(l, id);
	if i >= 0 {
		msg := at(*l.messages, i);
		parse_message_fields(s, msg, m);
		msg.pending = false;
		msg.failed = false;
		return id;
	} }
	nonce := "";
	nv := vget(m, "nonce");
	if nv.kind == {
	case .String; x := nv.s;
		nonce = x;
	case .Int; #through; case .Big; x := nv;
		nonce = snowflake_string(vsnow(nv));
	}
	if nonce != "" {
		for * pm, i: l.messages {
			if pm.pending && pm.nonce == nonce {
				free_message(s, *pm);
				ordered_remove(*l.messages, i);
				break;
			}
		}
	}
	msg := new_message(s);
	msg.id = id;
	parse_message_fields(s, *msg, m);
	insert_message(l, msg);
	{ c, ok := map_find_ptr(*s.channels, cid);
	if ok && id > c.last_message_id { c.last_message_id = id; } }
	return id;
}

// ---- presence / voice / misc ----

apply_presence :: (s: *Store, m: etf.Map, user_hint: Snowflake = 0) {
	uid := user_hint;
	{ um := fmap(m, "user");
	if um != null {
		{ u := parse_user_into(s, um);
		if u != 0 { uid = u; } }
	} }
	{ u := fsnow(m, "user_id");
	if u != 0 { uid = u; } }
	if uid == 0 { return; }
	p := Presence.{user_id = uid, status = status_from_string(fstr(m, "status"))};
	{ cs := fmap(m, "client_status");
	if cs != null {
		p.desktop = status_from_string(fstr(cs, "desktop"));
		p.mobile = status_from_string(fstr(cs, "mobile"));
		p.web = status_from_string(fstr(cs, "web"));
	} }
	old, had := map_find(s.presences, uid);
	if had { free_str(old.activity, s.allocator); }
	for av: flist(m, "activities") {
		am := vmap(av);
		t := fint(am, "type");
		txt := ifx t == 4 then fstr(am, "state") else fstr(am, "name");
		if txt != "" {
			p.activity = clone_str(txt, s.allocator);
			break;
		}
	}
	at(*s.presences, uid).* = p;
}

apply_voice_state :: (s: *Store, m: etf.Map, guild_hint: Snowflake = 0) {
	uid := fsnow(m, "user_id");
	{ mm := fmap(m, "member");
	if mm != null {
		gid := fsnow(m, "guild_id");
		if gid == 0 { gid = guild_hint; }
		u := parse_member_into(s, gid, mm);
		if uid == 0 { uid = u; }
	} }
	if uid == 0 { return; }
	{ old, ok := map_find(s.voice_states, uid);
	if ok { free_str(old.session_id, s.allocator); } }
	cid := fsnow(m, "channel_id");
	if cid == 0 {
		delete_key(*s.voice_states, uid);
		return;
	}
	gid := fsnow(m, "guild_id");
	if gid == 0 { gid = guild_hint; }
	at(*s.voice_states, uid).* = Voice_State.{
		user_id = uid,
		channel_id = cid,
		guild_id = gid,
		session_id = clone_str(fstr(m, "session_id"), s.allocator),
		self_mute = fbool(m, "self_mute"),
		self_deaf = fbool(m, "self_deaf"),
		mute = fbool(m, "mute"),
		deaf = fbool(m, "deaf"),
		self_video = fbool(m, "self_video"),
		self_stream = fbool(m, "self_stream")
	};
}
#scope_module

apply_relationship :: (s: *Store, m: etf.Map) {
	uid := fsnow(m, "user_id");
	{ um := fmap(m, "user");
	if um != null { uid = parse_user_into(s, um); } }
	if uid == 0 { uid = fsnow(m, "id"); }
	if uid == 0 { return; }
	r, ok := map_find_ptr(*s.relationships, uid);
	if !ok {
		at(*s.relationships, uid).* = Relationship.{user_id = uid};
		r = at(*s.relationships, uid);
	}
	if vhas(m, "type") { r.kind = cast(Relationship_Type)(fint(m, "type")); }
	if vhas(m, "nickname") {free_str(r.nickname, s.allocator); r.nickname = clone_str(fstr(m, "nickname"), s.allocator);}
	if vhas(m, "since") {free_str(r.since, s.allocator); r.since = clone_str(fstr(m, "since"), s.allocator);}
}

apply_read_state :: (s: *Store, m: etf.Map) {
	if vhas(m, "read_state_type") && fint(m, "read_state_type") != 0 { return; }
	cid := fsnow(m, "id");
	if cid == 0 { cid = fsnow(m, "channel_id"); }
	if cid == 0 { return; }
	rs := get(s.read_states, cid);
	rs.channel_id = cid;
	if vhas(m, "last_message_id") { rs.last_message_id = fsnow(m, "last_message_id"); }
	if vhas(m, "message_id") { rs.last_message_id = fsnow(m, "message_id"); }
	if vhas(m, "mention_count") { rs.mention_count = cast(int)(fint(m, "mention_count")); }
	if vhas(m, "last_viewed") { rs.last_viewed = cast(int)(fint(m, "last_viewed")); }
	if vhas(m, "flags") { rs.flags = cast(u64)(fint(m, "flags")); }
	at(*s.read_states, cid).* = rs;
}

apply_guild_settings :: (s: *Store, m: etf.Map) {
	gid := fsnow(m, "guild_id");
	gs, ok := map_find_ptr(*s.guild_settings, gid);
	if !ok {
		at(*s.guild_settings, gid).* = Guild_Settings.{guild_id = gid, muted_channels = make_dynamic(Snowflake, 0, 0, s.allocator), collapsed_channels = make_dynamic(Snowflake, 0, 0, s.allocator)};
		gs = at(*s.guild_settings, gid);
	}
	gs.muted = fbool(m, "muted");
	gs.message_notifications = cast(int)(fint(m, "message_notifications"));
	gs.suppress_everyone = fbool(m, "suppress_everyone");
	gs.suppress_roles = fbool(m, "suppress_roles");
	clear(*gs.muted_channels);
	clear(*gs.collapsed_channels);
	for ov: flist(m, "channel_overrides") {
		om := vmap(ov);
		if fbool(om, "muted") { append(*gs.muted_channels, fsnow(om, "channel_id")); }
		if fbool(om, "collapsed") { append(*gs.collapsed_channels, fsnow(om, "channel_id")); }
	}
	apply_guild_settings_extra(s, gs, m);
}
#scope_export

// ---- user_settings_proto (PreloadedUserSettings) ----

// apply_settings_proto decodes the fields the UI uses: status (11), localization
// (12), appearance/theme (13), guild folders (14).
apply_settings_proto :: (s: *Store, b64: string) {
	raw, err := base64.decode(bool64, allocator = temp);
	if err != null { return; }
	st := *s.settings;
	a := s.allocator;
	{ f, ok := protobuf.find_path(raw, 2, 1);
	if ok { st.inbox_tab = ifx f.value <= cast(u64)(max(Inbox_Tab)) then cast(Inbox_Tab)(f.value) else .Unspecified; } }
	{ f, ok := protobuf.find_path(raw, 11, 1, 1);
	if ok { st.status = status_from_string(as_string(f.bytes)); } }
	{ f, ok := protobuf.find_path(raw, 11, 2, 1);
	if ok {free_str(st.custom_status_text, a); st.custom_status_text = clone_str(as_string(f.bytes), a);} }
	{ f, ok := protobuf.find_path(raw, 11, 2, 3);
	if ok {free_str(st.custom_status_emoji, a); st.custom_status_emoji = clone_str(as_string(f.bytes), a);} }
	{ f, ok := protobuf.find_path(raw, 11, 2, 2);
	if ok { st.custom_status_emoji_id = cast(Snowflake)(f.value); } }
	{ f, ok := protobuf.find_path(raw, 11, 2, 4);
	if ok { st.custom_status_expires_ms = cast(s64)(f.value); } }
	{ f, ok := protobuf.find_path(raw, 11, 5, 1);
	if ok { st.status_created_ms = cast(s64)(f.value); } }
	{ f, ok := protobuf.find_path(raw, 12, 1, 1);
	if ok {free_str(st.locale, a); st.locale = clone_str(as_string(f.bytes), a);} }
	{ f, ok := protobuf.find_path(raw, 12, 2, 1);
	if ok { st.timezone_offset = cast(int)(cast(s32)(f.value)); } }
	// The official client maps an absent/UNSET theme to its UI "Dark", which is
	// proto DARKER (bundle: {[UNSET]: DARK, [DARK]: ASH, [DARKER]: DARK, ...}).
	{ f, ok := protobuf.find_path(raw, 13, 1);
	if ok && f.value != 0 { st.theme = cast(Theme)(f.value); } else { st.theme = .Darker; } }
	{ f, ok := protobuf.find_path(raw, 13, 2);
	if ok { st.developer_mode = f.value != 0; } }
	{ _, ok := protobuf.find_path(raw, 7, 12);
	if ok {
		f, set := protobuf.find_path(raw, 7, 12, 1);
		st.friend_online_off = !set || f.value == 0;
	} }
	{ gf, ok := protobuf.find(raw, 14);
	if ok {
		for * fo: st.guild_folders {
			free_str(fo.name, a);
			delete(fo.guild_ids);
		}
		clear(*st.guild_folders);
		clear(*st.guild_positions);
		r := protobuf.Reader.{buf = gf.bytes};
		while true {
			fld, more := protobuf.next(*r);
			if !more { break; }
			if fld.num == {
			case 1;
				fo := Guild_Folder.{guild_ids = make_dynamic(Snowflake, a, a)};
				{ ids, iok := protobuf.find(fld.bytes, 1);
				if iok {
					for id: protobuf.packed_fixed64(ids.bytes, temp) { append(*fo.guild_ids, cast(Snowflake)(id)); }
				} }
				{ v, vok := protobuf.find_path(fld.bytes, 2, 1);
				if vok { fo.id = cast(s64)(v.value); } }
				{ v, vok := protobuf.find_path(fld.bytes, 3, 1);
				if vok { fo.name = clone_str(as_string(v.bytes), a); } }
				{ v, vok := protobuf.find_path(fld.bytes, 4, 1);
				if vok {
					fo.color = v.value;
					fo.has_color = true;
				} }
				append(*st.guild_folders, fo);
			case 2;
				for id: protobuf.packed_fixed64(fld.bytes, temp) { append(*st.guild_positions, cast(Snowflake)(id)); }
			}
		}
	} }
}

// ---- READY / READY_SUPPLEMENTAL ----

apply_ready :: (s: *Store, d: etf.Map) {
	a := s.allocator;
	free_str(s.session_id, a);
	s.session_id = clone_str(fstr(d, "session_id"), a);
	free_str(s.resume_gateway_url, a);
	s.resume_gateway_url = clone_str(fstr(d, "resume_gateway_url"), a);
	free_str(s.analytics_token, a);
	s.analytics_token = clone_str(fstr(d, "analytics_token"), a);
	free_str(s.qos_token, a);
	s.qos_token = clone_str(fstr(d, "qos_token"), a);
	free_str(s.country_code, a);
	s.country_code = clone_str(fstr(d, "country_code"), a);
	s.me = parse_user_into(s, fmap(d, "user"));
	for uv: flist(d, "users") { parse_user_into(s, vmap(uv)); }
	guilds := flist(d, "guilds");
	for gv: guilds { parse_guild_into(s, vmap(gv)); }
	// merged_members[i] lists members (ourselves) of guilds[i].
	for ml, i: flist(d, "merged_members") {
		if i >= len(guilds) { break; }
		gid := fsnow(vmap(get(guilds, i)), "id");
		for mv: vlist(ml) { parse_member_into(s, gid, vmap(mv)); }
	}
	clear(*s.private_channels);
	for cv: flist(d, "private_channels") {
		cid := parse_channel_into(s, vmap(cv));
		if cid != 0 { append(*s.private_channels, cid); }
	}
	for rv: flist(d, "relationships") { apply_relationship(s, vmap(rv)); }
	{ rs := fmap(d, "read_state");
	if rs != null {
		for e: flist(rs, "entries") { apply_read_state(s, vmap(e)); }
	} }
	{ ugs := fmap(d, "user_guild_settings");
	if ugs != null {
		for e: flist(ugs, "entries") { apply_guild_settings(s, vmap(e)); }
	} }
	{ sp := fstr(d, "user_settings_proto");
	if sp != "" { apply_settings_proto(s, sp); } }
	apply_sessions(s, flist(d, "sessions"));
	s.ready = true;
	s.connection = .Ready;
}

apply_ready_supplemental :: (s: *Store, d: etf.Map) {
	guilds := flist(d, "guilds");
	for gv, i: guilds {
		gm := vmap(gv);
		gid := fsnow(gm, "id");
		for vs: flist(gm, "voice_states") { apply_voice_state(s, vmap(vs), gid); }
	}
	for ml, i: flist(d, "merged_members") {
		if i >= len(guilds) { break; }
		gid := fsnow(vmap(get(guilds, i)), "id");
		for mv: vlist(ml) { parse_member_into(s, gid, vmap(mv)); }
	}
	{ mp := fmap(d, "merged_presences");
	if mp != null {
		for pv: flist(mp, "friends") { apply_presence(s, vmap(pv)); }
		for gl: flist(mp, "guilds") { for pv: vlist(gl) { apply_presence(s, vmap(pv)); } }
	} }
	for cv: flist(d, "lazy_private_channels") {
		cid := parse_channel_into(s, vmap(cv));
		if cid != 0 && !slice.contains(view(s.private_channels), cid) { append(*s.private_channels, cid); }
	}
}
#scope_module

apply_sessions :: (s: *Store, l: []V) {
	for ss: s.sessions {
		free_str(ss.session_id, s.allocator);
		free_str(ss.client, s.allocator);
		free_str(ss.os, s.allocator);
	}
	clear(*s.sessions);
	for sv: l {
		sm := vmap(sv);
		ci := fmap(sm, "client_info");
		append(*s.sessions, Session_Info.{
			session_id = clone_str(fstr(sm, "session_id"), s.allocator),
			status = status_from_string(fstr(sm, "status")),
			client = clone_str(fstr(ci, "client"), s.allocator),
			os = clone_str(fstr(ci, "os"), s.allocator)
		});
	}
}

// ---- member list (op 37 channels → GUILD_MEMBER_LIST_UPDATE) ----

member_list_item :: (s: *Store, guild_id: Snowflake, iv: etf.Map) -> Member_List_Item {
	{ g := fmap(iv, "group");
	if g != null {
		gid, rid := group_id_of(vget(g, "id"));
		return Member_List_Item.{is_group = true, group_id = clone_str(gid, s.allocator), role_id = rid, count = cast(int)(fint(g, "count"))};
	} }
	{ mm := fmap(iv, "member");
	if mm != null {
		return Member_List_Item.{user_id = parse_member_into(s, guild_id, mm)};
	} }
	return .{};
}

// group ids are "online"/"offline" strings or role snowflakes (ETF integers).
group_id_of :: (v: V) -> string, Snowflake {
	id: string;
	role: Snowflake;
	if v.kind == {
	case .String; x := v.s;
		r := parse_snowflake(x);
		return x, r;
	case .Atom; x := v.s;
		return as_string(x), 0;
	case .Int; #through; case .Big; x := v;
		r := vsnow(v);
		return snowflake_string(r), r;
	}
	return "", 0;
}

free_list_item :: (s: *Store, it_: Member_List_Item) {
	free_str(it_.group_id, s.allocator);
}
#scope_export

apply_member_list_update :: (s: *Store, d: etf.Map) {
	gid := fsnow(d, "guild_id");
	ml, ok := map_find_ptr(*s.member_lists, gid);
	if !ok {
		at(*s.member_lists, gid).* = Member_List.{items = make_dynamic(Member_List_Item, 0, 0, s.allocator)};
		ml = at(*s.member_lists, gid);
	}
	id := fstr(d, "id");
	if ml.id != id {
		free_str(ml.id, s.allocator);
		ml.id = clone_str(id, s.allocator);
	}
	ml.member_count = cast(int)(fint(d, "member_count"));
	ml.online_count = cast(int)(fint(d, "online_count"));
	if vhas(d, "groups") {
		for g: ml.groups { free_str(g.id, s.allocator); }
		clear(*ml.groups);
		if ml.groups == null { ml.groups = make_dynamic(Member_List_Group, 0, 0, s.allocator); }
		for gv: flist(d, "groups") {
			gm := vmap(gv);
			gid, rid := group_id_of(vget(gm, "id"));
			append(*ml.groups, Member_List_Group.{clone_str(gid, s.allocator), rid, cast(int)(fint(gm, "count"))});
		}
	}
	defer {
		// Group header items carry their size from the top-level groups array.
		for * it_: ml.items {
			if !it_.is_group { continue; }
			for g: ml.groups { if g.id == it_.group_id { it_.count = g.count; } }
		}
	}
	for opv: flist(d, "ops") {
		op := vmap(opv);
		if fstr(op, "op") == {
		case "SYNC";
			r := flist(op, "range");
			start := ifx len(r) == 2 then cast(int)(vint(r[0])) else 0;
			items := flist(op, "items");
			while len(ml.items) < start + len(items) { append(*ml.items, Member_List_Item.{}); }
			for iv, k: items {
				free_list_item(s, ml.items[start + k]);
				ml.items[start + k] = member_list_item(s, gid, vmap(iv));
			}
		case "INSERT";
			idx := cast(int)(fint(op, "index"));
			it_ := member_list_item(s, gid, fmap(op, "item"));
			if idx >= len(ml.items) { append(*ml.items, it_); } else { inject_at(*ml.items, idx, it_); }
		case "UPDATE";
			idx := cast(int)(fint(op, "index"));
			if idx >= 0 && idx < len(ml.items) {
				free_list_item(s, ml.items[idx]);
				ml.items[idx] = member_list_item(s, gid, fmap(op, "item"));
			}
		case "DELETE";
			idx := cast(int)(fint(op, "index"));
			if idx >= 0 && idx < len(ml.items) {
				free_list_item(s, ml.items[idx]);
				ordered_remove(*ml.items, idx);
			}
		case "INVALIDATE";
			r := flist(op, "range");
			if len(r) == 2 {
				{ k := cast(int)(vint(r[0]));
				while k <= cast(int)(vint(r[1])) && k < len(ml.items) {
					free_list_item(s, ml.items[k]);
					ml.items[k] = .{};
					k += 1;
} }
			}
		}
	}
}

// ---- typing ----

TYPING_DURATION_MS :: 10_000;

store_expire_typing :: (s: *Store, now: s64) -> bool {
	changed := false;
	for * _, l: s.typing {
		for < i: 0..len(l) - 1 {
			if l[i].until <= now {
				ordered_remove(*l, i);
				changed = true;
			}
		}
	}
	return changed;
}
#scope_module

apply_typing :: (s: *Store, d: etf.Map, now: s64) {
	cid := fsnow(d, "channel_id");
	uid := fsnow(d, "user_id");
	{ mm := fmap(d, "member");
	if mm != null {
		{ gid := fsnow(d, "guild_id");
		if gid != 0 {
			u := parse_member_into(s, gid, mm);
			if uid == 0 { uid = u; }
		} }
	} }
	if cid == 0 || uid == 0 { return; }
	l, ok := map_find_ptr(*s.typing, cid);
	if !ok {
		at(*s.typing, cid).* = make_dynamic(Typing, 0, 0, s.allocator);
		l = at(*s.typing, cid);
	}
	for * t: l {
		if t.user_id == uid {
			t.until = now + TYPING_DURATION_MS;
			return;
		}
	}
	append(l, Typing.{uid, now + TYPING_DURATION_MS});
}

remove_typing :: (s: *Store, cid: Snowflake, uid: Snowflake) {
	{ l, ok := map_find_ptr(*s.typing, cid);
	if ok {
		for t, i: l {
			if t.user_id == uid {
				ordered_remove(l, i);
				return;
			}
		}
	} }
}

// ---- reactions ----

emoji_matches :: (e: Emoji, id: Snowflake, name: string) -> bool {
	if id != 0 { return e.id == id; }
	return e.id == 0 && e.name == name;
}

apply_reaction :: (s: *Store, d: etf.Map, add: bool) {
	cid := fsnow(d, "channel_id");
	mid := fsnow(d, "message_id");
	uid := fsnow(d, "user_id");
	em := fmap(d, "emoji");
	eid := fsnow(em, "id");
	ename := fstr(em, "name");
	burst := fbool(d, "burst");
	l, ok := map_find_ptr(*s.messages, cid);
	if !ok { return; }
	i := message_index(l, mid);
	if i < 0 { return; }
	msg := at(*l.messages, i);
	mine := uid == s.me;
	for * r, k: msg.reactions {
		if !emoji_matches(r.emoji, eid, ename) { continue; }
		if add {
			r.count += 1;
			if burst { r.burst_count += 1; }
			if mine {
				if burst { r.me_burst = true; } else { r.me = true; }
			}
		} else {
			r.count -= 1;
			if burst { r.burst_count = max(r.burst_count - 1, 0); }
			if mine {
				if burst { r.me_burst = false; } else { r.me = false; }
			}
			if r.count <= 0 {
				free_str(r.emoji.name, s.allocator);
				ordered_remove(*msg.reactions, k);
			}
		}
		return;
	}
	if add {
		r := Reaction.{emoji = parse_emoji_ref(s, em), count = 1};
		if burst { r.burst_count = 1; }
		if mine {
			if burst { r.me_burst = true; } else { r.me = true; }
		}
		append(*msg.reactions, r);
	}
}
#scope_export

// ---- dispatch application ----

remove_guild :: (s: *Store, gid: Snowflake) {
	g, ok := map_find_ptr(*s.guilds, gid);
	if !ok { return; }
	for cid: g.channels {
		{ c, cok := map_find_ptr(*s.channels, cid);
		if cok {
			free_channel(s, c);
			delete_key(*s.channels, cid);
		} }
		// a rejoin loads the channels again from scratch
		{ l, lok := map_find_ptr(*s.messages, cid);
		if lok {
			for * m: l.messages { free_message(s, *m); }
			delete(l.messages);
			delete_key(*s.messages, cid);
		} }
	}
	free_guild(s, g);
	delete_key(*s.guilds, gid);
	{ i, found := slice.linear_search(view(s.guild_order), gid);
	if found { ordered_remove(*s.guild_order, i); } }
	{ gm, mok := map_find_ptr(*s.members, gid);
	if mok {
		for * _, m: gm { free_member(s, *m); }
		delete(gm.*);
		delete_key(*s.members, gid);
	} }
}

remove_channel :: (s: *Store, cid: Snowflake) {
	c, ok := map_find_ptr(*s.channels, cid);
	if !ok { return; }
	{ g, gok := map_find_ptr(*s.guilds, c.guild_id);
	if gok {
		{ i, found := slice.linear_search(view(g.channels), cid);
		if found { ordered_remove(*g.channels, i); } }
	} }
	{ i, found := slice.linear_search(view(s.private_channels), cid);
	if found { ordered_remove(*s.private_channels, i); } }
	free_channel(s, c);
	delete_key(*s.channels, cid);
	{ l, lok := map_find_ptr(*s.messages, cid);
	if lok {
		for * m: l.messages { free_message(s, *m); }
		delete(l.messages);
		delete_key(*s.messages, cid);
	} }
}

// store_apply_dispatch applies one gateway dispatch. Returns false for events it ignores.
store_apply_dispatch :: (s: *Store, name: string, data: V, now: s64) -> bool {
	d := vmap(data);
	if name == {
	case "READY";
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
		if author != 0 && author == s.me && fint(d, "type") != 46 {
			rs := get(s.read_states, cid);
			rs.channel_id = cid;
			rs.last_message_id = max(rs.last_message_id, fsnow(d, "id"));
			at(*s.read_states, cid).* = rs;
		}
	case "MESSAGE_UPDATE";
		cid := fsnow(d, "channel_id");
		{ l, ok := map_find_ptr(*s.messages, cid);
		if ok {
			{ i := message_index(l, fsnow(d, "id"));
			if i >= 0 { parse_message_fields(s, at(*l.messages, i), d); } }
		} }
	case "MESSAGE_DELETE";
		cid := fsnow(d, "channel_id");
		{ l, ok := map_find_ptr(*s.messages, cid);
		if ok {
			{ i := message_index(l, fsnow(d, "id"));
			if i >= 0 {
				free_message(s, at(*l.messages, i));
				ordered_remove(*l.messages, i);
			} }
		} }
	case "MESSAGE_DELETE_BULK";
		cid := fsnow(d, "channel_id");
		{ l, ok := map_find_ptr(*s.messages, cid);
		if ok {
			for idv: flist(d, "ids") {
				{ i := message_index(l, vsnow(idv));
				if i >= 0 {
					free_message(s, at(*l.messages, i));
					ordered_remove(*l.messages, i);
				} }
			}
		} }
	case "MESSAGE_REACTION_ADD";
		apply_reaction(s, d, true);
	case "MESSAGE_REACTION_REMOVE";
		apply_reaction(s, d, false);
	case "MESSAGE_REACTION_REMOVE_ALL"; #through; case "MESSAGE_REACTION_REMOVE_EMOJI";
		cid := fsnow(d, "channel_id");
		{ l, ok := map_find_ptr(*s.messages, cid);
		if ok {
			{ i := message_index(l, fsnow(d, "message_id"));
			if i >= 0 {
				msg := at(*l.messages, i);
				em := fmap(d, "emoji");
				for < k: 0..len(msg.reactions) - 1 {
					if em == null || emoji_matches(msg.reactions[k].emoji, fsnow(em, "id"), fstr(em, "name")) {
						free_str(msg.reactions[k].emoji.name, s.allocator);
						ordered_remove(*msg.reactions, k);
					}
				}
			} }
		} }
	case "MESSAGE_ACK";
		cid := fsnow(d, "channel_id");
		rs := get(s.read_states, cid);
		rs.channel_id = cid;
		rs.last_message_id = fsnow(d, "message_id");
		rs.mention_count = cast(int)(fint(d, "mention_count"));
		at(*s.read_states, cid).* = rs;
	case "TYPING_START";
		apply_typing(s, d, now);
	case "PRESENCE_UPDATE";
		apply_presence(s, d);
	case "SESSIONS_REPLACE";
		apply_sessions(s, vlist(data));
	case "GUILD_CREATE"; #through; case "GUILD_UPDATE";
		parse_guild_into(s, d);
	case "GUILD_DELETE";
		gid := fsnow(d, "id");
		if fbool(d, "unavailable") {
			{ g, ok := map_find_ptr(*s.guilds, gid);
			if ok { g.unavailable = true; } }
		} else {
			remove_guild(s, gid);
		}
	case "GUILD_ROLE_CREATE"; #through; case "GUILD_ROLE_UPDATE";
		gid := fsnow(d, "guild_id");
		{ g, ok := map_find_ptr(*s.guilds, gid);
		if ok {
			r := parse_role(s, fmap(d, "role"));
			for * old, i: g.roles {
				if old.id == r.id {
					free_role(s, *old);
					g.roles[i] = r;
					return true;
				}
			}
			append(*g.roles, r);
		} }
	case "GUILD_ROLE_DELETE";
		gid := fsnow(d, "guild_id");
		rid := fsnow(d, "role_id");
		{ g, ok := map_find_ptr(*s.guilds, gid);
		if ok {
			for * r, i: g.roles {
				if r.id == rid {
					free_role(s, *r);
					ordered_remove(*g.roles, i);
					break;
				}
			}
		} }
	case "GUILD_EMOJIS_UPDATE";
		{ g, ok := map_find_ptr(*s.guilds, fsnow(d, "guild_id"));
		if ok { parse_emojis(s, g, flist(d, "emojis")); } }
	case "GUILD_STICKERS_UPDATE";
		{ g, ok := map_find_ptr(*s.guilds, fsnow(d, "guild_id"));
		if ok { parse_stickers(s, g, flist(d, "stickers")); } }
	case "GUILD_MEMBER_ADD"; #through; case "GUILD_MEMBER_UPDATE";
		parse_member_into(s, fsnow(d, "guild_id"), d);
	case "GUILD_MEMBER_REMOVE";
		gid := fsnow(d, "guild_id");
		uid := fsnow(fmap(d, "user"), "id");
		{ gm, ok := map_find_ptr(*s.members, gid);
		if ok {
			{ m, mok := *gm[uid];
			if mok {
				free_member(s, m);
				delete_key(gm, uid);
			} }
		} }
	case "GUILD_MEMBERS_CHUNK";
		gid := fsnow(d, "guild_id");
		for mv: flist(d, "members") { parse_member_into(s, gid, vmap(mv)); }
		for pv: flist(d, "presences") { apply_presence(s, vmap(pv)); }
	case "GUILD_MEMBER_LIST_UPDATE";
		apply_member_list_update(s, d);
	case "CHANNEL_CREATE"; #through; case "CHANNEL_UPDATE"; #through; case "THREAD_CREATE"; #through; case "THREAD_UPDATE";
		cid := parse_channel_into(s, d);
		c := get(s.channels, cid);
		if c.guild_id != 0 {
			{ g, ok := map_find_ptr(*s.guilds, c.guild_id);
			if ok && !slice.contains(view(g.channels), cid) { append(*g.channels, cid); } }
		} else if !slice.contains(view(s.private_channels), cid) {
			append(*s.private_channels, cid);
		}
	case "CHANNEL_DELETE"; #through; case "THREAD_DELETE";
		remove_channel(s, fsnow(d, "id"));
	case "CHANNEL_RECIPIENT_ADD";
		{ c, ok := map_find_ptr(*s.channels, fsnow(d, "channel_id"));
		if ok {
			uid := parse_user_into(s, fmap(d, "user"));
			if uid != 0 && !slice.contains(view(c.recipient_ids), uid) { append(*c.recipient_ids, uid); }
		} }
	case "CHANNEL_RECIPIENT_REMOVE";
		{ c, ok := map_find_ptr(*s.channels, fsnow(d, "channel_id"));
		if ok {
			uid := fsnow(fmap(d, "user"), "id");
			{ i, found := slice.linear_search(view(c.recipient_ids), uid);
			if found { ordered_remove(*c.recipient_ids, i); } }
		} }
	case "RELATIONSHIP_ADD"; #through; case "RELATIONSHIP_UPDATE";
		apply_relationship(s, d);
	case "RELATIONSHIP_REMOVE";
		uid := fsnow(d, "id");
		{ r, ok := map_find(s.relationships, uid);
		if ok {
			free_str(r.nickname, s.allocator);
			free_str(r.since, s.allocator);
			delete_key(*s.relationships, uid);
		} }
	case "USER_UPDATE";
		parse_user_into(s, d);
	case "USER_SETTINGS_PROTO_UPDATE";
		{ sm := fmap(d, "settings");
		if sm != null && fint(sm, "type") == 1 { apply_settings_proto(s, fstr(sm, "proto")); } }
	case "USER_GUILD_SETTINGS_UPDATE";
		apply_guild_settings(s, d);
	case "VOICE_STATE_UPDATE";
		apply_voice_state(s, d);
	case "VOICE_SERVER_UPDATE";
		vs := *s.voice_server;
		free_str(vs.token, s.allocator);
		free_str(vs.endpoint, s.allocator);
		vs.guild_id = fsnow(d, "guild_id");
		vs.channel_id = fsnow(d, "channel_id");
		vs.token = clone_str(fstr(d, "token"), s.allocator);
		vs.endpoint = clone_str(fstr(d, "endpoint"), s.allocator);
		vs.version += 1;
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
	for mv: items { upsert_message(s, vmap(mv)); }
	l.loaded = true;
	l.loading = false;
	if before || !l.loaded { l.has_more_before = len(items) >= limit; } else { l.has_more_before = len(items) >= limit; }
}

// ---- read helpers for the UI ----

user_get :: (s: *Store, id: Snowflake) -> *User {
	u, ok := map_find_ptr(*s.users, id);
	return ifx ok then u else null;
}

channel_get :: (s: *Store, id: Snowflake) -> *Channel {
	c, ok := map_find_ptr(*s.channels, id);
	return ifx ok then c else null;
}

guild_get :: (s: *Store, id: Snowflake) -> *Guild {
	g, ok := map_find_ptr(*s.guilds, id);
	return ifx ok then g else null;
}

member_get :: (s: *Store, guild_id: Snowflake, user_id: Snowflake) -> *Member {
	gm, ok := map_find_ptr(*s.members, guild_id);
	if !ok { return null; }
	m, mok := *gm[user_id];
	return ifx mok then m else null;
}

messages_get :: (s: *Store, channel_id: Snowflake) -> []Message {
	l, ok := map_find_ptr(*s.messages, channel_id);
	return ifx ok then view(l.messages) else null;
}

channel_unread :: (s: *Store, channel_id: Snowflake) -> bool {
	c, ok := map_find_ptr(*s.channels, channel_id);
	if !ok { return false; }
	rs, has_rs := map_find_ptr(*s.read_states, channel_id);
	return c.last_message_id > (ifx has_rs then rs.last_message_id else 0);
}

// guild_channels_sorted returns channel ids in sidebar order: uncategorized
// first, then each category followed by its children, by (position, id).
guild_channels_sorted :: (s: *Store, guild_id: Snowflake, allocator := temp) -> []Snowflake {
	g, ok := map_find_ptr(*s.guilds, guild_id);
	if !ok { return .{}; }
	// Keys are computed once per channel, not per comparison: map lookups dominate otherwise.
	Keyed :: struct {
		parent_pos: int;
		parent_id: Snowflake;
		is_cat: bool;
		voiceish: bool;
		pos: int;
		id: Snowflake;
	}
	keyed := make_slice(Keyed, len(g.channels), temp);
	for id, i: g.channels {
		k := Keyed.{id = id};
		{ c, has := map_find_ptr(*s.channels, id);
		if has {
			k.voiceish = c.kind == .Guild_Voice || c.kind == .Guild_Stage_Voice;
			if c.kind == .Guild_Category {
				k.parent_pos, k.parent_id, k.is_cat, k.voiceish, k.pos = c.position, c.id, true, false, -1;
			} else if c.parent_id == 0 {
				k.parent_pos, k.pos = -1, c.position;
			} else {
				{ p, has_p := map_find_ptr(*s.channels, c.parent_id);
				if has_p { k.parent_pos, k.parent_id = p.position, p.id; } }
				k.pos = c.position;
			}
		} }
		keyed[i] = k;
	}
	slice.sort_by(keyed, (a: Keyed, b: Keyed) -> bool {
		if a.parent_pos != b.parent_pos { return a.parent_pos < b.parent_pos; }
		if a.parent_id != b.parent_id { return a.parent_id < b.parent_id; }
		if a.is_cat != b.is_cat { return a.is_cat; }
		if a.voiceish != b.voiceish { return !a.voiceish; }
		if a.pos != b.pos { return a.pos < b.pos; }
		return a.id < b.id;
	});
	ids := make_slice(Snowflake, len(keyed), allocator);
	for k, i: keyed { at(*ids, i).* = k.id; }
	return ids;
}

// private_channels_sorted: DMs by last activity, newest first.
private_channels_sorted :: (s: *Store, allocator := temp) -> []Snowflake {
	Keyed :: struct {
		last, id: Snowflake;
	}
	keyed := make_slice(Keyed, len(s.private_channels), temp);
	for id, i: s.private_channels {
		last := id;
		{ c, ok := map_find_ptr(*s.channels, id);
		if ok { last = max(c.last_message_id, id); } }
		keyed[i] = .{last, id};
	}
	slice.sort_by(keyed, (a: Keyed, b: Keyed) -> bool {return a.last > b.last;});
	ids := make_slice(Snowflake, len(keyed), allocator);
	for k, i: keyed { at(*ids, i).* = k.id; }
	return ids;
}

typing_users :: (s: *Store, channel_id: Snowflake) -> []Typing {
	l, ok := map_find_ptr(*s.typing, channel_id);
	return ifx ok then view(l) else null;
}


// store_destroy frees everything the store owns.
store_destroy :: (s: *Store) {
	push_allocator(s.allocator);
	extras_destroy();
	a := s.allocator;
	for * _, u: s.users { free_user(s, *u); }
	delete(s.users);
	for * _, g: s.guilds { free_guild(s, *g); }
	delete(s.guilds);
	delete(s.guild_order);
	for * _, c: s.channels { free_channel(s, *c); }
	delete(s.channels);
	delete(s.private_channels);
	for * _, gm: s.members {
		for * _, m: gm { free_member(s, *m); }
		delete(gm);
	}
	delete(s.members);
	for * _, l: s.messages {
		for * m: l.messages { free_message(s, *m); }
		delete(l.messages);
	}
	delete(s.messages);
	for _, p: s.presences { free_str(p.activity, a); }
	delete(s.presences);
	for _, r: s.relationships {
		free_str(r.nickname, a);
		free_str(r.since, a);
	}
	delete(s.relationships);
	delete(s.read_states);
	for _, gs: s.guild_settings {
		delete(gs.muted_channels);
		delete(gs.collapsed_channels);
		delete(gs.overrides);
	}
	delete(s.guild_settings);
	for _, v: s.voice_states { free_str(v.session_id, a); }
	delete(s.voice_states);
	for _, l: s.typing { delete(l); }
	delete(s.typing);
	for _, ml: s.member_lists {
		for it_: ml.items { free_list_item(s, it_); }
		delete(ml.items);
		for g: ml.groups { free_str(g.id, a); }
		delete(ml.groups);
		free_str(ml.id, a);
	}
	delete(s.member_lists);
	for ss: s.sessions {
		free_str(ss.session_id, a);
		free_str(ss.client, a);
		free_str(ss.os, a);
	}
	delete(s.sessions);
	st := *s.settings;
	free_str(st.custom_status_text, a);
	free_str(st.custom_status_emoji, a);
	free_str(st.locale, a);
	for fo: st.guild_folders {
		free_str(fo.name, a);
		delete(fo.guild_ids);
	}
	delete(st.guild_folders);
	delete(st.guild_positions);
	free_str(s.voice_server.token, a);
	free_str(s.voice_server.endpoint, a);
	free_str(s.session_id, a);
	free_str(s.resume_gateway_url, a);
	free_str(s.analytics_token, a);
	free_str(s.qos_token, a);
	free_str(s.country_code, a);
	s.* = .{};
}

