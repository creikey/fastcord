msg :: objc.msg;
Void :: objc.Void;
Id :: objc.Id;
#scope_file
	kCGColorSpaceSRGB: *void #elsewhere coregraphics; // CFStringRef
	CGColorSpaceCreateWithName :: (name: *void) -> *void #foreign coregraphics;
	CGColorSpaceRelease :: (cs: *void) #foreign coregraphics;

NSRect :: NS.Rect;
NSPoint :: NS.Point;
NSSize :: NS.Size;
NSRange :: NS.Range;

NOT_FOUND :: cast(NS.UInteger)(NS.IntegerMax);

WAKE_SUBTYPE :: 0x4643;
#scope_export
#scope_file // 'FC'

Mac :: struct {
	app: Id;
	window: Id;
	view: Id;
	layer: Id;
	display_link: Id; // CADisplayLink (macOS 14+)
	cv_link: CVDisplayLinkRef; // fallback
	link_paused: bool;
	tick_pending: bool;
	in_next_event: bool; // inside nextEventMatchingMask (not inside a nested modal loop)
	wake_posted: bool; // atomic
	marked: string; // IME marked text (heap)
	cursor_hidden: bool;
	last_mods: Mods;
	pool: Id; // autorelease pool spanning one app frame
	mouse_inside: bool;
}
#scope_file

m: Mac;
#scope_export

// ---------------------------------------------------------------------------
// Natives for gfx

native_window :: () -> *void {return cast(*void)(m.window);}
native_view :: () -> *void {return cast(*void)(m.view);}
// CAMetalLayer backing the content view (nil in headless mode).
native_metal_layer :: () -> *void {return cast(*void)(m.layer);}

// set_capture_hidden: NSWindow.sharingType None (Electron's setContentProtection) or ReadOnly.
set_capture_hidden :: (hidden: bool) {
	if m.window != null { msg(Void, m.window, "setSharingType:", cast(NS.UInteger)(ifx hidden then 0 else 1)); }
}

// ---------------------------------------------------------------------------
// Small ObjC helpers

cls :: objc.cls;
sel :: objc.sel;
#scope_module

nsstr :: (str: string) -> Id {
	// Copies; autoreleased.
	s0 := msg(Id, cls("NSString"), "alloc");
	s1 := msg(Id, s0, "initWithBytes:length:encoding:", raw_data(str), cast(NS.UInteger)(len(str)), cast(NS.UInteger)(4) /*UTF8*/);
	return msg(Id, s1, "autorelease");
}

odin_str :: (nss: Id, allocator: Allocator) -> string {
	if nss == null { return ""; }
	c := msg(*u8, nss, "UTF8String");
	if c == null { return ""; }
	return clone(as_string(c), allocator);
}
#scope_file

add_method :: (c: Id, name: *u8, imp: *void, types: *u8) {
	ok := objc.add_method(c, name, imp, types);
	assert(cast(bool)(ok), as_string(name));
}

responds :: (obj: Id, name: *u8) -> bool {
	return msg(NS.BOOL, obj, "respondsToSelector:", sel(name));
}
#scope_module

// ---------------------------------------------------------------------------
// Init

_init :: (title: string, width: int, height: int) -> bool {
	m.pool = msg(Id, msg(Id, cls("NSAutoreleasePool"), "alloc"), "init");

	m.app = msg(Id, cls("NSApplication"), "sharedApplication");
	msg(NS.BOOL, m.app, "setActivationPolicy:", cast(NS.Integer)(0) /*Regular*/);

	register_classes();

	delegate := msg(Id, msg(Id, cls("FCAppDelegate"), "alloc"), "init");
	msg(Void, m.app, "setDelegate:", delegate);
	build_menu(title);

	style := cast(NS.UInteger)(1 | 2 | 4 | 8); // titled, closable, miniaturizable, resizable
	rect := NSRect.{.{0, 0}, .{cast(NS.Float)(width), cast(NS.Float)(height)}};
	win := msg(Id, cls("NSWindow"), "alloc");
	m.window = msg(Id, win, "initWithContentRect:styleMask:backing:defer:", rect, style, cast(NS.UInteger)(2), cast(NS.BOOL)(false));
	msg(Void, m.window, "setReleasedWhenClosed:", cast(NS.BOOL)(false));
	msg(Void, m.window, "setTitle:", nsstr(title));
	msg(Void, m.window, "setAcceptsMouseMovedEvents:", cast(NS.BOOL)(true));
	msg(Void, m.window, "setRestorable:", cast(NS.BOOL)(false));
	msg(Void, m.window, "setTabbingMode:", cast(NS.Integer)(2) /*disallowed*/);
	msg(Void, m.window, "setContentMinSize:", NSSize.{MIN_WINDOW_W, MIN_WINDOW_H});
	wdel := msg(Id, msg(Id, cls("FCWindowDelegate"), "alloc"), "init");
	msg(Void, m.window, "setDelegate:", wdel);

	view := msg(Id, cls("FCView"), "alloc");
	m.view = msg(Id, view, "initWithFrame:", rect);
	msg(Void, m.view, "setWantsLayer:", cast(NS.BOOL)(true)); // makeBackingLayer -> CAMetalLayer
	msg(Void, m.view, "setLayerContentsRedrawPolicy:", cast(NS.Integer)(2) /*DuringViewResize*/);
	msg(Void, m.view, "setLayerContentsPlacement:", cast(NS.Integer)(11) /*TopLeft: never stretch stale frames*/);
	m.layer = msg(Id, m.view, "layer");
	msg(Void, m.window, "setContentView:", m.view);
	msg(NS.BOOL, m.window, "makeFirstResponder:", m.view);

	// File drops
	types := msg(Id, cls("NSArray"), "arrayWithObject:", nsstr("public.file-url"));
	msg(Void, m.view, "registerForDraggedTypes:", types);

	msg(Void, m.window, "center");
	msg(Void, m.app, "finishLaunching");
	msg(Void, m.window, "makeKeyAndOrderFront:", cast(Id)(null));
	if responds(m.app, "activate") {
		msg(Void, m.app, "activate");
	} else {
		msg(Void, m.app, "activateIgnoringOtherApps:", cast(NS.BOOL)(true));
	}

	update_size_and_scale();
	update_refresh_rate();
	setup_display_link();
	return true;
}

_shutdown :: () {
	if m.display_link != null { msg(Void, m.display_link, "invalidate"); }
	if m.cv_link != null {
		CVDisplayLinkStop(m.cv_link);
		CVDisplayLinkRelease(m.cv_link);
	}
	if m.window != null { msg(Void, m.window, "close"); }
}
#scope_file

