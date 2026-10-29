// Editor is the state of an editable text field. It is plain data: the UI
// widget feeds it events plus the current Text_Layout (for vertical motion
// and mouse hits), and tests can drive it directly.
Editor :: struct {
	buf: [..]u8;
	caret: int;
	mark: int; // selection is [min(caret,mark), max(caret,mark))
	pref_x: float32; // remembered x for Up/Down
	has_pref_x: bool;
	undo: [..]Edit_Snapshot;
	redo: [..]Edit_Snapshot;
	coalesce: Edit_Kind;
	drag_gran: Granularity;
	drag_a: int; // anchor unit [drag_a, drag_b) for word/line drags
	drag_b: int;
}

Edit_Snapshot :: struct {
	text: string;
	caret: int;
	mark: int;
}

Edit_Kind :: enum u8 {
	None;
	Typing;
	Deleting;
	Other;
}

Edit_Result :: enum u8 {
	None;
	Changed;
	Moved;
	Submit; // Enter without shift
	Escape;
}

editor_text :: (e: *Editor) -> string { return .{e.buf.count, e.buf.data}; }

editor_set_text :: (e: *Editor, s: string) {
	e.buf.count = 0;
	array_add(*e.buf, ..cast([]u8) s);
	e.caret = e.buf.count;
	e.mark = e.caret;
	e.has_pref_x = false;
}

editor_destroy :: (e: *Editor) {
	array_free(e.buf);
	for e.undo free(it.text);
	for e.redo free(it.text);
	array_free(e.undo);
	array_free(e.redo);
}

editor_sel :: (e: *Editor) -> int, int { return min(e.caret, e.mark), max(e.caret, e.mark); }
editor_has_sel :: (e: *Editor) -> bool { return e.caret != e.mark; }

editor_selected_text :: (e: *Editor) -> string {
	a, b := editor_sel(e);
	return slice(editor_text(e), a, b - a);
}

editor_undo :: (e: *Editor) -> bool { return restore(e, *e.undo, *e.redo); }
editor_redo :: (e: *Editor) -> bool { return restore(e, *e.redo, *e.undo); }

// Insert (replacing the selection), as typing.
editor_insert :: (e: *Editor, s: string, kind := Edit_Kind.Typing) {
	breaks := contains_any_character(s, " \n");
	snapshot(e, ifx editor_has_sel(e) || breaks then .Other else kind);
	a, b := editor_sel(e);
	replace_range(e, a, b, s);
	if breaks e.coalesce = .None;
}

// Replace the whole text as one undoable edit, then place caret and mark (block indent).
editor_apply :: (e: *Editor, s: string, caret: int, mark: int) {
	snapshot(e, .Other);
	e.coalesce = .None;
	e.buf.count = 0;
	array_add(*e.buf, ..cast([]u8) s);
	e.caret = clamp(caret, 0, e.buf.count);
	e.mark = clamp(mark, 0, e.buf.count);
	e.has_pref_x = false;
}

