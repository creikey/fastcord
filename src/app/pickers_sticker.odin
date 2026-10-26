package app

import "core:fmt"
import "core:slice"
import "core:strings"
import dc "fc:discord"
import "fc:gfx"
import "fc:ui"

// Sticker picker: nav (frequent, favorites, guilds, standard packs), sticky
// headers, 4-column grid, inspector, search by name. PNG/APNG/GIF stickers go
// through the image pipeline (animating on hover); Lottie ones through src/lottie.

ST_NAV_W :: 48
ST_GRID_PAD_L :: 8
ST_CELL_MIN :: 104
ST_PAD :: 4 // inside a cell
ST_HEADER_H :: 32
ST_INSPECTOR_H :: 48
ST_FREQUENT_MAX :: 8
ST_URL_SIZE :: 160

Pk_Sticker :: struct {
	id:          dc.Snowflake,
	name:        string,
	format_type: int,
	guild:       dc.Snowflake,
	pack:        dc.Snowflake,
	locked:      bool,
}

Sticker_Pack :: struct {
	id:       dc.Snowflake,
	name:     string,
	cover:    dc.Snowflake,
	stickers: [dynamic]Pk_Sticker,
}

St_Section :: struct {
	key:   u64,
	title: string,
	icon:  string,
	guild: dc.Snowflake,
	cover: Pk_Sticker,
	items: []Pk_Sticker,
	y:     f32,
	rows:  int,
	flat:  bool, // search results: no header
}

Sticker_View :: struct {
	requested: bool,
	packs:     [dynamic]Sticker_Pack,
	scroll:    Pk_Scroll,
	inspected: [2]int, // section, index; -1 = none
	collapsed: map[u64]bool,
}

sv: Sticker_View

sticker_picker_on_show :: proc() {
	sv.inspected = {-1, 0}
	if sv.requested || app.client == nil do return
	sv.requested = true
	dc.sticker_packs_fetch(app.client)
}

sticker_picker_query_changed :: proc() {
	sv.scroll = {}
	sv.inspected = {-1, 0}
}

sticker_packs_receive :: proc(r: ^dc.Expr_Result) {
	if !r.ok do return
	m := dc.vmap(r.body)
	for &p in sv.packs {
		delete(p.name)
		for s in p.stickers do delete(s.name)
		delete(p.stickers)
	}
	clear(&sv.packs)
	for pv in dc.flist(m, "sticker_packs") {
		pm := dc.vmap(pv)
		p := Sticker_Pack{id = dc.fsnow(pm, "id"), name = strings.clone(dc.fstr(pm, "name")), cover = dc.fsnow(pm, "cover_sticker_id")}
		for stv in dc.flist(pm, "stickers") {
			s := dc.vmap(stv)
			append(&p.stickers, Pk_Sticker{id = dc.fsnow(s, "id"), name = strings.clone(dc.fstr(s, "name")), format_type = int(dc.fint(s, "format_type")), pack = p.id})
		}
		append(&sv.packs, p)
	}
}

