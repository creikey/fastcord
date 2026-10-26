package app

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import dc "fc:discord"
import "fc:gfx"
import "fc:ui"

// GIF picker: front page of category tiles (favorites, trending, /gifs/trending
// categories), masonry results for searches and tiles, suggestions at the end.
// Mirrors GIFPickerSearchResults / GIFPickerCategories in the client bundle:
// desiredItemWidth 200, maxColumns 6, itemGutter 12, category tiles 110 high,
// 250 ms search debounce, suggestions once within 1180 px of the end.

GIF_PAD_X :: 16
GIF_GUTTER :: 12
GIF_DESIRED_W :: 200
GIF_MAX_COLS :: 6
GIF_TILE_H :: 110
GIF_TILE_RADIUS :: 8
GIF_DEBOUNCE_S :: 0.25
GIF_SUGGEST_WITHIN :: 1180
GIF_FOOTER_H :: 120

Gif_Item :: struct {
	id:      string,
	title:   string,
	url:     string, // what gets sent (tenor page)
	src:     string, // media_format (webm) rendition
	gif_src: string,
	preview: string,
	width:   int,
	height:  int,
}

Gif_Category :: struct {
	name: string,
	src:  string,
}

Gif_Result_Kind :: enum u8 {
	None, // front page
	Search,
	Category,
	Trending,
	Favorites,
}

Gif_View :: struct {
	arena:            virtual.Arena, // categories + results strings
	results_arena:    virtual.Arena,
	requested:        bool,
	categories:       [dynamic]Gif_Category,
	trending_preview: Gif_Item,
	kind:             Gif_Result_Kind,
	results:          [dynamic]Gif_Item,
	result_query:     string,
	loading:          bool,
	debounce_at:      f64, // pending search fire time (0 = none)
	suggestions:      [dynamic]string,
	suggested_for:    string,
	scroll:           Pk_Scroll,
	hovered:          int,
}

gv: Gif_View

gif_picker_on_show :: proc() {
	if gv.requested || app.client == nil do return
	gv.requested = true
	dc.gifs_trending(app.client)
}

pickers_debug :: proc() -> bool {return os.get_env("FASTCORD_PICKER_DEBUG", context.temp_allocator) != ""}

@(private = "file")
reset_results :: proc(kind: Gif_Result_Kind) {
	virtual.arena_destroy(&gv.results_arena)
	gv.results_arena = {}
	gv.results = {}
	gv.suggestions = {}
	gv.suggested_for = ""
	gv.result_query = ""
	gv.kind = kind
	gv.scroll = {}
	gv.loading = kind != .None && kind != .Favorites
}

gif_picker_query_changed :: proc() {
	q := strings.trim_space(ui.editor_text(&pk.search[.Gif]))
	if q == "" {
		if gv.kind == .Search || gv.kind == .Category do reset_results(.None)
		gv.debounce_at = 0
		return
	}
	if gv.kind != .Search {
		reset_results(.Search)
	}
	gv.loading = true
	gv.debounce_at = app.ui.time + GIF_DEBOUNCE_S
}

@(private = "file")
fire_search :: proc() {
	q := strings.trim_space(ui.editor_text(&pk.search[.Gif]))
	gv.debounce_at = 0
	if q == "" || app.client == nil do return
	dc.gifs_search(app.client, q)
}

@(private = "file")
parse_gif :: proc(m: dc.V) -> Gif_Item {
	o := dc.vmap(m)
	alloc := virtual.arena_allocator(&gv.results_arena)
	return Gif_Item {
		id      = strings.clone(dc.fstr(o, "id"), alloc),
		title   = strings.clone(dc.fstr(o, "title"), alloc),
		url     = strings.clone(dc.fstr(o, "url"), alloc),
		src     = strings.clone(dc.fstr(o, "src"), alloc),
		gif_src = strings.clone(dc.fstr(o, "gif_src"), alloc),
		preview = strings.clone(dc.fstr(o, "preview"), alloc),
		width   = int(dc.fint(o, "width")),
		height  = int(dc.fint(o, "height")),
	}
}

