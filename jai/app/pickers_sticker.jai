// Sticker picker: nav (frequent, favorites, guilds, standard packs), sticky
// headers, 4-column grid, inspector, search by name. PNG/APNG/GIF stickers go
// through the image pipeline (animating on hover); Lottie ones through src/lottie.

// --custom-stickers-constants-*: preview 96 (margin 12), list padding-left 8,
// search results padding-top 8, category list padding 8, icons 32 (unicode 24)
// with 8 margin; the section heading / inspector are the shared expression ones.
ST_NAV_W :: 48;
ST_NAV_PAD :: 8;
ST_NAV_ICON :: 32;
ST_NAV_UNICODE_ICON :: 24;
ST_NAV_MARGIN :: 8;
ST_GRID_PAD_L :: 8;
ST_SEARCH_PAD_TOP :: 8;
ST_PREVIEW :: 96;
ST_PREVIEW_MARGIN :: 12;
ST_PREVIEW_RADIUS :: 4;
ST_HEADER_H :: 32;
ST_INSPECTOR_H :: 48;
ST_FREQUENT_MAX :: 8;
ST_URL_SIZE :: 160; // --custom-stickers-constants-sticker-dimension

Pk_Sticker :: struct {
	id: dc.Snowflake;
	name: string;
	format_type: int;
	guild: dc.Snowflake;
	pack: dc.Snowflake;
	locked: bool;
}

Sticker_Pack :: struct {
	id: dc.Snowflake;
	name: string;
	cover: dc.Snowflake;
	stickers: [..]Pk_Sticker;
}

St_Section :: struct {
	key: u64;
	title: string;
	icon: string;
	guild: dc.Snowflake;
	cover: Pk_Sticker;
	items: []Pk_Sticker;
	y: float32;
	rows: int;
	flat: bool; // search results: no header
}

Sticker_View :: struct {
	requested: bool;
	packs: [..]Sticker_Pack;
	scroll: Pk_Scroll;
	inspected: [2]int; // section, index; -1 = none
	collapsed: Map(u64, bool);
}

sv: Sticker_View;

sticker_picker_on_show :: () {
	sv.inspected = .[-1, 0];
	if sv.requested || app.client == null { return; }
	sv.requested = true;
	dc.sticker_packs_fetch(app.client);
}

sticker_picker_query_changed :: () {
	sv.scroll = .{};
	sv.inspected = .[-1, 0];
}

sticker_packs_receive :: (r: *dc.Expr_Result) {
	if !r.ok { return; }
	m := dc.vmap(r.body);
	for * p: sv.packs {
		delete(p.name);
		for s: p.stickers { delete(s.name); }
		delete(p.stickers);
	}
	clear(*sv.packs);
	for pv: dc.flist(m, "sticker_packs") {
		pm := dc.vmap(pv);
		p := Sticker_Pack.{id = dc.fsnow(pm, "id"), name = clone(dc.fstr(pm, "name")), cover = dc.fsnow(pm, "cover_sticker_id")};
		for stv: dc.flist(pm, "stickers") {
			s := dc.vmap(stv);
			append(*p.stickers, Pk_Sticker.{id = dc.fsnow(s, "id"), name = clone(dc.fstr(s, "name")), format_type = cast(int)(dc.fint(s, "format_type")), pack = p.id});
		}
		append(*sv.packs, p);
	}
}
#scope_file

