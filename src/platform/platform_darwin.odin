#+build darwin
package platform

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"
import NS "core:sys/darwin/Foundation"
import "fc:platform/objc"
import CV "vendor:darwin/CoreVideo"

msg :: objc.msg
Void :: objc.Void
Id :: objc.Id

@(require) foreign import "system:Cocoa.framework"
@(require) foreign import "system:QuartzCore.framework"

@(private = "file")
NSRect :: NS.Rect
@(private = "file")
NSPoint :: NS.Point
@(private = "file")
NSSize :: NS.Size
@(private = "file")
NSRange :: NS.Range

@(private = "file")
NOT_FOUND :: NS.UInteger(NS.IntegerMax)

@(private = "file")
WAKE_SUBTYPE :: 0x4643 // 'FC'

@(private = "file")
Mac :: struct {
	app:             Id,
	window:          Id,
	view:            Id,
	layer:           Id,
	display_link:    Id, // CADisplayLink (macOS 14+)
	cv_link:         CV.DisplayLinkRef, // fallback
	link_paused:     bool,
	tick_pending:    bool,
	in_next_event:   bool, // inside nextEventMatchingMask (not inside a nested modal loop)
	wake_posted:     bool, // atomic
	marked:          string, // IME marked text (heap)
	cursor_hidden:   bool,
	last_mods:       Mods,
	pool:            Id, // autorelease pool spanning one app frame
	mouse_inside:    bool,
}

@(private = "file")
m: Mac

// ---------------------------------------------------------------------------
// Natives for gfx

native_window :: proc() -> rawptr {return rawptr(m.window)}
native_view :: proc() -> rawptr {return rawptr(m.view)}
// CAMetalLayer backing the content view (nil in headless mode).
native_metal_layer :: proc() -> rawptr {return rawptr(m.layer)}

// ---------------------------------------------------------------------------
// Small ObjC helpers

cls :: objc.cls
sel :: objc.sel

@(private = "file")
nsstr :: proc(str: string) -> Id {
	// Copies; autoreleased.
	s0 := msg(Id, cls("NSString"), "alloc")
	s1 := msg(Id, s0, "initWithBytes:length:encoding:", raw_data(str), NS.UInteger(len(str)), NS.UInteger(4) /*UTF8*/)
	return msg(Id, s1, "autorelease")
}

@(private = "file")
odin_str :: proc(nss: Id, allocator: runtime.Allocator) -> string {
	if nss == nil do return ""
	c := msg(cstring, nss, "UTF8String")
	if c == nil do return ""
	return strings.clone(string(c), allocator)
}

@(private = "file")
add_method :: proc(c: Id, name: cstring, imp: rawptr, types: cstring) {
	ok := objc.add_method(c, name, imp, types)
	assert(bool(ok), string(name))
}

@(private = "file")
responds :: proc(obj: Id, name: cstring) -> bool {
	return msg(NS.BOOL, obj, "respondsToSelector:", sel(name))
}

// ---------------------------------------------------------------------------
// Init

@(private)
_init :: proc(title: string, width, height: int) -> bool {
	m.pool = msg(Id, msg(Id, cls("NSAutoreleasePool"), "alloc"), "init")

	m.app = msg(Id, cls("NSApplication"), "sharedApplication")
	msg(NS.BOOL, m.app, "setActivationPolicy:", NS.Integer(0) /*Regular*/)

	register_classes()

	delegate := msg(Id, msg(Id, cls("FCAppDelegate"), "alloc"), "init")
	msg(Void, m.app, "setDelegate:", delegate)
	build_menu(title)

	style := NS.UInteger(1 | 2 | 4 | 8) // titled, closable, miniaturizable, resizable
	rect := NSRect{{0, 0}, {NS.Float(width), NS.Float(height)}}
	win := msg(Id, cls("NSWindow"), "alloc")
	m.window = msg(Id, win, "initWithContentRect:styleMask:backing:defer:", rect, style, NS.UInteger(2) /*buffered*/, NS.BOOL(false))
	msg(Void, m.window, "setReleasedWhenClosed:", NS.BOOL(false))
	msg(Void, m.window, "setTitle:", nsstr(title))
	msg(Void, m.window, "setAcceptsMouseMovedEvents:", NS.BOOL(true))
	msg(Void, m.window, "setRestorable:", NS.BOOL(false))
	msg(Void, m.window, "setTabbingMode:", NS.Integer(2) /*disallowed*/)
	wdel := msg(Id, msg(Id, cls("FCWindowDelegate"), "alloc"), "init")
	msg(Void, m.window, "setDelegate:", wdel)

	view := msg(Id, cls("FCView"), "alloc")
	m.view = msg(Id, view, "initWithFrame:", rect)
	msg(Void, m.view, "setWantsLayer:", NS.BOOL(true)) // makeBackingLayer -> CAMetalLayer
	msg(Void, m.view, "setLayerContentsRedrawPolicy:", NS.Integer(2) /*DuringViewResize*/)
	msg(Void, m.view, "setLayerContentsPlacement:", NS.Integer(11) /*TopLeft: never stretch stale frames*/)
	m.layer = msg(Id, m.view, "layer")
	msg(Void, m.window, "setContentView:", m.view)
	msg(NS.BOOL, m.window, "makeFirstResponder:", m.view)

	// File drops
	types := msg(Id, cls("NSArray"), "arrayWithObject:", nsstr("public.file-url"))
	msg(Void, m.view, "registerForDraggedTypes:", types)

	msg(Void, m.window, "center")
	msg(Void, m.app, "finishLaunching")
	msg(Void, m.window, "makeKeyAndOrderFront:", Id(nil))
	if responds(m.app, "activate") {
		msg(Void, m.app, "activate")
	} else {
		msg(Void, m.app, "activateIgnoringOtherApps:", NS.BOOL(true))
	}

	update_size_and_scale()
	update_refresh_rate()
	setup_display_link()
	return true
}

