package app

import "core:math"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import dc "fc:discord"
import "fc:gfx"
import "fc:ui"
import "fc:vector"

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

@(private = "file")
by_norm: map[string]int // FE0F-stripped surrogates -> index (emoji with an image only)
@(private = "file")
max_runes: int

@(private = "file")
strip_fe0f :: proc(s: string, allocator := context.temp_allocator) -> string {
	if strings.index(s, "️") < 0 do return s
	out, _ := strings.remove_all(s, "️", allocator)
	return out
}

@(private = "file")
ensure_index :: proc() {
	emoji_db_load()
	if by_norm != nil do return
	by_norm = make(map[string]int, len(emoji_db.emojis))
	for e, i in emoji_db.emojis {
		if e.asset == "" do continue // ™ © ®: text, like the client
		k := strip_fe0f(e.surr, context.allocator)
		if k not_in by_norm do by_norm[k] = i
		max_runes = max(max_runes, utf8.rune_count(k))
	}
}

emoji_lookup_name :: proc(name: string) -> int {
	emoji_db_load()
	n := strings.trim(name, ":")
	if i, ok := emoji_db.by_name[n]; ok do return i
	return -1
}

emoji_lookup_surrogates :: proc(s: string) -> int {
	ensure_index()
	if i, ok := by_norm[strip_fe0f(s)]; ok do return i
	return -1
}

// A run of text that is one emoji.
Emoji_Segment :: struct {
	start, end: int, // byte range in the text (includes trailing U+FE0F)
	index:      int, // emoji_db index
}

@(private = "file")
could_start :: #force_inline proc(r: rune, next: rune) -> bool {
	if r == '#' || r == '*' || (r >= '0' && r <= '9') do return next == 0xFE0F || next == 0x20E3 // keycaps
	return (r >= 0x203C && r <= 0x3299) || r >= 0x1F000
}

// Next emoji at or after byte `from`: longest match on FE0F-insensitive
// sequences (ZWJ families, skin tones, flags, keycaps). ok=false: none left.
emoji_next :: proc(text: string, from: int) -> (seg: Emoji_Segment, ok: bool) {
	ensure_index()
	i := from
	runes: [24]rune
	ends: [24]int
	for i < len(text) {
		r, w := utf8.decode_rune_in_string(text[i:])
		next: rune
		if i + w < len(text) do next, _ = utf8.decode_rune_in_string(text[i + w:])
		if !could_start(r, next) {
			i += w
			continue
		}
		// gather up to max_runes non-FE0F runes (FE0F bytes stay inside the span)
		n := 0
		j := i
		for j < len(text) && n < min(max_runes, len(runes)) {
			rr, ww := utf8.decode_rune_in_string(text[j:])
			j += ww
			if rr == 0xFE0F {
				if n > 0 do ends[n - 1] = j
				continue
			}
			runes[n] = rr
			ends[n] = j
			n += 1
		}
		buf: [96]u8
		for k := n; k >= 1; k -= 1 {
			sb := strings.builder_from_bytes(buf[:])
			for q in 0 ..< k do strings.write_rune(&sb, runes[q])
			if idx, found := by_norm[strings.to_string(sb)]; found {
				return {i, ends[k - 1], idx}, true
			}
		}
		i += w
	}
	return {}, false
}

// ---- twemoji images ----

twemoji_url :: proc(hash: string) -> string {
	return strings.concatenate({"https://discord.com/assets/", hash, ".svg"}, context.temp_allocator)
}

@(private = "file")
Twemoji :: struct {
	state: Image_State,
	icon:  vector.Icon,
}

@(private = "file")
Tw_Key :: struct {
	hash: string,
	px:   int,
}

@(private = "file")
twemojis: map[string]Twemoji
@(private = "file")
tw_tex: map[Tw_Key]gfx.Texture

@(private = "file")
twemoji_get :: proc(hash: string, visible := true) -> ^Twemoji {
	if t, ok := &twemojis[hash]; ok do return t
	key := strings.clone(hash)
	twemojis[key] = {state = .Loading}
	if app.client != nil {
		// an <img src="/assets/<hash>.svg"> load, like the client's emoji images
		dc.fetch_media(app.client, {url = twemoji_url(key), kind = .Image, visible = visible})
	} else if data, ok := offline_media(twemoji_url(key)); ok {
		twemoji_receive(twemoji_url(key), 200, data)
	} else {
		twemojis[key] = {state = .Failed}
	}
	return &twemojis[key]
}

