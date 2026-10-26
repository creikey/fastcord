package app

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:slice"
import "core:strings"
import dc "fc:discord"
import "fc:ui"

// Server rail like the official client: home + unread DM avatars, guilds and
// guild folders (settings.guild_folders), mention badges, unread pills,
// drag-to-reorder persisted through dc.set_guild_folders (settings-proto 1).

RAIL_SLOT :: GUILD_ICON + 8 // 48px pitch
RAIL_ICON_X :: 16
FOLDER_MINI :: 16 // 2x2 mini guild icons in a closed folder
FOLDER_MINI_PAD :: 3
FOLDER_MINI_GAP :: 2
FOLDER_RADIUS :: 12
FOLDER_BG_W :: 48 // expanded folder background
FOLDER_BG_RADIUS :: 16
FOLDER_DEFAULT_COLOR :: 0x5865F2 // folders without a color use brand blurple
FOLDER_EXPAND_RATE :: 18
BADGE_H :: 16
BADGE_RING :: 4 // rail background ring around a badge
BADGE_FONT :: 12
DRAG_THRESHOLD :: 4

Rail_Entry :: struct {
	id:        i64, // folder id (0 = a single guild)
	name:      string,
	color:     u64,
	has_color: bool,
	guilds:    [dynamic]dc.Snowflake,
}

@(private = "file")
Drop_Kind :: enum u8 {
	None,
	Before, // insert before entry/guild
	After,
	Combine, // onto a guild (new folder) or into a closed folder
}

@(private = "file")
Rail_Target :: struct {
	rect:  ui.Rect,
	entry: int,
	inner: int, // guild index inside an expanded folder, -1 = the entry itself
}

@(private = "file")
Rail_State :: struct {
	open:        map[i64]bool,
	open_t:      map[i64]f32,
	drag_entry:  int, // entry being pressed / dragged
	drag_inner:  int, // guild index inside a folder (-1 = whole entry)
	drag_active: bool,
	drag_from:   ui.Vec2,
	drag_down:   bool,
	targets:     [dynamic]Rail_Target,
	prev:        [dynamic]Rail_Target, // last frame's slot rects (drop hit testing)
}

@(private = "file")
rs: Rail_State

// The rail's entries in sidebar order: guilds missing from the folders first
// (newest join first, like guild_order), then settings.guild_folders.
rail_entries :: proc() -> [dynamic]Rail_Entry {
	s := store()
	out := make([dynamic]Rail_Entry, context.temp_allocator)
	listed := make(map[dc.Snowflake]bool, allocator = context.temp_allocator)
	for f in s.settings.guild_folders do for id in f.guild_ids do listed[id] = true
	for gid in guild_order() {
		if listed[gid] do break
		e := Rail_Entry{guilds = make([dynamic]dc.Snowflake, context.temp_allocator)}
		append(&e.guilds, gid)
		append(&out, e)
	}
	for f in s.settings.guild_folders {
		e := Rail_Entry{id = f.id, name = f.name, color = f.color, has_color = f.has_color, guilds = make([dynamic]dc.Snowflake, context.temp_allocator)}
		for id in f.guild_ids do if id in s.guilds do append(&e.guilds, id)
		if len(e.guilds) == 0 do continue
		append(&out, e)
	}
	return out
}

// ---- unread / mentions ----

// Mentions in a channel: the read state's count (as of READY / the last ack),
// or the loaded unread messages that mention us if that's more — the store
// doesn't bump mention_count as messages arrive. Every DM message counts.
channel_mentions :: proc(cid: dc.Snowflake) -> int {
	s := store()
	ch := dc.channel_get(s, cid)
	if ch == nil do return 0
	r, _ := &s.read_states[cid]
	return channel_mentions_of(s, ch, r)
}

// channel_mentions for a channel already looked up; r may be nil (never read).
channel_mentions_of :: proc(s: ^dc.Store, ch: ^dc.Channel, r: ^dc.Read_State) -> int {
	last_read := r != nil ? r.last_message_id : 0
	if ch.last_message_id <= last_read do return 0
	cid := ch.id
	dm := ch.kind == .DM || ch.kind == .Group_DM
	n := 0
	for &m in dc.messages_get(s, cid) {
		if m.id <= last_read || m.author_id == s.me || m.pending do continue
		if dm || m.mention_everyone || slice.contains(m.mentions[:], s.me) do n += 1
	}
	return max(n, r != nil ? r.mention_count : 0)
}

