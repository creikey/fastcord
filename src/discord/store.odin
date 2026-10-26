package discord

import "core:encoding/base64"
import "core:slice"
import "core:strings"
import "fc:etf"
import "fc:protobuf"

// Store is the client-side cache the UI reads directly every frame.
// It is only mutated on the UI thread (client_poll drains the event queue),
// so readers need no locks. `changed` increases after every mutation batch.
Store :: struct {
	allocator:        Allocator,
	changed:          u64,
	connection:       Connection_State,
	ready:            bool,
	session_id:       string,
	me:               Snowflake,
	users:            map[Snowflake]User,
	guilds:           map[Snowflake]Guild,
	guild_order:      [dynamic]Snowflake, // READY order (see settings.guild_folders for the sidebar)
	channels:         map[Snowflake]Channel,
	private_channels: [dynamic]Snowflake,
	members:          map[Snowflake]map[Snowflake]Member, // guild -> user -> member
	messages:         map[Snowflake]Message_List, // channel -> messages
	presences:        map[Snowflake]Presence,
	relationships:    map[Snowflake]Relationship,
	read_states:      map[Snowflake]Read_State,
	guild_settings:   map[Snowflake]Guild_Settings,
	voice_states:     map[Snowflake]Voice_State, // user -> state (one voice connection per user)
	typing:           map[Snowflake][dynamic]Typing, // channel -> typers
	member_lists:     map[Snowflake]Member_List, // guild -> member sidebar
	sessions:         [dynamic]Session_Info,
	settings:         User_Settings,
	voice_server:     Voice_Server,
	resume_gateway_url: string,
	analytics_token:  string,
	qos_token:        string, // READY qos_token (base64 DerivedQosData) for reconnect IDENTIFY
	country_code:     string,
}

store_init :: proc(s: ^Store, allocator := context.allocator) {
	s.allocator = allocator
	context.allocator = allocator
	s.users = make(map[Snowflake]User)
	s.guilds = make(map[Snowflake]Guild)
	s.guild_order = make([dynamic]Snowflake)
	s.channels = make(map[Snowflake]Channel)
	s.private_channels = make([dynamic]Snowflake)
	s.members = make(map[Snowflake]map[Snowflake]Member)
	s.messages = make(map[Snowflake]Message_List)
	s.presences = make(map[Snowflake]Presence)
	s.relationships = make(map[Snowflake]Relationship)
	s.read_states = make(map[Snowflake]Read_State)
	s.guild_settings = make(map[Snowflake]Guild_Settings)
	s.voice_states = make(map[Snowflake]Voice_State)
	s.typing = make(map[Snowflake][dynamic]Typing)
	s.member_lists = make(map[Snowflake]Member_List)
	s.sessions = make([dynamic]Session_Info)
}

// ---- freeing ----

@(private)
free_user :: proc(s: ^Store, u: ^User) {
	a := s.allocator
	free_str(u.username, a)
	free_str(u.global_name, a)
	free_str(u.discriminator, a)
	free_str(u.avatar, a)
	free_str(u.banner, a)
	free_str(u.bio, a)
	free_str(u.pronouns, a)
}

@(private)
free_channel :: proc(s: ^Store, c: ^Channel) {
	a := s.allocator
	free_str(c.name, a)
	free_str(c.topic, a)
	free_str(c.icon, a)
	delete(c.recipient_ids)
	delete(c.overwrites)
}

@(private)
free_role :: proc(s: ^Store, r: ^Role) {
	free_str(r.name, s.allocator)
	free_str(r.icon, s.allocator)
	free_str(r.unicode_emoji, s.allocator)
}

@(private)
free_guild :: proc(s: ^Store, g: ^Guild) {
	a := s.allocator
	free_str(g.name, a)
	free_str(g.icon, a)
	free_str(g.banner, a)
	free_str(g.joined_at, a)
	delete(g.channels)
	for &r in g.roles do free_role(s, &r)
	delete(g.roles)
	for e in g.emojis do free_str(e.name, a)
	delete(g.emojis)
	for st in g.stickers {
		free_str(st.name, a)
		free_str(st.description, a)
	}
	delete(g.stickers)
	for f in g.features do free_str(f, a)
	delete(g.features)
}

@(private)
free_member :: proc(s: ^Store, m: ^Member) {
	free_str(m.nick, s.allocator)
	free_str(m.avatar, s.allocator)
	free_str(m.joined_at, s.allocator)
	delete(m.roles)
}

@(private)
free_attachment :: proc(s: ^Store, at: ^Attachment) {
	a := s.allocator
	free_str(at.filename, a)
	free_str(at.content_type, a)
	free_str(at.url, a)
	free_str(at.proxy_url, a)
	free_str(at.waveform, a)
}

@(private)
free_embed :: proc(s: ^Store, e: ^Embed) {
	a := s.allocator
	free_str(e.kind, a)
	free_str(e.title, a)
	free_str(e.description, a)
	free_str(e.url, a)
	free_str(e.thumbnail_url, a)
	free_str(e.image_url, a)
	free_str(e.video_url, a)
	free_str(e.provider, a)
	free_str(e.author_name, a)
}

@(private)
free_message :: proc(s: ^Store, m: ^Message) {
	a := s.allocator
	free_str(m.content, a)
	free_str(m.timestamp, a)
	free_str(m.edited_timestamp, a)
	free_str(m.nonce, a)
	for &at in m.attachments do free_attachment(s, &at)
	delete(m.attachments)
	for &e in m.embeds do free_embed(s, &e)
	delete(m.embeds)
	for r in m.reactions do free_str(r.emoji.name, a)
	delete(m.reactions)
	delete(m.sticker_ids)
	delete(m.mentions)
}

// ---- parsers (ETF or JSON value -> model, strings cloned into the store) ----

parse_user_into :: proc(s: ^Store, m: etf.Map) -> Snowflake {
	if m == nil do return 0
	id := fsnow(m, "id")
	if id == 0 do return 0
	a := s.allocator
	u, exists := &s.users[id]
	if !exists {
		s.users[id] = User{id = id}
		u = &s.users[id]
	}
	// Partial user objects (presence updates) only carry what changed.
	if vhas(m, "username") {free_str(u.username, a); u.username = clone_str(fstr(m, "username"), a)}
	if vhas(m, "global_name") {free_str(u.global_name, a); u.global_name = clone_str(fstr(m, "global_name"), a)}
	if vhas(m, "discriminator") {free_str(u.discriminator, a); u.discriminator = clone_str(fstr(m, "discriminator"), a)}
	if vhas(m, "avatar") {free_str(u.avatar, a); u.avatar = clone_str(fstr(m, "avatar"), a)}
	if vhas(m, "banner") {free_str(u.banner, a); u.banner = clone_str(fstr(m, "banner"), a)}
	if vhas(m, "bio") {free_str(u.bio, a); u.bio = clone_str(fstr(m, "bio"), a)}
	if vhas(m, "pronouns") {free_str(u.pronouns, a); u.pronouns = clone_str(fstr(m, "pronouns"), a)}
	if vhas(m, "accent_color") {
		ac := vget(m, "accent_color")
		u.accent_color = nil if ac == nil else u32(vint(ac))
	}
	if vhas(m, "bot") do u.bot = fbool(m, "bot")
	if vhas(m, "public_flags") do u.flags = u64(fint(m, "public_flags"))
	if vhas(m, "flags") do u.flags = u64(fint(m, "flags"))
	if vhas(m, "premium_type") do u.premium_type = int(fint(m, "premium_type"))
	return id
}

