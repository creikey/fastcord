package ui

import "core:strings"
import "core:testing"
import "core:unicode/utf8"

// Monospace fake backend: every grapheme is 10pt wide, lines are 20pt.
@(private = "file")
fake_shape :: proc(font: Font, size: f32, text: string) -> Shaped_Run {
	glyphs := make([dynamic]Shaped_Glyph, context.temp_allocator)
	x: f32
	it := utf8.decode_grapheme_iterator_make(text)
	off := 0
	for g, _ in utf8.decode_grapheme_iterate(&it) {
		append(&glyphs, Shaped_Glyph{x = x, advance = 10, cluster_start = off, cluster_end = off + len(g)})
		x += 10
		off += len(g)
	}
	return Shaped_Run{glyphs = glyphs[:], width = x, ascent = 15, descent = 5, line_h = 20}
}

@(private = "file")
setup :: proc() -> ^State {
	s := new(State)
	init(s, Backend{shape = fake_shape})
	return s
}

@(private = "file")
teardown :: proc() {
	s := ui
	shutdown(s)
	free(s)
}

@(private = "file")
frame :: proc(events: []Input_Event, build: proc()) -> []Draw_Cmd {
	begin({800, 600}, 1.0 / 60, 0, events)
	build()
	return end()
}

@(test)
test_layout_row_fill :: proc(t: ^testing.T) {
	setup()
	defer teardown()
	frame(nil, proc() {
		row := box("row")
		row.layout_axis = .X
		row.semantic_size = {.X = pct(1), .Y = px(50)}
		if parent(row) {
			a := box("a")
			a.semantic_size = {.X = px(72), .Y = pct(1)}
			b := box("b")
			b.semantic_size = {.X = fill(), .Y = pct(1)}
			c := box("c")
			c.semantic_size = {.X = px(240), .Y = pct(1)}
		}
	})
	b := box_lookup(key_from_string("b", key_from_string("row", Key(1))))
	testing.expect(t, b != nil)
	testing.expect_value(t, b.rect.x0, 72)
	testing.expect_value(t, b.rect.x1, 800 - 240)
	testing.expect_value(t, b.rect.y1, 50)
}

@(test)
test_wrap :: proc(t: ^testing.T) {
	setup()
	defer teardown()
	begin({800, 600}, 0.016, 0, nil)
	tl := layout_text(0, 16, "hello world foo", 60)
	// "hello " fits (50 + trailing space), "world " fits, "foo"
	testing.expect_value(t, len(tl.lines), 3)
	testing.expect_value(t, tl.lines[1].start, 6)
	testing.expect_value(t, tl.text[tl.lines[2].start:tl.lines[2].end], "foo")
	testing.expect_value(t, line_of(tl, 6), 1)
	testing.expect_value(t, caret_x(tl, 8), 20)
	// hard newline
	tl2 := layout_text(0, 16, "ab\ncd", -1)
	testing.expect_value(t, len(tl2.lines), 2)
	testing.expect_value(t, tl2.lines[1].start, 3)
	tl2.origin = {0, 0}
	testing.expect_value(t, hit_test(tl2, {14, 25}), 4)
	// a word longer than the line breaks by character
	tl3 := layout_text(0, 16, "abcdefghij", 35)
	testing.expect_value(t, len(tl3.lines), 4)
	end()
}

@(test)
test_graphemes :: proc(t: ^testing.T) {
	s := "a👨‍👩‍👧b"
	n := next_grapheme(s, 1)
	testing.expect_value(t, s[1:n], "👨‍👩‍👧")
	testing.expect_value(t, prev_grapheme(s, n), 1)
	a, b := word_range_at("foo bar, baz", 5)
	testing.expect_value(t, a, 4)
	testing.expect_value(t, b, 7)
	testing.expect_value(t, next_word("foo bar", 3), 7)
	testing.expect_value(t, prev_word("foo bar", 7), 4)
}

@(private = "file")
clip_buf: string

@(private = "file")
cget :: proc() -> string {return clip_buf}
@(private = "file")
cset :: proc(s: string) {clip_buf = strings.clone(s, context.temp_allocator)}

@(private = "file")
key :: proc(k: Key_Code, mods: Mods = {}) -> Input_Event {return {kind = .Key_Down, key = k, mods = mods}}
@(private = "file")
txt :: proc(s: string) -> Input_Event {return {kind = .Text, text = s}}

// The editor's word-wise and shortcut modifiers per platform.
@(private = "file")
WORD :: Mod.Alt when ODIN_OS == .Darwin else Mod.Ctrl
@(private = "file")
SHORT :: Mod.Cmd when ODIN_OS == .Darwin else Mod.Ctrl

