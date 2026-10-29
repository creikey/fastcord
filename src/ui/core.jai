Vec2 :: Vector2;
Color :: Vector4; // x, y, z, w = r, g, b, a
Rect :: struct {
	x0, y0, x1, y1: float32;
}

Axis :: enum u8 {
	X;
	Y;
}

Key :: u64;

Size_Kind :: enum u8 {
	None;
	Pixels;
	Text_Content;
	Percent_Of_Parent;
	Children_Sum;
	Fill; // takes the space its siblings leave along the parent's layout axis
}

Size :: struct {
	kind: Size_Kind;
	value: float32;
	strictness: float32; // 1 = never shrink, 0 = shrink freely when parent overflows
}

px :: (v: float32, strictness: float32 = 1) -> Size { return .{.Pixels, v, strictness}; }
pct :: (v: float32, strictness: float32 = 0) -> Size { return .{.Percent_Of_Parent, v, strictness}; }
text_size :: (pad: float32 = 0, strictness: float32 = 1) -> Size { return .{.Text_Content, pad, strictness}; }
children :: (strictness: float32 = 1) -> Size { return .{.Children_Sum, 0, strictness}; }
fill :: () -> Size { return .{.Fill, 1, 0}; }

Box_Flag :: enum_flags u32 {
	Clickable;
	Scroll_X;
	Scroll_Y;
	Clip;
	Draw_Background;
	Draw_Border;
	Draw_Text;
	Draw_Shadow;
	Floating_X;
	Floating_Y;
	Anchor_End_Y; // with Floating_Y: fixed_pos.y is the distance from the parent's bottom edge to this box's bottom
	Hot_Animation;
	Active_Animation;
	Focusable;
	Selectable_Text; // participates in the global (cross-box) text selection
	Wrap_Text;
	Overlay; // drawn after all normal boxes (popups, tooltips)
	Disabled;
	Keyboard_Clickable;
	Pinned; // floating box that stays put while its parent scrolls (scrollbars)
	Click_On_Release; // clicked on mouse-up over it, not on press: drag sources, resize handles, destructive actions
}
Box_Flags :: Box_Flag;

Align :: enum u8 {
	Start;
	Center;
	End;
}

Text_Align :: enum u8 {
	Left;
	Center;
	Right;
}

Style :: struct {
	bg: Color;
	bg_hot: Color; // used with Hot_Animation; zero = bg
	bg_active: Color;
	text_color: Color;
	border_color: Color;
	border: float32;
	radius: [4]float32;
	font: Font;
	font_size: float32;
	line_height: float32; // points; 0 = font default
	padding: Vec2; // inner text padding x,y
	text_align: Text_Align;
	shadow_color: Color;
	shadow_offset: Vec2;
	shadow_blur: float32;
	child_gap: float32;
}

Font :: u32;

Custom_Draw :: #type (b: *Box, user: *void);

Box :: struct {
	// tree links, rebuilt each frame
	first, last, next, prev, parent: *Box;
	child_count: int;
	// hash links
	hash_next: *Box;
	key: Key;
	last_frame_touched: u64;
	first_frame_touched: u64;

	// per-frame declaration
	flags: Box_Flags;
	semantic_size: [2]Size; // per Axis
	layout_axis: Axis;
	fixed_pos: Vec2; // for floating boxes, relative to parent
	text: string;
	style: Style;
	custom_draw: Custom_Draw;
	custom_user: *void;
	hover_cursor: Cursor;
	opacity: float32;

	// layout outputs
	fixed_size: Vec2;
	rel_pos: Vec2;
	rect: Rect;
	text_layout: *Text_Layout;
	prev_layout: *Text_Layout; // last frame's layout (its arena lives until the next begin); for hit testing spans while declaring
	spans: []Span; // rich text; text must be their concatenation (see set_spans)

	// persistent state
	hot_t, active_t, appear_t: float32;
	view_off, view_off_target: Vec2;
	content_size: Vec2;
	user_t: float32; // free animation slot for app code (animate it yourself)
	cross_align: Align; // where children sit on the axis perpendicular to layout_axis
	sel_order: u64; // reading order for Selectable_Text; 0 = declaration order
	sel_sub: u32; // tiebreak within sel_order (block index in a message)
	sel_join: string; // copied before this box when the selection continues from an earlier one; "" = newline
	scrollbar: Scrollbar_Kind; // a Scroll_Y box's scrollbar, declared when it is popped as a parent
	bar_inset_bottom: float32; // its track stops this far above the box's bottom (content floating over it)
	// on a scrollbar box: where the thumb was grabbed, page direction (0 = dragging), time to the next page
	is_scrollbar: bool;
	bar_grab, bar_page, bar_wait, bar_off: float32;
	bar_content: float32; // content height when the thumb was grabbed: kept until it is let go
	bar_seen: float64; // last time the scrollbar was in use (scrolled, hovered, held); it fades after
}

// The official client's two webkit scrollbars (scroller CSS: .thin, .auto). Thin hides until its
// scroller is hovered (.fade).
Scrollbar_Kind :: enum u8 {
	Thin;
	Auto;
	None;
}

Cursor :: enum u8 {
	Default;
	Pointer;
	IBeam;
	Resize_H;
	Resize_V;
}

Mouse_Button :: enum u8 {
	Left;
	Right;
	Middle;
	X1; // back
	X2; // forward
}

Mod :: enum_flags u8 {
	Shift;
	Ctrl;
	Alt;
	Cmd;
}
Mods :: Mod;

Key_Code :: enum u16 {
	None;
	Enter;
	Escape;
	Backspace;
	Delete;
	Tab;
	Left;
	Right;
	Up;
	Down;
	Home;
	End;
	Page_Up;
	Page_Down;
	A;
	C;
	V;
	X;
	Y;
	Z;
	K;
	F;
	M;
	D;
	E;
	G;
	S;
	U;
	B;
	I;
	P;
	Slash;
	Left_Bracket;
	Right_Bracket;
	Equals;
	Minus;
	N0;
	Other;
}

Input_Event_Kind :: enum u8 {
	Mouse_Move;
	Mouse_Down;
	Mouse_Up;
	Scroll;
	Key_Down;
	Text;
}

Input_Event :: struct {
	kind: Input_Event_Kind;
	pos: Vec2;
	delta: Vec2;
	button: Mouse_Button;
	click_count: int;
	key: Key_Code;
	mods: Mods;
	text: string;
	consumed: bool;
}

