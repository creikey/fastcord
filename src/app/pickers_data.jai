// Discord's unicode emoji database (assets/emoji/emoji.json, extracted from
// the client bundle) plus local frecency / skin tone persistence.

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
	by_name: Table(string, int); // every alias -> index
	by_surr: Table(string, int);
	default_frecency: []string;
	default_reaction: []string;
	parents: int; // emojis [0, parents) are pickable; children follow
}

emoji_db: Emoji_DB;

emoji_db_load :: () {
	if emoji_db.loaded return;
	emoji_db.loaded = true;
	v, err := etf.from_json(EMOJI_JSON,, temp);
	if err != .None return;
	root := dc.vmap(v);
	strs :: (v: etf.Value) -> []string {
		arr := dc.vlist(v);
		out := NewArray(arr.count, string);
		for arr out[it_index] = copy_string(dc.vstr(it));
		return out;
	}
	list := dc.flist(root, "emojis");
	emoji_db.emojis = NewArray(list.count, Uni_Emoji);
	for ev, i: list {
		o := dc.vmap(ev);
		e := *emoji_db.emojis[i];
		e.names = strs(dc.vget(o, "n"));
		e.surr = copy_string(dc.fstr(o, "s"));
		e.asset = copy_string(dc.fstr(o, "u"));
		e.sprite = -1;
		sp, has_sp := etf.map_get(o, "sp");
		if has_sp e.sprite = dc.vint(sp);
		children, has_children := etf.map_get(o, "dc");
		if has_children {
			arr := dc.vlist(children);
			e.children = NewArray(arr.count, s32);
			for arr e.children[it_index] = cast(s32) dc.vint(it);
		}
		md, has_md := etf.map_get(o, "md");
		if has_md e.multi = dc.vint(md) != 0;
		for e.names if !table_contains(*emoji_db.by_name, it) table_add(*emoji_db.by_name, it, i);
		if !table_contains(*emoji_db.by_surr, e.surr) table_add(*emoji_db.by_surr, e.surr, i);
	}
	cats := dc.flist(root, "categories");
	emoji_db.cats = NewArray(cats.count, Emoji_Category);
	for cats {
		a := dc.vlist(it);
		if a.count < 3 continue;
		emoji_db.cats[it_index] = .{copy_string(dc.vstr(a[0])), dc.vint(a[1]), dc.vint(a[2])};
		emoji_db.parents = max(emoji_db.parents, dc.vint(a[2]));
	}
	emoji_db.default_frecency = strs(dc.vget(root, "default_frecency"));
	emoji_db.default_reaction = strs(dc.vget(root, "default_reaction_frecency"));
}

// Skin-toned variant (tone 1..5) of a parent emoji; multi-person emoji use the same tone twice.
emoji_toned :: (idx: int, tone: int) -> int {
	if tone <= 0 || idx < 0 || idx >= emoji_db.emojis.count return idx;
	e := *emoji_db.emojis[idx];
	if e.children.count == 0 return idx;
	ci := ifx e.multi then (tone - 1) * 6 else tone - 1;
	if ci >= e.children.count return idx;
	return e.children[ci];
}

emoji_category_title :: (key: string) -> string {
	if key == {
		case "people";   return L("People");
		case "nature";   return L("Nature");
		case "food";     return L("Food & Drink");
		case "activity"; return L("Activities");
		case "travel";   return L("Travel & Places");
		case "objects";  return L("Objects");
		case "symbols";  return L("Symbols");
		case "flags";    return L("Flags");
	}
	return key;
}

