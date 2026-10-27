// Unicode emoji rendering like the official client: emoji in text become
// inline Twemoji images (https://discord.com/assets/<hash>.svg, requested as
// <img> loads), rasterized at device pixels with the vector module and cached per
// (hash, px). The database is pickers_data.jai's emoji_db.
//
// API for the pickers and other views:
//   emoji_lookup_name(":thumbsup:" or "thumbsup") -> index | -1
//   emoji_lookup_surrogates("👍") -> index | -1   (FE0F-insensitive)
//   emoji_next(text, from) -> segment of the next emoji grapheme
//   twemoji_url(hash) / set_twemoji(box, index) / twemoji_texture(hash, px)
//   emoji_text_spans(...) -> rich-text spans with emoji as inline objects
//   emoji_convert_shortcodes(text) -> ":name:" replaced by unicode (on send)

// ---- lookup ----

emoji_lookup_name :: (name: string) -> int {
	emoji_db_load();
	found, i := table_find(*emoji_db.by_name, trim(name, ":"));
	return ifx found then i else -1;
}

emoji_lookup_surrogates :: (s: string) -> int {
	ensure_index();
	found, i := table_find(*by_norm, strip_fe0f(s,, temp));
	return ifx found then i else -1;
}

// A run of text that is one emoji.
Emoji_Segment :: struct {
	start, end: int; // byte range in the text (includes trailing U+FE0F)
	index: int; // emoji_db index
}

// Next emoji at or after byte `from`: longest match on FE0F-insensitive
// sequences (ZWJ families, skin tones, flags, keycaps). ok=false: none left.
emoji_next :: (text: string, from: int) -> Emoji_Segment, bool {
	ensure_index();
	i := from;
	runes: [24]u32;
	ends: [24]int;
	while i < text.count {
		r, w := decode_rune(text, i);
		next: u32;
		if i + w < text.count next = decode_rune(text, i + w);
		if !could_start(r, next) {
			i += w;
			continue;
		}
		// gather up to max_runes non-FE0F runes (FE0F bytes stay inside the span)
		n := 0;
		j := i;
		while j < text.count && n < min(max_runes, runes.count) {
			rr, ww := decode_rune(text, j);
			j += ww;
			if rr == 0xFE0F {
				if n > 0 ends[n - 1] = j;
				continue;
			}
			runes[n] = rr;
			ends[n] = j;
			n += 1;
		}
		// UTF-8 of the gathered runes; bytes[k] = length of the first k
		buf: [96]u8;
		bytes: [25]int;
		for q: 0..n - 1 {
			s := string.{4, buf.data + bytes[q]};
			character_utf32_to_utf8(runes[q], *s);
			bytes[q + 1] = bytes[q] + s.count;
		}
		for < k: 1..n {
			found, idx := table_find(*by_norm, string.{bytes[k], buf.data});
			if found return .{i, ends[k - 1], idx}, true;
		}
		i += w;
	}
	return .{}, false;
}

// ---- twemoji images ----

twemoji_url :: (hash: string) -> string {
	return tprint("https://discord.com/assets/%.svg", hash);
}

