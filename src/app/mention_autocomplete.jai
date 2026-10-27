// Mention autocomplete above the composer, like the client's MENTIONS autocomplete: "@" at
// the start of a word lists the channel's members (recent authors first, then by name; the
// query matches the start of the nickname, display name or username), then @everyone /
// @here (with Mention Everyone) and the mentionable roles. Up/Down move, Tab/Enter/click
// insert "@username " or "@Role ", Escape hides it until the query changes. On send,
// mentions_convert turns those back into <@id> / <@&id>. See traffic/CLIENT_RULES.md
// "Composer mentions".

MAC_MAX :: 10; // rows, shared by members, @everyone / @here and roles
MAC_SEARCH_MS :: 200; // op 8 debounce (trailing)
MAC_SEARCH_TTL_MS :: 60_000; // the same guild + query is asked again after this
MAC_ROW_H :: 40;
MAC_HEADER_H :: 32;
MAC_SEP_H :: 17;
MAC_PAD :: 8;
MAC_GAP :: 8;

Mention_Kind :: enum u8 { User; Everyone; Here; Role; }

Mention_Item :: struct {
	kind: Mention_Kind;
	id: dc.Snowflake;
	name: string; // left column (temp)
	right: string; // right column: username or description (temp)
	insert: string; // composer text, without the trailing space (temp)
	color: ui.Color; // role colour (w = 0: default)
}

Mention_Autocomplete :: struct {
	channel: dc.Snowflake;
	query: string; // owned
	dismissed: string; // owned: the query Escape hid (when hidden)
	hidden: bool;
	sel: int;
	visible: bool;
	last_mouse: ui.Vec2;
	searched: Table(string, s64); // "guild:query" -> when op 8 was sent (owned keys)
	search_at: float64; // platform.time_now() when the current query was last typed
}

mac: Mention_Autocomplete;

// The "@query" word ending at the caret: byte of its '@' and the query.
mention_ac_query :: (text: string, caret: int) -> at: int, q: string, ok: bool {
	if caret <= 0 || caret > text.count return 0, "", false;
	i := caret;
	while i > 0 {
		c := text[i - 1];
		if c == #char "@" || is_space(c) break;
		i -= 1;
	}
	if i == 0 || text[i - 1] != #char "@" return 0, "", false;
	at := i - 1;
	if at > 0 && !is_space(text[at - 1]) return 0, "", false;
	return at, string.{caret - i, text.data + i}, true;
}

// mention_items: what "@q" offers in ch (temp), at most MAC_MAX rows.
mention_items :: (ch: *dc.Channel, q: string) -> []Mention_Item {
	s := store();
	lq := to_lower_copy(q,, temp);
	starts :: (name: string, lq: string) -> bool { return name != "" && begins_with(to_lower_copy(name,, temp), lq); }
	out: [..]Mention_Item;
	out.allocator = temp;
	// a member who can see ch (anyone in a DM) whose username, display name or nick starts with q
	ok :: (uid: dc.Snowflake) -> bool #expand {
		u := dc.user_get(s, uid);
		if !u return false;
		mem: *dc.Member;
		if ch.guild_id {
			mem = dc.member_get(s, ch.guild_id, uid);
			if !mem || !dc.has_permission(dc.channel_permissions_of(s, ch.id, uid, mem.roles), dc.PERM_VIEW_CHANNEL) return false;
		}
		return lq == "" || starts(u.username, lq) || starts(u.global_name, lq) || (mem && starts(mem.nick, lq));
	}
	users: [..]dc.Snowflake;
	users.allocator = temp;
	// no query: the channel's recent authors, newest first, if there are any
	if lq == "" for < dc.messages_get(s, ch.id) {
		if users.count == MAC_MAX break;
		if !array_find(users, it.author_id) && ok(it.author_id) array_add(*users, it.author_id);
	}
	if !users {
		cands: [..]dc.Snowflake;
		cands.allocator = temp;
		if ch.guild_id {
			ms := table_find_pointer(*s.members, ch.guild_id);
			if ms for _, uid: ms.* if ok(uid) array_add(*cands, uid);
		} else {
			for ch.recipient_ids if ok(it) array_add(*cands, it);
			if ok(s.me) array_add(*cands, s.me);
		}
		Keyed :: struct { key: string; uid: dc.Snowflake; }
		sorted := NewArray(cands.count, Keyed,, temp);
		for cands sorted[it_index] = .{to_lower_copy(name_in(it, ch.id),, temp), it};
		quick_sort(sorted, (a: Keyed, b: Keyed) -> s64 { return compare(a.key, b.key); });
		for sorted {
			if it_index == MAC_MAX break;
			array_add(*users, it.uid);
		}
	}
	for users {
		u := dc.user_get(s, it);
		array_add(*out, .{kind = .User, id = it, name = name_in(it, ch.id), right = u.username, insert = tprint("@%", u.username)});
	}
	if !ch.guild_id return out;
	everyone := dc.has_permission(dc.channel_permissions(s, ch.id), dc.PERM_MENTION_EVERYONE);
	if everyone {
		if out.count < MAC_MAX && starts("everyone", lq) array_add(*out, .{kind = .Everyone, name = "@everyone", right = "Notify everyone who has permission to view this channel.", insert = "@everyone"});
		if out.count < MAC_MAX && starts("here", lq) array_add(*out, .{kind = .Here, name = "@here", right = "Notify everyone online who has permission to view this channel.", insert = "@here"});
	}
	g := dc.guild_get(s, ch.guild_id);
	if g for r: g.roles {
		if out.count == MAC_MAX break;
		if r.id == g.id || !(r.mentionable || everyone) || !starts(r.name, lq) continue;
		array_add(*out, .{kind = .Role, id = r.id, name = tprint("@%", r.name), right = "Notify users with this role who have permission to view this channel.", insert = tprint("@%", r.name), color = ifx r.color then rgb_u32(r.color)});
	}
	return out;
}

