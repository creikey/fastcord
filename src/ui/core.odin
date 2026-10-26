// Package ui is an immediate-mode UI core in the style of Ryan Fleury's UI
// series: every frame the app declares a tree of keyed boxes; the library keeps
// a persistent cache keyed by hash so boxes carry state (animation, scroll,
// last-frame rect) across frames. Interaction is computed against the previous
// frame's layout, so a box's signal is available the moment it is declared.
//
// ui knows nothing about the GPU. It emits a flat list of draw commands and
// asks the app's Backend to shape text.
package ui

import "base:runtime"
import "core:hash"
import "core:math"
import "core:mem"
import "core:strings"

Vec2 :: [2]f32
Color :: [4]f32
Rect :: struct {
	x0, y0, x1, y1: f32,
}

Axis :: enum u8 {
	X,
	Y,
}

Key :: distinct u64

Size_Kind :: enum u8 {
	None,
	Pixels,
	Text_Content,
	Percent_Of_Parent,
	Children_Sum,
	Fill, // takes the space its siblings leave along the parent's layout axis
}

Size :: struct {
	kind:       Size_Kind,
	value:      f32,
	strictness: f32, // 1 = never shrink, 0 = shrink freely when parent overflows
}

px :: proc(v: f32, strictness: f32 = 1) -> Size {return {.Pixels, v, strictness}}
pct :: proc(v: f32, strictness: f32 = 0) -> Size {return {.Percent_Of_Parent, v, strictness}}
text_size :: proc(pad: f32 = 0, strictness: f32 = 1) -> Size {return {.Text_Content, pad, strictness}}
children :: proc(strictness: f32 = 1) -> Size {return {.Children_Sum, 0, strictness}}
fill :: proc() -> Size {return {.Fill, 1, 0}}

Box_Flag :: enum u32 {
	Clickable,
	Scroll_X,
	Scroll_Y,
	Clip,
	Draw_Background,
	Draw_Border,
	Draw_Text,
	Draw_Shadow,
	Floating_X,
	Floating_Y,
	Hot_Animation,
	Active_Animation,
	Focusable,
	Selectable_Text, // participates in the global (cross-box) text selection
	Wrap_Text,
	Overlay, // drawn after all normal boxes (popups, tooltips)
	Disabled,
	Keyboard_Clickable,
}
Box_Flags :: bit_set[Box_Flag;u32]

Align :: enum u8 {
	Start,
	Center,
	End,
}

Text_Align :: enum u8 {
	Left,
	Center,
	Right,
}

Style :: struct {
	bg:            Color,
	bg_hot:        Color, // used with Hot_Animation; zero = bg
	bg_active:     Color,
	text_color:    Color,
	border_color:  Color,
	border:        f32,
	radius:        [4]f32,
	font:          Font,
	font_size:     f32,
	line_height:   f32, // points; 0 = font default
	padding:       [2]f32, // inner text padding x,y
	text_align:    Text_Align,
	shadow_color:  Color,
	shadow_offset: Vec2,
	shadow_blur:   f32,
	child_gap:     f32,
}

Font :: distinct u32

Custom_Draw :: #type proc(b: ^Box, user: rawptr)

Box :: struct {
	// tree links, rebuilt each frame
	first, last, next, prev, parent: ^Box,
	child_count:                     int,
	// hash links
	hash_next:                       ^Box,
	key:                             Key,
	last_frame_touched:              u64,
	first_frame_touched:             u64,

	// per-frame declaration
	flags:                           Box_Flags,
	semantic_size:                   [Axis]Size,
	layout_axis:                     Axis,
	fixed_pos:                       Vec2, // for floating boxes, relative to parent
	text:                            string,
	style:                           Style,
	custom_draw:                     Custom_Draw,
	custom_user:                     rawptr,
	hover_cursor:                    Cursor,
	opacity:                         f32,

	// layout outputs
	fixed_size:                      Vec2,
	rel_pos:                         Vec2,
	rect:                            Rect,
	text_layout:                     ^Text_Layout,
	spans:                           []Span, // rich text; text must be their concatenation (see set_spans)

	// persistent state
	hot_t, active_t, appear_t:       f32,
	view_off, view_off_target:       Vec2,
	content_size:                    Vec2,
	user_t:                          f32, // free animation slot for app code (animate it yourself)
	cross_align:                     Align, // where children sit on the axis perpendicular to layout_axis
	sel_order:                       u64, // reading order for Selectable_Text; 0 = declaration order
	sel_join:                        string, // copied before this box when the selection continues from an earlier one; "" = newline
}