// Handle a key/text event. tl is the field's current layout (may be null).
// clip_get/clip_set let tests substitute the system clipboard.
editor_event :: (e: *Editor, ev: Input_Event, tl: *Text_Layout, clip_get: () -> string, clip_set: (s: string), multiline := true) -> Edit_Result {
	s := editor_text(e);
	if ev.kind == .Text {
		if ev.text == "" return .None;
		editor_insert(e, ev.text);
		return .Changed;
	}
	if ev.kind != .Key_Down return .None;
	shift := (ev.mods & .Shift) != 0;
	// cmd: line-wise moves; alt: word-wise; ctrl: emacs keys; short: clipboard/undo shortcuts.
	#if OS == .MACOS {
		cmd := (ev.mods & .Cmd) != 0;
		alt := (ev.mods & .Alt) != 0;
		ctrl := (ev.mods & .Ctrl) != 0;
		short := cmd;
	} else {
		cmd := false;
		alt := (ev.mods & .Ctrl) != 0;
		ctrl := false;
		short := alt;
	}
	a, b := editor_sel(e);

	if ev.key == {
		case .Left;
			if cmd                           move(e, line_start_of(tl, s, e.caret), shift);
			else if alt                      move(e, prev_word(s, e.caret), shift);
			else if editor_has_sel(e) && !shift move(e, a, false);
			else                             move(e, prev_grapheme(s, e.caret), shift);
			return .Moved;
		case .Right;
			if cmd                           move(e, line_end_of(tl, s, e.caret), shift);
			else if alt                      move(e, next_word(s, e.caret), shift);
			else if editor_has_sel(e) && !shift move(e, b, false);
			else                             move(e, next_grapheme(s, e.caret), shift);
			return .Moved;
		case .Up;
			if cmd move(e, 0, shift); else move(e, vertical(e, tl, -1), shift, true);
			return .Moved;
		case .Down;
			if cmd move(e, s.count, shift); else move(e, vertical(e, tl, 1), shift, true);
			return .Moved;
		// macOS: the whole text; elsewhere the line, and with Ctrl the whole text (as in Chromium)
		case .Home;
			move(e, ifx OS == .MACOS || alt then 0 else line_start_of(tl, s, e.caret), shift);
			return .Moved;
		case .End;
			move(e, ifx OS == .MACOS || alt then s.count else line_end_of(tl, s, e.caret), shift);
			return .Moved;
		case .Backspace;
			// Deleting the whole grapheme is the safe default (macOS removes one code point
			// of a cluster only for some scripts).
			if editor_has_sel(e) delete_to(e, e.caret);
			else if cmd          delete_to(e, line_start_of(tl, s, e.caret));
			else if alt          delete_to(e, prev_word(s, e.caret));
			else                 delete_to(e, prev_grapheme(s, e.caret));
			return .Changed;
		case .Delete;
			if editor_has_sel(e) delete_to(e, e.caret);
			else if cmd          delete_to(e, line_end_of(tl, s, e.caret));
			else if alt          delete_to(e, next_word(s, e.caret));
			else                 delete_to(e, next_grapheme(s, e.caret));
			return .Changed;
		case .Enter;
			if !shift || !multiline return .Submit;
			editor_insert(e, "\n");
			return .Changed;
		case .Escape;
			return .Escape;
		case .A;
			if short {
				e.mark = 0;
				e.caret = s.count;
				return .Moved;
			}
			if ctrl {
				move(e, line_start_of(tl, s, e.caret), shift);
				return .Moved;
			}
		case .C;
			if short && editor_has_sel(e) {
				clip_set(editor_selected_text(e));
				return .None;
			}
		case .X;
			if short && editor_has_sel(e) {
				clip_set(editor_selected_text(e));
				delete_to(e, e.caret);
				return .Changed;
			}
		case .V;
			if short {
				t := clip_get();
				if !multiline t = replace(t, "\n", " ",, temp);
				if t != "" {
					snapshot(e, .Other);
					replace_range(e, a, b, t);
					e.coalesce = .None;
					return .Changed;
				}
			}
		case .Z;
			if short {
				done := ifx shift then editor_redo(e) else editor_undo(e);
				return ifx done then .Changed else .None;
			}
		case .Y;
			if short && OS != .MACOS return ifx editor_redo(e) then .Changed else .None;
		case .K;
			if ctrl {
				delete_to(e, line_end_of(tl, s, e.caret));
				return .Changed;
			}
	}
	return .None;
}

// Mouse down at screen point p with OS click count.
editor_mouse_down :: (e: *Editor, tl: *Text_Layout, p: Vec2, click_count: int, shift: bool) {
	s := editor_text(e);
	pos := ifx tl then hit_test(tl, p) else s.count;
	e.has_pref_x = false;
	e.coalesce = .None;
	if shift {
		e.caret = pos;
		e.drag_gran = .Char;
		return;
	}
	if click_count == 2 {
		e.drag_a, e.drag_b = word_range_at(s, pos);
		e.drag_gran = .Word;
	} else if click_count >= 3 {
		e.drag_a, e.drag_b = paragraph_range_at(s, pos);
		e.drag_gran = .Paragraph;
	} else {
		e.drag_a, e.drag_b = pos, pos;
		e.drag_gran = .Char;
	}
	e.mark = e.drag_a;
	e.caret = e.drag_b;
}

