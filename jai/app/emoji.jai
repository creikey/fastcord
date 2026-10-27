#scope_file

// Unicode emoji rendering like the official client: emoji in text become
// inline Twemoji images (https://discord.com/assets/<hash>.svg, requested as
// <img> loads), rasterized at device pixels with fc:vector and cached per
// (hash, px). The database is pickers_data.odin's emoji_db.
//
// API for the pickers and other views:
//   emoji_lookup_name(":thumbsup:" or "thumbsup") -> index | -1
//   emoji_lookup_surrogates("👍") -> index | -1   (FE0F-insensitive)
//   emoji_next(text, from) -> segment of the next emoji grapheme
//   twemoji_url(hash) / set_twemoji(box, index) / twemoji_texture(hash, px)
//   emoji_text_spans(...) -> rich-text spans with emoji as inline objects
//   emoji_convert_shortcodes(text) -> ":name:" replaced by unicode (on send)

// ---- lookup ----

// Unicode emoji rendering like the official client: emoji in text become
// inline Twemoji images (https://discord.com/assets/<hash>.svg, requested as
// <img> loads), rasterized at device pixels with fc:vector and cached per
// (hash, px). The database is pickers_data.odin's emoji_db.
//
// API for the pickers and other views:
//   emoji_lookup_name(":thumbsup:" or "thumbsup") -> index | -1
//   emoji_lookup_surrogates("👍") -> index | -1   (FE0F-insensitive)
//   emoji_next(text, from) -> segment of the next emoji grapheme
//   twemoji_url(hash) / set_twemoji(box, index) / twemoji_texture(hash, px)
//   emoji_text_spans(...) -> rich-text spans with emoji as inline objects
//   emoji_convert_shortcodes(text) -> ":name:" replaced by unicode (on send)

// ---- lookup ----

by_norm: Map(string, int);
#scope_export
#scope_file // FE0F-stripped surrogates -> index (emoji with an image only)
// FE0F-stripped surrogates -> index (emoji with an image only)
max_runes: int;
#scope_file

strip_fe0f :: (s: string, allocator := temp) -> string {
	if strings.index(s, "️") < 0 { return s; }
	out, _ := strings.remove_all(s, "️", allocator);
	return out;
}

ensure_index :: () {
	emoji_db_load();
	if !is_null(by_norm) { return; }
	by_norm = Map(string, int).{};
	for e, i: emoji_db.emojis {
		if e.asset == "" { continue; } // ™ © ®: text, like the client
		k := strip_fe0f(e.surr, context.allocator);
		if !has(by_norm, k) { at(*by_norm, k).* = i; }
		max_runes = max(max_runes, utf8.rune_count_in_string(k));
	}
}
#scope_export

emoji_lookup_name :: (name: string) -> int {
	emoji_db_load();
	n := strings.trim(name, ":");
	{ i, ok := map_find(emoji_db.by_name, n);
	if ok { return i; } }
	return -1;
}

emoji_lookup_surrogates :: (s: string) -> int {
	ensure_index();
	{ i, ok := map_find(by_norm, strip_fe0f(s));
	if ok { return i; } }
	return -1;
}

// A run of text that is one emoji.
Emoji_Segment :: struct {
	start, end: int; // byte range in the text (includes trailing U+FE0F)
	index: int; // emoji_db index
}
#scope_file

could_start :: inline (r: u32, next: u32) -> bool {
	if r == #char "#" || r == #char "*" || (r >= #char "0" && r <= #char "9") { return next == 0xFE0F || next == 0x20E3; } // keycaps
	return (r >= 0x203C && r <= 0x3299) || r >= 0x1F000;
};
#scope_export