Cursor :: enum u8 {
	Default,
	Pointer,
	IBeam,
	Resize_H,
	Resize_V,
}

Mouse_Button :: enum u8 {
	Left,
	Right,
	Middle,
}

Mod :: enum u8 {
	Shift,
	Ctrl,
	Alt,
	Cmd,
}
Mods :: bit_set[Mod;u8]

Key_Code :: enum u16 {
	None,
	Enter,
	Escape,
	Backspace,
	Delete,
	Tab,
	Left,
	Right,
	Up,
	Down,
	Home,
	End,
	Page_Up,
	Page_Down,
	A,
	C,
	V,
	X,
	Y,
	Z,
	K,
	Other,
}

Input_Event_Kind :: enum u8 {
	Mouse_Move,
	Mouse_Down,
	Mouse_Up,
	Scroll,
	Key_Down,
	Text,
}

Input_Event :: struct {
	kind:        Input_Event_Kind,
	pos:         Vec2,
	delta:       Vec2,
	button:      Mouse_Button,
	click_count: int,
	key:         Key_Code,
	mods:        Mods,
	text:        string,
	consumed:    bool,
}

Signal :: struct {
	box:            ^Box,
	hovering:       bool, // mouse is over this box and nothing above it
	pressed:        bool, // mouse went down on it this frame
	released:       bool,
	clicked:        bool, // down and up on it
	double_clicked: bool,
	right_clicked:  bool,
	dragging:       bool, // is the active box
	mouse:          Vec2,
	drag_delta:     Vec2,
	keyboard_click: bool,
}

// Draw commands are what the app renders. Clip pushes nest.
Draw_Kind :: enum u8 {
	Rect,
	Text,
	Clip_Push,
	Clip_Pop,
	Custom,
}

Draw_Cmd :: struct {
	kind:     Draw_Kind,
	rect:     Rect,
	colors:   [4]Color,
	radii:    [4]f32,
	border:   f32,
	softness: f32,
	layout:   ^Text_Layout,
	origin:   Vec2,
	box:      ^Box,
}

// The backend shapes text. Glyph advances plus clusters let ui do wrapping,
// hit-testing and caret placement itself.
Shaped_Glyph :: struct {
	x, advance:                 f32, // x relative to run start
	cluster_start, cluster_end: int, // UTF-8 byte range in the source text
	handle:                     u64, // opaque to ui, passed back to the app at draw time
	span:                       i32, // rich text: index of the span this glyph came from
}

Shaped_Run :: struct {
	glyphs:  []Shaped_Glyph,
	width:   f32,
	ascent:  f32,
	descent: f32,
	line_h:  f32,
	handle:  rawptr, // backend's run, for drawing
}

Backend :: struct {
	shape: proc(font: Font, size: f32, text: string) -> Shaped_Run, // result must stay valid for the frame
}

STACK_MAX :: 64

State :: struct {
	backend:          Backend,
	frame:            u64,
	dt:               f32,
	time:             f64,
	arenas:           [2]mem.Dynamic_Arena,
	frame_alloc:      mem.Allocator,
	table:            []^Box,
	free_list:        ^Box,
	root:             ^Box,
	parents:          [dynamic]^Box,
	style_stack:      [dynamic]Style,
	seed_stack:       [dynamic]Key,
	order:            [dynamic]^Box, // declaration order, for event routing and drawing
	draw:             [dynamic]Draw_Cmd,
	window:           Vec2,

	// interaction
	mouse:            Vec2,
	mouse_prev:       Vec2,
	mouse_down:       [Mouse_Button]bool,
	press_pos:        Vec2,
	events:           [dynamic]Input_Event,
	hot:              Key, // the topmost hovered clickable box, decided at end of previous frame
	active:           Key, // box that received mouse down
	focus:            Key, // keyboard focus
	next_hot:         Key,
	cursor:           Cursor,
	animating:        bool,
	animating_loc:    runtime.Source_Code_Location, // last animate() still in motion (debugging idle wakeups)
	scroll_consumed:  bool,
	selection:        Selection,
	selection_color:  Color,
	selectables:      [dynamic]^Box, // Selectable_Text boxes in reading order this frame
	prev_selectables: [dynamic]Key,
}

@(thread_local)
ui: ^State

init :: proc(s: ^State, backend: Backend) {
	ui = s
	s.backend = backend
	mem.dynamic_arena_init(&s.arenas[0])
	mem.dynamic_arena_init(&s.arenas[1])
	s.selection_color = {0.2, 0.45, 0.95, 0.45}
	s.table = make([]^Box, 4096)
	s.selection.anchor.box = 0
}

