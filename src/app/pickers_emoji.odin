package app

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import dc "fc:discord"
import "fc:gfx"
import "fc:ui"

// Emoji picker: category nav, sticky section headers, 9-column virtualized
// grid, inspector bar, skin tones, keyboard navigation, search, frecency.

// ---- geometry ----
EM_NAV_W :: 48
EM_NAV_SLOT :: 36 // height per nav entry
EM_NAV_GUILD :: 32 // guild icon size in the nav
EM_NAV_ICON :: 24
EM_NAV_SEP_H :: 9
EM_GRID_PAD_L :: 8
EM_GRID_PAD_TOP :: 0
EM_GRID_PAD_BOTTOM :: 8
EM_CELL :: 48
EM_SIZE :: 40 // emoji draw size (sprite sheet 40)
EM_CELL_RADIUS :: 8
EM_HEADER_H :: 32
EM_HEADER_FONT :: 12
EM_HEADER_ICON :: 16
EM_INSPECTOR_H :: 48
EM_INSPECTOR_EMOJI :: 28
EM_FREQUENT_MAX :: 27 // three rows
EM_TONE_BUTTON :: 32
EM_TONE_ITEM :: 32
EM_SPRITE_PX :: 40 // which spritesheet set (40 or 48)

// Spritesheets from the client bundle (spritesheet-emoji-{40,48}, spritesheet-{tone}-{40,48}).
@(private = "file")
SPRITE_EMOJI := [2]string {
	"https://cdn.discordapp.com/assets/content/c357d57faac49918709981e6fb30e526fa62b6d440f99fd8bd2b88f0542ad6c5.png", // 40
	"https://cdn.discordapp.com/assets/content/91eab03bbed7fa52a213659925fa7af29c5d8e32d727eb2f90cc777f4edd9afb.png", // 48
}
// [size][tone 0..5]: tone 0 is spritesheet--{size} (diversity emoji without a tone)
@(private = "file")
SPRITE_TONES := [2][6]string {
	{
		"https://cdn.discordapp.com/assets/content/2f1adbbeee210ebdfaf92e6cdb29be32af98df2f576a85c6f18515eecb49a628.png",
		"https://cdn.discordapp.com/assets/content/112053a6b05b0d3869dde1b52ab452dd6286515848e4dc8145095b6c757fb126.png",
		"https://cdn.discordapp.com/assets/content/8c716c8c5de61506e1bc3df1beab3e1bb9313ae5dfbb5b555cad60fbbc2a1fa6.png",
		"https://cdn.discordapp.com/assets/content/5885b33027a6383a93d1021abb3f7b1c4096257eac03829456430f6453154bbd.png",
		"https://cdn.discordapp.com/assets/content/d474fadfda8e1fa265be85f90fd78232ebb8c87667435ee8d32719aec28f17de.png",
		"https://cdn.discordapp.com/assets/content/050dcea8f727152a7eb98afdced8d85c1ccdfe9bcb81eb7a14989f2e452e4ad8.png",
	},
	{
		"https://cdn.discordapp.com/assets/content/14e7ef6e372a0fd01b5a6e0436ce962cd61e7dacc8fb49888f9a997387a16041.png",
		"https://cdn.discordapp.com/assets/content/4e982c3eafac47f662e857b00b64b9801948b6b336f256cb8d3b768e4c8f9c7c.png",
		"https://cdn.discordapp.com/assets/content/fca48430d7ea5c68dba8d5c78b2f5d5e15546209fb669315f51a272808e2ef73.png",
		"https://cdn.discordapp.com/assets/content/88f20b32afd12ac9e4fe0a630cfdae8889fd810b81b79231e1991e70c0a26768.png",
		"https://cdn.discordapp.com/assets/content/6b84fe748077d9a437df4481644802dade5d86e78120182e549ed84f408d0d21.png",
		"https://cdn.discordapp.com/assets/content/2bbfef2ff9e844a977273ef48a15bf62ec50ff5b457743a9ba2aa2e1ebd2953f.png",
	},
}
SPRITE_PER_ROW :: 42 // EmojiSprites.NonDiversityPerRow
SPRITE_DIVERSITY_PER_ROW :: 10 // EmojiSprites.DiversityPerRow

TONE_SURROGATES := [6]string{"✋", "✋🏻", "✋🏼", "✋🏽", "✋🏾", "✋🏿"}

Pk_Emoji :: struct {
	uni:      i32, // emoji_db index, -1 = custom
	id:       dc.Snowflake,
	name:     string,
	animated: bool,
	guild:    dc.Snowflake,
	locked:   bool,
}

