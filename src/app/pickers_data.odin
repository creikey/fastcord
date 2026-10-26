package app

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import dc "fc:discord"

// Discord's unicode emoji database (assets/emoji/emoji.json, extracted from
// the client bundle) plus local frecency / skin tone persistence.

@(private = "file")
EMOJI_JSON := #load("../../assets/emoji/emoji.json")

Uni_Emoji :: struct {
	names:    []string, // names[0] is the canonical shortcode
	surr:     string,
	asset:    string, // twemoji asset hash (https://discord.com/assets/<u>.svg)
	sprite:   int, // spritesheet index; -1 = none (children)
	children: []i32, // skin tone variants (5, or 25 for multi-person)
	multi:    bool,
}

Emoji_Category :: struct {
	key:   string, // people, nature, ...
	start: int,
	end:   int,
}

Emoji_DB :: struct {
	loaded:           bool,
	emojis:           []Uni_Emoji,
	cats:             []Emoji_Category,
	by_name:          map[string]int, // every alias -> index
	by_surr:          map[string]int,
	default_frecency: []string,
	default_reaction: []string,
	parents:          int, // emojis [0, parents) are pickable; children follow
}

emoji_db: Emoji_DB

emoji_db_load :: proc() {
	if emoji_db.loaded do return
	emoji_db.loaded = true
	v, err := json.parse(EMOJI_JSON, allocator = context.temp_allocator)
	if err != nil do return
	root := v.(json.Object) or_else nil
	strs :: proc(v: json.Value) -> []string {
		arr := v.(json.Array) or_else nil
		out := make([]string, len(arr))
		for x, i in arr do out[i] = strings.clone(x.(json.String) or_else "")
		return out
	}
	num :: proc(v: json.Value) -> int {
		#partial switch x in v {
		case json.Integer:
			return int(x)
		case json.Float:
			return int(x)
		}
		return 0
	}
	list := root["emojis"].(json.Array) or_else nil
	emoji_db.emojis = make([]Uni_Emoji, len(list))
	for ev, i in list {
		o := ev.(json.Object) or_else nil
		e := &emoji_db.emojis[i]
		e.names = strs(o["n"])
		e.surr = strings.clone(o["s"].(json.String) or_else "")
		e.asset = strings.clone(o["u"].(json.String) or_else "")
		e.sprite = -1
		if sp, ok := o["sp"]; ok do e.sprite = num(sp)
		if dcv, ok := o["dc"]; ok {
			arr := dcv.(json.Array) or_else nil
			e.children = make([]i32, len(arr))
			for x, j in arr do e.children[j] = i32(num(x))
		}
		if md, ok := o["md"]; ok do e.multi = num(md) != 0
		for n in e.names do if n not_in emoji_db.by_name do emoji_db.by_name[n] = i
		if e.surr not_in emoji_db.by_surr do emoji_db.by_surr[e.surr] = i
	}
	cats := root["categories"].(json.Array) or_else nil
	emoji_db.cats = make([]Emoji_Category, len(cats))
	for cv, i in cats {
		a := cv.(json.Array) or_else nil
		if len(a) < 3 do continue
		emoji_db.cats[i] = {strings.clone(a[0].(json.String) or_else ""), num(a[1]), num(a[2])}
		emoji_db.parents = max(emoji_db.parents, num(a[2]))
	}
	emoji_db.default_frecency = strs(root["default_frecency"])
	emoji_db.default_reaction = strs(root["default_reaction_frecency"])
}

// Skin-toned variant (tone 1..5) of a parent emoji; multi-person emoji use the same tone twice.
emoji_toned :: proc(idx: int, tone: int) -> int {
	if tone <= 0 || idx < 0 || idx >= len(emoji_db.emojis) do return idx
	e := &emoji_db.emojis[idx]
	if len(e.children) == 0 do return idx
	ci := e.multi ? (tone - 1) * 6 : tone - 1
	if ci >= len(e.children) do return idx
	return int(e.children[ci])
}

emoji_category_title :: proc(key: string) -> string {
	switch key {
	case "people":
		return "People"
	case "nature":
		return "Nature"
	case "food":
		return "Food & Drink"
	case "activity":
		return "Activities"
	case "travel":
		return "Travel & Places"
	case "objects":
		return "Objects"
	case "symbols":
		return "Symbols"
	case "flags":
		return "Flags"
	}
	return key
}

emoji_category_icon :: proc(key: string) -> string {
	switch key {
	case "people":
		return "emoji-people"
	case "nature":
		return "nature"
	case "food":
		return "food"
	case "activity":
		return "game-controller"
	case "travel":
		return "bicycle"
	case "objects":
		return "object"
	case "symbols":
		return "heart"
	case "flags":
		return "flag"
	}
	return "reaction"
}

// ---- frecency ----
// Score like the client's Frecency util: total uses times the mean weight of
// the recent uses (weights by age: 3 d 100, 15 d 70, 30 d 50, 45 d 30, 80 d 10).

FRECENCY_MAX_RECENT :: 10

Frec_Entry :: struct {
	total:  int,
	recent: [dynamic]i64, // unix ms, newest last
}

Frecency :: struct {
	emoji:             map[string]Frec_Entry, // unicode canonical name or custom emoji id
	reaction:          map[string]Frec_Entry,
	sticker:           map[string]Frec_Entry,
	favorite_emojis:   [dynamic]string,
	favorite_stickers: [dynamic]dc.Snowflake,
	favorite_gifs:     [dynamic]dc.Favorite_Gif,
	skin_tone:         int, // 0 = default yellow, 1..5
	loaded_local:      bool,
	loaded_server:     bool,
	dirty:             bool,
}

frecency: Frecency