@(private)
parse_overwrites :: proc(out: ^[dynamic]Overwrite, l: []V) {
	clear(out)
	for ov in l {
		om := vmap(ov)
		append(out, Overwrite{
			id = fsnow(om, "id"),
			kind = u8(fint(om, "type")),
			allow = u64(fint(om, "allow")),
			deny = u64(fint(om, "deny")),
		})
	}
}

// parse_channel_into creates or updates a channel (guild_id may be implied by the container).
parse_channel_into :: proc(s: ^Store, m: etf.Map, guild_id: Snowflake = 0) -> Snowflake {
	id := fsnow(m, "id")
	if id == 0 do return 0
	a := s.allocator
	c, exists := &s.channels[id]
	if !exists {
		s.channels[id] = Channel{id = id}
		c = &s.channels[id]
		c.recipient_ids = make([dynamic]Snowflake, a)
		c.overwrites = make([dynamic]Overwrite, a)
	}
	if vhas(m, "type") do c.kind = Channel_Type(fint(m, "type"))
	gid := fsnow(m, "guild_id")
	if gid != 0 do c.guild_id = gid
	else if guild_id != 0 do c.guild_id = guild_id
	if vhas(m, "parent_id") do c.parent_id = fsnow(m, "parent_id")
	if vhas(m, "name") {free_str(c.name, a); c.name = clone_str(fstr(m, "name"), a)}
	if vhas(m, "topic") {free_str(c.topic, a); c.topic = clone_str(fstr(m, "topic"), a)}
	if vhas(m, "icon") {free_str(c.icon, a); c.icon = clone_str(fstr(m, "icon"), a)}
	if vhas(m, "position") do c.position = int(fint(m, "position"))
	if vhas(m, "nsfw") do c.nsfw = fbool(m, "nsfw")
	if vhas(m, "last_message_id") do c.last_message_id = fsnow(m, "last_message_id")
	if vhas(m, "rate_limit_per_user") do c.rate_limit_per_user = int(fint(m, "rate_limit_per_user"))
	if vhas(m, "bitrate") do c.bitrate = int(fint(m, "bitrate"))
	if vhas(m, "user_limit") do c.user_limit = int(fint(m, "user_limit"))
	if vhas(m, "owner_id") do c.owner_id = fsnow(m, "owner_id")
	if vhas(m, "flags") do c.flags = u64(fint(m, "flags"))
	if vhas(m, "permission_overwrites") do parse_overwrites(&c.overwrites, flist(m, "permission_overwrites"))
	if vhas(m, "recipient_ids") {
		clear(&c.recipient_ids)
		for r in flist(m, "recipient_ids") do append(&c.recipient_ids, vsnow(r))
	} else if vhas(m, "recipients") {
		clear(&c.recipient_ids)
		for r in flist(m, "recipients") {
			uid := parse_user_into(s, vmap(r))
			if uid != 0 do append(&c.recipient_ids, uid)
		}
	}
	return id
}

@(private)
parse_role :: proc(s: ^Store, m: etf.Map) -> Role {
	a := s.allocator
	r := Role{
		id = fsnow(m, "id"),
		name = clone_str(fstr(m, "name"), a),
		color = u32(fint(m, "color")),
		position = int(fint(m, "position")),
		permissions = u64(fint(m, "permissions")),
		hoist = fbool(m, "hoist"),
		icon = clone_str(fstr(m, "icon"), a),
		unicode_emoji = clone_str(fstr(m, "unicode_emoji"), a),
	}
	if colors := fmap(m, "colors"); colors != nil && vhas(colors, "primary_color") do r.color = u32(fint(colors, "primary_color"))
	return r
}

@(private)
parse_emojis :: proc(s: ^Store, g: ^Guild, l: []V) {
	for e in g.emojis do free_str(e.name, s.allocator)
	clear(&g.emojis)
	for ev in l {
		em := vmap(ev)
		append(&g.emojis, Emoji{
			id = fsnow(em, "id"),
			name = clone_str(fstr(em, "name"), s.allocator),
			animated = fbool(em, "animated"),
			available = !vhas(em, "available") || fbool(em, "available"),
			guild_id = g.id,
		})
	}
}

@(private)
parse_stickers :: proc(s: ^Store, g: ^Guild, l: []V) {
	for st in g.stickers {
		free_str(st.name, s.allocator)
		free_str(st.description, s.allocator)
	}
	clear(&g.stickers)
	for sv in l {
		sm := vmap(sv)
		append(&g.stickers, Sticker{
			id = fsnow(sm, "id"),
			name = clone_str(fstr(sm, "name"), s.allocator),
			format_type = int(fint(sm, "format_type")),
			guild_id = g.id,
			description = clone_str(fstr(sm, "description"), s.allocator),
		})
	}
}

// parse_guild_props applies guild-level fields (READY nests them in `properties`).
@(private)
parse_guild_props :: proc(s: ^Store, g: ^Guild, p: etf.Map) {
	a := s.allocator
	if vhas(p, "name") {free_str(g.name, a); g.name = clone_str(fstr(p, "name"), a)}
	if vhas(p, "icon") {free_str(g.icon, a); g.icon = clone_str(fstr(p, "icon"), a)}
	if vhas(p, "banner") {free_str(g.banner, a); g.banner = clone_str(fstr(p, "banner"), a)}
	if vhas(p, "owner_id") do g.owner_id = fsnow(p, "owner_id")
	if vhas(p, "system_channel_id") do g.system_channel_id = fsnow(p, "system_channel_id")
	if vhas(p, "features") {
		for f in g.features do free_str(f, a)
		clear(&g.features)
		for f in flist(p, "features") do append(&g.features, clone_str(vstr(f), a))
	}
}

parse_guild_into :: proc(s: ^Store, m: etf.Map) -> Snowflake {
	id := fsnow(m, "id")
	if id == 0 do return 0
	a := s.allocator
	g, exists := &s.guilds[id]
	if !exists {
		s.guilds[id] = Guild{id = id}
		g = &s.guilds[id]
		g.channels = make([dynamic]Snowflake, a)
		g.roles = make([dynamic]Role, a)
		g.emojis = make([dynamic]Emoji, a)
		g.stickers = make([dynamic]Sticker, a)
		g.features = make([dynamic]string, a)
		append(&s.guild_order, id)
	}
	g.unavailable = fbool(m, "unavailable")
	if props := fmap(m, "properties"); props != nil {
		parse_guild_props(s, g, props)
	} else {
		parse_guild_props(s, g, m)
	}
	if vhas(m, "member_count") do g.member_count = int(fint(m, "member_count"))
	if vhas(m, "lazy") do g.lazy = fbool(m, "lazy")
	if vhas(m, "joined_at") {free_str(g.joined_at, a); g.joined_at = clone_str(fstr(m, "joined_at"), a)}
	if vhas(m, "roles") {
		for &r in g.roles do free_role(s, &r)
		clear(&g.roles)
		for rv in flist(m, "roles") do append(&g.roles, parse_role(s, vmap(rv)))
	}
	if vhas(m, "emojis") do parse_emojis(s, g, flist(m, "emojis"))
	if vhas(m, "stickers") do parse_stickers(s, g, flist(m, "stickers"))
	if vhas(m, "channels") {
		clear(&g.channels)
		for cv in flist(m, "channels") {
			cid := parse_channel_into(s, vmap(cv), id)
			if cid != 0 do append(&g.channels, cid)
		}
	}
	for tv in flist(m, "threads") {
		cid := parse_channel_into(s, vmap(tv), id)
		if cid != 0 && !slice.contains(g.channels[:], cid) do append(&g.channels, cid)
	}
	for vs in flist(m, "voice_states") do apply_voice_state(s, vmap(vs), id)
	for mv in flist(m, "members") do parse_member_into(s, id, vmap(mv))
	for pv in flist(m, "presences") do apply_presence(s, vmap(pv))
	return id
}