shutdown :: proc(s: ^State) {
	for &slot in s.table {
		for b := slot; b != nil; {
			next := b.hash_next
			free(b)
			b = next
		}
	}
	for b := s.free_list; b != nil; {
		next := b.hash_next
		free(b)
		b = next
	}
	delete(s.table)
	mem.dynamic_arena_destroy(&s.arenas[0])
	mem.dynamic_arena_destroy(&s.arenas[1])
	delete(s.parents)
	delete(s.style_stack)
	delete(s.seed_stack)
	delete(s.order)
	delete(s.draw)
	delete(s.events)
	delete(s.selectables)
	delete(s.prev_selectables)
	if ui == s do ui = nil
}

// Begin a frame. events are borrowed for the frame.
begin :: proc(window: Vec2, dt: f32, time: f64, events: []Input_Event) {
	s := ui
	s.mouse_prev = s.mouse
	clear(&s.events)
	for e in events {
		append(&s.events, e)
		#partial switch e.kind {
		case .Mouse_Move:
			s.mouse = e.pos
		case .Mouse_Down:
			s.mouse = e.pos
			s.mouse_down[e.button] = true
			s.press_pos = e.pos
		case .Mouse_Up:
			s.mouse = e.pos
			s.mouse_down[e.button] = false
		}
	}
	// The hot box is whatever was topmost under the mouse in last frame's
	// layout; last frame's boxes (and their arena) are still alive here.
	s.hot = hit_test_prev(s.mouse)

	s.frame += 1
	s.dt = dt
	s.time = time
	s.window = window
	// Two arenas: anonymous boxes from frame N-1 must survive into frame N's hit test.
	s.frame_alloc = mem.dynamic_arena_allocator(&s.arenas[s.frame % 2])
	mem.dynamic_arena_free_all(&s.arenas[s.frame % 2])
	clear(&s.parents)
	clear(&s.style_stack)
	clear(&s.seed_stack)
	clear(&s.order)
	clear(&s.draw)
	clear(&s.selectables)
	s.animating = false
	s.scroll_consumed = false
	s.cursor = .Default

	append(&s.style_stack, default_style())
	root := box_make_key(Key(1), {})
	root.semantic_size = {.X = px(window.x), .Y = px(window.y)}
	root.layout_axis = .Y
	root.rect = {0, 0, window.x, window.y}
	s.root = root
	append(&s.parents, root)
}

default_style :: proc() -> Style {
	return Style{text_color = {1, 1, 1, 1}, font_size = 16, padding = {0, 0}}
}

// End the frame: lay out, run selection, emit draw commands, prune stale boxes.
end :: proc() -> []Draw_Cmd {
	s := ui
	layout(s.root)
	update_selection()
	emit_draw(s.root, false)
	emit_overlays(s.root)
	prune()
	// Unhandled mouse-up clears active.
	for e in s.events {
		if e.kind == .Mouse_Up && e.button == .Left do s.active = 0
	}
	if s.active != 0 && !s.mouse_down[.Left] do s.active = 0
	return s.draw[:]
}

//////////////////////////////////////////////////////////////////////////////
// keys and the box cache

key_from_string :: proc(str: string, seed: Key) -> Key {
	// "label##id": hash only the part after ##, display the part before.
	// "label###id": same, but ignore the seed so the key is global.
	hashed := str
	use_seed := true
	if i := strings.index(str, "###"); i >= 0 {
		hashed = str[i + 3:]
		use_seed = false
	} else if j := strings.index(str, "##"); j >= 0 {
		hashed = str[j + 2:]
	}
	h := hash.fnv64a(transmute([]byte)hashed, use_seed ? u64(seed) : 0xcbf29ce484222325)
	if h == 0 || h == 1 do h += 2
	return Key(h)
}

display_part :: proc(str: string) -> string {
	if i := strings.index(str, "##"); i >= 0 do return str[:i]
	return str
}

key_from_int :: proc(v: u64, seed: Key) -> Key {
	b := transmute([8]byte)v
	h := hash.fnv64a(b[:], u64(seed))
	if h == 0 || h == 1 do h += 2
	return Key(h)
}

current_seed :: proc() -> Key {
	s := ui
	if len(s.seed_stack) > 0 do return s.seed_stack[len(s.seed_stack) - 1]
	if len(s.parents) > 0 do return top_parent().key
	return 0
}