emoji_category_icon :: (key: string) -> string {
	if key == {
		case "people";   return "emoji-people";
		case "nature";   return "nature";
		case "food";     return "food";
		case "activity"; return "game-controller";
		case "travel";   return "bicycle";
		case "objects";  return "object";
		case "symbols";  return "heart";
		case "flags";    return "flag";
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
	emoji: Table(string, Frec_Entry); // unicode canonical name or custom emoji id
	reaction: Table(string, Frec_Entry);
	sticker: Table(string, Frec_Entry);
	favorite_emojis: [..]string;
	favorite_stickers: [..]dc.Snowflake;
	favorite_gifs: [..]dc.Favorite_Gif;
	skin_tone: int; // 0 = default yellow, 1..5
	loaded_server: bool;
	remote_seen: int; // the store's frecency.remote this was last merged with
}

frecency: Frecency;

frec_score :: (e: Frec_Entry, now: s64) -> float64 {
	if e.recent.count == 0 return cast(float64) e.total;
	sum: float64;
	for e.recent sum += frec_weight(now - it);
	return cast(float64) e.total * sum / cast(float64) e.recent.count;
}

frec_use :: (m: *Table(string, Frec_Entry), key: string) {
	if key == "" return;
	e := table_find_pointer(m, key);
	if !e e = table_add(m, copy_string(key), .{});
	e.total += 1;
	array_add(*e.recent, dc.now_ms());
	if e.recent.count > FRECENCY_MAX_RECENT array_ordered_remove_by_index(*e.recent, 0);
	// the library's copy is what the server gets (settings-proto/2)
	if app.client != null dc.frecency_use(app.client, ifx m == *frecency.reaction then .Reaction else ifx m == *frecency.sticker then .Sticker else .Emoji, key);
}

// frec_key_of: the frecency key of an emoji sent or reacted with: a custom emoji's id, else the unicode
// emoji's name ("" for text that isn't one).
frec_key_of :: (name: string, id: dc.Snowflake) -> string {
	if id return tprint("%", id);
	emoji_db_load();
	found, i := table_find(*emoji_db.by_surr, name);
	return ifx found then emoji_db.emojis[i].names[0] else "";
}

// track_sent_emoji: EMOJI_TRACK_USAGE after a send, every emoji in the text is a use (custom emoji
// markup and unicode emoji, longest match first; at most 50).
track_sent_emoji :: (text: string) {
	emoji_db_load();
	i, uses := 0, 0;
	while i < text.count && uses < 50 {
		c := text[i];
		if c == #char "<" && i + 2 < text.count && (text[i + 1] == #char ":" || (text[i + 1] == #char "a" && text[i + 2] == #char ":")) {
			// <:name:id> or <a:name:id>
			j := i + ifx text[i + 1] == #char "a" then 3 else 2;
			name_start := j;
			while j < text.count && j - name_start <= 32 && (is_alnum(text[j]) || text[j] == #char "_") j += 1;
			if j < text.count && text[j] == #char ":" && j > name_start {
				j += 1;
				id_start := j;
				while j < text.count && j - id_start < 20 && text[j] >= #char "0" && text[j] <= #char "9" j += 1;
				if j < text.count && text[j] == #char ">" && j > id_start {
					frec_use(*frecency.emoji, slice(text, id_start, j - id_start));
					uses += 1;
					i = j + 1;
					continue;
				}
			}
		}
		if c >= 0x80 {
			matched := 0;
			for < len: 1..min(32, text.count - i) {
				found, k := table_find(*emoji_db.by_surr, slice(text, i, len));
				if found {
					frec_use(*frecency.emoji, emoji_db.emojis[k].names[0]);
					uses += 1;
					matched = len;
					break;
				}
			}
			if matched {
				i += matched;
				continue;
			}
		}
		i += 1;
	}
}

// Keys by descending score.
frec_top :: (m: Table(string, Frec_Entry), n: int) -> []string {
	Pair :: struct {
		key: string;
		score: float64;
	}
	now := dc.now_ms();
	pairs: [..]Pair;
	pairs.allocator = temp;
	array_reserve(*pairs, m.count);
	for e, k: m array_add(*pairs, .{k, frec_score(e, now)});
	quick_sort(pairs, (a: Pair, b: Pair) -> int {
		if a.score != b.score return ifx a.score > b.score then -1 else 1;
		return compare(a.key, b.key);
	});
	out: [..]string;
	out.allocator = temp;
	for pairs {
		if out.count >= n break;
		if it.score > 0 array_add(*out, it.key);
	}
	return out;
}

frec_score_of :: (m: *Table(string, Frec_Entry), key: string) -> float64 {
	e := table_find_pointer(m, key);
	return ifx e then frec_score(e.*, dc.now_ms()) else 0;
}

// Local persistence, in settings.json (offline / fixture runs never load or save it).
Persisted_Expressions :: struct {
	skin_tone: int;
	favorite_emojis: []string;
	uses: []Persisted_Frec;
}
Persisted_Frec :: struct { kind: string; key: string; total: int; recent: []s64; } // kind: emoji, reaction, sticker

