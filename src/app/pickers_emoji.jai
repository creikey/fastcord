// Emoji picker: category nav, sticky section headers, 9-column virtualized
// grid, inspector bar, skin tones, keyboard navigation, search, frecency.

// ---- geometry ----
// --custom-emoji-picker-constants-*: list padding 0 0 8 8 (search results +8 top),
// section margin-bottom 12, item 40 + 4 padding, category icons 24 + 4 padding
// (margin 2), guild/recent icons 32 (margin 8), separators 1px with 12 margin,
// diversity emoji 24 + 7 padding; section heading 32, inspector 48 (graphic 28).
EM_NAV_W :: 48;
EM_NAV_PAD_TOP :: 8;
EM_NAV_ITEM :: 32;
EM_NAV_ICON :: 24;
EM_NAV_MARGIN_UNICODE :: 2;
EM_NAV_MARGIN_GUILD :: 8;
EM_NAV_SEP_MARGIN :: 12;
EM_GRID_PAD_L :: 8;
EM_GRID_PAD_BOTTOM :: 8;
EM_SEARCH_PAD_TOP :: 8;
EM_SECTION_GAP :: 12;
EM_CELL :: 48;
EM_SIZE :: 40; // EmojiSize.MEDIUM
EM_CELL_RADIUS :: 4;
EM_HEADER_H :: 32;
EM_HEADER_FONT :: 14; // text-sm/semibold
EM_HEADER_ICON :: 16;
EM_INSPECTOR_H :: 48;
EM_INSPECTOR_EMOJI :: 28;
EM_FREQUENT_MAX :: 27; // three rows
EM_TONE_GLYPH :: 24;
EM_TONE_BUTTON :: 38; // 24 + 7 * 2
EM_TONE_ITEM :: 38;
EM_SPRITE_PX :: 40; // which spritesheet set (40 or 48)

SPRITE_PER_ROW :: 42; // EmojiSprites.NonDiversityPerRow
SPRITE_DIVERSITY_PER_ROW :: 10; // EmojiSprites.DiversityPerRow

TONE_SURROGATES :: string.["✋", "✋🏻", "✋🏼", "✋🏽", "✋🏾", "✋🏿"];

Pk_Emoji :: struct {
	uni: s32; // emoji_db index, -1 = custom
	id: dc.Snowflake;
	name: string;
	animated: bool;
	guild: dc.Snowflake;
	locked: bool;
}

Em_Section_Kind :: enum u8 {
	Favorites;
	Recent;
	Guild;
	Unicode;
	Search;
}

Em_Section :: struct {
	kind: Em_Section_Kind;
	key: u64; // stable id for collapse state
	title: string;
	icon: string;
	guild: dc.Snowflake;
	items: []Pk_Emoji;
	y: float32; // header top in content space
	rows: int;
}

Em_Pos :: struct {
	sec, idx: int;
}

Emoji_View :: struct {
	scroll: Pk_Scroll;
	inspected: Em_Pos; // sec = -1: none
	collapsed: Table(u64, bool);
	tone_open: bool;
	last_mouse: ui.Vec2;
	keyboard: bool; // last navigation was keyboard (mouse-over doesn't steal until it moves)
	// telemetry: results are reported once the query rests (search_result_viewed)
	search_changed: float64;
	search_reported: bool;
}

EMOJI_SEARCH_VIEWED_DELAY :: 0.3; // seconds the query rests before its results count as viewed

ev: Emoji_View;

emoji_picker_reset :: () {
	ev.scroll = .{};
	ev.inspected = .{-1, 0};
	ev.tone_open = false;
	ev.keyboard = false;
}

emoji_picker_query_changed :: () {
	if app.client != null dc.picker_search_typed(app.client, pk_query(.Emoji));
	ev.search_changed = platform.time_now();
	ev.search_reported = false;
	ev.scroll.target = 0;
	ev.scroll.y = 0;
	ev.inspected = .{-1, 0};
}