Em_Section_Kind :: enum u8 {
	Favorites,
	Recent,
	Guild,
	Unicode,
	Search,
}

Em_Section :: struct {
	kind:  Em_Section_Kind,
	key:   u64, // stable id for collapse state
	title: string,
	icon:  string,
	guild: dc.Snowflake,
	items: []Pk_Emoji,
	y:     f32, // header top in content space
	rows:  int,
}

Em_Pos :: struct {
	sec, idx: int,
}

Emoji_View :: struct {
	scroll:      Pk_Scroll,
	inspected:   Em_Pos, // sec = -1: none
	collapsed:   map[u64]bool,
	tone_open:   bool,
	nav_scroll:  f32,
	last_mouse:  ui.Vec2,
	keyboard:    bool, // last navigation was keyboard (mouse-over doesn't steal until it moves)
}

ev: Emoji_View

emoji_picker_reset :: proc() {
	ev.scroll = {}
	ev.inspected = {-1, 0}
	ev.tone_open = false
	ev.keyboard = false
}

emoji_picker_query_changed :: proc() {
	ev.scroll.target = 0
	ev.scroll.y = 0
	ev.inspected = {-1, 0}
}

@(private = "file")
premium :: proc() -> bool {
	u := dc.user_get(store(), store().me)
	return u != nil && u.premium_type > 0
}

@(private = "file")
current_guild :: proc() -> dc.Snowflake {
	if c := dc.channel_get(store(), pk.channel); c != nil do return c.guild_id
	return 0
}

// Custom emoji usable here? Without Nitro: only this guild's, and not animated.
@(private = "file")
custom_locked :: proc(e: dc.Emoji, here: dc.Snowflake, nitro: bool) -> bool {
	if !e.available do return true
	if nitro do return false
	return e.guild_id != here || e.animated
}

@(private = "file")
uni_item :: proc(idx: int) -> Pk_Emoji {
	return Pk_Emoji{uni = i32(idx), name = emoji_db.emojis[idx].names[0]}
}

@(private = "file")
custom_item :: proc(e: dc.Emoji, here: dc.Snowflake, nitro: bool) -> Pk_Emoji {
	return Pk_Emoji{uni = -1, id = e.id, name = e.name, animated = e.animated, guild = e.guild_id, locked = custom_locked(e, here, nitro)}
}

@(private = "file")
frec_key :: proc(e: Pk_Emoji) -> string {
	if e.uni >= 0 do return e.name
	return fmt.tprint(u64(e.id))
}

// Guild order for custom emoji: the current guild first, then the sidebar order.
@(private = "file")
emoji_guilds :: proc() -> []dc.Snowflake {
	here := current_guild()
	out := make([dynamic]dc.Snowflake, context.temp_allocator)
	if here != 0 do append(&out, here)
	for gid in guild_order() do if gid != here do append(&out, gid)
	return out[:]
}

@(private = "file")
build_sections :: proc(ignore_query := false) -> []Em_Section {
	emoji_db_load()
	s := store()
	here := current_guild()
	nitro := premium()
	secs := make([dynamic]Em_Section, context.temp_allocator)
	by_id := make(map[dc.Snowflake]dc.Emoji, allocator = context.temp_allocator)
	for gid in emoji_guilds() {
		if g := dc.guild_get(s, gid); g != nil do for e in g.emojis do by_id[e.id] = e
	}
	key_item :: proc(key: string, by_id: map[dc.Snowflake]dc.Emoji, here: dc.Snowflake, nitro: bool) -> (Pk_Emoji, bool) {
		if id, ok := strconv.parse_u64(key); ok && len(key) > 6 {
			if e, found := by_id[dc.Snowflake(id)]; found do return custom_item(e, here, nitro), true
			return {}, false
		}
		if i, found := emoji_db.by_name[key]; found && i < emoji_db.parents do return uni_item(i), true
		return {}, false
	}

	q := ignore_query ? "" : pk_query(.Emoji)
	if q != "" {
		append(&secs, Em_Section{kind = .Search, key = 1, items = emoji_search(q, by_id, here, nitro)})
		return secs[:]
	}

	if len(frecency.favorite_emojis) > 0 {
		items := make([dynamic]Pk_Emoji, context.temp_allocator)
		for k in frecency.favorite_emojis do if it, ok := key_item(k, by_id, here, nitro); ok do append(&items, it)
		if len(items) > 0 do append(&secs, Em_Section{kind = .Favorites, key = 2, title = "Favorites", icon = "star", items = items[:]})
	}
	frequent: {
		reaction := pk.mode == .Reaction
		items := make([dynamic]Pk_Emoji, context.temp_allocator)
		seen := make(map[string]bool, allocator = context.temp_allocator)
		for k in frec_top(reaction ? frecency.reaction : frecency.emoji, EM_FREQUENT_MAX) {
			if it, ok := key_item(k, by_id, here, nitro); ok && !seen[k] {
				append(&items, it)
				seen[k] = true
			}
		}
		for k in (reaction ? emoji_db.default_reaction : emoji_db.default_frecency) {
			if len(items) >= EM_FREQUENT_MAX do break
			if it, ok := key_item(k, by_id, here, nitro); ok && !seen[k] {
				append(&items, it)
				seen[k] = true
			}
		}
		if len(items) > 0 do append(&secs, Em_Section{kind = .Recent, key = 3, title = "Frequently Used", icon = "clock", items = items[:]})
	}
	for gid in emoji_guilds() {
		g := dc.guild_get(s, gid)
		if g == nil || len(g.emojis) == 0 do continue
		items := make([]Pk_Emoji, len(g.emojis), context.temp_allocator)
		for e, i in g.emojis do items[i] = custom_item(e, here, nitro)
		append(&secs, Em_Section{kind = .Guild, key = u64(gid), title = g.name, guild = gid, items = items})
	}
	for c, ci in emoji_db.cats {
		items := make([]Pk_Emoji, c.end - c.start, context.temp_allocator)
		for i in c.start ..< c.end do items[i - c.start] = uni_item(i)
		append(&secs, Em_Section{kind = .Unicode, key = 100 + u64(ci), title = emoji_category_title(c.key), icon = emoji_category_icon(c.key), items = items})
	}
	return secs[:]
}