guild_mentions :: proc(gid: dc.Snowflake) -> int {
	g := dc.guild_get(store(), gid)
	if g == nil do return 0
	n := 0
	for cid in g.channels do n += channel_mentions(cid)
	return n
}

// DMs with unread messages, newest first (shown under the home button).
unread_dms :: proc() -> []dc.Snowflake {
	s := store()
	out := make([dynamic]dc.Snowflake, context.temp_allocator)
	for cid in s.private_channels {
		ch := dc.channel_get(s, cid)
		if ch == nil do continue
		r, _ := &s.read_states[cid]
		if channel_mentions_of(s, ch, r) > 0 do append(&out, cid)
	}
	slice.sort_by(out[:], proc(a, b: dc.Snowflake) -> bool {
		ca, cb := dc.channel_get(store(), a), dc.channel_get(store(), b)
		return (ca != nil ? ca.last_message_id : 0) > (cb != nil ? cb.last_message_id : 0)
	})
	return out[:]
}

// Red count pill at the icon's bottom-right, ringed in the rail background.
// Call with the 72-wide slot as parent; icon_y is the icon's top in the slot.
mention_badge :: proc(n: int, icon_y: f32) {
	if n <= 0 do return
	text := n > 99 ? "99+" : fmt.tprint(n)
	w := max(f32(BADGE_H), f32(len(text)) * 7 + 8)
	ring := ui.box("badgering", {.Draw_Background, .Floating_X, .Floating_Y})
	ring.semantic_size = {.X = ui.px(w + 2 * BADGE_RING), .Y = ui.px(BADGE_H + 2 * BADGE_RING)}
	ring.fixed_pos = {RAIL_ICON_X + GUILD_ICON + 4 - w - BADGE_RING, icon_y + GUILD_ICON + 4 - BADGE_H - BADGE_RING}
	ring.style.bg = T("--background-base-lowest")
	ring.style.radius = (BADGE_H + 2 * BADGE_RING) / 2
	if ui.parent(ring) {
		b := ui.box(fmt.tprintf("%s##badge", text), {.Draw_Background, .Draw_Text, .Floating_X, .Floating_Y})
		b.semantic_size = {.X = ui.px(w), .Y = ui.px(BADGE_H)}
		b.fixed_pos = {BADGE_RING, BADGE_RING}
		b.style.bg = T("--status-danger")
		b.style.radius = BADGE_H / 2
		b.style.font = F(.Bold)
		b.style.font_size = BADGE_FONT
		b.style.text_color = {1, 1, 1, 1}
		b.style.text_align = .Center
	}
}

// ---- the rail ----

rail_view :: proc() {
	s := store()
	clear(&rs.prev)
	append(&rs.prev, ..rs.targets[:])
	clear(&rs.targets)
	rail := ui.box("rail", {.Scroll_Y, .Clip})
	rail.semantic_size = {.X = ui.px(RAIL_W), .Y = ui.pct(1)}
	rail.layout_axis = .Y
	ui.signal(rail)
	entries := rail_entries()
	if ui.parent(rail) {
		home := rail_item("home", app.view.guild == 0, "", "clyde", 0)
		if home.clicked do go_home()
		if ui.parent(rail.last) do mention_badge(pending_count(), 0)
		for cid in unread_dms() {
			if ui.id_scope(u64(cid)) do rail_dm(cid)
		}
		sep := ui.box("sep")
		sep.semantic_size = {.X = ui.pct(1), .Y = ui.px(9)}
		if ui.parent(sep) {
			line := ui.box("line", {.Draw_Background, .Floating_X, .Floating_Y})
			line.semantic_size = {.X = ui.px(32), .Y = ui.px(1)}
			line.fixed_pos = {20, 0}
			line.style.bg = T("--background-mod-subtle")
			line.style.radius = 1
		}
		for &e, i in entries {
			if ui.id_scope(e.id != 0 ? u64(e.id) : u64(e.guilds[0])) {
				if e.id != 0 do rail_folder(&e, i)
				else do rail_guild(e.guilds[0], i, -1)
			}
		}
		rail_item("add", false, "", "circle-plus", 0)
		rail_item("discover", false, "", "compass", 0)
		spacer(.Y, USER_PANEL_H + 16)
	}
	rail_drag(entries)
	_ = s
}

