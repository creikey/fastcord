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

editor_text :: (e: *Editor) -> string {return as_string(view(e.buf));}

editor_set_text :: (e: *Editor, s: string) {
	clear(*e.buf);
	append(*e.buf, s);
	e.caret = len(e.buf);
	e.mark = e.caret;
	e.has_pref_x = false;
}

editor_destroy :: (e: *Editor) {
	delete(e.buf);
	for s: e.undo { delete(s.text); }
	for s: e.redo { delete(s.text); }
	delete(e.undo);
	delete(e.redo);
}

editor_sel :: (e: *Editor) -> int, int {return min(e.caret, e.mark), max(e.caret, e.mark);}
editor_has_sel :: (e: *Editor) -> bool {return e.caret != e.mark;}

editor_selected_text :: (e: *Editor) -> string {
	a, b := editor_sel(e);
	return as_string(sub(e.buf, a, b));
}
#scope_module

snapshot :: (e: *Editor, kind: Edit_Kind) {
	if kind != .Other && kind == e.coalesce && len(e.undo) > 0 { return; }
	e.coalesce = kind;
	append(*e.undo, Edit_Snapshot.{clone(editor_text(e)), e.caret, e.mark});
	if len(e.undo) > 200 {
		delete(e.undo[0].text);
		ordered_remove(*e.undo, 0);
	}
	for s: e.redo { delete(s.text); }
	clear(*e.redo);
}

restore :: (e: *Editor, from: *[..]Edit_Snapshot, to: *[..]Edit_Snapshot) -> bool {
	if len(from) == 0 { return false; }
	append(to, Edit_Snapshot.{clone(editor_text(e)), e.caret, e.mark});
	s := pop(from);
	clear(*e.buf);
	append(*e.buf, s.text);
	e.caret = s.caret;
	e.mark = s.mark;
	delete(s.text);
	e.coalesce = .None;
	return true;
}
#scope_export

editor_undo :: (e: *Editor) -> bool {return restore(e, *e.undo, *e.redo);}
editor_redo :: (e: *Editor) -> bool {return restore(e, *e.redo, *e.undo);}
#scope_module

replace_range :: (e: *Editor, a: int, b: int, s: string) {
	// Odin remove_range + inject_at: splice s over buf[a:b].
	tail := clone(as_string(sub_from(e.buf, b)), temp);
	resize(*e.buf, a);
	append(*e.buf, s);
	append(*e.buf, tail);
	e.caret = a + len(s);
	e.mark = e.caret;
	e.has_pref_x = false;
}
#scope_export

// Insert (replacing the selection), as typing.
editor_insert :: (e: *Editor, s: string, kind := Edit_Kind.Typing) {
	k := kind;
	if editor_has_sel(e) || strings.contains_any(s, " \n") { k = .Other; }
	snapshot(e, k);
	a, b := editor_sel(e);
	replace_range(e, a, b, s);
	if strings.contains_any(s, " \n") { e.coalesce = .None; }
}
#scope_module

delete_to :: (e: *Editor, target: int) {
	if editor_has_sel(e) {
		snapshot(e, .Other);
		a, b := editor_sel(e);
		replace_range(e, a, b, "");
		return;
	}
	if target == e.caret { return; }
	snapshot(e, .Deleting);
	replace_range(e, min(target, e.caret), max(target, e.caret), "");
}

line_start_of :: (tl: *Text_Layout, s: string, pos: int) -> int {
	if tl != null && len(tl.lines) > 0 { return get(tl.lines, line_of(tl, pos)).start; }
	return strings.last_index_byte(sub(s, 0, pos), 10) + 1;
}

line_end_of :: (tl: *Text_Layout, s: string, pos: int) -> int {
	if tl != null && len(tl.lines) > 0 { return get(tl.lines, line_of(tl, pos)).end; }
	i := strings.index_byte(sub_from(s, pos), 10);
	return ifx i < 0 then len(s) else pos + i;
}

vertical :: (e: *Editor, tl: *Text_Layout, dir: int) -> int {
	s := editor_text(e);
	if tl == null || len(tl.lines) == 0 { return ifx dir < 0 then 0 else len(s); }
	li := line_of(tl, e.caret);
	if !e.has_pref_x {
		e.pref_x = caret_x(tl, e.caret);
		e.has_pref_x = true;
	}
	nl := li + dir;
	if nl < 0 { return 0; }
	if nl >= len(tl.lines) { return len(s); }
	return hit_test_line(tl, nl, e.pref_x);
}