// EmojiStore.searchWithoutFetchingLatest: the query (lowercased, spaces and
// underscores removed) is a substring of a name with underscores removed; then
// getSearchResultsOrder: score 1 + 4*exact + 2*word match + 1*prefix, times
// max(1, frecency/100), descending, ties by name. Unlocked before locked.
emoji_search :: proc(q: string, by_id: map[dc.Snowflake]dc.Emoji, here: dc.Snowflake, nitro: bool) -> []Pk_Emoji {
	Hit :: struct {
		e:     Pk_Emoji,
		score: f64,
	}
	raw := strings.trim_prefix(strings.trim_suffix(q, ":"), ":")
	needle, _ := strings.replace_all(raw, "_", "", context.temp_allocator)
	needle, _ = strings.replace_all(needle, " ", "", context.temp_allocator)
	if needle == "" do return nil
	matches :: proc(name, needle: string) -> bool {
		n, _ := strings.replace_all(strings.to_lower(name, context.temp_allocator), "_", "", context.temp_allocator)
		return strings.contains(n, needle)
	}
	// (^|_|[A-Z])q s?([A-Z]|_|$) on the lowercased name
	word_match :: proc(name, q: string) -> bool {
		for i := 0; i + len(q) <= len(name); i += 1 {
			if name[i:i + len(q)] != q || (i > 0 && name[i - 1] != '_') do continue
			j := i + len(q)
			if j == len(name) || name[j] == '_' do return true
			if name[j] == 's' && (j + 1 == len(name) || name[j + 1] == '_') do return true
		}
		return false
	}
	score_of :: proc(name0, q: string, frec: f64) -> f64 {
		n := strings.to_lower(name0, context.temp_allocator)
		d: f64 = 1
		if n == q do d += 4
		if word_match(n, q) do d += 2
		if strings.has_prefix(n, q) do d += 1
		return d * max(1, frec / 100)
	}
	ql := strings.to_lower(raw, context.temp_allocator)
	fm := pk.mode == .Reaction ? frecency.reaction : frecency.emoji
	unlocked := make([dynamic]Hit, context.temp_allocator)
	locked := make([dynamic]Hit, context.temp_allocator)
	for gid in emoji_guilds() {
		g := dc.guild_get(store(), gid)
		if g == nil do continue
		for e in g.emojis {
			if !matches(e.name, needle) do continue
			it := custom_item(e, here, nitro)
			h := Hit{it, score_of(e.name, ql, frec_score_of(fm, frec_key(it)))}
			if it.locked do append(&locked, h)
			else do append(&unlocked, h)
		}
	}
	for i in 0 ..< emoji_db.parents {
		hit := false
		for n in emoji_db.emojis[i].names do if matches(n, needle) {hit = true; break}
		if !hit do continue
		it := uni_item(i)
		append(&unlocked, Hit{it, score_of(it.name, ql, frec_score_of(fm, it.name))})
	}
	order :: proc(a, b: Hit) -> bool {
		if a.score != b.score do return a.score > b.score
		return a.e.name < b.e.name
	}
	slice.stable_sort_by(unlocked[:], order)
	slice.stable_sort_by(locked[:], order)
	out := make([dynamic]Pk_Emoji, 0, len(unlocked) + len(locked), context.temp_allocator)
	for h in unlocked do append(&out, h.e)
	for h in locked do append(&out, h.e)
	return out[:]
}