@(private)
_shutdown :: proc() {
	if m.display_link != nil do msg(Void, m.display_link, "invalidate")
	if m.cv_link != nil {
		CV.DisplayLinkStop(m.cv_link)
		CV.DisplayLinkRelease(m.cv_link)
	}
	if m.window != nil do msg(Void, m.window, "close")
}

@(private = "file")
build_menu :: proc(title: string) {
	bar := msg(Id, msg(Id, cls("NSMenu"), "alloc"), "init")
	app_item := msg(Id, msg(Id, cls("NSMenuItem"), "alloc"), "init")
	msg(Void, bar, "addItem:", app_item)
	app_menu := msg(Id, msg(Id, cls("NSMenu"), "alloc"), "init")
	msg(Id, app_menu, "addItemWithTitle:action:keyEquivalent:", nsstr("Hide"), sel("hide:"), nsstr("h"))
	msg(Id, app_menu, "addItemWithTitle:action:keyEquivalent:", nsstr(strings.concatenate({"Quit ", title}, context.temp_allocator)), sel("terminate:"), nsstr("q"))
	msg(Void, app_item, "setSubmenu:", app_menu)

	// Edit menu exists only for the system text services (emoji picker, dictation).
	// cmd+c/v/x/a/z are NOT menu items: they arrive as Key_Down events.
	edit_item := msg(Id, msg(Id, cls("NSMenuItem"), "alloc"), "init")
	msg(Void, bar, "addItem:", edit_item)
	edit_menu := msg(Id, msg(Id, cls("NSMenu"), "alloc"), "initWithTitle:", nsstr("Edit"))
	emoji := msg(Id, edit_menu, "addItemWithTitle:action:keyEquivalent:", nsstr("Emoji & Symbols"), sel("orderFrontCharacterPalette:"), nsstr(" "))
	msg(Void, emoji, "setKeyEquivalentModifierMask:", NS.UInteger((1 << 18) | (1 << 20)))
	msg(Void, edit_item, "setSubmenu:", edit_menu)

	msg(Void, m.app, "setMainMenu:", bar)
}

@(private = "file")
update_size_and_scale :: proc() {
	bounds := msg(NSRect, m.view, "bounds")
	scale := f32(msg(NS.Float, m.window, "backingScaleFactor"))
	if scale <= 0 do scale = 1
	s.size = {f32(bounds.size.width), f32(bounds.size.height)}
	s.scale = scale
	if m.layer != nil {
		msg(Void, m.layer, "setContentsScale:", NS.Float(scale))
		fb := framebuffer_size()
		msg(Void, m.layer, "setDrawableSize:", NSSize{NS.Float(max(fb.x, 1)), NS.Float(max(fb.y, 1))})
	}
}

@(private = "file")
update_refresh_rate :: proc() {
	screen := msg(Id, m.window, "screen")
	if screen == nil do screen = msg(Id, cls("NSScreen"), "mainScreen")
	hz: f32 = 60
	if screen != nil && responds(screen, "maximumFramesPerSecond") {
		n := msg(NS.Integer, screen, "maximumFramesPerSecond")
		if n > 0 do hz = f32(n)
	}
	s.refresh_hz = hz
	if m.display_link != nil {
		Frame_Rate_Range :: struct {minimum, maximum, preferred: f32}
		r := Frame_Rate_Range{min(hz, 60), hz, hz}
		msg(Void, m.display_link, "setPreferredFrameRateRange:", r)
	}
}

@(private = "file")
setup_display_link :: proc() {
	if responds(m.view, "displayLinkWithTarget:selector:") {
		m.display_link = msg(Id, m.view, "displayLinkWithTarget:selector:", m.view, sel("fcTick:"))
		msg(Id, m.display_link, "retain")
		update_refresh_rate()
		run_loop := msg(Id, cls("NSRunLoop"), "mainRunLoop")
		msg(Void, m.display_link, "addToRunLoop:forMode:", run_loop, NS.RunLoopCommonModes)
		msg(Void, m.display_link, "setPaused:", NS.BOOL(true))
		m.link_paused = true
	} else {
		if CV.DisplayLinkCreateWithActiveCGDisplays(&m.cv_link) == 0 {
			CV.DisplayLinkSetOutputCallback(m.cv_link, cv_callback, nil)
		}
		m.link_paused = true
	}
}

@(private = "file")
cv_callback :: proc "c" (link: CV.DisplayLinkRef, #by_ptr now: CV.TimeStamp, #by_ptr out_time: CV.TimeStamp, flags_in: CV.OptionFlags, flags_out: ^CV.OptionFlags, user: rawptr) -> CV.Return {
	context = s.ctx
	post_wake(1)
	return 0
}

@(private = "file")
set_link_paused :: proc(paused: bool) {
	if m.link_paused == paused do return
	m.link_paused = paused
	if m.display_link != nil {
		msg(Void, m.display_link, "setPaused:", paused)
	} else if m.cv_link != nil {
		if paused do CV.DisplayLinkStop(m.cv_link)
		else do CV.DisplayLinkStart(m.cv_link)
	}
}

// data1: 0 = wake, 1 = tick (CVDisplayLink thread)
@(private = "file")
post_wake :: proc(data1: int) {
	if data1 == 0 {
		if sync.atomic_exchange(&m.wake_posted, true) do return
	}
	ev := msg(Id, cls("NSEvent"), "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:",
		NS.UInteger(15) /*ApplicationDefined*/, NSPoint{}, NS.UInteger(0), NS.TimeInterval(0), NS.Integer(0), Id(nil), i16(WAKE_SUBTYPE), NS.Integer(data1), NS.Integer(0))
	msg(Void, m.app, "postEvent:atStart:", ev, NS.BOOL(false))
}

