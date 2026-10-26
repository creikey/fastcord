package ui

import "core:strings"

// Editor is the state of an editable text field. It is plain data: the UI
// widget feeds it events plus the current Text_Layout (for vertical motion
// and mouse hits), and tests can drive it directly.
Editor :: struct {
	buf:        [dynamic]byte,
	caret:      int,
	mark:       int, // selection is [min(caret,mark), max(caret,mark))
	pref_x:     f32, // remembered x for Up/Down
	has_pref_x: bool,
	undo:       [dynamic]Edit_Snapshot,
	redo:       [dynamic]Edit_Snapshot,
	coalesce:   Edit_Kind,
	drag_gran:  Granularity,
	drag_a:     int, // anchor unit [drag_a, drag_b) for word/line drags
	drag_b:     int,
}

Edit_Snapshot :: struct {
	text:  string,
	caret: int,
	mark:  int,
}

Edit_Kind :: enum u8 {
	None,
	Typing,
	Deleting,
	Other,
}

Edit_Result :: enum u8 {
	None,
	Changed,
	Moved,
	Submit, // Enter without shift
	Escape,
}

editor_text :: proc(e: ^Editor) -> string {return string(e.buf[:])}

editor_set_text :: proc(e: ^Editor, s: string) {
	clear(&e.buf)
	append(&e.buf, s)
	e.caret = len(e.buf)
	e.mark = e.caret
	e.has_pref_x = false
}

editor_destroy :: proc(e: ^Editor) {
	delete(e.buf)
	for s in e.undo do delete(s.text)
	for s in e.redo do delete(s.text)
	delete(e.undo)
	delete(e.redo)
}

editor_sel :: proc(e: ^Editor) -> (int, int) {return min(e.caret, e.mark), max(e.caret, e.mark)}
editor_has_sel :: proc(e: ^Editor) -> bool {return e.caret != e.mark}

editor_selected_text :: proc(e: ^Editor) -> string {
	a, b := editor_sel(e)
	return string(e.buf[a:b])
}

@(private)
snapshot :: proc(e: ^Editor, kind: Edit_Kind) {
	if kind != .Other && kind == e.coalesce && len(e.undo) > 0 do return
	e.coalesce = kind
	append(&e.undo, Edit_Snapshot{strings.clone(editor_text(e)), e.caret, e.mark})
	if len(e.undo) > 200 {
		delete(e.undo[0].text)
		ordered_remove(&e.undo, 0)
	}
	for s in e.redo do delete(s.text)
	clear(&e.redo)
}

@(private)
restore :: proc(e: ^Editor, from, to: ^[dynamic]Edit_Snapshot) -> bool {
	if len(from) == 0 do return false
	append(to, Edit_Snapshot{strings.clone(editor_text(e)), e.caret, e.mark})
	s := pop(from)
	clear(&e.buf)
	append(&e.buf, s.text)
	e.caret = s.caret
	e.mark = s.mark
	delete(s.text)
	e.coalesce = .None
	return true
}

editor_undo :: proc(e: ^Editor) -> bool {return restore(e, &e.undo, &e.redo)}
editor_redo :: proc(e: ^Editor) -> bool {return restore(e, &e.redo, &e.undo)}

@(private)
replace_range :: proc(e: ^Editor, a, b: int, s: string) {
	remove_range(&e.buf, a, b)
	inject_at(&e.buf, a, s)
	e.caret = a + len(s)
	e.mark = e.caret
	e.has_pref_x = false
}

// Insert (replacing the selection), as typing.
editor_insert :: proc(e: ^Editor, s: string, kind := Edit_Kind.Typing) {
	k := kind
	if editor_has_sel(e) || strings.contains_any(s, " \n") do k = .Other
	snapshot(e, k)
	a, b := editor_sel(e)
	replace_range(e, a, b, s)
	if strings.contains_any(s, " \n") do e.coalesce = .None
}

@(private)
delete_to :: proc(e: ^Editor, target: int) {
	if editor_has_sel(e) {
		snapshot(e, .Other)
		a, b := editor_sel(e)
		replace_range(e, a, b, "")
		return
	}
	if target == e.caret do return
	snapshot(e, .Deleting)
	replace_range(e, min(target, e.caret), max(target, e.caret), "")
}

@(private)
line_start_of :: proc(tl: ^Text_Layout, s: string, pos: int) -> int {
	if tl != nil && len(tl.lines) > 0 do return tl.lines[line_of(tl, pos)].start
	return strings.last_index_byte(s[:pos], '\n') + 1
}

@(private)
line_end_of :: proc(tl: ^Text_Layout, s: string, pos: int) -> int {
	if tl != nil && len(tl.lines) > 0 do return tl.lines[line_of(tl, pos)].end
	i := strings.index_byte(s[pos:], '\n')
	return i < 0 ? len(s) : pos + i
}

@(private)
vertical :: proc(e: ^Editor, tl: ^Text_Layout, dir: int) -> int {
	s := editor_text(e)
	if tl == nil || len(tl.lines) == 0 do return dir < 0 ? 0 : len(s)
	li := line_of(tl, e.caret)
	if !e.has_pref_x {
		e.pref_x = caret_x(tl, e.caret)
		e.has_pref_x = true
	}
	nl := li + dir
	if nl < 0 do return 0
	if nl >= len(tl.lines) do return len(s)
	return hit_test_line(tl, nl, e.pref_x)
}

@(private)
move :: proc(e: ^Editor, target: int, extend: bool, keep_pref_x := false) {
	e.caret = clamp(target, 0, len(e.buf))
	if !extend do e.mark = e.caret
	if !keep_pref_x do e.has_pref_x = false
	e.coalesce = .None
}