build_sections :: (ignore_query := false) -> []St_Section {
	s := store();
	here: dc.Snowflake;
	{ c := dc.channel_get(s, pk.channel);
	if c != null { here = c.guild_id; } }
	nitro := false;
	{ u := dc.user_get(s, s.me);
	if u != null { nitro = u.premium_type > 0; } }
	all := Map(dc.Snowflake, Pk_Sticker).{};
	guilds := make_dynamic(dc.Snowflake, 0, 0, temp);
	if here != 0 { append(*guilds, here); }
	for gid: guild_order() { if gid != here { append(*guilds, gid); } }
	guild_items :: (g: *dc.Guild, here: dc.Snowflake, nitro: bool) -> []Pk_Sticker {
		out := make_slice(Pk_Sticker, len(g.stickers), temp);
		for st, i: g.stickers { at(*out, i).* = Pk_Sticker.{id = st.id, name = st.name, format_type = st.format_type, guild = g.id, locked = !nitro && g.id != here}; }
		return out;
	}
	for gid: guilds {
		{ g := dc.guild_get(s, gid);
		if g != null { for it_: guild_items(g, here, nitro) { at(*all, it_.id).* = it_; } } }
	}
	for p: sv.packs { for it_: p.stickers { at(*all, it_.id).* = it_; } }

	secs := make_dynamic(St_Section, 0, 0, temp);
	q := ifx ignore_query then "" else pk_query(.Sticker);
	if q != "" {
		hits := make_dynamic(Pk_Sticker, 0, 0, temp);
		for gid: guilds {
			{ g := dc.guild_get(s, gid);
			if g != null { for it_: guild_items(g, here, nitro) { if strings.contains(strings.to_lower(it_.name, temp), q) { append(*hits, it_); } } } }
		}
		for p: sv.packs { for it_: p.stickers { if strings.contains(strings.to_lower(it_.name, temp), q) { append(*hits, it_); } } }
		append(*secs, St_Section.{key = 1, items = view(hits), flat = true});
		return view(secs);
	}
	if len(frecency.favorite_stickers) > 0 {
		items := make_dynamic(Pk_Sticker, 0, 0, temp);
		for id: frecency.favorite_stickers { { it_, ok := map_find(all, id);
if ok { append(*items, it_); } } }
		if len(items) > 0 { append(*secs, St_Section.{key = 2, title = "Favorites", icon = "star", items = view(items)}); }
	}
	/*label frequent*/ {
		items := make_dynamic(Pk_Sticker, 0, 0, temp);
		for k: frec_top(frecency.sticker, ST_FREQUENT_MAX) {
			id := cast(dc.Snowflake)(0);
			for ch: k { if ch >= #char "0" && ch <= #char "9" { id = id * 10 + cast(dc.Snowflake)(ch - #char "0"); } }
			{ it_, ok := map_find(all, id);
			if ok { append(*items, it_); } }
		}
		if len(items) > 0 { append(*secs, St_Section.{key = 3, title = "Frequently Used", icon = "clock", items = view(items)}); }
	}
	for gid: guilds {
		g := dc.guild_get(s, gid);
		if g == null || len(g.stickers) == 0 { continue; }
		append(*secs, St_Section.{key = cast(u64)(gid), title = g.name, guild = gid, items = guild_items(g, here, nitro)});
	}
	for p: sv.packs {
		cover := ifx len(p.stickers) > 0 then p.stickers[0] else Pk_Sticker.{};
		for it_: p.stickers { if it_.id == p.cover { cover = it_; } }
		append(*secs, St_Section.{key = cast(u64)(p.id), title = p.name, cover = cover, items = view(p.stickers)});
	}
	return view(secs);
}
#scope_export

sticker_picker_body :: (r: ui.Rect) {
	secs := build_sections();
	grid := ui.Rect.{r.x0 + ST_NAV_W, r.y0, r.x1, r.y1 - ST_INSPECTOR_H};
	inner := grid.x1 - grid.x0 - ST_GRID_PAD_L;
	cols := max(1, cast(int)(inner / (ST_PREVIEW + ST_PREVIEW_MARGIN)));
	cell: float32 = ST_PREVIEW + ST_PREVIEW_MARGIN;
	content_h := st_layout(secs, cols, cell);
	nav_secs := secs;
	searching := len(secs) > 0 && secs[0].flat;
	if searching {
		nav_secs = build_sections(true);
		st_layout(nav_secs, cols, cell);
	}
	pk_scroll_update(*sv.scroll, grid, content_h);
	body := row("st_body");
	body.semantic_size = .[ui.pct(1), ui.fill()];
	body.cross_align = .Start;
	{ ui.parent(body); defer ui.pop_parent();
		sticker_nav(nav_secs, r.y1 - r.y0, searching);
		col := ui.box("st_main");
		col.semantic_size = .[ui.fill(), ui.pct(1)];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			sticker_grid(secs, cols, cell, grid);
			sticker_inspector(secs);
		}
	}
}
#scope_file