@(private)
_wake :: proc() {
	if sync.atomic_load(&s.frame_requested) && is_main_thread() {
		set_link_paused(false)
		return
	}
	post_wake(0)
}

@(private = "file")
is_main_thread :: proc() -> bool {
	return msg(NS.BOOL, cls("NSThread"), "isMainThread")
}

// ---------------------------------------------------------------------------
// Event loop

@(private)
_wait :: proc(timeout: f64) {
	// End the app frame's autorelease pool.
	if m.pool != nil {
		msg(Void, m.pool, "drain")
		m.pool = nil
	}
	defer m.pool = msg(Id, msg(Id, cls("NSAutoreleasePool"), "alloc"), "init")

	animating := sync.atomic_load(&s.frame_requested)
	if animating do set_link_paused(false)
	start := time_now()
	m.tick_pending = false

	for {
		pool := msg(Id, msg(Id, cls("NSAutoreleasePool"), "alloc"), "init")
		animating = sync.atomic_load(&s.frame_requested)
		if animating do set_link_paused(false)

		// Decide how long to block.
		have_input := pending_count() > 0
		done := s.quit || (animating ? m.tick_pending : have_input)
		until: Id
		if done || timeout == 0 {
			until = msg(Id, cls("NSDate"), "distantPast")
		} else if timeout < 0 {
			until = msg(Id, cls("NSDate"), "distantFuture")
		} else {
			remaining := timeout - (time_now() - start)
			if remaining <= 0 {
				until = msg(Id, cls("NSDate"), "distantPast")
				done = true
			} else {
				until = msg(Id, cls("NSDate"), "dateWithTimeIntervalSinceNow:", NS.TimeInterval(remaining))
			}
		}

		m.in_next_event = true
		ev := msg(Id, m.app, "nextEventMatchingMask:untilDate:inMode:dequeue:", NS.EventMaskAny, until, NS.DefaultRunLoopMode, NS.BOOL(true))
		m.in_next_event = false

		if ev == nil {
			msg(Void, pool, "drain")
			// Nothing left in the queue: either we were done (drained), or timed out.
			if done || timeout == 0 do break
			if timeout > 0 && time_now() - start >= timeout do break
			continue
		}

		type := msg(NS.UInteger, ev, "type")
		if type == 15 && msg(i16, ev, "subtype") == WAKE_SUBTYPE {
			if msg(NS.Integer, ev, "data1") == 1 {
				on_tick()
			} else {
				sync.atomic_store(&m.wake_posted, false)
				if sync.atomic_load(&s.frame_requested) do set_link_paused(false)
			}
		} else {
			msg(Void, m.app, "sendEvent:", ev)
		}
		msg(Void, pool, "drain")
	}
	if !sync.atomic_load(&s.frame_requested) {
		// Will be re-enabled by request_frame. Pausing here keeps idle at zero wakeups.
		set_link_paused(true)
	}
}

// Vsync tick (main thread).
@(private = "file")
on_tick :: proc() {
	if !sync.atomic_load(&s.frame_requested) {
		set_link_paused(true)
		return
	}
	if m.in_next_event {
		m.tick_pending = true
		return
	}
	// Inside a nested AppKit loop (live resize, title-bar drag, menu tracking):
	// our loop can't run, so render from here.
	pool := msg(Id, msg(Id, cls("NSAutoreleasePool"), "alloc"), "init")
	run_frame_callback()
	msg(Void, pool, "drain")
}

// ---------------------------------------------------------------------------
// Clipboard / cursor

@(private)
_clipboard_get :: proc(allocator: runtime.Allocator) -> string {
	pb := msg(Id, cls("NSPasteboard"), "generalPasteboard")
	str := msg(Id, pb, "stringForType:", nsstr("public.utf8-plain-text"))
	return odin_str(str, allocator)
}

@(private)
_clipboard_set :: proc(str: string) {
	pb := msg(Id, cls("NSPasteboard"), "generalPasteboard")
	msg(NS.Integer, pb, "clearContents")
	msg(NS.BOOL, pb, "setString:forType:", nsstr(str), nsstr("public.utf8-plain-text"))
}

@(private)
_apply_cursor :: proc() {
	if s.cursor == .Hidden {
		if !m.cursor_hidden {
			msg(Void, cls("NSCursor"), "hide")
			m.cursor_hidden = true
		}
		return
	}
	if m.cursor_hidden {
		msg(Void, cls("NSCursor"), "unhide")
		m.cursor_hidden = false
	}
	c := cls("NSCursor")
	name: cstring
	switch s.cursor {
	case .Arrow:       name = "arrowCursor"
	case .Pointer:     name = "pointingHandCursor"
	case .IBeam:       name = "IBeamCursor"
	case .Resize_H:    name = "resizeLeftRightCursor"
	case .Resize_V:    name = "resizeUpDownCursor"
	case .Resize_NWSE: name = "_windowResizeNorthWestSouthEastCursor"
	case .Resize_NESW: name = "_windowResizeNorthEastSouthWestCursor"
	case .Move:        name = "openHandCursor"
	case .Not_Allowed: name = "operationNotAllowedCursor"
	case .Crosshair:   name = "crosshairCursor"
	case .Hidden:      name = "arrowCursor"
	}
	if !msg(NS.BOOL, c, "respondsToSelector:", sel(name)) do name = "crosshairCursor"
	cur := msg_class_cursor(name)
	if cur != nil do msg(Void, cur, "set")
}