// The popup for the composer of ch (inside its bordered stack, before the text field so its
// keys win). focused: the composer has keyboard focus.
mention_autocomplete :: (ch: *dc.Channel, ed: *ui.Editor, focused: bool) {
	shown := false;
	defer if !shown mac.visible = false;
	if !focused || ui.editor_has_sel(ed) return;
	at, q, ok := mention_ac_query(ui.editor_text(ed), ed.caret);
	if !ok return;
	if mac.channel != ch.id || mac.query != q {
		free(mac.query);
		mac.query = copy_string(q);
		mac.channel = ch.id;
		mac.sel = 0;
		mac.search_at = platform.time_now();
	}
	member_search(ch, q);
	if mac.hidden && mac.dismissed == q return;
	mac.hidden = false;
	items := mention_items(ch, q);
	if !items return;
	shown = true;
	if !mac.visible && app.client != null dc.autocomplete_mentions_open(app.client, ch.id);
	mac.visible = true;
	mac.sel = clamp(mac.sel, 0, items.count - 1);
	pick := -1;
	for * e: app.ui.events {
		if e.consumed || e.kind != .Key_Down || e.mods != 0 continue;
		if e.key == {
		case .Up;     mac.sel = (mac.sel + items.count - 1) % items.count;
		case .Down;   mac.sel = (mac.sel + 1) % items.count;
		case .Tab;    pick = mac.sel;
		case .Enter;  pick = mac.sel;
		case .Escape;
			free(mac.dismissed);
			mac.dismissed = copy_string(q);
			mac.hidden = true;
		case; continue;
		}
		e.consumed = true;
	}

	users := 0;
	for items if it.kind == .User users += 1;
	header := ifx q == "" then "Members" else tprint("Members matching @%", q);
	sep := users > 0 && users < items.count;
	h := cast(float32) (MAC_PAD + MAC_ROW_H * items.count + MAC_PAD + (ifx users > 0 then MAC_HEADER_H else 0) + (ifx sep then MAC_SEP_H else 0));
	pop := ui.box("mention_ac", .Floating_X | .Floating_Y | .Overlay | .Draw_Background | .Draw_Border | .Draw_Shadow | .Clickable);
	pop.semantic_size = .[ui.pct(1), ui.px(h)];
	pop.fixed_pos = .{0, -h - MAC_GAP};
	pop.layout_axis = .Y;
	pop.style.bg = T("--background-surface-higher");
	pop.style.border_color = T("--border-subtle");
	pop.style.border = 1;
	pop.style.radius = all4(8);
	pop.style.shadow_color = .{0, 0, 0, 0.24};
	pop.style.shadow_blur = 8;
	ui.signal(pop);
	moved := app.ui.mouse != mac.last_mouse;
	mac.last_mouse = app.ui.mouse;
	{ ui.parent(pop); defer ui.pop_parent();
		spacer(.Y, MAC_PAD);
		if users > 0 {
			head := row("head");
			head.semantic_size = .[ui.pct(1), ui.px(MAC_HEADER_H)];
			{ ui.parent(head); defer ui.pop_parent();
				spacer(.X, 16);
				label(header, .Medium, 14, T("--text-muted"), 18);
			}
		}
		for item, i: items {
			if sep && i == users {
				sr := row("sep");
				sr.semantic_size = .[ui.pct(1), ui.px(MAC_SEP_H)];
				{ ui.parent(sr); defer ui.pop_parent();
					spacer(.X, 16);
					l := ui.box("l", .Draw_Background);
					l.semantic_size = .[ui.fill(), ui.px(1)];
					l.style.bg = T("--border-subtle");
					spacer(.X, 16);
				}
			}
			r := row(tprint("r%", i), .Clickable);
			r.semantic_size = .[ui.pct(1), ui.px(MAC_ROW_H)];
			sig := ui.signal(r);
			if sig.hovering && moved mac.sel = i;
			if sig.clicked pick = i;
			{ ui.parent(r); defer ui.pop_parent();
				spacer(.X, MAC_PAD);
				bg := row("bg", .Draw_Background);
				bg.semantic_size = .[ui.fill(), ui.px(MAC_ROW_H)];
				bg.style.radius = all4(4);
				if i == mac.sel bg.style.bg = T("--background-mod-normal");
				{ ui.parent(bg); defer ui.pop_parent();
					spacer(.X, 8);
					if item.kind == .User {
						avatar_with_status("av", item.id, 24, ifx i == mac.sel then T("--background-mod-normal") else T("--background-surface-higher"));
						spacer(.X, 12);
					}
					// the name keeps its width up to half the row; the right column gets the rest
					row_w := r.rect.x1 - r.rect.x0;
					name := ellipsize(item.name, .Medium, 16, row_w / 2);
					color := ifx item.color.w > 0 then item.color else T(ifx i == mac.sel then "--interactive-text-active" else "--interactive-text-default");
					label(name, .Medium, 16, color, 20);
					filler(.X);
					spacer(.X, 16);
					left := ui.layout_text(F(.Medium), 16, name, -1).width + ifx item.kind == .User then 36.0 else 0.0;
					label(ellipsize(item.right, .Normal, 14, max(row_w - left - 64, 40)), .Normal, 14, T("--text-muted"), 18);
					spacer(.X, 8);
				}
				spacer(.X, MAC_PAD);
			}
		}
	}
	if pick < 0 return;
	ed.mark = at;
	ui.editor_insert(ed, tprint("% ", items[pick].insert), .Other);
	if app.client != null dc.autocomplete_mention_selected(app.client, ch.id);
	mac.visible = false;
}

