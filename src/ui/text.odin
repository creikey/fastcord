package ui

import "core:strings"
import "core:unicode/utf8"

Text_Line :: struct {
	start, end:             int, // byte range (end excludes the break char)
	glyph_start, glyph_end: int,
	x_shift:                f32, // run-space x of the line's first glyph
	y:                      f32, // top of line, relative to layout origin
	width:                  f32,
}

Text_Layout :: struct {
	text:       string,
	font:       Font,
	size:       f32,
	run:        Shaped_Run, // all spans merged; glyph x is continuous across spans
	spans:      []Span, // nil for plain text
	span_runs:  []Shaped_Run, // backend run per span (glyph.handle indexes into it)
	lines:      []Text_Line,
	width:      f32,
	height:     f32,
	line_h:     f32,
	wrap_width: f32,
	baseline:   f32, // from line top, CSS half-leading
	origin:     Vec2, // screen position of the first line, set when drawn
}

// A run of rich text. Spans with object != 0 are inline objects (custom
// emoji, images) that occupy object.x by object.y and copy as their text.
Span :: struct {
	text:      string,
	font:      Font,
	size:      f32,
	color:     Color, // zero alpha = the box's text color
	bg:        Color, // inline code / mention highlight
	bg_radius: f32,
	underline: bool,
	strike:    bool,
	object:    Vec2,
	id:        u64, // app-defined (link index, mention id) for hit testing
	user:      rawptr,
}

@(private)
is_space_byte :: proc(c: byte) -> bool {return c == ' ' || c == '\t'}

// Shape and wrap text. wrap_width < 0 means no wrapping (only hard newlines).
layout_text :: proc(font: Font, size: f32, text: string, wrap_width: f32, line_height: f32 = 0) -> ^Text_Layout {
	s := ui
	tl := new(Text_Layout, s.frame_alloc)
	tl.text = text
	tl.font = font
	tl.size = size
	tl.run = s.backend.shape(font, size, text)
	s.stats.text_layouts += 1
	s.stats.shape_calls += 1
	s.stats.glyphs += len(tl.run.glyphs)
	tl.line_h = line_height > 0 ? line_height : tl.run.line_h
	tl.baseline = (tl.line_h - (tl.run.ascent + tl.run.descent)) / 2 + tl.run.ascent
	wrap_layout(tl, wrap_width)
	return tl
}

// Shape spans into one paragraph. The text of the layout is the spans' texts concatenated.
layout_rich :: proc(spans: []Span, wrap_width: f32, line_height: f32 = 0) -> ^Text_Layout {
	s := ui
	tl := new(Text_Layout, s.frame_alloc)
	tl.spans = spans
	tl.span_runs = make([]Shaped_Run, len(spans), s.frame_alloc)
	sb := strings.builder_make(s.frame_alloc)
	glyphs := make([dynamic]Shaped_Glyph, 0, 64, s.frame_alloc)
	x: f32
	ascent, descent, lh: f32
	for sp, si in spans {
		base := strings.builder_len(sb)
		strings.write_string(&sb, sp.text)
		if sp.object != {} {
			append(&glyphs, Shaped_Glyph{x = x, advance = sp.object.x, cluster_start = base, cluster_end = base + len(sp.text), handle = 0, span = i32(si)})
			x += sp.object.x
			continue
		}
		run := s.backend.shape(sp.font, sp.size, sp.text)
		s.stats.shape_calls += 1
		tl.span_runs[si] = run
		ascent = max(ascent, run.ascent)
		descent = max(descent, run.descent)
		lh = max(lh, run.line_h)
		for g, gi in run.glyphs {
			append(&glyphs, Shaped_Glyph{x = x + g.x, advance = g.advance, cluster_start = base + g.cluster_start, cluster_end = base + g.cluster_end, handle = u64(gi), span = i32(si)})
		}
		x += run.width
	}
	tl.text = strings.to_string(sb)
	if len(spans) > 0 {
		tl.font = spans[0].font
		tl.size = spans[0].size
	}
	tl.run = Shaped_Run{glyphs = glyphs[:], width = x, ascent = ascent, descent = descent, line_h = lh}
	s.stats.text_layouts += 1
	s.stats.glyphs += len(glyphs)
	tl.line_h = line_height > 0 ? line_height : lh
	tl.baseline = (tl.line_h - (ascent + descent)) / 2 + ascent
	wrap_layout(tl, wrap_width)
	return tl
}