@(private = "file")
msg_class_cursor :: proc(name: cstring) -> Id {
	// Dynamic selector: objc_send needs a constant selector, so go through performSelector.
	return msg(Id, cls("NSCursor"), "performSelector:", sel(name))
}

// ---------------------------------------------------------------------------
// Input translation

@(private = "file")
mods_from_flags :: proc(flags: NS.UInteger) -> Mods {
	r: Mods
	if flags & (1 << 17) != 0 do r += {.Shift}
	if flags & (1 << 18) != 0 do r += {.Ctrl}
	if flags & (1 << 19) != 0 do r += {.Alt}
	if flags & (1 << 20) != 0 do r += {.Cmd}
	return r
}

@(private = "file")
keycode_table := [128]Key {
	0x00 = .A, 0x01 = .S, 0x02 = .D, 0x03 = .F, 0x04 = .H, 0x05 = .G, 0x06 = .Z, 0x07 = .X,
	0x08 = .C, 0x09 = .V, 0x0B = .B, 0x0C = .Q, 0x0D = .W, 0x0E = .E, 0x0F = .R,
	0x10 = .Y, 0x11 = .T, 0x12 = .N1, 0x13 = .N2, 0x14 = .N3, 0x15 = .N4, 0x16 = .N6, 0x17 = .N5,
	0x18 = .Equals, 0x19 = .N9, 0x1A = .N7, 0x1B = .Minus, 0x1C = .N8, 0x1D = .N0, 0x1E = .Right_Bracket, 0x1F = .O,
	0x20 = .U, 0x21 = .Left_Bracket, 0x22 = .I, 0x23 = .P, 0x24 = .Enter, 0x25 = .L, 0x26 = .J, 0x27 = .Apostrophe,
	0x28 = .K, 0x29 = .Semicolon, 0x2A = .Backslash, 0x2B = .Comma, 0x2C = .Slash, 0x2D = .N, 0x2E = .M, 0x2F = .Period,
	0x30 = .Tab, 0x31 = .Space, 0x32 = .Grave, 0x33 = .Backspace, 0x35 = .Escape,
	0x36 = .Cmd, 0x37 = .Cmd, 0x38 = .Shift, 0x39 = .Caps_Lock, 0x3A = .Alt, 0x3B = .Ctrl, 0x3C = .Shift, 0x3D = .Alt, 0x3E = .Ctrl,
	0x4C = .Keypad_Enter,
	0x60 = .F5, 0x61 = .F6, 0x62 = .F7, 0x63 = .F3, 0x64 = .F8, 0x65 = .F9, 0x67 = .F11, 0x6D = .F10, 0x6F = .F12,
	0x73 = .Home, 0x74 = .Page_Up, 0x75 = .Delete, 0x76 = .F4, 0x77 = .End, 0x78 = .F2, 0x79 = .Page_Down, 0x7A = .F1,
	0x7B = .Left, 0x7C = .Right, 0x7D = .Down, 0x7E = .Up,
}

@(private = "file")
key_from_event :: proc(ev: Id) -> Key {
	code := msg(u16, ev, "keyCode")
	k := code < 128 ? keycode_table[code] : .None
	// Letters follow the active keyboard layout (Dvorak, AZERTY...) so cmd+c means "c".
	if (k >= .A && k <= .Z) || k == .None || (k >= .N0 && k <= .N9) {
		chars := msg(Id, ev, "charactersIgnoringModifiers")
		if chars != nil && msg(NS.UInteger, chars, "length") == 1 {
			ch := msg(u16, chars, "characterAtIndex:", NS.UInteger(0))
			switch ch {
			case 'a' ..= 'z': k = Key(int(Key.A) + int(ch - 'a'))
			case 'A' ..= 'Z': k = Key(int(Key.A) + int(ch - 'A'))
			}
		}
	}
	return k
}

@(private = "file")
mouse_pos :: proc(ev: Id) -> [2]f32 {
	p := msg(NSPoint, ev, "locationInWindow")
	v := msg(NSPoint, m.view, "convertPoint:fromView:", p, Id(nil)) // view is flipped: top-left origin
	return {f32(v.x), f32(v.y)}
}

@(private = "file")
event_time :: proc(ev: Id) -> f64 {return time_now()}

@(private = "file")
push_mouse :: proc(kind: Event_Kind, ev: Id) {
	e := Event{kind = kind, pos = mouse_pos(ev), mods = mods_from_flags(msg(NS.UInteger, ev, "modifierFlags")), time = event_time(ev)}
	if kind == .Mouse_Down || kind == .Mouse_Up {
		n := msg(NS.Integer, ev, "buttonNumber")
		switch n {
		case 0: e.button = .Left
		case 1: e.button = .Right
		case 2: e.button = .Middle
		case 3: e.button = .X1
		case:   e.button = .X2
		}
		// ctrl+click is a right click on macOS
		if e.button == .Left && .Ctrl in e.mods && kind == .Mouse_Down do e.button = .Right
		e.click_count = int(msg(NS.Integer, ev, "clickCount"))
	}
	if kind == .Mouse_Move && s.cursor != .Arrow do _apply_cursor_force()
	push_event(e)
}

@(private = "file")
_apply_cursor_force :: proc() {_apply_cursor()}

@(private = "file")
phase_from :: proc(p: NS.UInteger) -> Scroll_Phase {
	if p & 1 != 0 do return .Began
	if p & 4 != 0 do return .Changed
	if p & 8 != 0 do return .Ended
	if p & 16 != 0 do return .Cancelled
	if p & 32 != 0 do return .May_Begin
	if p & 2 != 0 do return .Changed
	return .None
}