@(private = "file")
build_sections :: proc(ignore_query := false) -> []St_Section {
	s := store()
	here: dc.Snowflake
	if c := dc.channel_get(s, pk.channel); c != nil do here = c.guild_id
	nitro := false
	if u := dc.user_get(s, s.me); u != nil do nitro = u.premium_type > 0
	all := make(map[dc.Snowflake]Pk_Sticker, allocator = context.temp_allocator)
	guilds := make([dynamic]dc.Snowflake, context.temp_allocator)
	if here != 0 do append(&guilds, here)
	for gid in guild_order() do if gid != here do append(&guilds, gid)
	guild_items :: proc(g: ^dc.Guild, here: dc.Snowflake, nitro: bool) -> []Pk_Sticker {
		out := make([]Pk_Sticker, len(g.stickers), context.temp_allocator)
		for st, i in g.stickers do out[i] = Pk_Sticker{id = st.id, name = st.name, format_type = st.format_type, guild = g.id, locked = !nitro && g.id != here}
		return out
	}
	for gid in guilds {
		if g := dc.guild_get(s, gid); g != nil do for it in guild_items(g, here, nitro) do all[it.id] = it
	}
	for p in sv.packs do for it in p.stickers do all[it.id] = it

	secs := make([dynamic]St_Section, context.temp_allocator)
	q := ignore_query ? "" : pk_query(.Sticker)
	if q != "" {
		hits := make([dynamic]Pk_Sticker, context.temp_allocator)
		for gid in guilds {
			if g := dc.guild_get(s, gid); g != nil do for it in guild_items(g, here, nitro) do if strings.contains(strings.to_lower(it.name, context.temp_allocator), q) do append(&hits, it)
		}
		for p in sv.packs do for it in p.stickers do if strings.contains(strings.to_lower(it.name, context.temp_allocator), q) do append(&hits, it)
		append(&secs, St_Section{key = 1, items = hits[:], flat = true})
		return secs[:]
	}
	if len(frecency.favorite_stickers) > 0 {
		items := make([dynamic]Pk_Sticker, context.temp_allocator)
		for id in frecency.favorite_stickers do if it, ok := all[id]; ok do append(&items, it)
		if len(items) > 0 do append(&secs, St_Section{key = 2, title = "Favorites", icon = "star", items = items[:]})
	}
	frequent: {
		items := make([dynamic]Pk_Sticker, context.temp_allocator)
		for k in frec_top(frecency.sticker, ST_FREQUENT_MAX) {
			id := dc.Snowflake(0)
			for ch in k do if ch >= '0' && ch <= '9' do id = id * 10 + dc.Snowflake(ch - '0')
			if it, ok := all[id]; ok do append(&items, it)
		}
		if len(items) > 0 do append(&secs, St_Section{key = 3, title = "Frequently Used", icon = "clock", items = items[:]})
	}
	for gid in guilds {
		g := dc.guild_get(s, gid)
		if g == nil || len(g.stickers) == 0 do continue
		append(&secs, St_Section{key = u64(gid), title = g.name, guild = gid, items = guild_items(g, here, nitro)})
	}
	for p in sv.packs {
		cover := len(p.stickers) > 0 ? p.stickers[0] : Pk_Sticker{}
		for it in p.stickers do if it.id == p.cover do cover = it
		append(&secs, St_Section{key = u64(p.id), title = p.name, cover = cover, items = p.stickers[:]})
	}
	return secs[:]
}

sticker_picker_body :: proc(r: ui.Rect) {
	secs := build_sections()
	grid := ui.Rect{r.x0 + ST_NAV_W + 1, r.y0, r.x1, r.y1 - ST_INSPECTOR_H}
	inner := grid.x1 - grid.x0 - ST_GRID_PAD_L - PK_SCROLLBAR_W - 4
	cols := max(1, int(inner / ST_CELL_MIN))
	cell := pk_round(inner / f32(cols))
	content_h := st_layout(secs, cols, cell)
	nav_secs := secs
	searching := len(secs) > 0 && secs[0].flat
	if searching {
		nav_secs = build_sections(true)
		st_layout(nav_secs, cols, cell)
	}
	pk_scroll_update(&sv.scroll, grid, content_h)
	body := row("st_body")
	body.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	body.cross_align = .Start
	if ui.parent(body) {
		sticker_nav(nav_secs, r.y1 - r.y0, searching)
		col := ui.box("st_main")
		col.semantic_size = {.X = ui.fill(), .Y = ui.pct(1)}
		col.layout_axis = .Y
		if ui.parent(col) {
			sticker_grid(secs, cols, cell, grid)
			sticker_inspector(secs)
		}
	}
}

@(private = "file")
st_layout :: proc(secs: []St_Section, cols: int, cell: f32) -> f32 {
	y: f32 = 0
	for &sc in secs {
		sc.y = y
		if !sc.flat do y += ST_HEADER_H
		sc.rows = (len(sc.items) + cols - 1) / cols
		if sv.collapsed[sc.key] && !sc.flat do sc.rows = 0
		y += f32(sc.rows) * cell
	}
	return y + 8
}

@(private = "file")
cur_section :: proc(secs: []St_Section) -> int {
	cur := 0
	for sc, i in secs do if sc.y <= sv.scroll.y + 1 do cur = i
	return cur
}