// EmojiStore.searchWithoutFetchingLatest: the query (lowercased, spaces and
// underscores removed) is a substring of a name with underscores removed; then
// getSearchResultsOrder: score 1 + 4*exact + 2*word match + 1*prefix, times
// max(1, frecency/100), descending, ties by name. Unlocked before locked.
emoji_search :: (q: string, here: dc.Snowflake, nitro: bool, reaction: bool) -> []Pk_Emoji {
	Hit :: struct {
		e: Pk_Emoji;
		score: float64;
		order: int; // insertion order: keeps the sort stable
	}
	raw := q;
	if ends_with(raw, ":") raw.count -= 1;
	if begins_with(raw, ":") advance(*raw);
	needle := replace(replace(raw, "_", "",, temp), " ", "",, temp);
	if needle == "" return .[];
	matches :: (name: string, needle: string) -> bool {
		return contains(replace(to_lower_copy(name,, temp), "_", "",, temp), needle);
	}
	// (^|_|[A-Z])q s?([A-Z]|_|$) on the lowercased name
	word_match :: (name: string, q: string) -> bool {
		for i: 0..name.count - q.count {
			if (i > 0 && name[i - 1] != #char "_") || string.{q.count, name.data + i} != q continue;
			j := i + q.count;
			if j == name.count || name[j] == #char "_" return true;
			if name[j] == #char "s" && (j + 1 == name.count || name[j + 1] == #char "_") return true;
		}
		return false;
	}
	score_of :: (name0: string, q: string, frec: float64) -> float64 {
		n := to_lower_copy(name0,, temp);
		d: float64 = 1;
		if n == q d += 4;
		if word_match(n, q) d += 2;
		if begins_with(n, q) d += 1;
		return d * max(cast(float64) 1, frec / 100);
	}
	ql := to_lower_copy(raw,, temp);
	fm := ifx reaction then *frecency.reaction else *frecency.emoji;
	unlocked, locked: [..]Hit;
	unlocked.allocator = temp;
	locked.allocator = temp;
	for gid: emoji_guilds(here) {
		g := dc.guild_get(store(), gid);
		if g == null continue;
		for e: g.emojis {
			if !matches(e.name, needle) continue;
			item := custom_item(e, here, nitro);
			list := ifx item.locked then *locked else *unlocked;
			array_add(list, .{item, score_of(e.name, ql, frec_score_of(fm, frec_key(item))), list.count});
		}
	}
	for i: 0..emoji_db.parents - 1 {
		hit := false;
		for emoji_db.emojis[i].names if matches(it, needle) { hit = true; break; }
		if !hit continue;
		item := uni_item(i);
		array_add(*unlocked, .{item, score_of(item.name, ql, frec_score_of(fm, item.name)), unlocked.count});
	}
	order :: (a: Hit, b: Hit) -> int {
		if a.score != b.score return ifx a.score > b.score then -1 else 1;
		c := compare(a.e.name, b.e.name);
		return ifx c != 0 then c else a.order - b.order;
	}
	quick_sort(unlocked, order);
	quick_sort(locked, order);
	out := NewArray(unlocked.count + locked.count, Pk_Emoji,, temp);
	for unlocked out[it_index] = it.e;
	for locked out[unlocked.count + it_index] = it.e;
	return out;
}

// picker_expression_counts: what the emoji picker lists (expression_picker_opened):
// frecent and favorite emoji split by kind, this guild's and all usable custom emoji.
picker_expression_counts :: (reaction: bool, here: dc.Snowflake) -> dc.Expression_Counts {
	n: dc.Expression_Counts;
	s := store();
	animated: Table(dc.Snowflake, bool);
	animated.allocator = temp;
	for gid: emoji_guilds(here) {
		g := dc.guild_get(s, gid);
		if g == null continue;
		for g.emojis table_set(*animated, it.id, it.animated);
		n.custom_total += g.emojis.count;
		if gid == here n.current_guild = g.emojis.count;
	}
	count :: (key: string, animated: *Table(dc.Snowflake, bool), total: *int, anim: *int, custom: *int, standard: *int) {
		total.* += 1;
		id, ok := custom_id(key);
		if ok {
			custom.* += 1;
			_, is_animated := table_find(animated, id);
			if is_animated anim.* += 1;
		} else {
			standard.* += 1;
		}
	}
	for _, k: ifx reaction then frecency.reaction else frecency.emoji count(k, *animated, *n.frecent, *n.animated_frecent, *n.custom_frecent, *n.standard_frecent);
	for frecency.favorite_emojis count(it, *animated, *n.favorites, *n.animated_favorites, *n.custom_favorites, *n.standard_favorites);
	return n;
}

emoji_picker_body :: (r: ui.Rect) {
	emoji_db_load();
	body := row("emoji_body");
	body.semantic_size = .[ui.pct(1), ui.fill()];
	body.cross_align = .Start;
	secs := build_sections();
	grid_rect := ui.Rect.{r.x0 + EM_NAV_W + 1, r.y0, r.x1, r.y1 - EM_INSPECTOR_H};
	cols := max(1, cast(int) ((grid_rect.x1 - grid_rect.x0 - PK_SCROLLBAR_W - EM_GRID_PAD_L) / EM_CELL));
	content_h := layout_sections(secs, cols);
	emoji_keyboard(secs, cols);
	pk_scroll_update(*ev.scroll, grid_rect, content_h);
	nav_secs := secs;
	searching := secs.count > 0 && secs[0].kind == .Search;
	if searching && app.client != null && !ev.search_reported {
		if platform.time_now() - ev.search_changed >= EMOJI_SEARCH_VIEWED_DELAY {
			ev.search_reported = true;
			locked := 0;
			for secs[0].items if it.locked locked += 1;
			dc.picker_search_results(app.client, pk_query(.Emoji), secs[0].items.count, locked);
		} else {
			request_wake(ev.search_changed + EMOJI_SEARCH_VIEWED_DELAY);
		}
	}
	if searching {
		nav_secs = build_sections(true);
		layout_sections(nav_secs, cols);
	}
	{ ui.parent(body); defer ui.pop_parent();
		category_nav(nav_secs, r.y1 - r.y0, searching);
		col := ui.box("emoji_main");
		col.semantic_size = .[ui.fill(), ui.pct(1)];
		col.layout_axis = .Y;
		ui.parent(col); defer ui.pop_parent();
		emoji_grid(secs, cols, grid_rect);
		emoji_inspector(secs);
	}
	if ev.tone_open skin_tone_menu();
}

// The emoji glyph: spritesheet cell for unicode (text fallback while the sheet
// loads or offline), CDN image for custom (animated on hover).
pk_emoji_box :: (id: string, item: Pk_Emoji, size: float32, hovered: bool) -> *ui.Box {
	if item.uni < 0 {
		b := ui.box(id);
		b.semantic_size = .[ui.px(size), ui.px(size)];
		set_remote_image(b, dc.custom_emoji_url(item.id, item.animated && hovered, 48));
		return b;
	}
	tone := frecency.skin_tone;
	e := *emoji_db.emojis[item.uni];
	if e.sprite >= 0 {
		url := sprite_url(e.children.count > 0, tone);
		im := image_get(url);
		if im != null && im.state == .Ready {
			b := ui.box(id);
			b.semantic_size = .[ui.px(size), ui.px(size)];
			d := New(Sprite_Draw,, temp);
			d.* = .{url = url, index = e.sprite, per_row = ifx e.children.count > 0 then SPRITE_DIVERSITY_PER_ROW else SPRITE_PER_ROW};
			b.custom_draw = sprite_draw;
			b.custom_user = d;
			return b;
		}
	}
	b := label(emoji_db.emojis[emoji_toned(item.uni, tone)].surr, .Normal, size * 0.8, .{1, 1, 1, 1}, size);
	b.semantic_size = .[ui.px(size), ui.px(size)];
	b.style.text_align = .Center;
	return b;
}

skin_tone_button :: () {
	b := ui.box("tone", .Clickable | .Draw_Background | .Hot_Animation);
	b.semantic_size = .[ui.px(EM_TONE_BUTTON), ui.px(EM_TONE_BUTTON)];
	b.style.radius = all4(4);
	b.style.bg_hot = T("--interactive-background-hover");
	b.layout_axis = .X;
	b.cross_align = .Center;
	sig := ui.signal(b);
	{ ui.parent(b); defer ui.pop_parent();
		spacer(.X, (EM_TONE_BUTTON - EM_TONE_GLYPH) / 2);
		tone_glyph("g", frecency.skin_tone, EM_TONE_GLYPH);
	}
	if sig.clicked ev.tone_open = !ev.tone_open;
}

premium :: () -> bool {
	u := dc.user_get(store(), store().me);
	return u != null && u.premium_type > 0;
}

current_guild :: () -> dc.Snowflake {
	c := dc.channel_get(store(), pk.channel);
	return ifx c then c.guild_id else 0;
}

// Custom emoji usable here? Without Nitro: only this guild's, and not animated.
custom_locked :: (e: dc.Emoji, here: dc.Snowflake, nitro: bool) -> bool {
	if !e.available return true;
	if nitro return false;
	return e.guild_id != here || e.animated;
}

uni_item :: (idx: int) -> Pk_Emoji {
	return .{uni = cast(s32) idx, name = emoji_db.emojis[idx].names[0]};
}

custom_item :: (e: dc.Emoji, here: dc.Snowflake, nitro: bool) -> Pk_Emoji {
	return .{uni = -1, id = e.id, name = e.name, animated = e.animated, guild = e.guild_id, locked = custom_locked(e, here, nitro)};
}

frec_key :: (e: Pk_Emoji) -> string {
	return ifx e.uni >= 0 then e.name else tprint("%", e.id);
}

// What inserting an emoji puts in the composer: the unicode in the chosen skin
// tone, or the custom emoji markup.
emoji_item_text :: (item: Pk_Emoji) -> string {
	if item.uni >= 0 return emoji_db.emojis[emoji_toned(item.uni, frecency.skin_tone)].surr;
	return custom_emoji_markup(item.name, item.id, item.animated);
}

// Guild order for custom emoji: the current guild first, then the sidebar order.
emoji_guilds :: (here: dc.Snowflake) -> []dc.Snowflake {
	out: [..]dc.Snowflake;
	out.allocator = temp;
	if here != 0 array_add(*out, here);
	for guild_order() if it != here array_add(*out, it);
	return out;
}

#scope_file

// Spritesheets from the client bundle (spritesheet-emoji-{40,48}, spritesheet-{tone}-{40,48}).
SPRITE_EMOJI :: string.[
	"https://cdn.discordapp.com/assets/content/c357d57faac49918709981e6fb30e526fa62b6d440f99fd8bd2b88f0542ad6c5.png", // 40
	"https://cdn.discordapp.com/assets/content/91eab03bbed7fa52a213659925fa7af29c5d8e32d727eb2f90cc777f4edd9afb.png" // 48
];
// [size][tone 0..5]: tone 0 is spritesheet--{size} (diversity emoji without a tone)
SPRITE_TONES :: [6]string.[
	.[
		"https://cdn.discordapp.com/assets/content/2f1adbbeee210ebdfaf92e6cdb29be32af98df2f576a85c6f18515eecb49a628.png",
		"https://cdn.discordapp.com/assets/content/112053a6b05b0d3869dde1b52ab452dd6286515848e4dc8145095b6c757fb126.png",
		"https://cdn.discordapp.com/assets/content/8c716c8c5de61506e1bc3df1beab3e1bb9313ae5dfbb5b555cad60fbbc2a1fa6.png",
		"https://cdn.discordapp.com/assets/content/5885b33027a6383a93d1021abb3f7b1c4096257eac03829456430f6453154bbd.png",
		"https://cdn.discordapp.com/assets/content/d474fadfda8e1fa265be85f90fd78232ebb8c87667435ee8d32719aec28f17de.png",
		"https://cdn.discordapp.com/assets/content/050dcea8f727152a7eb98afdced8d85c1ccdfe9bcb81eb7a14989f2e452e4ad8.png"
	],
	.[
		"https://cdn.discordapp.com/assets/content/14e7ef6e372a0fd01b5a6e0436ce962cd61e7dacc8fb49888f9a997387a16041.png",
		"https://cdn.discordapp.com/assets/content/4e982c3eafac47f662e857b00b64b9801948b6b336f256cb8d3b768e4c8f9c7c.png",
		"https://cdn.discordapp.com/assets/content/fca48430d7ea5c68dba8d5c78b2f5d5e15546209fb669315f51a272808e2ef73.png",
		"https://cdn.discordapp.com/assets/content/88f20b32afd12ac9e4fe0a630cfdae8889fd810b81b79231e1991e70c0a26768.png",
		"https://cdn.discordapp.com/assets/content/6b84fe748077d9a437df4481644802dade5d86e78120182e549ed84f408d0d21.png",
		"https://cdn.discordapp.com/assets/content/2bbfef2ff9e844a977273ef48a15bf62ec50ff5b457743a9ba2aa2e1ebd2953f.png"
	]
];

// Frecency / favorite keys longer than 6 digits are custom emoji ids.
custom_id :: (key: string) -> dc.Snowflake, bool {
	id, ok, rest := string_to_int(key, T = u64);
	return id, ok && !rest && key.count > 6;
}

build_sections :: (ignore_query := false) -> []Em_Section {
	emoji_db_load();
	s := store();
	here := current_guild();
	nitro := premium();
	secs: [..]Em_Section;
	secs.allocator = temp;
	q := ifx ignore_query then "" else pk_query(.Emoji);
	if q != "" {
		array_add(*secs, .{kind = .Search, key = 1, items = emoji_search(q, here, nitro, pk.mode == .Reaction)});
		return secs;
	}
	by_id: Table(dc.Snowflake, dc.Emoji);
	by_id.allocator = temp;
	for gid: emoji_guilds(current_guild()) {
		g := dc.guild_get(s, gid);
		if g for g.emojis table_set(*by_id, it.id, it);
	}
	key_item :: (key: string, by_id: *Table(dc.Snowflake, dc.Emoji), here: dc.Snowflake, nitro: bool) -> Pk_Emoji, bool {
		id, custom := custom_id(key);
		if custom {
			e := table_find_pointer(by_id, id);
			if e return custom_item(e.*, here, nitro), true;
			return .{}, false;
		}
		found, i := table_find(*emoji_db.by_name, key);
		if found && i < emoji_db.parents return uni_item(i), true;
		return .{}, false;
	}

	if frecency.favorite_emojis.count > 0 {
		items: [..]Pk_Emoji;
		items.allocator = temp;
		for frecency.favorite_emojis {
			item, ok := key_item(it, *by_id, here, nitro);
			if ok array_add(*items, item);
		}
		if items.count > 0 array_add(*secs, .{kind = .Favorites, key = 2, title = "Favorites", icon = "star", items = items});
	}
	{
		reaction := pk.mode == .Reaction;
		items: [..]Pk_Emoji;
		items.allocator = temp;
		seen: Table(string, bool);
		seen.allocator = temp;
		top := frec_top(ifx reaction then frecency.reaction else frecency.emoji, EM_FREQUENT_MAX);
		defaults := ifx reaction then emoji_db.default_reaction else emoji_db.default_frecency;
		for pass: 0..1 for k: ifx pass == 0 then top else defaults {
			// defaults only seed an empty history (the reference shows just the 3 real entries)
			if pass == 1 && (items.count >= EM_FREQUENT_MAX || frec_had(reaction)) break;
			item, ok := key_item(k, *by_id, here, nitro);
			if ok && !table_contains(*seen, k) {
				array_add(*items, item);
				table_set(*seen, k, true);
			}
		}
		if items.count > 0 array_add(*secs, .{kind = .Recent, key = 3, title = "Frequently Used", icon = "clock", items = items});
	}
	for gid: emoji_guilds(current_guild()) {
		g := dc.guild_get(s, gid);
		if g == null || g.emojis.count == 0 continue;
		items := NewArray(g.emojis.count, Pk_Emoji,, temp);
		for g.emojis items[it_index] = custom_item(it, here, nitro);
		array_add(*secs, .{kind = .Guild, key = gid, title = g.name, guild = gid, items = items});
	}
	for c, ci: emoji_db.cats {
		items := NewArray(c.end - c.start, Pk_Emoji,, temp);
		for * items it.* = uni_item(c.start + it_index);
		array_add(*secs, .{kind = .Unicode, key = 100 + cast(u64) ci, title = emoji_category_title(c.key), icon = emoji_category_icon(c.key), items = items});
	}
	return secs;
}

frec_had :: (reaction: bool) -> bool {
	return (ifx reaction then frecency.reaction.count else frecency.emoji.count) > 0;
}

is_collapsed :: (key: u64) -> bool {
	_, collapsed := table_find(*ev.collapsed, key);
	return collapsed;
}

// Lay sections out in content space; returns total height.
layout_sections :: (secs: []Em_Section, cols: int) -> float32 {
	y: float32 = 0;
	for * sc, i: secs {
		if sc.kind == .Search y += EM_SEARCH_PAD_TOP;
		sc.y = y;
		if sc.kind != .Search y += EM_HEADER_H;
		sc.rows = (sc.items.count + cols - 1) / cols;
		collapsed := is_collapsed(sc.key) && sc.kind != .Search;
		if collapsed sc.rows = 0;
		y += cast(float32) sc.rows * EM_CELL;
		if !collapsed && i + 1 < secs.count y += EM_SECTION_GAP;
	}
	return y + EM_GRID_PAD_BOTTOM;
}

body_top :: (sc: *Em_Section) -> float32 {
	return sc.y + ifx sc.kind != .Search then cast(float32) EM_HEADER_H else 0;
}

category_nav :: (secs: []Em_Section, h: float32, searching: bool) {
	nav := ui.box("emoji_nav", .Clip | .Scroll_Y);
	nav.semantic_size = .[ui.px(EM_NAV_W), ui.px(h)];
	nav.layout_axis = .Y;
	nav.cross_align = .Center;
	ui.signal(nav);
	ui.parent(nav); defer ui.pop_parent();
	spacer(.Y, EM_NAV_PAD_TOP);
	cur := ifx searching then -1 else current_section(secs);
	had_custom := false;
	first_unicode := true;
	for * sc, i: secs {
		if sc.kind == .Search continue;
		if sc.kind == .Unicode && first_unicode {
			first_unicode = false;
			if had_custom {
				// .guildCategorySeparator: 1px --border-subtle, 12px margins
				// (the margin above comes from the previous item's 8 + 4)
				sep := ui.box(tprint("sep%", i), .Draw_Background);
				sep.semantic_size = .[ui.px(EM_NAV_ITEM), ui.px(1)];
				sep.style.bg = T("--border-subtle");
				spacer(.Y, EM_NAV_SEP_MARGIN);
			}
		}
		if sc.kind == .Guild had_custom = true;
		active := cur == i;
		ui.id_scope(sc.key);
		slot := ui.box("slot", .Clickable | .Draw_Background | .Hot_Animation);
		slot.semantic_size = .[ui.px(EM_NAV_ITEM), ui.px(EM_NAV_ITEM)];
		slot.layout_axis = .X;
		slot.cross_align = .Center;
		sig := ui.signal(slot);
		{ ui.parent(slot); defer ui.pop_parent();
			if sc.kind == .Guild {
				gi := ui.box("##gicon", .Draw_Background | .Draw_Text);
				gi.semantic_size = .[ui.px(EM_NAV_ITEM), ui.px(EM_NAV_ITEM)];
				gi.style.radius = all4(cast(float32) (ifx active || sig.hovering then 10 else EM_NAV_ITEM / 2));
				gi.style.bg = T("--background-mod-subtle");
				gi.style.text_align = .Center;
				gi.style.font = F(.Medium);
				gi.style.font_size = 11;
				gi.style.text_color = T("--text-default");
				g := dc.guild_get(store(), sc.guild);
				if g {
					if g.icon != "" set_remote_image(gi, dc.guild_icon_url(sc.guild, g.icon, 64));
					else gi.text = guild_initials(g.name);
				}
				if active {
					// .categoryPill on the nav's left edge
					pill := ui.box("pill", .Draw_Background | .Floating_X | .Floating_Y);
					pill.semantic_size = .[ui.px(4), ui.px(20)];
					pill.fixed_pos = .{-8, 6};
					pill.style.bg = T("--text-strong");
					pill.style.radius = .[0, 4, 0, 4];
				}
			} else {
				// .categoryItemDefaultCategory: 24 icon, 4 padding, radius 4
				slot.style.radius = all4(4);
				slot.style.bg = ifx active then T("--background-base-low") else .{};
				slot.style.bg_hot = ifx active then slot.style.bg else T("--interactive-background-hover");
				spacer(.X, (EM_NAV_ITEM - EM_NAV_ICON) / 2);
				c := ifx active then T("--interactive-text-active") else ifx sig.hovering then T("--interactive-text-hover") else T("--interactive-text-default");
				icon("ic", sc.icon, EM_NAV_ICON, c);
			}
		}
		if sig.clicked {
			if searching ui.editor_set_text(*pk.search[Picker_Tab.Emoji], "");
			table_set(*ev.collapsed, sc.key, false);
			ev.scroll.target = sc.y;
		}
		ui.pop_seed();
		spacer(.Y, ifx sc.kind == .Unicode then cast(float32) EM_NAV_MARGIN_UNICODE else cast(float32) EM_NAV_MARGIN_GUILD);
	}
	spacer(.Y, 8);
}

// Section whose span contains the scroll top.
current_section :: (secs: []Em_Section) -> int {
	cur := 0;
	for secs if it.y <= ev.scroll.y + 1 cur = it_index;
	return cur;
}

// ExpressionPickerListSectionHeading: 32 high, padding 8/4, icon, text-sm/semibold
// label, collapse chevron; --text-default, --interactive-text-active on hover.
section_header :: (sc: *Em_Section, id: string, y: float32, w: float32) {
	h := row(id, .Floating_X | .Floating_Y | .Clickable | .Draw_Background);
	h.semantic_size = .[ui.px(w), ui.px(EM_HEADER_H)];
	h.fixed_pos = .{0, y};
	h.style.bg = T("--background-surface-high");
	sig := ui.signal(h);
	collapsed := is_collapsed(sc.key);
	c := ifx sig.hovering then T("--interactive-text-active") else T("--text-default");
	{ ui.parent(h); defer ui.pop_parent();
		spacer(.X, 8);
		if sc.kind == .Guild {
			gi := ui.box("gi", .Draw_Background);
			gi.semantic_size = .[ui.px(EM_HEADER_ICON), ui.px(EM_HEADER_ICON)];
			gi.style.radius = all4(4);
			gi.style.bg = T("--background-mod-subtle");
			g := dc.guild_get(store(), sc.guild);
			if g != null && g.icon != "" set_remote_image(gi, dc.guild_icon_url(sc.guild, g.icon, 32));
		} else {
			icon("hi", sc.icon, EM_HEADER_ICON, c);
		}
		spacer(.X, 4);
		t := label(sc.title, .Semibold, EM_HEADER_FONT, c, 18);
		t.flags |= .Clip;
		spacer(.X, 4);
		icon("chev", ifx collapsed then "chevron-small-right" else "chevron-small-down", 16, c);
		filler(.X);
	}
	if sig.clicked table_set(*ev.collapsed, sc.key, !collapsed);
}

emoji_grid :: (secs: []Em_Section, cols: int, view: ui.Rect) {
	w := view.x1 - view.x0;
	vh := view.y1 - view.y0;
	list := ui.box("emoji_grid", .Clip);
	list.semantic_size = .[ui.pct(1), ui.px(vh)];
	top := ev.scroll.y;
	moved := app.ui.mouse != ev.last_mouse;
	ev.last_mouse = app.ui.mouse;
	if moved ev.keyboard = false;
	ui.parent(list); defer ui.pop_parent();
	for * sc, si: secs {
		body_y := body_top(sc);
		end_y := body_y + cast(float32) sc.rows * EM_CELL;
		if end_y < top - EM_CELL || sc.y > top + vh + EM_CELL continue;
		ui.id_scope(sc.key); defer ui.pop_seed();
		if sc.kind != .Search section_header(sc, "hdr", sc.y - top, w);
		r0 := max(0, cast(int) ((top - body_y) / EM_CELL) - 1);
		r1 := min(sc.rows, cast(int) ((top + vh - body_y) / EM_CELL) + 2);
		for rr: r0..r1 - 1 {
			for cc: 0..cols - 1 {
				i := rr * cols + cc;
				if i >= sc.items.count break;
				item := sc.items[i];
				ui.id_scope(cast(u64) i); defer ui.pop_seed();
				cell := ui.box("cell", .Clickable | .Floating_X | .Floating_Y | .Draw_Background);
				cell.semantic_size = .[ui.px(EM_CELL), ui.px(EM_CELL)];
				cell.fixed_pos = .{EM_GRID_PAD_L + cast(float32) cc * EM_CELL, body_y + cast(float32) rr * EM_CELL - top};
				cell.style.radius = all4(EM_CELL_RADIUS);
				sig := ui.signal(cell);
				if sig.hovering && (moved || !ev.keyboard) ev.inspected = .{si, i};
				inspected := ev.inspected.sec == si && ev.inspected.idx == i;
				if inspected cell.style.bg = T("--interactive-background-selected");
				{ ui.parent(cell); defer ui.pop_parent();
					e := pk_emoji_box("e", item, EM_SIZE, inspected && sig.hovering);
					e.flags |= .Floating_X | .Floating_Y;
					e.fixed_pos = .{(EM_CELL - EM_SIZE) / 2, (EM_CELL - EM_SIZE) / 2};
					if item.locked {
						e.opacity = 0.3;
						lk := ui.box("lock", .Floating_X | .Floating_Y);
						lk.semantic_size = .[ui.px(14), ui.px(14)];
						lk.fixed_pos = .{EM_CELL - 18, EM_CELL - 18};
						set_icon(lk, "lock", T("--text-default"));
					}
				}
				if sig.clicked {
					ev.inspected = .{si, i};
					emoji_select(item, (app.ui_mods & .Shift) != 0);
				}
			}
		}
	}
	// sticky header: the section under the scroll top, pushed up by the next header
	if secs.count > 0 && secs[0].kind != .Search {
		cur := current_section(secs);
		y: float32 = 0;
		if cur + 1 < secs.count {
			nxt := secs[cur + 1].y - top;
			if nxt < EM_HEADER_H y = nxt - EM_HEADER_H;
		}
		ui.id_scope(0xffff);
		section_header(*secs[cur], "sticky", y, w);
		ui.pop_seed();
	}
	if secs.count == 1 && secs[0].kind == .Search && secs[0].items.count == 0 {
		msg := ui.box("empty", .Floating_X | .Floating_Y);
		msg.semantic_size = .[ui.px(w), ui.px(vh)];
		msg.layout_axis = .Y;
		msg.cross_align = .Center;
		ui.parent(msg); defer ui.pop_parent();
		spacer(.Y, vh / 2 - 40);
		label("No emoji found", .Semibold, 16, T("--text-strong"), 20);
		spacer(.Y, 4);
		label("Try searching for something else", .Normal, 14, T("--text-muted"), 18);
	}
	pk_scrollbar(*ev.scroll);
}

// Arrow keys move the inspected emoji through the grid; Enter selects.
emoji_keyboard :: (secs: []Em_Section, cols: int) {
	if pk.keys.count == 0 || pk.tab != .Emoji || pk.closing return;
	// item rows in order: (section, first index)
	Row :: struct {
		sec, start, count: int;
	}
	rows: [..]Row;
	rows.allocator = temp;
	for sc, si: secs {
		for rr: 0..sc.rows - 1 array_add(*rows, .{si, rr * cols, min(cols, sc.items.count - rr * cols)});
	}
	if rows.count == 0 return;
	cur_row, cur_col := -1, 0;
	if ev.inspected.sec >= 0 {
		for rows {
			if it.sec == ev.inspected.sec && ev.inspected.idx >= it.start && ev.inspected.idx < it.start + it.count {
				cur_row = it_index;
				cur_col = ev.inspected.idx - it.start;
			}
		}
	}
	for e: pk.keys {
		if e.key == {
		case .Enter;
			if cur_row < 0 {
				cur_row = 0;
				cur_col = 0;
			}
			rw := rows[cur_row];
			emoji_select(secs[rw.sec].items[rw.start + min(cur_col, rw.count - 1)], (e.mods & .Shift) != 0);
			continue;
		case .Left;
			if cur_row < 0 { cur_row = 0; cur_col = 0; }
			else if cur_col > 0 cur_col -= 1;
			else if cur_row > 0 { cur_row -= 1; cur_col = rows[cur_row].count - 1; }
		case .Right;
			if cur_row < 0 { cur_row = 0; cur_col = 0; }
			else if cur_col + 1 < rows[cur_row].count cur_col += 1;
			else if cur_row + 1 < rows.count { cur_row += 1; cur_col = 0; }
		case .Up;
			cur_row = max(0, cur_row - 1);
		case .Down;
			cur_row = ifx cur_row < 0 then 0 else min(cur_row + 1, rows.count - 1);
		case .Page_Up;
			cur_row = max(0, cur_row - 6);
		case .Page_Down;
			cur_row = min(rows.count - 1, max(cur_row, 0) + 6);
		case;
			continue;
		}
		cur_col = min(cur_col, rows[cur_row].count - 1);
		rw := rows[cur_row];
		ev.inspected = .{rw.sec, rw.start + cur_col};
		ev.keyboard = true;
		sc := *secs[rw.sec];
		y := body_top(sc) + cast(float32) (ev.inspected.idx / cols) * EM_CELL;
		pk_scroll_reveal(*ev.scroll, y, y + EM_CELL, ifx sc.kind != .Search then cast(float32) EM_HEADER_H else 0.0);
	}
}

// .inspector: --background-base-lower, 1px --border-normal top, padding 0 16,
// graphic 28, text 8 after; secondary title --interactive-text-default.
emoji_inspector :: (secs: []Em_Section) {
	line := ui.box("insline", .Draw_Background);
	line.semantic_size = .[ui.pct(1), ui.px(1)];
	line.style.bg = T("--border-normal");
	bar := row("inspector", .Draw_Background);
	bar.semantic_size = .[ui.pct(1), ui.px(EM_INSPECTOR_H - 1)];
	bar.style.bg = T("--background-base-lower");
	item: Pk_Emoji;
	have := false;
	sel := ev.inspected;
	if sel.sec >= 0 && sel.sec < secs.count && sel.idx < secs[sel.sec].items.count {
		item = secs[sel.sec].items[sel.idx];
		have = true;
	} else if secs.count > 0 && secs[0].items.count > 0 {
		item = secs[0].items[0];
		have = true;
	}
	ui.parent(bar); defer ui.pop_parent();
	spacer(.X, 16);
	if !have return;
	pk_emoji_box("ie", item, EM_INSPECTOR_EMOJI, true);
	spacer(.X, 8);
	g := ifx item.uni < 0 then dc.guild_get(store(), item.guild) else null;
	col := ui.box("names");
	col.semantic_size = .[ui.fill(), ui.children()];
	col.layout_axis = .Y;
	{ ui.parent(col); defer ui.pop_parent();
		n := label(tprint(":%:", emoji_display_name(item)), .Semibold, 16, T("--text-strong"), 20);
		n.flags |= .Clip;
		if item.uni < 0 label(tprint("from %", ifx g then g.name else ""), .Normal, 12, T("--interactive-text-default"), 16);
	}
	if item.uni < 0 {
		if g {
			gi := ui.box("gs", .Draw_Background);
			gi.semantic_size = .[ui.px(32), ui.px(32)];
			gi.style.radius = all4(10);
			gi.style.bg = T("--background-mod-subtle");
			if g.icon != "" set_remote_image(gi, dc.guild_icon_url(g.id, g.icon, 64));
		}
		spacer(.X, 16);
	}
}

// Inspector title: every alias, ":thumbsup: :+1: :thumbup: :thumbs_up:" like the client.
emoji_display_name :: (item: Pk_Emoji) -> string {
	if item.uni < 0 return item.name;
	return join(..emoji_db.emojis[emoji_toned(item.uni, frecency.skin_tone)].names, separator = ": :",, temp);
}

sprite_url :: (diversity: bool, tone: int) -> string {
	si := ifx EM_SPRITE_PX == 48 then 1 else 0;
	return ifx diversity then SPRITE_TONES[si][clamp(tone, 0, 5)] else SPRITE_EMOJI[si];
}

Sprite_Draw :: struct {
	url: string;
	index: int;
	per_row: int;
}

sprite_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Sprite_Draw) user;
	im := image_get(d.url);
	tex := image_texture(im);
	if tex == 0 return;
	cell := cast(float32) im.size.x / cast(float32) d.per_row;
	cx := cast(float32) (d.index % d.per_row) * cell;
	cy := cast(float32) (d.index / d.per_row) * cell;
	c := gfx.Color.{1, 1, 1, b.opacity};
	gfx.push_rect(.{dst = cast,force(gfx.Rect) b.rect, tex = tex, src = .{cx, cy, cx + cell, cy + cell}, colors = .[c, c, c, c]});
}