frec_now_ms :: proc() -> i64 {return time.time_to_unix_nano(time.now()) / 1e6}

@(private = "file")
frec_weight :: proc(age_ms: i64) -> f64 {
	days := f64(age_ms) / 86_400_000
	switch {
	case days <= 3:
		return 100
	case days <= 15:
		return 70
	case days <= 30:
		return 50
	case days <= 45:
		return 30
	case days <= 80:
		return 10
	}
	return 0
}

frec_score :: proc(e: Frec_Entry, now: i64) -> f64 {
	if len(e.recent) == 0 do return f64(e.total)
	sum: f64
	for t in e.recent do sum += frec_weight(now - t)
	return f64(e.total) * sum / f64(len(e.recent))
}

frec_use :: proc(m: ^map[string]Frec_Entry, key: string) {
	if key == "" do return
	e, ok := &m[key]
	if !ok {
		m[strings.clone(key)] = {}
		e = &m[key]
	}
	e.total += 1
	append(&e.recent, frec_now_ms())
	if len(e.recent) > FRECENCY_MAX_RECENT do ordered_remove(&e.recent, 0)
	frecency.dirty = true
	frecency_save()
}

// Keys by descending score.
frec_top :: proc(m: map[string]Frec_Entry, n: int) -> []string {
	Pair :: struct {
		key:   string,
		score: f64,
	}
	now := frec_now_ms()
	pairs := make([dynamic]Pair, 0, len(m), context.temp_allocator)
	for k, e in m do append(&pairs, Pair{k, frec_score(e, now)})
	slice.sort_by(pairs[:], proc(a, b: Pair) -> bool {return a.score > b.score || (a.score == b.score && a.key < b.key)})
	out := make([dynamic]string, 0, n, context.temp_allocator)
	for p in pairs {
		if len(out) >= n do break
		if p.score <= 0 do continue
		append(&out, p.key)
	}
	return out[:]
}

frec_score_of :: proc(m: map[string]Frec_Entry, key: string) -> f64 {
	if e, ok := m[key]; ok do return frec_score(e, frec_now_ms())
	return 0
}

@(private = "file")
frecency_path :: proc() -> string {
	return strings.concatenate({app_state_dir(), "/expressions.txt"}, context.temp_allocator)
}

// Local persistence (offline / fixture runs never touch the file).
frecency_load_local :: proc() {
	if frecency.loaded_local do return
	frecency.loaded_local = true
	if app.client == nil do return
	data, err := os.read_entire_file(frecency_path(), context.temp_allocator)
	if err != nil do return
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 2 do continue
		switch f[0] {
		case "tone":
			frecency.skin_tone, _ = strconv.parse_int(f[1])
		case "fav_emoji":
			append(&frecency.favorite_emojis, strings.clone(f[1]))
		case "emoji", "reaction", "sticker":
			if len(f) < 3 do continue
			m := &frecency.emoji
			if f[0] == "reaction" do m = &frecency.reaction
			if f[0] == "sticker" do m = &frecency.sticker
			e: Frec_Entry
			e.total, _ = strconv.parse_int(f[2])
			for ts in f[3:] {
				if v, ok := strconv.parse_i64(ts); ok do append(&e.recent, v)
			}
			if f[1] not_in m^ do m[strings.clone(f[1])] = e
		}
	}
}

frecency_save :: proc() {
	if app.client == nil do return
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "tone\t%d\n", frecency.skin_tone)
	for name in frecency.favorite_emojis do fmt.sbprintf(&sb, "fav_emoji\t%s\n", name)
	write_map :: proc(sb: ^strings.Builder, kind: string, m: map[string]Frec_Entry) {
		for k, e in m {
			fmt.sbprintf(sb, "%s\t%s\t%d", kind, k, e.total)
			for t in e.recent do fmt.sbprintf(sb, "\t%d", t)
			strings.write_byte(sb, '\n')
		}
	}
	write_map(&sb, "emoji", frecency.emoji)
	write_map(&sb, "reaction", frecency.reaction)
	write_map(&sb, "sticker", frecency.sticker)
	_ = os.write_entire_file(frecency_path(), transmute([]byte)strings.to_string(sb))
	frecency.dirty = false
}

// Merge GET /users/@me/settings-proto/2 into the local tables (max of counts, union of uses).
frecency_merge_server :: proc(fs: dc.Frecency_Settings) {
	frecency.loaded_server = true
	merge :: proc(m: ^map[string]Frec_Entry, items: []dc.Frecency_Item) {
		for it in items {
			e, ok := &m[it.key]
			if !ok {
				m[strings.clone(it.key)] = {}
				e = &m[it.key]
			}
			e.total = max(e.total, it.total_uses)
			for u in it.recent_uses do if !slice.contains(e.recent[:], u) do append(&e.recent, u)
			slice.sort(e.recent[:])
			for len(e.recent) > FRECENCY_MAX_RECENT do ordered_remove(&e.recent, 0)
		}
	}
	merge(&frecency.emoji, fs.emoji)
	merge(&frecency.reaction, fs.emoji_reaction)
	merge(&frecency.sticker, fs.sticker)
	for name in fs.favorite_emojis do if !slice.contains(frecency.favorite_emojis[:], name) do append(&frecency.favorite_emojis, strings.clone(name))
	for id in fs.favorite_stickers do if !slice.contains(frecency.favorite_stickers[:], id) do append(&frecency.favorite_stickers, id)
	for g in fs.favorite_gifs {
		gg := g
		gg.url = strings.clone(g.url)
		gg.src = strings.clone(g.src)
		append(&frecency.favorite_gifs, gg)
	}
	slice.sort_by(frecency.favorite_gifs[:], proc(a, b: dc.Favorite_Gif) -> bool {return a.order > b.order})
}
