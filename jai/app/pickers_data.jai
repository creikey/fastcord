#scope_file

// Discord's unicode emoji database (assets/emoji/emoji.json, extracted from
// the client bundle) plus local frecency / skin tone persistence.

// Discord's unicode emoji database (assets/emoji/emoji.json, extracted from
// the client bundle) plus local frecency / skin tone persistence.

EMOJI_JSON := #run load_file("../../assets/emoji/emoji.json", #filepath);
#scope_export

Uni_Emoji :: struct {
	names: []string; // names[0] is the canonical shortcode
	surr: string;
	asset: string; // twemoji asset hash (https://discord.com/assets/<u>.svg)
	sprite: int; // spritesheet index; -1 = none (children)
	children: []s32; // skin tone variants (5, or 25 for multi-person)
	multi: bool;
}

Emoji_Category :: struct {
	key: string; // people, nature, ...
	start: int;
	end: int;
}

Emoji_DB :: struct {
	loaded: bool;
	emojis: []Uni_Emoji;
	cats: []Emoji_Category;
	by_name: Map(string, int); // every alias -> index
	by_surr: Map(string, int);
	default_frecency: []string;
	default_reaction: []string;
	parents: int; // emojis [0, parents) are pickable; children follow
}

emoji_db: Emoji_DB;

emoji_db_load :: () {
	if emoji_db.loaded { return; }
	emoji_db.loaded = true;
	v, err := json.parse(EMOJI_JSON, allocator = temp);
	if err != .None { return; }
	root := ifx v.kind == .Map then v.map else .{};
	strs :: (v: json.Value) -> []string {
		arr := ifx v.kind == .List then v.list else zero(type_of(v.list));
		out := make_slice(string, len(arr));
		for x, i: arr { at(*out, i).* = clone(ifx x.kind == .String then x.s else ""); }
		return out;
	}
	num :: (v: json.Value) -> int {
		if v.kind == {
		case .Int; x := v.i;
			return cast(int)(x);
		case .Float; x := v.f;
			return cast(int)(x);
		}
		return 0;
	}
	list := ifx get(root, "emojis").kind == .List then get(root, "emojis").list else zero(type_of(get(root, "emojis").list));
	emoji_db.emojis = make_slice(Uni_Emoji, len(list));
	for ev, i: list {
		o := ifx ev.kind == .Map then ev.map else .{};
		e := *emoji_db.emojis[i];
		e.names = strs(get(o, "n"));
		e.surr = clone(ifx get(o, "s").kind == .String then get(o, "s").s else "");
		e.asset = clone(ifx get(o, "u").kind == .String then get(o, "u").s else "");
		e.sprite = -1;
		{ sp, ok := map_find(o, "sp");
		if ok { e.sprite = num(sp); } }
		{ dcv, ok := map_find(o, "dc");
		if ok {
			arr := ifx dcv.kind == .List then dcv.list else zero(type_of(dcv.list));
			e.children = make_slice(s32, len(arr));
			for x, j: arr { e.children[j] = cast(s32)(num(x)); }
		} }
		{ md, ok := map_find(o, "md");
		if ok { e.multi = num(md) != 0; } }
		for n: e.names { if !has(emoji_db.by_name, n) { at(*emoji_db.by_name, n).* = i; } }
		if !has(emoji_db.by_surr, e.surr) { at(*emoji_db.by_surr, e.surr).* = i; }
	}
	cats := ifx get(root, "categories").kind == .List then get(root, "categories").list else zero(type_of(get(root, "categories").list));
	emoji_db.cats = make_slice(Emoji_Category, len(cats));
	for cv, i: cats {
		a := ifx cv.kind == .List then cv.list else zero(type_of(cv.list));
		if len(a) < 3 { continue; }
		emoji_db.cats[i] = .{clone(ifx a[0].kind == .String then a[0].s else ""), num(a[1]), num(a[2])};
		emoji_db.parents = max(emoji_db.parents, num(a[2]));
	}
	emoji_db.default_frecency = strs(get(root, "default_frecency"));
	emoji_db.default_reaction = strs(get(root, "default_reaction_frecency"));
}