build_menu :: (title: string) {
	bar := msg(Id, msg(Id, cls("NSMenu"), "alloc"), "init");
	app_item := msg(Id, msg(Id, cls("NSMenuItem"), "alloc"), "init");
	msg(Void, bar, "addItem:", app_item);
	app_menu := msg(Id, msg(Id, cls("NSMenu"), "alloc"), "init");
	msg(Id, app_menu, "addItemWithTitle:action:keyEquivalent:", nsstr("Hide"), sel("hide:"), nsstr("h"));
	msg(Id, app_menu, "addItemWithTitle:action:keyEquivalent:", nsstr(strings.concatenate(string.["Quit ", title], temp)), sel("terminate:"), nsstr("q"));
	msg(Void, app_item, "setSubmenu:", app_menu);

	// Edit menu exists only for the system text services (emoji picker, dictation).
	// cmd+c/v/x/a/z are NOT menu items: they arrive as Key_Down events.
	edit_item := msg(Id, msg(Id, cls("NSMenuItem"), "alloc"), "init");
	msg(Void, bar, "addItem:", edit_item);
	edit_menu := msg(Id, msg(Id, cls("NSMenu"), "alloc"), "initWithTitle:", nsstr("Edit"));
	emoji := msg(Id, edit_menu, "addItemWithTitle:action:keyEquivalent:", nsstr("Emoji & Symbols"), sel("orderFrontCharacterPalette:"), nsstr(" "));
	msg(Void, emoji, "setKeyEquivalentModifierMask:", cast(NS.UInteger)((1 << 18) | (1 << 20)));
	msg(Void, edit_item, "setSubmenu:", edit_menu);

	msg(Void, m.app, "setMainMenu:", bar);
}

update_size_and_scale :: () {
	bounds := msg(NSRect, m.view, "bounds");
	scale := cast(float32)(msg(NS.Float, m.window, "backingScaleFactor"));
	if scale <= 0 { scale = 1; }
	s.size = .{cast(float32)(bounds.size.width), cast(float32)(bounds.size.height)};
	s.scale = scale;
	if m.layer != null {
		msg(Void, m.layer, "setContentsScale:", cast(NS.Float)(scale));
		fb := framebuffer_size();
		msg(Void, m.layer, "setDrawableSize:", NSSize.{cast(NS.Float)(max(fb[0], 1)), cast(NS.Float)(max(fb[1], 1))});
	}
}

update_refresh_rate :: () {
	screen := msg(Id, m.window, "screen");
	if screen == null { screen = msg(Id, cls("NSScreen"), "mainScreen"); }
	hz: float32 = 60;
	if screen != null && responds(screen, "maximumFramesPerSecond") {
		n := msg(NS.Integer, screen, "maximumFramesPerSecond");
		if n > 0 { hz = cast(float32)(n); }
	}
	s.refresh_hz = hz;
	if m.display_link != null {
		Frame_Rate_Range :: struct {minimum, maximum, preferred: float32;}
		r := Frame_Rate_Range.{min(hz, 60), hz, hz};
		msg(Void, m.display_link, "setPreferredFrameRateRange:", r);
	}
}

setup_display_link :: () {
	if responds(m.view, "displayLinkWithTarget:selector:") {
		m.display_link = msg(Id, m.view, "displayLinkWithTarget:selector:", m.view, sel("fcTick:"));
		msg(Id, m.display_link, "retain");
		update_refresh_rate();
		run_loop := msg(Id, cls("NSRunLoop"), "mainRunLoop");
		msg(Void, m.display_link, "addToRunLoop:forMode:", run_loop, NSRunLoopCommonModes);
		msg(Void, m.display_link, "setPaused:", cast(NS.BOOL)(true));
		m.link_paused = true;
	} else {
		if CVDisplayLinkCreateWithActiveCGDisplays(*m.cv_link) == 0 {
			CVDisplayLinkSetOutputCallback(m.cv_link, cast(*void) cv_callback, null);
		}
		m.link_paused = true;
	}
}

cv_callback :: (link: CVDisplayLinkRef, now: *CV.TimeStamp, out_time: *CV.TimeStamp, flags_in: CV.OptionFlags, flags_out: *CV.OptionFlags, user: *void) -> CV.Return #c_call {
	__ctx3 := s.ctx; push_context,defer_pop __ctx3;
	post_wake(1);
	return 0;
}

set_link_paused :: (paused: bool) {
	if m.link_paused == paused { return; }
	m.link_paused = paused;
	if m.display_link != null {
		msg(Void, m.display_link, "setPaused:", paused);
	} else if m.cv_link != null {
		if paused { CVDisplayLinkStop(m.cv_link); } else { CVDisplayLinkStart(m.cv_link); }
	}
}

// data1: 0 = wake, 1 = tick (CVDisplayLink thread)
post_wake :: (data1: int) {
	if data1 == 0 {
		if atomic_exchange(*m.wake_posted, true) { return; }
	}
	ev := msg(Id, cls("NSEvent"), "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:",
		cast(NS.UInteger)(15), NSPoint.{}, cast(NS.UInteger)(0), cast(NS.TimeInterval)(0), cast(NS.Integer)(0), cast(Id)(null), cast(s16)(WAKE_SUBTYPE), cast(NS.Integer)(data1), cast(NS.Integer)(0));
	msg(Void, m.app, "postEvent:atStart:", ev, cast(NS.BOOL)(false));
}
#scope_module

_wake :: () {
	if atomic_load(*s.frame_requested) && is_main_thread() {
		set_link_paused(false);
		return;
	}
	post_wake(0);
}
#scope_file

is_main_thread :: () -> bool {
	return msg(NS.BOOL, cls("NSThread"), "isMainThread");
}
#scope_module

// ---------------------------------------------------------------------------
// Event loop

