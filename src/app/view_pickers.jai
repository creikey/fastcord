// Expression picker (GIFs / Stickers / Emoji) popout above the composer, and
// the emoji-only reaction picker from a message. Geometry lives in PK_* so it
// can be tuned against screenshots of the official client.

// ---- geometry (points) ----
// From the client's CSS (expression picker chunk 678906 + emoji picker 31544):
// .positionContainer height 486 (only-emoji 396), .contentWrapper padding-top 16,
// rows 30px (nav) / gap 12, .navButton 14px/600 padding 8px 12px, gap 8, nav
// padding 0 16; emoji picker standalone 498x440; header padding 0 16 12 16
// (16 top when standalone) with a 1px --border-subtle bottom; search bar 40.
PK_W :: 498; // popout width (--custom-emoji-picker-constants-min-emoji-picker-width)
PK_H :: 486; // .positionContainer height
PK_RADIUS :: 8; // --radius-sm
PK_COMPOSER_GAP :: 8; // space between the popout and the composer's top edge
PK_RIGHT_INSET :: 24; // .drawerSizingWrapper inset-inline-end (matches the reference screenshot)
PK_REACTION_W :: 498;
PK_REACTION_H :: 440; // --custom-emoji-picker-constants-emoji-picker-height
PK_SCREEN_MARGIN :: 8;
PK_OPEN_SECONDS :: 0.15; // scale + fade in
PK_CLOSE_SECONDS :: 0.1;
PK_OPEN_SCALE :: 0.95; // starting scale of the open animation

PK_HEADER_PAD_X :: 16;
PK_HEADER_PAD_TOP :: 16;
PK_TAB_H :: 30;
PK_TAB_PAD_X :: 12;
PK_TAB_GAP :: 8;
PK_TAB_FONT :: 14;
PK_TABS_TO_SEARCH :: 12;
PK_SEARCH_H :: 40;
PK_SEARCH_FONT :: 16;
PK_SEARCH_RADIUS :: 8;
PK_SEARCH_PAD_X :: 12;
PK_HEADER_PAD_BOTTOM :: 12;
PK_HEADER_GAP :: 12; // search bar to skin tone selector
PK_ADD_EMOJI_PAD_X :: 16; // "Add Emoji" button padding (102px wide at 16px)

PK_SCROLLBAR_W :: 4;

Picker_Tab :: enum u8 {
	Gif;
	Sticker;
	Emoji;
}

PICKER_TABS :: #run enum_highest_value(Picker_Tab) + 1;
PICKER_TAB_LABELS :: string.["GIFs", "Stickers", "Emoji"];

Picker_Mode :: enum u8 {
	Composer;
	Reaction;
}

Picker_State :: struct {
	open: bool;
	closing: bool;
	t: float32; // 0..1 open progress (linear in time)
	mode: Picker_Mode;
	tab: Picker_Tab;
	channel: dc.Snowflake;
	message: dc.Snowflake; // reaction target
	anchor: ui.Rect; // the button that opened it
	composer_right: float32; // right edge of the composer (from the reaction button)
	composer_top: float32;
	rect: ui.Rect; // last laid-out popout rect (final, unscaled)
	captured: [..]int; // indices into app.ui.events stolen for the picker this frame
	search: [PICKER_TABS]ui.Editor;
	search_focus: bool;
	opened_once: bool;
	keys: [..]ui.Input_Event; // keyboard events for the active tab this frame
	hidden_mouse: ui.Vec2;
	has_hidden_mouse: bool; // real mouse while hidden from the views under the popout
	buttons: [PICKER_TABS]ui.Rect; // composer buttons (clicks on them switch tabs, not close)
}

pk: Picker_State;

picker_is_open :: () -> bool { return pk.open && !pk.closing; }