parse_member_into :: proc(s: ^Store, guild_id: Snowflake, m: etf.Map) -> Snowflake {
	if m == nil do return 0
	uid := fsnow(m, "user_id")
	if um := fmap(m, "user"); um != nil do uid = parse_user_into(s, um)
	if uid == 0 do return 0
	a := s.allocator
	gm, gok := &s.members[guild_id]
	if !gok {
		s.members[guild_id] = make(map[Snowflake]Member, allocator = a)
		gm = &s.members[guild_id]
	}
	mem_, exists := &gm[uid]
	if !exists {
		gm[uid] = Member{user_id = uid, roles = make([dynamic]Snowflake, a)}
		mem_ = &gm[uid]
	}
	if vhas(m, "nick") {free_str(mem_.nick, a); mem_.nick = clone_str(fstr(m, "nick"), a)}
	if vhas(m, "avatar") {free_str(mem_.avatar, a); mem_.avatar = clone_str(fstr(m, "avatar"), a)}
	if vhas(m, "joined_at") {free_str(mem_.joined_at, a); mem_.joined_at = clone_str(fstr(m, "joined_at"), a)}
	if vhas(m, "roles") {
		clear(&mem_.roles)
		for r in flist(m, "roles") do append(&mem_.roles, vsnow(r))
	}
	if pm := fmap(m, "presence"); pm != nil do apply_presence(s, pm, uid)
	return uid
}

@(private)
parse_emoji_ref :: proc(s: ^Store, m: etf.Map) -> Emoji {
	return Emoji{id = fsnow(m, "id"), name = clone_str(fstr(m, "name"), s.allocator), animated = fbool(m, "animated"), available = true}
}

@(private)
parse_attachment :: proc(s: ^Store, m: etf.Map) -> Attachment {
	a := s.allocator
	return Attachment{
		id = fsnow(m, "id"),
		filename = clone_str(fstr(m, "filename"), a),
		content_type = clone_str(fstr(m, "content_type"), a),
		size = int(fint(m, "size")),
		url = clone_str(fstr(m, "url"), a),
		proxy_url = clone_str(fstr(m, "proxy_url"), a),
		width = int(fint(m, "width")),
		height = int(fint(m, "height")),
		duration_secs = f32(vf64(vget(m, "duration_secs"))),
		waveform = clone_str(fstr(m, "waveform"), a),
		flags = u64(fint(m, "flags")),
	}
}

@(private)
parse_embed :: proc(s: ^Store, m: etf.Map) -> Embed {
	a := s.allocator
	e := Embed{
		kind = clone_str(fstr(m, "type"), a),
		title = clone_str(fstr(m, "title"), a),
		description = clone_str(fstr(m, "description"), a),
		url = clone_str(fstr(m, "url"), a),
		color = u32(fint(m, "color")),
	}
	if t := fmap(m, "thumbnail"); t != nil {
		e.thumbnail_url = clone_str(fstr(t, "proxy_url") if vhas(t, "proxy_url") else fstr(t, "url"), a)
		e.thumbnail_w = int(fint(t, "width"))
		e.thumbnail_h = int(fint(t, "height"))
	}
	if im := fmap(m, "image"); im != nil {
		e.image_url = clone_str(fstr(im, "proxy_url") if vhas(im, "proxy_url") else fstr(im, "url"), a)
		e.image_w = int(fint(im, "width"))
		e.image_h = int(fint(im, "height"))
	}
	if vd := fmap(m, "video"); vd != nil do e.video_url = clone_str(fstr(vd, "url"), a)
	if p := fmap(m, "provider"); p != nil do e.provider = clone_str(fstr(p, "name"), a)
	if au := fmap(m, "author"); au != nil do e.author_name = clone_str(fstr(au, "name"), a)
	return e
}

@(private)
parse_reactions :: proc(s: ^Store, msg: ^Message, l: []V) {
	for r in msg.reactions do free_str(r.emoji.name, s.allocator)
	clear(&msg.reactions)
	for rv in l {
		rm := vmap(rv)
		r := Reaction{
			emoji = parse_emoji_ref(s, fmap(rm, "emoji")),
			count = int(fint(rm, "count")),
			burst_count = int(fint(rm, "burst_count")),
			me = fbool(rm, "me"),
			me_burst = fbool(rm, "me_burst"),
		}
		if cd := fmap(rm, "count_details"); cd != nil do r.burst_count = int(fint(cd, "burst"))
		append(&msg.reactions, r)
	}
}

// parse_message_fields fills msg from a full or partial (MESSAGE_UPDATE) object.
@(private)
parse_message_fields :: proc(s: ^Store, msg: ^Message, m: etf.Map) {
	a := s.allocator
	if vhas(m, "channel_id") do msg.channel_id = fsnow(m, "channel_id")
	if au := fmap(m, "author"); au != nil do msg.author_id = parse_user_into(s, au)
	if vhas(m, "type") do msg.kind = int(fint(m, "type"))
	if vhas(m, "content") {free_str(msg.content, a); msg.content = clone_str(fstr(m, "content"), a)}
	if vhas(m, "timestamp") {free_str(msg.timestamp, a); msg.timestamp = clone_str(fstr(m, "timestamp"), a)}
	if vhas(m, "edited_timestamp") {free_str(msg.edited_timestamp, a); msg.edited_timestamp = clone_str(fstr(m, "edited_timestamp"), a)}
	if vhas(m, "nonce") {
		free_str(msg.nonce, a)
		nv := vget(m, "nonce")
		#partial switch x in nv {
		case string:
			msg.nonce = clone_str(x, a)
		case i64, etf.Big:
			msg.nonce = clone_str(snowflake_string(vsnow(nv)), a)
		case:
			msg.nonce = ""
		}
	}
	if vhas(m, "flags") do msg.flags = u64(fint(m, "flags"))
	if vhas(m, "mention_everyone") do msg.mention_everyone = fbool(m, "mention_everyone")
	if vhas(m, "attachments") {
		for &at in msg.attachments do free_attachment(s, &at)
		clear(&msg.attachments)
		for av in flist(m, "attachments") do append(&msg.attachments, parse_attachment(s, vmap(av)))
	}
	if vhas(m, "embeds") {
		for &e in msg.embeds do free_embed(s, &e)
		clear(&msg.embeds)
		for ev in flist(m, "embeds") do append(&msg.embeds, parse_embed(s, vmap(ev)))
	}
	if vhas(m, "reactions") do parse_reactions(s, msg, flist(m, "reactions"))
	if vhas(m, "mentions") {
		clear(&msg.mentions)
		for uv in flist(m, "mentions") {
			uid := parse_user_into(s, vmap(uv))
			if uid != 0 do append(&msg.mentions, uid)
		}
	}
	if vhas(m, "sticker_items") {
		clear(&msg.sticker_ids)
		for sv in flist(m, "sticker_items") do append(&msg.sticker_ids, fsnow(vmap(sv), "id"))
	}
	if ref := fmap(m, "message_reference"); ref != nil do msg.referenced_id = fsnow(ref, "message_id")
	if rm := fmap(m, "referenced_message"); rm != nil {
		// Keep the referenced author resolvable for reply previews.
		if au := fmap(rm, "author"); au != nil do parse_user_into(s, au)
	}
	gid := fsnow(m, "guild_id")
	if mm := fmap(m, "member"); mm != nil && gid != 0 && msg.author_id != 0 {
		// MESSAGE_CREATE members omit `user`; attach to the author.
		if !vhas(mm, "user") && !vhas(mm, "user_id") {
			parse_member_with_id(s, gid, msg.author_id, mm)
		} else {
			parse_member_into(s, gid, mm)
		}
	}
}