_wait :: (timeout: float64) {
	// End the app frame's autorelease pool.
	if m.pool != null {
		msg(Void, m.pool, "drain");
		m.pool = null;
	}
	defer m.pool = msg(Id, msg(Id, cls("NSAutoreleasePool"), "alloc"), "init");

	animating := atomic_load(*s.frame_requested);
	if animating { set_link_paused(false); }
	start := time_now();
	m.tick_pending = false;

	while true {
		pool := msg(Id, msg(Id, cls("NSAutoreleasePool"), "alloc"), "init");
		animating = atomic_load(*s.frame_requested);
		if animating { set_link_paused(false); }

		// Decide how long to block.
		have_input := pending_count() > 0;
		done := s.quit || (ifx animating then m.tick_pending else have_input);
		until: Id;
		if done || timeout == 0 {
			until = msg(Id, cls("NSDate"), "distantPast");
		} else if timeout < 0 {
			until = msg(Id, cls("NSDate"), "distantFuture");
		} else {
			remaining := timeout - (time_now() - start);
			if remaining <= 0 {
				until = msg(Id, cls("NSDate"), "distantPast");
				done = true;
			} else {
				until = msg(Id, cls("NSDate"), "dateWithTimeIntervalSinceNow:", cast(NS.TimeInterval)(remaining));
			}
		}

		m.in_next_event = true;
		ev := msg(Id, m.app, "nextEventMatchingMask:untilDate:inMode:dequeue:", NS.EventMaskAny, until, NSDefaultRunLoopMode, cast(NS.BOOL)(true));
		m.in_next_event = false;

		if ev == null {
			msg(Void, pool, "drain");
			// Nothing left in the queue: either we were done (drained), or timed out.
			if done || timeout == 0 { break; }
			if timeout > 0 && time_now() - start >= timeout { break; }
			continue;
		}

		type := msg(NS.UInteger, ev, "type");
		if type == 15 && msg(s16, ev, "subtype") == WAKE_SUBTYPE {
			if msg(NS.Integer, ev, "data1") == 1 {
				on_tick();
			} else {
				atomic_store(*m.wake_posted, false);
				if atomic_load(*s.frame_requested) { set_link_paused(false); }
			}
		} else {
			msg(Void, m.app, "sendEvent:", ev);
		}
		msg(Void, pool, "drain");
	}
	if !atomic_load(*s.frame_requested) {
		// Will be re-enabled by request_frame. Pausing here keeps idle at zero wakeups.
		set_link_paused(true);
	}
}
#scope_file

// Vsync tick (main thread).
on_tick :: () {
	if !atomic_load(*s.frame_requested) {
		set_link_paused(true);
		return;
	}
	if m.in_next_event {
		m.tick_pending = true;
		return;
	}
	// Inside a nested AppKit loop (live resize, title-bar drag, menu tracking):
	// our loop can't run, so render from here.
	pool := msg(Id, msg(Id, cls("NSAutoreleasePool"), "alloc"), "init");
	run_frame_callback();
	msg(Void, pool, "drain");
}
#scope_module

// ---------------------------------------------------------------------------
// Clipboard / cursor

_clipboard_get :: (allocator: Allocator) -> string {
	pb := msg(Id, cls("NSPasteboard"), "generalPasteboard");
	str := msg(Id, pb, "stringForType:", nsstr("public.utf8-plain-text"));
	return odin_str(str, allocator);
}

_clipboard_set :: (str: string) {
	pb := msg(Id, cls("NSPasteboard"), "generalPasteboard");
	msg(NS.Integer, pb, "clearContents");
	msg(NS.BOOL, pb, "setString:forType:", nsstr(str), nsstr("public.utf8-plain-text"));
}
#scope_file

pb_has_type :: (pb: Id, types: []string) -> bool {
	for t: types {
		arr := msg(Id, cls("NSArray"), "arrayWithObject:", nsstr(t));
		if msg(Id, pb, "availableTypeFromArray:", arr) != null { return true; }
	}
	return false;
}

IMAGE_TYPES := string.["public.png", "public.tiff", "public.jpeg", "com.compuserve.gif", "public.heic", "com.microsoft.bmp"];
#scope_module

_clipboard_kind :: () -> Clipboard_Kind {
	pool := msg(Id, msg(Id, cls("NSAutoreleasePool"), "alloc"), "init");
	defer msg(Void, pool, "drain");
	pb := msg(Id, cls("NSPasteboard"), "generalPasteboard");
	if pb_has_type(pb, string.["public.file-url"]) { return .Files; }
	if pb_has_type(pb, IMAGE_TYPES) { return .Image; }
	if pb_has_type(pb, string.["public.utf8-plain-text"]) { return .Text; }
	return .None;
}
#scope_file

ns_data_bytes :: (data: Id, allocator: Allocator) -> []u8 {
	if data == null { return .{}; }
	n := cast(int)(msg(NS.UInteger, data, "length"));
	p := msg(*void, data, "bytes");
	if n == 0 || p == null { return .{}; }
	out := make_slice(u8, n, allocator);
	copy(out, sub(cast(*u8)(p), 0, n));
	return out;
}
#scope_module

// PNG as is; any other bitmap type (TIFF from screenshots and Preview, JPEG...) through
// NSBitmapImageRep to PNG. Worker thread (its own autorelease pool).
_clipboard_image :: (allocator: Allocator) -> []u8, bool {
	pool := msg(Id, msg(Id, cls("NSAutoreleasePool"), "alloc"), "init");
	defer msg(Void, pool, "drain");
	pb := msg(Id, cls("NSPasteboard"), "generalPasteboard");
	{ png := msg(Id, pb, "dataForType:", nsstr("public.png"));
	if png != null {
		b := ns_data_bytes(png, allocator);
		return b, len(b) > 0;
	} }
	for t: sub_from(IMAGE_TYPES, 1) {
		data := msg(Id, pb, "dataForType:", nsstr(t));
		if data == null { continue; }
		rep := msg(Id, cls("NSBitmapImageRep"), "imageRepWithData:", data);
		if rep == null { continue; }
		props := msg(Id, cls("NSDictionary"), "dictionary");
		png := msg(Id, rep, "representationUsingType:properties:", cast(NS.UInteger)(4), props);
		b := ns_data_bytes(png, allocator);
		if len(b) > 0 { return b, true; }
	}
	return .{}, false;
}

_clipboard_files :: (allocator: Allocator) -> []string {
	pool := msg(Id, msg(Id, cls("NSAutoreleasePool"), "alloc"), "init");
	defer msg(Void, pool, "drain");
	pb := msg(Id, cls("NSPasteboard"), "generalPasteboard");
	classes := msg(Id, cls("NSArray"), "arrayWithObject:", cls("NSURL"));
	urls := msg(Id, pb, "readObjectsForClasses:options:", classes, cast(Id)(null));
	if urls == null { return .{}; }
	out := make_dynamic(string, 0, 0, allocator);
	n := msg(NS.UInteger, urls, "count");
	for i: 0..n-1 {
		u := msg(Id, urls, "objectAtIndex:", cast(NS.UInteger)(i));
		if !msg(NS.BOOL, u, "isFileURL") { continue; }
		append(*out, odin_str(msg(Id, u, "path"), allocator));
	}
	return view(out);
}