// Composer hook: one call per composer button ("gif", "sticker", "reaction").
// Returns whether the button should draw highlighted.
picker_composer_button :: (name: string, sig: ui.Signal, rect: ui.Rect, channel_id: dc.Snowflake) -> bool {
	tab: Picker_Tab;
	if name == {
	case "gif";
		tab = .Gif;
	case "sticker";
		tab = .Sticker;
	case "reaction";
		tab = .Emoji;
	case;
		return sig.hovering;
	}
	// the popout aligns to the composer box (the buttons' parent), like the client's positionTargetRef
	p := sig.box.parent;
	if p != null && p.rect.x1 > p.rect.x0 {
		pk.composer_right = p.rect.x1;
		pk.composer_top = p.rect.y0;
	} else {
		pk.composer_right = rect.x1 + 8;
		pk.composer_top = rect.y0;
	}
	pk.buttons[tab] = rect;
	active := picker_is_open() && pk.mode == .Composer && pk.tab == tab && pk.channel == channel_id;
	if sig.clicked {
		if active {
			picker_close();
		} else {
			if !picker_is_open() || pk.mode != .Composer || pk.channel != channel_id picker_open(.Composer, tab, channel_id, 0, rect);
			else picker_set_tab(tab);
			pk.anchor = rect;
		}
	}
	return sig.hovering || active;
}

picker_open :: (mode: Picker_Mode, tab: Picker_Tab, channel_id: dc.Snowflake, message_id: dc.Snowflake, anchor: ui.Rect) {
	if !picker_is_open() pk.t = 0;
	pk.open = true;
	pk.closing = false;
	pk.mode = mode;
	pk.channel = channel_id;
	pk.message = message_id;
	pk.anchor = anchor;
	pk.search_focus = true;
	picker_set_tab(tab);
	for * pk.search ui.editor_set_text(it, "");
	emoji_picker_reset();
	if !pk.opened_once {
		pk.opened_once = true;
		pickers_first_open();
	}
	c := dc.channel_get(store(), channel_id);
	gid := ifx c then c.guild_id else 0;
	if (tab == .Emoji || mode == .Reaction) && c != null pickers_on_open_guild(gid);
	if app.client != null && tab != .Sticker {
		kind: dc.Picker_Kind = ifx mode == .Reaction then .Reaction else ifx tab == .Gif then .Gif else .Emoji;
		dc.expression_picker_opened(app.client, kind, gid, channel_id, picker_expression_counts(mode == .Reaction, gid), message_id, PK_W);
	}
}

picker_set_tab :: (tab: Picker_Tab) {
	pk.tab = tab;
	if tab == .Gif gif_picker_on_show();
	if tab == .Sticker sticker_picker_on_show();
}

picker_close :: () {
	if !picker_is_open() return;
	pk.closing = true;
	if app.client != null dc.picker_closed(app.client);
	if pk.mode == .Reaction app.reaction_target = 0;
	// only if the picker still has the keyboard: the press that closed it may have focused a field
	if app.ui.focus == ui.key_from_string("picker_search###pk_search", 0) app.ui.focus = 0;
}

// Called at the top of chat_view, before anything else reads input: while the
// picker is open it owns the keyboard, and the wheel when over the popout.
picker_capture_input :: () {
	pk.captured.count = 0;
	if !picker_is_open() return;
	over := pk_contains(pk.rect, app.ui.mouse);
	if over {
		// the message list hovers by rect (ui.mouse_over); keep it from reacting under the popout
		pk.hidden_mouse, pk.has_hidden_mouse = app.ui.mouse, true;
		app.ui.mouse = .{-1000000, -1000000};
	}
	for * e, i: app.ui.events {
		if e.consumed continue;
		if e.kind == .Key_Down || e.kind == .Text || (e.kind == .Scroll && over) {
			e.consumed = true;
			array_add(*pk.captured, i);
		}
	}
}

pk_contains :: (r: ui.Rect, p: ui.Vec2) -> bool {
	return p.x >= r.x0 && p.x < r.x1 && p.y >= r.y0 && p.y < r.y1;
}