// images_receive routes finished .svg loads here; true if it was a twemoji.
twemoji_receive :: proc(url: string, status: int, data: []byte) -> bool {
	PFX :: "https://discord.com/assets/"
	if !strings.has_prefix(url, PFX) || !strings.has_suffix(url, ".svg") do return false
	hash := url[len(PFX):len(url) - 4]
	t, ok := &twemojis[hash]
	if !ok do return false
	if status != 200 || len(data) == 0 {
		t.state = .Failed
		return true
	}
	icon, pok := vector.parse_svg(string(data))
	if !pok {
		t.state = .Failed
		return true
	}
	t.icon = icon
	t.state = .Ready
	app.ui.animating = true
	return true
}

// Texture of an emoji at px device pixels (0 while loading).
twemoji_texture :: proc(hash: string, px: int) -> gfx.Texture {
	if hash == "" || px <= 0 do return 0
	t := twemoji_get(hash)
	if t.state != .Ready do return 0
	k := Tw_Key{hash, px}
	if tex, ok := tw_tex[k]; ok do return tex
	pixels := vector.rasterize_rgba(&t.icon, px, px, allocator = context.temp_allocator)
	tex := gfx.texture_from_rgba(px, px, pixels)
	k.hash = strings.clone(hash)
	tw_tex[k] = tex
	return tex
}

// Twemoji in r; until its texture exists (loading, failed, offline) the unicode
// `fallback` is drawn with the system emoji font in the same rect, so emoji
// never render invisible (progressive load).
twemoji_draw_rect :: proc(hash: string, r: ui.Rect, opacity: f32, fallback := "") {
	px := int(math.round((r.x1 - r.x0) * max(gfx.scale(), 1)))
	tex := twemoji_texture(hash, px)
	if tex == 0 {
		emoji_text_fallback(fallback, r, opacity)
		return
	}
	c := gfx.Color{1, 1, 1, opacity}
	gfx.push_rect({dst = gfx.Rect(r), tex = tex, colors = {c, c, c, c}})
}

// The unicode text centered in r (system font; CoreText / DirectWrite fall back to the color emoji font).
emoji_text_fallback :: proc(text: string, r: ui.Rect, opacity: f32) {
	if text == "" || opacity <= 0 do return
	h := r.y1 - r.y0
	size := h * 0.8
	face := fonts[.Normal]
	run := gfx.shape(face, size, text)
	m := gfx.font_metrics(face, size)
	x := r.x0 + ((r.x1 - r.x0) - run.width) / 2
	y := r.y0 + (h - (m.ascent + m.descent)) / 2 + m.ascent
	gfx.draw_run(run, {x, y}, {1, 1, 1, opacity})
}

@(private = "file")
Tw_Draw :: struct {
	hash: string,
	text: string, // unicode fallback while the svg loads
}

@(private = "file")
tw_box_draw :: proc(b: ^ui.Box, user: rawptr) {
	d := (^Tw_Draw)(user)
	twemoji_draw_rect(d.hash, b.rect, b.opacity, d.text)
}

// Draw emoji `index` (emoji_db) filling the box.
set_twemoji :: proc(b: ^ui.Box, index: int) {
	emoji_db_load()
	if index < 0 || index >= len(emoji_db.emojis) do return
	h := emoji_db.emojis[index].asset
	if h != "" do twemoji_get(h)
	d := new(Tw_Draw, context.temp_allocator)
	d.hash = h
	d.text = emoji_db.emojis[index].surr
	b.custom_draw = tw_box_draw
	b.custom_user = d
}

// ---- rich text ----

// Spans for unicode emoji carry this bit in Span.id and the emoji index in user.
EMOJI_SPAN_FLAG :: u64(1) << 62

// Splits `sp` (a text span) into text and inline-emoji spans (size px objects).
// The emoji spans keep the original unicode as their text, so copy/selection
// round-trips.
emoji_text_spans :: proc(out: ^[dynamic]ui.Span, sp: ui.Span, size: f32 = 22) {
	text := sp.text
	pos := 0
	for {
		seg, ok := emoji_next(text, pos)
		if !ok do break
		if seg.start > pos {
			t := sp
			t.text = text[pos:seg.start]
			append(out, t)
		}
		e := sp
		e.text = text[seg.start:seg.end]
		e.object = {size, size}
		e.id = sp.id | EMOJI_SPAN_FLAG
		e.user = rawptr(uintptr(seg.index + 1))
		e.bg = {}
		append(out, e)
		pos = seg.end
	}
	if pos == 0 {
		append(out, sp)
	} else if pos < len(text) {
		t := sp
		t.text = text[pos:]
		append(out, t)
	}
}