box_lookup :: proc(k: Key) -> ^Box {
	if k == 0 do return nil
	s := ui
	slot := u64(k) % u64(len(s.table))
	for b := s.table[slot]; b != nil; b = b.hash_next {
		if b.key == k do return b
	}
	return nil
}

@(private)
box_make_key :: proc(k: Key, flags: Box_Flags) -> ^Box {
	s := ui
	b := box_lookup(k)
	if b != nil && b.last_frame_touched == s.frame {
		// Duplicate key this frame: fall back to an anonymous box so the tree stays sane.
		return box_make_anon(flags)
	}
	if b == nil {
		if s.free_list != nil {
			b = s.free_list
			s.free_list = b.hash_next
			b^ = {}
		} else {
			b = new(Box)
		}
		b.key = k
		b.first_frame_touched = s.frame
		slot := u64(k) % u64(len(s.table))
		b.hash_next = s.table[slot]
		s.table[slot] = b
	}
	b.first, b.last, b.next, b.prev, b.parent = nil, nil, nil, nil, nil
	b.child_count = 0
	b.last_frame_touched = s.frame
	b.flags = flags
	b.text = ""
	b.custom_draw = nil
	b.custom_user = nil
	b.hover_cursor = .Default
	b.opacity = 1
	b.style = top_style()
	b.semantic_size = {.X = {}, .Y = {}}
	b.text_layout = nil
	b.spans = nil
	b.fixed_pos = {}
	b.layout_axis = .Y
	b.sel_order = 0
	b.sel_join = ""
	b.cross_align = .Start

	if len(s.parents) > 0 {
		p := top_parent()
		b.parent = p
		if p.last == nil {
			p.first = b
		} else {
			p.last.next = b
			b.prev = p.last
		}
		p.last = b
		p.child_count += 1
	}
	append(&s.order, b)
	return b
}

// Create (or fetch) a box for this frame.
box :: proc(str: string, flags: Box_Flags = {}) -> ^Box {
	k := str == "" ? Key(0) : key_from_string(str, current_seed())
	b: ^Box
	if k == 0 {
		b = box_make_anon(flags)
	} else {
		b = box_make_key(k, flags)
	}
	b.text = display_part(str)
	return b
}

box_k :: proc(k: Key, flags: Box_Flags = {}) -> ^Box {
	return box_make_key(k, flags)
}

@(private)
box_make_anon :: proc(flags: Box_Flags) -> ^Box {
	s := ui
	b := new(Box, s.frame_alloc)
	b.first_frame_touched = s.frame
	b.last_frame_touched = s.frame
	b.flags = flags
	b.style = top_style()
	b.opacity = 1
	if len(s.parents) > 0 {
		p := top_parent()
		b.parent = p
		if p.last == nil {
			p.first = b
		} else {
			p.last.next = b
			b.prev = p.last
		}
		p.last = b
		p.child_count += 1
	}
	append(&s.order, b)
	return b
}

@(private)
prune :: proc() {
	s := ui
	for &slot in s.table {
		prev: ^^Box = &slot
		for b := slot; b != nil; {
			next := b.hash_next
			if b.last_frame_touched + 1 < s.frame {
				prev^ = next
				b.hash_next = s.free_list
				s.free_list = b
			} else {
				prev = &b.hash_next
			}
			b = next
		}
	}
}

//////////////////////////////////////////////////////////////////////////////
// stacks

top_parent :: proc() -> ^Box {return ui.parents[len(ui.parents) - 1]}
top_style :: proc() -> Style {return ui.style_stack[len(ui.style_stack) - 1]}

push_parent :: proc(b: ^Box) {append(&ui.parents, b)}
pop_parent :: proc() {pop(&ui.parents)}

@(deferred_none = pop_parent)
parent :: proc(b: ^Box) -> bool {
	push_parent(b)
	return true
}

push_style :: proc(st: Style) {append(&ui.style_stack, st)}
pop_style :: proc() {pop(&ui.style_stack)}

// Scoped style edit: `if ui.styled() { ui.st().bg = ...; ... }` or use the helpers below.
@(deferred_none = pop_style)
styled :: proc() -> bool {
	push_style(top_style())
	return true
}

// Mutable reference to the current style; edits affect boxes declared after.
st :: proc() -> ^Style {return &ui.style_stack[len(ui.style_stack) - 1]}

push_seed :: proc(k: Key) {append(&ui.seed_stack, k)}
pop_seed :: proc() {pop(&ui.seed_stack)}