// utf16 index -> byte offset in str (for IME selection ranges)
@(private = "file")
utf16_to_byte :: proc(str: string, idx16: int) -> int {
	n := 0
	for r, i in str {
		if n >= idx16 do return i
		n += r >= 0x10000 ? 2 : 1
	}
	return len(str)
}

@(private = "file")
string_from_text_arg :: proc(arg: Id) -> string {
	if arg == nil do return ""
	str := arg
	if msg(NS.BOOL, arg, "isKindOfClass:", cls("NSAttributedString")) {
		str = msg(Id, arg, "string")
	}
	return odin_str(str, context.temp_allocator)
}

// ---------------------------------------------------------------------------
// ObjC classes

@(private = "file")
register_classes :: proc() {
	if cls("FCView") != nil do return

	// ---- FCView : NSView <NSTextInputClient>
	v := objc.allocate_class(cls("NSView"), "FCView")
	add_method(v, "acceptsFirstResponder", rawptr(view_yes), "B@:")
	add_method(v, "canBecomeKeyView", rawptr(view_yes), "B@:")
	add_method(v, "acceptsFirstMouse:", rawptr(view_yes1), "B@:@")
	add_method(v, "isFlipped", rawptr(view_yes), "B@:")
	add_method(v, "isOpaque", rawptr(view_yes), "B@:")
	add_method(v, "wantsUpdateLayer", rawptr(view_yes), "B@:")
	add_method(v, "updateLayer", rawptr(view_update_layer), "v@:")
	add_method(v, "makeBackingLayer", rawptr(view_make_backing_layer), "@@:")
	add_method(v, "setFrameSize:", rawptr(view_set_frame_size), "v@:{CGSize=dd}")
	add_method(v, "viewDidChangeBackingProperties", rawptr(view_did_change_backing), "v@:")
	add_method(v, "viewWillStartLiveResize", rawptr(view_will_start_live_resize), "v@:")
	add_method(v, "viewDidEndLiveResize", rawptr(view_did_end_live_resize), "v@:")
	add_method(v, "updateTrackingAreas", rawptr(view_update_tracking_areas), "v@:")
	add_method(v, "fcTick:", rawptr(view_tick), "v@:@")

	add_method(v, "keyDown:", rawptr(view_key_down), "v@:@")
	add_method(v, "keyUp:", rawptr(view_key_up), "v@:@")
	add_method(v, "flagsChanged:", rawptr(view_flags_changed), "v@:@")
	add_method(v, "mouseDown:", rawptr(view_mouse_down), "v@:@")
	add_method(v, "mouseUp:", rawptr(view_mouse_up), "v@:@")
	add_method(v, "rightMouseDown:", rawptr(view_mouse_down), "v@:@")
	add_method(v, "rightMouseUp:", rawptr(view_mouse_up), "v@:@")
	add_method(v, "otherMouseDown:", rawptr(view_mouse_down), "v@:@")
	add_method(v, "otherMouseUp:", rawptr(view_mouse_up), "v@:@")
	add_method(v, "mouseMoved:", rawptr(view_mouse_moved), "v@:@")
	add_method(v, "mouseDragged:", rawptr(view_mouse_moved), "v@:@")
	add_method(v, "rightMouseDragged:", rawptr(view_mouse_moved), "v@:@")
	add_method(v, "otherMouseDragged:", rawptr(view_mouse_moved), "v@:@")
	add_method(v, "mouseEntered:", rawptr(view_mouse_entered), "v@:@")
	add_method(v, "mouseExited:", rawptr(view_mouse_exited), "v@:@")
	add_method(v, "scrollWheel:", rawptr(view_scroll), "v@:@")
	add_method(v, "cursorUpdate:", rawptr(view_cursor_update), "v@:@")

	// NSTextInputClient
	add_method(v, "hasMarkedText", rawptr(ti_has_marked), "B@:")
	add_method(v, "markedRange", rawptr(ti_marked_range), "{_NSRange=QQ}@:")
	add_method(v, "selectedRange", rawptr(ti_selected_range), "{_NSRange=QQ}@:")
	add_method(v, "setMarkedText:selectedRange:replacementRange:", rawptr(ti_set_marked), "v@:@{_NSRange=QQ}{_NSRange=QQ}")
	add_method(v, "unmarkText", rawptr(ti_unmark), "v@:")
	add_method(v, "validAttributesForMarkedText", rawptr(ti_valid_attrs), "@@:")
	add_method(v, "attributedSubstringForProposedRange:actualRange:", rawptr(ti_attr_substring), "@@:{_NSRange=QQ}^{_NSRange=QQ}")
	add_method(v, "insertText:replacementRange:", rawptr(ti_insert_text), "v@:@{_NSRange=QQ}")
	add_method(v, "insertText:", rawptr(ti_insert_text_simple), "v@:@")
	add_method(v, "characterIndexForPoint:", rawptr(ti_char_index), "Q@:{CGPoint=dd}")
	add_method(v, "firstRectForCharacterRange:actualRange:", rawptr(ti_first_rect), "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}")
	add_method(v, "doCommandBySelector:", rawptr(ti_do_command), "v@::")

	// Drag and drop
	add_method(v, "draggingEntered:", rawptr(dnd_entered), "Q@:@")
	add_method(v, "draggingUpdated:", rawptr(dnd_entered), "Q@:@")
	add_method(v, "performDragOperation:", rawptr(dnd_perform), "B@:@")

	if p := objc.objc_getProtocol("NSTextInputClient"); p != nil do objc.class_addProtocol(v, p)
	objc.register_class(v)

	// ---- FCWindowDelegate
	w := objc.allocate_class(cls("NSObject"), "FCWindowDelegate")
	add_method(w, "windowShouldClose:", rawptr(win_should_close), "B@:@")
	add_method(w, "windowDidBecomeKey:", rawptr(win_did_become_key), "v@:@")
	add_method(w, "windowDidResignKey:", rawptr(win_did_resign_key), "v@:@")
	add_method(w, "windowDidChangeScreen:", rawptr(win_did_change_screen), "v@:@")
	add_method(w, "windowDidChangeBackingProperties:", rawptr(win_did_change_screen), "v@:@")
	objc.register_class(w)

	// ---- FCAppDelegate
	a := objc.allocate_class(cls("NSObject"), "FCAppDelegate")
	add_method(a, "applicationShouldTerminate:", rawptr(app_should_terminate), "Q@:@")
	add_method(a, "applicationShouldTerminateAfterLastWindowClosed:", rawptr(view_no1), "B@:@")
	objc.register_class(a)
}