// Index of the span under point p (screen space), or -1.
span_at :: proc(tl: ^Text_Layout, p: Vec2) -> int {
	if tl == nil || tl.spans == nil do return -1
	local := p - tl.origin
	if local.y < 0 || local.y >= tl.height do return -1
	li := clamp(int(local.y / tl.line_h), 0, len(tl.lines) - 1)
	l := tl.lines[li]
	for gi in l.glyph_start ..< l.glyph_end {
		g := tl.run.glyphs[gi]
		gx := g.x - l.x_shift
		if local.x >= gx && local.x < gx + g.advance do return int(g.span)
	}
	return -1
}

@(private)
wrap_layout :: proc(tl: ^Text_Layout, wrap_width: f32) {
	s := ui
	text := tl.text
	tl.wrap_width = wrap_width
	lines := make([dynamic]Text_Line, 0, 4, s.frame_alloc)
	g := tl.run.glyphs

	line_start_g := 0
	line_start_b := 0
	last_break_g := -1 // glyph index after which we can break
	i := 0
	for i < len(g) {
		gl := g[i]
		c := gl.cluster_start < len(text) ? text[gl.cluster_start] : 0
		if c == '\n' {
			append(&lines, make_line(tl, line_start_g, i, line_start_b, gl.cluster_start))
			line_start_g = i + 1
			line_start_b = gl.cluster_end
			last_break_g = -1
			i += 1
			continue
		}
		if wrap_width >= 0 && i > line_start_g {
			x0 := g[line_start_g].x
			if gl.x + gl.advance - x0 > wrap_width && !is_space_byte(c) {
				brk := last_break_g >= 0 ? last_break_g + 1 : i
				end_b := g[brk].cluster_start
				// trailing spaces stay on the line but don't count toward width
				append(&lines, make_line(tl, line_start_g, brk, line_start_b, end_b))
				line_start_g = brk
				line_start_b = end_b
				last_break_g = -1
				i = brk
				continue
			}
		}
		if is_space_byte(c) do last_break_g = i
		i += 1
	}
	append(&lines, make_line(tl, line_start_g, len(g), line_start_b, len(text)))
	tl.lines = lines[:]
	for &l, li in tl.lines {
		l.y = f32(li) * tl.line_h
		tl.width = max(tl.width, l.width)
	}
	tl.height = f32(len(tl.lines)) * tl.line_h
}

@(private)
make_line :: proc(tl: ^Text_Layout, g0, g1, b0, b1: int) -> Text_Line {
	g := tl.run.glyphs
	l := Text_Line{start = b0, end = b1, glyph_start = g0, glyph_end = g1}
	if g0 < len(g) do l.x_shift = g[g0].x
	// width excludes trailing whitespace
	last := g1 - 1
	for last >= g0 && g[last].cluster_start < len(tl.text) && is_space_byte(tl.text[g[last].cluster_start]) do last -= 1
	if last >= g0 do l.width = g[last].x + g[last].advance - l.x_shift
	return l
}

// Which line holds byte offset `pos`. A position at a wrap point belongs to
// the next line, except at the very end of text.
line_of :: proc(tl: ^Text_Layout, pos: int) -> int {
	for l, i in tl.lines {
		if pos < l.end || (pos == l.end && i == len(tl.lines) - 1) do return i
		if i + 1 < len(tl.lines) && pos < tl.lines[i + 1].start do return i // inside a break char
	}
	return max(0, len(tl.lines) - 1)
}

// x of the caret before byte `pos`, relative to the layout origin.
caret_x :: proc(tl: ^Text_Layout, pos: int) -> f32 {
	if len(tl.lines) == 0 do return 0
	return caret_x_in_line(tl, line_of(tl, pos), pos)
}