st_layout :: (secs: []St_Section, cols: int, cell: float32) -> float32 {
	y: float32 = 0;
	for * sc: secs {
		if sc.flat { y += ST_SEARCH_PAD_TOP; }
		sc.y = y;
		if !sc.flat { y += ST_HEADER_H; }
		sc.rows = (len(sc.items) + cols - 1) / cols;
		if get(sv.collapsed, sc.key) && !sc.flat { sc.rows = 0; }
		y += cast(float32)(sc.rows) * cell;
	}
	return y;
}

cur_section :: (secs: []St_Section) -> int {
	cur := 0;
	for sc, i: secs { if sc.y <= sv.scroll.y + 1 { cur = i; } }
	return cur;
}

sticker_nav :: (secs: []St_Section, h: float32, searching: bool) {
	nav := ui.box("st_nav", .Clip | .Scroll_Y);
	nav.semantic_size = .[ui.px(ST_NAV_W), ui.px(h)];
	nav.layout_axis = .Y;
	nav.cross_align = .Center;
	ui.signal(nav);
	{ ui.parent(nav); defer ui.pop_parent();
		spacer(.Y, ST_NAV_PAD);
		cur := ifx searching then -1 else cur_section(secs);
		for * sc, i: secs {
			if sc.flat { continue; }
			active := cur == i;
			{ ui.id_scope(sc.key); defer ui.pop_seed();
				slot := ui.box("slot", .Clickable | .Draw_Background | .Hot_Animation);
				slot.semantic_size = .[ui.px(ST_NAV_ICON), ui.px(ST_NAV_ICON)];
				slot.layout_axis = .X;
				slot.cross_align = .Center;
				slot.style.radius = all4(4);
				sig := ui.signal(slot);
				{ ui.parent(slot); defer ui.pop_parent();
					if sc.guild != 0 {
						gi := ui.box("##gicon", .Draw_Background | .Draw_Text);
						gi.semantic_size = .[ui.px(ST_NAV_ICON), ui.px(ST_NAV_ICON)];
						gi.style.radius = all4(cast(float32) (ifx active || sig.hovering then 10 else ST_NAV_ICON / 2));
						gi.style.bg = T("--background-mod-subtle");
						gi.style.text_align = .Center;
						gi.style.font = F(.Medium);
						gi.style.font_size = 11;
						gi.style.text_color = T("--text-default");
						{ g := dc.guild_get(store(), sc.guild);
						if g != null {
							if g.icon != "" { set_remote_image(gi, dc.guild_icon_url(sc.guild, g.icon, 64)); } else { gi.text = guild_initials(g.name); }
						} }
					} else if sc.cover.id != 0 {
						slot.style.bg = ifx active then T("--background-base-low") else .{};
						slot.style.bg_hot = ifx active then slot.style.bg else T("--interactive-background-hover");
						sticker_box("cover", sc.cover, ST_NAV_ICON, false);
					} else {
						slot.style.bg = ifx active then T("--background-base-low") else .{};
						slot.style.bg_hot = ifx active then slot.style.bg else T("--interactive-background-hover");
						spacer(.X, (ST_NAV_ICON - ST_NAV_UNICODE_ICON) / 2);
						icon("ic", sc.icon, ST_NAV_UNICODE_ICON, ifx active then T("--interactive-text-active") else (ifx sig.hovering then T("--interactive-text-hover") else T("--interactive-text-default")));
					}
				}
				if sig.clicked {
					if searching { ui.editor_set_text(*pk.search[Picker_Tab.Sticker], ""); }
					at(*sv.collapsed, sc.key).* = false;
					sv.scroll.target = sc.y;
				}
			}
			spacer(.Y, ST_NAV_MARGIN);
		}
	}
}