@(private)
parse_member_with_id :: proc(s: ^Store, guild_id, uid: Snowflake, m: etf.Map) {
	a := s.allocator
	gm, gok := &s.members[guild_id]
	if !gok {
		s.members[guild_id] = make(map[Snowflake]Member, allocator = a)
		gm = &s.members[guild_id]
	}
	mem_, exists := &gm[uid]
	if !exists {
		gm[uid] = Member{user_id = uid, roles = make([dynamic]Snowflake, a)}
		mem_ = &gm[uid]
	}
	if vhas(m, "nick") {free_str(mem_.nick, a); mem_.nick = clone_str(fstr(m, "nick"), a)}
	if vhas(m, "avatar") {free_str(mem_.avatar, a); mem_.avatar = clone_str(fstr(m, "avatar"), a)}
	if vhas(m, "joined_at") {free_str(mem_.joined_at, a); mem_.joined_at = clone_str(fstr(m, "joined_at"), a)}
	if vhas(m, "roles") {
		clear(&mem_.roles)
		for r in flist(m, "roles") do append(&mem_.roles, vsnow(r))
	}
}

new_message :: proc(s: ^Store) -> Message {
	a := s.allocator
	return Message{
		attachments = make([dynamic]Attachment, a),
		embeds = make([dynamic]Embed, a),
		reactions = make([dynamic]Reaction, a),
		sticker_ids = make([dynamic]Snowflake, a),
		mentions = make([dynamic]Snowflake, a),
	}
}

@(private)
message_list :: proc(s: ^Store, channel_id: Snowflake) -> ^Message_List {
	l, ok := &s.messages[channel_id]
	if !ok {
		s.messages[channel_id] = Message_List{messages = make([dynamic]Message, s.allocator), has_more_before = true}
		l = &s.messages[channel_id]
	}
	return l
}

// message_index finds a message by id (binary search; pending messages sort by nonce id).
message_index :: proc(l: ^Message_List, id: Snowflake) -> int {
	i, found := slice.binary_search_by(l.messages[:], id, proc(m: Message, id: Snowflake) -> slice.Ordering {
		if m.id < id do return .Less
		if m.id > id do return .Greater
		return .Equal
	})
	return i if found else -1
}

@(private)
insert_message :: proc(l: ^Message_List, msg: Message) {
	i, _ := slice.binary_search_by(l.messages[:], msg.id, proc(m: Message, id: Snowflake) -> slice.Ordering {
		if m.id < id do return .Less
		if m.id > id do return .Greater
		return .Equal
	})
	inject_at(&l.messages, i, msg)
}

// upsert_message handles MESSAGE_CREATE / REST message objects, replacing a
// pending optimistic message with the same nonce.
upsert_message :: proc(s: ^Store, m: etf.Map) -> Snowflake {
	id := fsnow(m, "id")
	cid := fsnow(m, "channel_id")
	if id == 0 || cid == 0 do return 0
	l := message_list(s, cid)
	if i := message_index(l, id); i >= 0 {
		msg := &l.messages[i]
		parse_message_fields(s, msg, m)
		msg.pending = false
		msg.failed = false
		return id
	}
	nonce := ""
	nv := vget(m, "nonce")
	#partial switch x in nv {
	case string:
		nonce = x
	case i64, etf.Big:
		nonce = snowflake_string(vsnow(nv))
	}
	if nonce != "" {
		for &pm, i in l.messages {
			if pm.pending && pm.nonce == nonce {
				free_message(s, &pm)
				ordered_remove(&l.messages, i)
				break
			}
		}
	}
	msg := new_message(s)
	msg.id = id
	parse_message_fields(s, &msg, m)
	insert_message(l, msg)
	if c, ok := &s.channels[cid]; ok && id > c.last_message_id do c.last_message_id = id
	return id
}

// ---- presence / voice / misc ----

apply_presence :: proc(s: ^Store, m: etf.Map, user_hint: Snowflake = 0) {
	uid := user_hint
	if um := fmap(m, "user"); um != nil {
		if u := parse_user_into(s, um); u != 0 do uid = u
	}
	if u := fsnow(m, "user_id"); u != 0 do uid = u
	if uid == 0 do return
	p := Presence{user_id = uid, status = status_from_string(fstr(m, "status"))}
	if cs := fmap(m, "client_status"); cs != nil {
		p.desktop = status_from_string(fstr(cs, "desktop"))
		p.mobile = status_from_string(fstr(cs, "mobile"))
		p.web = status_from_string(fstr(cs, "web"))
	}
	old, had := s.presences[uid]
	if had do free_str(old.activity, s.allocator)
	for av in flist(m, "activities") {
		am := vmap(av)
		t := fint(am, "type")
		txt := fstr(am, "state") if t == 4 else fstr(am, "name")
		if txt != "" {
			p.activity = clone_str(txt, s.allocator)
			break
		}
	}
	s.presences[uid] = p
}

apply_voice_state :: proc(s: ^Store, m: etf.Map, guild_hint: Snowflake = 0) {
	uid := fsnow(m, "user_id")
	if mm := fmap(m, "member"); mm != nil {
		gid := fsnow(m, "guild_id")
		if gid == 0 do gid = guild_hint
		u := parse_member_into(s, gid, mm)
		if uid == 0 do uid = u
	}
	if uid == 0 do return
	if old, ok := s.voice_states[uid]; ok do free_str(old.session_id, s.allocator)
	cid := fsnow(m, "channel_id")
	if cid == 0 {
		delete_key(&s.voice_states, uid)
		return
	}
	gid := fsnow(m, "guild_id")
	if gid == 0 do gid = guild_hint
	s.voice_states[uid] = Voice_State{
		user_id = uid,
		channel_id = cid,
		guild_id = gid,
		session_id = clone_str(fstr(m, "session_id"), s.allocator),
		self_mute = fbool(m, "self_mute"),
		self_deaf = fbool(m, "self_deaf"),
		mute = fbool(m, "mute"),
		deaf = fbool(m, "deaf"),
		self_video = fbool(m, "self_video"),
		self_stream = fbool(m, "self_stream"),
	}
}