// Like caret_x, but on a given line (pos == line end is that line's end, not the next line's start).
caret_x_in_line :: proc(tl: ^Text_Layout, li: int, pos: int) -> f32 {
	if len(tl.lines) == 0 do return 0
	l := tl.lines[li]
	g := tl.run.glyphs
	for gi in l.glyph_start ..< l.glyph_end {
		gl := g[gi]
		if pos <= gl.cluster_start do return gl.x - l.x_shift
		if pos < gl.cluster_end {
			// inside a multi-codepoint cluster (ligature): interpolate by bytes
			t := f32(pos - gl.cluster_start) / f32(gl.cluster_end - gl.cluster_start)
			return gl.x + gl.advance * t - l.x_shift
		}
	}
	if l.glyph_end > l.glyph_start {
		last := g[l.glyph_end - 1]
		return last.x + last.advance - l.x_shift
	}
	return 0
}

caret_pos :: proc(tl: ^Text_Layout, pos: int) -> Vec2 {
	if len(tl.lines) == 0 do return tl.origin
	li := line_of(tl, pos)
	return tl.origin + {caret_x(tl, pos), tl.lines[li].y}
}

// Byte offset nearest to point p (screen space).
hit_test :: proc(tl: ^Text_Layout, p: Vec2) -> int {
	if len(tl.lines) == 0 do return 0
	local := p - tl.origin
	li := int(local.y / tl.line_h)
	li = clamp(li, 0, len(tl.lines) - 1)
	if local.y < 0 do return 0
	if local.y >= tl.height do return len(tl.text)
	return hit_test_line(tl, li, local.x)
}

hit_test_line :: proc(tl: ^Text_Layout, li: int, x: f32) -> int {
	l := tl.lines[li]
	g := tl.run.glyphs
	for gi in l.glyph_start ..< l.glyph_end {
		gl := g[gi]
		gx := gl.x - l.x_shift
		if x < gx + gl.advance / 2 do return gl.cluster_start
	}
	return l.end
}

//////////////////////////////////////////////////////////////////////////////
// grapheme / word navigation shared by selection and the text editor

next_grapheme :: proc(s: string, pos: int) -> int {
	if pos >= len(s) do return len(s)
	it := utf8.decode_grapheme_iterator_make(s[pos:])
	if txt, _, ok := utf8.decode_grapheme_iterate(&it); ok do return pos + len(txt)
	return len(s)
}

prev_grapheme :: proc(s: string, pos: int) -> int {
	if pos <= 0 do return 0
	// Scan from the start of the line for correctness with ZWJ/combining sequences.
	line_start := strings.last_index_byte(s[:pos], '\n') + 1
	if line_start == pos do return pos - 1
	prev := line_start
	it := utf8.decode_grapheme_iterator_make(s[line_start:])
	for txt, _ in utf8.decode_grapheme_iterate(&it) {
		end := prev + len(txt)
		if end >= pos do return prev
		prev = end
	}
	return prev
}

@(private)
is_word_byte :: proc(s: string, i: int) -> bool {
	c := s[i]
	if c >= 0x80 do return true // treat non-ASCII (letters, emoji) as word chars
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '\''
}

// Option+Right semantics: skip non-word chars, then the word.
next_word :: proc(s: string, pos: int) -> int {
	i := pos
	for i < len(s) && !is_word_byte(s, i) do i += 1
	for i < len(s) && is_word_byte(s, i) do i += 1
	return i
}

prev_word :: proc(s: string, pos: int) -> int {
	i := pos
	for i > 0 && !is_word_byte(s, i - 1) do i -= 1
	for i > 0 && is_word_byte(s, i - 1) do i -= 1
	return i
}

// Range a double-click at pos selects: the word, a run of spaces, or one punctuation char.
word_range_at :: proc(s: string, pos: int) -> (int, int) {
	if len(s) == 0 do return 0, 0
	p := clamp(pos, 0, len(s) - 1)
	if pos == len(s) && p > 0 do p = len(s) - 1
	if is_word_byte(s, p) {
		a, b := p, p
		for a > 0 && is_word_byte(s, a - 1) do a -= 1
		for b < len(s) && is_word_byte(s, b) do b += 1
		return a, b
	}
	if is_space_byte(s[p]) {
		a, b := p, p
		for a > 0 && is_space_byte(s[a - 1]) do a -= 1
		for b < len(s) && is_space_byte(s[b]) do b += 1
		return a, b
	}
	return p, next_grapheme(s, p)
}