_apply_cursor :: () {
	if s.cursor == .Hidden {
		if !m.cursor_hidden {
			msg(Void, cls("NSCursor"), "hide");
			m.cursor_hidden = true;
		}
		return;
	}
	if m.cursor_hidden {
		msg(Void, cls("NSCursor"), "unhide");
		m.cursor_hidden = false;
	}
	c := cls("NSCursor");
	name: *u8;
	if s.cursor == {
	case .Arrow;       name = "arrowCursor";
	case .Pointer;     name = "pointingHandCursor";
	case .IBeam;       name = "IBeamCursor";
	case .Resize_H;    name = "resizeLeftRightCursor";
	case .Resize_V;    name = "resizeUpDownCursor";
	case .Resize_NWSE; name = "_windowResizeNorthWestSouthEastCursor";
	case .Resize_NESW; name = "_windowResizeNorthEastSouthWestCursor";
	case .Move;        name = "openHandCursor";
	case .Not_Allowed; name = "operationNotAllowedCursor";
	case .Crosshair;   name = "crosshairCursor";
	case .Hidden;      name = "arrowCursor";
	}
	if !msg(NS.BOOL, c, "respondsToSelector:", sel(name)) { name = "crosshairCursor"; }
	cur := msg_class_cursor(name);
	if cur != null { msg(Void, cur, "set"); }
}
#scope_file

msg_class_cursor :: (name: *u8) -> Id {
	// Dynamic selector: objc_send needs a constant selector, so go through performSelector.
	return msg(Id, cls("NSCursor"), "performSelector:", sel(name));
}

// ---------------------------------------------------------------------------
// Input translation

mods_from_flags :: (flags: NS.UInteger) -> Mods {
	r: Mods;
	if flags & (1 << 17) != 0 { r |= .Shift; }
	if flags & (1 << 18) != 0 { r |= .Ctrl; }
	if flags & (1 << 19) != 0 { r |= .Alt; }
	if flags & (1 << 20) != 0 { r |= .Cmd; }
	return r;
}

keycode_table :: #run () -> [128]Key {
	t: [128]Key;
	t[0x00] = .A;
	t[0x01] = .S;
	t[0x02] = .D;
	t[0x03] = .F;
	t[0x04] = .H;
	t[0x05] = .G;
	t[0x06] = .Z;
	t[0x07] = .X;
	t[0x08] = .C;
	t[0x09] = .V;
	t[0x0B] = .B;
	t[0x0C] = .Q;
	t[0x0D] = .W;
	t[0x0E] = .E;
	t[0x0F] = .R;
	t[0x10] = .Y;
	t[0x11] = .T;
	t[0x12] = .N1;
	t[0x13] = .N2;
	t[0x14] = .N3;
	t[0x15] = .N4;
	t[0x16] = .N6;
	t[0x17] = .N5;
	t[0x18] = .Equals;
	t[0x19] = .N9;
	t[0x1A] = .N7;
	t[0x1B] = .Minus;
	t[0x1C] = .N8;
	t[0x1D] = .N0;
	t[0x1E] = .Right_Bracket;
	t[0x1F] = .O;
	t[0x20] = .U;
	t[0x21] = .Left_Bracket;
	t[0x22] = .I;
	t[0x23] = .P;
	t[0x24] = .Enter;
	t[0x25] = .L;
	t[0x26] = .J;
	t[0x27] = .Apostrophe;
	t[0x28] = .K;
	t[0x29] = .Semicolon;
	t[0x2A] = .Backslash;
	t[0x2B] = .Comma;
	t[0x2C] = .Slash;
	t[0x2D] = .N;
	t[0x2E] = .M;
	t[0x2F] = .Period;
	t[0x30] = .Tab;
	t[0x31] = .Space;
	t[0x32] = .Grave;
	t[0x33] = .Backspace;
	t[0x35] = .Escape;
	t[0x36] = .Cmd;
	t[0x37] = .Cmd;
	t[0x38] = .Shift;
	t[0x39] = .Caps_Lock;
	t[0x3A] = .Alt;
	t[0x3B] = .Ctrl;
	t[0x3C] = .Shift;
	t[0x3D] = .Alt;
	t[0x3E] = .Ctrl;
	t[0x4C] = .Keypad_Enter;
	t[0x60] = .F5;
	t[0x61] = .F6;
	t[0x62] = .F7;
	t[0x63] = .F3;
	t[0x64] = .F8;
	t[0x65] = .F9;
	t[0x67] = .F11;
	t[0x6D] = .F10;
	t[0x6F] = .F12;
	t[0x73] = .Home;
	t[0x74] = .Page_Up;
	t[0x75] = .Delete;
	t[0x76] = .F4;
	t[0x77] = .End;
	t[0x78] = .F2;
	t[0x79] = .Page_Down;
	t[0x7A] = .F1;
	t[0x7B] = .Left;
	t[0x7C] = .Right;
	t[0x7D] = .Down;
	t[0x7E] = .Up;
	return t;
}();

key_from_event :: (ev: Id) -> Key {
	code := msg(u16, ev, "keyCode");
	k := ifx code < 128 then keycode_table[code] else .None;
	// Letters follow the active keyboard layout (Dvorak, AZERTY...) so cmd+c means "c".
	if (k >= .A && k <= .Z) || k == .None || (k >= .N0 && k <= .N9) {
		chars := msg(Id, ev, "charactersIgnoringModifiers");
		if chars != null && msg(NS.UInteger, chars, "length") == 1 {
			ch := msg(u16, chars, "characterAtIndex:", cast(NS.UInteger)(0));
			if (ch >= #char "a" && ch <= #char "z") { k = cast(Key)(cast(int)(Key.A) + cast(int)(ch - #char "a"));
			} else if (ch >= #char "A" && ch <= #char "Z") { k = cast(Key)(cast(int)(Key.A) + cast(int)(ch - #char "A"));
			}
		}
	}
	return k;
}

mouse_pos :: (ev: Id) -> Vector2 {
	p := msg(NSPoint, ev, "locationInWindow");
	v := msg(NSPoint, m.view, "convertPoint:fromView:", p, cast(Id)(null)); // view is flipped: top-left origin
	return .{cast(float32)(v.x), cast(float32)(v.y)};
}

event_time :: (ev: Id) -> float64 {return time_now();}