// Next emoji at or after byte `from`: longest match on FE0F-insensitive
// sequences (ZWJ families, skin tones, flags, keycaps). ok=false: none left.
emoji_next :: (text: string, from: int) -> Emoji_Segment, bool {
	seg: Emoji_Segment;
	ok: bool;
	ensure_index();
	i := from;
	runes: [24]u32;
	ends: [24]int;
	while i < len(text) {
		r, w := utf8.decode_rune_in_string(sub_from(text, i));
		next: u32;
		if i + w < len(text) { next, _ = utf8.decode_rune_in_string(sub_from(text, i + w)); }
		if !could_start(r, next) {
			i += w;
			continue;
		}
		// gather up to max_runes non-FE0F runes (FE0F bytes stay inside the span)
		n := 0;
		j := i;
		while j < len(text) && n < min(max_runes, len(runes)) {
			rr, ww := utf8.decode_rune_in_string(sub_from(text, j));
			j += ww;
			if rr == 0xFE0F {
				if n > 0 { ends[n - 1] = j; }
				continue;
			}
			runes[n] = rr;
			ends[n] = j;
			n += 1;
		}
		buf: [96]u8;
		for < k: 1..n {
			sb := strings.builder_from_bytes(view(buf));
			for q: 0..k-1 { strings.write_rune(*sb, runes[q]); }
			{ idx, found := map_find(by_norm, strings.to_string(sb));
			if found {
				return .{i, ends[k - 1], idx}, true;
			} }
		}
		i += w;
	}
	return .{}, false;
}

// ---- twemoji images ----

twemoji_url :: (hash: string) -> string {
	return strings.concatenate(string.["https://discord.com/assets/", hash, ".svg"], temp);
}
#scope_file

Twemoji :: struct {
	state: Image_State;
	icon: vector.Icon;
}


twemojis: Map(string, Twemoji);
tw_tex: Name_Px_Map;

twemoji_get :: (hash: string, visible := true) -> *Twemoji {
	{ t, ok := map_find_ptr(*twemojis, hash);
	if ok { return t; } }
	key := clone(hash);
	at(*twemojis, key).* = .{state = .Loading};
	if app.client != null {
		// an <img src="/assets/<hash>.svg"> load, like the client's emoji images
		dc.fetch_media(app.client, .{url = twemoji_url(key), kind = .Image, visible = visible});
	} else { data, ok := offline_media(twemoji_url(key));
if ok {
		twemoji_receive(twemoji_url(key), 200, data);
	} else {
		at(*twemojis, key).* = .{state = .Failed};
	} }
	return at(*twemojis, key);
}
#scope_export

// images_receive routes finished .svg loads here; true if it was a twemoji.
twemoji_receive :: (url: string, status: int, data: []u8) -> bool {
	PFX :: "https://discord.com/assets/";
	if !strings.has_prefix(url, PFX) || !strings.has_suffix(url, ".svg") { return false; }
	hash := sub(url, len(PFX), len(url) - 4);
	t, ok := map_find_ptr(*twemojis, hash);
	if !ok { return false; }
	if status != 200 || len(data) == 0 {
		t.state = .Failed;
		return true;
	}
	icon, pok := vector.parse_svg(as_string(data));
	if !pok {
		t.state = .Failed;
		return true;
	}
	t.icon = icon;
	t.state = .Ready;
	app.ui.animating = true;
	return true;
}

// Texture of an emoji at px device pixels (0 while loading).
twemoji_texture :: (hash: string, px: int) -> gfx.Texture {
	if hash == "" || px <= 0 { return 0; }
	t := twemoji_get(hash);
	if t.state != .Ready { return 0; }
	k := Name_Px.{hash, px};
	{ p := table_find_pointer(*tw_tex, k);
	if p { return p.*; } }
	pixels := vector.rasterize_rgba(*t.icon, px, px, allocator = temp);
	tex := gfx.texture_from_rgba(px, px, pixels);
	k.name = clone(hash);
	table_set(*tw_tex, k, tex);
	return tex;
}