@(deferred_none = pop_seed)
id_scope :: proc(v: u64) -> bool {
	push_seed(key_from_int(v, current_seed()))
	return true
}

//////////////////////////////////////////////////////////////////////////////
// interaction

@(private)
contains :: proc(r: Rect, p: Vec2) -> bool {
	return p.x >= r.x0 && p.x < r.x1 && p.y >= r.y0 && p.y < r.y1
}

intersect :: proc(a, b: Rect) -> Rect {
	return {max(a.x0, b.x0), max(a.y0, b.y0), min(a.x1, b.x1), min(a.y1, b.y1)}
}

// Clip rect a box is visible within, from last frame's layout.
@(private)
visible_rect :: proc(b: ^Box) -> Rect {
	r := b.rect
	for p := b.parent; p != nil; p = p.parent {
		if .Clip in p.flags do r = intersect(r, p.rect)
	}
	return r
}

// Hit test against the previous frame's boxes; overlays win, later boxes win.
@(private)
hit_test_prev :: proc(p: Vec2) -> Key {
	s := ui
	best: Key
	best_overlay := false
	for b in s.order { 	// order still holds last frame's boxes at this point
		if b.key == 0 do continue
		if b.flags & {.Clickable, .Scroll_X, .Scroll_Y, .Selectable_Text} == {} do continue
		if .Disabled in b.flags do continue
		ov := in_overlay(b)
		if best_overlay && !ov do continue
		if contains(visible_rect(b), p) && .Clickable in b.flags {
			best = b.key
			best_overlay = ov
		}
	}
	return best
}

@(private)
in_overlay :: proc(b: ^Box) -> bool {
	for x := b; x != nil; x = x.parent {
		if .Overlay in x.flags do return true
	}
	return false
}

// Is the mouse over this box's last-frame rect (ignoring occlusion)?
mouse_over :: proc(b: ^Box) -> bool {
	return contains(visible_rect(b), ui.mouse)
}

signal :: proc(b: ^Box) -> Signal {
	s := ui
	sig := Signal{box = b, mouse = s.mouse}
	if b.key == 0 do return sig
	sig.hovering = s.hot == b.key
	if sig.hovering && b.hover_cursor != .Default do s.cursor = b.hover_cursor
	if sig.hovering && .Clickable in b.flags && b.hover_cursor == .Default do s.cursor = .Pointer
	if .Clickable in b.flags {
		for &e in s.events {
			if e.consumed do continue
			#partial switch e.kind {
			case .Mouse_Down:
				if sig.hovering {
					if e.button == .Left {
						s.active = b.key
						sig.pressed = true
						if e.click_count == 2 do sig.double_clicked = true
						if .Focusable in b.flags do s.focus = b.key
					} else if e.button == .Right {
						sig.right_clicked = true
					}
					e.consumed = true
				}
			case .Mouse_Up:
				if e.button == .Left && s.active == b.key {
					sig.released = true
					if contains(visible_rect(b), e.pos) do sig.clicked = true
					s.active = 0
					e.consumed = true
				}
			case .Key_Down:
				if .Keyboard_Clickable in b.flags && s.focus == b.key && (e.key == .Enter) {
					sig.clicked = true
					sig.keyboard_click = true
					e.consumed = true
				}
			}
		}
	}
	sig.dragging = s.active == b.key
	if sig.dragging do sig.drag_delta = s.mouse - s.press_pos

	// scrolling: the innermost scrollable under the mouse takes the wheel
	if b.flags & {.Scroll_X, .Scroll_Y} != {} && !s.scroll_consumed && contains(visible_rect(b), s.mouse) {
		for &e in s.events {
			if e.kind != .Scroll || e.consumed do continue
			if .Scroll_Y in b.flags do b.view_off_target.y -= e.delta.y
			if .Scroll_X in b.flags do b.view_off_target.x -= e.delta.x
			e.consumed = true
		}
	}
	return sig
}

is_focused :: proc(b: ^Box) -> bool {return b.key != 0 && ui.focus == b.key}
set_focus :: proc(b: ^Box) {ui.focus = b.key}

// Frame-rate independent exponential approach. rate is ~1/seconds to settle.
animate :: proc(v: ^f32, target: f32, rate: f32 = 18, loc := #caller_location) {
	s := ui
	if abs(v^ - target) < 0.001 {
		v^ = target
		return
	}
	v^ += (target - v^) * (1 - math.pow(2, -rate * s.dt))
	if abs(v^ - target) < 0.001 {
		v^ = target
	} else {
		s.animating = true
		s.animating_loc = loc
	}
}