// Overlay entry (views.jai overlays()): network results every frame, the popout when open.
picker_overlay :: () {
	if pk.has_hidden_mouse {
		app.ui.mouse = pk.hidden_mouse;
		pk.has_hidden_mouse = false;
	}
	pickers_poll();
	pk.keys.count = 0;
	picker_debug_autopen();
	// toolbar / context menu "Add Reaction" set app.reaction_target
	if app.reaction_target != 0 && !(picker_is_open() && pk.mode == .Reaction && pk.message == app.reaction_target) {
		m := find_message(app.reaction_target);
		if m != null {
			p := app.ui.mouse;
			picker_open(.Reaction, .Emoji, m.channel_id, m.id, .{p.x - 16, p.y - 16, p.x + 16, p.y + 16});
		} else {
			app.reaction_target = 0;
		}
	}
	if !pk.open return;
	if pk.channel != app.view.channel {
		pk.open = false;
		pk.closing = false;
		if pk.mode == .Reaction app.reaction_target = 0;
		return;
	}
	dt := app.ui.dt;
	if pk.closing {
		pk.t -= dt / PK_CLOSE_SECONDS;
		if pk.t <= 0 {
			pk.t = 0;
			pk.open = false;
			pk.closing = false;
			return;
		}
		app.ui.animating = true;
	} else if pk.t < 1 {
		pk.t = min(1.0, pk.t + dt / PK_OPEN_SECONDS);
		app.ui.animating = true;
	}
	// hand the captured events back to the picker's widgets
	for pk.captured if it < app.ui.events.count app.ui.events[it].consumed = false;
	pk.captured.count = 0;
	if !pk.closing picker_input();
	if !pk.open return;
	picker_panel();
}

// Multiplies opacity through a subtree (ui does not inherit opacity).
pk_fade :: (b: *ui.Box, a: float32) {
	b.opacity *= a;
	c := b.first;
	while c {
		pk_fade(c, a);
		c = c.next;
	}
}

picker_header_h :: () -> float32 {
	h: float32 = PK_HEADER_PAD_TOP + PK_SEARCH_H + PK_HEADER_PAD_BOTTOM + 1;
	if pk.mode == .Composer h += PK_TAB_H + PK_TABS_TO_SEARCH;
	return h;
}
Search_Draw :: struct {
	ed: *ui.Editor;
}

// Caret + selection for a single-line field whose text is vertically centered.
search_caret_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Search_Draw) user;
	tl := b.text_layout;
	if tl == null return;
	text := ui.editor_text(d.ed);
	o := tl.origin;
	if o == .{} o = .{b.rect.x0, b.rect.y0 + (b.rect.y1 - b.rect.y0 - tl.height) / 2};
	if text != "" && ui.editor_has_sel(d.ed) {
		a, z := ui.editor_sel(d.ed);
		x0 := ui.caret_x(tl, a);
		x1 := ui.caret_x(tl, z);
		gfx.rect(.{o.x + x0, o.y, o.x + x1, o.y + tl.line_h}, cast(gfx.Color) with_alpha(app.ui.selection_color, b.opacity));
	}
	x := ifx text == "" then 0 else ui.caret_x(tl, d.ed.caret);
	phase := app.ui.time - app.caret_reset_t;
	request_wake(app.caret_reset_t + (cast(float64) cast(int) (phase * 2) + 1) * 0.5);
	if app.sweep || phase < 0.5 || cast(int) (phase * 2) % 2 == 0 {
		gfx.rect(.{o.x + x, o.y + 2, o.x + x + 1.5, o.y + tl.line_h - 2}, cast(gfx.Color) with_alpha(T("--text-default"), b.opacity));
	}
	platform.set_ime_rect(o.x + x, o.y, 1, tl.line_h);
}

// ---- shared scrolling list (virtualized grids position rows themselves) ----

Pk_Scroll :: struct {
	y, target: float32;
	content_h: float32;
	view_h: float32;
}

// Wheel over rect moves the list; call before laying out rows.
pk_scroll_update :: (s: *Pk_Scroll, view: ui.Rect, content_h: float32) {
	s.content_h = content_h;
	s.view_h = view.y1 - view.y0;
	if pk_contains(view, app.ui.mouse) {
		for * e: app.ui.events {
			if e.kind != .Scroll || e.consumed continue;
			s.target -= e.delta.y;
			e.consumed = true;
		}
	}
	max_y := max(0.0, content_h - s.view_h);
	s.target = clamp(s.target, 0, max_y);
	ui.animate(*s.y, s.target, 40);
	s.y = clamp(s.y, 0, max_y);
}