Signal :: struct {
	box: *Box;
	hovering: bool; // mouse is over this box and nothing above it
	pressed: bool; // mouse went down on it this frame
	released: bool; // only with .Click_On_Release
	clicked: bool; // pressed, or with .Click_On_Release down and up on it
	double_clicked: bool;
	right_clicked: bool;
	dragging: bool; // is the active box
	mouse: Vec2;
	drag_delta: Vec2;
	keyboard_click: bool;
}

// Draw commands are what the app renders. Clip pushes nest.
Draw_Kind :: enum u8 {
	Rect;
	Text;
	Clip_Push;
	Clip_Pop;
	Custom;
}

Draw_Cmd :: struct {
	kind: Draw_Kind;
	rect: Rect;
	colors: [4]Color;
	radii: [4]float32;
	border: float32;
	softness: float32;
	layout: *Text_Layout;
	origin: Vec2;
	box: *Box;
}

// The backend shapes text. Glyph advances plus clusters let context.ui do wrapping,
// hit-testing and caret placement itself.
Shaped_Glyph :: struct {
	x, advance: float32; // x relative to run start
	cluster_start, cluster_end: int; // UTF-8 byte range in the source text
	handle: u64; // opaque to context.ui, passed back to the app at draw time
	span: s32; // rich text: index of the span this glyph came from
}

Shaped_Run :: struct {
	glyphs: []Shaped_Glyph;
	width: float32;
	ascent: float32;
	descent: float32;
	line_h: float32;
	handle: *void; // backend's run, for drawing
}

Backend :: struct {
	shape: (font: Font, size: float32, text: string) -> Shaped_Run; // result must stay valid for the frame
	// optional: plain text with inline objects (emoji) as spans; none = shape as plain text
	split: (font: Font, size: float32, text: string) -> []Span;
}

// Work done by the last pass (begin to end). Deterministic for a given input, so benchmarks can
// guard against regressions with them where timings are too noisy.
Stats :: struct {
	boxes: int;
	keyed_boxes: int;
	text_layouts: int; // layout_text / layout_rich calls
	shape_calls: int; // backend.shape calls
	glyphs: int; // glyphs laid out
	draw_cmds: int;
	arena_bytes: int; // frame arena in use
}

State :: struct {
	stats: Stats;
	backend: Backend;
	frame: u64;
	dt: float32;
	time: float64;
	wake_at: float64; // a frame is wanted at this time (0: none); reset by begin
	arenas: [2]Flat_Pool;
	frame_alloc: Allocator;
	table: []*Box;
	free_list: *Box;
	root: *Box;
	parents: [..]*Box;
	style_stack: [..]Style;
	seed_stack: [..]Key;
	order: [..]*Box; // declaration order, for event routing and drawing
	draw: [..]Draw_Cmd;
	window: Vec2;

	// interaction
	mouse: Vec2;
	mouse_prev: Vec2;
	mouse_down: [5]bool; // per Mouse_Button
	press_pos: Vec2;
	swallow_up: bool; // a press already clicked; its release goes to nothing else
	events: [..]Input_Event;
	hot: Key; // the topmost hovered clickable box, decided at end of previous frame
	active: Key; // box that received mouse down
	focus: Key; // keyboard focus
	next_hot: Key;
	cursor: Cursor;
	span_cursor: Cursor; // a link or mention under the mouse in selectable text: wins over the I-beam unless dragging
	animating: bool;
	instant_scroll: bool; // scroll boxes jump to their target instead of easing
	overlay_under_mouse: bool; // last frame's overlay (popout, modal, menu) covers the mouse
	animating_loc: Source_Code_Location; // last animate() still in motion (debugging idle wakeups)
	scroll_consumed: bool;
	// Middle-click autoscroll: the scroll box it drives (0 = off), where it was clicked, and whether the
	// box was declared last frame (a box that went away ends it).
	autoscroll: Key;
	autoscroll_anchor: Vec2;
	autoscroll_seen: bool;
	selection: Selection;
	selection_color: Color;
	scrollbar_thin_thumb, scrollbar_auto_thumb, scrollbar_auto_track: Color; // set by the app from its theme
	selectables: [..]*Box; // Selectable_Text boxes in reading order this frame
	prev_selectables: [..]Key;
}

#add_context ui: *State;

init :: (s: *State, backend: Backend) {
	context.ui = s;
	s.backend = backend;
	s.selection_color = .{0.2, 0.45, 0.95, 0.45};
	s.table = NewArray(4096, *Box);
}

shutdown :: (s: *State) {
	free_chain :: (first: *Box) {
		b := first;
		while b {
			next := b.hash_next;
			free(b);
			b = next;
		}
	}
	for s.table free_chain(it);
	free_chain(s.free_list);
	array_free(s.table);
	fini(*s.arenas[0]);
	fini(*s.arenas[1]);
	array_free(s.parents);
	array_free(s.style_stack);
	array_free(s.seed_stack);
	array_free(s.order);
	array_free(s.draw);
	array_free(s.events);
	array_free(s.selectables);
	array_free(s.prev_selectables);
	if context.ui == s context.ui = null;
	s.* = .{}; // no dangling free list / table for a later init
}

// Begin a frame. events are borrowed for the frame.
begin :: (window: Vec2, dt: float32, time: float64, events: []Input_Event) {
	s := context.ui;
	s.mouse_prev = s.mouse;
	s.wake_at = 0;
	s.events.count = 0;
	if s.autoscroll && !s.autoscroll_seen s.autoscroll = 0;
	s.autoscroll_seen = false;
	for e: events {
		array_add(*s.events, e);
		// Any click or Escape ends autoscroll, and does nothing else.
		if s.autoscroll && (e.kind == .Mouse_Down || (e.kind == .Key_Down && e.key == .Escape)) {
			s.autoscroll = 0;
			s.events[s.events.count - 1].consumed = true;
			if e.kind == .Mouse_Down s.swallow_up = true;
			continue;
		}
		if e.kind == {
			case .Mouse_Move;
				s.mouse = e.pos;
			case .Mouse_Down;
				s.mouse = e.pos;
				s.mouse_down[e.button] = true;
				s.press_pos = e.pos;
				if e.button == .Left s.swallow_up = false;
			case .Mouse_Up;
				s.mouse = e.pos;
				s.mouse_down[e.button] = false;
				// The pressed box may be gone (a menu item closed its menu), so its release
				// would otherwise land on whatever is now under the mouse.
				if e.button == .Left && s.swallow_up {
					s.events[s.events.count - 1].consumed = true;
					s.swallow_up = false;
				}
		}
	}
	// The hot box is whatever was topmost under the mouse in last frame's
	// layout; last frame's boxes (and their arena) are still alive here.
	{
		prof.zone("ui.hit_test");
		s.hot = hit_test_prev(s.mouse);
		s.overlay_under_mouse = overlay_at(s.mouse);
	}

	s.stats = .{};
	s.frame += 1;
	s.dt = dt;
	s.time = time;
	s.window = window;
	// Two arenas: anonymous boxes from frame N-1 must survive into frame N's hit test.
	// Reset keeps the pages for reuse.
	pool := *s.arenas[s.frame % 2];
	reset(pool);
	s.frame_alloc = .{flat_pool_allocator_proc, pool};
	s.parents.count = 0;
	s.style_stack.count = 0;
	s.seed_stack.count = 0;
	s.order.count = 0;
	s.draw.count = 0;
	s.selectables.count = 0;
	s.animating = false;
	s.scroll_consumed = false;
	s.cursor = .Default;
	s.span_cursor = .Default;

	array_add(*s.style_stack, default_style());
	root := box_make_key(1, 0);
	root.semantic_size = .[px(window.x), px(window.y)];
	root.layout_axis = .Y;
	root.rect = .{0, 0, window.x, window.y};
	s.root = root;
	array_add(*s.parents, root);
}

