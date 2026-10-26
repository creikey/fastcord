package app

import "core:fmt"
import "core:slice"
import "core:strings"
import dc "fc:discord"
import "fc:ui"

// Cmd+K quick switcher: fuzzy search over DMs, channels and servers.

Switcher :: struct {
	open:   bool,
	editor: ui.Editor,
	sel:    int,
	t:      f32,
}

sw: Switcher

Switch_Kind :: enum u8 {
	Channel,
	DM,
	Guild,
}

Switch_Item :: struct {
	kind:  Switch_Kind,
	id:    dc.Snowflake, // channel or guild
	guild: dc.Snowflake,
	name:  string,
	sub:   string,
	score: int,
}

// Subsequence match with bonuses for prefix and word starts; -1 = no match.
fuzzy_score :: proc(query, text: string) -> int {
	if query == "" do return 1
	q := strings.to_lower(query, context.temp_allocator)
	t := strings.to_lower(text, context.temp_allocator)
	if strings.has_prefix(t, q) do return 1000 - len(t)
	if i := strings.index(t, q); i >= 0 do return 500 - i
	score := 0
	ti := 0
	for qi in 0 ..< len(q) {
		found := false
		for ti < len(t) {
			if t[ti] == q[qi] {
				score += (ti == 0 || t[ti - 1] == ' ' || t[ti - 1] == '-') ? 10 : 1
				ti += 1
				found = true
				break
			}
			ti += 1
		}
		if !found do return -1
	}
	return score
}

switcher_toggle :: proc() {
	sw.open = !sw.open
	sw.t = 0
	sw.sel = 0
	ui.editor_set_text(&sw.editor, "")
}

switcher_items :: proc(query: string) -> []Switch_Item {
	s := store()
	items := make([dynamic]Switch_Item, context.temp_allocator)
	for cid in s.private_channels {
		ch := dc.channel_get(s, cid)
		if ch == nil do continue
		name := dm_name(ch)
		if sc := fuzzy_score(query, name); sc >= 0 do append(&items, Switch_Item{kind = .DM, id = cid, name = name, score = sc + 5})
	}
	for gid in guild_order() {
		g := dc.guild_get(s, gid)
		if g == nil do continue
		if sc := fuzzy_score(query, g.name); sc >= 0 && query != "" do append(&items, Switch_Item{kind = .Guild, id = gid, name = g.name, score = sc})
		for cid in dc.guild_channels_sorted(s, gid) {
			ch := dc.channel_get(s, cid)
			if ch == nil || ch.kind == .Guild_Category do continue
			if sc := fuzzy_score(query, ch.name); sc >= 0 {
				append(&items, Switch_Item{kind = .Channel, id = cid, guild = gid, name = ch.name, sub = g.name, score = sc + (dc.channel_unread(s, cid) ? 3 : 0)})
			}
		}
	}
	slice.stable_sort_by(items[:], proc(a, b: Switch_Item) -> bool {return a.score > b.score})
	if len(items) > 12 do resize(&items, 12)
	return items[:]
}

switcher_activate :: proc(it: Switch_Item) {
	switch it.kind {
	case .DM:
		select_channel(0, it.id)
	case .Channel:
		select_channel(it.guild, it.id)
	case .Guild:
		select_guild(it.id)
	}
	sw.open = false
}

quick_switcher :: proc() {
	ui.animate(&sw.t, 1, 30)
	scrim := ui.box("sw_scrim", {.Draw_Background, .Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	scrim.style.bg = {0, 0, 0, 0.7 * sw.t}
	if ui.signal(scrim).clicked {
		sw.open = false
		return
	}
	query := strings.trim_space(ui.editor_text(&sw.editor))
	items := switcher_items(query)
	sw.sel = clamp(sw.sel, 0, max(len(items) - 1, 0))
	for &e in app.ui.events {
		if e.kind != .Key_Down || e.consumed do continue
		#partial switch e.key {
		case .Down:
			sw.sel = min(sw.sel + 1, len(items) - 1)
			e.consumed = true
		case .Up:
			sw.sel = max(sw.sel - 1, 0)
			e.consumed = true
		case .Escape:
			sw.open = false
			e.consumed = true
		}
	}
	W :: 570
	box := ui.box("switcher", {.Draw_Background, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	box.semantic_size = {.X = ui.px(W), .Y = ui.children()}
	box.fixed_pos = {(app.ui.window.x - W) / 2, app.ui.window.y * 0.2 - (1 - sw.t) * 8}
	box.opacity = sw.t
	box.layout_axis = .Y
	box.style.bg = T("--modal-background")
	box.style.radius = 8
	box.style.shadow_color = {0, 0, 0, 0.3}
	box.style.shadow_blur = 24
	ui.signal(box)
	if ui.parent(box) {
		spacer(.Y, 20)
		r := row("inrow")
		r.semantic_size = {.X = ui.pct(1), .Y = ui.px(70)}
		if ui.parent(r) {
			spacer(.X, 20)
			field := row("field", {.Draw_Background})
			field.semantic_size = {.X = ui.fill(), .Y = ui.px(70)}
			field.style.bg = T("--input-background-default")
			field.style.radius = 4
			if ui.parent(field) {
				spacer(.X, 12)
				res := text_field("q", &sw.editor, "Where would you like to go?", true, 24, 30)
				if res == .Submit && len(items) > 0 do switcher_activate(items[sw.sel])
				if res == .Changed do sw.sel = 0
				spacer(.X, 12)
			}
			spacer(.X, 20)
		}
		spacer(.Y, 12)
		for it, i in items {
			ir := row(fmt.tprintf("it%d", i), {.Clickable, .Draw_Background})
			ir.semantic_size = {.X = ui.pct(1), .Y = ui.px(34)}
			sig := ui.signal(ir)
			if sig.hovering && app.ui.mouse != app.ui.mouse_prev do sw.sel = i
			sel := i == sw.sel
			if sel do ir.style.bg = T("--background-mod-normal")
			if sig.clicked do switcher_activate(it)
			if ui.parent(ir) {
				spacer(.X, 28)
				switch it.kind {
				case .DM:
					ch := dc.channel_get(store(), it.id)
					if ch != nil && ch.kind == .DM && len(ch.recipient_ids) > 0 do avatar_box("av", ch.recipient_ids[0], 20)
					else do icon("ic", "group", 20, T("--interactive-icon-default"))
				case .Channel:
					ch := dc.channel_get(store(), it.id)
					icon("ic", ch != nil ? channel_icon_name(ch) : "text", 20, T("--interactive-icon-default"))
				case .Guild:
					icon("ic", "server", 20, T("--interactive-icon-default"))
				}
				spacer(.X, 8)
				label(it.name, .Medium, 16, sel ? T("--interactive-text-active") : T("--interactive-text-default"), 20)
				if it.sub != "" {
					filler(.X)
					label(it.sub, .Semibold, 12, T("--text-muted"), 16)
				}
				spacer(.X, 28)
			}
		}
		spacer(.Y, 20)
	}
}