push_mouse :: (kind: Event_Kind, ev: Id) {
	e := Event.{kind = kind, pos = mouse_pos(ev), mods = mods_from_flags(msg(NS.UInteger, ev, "modifierFlags")), time = event_time(ev)};
	if kind == .Mouse_Down || kind == .Mouse_Up {
		n := msg(NS.Integer, ev, "buttonNumber");
		if n == {
		case 0; e.button = .Left;
		case 1; e.button = .Right;
		case 2; e.button = .Middle;
		case 3; e.button = .X1;
		case;   e.button = .X2;
		}
		// ctrl+click is a right click on macOS
		if e.button == .Left && has(e.mods, .Ctrl) && kind == .Mouse_Down { e.button = .Right; }
		e.click_count = cast(int)(msg(NS.Integer, ev, "clickCount"));
	}
	if kind == .Mouse_Move && s.cursor != .Arrow { _apply_cursor_force(); }
	push_event(e);
}

_apply_cursor_force :: () {_apply_cursor();}

phase_from :: (p: NS.UInteger) -> Scroll_Phase {
	if p & 1 != 0 { return .Began; }
	if p & 4 != 0 { return .Changed; }
	if p & 8 != 0 { return .Ended; }
	if p & 16 != 0 { return .Cancelled; }
	if p & 32 != 0 { return .May_Begin; }
	if p & 2 != 0 { return .Changed; }
	return .None;
}

// utf16 index -> byte offset in str (for IME selection ranges)
utf16_to_byte :: (str: string, idx16: int) -> int {
	n := 0;
	for r, i: str {
		if n >= idx16 { return i; }
		n += ifx r >= 0x10000 then 2 else 1;
	}
	return len(str);
}

string_from_text_arg :: (arg: Id) -> string {
	if arg == null { return ""; }
	str := arg;
	if msg(NS.BOOL, arg, "isKindOfClass:", cls("NSAttributedString")) {
		str = msg(Id, arg, "string");
	}
	return odin_str(str, temp);
}

// ---------------------------------------------------------------------------
// ObjC classes

register_classes :: () {
	if cls("FCView") != null { return; }

	// ---- FCView : NSView <NSTextInputClient>
	v := objc.allocate_class(cls("NSView"), "FCView");
	add_method(v, "acceptsFirstResponder", cast(*void)(view_yes), "B@:");
	add_method(v, "canBecomeKeyView", cast(*void)(view_yes), "B@:");
	add_method(v, "acceptsFirstMouse:", cast(*void)(view_yes1), "B@:@");
	add_method(v, "isFlipped", cast(*void)(view_yes), "B@:");
	add_method(v, "isOpaque", cast(*void)(view_yes), "B@:");
	add_method(v, "wantsUpdateLayer", cast(*void)(view_yes), "B@:");
	add_method(v, "updateLayer", cast(*void)(view_update_layer), "v@:");
	add_method(v, "makeBackingLayer", cast(*void)(view_make_backing_layer), "@@:");
	add_method(v, "setFrameSize:", cast(*void)(view_set_frame_size), "v@:{CGSize=dd}");
	add_method(v, "viewDidChangeBackingProperties", cast(*void)(view_did_change_backing), "v@:");
	add_method(v, "viewWillStartLiveResize", cast(*void)(view_will_start_live_resize), "v@:");
	add_method(v, "viewDidEndLiveResize", cast(*void)(view_did_end_live_resize), "v@:");
	add_method(v, "updateTrackingAreas", cast(*void)(view_update_tracking_areas), "v@:");
	add_method(v, "fcTick:", cast(*void)(view_tick), "v@:@");

	add_method(v, "keyDown:", cast(*void)(view_key_down), "v@:@");
	add_method(v, "keyUp:", cast(*void)(view_key_up), "v@:@");
	add_method(v, "flagsChanged:", cast(*void)(view_flags_changed), "v@:@");
	add_method(v, "mouseDown:", cast(*void)(view_mouse_down), "v@:@");
	add_method(v, "mouseUp:", cast(*void)(view_mouse_up), "v@:@");
	add_method(v, "rightMouseDown:", cast(*void)(view_mouse_down), "v@:@");
	add_method(v, "rightMouseUp:", cast(*void)(view_mouse_up), "v@:@");
	add_method(v, "otherMouseDown:", cast(*void)(view_mouse_down), "v@:@");
	add_method(v, "otherMouseUp:", cast(*void)(view_mouse_up), "v@:@");
	add_method(v, "mouseMoved:", cast(*void)(view_mouse_moved), "v@:@");
	add_method(v, "mouseDragged:", cast(*void)(view_mouse_moved), "v@:@");
	add_method(v, "rightMouseDragged:", cast(*void)(view_mouse_moved), "v@:@");
	add_method(v, "otherMouseDragged:", cast(*void)(view_mouse_moved), "v@:@");
	add_method(v, "mouseEntered:", cast(*void)(view_mouse_entered), "v@:@");
	add_method(v, "mouseExited:", cast(*void)(view_mouse_exited), "v@:@");
	add_method(v, "scrollWheel:", cast(*void)(view_scroll), "v@:@");
	add_method(v, "cursorUpdate:", cast(*void)(view_cursor_update), "v@:@");

	// NSTextInputClient
	add_method(v, "hasMarkedText", cast(*void)(ti_has_marked), "B@:");
	add_method(v, "markedRange", cast(*void)(ti_marked_range), "{_NSRange=QQ}@:");
	add_method(v, "selectedRange", cast(*void)(ti_selected_range), "{_NSRange=QQ}@:");
	add_method(v, "setMarkedText:selectedRange:replacementRange:", cast(*void)(ti_set_marked), "v@:@{_NSRange=QQ}{_NSRange=QQ}");
	add_method(v, "unmarkText", cast(*void)(ti_unmark), "v@:");
	add_method(v, "validAttributesForMarkedText", cast(*void)(ti_valid_attrs), "@@:");
	add_method(v, "attributedSubstringForProposedRange:actualRange:", cast(*void)(ti_attr_substring), "@@:{_NSRange=QQ}^{_NSRange=QQ}");
	add_method(v, "insertText:replacementRange:", cast(*void)(ti_insert_text), "v@:@{_NSRange=QQ}");
	add_method(v, "insertText:", cast(*void)(ti_insert_text_simple), "v@:@");
	add_method(v, "characterIndexForPoint:", cast(*void)(ti_char_index), "Q@:{CGPoint=dd}");
	add_method(v, "firstRectForCharacterRange:actualRange:", cast(*void)(ti_first_rect), "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}");
	add_method(v, "doCommandBySelector:", cast(*void)(ti_do_command), "v@::");

	// Drag and drop
	add_method(v, "draggingEntered:", cast(*void)(dnd_entered), "Q@:@");
	add_method(v, "draggingUpdated:", cast(*void)(dnd_updated), "Q@:@");
	add_method(v, "draggingExited:", cast(*void)(dnd_exited), "v@:@");
	add_method(v, "performDragOperation:", cast(*void)(dnd_perform), "B@:@");

	{ p := objc.objc_getProtocol("NSTextInputClient");
	if p != null { objc.class_addProtocol(v, p); } }
	objc.register_class(v);

	// ---- FCWindowDelegate
	w := objc.allocate_class(cls("NSObject"), "FCWindowDelegate");
	add_method(w, "windowShouldClose:", cast(*void)(win_should_close), "B@:@");
	add_method(w, "windowDidBecomeKey:", cast(*void)(win_did_become_key), "v@:@");
	add_method(w, "windowDidResignKey:", cast(*void)(win_did_resign_key), "v@:@");
	add_method(w, "windowDidChangeScreen:", cast(*void)(win_did_change_screen), "v@:@");
	add_method(w, "windowDidChangeBackingProperties:", cast(*void)(win_did_change_screen), "v@:@");
	objc.register_class(w);

	// ---- FCAppDelegate
	a := objc.allocate_class(cls("NSObject"), "FCAppDelegate");
	add_method(a, "applicationShouldTerminate:", cast(*void)(app_should_terminate), "Q@:@");
	add_method(a, "applicationShouldTerminateAfterLastWindowClosed:", cast(*void)(view_no1), "B@:@");
	objc.register_class(a);
}