@(private = "file")
sticker_nav :: proc(secs: []St_Section, h: f32, searching: bool) {
	nav := ui.box("st_nav", {.Draw_Background, .Clip, .Scroll_Y})
	nav.semantic_size = {.X = ui.px(ST_NAV_W), .Y = ui.px(h)}
	nav.style.bg = T("--background-base-lower")
	nav.layout_axis = .Y
	ui.signal(nav)
	if ui.parent(nav) {
		line := ui.box("navline", {.Draw_Background, .Floating_X, .Floating_Y})
		line.semantic_size = {.X = ui.px(1), .Y = ui.px(max(h, nav.content_size.y))}
		line.fixed_pos = {ST_NAV_W - 1, 0}
		line.style.bg = T("--border-subtle")
		spacer(.Y, 4)
		cur := searching ? -1 : cur_section(secs)
		for &sc, i in secs {
			if sc.flat do continue
			if ui.id_scope(sc.key) {
				slot := ui.box("slot", {.Clickable})
				slot.semantic_size = {.X = ui.pct(1), .Y = ui.px(EM_NAV_SLOT)}
				slot.layout_axis = .X
				slot.cross_align = .Center
				sig := ui.signal(slot)
				active := cur == i
				if ui.parent(slot) {
					spacer(.X, (ST_NAV_W - EM_NAV_GUILD) / 2)
					switch {
					case sc.guild != 0:
						gi := ui.box("gicon", {.Draw_Background, .Draw_Text})
						gi.semantic_size = {.X = ui.px(EM_NAV_GUILD), .Y = ui.px(EM_NAV_GUILD)}
						gi.style.radius = active || sig.hovering ? 10 : EM_NAV_GUILD / 2
						gi.style.bg = T("--background-mod-subtle")
						gi.style.text_align = .Center
						gi.style.font = F(.Medium)
						gi.style.font_size = 11
						gi.style.text_color = T("--text-default")
						if g := dc.guild_get(store(), sc.guild); g != nil {
							if g.icon != "" do set_remote_image(gi, dc.guild_icon_url(sc.guild, g.icon, 64))
							else do gi.text = guild_initials(g.name)
						}
					case sc.cover.id != 0:
						sticker_box("cover", sc.cover, EM_NAV_GUILD, false)
					case:
						spacer(.X, (EM_NAV_GUILD - EM_NAV_ICON) / 2)
						icon("ic", sc.icon, EM_NAV_ICON, active ? T("--interactive-icon-active") : (sig.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default")))
					}
				}
				if sig.clicked {
					if searching do ui.editor_set_text(&pk.search[.Sticker], "")
					sv.collapsed[sc.key] = false
					sv.scroll.target = sc.y
				}
			}
		}
	}
}

@(private = "file")
st_header :: proc(sc: ^St_Section, id: string, y, w: f32) {
	h := row(id, {.Floating_X, .Floating_Y, .Clickable, .Draw_Background})
	h.semantic_size = {.X = ui.px(w), .Y = ui.px(ST_HEADER_H)}
	h.fixed_pos = {0, y}
	h.style.bg = T("--background-surface-high")
	sig := ui.signal(h)
	collapsed := sv.collapsed[sc.key]
	c := sig.hovering ? T("--interactive-text-hover") : T("--text-muted")
	if ui.parent(h) {
		spacer(.X, ST_GRID_PAD_L)
		if sc.icon != "" {
			icon("hi", sc.icon, EM_HEADER_ICON, c)
			spacer(.X, 8)
		}
		t := label(strings.to_upper(sc.title, context.temp_allocator), .Semibold, EM_HEADER_FONT, c, 16)
		t.flags += {.Clip}
		spacer(.X, 4)
		icon("chev", collapsed ? "chevron-small-right" : "chevron-small-down", 16, c)
		filler(.X)
	}
	if sig.clicked do sv.collapsed[sc.key] = !collapsed
}

@(private = "file")
sticker_grid :: proc(secs: []St_Section, cols: int, cell: f32, view: ui.Rect) {
	w := view.x1 - view.x0
	vh := view.y1 - view.y0
	list := ui.box("st_grid", {.Clip})
	list.semantic_size = {.X = ui.pct(1), .Y = ui.px(vh)}
	top := sv.scroll.y
	if ui.parent(list) {
		for &sc, si in secs {
			body_y := sc.y + (sc.flat ? 0 : ST_HEADER_H)
			if body_y + f32(sc.rows) * cell < top - cell || sc.y > top + vh do continue
			if ui.id_scope(sc.key) {
				if !sc.flat do st_header(&sc, "hdr", sc.y - top, w)
				for it, i in sc.items {
					rr, cc := i / cols, i % cols
					if rr >= sc.rows do break
					y := body_y + f32(rr) * cell - top
					if y + cell < 0 || y > vh do continue
					if ui.id_scope(u64(i)) {
						b := ui.box("cell", {.Clickable, .Floating_X, .Floating_Y, .Draw_Background})
						b.semantic_size = {.X = ui.px(cell), .Y = ui.px(cell)}
						b.fixed_pos = {ST_GRID_PAD_L + f32(cc) * cell, y}
						b.style.radius = 8
						sig := ui.signal(b)
						if sig.hovering do sv.inspected = {si, i}
						if sig.hovering do b.style.bg = T("--background-mod-normal")
						if ui.parent(b) {
							sb := sticker_box("st", it, cell - 2 * ST_PAD, sig.hovering)
							sb.flags += {.Floating_X, .Floating_Y}
							sb.fixed_pos = {ST_PAD, ST_PAD}
							if it.locked do sb.opacity = 0.3
						}
						if sig.clicked do sticker_select(it, .Shift in app.ui_mods)
					}
				}
			}
		}
		if len(secs) > 0 && !secs[0].flat {
			cur := cur_section(secs)
			y: f32 = 0
			if cur + 1 < len(secs) {
				nxt := secs[cur + 1].y - top
				if nxt < ST_HEADER_H do y = nxt - ST_HEADER_H
			}
			if ui.id_scope(0xffff) do st_header(&secs[cur], "sticky", y, w)
		}
		if len(secs) == 0 || (secs[0].flat && len(secs[0].items) == 0) {
			msg := ui.box("empty", {.Floating_X, .Floating_Y})
			msg.semantic_size = {.X = ui.px(w), .Y = ui.px(vh)}
			msg.layout_axis = .Y
			msg.cross_align = .Center
			if ui.parent(msg) {
				spacer(.Y, vh / 2 - 30)
				label(len(secs) == 0 ? "No stickers yet" : "No stickers found", .Semibold, 16, T("--text-strong"), 20)
			}
		}
		pk_scrollbar(&sv.scroll, w - PK_SCROLLBAR_W - 2)
	}
}

@(private = "file")
sticker_inspector :: proc(secs: []St_Section) {
	bar := row("inspector", {.Draw_Background})
	bar.semantic_size = {.X = ui.pct(1), .Y = ui.px(ST_INSPECTOR_H)}
	bar.style.bg = T("--background-base-lower")
	si, ii := sv.inspected[0], sv.inspected[1]
	if si < 0 || si >= len(secs) || ii >= len(secs[si].items) do return
	it := secs[si].items[ii]
	if ui.parent(bar) {
		spacer(.X, 16)
		sticker_box("is", it, 28, false)
		spacer(.X, 8)
		col := ui.box("names")
		col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
		col.layout_axis = .Y
		if ui.parent(col) {
			label(it.name, .Semibold, 16, T("--text-strong"), 20)
			from := ""
			if g := dc.guild_get(store(), it.guild); g != nil do from = g.name
			for p in sv.packs do if p.id == it.pack do from = p.name
			if from != "" do label(fmt.tprintf("from %s", from), .Normal, 12, T("--text-muted"), 16)
		}
	}
}

@(private = "file")
sticker_select :: proc(it: Pk_Sticker, keep_open: bool) {
	if it.locked do return
	frec_use(&frecency.sticker, fmt.tprint(u64(it.id)))
	if app.client != nil {
		ids := []dc.Snowflake{it.id}
		dc.send_message(app.client, pk.channel, "", {sticker_ids = slice.clone(ids, context.temp_allocator)})
		chat_state(pk.channel).scroll_target = 0
	}
	if !keep_open do picker_close()
}

// A sticker drawn aspect-fit in a size x size box; animates only when `animate`.
sticker_box :: proc(id: string, it: Pk_Sticker, size: f32, animate: bool) -> ^ui.Box {
	b := ui.box(id)
	b.semantic_size = {.X = ui.px(size), .Y = ui.px(size)}
	if it.format_type == 3 {
		lottie_sticker_draw(b, it.id, animate)
		return b
	}
	url := dc.sticker_url(it.id, it.format_type, ST_URL_SIZE)
	image_get(url)
	d := new(Sticker_Draw, context.temp_allocator)
	d^ = {url = url, animate = animate}
	b.custom_draw = sticker_draw
	b.custom_user = d
	return b
}

@(private = "file")
Sticker_Draw :: struct {
	url:     string,
	animate: bool,
}

@(private = "file")
sticker_draw :: proc(b: ^ui.Box, user: rawptr) {
	d := (^Sticker_Draw)(user)
	im := image_get(d.url)
	if im == nil || im.state != .Ready do return
	tex := d.animate ? image_texture(im) : (len(im.frames) > 0 ? im.frames[0] : im.tex)
	if tex == 0 do return
	if d.animate && len(im.frames) > 1 do app.ui.animating = true
	draw_fit(b, tex, f32(im.size.x), f32(im.size.y))
}

draw_fit :: proc(b: ^ui.Box, tex: gfx.Texture, iw, ih: f32) {
	bw, bh := b.rect.x1 - b.rect.x0, b.rect.y1 - b.rect.y0
	if iw <= 0 || ih <= 0 do return
	s := min(bw / iw, bh / ih)
	w, h := iw * s, ih * s
	x0 := b.rect.x0 + (bw - w) / 2
	y0 := b.rect.y0 + (bh - h) / 2
	c := gfx.Color{1, 1, 1, b.opacity}
	gfx.push_rect({dst = {x0, y0, x0 + w, y0 + h}, tex = tex, colors = {c, c, c, c}})
}
