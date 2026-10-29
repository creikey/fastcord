Text_Line :: struct {
	start, end: int; // byte range (end excludes the break char)
	glyph_start, glyph_end: int;
	x_shift: float32; // run-space x of the line's first glyph
	y: float32; // top of line, relative to layout origin
	width: float32;
}

Text_Layout :: struct {
	text: string;
	font: Font;
	size: float32;
	run: Shaped_Run; // all spans merged; glyph x is continuous across spans
	spans: []Span; // empty for plain text
	span_runs: []Shaped_Run; // backend run per span (glyph.handle indexes into it)
	lines: []Text_Line;
	width: float32;
	height: float32;
	line_h: float32;
	wrap_width: float32;
	baseline: float32; // from line top, CSS half-leading
	origin: Vec2; // screen position of the first line, set when drawn
}

// A run of rich text. Spans with object != 0 are inline objects (custom
// emoji, images) that occupy object.x by object.y and copy as their text.
Span :: struct {
	text: string;
	font: Font;
	size: float32;
	color: Color; // zero alpha = the box's text color
	bg: Color; // inline code / mention highlight
	bg_radius: float32;
	underline: bool;
	strike: bool;
	object: Vec2;
	id: u64; // app-defined (link index, mention id) for hit testing
	user: *void;
}

// Shape and wrap text. wrap_width < 0 means no wrapping (only hard newlines).
layout_text :: (font: Font, size: float32, text: string, wrap_width: float32, line_height: float32 = 0) -> *Text_Layout {
	s := context.ui;
	tl := New(Text_Layout,, s.frame_alloc);
	tl.text = text;
	tl.font = font;
	tl.size = size;
	tl.run = s.backend.shape(font, size, text);
	s.stats.text_layouts += 1;
	s.stats.shape_calls += 1;
	s.stats.glyphs += tl.run.glyphs.count;
	tl.line_h = ifx line_height > 0 then line_height else tl.run.line_h;
	tl.baseline = (tl.line_h - (tl.run.ascent + tl.run.descent)) / 2 + tl.run.ascent;
	wrap_layout(tl, wrap_width);
	return tl;
}

// Shape spans into one paragraph. The text of the layout is the spans' texts concatenated.
layout_rich :: (spans: []Span, wrap_width: float32, line_height: float32 = 0) -> *Text_Layout {
	s := context.ui;
	tl := New(Text_Layout,, s.frame_alloc);
	tl.spans = spans;
	tl.span_runs = NewArray(spans.count, Shaped_Run,, s.frame_alloc);
	tl.text = concat_spans(spans);
	glyphs: [..]Shaped_Glyph;
	glyphs.allocator = s.frame_alloc;
	array_reserve(*glyphs, 64);
	x, ascent, descent, lh: float32;
	base := 0;
	for sp, si: spans {
		defer base += sp.text.count;
		if sp.object != Vec2.{} {
			array_add(*glyphs, .{x = x, advance = sp.object.x, cluster_start = base, cluster_end = base + sp.text.count, span = cast(s32) si});
			x += sp.object.x;
			continue;
		}
		run := s.backend.shape(sp.font, sp.size, sp.text);
		s.stats.shape_calls += 1;
		tl.span_runs[si] = run;
		ascent = max(ascent, run.ascent);
		descent = max(descent, run.descent);
		lh = max(lh, run.line_h);
		for g, gi: run.glyphs {
			array_add(*glyphs, .{x = x + g.x, advance = g.advance, cluster_start = base + g.cluster_start, cluster_end = base + g.cluster_end, handle = cast(u64) gi, span = cast(s32) si});
		}
		x += run.width;
	}
	if spans.count {
		tl.font = spans[0].font;
		tl.size = spans[0].size;
	}
	tl.run = .{glyphs = glyphs, width = x, ascent = ascent, descent = descent, line_h = lh};
	s.stats.text_layouts += 1;
	s.stats.glyphs += glyphs.count;
	tl.line_h = ifx line_height > 0 then line_height else lh;
	tl.baseline = (tl.line_h - (ascent + descent)) / 2 + ascent;
	wrap_layout(tl, wrap_width);
	return tl;
}