default_style :: () -> Style {
	return .{text_color = .{1, 1, 1, 1}, font_size = 16};
}

// End the frame: lay out, run selection, emit draw commands, prune stale boxes.
end :: () -> []Draw_Cmd {
	s := context.ui;
	{
		prof.zone("ui.layout");
		layout(s.root);
	}
	{
		prof.zone("ui.selection");
		update_selection();
	}
	{
		prof.zone("ui.emit_draw");
		emit_draw(s.root, false);
		emit_overlays(s.root);
	}
	{
		prof.zone("ui.prune");
		prune();
	}
	s.stats.boxes = s.order.count;
	s.stats.draw_cmds = s.draw.count;
	a := *s.arenas[s.frame % 2];
	if a.memory_base s.stats.arena_bytes = a.current_point - a.memory_base;
	// Unhandled mouse-up clears active.
	for s.events if it.kind == .Mouse_Up && it.button == .Left s.active = 0;
	if s.active != 0 && !s.mouse_down[Mouse_Button.Left] s.active = 0;
	return s.draw;
}

//////////////////////////////////////////////////////////////////////////////
// keys and the box cache

key_from_string :: (str: string, seed: Key) -> Key {
	// "label##id": hash only the part after ##, display the part before.
	// "label###id": same, but ignore the seed so the key is global.
	hashed := str;
	h := seed;
	if find_index_from_left(str, #char "#") >= 0 { // String's substring search is slow; most keys have no #
		i := find_index_from_left(str, "###");
		if i >= 0 {
			hashed = advance(str, i + 3);
			h = FNV_64_OFFSET_BIAS;
		} else {
			j := find_index_from_left(str, "##");
			if j >= 0 hashed = advance(str, j + 2);
		}
	}
	h = fnv1a_hash(hashed.data, hashed.count, h);
	if h == 0 || h == 1 h += 2;
	return h;
}