// Skin-toned variant (tone 1..5) of a parent emoji; multi-person emoji use the same tone twice.
emoji_toned :: (idx: int, tone: int) -> int {
	if tone <= 0 || idx < 0 || idx >= len(emoji_db.emojis) { return idx; }
	e := *emoji_db.emojis[idx];
	if len(e.children) == 0 { return idx; }
	ci := ifx e.multi then (tone - 1) * 6 else tone - 1;
	if ci >= len(e.children) { return idx; }
	return cast(int)(e.children[ci]);
}

emoji_category_title :: (key: string) -> string {
	if key == {
	case "people";
		return "People";
	case "nature";
		return "Nature";
	case "food";
		return "Food & Drink";
	case "activity";
		return "Activities";
	case "travel";
		return "Travel & Places";
	case "objects";
		return "Objects";
	case "symbols";
		return "Symbols";
	case "flags";
		return "Flags";
	}
	return key;
}

emoji_category_icon :: (key: string) -> string {
	if key == {
	case "people";
		return "emoji-people";
	case "nature";
		return "nature";
	case "food";
		return "food";
	case "activity";
		return "game-controller";
	case "travel";
		return "bicycle";
	case "objects";
		return "object";
	case "symbols";
		return "heart";
	case "flags";
		return "flag";
	}
	return "reaction";
}

// ---- frecency ----
// Score like the client's Frecency util: total uses times the mean weight of
// the recent uses (weights by age: 3 d 100, 15 d 70, 30 d 50, 45 d 30, 80 d 10).

FRECENCY_MAX_RECENT :: 10;

Frec_Entry :: struct {
	total: int;
	recent: [..]s64; // unix ms, newest last
}

Frecency :: struct {
	emoji: Map(string, Frec_Entry); // unicode canonical name or custom emoji id
	reaction: Map(string, Frec_Entry);
	sticker: Map(string, Frec_Entry);
	favorite_emojis: [..]string;
	favorite_stickers: [..]dc.Snowflake;
	favorite_gifs: [..]dc.Favorite_Gif;
	skin_tone: int; // 0 = default yellow, 1..5
	loaded_local: bool;
	loaded_server: bool;
	dirty: bool;
}

frecency: Frecency;

frec_now_ms :: () -> s64 {return time.time_to_unix_nano(time.now()) / 1000000;}
#scope_file

frec_weight :: (age_ms: s64) -> float64 {
	days := cast(float64)(age_ms) / 86_400_000;
	if days <= 3 {
		return 100;
	} else if days <= 15 {
		return 70;
	} else if days <= 30 {
		return 50;
	} else if days <= 45 {
		return 30;
	} else if days <= 80 {
		return 10;
	}
	return 0;
}
#scope_export

frec_score :: (e: Frec_Entry, now: s64) -> float64 {
	if len(e.recent) == 0 { return cast(float64)(e.total); }
	sum: float64;
	for t: e.recent { sum += frec_weight(now - t); }
	return cast(float64)(e.total) * sum / cast(float64)(len(e.recent));
}

frec_use :: (m: *Map(string, Frec_Entry), key: string) {
	if key == "" { return; }
	e, ok := map_find_ptr(m, key);
	if !ok {
		at(m, clone(key)).* = .{};
		e = at(m, key);
	}
	e.total += 1;
	append(*e.recent, frec_now_ms());
	if len(e.recent) > FRECENCY_MAX_RECENT { ordered_remove(*e.recent, 0); }
	frecency.dirty = true;
	frecency_save();
}

// Keys by descending score.
frec_top :: (m: Map(string, Frec_Entry), n: int) -> []string {
	Pair :: struct {
		key: string;
		score: float64;
	}
	now := frec_now_ms();
	pairs := make_dynamic(Pair, 0, len(m), temp);
	for k, e: m { append(*pairs, Pair.{k, frec_score(e, now)}); }
	slice.sort_by(view(pairs), (a: Pair, b: Pair) -> bool {return a.score > b.score || (a.score == b.score && compare(a.key, b.key) < 0);});
	out := make_dynamic(string, 0, n, temp);
	for p: pairs {
		if len(out) >= n { break; }
		if p.score <= 0 { continue; }
		append(*out, p.key);
	}
	return view(out);
}