@(private = "file")
view_yes :: proc "c" (self: Id, cmd: objc.SEL) -> NS.BOOL {return true}
@(private = "file")
view_yes1 :: proc "c" (self: Id, cmd: objc.SEL, a: Id) -> NS.BOOL {return true}
@(private = "file")
view_no1 :: proc "c" (self: Id, cmd: objc.SEL, a: Id) -> NS.BOOL {return false}
@(private = "file")
view_update_layer :: proc "c" (self: Id, cmd: objc.SEL) {}

@(private = "file")
view_make_backing_layer :: proc "c" (self: Id, cmd: objc.SEL) -> Id {
	layer := msg(Id, cls("CAMetalLayer"), "layer")
	msg(Void, layer, "setFramebufferOnly:", NS.BOOL(true))
	msg(Void, layer, "setOpaque:", NS.BOOL(true))
	msg(Void, layer, "setNeedsDisplayOnBoundsChange:", NS.BOOL(false))
	msg(Void, layer, "setPixelFormat:", NS.UInteger(80) /*BGRA8Unorm*/)
	msg(Void, layer, "setMaximumDrawableCount:", NS.UInteger(3))
	if msg(NS.BOOL, layer, "respondsToSelector:", sel("setDisplaySyncEnabled:")) {
		msg(Void, layer, "setDisplaySyncEnabled:", NS.BOOL(true))
	}
	// Don't let CA animate resizes/scale changes of our content.
	msg(Void, layer, "setActions:", msg(Id, cls("NSDictionary"), "dictionary"))
	return layer
}

@(private = "file")
call_super_set_frame_size :: proc "c" (self: Id, size: NSSize) {
	imp := objc.class_getMethodImplementation(cls("NSView"), sel("setFrameSize:"))
	f := cast(proc "c" (self: Id, cmd: objc.SEL, size: NSSize))imp
	f(self, sel("setFrameSize:"), size)
}

@(private = "file")
view_set_frame_size :: proc "c" (self: Id, cmd: objc.SEL, size: NSSize) {
	call_super_set_frame_size(self, size)
	context = s.ctx
	if m.view == nil || self != m.view do return
	old := s.size
	update_size_and_scale()
	if old != s.size {
		push_event({kind = .Resize, pos = s.size, time = time_now()})
		if msg(NS.BOOL, self, "inLiveResize") {
			pool := msg(Id, msg(Id, cls("NSAutoreleasePool"), "alloc"), "init")
			run_frame_callback()
			msg(Void, pool, "drain")
		}
	}
}

@(private = "file")
view_did_change_backing :: proc "c" (self: Id, cmd: objc.SEL) {
	context = s.ctx
	if m.view == nil do return
	old_scale := s.scale
	update_size_and_scale()
	update_refresh_rate()
	if old_scale != s.scale do push_event({kind = .Resize, pos = s.size, time = time_now()})
}

@(private = "file")
view_will_start_live_resize :: proc "c" (self: Id, cmd: objc.SEL) {
	context = s.ctx
	// Present inside the CA transaction that resizes the window: no stretching or tearing.
	if m.layer != nil do msg(Void, m.layer, "setPresentsWithTransaction:", NS.BOOL(true))
}

@(private = "file")
view_did_end_live_resize :: proc "c" (self: Id, cmd: objc.SEL) {
	context = s.ctx
	if m.layer != nil do msg(Void, m.layer, "setPresentsWithTransaction:", NS.BOOL(false))
	push_event({kind = .Resize, pos = s.size, time = time_now()})
}

@(private = "file")
view_update_tracking_areas :: proc "c" (self: Id, cmd: objc.SEL) {
	context = s.ctx
	areas := msg(Id, self, "trackingAreas")
	n := msg(NS.UInteger, areas, "count")
	for i := int(n) - 1; i >= 0; i -= 1 {
		a := msg(Id, areas, "objectAtIndex:", NS.UInteger(i))
		msg(Void, self, "removeTrackingArea:", a)
	}
	// MouseEnteredAndExited | MouseMoved | CursorUpdate | ActiveAlways | InVisibleRect | EnabledDuringMouseDrag
	opts := NS.UInteger(0x01 | 0x02 | 0x04 | 0x80 | 0x200 | 0x400)
	bounds := msg(NSRect, self, "bounds")
	area := msg(Id, msg(Id, cls("NSTrackingArea"), "alloc"), "initWithRect:options:owner:userInfo:", bounds, opts, self, Id(nil))
	msg(Void, self, "addTrackingArea:", area)
	msg(Void, area, "release")
	imp := objc.class_getMethodImplementation(cls("NSView"), sel("updateTrackingAreas"))
	f := cast(proc "c" (self: Id, cmd: objc.SEL))imp
	f(self, sel("updateTrackingAreas"))
}