display_part :: (str: string) -> string {
	if find_index_from_left(str, #char "#") < 0 return str;
	i := find_index_from_left(str, "##");
	return ifx i >= 0 then slice(str, 0, i) else str;
}

key_from_int :: (v: u64, seed: Key) -> Key {
	b := v;
	h := fnv1a_hash(*b, size_of(u64), seed); // byte-wise, little endian
	if h == 0 || h == 1 h += 2;
	return h;
}

current_seed :: () -> Key {
	s := context.ui;
	if s.seed_stack.count return peek(s.seed_stack);
	if s.parents.count return top_parent().key;
	return 0;
}

box_lookup :: (k: Key) -> *Box {
	if k == 0 return null;
	s := context.ui;
	b := s.table[k % cast(u64) s.table.count];
	while b {
		if b.key == k return b;
		b = b.hash_next;
	}
	return null;
}

// Create (or fetch) a box for this frame.
box :: (str: string, flags: Box_Flags = 0) -> *Box {
	b := ifx str == "" then box_make_anon(flags) else box_make_key(key_from_string(str, current_seed()), flags);
	b.text = display_part(str);
	return b;
}

box_k :: (k: Key, flags: Box_Flags = 0) -> *Box { return box_make_key(k, flags); }

//////////////////////////////////////////////////////////////////////////////
// stacks

top_parent :: () -> *Box { return peek(context.ui.parents); }
top_style :: () -> Style { return peek(context.ui.style_stack); }

push_parent :: (b: *Box) { array_add(*context.ui.parents, b); }
pop_parent :: () {
	b := pop(*context.ui.parents);
	if (b.flags & .Scroll_Y) && b.scrollbar != .None && b.key != 0 {
		push_parent(b);
		scrollbar(b, b.scrollbar, *b.view_off.y, *b.view_off_target.y, b.content_size.y);
		pop(*context.ui.parents);
	}
}

parent :: (b: *Box) -> bool {
	push_parent(b);
	return true;
}

push_style :: (st: Style) { array_add(*context.ui.style_stack, st); }
pop_style :: () { pop(*context.ui.style_stack); }

// Scoped style edit: `if ui.styled() { ui.st().bg = ...; ... }` or use the helpers below.
styled :: () -> bool {
	push_style(top_style());
	return true;
}

// Mutable reference to the current style; edits affect boxes declared after.
st :: () -> *Style { return peek_pointer(context.ui.style_stack); }

push_seed :: (k: Key) { array_add(*context.ui.seed_stack, k); }
pop_seed :: () { pop(*context.ui.seed_stack); }

id_scope :: (v: u64) -> bool {
	push_seed(key_from_int(v, current_seed()));
	return true;
}

//////////////////////////////////////////////////////////////////////////////
// interaction

intersect :: (a: Rect, b: Rect) -> Rect {
	return .{max(a.x0, b.x0), max(a.y0, b.y0), min(a.x1, b.x1), min(a.y1, b.y1)};
}

// Clip rect a box is visible within, from last frame's layout.
visible_rect :: (b: *Box) -> Rect {
	r := b.rect;
	p := b.parent;
	while p {
		if p.flags & .Clip r = intersect(r, p.rect);
		p = p.parent;
	}
	return r;
}

// The clickable box a press at p goes to, against the most recently laid-out
// boxes (after end(): this frame's; tests use it to find reachable controls).
hit_box :: (p: Vec2) -> Key { return hit_test_prev(p); }

// Does any box of last frame's overlay layer (popups, modals) contain p?
overlay_at :: (p: Vec2) -> bool {
	for context.ui.order if (it.flags & .Overlay) && contains(it.rect, p) return true;
	return false;
}

in_overlay :: (b: *Box) -> bool {
	x := b;
	while x {
		if x.flags & .Overlay return true;
		x = x.parent;
	}
	return false;
}

// Is the mouse over this box's last-frame rect (ignoring occlusion)?
mouse_over :: (b: *Box) -> bool {
	if context.ui.overlay_under_mouse && !in_overlay(b) return false;
	return contains(visible_rect(b), context.ui.mouse);
}

signal :: (b: *Box) -> Signal {
	s := context.ui;
	sig := Signal.{box = b, mouse = s.mouse};
	if b.key == 0 return sig;
	clickable := (b.flags & .Clickable) != 0;
	sig.hovering = s.hot == b.key;
	if sig.hovering && b.hover_cursor != .Default s.cursor = b.hover_cursor;
	if sig.hovering && clickable && b.hover_cursor == .Default s.cursor = .Pointer;
	if clickable {
		for * e: s.events {
			if e.consumed continue;
			if e.kind == {
				case .Mouse_Down;
					if sig.hovering {
						if e.button == .Left {
							s.active = b.key;
							sig.pressed = true;
							if (b.flags & .Click_On_Release) == 0 {
								sig.clicked = true;
								s.swallow_up = true;
							}
							if e.click_count == 2 sig.double_clicked = true;
							if b.flags & .Focusable s.focus = b.key;
						} else if e.button == .Right {
							sig.right_clicked = true;
						}
						e.consumed = true;
					}
				case .Mouse_Up;
					if e.button == .Left && s.active == b.key {
						sig.released = true;
						if (b.flags & .Click_On_Release) && contains(visible_rect(b), e.pos) sig.clicked = true;
						s.swallow_up = false;
						s.active = 0;
						e.consumed = true;
					}
				case .Key_Down;
					if (b.flags & .Keyboard_Clickable) && s.focus == b.key && e.key == .Enter {
						sig.clicked = true;
						sig.keyboard_click = true;
						e.consumed = true;
					}
			}
		}
	}
	sig.dragging = s.active == b.key;
	if sig.dragging sig.drag_delta = s.mouse - s.press_pos;

	// scrolling: the innermost scrollable under the mouse takes the wheel and a middle click (autoscroll);
	// one behind an open overlay doesn't
	if (b.flags & SCROLL) && !s.scroll_consumed && mouse_over(b) {
		for * e: s.events {
			if e.kind != .Scroll || e.consumed continue;
			if b.flags & .Scroll_Y b.view_off_target.y -= e.delta.y;
			if b.flags & .Scroll_X b.view_off_target.x -= e.delta.x;
			e.consumed = true;
		}
	}
	if b.flags & .Scroll_Y b.view_off_target.y += autoscroll_step(b);
	return sig;
}

is_focused :: (b: *Box) -> bool { return b.key != 0 && context.ui.focus == b.key; }
set_focus :: (b: *Box) { context.ui.focus = b.key; }

// Frame-rate independent exponential approach. rate is ~1/seconds to settle.
animate :: (v: *float32, target: float32, rate: float32 = 18, loc := #caller_location) {
	s := context.ui;
	if abs(v.* - target) < 0.001 {
		v.* = target;
		return;
	}
	v.* += (target - v.*) * (1 - pow(2.0, -rate * s.dt));
	if abs(v.* - target) < 0.001 {
		v.* = target;
	} else {
		s.animating = true;
		s.animating_loc = loc;
	}
}

//////////////////////////////////////////////////////////////////////////////
// drawing

lerp_color :: (a: Color, b: Color, t: float32) -> Color { return a + (b - a) * t; }

//////////////////////////////////////////////////////////////////////////////
// list windows: declare only the rows of a long list that can be on screen

List_Window :: struct {
	first, last: int; // declare rows [first, last)
	n: int;
	pitch: float32;
}

// For n rows `pitch` apart (gaps included) in the scrolling box `scroll`: declares a spacer standing
// in for the rows above the window and returns the rows that may be visible this frame, at the
// current scroll offset or anywhere it is animating to, plus `margin` rows each side. Declare those
// rows, then call list_window_end. Call it where the first row would go, after signal(scroll)
// so this frame's wheel input is counted, in a parent with no child_gap.
list_window :: (scroll: *Box, pitch: float32, n: int, margin := 2, id := "list_window") -> List_Window {
	w := List_Window.{n = n, pitch = pitch};
	top_box := box_make_key(key_from_string(id, current_seed()), 0);
	// Where the rows started in the scroll content, from last frame's layout. A new box has no rect
	// yet: assume the rows start at the top, which can only make the window larger.
	top: float32;
	if top_box.first_frame_touched != context.ui.frame top = top_box.rect.y0 - scroll.rect.y0 + scroll.view_off.y;
	h := scroll.rect.y1 - scroll.rect.y0;
	if h <= 0 h = context.ui.window.y;
	y0 := min(scroll.view_off.y, scroll.view_off_target.y) - top;
	y1 := max(scroll.view_off.y, scroll.view_off_target.y) + h - top;
	if pitch <= 0 {
		w.last = n;
	} else {
		w.first = clamp(cast(int) floor(y0 / pitch) - margin, 0, n);
		w.last = clamp(cast(int) ceil(y1 / pitch) + margin, w.first, n);
	}
	top_box.semantic_size = .[px(0), px(w.first * pitch)];
	return w;
}

list_window_end :: (w: List_Window) {
	b := box_make_anon(0);
	b.semantic_size = .[px(0), px((w.n - w.last) * w.pitch)];
}

// Was b out of view last frame (outside a clipping ancestor by more than margin), with room for the
// scrolling still pending? A caller may then declare b at its size but without its contents: it
// stays keyed and laid out, and the frame it can come into view it is declared in full again.
// Boxes new this frame, or under a new clipping ancestor, are never offscreen.
offscreen :: (b: *Box, margin: float32 = 64) -> bool {
	if b.first_frame_touched == context.ui.frame return false;
	r := b.rect;
	if r.x1 <= r.x0 && r.y1 <= r.y0 return false;
	m := Vec2.{margin, margin};
	p := b.parent;
	while p {
		if p.first_frame_touched == context.ui.frame && (p.flags & .Clip) return false;
		if p.flags & SCROLL m += .{abs(p.view_off_target.x - p.view_off.x), abs(p.view_off_target.y - p.view_off.y)};
		p = p.parent;
	}
	p = b.parent;
	while p {
		c := p.rect;
		if (p.flags & .Clip) && (r.y1 < c.y0 - m.y || r.y0 > c.y1 + m.y || r.x1 < c.x0 - m.x || r.x0 > c.x1 + m.x) return true;
		p = p.parent;
	}
	return false;
}

// Declares, as the last child of the current parent, the scrollbar of `host`, a vertically scrolling
// area: off/target are its scroll offset and where it is animating to, from the top (from the bottom
// with from_end), content the scrolled height. Uses host's last-frame rect. Scroll_Y boxes get theirs
// from pop_parent; areas that scroll by hand call this inside their host box. Webkit geometry (Chrome
// on the official client's scroller CSS): thin 8px wide, thumb inset 2px; auto 16px, track and thumb
// inset 4px; thumb at least 40px. Pressing the track pages by 87.5% of the view (Chrome's
// kMinFractionToStepWhenPaging), repeating while held until the thumb reaches the mouse.
scrollbar :: (host: *Box, kind: Scrollbar_Kind, off: *float32, target: *float32, content_now: float32, from_end := false) {
	s := context.ui;
	r := host.rect;
	view := r.y1 - r.y0;
	track := view - host.bar_inset_bottom;
	content := content_now;
	max_off := content - view;
	if kind == .None || track <= 0 || max_off < 1 return;
	W: float32 = ifx kind == .Auto then 16.0 else 8.0;
	inset: float32 = ifx kind == .Auto then 4.0 else 2.0;
	bar := box_make_key(key_from_int(0x5c5011ba, host.key), .Clickable | .Floating_X | .Floating_Y);
	// While the thumb is dragged the mapping uses the content height from the grab: rows
	// measured or history loaded mid-drag would otherwise move the thumb away from the
	// pointer. The new height applies on release (the client's scroller does the same).
	if s.active == bar.key && s.mouse_down[Mouse_Button.Left] && bar.bar_page == 0 && bar.bar_content > view {
		content = bar.bar_content;
		max_off = content - view;
	} else {
		bar.bar_content = content;
	}
	if host.flags & SCROLL bar.flags |= .Pinned;
	bar.is_scrollbar = true;
	bar.semantic_size = .[px(W), px(track)];
	bar.fixed_pos = .{r.x1 - r.x0 - W, 0};

	thumb_h := min(track, max(40.0, track * view / content));
	travel := track - thumb_h;
	// offsets below are from the top; set() writes them back in the caller's direction
	to_top :: (v: float32, max_off: float32, from_end: bool) -> float32 { return clamp(ifx from_end then max_off - v else v, 0, max_off); }
	set :: (v: float32, now: bool, off: *float32, target: *float32, max_off: float32, from_end: bool) {
		target.* = to_top(clamp(v, 0, max_off), max_off, from_end); // the mapping is its own inverse
		if now off.* = target.*;
	}
	top := to_top(off.*, max_off, from_end);
	ty := travel * top / max_off;
	page_step := view * 0.875;
	for * e: s.events {
		if e.consumed || e.kind != .Mouse_Down || e.button != .Left || s.hot != bar.key continue;
		y := e.pos.y - r.y0;
		s.active = bar.key;
		e.consumed = true;
		if y >= ty && y < ty + thumb_h {
			bar.bar_page = 0;
			bar.bar_grab = y - ty;
		} else {
			bar.bar_page = ifx y < ty then -1.0 else 1.0;
			bar.bar_wait = 0.25; // Chrome's initial autoscroll delay, then every 50 ms
			set(to_top(target.*, max_off, from_end) + bar.bar_page * page_step, false, off, target, max_off, from_end);
		}
	}
	held := s.active == bar.key && s.mouse_down[Mouse_Button.Left];
	if held && bar.bar_page == 0 {
		if travel > 0 set((s.mouse.y - r.y0 - bar.bar_grab) / travel * max_off, true, off, target, max_off, from_end);
	} else if held {
		bar.bar_wait -= s.dt;
		s.animating = true;
		y := s.mouse.y - r.y0;
		reached := ifx bar.bar_page < 0 then y >= ty else y < ty + thumb_h;
		if bar.bar_wait <= 0 && !reached {
			set(to_top(target.*, max_off, from_end) + bar.bar_page * page_step, false, off, target, max_off, from_end);
			bar.bar_wait = 0.05;
		}
	}

	// Shown while in use, then faded out (overlay-scrollbar style): scrolling, holding it,
	// the pointer over its strip, and for thin scrollers the pointer over the scroller.
	if bar.bar_seen == 0 { bar.bar_seen = -100; bar.bar_off = off.*; }
	over_strip := s.mouse.x >= r.x1 - W && s.mouse.x < r.x1 && s.mouse.y >= r.y0 && s.mouse.y < r.y0 + track;
	// hovering shows it only while hovered; scrolling and dragging leave it up a moment
	hovered := over_strip || (kind == .Thin && mouse_over(host));
	if held || abs(off.* - bar.bar_off) > 0.5 || abs(off.* - target.*) > 0.5 bar.bar_seen = s.time;
	bar.bar_off = off.*;
	LINGER :: 1.0;
	FADE :: 0.25;
	age := s.time - bar.bar_seen;
	if hovered age = 0;
	else if age >= LINGER + FADE return;
	alpha: float32 = 1;
	if age >= LINGER {
		alpha = cast(float32) (1 - (age - LINGER) / FADE);
		s.animating = true;
	} else if !hovered {
		if s.wake_at == 0 || bar.bar_seen + LINGER < s.wake_at s.wake_at = bar.bar_seen + LINGER;
	}
	push_parent(bar);
	if kind == .Auto && s.scrollbar_auto_track.w > 0 {
		t := box_make_anon(.Draw_Background | .Floating_X | .Floating_Y);
		t.semantic_size = .[px(W - 2 * inset), px(track - 2 * inset)];
		t.fixed_pos = .{inset, inset};
		t.style.bg = s.scrollbar_auto_track;
		t.style.bg.w *= alpha;
		t.style.radius = .[W / 2 - inset, W / 2 - inset, W / 2 - inset, W / 2 - inset];
	}
	th := box_make_anon(.Draw_Background | .Floating_X | .Floating_Y);
	th.semantic_size = .[px(W - 2 * inset), px(thumb_h - 2 * inset)];
	th.fixed_pos = .{inset, ty + inset};
	th.style.bg = ifx kind == .Auto then s.scrollbar_auto_thumb else s.scrollbar_thin_thumb;
	th.style.bg.w *= alpha;
	rad := W / 2 - inset;
	th.style.radius = .[rad, rad, rad, rad];
	pop(*s.parents);
}

// Has any box requested another frame (animation, smooth scroll)?
needs_frame :: () -> bool { return context.ui.animating; }
cursor :: () -> Cursor { return ifx context.ui.autoscroll then .Resize_V else context.ui.cursor; }

// Middle-click autoscroll, as browsers do on Windows, for a box that scrolls vertically (Scroll_Y boxes get
// it in signal; lists that scroll themselves call it): a middle click over b drops the anchor, and while it
// runs this returns how far to scroll this frame (points, + = down), faster the farther the mouse is
// above or below the anchor. Any click or Escape ends it (begin).
autoscroll_step :: (b: *Box) -> float32 {
	s := context.ui;
	if !b.key return 0;
	if !s.autoscroll && !s.scroll_consumed && mouse_over(b) {
		for * e: s.events if !e.consumed && e.kind == .Mouse_Down && e.button == .Middle {
			s.autoscroll, s.autoscroll_anchor = b.key, e.pos;
			e.consumed = true;
			break;
		}
	}
	if s.autoscroll != b.key return 0;
	s.autoscroll_seen = true;
	s.animating = true;
	dy := s.mouse.y - s.autoscroll_anchor.y;
	DEAD :: 12;
	if abs(dy) <= DEAD return 0;
	return (dy - ifx dy > 0 then DEAD else -DEAD) * 8 * s.dt;
}

// Where a middle click started autoscroll (the app draws its marker there); false when it is off.
autoscroll_anchor :: () -> Vec2, bool { return context.ui.autoscroll_anchor, context.ui.autoscroll != 0; }

// Concatenates span texts into the box text so selection/copy see them.
// The spans are copied, so callers may pass slice literals.
set_spans :: (b: *Box, spans: []Span) {
	b.spans = array_copy(spans,, context.ui.frame_alloc);
	b.text = concat_spans(spans);
	b.flags |= .Draw_Text;
}

#scope_module

SCROLL :: Box_Flag.Scroll_X | .Scroll_Y;

// `for c: each_child(b)` walks b's children in order.
Children :: struct { b: *Box; }
each_child :: (b: *Box) -> Children { return .{b}; }
for_expansion :: (ch: *Children, body: Code, flags: For_Flags) #expand {
	next := ch.b.first;
	while next {
		`it := next;
		`it_index := 0;
		next = next.next;
		#insert body;
	}
}