// The hard-newline-delimited paragraph containing pos (triple click).
paragraph_range_at :: proc(s: string, pos: int) -> (int, int) {
	a := strings.last_index_byte(s[:clamp(pos, 0, len(s))], '\n') + 1
	b := strings.index_byte(s[a:], '\n')
	return a, b < 0 ? len(s) : a + b
}

//////////////////////////////////////////////////////////////////////////////
// Global selection across Selectable_Text boxes (e.g. dragging across many
// chat messages). Boxes are ordered by box.sel_order, which the app sets to
// something stable (message id * N + field); endpoints survive the box
// scrolling out of view.

Text_Pos :: struct {
	order: u64,
	box:   Key,
	byte:  int,
}

Granularity :: enum u8 {
	Char,
	Word,
	Paragraph,
}

Selection :: struct {
	anchor, focus:          Text_Pos,
	anchor_end:             Text_Pos, // for word/paragraph drags: the far end of the anchor unit
	active:                 bool,
	dragging:               bool,
	gran:                   Granularity,
}

pos_less :: proc(a, b: Text_Pos) -> bool {
	if a.order != b.order do return a.order < b.order
	return a.byte < b.byte
}

selection_range :: proc() -> (lo, hi: Text_Pos, ok: bool) {
	sel := &ui.selection
	if !sel.active do return {}, {}, false
	a, b := sel.anchor, sel.focus
	if pos_less(b, a) {
		a, b = b, a
		if sel.gran != .Char {
			// dragging backwards from a word: keep the whole anchor word selected
			b = pos_less(b, sel.anchor_end) ? sel.anchor_end : b
		}
	} else if sel.gran != .Char {
		a = pos_less(sel.anchor, a) ? sel.anchor : a
	}
	if a == b do return a, b, false
	return a, b, true
}

selection_clear :: proc() {
	ui.selection = {}
}

has_selection :: proc() -> bool {
	_, _, ok := selection_range()
	return ok
}

// Byte range of the selection inside box b, if any.
selection_in_box :: proc(b: ^Box) -> (int, int, bool) {
	lo, hi, ok := selection_range()
	if !ok do return 0, 0, false
	if b.sel_order < lo.order || b.sel_order > hi.order do return 0, 0, false
	s0 := b.sel_order == lo.order ? lo.byte : 0
	s1 := b.sel_order == hi.order ? hi.byte : len(b.text)
	if s0 >= s1 && !(b.sel_order != hi.order) do return 0, 0, false
	return s0, s1, true
}

@(private)
collect_selectables :: proc(b: ^Box) {
	if .Selectable_Text in b.flags && b.key != 0 {
		if b.sel_order == 0 do b.sel_order = u64(len(ui.selectables) + 1)
		append(&ui.selectables, b)
	}
	for c := b.first; c != nil; c = c.next do collect_selectables(c)
}

// Text position nearest the mouse among visible selectables. Rows are found
// by vertical extent first, like a browser.
@(private)
selectable_pos_at :: proc(p: Vec2, clamp_to_nearest: bool) -> (Text_Pos, bool) {
	s := ui
	best: ^Box
	best_d := max(f32)
	for b in s.selectables {
		r := visible_rect(b)
		if r.x1 <= r.x0 || r.y1 <= r.y0 do continue
		if contains(b.rect, p) {
			best = b
			break
		}
		if !clamp_to_nearest do continue
		// distance, weighting vertical much more than horizontal
		dy: f32 = p.y < b.rect.y0 ? b.rect.y0 - p.y : (p.y > b.rect.y1 ? p.y - b.rect.y1 : 0)
		dx: f32 = p.x < b.rect.x0 ? b.rect.x0 - p.x : (p.x > b.rect.x1 ? p.x - b.rect.x1 : 0)
		d := dy * 1000 + dx
		if d < best_d {
			best_d = d
			best = b
		}
	}
	if best == nil do return {}, false
	tl := text_layout_for(best, best.fixed_size.x - best.style.padding.x * 2)
	if tl.origin == {} do tl.origin = {best.rect.x0 + best.style.padding.x, best.rect.y0 + best.style.padding.y}
	byte := hit_test(tl, p)
	if p.y > best.rect.y1 do byte = len(best.text)
	if p.y < best.rect.y0 do byte = 0
	return Text_Pos{order = best.sel_order, box = best.key, byte = byte}, true
}