gif_receive :: proc(r: ^dc.Expr_Result) {
	if pickers_debug() do fmt.eprintfln("[gif] op=%v status=%d query=%q body=%v", r.op, r.status, r.query, r.body)
	if !r.ok do return
	#partial switch r.op {
	case .Gif_Trending:
		m := dc.vmap(r.body)
		alloc := virtual.arena_allocator(&gv.arena)
		clear(&gv.categories)
		for cv in dc.flist(m, "categories") {
			c := dc.vmap(cv)
			append(&gv.categories, Gif_Category{strings.clone(dc.fstr(c, "name"), alloc), strings.clone(dc.fstr(c, "src"), alloc)})
		}
		gifs := dc.flist(m, "gifs")
		if len(gifs) > 0 {
			o := dc.vmap(gifs[0])
			gv.trending_preview = Gif_Item {
				src     = strings.clone(dc.fstr(o, "src"), alloc),
				gif_src = strings.clone(dc.fstr(o, "gif_src"), alloc),
				preview = strings.clone(dc.fstr(o, "preview"), alloc),
			}
		}
	case .Gif_Search, .Gif_Trending_Gifs:
		want := strings.trim_space(ui.editor_text(&pk.search[.Gif]))
		if r.op == .Gif_Search && gv.kind == .Search && r.query != want do return // stale
		if r.op == .Gif_Search && gv.kind != .Search && gv.kind != .Category do return
		if r.op == .Gif_Trending_Gifs && gv.kind != .Trending do return
		kind := gv.kind
		reset_results(kind)
		gv.loading = false
		gv.result_query = strings.clone(r.query, virtual.arena_allocator(&gv.results_arena))
		gv.results = make([dynamic]Gif_Item, virtual.arena_allocator(&gv.results_arena))
		for it in dc.vlist(r.body) do append(&gv.results, parse_gif(it))
	case .Gif_Suggest:
		alloc := virtual.arena_allocator(&gv.results_arena)
		gv.suggestions = make([dynamic]string, alloc)
		for s in dc.vlist(r.body) do append(&gv.suggestions, strings.clone(dc.vstr(s), alloc))
	}
}

// Back arrow in the header while showing results (clears the query, like handleClearQuery).
gif_header_back :: proc() {
	if gv.kind == .None do return
	b := ui.box("gifback", {.Clickable, .Draw_Background, .Hot_Animation})
	b.semantic_size = {.X = ui.px(32), .Y = ui.px(32)}
	b.style.radius = 8
	b.style.bg_hot = T("--background-mod-subtle")
	b.layout_axis = .X
	b.cross_align = .Center
	sig := ui.signal(b)
	if ui.parent(b) {
		spacer(.X, 6)
		icon("i", "arrow-large-left", 20, sig.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
	}
	spacer(.X, 8)
	if sig.clicked {
		ui.editor_set_text(&pk.search[.Gif], "")
		reset_results(.None)
	}
}

// Title instead of the search bar for Trending / Favorites (renderHeaderContent).
gif_header_title :: proc() -> bool {
	#partial switch gv.kind {
	case .Trending:
		label("Trending GIFs", .Semibold, 16, T("--text-strong"), 20)
		filler(.X)
		return true
	case .Favorites:
		label("Favorites", .Semibold, 16, T("--text-strong"), 20)
		filler(.X)
		return true
	}
	return false
}

@(private = "file")
columns_for :: proc(w: f32) -> int {
	return clamp(int(w / GIF_DESIRED_W), 1, GIF_MAX_COLS)
}

gif_picker_body :: proc(r: ui.Rect) {
	if gv.debounce_at > 0 {
		if app.ui.time >= gv.debounce_at do fire_search()
		else do request_wake(gv.debounce_at)
	}
	view := ui.Rect{r.x0, r.y0, r.x1, r.y1}
	inner_w := (r.x1 - r.x0) - 2 * GIF_PAD_X
	cols := columns_for(inner_w)
	col_w := (inner_w - f32(cols - 1) * GIF_GUTTER) / f32(cols)
	list := ui.box("gif_list", {.Clip})
	list.semantic_size = {.X = ui.pct(1), .Y = ui.pct(1)}
	if gv.kind == .None {
		gif_front_page(list, view, cols, col_w)
	} else {
		gif_results(list, view, cols, col_w)
	}
}

@(private = "file")
Tile :: struct {
	name:  string,
	src:   string,
	icon:  string,
	kind:  Gif_Result_Kind,
}

