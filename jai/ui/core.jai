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

px :: (v: float32, strictness: float32 = 1) -> Size {return .{.Pixels, v, strictness};}
pct :: (v: float32, strictness: float32 = 0) -> Size {return .{.Percent_Of_Parent, v, strictness};}
text_size :: (pad: float32 = 0, strictness: float32 = 1) -> Size {return .{.Text_Content, pad, strictness};}
children :: (strictness: float32 = 1) -> Size {return .{.Children_Sum, 0, strictness};}
fill :: () -> Size {return .{.Fill, 1, 0};}

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
	semantic_size: [#run enum_count(Axis)]Size;
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
	sel_join: string; // copied before this box when the selection continues from an earlier one; "" = newline
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
	Left_Bracket;
	Right_Bracket;
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
	released: bool;
	clicked: bool; // down and up on it
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
}

STACK_MAX :: 64;

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
	arenas: [2]mem.Dynamic_Arena;
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
	mouse_down: [#run enum_count(Mouse_Button)]bool;
	press_pos: Vec2;
	events: [..]Input_Event;
	hot: Key; // the topmost hovered clickable box, decided at end of previous frame
	active: Key; // box that received mouse down
	focus: Key; // keyboard focus
	next_hot: Key;
	cursor: Cursor;
	animating: bool;
	overlay_under_mouse: bool; // last frame's overlay (popout, modal, menu) covers the mouse
	animating_loc: Source_Code_Location; // last animate() still in motion (debugging idle wakeups)
	scroll_consumed: bool;
	selection: Selection;
	selection_color: Color;
	selectables: [..]*Box; // Selectable_Text boxes in reading order this frame
	prev_selectables: [..]Key;
}

#add_context ui: *State;

init :: (s: *State, backend: Backend) {
	context.ui = s;
	s.backend = backend;
	mem.dynamic_arena_init(*s.arenas[0]);
	mem.dynamic_arena_init(*s.arenas[1]);
	s.selection_color = .{0.2, 0.45, 0.95, 0.45};
	s.table = make_slice(*Box, 4096);
	s.selection.anchor.box = 0;
}

shutdown :: (s: *State) {
	for * slot: s.table {
		{ b := slot.*;
		while b != null {
			next := b.hash_next;
			free(b);
			b = next;
		} }
	}
	{ b := s.free_list;
	while b != null {
		next := b.hash_next;
		free(b);
		b = next;
	} }
	delete(s.table);
	mem.dynamic_arena_destroy(*s.arenas[0]);
	mem.dynamic_arena_destroy(*s.arenas[1]);
	delete(s.parents);
	delete(s.style_stack);
	delete(s.seed_stack);
	delete(s.order);
	delete(s.draw);
	delete(s.events);
	delete(s.selectables);
	delete(s.prev_selectables);
	if context.ui == s { context.ui = null; }
	s.* = .{}; // no dangling free list / table for a later init
}