view_yes :: (self: Id, cmd: objc.SEL) -> NS.BOOL #c_call {return true;}
view_yes1 :: (self: Id, cmd: objc.SEL, a: Id) -> NS.BOOL #c_call {return true;}
view_no1 :: (self: Id, cmd: objc.SEL, a: Id) -> NS.BOOL #c_call {return false;}
view_update_layer :: (self: Id, cmd: objc.SEL) #c_call {}

view_make_backing_layer :: (self: Id, cmd: objc.SEL) -> Id #c_call {
	layer := msg(Id, cls("CAMetalLayer"), "layer");
	msg(Void, layer, "setFramebufferOnly:", cast(NS.BOOL)(true));
	msg(Void, layer, "setOpaque:", cast(NS.BOOL)(true));
	msg(Void, layer, "setNeedsDisplayOnBoundsChange:", cast(NS.BOOL)(false));
	msg(Void, layer, "setPixelFormat:", cast(NS.UInteger)(80) /*BGRA8Unorm*/);
	// Our colors are sRGB (the client's CSS); tag the layer so macOS converts to
	// the display's space like Chrome does, instead of showing raw values (oversaturated on P3).
	srgb := CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	msg(Void, layer, "setColorspace:", srgb);
	CGColorSpaceRelease(srgb);
	msg(Void, layer, "setMaximumDrawableCount:", cast(NS.UInteger)(3));
	if msg(NS.BOOL, layer, "respondsToSelector:", sel("setDisplaySyncEnabled:")) {
		msg(Void, layer, "setDisplaySyncEnabled:", cast(NS.BOOL)(true));
	}
	// Don't let CA animate resizes/scale changes of our content.
	msg(Void, layer, "setActions:", msg(Id, cls("NSDictionary"), "dictionary"));
	return layer;
}

call_super_set_frame_size :: (self: Id, size: NSSize) #c_call {
	imp := objc.class_getMethodImplementation(cls("NSView"), sel("setFrameSize:"));
	f := cast((self: Id, cmd: objc.SEL, size: NSSize) #c_call)imp;
	f(self, sel("setFrameSize:"), size);
}

view_set_frame_size :: (self: Id, cmd: objc.SEL, size: NSSize) #c_call {
	call_super_set_frame_size(self, size);
	__ctx7 := s.ctx; push_context,defer_pop __ctx7;
	if m.view == null || self != m.view { return; }
	old := s.size;
	update_size_and_scale();
	if old != s.size {
		push_event(.{kind = .Resize, pos = s.size, time = time_now()});
		if msg(NS.BOOL, self, "inLiveResize") {
			pool := msg(Id, msg(Id, cls("NSAutoreleasePool"), "alloc"), "init");
			run_frame_callback();
			msg(Void, pool, "drain");
		}
	}
}

view_did_change_backing :: (self: Id, cmd: objc.SEL) #c_call {
	__ctx8 := s.ctx; push_context,defer_pop __ctx8;
	if m.view == null { return; }
	old_scale := s.scale;
	update_size_and_scale();
	update_refresh_rate();
	if old_scale != s.scale { push_event(.{kind = .Resize, pos = s.size, time = time_now()}); }
}

view_will_start_live_resize :: (self: Id, cmd: objc.SEL) #c_call {
	__ctx9 := s.ctx; push_context,defer_pop __ctx9;
	// Present inside the CA transaction that resizes the window: no stretching or tearing.
	if m.layer != null { msg(Void, m.layer, "setPresentsWithTransaction:", cast(NS.BOOL)(true)); }
}

view_did_end_live_resize :: (self: Id, cmd: objc.SEL) #c_call {
	__ctx10 := s.ctx; push_context,defer_pop __ctx10;
	if m.layer != null { msg(Void, m.layer, "setPresentsWithTransaction:", cast(NS.BOOL)(false)); }
	push_event(.{kind = .Resize, pos = s.size, time = time_now()});
}

view_update_tracking_areas :: (self: Id, cmd: objc.SEL) #c_call {
	__ctx11 := s.ctx; push_context,defer_pop __ctx11;
	areas := msg(Id, self, "trackingAreas");
	n := msg(NS.UInteger, areas, "count");
	for < i: cast(int)(n) - 1..0 {
		a := msg(Id, areas, "objectAtIndex:", cast(NS.UInteger)(i));
		msg(Void, self, "removeTrackingArea:", a);
	}
	// MouseEnteredAndExited | MouseMoved | CursorUpdate | ActiveAlways | InVisibleRect | EnabledDuringMouseDrag
	opts := cast(NS.UInteger)(0x01 | 0x02 | 0x04 | 0x80 | 0x200 | 0x400);
	bounds := msg(NSRect, self, "bounds");
	area := msg(Id, msg(Id, cls("NSTrackingArea"), "alloc"), "initWithRect:options:owner:userInfo:", bounds, opts, self, cast(Id)(null));
	msg(Void, self, "addTrackingArea:", area);
	msg(Void, area, "release");
	imp := objc.class_getMethodImplementation(cls("NSView"), sel("updateTrackingAreas"));
	f := cast((self: Id, cmd: objc.SEL) #c_call)imp;
	f(self, sel("updateTrackingAreas"));
}