// mentions_convert: the sent text with "@username" (a member of ch, or a recipient) as
// <@id> and "@Role Name" (a role of ch's guild) as <@&id>, outside code (temp).
mentions_convert :: (text: string, ch: *dc.Channel) -> string {
	if find_index_from_left(text, #char "@") < 0 return text;
	s := store();
	g := ifx ch.guild_id then dc.guild_get(s, ch.guild_id);
	b: String_Builder;
	b.allocator = temp;
	i := 0;
	fence := false; // inside ``` ... ```
	tick := false; // inside ` ... `
	while i < text.count {
		rest := advance(text, i);
		if begins_with(rest, "```") {
			fence = !fence;
			append(*b, "```");
			i += 3;
			continue;
		}
		c := text[i];
		if c == #char "`" && !fence tick = !tick;
		if c != #char "@" || fence || tick || (i > 0 && !is_space(text[i - 1])) {
			append(*b, c);
			i += 1;
			continue;
		}
		word := advance(rest, 1);
		n := 0;
		while n < word.count && (is_alnum(word[n]) || word[n] == #char "_" || word[n] == #char ".") n += 1;
		while n > 0 && word[n - 1] == #char "." n -= 1; // "@robin." ends a sentence
		uid := ifx n > 0 then mention_user_by_name(ch, slice(word, 0, n));
		if uid {
			print_to_builder(*b, "<@%>", uid);
			i += 1 + n;
			continue;
		}
		// the longest role name that follows
		best: *dc.Role;
		if g for * r: g.roles if r.id != g.id && r.name != "" && begins_with(word, r.name) && (!best || r.name.count > best.name.count) {
			after := 1 + r.name.count;
			if after >= rest.count || !is_alnum(rest[after]) best = r;
		}
		if best {
			print_to_builder(*b, "<@&%>", best.id);
			i += 1 + best.name.count;
			continue;
		}
		append(*b, c);
		i += 1;
	}
	return builder_to_string(*b,, temp);
}

#scope_file

// Members not loaded yet: ask the gateway for the query's matches once it has been still for
// MAC_SEARCH_MS (at most once a minute per guild and query); the chunk lands in the store.
member_search :: (ch: *dc.Channel, q: string) {
	if app.client == null || !ch.guild_id || q == "" return;
	if platform.time_now() - mac.search_at < MAC_SEARCH_MS / 1000.0 {
		request_wake(mac.search_at + MAC_SEARCH_MS / 1000.0);
		return;
	}
	now := dc.now_ms();
	key := tprint("%:%", ch.guild_id, to_lower_copy(q,, temp));
	found, at := table_find(*mac.searched, key);
	if found && now - at < MAC_SEARCH_TTL_MS return;
	if !found key = copy_string(key);
	table_set(*mac.searched, key, now);
	dc.search_guild_members(app.client, ch.guild_id, q);
}

// A member of ch's guild (or a recipient of the DM) with this exact username.
mention_user_by_name :: (ch: *dc.Channel, name: string) -> dc.Snowflake {
	s := store();
	is :: (uid: dc.Snowflake) -> bool #expand {
		u := dc.user_get(s, uid);
		return u && u.username == name;
	}
	if !ch.guild_id {
		for ch.recipient_ids if is(it) return it;
		if is(s.me) return s.me;
		return 0;
	}
	ms := table_find_pointer(*s.members, ch.guild_id);
	if ms for _, uid: ms.* if is(uid) return uid;
	return 0;
}