@(private = "file")
gif_front_page :: proc(list: ^ui.Box, view: ui.Rect, cols: int, col_w: f32) {
	tiles := make([dynamic]Tile, context.temp_allocator)
	if len(frecency.favorite_gifs) > 0 do append(&tiles, Tile{"Favorites", gif_render_url(frecency.favorite_gifs[0].src, ""), "star", .Favorites})
	if gv.trending_preview.src != "" || gv.trending_preview.gif_src != "" {
		append(&tiles, Tile{"Trending GIFs", gif_render_url(gv.trending_preview.src, gv.trending_preview.gif_src), "analytics", .Trending})
	}
	for c in gv.categories do append(&tiles, Tile{c.name, gif_render_url(c.src, ""), "", .Category})
	rows := (len(tiles) + cols - 1) / cols
	content_h := f32(rows) * (GIF_TILE_H + GIF_GUTTER) + GIF_GUTTER
	pk_scroll_update(&gv.scroll, view, content_h)
	top := gv.scroll.y
	vh := view.y1 - view.y0
	if ui.parent(list) {
		if len(tiles) == 0 {
			// loading placeholders (GIFPickerCategories renders 4 gray blocks per column)
			for i in 0 ..< cols * 4 {
				ph := ui.box(fmt.tprintf("ph%d", i), {.Floating_X, .Floating_Y, .Draw_Background})
				ph.semantic_size = {.X = ui.px(col_w), .Y = ui.px(GIF_TILE_H)}
				ph.fixed_pos = {GIF_PAD_X + f32(i % cols) * (col_w + GIF_GUTTER), f32(i / cols) * (GIF_TILE_H + GIF_GUTTER) - top}
				ph.style.radius = GIF_TILE_RADIUS
				ph.style.bg = T("--background-mod-subtle")
			}
		}
		for t, i in tiles {
			y := f32(i / cols) * (GIF_TILE_H + GIF_GUTTER) - top
			if y + GIF_TILE_H < 0 || y > vh do continue
			if ui.id_scope(u64(i)) {
				tile := ui.box("tile", {.Clickable, .Floating_X, .Floating_Y, .Draw_Background, .Clip})
				tile.semantic_size = {.X = ui.px(col_w), .Y = ui.px(GIF_TILE_H)}
				tile.fixed_pos = {GIF_PAD_X + f32(i % cols) * (col_w + GIF_GUTTER), y}
				tile.style.radius = GIF_TILE_RADIUS
				tile.style.bg = T("--background-mod-normal")
				sig := ui.signal(tile)
				if ui.parent(tile) {
					img := ui.box("img", {.Floating_X, .Floating_Y})
					img.semantic_size = {.X = ui.px(col_w), .Y = ui.px(GIF_TILE_H)}
					img.style.radius = GIF_TILE_RADIUS
					set_cover_image(img, t.src)
					shade := ui.box("shade", {.Floating_X, .Floating_Y, .Draw_Background})
					shade.semantic_size = {.X = ui.px(col_w), .Y = ui.px(GIF_TILE_H)}
					shade.style.radius = GIF_TILE_RADIUS
					shade.style.bg = {0, 0, 0, sig.hovering ? 0.35 : 0.5}
					lab := row("lab", {.Floating_X, .Floating_Y})
					lab.semantic_size = {.X = ui.px(col_w), .Y = ui.px(GIF_TILE_H)}
					lab.cross_align = .Center
					if ui.parent(lab) {
						filler(.X)
						if t.icon != "" {
							icon("i", t.icon, 20, {1, 1, 1, 1})
							spacer(.X, 6)
						}
						label(t.name, .Bold, 16, {1, 1, 1, 1}, 20)
						filler(.X)
					}
				}
				if sig.clicked do gif_open_tile(t)
			}
		}
		pk_scrollbar(&gv.scroll, view.x1 - view.x0 - PK_SCROLLBAR_W - 2)
	}
}

@(private = "file")
gif_open_tile :: proc(t: Tile) {
	#partial switch t.kind {
	case .Category:
		// handleSelectItem: search the category name immediately, query shown in the bar
		ui.editor_set_text(&pk.search[.Gif], t.name)
		reset_results(.Category)
		if app.client != nil do dc.gifs_search(app.client, t.name)
	case .Trending:
		reset_results(.Trending)
		if app.client != nil do dc.gifs_trending_gifs(app.client)
	case .Favorites:
		reset_results(.Favorites)
	}
}

