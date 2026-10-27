// GIF picker: front page of category tiles (favorites, trending, /gifs/trending
// categories), masonry results for searches and tiles, suggestions at the end.
// Mirrors GIFPickerSearchResults / GIFPickerCategories in the client bundle:
// desiredItemWidth 200, maxColumns 6, itemGutter 12, category tiles 110 high,
// 250 ms search debounce, suggestions once within 1180 px of the end.

GIF_PAD_X :: 12; // grid inset (official tiles at 12px from the picker edge and the header line)
GIF_GUTTER :: 12;
GIF_DESIRED_W :: 200; // category tiles (GIFPickerCategories desiredItemWidth)
GIF_RESULTS_DESIRED_W :: 160; // --custom-gif-picker-search-results-desired-item-width
GIF_MAX_COLS :: 6;
GIF_TILE_H :: 110;
GIF_TILE_RADIUS :: 5;
GIF_DEBOUNCE_S :: 0.25;
GIF_SUGGEST_WITHIN :: 1180;
GIF_FOOTER_H :: 120;

Gif_Item :: struct {
	id: string;
	title: string;
	url: string; // what gets sent (tenor page)
	src: string; // media_format (webm) rendition
	gif_src: string;
	preview: string;
	width: int;
	height: int;
}

Gif_Category :: struct {
	name: string;
	src: string;
}

Gif_Result_Kind :: enum u8 {
	None; // front page
	Search;
	Category;
	Trending;
	Favorites;
}

Gif_View :: struct {
	pool: Flat_Pool; // categories + trending preview strings
	results_pool: Flat_Pool; // results, query, suggestions; freed by reset_results
	requested: bool;
	categories: [..]Gif_Category;
	trending_preview: Gif_Item;
	kind: Gif_Result_Kind;
	results: [..]Gif_Item;
	result_query: string;
	loading: bool;
	debounce_at: float64; // pending search fire time (0 = none)
	suggestions: [..]string;
	suggested_for: string;
	scroll: Pk_Scroll;
}

gv: Gif_View;

gif_picker_on_show :: () {
	if gv.requested || app.client == null return;
	gv.requested = true;
	dc.gifs_trending(app.client);
}

pickers_debug :: () -> bool {
	return env_var("FASTCORD_PICKER_DEBUG") != "";
}

gif_picker_query_changed :: () {
	if gif_query() == "" {
		if gv.kind == .Search || gv.kind == .Category reset_results(.None);
		gv.debounce_at = 0;
		return;
	}
	if gv.kind != .Search reset_results(.Search);
	gv.loading = true;
	gv.debounce_at = app.ui.time + GIF_DEBOUNCE_S;
}

gif_receive :: (r: *dc.Expr_Result) {
	if pickers_debug() print("[gif] op=% status=% query=\"%\" body=%\n", r.op, r.status, r.query, r.body, to_standard_error = true);
	if !r.ok return;
	if r.op == {
	case .Gif_Trending;
		m := dc.vmap(r.body);
		a := dc.pool_allocator(*gv.pool);
		gv.categories.count = 0;
		for dc.flist(m, "categories") {
			c := dc.vmap(it);
			array_add(*gv.categories, .{copy_string(dc.fstr(c, "name"),, a), copy_string(dc.fstr(c, "src"),, a)});
		}
		gifs := dc.flist(m, "gifs");
		if gifs.count > 0 {
			o := dc.vmap(gifs[0]);
			gv.trending_preview = .{src = copy_string(dc.fstr(o, "src"),, a), gif_src = copy_string(dc.fstr(o, "gif_src"),, a), preview = copy_string(dc.fstr(o, "preview"),, a)};
		}
	case .Gif_Search; #through;
	case .Gif_Trending_Gifs;
		if r.op == .Gif_Search && gv.kind == .Search && r.query != gif_query() return; // stale
		if r.op == .Gif_Search && gv.kind != .Search && gv.kind != .Category return;
		if r.op == .Gif_Trending_Gifs && gv.kind != .Trending return;
		reset_results(gv.kind);
		gv.loading = false;
		a := dc.pool_allocator(*gv.results_pool);
		gv.result_query = copy_string(r.query,, a);
		gv.results.allocator = a;
		for dc.vlist(r.body) {
			o := dc.vmap(it);
			array_add(*gv.results, .{
				id = copy_string(dc.fstr(o, "id"),, a),
				title = copy_string(dc.fstr(o, "title"),, a),
				url = copy_string(dc.fstr(o, "url"),, a),
				src = copy_string(dc.fstr(o, "src"),, a),
				gif_src = copy_string(dc.fstr(o, "gif_src"),, a),
				preview = copy_string(dc.fstr(o, "preview"),, a),
				width = dc.fint(o, "width"),
				height = dc.fint(o, "height")
			});
		}
	case .Gif_Suggest;
		a := dc.pool_allocator(*gv.results_pool);
		Initialize(*gv.suggestions);
		gv.suggestions.allocator = a;
		for dc.vlist(r.body) array_add(*gv.suggestions, copy_string(dc.vstr(it),, a));
	}
}