contains :: (r: Rect, p: Vec2) -> bool {
	return p.x >= r.x0 && p.x < r.x1 && p.y >= r.y0 && p.y < r.y1;
}

link_box :: (b: *Box) {
	s := context.ui;
	if s.parents.count {
		p := top_parent();
		b.parent = p;
		if p.last {
			p.last.next = b;
			b.prev = p.last;
		} else {
			p.first = b;
		}
		p.last = b;
		p.child_count += 1;
	}
	array_add(*s.order, b);
}

box_make_key :: (k: Key, flags: Box_Flags) -> *Box {
	s := context.ui;
	b := box_lookup(k);
	// Duplicate key this frame: fall back to an anonymous box so the tree stays sane.
	if b && b.last_frame_touched == s.frame return box_make_anon(flags);
	if !b {
		if s.free_list {
			b = s.free_list;
			s.free_list = b.hash_next;
			b.* = .{};
		} else {
			b = New(Box);
		}
		b.key = k;
		b.first_frame_touched = s.frame;
		slot := *s.table[k % cast(u64) s.table.count];
		b.hash_next = slot.*;
		slot.* = b;
	}
	s.stats.keyed_boxes += 1;
	b.first, b.last, b.next, b.prev, b.parent = null, null, null, null, null;
	b.child_count = 0;
	// A box skipped for a frame or more holds a layout from a frame arena that has since been reset.
	if b.last_frame_touched + 1 != s.frame b.text_layout = null;
	b.last_frame_touched = s.frame;
	b.flags = flags;
	b.text = "";
	b.custom_draw = null;
	b.custom_user = null;
	b.bar_inset_bottom = 0;
	b.hover_cursor = .Default;
	b.opacity = 1;
	b.style = top_style();
	b.semantic_size = .[.{}, .{}];
	b.prev_layout = b.text_layout;
	b.text_layout = null;
	b.spans = .[];
	b.fixed_pos = .{};
	b.layout_axis = .Y;
	b.sel_order = 0;
	b.sel_sub = 0;
	b.sel_join = "";
	b.cross_align = .Start;
	b.scrollbar = .Thin;
	b.is_scrollbar = false;
	link_box(b);
	return b;
}