@(private)
apply_relationship :: proc(s: ^Store, m: etf.Map) {
	uid := fsnow(m, "user_id")
	if um := fmap(m, "user"); um != nil do uid = parse_user_into(s, um)
	if uid == 0 do uid = fsnow(m, "id")
	if uid == 0 do return
	r, ok := &s.relationships[uid]
	if !ok {
		s.relationships[uid] = Relationship{user_id = uid}
		r = &s.relationships[uid]
	}
	if vhas(m, "type") do r.kind = Relationship_Type(fint(m, "type"))
	if vhas(m, "nickname") {free_str(r.nickname, s.allocator); r.nickname = clone_str(fstr(m, "nickname"), s.allocator)}
	if vhas(m, "since") {free_str(r.since, s.allocator); r.since = clone_str(fstr(m, "since"), s.allocator)}
}

@(private)
apply_read_state :: proc(s: ^Store, m: etf.Map) {
	if vhas(m, "read_state_type") && fint(m, "read_state_type") != 0 do return
	cid := fsnow(m, "id")
	if cid == 0 do cid = fsnow(m, "channel_id")
	if cid == 0 do return
	rs := s.read_states[cid]
	rs.channel_id = cid
	if vhas(m, "last_message_id") do rs.last_message_id = fsnow(m, "last_message_id")
	if vhas(m, "message_id") do rs.last_message_id = fsnow(m, "message_id")
	if vhas(m, "mention_count") do rs.mention_count = int(fint(m, "mention_count"))
	if vhas(m, "last_viewed") do rs.last_viewed = int(fint(m, "last_viewed"))
	if vhas(m, "flags") do rs.flags = u64(fint(m, "flags"))
	s.read_states[cid] = rs
}

@(private)
apply_guild_settings :: proc(s: ^Store, m: etf.Map) {
	gid := fsnow(m, "guild_id")
	gs, ok := &s.guild_settings[gid]
	if !ok {
		s.guild_settings[gid] = Guild_Settings{guild_id = gid, muted_channels = make([dynamic]Snowflake, s.allocator), collapsed_channels = make([dynamic]Snowflake, s.allocator)}
		gs = &s.guild_settings[gid]
	}
	gs.muted = fbool(m, "muted")
	gs.message_notifications = int(fint(m, "message_notifications"))
	gs.suppress_everyone = fbool(m, "suppress_everyone")
	gs.suppress_roles = fbool(m, "suppress_roles")
	clear(&gs.muted_channels)
	clear(&gs.collapsed_channels)
	for ov in flist(m, "channel_overrides") {
		om := vmap(ov)
		if fbool(om, "muted") do append(&gs.muted_channels, fsnow(om, "channel_id"))
		if fbool(om, "collapsed") do append(&gs.collapsed_channels, fsnow(om, "channel_id"))
	}
}

// ---- user_settings_proto (PreloadedUserSettings) ----

// apply_settings_proto decodes the fields the UI uses: status (11), localization
// (12), appearance/theme (13), guild folders (14).
apply_settings_proto :: proc(s: ^Store, b64: string) {
	raw, err := base64.decode(b64, allocator = context.temp_allocator)
	if err != nil do return
	st := &s.settings
	a := s.allocator
	if f, ok := protobuf.find_path(raw, 11, 1, 1); ok do st.status = status_from_string(string(f.bytes))
	if f, ok := protobuf.find_path(raw, 11, 2, 1); ok {free_str(st.custom_status_text, a); st.custom_status_text = clone_str(string(f.bytes), a)}
	if f, ok := protobuf.find_path(raw, 11, 2, 3); ok {free_str(st.custom_status_emoji, a); st.custom_status_emoji = clone_str(string(f.bytes), a)}
	if f, ok := protobuf.find_path(raw, 12, 1, 1); ok {free_str(st.locale, a); st.locale = clone_str(string(f.bytes), a)}
	if f, ok := protobuf.find_path(raw, 12, 2, 1); ok do st.timezone_offset = int(i32(f.value))
	if f, ok := protobuf.find_path(raw, 13, 1); ok do st.theme = Theme(f.value)
	else do st.theme = .Dark
	if f, ok := protobuf.find_path(raw, 13, 2); ok do st.developer_mode = f.value != 0
	if gf, ok := protobuf.find(raw, 14); ok {
		for &fo in st.guild_folders {
			free_str(fo.name, a)
			delete(fo.guild_ids)
		}
		clear(&st.guild_folders)
		clear(&st.guild_positions)
		r := protobuf.Reader{buf = gf.bytes}
		for {
			fld, more := protobuf.next(&r)
			if !more do break
			switch fld.num {
			case 1:
				fo := Guild_Folder{guild_ids = make([dynamic]Snowflake, a)}
				if ids, iok := protobuf.find(fld.bytes, 1); iok {
					for id in protobuf.packed_fixed64(ids.bytes, context.temp_allocator) do append(&fo.guild_ids, Snowflake(id))
				}
				if v, vok := protobuf.find_path(fld.bytes, 2, 1); vok do fo.id = i64(v.value)
				if v, vok := protobuf.find_path(fld.bytes, 3, 1); vok do fo.name = clone_str(string(v.bytes), a)
				if v, vok := protobuf.find_path(fld.bytes, 4, 1); vok {
					fo.color = v.value
					fo.has_color = true
				}
				append(&st.guild_folders, fo)
			case 2:
				for id in protobuf.packed_fixed64(fld.bytes, context.temp_allocator) do append(&st.guild_positions, Snowflake(id))
			}
		}
	}
}

// ---- READY / READY_SUPPLEMENTAL ----

apply_ready :: proc(s: ^Store, d: etf.Map) {
	a := s.allocator
	free_str(s.session_id, a)
	s.session_id = clone_str(fstr(d, "session_id"), a)
	free_str(s.resume_gateway_url, a)
	s.resume_gateway_url = clone_str(fstr(d, "resume_gateway_url"), a)
	free_str(s.analytics_token, a)
	s.analytics_token = clone_str(fstr(d, "analytics_token"), a)
	free_str(s.qos_token, a)
	s.qos_token = clone_str(fstr(d, "qos_token"), a)
	free_str(s.country_code, a)
	s.country_code = clone_str(fstr(d, "country_code"), a)
	s.me = parse_user_into(s, fmap(d, "user"))
	for uv in flist(d, "users") do parse_user_into(s, vmap(uv))
	guilds := flist(d, "guilds")
	for gv in guilds do parse_guild_into(s, vmap(gv))
	// merged_members[i] lists members (ourselves) of guilds[i].
	for ml, i in flist(d, "merged_members") {
		if i >= len(guilds) do break
		gid := fsnow(vmap(guilds[i]), "id")
		for mv in vlist(ml) do parse_member_into(s, gid, vmap(mv))
	}
	clear(&s.private_channels)
	for cv in flist(d, "private_channels") {
		cid := parse_channel_into(s, vmap(cv))
		if cid != 0 do append(&s.private_channels, cid)
	}
	for rv in flist(d, "relationships") do apply_relationship(s, vmap(rv))
	if rs := fmap(d, "read_state"); rs != nil {
		for e in flist(rs, "entries") do apply_read_state(s, vmap(e))
	}
	if ugs := fmap(d, "user_guild_settings"); ugs != nil {
		for e in flist(ugs, "entries") do apply_guild_settings(s, vmap(e))
	}
	if sp := fstr(d, "user_settings_proto"); sp != "" do apply_settings_proto(s, sp)
	apply_sessions(s, flist(d, "sessions"))
	s.ready = true
	s.connection = .Ready
}