editor_mouse_drag :: (e: *Editor, tl: *Text_Layout, p: Vec2) {
	if !tl return;
	s := editor_text(e);
	pos := hit_test(tl, p);
	if e.drag_gran == .Char {
		e.caret = pos;
		return;
	}
	a, b: int;
	if e.drag_gran == .Word a, b = word_range_at(s, pos);
	else a, b = paragraph_range_at(s, pos);
	if pos < e.drag_a {
		e.mark = e.drag_b;
		e.caret = a;
	} else {
		e.mark = e.drag_a;
		e.caret = max(b, e.drag_b);
	}
}

#scope_module

snapshot :: (e: *Editor, kind: Edit_Kind) {
	if kind != .Other && kind == e.coalesce && e.undo.count return;
	e.coalesce = kind;
	array_add(*e.undo, .{copy_string(editor_text(e)), e.caret, e.mark});
	if e.undo.count > 200 {
		free(e.undo[0].text);
		array_ordered_remove_by_index(*e.undo, 0);
	}
	for e.redo free(it.text);
	e.redo.count = 0;
}

restore :: (e: *Editor, from: *[..]Edit_Snapshot, to: *[..]Edit_Snapshot) -> bool {
	if !from.count return false;
	array_add(to, .{copy_string(editor_text(e)), e.caret, e.mark});
	s := pop(from);
	e.buf.count = 0;
	array_add(*e.buf, ..cast([]u8) s.text);
	e.caret = s.caret;
	e.mark = s.mark;
	free(s.text);
	e.coalesce = .None;
	return true;
}

// Splice s over buf[a:b].
replace_range :: (e: *Editor, a: int, b: int, s: string) {
	tail := copy_string(slice(editor_text(e), b, e.buf.count - b),, temp);
	e.buf.count = a;
	array_add(*e.buf, ..cast([]u8) s);
	array_add(*e.buf, ..cast([]u8) tail);
	e.caret = a + s.count;
	e.mark = e.caret;
	e.has_pref_x = false;
}

delete_to :: (e: *Editor, target: int) {
	if editor_has_sel(e) {
		snapshot(e, .Other);
		a, b := editor_sel(e);
		replace_range(e, a, b, "");
		return;
	}
	if target == e.caret return;
	snapshot(e, .Deleting);
	replace_range(e, min(target, e.caret), max(target, e.caret), "");
}

line_start_of :: (tl: *Text_Layout, s: string, pos: int) -> int {
	if tl && tl.lines.count return tl.lines[line_of(tl, pos)].start;
	return find_index_from_right(slice(s, 0, pos), #char "\n") + 1;
}

line_end_of :: (tl: *Text_Layout, s: string, pos: int) -> int {
	if tl && tl.lines.count return tl.lines[line_of(tl, pos)].end;
	i := find_index_from_left(s, #char "\n", pos);
	return ifx i < 0 then s.count else i;
}

vertical :: (e: *Editor, tl: *Text_Layout, dir: int) -> int {
	s := editor_text(e);
	if !tl || !tl.lines.count return ifx dir < 0 then 0 else s.count;
	if !e.has_pref_x {
		e.pref_x = caret_x(tl, e.caret);
		e.has_pref_x = true;
	}
	nl := line_of(tl, e.caret) + dir;
	if nl < 0 return 0;
	if nl >= tl.lines.count return s.count;
	return hit_test_line(tl, nl, e.pref_x);
}

move :: (e: *Editor, target: int, extend: bool, keep_pref_x := false) {
	e.caret = clamp(target, 0, e.buf.count);
	if !extend e.mark = e.caret;
	if !keep_pref_x e.has_pref_x = false;
	e.coalesce = .None;
}

#scope_export