@(private = "file")
cols_for :: proc(w: f32) -> int {return max(1, int((w - EM_GRID_PAD_L) / EM_CELL))}

// Lay sections out in content space; returns total height.
@(private = "file")
layout_sections :: proc(secs: []Em_Section, cols: int) -> f32 {
	y: f32 = EM_GRID_PAD_TOP
	for &sc in secs {
		sc.y = y
		if sc.kind != .Search do y += EM_HEADER_H
		sc.rows = (len(sc.items) + cols - 1) / cols
		if ev.collapsed[sc.key] && sc.kind != .Search do sc.rows = 0
		y += f32(sc.rows) * EM_CELL
	}
	return y + EM_GRID_PAD_BOTTOM
}

@(private = "file")
item_y :: proc(sc: ^Em_Section, idx, cols: int) -> f32 {
	base := sc.y + (sc.kind != .Search ? EM_HEADER_H : 0)
	return base + f32(idx / cols) * EM_CELL
}

emoji_picker_body :: proc(r: ui.Rect) {
	emoji_db_load()
	body := row("emoji_body")
	body.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	body.cross_align = .Start
	secs := build_sections()
	inspector_h: f32 = EM_INSPECTOR_H
	grid_rect := ui.Rect{r.x0 + EM_NAV_W + 1, r.y0, r.x1, r.y1 - inspector_h}
	cols := cols_for(grid_rect.x1 - grid_rect.x0 - PK_SCROLLBAR_W)
	content_h := layout_sections(secs, cols)
	emoji_keyboard(secs, cols)
	pk_scroll_update(&ev.scroll, grid_rect, content_h)
	nav_secs := secs
	searching := len(secs) > 0 && secs[0].kind == .Search
	if searching {
		nav_secs = build_sections(true)
		layout_sections(nav_secs, cols)
	}
	if ui.parent(body) {
		category_nav(nav_secs, r.y1 - r.y0, searching)
		col := ui.box("emoji_main")
		col.semantic_size = {.X = ui.fill(), .Y = ui.pct(1)}
		col.layout_axis = .Y
		if ui.parent(col) {
			emoji_grid(secs, cols, grid_rect)
			emoji_inspector(secs)
		}
	}
	if ev.tone_open do skin_tone_menu()
}