st_header :: (sc: *St_Section, id: string, y: float32, w: float32) {
	h := row(id, .Floating_X | .Floating_Y | .Clickable | .Draw_Background);
	h.semantic_size = .[ui.px(w), ui.px(ST_HEADER_H)];
	h.fixed_pos = .{0, y};
	h.style.bg = T("--background-surface-high");
	sig := ui.signal(h);
	collapsed := get(sv.collapsed, sc.key);
	c := ifx sig.hovering then T("--interactive-text-active") else T("--text-default");
	{ ui.parent(h); defer ui.pop_parent();
		spacer(.X, 8);
		if sc.icon != "" {
			icon("hi", sc.icon, EM_HEADER_ICON, c);
			spacer(.X, 4);
		}
		t := label(sc.title, .Semibold, EM_HEADER_FONT, c, 18);
		t.flags |= .Clip;
		spacer(.X, 4);
		icon("chev", ifx collapsed then "chevron-small-right" else "chevron-small-down", 16, c);
		filler(.X);
	}
	if sig.clicked { at(*sv.collapsed, sc.key).* = !collapsed; }
}

sticker_grid :: (secs: []St_Section, cols: int, cell: float32, view: ui.Rect) {
	w := view.x1 - view.x0;
	vh := view.y1 - view.y0;
	list := ui.box("st_grid", .Clip);
	list.semantic_size = .[ui.pct(1), ui.px(vh)];
	top := sv.scroll.y;
	{ ui.parent(list); defer ui.pop_parent();
		for * sc, si: secs {
			body_y := sc.y + (ifx sc.flat then 0 else ST_HEADER_H);
			if body_y + cast(float32)(sc.rows) * cell < top - cell || sc.y > top + vh { continue; }
			{ ui.id_scope(sc.key); defer ui.pop_seed();
				if !sc.flat { st_header(sc, "hdr", sc.y - top, w); }
				for it_, i: sc.items {
					rr, cc := i / cols, i % cols;
					if rr >= sc.rows { break; }
					y := body_y + cast(float32)(rr) * cell - top;
					if y + cell < 0 || y > vh { continue; }
					{ ui.id_scope(cast(u64)(i)); defer ui.pop_seed();
						b := ui.box("cell", .Clickable | .Floating_X | .Floating_Y | .Draw_Background);
						b.semantic_size = .[ui.px(ST_PREVIEW), ui.px(ST_PREVIEW)];
						b.fixed_pos = .{ST_GRID_PAD_L + cast(float32)(cc) * cell, y};
						b.style.radius = all4(ST_PREVIEW_RADIUS);
						sig := ui.signal(b);
						if sig.hovering { sv.inspected = .[si, i]; }
						if sig.hovering { b.style.bg = T("--interactive-background-selected"); }
						{ ui.parent(b); defer ui.pop_parent();
							sb := sticker_box("st", it_, ST_PREVIEW - 8, sig.hovering);
							sb.flags |= .Floating_X | .Floating_Y;
							sb.fixed_pos = .{4, 4};
							if it_.locked { sb.opacity = 0.3; }
						}
						if sig.clicked { sticker_select(it_, has(app.ui_mods, .Shift)); }
					}
				}
			}
		}
		if len(secs) > 0 && !secs[0].flat {
			cur := cur_section(secs);
			y: float32 = 0;
			if cur + 1 < len(secs) {
				nxt := secs[cur + 1].y - top;
				if nxt < ST_HEADER_H { y = nxt - ST_HEADER_H; }
			}
			{ ui.id_scope(0xffff); defer ui.pop_seed(); st_header(*secs[cur], "sticky", y, w); }
		}
		if len(secs) == 0 || (secs[0].flat && len(secs[0].items) == 0) {
			msg := ui.box("empty", .Floating_X | .Floating_Y);
			msg.semantic_size = .[ui.px(w), ui.px(vh)];
			msg.layout_axis = .Y;
			msg.cross_align = .Center;
			{ ui.parent(msg); defer ui.pop_parent();
				spacer(.Y, vh / 2 - 30);
				label(ifx len(secs) == 0 then "No stickers yet" else "No stickers found", .Semibold, 16, T("--text-strong"), 20);
			}
		}
		pk_scrollbar(*sv.scroll, w - PK_SCROLLBAR_W - 2);
	}
}