// Insert into the composer, or react. Shift keeps the picker open.
emoji_select :: (item: Pk_Emoji, keep_open: bool) {
	if item.locked return;
	text := emoji_item_text(item);
	name := ifx item.uni >= 0 then text else item.name;
	key := frec_key(item);
	if app.client != null dc.picker_emoji_selected(app.client, item.name, item.id, item.guild, item.animated, item.locked);
	if pk.mode == .Reaction {
		frec_use(*frecency.reaction, key);
		if app.client != null {
			m := find_message(pk.message);
			// opened from the "+" after the reactions: Inline Button; toolbar / menu: Reaction Picker
			if m != null react(m, .{id = item.id, name = name, animated = item.animated}, ifx pk.from_inline then "Message Inline Button" else "Message Reaction Picker");
		}
	} else {
		frec_use(*frecency.emoji, key);
		ui.editor_insert(ifx pk.mode == .Edit then *ma.edit_editor else *chat_state(pk.channel).editor, text);
	}
	if !keep_open picker_close();
}

tone_glyph :: (id: string, tone: int, size: float32) {
	found, idx := table_find(*emoji_db.by_name, "clap"); // the client's tone selector shows clapping hands
	if found {
		pk_emoji_box(id, .{uni = cast(s32) idx}, size, false);
		return;
	}
	l := label(TONE_SURROGATES[clamp(tone, 0, 5)], .Normal, size * 0.8, .{1, 1, 1, 1}, size);
	l.semantic_size = .[ui.px(size), ui.px(size)];
}