@(private = "file")
rail_dm :: proc(cid: dc.Snowflake) {
	s := store()
	ch := dc.channel_get(s, cid)
	if ch == nil do return
	slot := ui.box("dmslot")
	slot.semantic_size = {.X = ui.pct(1), .Y = ui.px(RAIL_SLOT)}
	if ui.offscreen(slot) do return
	if ui.parent(slot) {
		ic := ui.box("dmicon", {.Clickable, .Draw_Background, .Floating_X, .Floating_Y})
		ic.semantic_size = {.X = ui.px(GUILD_ICON), .Y = ui.px(GUILD_ICON)}
		ic.fixed_pos = {RAIL_ICON_X, 0}
		sig := ui.signal(ic)
		ui.animate(&ic.user_t, sig.hovering ? 1 : 0, 25)
		ic.style.radius = GUILD_ICON / 2 - (GUILD_ICON / 2 - 12) * ic.user_t
		ic.style.bg = ch.kind == .Group_DM ? group_icon_color(ch.id) : T("--background-brand")
		if ch.kind == .DM && len(ch.recipient_ids) > 0 {
			set_remote_image(ic, avatar_url_for(ch.recipient_ids[0], GUILD_ICON))
		} else if ui.parent(ic) {
			g := ui.box("g", {.Floating_X, .Floating_Y})
			g.semantic_size = {.X = ui.px(24), .Y = ui.px(24)}
			g.fixed_pos = {8, 8}
			set_icon(g, "group", {1, 1, 1, 1})
		}
		pill := ui.box("pill", {.Draw_Background, .Floating_X, .Floating_Y})
		ui.animate(&pill.user_t, sig.hovering ? 20 : 8, 25)
		pill.semantic_size = {.X = ui.px(4), .Y = ui.px(pill.user_t)}
		pill.fixed_pos = {0, (GUILD_ICON - pill.user_t) / 2}
		pill.style.bg = T("--text-strong")
		pill.style.radius = {0, 4, 0, 4}
		mention_badge(channel_mentions(cid), 0)
		if sig.hovering do tooltip_right(dm_name(ch))
		if sig.clicked do select_channel(0, cid)
	}
}

// One guild slot (top level or inside an expanded folder) with badge + drag source.
@(private = "file")
rail_guild :: proc(gid: dc.Snowflake, entry, inner: int) {
	g := dc.guild_get(store(), gid)
	if g == nil do return
	if ui.id_scope(u64(gid)) {
		sig := rail_item("guild", app.view.guild == gid, guild_initials(g.name), "", gid)
		slot := ui.top_parent().last
		if sig.box == nil do return // offscreen
		if ui.parent(slot) do mention_badge(guild_mentions(gid), 0)
		if sig.clicked && !rs.drag_active do select_guild(gid)
		drag_source(sig, entry, inner)
		if rs.drag_active && rs.drag_entry == entry && rs.drag_inner == inner do pk_fade(slot, 0)
		append(&rs.targets, Rail_Target{slot.rect, entry, inner})
	}
}

@(private = "file")
folder_color :: proc(e: ^Rail_Entry) -> ui.Color {
	return rgb_u32(u32(e.has_color ? e.color : FOLDER_DEFAULT_COLOR))
}