// Hot/active/appear animations are updated as boxes are signaled; call this
// once per box that has animation flags (box_end does it).
@(private)
update_anims :: proc(b: ^Box) {
	s := ui
	if b.key == 0 do return
	is_hot := s.hot == b.key
	is_active := s.active == b.key
	if .Hot_Animation in b.flags do animate(&b.hot_t, is_hot ? 1 : 0, 30)
	if .Active_Animation in b.flags do animate(&b.active_t, is_active ? 1 : 0, 40)
	animate(&b.appear_t, 1, 20)
}

//////////////////////////////////////////////////////////////////////////////
// layout

@(private)
layout :: proc(root: ^Box) {
	for axis in Axis {
		layout_standalone(root, axis)
		layout_upward(root, axis)
		layout_downward(root, axis)
		layout_solve(root, axis)
	}
	layout_position(root)
}

@(private)
text_layout_for :: proc(b: ^Box, wrap_width: f32) -> ^Text_Layout {
	if b.text_layout != nil && (b.text_layout.wrap_width == wrap_width || .Wrap_Text not_in b.flags) {
		return b.text_layout
	}
	ww := .Wrap_Text in b.flags ? wrap_width : -1
	if b.spans != nil {
		b.text_layout = layout_rich(b.spans, ww, b.style.line_height)
		b.text = b.text_layout.text
	} else {
		b.text_layout = layout_text(b.style.font, b.style.font_size, b.text, ww, b.style.line_height)
	}
	return b.text_layout
}

@(private)
layout_standalone :: proc(b: ^Box, axis: Axis) {
	sz := b.semantic_size[axis]
	#partial switch sz.kind {
	case .Pixels:
		b.fixed_size[axis] = sz.value
	case .Text_Content:
		if axis == .X || .Wrap_Text not_in b.flags {
			tl := text_layout_for(b, -1)
			b.fixed_size[axis] = (axis == .X ? tl.width : tl.height) + sz.value * 2 + b.style.padding[int(axis)] * 2
		}
	}
	for c := b.first; c != nil; c = c.next do layout_standalone(c, axis)
}

@(private)
layout_upward :: proc(b: ^Box, axis: Axis) {
	sz := b.semantic_size[axis]
	if sz.kind == .Percent_Of_Parent {
		for p := b.parent; p != nil; p = p.parent {
			pk := p.semantic_size[axis].kind
			if pk == .Pixels || pk == .Percent_Of_Parent || pk == .Fill || pk == .Text_Content {
				b.fixed_size[axis] = p.fixed_size[axis] * sz.value
				break
			}
		}
	}
	for c := b.first; c != nil; c = c.next do layout_upward(c, axis)
}

@(private)
layout_downward :: proc(b: ^Box, axis: Axis) {
	for c := b.first; c != nil; c = c.next do layout_downward(c, axis)
	if b.semantic_size[axis].kind == .Children_Sum {
		sum: f32
		n := 0
		for c := b.first; c != nil; c = c.next {
			if is_floating(c, axis) do continue
			if axis == b.layout_axis {
				sum += c.fixed_size[axis]
				n += 1
			} else {
				sum = max(sum, c.fixed_size[axis])
			}
		}
		if axis == b.layout_axis && n > 1 do sum += b.style.child_gap * f32(n - 1)
		b.fixed_size[axis] = sum
	}
}

@(private)
is_floating :: proc(b: ^Box, axis: Axis) -> bool {
	return axis == .X ? .Floating_X in b.flags : .Floating_Y in b.flags
}