box_make_anon :: (flags: Box_Flags) -> *Box {
	s := context.ui;
	b := New(Box,, s.frame_alloc);
	b.first_frame_touched = s.frame;
	b.last_frame_touched = s.frame;
	b.flags = flags;
	b.style = top_style();
	b.opacity = 1;
	link_box(b);
	return b;
}

prune :: () {
	s := context.ui;
	for * slot: s.table {
		prev := slot;
		b := slot.*;
		while b {
			next := b.hash_next;
			if b.last_frame_touched + 1 < s.frame {
				prev.* = next;
				b.hash_next = s.free_list;
				s.free_list = b;
			} else {
				prev = *b.hash_next;
			}
			b = next;
		}
	}
}

// Hit test against the previous frame's boxes; overlays win, later boxes win.
hit_test_prev :: (p: Vec2) -> Key {
	best: Key;
	best_overlay := false;
	for b: context.ui.order { // order still holds last frame's boxes at this point
		if b.key == 0 || !(b.flags & .Clickable) || (b.flags & .Disabled) continue;
		ov := in_overlay(b);
		if best_overlay && !ov continue;
		if contains(visible_rect(b), p) {
			best = b.key;
			best_overlay = ov;
		}
	}
	return best;
}

// Hot/active/appear animations are updated as boxes are laid out.
update_anims :: (b: *Box) {
	s := context.ui;
	if b.key == 0 return;
	if b.flags & .Hot_Animation animate(*b.hot_t, ifx s.hot == b.key then 1.0 else 0.0, 30);
	if b.flags & .Active_Animation animate(*b.active_t, ifx s.active == b.key then 1.0 else 0.0, 40);
	animate(*b.appear_t, 1, 20);
}