apply_ready_supplemental :: proc(s: ^Store, d: etf.Map) {
	guilds := flist(d, "guilds")
	for gv, i in guilds {
		gm := vmap(gv)
		gid := fsnow(gm, "id")
		for vs in flist(gm, "voice_states") do apply_voice_state(s, vmap(vs), gid)
		_ = i
	}
	for ml, i in flist(d, "merged_members") {
		if i >= len(guilds) do break
		gid := fsnow(vmap(guilds[i]), "id")
		for mv in vlist(ml) do parse_member_into(s, gid, vmap(mv))
	}
	if mp := fmap(d, "merged_presences"); mp != nil {
		for pv in flist(mp, "friends") do apply_presence(s, vmap(pv))
		for gl in flist(mp, "guilds") do for pv in vlist(gl) do apply_presence(s, vmap(pv))
	}
	for cv in flist(d, "lazy_private_channels") {
		cid := parse_channel_into(s, vmap(cv))
		if cid != 0 && !slice.contains(s.private_channels[:], cid) do append(&s.private_channels, cid)
	}
}

@(private)
apply_sessions :: proc(s: ^Store, l: []V) {
	for ss in s.sessions {
		free_str(ss.session_id, s.allocator)
		free_str(ss.client, s.allocator)
		free_str(ss.os, s.allocator)
	}
	clear(&s.sessions)
	for sv in l {
		sm := vmap(sv)
		ci := fmap(sm, "client_info")
		append(&s.sessions, Session_Info{
			session_id = clone_str(fstr(sm, "session_id"), s.allocator),
			status = status_from_string(fstr(sm, "status")),
			client = clone_str(fstr(ci, "client"), s.allocator),
			os = clone_str(fstr(ci, "os"), s.allocator),
		})
	}
}

// ---- member list (op 37 channels → GUILD_MEMBER_LIST_UPDATE) ----

@(private)
member_list_item :: proc(s: ^Store, guild_id: Snowflake, iv: etf.Map) -> Member_List_Item {
	if g := fmap(iv, "group"); g != nil {
		return Member_List_Item{is_group = true, group_id = clone_str(fstr(g, "id"), s.allocator), count = int(fint(g, "count"))}
	}
	if mm := fmap(iv, "member"); mm != nil {
		return Member_List_Item{user_id = parse_member_into(s, guild_id, mm)}
	}
	return {}
}

@(private)
free_list_item :: proc(s: ^Store, it: Member_List_Item) {
	free_str(it.group_id, s.allocator)
}

apply_member_list_update :: proc(s: ^Store, d: etf.Map) {
	gid := fsnow(d, "guild_id")
	ml, ok := &s.member_lists[gid]
	if !ok {
		s.member_lists[gid] = Member_List{items = make([dynamic]Member_List_Item, s.allocator)}
		ml = &s.member_lists[gid]
	}
	id := fstr(d, "id")
	if ml.id != id {
		free_str(ml.id, s.allocator)
		ml.id = clone_str(id, s.allocator)
	}
	ml.member_count = int(fint(d, "member_count"))
	ml.online_count = int(fint(d, "online_count"))
	for opv in flist(d, "ops") {
		op := vmap(opv)
		switch fstr(op, "op") {
		case "SYNC":
			r := flist(op, "range")
			start := int(vint(r[0])) if len(r) == 2 else 0
			items := flist(op, "items")
			for len(ml.items) < start + len(items) do append(&ml.items, Member_List_Item{})
			for iv, k in items {
				free_list_item(s, ml.items[start + k])
				ml.items[start + k] = member_list_item(s, gid, vmap(iv))
			}
		case "INSERT":
			idx := int(fint(op, "index"))
			it := member_list_item(s, gid, fmap(op, "item"))
			if idx >= len(ml.items) do append(&ml.items, it)
			else do inject_at(&ml.items, idx, it)
		case "UPDATE":
			idx := int(fint(op, "index"))
			if idx >= 0 && idx < len(ml.items) {
				free_list_item(s, ml.items[idx])
				ml.items[idx] = member_list_item(s, gid, fmap(op, "item"))
			}
		case "DELETE":
			idx := int(fint(op, "index"))
			if idx >= 0 && idx < len(ml.items) {
				free_list_item(s, ml.items[idx])
				ordered_remove(&ml.items, idx)
			}
		case "INVALIDATE":
			r := flist(op, "range")
			if len(r) == 2 {
				for k := int(vint(r[0])); k <= int(vint(r[1])) && k < len(ml.items); k += 1 {
					free_list_item(s, ml.items[k])
					ml.items[k] = {}
				}
			}
		}
	}
}

// ---- typing ----

TYPING_DURATION_MS :: 10_000

store_expire_typing :: proc(s: ^Store, now: i64) -> bool {
	changed := false
	for _, &l in s.typing {
		for i := len(l) - 1; i >= 0; i -= 1 {
			if l[i].until <= now {
				ordered_remove(&l, i)
				changed = true
			}
		}
	}
	return changed
}

@(private)
apply_typing :: proc(s: ^Store, d: etf.Map, now: i64) {
	cid := fsnow(d, "channel_id")
	uid := fsnow(d, "user_id")
	if mm := fmap(d, "member"); mm != nil {
		if gid := fsnow(d, "guild_id"); gid != 0 {
			u := parse_member_into(s, gid, mm)
			if uid == 0 do uid = u
		}
	}
	if cid == 0 || uid == 0 do return
	l, ok := &s.typing[cid]
	if !ok {
		s.typing[cid] = make([dynamic]Typing, s.allocator)
		l = &s.typing[cid]
	}
	for &t in l {
		if t.user_id == uid {
			t.until = now + TYPING_DURATION_MS
			return
		}
	}
	append(l, Typing{uid, now + TYPING_DURATION_MS})
}

@(private)
remove_typing :: proc(s: ^Store, cid, uid: Snowflake) {
	if l, ok := &s.typing[cid]; ok {
		for t, i in l {
			if t.user_id == uid {
				ordered_remove(l, i)
				return
			}
		}
	}
}

// ---- reactions ----

@(private)
emoji_matches :: proc(e: Emoji, id: Snowflake, name: string) -> bool {
	if id != 0 do return e.id == id
	return e.id == 0 && e.name == name
}