// Top-down: distribute Fill space, shrink to fix overflow, then recurse.
@(private)
layout_solve :: proc(b: ^Box, axis: Axis) {
	avail := b.fixed_size[axis]
	if axis == b.layout_axis {
		total: f32
		fills := 0
		n := 0
		for c := b.first; c != nil; c = c.next {
			if is_floating(c, axis) do continue
			n += 1
			if c.semantic_size[axis].kind == .Fill {
				fills += 1
			} else {
				total += c.fixed_size[axis]
			}
		}
		if n > 1 do total += b.style.child_gap * f32(n - 1)
		if fills > 0 {
			each := max(0, (avail - total) / f32(fills))
			for c := b.first; c != nil; c = c.next {
				if !is_floating(c, axis) && c.semantic_size[axis].kind == .Fill do c.fixed_size[axis] = each
			}
		} else if total > avail && b.flags & {.Scroll_X, .Scroll_Y} == {} {
			// Shrink children proportionally to their slack (1 - strictness).
			over := total - avail
			slack: f32
			for c := b.first; c != nil; c = c.next {
				if is_floating(c, axis) do continue
				slack += c.fixed_size[axis] * (1 - c.semantic_size[axis].strictness)
			}
			if slack > 0 {
				k := min(over / slack, 1)
				for c := b.first; c != nil; c = c.next {
					if is_floating(c, axis) do continue
					c.fixed_size[axis] -= c.fixed_size[axis] * (1 - c.semantic_size[axis].strictness) * k
				}
			}
		}
	} else {
		for c := b.first; c != nil; c = c.next {
			if is_floating(c, axis) do continue
			if c.semantic_size[axis].kind == .Fill {
				c.fixed_size[axis] = avail
			} else if c.fixed_size[axis] > avail && b.flags & {.Scroll_X, .Scroll_Y} == {} {
				s := c.semantic_size[axis].strictness
				c.fixed_size[axis] -= (c.fixed_size[axis] - avail) * (1 - s)
			}
		}
	}
	// Wrapped text height depends on the now-known width.
	if axis == .Y {
		for c := b.first; c != nil; c = c.next {
			if .Wrap_Text in c.flags && c.semantic_size[.Y].kind == .Text_Content {
				tl := text_layout_for(c, c.fixed_size.x - c.style.padding.x * 2)
				c.fixed_size.y = tl.height + c.style.padding.y * 2 + c.semantic_size[.Y].value * 2
			}
		}
	}
	for c := b.first; c != nil; c = c.next do layout_solve(c, axis)
	if axis == .Y && b.semantic_size[.Y].kind == .Children_Sum {
		// children sizes may have changed during solve (wrapped text); recompute
		sum: f32
		n := 0
		for c := b.first; c != nil; c = c.next {
			if is_floating(c, .Y) do continue
			if b.layout_axis == .Y {
				sum += c.fixed_size.y
				n += 1
			} else {
				sum = max(sum, c.fixed_size.y)
			}
		}
		if b.layout_axis == .Y && n > 1 do sum += b.style.child_gap * f32(n - 1)
		b.fixed_size.y = sum
	}
}

@(private)
layout_position :: proc(b: ^Box) {
	cursor: f32
	content: Vec2
	for c := b.first; c != nil; c = c.next {
		for axis in Axis {
			if is_floating(c, axis) {
				c.rel_pos[axis] = c.fixed_pos[axis]
			} else if axis == b.layout_axis {
				c.rel_pos[axis] = cursor
			} else {
				switch b.cross_align {
				case .Start:
					c.rel_pos[axis] = 0
				case .Center:
					c.rel_pos[axis] = (b.fixed_size[axis] - c.fixed_size[axis]) / 2
				case .End:
					c.rel_pos[axis] = b.fixed_size[axis] - c.fixed_size[axis]
				}
			}
		}
		if !is_floating(c, b.layout_axis) {
			cursor += c.fixed_size[b.layout_axis] + b.style.child_gap
		}
		content.x = max(content.x, c.rel_pos.x + c.fixed_size.x)
		content.y = max(content.y, c.rel_pos.y + c.fixed_size.y)
	}
	b.content_size = content

	// scroll: clamp target, animate offset
	if b.flags & {.Scroll_X, .Scroll_Y} != {} {
		for axis in Axis {
			max_off := max(0, content[axis] - b.fixed_size[axis])
			b.view_off_target[axis] = clamp(b.view_off_target[axis], 0, max_off)
			animate(&b.view_off[axis], b.view_off_target[axis], 40)
			b.view_off[axis] = clamp(b.view_off[axis], 0, max_off)
		}
	}

	origin := Vec2{b.rect.x0, b.rect.y0} - b.view_off
	for c := b.first; c != nil; c = c.next {
		p := origin + c.rel_pos
		c.rect = Rect{p.x, p.y, p.x + c.fixed_size.x, p.y + c.fixed_size.y}
		update_anims(c)
		layout_position(c)
	}
}

//////////////////////////////////////////////////////////////////////////////
// drawing

lerp_color :: proc(a, b: Color, t: f32) -> Color {return a + (b - a) * t}