@(private = "file")
rail_folder :: proc(e: ^Rail_Entry, entry: int) {
	open := rs.open[e.id]
	t := rs.open_t[e.id]
	ui.animate(&t, open ? 1 : 0, FOLDER_EXPAND_RATE)
	rs.open_t[e.id] = t
	group := ui.box("folder")
	group.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	group.layout_axis = .Y
	if ui.offscreen(group) {
		group.semantic_size[.Y] = ui.px(group.rect.y1 - group.rect.y0)
		return
	}
	selected_inside := false
	unread := false
	mentions := 0
	for gid in e.guilds {
		if gid == app.view.guild do selected_inside = true
		if guild_has_unread(gid) do unread = true
		mentions += guild_mentions(gid)
	}
	color := folder_color(e)
	if ui.parent(group) {
		// expanded background behind header + guilds
		if t > 0.01 {
			bg := ui.box("folderbg", {.Draw_Background, .Floating_X, .Floating_Y})
			bg.semantic_size = {.X = ui.px(FOLDER_BG_W), .Y = ui.px(RAIL_SLOT - 8 + f32(len(e.guilds)) * RAIL_SLOT * t)}
			bg.fixed_pos = {(RAIL_W - FOLDER_BG_W) / 2, -4}
			bg.style.radius = FOLDER_BG_RADIUS
			bg.style.bg = with_alpha(T("--background-mod-subtle"), t)
		}
		slot := ui.box("fslot")
		slot.semantic_size = {.X = ui.pct(1), .Y = ui.px(RAIL_SLOT)}
		sig: ui.Signal
		if ui.parent(slot) {
			pill := ui.box("pill", {.Draw_Background, .Floating_X, .Floating_Y})
			ic := ui.box("ficon", {.Clickable, .Draw_Background, .Floating_X, .Floating_Y, .Hot_Animation})
			ic.semantic_size = {.X = ui.px(GUILD_ICON), .Y = ui.px(GUILD_ICON)}
			ic.fixed_pos = {RAIL_ICON_X, 0}
			ic.style.radius = FOLDER_RADIUS
			sig = ui.signal(ic)
			// closed: color-tinted squircle with 2x2 minis; open: the folder glyph
			ic.style.bg = with_alpha(color, 0.4 * (1 - t))
			ic.style.bg_hot = with_alpha(color, 0.55 * (1 - t))
			if ui.parent(ic) {
				if t < 0.99 {
					for gid, i in e.guilds {
						if i >= 4 do break
						g := dc.guild_get(store(), gid)
						if g == nil do continue
						m := ui.box(fmt.tprintf("##mini%d", i), {.Draw_Background, .Draw_Text, .Floating_X, .Floating_Y})
						m.semantic_size = {.X = ui.px(FOLDER_MINI), .Y = ui.px(FOLDER_MINI)}
						m.fixed_pos = {FOLDER_MINI_PAD + f32(i % 2) * (FOLDER_MINI + FOLDER_MINI_GAP), FOLDER_MINI_PAD + f32(i / 2) * (FOLDER_MINI + FOLDER_MINI_GAP)}
						m.style.radius = 5
						m.style.bg = T("--background-base-lower")
						m.style.font = F(.Medium)
						m.style.font_size = 6
						m.style.text_align = .Center
						m.style.text_color = T("--text-default")
						if g.icon != "" do set_remote_image(m, dc.guild_icon_url(gid, g.icon, 32))
						else do m.text = guild_initials(g.name)
						m.opacity = 1 - t
					}
				}
				if t > 0.01 {
					f := ui.box("glyph", {.Floating_X, .Floating_Y})
					f.semantic_size = {.X = ui.px(24), .Y = ui.px(24)}
					f.fixed_pos = {8, 8}
					set_icon(f, "folder", with_alpha(color, t))
				}
			}
			unread_closed := !open && unread
			target: f32 = (!open && selected_inside) ? 40 : (sig.hovering ? 20 : (unread_closed ? 8 : 0))
			ui.animate(&pill.user_t, target, 25)
			h := pill.user_t
			pill.semantic_size = {.X = ui.px(4), .Y = ui.px(h)}
			pill.fixed_pos = {0, (GUILD_ICON - h) / 2}
			pill.style.bg = T("--text-strong")
			pill.style.radius = {0, 4, 0, 4}
			if h < 0.5 do pill.flags -= {.Draw_Background}
			if !open do mention_badge(mentions, 0)
			if sig.hovering && !rs.drag_active {
				name := e.name
				if name == "" {
					names := make([dynamic]string, context.temp_allocator)
					for gid in e.guilds do if g := dc.guild_get(store(), gid); g != nil do append(&names, g.name)
					name = strings.join(names[:], ", ", context.temp_allocator)
				}
				tooltip_right(name)
			}
		}
		if sig.clicked && !rs.drag_active do rs.open[e.id] = !open
		drag_source(sig, entry, -1)
		if rs.drag_active && rs.drag_entry == entry && rs.drag_inner < 0 do pk_fade(group, 0)
		append(&rs.targets, Rail_Target{slot.rect, entry, -1})
		if t > 0.01 {
			list := ui.box("fguilds", {.Clip})
			list.semantic_size = {.X = ui.pct(1), .Y = ui.px(f32(len(e.guilds)) * RAIL_SLOT * t)}
			list.layout_axis = .Y
			if ui.parent(list) {
				for gid, i in e.guilds do rail_guild(gid, entry, i)
			}
		}
	}
}