//////////////////////////////////////////////////////////////////////////////
// layout

AXES :: Axis.[.X, .Y];

layout :: (root: *Box) {
	for axis: AXES {
		layout_standalone(root, axis);
		layout_upward(root, axis);
		layout_downward(root, axis);
		layout_solve(root, axis);
	}
	layout_position(root);
}

text_layout_for :: (b: *Box, wrap_width: float32) -> *Text_Layout {
	wrap := (b.flags & .Wrap_Text) != 0;
	if b.text_layout && (b.text_layout.wrap_width == wrap_width || !wrap) return b.text_layout;
	ww := ifx wrap then wrap_width else -1;
	if b.spans.count {
		b.text_layout = layout_rich(b.spans, ww, b.style.line_height);
		b.text = b.text_layout.text;
	} else {
		split: []Span;
		if context.ui.backend.split split = context.ui.backend.split(b.style.font, b.style.font_size, b.text);
		if split.count b.text_layout = layout_rich(split, ww, b.style.line_height);
		else b.text_layout = layout_text(b.style.font, b.style.font_size, b.text, ww, b.style.line_height);
	}
	return b.text_layout;
}

layout_standalone :: (b: *Box, axis: Axis) {
	sz := b.semantic_size[axis];
	if sz.kind == {
		case .Pixels;
			b.fixed_size.component[axis] = sz.value;
		case .Text_Content;
			if axis == .X || !(b.flags & .Wrap_Text) {
				tl := text_layout_for(b, -1);
				b.fixed_size.component[axis] = (ifx axis == .X then tl.width else tl.height) + sz.value * 2 + b.style.padding.component[axis] * 2;
			} else {
				// widths are solved by now: measure wrapped text before the Y passes, so
				// parents summing their children see a line added this frame, not last frame's
				// height (a growing composer overlapped the list for a frame)
				tl := text_layout_for(b, b.fixed_size.x - b.style.padding.x * 2);
				b.fixed_size.y = tl.height + b.style.padding.y * 2 + sz.value * 2;
			}
	}
	for c: each_child(b) layout_standalone(c, axis);
}

layout_upward :: (b: *Box, axis: Axis) {
	sz := b.semantic_size[axis];
	if sz.kind == .Percent_Of_Parent {
		p := b.parent;
		while p {
			pk := p.semantic_size[axis].kind;
			if pk == .Pixels || pk == .Percent_Of_Parent || pk == .Fill || pk == .Text_Content {
				b.fixed_size.component[axis] = p.fixed_size.component[axis] * sz.value;
				break;
			}
			p = p.parent;
		}
	}
	for c: each_child(b) layout_upward(c, axis);
}

// Sum (along the layout axis, with gaps) or max (across it) of the non-floating children's sizes.
children_extent :: (b: *Box, axis: Axis) -> float32 {
	sum: float32;
	n := 0;
	for c: each_child(b) {
		if is_floating(c, axis) continue;
		if axis == b.layout_axis {
			sum += c.fixed_size.component[axis];
			n += 1;
		} else {
			sum = max(sum, c.fixed_size.component[axis]);
		}
	}
	if axis == b.layout_axis && n > 1 sum += b.style.child_gap * (n - 1);
	return sum;
}

layout_downward :: (b: *Box, axis: Axis) {
	for c: each_child(b) layout_downward(c, axis);
	if b.semantic_size[axis].kind == .Children_Sum b.fixed_size.component[axis] = children_extent(b, axis);
}

is_floating :: (b: *Box, axis: Axis) -> bool {
	return (b.flags & (ifx axis == .X then Box_Flag.Floating_X else .Floating_Y)) != 0;
}

// Top-down: distribute Fill space, shrink to fix overflow, then recurse.
layout_solve :: (b: *Box, axis: Axis) {
	avail := b.fixed_size.component[axis];
	scrolls := (b.flags & SCROLL) != 0;
	// Percent-of-parent children took b's size in layout_upward, before a Fill b was
	// solved (last frame's size: 0 for a new box, whose wrapped text then broke per
	// character). b's size is final here, so take it again.
	bk := b.semantic_size[axis].kind;
	if bk == .Pixels || bk == .Percent_Of_Parent || bk == .Fill || bk == .Text_Content {
		for c: each_child(b) if c.semantic_size[axis].kind == .Percent_Of_Parent c.fixed_size.component[axis] = avail * c.semantic_size[axis].value;
	}
	if axis == b.layout_axis {
		total: float32;
		fills := 0;
		n := 0;
		for c: each_child(b) {
			if is_floating(c, axis) continue;
			n += 1;
			if c.semantic_size[axis].kind == .Fill fills += 1;
			else total += c.fixed_size.component[axis];
		}
		if n > 1 total += b.style.child_gap * (n - 1);
		if fills > 0 {
			each := max(0.0, (avail - total) / fills);
			for c: each_child(b) if !is_floating(c, axis) && c.semantic_size[axis].kind == .Fill c.fixed_size.component[axis] = each;
		}
		// Overflowing (fills got 0): shrink the rest too, or rows with a filler
		// (headers) pushed their right side out of the window instead.
		if total > avail && !scrolls {
			// Shrink children proportionally to their slack (1 - strictness).
			over := total - avail;
			slack: float32;
			for c: each_child(b) if !is_floating(c, axis) slack += c.fixed_size.component[axis] * (1 - c.semantic_size[axis].strictness);
			if slack > 0 {
				k := min(over / slack, 1);
				for c: each_child(b) {
					if is_floating(c, axis) continue;
					c.fixed_size.component[axis] -= c.fixed_size.component[axis] * (1 - c.semantic_size[axis].strictness) * k;
				}
			}
		}
	} else {
		for c: each_child(b) {
			if is_floating(c, axis) continue;
			size := *c.fixed_size.component[axis];
			if c.semantic_size[axis].kind == .Fill {
				size.* = avail;
			} else if size.* > avail && !scrolls {
				size.* -= (size.* - avail) * (1 - c.semantic_size[axis].strictness);
			}
		}
	}
	// Wrapped text height depends on the now-known width.
	if axis == .Y {
		for c: each_child(b) {
			if (c.flags & .Wrap_Text) && c.semantic_size[Axis.Y].kind == .Text_Content {
				tl := text_layout_for(c, c.fixed_size.x - c.style.padding.x * 2);
				c.fixed_size.y = tl.height + c.style.padding.y * 2 + c.semantic_size[Axis.Y].value * 2;
			}
		}
	}
	for c: each_child(b) layout_solve(c, axis);
	// children sizes may have changed during solve (wrapped text); recompute
	if axis == .Y && b.semantic_size[Axis.Y].kind == .Children_Sum b.fixed_size.y = children_extent(b, .Y);
}