@(private = "file")
view_tick :: proc "c" (self: Id, cmd: objc.SEL, link: Id) {
	context = s.ctx
	on_tick()
	// Wake nextEventMatchingMask so _wait sees tick_pending.
	if m.in_next_event && m.tick_pending do post_wake(0)
}

@(private = "file")
view_key_down :: proc "c" (self: Id, cmd: objc.SEL, ev: Id) {
	context = s.ctx
	flags := msg(NS.UInteger, ev, "modifierFlags")
	e := Event {
		kind      = .Key_Down,
		key       = key_from_event(ev),
		mods      = mods_from_flags(flags),
		is_repeat = msg(NS.BOOL, ev, "isARepeat"),
		time      = time_now(),
	}
	had_marked := len(m.marked) > 0
	idx := pending_count()
	if .Cmd not_in e.mods {
		arr := msg(Id, cls("NSArray"), "arrayWithObject:", ev)
		msg(Void, self, "interpretKeyEvents:", arr)
	}
	consumed_by_ime := had_marked || len(m.marked) > 0
	if !consumed_by_ime {
		sync.mutex_lock(&s.queue_lock)
		inject_at(&s.pending, min(idx, len(s.pending)), e)
		sync.mutex_unlock(&s.queue_lock)
	}
}

@(private = "file")
view_key_up :: proc "c" (self: Id, cmd: objc.SEL, ev: Id) {
	context = s.ctx
	push_event({kind = .Key_Up, key = key_from_event(ev), mods = mods_from_flags(msg(NS.UInteger, ev, "modifierFlags")), time = time_now()})
}

@(private = "file")
view_flags_changed :: proc "c" (self: Id, cmd: objc.SEL, ev: Id) {
	context = s.ctx
	mods := mods_from_flags(msg(NS.UInteger, ev, "modifierFlags"))
	code := msg(u16, ev, "keyCode")
	k := code < 128 ? keycode_table[code] : .None
	mod: Maybe(Mod)
	#partial switch k {
	case .Shift: mod = .Shift
	case .Ctrl:  mod = .Ctrl
	case .Alt:   mod = .Alt
	case .Cmd:   mod = .Cmd
	}
	if md, ok := mod.?; ok {
		down := md in mods
		push_event({kind = down ? .Key_Down : .Key_Up, key = k, mods = mods, time = time_now()})
	}
	m.last_mods = mods
}

@(private = "file")
view_mouse_down :: proc "c" (self: Id, cmd: objc.SEL, ev: Id) {context = s.ctx; push_mouse(.Mouse_Down, ev)}
@(private = "file")
view_mouse_up :: proc "c" (self: Id, cmd: objc.SEL, ev: Id) {context = s.ctx; push_mouse(.Mouse_Up, ev)}
@(private = "file")
view_mouse_moved :: proc "c" (self: Id, cmd: objc.SEL, ev: Id) {context = s.ctx; push_mouse(.Mouse_Move, ev)}
@(private = "file")
view_mouse_entered :: proc "c" (self: Id, cmd: objc.SEL, ev: Id) {
	context = s.ctx
	m.mouse_inside = true
	_apply_cursor()
	push_mouse(.Mouse_Move, ev)
}
@(private = "file")
view_mouse_exited :: proc "c" (self: Id, cmd: objc.SEL, ev: Id) {
	context = s.ctx
	m.mouse_inside = false
	if m.cursor_hidden {
		msg(Void, cls("NSCursor"), "unhide")
		m.cursor_hidden = false
	}
	push_event({kind = .Mouse_Leave, pos = mouse_pos(ev), time = time_now()})
}
@(private = "file")
view_cursor_update :: proc "c" (self: Id, cmd: objc.SEL, ev: Id) {context = s.ctx; _apply_cursor()}

@(private = "file")
view_scroll :: proc "c" (self: Id, cmd: objc.SEL, ev: Id) {
	context = s.ctx
	dx := f32(msg(NS.Float, ev, "scrollingDeltaX"))
	dy := f32(msg(NS.Float, ev, "scrollingDeltaY"))
	precise := msg(NS.BOOL, ev, "hasPreciseScrollingDeltas")
	if !precise {
		dx *= 40 // Chrome: 40px per wheel tick
		dy *= 40
	}
	phase := msg(NS.UInteger, ev, "phase")
	momentum := msg(NS.UInteger, ev, "momentumPhase")
	e := Event {
		kind         = .Scroll,
		pos          = mouse_pos(ev),
		delta        = {dx, dy},
		mods         = mods_from_flags(msg(NS.UInteger, ev, "modifierFlags")),
		precise      = precise,
		momentum     = momentum != 0,
		scroll_phase = momentum != 0 ? phase_from(momentum) : phase_from(phase),
		time         = time_now(),
	}
	push_event(e)
}

// ---- NSTextInputClient

@(private = "file")
ti_has_marked :: proc "c" (self: Id, cmd: objc.SEL) -> NS.BOOL {return len(m.marked) > 0}

@(private = "file")
utf16_len :: proc "contextless" (str: string) -> int {
	n := 0
	for i := 0; i < len(str); {
		r, w := utf8.decode_rune_in_string(str[i:])
		n += r >= 0x10000 ? 2 : 1
		i += max(w, 1)
	}
	return n
}

@(private = "file")
ti_marked_range :: proc "c" (self: Id, cmd: objc.SEL) -> NSRange {
	if len(m.marked) == 0 do return {NOT_FOUND, 0}
	return {0, NS.UInteger(utf16_len(m.marked))}
}