@(private = "file")
gif_results :: proc(list: ^ui.Box, view: ui.Rect, cols: int, col_w: f32) {
	items := gv.results[:]
	if gv.kind == .Favorites {
		fav := make([]Gif_Item, len(frecency.favorite_gifs), context.temp_allocator)
		for g, i in frecency.favorite_gifs do fav[i] = Gif_Item{url = g.url, src = g.src, width = g.width, height = g.height}
		items = fav
	}
	// masonry: each item goes to the shortest column
	Placed :: struct {
		x, y, h: f32,
	}
	placed := make([]Placed, len(items), context.temp_allocator)
	heights := make([]f32, cols, context.temp_allocator)
	for &h in heights do h = 0
	for it, i in items {
		c := 0
		for j in 1 ..< cols do if heights[j] < heights[c] do c = j
		h := col_w
		if it.width > 0 && it.height > 0 do h = col_w * f32(it.height) / f32(it.width)
		placed[i] = {GIF_PAD_X + f32(c) * (col_w + GIF_GUTTER), heights[c], h}
		heights[c] += h + GIF_GUTTER
	}
	content_h: f32 = 0
	for h in heights do content_h = max(content_h, h)
	footer := gv.kind == .Search || gv.kind == .Category
	if footer do content_h += GIF_FOOTER_H
	pk_scroll_update(&gv.scroll, view, content_h)
	top := gv.scroll.y
	vh := view.y1 - view.y0
	// suggestions when near the end (handleScroll)
	if footer && app.client != nil && len(items) > 0 && content_h - top <= GIF_SUGGEST_WITHIN && gv.suggested_for != gv.result_query {
		gv.suggested_for = gv.result_query
		dc.gifs_suggest(app.client, gv.result_query)
	}
	if ui.parent(list) {
		if gv.loading && len(items) == 0 {
			for i in 0 ..< cols * 3 {
				ph := ui.box(fmt.tprintf("ph%d", i), {.Floating_X, .Floating_Y, .Draw_Background})
				h := f32(120 + (i * 37) % 100)
				ph.semantic_size = {.X = ui.px(col_w), .Y = ui.px(h)}
				ph.fixed_pos = {GIF_PAD_X + f32(i % cols) * (col_w + GIF_GUTTER), f32(i / cols) * 232}
				ph.style.radius = GIF_TILE_RADIUS
				ph.style.bg = T("--background-mod-subtle")
			}
		} else if len(items) == 0 {
			msg := ui.box("empty", {.Floating_X, .Floating_Y})
			msg.semantic_size = {.X = ui.px(view.x1 - view.x0), .Y = ui.px(vh)}
			msg.layout_axis = .Y
			msg.cross_align = .Center
			if ui.parent(msg) {
				spacer(.Y, vh / 2 - 30)
				label(gv.kind == .Favorites ? "No favorites yet" : "No GIFs found", .Semibold, 16, T("--text-strong"), 20)
			}
		}
		for it, i in items {
			p := placed[i]
			y := p.y - top
			if y + p.h < -200 || y > vh + 200 do continue
			if ui.id_scope(u64(i)) {
				cell := ui.box("gif", {.Clickable, .Floating_X, .Floating_Y, .Draw_Background, .Draw_Border})
				cell.semantic_size = {.X = ui.px(col_w), .Y = ui.px(p.h)}
				cell.fixed_pos = {p.x, y}
				cell.style.radius = 4
				cell.style.bg = T("--background-mod-normal")
				sig := ui.signal(cell)
				cell.style.border = sig.hovering ? 2 : 0
				cell.style.border_color = T("--background-brand")
				set_cover_image(cell, gif_render_url(it.src, it.gif_src))
				if sig.clicked do gif_select(it, .Shift in app.ui_mods)
			}
		}
		if footer && len(items) > 0 {
			fy := content_h - GIF_FOOTER_H - top
			f := ui.box("footer", {.Floating_X, .Floating_Y})
			f.semantic_size = {.X = ui.px(view.x1 - view.x0), .Y = ui.px(GIF_FOOTER_H)}
			f.fixed_pos = {0, fy}
			f.layout_axis = .Y
			f.cross_align = .Center
			if ui.parent(f) {
				spacer(.Y, 16)
				if len(gv.suggestions) > 0 {
					label("Try searching for...", .Semibold, 14, T("--text-muted"), 18)
					spacer(.Y, 8)
					chips := row("chips")
					chips.semantic_size = {.X = ui.children(), .Y = ui.px(28)}
					chips.style.child_gap = 8
					if ui.parent(chips) {
						for s in gv.suggestions {
							chip := ui.box(s, {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
							chip.semantic_size = {.X = ui.text_size(10), .Y = ui.px(28)}
							chip.style.radius = 14
							chip.style.bg = T("--background-mod-subtle")
							chip.style.bg_hot = T("--background-mod-strong")
							chip.style.font = F(.Medium)
							chip.style.font_size = 14
							chip.style.text_color = T("--interactive-text-default")
							if ui.signal(chip).clicked {
								ui.editor_set_text(&pk.search[.Gif], s)
								reset_results(.Search)
								if app.client != nil do dc.gifs_search(app.client, s)
							}
						}
					}
				}
			}
		}
		pk_scrollbar(&gv.scroll, view.x1 - view.x0 - PK_SCROLLBAR_W - 2)
	}
}

// Sends the GIF's url as a message (the client's onSelectGIF), then POST /gifs/select.
@(private = "file")
gif_select :: proc(it: Gif_Item, keep_open: bool) {
	if app.client != nil && it.url != "" {
		dc.send_message(app.client, pk.channel, it.url)
		dc.gif_select(app.client, it.id, gv.result_query)
		chat_state(pk.channel).scroll_target = 0
	}
	if !keep_open do picker_close()
}

// What we can decode: the API's media_format rendition is webm (video); its
// gif_src / an image src renders through the image pipeline.
gif_render_url :: proc(src, gif_src: string) -> string {
	u := src
	if strings.has_prefix(u, "//") do u = strings.concatenate({"https:", u}, context.temp_allocator)
	path := u
	if q := strings.index_byte(path, '?'); q >= 0 do path = path[:q]
	if strings.has_suffix(path, ".webm") || strings.has_suffix(path, ".mp4") {
		if gif_src != "" do return gif_src
		return tenor_image_variant(u)
	}
	return u
}

// Tenor renditions differ by the last two characters of the media id
// (…AAPo webm, …AAAC gif, …AAAM tinygif): swap a video url to tinygif.
tenor_image_variant :: proc(u: string) -> string {
	if !strings.contains(u, "media.tenor.com/") do return u
	i := strings.index(u, "media.tenor.com/") + len("media.tenor.com/")
	rest := u[i:]
	slash := strings.index_byte(rest, '/')
	if slash < 2 do return u
	id := rest[:slash]
	name := rest[slash + 1:]
	if dot := strings.last_index_byte(name, '.'); dot >= 0 do name = name[:dot]
	return strings.concatenate({u[:i], id[:len(id) - 2], "AM/", name, ".gif"}, context.temp_allocator)
}

// Image scaled to cover the box (center crop), animated images advance.
set_cover_image :: proc(b: ^ui.Box, url: string) {
	if url == "" do return
	image_get(url)
	d := new(Cover_Draw, context.temp_allocator)
	d.url = url
	b.custom_draw = cover_draw
	b.custom_user = d
}

@(private = "file")
Cover_Draw :: struct {
	url: string,
}

@(private = "file")
cover_draw :: proc(b: ^ui.Box, user: rawptr) {
	d := (^Cover_Draw)(user)
	im := image_get(d.url)
	tex := image_texture(im)
	if tex == 0 do return
	if len(im.frames) > 1 do app.ui.animating = true
	bw, bh := b.rect.x1 - b.rect.x0, b.rect.y1 - b.rect.y0
	iw, ih := f32(im.size.x), f32(im.size.y)
	src := gfx.Rect{0, 0, iw, ih}
	if bw > 0 && bh > 0 && iw > 0 && ih > 0 {
		if iw / ih > bw / bh {
			w := ih * bw / bh
			src.x0 = (iw - w) / 2
			src.x1 = src.x0 + w
		} else {
			h := iw * bh / bw
			src.y0 = (ih - h) / 2
			src.y1 = src.y0 + h
		}
	}
	c := gfx.Color{1, 1, 1, b.opacity}
	gfx.push_rect({dst = gfx.Rect(b.rect), tex = tex, src = src, colors = {c, c, c, c}, radii = b.style.radius})
}
