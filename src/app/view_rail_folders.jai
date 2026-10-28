// Server rail like the official client: home + unread DM avatars, guilds and
// guild folders (settings.guild_folders), mention badges, unread pills,
// drag-to-reorder persisted through dc.set_guild_folders (settings-proto 1).

RAIL_SLOT :: GUILD_ICON + 8; // 48px pitch
RAIL_ICON_X :: 16;
FOLDER_MINI :: 16; // 2x2 mini guild icons in a closed folder
FOLDER_MINI_PAD :: 3;
FOLDER_MINI_GAP :: 2;
FOLDER_RADIUS :: 12;
FOLDER_BG_W :: 48; // expanded folder background
FOLDER_BG_RADIUS :: 16;
FOLDER_DEFAULT_COLOR :: 0x5865F2; // folders without a color use brand blurple
FOLDER_EXPAND_RATE :: 18;
BADGE_H :: 16;
BADGE_RING :: 4; // rail background ring around a badge
BADGE_FONT :: 12;
DRAG_THRESHOLD :: 4;

Rail_Entry :: struct {
	id: s64; // folder id (0 = a single guild)
	name: string;
	color: u64;
	has_color: bool;
	guilds: [..]dc.Snowflake;
}

// The rail's entries in sidebar order: guilds missing from the folders first
// (newest join first, like guild_order), then settings.guild_folders.
rail_entries :: () -> [..]Rail_Entry {
	s := store();
	out: [..]Rail_Entry;
	out.allocator = temp;
	listed: Table(dc.Snowflake, bool);
	listed.allocator = temp;
	for f: s.settings.guild_folders { for f.guild_ids table_set(*listed, it, true); }
	for gid: guild_order() {
		if table_contains(*listed, gid) { break; }
		array_add(*out, .{guilds = temp_list(gid)});
	}
	for f: s.settings.guild_folders {
		e := Rail_Entry.{id = f.id, name = f.name, color = f.color, has_color = f.has_color};
		e.guilds.allocator = temp;
		for f.guild_ids { if table_contains(*s.guilds, it) { array_add(*e.guilds, it); } }
		if e.guilds.count == 0 { continue; }
		array_add(*out, e);
	}
	return out;
}

// ---- unread / mentions ----

// Mentions in a channel: the read state's count (as of READY / the last ack),
// or the loaded unread messages that mention us if that's more — the store
// doesn't bump mention_count as messages arrive. Every DM message counts.
channel_mentions :: (cid: dc.Snowflake) -> int {
	s := store();
	ch := dc.channel_get(s, cid);
	if ch == null { return 0; }
	return channel_mentions_of(s, ch, table_find_pointer(*s.read_states, cid));
}

// channel_mentions for a channel already looked up; r may be null (never read).
channel_mentions_of :: (s: *dc.Store, ch: *dc.Channel, r: *dc.Read_State) -> int {
	last_read := ifx r != null then r.last_message_id else 0;
	if ch.last_message_id <= last_read { return 0; }
	dm := ch.kind == .DM || ch.kind == .Group_DM;
	n := 0;
	for * m: dc.messages_get(s, ch.id) {
		if m.id <= last_read || m.author_id == s.me || m.pending { continue; }
		if dm || m.mention_everyone || array_find(m.mentions, s.me) { n += 1; }
	}
	return max(n, ifx r != null then r.mention_count else 0);
}

guild_mentions :: (gid: dc.Snowflake) -> int {
	g := dc.guild_get(store(), gid);
	if g == null { return 0; }
	n := 0;
	for g.channels { n += channel_mentions(it); }
	return n;
}

// DMs with unread messages, newest first (shown under the home button).
unread_dms :: () -> []dc.Snowflake {
	s := store();
	out: [..]dc.Snowflake;
	out.allocator = temp;
	for cid: s.private_channels {
		ch := dc.channel_get(s, cid);
		if ch == null { continue; }
		if channel_mentions_of(s, ch, table_find_pointer(*s.read_states, cid)) > 0 { array_add(*out, cid); }
	}
	quick_sort(out, (a: dc.Snowflake, b: dc.Snowflake) -> int {
		ca, cb := dc.channel_get(store(), a), dc.channel_get(store(), b);
		la := ifx ca != null then ca.last_message_id else 0;
		lb := ifx cb != null then cb.last_message_id else 0;
		return ifx la > lb then -1 else ifx la < lb then 1 else 0;
	});
	return out;
}