@(private = "file")
ti_selected_range :: proc "c" (self: Id, cmd: objc.SEL) -> NSRange {
	if len(m.marked) == 0 do return {0, 0}
	return {NS.UInteger(utf16_len(m.marked)), 0}
}

@(private = "file")
ti_set_marked :: proc "c" (self: Id, cmd: objc.SEL, str: Id, sel_range: NSRange, repl: NSRange) {
	context = s.ctx
	text := string_from_text_arg(str)
	delete(m.marked)
	m.marked = strings.clone(text)
	a := utf16_to_byte(text, int(sel_range.location))
	b := utf16_to_byte(text, int(sel_range.location + sel_range.length))
	push_event({kind = .Composition, text = text, composition_sel = {a, b}, time = time_now()})
}

@(private = "file")
ti_unmark :: proc "c" (self: Id, cmd: objc.SEL) {
	context = s.ctx
	if len(m.marked) > 0 {
		delete(m.marked)
		m.marked = ""
		push_event({kind = .Composition, time = time_now()})
	}
}

@(private = "file")
ti_valid_attrs :: proc "c" (self: Id, cmd: objc.SEL) -> Id {
	return msg(Id, cls("NSArray"), "array")
}

@(private = "file")
ti_attr_substring :: proc "c" (self: Id, cmd: objc.SEL, r: NSRange, actual: ^NSRange) -> Id {return nil}

@(private = "file")
ti_insert_text :: proc "c" (self: Id, cmd: objc.SEL, str: Id, repl: NSRange) {
	context = s.ctx
	text := string_from_text_arg(str)
	if len(m.marked) > 0 {
		delete(m.marked)
		m.marked = ""
		push_event({kind = .Composition, time = time_now()})
	}
	if len(text) == 0 do return
	// Drop control chars and AppKit's private-use function-key characters.
	r, _ := utf8.decode_rune_in_string(text)
	if len(text) == utf8.rune_size(r) && (r < 0x20 || r == 0x7f || (r >= 0xF700 && r <= 0xF8FF)) do return
	push_event({kind = .Text, text = text, time = time_now()})
}

@(private = "file")
ti_insert_text_simple :: proc "c" (self: Id, cmd: objc.SEL, str: Id) {
	ti_insert_text(self, cmd, str, {NOT_FOUND, 0})
}

@(private = "file")
ti_char_index :: proc "c" (self: Id, cmd: objc.SEL, p: NSPoint) -> NS.UInteger {return NOT_FOUND}

@(private = "file")
ti_first_rect :: proc "c" (self: Id, cmd: objc.SEL, r: NSRange, actual: ^NSRange) -> NSRect {
	context = s.ctx
	if actual != nil do actual^ = r
	ir := s.ime_rect
	// view (flipped) -> window -> screen
	local := NSRect{{NS.Float(ir[0]), NS.Float(ir[1])}, {NS.Float(max(ir[2], 1)), NS.Float(max(ir[3], 1))}}
	in_win := msg(NSRect, m.view, "convertRect:toView:", local, Id(nil))
	return msg(NSRect, m.window, "convertRectToScreen:", in_win)
}

@(private = "file")
ti_do_command :: proc "c" (self: Id, cmd: objc.SEL, command: objc.SEL) {
	// Swallow: keys are delivered as Key_Down events; don't beep.
}

// ---- Drag and drop

@(private = "file")
dnd_entered :: proc "c" (self: Id, cmd: objc.SEL, info: Id) -> NS.UInteger {return 1 /*Copy*/}

@(private = "file")
dnd_perform :: proc "c" (self: Id, cmd: objc.SEL, info: Id) -> NS.BOOL {
	context = s.ctx
	pb := msg(Id, info, "draggingPasteboard")
	p := msg(NSPoint, info, "draggingLocation")
	v := msg(NSPoint, m.view, "convertPoint:fromView:", p, Id(nil))
	classes := msg(Id, cls("NSArray"), "arrayWithObject:", cls("NSURL"))
	urls := msg(Id, pb, "readObjectsForClasses:options:", classes, Id(nil))
	if urls == nil do return false
	n := msg(NS.UInteger, urls, "count")
	for i in 0 ..< n {
		u := msg(Id, urls, "objectAtIndex:", NS.UInteger(i))
		if !msg(NS.BOOL, u, "isFileURL") do continue
		path := odin_str(msg(Id, u, "path"), context.temp_allocator)
		push_event({kind = .File_Drop, text = path, pos = {f32(v.x), f32(v.y)}, time = time_now()})
	}
	return true
}

// ---- Window / app delegates

@(private = "file")
win_should_close :: proc "c" (self: Id, cmd: objc.SEL, sender: Id) -> NS.BOOL {
	context = s.ctx
	s.quit = true
	push_event({kind = .Quit, time = time_now()})
	return false // the app decides; it will exit its loop
}

@(private = "file")
win_did_become_key :: proc "c" (self: Id, cmd: objc.SEL, n: Id) {
	context = s.ctx
	push_event({kind = .Focus_Gained, time = time_now()})
}

@(private = "file")
win_did_resign_key :: proc "c" (self: Id, cmd: objc.SEL, n: Id) {
	context = s.ctx
	push_event({kind = .Focus_Lost, time = time_now()})
}

@(private = "file")
win_did_change_screen :: proc "c" (self: Id, cmd: objc.SEL, n: Id) {
	context = s.ctx
	if m.view == nil do return
	update_size_and_scale()
	update_refresh_rate()
}

@(private = "file")
app_should_terminate :: proc "c" (self: Id, cmd: objc.SEL, sender: Id) -> NS.UInteger {
	context = s.ctx
	s.quit = true
	push_event({kind = .Quit, time = time_now()})
	return 0 // NSTerminateCancel; the app exits its own loop
}