view_tick :: (self: Id, cmd: objc.SEL, link: Id) #c_call {
	__ctx12 := s.ctx; push_context,defer_pop __ctx12;
	on_tick();
	// Wake nextEventMatchingMask so _wait sees tick_pending.
	if m.in_next_event && m.tick_pending { post_wake(0); }
}

view_key_down :: (self: Id, cmd: objc.SEL, ev: Id) #c_call {
	__ctx13 := s.ctx; push_context,defer_pop __ctx13;
	flags := msg(NS.UInteger, ev, "modifierFlags");
	e := Event.{
		kind = .Key_Down,
		key = key_from_event(ev),
		mods = mods_from_flags(flags),
		is_repeat = msg(NS.BOOL, ev, "isARepeat"),
		time = time_now()
	};
	had_marked := len(m.marked) > 0;
	idx := pending_count();
	if !has(e.mods, .Cmd) {
		arr := msg(Id, cls("NSArray"), "arrayWithObject:", ev);
		msg(Void, self, "interpretKeyEvents:", arr);
	}
	consumed_by_ime := had_marked || len(m.marked) > 0;
	if !consumed_by_ime {
		locks.lock(*s.queue_lock);
		inject_at(*s.pending, min(idx, len(s.pending)), e);
		locks.unlock(*s.queue_lock);
	}
}

view_key_up :: (self: Id, cmd: objc.SEL, ev: Id) #c_call {
	__ctx14 := s.ctx; push_context,defer_pop __ctx14;
	push_event(.{kind = .Key_Up, key = key_from_event(ev), mods = mods_from_flags(msg(NS.UInteger, ev, "modifierFlags")), time = time_now()});
}

view_flags_changed :: (self: Id, cmd: objc.SEL, ev: Id) #c_call {
	__ctx15 := s.ctx; push_context,defer_pop __ctx15;
	mods := mods_from_flags(msg(NS.UInteger, ev, "modifierFlags"));
	code := msg(u16, ev, "keyCode");
	k := ifx code < 128 then keycode_table[code] else .None;
	mod: Mod; mod_ok := true;
	if k == {
	case .Shift; mod = .Shift;
	case .Ctrl;  mod = .Ctrl;
	case .Alt;   mod = .Alt;
	case .Cmd;   mod = .Cmd;
	case; mod_ok = false;
	}
	{ if mod_ok {
		down := has(mods, mod);
		push_event(.{kind = ifx down then .Key_Down else .Key_Up, key = k, mods = mods, time = time_now()});
	} }
	m.last_mods = mods;
}

view_mouse_down :: (self: Id, cmd: objc.SEL, ev: Id) #c_call {__ctx17 := s.ctx; push_context,defer_pop __ctx17; push_mouse(.Mouse_Down, ev);}
view_mouse_up :: (self: Id, cmd: objc.SEL, ev: Id) #c_call {__ctx18 := s.ctx; push_context,defer_pop __ctx18; push_mouse(.Mouse_Up, ev);}
view_mouse_moved :: (self: Id, cmd: objc.SEL, ev: Id) #c_call {__ctx19 := s.ctx; push_context,defer_pop __ctx19; push_mouse(.Mouse_Move, ev);}
view_mouse_entered :: (self: Id, cmd: objc.SEL, ev: Id) #c_call {
	__ctx20 := s.ctx; push_context,defer_pop __ctx20;
	m.mouse_inside = true;
	_apply_cursor();
	push_mouse(.Mouse_Move, ev);
}
view_mouse_exited :: (self: Id, cmd: objc.SEL, ev: Id) #c_call {
	__ctx21 := s.ctx; push_context,defer_pop __ctx21;
	m.mouse_inside = false;
	if m.cursor_hidden {
		msg(Void, cls("NSCursor"), "unhide");
		m.cursor_hidden = false;
	}
	push_event(.{kind = .Mouse_Leave, pos = mouse_pos(ev), time = time_now()});
}
view_cursor_update :: (self: Id, cmd: objc.SEL, ev: Id) #c_call {__ctx22 := s.ctx; push_context,defer_pop __ctx22; _apply_cursor();}

view_scroll :: (self: Id, cmd: objc.SEL, ev: Id) #c_call {
	__ctx23 := s.ctx; push_context,defer_pop __ctx23;
	dx := cast(float32)(msg(NS.Float, ev, "scrollingDeltaX"));
	dy := cast(float32)(msg(NS.Float, ev, "scrollingDeltaY"));
	precise := msg(NS.BOOL, ev, "hasPreciseScrollingDeltas");
	if !precise {
		dx *= 40; // Chrome: 40px per wheel tick
		dy *= 40;
	}
	phase := msg(NS.UInteger, ev, "phase");
	momentum := msg(NS.UInteger, ev, "momentumPhase");
	e := Event.{
		kind = .Scroll,
		pos = mouse_pos(ev),
		delta = .{dx, dy},
		mods = mods_from_flags(msg(NS.UInteger, ev, "modifierFlags")),
		precise = precise,
		momentum = momentum != 0,
		scroll_phase = ifx momentum != 0 then phase_from(momentum) else phase_from(phase),
		time = time_now()
	};
	push_event(e);
}

// ---- NSTextInputClient

ti_has_marked :: (self: Id, cmd: objc.SEL) -> NS.BOOL #c_call {return m.marked.count > 0;}

utf16_len :: (str: string) -> int {
	n := 0;
	{ i := 0;
	while i < len(str) {
		r, w := utf8.decode_rune_in_string(sub_from(str, i));
		n += ifx r >= 0x10000 then 2 else 1;
		i += max(w, 1);
	} }
	return n;
}

ti_marked_range :: (self: Id, cmd: objc.SEL) -> NSRange #c_call {
	__c := s.ctx; push_context,defer_pop __c;
	if len(m.marked) == 0 { return .{NOT_FOUND, 0}; }
	return .{0, cast(NS.UInteger)(utf16_len(m.marked))};
}

ti_selected_range :: (self: Id, cmd: objc.SEL) -> NSRange #c_call {
	__c := s.ctx; push_context,defer_pop __c;
	if len(m.marked) == 0 { return .{0, 0}; }
	return .{cast(NS.UInteger)(utf16_len(m.marked)), 0};
}