// Twemoji in r; until its texture exists (loading, failed, offline) the unicode
// `fallback` is drawn with the system emoji font in the same rect, so emoji
// never render invisible (progressive load).
twemoji_draw_rect :: (hash: string, r: ui.Rect, opacity: float32, fallback := "") {
	px := cast(int)(math.round((r.x1 - r.x0) * max(gfx.scale(), 1)));
	tex := twemoji_texture(hash, px);
	if tex == 0 {
		emoji_text_fallback(fallback, r, opacity);
		return;
	}
	c := gfx.Color.{1, 1, 1, opacity};
	gfx.push_rect(.{dst = cast,force(gfx.Rect)(r), tex = tex, colors = .[c, c, c, c]});
}

// The unicode text centered in r (system font; CoreText / DirectWrite fall back to the color emoji font).
emoji_text_fallback :: (text: string, r: ui.Rect, opacity: float32) {
	if text == "" || opacity <= 0 { return; }
	h := r.y1 - r.y0;
	size := h * 0.8;
	face := fonts[Font_Id.Normal];
	run := gfx.shape(face, size, text);
	m := gfx.font_metrics(face, size);
	x := r.x0 + ((r.x1 - r.x0) - run.width) / 2;
	y := r.y0 + (h - (m.ascent + m.descent)) / 2 + m.ascent;
	gfx.draw_run(run, .{x, y}, .{1, 1, 1, opacity});
}
#scope_file

Tw_Draw :: struct {
	hash: string;
	text: string; // unicode fallback while the svg loads
}

tw_box_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Tw_Draw)(user);
	twemoji_draw_rect(d.hash, b.rect, b.opacity, d.text);
}
#scope_export

// Draw emoji `index` (emoji_db) filling the box.
set_twemoji :: (b: *ui.Box, index: int) {
	emoji_db_load();
	if index < 0 || index >= len(emoji_db.emojis) { return; }
	h := emoji_db.emojis[index].asset;
	if h != "" { twemoji_get(h); }
	d := new(Tw_Draw, temp);
	d.hash = h;
	d.text = emoji_db.emojis[index].surr;
	b.custom_draw = tw_box_draw;
	b.custom_user = d;
}

// ---- rich text ----

// Spans for unicode emoji carry this bit in Span.id and the emoji index in user.
EMOJI_SPAN_FLAG :: (cast(u64)(1)) << 62;

// Splits `sp` (a text span) into text and inline-emoji spans (size px objects).
// The emoji spans keep the original unicode as their text, so copy/selection
// round-trips.
emoji_text_spans :: (out: *[..]ui.Span, sp: ui.Span, size: float32 = 22) {
	text := sp.text;
	pos := 0;
	while true {
		seg, ok := emoji_next(text, pos);
		if !ok { break; }
		if seg.start > pos {
			t := sp;
			t.text = sub(text, pos, seg.start);
			append(out, t);
		}
		e := sp;
		e.text = sub(text, seg.start, seg.end);
		e.object = .{size, size};
		e.id = sp.id | EMOJI_SPAN_FLAG;
		e.user = cast(*void)(cast(u64)(seg.index + 1));
		e.bg = .{};
		append(out, e);
		pos = seg.end;
	}
	if pos == 0 {
		append(out, sp);
	} else if pos < len(text) {
		t := sp;
		t.text = sub_from(text, pos);
		append(out, t);
	}
}

// Inline-object hook for unicode emoji spans; false if the span is something else.
draw_unicode_emoji_span :: (sp: ui.Span, r: ui.Rect, opacity: float32) -> bool {
	if (sp.id & EMOJI_SPAN_FLAG) == 0 { return false; }
	idx := cast(int)(cast(u64)(sp.user)) - 1;
	if idx < 0 || idx >= len(emoji_db.emojis) {
		emoji_text_fallback(sp.text, r, opacity);
		return true;
	}
	twemoji_draw_rect(emoji_db.emojis[idx].asset, r, opacity, sp.text);
	return true;
}