// Back arrow in the header while showing results (clears the query, like handleClearQuery).
gif_header_back :: () {
	if gv.kind == .None return;
	b := ui.box("gifback", .Clickable | .Draw_Background | .Hot_Animation);
	b.semantic_size = .[ui.px(32), ui.px(32)];
	b.style.radius = all4(8);
	b.style.bg_hot = T("--background-mod-subtle");
	b.layout_axis = .X;
	b.cross_align = .Center;
	sig := ui.signal(b);
	{ ui.parent(b); defer ui.pop_parent();
		spacer(.X, 6);
		icon("i", "arrow-large-left", 20, ifx sig.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
	}
	spacer(.X, 8);
	if sig.clicked {
		ui.editor_set_text(*pk.search[Picker_Tab.Gif], "");
		reset_results(.None);
	}
}

// Title instead of the search bar for Trending / Favorites (renderHeaderContent).
gif_header_title :: () -> bool {
	if gv.kind != .Trending && gv.kind != .Favorites return false;
	label(ifx gv.kind == .Trending then "Trending GIFs" else "Favorites", .Semibold, 16, T("--text-strong"), 20);
	filler(.X);
	return true;
}

gif_picker_body :: (r: ui.Rect) {
	if gv.debounce_at > 0 {
		if app.ui.time >= gv.debounce_at fire_search();
		else request_wake(gv.debounce_at);
	}
	inner_w := (r.x1 - r.x0) - 2 * GIF_PAD_X;
	desired: float32 = ifx gv.kind == .None then cast(float32) GIF_DESIRED_W else GIF_RESULTS_DESIRED_W;
	cols := clamp(cast(int) (inner_w / desired), 1, GIF_MAX_COLS);
	col_w := (inner_w - cast(float32) (cols - 1) * GIF_GUTTER) / cast(float32) cols;
	list := ui.box("gif_list", .Clip | .Draw_Background);
	list.semantic_size = .[ui.pct(1), ui.pct(1)];
	list.style.bg = T("--background-base-lower"); // the GIF grid sits on a darker well
	if gv.kind == .None gif_front_page(list, r, cols, col_w);
	else gif_results(list, r, cols, col_w);
}

// What we can decode: the API's media_format rendition is webm (video); its
// gif_src / an image src renders through the image pipeline.
gif_render_url :: (src: string, gif_src: string) -> string {
	u := ifx begins_with(src, "//") then tprint("https:%", src) else src;
	path := u;
	q := find_index_from_left(path, #char "?");
	if q >= 0 path.count = q;
	if ends_with(path, ".webm") || ends_with(path, ".mp4") return ifx gif_src != "" then gif_src else tenor_image_variant(u);
	return u;
}

// Tenor renditions differ by the last two characters of the media id
// (…AAPo webm, …AAAC gif, …AAAM tinygif): swap a video url to tinygif.
tenor_image_variant :: (u: string) -> string {
	HOST :: "media.tenor.com/";
	i := find_index_from_left(u, HOST);
	if i < 0 return u;
	i += HOST.count;
	rest := u;
	advance(*rest, i);
	slash := find_index_from_left(rest, #char "/");
	if slash < 2 return u;
	name := rest;
	advance(*name, slash + 1);
	dot := find_index_from_right(name, #char ".");
	if dot >= 0 name.count = dot;
	return tprint("%1%2AM/%3.gif", string.{i, u.data}, string.{slash - 2, rest.data}, name);
}

// Image scaled to cover the box (center crop), animated images advance.
set_cover_image :: (b: *ui.Box, url: string) {
	if url == "" return;
	image_get(url);
	d := New(Cover_Draw,, temp);
	d.url = url;
	b.custom_draw = cover_draw;
	b.custom_user = d;
}

#scope_file


gif_query :: () -> string { return trim(ui.editor_text(*pk.search[Picker_Tab.Gif])); }

reset_results :: (kind: Gif_Result_Kind) {
	fini(*gv.results_pool);
	Initialize(*gv.results);
	Initialize(*gv.suggestions);
	gv.suggested_for = "";
	gv.result_query = "";
	gv.kind = kind;
	gv.scroll = .{};
	gv.loading = kind != .None && kind != .Favorites;
}

fire_search :: () {
	q := gif_query();
	gv.debounce_at = 0;
	if q == "" || app.client == null return;
	dc.gifs_search(app.client, q);
}

Tile :: struct {
	name: string;
	src: string;
	icon: string;
	kind: Gif_Result_Kind;
}

gif_front_page :: (list: *ui.Box, view: ui.Rect, cols: int, col_w: float32) {
	tiles: [..]Tile;
	tiles.allocator = temp;
	if frecency.favorite_gifs.count > 0 array_add(*tiles, .{"Favorites", gif_render_url(frecency.favorite_gifs[0].src, ""), "star", .Favorites});
	if gv.trending_preview.src != "" || gv.trending_preview.gif_src != "" {
		array_add(*tiles, .{"Trending GIFs", gif_render_url(gv.trending_preview.src, gv.trending_preview.gif_src), "analytics", .Trending});
	}
	for gv.categories array_add(*tiles, .{it.name, gif_render_url(it.src, ""), "", .Category});
	rows := (tiles.count + cols - 1) / cols;
	content_h := cast(float32) rows * (GIF_TILE_H + GIF_GUTTER) + GIF_GUTTER;
	pk_scroll_update(*gv.scroll, view, content_h);
	top := gv.scroll.y;
	vh := view.y1 - view.y0;
	{ ui.parent(list); defer ui.pop_parent();
		if tiles.count == 0 {
			// loading placeholders (GIFPickerCategories renders 4 gray blocks per column)
			for i: 0..cols * 4 - 1 {
				ph := ui.box(tprint("ph%", i), .Floating_X | .Floating_Y | .Draw_Background);
				ph.semantic_size = .[ui.px(col_w), ui.px(GIF_TILE_H)];
				ph.fixed_pos = .{GIF_PAD_X + cast(float32) (i % cols) * (col_w + GIF_GUTTER), GIF_GUTTER + cast(float32) (i / cols) * (GIF_TILE_H + GIF_GUTTER) - top};
				ph.style.radius = all4(GIF_TILE_RADIUS);
				ph.style.bg = T("--background-mod-subtle");
			}
		}
		for t, i: tiles {
			y := GIF_GUTTER + cast(float32) (i / cols) * (GIF_TILE_H + GIF_GUTTER) - top;
			if y + GIF_TILE_H < 0 || y > vh continue;
			ui.id_scope(cast(u64) i); defer ui.pop_seed();
			tile := ui.box("tile", .Clickable | .Floating_X | .Floating_Y | .Draw_Background | .Clip);
			tile.semantic_size = .[ui.px(col_w), ui.px(GIF_TILE_H)];
			tile.fixed_pos = .{GIF_PAD_X + cast(float32) (i % cols) * (col_w + GIF_GUTTER), y};
			tile.style.radius = all4(GIF_TILE_RADIUS);
			tile.style.bg = T("--background-mod-normal");
			sig := ui.signal(tile);
			{ ui.parent(tile); defer ui.pop_parent();
				img := ui.box("img", .Floating_X | .Floating_Y);
				img.semantic_size = .[ui.px(col_w), ui.px(GIF_TILE_H)];
				img.style.radius = all4(GIF_TILE_RADIUS);
				set_cover_image(img, t.src);
				// .categoryFade (favorites: .categoryFadeBlurple); hover darkens + 1px --border-strong
				shade := ui.box("shade", .Floating_X | .Floating_Y | .Draw_Background | .Draw_Border);
				shade.semantic_size = .[ui.px(col_w), ui.px(GIF_TILE_H)];
				shade.style.radius = all4(GIF_TILE_RADIUS);
				shade.style.bg = ifx t.kind == .Favorites then with_alpha(T("--background-brand"), 0.8) else .{0, 0, 0, ifx sig.hovering then 0.6 else 0.45};
				shade.style.border = ifx sig.hovering then 1.0 else 0.0;
				shade.style.border_color = T("--border-strong");
				lab := row("lab", .Floating_X | .Floating_Y);
				lab.semantic_size = .[ui.px(col_w), ui.px(GIF_TILE_H)];
				lab.cross_align = .Center;
				{ ui.parent(lab); defer ui.pop_parent();
					filler(.X);
					if t.icon != "" {
						icon("i", t.icon, 20, .{1, 1, 1, 1});
						spacer(.X, 4);
					}
					label(t.name, .Semibold, 16, .{1, 1, 1, 1}, 16);
					filler(.X);
				}
			}
			if sig.clicked gif_open_tile(t);
		}
		pk_scrollbar(*gv.scroll);
	}
}

gif_open_tile :: (t: Tile) {
	if t.kind == {
	case .Category;
		// handleSelectItem: search the category name immediately, query shown in the bar
		ui.editor_set_text(*pk.search[Picker_Tab.Gif], t.name);
		reset_results(.Category);
		if app.client != null dc.gifs_search(app.client, t.name);
	case .Trending;
		reset_results(.Trending);
		if app.client != null dc.gifs_trending_gifs(app.client);
	case .Favorites;
		reset_results(.Favorites);
	}
}

gif_results :: (list: *ui.Box, view: ui.Rect, cols: int, col_w: float32) {
	items: []Gif_Item = gv.results;
	if gv.kind == .Favorites {
		items = NewArray(frecency.favorite_gifs.count, Gif_Item,, temp);
		for frecency.favorite_gifs items[it_index] = .{url = it.url, src = it.src, width = it.width, height = it.height};
	}
	// masonry: each item goes to the shortest column
	Placed :: struct {
		x, y, h: float32;
	}
	placed := NewArray(items.count, Placed,, temp);
	heights := NewArray(cols, float32,, temp);
	for items {
		c := 0;
		for j: 1..cols - 1 if heights[j] < heights[c] c = j;
		h := col_w;
		if it.width > 0 && it.height > 0 h = col_w * cast(float32) it.height / cast(float32) it.width;
		placed[it_index] = .{GIF_PAD_X + cast(float32) c * (col_w + GIF_GUTTER), heights[c], h};
		heights[c] += h + GIF_GUTTER;
	}
	content_h: float32 = 0;
	for heights content_h = max(content_h, it);
	footer := gv.kind == .Search || gv.kind == .Category;
	if footer content_h += GIF_FOOTER_H;
	pk_scroll_update(*gv.scroll, view, content_h);
	top := gv.scroll.y;
	vh := view.y1 - view.y0;
	// suggestions when near the end (handleScroll)
	if footer && app.client != null && items.count > 0 && content_h - top <= GIF_SUGGEST_WITHIN && gv.suggested_for != gv.result_query {
		gv.suggested_for = gv.result_query;
		dc.gifs_suggest(app.client, gv.result_query);
	}
	{ ui.parent(list); defer ui.pop_parent();
		if gv.loading && items.count == 0 {
			for i: 0..cols * 3 - 1 {
				ph := ui.box(tprint("ph%", i), .Floating_X | .Floating_Y | .Draw_Background);
				ph.semantic_size = .[ui.px(col_w), ui.px(cast(float32) (120 + (i * 37) % 100))];
				ph.fixed_pos = .{GIF_PAD_X + cast(float32) (i % cols) * (col_w + GIF_GUTTER), cast(float32) (i / cols) * 232};
				ph.style.radius = all4(GIF_TILE_RADIUS);
				ph.style.bg = T("--background-mod-subtle");
			}
		} else if items.count == 0 {
			msg := ui.box("empty", .Floating_X | .Floating_Y);
			msg.semantic_size = .[ui.px(view.x1 - view.x0), ui.px(vh)];
			msg.layout_axis = .Y;
			msg.cross_align = .Center;
			{ ui.parent(msg); defer ui.pop_parent();
				spacer(.Y, vh / 2 - 30);
				label(ifx gv.kind == .Favorites then "No favorites yet" else "No GIFs found", .Semibold, 16, T("--text-strong"), 20);
			}
		}
		for items {
			p := placed[it_index];
			y := p.y - top;
			if y + p.h < -200 || y > vh + 200 continue;
			ui.id_scope(cast(u64) it_index); defer ui.pop_seed();
			cell := ui.box("gif", .Clickable | .Floating_X | .Floating_Y | .Draw_Background | .Draw_Border);
			cell.semantic_size = .[ui.px(col_w), ui.px(p.h)];
			cell.fixed_pos = .{p.x, y};
			cell.style.radius = all4(GIF_TILE_RADIUS);
			cell.style.bg = T("--background-mod-muted");
			sig := ui.signal(cell);
			cell.style.border = ifx sig.hovering then 1.0 else 0.0;
			cell.style.border_color = T("--border-strong");
			set_cover_image(cell, gif_render_url(it.src, it.gif_src));
			if sig.clicked gif_select(it, (app.ui_mods & .Shift) != 0);
		}
		if footer && items.count > 0 {
			f := ui.box("footer", .Floating_X | .Floating_Y);
			f.semantic_size = .[ui.px(view.x1 - view.x0), ui.px(GIF_FOOTER_H)];
			f.fixed_pos = .{0, content_h - GIF_FOOTER_H - top};
			f.layout_axis = .Y;
			f.cross_align = .Center;
			{ ui.parent(f); defer ui.pop_parent();
				spacer(.Y, 16);
				if gv.suggestions.count > 0 {
					label("Try searching for...", .Semibold, 14, T("--text-muted"), 18);
					spacer(.Y, 8);
					chips := row("chips");
					chips.semantic_size = .[ui.children(), ui.px(28)];
					chips.style.child_gap = 8;
					ui.parent(chips); defer ui.pop_parent();
					for s: gv.suggestions {
						chip := ui.box(s, .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
						chip.semantic_size = .[ui.text_size(10), ui.px(28)];
						chip.style.radius = all4(14);
						chip.style.bg = T("--background-mod-subtle");
						chip.style.bg_hot = T("--background-mod-strong");
						chip.style.font = F(.Medium);
						chip.style.font_size = 14;
						chip.style.text_color = T("--interactive-text-default");
						if ui.signal(chip).clicked {
							ui.editor_set_text(*pk.search[Picker_Tab.Gif], s);
							reset_results(.Search);
							if app.client != null dc.gifs_search(app.client, s);
						}
					}
				}
			}
		}
		pk_scrollbar(*gv.scroll);
	}
}

// The client's onSelectGIF (chunk "n_"): shift-click inserts the url into the
// composer, otherwise the url is sent as its own message; then POST /gifs/select,
// close the picker and refocus the composer.
gif_select :: (it: Gif_Item, insert: bool) {
	if insert {
		ui.editor_insert(*chat_state(pk.channel).editor, it.url);
	} else if app.client != null && it.url != "" {
		dc.send_message(app.client, pk.channel, it.url);
		chat_state(pk.channel).scroll_target = 0;
	}
	if app.client != null dc.gif_select(app.client, it.id, gv.result_query);
	picker_close();
}

Cover_Draw :: struct {
	url: string;
}

cover_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Cover_Draw) user;
	im := image_get(d.url);
	tex := image_texture(im);
	if tex == 0 return;
	if im.frames.count > 1 app.ui.animating = true;
	bw, bh := b.rect.x1 - b.rect.x0, b.rect.y1 - b.rect.y0;
	iw, ih := cast(float32) im.size.x, cast(float32) im.size.y;
	src := gfx.Rect.{0, 0, iw, ih};
	if bw > 0 && bh > 0 && iw > 0 && ih > 0 {
		if iw / ih > bw / bh {
			w := ih * bw / bh;
			src.x0 = (iw - w) / 2;
			src.x1 = src.x0 + w;
		} else {
			h := iw * bh / bw;
			src.y0 = (ih - h) / 2;
			src.y1 = src.y0 + h;
		}
	}
	c := gfx.Color.{1, 1, 1, b.opacity};
	gfx.push_rect(.{dst = cast,force(gfx.Rect) b.rect, tex = tex, src = src, colors = .[c, c, c, c], radii = b.style.radius});
}