// ---- drag to reorder ----

@(private = "file")
drag_source :: proc(sig: ui.Signal, entry, inner: int) {
	if sig.pressed {
		rs.drag_entry = entry
		rs.drag_inner = inner
		rs.drag_from = app.ui.mouse
		rs.drag_down = true
		rs.drag_active = false
	}
}

@(private = "file")
drop_at :: proc(p: ui.Vec2) -> (t: Rail_Target, kind: Drop_Kind) {
	for tg in rs.prev {
		r := tg.rect
		if p.y < r.y0 || p.y >= r.y1 do continue
		f := (p.y - r.y0) / max(1, r.y1 - r.y0)
		switch {
		case f < 0.25:
			return tg, .Before
		case f > 0.75:
			return tg, .After
		}
		return tg, .Combine
	}
	return {}, .None
}

@(private = "file")
rail_drag :: proc(entries: [dynamic]Rail_Entry) {
	if !rs.drag_down do return
	released := false
	for e in app.ui.events do if e.kind == .Mouse_Up && e.button == .Left do released = true
	d := app.ui.mouse - rs.drag_from
	if !rs.drag_active && math.sqrt(d.x * d.x + d.y * d.y) > DRAG_THRESHOLD do rs.drag_active = true
	if rs.drag_active {
		tg, kind := drop_at(app.ui.mouse)
		// dragged icon follows the mouse
		ghost := ui.box("rail_ghost###rail_ghost", {.Draw_Background, .Draw_Text, .Floating_X, .Floating_Y, .Overlay})
		ghost.semantic_size = {.X = ui.px(GUILD_ICON), .Y = ui.px(GUILD_ICON)}
		ghost.fixed_pos = {RAIL_ICON_X, app.ui.mouse.y - GUILD_ICON / 2}
		ghost.style.radius = FOLDER_RADIUS
		ghost.style.bg = T("--background-mod-normal")
		ghost.opacity = 0.8
		if rs.drag_entry < len(entries) {
			e := &entries[rs.drag_entry]
			gid := rs.drag_inner >= 0 && rs.drag_inner < len(e.guilds) ? e.guilds[rs.drag_inner] : (e.id == 0 ? e.guilds[0] : 0)
			if g := dc.guild_get(store(), gid); g != nil {
				if g.icon != "" do set_remote_image(ghost, dc.guild_icon_url(gid, g.icon, 96))
				else do ghost.text = guild_initials(g.name)
				ghost.style.font = F(.Medium)
				ghost.style.font_size = guild_acronym_size(len(ghost.text))
				ghost.style.text_align = .Center
				ghost.style.text_color = T("--text-default")
			} else {
				ghost.style.bg = with_alpha(folder_color(e), 0.4)
			}
		}
		// insertion line / combine ring
		if kind != .None {
			r := tg.rect
			ind := ui.box("rail_drop###rail_drop", {.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y, .Overlay})
			switch kind {
			case .Before, .After:
				y := kind == .Before ? r.y0 - 4 : r.y1 - 4
				ind.semantic_size = {.X = ui.px(GUILD_ICON), .Y = ui.px(4)}
				ind.fixed_pos = {RAIL_ICON_X, y - 2}
				ind.style.bg = T("--status-positive")
				ind.style.radius = 2
			case .Combine:
				ind.semantic_size = {.X = ui.px(GUILD_ICON + 4), .Y = ui.px(GUILD_ICON + 4)}
				ind.fixed_pos = {RAIL_ICON_X - 2, r.y0 - 2}
				ind.style.border = 2
				ind.style.border_color = T("--status-positive")
				ind.style.radius = FOLDER_RADIUS + 2
			case .None:
			}
		}
		app.ui.animating = true
		if released {
			if kind != .None do rail_apply_drop(entries, tg, kind)
		}
	}
	if released {
		rs.drag_down = false
		rs.drag_active = false
	}
}