// Index of the span under point p (screen space), or -1.
span_at :: (tl: *Text_Layout, p: Vec2) -> int {
	if tl == null || tl.spans.count == 0 return -1;
	local := p - tl.origin;
	if local.y < 0 || local.y >= tl.height return -1;
	l := tl.lines[clamp(cast(int)(local.y / tl.line_h), 0, tl.lines.count - 1)];
	for gi: l.glyph_start..l.glyph_end-1 {
		g := tl.run.glyphs[gi];
		gx := g.x - l.x_shift;
		if local.x >= gx && local.x < gx + g.advance return g.span;
	}
	return -1;
}

// Which line holds byte offset `pos`. A position at a wrap point belongs to
// the next line, except at the very end of text.
line_of :: (tl: *Text_Layout, pos: int) -> int {
	for l, i: tl.lines {
		if pos < l.end || (pos == l.end && i == tl.lines.count - 1) return i;
		if i + 1 < tl.lines.count && pos < tl.lines[i + 1].start return i; // inside a break char
	}
	return max(0, tl.lines.count - 1);
}

// x of the caret before byte `pos`, relative to the layout origin.
caret_x :: (tl: *Text_Layout, pos: int) -> float32 {
	if tl.lines.count == 0 return 0;
	return caret_x_in_line(tl, line_of(tl, pos), pos);
}

// Like caret_x, but on a given line (pos == line end is that line's end, not the next line's start).
caret_x_in_line :: (tl: *Text_Layout, li: int, pos: int) -> float32 {
	if tl.lines.count == 0 return 0;
	l := tl.lines[li];
	g := tl.run.glyphs;
	for gi: l.glyph_start..l.glyph_end-1 {
		gl := g[gi];
		if pos <= gl.cluster_start return gl.x - l.x_shift;
		if pos < gl.cluster_end {
			// inside a multi-codepoint cluster (ligature): interpolate by bytes
			t := cast(float32)(pos - gl.cluster_start) / cast(float32)(gl.cluster_end - gl.cluster_start);
			return gl.x + gl.advance * t - l.x_shift;
		}
	}
	if l.glyph_end > l.glyph_start {
		last := g[l.glyph_end - 1];
		return last.x + last.advance - l.x_shift;
	}
	return 0;
}

caret_pos :: (tl: *Text_Layout, pos: int) -> Vec2 {
	if tl.lines.count == 0 return tl.origin;
	return tl.origin + Vec2.{caret_x(tl, pos), tl.lines[line_of(tl, pos)].y};
}

// Byte offset nearest to point p (screen space).
hit_test :: (tl: *Text_Layout, p: Vec2) -> int {
	if tl.lines.count == 0 return 0;
	local := p - tl.origin;
	li := clamp(cast(int)(local.y / tl.line_h), 0, tl.lines.count - 1);
	if local.y < 0 return 0;
	if local.y >= tl.height return tl.text.count;
	return hit_test_line(tl, li, local.x);
}

hit_test_line :: (tl: *Text_Layout, li: int, x: float32) -> int {
	l := tl.lines[li];
	for gi: l.glyph_start..l.glyph_end-1 {
		gl := tl.run.glyphs[gi];
		if x < gl.x - l.x_shift + gl.advance / 2 return gl.cluster_start;
	}
	return l.end;
}

//////////////////////////////////////////////////////////////////////////////
// grapheme / word navigation shared by selection and the text editor

next_grapheme :: (s: string, pos: int) -> int {
	if pos >= s.count return s.count;
	return grapheme_end(s, pos);
}