@(private)
apply_reaction :: proc(s: ^Store, d: etf.Map, add: bool) {
	cid := fsnow(d, "channel_id")
	mid := fsnow(d, "message_id")
	uid := fsnow(d, "user_id")
	em := fmap(d, "emoji")
	eid := fsnow(em, "id")
	ename := fstr(em, "name")
	burst := fbool(d, "burst")
	l, ok := &s.messages[cid]
	if !ok do return
	i := message_index(l, mid)
	if i < 0 do return
	msg := &l.messages[i]
	mine := uid == s.me
	for &r, k in msg.reactions {
		if !emoji_matches(r.emoji, eid, ename) do continue
		if add {
			r.count += 1
			if burst do r.burst_count += 1
			if mine {
				if burst do r.me_burst = true
				else do r.me = true
			}
		} else {
			r.count -= 1
			if burst do r.burst_count = max(r.burst_count - 1, 0)
			if mine {
				if burst do r.me_burst = false
				else do r.me = false
			}
			if r.count <= 0 {
				free_str(r.emoji.name, s.allocator)
				ordered_remove(&msg.reactions, k)
			}
		}
		return
	}
	if add {
		r := Reaction{emoji = parse_emoji_ref(s, em), count = 1}
		if burst do r.burst_count = 1
		if mine {
			if burst do r.me_burst = true
			else do r.me = true
		}
		append(&msg.reactions, r)
	}
}

// ---- dispatch application ----

remove_guild :: proc(s: ^Store, gid: Snowflake) {
	g, ok := &s.guilds[gid]
	if !ok do return
	for cid in g.channels {
		if c, cok := &s.channels[cid]; cok {
			free_channel(s, c)
			delete_key(&s.channels, cid)
		}
	}
	free_guild(s, g)
	delete_key(&s.guilds, gid)
	if i, found := slice.linear_search(s.guild_order[:], gid); found do ordered_remove(&s.guild_order, i)
	if gm, mok := &s.members[gid]; mok {
		for _, &m in gm do free_member(s, &m)
		delete(gm^)
		delete_key(&s.members, gid)
	}
}

remove_channel :: proc(s: ^Store, cid: Snowflake) {
	c, ok := &s.channels[cid]
	if !ok do return
	if g, gok := &s.guilds[c.guild_id]; gok {
		if i, found := slice.linear_search(g.channels[:], cid); found do ordered_remove(&g.channels, i)
	}
	if i, found := slice.linear_search(s.private_channels[:], cid); found do ordered_remove(&s.private_channels, i)
	free_channel(s, c)
	delete_key(&s.channels, cid)
	if l, lok := &s.messages[cid]; lok {
		for &m in l.messages do free_message(s, &m)
		delete(l.messages)
		delete_key(&s.messages, cid)
	}
}

// store_apply_dispatch applies one gateway dispatch. Returns false for events it ignores.
store_apply_dispatch :: proc(s: ^Store, name: string, data: V, now: i64) -> bool {
	d := vmap(data)
	switch name {
	case "READY":
		apply_ready(s, d)
	case "READY_SUPPLEMENTAL":
		apply_ready_supplemental(s, d)
	case "RESUMED":
		s.connection = .Ready
	case "MESSAGE_CREATE":
		upsert_message(s, d)
		remove_typing(s, fsnow(d, "channel_id"), fsnow(fmap(d, "author"), "id"))
	case "MESSAGE_UPDATE":
		cid := fsnow(d, "channel_id")
		if l, ok := &s.messages[cid]; ok {
			if i := message_index(l, fsnow(d, "id")); i >= 0 do parse_message_fields(s, &l.messages[i], d)
		}
	case "MESSAGE_DELETE":
		cid := fsnow(d, "channel_id")
		if l, ok := &s.messages[cid]; ok {
			if i := message_index(l, fsnow(d, "id")); i >= 0 {
				free_message(s, &l.messages[i])
				ordered_remove(&l.messages, i)
			}
		}
	case "MESSAGE_DELETE_BULK":
		cid := fsnow(d, "channel_id")
		if l, ok := &s.messages[cid]; ok {
			for idv in flist(d, "ids") {
				if i := message_index(l, vsnow(idv)); i >= 0 {
					free_message(s, &l.messages[i])
					ordered_remove(&l.messages, i)
				}
			}
		}
	case "MESSAGE_REACTION_ADD":
		apply_reaction(s, d, true)
	case "MESSAGE_REACTION_REMOVE":
		apply_reaction(s, d, false)
	case "MESSAGE_REACTION_REMOVE_ALL", "MESSAGE_REACTION_REMOVE_EMOJI":
		cid := fsnow(d, "channel_id")
		if l, ok := &s.messages[cid]; ok {
			if i := message_index(l, fsnow(d, "message_id")); i >= 0 {
				msg := &l.messages[i]
				em := fmap(d, "emoji")
				for k := len(msg.reactions) - 1; k >= 0; k -= 1 {
					if em == nil || emoji_matches(msg.reactions[k].emoji, fsnow(em, "id"), fstr(em, "name")) {
						free_str(msg.reactions[k].emoji.name, s.allocator)
						ordered_remove(&msg.reactions, k)
					}
				}
			}
		}
	case "MESSAGE_ACK":
		cid := fsnow(d, "channel_id")
		rs := s.read_states[cid]
		rs.channel_id = cid
		rs.last_message_id = fsnow(d, "message_id")
		rs.mention_count = int(fint(d, "mention_count"))
		s.read_states[cid] = rs
	case "TYPING_START":
		apply_typing(s, d, now)
	case "PRESENCE_UPDATE":
		apply_presence(s, d)
	case "SESSIONS_REPLACE":
		apply_sessions(s, vlist(data))
	case "GUILD_CREATE", "GUILD_UPDATE":
		parse_guild_into(s, d)
	case "GUILD_DELETE":
		gid := fsnow(d, "id")
		if fbool(d, "unavailable") {
			if g, ok := &s.guilds[gid]; ok do g.unavailable = true
		} else {
			remove_guild(s, gid)
		}
	case "GUILD_ROLE_CREATE", "GUILD_ROLE_UPDATE":
		gid := fsnow(d, "guild_id")
		if g, ok := &s.guilds[gid]; ok {
			r := parse_role(s, fmap(d, "role"))
			for &old, i in g.roles {
				if old.id == r.id {
					free_role(s, &old)
					g.roles[i] = r
					return true
				}
			}
			append(&g.roles, r)
		}
	case "GUILD_ROLE_DELETE":
		gid := fsnow(d, "guild_id")
		rid := fsnow(d, "role_id")
		if g, ok := &s.guilds[gid]; ok {
			for &r, i in g.roles {
				if r.id == rid {
					free_role(s, &r)
					ordered_remove(&g.roles, i)
					break
				}
			}
		}
	case "GUILD_EMOJIS_UPDATE":
		if g, ok := &s.guilds[fsnow(d, "guild_id")]; ok do parse_emojis(s, g, flist(d, "emojis"))
	case "GUILD_STICKERS_UPDATE":
		if g, ok := &s.guilds[fsnow(d, "guild_id")]; ok do parse_stickers(s, g, flist(d, "stickers"))
	case "GUILD_MEMBER_ADD", "GUILD_MEMBER_UPDATE":
		parse_member_into(s, fsnow(d, "guild_id"), d)
	case "GUILD_MEMBER_REMOVE":
		gid := fsnow(d, "guild_id")
		uid := fsnow(fmap(d, "user"), "id")
		if gm, ok := &s.members[gid]; ok {
			if m, mok := &gm[uid]; mok {
				free_member(s, m)
				delete_key(gm, uid)
			}
		}
	case "GUILD_MEMBERS_CHUNK":
		gid := fsnow(d, "guild_id")
		for mv in flist(d, "members") do parse_member_into(s, gid, vmap(mv))
		for pv in flist(d, "presences") do apply_presence(s, vmap(pv))
	case "GUILD_MEMBER_LIST_UPDATE":
		apply_member_list_update(s, d)
	case "CHANNEL_CREATE", "CHANNEL_UPDATE", "THREAD_CREATE", "THREAD_UPDATE":
		cid := parse_channel_into(s, d)
		c := s.channels[cid]
		if c.guild_id != 0 {
			if g, ok := &s.guilds[c.guild_id]; ok && !slice.contains(g.channels[:], cid) do append(&g.channels, cid)
		} else if !slice.contains(s.private_channels[:], cid) {
			append(&s.private_channels, cid)
		}
	case "CHANNEL_DELETE", "THREAD_DELETE":
		remove_channel(s, fsnow(d, "id"))
	case "CHANNEL_RECIPIENT_ADD":
		if c, ok := &s.channels[fsnow(d, "channel_id")]; ok {
			uid := parse_user_into(s, fmap(d, "user"))
			if uid != 0 && !slice.contains(c.recipient_ids[:], uid) do append(&c.recipient_ids, uid)
		}
	case "CHANNEL_RECIPIENT_REMOVE":
		if c, ok := &s.channels[fsnow(d, "channel_id")]; ok {
			uid := fsnow(fmap(d, "user"), "id")
			if i, found := slice.linear_search(c.recipient_ids[:], uid); found do ordered_remove(&c.recipient_ids, i)
		}
	case "RELATIONSHIP_ADD", "RELATIONSHIP_UPDATE":
		apply_relationship(s, d)
	case "RELATIONSHIP_REMOVE":
		uid := fsnow(d, "id")
		if r, ok := s.relationships[uid]; ok {
			free_str(r.nickname, s.allocator)
			free_str(r.since, s.allocator)
			delete_key(&s.relationships, uid)
		}
	case "USER_UPDATE":
		parse_user_into(s, d)
	case "USER_SETTINGS_PROTO_UPDATE":
		if sm := fmap(d, "settings"); sm != nil && fint(sm, "type") == 1 do apply_settings_proto(s, fstr(sm, "proto"))
	case "USER_GUILD_SETTINGS_UPDATE":
		apply_guild_settings(s, d)
	case "VOICE_STATE_UPDATE":
		apply_voice_state(s, d)
	case "VOICE_SERVER_UPDATE":
		vs := &s.voice_server
		free_str(vs.token, s.allocator)
		free_str(vs.endpoint, s.allocator)
		vs.guild_id = fsnow(d, "guild_id")
		vs.channel_id = fsnow(d, "channel_id")
		vs.token = clone_str(fstr(d, "token"), s.allocator)
		vs.endpoint = clone_str(fstr(d, "endpoint"), s.allocator)
	case:
		return false
	}
	return true
}