frec_score_of :: (m: Map(string, Frec_Entry), key: string) -> float64 {
	{ e, ok := map_find(m, key);
	if ok { return frec_score(e, frec_now_ms()); } }
	return 0;
}
#scope_file

frecency_path :: () -> string {
	return strings.concatenate(string.[app_state_dir(), "/expressions.txt"], temp);
}
#scope_export

// Local persistence (offline / fixture runs never touch the file).
frecency_load_local :: () {
	if frecency.loaded_local { return; }
	frecency.loaded_local = true;
	if app.client == null { return; }
	data, err := os.read_entire_file(frecency_path(), temp);
	if err != null { return; }
	text := as_string(data);
	while true { line, __ok5 := strings.split_lines_iterator(*text); if !__ok5 break;
		f := strings.split(line, "\t", temp);
		if len(f) < 2 { continue; }
		if f[0] == {
		case "tone";
			frecency.skin_tone, _ = strconv.parse_int(f[1]);
		case "fav_emoji";
			append(*frecency.favorite_emojis, clone(f[1]));
		case "emoji"; #through; case "reaction"; #through; case "sticker";
			if len(f) < 3 { continue; }
			m := *frecency.emoji;
			if f[0] == "reaction" { m = *frecency.reaction; }
			if f[0] == "sticker" { m = *frecency.sticker; }
			e: Frec_Entry;
			e.total, _ = strconv.parse_int(f[2]);
			for ts: sub_from(f, 3) {
				{ v, ok := strconv.parse_i64(ts);
				if ok { append(*e.recent, v); } }
			}
			if !has(m.*, f[1]) { at(m, clone(f[1])).* = e; }
		}
	}
}

frecency_save :: () {
	if app.client == null { return; }
	sb := strings.builder_make(temp);
	fmt.sbprintf(*sb, "tone\t%d\n", frecency.skin_tone);
	for name: frecency.favorite_emojis { fmt.sbprintf(*sb, "fav_emoji\t%s\n", name); }
	write_map :: (sb: *strings.Builder, kind: string, m: Map(string, Frec_Entry)) {
		for k, e: m {
			fmt.sbprintf(sb, "%s\t%s\t%d", kind, k, e.total);
			for t: e.recent { fmt.sbprintf(sb, "\t%d", t); }
			strings.write_byte(sb, 10);
		}
	}
	write_map(*sb, "emoji", frecency.emoji);
	write_map(*sb, "reaction", frecency.reaction);
	write_map(*sb, "sticker", frecency.sticker);
	os.write_entire_file(frecency_path(), transmute([]u8, strings.to_string(sb)));
	frecency.dirty = false;
}

// Merge GET /users/@me/settings-proto/2 into the local tables (max of counts, union of uses).
frecency_merge_server :: (fs: dc.Frecency_Settings) {
	frecency.loaded_server = true;
	merge :: (m: *Map(string, Frec_Entry), items: []dc.Frecency_Item) {
		for it_: items {
			e, ok := map_find_ptr(m, it_.key);
			if !ok {
				at(m, clone(it_.key)).* = .{};
				e = at(m, it_.key);
			}
			e.total = max(e.total, it_.total_uses);
			for u: it_.recent_uses { if !slice.contains(view(e.recent), u) { append(*e.recent, u); } }
			slice.sort(view(e.recent));
			while len(e.recent) > FRECENCY_MAX_RECENT { ordered_remove(*e.recent, 0); }
		}
	}
	merge(*frecency.emoji, fs.emoji);
	merge(*frecency.reaction, fs.emoji_reaction);
	merge(*frecency.sticker, fs.sticker);
	for name: fs.favorite_emojis { if !slice.contains(view(frecency.favorite_emojis), name) { append(*frecency.favorite_emojis, clone(name)); } }
	for id: fs.favorite_stickers { if !slice.contains(view(frecency.favorite_stickers), id) { append(*frecency.favorite_stickers, id); } }
	for g: fs.favorite_gifs {
		gg := g;
		gg.url = clone(g.url);
		gg.src = clone(g.src);
		append(*frecency.favorite_gifs, gg);
	}
	slice.sort_by(view(frecency.favorite_gifs), (a: dc.Favorite_Gif, b: dc.Favorite_Gif) -> bool {return a.order > b.order;});
}