// Keep [y0, y1) in view.
pk_scroll_reveal :: (s: *Pk_Scroll, y0: float32, y1: float32, top_inset: float32 = 0) {
	if y0 - top_inset < s.target s.target = y0 - top_inset;
	else if y1 > s.target + s.view_h s.target = y1 - s.view_h;
	s.target = clamp(s.target, 0, max(0.0, s.content_h - s.view_h));
}

// The list's thin scrollbar; call inside the list box, after its rows.
pk_scrollbar :: (s: *Pk_Scroll) {
	ui.scrollbar(ui.top_parent(), .Thin, *s.y, *s.target, s.content_h);
}

// Lowercased, trimmed query of the active tab.
pk_query :: (tab: Picker_Tab) -> string {
	return to_lower_copy(trim(ui.editor_text(*pk.search[tab])),, temp);
}

// "Add Reaction" button after a message's reactions (shown while the message is hovered).
reaction_add_button :: (m: *dc.Message) {
	open := picker_is_open() && pk.mode == .Reaction && pk.message == m.id;
	if app.chat_hover != m.id && !open return;
	b := row("addreaction", .Clickable | .Draw_Background | .Draw_Border | .Hot_Animation);
	b.semantic_size = .[ui.px(34), ui.px(26)];
	b.style.radius = all4(8);
	b.style.border = 1;
	b.style.bg = T("--reaction-background-default");
	b.style.bg_hot = T("--reaction-background-hover");
	b.style.border_color = T("--reaction-border-default");
	sig := ui.signal(b);
	{ ui.parent(b); defer ui.pop_parent();
		spacer(.X, 8);
		icon("i", "reaction-plus", 18, ifx sig.hovering || open then T("--interactive-icon-hover") else T("--interactive-icon-default"));
	}
	if sig.clicked {
		if open {
			picker_close();
		} else {
			app.reaction_target = m.id;
			picker_open(.Reaction, .Emoji, m.channel_id, m.id, b.rect);
		}
	}
}

#scope_file

// Escape, click-outside, and the keyboard routed to the active tab.
picker_input :: () {
	for * e: app.ui.events {
		// a press outside closes the picker even when the control under it took the
		// press (composer, header search, ...), like the client; otherwise the picker
		// stayed open and kept the keyboard focus that control just asked for
		if e.consumed && e.kind != .Mouse_Down continue;
		if e.kind == {
		case .Mouse_Down;
			on_button := false;
			if pk.mode == .Composer for pk.buttons if pk_contains(it, e.pos) on_button = true;
			if !pk_contains(pk.rect, e.pos) && !pk_contains(pk.anchor, e.pos) && !on_button {
				picker_close();
				return;
			}
		case .Key_Down;
			if e.key == .Escape {
				e.consumed = true;
				picker_close();
				return;
			}
		}
	}
	app.ui.focus = ui.key_from_string("picker_search###pk_search", 0);
}

ease_out :: (t: float32) -> float32 {
	u := 1 - clamp(t, 0, 1);
	return 1 - u * u * u;
}