// Inline-object hook for unicode emoji spans; false if the span is something else.
draw_unicode_emoji_span :: proc(sp: ui.Span, r: ui.Rect, opacity: f32) -> bool {
	if sp.id & EMOJI_SPAN_FLAG == 0 do return false
	idx := int(uintptr(sp.user)) - 1
	if idx < 0 || idx >= len(emoji_db.emojis) {
		emoji_text_fallback(sp.text, r, opacity)
		return true
	}
	twemoji_draw_rect(emoji_db.emojis[idx].asset, r, opacity, sp.text)
	return true
}

// Number of emoji in s, and whether s holds nothing but emoji and whitespace.
emoji_count :: proc(s: string) -> (n: int, only: bool) {
	pos := 0
	only = true
	for {
		seg, ok := emoji_next(s, pos)
		gap := s[pos:ok ? seg.start : len(s)]
		if strings.trim_space(gap) != "" do only = false
		if !ok do break
		n += 1
		pos = seg.end
	}
	return
}

// Reaction / status emoji box: custom emoji image or twemoji (text if unknown).
emoji_box :: proc(id: string, e: dc.Emoji, size: f32) -> ^ui.Box {
	if e.id != 0 do return emoji_inline(id, e, size)
	idx := emoji_lookup_surrogates(e.name)
	if idx < 0 do return emoji_inline(id, e, size)
	b := ui.box(id)
	b.semantic_size = {.X = ui.px(size), .Y = ui.px(size)}
	set_twemoji(b, idx)
	return b
}

// ---- composer ----

// ":name:" -> unicode before sending, like the client (outside inline/fenced
// code; unknown names stay as typed).
emoji_convert_shortcodes :: proc(text: string) -> string {
	if strings.index_byte(text, ':') < 0 do return text
	emoji_db_load()
	sb := strings.builder_make(context.temp_allocator)
	i := 0
	in_code := false
	for i < len(text) {
		c := text[i]
		if c == '`' {
			in_code = !in_code
			strings.write_byte(&sb, c)
			i += 1
			continue
		}
		if c == ':' && !in_code {
			end := strings.index_byte(text[i + 1:], ':')
			if end > 0 {
				name := text[i + 1:i + 1 + end]
				valid := true
				for ch in name {
					if !(ch == '_' || ch == '-' || ch == '+' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) {
						valid = false
						break
					}
				}
				if valid {
					if idx, ok := emoji_db.by_name[name]; ok {
						strings.write_string(&sb, emoji_db.emojis[idx].surr)
						i += end + 2
						continue
					}
				}
			}
		}
		strings.write_byte(&sb, c)
		i += 1
	}
	return strings.to_string(sb)
}

// Offline runs (fixtures / UI tests): FASTCORD_MEDIA_DIR holds media files named
// by the last URL path component (e.g. f753793200a49ad6.svg, <id>.json).
offline_media :: proc(url: string) -> ([]byte, bool) {
	dir := os.get_env("FASTCORD_MEDIA_DIR", context.temp_allocator)
	if dir == "" do return nil, false
	u := url
	if q := strings.index_byte(u, '?'); q >= 0 do u = u[:q]
	name := u[strings.last_index_byte(u, '/') + 1:]
	data, err := os.read_entire_file(strings.concatenate({dir, "/", name}, context.temp_allocator), context.temp_allocator)
	return data, err == nil
}

// A one-line label whose unicode emoji draw as Twemoji (custom status, names).
// Emoji are sized to the line (font size + 4, like the client's 1.375em-ish inline emoji).
emoji_label :: proc(text: string, font: Font_Id, size: f32, color: ui.Color, line_h: f32 = 0) -> ^ui.Box {
	if _, ok := emoji_next(text, 0); !ok do return label(text, font, size, color, line_h)
	b := ui.box(text, {.Draw_Text})
	b.semantic_size = {.X = ui.text_size(0, 0), .Y = ui.text_size()}
	b.style.text_color = color
	b.style.line_height = line_h
	b.style.font = F(font)
	b.style.font_size = size
	spans := make([dynamic]ui.Span, context.temp_allocator)
	emoji_text_spans(&spans, ui.Span{text = text, font = F(font), size = size}, size + 4)
	ui.set_spans(b, spans[:])
	return b
}