// Begin a frame. events are borrowed for the frame.
begin :: (window: Vec2, dt: float32, time: float64, events: []Input_Event) {
	s := context.ui;
	s.mouse_prev = s.mouse;
	clear(*s.events);
	for e: events {
		append(*s.events, e);
		if e.kind == {
		case .Mouse_Move;
			s.mouse = e.pos;
		case .Mouse_Down;
			s.mouse = e.pos;
			s.mouse_down[e.button] = true;
			s.press_pos = e.pos;
		case .Mouse_Up;
			s.mouse = e.pos;
			s.mouse_down[e.button] = false;
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
	s.frame_alloc = mem.dynamic_arena_allocator(*s.arenas[s.frame % 2]);
	// Reset keeps the blocks for reuse; free_all would hand them back to the OS every pass.
	mem.dynamic_arena_reset(*s.arenas[s.frame % 2]);
	clear(*s.parents);
	clear(*s.style_stack);
	clear(*s.seed_stack);
	clear(*s.order);
	clear(*s.draw);
	clear(*s.selectables);
	s.animating = false;
	s.scroll_consumed = false;
	s.cursor = .Default;

	append(*s.style_stack, default_style());
	root := box_make_key(cast(Key)(1), 0);
	root.semantic_size = .[px(window.x), px(window.y)];
	root.layout_axis = .Y;
	root.rect = .{0, 0, window.x, window.y};
	s.root = root;
	append(*s.parents, root);
}

default_style :: () -> Style {
	return Style.{text_color = .{1, 1, 1, 1}, font_size = 16, padding = .{0, 0}};
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
	s.stats.boxes = len(s.order);
	s.stats.draw_cmds = len(s.draw);
	a := *s.arenas[s.frame % 2];
	if a.memory_base != null { s.stats.arena_bytes = a.current_point - a.memory_base; } // fc_mem arenas are Flat_Pools
	// Unhandled mouse-up clears active.
	for e: s.events {
		if e.kind == .Mouse_Up && e.button == .Left { s.active = 0; }
	}
	if s.active != 0 && !s.mouse_down[Mouse_Button.Left] { s.active = 0; }
	return view(s.draw);
}

//////////////////////////////////////////////////////////////////////////////
// keys and the box cache

key_from_string :: (str: string, seed: Key) -> Key {
	// "label##id": hash only the part after ##, display the part before.
	// "label###id": same, but ignore the seed so the key is global.
	hashed := str;
	use_seed := true;
	{ i := strings.index(str, "###");
	if i >= 0 {
		hashed = sub_from(str, i + 3);
		use_seed = false;
	} else { j := strings.index(str, "##");
if j >= 0 {
		hashed = sub_from(str, j + 2);
	} } }
	h := hash.fnv64a(transmute([]u8, hashed), ifx use_seed then cast(u64)(seed) else 0xcbf29ce484222325);
	if h == 0 || h == 1 { h += 2; }
	return cast(Key)(h);
}

display_part :: (str: string) -> string {
	{ i := strings.index(str, "##");
	if i >= 0 { return sub(str, 0, i); } }
	return str;
}

key_from_int :: (v: u64, seed: Key) -> Key {
	b := transmute([8]u8, v);
	h := hash.fnv64a(view(b), cast(u64)(seed));
	if h == 0 || h == 1 { h += 2; }
	return cast(Key)(h);
}

current_seed :: () -> Key {
	s := context.ui;
	if len(s.seed_stack) > 0 { return s.seed_stack[len(s.seed_stack) - 1]; }
	if len(s.parents) > 0 { return top_parent().key; }
	return 0;
}

box_lookup :: (k: Key) -> *Box {
	if k == 0 { return null; }
	s := context.ui;
	slot := cast(u64)(k) % cast(u64)(len(s.table));
	{ b := s.table[slot];
	while b != null {
		if b.key == k { return b; }
		b = b.hash_next;
} }
	return null;
}
#scope_module

box_make_key :: (k: Key, flags: Box_Flags) -> *Box {
	s := context.ui;
	b := box_lookup(k);
	if b != null && b.last_frame_touched == s.frame {
		// Duplicate key this frame: fall back to an anonymous box so the tree stays sane.
		return box_make_anon(flags);
	}
	if b == null {
		if s.free_list != null {
			b = s.free_list;
			s.free_list = b.hash_next;
			b.* = .{};
		} else {
			b = new(Box);
		}
		b.key = k;
		b.first_frame_touched = s.frame;
		slot := cast(u64)(k) % cast(u64)(len(s.table));
		b.hash_next = s.table[slot];
		s.table[slot] = b;
	}
	s.stats.keyed_boxes += 1;
	b.first, b.last, b.next, b.prev, b.parent = null, null, null, null, null;
	b.child_count = 0;
	b.last_frame_touched = s.frame;
	b.flags = flags;
	b.text = "";
	b.custom_draw = null;
	b.custom_user = null;
	b.hover_cursor = .Default;
	b.opacity = 1;
	b.style = top_style();
	b.semantic_size = .[.{}, .{}];
	b.prev_layout = b.text_layout;
	b.text_layout = null;
	b.spans = .{};
	b.fixed_pos = .{};
	b.layout_axis = .Y;
	b.sel_order = 0;
	b.sel_join = "";
	b.cross_align = .Start;

	if len(s.parents) > 0 {
		p := top_parent();
		b.parent = p;
		if p.last == null {
			p.first = b;
		} else {
			p.last.next = b;
			b.prev = p.last;
		}
		p.last = b;
		p.child_count += 1;
	}
	append(*s.order, b);
	return b;
}
#scope_export

// Create (or fetch) a box for this frame.
box :: (str: string, flags: Box_Flags = 0) -> *Box {
	k := ifx str == "" then cast(Key)(0) else key_from_string(str, current_seed());
	b: *Box;
	if k == 0 {
		b = box_make_anon(flags);
	} else {
		b = box_make_key(k, flags);
	}
	b.text = display_part(str);
	return b;
}

box_k :: (k: Key, flags: Box_Flags = 0) -> *Box {
	return box_make_key(k, flags);
}
#scope_module

box_make_anon :: (flags: Box_Flags) -> *Box {
	s := context.ui;
	b := new(Box, s.frame_alloc);
	b.first_frame_touched = s.frame;
	b.last_frame_touched = s.frame;
	b.flags = flags;
	b.style = top_style();
	b.opacity = 1;
	if len(s.parents) > 0 {
		p := top_parent();
		b.parent = p;
		if p.last == null {
			p.first = b;
		} else {
			p.last.next = b;
			b.prev = p.last;
		}
		p.last = b;
		p.child_count += 1;
	}
	append(*s.order, b);
	return b;
}

prune :: () {
	s := context.ui;
	for * slot: s.table {
		prev: **Box = slot;
		{ b := slot.*;
		while b != null {
			next := b.hash_next;
			if b.last_frame_touched + 1 < s.frame {
				prev.* = next;
				b.hash_next = s.free_list;
				s.free_list = b;
			} else {
				prev = *b.hash_next;
			}
			b = next;
		} }
	}
}
#scope_export

//////////////////////////////////////////////////////////////////////////////
// stacks

top_parent :: () -> *Box {return context.ui.parents[len(context.ui.parents) - 1];}
top_style :: () -> Style {return context.ui.style_stack[len(context.ui.style_stack) - 1];}

push_parent :: (b: *Box) {append(*context.ui.parents, b);}
pop_parent :: () {pop(*context.ui.parents);}

parent :: (b: *Box) -> bool {
	push_parent(b);
	return true;
}

push_style :: (st: Style) {append(*context.ui.style_stack, st);}
pop_style :: () {pop(*context.ui.style_stack);}

// Scoped style edit: `if context.ui.styled() { context.ui.st().bg = ...; ... }` or use the helpers below.
styled :: () -> bool {
	push_style(top_style());
	return true;
}

// Mutable reference to the current style; edits affect boxes declared after.
st :: () -> *Style {return *context.ui.style_stack[len(context.ui.style_stack) - 1];}

push_seed :: (k: Key) {append(*context.ui.seed_stack, k);}
pop_seed :: () {pop(*context.ui.seed_stack);}

id_scope :: (v: u64) -> bool {
	push_seed(key_from_int(v, current_seed()));
	return true;
}
#scope_module

//////////////////////////////////////////////////////////////////////////////
// interaction

contains :: (r: Rect, p: Vec2) -> bool {
	return p.x >= r.x0 && p.x < r.x1 && p.y >= r.y0 && p.y < r.y1;
}
#scope_export

intersect :: (a: Rect, b: Rect) -> Rect {
	return .{max(a.x0, b.x0), max(a.y0, b.y0), min(a.x1, b.x1), min(a.y1, b.y1)};
}

// Clip rect a box is visible within, from last frame's layout.
visible_rect :: (b: *Box) -> Rect {
	r := b.rect;
	{ p := b.parent;
	while p != null {
		if has(p.flags, .Clip) { r = intersect(r, p.rect); }
		p = p.parent;
} }
	return r;
}

// The clickable box a press at p goes to, against the most recently laid-out
// boxes (after end(): this frame's; tests use it to find reachable controls).
hit_box :: (p: Vec2) -> Key {return hit_test_prev(p);}
#scope_module

// Hit test against the previous frame's boxes; overlays win, later boxes win.
hit_test_prev :: (p: Vec2) -> Key {
	s := context.ui;
	best: Key;
	best_overlay := false;
	for b: s.order { 	// order still holds last frame's boxes at this point
		if b.key == 0 { continue; }
		if (b.flags & (Box_Flags.Clickable | .Scroll_X | .Scroll_Y | .Selectable_Text)) == 0 { continue; }
		if has(b.flags, .Disabled) { continue; }
		ov := in_overlay(b);
		if best_overlay && !ov { continue; }
		if contains(visible_rect(b), p) && has(b.flags, .Clickable) {
			best = b.key;
			best_overlay = ov;
		}
	}
	return best;
}
#scope_export

// Does any box of last frame's overlay layer (popups, modals) contain p?
overlay_at :: (p: Vec2) -> bool {
	for b: context.ui.order {
		if has(b.flags, .Overlay) && contains(b.rect, p) { return true; }
	}
	return false;
}

in_overlay :: (b: *Box) -> bool {
	{ x := b;
	while x != null {
		if has(x.flags, .Overlay) { return true; }
		x = x.parent;
} }
	return false;
}

// Is the mouse over this box's last-frame rect (ignoring occlusion)?
mouse_over :: (b: *Box) -> bool {
	if context.ui.overlay_under_mouse && !in_overlay(b) { return false; }
	return contains(visible_rect(b), context.ui.mouse);
}

signal :: (b: *Box) -> Signal {
	s := context.ui;
	sig := Signal.{box = b, mouse = s.mouse};
	if b.key == 0 { return sig; }
	sig.hovering = s.hot == b.key;
	if sig.hovering && b.hover_cursor != .Default { s.cursor = b.hover_cursor; }
	if sig.hovering && has(b.flags, .Clickable) && b.hover_cursor == .Default { s.cursor = .Pointer; }
	if has(b.flags, .Clickable) {
		for * e: s.events {
			if e.consumed { continue; }
			if e.kind == {
			case .Mouse_Down;
				if sig.hovering {
					if e.button == .Left {
						s.active = b.key;
						sig.pressed = true;
						if e.click_count == 2 { sig.double_clicked = true; }
						if has(b.flags, .Focusable) { s.focus = b.key; }
					} else if e.button == .Right {
						sig.right_clicked = true;
					}
					e.consumed = true;
				}
			case .Mouse_Up;
				if e.button == .Left && s.active == b.key {
					sig.released = true;
					if contains(visible_rect(b), e.pos) { sig.clicked = true; }
					s.active = 0;
					e.consumed = true;
				}
			case .Key_Down;
				if has(b.flags, .Keyboard_Clickable) && s.focus == b.key && (e.key == .Enter) {
					sig.clicked = true;
					sig.keyboard_click = true;
					e.consumed = true;
				}
			}
		}
	}
	sig.dragging = s.active == b.key;
	if sig.dragging { sig.drag_delta = s.mouse - s.press_pos; }

	// scrolling: the innermost scrollable under the mouse takes the wheel
	if (b.flags & (Box_Flags.Scroll_X | .Scroll_Y)) != 0 && !s.scroll_consumed && contains(visible_rect(b), s.mouse) {
		for * e: s.events {
			if e.kind != .Scroll || e.consumed { continue; }
			if has(b.flags, .Scroll_Y) { b.view_off_target.y -= e.delta.y; }
			if has(b.flags, .Scroll_X) { b.view_off_target.x -= e.delta.x; }
			e.consumed = true;
		}
	}
	return sig;
}

is_focused :: (b: *Box) -> bool {return b.key != 0 && context.ui.focus == b.key;}
set_focus :: (b: *Box) {context.ui.focus = b.key;}

// Frame-rate independent exponential approach. rate is ~1/seconds to settle.
animate :: (v: *float32, target: float32, rate: float32 = 18, loc := #caller_location) {
	s := context.ui;
	if abs(v.* - target) < 0.001 {
		v.* = target;
		return;
	}
	v.* += (target - v.*) * (1 - math.pow(cast(float32) 2, -rate * s.dt));
	if abs(v.* - target) < 0.001 {
		v.* = target;
	} else {
		s.animating = true;
		s.animating_loc = loc;
	}
}
#scope_module

// Hot/active/appear animations are updated as boxes are signaled; call this
// once per box that has animation flags (box_end does it).
update_anims :: (b: *Box) {
	s := context.ui;
	if b.key == 0 { return; }
	is_hot := s.hot == b.key;
	is_active := s.active == b.key;
	if has(b.flags, .Hot_Animation) { animate(*b.hot_t, ifx is_hot then 1.0 else 0.0, 30); }
	if has(b.flags, .Active_Animation) { animate(*b.active_t, ifx is_active then 1.0 else 0.0, 40); }
	animate(*b.appear_t, 1, 20);
}

//////////////////////////////////////////////////////////////////////////////
// layout

layout :: (root: *Box) {
	for axis_i: 0..enum_count(Axis)-1 { axis := cast(Axis) axis_i;
		layout_standalone(root, axis);
		layout_upward(root, axis);
		layout_downward(root, axis);
		layout_solve(root, axis);
	}
	layout_position(root);
}

text_layout_for :: (b: *Box, wrap_width: float32) -> *Text_Layout {
	if b.text_layout != null && (b.text_layout.wrap_width == wrap_width || !has(b.flags, .Wrap_Text)) {
		return b.text_layout;
	}
	ww := ifx has(b.flags, .Wrap_Text) then wrap_width else -1;
	if b.spans.count != 0 {
		b.text_layout = layout_rich(b.spans, ww, b.style.line_height);
		b.text = b.text_layout.text;
	} else {
		b.text_layout = layout_text(b.style.font, b.style.font_size, b.text, ww, b.style.line_height);
	}
	return b.text_layout;
}

layout_standalone :: (b: *Box, axis: Axis) {
	sz := b.semantic_size[axis];
	if sz.kind == {
	case .Pixels;
		b.fixed_size.component[axis] = sz.value;
	case .Text_Content;
		if axis == .X || !has(b.flags, .Wrap_Text) {
			tl := text_layout_for(b, -1);
			b.fixed_size.component[axis] = (ifx axis == .X then tl.width else tl.height) + sz.value * 2 + b.style.padding.component[axis] * 2;
		}
	}
	{ c := b.first;
	while c != null { layout_standalone(c, axis);  c = c.next; } }
}

layout_upward :: (b: *Box, axis: Axis) {
	sz := b.semantic_size[axis];
	if sz.kind == .Percent_Of_Parent {
		{ p := b.parent;
		while p != null {
			pk := p.semantic_size[axis].kind;
			if pk == .Pixels || pk == .Percent_Of_Parent || pk == .Fill || pk == .Text_Content {
				b.fixed_size.component[axis] = p.fixed_size.component[axis] * sz.value;
				break;
			}
			p = p.parent;
} }
	}
	{ c := b.first;
	while c != null { layout_upward(c, axis);  c = c.next; } }
}

layout_downward :: (b: *Box, axis: Axis) {
	{ c := b.first;
	while c != null { layout_downward(c, axis);  c = c.next; } }
	if b.semantic_size[axis].kind == .Children_Sum {
		sum: float32;
		n := 0;
		{ c := b.first;
		while c != null {
			if is_floating(c, axis) { { c = c.next; continue; } }
			if axis == b.layout_axis {
				sum += c.fixed_size.component[axis];
				n += 1;
			} else {
				sum = max(sum, c.fixed_size.component[axis]);
			}
			c = c.next;
} }
		if axis == b.layout_axis && n > 1 { sum += b.style.child_gap * cast(float32)(n - 1); }
		b.fixed_size.component[axis] = sum;
	}
}

is_floating :: (b: *Box, axis: Axis) -> bool {
	return ifx axis == .X then has(b.flags, .Floating_X) else has(b.flags, .Floating_Y);
}

// Top-down: distribute Fill space, shrink to fix overflow, then recurse.
layout_solve :: (b: *Box, axis: Axis) {
	avail := b.fixed_size.component[axis];
	if axis == b.layout_axis {
		total: float32;
		fills := 0;
		n := 0;
		{ c := b.first;
		while c != null {
			if is_floating(c, axis) { { c = c.next; continue; } }
			n += 1;
			if c.semantic_size[axis].kind == .Fill {
				fills += 1;
			} else {
				total += c.fixed_size.component[axis];
			}
			c = c.next;
} }
		if n > 1 { total += b.style.child_gap * cast(float32)(n - 1); }
		if fills > 0 {
			each := max(0.0, (avail - total) / cast(float32)(fills));
			{ c := b.first;
			while c != null {
				if !is_floating(c, axis) && c.semantic_size[axis].kind == .Fill { c.fixed_size.component[axis] = each; }
				c = c.next;
} }
		}
		// Overflowing (fills got 0): shrink the rest too, or rows with a filler
		// (headers) pushed their right side out of the window instead.
		if total > avail && (b.flags & (Box_Flags.Scroll_X | .Scroll_Y)) == 0 {
			// Shrink children proportionally to their slack (1 - strictness).
			over := total - avail;
			slack: float32;
			{ c := b.first;
			while c != null {
				if is_floating(c, axis) { { c = c.next; continue; } }
				slack += c.fixed_size.component[axis] * (1 - c.semantic_size[axis].strictness);
				c = c.next;
} }
			if slack > 0 {
				k := min(over / slack, 1);
				{ c := b.first;
				while c != null {
					if is_floating(c, axis) { { c = c.next; continue; } }
					c.fixed_size.component[axis] -= c.fixed_size.component[axis] * (1 - c.semantic_size[axis].strictness) * k;
					c = c.next;
} }
			}
		}
	} else {
		{ c := b.first;
		while c != null {
			if is_floating(c, axis) { { c = c.next; continue; } }
			if c.semantic_size[axis].kind == .Fill {
				c.fixed_size.component[axis] = avail;
			} else if c.fixed_size.component[axis] > avail && (b.flags & (Box_Flags.Scroll_X | .Scroll_Y)) == 0 {
				s := c.semantic_size[axis].strictness;
				c.fixed_size.component[axis] -= (c.fixed_size.component[axis] - avail) * (1 - s);
			}
			c = c.next;
} }
	}
	// Wrapped text height depends on the now-known width.
	if axis == .Y {
		{ c := b.first;
		while c != null {
			if has(c.flags, .Wrap_Text) && c.semantic_size[Axis.Y].kind == .Text_Content {
				tl := text_layout_for(c, c.fixed_size.x - c.style.padding.x * 2);
				c.fixed_size.y = tl.height + c.style.padding.y * 2 + c.semantic_size[Axis.Y].value * 2;
			}
			c = c.next;
} }
	}
	{ c := b.first;
	while c != null { layout_solve(c, axis);  c = c.next; } }
	if axis == .Y && b.semantic_size[Axis.Y].kind == .Children_Sum {
		// children sizes may have changed during solve (wrapped text); recompute
		sum: float32;
		n := 0;
		{ c := b.first;
		while c != null {
			if is_floating(c, .Y) { { c = c.next; continue; } }
			if b.layout_axis == .Y {
				sum += c.fixed_size.y;
				n += 1;
			} else {
				sum = max(sum, c.fixed_size.y);
			}
			c = c.next;
} }
		if b.layout_axis == .Y && n > 1 { sum += b.style.child_gap * cast(float32)(n - 1); }
		b.fixed_size.y = sum;
	}
}

layout_position :: (b: *Box) {
	cursor: float32;
	content: Vec2;
	{ c := b.first;
	while c != null {
		for axis_i: 0..enum_count(Axis)-1 { axis := cast(Axis) axis_i;
			if is_floating(c, axis) {
				c.rel_pos.component[axis] = c.fixed_pos.component[axis];
				if axis == .Y && has(c.flags, .Anchor_End_Y) { c.rel_pos.y = b.fixed_size.y - c.fixed_size.y - c.fixed_pos.y; }
			} else if axis == b.layout_axis {
				c.rel_pos.component[axis] = cursor;
			} else {
				if b.cross_align == {
				case .Start;
					c.rel_pos.component[axis] = 0;
				case .Center;
					c.rel_pos.component[axis] = (b.fixed_size.component[axis] - c.fixed_size.component[axis]) / 2;
				case .End;
					c.rel_pos.component[axis] = b.fixed_size.component[axis] - c.fixed_size.component[axis];
				}
			}
		}
		if !is_floating(c, b.layout_axis) {
			cursor += c.fixed_size.component[b.layout_axis] + b.style.child_gap;
		}
		content.x = max(content.x, c.rel_pos.x + c.fixed_size.x);
		content.y = max(content.y, c.rel_pos.y + c.fixed_size.y);
		c = c.next;
} }
	b.content_size = content;

	// scroll: clamp target, animate offset
	if (b.flags & (Box_Flags.Scroll_X | .Scroll_Y)) != 0 {
		for axis_i: 0..enum_count(Axis)-1 { axis := cast(Axis) axis_i;
			max_off := max(0.0, content.component[axis] - b.fixed_size.component[axis]);
			b.view_off_target.component[axis] = clamp(b.view_off_target.component[axis], 0, max_off);
			animate(*b.view_off.component[axis], b.view_off_target.component[axis], 40);
			b.view_off.component[axis] = clamp(b.view_off.component[axis], 0, max_off);
		}
	}

	origin := Vec2.{b.rect.x0, b.rect.y0} - b.view_off;
	{ c := b.first;
	while c != null {
		p := origin + c.rel_pos;
		c.rect = Rect.{p.x, p.y, p.x + c.fixed_size.x, p.y + c.fixed_size.y};
		update_anims(c);
		layout_position(c);
		c = c.next;
} }
}
#scope_export

//////////////////////////////////////////////////////////////////////////////
// drawing

lerp_color :: (a: Color, b: Color, t: float32) -> Color {return a + (b - a) * t;}
#scope_module

emit_draw :: (b: *Box, in_overlay_pass: bool) {
	s := context.ui;
	if has(b.flags, .Overlay) && !in_overlay_pass { return; }
	st := *b.style;
	alpha := b.opacity;
	if has(b.flags, .Draw_Shadow) && st.shadow_color.w > 0 {
		r := b.rect;
		r.x0 += st.shadow_offset.x;
		r.x1 += st.shadow_offset.x;
		r.y0 += st.shadow_offset.y;
		r.y1 += st.shadow_offset.y;
		c := st.shadow_color;
		c.w *= alpha;
		append(*s.draw, Draw_Cmd.{kind = .Rect, rect = r, colors = .[c, c, c, c], radii = st.radius, softness = st.shadow_blur});
	}
	if has(b.flags, .Draw_Background) {
		c := st.bg;
		if has(b.flags, .Hot_Animation) && st.bg_hot.w > 0 { c = lerp_color(c, st.bg_hot, b.hot_t); }
		if has(b.flags, .Active_Animation) && st.bg_active.w > 0 { c = lerp_color(c, st.bg_active, b.active_t); }
		c.w *= alpha;
		if c.w > 0 { append(*s.draw, Draw_Cmd.{kind = .Rect, rect = b.rect, colors = .[c, c, c, c], radii = st.radius}); }
	}
	if has(b.flags, .Draw_Border) && st.border > 0 {
		c := st.border_color;
		c.w *= alpha;
		append(*s.draw, Draw_Cmd.{kind = .Rect, rect = b.rect, colors = .[c, c, c, c], radii = st.radius, border = st.border});
	}
	if b.custom_draw != null {
		append(*s.draw, Draw_Cmd.{kind = .Custom, rect = b.rect, box = b});
	}
	if has(b.flags, .Draw_Text) && b.text != "" {
		tl := text_layout_for(b, b.fixed_size.x - st.padding.x * 2);
		o := Vec2.{b.rect.x0 + st.padding.x, b.rect.y0 + st.padding.y};
		inner_w := b.fixed_size.x - st.padding.x * 2;
		if st.text_align == {
		case .Left;
		case .Center;
			o.x += (inner_w - tl.width) / 2;
		case .Right;
			o.x += inner_w - tl.width;
		}
		if !has(b.flags, .Wrap_Text) {
			// vertically center single-line text
			o.y = b.rect.y0 + (b.fixed_size.y - tl.height) / 2;
		}
		tl.origin = o;
		if tl.spans.count != 0 { draw_span_backgrounds(tl); }
		if has(b.flags, .Selectable_Text) { draw_selection_highlight(b, tl); }
		c := st.text_color;
		c.w *= alpha;
		append(*s.draw, Draw_Cmd.{kind = .Text, layout = tl, origin = o, colors = .[c, c, c, c], box = b});
	}
	clip := has(b.flags, .Clip);
	if clip { append(*s.draw, Draw_Cmd.{kind = .Clip_Push, rect = b.rect}); }
	{ c := b.first;
	while c != null { emit_draw(c, in_overlay_pass);  c = c.next; } }
	if clip { append(*s.draw, Draw_Cmd.{kind = .Clip_Pop}); }
}

emit_overlays :: (b: *Box) {
	{ c := b.first;
	while c != null {
		if has(c.flags, .Overlay) {
			emit_draw(c, true);
		} else {
			emit_overlays(c);
		}
		c = c.next;
} }
}
#scope_export

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
// rows, then call list_window_end. Call it where the first row would go, after context.ui.signal(scroll)
// so this frame's wheel input is counted, in a parent with no child_gap.
list_window :: (scroll: *Box, pitch: float32, n: int, margin := 2, id := "list_window") -> List_Window {
	w := List_Window.{n = n, pitch = pitch};
	top_box := box_make_key(key_from_string(id, current_seed()), 0);
	// Where the rows started in the scroll content, from last frame's layout. A new box has no rect
	// yet: assume the rows start at the top, which can only make the window larger.
	top: float32;
	if top_box.first_frame_touched != context.ui.frame { top = top_box.rect.y0 - scroll.rect.y0 + scroll.view_off.y; }
	h := scroll.rect.y1 - scroll.rect.y0;
	if h <= 0 { h = context.ui.window.y; }
	y0 := min(scroll.view_off.y, scroll.view_off_target.y) - top;
	y1 := max(scroll.view_off.y, scroll.view_off_target.y) + h - top;
	if pitch <= 0 {
		w.last = n;
	} else {
		w.first = clamp(cast(int)(math.floor(y0 / pitch)) - margin, 0, n);
		w.last = clamp(cast(int)(math.ceil(y1 / pitch)) + margin, w.first, n);
	}
	top_box.semantic_size = .[px(0), px(cast(float32)(w.first) * pitch)];
	return w;
}

list_window_end :: (w: List_Window) {
	b := box_make_anon(0);
	b.semantic_size = .[px(0), px(cast(float32)(w.n - w.last) * w.pitch)];
}

// Was b out of view last frame (outside a clipping ancestor by more than margin), with room for the
// scrolling still pending? A caller may then declare b at its size but without its contents: it
// stays keyed and laid out, and the frame it can come into view it is declared in full again.
// Boxes new this frame, or under a new clipping ancestor, are never offscreen.
offscreen :: (b: *Box, margin: float32 = 64) -> bool {
	if b.first_frame_touched == context.ui.frame { return false; }
	r := b.rect;
	if r.x1 <= r.x0 && r.y1 <= r.y0 { return false; }
	m := Vec2.{margin, margin};
	{ p := b.parent;
	while p != null {
		if p.first_frame_touched == context.ui.frame && has(p.flags, .Clip) { return false; }
		if (p.flags & (Box_Flags.Scroll_X | .Scroll_Y)) != 0 { m += .{abs(p.view_off_target.x - p.view_off.x), abs(p.view_off_target.y - p.view_off.y)}; }
		p = p.parent;
} }
	{ p := b.parent;
	while p != null {
		if !has(p.flags, .Clip) { { p = p.parent; continue; } }
		c := p.rect;
		if r.y1 < c.y0 - m.y || r.y0 > c.y1 + m.y || r.x1 < c.x0 - m.x || r.x0 > c.x1 + m.x { return true; }
		p = p.parent;
} }
	return false;
}

// Has any box requested another frame (animation, smooth scroll)?
needs_frame :: () -> bool {return context.ui.animating;}
cursor :: () -> Cursor {return context.ui.cursor;}

// Concatenates span texts into the box text so selection/copy see them.
// The spans are copied, so callers may pass slice literals.
set_spans :: (b: *Box, spans: []Span) {
	copied := make_slice(Span, len(spans), context.ui.frame_alloc);
	copy(copied, spans);
	b.spans = copied;
	sb := strings.builder_make(context.ui.frame_alloc);
	for sp: spans { strings.write_string(*sb, sp.text); }
	b.text = strings.to_string(sb);
	b.flags |= .Draw_Text;
}
#scope_module

draw_span_backgrounds :: (tl: *Text_Layout) {
	for l: tl.lines {
		gi := l.glyph_start;
		while gi < l.glyph_end {
			si := get(tl.run.glyphs, gi).span;
			start := gi;
			while gi < l.glyph_end && tl.run.glyphs[gi].span == si { gi += 1; }
			sp := tl.spans[si];
			if sp.bg.w <= 0 { continue; }
			g0 := get(tl.run.glyphs, start);
			g1 := get(tl.run.glyphs, gi - 1);
			x0 := tl.origin.x + g0.x - l.x_shift;
			x1 := tl.origin.x + g1.x + g1.advance - l.x_shift;
			y0 := tl.origin.y + l.y;
			r := Rect.{x0 - 2, y0 + 1, x1 + 2, y0 + tl.line_h - 1};
			c := sp.bg;
			append(*context.ui.draw, Draw_Cmd.{kind = .Rect, rect = r, colors = .[c, c, c, c], radii = .[sp.bg_radius, sp.bg_radius, sp.bg_radius, sp.bg_radius]});
		}
	}
}
#scope_export