@(private = "file")
category_nav :: proc(secs: []Em_Section, h: f32, searching: bool) {
	nav := ui.box("emoji_nav", {.Draw_Background, .Clip, .Scroll_Y})
	nav.semantic_size = {.X = ui.px(EM_NAV_W), .Y = ui.px(h)}
	nav.style.bg = T("--background-base-lower")
	nav.layout_axis = .Y
	ui.signal(nav)
	// border between nav and grid
	if ui.parent(nav) {
		line := ui.box("navline", {.Draw_Background, .Floating_X, .Floating_Y})
		line.semantic_size = {.X = ui.px(1), .Y = ui.px(max(h, nav.content_size.y))}
		line.fixed_pos = {EM_NAV_W - 1, 0}
		line.style.bg = T("--border-subtle")
		spacer(.Y, 4)
		cur := searching ? -1 : current_section(secs)
		prev_kind := Em_Section_Kind.Favorites
		for &sc, i in secs {
			if sc.kind == .Search do continue
			if i > 0 && sc.kind == .Unicode && prev_kind != .Unicode {
				sep := ui.box(fmt.tprintf("sep%d", i))
				sep.semantic_size = {.X = ui.pct(1), .Y = ui.px(EM_NAV_SEP_H)}
				if ui.parent(sep) {
					l := ui.box("l", {.Draw_Background, .Floating_X, .Floating_Y})
					l.semantic_size = {.X = ui.px(24), .Y = ui.px(1)}
					l.fixed_pos = {(EM_NAV_W - 24) / 2, 4}
					l.style.bg = T("--border-subtle")
				}
			}
			prev_kind = sc.kind
			if ui.id_scope(sc.key) {
				slot := ui.box("slot", {.Clickable})
				slot.semantic_size = {.X = ui.pct(1), .Y = ui.px(EM_NAV_SLOT)}
				slot.layout_axis = .X
				slot.cross_align = .Center
				sig := ui.signal(slot)
				active := cur == i
				if ui.parent(slot) {
					if sc.kind == .Guild {
						spacer(.X, (EM_NAV_W - EM_NAV_GUILD) / 2)
						gi := ui.box("gicon", {.Draw_Background, .Draw_Text})
						gi.semantic_size = {.X = ui.px(EM_NAV_GUILD), .Y = ui.px(EM_NAV_GUILD)}
						gi.style.radius = active || sig.hovering ? 10 : EM_NAV_GUILD / 2
						gi.style.bg = T("--background-mod-subtle")
						gi.style.text_align = .Center
						gi.style.font = F(.Medium)
						gi.style.font_size = 11
						gi.style.text_color = T("--text-default")
						if g := dc.guild_get(store(), sc.guild); g != nil {
							if g.icon != "" {
								set_remote_image(gi, dc.guild_icon_url(sc.guild, g.icon, 64))
							} else {
								gi.text = guild_initials(g.name)
							}
						}
					} else {
						spacer(.X, (EM_NAV_W - EM_NAV_ICON) / 2)
						c := active ? T("--interactive-icon-active") : (sig.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
						icon("ic", sc.icon, EM_NAV_ICON, c)
					}
				}
				if sig.clicked {
					if searching do ui.editor_set_text(&pk.search[.Emoji], "")
					ev.collapsed[sc.key] = false
					ev.scroll.target = sc.y
				}
			}
		}
		spacer(.Y, 8)
	}
}

// Section whose span contains the scroll top.
@(private = "file")
current_section :: proc(secs: []Em_Section) -> int {
	cur := 0
	for sc, i in secs do if sc.y <= ev.scroll.y + 1 do cur = i
	return cur
}

@(private = "file")
section_header :: proc(sc: ^Em_Section, id: string, y: f32, w: f32) {
	h := row(id, {.Floating_X, .Floating_Y, .Clickable, .Draw_Background})
	h.semantic_size = {.X = ui.px(w), .Y = ui.px(EM_HEADER_H)}
	h.fixed_pos = {0, y}
	h.style.bg = T("--background-surface-high")
	sig := ui.signal(h)
	collapsed := ev.collapsed[sc.key]
	c := sig.hovering ? T("--interactive-text-hover") : T("--text-muted")
	if ui.parent(h) {
		spacer(.X, EM_GRID_PAD_L)
		if sc.kind == .Guild {
			gi := ui.box("gi", {.Draw_Background})
			gi.semantic_size = {.X = ui.px(EM_HEADER_ICON), .Y = ui.px(EM_HEADER_ICON)}
			gi.style.radius = 4
			gi.style.bg = T("--background-mod-subtle")
			if g := dc.guild_get(store(), sc.guild); g != nil && g.icon != "" do set_remote_image(gi, dc.guild_icon_url(sc.guild, g.icon, 32))
		} else {
			icon("hi", sc.icon, EM_HEADER_ICON, c)
		}
		spacer(.X, 8)
		t := label(strings.to_upper(sc.title, context.temp_allocator), .Semibold, EM_HEADER_FONT, c, 16)
		t.flags += {.Clip}
		spacer(.X, 4)
		icon("chev", collapsed ? "chevron-small-right" : "chevron-small-down", 16, c)
		filler(.X)
	}
	if sig.clicked do ev.collapsed[sc.key] = !collapsed
}

@(private = "file")
emoji_grid :: proc(secs: []Em_Section, cols: int, view: ui.Rect) {
	w := view.x1 - view.x0
	vh := view.y1 - view.y0
	list := ui.box("emoji_grid", {.Clip})
	list.semantic_size = {.X = ui.pct(1), .Y = ui.px(vh)}
	top := ev.scroll.y
	moved := app.ui.mouse != ev.last_mouse
	ev.last_mouse = app.ui.mouse
	if moved do ev.keyboard = false
	if ui.parent(list) {
		for &sc, si in secs {
			body_y := sc.y + (sc.kind != .Search ? EM_HEADER_H : 0)
			end_y := body_y + f32(sc.rows) * EM_CELL
			if end_y < top - EM_CELL || sc.y > top + vh + EM_CELL do continue
			if ui.id_scope(sc.key) {
				if sc.kind != .Search do section_header(&sc, "hdr", sc.y - top, w)
				r0 := max(0, int((top - body_y) / EM_CELL) - 1)
				r1 := min(sc.rows, int((top + vh - body_y) / EM_CELL) + 2)
				for rr in r0 ..< r1 {
					for cc in 0 ..< cols {
						i := rr * cols + cc
						if i >= len(sc.items) do break
						it := sc.items[i]
						if ui.id_scope(u64(i)) {
							cell := ui.box("cell", {.Clickable, .Floating_X, .Floating_Y, .Draw_Background})
							cell.semantic_size = {.X = ui.px(EM_CELL), .Y = ui.px(EM_CELL)}
							cell.fixed_pos = {EM_GRID_PAD_L + f32(cc) * EM_CELL, body_y + f32(rr) * EM_CELL - top}
							cell.style.radius = EM_CELL_RADIUS
							sig := ui.signal(cell)
							if sig.hovering && (moved || !ev.keyboard) do ev.inspected = {si, i}
							inspected := ev.inspected.sec == si && ev.inspected.idx == i
							if inspected do cell.style.bg = T("--background-mod-normal")
							if ui.parent(cell) {
								e := pk_emoji_box("e", it, EM_SIZE, inspected && sig.hovering)
								e.flags += {.Floating_X, .Floating_Y}
								e.fixed_pos = {(EM_CELL - EM_SIZE) / 2, (EM_CELL - EM_SIZE) / 2}
								if it.locked {
									e.opacity = 0.3
									lk := ui.box("lock", {.Floating_X, .Floating_Y})
									lk.semantic_size = {.X = ui.px(14), .Y = ui.px(14)}
									lk.fixed_pos = {EM_CELL - 18, EM_CELL - 18}
									set_icon(lk, "lock", T("--text-default"))
								}
							}
							if sig.clicked {
								ev.inspected = {si, i}
								emoji_select(it, .Shift in app.ui_mods)
							}
						}
					}
				}
			}
		}
		// sticky header: the section under the scroll top, pushed up by the next header
		if len(secs) > 0 && secs[0].kind != .Search {
			cur := current_section(secs)
			y: f32 = 0
			if cur + 1 < len(secs) {
				nxt := secs[cur + 1].y - top
				if nxt < EM_HEADER_H do y = nxt - EM_HEADER_H
			}
			if ui.id_scope(0xffff) do section_header(&secs[cur], "sticky", y, w)
		}
		if len(secs) == 1 && secs[0].kind == .Search && len(secs[0].items) == 0 {
			msg := ui.box("empty", {.Floating_X, .Floating_Y})
			msg.semantic_size = {.X = ui.px(w), .Y = ui.px(vh)}
			msg.layout_axis = .Y
			msg.cross_align = .Center
			if ui.parent(msg) {
				spacer(.Y, vh / 2 - 40)
				label("No emoji found", .Semibold, 16, T("--text-strong"), 20)
				spacer(.Y, 4)
				label("Try searching for something else", .Normal, 14, T("--text-muted"), 18)
			}
		}
		pk_scrollbar(&ev.scroll, w - PK_SCROLLBAR_W - 2)
	}
}

// Arrow keys move the inspected emoji through the grid; Enter selects.
@(private = "file")
emoji_keyboard :: proc(secs: []Em_Section, cols: int) {
	if len(pk.keys) == 0 || pk.tab != .Emoji || pk.closing do return
	// item rows in order: (section, first index)
	Row :: struct {
		sec, start, count: int,
	}
	rows := make([dynamic]Row, context.temp_allocator)
	for sc, si in secs {
		for rr in 0 ..< sc.rows do append(&rows, Row{si, rr * cols, min(cols, len(sc.items) - rr * cols)})
	}
	if len(rows) == 0 do return
	cur_row, cur_col := -1, 0
	if ev.inspected.sec >= 0 {
		for rw, ri in rows {
			if rw.sec == ev.inspected.sec && ev.inspected.idx >= rw.start && ev.inspected.idx < rw.start + rw.count {
				cur_row = ri
				cur_col = ev.inspected.idx - rw.start
			}
		}
	}
	for e in pk.keys {
		#partial switch e.key {
		case .Enter:
			if cur_row < 0 {
				cur_row = 0
				cur_col = 0
			}
			rw := rows[cur_row]
			emoji_select(secs[rw.sec].items[rw.start + min(cur_col, rw.count - 1)], .Shift in e.mods)
			continue
		case .Left:
			if cur_row < 0 {cur_row = 0; cur_col = 0} else if cur_col > 0 {cur_col -= 1} else if cur_row > 0 {cur_row -= 1; cur_col = rows[cur_row].count - 1}
		case .Right:
			if cur_row < 0 {cur_row = 0; cur_col = 0} else if cur_col + 1 < rows[cur_row].count {cur_col += 1} else if cur_row + 1 < len(rows) {cur_row += 1; cur_col = 0}
		case .Up:
			if cur_row < 0 {cur_row = 0} else if cur_row > 0 do cur_row -= 1
		case .Down:
			if cur_row < 0 {cur_row = 0} else if cur_row + 1 < len(rows) do cur_row += 1
		case .Page_Up:
			cur_row = max(0, cur_row - 6)
		case .Page_Down:
			cur_row = min(len(rows) - 1, max(cur_row, 0) + 6)
		case:
			continue
		}
		cur_col = min(cur_col, rows[cur_row].count - 1)
		rw := rows[cur_row]
		ev.inspected = {rw.sec, rw.start + cur_col}
		ev.keyboard = true
		sc := &secs[rw.sec]
		y := item_y(sc, ev.inspected.idx, cols)
		pk_scroll_reveal(&ev.scroll, y, y + EM_CELL, sc.kind != .Search ? EM_HEADER_H : 0)
	}
}