// images_receive routes finished .svg loads here; true if it was a twemoji.
twemoji_receive :: (url: string, status: int, data: []u8) -> bool {
	PFX :: "https://discord.com/assets/";
	if !begins_with(url, PFX) || !ends_with(url, ".svg") return false;
	t := table_find_pointer(*twemojis, string.{url.count - PFX.count - 4, url.data + PFX.count});
	if !t return false;
	if status != 200 || data.count == 0 {
		t.state = .Failed;
		return true;
	}
	icon, ok := vector.parse_svg(cast(string) data);
	if !ok {
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
	if hash == "" || px <= 0 return 0;
	t := twemoji_get(hash);
	if t.state != .Ready return 0;
	k := Name_Px.{hash, px};
	p := table_find_pointer(*tw_tex, k);
	if p return p.*;
	pixels := vector.rasterize_rgba(*t.icon, px, px,, temp);
	tex := gfx.texture_from_rgba(px, px, pixels);
	k.name = copy_string(hash);
	table_set(*tw_tex, k, tex);
	return tex;
}

// Twemoji in r; until its texture exists (loading, failed, offline) the unicode
// `fallback` is drawn with the system emoji font in the same rect, so emoji
// never render invisible (progressive load).
twemoji_draw_rect :: (hash: string, r: ui.Rect, opacity: float32, fallback := "") {
	px := cast(int) floor((r.x1 - r.x0) * max(gfx.scale(), 1) + 0.5);
	tex := twemoji_texture(hash, px);
	if tex == 0 {
		emoji_text_fallback(fallback, r, opacity);
		return;
	}
	c := gfx.Color.{1, 1, 1, opacity};
	gfx.push_rect(.{dst = cast,force(gfx.Rect) r, tex = tex, colors = .[c, c, c, c]});
}

// The unicode text centered in r (system font; CoreText / DirectWrite fall back to the color emoji font).
emoji_text_fallback :: (text: string, r: ui.Rect, opacity: float32) {
	if text == "" || opacity <= 0 return;
	h := r.y1 - r.y0;
	size := h * 0.8;
	face := fonts[Font_Id.Normal];
	run := gfx.shape(face, size, text);
	m := gfx.font_metrics(face, size);
	x := r.x0 + ((r.x1 - r.x0) - run.width) / 2;
	y := r.y0 + (h - (m.ascent + m.descent)) / 2 + m.ascent;
	gfx.draw_run(run, .{x, y}, .{1, 1, 1, opacity});
}

// Draw emoji `index` (emoji_db) filling the box.
set_twemoji :: (b: *ui.Box, index: int) {
	emoji_db_load();
	if index < 0 || index >= emoji_db.emojis.count return;
	e := *emoji_db.emojis[index];
	if e.asset != "" twemoji_get(e.asset);
	d := New(Tw_Draw,, temp);
	d.* = .{e.asset, e.surr};
	b.custom_draw = tw_box_draw;
	b.custom_user = d;
}

// ---- rich text ----

// Spans for unicode emoji carry this bit in Span.id and the emoji index in user.
EMOJI_SPAN_FLAG :: (cast(u64) 1) << 62;

// Splits `sp` (a text span) into text and inline-emoji spans (size px objects).
// The emoji spans keep the original unicode as their text, so copy/selection
// round-trips.
emoji_text_spans :: (out: *[..]ui.Span, sp: ui.Span, size: float32 = 22) {
	text := sp.text;
	pos := 0;
	while true {
		seg, ok := emoji_next(text, pos);
		if !ok break;
		if seg.start > pos {
			t := sp;
			t.text = string.{seg.start - pos, text.data + pos};
			array_add(out, t);
		}
		e := sp;
		e.text = string.{seg.end - seg.start, text.data + seg.start};
		e.object = .{size, size};
		e.id = sp.id | EMOJI_SPAN_FLAG;
		e.user = cast(*void) (seg.index + 1);
		e.bg = .{};
		array_add(out, e);
		pos = seg.end;
	}
	if pos == 0 {
		array_add(out, sp);
	} else if pos < text.count {
		t := sp;
		t.text = string.{text.count - pos, text.data + pos};
		array_add(out, t);
	}
}

// Inline-object hook for unicode emoji spans; false if the span is something else.
draw_unicode_emoji_span :: (sp: ui.Span, r: ui.Rect, opacity: float32) -> bool {
	if (sp.id & EMOJI_SPAN_FLAG) == 0 return false;
	idx := cast(int) sp.user - 1;
	if idx < 0 || idx >= emoji_db.emojis.count emoji_text_fallback(sp.text, r, opacity);
	else twemoji_draw_rect(emoji_db.emojis[idx].asset, r, opacity, sp.text);
	return true;
}

// Number of emoji in s, and whether s holds nothing but emoji and whitespace.
emoji_count :: (s: string) -> int, bool {
	n := 0;
	only := true;
	pos := 0;
	while true {
		seg, ok := emoji_next(s, pos);
		end := ifx ok then seg.start else s.count;
		if trim(string.{end - pos, s.data + pos}) != "" only = false;
		if !ok break;
		n += 1;
		pos = seg.end;
	}
	return n, only;
}

// Reaction / status emoji box: custom emoji image or twemoji (text if unknown).
emoji_box :: (id: string, e: dc.Emoji, size: float32) -> *ui.Box {
	idx := ifx e.id != 0 then -1 else emoji_lookup_surrogates(e.name);
	if idx < 0 return emoji_inline(id, e, size);
	b := ui.box(id);
	b.semantic_size = .[ui.px(size), ui.px(size)];
	set_twemoji(b, idx);
	return b;
}

// ---- composer ----

// ":name:" -> unicode before sending, like the client (outside inline/fenced
// code; unknown names stay as typed).
emoji_convert_shortcodes :: (text: string) -> string {
	if find_index_from_left(text, #char ":") < 0 return text;
	emoji_db_load();
	sb: String_Builder;
	sb.allocator = temp;
	i := 0;
	in_code := false;
	while i < text.count {
		c := text[i];
		if c == #char "`" in_code = !in_code;
		if c == #char ":" && !in_code {
			j := find_index_from_left(text, #char ":", i + 1);
			if j > i + 1 {
				name := string.{j - i - 1, text.data + i + 1};
				valid := true;
				for cast([]u8) name {
					if !(it == #char "_" || it == #char "-" || it == #char "+" || is_alnum(it)) {
						valid = false;
						break;
					}
				}
				found, idx := table_find(*emoji_db.by_name, name);
				if valid && found {
					append(*sb, emoji_db.emojis[idx].surr);
					i = j + 1;
					continue;
				}
			}
		}
		append(*sb, c);
		i += 1;
	}
	return builder_to_string(*sb,, temp);
}

// Offline runs (fixtures / UI tests): FASTCORD_MEDIA_DIR holds media files named
// by the last URL path component (e.g. f753793200a49ad6.svg, <id>.json).
offline_media :: (url: string) -> []u8, bool {
	dir := env_var("FASTCORD_MEDIA_DIR");
	if dir == "" return .[], false;
	u := url;
	q := find_index_from_left(u, #char "?");
	if q >= 0 u.count = q;
	name := u;
	advance(*name, find_index_from_right(u, #char "/") + 1);
	data, ok := read_entire_file(tprint("%/%", dir, name), log_errors = false,, temp);
	return cast([]u8) data, ok;
}

// A one-line label whose unicode emoji draw as Twemoji (custom status, names).
// Emoji are sized to the line (font size + 4, like the client's 1.375em-ish inline emoji).
emoji_label :: (text: string, font: Font_Id, size: float32, color: ui.Color, line_h: float32 = 0) -> *ui.Box {
	_, has_emoji := emoji_next(text, 0);
	if !has_emoji return label(text, font, size, color, line_h);
	b := ui.box(text, .Draw_Text);
	b.semantic_size = .[ui.text_size(0, 0), ui.text_size()];
	b.style.text_color = color;
	b.style.line_height = line_h;
	b.style.font = F(font);
	b.style.font_size = size;
	spans: [..]ui.Span;
	spans.allocator = temp;
	emoji_text_spans(*spans, .{text = text, font = F(font), size = size}, size + 4);
	ui.set_spans(b, spans);
	return b;
}

#scope_file

FE0F :: "️"; // U+FE0F VARIATION SELECTOR-16

by_norm: Table(string, int); // FE0F-stripped surrogates -> index (emoji with an image only)
by_norm_built: bool;
max_runes: int;


strip_fe0f :: (s: string) -> string {
	return ifx contains(s, FE0F) then replace(s, FE0F, "") else s;
}

ensure_index :: () {
	emoji_db_load();
	if by_norm_built return;
	by_norm_built = true;
	for e: emoji_db.emojis {
		if e.asset == "" continue; // ™ © ®: text, like the client
		k := strip_fe0f(e.surr,, temp);
		if table_contains(*by_norm, k) continue;
		table_add(*by_norm, copy_string(k), it_index);
		runes := 0;
		for cast([]u8) k if (it & 0xC0) != 0x80 runes += 1;
		max_runes = max(max_runes, runes);
	}
}

decode_rune :: (s: string, i: int) -> u32, int {
	r, n := character_utf8_to_utf32(s.data + i, s.count - i);
	return r, n;
}

could_start :: inline (r: u32, next: u32) -> bool {
	if r == #char "#" || r == #char "*" || (r >= #char "0" && r <= #char "9") return next == 0xFE0F || next == 0x20E3; // keycaps
	return (r >= 0x203C && r <= 0x3299) || r >= 0x1F000;
}

Twemoji :: struct {
	state: Image_State;
	icon: vector.Icon;
}

twemojis: Table(string, Twemoji);
tw_tex: Name_Px_Map;

twemoji_get :: (hash: string, visible := true) -> *Twemoji {
	t := table_find_pointer(*twemojis, hash);
	if t return t;
	key := copy_string(hash);
	t = table_add(*twemojis, key, .{state = .Loading});
	url := twemoji_url(key);
	if app.client != null {
		// an <img src="/assets/<hash>.svg"> load, like the client's emoji images
		dc.fetch_media(app.client, .{url = url, kind = .Image, visible = visible});
	} else {
		data, ok := offline_media(url);
		if ok twemoji_receive(url, 200, data);
		else t.state = .Failed;
	}
	return t;
}

Tw_Draw :: struct {
	hash: string;
	text: string; // unicode fallback while the svg loads
}

tw_box_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Tw_Draw) user;
	twemoji_draw_rect(d.hash, b.rect, b.opacity, d.text);
}