frecency_restore :: (p: Persisted_Expressions, dir: string) {
	frecency.skin_tone = p.skin_tone;
	for p.favorite_emojis array_add(*frecency.favorite_emojis, copy_string(it));
	for p.uses {
		m := ifx it.kind == "reaction" then *frecency.reaction else ifx it.kind == "sticker" then *frecency.sticker else *frecency.emoji;
		if table_contains(m, it.key) || it.recent.count > FRECENCY_MAX_RECENT continue;
		e := table_add(m, copy_string(it.key), .{total = it.total});
		array_copy(*e.recent, it.recent);
	}
	// before settings.json kept them: <state>/expressions.txt, read once and removed
	old := tprint("%/expressions.txt", dir);
	text, ok := read_entire_file(old, log_errors = false,, temp);
	if !ok return;
	for line: split(text, "\n",, temp) {
		f := split(trim_right(line, "\r"), "\t",, temp);
		if f.count < 2 continue;
		if f[0] == {
		case "tone";
			frecency.skin_tone = string_to_int(f[1]);
		case "fav_emoji";
			if !array_find(frecency.favorite_emojis, f[1]) array_add(*frecency.favorite_emojis, copy_string(f[1]));
		case "emoji"; #through;
		case "reaction"; #through;
		case "sticker";
			if f.count < 3 continue;
			m := ifx f[0] == "reaction" then *frecency.reaction else ifx f[0] == "sticker" then *frecency.sticker else *frecency.emoji;
			if table_contains(m, f[1]) continue;
			e := table_add(m, copy_string(f[1]), .{total = string_to_int(f[2])});
			for array_view(f, 3) {
				v, ok, rest := string_to_int(it, T = s64);
				if ok && !rest && e.recent.count < FRECENCY_MAX_RECENT array_add(*e.recent, v);
			}
		}
	}
	file_delete(old);
}

frecency_snapshot :: () -> Persisted_Expressions { // in temp
	uses: [..]Persisted_Frec;
	add :: (uses: *[..]Persisted_Frec, kind: string, m: Table(string, Frec_Entry)) {
		for e, k: m array_add(uses, .{kind, k, e.total, e.recent});
	}
	add(*uses, "emoji", frecency.emoji);
	add(*uses, "reaction", frecency.reaction);
	add(*uses, "sticker", frecency.sticker);
	return .{frecency.skin_tone, frecency.favorite_emojis, uses};
}

// Merge GET /users/@me/settings-proto/2 into the local tables (max of counts, union of uses). Another
// device's update (remote) replaces the favourites, so removals there show here.
frecency_merge_server :: (fs: dc.Frecency_Settings, remote := false) {
	frecency.loaded_server = true;
	if remote {
		for frecency.favorite_emojis free(it);
		for frecency.favorite_gifs { free(it.url); free(it.src); }
		array_reset_keeping_memory(*frecency.favorite_emojis);
		array_reset_keeping_memory(*frecency.favorite_stickers);
		array_reset_keeping_memory(*frecency.favorite_gifs);
	}
	merge :: (m: *Table(string, Frec_Entry), items: []dc.Frecency_Item) {
		for items {
			e := table_find_pointer(m, it.key);
			if !e e = table_add(m, copy_string(it.key), .{});
			e.total = max(e.total, it.total_uses);
			for u: it.recent_uses if !array_find(e.recent, u) array_add(*e.recent, u);
			quick_sort(e.recent, (a: s64, b: s64) -> int { return ifx a < b then -1 else ifx a > b then 1 else 0; });
			while e.recent.count > FRECENCY_MAX_RECENT array_ordered_remove_by_index(*e.recent, 0);
		}
	}
	merge(*frecency.emoji, fs.emoji);
	merge(*frecency.reaction, fs.emoji_reaction);
	merge(*frecency.sticker, fs.sticker);
	for fs.favorite_emojis if !array_find(frecency.favorite_emojis, it) array_add(*frecency.favorite_emojis, copy_string(it));
	for fs.favorite_stickers array_add_if_unique(*frecency.favorite_stickers, it);
	for fs.favorite_gifs {
		g := it;
		g.url = copy_string(it.url);
		g.src = copy_string(it.src);
		array_add(*frecency.favorite_gifs, g);
	}
	quick_sort(frecency.favorite_gifs, (a: dc.Favorite_Gif, b: dc.Favorite_Gif) -> int { return b.order - a.order; });
}

#scope_file

EMOJI_JSON :: #run,host -> string { #import "Basic"; #import "File"; return read_entire_file(tprint("%/../../assets/emoji/emoji.json", #filepath)); };

frec_weight :: (age_ms: s64) -> float64 {
	days := cast(float64) age_ms / 86_400_000;
	if days <= 3  return 100;
	if days <= 15 return 70;
	if days <= 30 return 50;
	if days <= 45 return 30;
	if days <= 80 return 10;
	return 0;
}