@(private)
emit_draw :: proc(b: ^Box, in_overlay_pass: bool) {
	s := ui
	if .Overlay in b.flags && !in_overlay_pass do return
	st := &b.style
	alpha := b.opacity
	if .Draw_Shadow in b.flags && st.shadow_color.a > 0 {
		r := b.rect
		r.x0 += st.shadow_offset.x
		r.x1 += st.shadow_offset.x
		r.y0 += st.shadow_offset.y
		r.y1 += st.shadow_offset.y
		c := st.shadow_color
		c.a *= alpha
		append(&s.draw, Draw_Cmd{kind = .Rect, rect = r, colors = {c, c, c, c}, radii = st.radius, softness = st.shadow_blur})
	}
	if .Draw_Background in b.flags {
		c := st.bg
		if .Hot_Animation in b.flags && st.bg_hot.a > 0 do c = lerp_color(c, st.bg_hot, b.hot_t)
		if .Active_Animation in b.flags && st.bg_active.a > 0 do c = lerp_color(c, st.bg_active, b.active_t)
		c.a *= alpha
		if c.a > 0 do append(&s.draw, Draw_Cmd{kind = .Rect, rect = b.rect, colors = {c, c, c, c}, radii = st.radius})
	}
	if .Draw_Border in b.flags && st.border > 0 {
		c := st.border_color
		c.a *= alpha
		append(&s.draw, Draw_Cmd{kind = .Rect, rect = b.rect, colors = {c, c, c, c}, radii = st.radius, border = st.border})
	}
	if b.custom_draw != nil {
		append(&s.draw, Draw_Cmd{kind = .Custom, rect = b.rect, box = b})
	}
	if .Draw_Text in b.flags && b.text != "" {
		tl := text_layout_for(b, b.fixed_size.x - st.padding.x * 2)
		o := Vec2{b.rect.x0 + st.padding.x, b.rect.y0 + st.padding.y}
		inner_w := b.fixed_size.x - st.padding.x * 2
		switch st.text_align {
		case .Left:
		case .Center:
			o.x += (inner_w - tl.width) / 2
		case .Right:
			o.x += inner_w - tl.width
		}
		if .Wrap_Text not_in b.flags {
			// vertically center single-line text
			o.y = b.rect.y0 + (b.fixed_size.y - tl.height) / 2
		}
		tl.origin = o
		if tl.spans != nil do draw_span_backgrounds(tl)
		if .Selectable_Text in b.flags do draw_selection_highlight(b, tl)
		c := st.text_color
		c.a *= alpha
		append(&s.draw, Draw_Cmd{kind = .Text, layout = tl, origin = o, colors = {c, c, c, c}, box = b})
	}
	clip := .Clip in b.flags
	if clip do append(&s.draw, Draw_Cmd{kind = .Clip_Push, rect = b.rect})
	for c := b.first; c != nil; c = c.next do emit_draw(c, in_overlay_pass)
	if clip do append(&s.draw, Draw_Cmd{kind = .Clip_Pop})
}

@(private)
emit_overlays :: proc(b: ^Box) {
	for c := b.first; c != nil; c = c.next {
		if .Overlay in c.flags {
			emit_draw(c, true)
		} else {
			emit_overlays(c)
		}
	}
}

// Has any box requested another frame (animation, smooth scroll)?
needs_frame :: proc() -> bool {return ui.animating}
cursor :: proc() -> Cursor {return ui.cursor}

// Concatenates span texts into the box text so selection/copy see them.
// The spans are copied, so callers may pass slice literals.
set_spans :: proc(b: ^Box, spans: []Span) {
	copied := make([]Span, len(spans), ui.frame_alloc)
	copy(copied, spans)
	b.spans = copied
	sb := strings.builder_make(ui.frame_alloc)
	for sp in spans do strings.write_string(&sb, sp.text)
	b.text = strings.to_string(sb)
	b.flags += {.Draw_Text}
}

@(private)
draw_span_backgrounds :: proc(tl: ^Text_Layout) {
	for l in tl.lines {
		gi := l.glyph_start
		for gi < l.glyph_end {
			si := tl.run.glyphs[gi].span
			start := gi
			for gi < l.glyph_end && tl.run.glyphs[gi].span == si do gi += 1
			sp := tl.spans[si]
			if sp.bg.a <= 0 do continue
			g0 := tl.run.glyphs[start]
			g1 := tl.run.glyphs[gi - 1]
			x0 := tl.origin.x + g0.x - l.x_shift
			x1 := tl.origin.x + g1.x + g1.advance - l.x_shift
			y0 := tl.origin.y + l.y
			r := Rect{x0 - 2, y0 + 1, x1 + 2, y0 + tl.line_h - 1}
			c := sp.bg
			append(&ui.draw, Draw_Cmd{kind = .Rect, rect = r, colors = {c, c, c, c}, radii = sp.bg_radius})
		}
	}
}