// Handle a key/text event. tl is the field's current layout (may be nil).
// clipboard_set/get let tests substitute the system clipboard.
editor_event :: proc(
	e: ^Editor,
	ev: Input_Event,
	tl: ^Text_Layout,
	clip_get: proc() -> string,
	clip_set: proc(s: string),
	multiline := true,
) -> Edit_Result {
	s := editor_text(e)
	if ev.kind == .Text {
		if ev.text == "" do return .None
		editor_insert(e, ev.text)
		return .Changed
	}
	if ev.kind != .Key_Down do return .None
	shift := .Shift in ev.mods
	cmd := .Cmd in ev.mods
	alt := .Alt in ev.mods
	ctrl := .Ctrl in ev.mods
	a, b := editor_sel(e)

	#partial switch ev.key {
	case .Left:
		switch {
		case cmd:
			move(e, line_start_of(tl, s, e.caret), shift)
		case alt:
			move(e, prev_word(s, e.caret), shift)
		case editor_has_sel(e) && !shift:
			move(e, a, false)
		case:
			move(e, prev_grapheme(s, e.caret), shift)
		}
		return .Moved
	case .Right:
		switch {
		case cmd:
			move(e, line_end_of(tl, s, e.caret), shift)
		case alt:
			move(e, next_word(s, e.caret), shift)
		case editor_has_sel(e) && !shift:
			move(e, b, false)
		case:
			move(e, next_grapheme(s, e.caret), shift)
		}
		return .Moved
	case .Up:
		if cmd do move(e, 0, shift)
		else do move(e, vertical(e, tl, -1), shift, true)
		return .Moved
	case .Down:
		if cmd do move(e, len(s), shift)
		else do move(e, vertical(e, tl, 1), shift, true)
		return .Moved
	case .Home:
		move(e, 0, shift)
		return .Moved
	case .End:
		move(e, len(s), shift)
		return .Moved
	case .Backspace:
		switch {
		case editor_has_sel(e):
			delete_to(e, e.caret)
		case cmd:
			delete_to(e, line_start_of(tl, s, e.caret))
		case alt:
			delete_to(e, prev_word(s, e.caret))
		case:
			// Backspace removes one code point of a cluster on macOS only for
			// some scripts; deleting the whole grapheme is the safe default.
			delete_to(e, prev_grapheme(s, e.caret))
		}
		return .Changed
	case .Delete:
		switch {
		case editor_has_sel(e):
			delete_to(e, e.caret)
		case cmd:
			delete_to(e, line_end_of(tl, s, e.caret))
		case alt:
			delete_to(e, next_word(s, e.caret))
		case:
			delete_to(e, next_grapheme(s, e.caret))
		}
		return .Changed
	case .Enter:
		if shift && multiline {
			editor_insert(e, "\n")
			return .Changed
		}
		return .Submit
	case .Escape:
		return .Escape
	case .A:
		if cmd {
			e.mark = 0
			e.caret = len(s)
			return .Moved
		}
		if ctrl {
			move(e, line_start_of(tl, s, e.caret), shift)
			return .Moved
		}
	case .C:
		if cmd && editor_has_sel(e) {
			clip_set(editor_selected_text(e))
			return .None
		}
	case .X:
		if cmd && editor_has_sel(e) {
			clip_set(editor_selected_text(e))
			delete_to(e, e.caret)
			return .Changed
		}
	case .V:
		if cmd {
			t := clip_get()
			if !multiline do t, _ = strings.replace_all(t, "\n", " ", context.temp_allocator)
			if t != "" {
				snapshot(e, .Other)
				replace_range(e, a, b, t)
				e.coalesce = .None
				return .Changed
			}
		}
	case .Z:
		if cmd {
			if shift do return editor_redo(e) ? .Changed : .None
			return editor_undo(e) ? .Changed : .None
		}
	case .K:
		if ctrl {
			delete_to(e, line_end_of(tl, s, e.caret))
			return .Changed
		}
	}
	return .None
}

// Mouse down at screen point p with OS click count.
editor_mouse_down :: proc(e: ^Editor, tl: ^Text_Layout, p: Vec2, click_count: int, shift: bool) {
	s := editor_text(e)
	pos := tl != nil ? hit_test(tl, p) : len(s)
	e.has_pref_x = false
	e.coalesce = .None
	if shift {
		e.caret = pos
		e.drag_gran = .Char
		return
	}
	switch {
	case click_count == 2:
		e.drag_a, e.drag_b = word_range_at(s, pos)
		e.drag_gran = .Word
	case click_count >= 3:
		e.drag_a, e.drag_b = paragraph_range_at(s, pos)
		e.drag_gran = .Paragraph
	case:
		e.drag_a, e.drag_b = pos, pos
		e.drag_gran = .Char
	}
	e.mark = e.drag_a
	e.caret = e.drag_b
}

editor_mouse_drag :: proc(e: ^Editor, tl: ^Text_Layout, p: Vec2) {
	if tl == nil do return
	s := editor_text(e)
	pos := hit_test(tl, p)
	switch e.drag_gran {
	case .Char:
		e.caret = pos
	case .Word, .Paragraph:
		a, b: int
		if e.drag_gran == .Word do a, b = word_range_at(s, pos)
		else do a, b = paragraph_range_at(s, pos)
		if pos < e.drag_a {
			e.mark = e.drag_b
			e.caret = a
		} else {
			e.mark = e.drag_a
			e.caret = max(b, e.drag_b)
		}
	}
}