// Red count pill at the icon's bottom-right, ringed in the rail background.
// Call with the 72-wide slot as parent; icon_y is the icon's top in the slot.
mention_badge :: (n: int, icon_y: float32) {
	if n <= 0 || notify_prefs.lotus { return; }
	text := ifx n > 99 then "99+" else tprint("%", n);
	w := max(cast(float32)(BADGE_H), cast(float32)(text.count) * 7 + 8);
	ring := ui.box("badgering", .Draw_Background | .Floating_X | .Floating_Y);
	ring.semantic_size = .[ui.px(w + 2 * BADGE_RING), ui.px(BADGE_H + 2 * BADGE_RING)];
	ring.fixed_pos = .{RAIL_ICON_X + GUILD_ICON + 4 - w - BADGE_RING, icon_y + GUILD_ICON + 4 - BADGE_H - BADGE_RING};
	ring.style.bg = T("--background-base-lowest");
	ring.style.radius = all4((BADGE_H + 2 * BADGE_RING) / 2);
	{ ui.parent(ring); defer ui.pop_parent();
		b := ui.box(tprint("%##badge", text), .Draw_Background | .Draw_Text | .Floating_X | .Floating_Y);
		b.semantic_size = .[ui.px(w), ui.px(BADGE_H)];
		b.fixed_pos = .{BADGE_RING, BADGE_RING};
		b.style.bg = T("--status-danger");
		b.style.radius = all4(BADGE_H / 2);
		b.style.font = F(.Bold);
		b.style.font_size = BADGE_FONT;
		b.style.text_color = .{1, 1, 1, 1};
		b.style.text_align = .Center;
	}
}

// ---- the rail ----

rail_view :: () {
	array_copy(*rs.prev, rs.targets);
	array_reset_keeping_memory(*rs.targets);
	rail := ui.box("rail", .Scroll_Y | .Clip);
	rail.semantic_size = .[ui.px(RAIL_W), ui.pct(1)];
	rail.layout_axis = .Y;
	rail.scrollbar = .None; // the official guild list scrolls without a visible bar
	ui.signal(rail);
	entries := rail_entries();
	{ ui.parent(rail); defer ui.pop_parent();
		home := rail_item("home", app.view.guild == 0, "", "logo", 0);
		if home.clicked { go_home(); }
		{ ui.parent(rail.last); defer ui.pop_parent(); mention_badge(pending_count(), 0); }
		if !notify_prefs.lotus for cid: unread_dms() {
			ui.id_scope(cast(u64)(cid)); defer ui.pop_seed();
			rail_dm(cid);
		}
		sep := ui.box("sep");
		sep.semantic_size = .[ui.pct(1), ui.px(9)];
		{ ui.parent(sep); defer ui.pop_parent();
			line := ui.box("line", .Draw_Background | .Floating_X | .Floating_Y);
			line.semantic_size = .[ui.px(32), ui.px(1)];
			line.fixed_pos = .{20, 0};
			line.style.bg = T("--background-mod-subtle");
			line.style.radius = all4(1);
		}
		for * e, i: entries {
			ui.id_scope(ifx e.id != 0 then cast(u64)(e.id) else cast(u64)(e.guilds[0])); defer ui.pop_seed();
			if e.id != 0 { rail_folder(e, i); } else { rail_guild(e.guilds[0], i, -1); }
		}
		if rail_item("add", add_server_is_open(), "", "circle-plus", 0).clicked { add_server_open(); } // view_add_server.jai
		if rail_item("discover", false, "", "compass", 0).clicked { discover_open(); }
		spacer(.Y, USER_PANEL_H + 16);
	}
	rail_drag(entries);
}

rail_reset_for_test :: () {rs = .{};}
rail_state_for_test :: () -> string {
	sb: String_Builder;
	sb.allocator = temp;
	for open, id: rs.open { if open { print_to_builder(*sb, "% ", id); } }
	print_to_builder(*sb, "%", rs.drag_active);
	return builder_to_string(*sb,, temp);
}

#scope_file

Drop_Kind :: enum u8 {
	None;
	Before; // insert before entry/guild
	After;
	Combine; // onto a guild (new folder) or into a closed folder
}