// Final (unscaled) popout rect.
picker_target_rect :: () -> ui.Rect {
	screen := app.ui.window;
	w, h: float32 = PK_W, PK_H;
	r: ui.Rect;
	if pk.mode == .Composer {
		w = min(w, screen.x - 2 * PK_SCREEN_MARGIN);
		h = min(h, max(200.0, pk.composer_top - PK_COMPOSER_GAP - TITLE_BAR_H - PK_SCREEN_MARGIN));
		right := (ifx pk.composer_right != 0 then pk.composer_right else pk.anchor.x1) - PK_RIGHT_INSET;
		bottom := ifx pk.composer_top != 0 then pk.composer_top - PK_COMPOSER_GAP else pk.anchor.y0 - PK_COMPOSER_GAP;
		r = .{right - w, bottom - h, right, bottom};
	} else {
		w, h = PK_REACTION_W, PK_REACTION_H;
		// to the left of the anchor, top-aligned, kept on screen
		r = .{pk.anchor.x0 - w - 8, pk.anchor.y0, pk.anchor.x0 - 8, pk.anchor.y0 + h};
		if r.x0 < PK_SCREEN_MARGIN { r = .{pk.anchor.x1 + 8, r.y0, pk.anchor.x1 + 8 + w, r.y1}; }
	}
	if r.x0 < PK_SCREEN_MARGIN {
		r.x1 += PK_SCREEN_MARGIN - r.x0;
		r.x0 = PK_SCREEN_MARGIN;
	}
	if r.x1 > screen.x - PK_SCREEN_MARGIN {
		d := r.x1 - (screen.x - PK_SCREEN_MARGIN);
		r.x0 -= d;
		r.x1 -= d;
	}
	if r.y1 > screen.y - PK_SCREEN_MARGIN {
		d := r.y1 - (screen.y - PK_SCREEN_MARGIN);
		r.y0 -= d;
		r.y1 -= d;
	}
	if r.y0 < TITLE_BAR_H + PK_SCREEN_MARGIN {
		d := TITLE_BAR_H + PK_SCREEN_MARGIN - r.y0;
		r.y0 += d;
		r.y1 += d;
	}
	return r;
}