// Vertical list of the six tones, dropping down over the search row's right edge.
skin_tone_menu :: () {
	r := pk.rect;
	// .diversitySelectorOptions: over the button (top -1, right -1), growing down
	x := r.x1 - PK_HEADER_PAD_X - EM_TONE_BUTTON - 1;
	y := r.y0 + picker_header_h() - 1 - PK_HEADER_PAD_BOTTOM - PK_SEARCH_H + (PK_SEARCH_H - EM_TONE_BUTTON) / 2 - 1;
	m := ui.box("tonemenu", .Floating_X | .Floating_Y | .Draw_Background | .Draw_Border | .Draw_Shadow | .Clickable);
	m.semantic_size = .[ui.px(EM_TONE_BUTTON + 2), ui.px(EM_TONE_ITEM * 6 + 2)];
	m.fixed_pos = .{x - r.x0, y - r.y0 - picker_header_h()};
	m.style.bg = T("--background-surface-higher");
	m.style.border_color = T("--border-subtle");
	m.style.border = 1;
	m.style.radius = all4(4);
	for app.ui.events {
		if it.kind == .Mouse_Down && !pk_contains(m.rect, it.pos) && m.rect.x1 > m.rect.x0 ev.tone_open = false;
	}
	m.style.shadow_color = .{0, 0, 0, 0.24};
	m.style.shadow_blur = 8;
	m.layout_axis = .Y;
	ui.signal(m);
	saved := frecency.skin_tone;
	{ ui.parent(m); defer ui.pop_parent();
		// current first, then the rest in order
		order := int.[saved, 0, 1, 2, 3, 4];
		n := 1;
		for t: 0..5 if t != saved { order[n] = t; n += 1; }
		spacer(.Y, 1);
		for t: order {
			b := ui.box(tprint("t%", t), .Clickable | .Draw_Background | .Hot_Animation);
			b.semantic_size = .[ui.pct(1), ui.px(EM_TONE_ITEM)];
			b.style.bg_hot = T("--interactive-background-hover");
			b.layout_axis = .X;
			b.cross_align = .Center;
			sig := ui.signal(b);
			frecency.skin_tone = t;
			{ ui.parent(b); defer ui.pop_parent();
				spacer(.X, 1 + (EM_TONE_BUTTON - EM_TONE_GLYPH) / 2);
				tone_glyph("g", t, EM_TONE_GLYPH);
			}
			frecency.skin_tone = saved;
			if sig.clicked {
				saved = t;
				ev.tone_open = false;
				frecency_save();
			}
		}
	}
	frecency.skin_tone = saved;
}