// ---- REST results ----

// store_apply_messages merges a GET /channels/{id}/messages page (newest first).
store_apply_messages :: proc(s: ^Store, channel_id: Snowflake, data: V, limit: int, before: bool) {
	l := message_list(s, channel_id)
	items := vlist(data)
	for mv in items do upsert_message(s, vmap(mv))
	l.loaded = true
	l.loading = false
	if before || !l.loaded do l.has_more_before = len(items) >= limit
	else do l.has_more_before = len(items) >= limit
}

// ---- read helpers for the UI ----

user_get :: proc(s: ^Store, id: Snowflake) -> ^User {
	u, ok := &s.users[id]
	return u if ok else nil
}

channel_get :: proc(s: ^Store, id: Snowflake) -> ^Channel {
	c, ok := &s.channels[id]
	return c if ok else nil
}

guild_get :: proc(s: ^Store, id: Snowflake) -> ^Guild {
	g, ok := &s.guilds[id]
	return g if ok else nil
}

member_get :: proc(s: ^Store, guild_id, user_id: Snowflake) -> ^Member {
	gm, ok := &s.members[guild_id]
	if !ok do return nil
	m, mok := &gm[user_id]
	return m if mok else nil
}

messages_get :: proc(s: ^Store, channel_id: Snowflake) -> []Message {
	l, ok := &s.messages[channel_id]
	return l.messages[:] if ok else nil
}

channel_unread :: proc(s: ^Store, channel_id: Snowflake) -> bool {
	c, ok := s.channels[channel_id]
	if !ok do return false
	rs := s.read_states[channel_id]
	return c.last_message_id > rs.last_message_id
}

// guild_channels_sorted returns channel ids in sidebar order: uncategorized
// first, then each category followed by its children, by (position, id).
guild_channels_sorted :: proc(s: ^Store, guild_id: Snowflake, allocator := context.temp_allocator) -> []Snowflake {
	g, ok := &s.guilds[guild_id]
	if !ok do return nil
	ids := slice.clone(g.channels[:], allocator)
	Ctx :: struct {
		s: ^Store,
	}
	key :: proc(s: ^Store, id: Snowflake) -> (parent_pos: int, parent_id: Snowflake, is_cat: bool, voiceish: bool, pos: int) {
		c := s.channels[id]
		voiceish = c.kind == .Guild_Voice || c.kind == .Guild_Stage_Voice
		if c.kind == .Guild_Category do return c.position, c.id, true, false, -1
		if c.parent_id == 0 do return -1, 0, false, voiceish, c.position
		p := s.channels[c.parent_id]
		return p.position, p.id, false, voiceish, c.position
	}
	store_ptr := s
	context.user_ptr = store_ptr
	slice.sort_by(ids, proc(a, b: Snowflake) -> bool {
		st := cast(^Store)context.user_ptr
		apos, apid, acat, avoice, ap := key(st, a)
		bpos, bpid, bcat, bvoice, bp := key(st, b)
		if apos != bpos do return apos < bpos
		if apid != bpid do return apid < bpid
		if acat != bcat do return acat
		if avoice != bvoice do return !avoice
		if ap != bp do return ap < bp
		return a < b
	})
	return ids
}

// private_channels_sorted: DMs by last activity, newest first.
private_channels_sorted :: proc(s: ^Store, allocator := context.temp_allocator) -> []Snowflake {
	ids := slice.clone(s.private_channels[:], allocator)
	context.user_ptr = s
	slice.sort_by(ids, proc(a, b: Snowflake) -> bool {
		st := cast(^Store)context.user_ptr
		la := max(st.channels[a].last_message_id, a)
		lb := max(st.channels[b].last_message_id, b)
		return la > lb
	})
	return ids
}

typing_users :: proc(s: ^Store, channel_id: Snowflake) -> []Typing {
	l, ok := &s.typing[channel_id]
	return l[:] if ok else nil
}

