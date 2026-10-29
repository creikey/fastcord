// Message components: a bot's buttons, select menus and links (action rows), and Components V2 layouts
// (containers, sections, text, thumbnails, galleries, files, separators). Untrusted: at most
// MAX_COMPONENTS entries, MAX_COMPONENT_DEPTH levels and capped strings; a select's options are entries
// of kind COMP_OPTION under it. Clicking one sends an interaction:
//   POST /interactions {"type":3, nonce, guild_id, channel_id, message_flags, message_id, application_id,
//                       session_id, "data":{"component_type":k, "custom_id":..., ("type":k, "values":[...])}}
// and the gateway answers INTERACTION_CREATE, then INTERACTION_SUCCESS or INTERACTION_FAILURE (same nonce).
// No capture yet (traffic/CLIENT_RULES.md "Message components").

COMP_ACTION_ROW :: 1;
COMP_BUTTON :: 2;
COMP_STRING_SELECT :: 3;
COMP_USER_SELECT :: 5;
COMP_ROLE_SELECT :: 6;
COMP_MENTIONABLE_SELECT :: 7;
COMP_CHANNEL_SELECT :: 8;
COMP_SECTION :: 9;
COMP_TEXT_DISPLAY :: 10;
COMP_THUMBNAIL :: 11;
COMP_MEDIA_GALLERY :: 12;
COMP_FILE :: 13;
COMP_SEPARATOR :: 14;
COMP_CONTAINER :: 17;
COMP_OPTION :: 255; // a select's option, or a gallery's item

BUTTON_LINK :: 5;
BUTTON_PREMIUM :: 6; // a purchase button: never shown (no promotions)
MESSAGE_EPHEMERAL :: 1 << 6;
MESSAGE_COMPONENTS_V2 :: 1 << 15;

MAX_COMPONENTS :: 160;
MAX_COMPONENT_DEPTH :: 4;
MAX_SELECT_OPTIONS :: 25;
MAX_COMPONENT_TEXT :: 4000;

Component :: struct {
	kind: u8;
	style: u8;
	parent: s16; // index of the parent entry, -1 at the top
	disabled: bool;
	spoiler: bool;
	divider: bool; // a separator's line
	spacing: u8;   // a separator's size (1 small, 2 large)
	accent: s64 = -1; // a container's colour, -1 for none
	label, emoji, custom_id, url, placeholder, text: string; // into Components.buf
}

Components :: struct {
	items: [..]Component;
	buf: string; // every string of items, one store-owned block
	app_id: Snowflake; // whose interactions these send
}