@(private = "file")
emoji_inspector :: proc(secs: []Em_Section) {
	bar := row("inspector", {.Draw_Background})
	bar.semantic_size = {.X = ui.pct(1), .Y = ui.px(EM_INSPECTOR_H)}
	bar.style.bg = T("--background-base-lower")
	it: Pk_Emoji
	has := false
	if ev.inspected.sec >= 0 && ev.inspected.sec < len(secs) && ev.inspected.idx < len(secs[ev.inspected.sec].items) {
		it = secs[ev.inspected.sec].items[ev.inspected.idx]
		has = true
	} else if len(secs) > 0 && len(secs[0].items) > 0 {
		it = secs[0].items[0]
		has = true
	}
	if ui.parent(bar) {
		spacer(.X, 16)
		if has {
			pk_emoji_box("ie", it, EM_INSPECTOR_EMOJI, true)
			spacer(.X, 8)
			col := ui.box("names")
			col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
			col.layout_axis = .Y
			if ui.parent(col) {
				n := label(fmt.tprintf(":%s:", emoji_display_name(it)), .Semibold, 16, T("--text-strong"), 20)
				n.flags += {.Clip}
				if it.uni < 0 {
					gname := ""
					if g := dc.guild_get(store(), it.guild); g != nil do gname = g.name
					label(fmt.tprintf("from %s", gname), .Normal, 12, T("--text-muted"), 16)
				}
			}
		}
	}
}