// Rebuild the folder list with the dragged item moved, then persist it.
@(private = "file")
rail_apply_drop :: proc(entries_in: [dynamic]Rail_Entry, tg: Rail_Target, kind: Drop_Kind) {
	if tg.entry == rs.drag_entry && tg.inner == rs.drag_inner do return
	entries := make([dynamic]Rail_Entry, context.temp_allocator)
	for e in entries_in {
		c := e
		c.guilds = make([dynamic]dc.Snowflake, context.temp_allocator)
		append(&c.guilds, ..e.guilds[:])
		append(&entries, c)
	}
	src := &entries[rs.drag_entry]
	moving_folder := rs.drag_inner < 0 && src.id != 0
	moved: Rail_Entry
	gid: dc.Snowflake
	if moving_folder {
		moved = src^
	} else {
		gi := max(rs.drag_inner, 0)
		gid = src.guilds[gi]
		ordered_remove(&src.guilds, gi)
	}
	// mark removal without shifting indices yet
	removed_entry := moving_folder || (len(src.guilds) == 0)
	te := &entries[tg.entry]
	switch {
	case kind == .Combine && !moving_folder && tg.inner < 0 && te.id == 0 && te.guilds[0] != gid:
		// guild onto guild: new folder (random 32-bit id like the client)
		te.id = i64(rand.uint32())
		append(&te.guilds, gid)
	case kind == .Combine && !moving_folder && tg.inner < 0 && te.id != 0:
		append(&te.guilds, gid)
	case tg.inner >= 0 && !moving_folder:
		at := tg.inner + (kind == .After ? 1 : 0)
		if te == src && rs.drag_inner >= 0 && rs.drag_inner < tg.inner do at -= 1
		inject_at(&te.guilds, clamp(at, 0, len(te.guilds)), gid)
	case:
		n := moved
		if !moving_folder {
			n = Rail_Entry{guilds = make([dynamic]dc.Snowflake, context.temp_allocator)}
			append(&n.guilds, gid)
		}
		at := tg.entry + (kind == .After || kind == .Combine ? 1 : 0)
		inject_at(&entries, at, n)
		if at <= rs.drag_entry do rs.drag_entry += 1
	}
	if removed_entry do ordered_remove(&entries, rs.drag_entry)
	rail_save(entries[:])
}

// Writes the new order into the store (immediately visible) and settings-proto 1.
@(private = "file")
rail_save :: proc(entries: []Rail_Entry) {
	s := store()
	a := s.allocator
	folders := make([dynamic]dc.Guild_Folder, context.temp_allocator)
	for e in entries {
		if len(e.guilds) == 0 do continue
		append(&folders, dc.Guild_Folder{id = e.id, name = e.name, color = e.color, has_color = e.has_color, guild_ids = e.guilds})
	}
	if app.client != nil do dc.set_guild_folders(app.client, folders[:])
	old := s.settings.guild_folders
	nf := make([dynamic]dc.Guild_Folder, a)
	for f in folders {
		c := dc.Guild_Folder{id = f.id, name = strings.clone(f.name, a), color = f.color, has_color = f.has_color, guild_ids = make([dynamic]dc.Snowflake, a)}
		append(&c.guild_ids, ..f.guild_ids[:])
		append(&nf, c)
	}
	for &f in old {
		delete(f.name, a)
		delete(f.guild_ids)
	}
	delete(old)
	s.settings.guild_folders = nf
	s.changed += 1
}