Rail_Target :: struct {
	rect: ui.Rect;
	entry: int;
	inner: int; // guild index inside an expanded folder, -1 = the entry itself
}

Rail_State :: struct {
	open: Table(s64, bool);
	open_t: Table(s64, float32);
	drag_entry: int; // entry being pressed / dragged
	drag_inner: int; // guild index inside a folder (-1 = whole entry)
	drag_active: bool;
	drag_from: ui.Vec2;
	drag_down: bool;
	targets: [..]Rail_Target;
	prev: [..]Rail_Target; // last frame's slot rects (drop hit testing)
}

rs: Rail_State;

rail_dm :: (cid: dc.Snowflake) {
	s := store();
	ch := dc.channel_get(s, cid);
	if ch == null { return; }
	slot := ui.box("dmslot");
	slot.semantic_size = .[ui.pct(1), ui.px(RAIL_SLOT)];
	if ui.offscreen(slot) { return; }
	{ ui.parent(slot); defer ui.pop_parent();
		ic := ui.box("dmicon", .Clickable | .Draw_Background | .Floating_X | .Floating_Y);
		ic.semantic_size = .[ui.px(GUILD_ICON), ui.px(GUILD_ICON)];
		ic.fixed_pos = .{RAIL_ICON_X, 0};
		sig := ui.signal(ic);
		ui.animate(*ic.user_t, ifx sig.hovering then 1.0 else 0.0, 25);
		ic.style.radius = all4(GUILD_ICON / 2 - (GUILD_ICON / 2 - 12) * ic.user_t);
		ic.style.bg = ifx ch.kind == .Group_DM then group_icon_color(ch.id) else T("--background-brand");
		if ch.kind == .DM && ch.recipient_ids.count > 0 {
			set_remote_image(ic, avatar_url_for(ch.recipient_ids[0], GUILD_ICON));
		} else { ui.parent(ic); defer ui.pop_parent();
			g := ui.box("g", .Floating_X | .Floating_Y);
			g.semantic_size = .[ui.px(24), ui.px(24)];
			g.fixed_pos = .{8, 8};
			set_icon(g, "group", .{1, 1, 1, 1});
		}
		pill := ui.box("pill", .Draw_Background | .Floating_X | .Floating_Y);
		ui.animate(*pill.user_t, ifx sig.hovering then 20.0 else 8.0, 25);
		pill.semantic_size = .[ui.px(4), ui.px(pill.user_t)];
		pill.fixed_pos = .{0, (GUILD_ICON - pill.user_t) / 2};
		pill.style.bg = T("--text-strong");
		pill.style.radius = .[0, 4, 0, 4];
		mention_badge(channel_mentions(cid), 0);
		if sig.hovering { tooltip_right(dm_name(ch)); }
		if sig.clicked { select_channel(0, cid); }
	}
}

// One guild slot (top level or inside an expanded folder) with badge + drag source.
rail_guild :: (gid: dc.Snowflake, entry: int, inner: int) {
	g := dc.guild_get(store(), gid);
	if g == null { return; }
	ui.id_scope(cast(u64)(gid)); defer ui.pop_seed();
	sig := rail_item("guild", app.view.guild == gid, guild_initials(g.name), "", gid);
	slot := ui.top_parent().last;
	if sig.box == null { return; } // offscreen
	{ ui.parent(slot); defer ui.pop_parent(); mention_badge(guild_mentions(gid), 0); }
	if sig.clicked && !rs.drag_active { select_guild(gid); }
	if sig.right_clicked && !rs.drag_active { guild_context_open(gid, app.ui.mouse); }
	drag_source(sig, entry, inner);
	if rs.drag_active && rs.drag_entry == entry && rs.drag_inner == inner { pk_fade(slot, 0); }
	array_add(*rs.targets, .{slot.rect, entry, inner});
}

folder_color :: (e: *Rail_Entry) -> ui.Color {
	return rgb_u32(cast(u32)(ifx e.has_color then e.color else FOLDER_DEFAULT_COLOR));
}