@(test)
test_editor :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)
	for c in ([]string{"h", "e", "l", "l", "o", " ", "w", "o", "r", "l", "d"}) do editor_event(&e, txt(c), nil, cget, cset)
	testing.expect_value(t, editor_text(&e), "hello world")
	editor_event(&e, key(.Backspace, {WORD}), nil, cget, cset)
	testing.expect_value(t, editor_text(&e), "hello ")
	editor_event(&e, key(.Z, {SHORT}), nil, cget, cset)
	testing.expect_value(t, editor_text(&e), "hello world")
	editor_event(&e, key(.Left, {WORD, .Shift}), nil, cget, cset)
	testing.expect_value(t, editor_selected_text(&e), "world")
	editor_event(&e, key(.X, {SHORT}), nil, cget, cset)
	testing.expect_value(t, clip_buf, "world")
	testing.expect_value(t, editor_text(&e), "hello ")
	editor_event(&e, key(.Home), nil, cget, cset)
	editor_event(&e, key(.V, {SHORT}), nil, cget, cset)
	testing.expect_value(t, editor_text(&e), "worldhello ")
	testing.expect_value(t, editor_event(&e, key(.Enter), nil, cget, cset), Edit_Result.Submit)
	editor_event(&e, key(.Enter, {.Shift}), nil, cget, cset)
	testing.expect_value(t, editor_text(&e), "world\nhello ")
	// typing over a selection then undo restores it in one step
	editor_event(&e, key(.A, {SHORT}), nil, cget, cset)
	editor_event(&e, txt("x"), nil, cget, cset)
	testing.expect_value(t, editor_text(&e), "x")
	editor_event(&e, key(.Z, {SHORT}), nil, cget, cset)
	testing.expect_value(t, editor_text(&e), "world\nhello ")
	editor_event(&e, key(.Z, {SHORT, .Shift}), nil, cget, cset)
	testing.expect_value(t, editor_text(&e), "x")
}

@(test)
test_editor_vertical :: proc(t: ^testing.T) {
	setup()
	defer teardown()
	begin({800, 600}, 0.016, 0, nil)
	e: Editor
	defer editor_destroy(&e)
	editor_set_text(&e, "abcdef\nab\nabcdef")
	tl := layout_text(0, 16, editor_text(&e), -1)
	e.caret = 5
	e.mark = 5
	editor_event(&e, key(.Down), tl, cget, cset)
	testing.expect_value(t, e.caret, 9) // clamped to end of "ab"
	editor_event(&e, key(.Down), tl, cget, cset)
	testing.expect_value(t, e.caret, 15) // remembered x restores column 5
	editor_event(&e, key(.Down), tl, cget, cset)
	testing.expect_value(t, e.caret, len(editor_text(&e)))
	end()
}

@(private = "file")
build_messages :: proc() {
	list := box("list")
	list.semantic_size = {.X = pct(1), .Y = pct(1)}
	if parent(list) {
		texts := []string{"first message", "second one here", "third"}
		for m, i in texts {
			b := box(m, {.Draw_Text, .Selectable_Text})
			b.semantic_size = {.X = pct(1), .Y = text_size()}
			b.sel_order = u64(i + 1) * 10
		}
	}
}

@(test)
test_cross_box_selection :: proc(t: ^testing.T) {
	setup()
	defer teardown()
	frame(nil, build_messages) // lay out once so hit testing has rects
	frame(nil, build_messages)
	// drag from inside "first" (x=60 -> byte 6) to the middle of "third" line
	frame({{kind = .Mouse_Down, pos = {60, 5}, button = .Left, click_count = 1}}, build_messages)
	frame({{kind = .Mouse_Move, pos = {25, 45}}}, build_messages)
	frame({{kind = .Mouse_Up, pos = {25, 45}, button = .Left}}, build_messages)
	got := selection_text()
	testing.expect_value(t, got, "message\nsecond one here\nthi")
	// double click selects a word
	frame({{kind = .Mouse_Down, pos = {75, 25}, button = .Left, click_count = 2}}, build_messages)
	frame({{kind = .Mouse_Up, pos = {75, 25}, button = .Left}}, build_messages)
	testing.expect_value(t, selection_text(), "one")
	// clicking empty space clears it
	frame({{kind = .Mouse_Down, pos = {400, 500}, button = .Left, click_count = 1}}, build_messages)
	testing.expect_value(t, has_selection(), false)
}

@(test)
test_click_signal :: proc(t: ^testing.T) {
	setup()
	defer teardown()
	clicked := false
	build := proc() {
		b := box("btn", {.Clickable, .Draw_Background})
		b.semantic_size = {.X = px(100), .Y = px(40)}
		sig := signal(b)
		if sig.clicked do (cast(^bool)context.user_ptr)^ = true
	}
	context.user_ptr = &clicked
	frame(nil, build)
	frame({{kind = .Mouse_Move, pos = {50, 20}}}, build)
	frame({{kind = .Mouse_Down, pos = {50, 20}, button = .Left, click_count = 1}}, build)
	testing.expect_value(t, clicked, false)
	frame({{kind = .Mouse_Up, pos = {50, 20}, button = .Left}}, build)
	testing.expect_value(t, clicked, true)
	// press inside, release outside: no click
	clicked = false
	frame({{kind = .Mouse_Down, pos = {50, 20}, button = .Left, click_count = 1}}, build)
	frame({{kind = .Mouse_Up, pos = {300, 300}, button = .Left}}, build)
	testing.expect_value(t, clicked, false)
}
