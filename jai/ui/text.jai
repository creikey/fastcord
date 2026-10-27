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
	spans: []Span; // nil for plain text
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
#scope_module

is_space_byte :: (c: u8) -> bool {return c == #char " " || c == 9;}
#scope_export

// Shape and wrap text. wrap_width < 0 means no wrapping (only hard newlines).
layout_text :: (font: Font, size: float32, text: string, wrap_width: float32, line_height: float32 = 0) -> *Text_Layout {
	s := context.ui;
	tl := new(Text_Layout, s.frame_alloc);
	tl.text = text;
	tl.font = font;
	tl.size = size;
	tl.run = s.backend.shape(font, size, text);
	s.stats.text_layouts += 1;
	s.stats.shape_calls += 1;
	s.stats.glyphs += len(tl.run.glyphs);
	tl.line_h = ifx line_height > 0 then line_height else tl.run.line_h;
	tl.baseline = (tl.line_h - (tl.run.ascent + tl.run.descent)) / 2 + tl.run.ascent;
	wrap_layout(tl, wrap_width);
	return tl;
}

// Shape spans into one paragraph. The text of the layout is the spans' texts concatenated.
layout_rich :: (spans: []Span, wrap_width: float32, line_height: float32 = 0) -> *Text_Layout {
	s := context.ui;
	tl := new(Text_Layout, s.frame_alloc);
	tl.spans = spans;
	tl.span_runs = make_slice(Shaped_Run, len(spans), s.frame_alloc);
	sb := strings.builder_make(s.frame_alloc);
	glyphs := make_dynamic(Shaped_Glyph, 0, 64, s.frame_alloc);
	x: float32;
	ascent, descent, lh: float32;
	for sp, si: spans {
		base := strings.builder_len(sb);
		strings.write_string(*sb, sp.text);
		if !(sp.object == Vec2.{}) {
			append(*glyphs, Shaped_Glyph.{x = x, advance = sp.object.x, cluster_start = base, cluster_end = base + len(sp.text), handle = 0, span = cast(s32)(si)});
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
			append(*glyphs, Shaped_Glyph.{x = x + g.x, advance = g.advance, cluster_start = base + g.cluster_start, cluster_end = base + g.cluster_end, handle = cast(u64)(gi), span = cast(s32)(si)});
		}
		x += run.width;
	}
	tl.text = strings.to_string(sb);
	if len(spans) > 0 {
		tl.font = spans[0].font;
		tl.size = spans[0].size;
	}
	tl.run = Shaped_Run.{glyphs = view(glyphs), width = x, ascent = ascent, descent = descent, line_h = lh};
	s.stats.text_layouts += 1;
	s.stats.glyphs += len(glyphs);
	tl.line_h = ifx line_height > 0 then line_height else lh;
	tl.baseline = (tl.line_h - (ascent + descent)) / 2 + ascent;
	wrap_layout(tl, wrap_width);
	return tl;
}

// Index of the span under point p (screen space), or -1.
span_at :: (tl: *Text_Layout, p: Vec2) -> int {
	if tl == null || tl.spans.count == 0 { return -1; }
	local := p - tl.origin;
	if local.y < 0 || local.y >= tl.height { return -1; }
	li := clamp(cast(int)(local.y / tl.line_h), 0, len(tl.lines) - 1);
	l := get(tl.lines, li);
	for gi: l.glyph_start..l.glyph_end-1 {
		g := get(tl.run.glyphs, gi);
		gx := g.x - l.x_shift;
		if local.x >= gx && local.x < gx + g.advance { return cast(int)(g.span); }
	}
	return -1;
}
#scope_module

wrap_layout :: (tl: *Text_Layout, wrap_width: float32) {
	s := context.ui;
	text := tl.text;
	tl.wrap_width = wrap_width;
	lines := make_dynamic(Text_Line, 0, 4, s.frame_alloc);
	g := tl.run.glyphs;

	line_start_g := 0;
	line_start_b := 0;
	last_break_g := -1; // glyph index after which we can break
	i := 0;
	while i < len(g) {
		gl := g[i];
		c := ifx gl.cluster_start < len(text) then text[gl.cluster_start] else 0;
		if c == 10 {
			append(*lines, make_line(tl, line_start_g, i, line_start_b, gl.cluster_start));
			line_start_g = i + 1;
			line_start_b = gl.cluster_end;
			last_break_g = -1;
			i += 1;
			continue;
		}
		if wrap_width >= 0 && i > line_start_g {
			x0 := g[line_start_g].x;
			if gl.x + gl.advance - x0 > wrap_width && !is_space_byte(c) {
				brk := ifx last_break_g >= 0 then last_break_g + 1 else i;
				end_b := g[brk].cluster_start;
				// trailing spaces stay on the line but don't count toward width
				append(*lines, make_line(tl, line_start_g, brk, line_start_b, end_b));
				line_start_g = brk;
				line_start_b = end_b;
				last_break_g = -1;
				i = brk;
				continue;
			}
		}
		if is_space_byte(c) { last_break_g = i; }
		i += 1;
	}
	append(*lines, make_line(tl, line_start_g, len(g), line_start_b, len(text)));
	tl.lines = view(lines);
	for * l, li: tl.lines {
		l.y = cast(float32)(li) * tl.line_h;
		tl.width = max(tl.width, l.width);
	}
	tl.height = cast(float32)(len(tl.lines)) * tl.line_h;
}

make_line :: (tl: *Text_Layout, g0: int, g1: int, b0: int, b1: int) -> Text_Line {
	g := tl.run.glyphs;
	l := Text_Line.{start = b0, end = b1, glyph_start = g0, glyph_end = g1};
	if g0 < len(g) { l.x_shift = g[g0].x; }
	// width excludes trailing whitespace
	last := g1 - 1;
	while last >= g0 && g[last].cluster_start < len(tl.text) && is_space_byte(tl.text[g[last].cluster_start]) { last -= 1; }
	if last >= g0 { l.width = g[last].x + g[last].advance - l.x_shift; }
	return l;
}
#scope_export

// Which line holds byte offset `pos`. A position at a wrap point belongs to
// the next line, except at the very end of text.
line_of :: (tl: *Text_Layout, pos: int) -> int {
	for l, i: tl.lines {
		if pos < l.end || (pos == l.end && i == len(tl.lines) - 1) { return i; }
		if i + 1 < len(tl.lines) && pos < tl.lines[i + 1].start { return i; } // inside a break char
	}
	return max(0, len(tl.lines) - 1);
}

// x of the caret before byte `pos`, relative to the layout origin.
caret_x :: (tl: *Text_Layout, pos: int) -> float32 {
	if len(tl.lines) == 0 { return 0; }
	return caret_x_in_line(tl, line_of(tl, pos), pos);
}

// Like caret_x, but on a given line (pos == line end is that line's end, not the next line's start).
caret_x_in_line :: (tl: *Text_Layout, li: int, pos: int) -> float32 {
	if len(tl.lines) == 0 { return 0; }
	l := get(tl.lines, li);
	g := tl.run.glyphs;
	for gi: l.glyph_start..l.glyph_end-1 {
		gl := g[gi];
		if pos <= gl.cluster_start { return gl.x - l.x_shift; }
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
	if len(tl.lines) == 0 { return tl.origin; }
	li := line_of(tl, pos);
	return tl.origin + .{caret_x(tl, pos), get(tl.lines, li).y};
}

// Byte offset nearest to point p (screen space).
hit_test :: (tl: *Text_Layout, p: Vec2) -> int {
	if len(tl.lines) == 0 { return 0; }
	local := p - tl.origin;
	li := cast(int)(local.y / tl.line_h);
	li = clamp(li, 0, len(tl.lines) - 1);
	if local.y < 0 { return 0; }
	if local.y >= tl.height { return len(tl.text); }
	return hit_test_line(tl, li, local.x);
}

hit_test_line :: (tl: *Text_Layout, li: int, x: float32) -> int {
	l := get(tl.lines, li);
	g := tl.run.glyphs;
	for gi: l.glyph_start..l.glyph_end-1 {
		gl := g[gi];
		gx := gl.x - l.x_shift;
		if x < gx + gl.advance / 2 { return gl.cluster_start; }
	}
	return l.end;
}

//////////////////////////////////////////////////////////////////////////////
// grapheme / word navigation shared by selection and the text editor

next_grapheme :: (s: string, pos: int) -> int {
	if pos >= len(s) { return len(s); }
	it_ := utf8.decode_grapheme_iterator_make(sub_from(s, pos));
	{ txt, _, ok := utf8.decode_grapheme_iterate(*it_);
	if ok { return pos + len(txt); } }
	return len(s);
}

prev_grapheme :: (s: string, pos: int) -> int {
	if pos <= 0 { return 0; }
	// Scan from the start of the line for correctness with ZWJ/combining sequences.
	line_start := strings.last_index_byte(sub(s, 0, pos), 10) + 1;
	if line_start == pos { return pos - 1; }
	prev := line_start;
	it_ := utf8.decode_grapheme_iterator_make(sub_from(s, line_start));
	while true { txt, _, __ok1 := utf8.decode_grapheme_iterate(*it_); if !__ok1 break;
		end := prev + len(txt);
		if end >= pos { return prev; }
		prev = end;
	}
	return prev;
}
#scope_module

is_word_byte :: (s: string, i: int) -> bool {
	c := s[i];
	if c >= 0x80 { return true; } // treat non-ASCII (letters, emoji) as word chars
	return (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z") || (c >= #char "0" && c <= #char "9") || c == #char "_" || c == #char "'";
}
#scope_export

// Option+Right semantics: skip non-word chars, then the word.
next_word :: (s: string, pos: int) -> int {
	i := pos;
	while i < len(s) && !is_word_byte(s, i) { i += 1; }
	while i < len(s) && is_word_byte(s, i) { i += 1; }
	return i;
}

prev_word :: (s: string, pos: int) -> int {
	i := pos;
	while i > 0 && !is_word_byte(s, i - 1) { i -= 1; }
	while i > 0 && is_word_byte(s, i - 1) { i -= 1; }
	return i;
}

// Range a double-click at pos selects: the word, a run of spaces, or one punctuation char.
word_range_at :: (s: string, pos: int) -> int, int {
	if len(s) == 0 { return 0, 0; }
	p := clamp(pos, 0, len(s) - 1);
	if pos == len(s) && p > 0 { p = len(s) - 1; }
	if is_word_byte(s, p) {
		a, b := p, p;
		while a > 0 && is_word_byte(s, a - 1) { a -= 1; }
		while b < len(s) && is_word_byte(s, b) { b += 1; }
		return a, b;
	}
	if is_space_byte(s[p]) {
		a, b := p, p;
		while a > 0 && is_space_byte(s[a - 1]) { a -= 1; }
		while b < len(s) && is_space_byte(s[b]) { b += 1; }
		return a, b;
	}
	return p, next_grapheme(s, p);
}

// The hard-newline-delimited paragraph containing pos (triple click).
paragraph_range_at :: (s: string, pos: int) -> int, int {
	a := strings.last_index_byte(sub(s, 0, clamp(pos, 0, len(s))), 10) + 1;
	b := strings.index_byte(sub_from(s, a), 10);
	return a, ifx b < 0 then len(s) else a + b;
}

//////////////////////////////////////////////////////////////////////////////
// Global selection across Selectable_Text boxes (e.g. dragging across many
// chat messages). Boxes are ordered by box.sel_order, which the app sets to
// something stable (message id * N + field); endpoints survive the box
// scrolling out of view.

Text_Pos :: struct {
	order: u64;
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
	if a.order != b.order { return a.order < b.order; }
	return a.byte < b.byte;
}

selection_range :: () -> Text_Pos, Text_Pos, bool {
	lo: Text_Pos;
	hi: Text_Pos;
	ok: bool;
	sel := *context.ui.selection;
	if !sel.active { return .{}, .{}, false; }
	a, b := sel.anchor, sel.focus;
	if pos_less(b, a) {
		a, b = b, a;
		if sel.gran != .Char {
			// dragging backwards from a word: keep the whole anchor word selected
			b = ifx pos_less(b, sel.anchor_end) then sel.anchor_end else b;
		}
	} else if sel.gran != .Char {
		a = ifx pos_less(sel.anchor, a) then sel.anchor else a;
	}
	if a.order == b.order && a.box == b.box && a.byte == b.byte { return a, b, false; }
	return a, b, true;
}

selection_clear :: () {
	context.ui.selection = .{};
}

has_selection :: () -> bool {
	_, _, ok := selection_range();
	return ok;
}

// Byte range of the selection inside box b, if any.
selection_in_box :: (b: *Box) -> int, int, bool {
	lo, hi, ok := selection_range();
	if !ok { return 0, 0, false; }
	if b.sel_order < lo.order || b.sel_order > hi.order { return 0, 0, false; }
	s0 := ifx b.sel_order == lo.order then lo.byte else 0;
	s1 := ifx b.sel_order == hi.order then hi.byte else len(b.text);
	if s0 >= s1 && !(b.sel_order != hi.order) { return 0, 0, false; }
	return s0, s1, true;
}
#scope_module

collect_selectables :: (b: *Box) {
	if has(b.flags, .Selectable_Text) && b.key != 0 {
		if b.sel_order == 0 { b.sel_order = cast(u64)(len(context.ui.selectables) + 1); }
		append(*context.ui.selectables, b);
	}
	{ c := b.first;
	while c != null { collect_selectables(c);  c = c.next; } }
}

// Text position nearest the mouse among visible selectables. Rows are found
// by vertical extent first, like a browser.
selectable_pos_at :: (p: Vec2, clamp_to_nearest: bool) -> Text_Pos, bool {
	s := context.ui;
	best: *Box;
	best_d := FLOAT32_MAX;
	for b: s.selectables {
		r := visible_rect(b);
		if r.x1 <= r.x0 || r.y1 <= r.y0 { continue; }
		if contains(b.rect, p) {
			best = b;
			break;
		}
		if !clamp_to_nearest { continue; }
		// distance, weighting vertical much more than horizontal
		dy: float32 = ifx p.y < b.rect.y0 then b.rect.y0 - p.y else (ifx p.y > b.rect.y1 then p.y - b.rect.y1 else 0);
		dx: float32 = ifx p.x < b.rect.x0 then b.rect.x0 - p.x else (ifx p.x > b.rect.x1 then p.x - b.rect.x1 else 0);
		d := dy * 1000 + dx;
		if d < best_d {
			best_d = d;
			best = b;
		}
	}
	if best == null { return .{}, false; }
	tl := text_layout_for(best, best.fixed_size.x - best.style.padding.x * 2);
	if tl.origin == Vec2.{} { tl.origin = .{best.rect.x0 + best.style.padding.x, best.rect.y0 + best.style.padding.y}; }
	byte_ := hit_test(tl, p);
	if p.y > best.rect.y1 { byte_ = len(best.text); }
	if p.y < best.rect.y0 { byte_ = 0; }
	return Text_Pos.{order = best.sel_order, box = best.key, byte = byte_}, true;
}

update_selection :: () {
	s := context.ui;
	collect_selectables(s.root);
	sel := *s.selection;
	for * e: s.events {
		if e.consumed { continue; }
		if e.kind == {
		case .Mouse_Down;
			if e.button != .Left { continue; }
			pos, ok := selectable_pos_at(e.pos, false);
			if !ok {
				if s.hot == 0 { selection_clear(); }
				continue;
			}
			b := box_lookup(pos.box);
			if has(e.mods, .Shift) && sel.active {
				sel.focus = pos;
			} else {
				sel.active = true;
				sel.anchor = pos;
				sel.focus = pos;
				sel.anchor_end = pos;
				sel.gran = .Char;
				if e.click_count == 2 {
					a, z := word_range_at(b.text, pos.byte);
					sel.anchor.byte = a;
					sel.focus.byte = z;
					sel.anchor_end = sel.focus;
					sel.gran = .Word;
				} else if e.click_count >= 3 {
					a, z := paragraph_range_at(b.text, pos.byte);
					sel.anchor.byte = a;
					sel.focus.byte = z;
					sel.anchor_end = sel.focus;
					sel.gran = .Paragraph;
				}
			}
			sel.dragging = true;
			s.focus = 0;
			e.consumed = true;
		case .Mouse_Up;
			if e.button == .Left { sel.dragging = false; }
		}
	}
	if sel.dragging && s.mouse != s.mouse_prev {
		{ pos, ok := selectable_pos_at(s.mouse, true);
		if ok {
			{ b := box_lookup(pos.box);
			if b != null {
				if sel.gran == {
				case .Char;
				case .Word;
					a, z := word_range_at(b.text, pos.byte);
					pos.byte = ifx pos_less(pos, sel.anchor) then a else z;
				case .Paragraph;
					a, z := paragraph_range_at(b.text, pos.byte);
					pos.byte = ifx pos_less(pos, sel.anchor) then a else z;
				}
			} }
			sel.focus = pos;
		} }
	}
	if sel.dragging { s.cursor = .IBeam; }
	for b: s.selectables {
		if b.key == s.hot || (s.hot == 0 && mouse_over(b)) { s.cursor = .IBeam; }
	}
}

draw_selection_highlight :: (b: *Box, tl: *Text_Layout) {
	s0, s1, ok := selection_in_box(b);
	if !ok { return; }
	lo, hi, _ := selection_range();
	c := context.ui.selection_color;
	for l, li: tl.lines {
		a := max(s0, l.start);
		z := min(s1, l.end);
		continues := s1 > l.end && li + 1 < len(tl.lines) || (li + 1 == len(tl.lines) && b.sel_order < hi.order);
		if a > z || (a == z && !continues) { continue; }
		x0 := caret_x_in_line(tl, li, a);
		x1 := ifx a == z then x0 else caret_x_in_line(tl, li, z);
		if continues { x1 += tl.size * 0.3; } // show that the newline is selected
		_ = lo;
		r := Rect.{tl.origin.x + x0, tl.origin.y + l.y, tl.origin.x + x1, tl.origin.y + l.y + tl.line_h};
		append(*context.ui.draw, Draw_Cmd.{kind = .Rect, rect = r, colors = .[c, c, c, c]});
	}
}
#scope_export

// Text of the current selection. Boxes not alive this frame are fetched via
// fetch(order) when provided (virtualized lists), else skipped.
selection_text :: (fetch: (order: u64) -> string = null, allocator := temp) -> string {
	lo, hi, ok := selection_range();
	if !ok { return ""; }
	sb := strings.builder_make(allocator);
	first := true;
	for b: context.ui.selectables {
		if b.sel_order < lo.order || b.sel_order > hi.order { continue; }
		s0, s1, in_sel := selection_in_box(b);
		if !in_sel { continue; }
		if !first {
			if b.sel_join != "" { strings.write_string(*sb, b.sel_join); } else { strings.write_byte(*sb, 10); }
		}
		first = false;
		strings.write_string(*sb, sub(b.text, clamp(s0, 0, len(b.text)), clamp(s1, 0, len(b.text))));
	}
	return strings.to_string(sb);
}