// parse_components fills msg.components from a message's `components` (an empty list clears them).
parse_components :: (s: *Store, msg: *Message, list: []V, app_id: Snowflake) {
	free_components(s, msg.components);
	msg.components = null;
	if !list.count return;
	items: [..]Component;
	items.allocator = temp;
	add_level :: (items: *[..]Component, list: []V, parent: s16, depth: int) {
		if depth > MAX_COMPONENT_DEPTH return;
		for list {
			if items.count >= MAX_COMPONENTS return;
			m := vmap(it);
			if !m continue;
			cut :: (t: string) -> string { return slice(t, 0, min(t.count, MAX_COMPONENT_TEXT)); }
			c: Component;
			c.kind = cast(u8) clamp(fint(m, "type"), 0, 254);
			c.style = cast(u8) clamp(fint(m, "style"), 0, 255);
			c.parent = parent;
			c.disabled = fbool(m, "disabled");
			c.spoiler = fbool(m, "spoiler");
			c.divider = !vhas(m, "divider") || fbool(m, "divider");
			c.spacing = cast(u8) clamp(fint(m, "spacing"), 0, 2);
			if vhas(m, "accent_color") && !vis_null(vget(m, "accent_color")) c.accent = fint(m, "accent_color") & 0xffffff;
			c.label = cut(fstr(m, "label"));
			c.custom_id = cut(fstr(m, "custom_id"));
			c.url = cut(fstr(m, "url"));
			c.placeholder = cut(fstr(m, "placeholder"));
			c.text = cut(fstr(m, "content"));
			e := fmap(m, "emoji");
			if e && !fsnow(e, "id") c.emoji = cut(fstr(e, "name"));
			media := fmap(m, "media");
			if !media media = fmap(m, "file");
			if media c.url = cut(ifx fstr(media, "proxy_url") then fstr(media, "proxy_url") else fstr(media, "url"));
			if c.kind == COMP_BUTTON && c.style == BUTTON_PREMIUM continue;
			me := cast(s16) items.count;
			array_add(items, c);
			add_level(items, flist(m, "components"), me, depth + 1);
			acc := fmap(m, "accessory");
			if acc {
				one := NewArray(1, V,, temp);
				one[0] = vget(m, "accessory");
				add_level(items, one, me, depth + 1);
			}
			// a select's options and a gallery's items, as entries under it
			for o, i: flist(m, "options") {
				if i >= MAX_SELECT_OPTIONS || items.count >= MAX_COMPONENTS break;
				om := vmap(o);
				oe := fmap(om, "emoji");
				array_add(items, .{kind = COMP_OPTION, parent = me, label = cut(fstr(om, "label")), custom_id = cut(fstr(om, "value")), text = cut(fstr(om, "description")), emoji = ifx oe && !fsnow(oe, "id") then cut(fstr(oe, "name")) else ""});
			}
			for g, i: flist(m, "items") {
				if i >= 10 || items.count >= MAX_COMPONENTS break;
				gm := vmap(g);
				gmedia := fmap(gm, "media");
				array_add(items, .{kind = COMP_OPTION, parent = me, spoiler = fbool(gm, "spoiler"), text = cut(fstr(gm, "description")), url = cut(ifx fstr(gmedia, "proxy_url") then fstr(gmedia, "proxy_url") else fstr(gmedia, "url"))});
			}
		}
	}
	add_level(*items, list, -1, 1);
	if !items.count return;
	total := 0;
	for items total += it.label.count + it.emoji.count + it.custom_id.count + it.url.count + it.placeholder.count + it.text.count;
	cs := New(Components,, s.allocator);
	cs.items.allocator = s.allocator;
	cs.app_id = app_id;
	cs.buf = alloc_string(total,, s.allocator);
	at := 0;
	put :: (cs: *Components, at: *int, t: *string) {
		memcpy(cs.buf.data + at.*, t.data, t.count);
		t.* = string.{t.count, cs.buf.data + at.*};
		at.* += t.count;
	}
	for * items {
		put(cs, *at, *it.label); put(cs, *at, *it.emoji); put(cs, *at, *it.custom_id);
		put(cs, *at, *it.url); put(cs, *at, *it.placeholder); put(cs, *at, *it.text);
	}
	array_copy(*cs.items, items);
	msg.components = cs;
}

free_components :: (s: *Store, cs: *Components) {
	if !cs return;
	array_free(cs.items);
	free(cs.buf,, s.allocator);
	free(cs,, s.allocator);
}

// An interaction we sent for a message, until the gateway says how it went.
Interaction_State :: struct {
	nonce: Snowflake;
	index: int; // the component clicked
	failed: bool;
	start_ms: s64;
}

// apply_interaction_result: INTERACTION_SUCCESS (done) or INTERACTION_FAILURE ("This interaction failed").
apply_interaction_result :: (s: *Store, d: etf.Map, ok: bool) {
	nonce := fsnow(d, "nonce");
	for * st, mid: s.interactions if st.nonce == nonce {
		if ok table_remove(*s.interactions, mid);
		else st.failed = true;
		s.changed += 1;
		return;
	}
}

// send_component_interaction: a click on msg's component `index` (values: a select's picks).
send_component_interaction :: (c: *Client, msg: *Message, guild_id: Snowflake, index: int, values: []string = .[]) {
	cs := msg.components;
	if !cs || index < 0 || index >= cs.items.count return;
	it := cs.items[index];
	nonce := nonce_next(*c.id.nonces);
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kint(*w, "type", 3);
	json_ksnow(*w, "nonce", nonce);
	if guild_id json_ksnow(*w, "guild_id", guild_id);
	json_ksnow(*w, "channel_id", msg.channel_id);
	json_kint(*w, "message_flags", cast(s64) msg.flags);
	json_ksnow(*w, "message_id", msg.id);
	json_ksnow(*w, "application_id", cs.app_id);
	json_kstr(*w, "session_id", c.store.session_id);
	json_key(*w, "data");
	json_obj(*w);
	json_kint(*w, "component_type", it.kind);
	json_kstr(*w, "custom_id", it.custom_id);
	if it.kind != COMP_BUTTON {
		json_kint(*w, "type", it.kind);
		json_key(*w, "values");
		json_arr(*w);
		for values json_str(*w, it);
		json_arr_end(*w);
	}
	json_obj_end(*w);
	json_obj_end(*w);
	table_set(*c.store.interactions, msg.id, .{nonce = nonce, index = index, start_ms = now_ms()});
	c.store.changed += 1;
	f_submit(c, .{op = .Guild_Aux, channel_id = msg.channel_id, method = "POST", path = "/interactions", body = json_string(*w)});
}