@(private)
update_selection :: proc() {
	s := ui
	collect_selectables(s.root)
	sel := &s.selection
	for &e in s.events {
		if e.consumed do continue
		#partial switch e.kind {
		case .Mouse_Down:
			if e.button != .Left do continue
			pos, ok := selectable_pos_at(e.pos, false)
			if !ok {
				if s.hot == 0 do selection_clear()
				continue
			}
			b := box_lookup(pos.box)
			if .Shift in e.mods && sel.active {
				sel.focus = pos
			} else {
				sel.active = true
				sel.anchor = pos
				sel.focus = pos
				sel.anchor_end = pos
				sel.gran = .Char
				switch {
				case e.click_count == 2:
					a, z := word_range_at(b.text, pos.byte)
					sel.anchor.byte = a
					sel.focus.byte = z
					sel.anchor_end = sel.focus
					sel.gran = .Word
				case e.click_count >= 3:
					a, z := paragraph_range_at(b.text, pos.byte)
					sel.anchor.byte = a
					sel.focus.byte = z
					sel.anchor_end = sel.focus
					sel.gran = .Paragraph
				}
			}
			sel.dragging = true
			s.focus = 0
			e.consumed = true
		case .Mouse_Up:
			if e.button == .Left do sel.dragging = false
		}
	}
	if sel.dragging && s.mouse != s.mouse_prev {
		if pos, ok := selectable_pos_at(s.mouse, true); ok {
			if b := box_lookup(pos.box); b != nil {
				switch sel.gran {
				case .Char:
				case .Word:
					a, z := word_range_at(b.text, pos.byte)
					pos.byte = pos_less(pos, sel.anchor) ? a : z
				case .Paragraph:
					a, z := paragraph_range_at(b.text, pos.byte)
					pos.byte = pos_less(pos, sel.anchor) ? a : z
				}
			}
			sel.focus = pos
		}
	}
	if sel.dragging do s.cursor = .IBeam
	for b in s.selectables {
		if b.key == s.hot || (s.hot == 0 && mouse_over(b)) do s.cursor = .IBeam
	}
}

@(private)
draw_selection_highlight :: proc(b: ^Box, tl: ^Text_Layout) {
	s0, s1, ok := selection_in_box(b)
	if !ok do return
	lo, hi, _ := selection_range()
	c := ui.selection_color
	for l, li in tl.lines {
		a := max(s0, l.start)
		z := min(s1, l.end)
		continues := s1 > l.end && li + 1 < len(tl.lines) || (li + 1 == len(tl.lines) && b.sel_order < hi.order)
		if a > z || (a == z && !continues) do continue
		x0 := caret_x_in_line(tl, li, a)
		x1 := a == z ? x0 : caret_x_in_line(tl, li, z)
		if continues do x1 += tl.size * 0.3 // show that the newline is selected
		_ = lo
		r := Rect{tl.origin.x + x0, tl.origin.y + l.y, tl.origin.x + x1, tl.origin.y + l.y + tl.line_h}
		append(&ui.draw, Draw_Cmd{kind = .Rect, rect = r, colors = {c, c, c, c}})
	}
}

// Text of the current selection. Boxes not alive this frame are fetched via
// fetch(order) when provided (virtualized lists), else skipped.
selection_text :: proc(fetch: proc(order: u64) -> string = nil, allocator := context.temp_allocator) -> string {
	lo, hi, ok := selection_range()
	if !ok do return ""
	sb := strings.builder_make(allocator)
	first := true
	for b in ui.selectables {
		if b.sel_order < lo.order || b.sel_order > hi.order do continue
		s0, s1, in_sel := selection_in_box(b)
		if !in_sel do continue
		if !first {
			if b.sel_join != "" do strings.write_string(&sb, b.sel_join)
			else do strings.write_byte(&sb, '\n')
		}
		first = false
		strings.write_string(&sb, b.text[clamp(s0, 0, len(b.text)):clamp(s1, 0, len(b.text))])
	}
	_ = fetch
	return strings.to_string(sb)
}