layout_position :: (b: *Box) {
	cursor: float32;
	content: Vec2;
	for c: each_child(b) {
		for axis: AXES {
			pos := *c.rel_pos.component[axis];
			if is_floating(c, axis) {
				pos.* = c.fixed_pos.component[axis];
				if axis == .Y && (c.flags & .Anchor_End_Y) pos.* = b.fixed_size.y - c.fixed_size.y - c.fixed_pos.y;
			} else if axis == b.layout_axis {
				pos.* = cursor;
			} else if b.cross_align == {
				case .Start;  pos.* = 0;
				case .Center; pos.* = (b.fixed_size.component[axis] - c.fixed_size.component[axis]) / 2;
				case .End;    pos.* = b.fixed_size.component[axis] - c.fixed_size.component[axis];
			}
		}
		if !is_floating(c, b.layout_axis) cursor += c.fixed_size.component[b.layout_axis] + b.style.child_gap;
		content.x = max(content.x, c.rel_pos.x + c.fixed_size.x);
		content.y = max(content.y, c.rel_pos.y + c.fixed_size.y);
	}
	b.content_size = content;

	// scroll: clamp target, animate offset
	if b.flags & SCROLL {
		for axis: AXES {
			max_off := max(0.0, content.component[axis] - b.fixed_size.component[axis]);
			b.view_off_target.component[axis] = clamp(b.view_off_target.component[axis], 0, max_off);
			if context.ui.instant_scroll b.view_off.component[axis] = b.view_off_target.component[axis];
			else animate(*b.view_off.component[axis], b.view_off_target.component[axis], 40);
			b.view_off.component[axis] = clamp(b.view_off.component[axis], 0, max_off);
		}
	}

	origin := Vec2.{b.rect.x0, b.rect.y0} - b.view_off;
	for c: each_child(b) {
		p := origin + c.rel_pos;
		if c.flags & .Pinned p += b.view_off;
		c.rect = .{p.x, p.y, p.x + c.fixed_size.x, p.y + c.fixed_size.y};
		update_anims(c);
		layout_position(c);
	}
}

//////////////////////////////////////////////////////////////////////////////
// drawing

draw_rect :: (r: Rect, c: Color, radii := float32.[0, 0, 0, 0], border: float32 = 0, softness: float32 = 0) {
	array_add(*context.ui.draw, .{kind = .Rect, rect = r, colors = .[c, c, c, c], radii = radii, border = border, softness = softness});
}

emit_draw :: (b: *Box, in_overlay_pass: bool) {
	s := context.ui;
	if (b.flags & .Overlay) && !in_overlay_pass return;
	st := *b.style;
	alpha := b.opacity;
	if (b.flags & .Draw_Shadow) && st.shadow_color.w > 0 {
		r := b.rect;
		r.x0 += st.shadow_offset.x;
		r.x1 += st.shadow_offset.x;
		r.y0 += st.shadow_offset.y;
		r.y1 += st.shadow_offset.y;
		c := st.shadow_color;
		c.w *= alpha;
		draw_rect(r, c, st.radius, softness = st.shadow_blur);
	}
	if b.flags & .Draw_Background {
		c := st.bg;
		if (b.flags & .Hot_Animation) && st.bg_hot.w > 0 c = lerp_color(c, st.bg_hot, b.hot_t);
		if (b.flags & .Active_Animation) && st.bg_active.w > 0 c = lerp_color(c, st.bg_active, b.active_t);
		c.w *= alpha;
		if c.w > 0 draw_rect(b.rect, c, st.radius);
	}
	if (b.flags & .Draw_Border) && st.border > 0 {
		c := st.border_color;
		c.w *= alpha;
		draw_rect(b.rect, c, st.radius, st.border);
	}
	if b.custom_draw array_add(*s.draw, .{kind = .Custom, rect = b.rect, box = b});
	if (b.flags & .Draw_Text) && b.text != "" {
		inner_w := b.fixed_size.x - st.padding.x * 2;
		tl := text_layout_for(b, inner_w);
		o := Vec2.{b.rect.x0 + st.padding.x, b.rect.y0 + st.padding.y};
		if st.text_align == .Center o.x += (inner_w - tl.width) / 2;
		else if st.text_align == .Right o.x += inner_w - tl.width;
		// vertically center single-line text
		if !(b.flags & .Wrap_Text) o.y = b.rect.y0 + (b.fixed_size.y - tl.height) / 2;
		tl.origin = o;
		if tl.spans.count draw_span_backgrounds(tl);
		if b.flags & .Selectable_Text draw_selection_highlight(b, tl);
		c := st.text_color;
		c.w *= alpha;
		array_add(*s.draw, .{kind = .Text, layout = tl, origin = o, colors = .[c, c, c, c], box = b});
	}
	clip := (b.flags & .Clip) != 0;
	if clip array_add(*s.draw, .{kind = .Clip_Push, rect = b.rect});
	for c: each_child(b) emit_draw(c, in_overlay_pass);
	if clip array_add(*s.draw, .{kind = .Clip_Pop});
}

emit_overlays :: (b: *Box) {
	for c: each_child(b) {
		if c.flags & .Overlay emit_draw(c, true);
		else emit_overlays(c);
	}
}

draw_span_backgrounds :: (tl: *Text_Layout) {
	g := tl.run.glyphs;
	for l: tl.lines {
		gi := l.glyph_start;
		while gi < l.glyph_end {
			si := g[gi].span;
			start := gi;
			while gi < l.glyph_end && g[gi].span == si gi += 1;
			sp := tl.spans[si];
			if sp.bg.w <= 0 continue;
			x0 := tl.origin.x + g[start].x - l.x_shift;
			x1 := tl.origin.x + g[gi - 1].x + g[gi - 1].advance - l.x_shift;
			y0 := tl.origin.y + l.y;
			rr := sp.bg_radius;
			draw_rect(.{x0 - 2, y0 + 1, x1 + 2, y0 + tl.line_h - 1}, sp.bg, .[rr, rr, rr, rr]);
		}
	}
}

#scope_export