ti_set_marked :: (self: Id, cmd: objc.SEL, str: Id, sel_range: NSRange, repl: NSRange) #c_call {
	__ctx24 := s.ctx; push_context,defer_pop __ctx24;
	text := string_from_text_arg(str);
	delete(m.marked);
	m.marked = clone(text);
	a := utf16_to_byte(text, cast(int)(sel_range.location));
	b := utf16_to_byte(text, cast(int)(sel_range.location + sel_range.length));
	push_event(.{kind = .Composition, text = text, composition_sel = .[a, b], time = time_now()});
}

ti_unmark :: (self: Id, cmd: objc.SEL) #c_call {
	__ctx25 := s.ctx; push_context,defer_pop __ctx25;
	if len(m.marked) > 0 {
		delete(m.marked);
		m.marked = "";
		push_event(.{kind = .Composition, time = time_now()});
	}
}

ti_valid_attrs :: (self: Id, cmd: objc.SEL) -> Id #c_call {
	return msg(Id, cls("NSArray"), "array");
}

ti_attr_substring :: (self: Id, cmd: objc.SEL, r: NSRange, actual: *NSRange) -> Id #c_call {return null;}

ti_insert_text :: (self: Id, cmd: objc.SEL, str: Id, repl: NSRange) #c_call {
	__ctx26 := s.ctx; push_context,defer_pop __ctx26;
	text := string_from_text_arg(str);
	if len(m.marked) > 0 {
		delete(m.marked);
		m.marked = "";
		push_event(.{kind = .Composition, time = time_now()});
	}
	if len(text) == 0 { return; }
	// Drop control chars and AppKit's private-use function-key characters.
	r, _ := utf8.decode_rune_in_string(text);
	if len(text) == utf8.rune_size(r) && (r < 0x20 || r == 0x7f || (r >= 0xF700 && r <= 0xF8FF)) { return; }
	push_event(.{kind = .Text, text = text, time = time_now()});
}

ti_insert_text_simple :: (self: Id, cmd: objc.SEL, str: Id) #c_call {
	ti_insert_text(self, cmd, str, .{NOT_FOUND, 0});
}

ti_char_index :: (self: Id, cmd: objc.SEL, p: NSPoint) -> NS.UInteger #c_call {return NOT_FOUND;}

ti_first_rect :: (self: Id, cmd: objc.SEL, r: NSRange, actual: *NSRange) -> NSRect #c_call {
	__ctx27 := s.ctx; push_context,defer_pop __ctx27;
	if actual != null { actual.* = r; }
	ir := s.ime_rect;
	// view (flipped) -> window -> screen
	local := NSRect.{.{cast(NS.Float)(ir.x), cast(NS.Float)(ir.y)}, .{cast(NS.Float)(max(ir.z, 1)), cast(NS.Float)(max(ir.w, 1))}};
	in_win := msg(NSRect, m.view, "convertRect:toView:", local, cast(Id)(null));
	return msg(NSRect, m.window, "convertRectToScreen:", in_win);
}

ti_do_command :: (self: Id, cmd: objc.SEL, command: objc.SEL) #c_call {
	// Swallow: keys are delivered as Key_Down events; don't beep.
}

// ---- Drag and drop

dnd_entered :: (self: Id, cmd: objc.SEL, info: Id) -> NS.UInteger #c_call {
	__ctx28 := s.ctx; push_context,defer_pop __ctx28;
	p := msg(NSPoint, info, "draggingLocation");
	v := msg(NSPoint, m.view, "convertPoint:fromView:", p, cast(Id)(null));
	push_event(.{kind = .Drag_Enter, pos = .{cast(float32)(v.x), cast(float32)(v.y)}, time = time_now()});
	return 1; /*Copy*/
}

dnd_updated :: (self: Id, cmd: objc.SEL, info: Id) -> NS.UInteger #c_call {return 1; /*Copy*/}

dnd_exited :: (self: Id, cmd: objc.SEL, info: Id) #c_call {
	__ctx29 := s.ctx; push_context,defer_pop __ctx29;
	push_event(.{kind = .Drag_Leave, time = time_now()});
}

dnd_perform :: (self: Id, cmd: objc.SEL, info: Id) -> NS.BOOL #c_call {
	__ctx30 := s.ctx; push_context,defer_pop __ctx30;
	pb := msg(Id, info, "draggingPasteboard");
	p := msg(NSPoint, info, "draggingLocation");
	v := msg(NSPoint, m.view, "convertPoint:fromView:", p, cast(Id)(null));
	classes := msg(Id, cls("NSArray"), "arrayWithObject:", cls("NSURL"));
	urls := msg(Id, pb, "readObjectsForClasses:options:", classes, cast(Id)(null));
	if urls == null {
		push_event(.{kind = .Drag_Leave, time = time_now()});
		return false;
	}
	n := msg(NS.UInteger, urls, "count");
	for i: 0..n-1 {
		u := msg(Id, urls, "objectAtIndex:", cast(NS.UInteger)(i));
		if !msg(NS.BOOL, u, "isFileURL") { continue; }
		path := odin_str(msg(Id, u, "path"), temp);
		push_event(.{kind = .File_Drop, text = path, pos = .{cast(float32)(v.x), cast(float32)(v.y)}, time = time_now()});
	}
	push_event(.{kind = .Drag_Leave, time = time_now()});
	return true;
}

// ---- Window / app delegates

win_should_close :: (self: Id, cmd: objc.SEL, sender: Id) -> NS.BOOL #c_call {
	__ctx31 := s.ctx; push_context,defer_pop __ctx31;
	s.quit = true;
	push_event(.{kind = .Quit, time = time_now()});
	return false; // the app decides; it will exit its loop
}

win_did_become_key :: (self: Id, cmd: objc.SEL, n: Id) #c_call {
	__ctx32 := s.ctx; push_context,defer_pop __ctx32;
	push_event(.{kind = .Focus_Gained, time = time_now()});
}

win_did_resign_key :: (self: Id, cmd: objc.SEL, n: Id) #c_call {
	__ctx33 := s.ctx; push_context,defer_pop __ctx33;
	push_event(.{kind = .Focus_Lost, time = time_now()});
}

win_did_change_screen :: (self: Id, cmd: objc.SEL, n: Id) #c_call {
	__ctx34 := s.ctx; push_context,defer_pop __ctx34;
	if m.view == null { return; }
	update_size_and_scale();
	update_refresh_rate();
}

app_should_terminate :: (self: Id, cmd: objc.SEL, sender: Id) -> NS.UInteger #c_call {
	__ctx35 := s.ctx; push_context,defer_pop __ctx35;
	s.quit = true;
	push_event(.{kind = .Quit, time = time_now()});
	return 0; // NSTerminateCancel; the app exits its own loop
}
#scope_export