prev_grapheme :: (s: string, pos: int) -> int {
	if pos <= 0 return 0;
	// Scan from the start of the line for correctness with ZWJ/combining sequences.
	line_start := find_index_from_right(slice(s, 0, pos), #char "\n") + 1;
	if line_start == pos return pos - 1;
	prev := line_start;
	while prev < s.count {
		end := grapheme_end(s, prev);
		if end >= pos return prev;
		prev = end;
	}
	return prev;
}

// Option+Right semantics: skip non-word chars, then the word.
next_word :: (s: string, pos: int) -> int {
	i := pos;
	while i < s.count && !is_word_byte(s[i]) i += 1;
	while i < s.count && is_word_byte(s[i]) i += 1;
	return i;
}

prev_word :: (s: string, pos: int) -> int {
	i := pos;
	while i > 0 && !is_word_byte(s[i - 1]) i -= 1;
	while i > 0 && is_word_byte(s[i - 1]) i -= 1;
	return i;
}

// Range a double-click at pos selects: the word, a run of spaces, or one punctuation char.
word_range_at :: (s: string, pos: int) -> int, int {
	if s.count == 0 return 0, 0;
	p := clamp(pos, 0, s.count - 1);
	if is_word_byte(s[p]) {
		a, b := p, p;
		while a > 0 && is_word_byte(s[a - 1]) a -= 1;
		while b < s.count && is_word_byte(s[b]) b += 1;
		return a, b;
	}
	if is_space_byte(s[p]) {
		a, b := p, p;
		while a > 0 && is_space_byte(s[a - 1]) a -= 1;
		while b < s.count && is_space_byte(s[b]) b += 1;
		return a, b;
	}
	return p, next_grapheme(s, p);
}

// The hard-newline-delimited paragraph containing pos (triple click).
paragraph_range_at :: (s: string, pos: int) -> int, int {
	a := find_index_from_right(slice(s, 0, clamp(pos, 0, s.count)), #char "\n") + 1;
	b := find_index_from_left(s, #char "\n", a);
	return a, ifx b < 0 then s.count else b;
}

//////////////////////////////////////////////////////////////////////////////
// Global selection across Selectable_Text boxes (e.g. dragging across many
// chat messages). Boxes are ordered by (box.sel_order, box.sel_sub), which the
// app sets to something stable (message id * N + field, then block index);
// endpoints survive the box scrolling out of view.

Text_Pos :: struct {
	order: u64;
	sub: u32;
	box: Key;
	byte: int;
}

Granularity :: enum u8 {
	Char;
	Word;
	Paragraph;
}

Selection :: struct {
	anchor, focus: Text_Pos;
	anchor_end: Text_Pos; // for word/paragraph drags: the far end of the anchor unit
	active: bool;
	dragging: bool;
	gran: Granularity;
}

pos_less :: (a: Text_Pos, b: Text_Pos) -> bool {
	if a.order != b.order return a.order < b.order;
	if a.sub != b.sub return a.sub < b.sub;
	return a.byte < b.byte;
}

// Where box b sits relative to p's box in reading order: -1 before, 0 same slot, 1 after.
slot_cmp :: (b: *Box, p: Text_Pos) -> int {
	if b.sel_order != p.order return ifx b.sel_order < p.order then -1 else 1;
	if b.sel_sub != p.sub return ifx b.sel_sub < p.sub then -1 else 1;
	return 0;
}

selection_range :: () -> lo: Text_Pos, hi: Text_Pos, ok: bool {
	sel := *context.ui.selection;
	if !sel.active return .{}, .{}, false;
	a, b := sel.anchor, sel.focus;
	if pos_less(b, a) {
		a, b = b, a;
		// dragging backwards from a word: keep the whole anchor word selected
		if sel.gran != .Char && pos_less(b, sel.anchor_end) b = sel.anchor_end;
	} else if sel.gran != .Char && pos_less(sel.anchor, a) {
		a = sel.anchor;
	}
	return a, b, !(a.order == b.order && a.box == b.box && a.byte == b.byte);
}

selection_clear :: () { context.ui.selection = .{}; }

has_selection :: () -> bool {
	_, _, ok := selection_range();
	return ok;
}

// Byte range of the selection inside box b, if any.
selection_in_box :: (b: *Box) -> int, int, bool {
	lo, hi, ok := selection_range();
	if !ok return 0, 0, false;
	cl, ch := slot_cmp(b, lo), slot_cmp(b, hi);
	if cl < 0 || ch > 0 return 0, 0, false;
	s0 := ifx cl == 0 then lo.byte else 0;
	s1 := ifx ch == 0 then hi.byte else b.text.count;
	if s0 >= s1 && ch == 0 return 0, 0, false;
	return s0, s1, true;
}

// Text of the current selection, from the boxes alive this frame.
selection_text :: (allocator := temp) -> string {
	lo, hi, ok := selection_range();
	if !ok return "";
	sb: String_Builder;
	sb.allocator = temp;
	first := true;
	for b: context.ui.selectables {
		s0, s1, in_sel := selection_in_box(b);
		if !in_sel continue;
		if !first append(*sb, ifx b.sel_join != "" then b.sel_join else "\n");
		first = false;
		s0 = clamp(s0, 0, b.text.count);
		append(*sb, slice(b.text, s0, clamp(s1, 0, b.text.count) - s0));
	}
	return builder_to_string(*sb,, allocator);
}

#scope_module

is_space_byte :: (c: u8) -> bool { return c == #char " " || c == #char "\t"; }

// Treats non-ASCII (letters, emoji) as word chars.
is_word_byte :: (c: u8) -> bool {
	return c >= 0x80 || (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z") || (c >= #char "0" && c <= #char "9") || c == #char "_" || c == #char "'";
}

// The spans' texts concatenated, in the frame arena.
concat_spans :: (spans: []Span) -> string {
	n := 0;
	for spans n += it.text.count;
	out := alloc_string(n,, context.ui.frame_alloc);
	n = 0;
	for spans {
		memcpy(out.data + n, it.text.data, it.text.count);
		n += it.text.count;
	}
	return out;
}

// One UTF-8 code point at s[i]: the rune (0xFFFD if malformed) and its length.
decode_rune :: (s: string, i: int) -> u32, int {
	c := s[i];
	if c < 0x80 return c, 1;
	n := ifx c >= 0xF0 then 4 else ifx c >= 0xE0 then 3 else ifx c >= 0xC0 then 2 else 0;
	if n == 0 || i + n > s.count return 0xFFFD, 1;
	r := cast(u32) (c & (0x7F >> n));
	for k: 1..n-1 {
		if (s[i + k] & 0xC0) != 0x80 return 0xFFFD, 1;
		r = (r << 6) | (s[i + k] & 0x3F);
	}
	return r, n;
}

// End of the grapheme cluster starting at pos < s.count. Simplified extended clusters: a base rune
// plus combining marks, variation selectors, skin tones, ZWJ sequences, keycaps, tags, and
// regional-indicator pairs.
grapheme_end :: (s: string, pos: int) -> int {
	extends :: (r: u32) -> bool {
		return (r >= 0x300 && r <= 0x36F) || (r >= 0x1AB0 && r <= 0x1AFF) || (r >= 0x1DC0 && r <= 0x1DFF) || (r >= 0x20D0 && r <= 0x20FF)
			|| (r >= 0xFE00 && r <= 0xFE0F) || (r >= 0xFE20 && r <= 0xFE2F) || (r >= 0x1F3FB && r <= 0x1F3FF) || (r >= 0xE0020 && r <= 0xE007F)
			|| (r >= 0xE0100 && r <= 0xE01EF) || r == 0x200D || r == 0x20E3;
	}
	regional :: (r: u32) -> bool { return r >= 0x1F1E6 && r <= 0x1F1FF; }
	r, n := decode_rune(s, pos);
	i := pos + n;
	if r == #char "\r" && i < s.count && s[i] == #char "\n" i += 1;
	ri := regional(r);
	prev := r;
	while i < s.count {
		r2, n2 := decode_rune(s, i);
		if ri && regional(r2) {
			ri = false;
		} else if !extends(r2) && prev != 0x200D {
			break;
		}
		i += n2;
		prev = r2;
	}
	return i;
}

wrap_layout :: (tl: *Text_Layout, wrap_width: float32) {
	text := tl.text;
	tl.wrap_width = wrap_width;
	lines: [..]Text_Line;
	lines.allocator = context.ui.frame_alloc;
	array_reserve(*lines, 4);
	g := tl.run.glyphs;

	line_start_g := 0;
	line_start_b := 0;
	last_break_g := -1; // glyph index after which we can break
	i := 0;
	while i < g.count {
		gl := g[i];
		c := ifx gl.cluster_start < text.count then text[gl.cluster_start] else 0;
		if c == #char "\n" {
			array_add(*lines, make_line(tl, line_start_g, i, line_start_b, gl.cluster_start));
			line_start_g = i + 1;
			line_start_b = gl.cluster_end;
			last_break_g = -1;
			i += 1;
			continue;
		}
		if wrap_width >= 0 && i > line_start_g && gl.x + gl.advance - g[line_start_g].x > wrap_width && !is_space_byte(c) {
			brk := ifx last_break_g >= 0 then last_break_g + 1 else i;
			end_b := g[brk].cluster_start;
			// trailing spaces stay on the line but don't count toward width
			array_add(*lines, make_line(tl, line_start_g, brk, line_start_b, end_b));
			line_start_g = brk;
			line_start_b = end_b;
			last_break_g = -1;
			i = brk;
			continue;
		}
		if is_space_byte(c) last_break_g = i;
		i += 1;
	}
	array_add(*lines, make_line(tl, line_start_g, g.count, line_start_b, text.count));
	tl.lines = lines;
	for * l, li: tl.lines {
		l.y = li * tl.line_h;
		tl.width = max(tl.width, l.width);
	}
	tl.height = tl.lines.count * tl.line_h;
}

make_line :: (tl: *Text_Layout, g0: int, g1: int, b0: int, b1: int) -> Text_Line {
	g := tl.run.glyphs;
	l := Text_Line.{start = b0, end = b1, glyph_start = g0, glyph_end = g1};
	if g0 < g.count l.x_shift = g[g0].x;
	// width excludes trailing whitespace
	last := g1 - 1;
	while last >= g0 && g[last].cluster_start < tl.text.count && is_space_byte(tl.text[g[last].cluster_start]) last -= 1;
	if last >= g0 l.width = g[last].x + g[last].advance - l.x_shift;
	return l;
}

collect_selectables :: (b: *Box, depth := 0) {
	assert(depth < MAX_BOX_DEPTH);
	s := context.ui;
	if (b.flags & .Selectable_Text) && b.key != 0 {
		if b.sel_order == 0 b.sel_order = cast(u64) s.selectables.count + 1;
		array_add(*s.selectables, b);
	}
	for c: each_child(b) collect_selectables(c, depth + 1);
}

// Text position nearest the mouse among visible selectables. Rows are found
// by vertical extent first, like a browser. .Exact: only a box under p; .Region: the nearest box
// whose clip region (e.g. the message list) holds p, so a press beside or between texts starts a
// selection there; .Any: the nearest box anywhere (while dragging).
Pos_Mode :: enum u8 { Exact; Region; Any; }
selectable_pos_at :: (p: Vec2, mode: Pos_Mode) -> Text_Pos, bool {
	best: *Box;
	best_d := FLOAT32_MAX;
	for b: context.ui.selectables {
		r := visible_rect(b);
		if r.x1 <= r.x0 || r.y1 <= r.y0 continue;
		if contains(b.rect, p) {
			best = b;
			break;
		}
		if mode == .Exact continue;
		if mode == .Region {
			c := b.parent;
			while c && !(c.flags & .Clip) c = c.parent;
			if !c || !contains(visible_rect(c), p) continue;
		}
		// distance, weighting vertical much more than horizontal
		dy := ifx p.y < b.rect.y0 then b.rect.y0 - p.y else ifx p.y > b.rect.y1 then p.y - b.rect.y1 else 0;
		dx := ifx p.x < b.rect.x0 then b.rect.x0 - p.x else ifx p.x > b.rect.x1 then p.x - b.rect.x1 else 0;
		d := dy * 1000 + dx;
		if d < best_d {
			best_d = d;
			best = b;
		}
	}
	if !best return .{}, false;
	tl := text_layout_for(best, best.fixed_size.x - best.style.padding.x * 2);
	if tl.origin == Vec2.{} tl.origin = .{best.rect.x0 + best.style.padding.x, best.rect.y0 + best.style.padding.y};
	byte := hit_test(tl, p);
	if p.y > best.rect.y1 byte = best.text.count;
	if p.y < best.rect.y0 byte = 0;
	return .{order = best.sel_order, sub = best.sel_sub, box = best.key, byte = byte}, true;
}

update_selection :: () {
	s := context.ui;
	collect_selectables(s.root);
	sel := *s.selection;
	for * e: s.events {
		if e.consumed continue;
		if e.kind == .Mouse_Up && e.button == .Left sel.dragging = false;
		if e.kind != .Mouse_Down || e.button != .Left continue;
		// what is under the press itself (hot is for the mouse after all of this frame's events)
		on_control := hit_test_prev(e.pos) != 0;
		pos, ok := selectable_pos_at(e.pos, .Exact);
		if !ok && !on_control pos, ok = selectable_pos_at(e.pos, .Region);
		if !ok {
			if !on_control selection_clear();
			continue;
		}
		if (e.mods & .Shift) && sel.active {
			sel.focus = pos;
		} else {
			sel.active = true;
			sel.anchor = pos;
			sel.focus = pos;
			sel.gran = .Char;
			text := box_lookup(pos.box).text;
			if e.click_count == 2 {
				sel.anchor.byte, sel.focus.byte = word_range_at(text, pos.byte);
				sel.gran = .Word;
			} else if e.click_count >= 3 {
				sel.anchor.byte, sel.focus.byte = paragraph_range_at(text, pos.byte);
				sel.gran = .Paragraph;
			}
			sel.anchor_end = sel.focus;
		}
		sel.dragging = true;
		s.focus = 0;
		e.consumed = true;
	}
	// every frame, not only on mouse moves: autoscroll moves the text under a still mouse
	if sel.dragging {
		pos, ok := selectable_pos_at(s.mouse, .Any);
		if ok {
			b := box_lookup(pos.box);
			if b && sel.gran != .Char {
				a, z: int;
				if sel.gran == .Word a, z = word_range_at(b.text, pos.byte);
				else a, z = paragraph_range_at(b.text, pos.byte);
				pos.byte = ifx pos_less(pos, sel.anchor) then a else z;
			}
			sel.focus = pos;
		}
	}
	if sel.dragging s.cursor = .IBeam;
	for b: s.selectables if b.key == s.hot || (s.hot == 0 && mouse_over(b)) s.cursor = .IBeam;
	if s.span_cursor != .Default && !sel.dragging s.cursor = s.span_cursor;
}

draw_selection_highlight :: (b: *Box, tl: *Text_Layout) {
	s0, s1, ok := selection_in_box(b);
	if !ok return;
	_, hi := selection_range();
	c := context.ui.selection_color;
	for l, li: tl.lines {
		a := max(s0, l.start);
		z := min(s1, l.end);
		last := li + 1 == tl.lines.count;
		continues := (s1 > l.end && !last) || (last && slot_cmp(b, hi) < 0);
		if a > z || (a == z && !continues) continue;
		x0 := caret_x_in_line(tl, li, a);
		x1 := ifx a == z then x0 else caret_x_in_line(tl, li, z);
		if continues x1 += tl.size * 0.3; // show that the newline is selected
		draw_rect(.{tl.origin.x + x0, tl.origin.y + l.y, tl.origin.x + x1, tl.origin.y + l.y + tl.line_h}, c);
	}
}

#scope_export