sticker_inspector :: (secs: []St_Section) {
	line := ui.box("insline", .Draw_Background);
	line.semantic_size = .[ui.pct(1), ui.px(1)];
	line.style.bg = T("--border-normal");
	bar := row("inspector", .Draw_Background);
	bar.semantic_size = .[ui.pct(1), ui.px(ST_INSPECTOR_H - 1)];
	bar.style.bg = T("--background-base-lower");
	si, ii := sv.inspected[0], sv.inspected[1];
	if si < 0 || si >= len(secs) || ii >= len(secs[si].items) { return; }
	it_ := secs[si].items[ii];
	{ ui.parent(bar); defer ui.pop_parent();
		spacer(.X, 16);
		sticker_box("is", it_, 28, false);
		spacer(.X, 8);
		col := ui.box("names");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			label(it_.name, .Semibold, 16, T("--text-strong"), 20);
			from := "";
			{ g := dc.guild_get(store(), it_.guild);
			if g != null { from = g.name; } }
			for p: sv.packs { if p.id == it_.pack { from = p.name; } }
			if from != "" { label(fmt.tprintf("from %s", from), .Normal, 12, T("--interactive-text-default"), 16); }
		}
	}
}

// The client's onSelectSticker: an empty composer sends the sticker right away
// ({content:"", sticker_ids:[id]}); the picker closes and the composer refocuses.
// (With text in the composer the client stages a sticker preview instead; we send.)
sticker_select :: (it_: Pk_Sticker, keep_open: bool) {
	if it_.locked { return; }
	frec_use(*frecency.sticker, fmt.tprint(cast(u64)(it_.id)));
	if app.client != null {
		ids := dc.Snowflake.[it_.id];
		dc.send_message(app.client, pk.channel, "", .{sticker_ids = clone(ids, temp)});
		chat_state(pk.channel).scroll_target = 0;
	}
	picker_close();
}
#scope_export

// A sticker drawn aspect-fit in a size x size box; animates only when `animate`.
sticker_box :: (id: string, it_: Pk_Sticker, size: float32, animate: bool) -> *ui.Box {
	b := ui.box(id);
	b.semantic_size = .[ui.px(size), ui.px(size)];
	if it_.format_type == 3 {
		lottie_sticker_draw(b, it_.id, animate);
		return b;
	}
	url := dc.sticker_url(it_.id, it_.format_type, ST_URL_SIZE);
	image_get(url);
	d := new(Sticker_Draw, temp);
	d.* = .{url = url, animate = animate};
	b.custom_draw = sticker_draw;
	b.custom_user = d;
	return b;
}
#scope_file

Sticker_Draw :: struct {
	url: string;
	animate: bool;
}

sticker_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Sticker_Draw)(user);
	im := image_get(d.url);
	if im == null || im.state != .Ready { return; }
	tex := ifx d.animate then image_texture(im) else (ifx len(im.frames) > 0 then im.frames[0] else im.tex);
	if tex == 0 { return; }
	if d.animate && len(im.frames) > 1 { app.ui.animating = true; }
	draw_fit(b, tex, cast(float32)(im.size.x), cast(float32)(im.size.y));
}
#scope_export

draw_fit :: (b: *ui.Box, tex: gfx.Texture, iw: float32, ih: float32) {
	bw, bh := b.rect.x1 - b.rect.x0, b.rect.y1 - b.rect.y0;
	if iw <= 0 || ih <= 0 { return; }
	s := min(bw / iw, bh / ih);
	w, h := iw * s, ih * s;
	x0 := b.rect.x0 + (bw - w) / 2;
	y0 := b.rect.y0 + (bh - h) / 2;
	c := gfx.Color.{1, 1, 1, b.opacity};
	gfx.push_rect(.{dst = .{x0, y0, x0 + w, y0 + h}, tex = tex, colors = .[c, c, c, c]});
}