rail_folder :: (e: *Rail_Entry, entry: int) {
	_, open := table_find(*rs.open, e.id);
	tp := find_or_add(*rs.open_t, e.id);
	ui.animate(tp, ifx open then 1.0 else 0.0, FOLDER_EXPAND_RATE);
	t := tp.*;
	group := ui.box("folder");
	group.semantic_size = .[ui.pct(1), ui.children()];
	group.layout_axis = .Y;
	if ui.offscreen(group) {
		group.semantic_size[ui.Axis.Y] = ui.px(group.rect.y1 - group.rect.y0);
		return;
	}
	selected_inside := false;
	unread := false;
	mentions := 0;
	for gid: e.guilds {
		if gid == app.view.guild { selected_inside = true; }
		if guild_unread_shown(gid) { unread = true; }
		mentions += guild_mentions(gid);
	}
	color := folder_color(e);
	{ ui.parent(group); defer ui.pop_parent();
		// expanded background behind header + guilds
		if t > 0.01 {
			bg := ui.box("folderbg", .Draw_Background | .Floating_X | .Floating_Y);
			bg.semantic_size = .[ui.px(FOLDER_BG_W), ui.px(RAIL_SLOT - 8 + cast(float32)(e.guilds.count) * RAIL_SLOT * t)];
			bg.fixed_pos = .{(RAIL_W - FOLDER_BG_W) / 2, -4};
			bg.style.radius = all4(FOLDER_BG_RADIUS);
			bg.style.bg = with_alpha(T("--background-mod-subtle"), t);
		}
		slot := ui.box("fslot");
		slot.semantic_size = .[ui.pct(1), ui.px(RAIL_SLOT)];
		sig: ui.Signal;
		{ ui.parent(slot); defer ui.pop_parent();
			pill := ui.box("pill", .Draw_Background | .Floating_X | .Floating_Y);
			ic := ui.box("ficon", .Clickable | .Click_On_Release | .Draw_Background | .Floating_X | .Floating_Y | .Hot_Animation);
			ic.semantic_size = .[ui.px(GUILD_ICON), ui.px(GUILD_ICON)];
			ic.fixed_pos = .{RAIL_ICON_X, 0};
			ic.style.radius = all4(FOLDER_RADIUS);
			sig = ui.signal(ic);
			// closed: color-tinted squircle with 2x2 minis; open: the folder glyph
			ic.style.bg = with_alpha(color, 0.4 * (1 - t));
			ic.style.bg_hot = with_alpha(color, 0.55 * (1 - t));
			{ ui.parent(ic); defer ui.pop_parent();
				if t < 0.99 {
					for gid, i: e.guilds {
						if i >= 4 { break; }
						g := dc.guild_get(store(), gid);
						if g == null { continue; }
						m := ui.box(tprint("##mini%", i), .Draw_Background | .Draw_Text | .Floating_X | .Floating_Y);
						m.semantic_size = .[ui.px(FOLDER_MINI), ui.px(FOLDER_MINI)];
						m.fixed_pos = .{FOLDER_MINI_PAD + cast(float32)(i % 2) * (FOLDER_MINI + FOLDER_MINI_GAP), FOLDER_MINI_PAD + cast(float32)(i / 2) * (FOLDER_MINI + FOLDER_MINI_GAP)};
						m.style.radius = all4(5);
						m.style.bg = T("--background-base-lower");
						m.style.font = F(.Medium);
						m.style.font_size = 6;
						m.style.text_align = .Center;
						m.style.text_color = T("--text-default");
						if g.icon != "" { set_remote_image(m, dc.guild_icon_url(gid, g.icon, 32)); } else { m.text = guild_initials(g.name); }
						m.opacity = 1 - t;
					}
				}
				if t > 0.01 {
					f := ui.box("glyph", .Floating_X | .Floating_Y);
					f.semantic_size = .[ui.px(24), ui.px(24)];
					f.fixed_pos = .{8, 8};
					set_icon(f, "folder", with_alpha(color, t));
				}
			}
			unread_closed := !open && unread;
			target: float32 = cast(float32) (ifx (!open && selected_inside) then 40 else (ifx sig.hovering then 20 else (ifx unread_closed then 8 else 0)));
			ui.animate(*pill.user_t, target, 25);
			h := pill.user_t;
			pill.semantic_size = .[ui.px(4), ui.px(h)];
			pill.fixed_pos = .{0, (GUILD_ICON - h) / 2};
			pill.style.bg = T("--text-strong");
			pill.style.radius = .[0, 4, 0, 4];
			if h < 0.5 { pill.flags &= ~ui.Box_Flag.Draw_Background; }
			if !open { mention_badge(mentions, 0); }
			if sig.hovering && !rs.drag_active {
				name := e.name;
				if name == "" {
					names: [..]string;
					names.allocator = temp;
					for gid: e.guilds {
						g := dc.guild_get(store(), gid);
						if g != null { array_add(*names, g.name); }
					}
					name = join(..names, ", ",, temp);
				}
				tooltip_right(name);
			}
		}
		if sig.clicked && !rs.drag_active { table_set(*rs.open, e.id, !open); }
		drag_source(sig, entry, -1);
		if rs.drag_active && rs.drag_entry == entry && rs.drag_inner < 0 { pk_fade(group, 0); }
		array_add(*rs.targets, .{slot.rect, entry, -1});
		if t > 0.01 {
			list := ui.box("fguilds", .Clip);
			list.semantic_size = .[ui.pct(1), ui.px(cast(float32)(e.guilds.count) * RAIL_SLOT * t)];
			list.layout_axis = .Y;
			{ ui.parent(list); defer ui.pop_parent();
				for gid, i: e.guilds { rail_guild(gid, entry, i); }
			}
		}
	}
}