@(private = "file")
emoji_display_name :: proc(it: Pk_Emoji) -> string {
	if it.uni >= 0 {
		t := emoji_toned(int(it.uni), frecency.skin_tone)
		return emoji_db.emojis[t].names[0]
	}
	return it.name
}

// The emoji glyph: spritesheet cell for unicode (text fallback while the sheet
// loads or offline), CDN image for custom (animated on hover).
pk_emoji_box :: proc(id: string, it: Pk_Emoji, size: f32, hovered: bool) -> ^ui.Box {
	if it.uni < 0 {
		b := ui.box(id)
		b.semantic_size = {.X = ui.px(size), .Y = ui.px(size)}
		set_remote_image(b, dc.custom_emoji_url(it.id, it.animated && hovered, 48))
		return b
	}
	idx := int(it.uni)
	tone := frecency.skin_tone
	e := &emoji_db.emojis[idx]
	if e.sprite >= 0 {
		url := sprite_url(len(e.children) > 0, tone)
		im := image_get(url)
		if im != nil && im.state == .Ready {
			b := ui.box(id)
			b.semantic_size = {.X = ui.px(size), .Y = ui.px(size)}
			d := new(Sprite_Draw, context.temp_allocator)
			d^ = {url = url, index = e.sprite, per_row = len(e.children) > 0 ? SPRITE_DIVERSITY_PER_ROW : SPRITE_PER_ROW}
			b.custom_draw = sprite_draw
			b.custom_user = d
			return b
		}
	}
	t := emoji_toned(idx, tone)
	b := label(emoji_db.emojis[t].surr, .Normal, size * 0.8, {1, 1, 1, 1}, size)
	b.semantic_size = {.X = ui.px(size), .Y = ui.px(size)}
	b.style.text_align = .Center
	return b
}

@(private = "file")
sprite_url :: proc(diversity: bool, tone: int) -> string {
	si := EM_SPRITE_PX == 48 ? 1 : 0
	if diversity do return SPRITE_TONES[si][clamp(tone, 0, 5)]
	return SPRITE_EMOJI[si]
}

@(private = "file")
Sprite_Draw :: struct {
	url:     string,
	index:   int,
	per_row: int,
}