move :: (e: *Editor, target: int, extend: bool, keep_pref_x := false) {
	e.caret = clamp(target, 0, len(e.buf));
	if !extend { e.mark = e.caret; }
	if !keep_pref_x { e.has_pref_x = false; }
	e.coalesce = .None;
}
#scope_export

// Handle a key/text event. tl is the field's current layout (may be nil).
// clipboard_set/get let tests substitute the system clipboard.
editor_event :: (e: *Editor, ev: Input_Event, tl: *Text_Layout, clip_get: () -> string, clip_set: (s: string), multiline := true) -> Edit_Result {
	s := editor_text(e);
	if ev.kind == .Text {
		if ev.text == "" { return .None; }
		editor_insert(e, ev.text);
		return .Changed;
	}
	if ev.kind != .Key_Down { return .None; }
	shift := has(ev.mods, .Shift);
	// cmd: line-wise moves; alt: word-wise; ctrl: emacs keys; short: clipboard/undo shortcuts.
	#if OS == .MACOS {
		cmd := has(ev.mods, .Cmd);
		alt := has(ev.mods, .Alt);
		ctrl := has(ev.mods, .Ctrl);
		short := cmd;
	} else {
		cmd := false;
		alt := has(ev.mods, .Ctrl);
		ctrl := false;
		short := has(ev.mods, .Ctrl);
	}
	a, b := editor_sel(e);

	if ev.key == {
	case .Left;
		if cmd {
			move(e, line_start_of(tl, s, e.caret), shift);
		} else if alt {
			move(e, prev_word(s, e.caret), shift);
		} else if editor_has_sel(e) && !shift {
			move(e, a, false);
		} else {
			move(e, prev_grapheme(s, e.caret), shift);
		}
		return .Moved;
	case .Right;
		if cmd {
			move(e, line_end_of(tl, s, e.caret), shift);
		} else if alt {
			move(e, next_word(s, e.caret), shift);
		} else if editor_has_sel(e) && !shift {
			move(e, b, false);
		} else {
			move(e, next_grapheme(s, e.caret), shift);
		}
		return .Moved;
	case .Up;
		if cmd { move(e, 0, shift); } else { move(e, vertical(e, tl, -1), shift, true); }
		return .Moved;
	case .Down;
		if cmd { move(e, len(s), shift); } else { move(e, vertical(e, tl, 1), shift, true); }
		return .Moved;
	case .Home;
		move(e, 0, shift);
		return .Moved;
	case .End;
		move(e, len(s), shift);
		return .Moved;
	case .Backspace;
		if editor_has_sel(e) {
			delete_to(e, e.caret);
		} else if cmd {
			delete_to(e, line_start_of(tl, s, e.caret));
		} else if alt {
			delete_to(e, prev_word(s, e.caret));
		} else {
			// Backspace removes one code point of a cluster on macOS only for
			// some scripts; deleting the whole grapheme is the safe default.
			delete_to(e, prev_grapheme(s, e.caret));
		}
		return .Changed;
	case .Delete;
		if editor_has_sel(e) {
			delete_to(e, e.caret);
		} else if cmd {
			delete_to(e, line_end_of(tl, s, e.caret));
		} else if alt {
			delete_to(e, next_word(s, e.caret));
		} else {
			delete_to(e, next_grapheme(s, e.caret));
		}
		return .Changed;
	case .Enter;
		if shift && multiline {
			editor_insert(e, "\n");
			return .Changed;
		}
		return .Submit;
	case .Escape;
		return .Escape;
	case .A;
		if short {
			e.mark = 0;
			e.caret = len(s);
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
			if !multiline { t, _ = strings.replace_all(t, "\n", " ", temp); }
			if t != "" {
				snapshot(e, .Other);
				replace_range(e, a, b, t);
				e.coalesce = .None;
				return .Changed;
			}
		}
	case .Z;
		if short {
			if shift { return ifx editor_redo(e) then .Changed else .None; }
			return ifx editor_undo(e) then .Changed else .None;
		}
	case .Y;
		if short && OS != .MACOS { return ifx editor_redo(e) then .Changed else .None; }
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
	pos := ifx tl != null then hit_test(tl, p) else len(s);
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
	if tl == null { return; }
	s := editor_text(e);
	pos := hit_test(tl, p);
	if e.drag_gran == {
	case .Char;
		e.caret = pos;
	case .Word; #through; case .Paragraph;
		a, b: int;
		if e.drag_gran == .Word { a, b = word_range_at(s, pos); } else { a, b = paragraph_range_at(s, pos); }
		if pos < e.drag_a {
			e.mark = e.drag_b;
			e.caret = a;
		} else {
			e.mark = e.drag_a;
			e.caret = max(b, e.drag_b);
		}
	}
}