// ---- drag to reorder ----

drag_source :: (sig: ui.Signal, entry: int, inner: int) {
	if sig.pressed {
		rs.drag_entry = entry;
		rs.drag_inner = inner;
		rs.drag_from = app.ui.mouse;
		rs.drag_down = true;
		rs.drag_active = false;
	}
}

drop_at :: (p: ui.Vec2) -> Rail_Target, Drop_Kind {
	t: Rail_Target;
	kind: Drop_Kind;
	for tg: rs.prev {
		r := tg.rect;
		if p.y < r.y0 || p.y >= r.y1 { continue; }
		f := (p.y - r.y0) / max(1.0, r.y1 - r.y0);
		if f < 0.25 {
			return tg, .Before;
		} else if f > 0.75 {
			return tg, .After;
		}
		return tg, .Combine;
	}
	return .{}, .None;
}

rail_drag :: (entries: [..]Rail_Entry) {
	if !rs.drag_down { return; }
	released := false;
	for e: app.ui.events { if e.kind == .Mouse_Up && e.button == .Left { released = true; } }
	d := app.ui.mouse - rs.drag_from;
	if !rs.drag_active && sqrt(d.x * d.x + d.y * d.y) > DRAG_THRESHOLD { rs.drag_active = true; }
	if rs.drag_active {
		tg, kind := drop_at(app.ui.mouse);
		// dragged icon follows the mouse
		ghost := ui.box("rail_ghost###rail_ghost", .Draw_Background | .Draw_Text | .Floating_X | .Floating_Y | .Overlay);
		ghost.semantic_size = .[ui.px(GUILD_ICON), ui.px(GUILD_ICON)];
		ghost.fixed_pos = .{RAIL_ICON_X, app.ui.mouse.y - GUILD_ICON / 2};
		ghost.style.radius = all4(FOLDER_RADIUS);
		ghost.style.bg = T("--background-mod-normal");
		ghost.opacity = 0.8;
		if rs.drag_entry < entries.count {
			e := *entries[rs.drag_entry];
			gid := ifx rs.drag_inner >= 0 && rs.drag_inner < e.guilds.count then e.guilds[rs.drag_inner] else (ifx e.id == 0 then e.guilds[0] else 0);
			g := dc.guild_get(store(), gid);
			if g != null {
				if g.icon != "" { set_remote_image(ghost, dc.guild_icon_url(gid, g.icon, 96)); } else { ghost.text = guild_initials(g.name); }
				ghost.style.font = F(.Medium);
				ghost.style.font_size = guild_acronym_size(ghost.text.count);
				ghost.style.text_align = .Center;
				ghost.style.text_color = T("--text-default");
			} else {
				ghost.style.bg = with_alpha(folder_color(e), 0.4);
			}
		}
		// insertion line / combine ring
		if kind != .None {
			r := tg.rect;
			ind := ui.box("rail_drop###rail_drop", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay);
			if kind == {
			case .Before; #through; case .After;
				y := ifx kind == .Before then r.y0 - 4 else r.y1 - 4;
				ind.semantic_size = .[ui.px(GUILD_ICON), ui.px(4)];
				ind.fixed_pos = .{RAIL_ICON_X, y - 2};
				ind.style.bg = T("--status-positive");
				ind.style.radius = all4(2);
			case .Combine;
				ind.semantic_size = .[ui.px(GUILD_ICON + 4), ui.px(GUILD_ICON + 4)];
				ind.fixed_pos = .{RAIL_ICON_X - 2, r.y0 - 2};
				ind.style.border = 2;
				ind.style.border_color = T("--status-positive");
				ind.style.radius = all4(FOLDER_RADIUS + 2);
			case .None;
			}
		}
		app.ui.animating = true;
		if released {
			if kind != .None { rail_apply_drop(entries, tg, kind); }
		}
	}
	if released {
		rs.drag_down = false;
		rs.drag_active = false;
	}
}