// Number of emoji in s, and whether s holds nothing but emoji and whitespace.
emoji_count :: (s: string) -> int, bool {
	n: int;
	only: bool;
	pos := 0;
	only = true;
	while true {
		seg, ok := emoji_next(s, pos);
		gap := sub(s, pos, ifx ok then seg.start else len(s));
		if strings.trim_space(gap) != "" { only = false; }
		if !ok { break; }
		n += 1;
		pos = seg.end;
	}
	return n, only;
}

// Reaction / status emoji box: custom emoji image or twemoji (text if unknown).
emoji_box :: (id: string, e: dc.Emoji, size: float32) -> *ui.Box {
	if e.id != 0 { return emoji_inline(id, e, size); }
	idx := emoji_lookup_surrogates(e.name);
	if idx < 0 { return emoji_inline(id, e, size); }
	b := ui.box(id);
	b.semantic_size = .[ui.px(size), ui.px(size)];
	set_twemoji(b, idx);
	return b;
}

// ---- composer ----

// ":name:" -> unicode before sending, like the client (outside inline/fenced
// code; unknown names stay as typed).
emoji_convert_shortcodes :: (text: string) -> string {
	if strings.index_byte(text, #char ":") < 0 { return text; }
	emoji_db_load();
	sb := strings.builder_make(temp);
	i := 0;
	in_code := false;
	while i < len(text) {
		c := text[i];
		if c == #char "`" {
			in_code = !in_code;
			strings.write_byte(*sb, c);
			i += 1;
			continue;
		}
		if c == #char ":" && !in_code {
			end := strings.index_byte(sub_from(text, i + 1), #char ":");
			if end > 0 {
				name := sub(text, i + 1, i + 1 + end);
				valid := true;
				for ch: name {
					if !(ch == #char "_" || ch == #char "-" || ch == #char "+" || (ch >= #char "a" && ch <= #char "z") || (ch >= #char "A" && ch <= #char "Z") || (ch >= #char "0" && ch <= #char "9")) {
						valid = false;
						break;
					}
				}
				if valid {
					{ idx, ok := map_find(emoji_db.by_name, name);
					if ok {
						strings.write_string(*sb, emoji_db.emojis[idx].surr);
						i += end + 2;
						continue;
					} }
				}
			}
		}
		strings.write_byte(*sb, c);
		i += 1;
	}
	return strings.to_string(sb);
}

// Offline runs (fixtures / UI tests): FASTCORD_MEDIA_DIR holds media files named
// by the last URL path component (e.g. f753793200a49ad6.svg, <id>.json).
offline_media :: (url: string) -> []u8, bool {
	dir := os.get_env("FASTCORD_MEDIA_DIR", temp);
	if dir == "" { return .{}, false; }
	u := url;
	{ q := strings.index_byte(u, #char "?");
	if q >= 0 { u = sub(u, 0, q); } }
	name := sub_from(u, strings.last_index_byte(u, #char "/") + 1);
	data, err := os.read_entire_file(strings.concatenate(string.[dir, "/", name], temp), temp);
	return data, err == null;
}

// A one-line label whose unicode emoji draw as Twemoji (custom status, names).
// Emoji are sized to the line (font size + 4, like the client's 1.375em-ish inline emoji).
emoji_label :: (text: string, font: Font_Id, size: float32, color: ui.Color, line_h: float32 = 0) -> *ui.Box {
	{ _, ok := emoji_next(text, 0);
	if !ok { return label(text, font, size, color, line_h); } }
	b := ui.box(text, .Draw_Text);
	b.semantic_size = .[ui.text_size(0, 0), ui.text_size()];
	b.style.text_color = color;
	b.style.line_height = line_h;
	b.style.font = F(font);
	b.style.font_size = size;
	spans := make_dynamic(ui.Span, 0, 0, temp);
	emoji_text_spans(*spans, ui.Span.{text = text, font = F(font), size = size}, size + 4);
	ui.set_spans(b, view(spans));
	return b;
}