picker_panel :: () {
	r := picker_target_rect();
	pk.rect = r;
	k := ease_out(pk.t);
	sc := PK_OPEN_SCALE + (1 - PK_OPEN_SCALE) * k;
	// scale about the corner nearest the anchor (bottom-right above the composer)
	w, h := (r.x1 - r.x0) * sc, (r.y1 - r.y0) * sc;
	ox, oy := r.x1 - w, r.y1 - h;
	if pk.mode == .Reaction {
		ox = r.x0 + (r.x1 - r.x0 - w) / 2;
		oy = r.y0;
	}
	frame := ui.box("picker_frame###pk_frame", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable | .Clip);
	frame.semantic_size = .[ui.px(w), ui.px(h)];
	frame.fixed_pos = .{ox, oy};
	frame.style.bg = T("--background-surface-high");
	frame.style.border_color = T("--border-subtle");
	frame.style.border = 1;
	frame.style.radius = all4(PK_RADIUS);
	frame.style.shadow_color = .{0, 0, 0, 0.32};
	frame.style.shadow_blur = 16;
	frame.style.shadow_offset = .{0, 8};
	ui.signal(frame); // swallow clicks inside
	{ ui.parent(frame); defer ui.pop_parent();
		content := ui.box("picker_content", .Floating_X | .Floating_Y);
		content.semantic_size = .[ui.px(r.x1 - r.x0), ui.px(r.y1 - r.y0)];
		content.fixed_pos = .{r.x0 - ox, r.y0 - oy};
		content.layout_axis = .Y;
		{ ui.parent(content); defer ui.pop_parent();
			picker_header(r);
			body := ui.box("picker_body");
			body.semantic_size = .[ui.pct(1), ui.fill()];
			body.layout_axis = .Y;
			{ ui.parent(body); defer ui.pop_parent();
				body_rect := ui.Rect.{r.x0, r.y0 + picker_header_h(), r.x1, r.y1};
				if pk.tab == {
				case .Emoji;
					emoji_picker_body(body_rect);
				case .Gif;
					gif_picker_body(body_rect);
				case .Sticker;
					sticker_picker_body(body_rect);
				}
			}
		}
	}
	pk_fade(frame, ease_out(pk.t));
}
picker_header :: (r: ui.Rect) {
	hdr := ui.box("picker_header");
	hdr.semantic_size = .[ui.pct(1), ui.px(picker_header_h())];
	hdr.layout_axis = .Y;
	{ ui.parent(hdr); defer ui.pop_parent();
		spacer(.Y, PK_HEADER_PAD_TOP);
		if pk.mode == .Composer {
			tabs := row("tabs");
			tabs.semantic_size = .[ui.pct(1), ui.px(PK_TAB_H)];
			{ ui.parent(tabs); defer ui.pop_parent();
				spacer(.X, PK_HEADER_PAD_X);
				for tab: enum_values_as_enum(Picker_Tab) {
					sel := pk.tab == tab;
					b := ui.box(PICKER_TAB_LABELS[tab], .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
					b.semantic_size = .[ui.text_size(PK_TAB_PAD_X), ui.px(PK_TAB_H)];
					b.style.font = F(.Semibold);
					b.style.font_size = PK_TAB_FONT;
					b.style.line_height = 14;
					b.style.radius = all4(PK_RADIUS);
					b.style.text_align = .Center;
					sig := ui.signal(b);
					// .navButton / .navButtonActive
					b.style.bg = ifx sel then T("--background-mod-normal") else .{};
					b.style.bg_hot = ifx sel then T("--background-mod-strong") else T("--control-secondary-background-hover");
					b.style.text_color = ifx sel then (ifx sig.hovering then T("--interactive-text-active") else T("--text-strong")) else (ifx sig.hovering then T("--interactive-text-hover") else T("--text-default"));
					if sig.clicked && !sel picker_set_tab(tab);
					spacer(.X, PK_TAB_GAP);
				}
			}
			spacer(.Y, PK_TABS_TO_SEARCH);
		}
		srow := row("searchrow");
		srow.semantic_size = .[ui.pct(1), ui.px(PK_SEARCH_H)];
		{ ui.parent(srow); defer ui.pop_parent();
			spacer(.X, PK_HEADER_PAD_X);
			placeholder := ifx pk.mode == .Reaction then "Find the perfect reaction" else "Find the perfect emoji";
			if pk.tab == .Gif placeholder = "Search Klipy";
			if pk.tab == .Sticker placeholder = "Find the perfect sticker";
			res := ui.Edit_Result.None;
			if pk.tab == .Gif gif_header_back();
			if !(pk.tab == .Gif && gif_header_title()) res = pk_search_field(*pk.search[pk.tab], placeholder);
			if res == .Changed query_changed(pk.tab);
			if pk.tab == .Emoji {
				spacer(.X, PK_HEADER_GAP);
				skin_tone_button();
				// "Add Emoji" when you can manage this guild's expressions (official: 102x40)
				pch := dc.channel_get(store(), pk.channel);
				gid := ifx pch then pch.guild_id else 0;
				if can_upload_emoji(gid) {
					spacer(.X, PK_HEADER_GAP);
					busy := emoji_upload_busy();
					add := ui.box(ifx busy then "Uploading...##addemoji" else "Add Emoji##addemoji", .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
					add.semantic_size = .[ui.text_size(PK_ADD_EMOJI_PAD_X), ui.px(PK_SEARCH_H)];
					add.style.radius = all4(PK_SEARCH_RADIUS);
					add.style.font = F(.Medium);
					add.style.font_size = 16;
					add.style.text_align = .Center;
					add.style.text_color = T("--text-strong");
					add.style.bg = T("--background-mod-normal");
					add.style.bg_hot = T("--background-mod-strong");
					if busy add.flags |= .Disabled;
					if ui.signal(add).clicked && !busy emoji_upload_pick(gid); // file dialog, then upload off the UI thread
				}
			}
			spacer(.X, PK_HEADER_PAD_X);
		}
		spacer(.Y, PK_HEADER_PAD_BOTTOM);
		line := ui.box("hdrline", .Draw_Background);
		line.semantic_size = .[ui.pct(1), ui.px(1)];
		line.style.bg = T("--border-subtle");
	}
}

// Single-line search input with a magnifier (or clear button once there is text).
pk_search_field :: (ed: *ui.Editor, placeholder: string) -> ui.Edit_Result {
	wrap := row("search", .Draw_Background | .Draw_Border | .Clickable);
	wrap.semantic_size = .[ui.fill(), ui.px(PK_SEARCH_H)];
	wrap.style.bg = T("--input-background-default");
	wrap.style.border_color = T("--input-border-active"); // focused while open: 2px brand border
	wrap.style.border = 2;
	wrap.style.radius = all4(PK_SEARCH_RADIUS);
	wrap.hover_cursor = .IBeam;
	result := ui.Edit_Result.None;
	{ ui.parent(wrap); defer ui.pop_parent();
		spacer(.X, PK_SEARCH_PAD_X);
		icon("mag", "magnifying-glass", 20, T("--icon-default"));
		spacer(.X, 8);
		f := ui.box("picker_search###pk_search", .Clickable | .Draw_Text | .Focusable | .Clip);
		f.semantic_size = .[ui.fill(), ui.px(PK_SEARCH_H - 2)];
		f.style.font = F(.Normal);
		f.style.font_size = PK_SEARCH_FONT;
		f.style.line_height = 20;
		f.hover_cursor = .IBeam;
		text := ui.editor_text(ed);
		f.text = text;
		f.style.text_color = T("--text-default");
		if text == "" {
			f.text = placeholder;
			f.style.text_color = T("--input-placeholder-text-default");
		}
		sig := ui.signal(f);
		tl := f.prev_layout; // this frame's is laid out after the events are handled
		if text == "" tl = null;
		if sig.pressed {
			for e: app.ui.events {
				if e.kind == .Mouse_Down && e.button == .Left {
					ui.editor_mouse_down(ed, tl, e.pos, e.click_count, (e.mods & .Shift) != 0);
					break;
				}
			}
		} else if sig.dragging {
			ui.editor_mouse_drag(ed, tl, app.ui.mouse);
		}
		for * e: app.ui.events {
			if e.consumed continue;
			if e.kind == .Key_Down {
				// the grid owns arrows / enter (the input keeps focus, like the client)
				if e.key == {
				case .Up; #through; case .Down; #through; case .Enter; #through; case .Page_Up; #through; case .Page_Down;
					array_add(*pk.keys, e.*);
					e.consumed = true;
					continue;
				case .Left; #through; case .Right;
					if e.mods == 0 && pk.tab == .Emoji && text == "" {
						array_add(*pk.keys, e.*);
						e.consumed = true;
						continue;
					}
				}
			}
			if e.kind != .Key_Down && e.kind != .Text continue;
			r := ui.editor_event(ed, e, tl, clipboard_get, clipboard_set);
			if r != .None {
				e.consumed = true;
				if r != .Moved || result == .None result = r;
			}
		}
		note_focused_editor(ed, f);
		d := New(Search_Draw,, temp);
		d.ed = ed;
		f.custom_draw = search_caret_draw;
		f.custom_user = d;
		if text != "" {
			x := ui.box("clear", .Clickable);
			x.semantic_size = .[ui.px(24), ui.px(24)];
			xs := ui.signal(x);
			set_icon(x, "x-small", ifx xs.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
			if xs.clicked {
				ui.editor_set_text(ed, "");
				result = .Changed;
			}
		}
		spacer(.X, PK_SEARCH_PAD_X);
	}
	if ui.signal(wrap).pressed pk.search_focus = true;
	return result;
}
autopen_done: bool;

// FASTCORD_PICKER=gif|sticker|emoji (+ FASTCORD_PICKER_QUERY=...) opens the picker
// once a channel is showing — for headless -live checks of the real REST data.
picker_debug_autopen :: () {
	if autopen_done || app.view.channel == 0 || pk.composer_top == 0 return;
	autopen_done = true;
	which := env_var("FASTCORD_PICKER");
	if which == "" return;
	tab := ifx which == "gif" then Picker_Tab.Gif else ifx which == "sticker" then Picker_Tab.Sticker else .Emoji;
	picker_open(.Composer, tab, app.view.channel, 0, .{pk.composer_right - 48, pk.composer_top, pk.composer_right - 8, pk.composer_top + 52});
	q := env_var("FASTCORD_PICKER_QUERY");
	if q != "" {
		ui.editor_set_text(*pk.search[tab], q);
		query_changed(tab);
	}
}

query_changed :: (tab: Picker_Tab) {
	if tab == {
		case .Emoji;   emoji_picker_query_changed();
		case .Gif;     gif_picker_query_changed();
		case .Sticker; sticker_picker_query_changed();
	}
}