// Rebuild the folder list with the dragged item moved, then persist it.
rail_apply_drop :: (entries_in: [..]Rail_Entry, tg: Rail_Target, kind: Drop_Kind) {
	if tg.entry == rs.drag_entry && tg.inner == rs.drag_inner { return; }
	entries: [..]Rail_Entry;
	entries.allocator = temp;
	for entries_in {
		c := array_add(*entries);
		c.* = it;
		c.guilds = temp_list(..it.guilds);
	}
	src := *entries[rs.drag_entry];
	moving_folder := rs.drag_inner < 0 && src.id != 0;
	moved: Rail_Entry;
	gid: dc.Snowflake;
	if moving_folder {
		moved = src.*;
	} else {
		gi := max(rs.drag_inner, 0);
		gid = src.guilds[gi];
		array_ordered_remove_by_index(*src.guilds, gi);
	}
	// mark removal without shifting indices yet
	removed_entry := moving_folder || src.guilds.count == 0;
	te := *entries[tg.entry];
	if kind == .Combine && !moving_folder && tg.inner < 0 && te.id == 0 && te.guilds[0] != gid {
		// guild onto guild: new folder (random 32-bit id like the client)
		id: u32;
		crypto.random_bytes(.{size_of(u32), cast(*u8) *id});
		te.id = id;
		array_add(*te.guilds, gid);
	} else if kind == .Combine && !moving_folder && tg.inner < 0 && te.id != 0 {
		array_add(*te.guilds, gid);
	} else if tg.inner >= 0 && !moving_folder {
		at := tg.inner + (ifx kind == .After then 1 else 0);
		if te == src && rs.drag_inner >= 0 && rs.drag_inner < tg.inner { at -= 1; }
		array_insert_at(*te.guilds, gid, clamp(at, 0, te.guilds.count));
	} else {
		n := moved;
		if !moving_folder {
			n = .{guilds = temp_list(gid)};
		}
		at := tg.entry + (ifx kind == .After || kind == .Combine then 1 else 0);
		array_insert_at(*entries, n, at);
		if at <= rs.drag_entry { rs.drag_entry += 1; }
	}
	if removed_entry { array_ordered_remove_by_index(*entries, rs.drag_entry); }
	rail_save(entries);
}

// Writes the new order into the store (immediately visible) and settings-proto 1.
rail_save :: (entries: []Rail_Entry) {
	s := store();
	a := s.allocator;
	folders: [..]dc.Guild_Folder;
	folders.allocator = temp;
	for e: entries {
		if e.guilds.count == 0 { continue; }
		array_add(*folders, .{id = e.id, name = e.name, color = e.color, has_color = e.has_color, guild_ids = e.guilds});
	}
	if net_action() { dc.set_guild_folders(app.client, folders); }
	old := s.settings.guild_folders;
	nf: [..]dc.Guild_Folder;
	nf.allocator = a;
	for folders {
		c := array_add(*nf);
		c.* = .{id = it.id, name = copy_string(it.name,, a), color = it.color, has_color = it.has_color};
		c.guild_ids.allocator = a;
		array_copy(*c.guild_ids, it.guild_ids);
	}
	for old {
		free(it.name,, a);
		array_free(it.guild_ids);
	}
	array_free(old);
	s.settings.guild_folders = nf;

	s.changed += 1;
}

temp_list :: (ids: ..dc.Snowflake) -> [..]dc.Snowflake {
	out: [..]dc.Snowflake;
	out.allocator = temp;
	array_add(*out, ..ids);
	return out;
}