@(private = "file")
sprite_draw :: proc(b: ^ui.Box, user: rawptr) {
	d := (^Sprite_Draw)(user)
	im := image_get(d.url)
	tex := image_texture(im)
	if tex == 0 do return
	cell := f32(im.size.x) / f32(d.per_row)
	cx := f32(d.index % d.per_row) * cell
	cy := f32(d.index / d.per_row) * cell
	c := gfx.Color{1, 1, 1, b.opacity}
	gfx.push_rect({dst = gfx.Rect(b.rect), tex = tex, src = {cx, cy, cx + cell, cy + cell}, colors = {c, c, c, c}})
}

// Insert into the composer, or react. Shift keeps the picker open.
@(private = "file")
emoji_select :: proc(it: Pk_Emoji, keep_open: bool) {
	if it.locked do return
	text: string
	name := it.name
	if it.uni >= 0 {
		t := emoji_toned(int(it.uni), frecency.skin_tone)
		text = emoji_db.emojis[t].surr
		name = text
	} else {
		text = fmt.tprintf("<%s:%s:%d>", it.animated ? "a" : "", it.name, u64(it.id))
	}
	key := frec_key(it)
	if pk.mode == .Reaction {
		frec_use(&frecency.reaction, key)
		if app.client != nil {
			m := find_message(pk.message)
			if m != nil do dc.add_reaction(app.client, m.channel_id, m.id, name, it.id)
		}
	} else {
		frec_use(&frecency.emoji, key)
		cs := chat_state(pk.channel)
		ui.editor_insert(&cs.editor, text)
	}
	if !keep_open do picker_close()
}

skin_tone_button :: proc() {
	b := ui.box("tone", {.Clickable, .Draw_Background, .Hot_Animation})
	b.semantic_size = {.X = ui.px(EM_TONE_BUTTON), .Y = ui.px(EM_TONE_BUTTON)}
	b.style.radius = 8
	b.style.bg_hot = T("--background-mod-subtle")
	b.layout_axis = .X
	b.cross_align = .Center
	sig := ui.signal(b)
	if ui.parent(b) {
		spacer(.X, 4)
		tone_glyph("g", frecency.skin_tone, 24)
	}
	if sig.clicked do ev.tone_open = !ev.tone_open
}

@(private = "file")
tone_glyph :: proc(id: string, tone: int, size: f32) {
	idx, ok := emoji_db.by_name["raised_hand"]
	if ok {
		pk_emoji_box(id, Pk_Emoji{uni = i32(idx)}, size, false)
		return
	}
	l := label(TONE_SURROGATES[clamp(tone, 0, 5)], .Normal, size * 0.8, {1, 1, 1, 1}, size)
	l.semantic_size = {.X = ui.px(size), .Y = ui.px(size)}
}

// Vertical list of the six tones, dropping down over the search row's right edge.
@(private = "file")
skin_tone_menu :: proc() {
	r := pk.rect
	x := r.x1 - PK_HEADER_PAD_X - EM_TONE_BUTTON
	y := r.y0 + picker_header_h() - PK_HEADER_PAD_BOTTOM - PK_SEARCH_H
	m := ui.box("tonemenu", {.Floating_X, .Floating_Y, .Draw_Background, .Draw_Border, .Draw_Shadow, .Clickable})
	m.semantic_size = {.X = ui.px(EM_TONE_BUTTON), .Y = ui.px(EM_TONE_ITEM * 6)}
	m.fixed_pos = {x - r.x0, y - r.y0 - picker_header_h()}
	m.style.bg = T("--background-surface-higher")
	m.style.border_color = T("--border-subtle")
	m.style.border = 1
	m.style.radius = 8
	m.style.shadow_color = {0, 0, 0, 0.24}
	m.style.shadow_blur = 8
	m.layout_axis = .Y
	ui.signal(m)
	saved := frecency.skin_tone
	if ui.parent(m) {
		order := [6]int{saved, 0, 1, 2, 3, 4}
		// current first, then the rest in order
		n := 1
		for t in 0 ..< 6 do if t != saved {order[n] = t; n += 1}
		for t in order {
			it := ui.box(fmt.tprintf("t%d", t), {.Clickable, .Draw_Background, .Hot_Animation})
			it.semantic_size = {.X = ui.pct(1), .Y = ui.px(EM_TONE_ITEM)}
			it.style.radius = 6
			it.style.bg_hot = T("--background-mod-normal")
			it.layout_axis = .X
			it.cross_align = .Center
			sig := ui.signal(it)
			frecency.skin_tone = t
			if ui.parent(it) {
				spacer(.X, 4)
				tone_glyph("g", t, 24)
			}
			frecency.skin_tone = saved
			if sig.clicked {
				saved = t
				ev.tone_open = false
				frecency_save()
			}
		}
	}
	frecency.skin_tone = saved
}
