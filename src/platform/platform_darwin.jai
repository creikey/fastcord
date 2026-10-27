// ---------------------------------------------------------------------------
// Natives for gfx

native_window :: () -> *void { return m.window; }
// CAMetalLayer backing the content view (nil in headless mode).
native_metal_layer :: () -> *void { return m.layer; }

// NSWindow.sharingType None (Electron's setContentProtection) or ReadOnly.
set_capture_hidden :: (hidden: bool) {
    if m.window msg(Void, m.window, "setSharingType:", cast(NSUInteger) ifx hidden then 0 else 1);
}

// True when the OS appearance is dark (NSApp.effectiveAppearance, which follows System Settings >
// Appearance, including "Auto"). ok is false headless.
system_dark_mode :: () -> dark: bool, ok: bool {
    if s.headless return false, false;
    app := msg(Id, cls("NSApplication"), "sharedApplication");
    if !app return false, false;
    ap := msg(Id, app, "effectiveAppearance");
    if !ap return false, false;
    return contains(to_jai_string(msg(Id, ap, "name"), temp), "Dark"), true;
}

// The display accommodations Chromium's media queries read on macOS (NSWorkspace): Reduce motion ->
// prefers-reduced-motion, Increase contrast -> prefers-contrast: more, Invert colors -> inverted-colors.
// macOS has no forced colors.
system_a11y :: () -> System_A11y {
    a: System_A11y;
    if s.headless return a;
    ws := msg(Id, cls("NSWorkspace"), "sharedWorkspace");
    if !ws return a;
    a.reduce_motion = msg(bool, ws, "accessibilityDisplayShouldReduceMotion");
    a.contrast_more = msg(bool, ws, "accessibilityDisplayShouldIncreaseContrast");
    a.invert_colors = msg(bool, ws, "accessibilityDisplayShouldInvertColors");
    return a;
}

// Modal "open file" panel. Returns absolute paths (empty if cancelled).
open_file_dialog :: (allow_multiple := true, allocator := context.allocator) -> []string {
    if s.headless return .[];
    panel := msg(Id, cls("NSOpenPanel"), "openPanel");
    msg(Void, panel, "setCanChooseFiles:", true);
    msg(Void, panel, "setCanChooseDirectories:", false);
    msg(Void, panel, "setAllowsMultipleSelection:", allow_multiple);
    if msg(NSInteger, panel, "runModal") != 1 return .[]; // NSModalResponseOK
    urls := msg(Id, panel, "URLs");
    out := NewArray(cast(int) msg(NSUInteger, urls, "count"), string,, allocator);
    for * out {
        url := msg(Id, urls, "objectAtIndex:", cast(NSUInteger) it_index);
        it.* = to_jai_string(msg(Id, url, "path"), allocator);
    }
    return out;
}

// Opens a URL in the user's default browser.
open_url :: (url: string) {
    u := msg(Id, cls("NSURL"), "URLWithString:", nsstr(url));
    if !u return;
    msg(Void, msg(Id, cls("NSWorkspace"), "sharedWorkspace"), "openURL:", u);
}

#scope_module

os_init :: (title: string, width: int, height: int) -> bool {
    m.pool = autorelease_pool();

    m.app = msg(Id, cls("NSApplication"), "sharedApplication");
    msg(bool, m.app, "setActivationPolicy:", cast(NSInteger) 0 /*Regular*/);

    register_classes();

    msg(Void, m.app, "setDelegate:", objc.new_obj("FCAppDelegate"));
    build_menu(title);

    style := cast(NSUInteger) (1 | 2 | 4 | 8); // titled, closable, miniaturizable, resizable
    rect := NSRect.{.{0, 0}, .{xx width, xx height}};
    m.window = msg(Id, msg(Id, cls("NSWindow"), "alloc"), "initWithContentRect:styleMask:backing:defer:", rect, style, cast(NSUInteger) 2, false);
    msg(Void, m.window, "setReleasedWhenClosed:", false);
    msg(Void, m.window, "setTitle:", nsstr(title));
    msg(Void, m.window, "setAcceptsMouseMovedEvents:", true);
    msg(Void, m.window, "setRestorable:", false);
    msg(Void, m.window, "setTabbingMode:", cast(NSInteger) 2 /*disallowed*/);
    msg(Void, m.window, "setContentMinSize:", NSSize.{MIN_WINDOW_W, MIN_WINDOW_H});
    msg(Void, m.window, "setDelegate:", objc.new_obj("FCWindowDelegate"));

    m.view = msg(Id, msg(Id, cls("FCView"), "alloc"), "initWithFrame:", rect);
    msg(Void, m.view, "setWantsLayer:", true); // makeBackingLayer -> CAMetalLayer
    msg(Void, m.view, "setLayerContentsRedrawPolicy:", cast(NSInteger) 2 /*DuringViewResize*/);
    msg(Void, m.view, "setLayerContentsPlacement:", cast(NSInteger) 11 /*TopLeft: never stretch stale frames*/);
    m.layer = msg(Id, m.view, "layer");
    msg(Void, m.window, "setContentView:", m.view);
    msg(bool, m.window, "makeFirstResponder:", m.view);

    // File drops
    msg(Void, m.view, "registerForDraggedTypes:", msg(Id, cls("NSArray"), "arrayWithObject:", nsstr("public.file-url")));

    msg(Void, m.window, "center");
    msg(Void, m.app, "finishLaunching");
    msg(Void, m.window, "makeKeyAndOrderFront:", cast(Id) null);
    if responds(m.app, "activate") msg(Void, m.app, "activate");
    else msg(Void, m.app, "activateIgnoringOtherApps:", true);

    update_size_and_scale();
    update_refresh_rate();
    setup_display_link();
    return true;
}

os_shutdown :: () {
    if m.display_link msg(Void, m.display_link, "invalidate");
    if m.cv_link {
        CVDisplayLinkStop(m.cv_link);
        CVDisplayLinkRelease(m.cv_link);
    }
    if m.window msg(Void, m.window, "close");
}

os_wake :: () {
    if atomic_load(*s.frame_requested) && msg(bool, cls("NSThread"), "isMainThread") {
        set_link_paused(false);
        return;
    }
    post_wake(0);
}

os_wait :: (timeout: float64) {
    // End the app frame's autorelease pool.
    if m.pool {
        msg(Void, m.pool, "drain");
        m.pool = null;
    }
    defer m.pool = autorelease_pool();

    if atomic_load(*s.frame_requested) set_link_paused(false);
    start := time_now();
    m.tick_pending = false;

    while true {
        pool := autorelease_pool();
        animating := atomic_load(*s.frame_requested);
        if animating set_link_paused(false);

        // Decide how long to block.
        done := s.quit || (ifx animating then m.tick_pending else pending_count() > 0);
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
                until = msg(Id, cls("NSDate"), "dateWithTimeIntervalSinceNow:", remaining);
            }
        }

        m.in_next_event = true;
        ev := msg(Id, m.app, "nextEventMatchingMask:untilDate:inMode:dequeue:", cast(NSUInteger) NS_EVENT_MASK_ANY, until, NSDefaultRunLoopMode, true);
        m.in_next_event = false;

        if !ev {
            msg(Void, pool, "drain");
            // Nothing left in the queue: either we were done (drained), or timed out.
            if done || timeout == 0 break;
            if timeout > 0 && time_now() - start >= timeout break;
            continue;
        }

        if msg(NSUInteger, ev, "type") == 15 && msg(s16, ev, "subtype") == WAKE_SUBTYPE {
            if msg(NSInteger, ev, "data1") == 1 {
                on_tick();
            } else {
                atomic_store(*m.wake_posted, false);
                if atomic_load(*s.frame_requested) set_link_paused(false);
            }
        } else {
            msg(Void, m.app, "sendEvent:", ev);
        }
        msg(Void, pool, "drain");
    }
    // Re-enabled by request_frame. Pausing here keeps idle at zero wakeups.
    if !atomic_load(*s.frame_requested) set_link_paused(true);
}

os_clipboard_get :: (allocator: Allocator) -> string {
    pb := msg(Id, cls("NSPasteboard"), "generalPasteboard");
    return to_jai_string(msg(Id, pb, "stringForType:", nsstr("public.utf8-plain-text")), allocator);
}

os_clipboard_set :: (str: string) {
    pb := msg(Id, cls("NSPasteboard"), "generalPasteboard");
    msg(NSInteger, pb, "clearContents");
    msg(bool, pb, "setString:forType:", nsstr(str), nsstr("public.utf8-plain-text"));
}

// NSImage writes TIFF (and keeps the PNG), which every app pastes. Worker thread (its own autorelease pool).
os_clipboard_set_image :: (data: []u8) {
    pool := autorelease_pool();
    defer msg(Void, pool, "drain");
    nsdata := msg(Id, cls("NSData"), "dataWithBytes:length:", data.data, cast(NSUInteger) data.count);
    img := msg(Id, msg(Id, cls("NSImage"), "alloc"), "initWithData:", nsdata);
    if !img return;
    defer msg(Void, img, "release");
    pb := msg(Id, cls("NSPasteboard"), "generalPasteboard");
    msg(NSInteger, pb, "clearContents");
    msg(bool, pb, "writeObjects:", msg(Id, cls("NSArray"), "arrayWithObject:", img));
}

os_clipboard_kind :: () -> Clipboard_Kind {
    pool := autorelease_pool();
    defer msg(Void, pool, "drain");
    pb := msg(Id, cls("NSPasteboard"), "generalPasteboard");
    if pb_has_type(pb, .["public.file-url"]) return .Files;
    if pb_has_type(pb, IMAGE_TYPES) return .Image;
    if pb_has_type(pb, .["public.utf8-plain-text"]) return .Text;
    return .None;
}

// PNG as is; any other bitmap type (TIFF from screenshots and Preview, JPEG...) through NSBitmapImageRep to
// PNG. Worker thread (its own autorelease pool).
os_clipboard_image :: (allocator: Allocator) -> []u8, bool {
    pool := autorelease_pool();
    defer msg(Void, pool, "drain");
    pb := msg(Id, cls("NSPasteboard"), "generalPasteboard");
    png := msg(Id, pb, "dataForType:", nsstr("public.png"));
    if png {
        b := ns_data_bytes(png, allocator);
        return b, b.count > 0;
    }
    for t: array_view(IMAGE_TYPES, 1) {
        data := msg(Id, pb, "dataForType:", nsstr(t));
        if !data continue;
        rep := msg(Id, cls("NSBitmapImageRep"), "imageRepWithData:", data);
        if !rep continue;
        props := msg(Id, cls("NSDictionary"), "dictionary");
        b := ns_data_bytes(msg(Id, rep, "representationUsingType:properties:", cast(NSUInteger) 4 /*PNG*/, props), allocator);
        if b.count return b, true;
    }
    return .[], false;
}

os_clipboard_files :: (allocator: Allocator) -> []string {
    pool := autorelease_pool();
    defer msg(Void, pool, "drain");
    pb := msg(Id, cls("NSPasteboard"), "generalPasteboard");
    out: [..]string;
    out.allocator = allocator;
    for file_urls(pb) array_add(*out, to_jai_string(msg(Id, it, "path"), allocator));
    return out;
}

os_apply_cursor :: () {
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
    name: *u8;
    if s.cursor == {
        case .Pointer;     name = "pointingHandCursor";
        case .IBeam;       name = "IBeamCursor";
        case .Resize_H;    name = "resizeLeftRightCursor";
        case .Resize_V;    name = "resizeUpDownCursor";
        case .Resize_NWSE; name = "_windowResizeNorthWestSouthEastCursor";
        case .Resize_NESW; name = "_windowResizeNorthEastSouthWestCursor";
        case .Move;        name = "openHandCursor";
        case .Not_Allowed; name = "operationNotAllowedCursor";
        case .Crosshair;   name = "crosshairCursor";
        case;              name = "arrowCursor";
    }
    c := cls("NSCursor");
    if !responds(c, name) name = "crosshairCursor";
    // Dynamic selector: go through performSelector.
    cur := msg(Id, c, "performSelector:", sel(name));
    if cur msg(Void, cur, "set");
}

#scope_file

WAKE_SUBTYPE :: 0x4643; // 'FC'

m: struct {
    app: Id;
    window: Id;
    view: Id;
    layer: Id;
    display_link: Id;           // CADisplayLink (macOS 14+)
    cv_link: CVDisplayLinkRef;  // fallback
    link_paused: bool;
    tick_pending: bool;
    in_next_event: bool;        // inside nextEventMatchingMask (not inside a nested modal loop)
    wake_posted: bool;          // atomic
    marked: string;             // IME marked text (heap)
    cursor_hidden: bool;
    pool: Id;                   // autorelease pool spanning one app frame
};

IMAGE_TYPES :: string.["public.png", "public.tiff", "public.jpeg", "com.compuserve.gif", "public.heic", "com.microsoft.bmp"];

responds :: (obj: Id, name: *u8) -> bool #no_context { return msg(bool, obj, "respondsToSelector:", sel(name)); }

build_menu :: (title: string) {
    bar := objc.new_obj("NSMenu");
    app_item := objc.new_obj("NSMenuItem");
    msg(Void, bar, "addItem:", app_item);
    app_menu := objc.new_obj("NSMenu");
    msg(Id, app_menu, "addItemWithTitle:action:keyEquivalent:", nsstr("Hide"), sel("hide:"), nsstr("h"));
    msg(Id, app_menu, "addItemWithTitle:action:keyEquivalent:", nsstr(tprint("Quit %", title)), sel("terminate:"), nsstr("q"));
    msg(Void, app_item, "setSubmenu:", app_menu);

    // Edit menu exists only for the system text services (emoji picker, dictation).
    // cmd+c/v/x/a/z are NOT menu items: they arrive as Key_Down events.
    edit_item := objc.new_obj("NSMenuItem");
    msg(Void, bar, "addItem:", edit_item);
    edit_menu := msg(Id, msg(Id, cls("NSMenu"), "alloc"), "initWithTitle:", nsstr("Edit"));
    emoji := msg(Id, edit_menu, "addItemWithTitle:action:keyEquivalent:", nsstr("Emoji & Symbols"), sel("orderFrontCharacterPalette:"), nsstr(" "));
    msg(Void, emoji, "setKeyEquivalentModifierMask:", cast(NSUInteger) ((1 << 18) | (1 << 20)));
    msg(Void, edit_item, "setSubmenu:", edit_menu);

    msg(Void, m.app, "setMainMenu:", bar);
}

update_size_and_scale :: () {
    bounds := msg(NSRect, m.view, "bounds");
    scale := cast(float32) msg(NSFloat, m.window, "backingScaleFactor");
    if scale <= 0 scale = 1;
    s.size = .{xx bounds.size.width, xx bounds.size.height};
    s.scale = scale;
    if m.layer {
        msg(Void, m.layer, "setContentsScale:", cast(NSFloat) scale);
        fb := framebuffer_size();
        msg(Void, m.layer, "setDrawableSize:", NSSize.{xx max(fb[0], 1), xx max(fb[1], 1)});
    }
}

update_refresh_rate :: () {
    screen := msg(Id, m.window, "screen");
    if !screen screen = msg(Id, cls("NSScreen"), "mainScreen");
    hz: float32 = 60;
    if screen && responds(screen, "maximumFramesPerSecond") {
        n := msg(NSInteger, screen, "maximumFramesPerSecond");
        if n > 0 hz = xx n;
    }
    s.refresh_hz = hz;
    if m.display_link {
        Frame_Rate_Range :: struct { minimum, maximum, preferred: float32; }
        msg(Void, m.display_link, "setPreferredFrameRateRange:", Frame_Rate_Range.{min(hz, 60), hz, hz});
    }
}

setup_display_link :: () {
    m.link_paused = true;
    if responds(m.view, "displayLinkWithTarget:selector:") {
        m.display_link = msg(Id, m.view, "displayLinkWithTarget:selector:", m.view, sel("fcTick:"));
        msg(Id, m.display_link, "retain");
        update_refresh_rate();
        msg(Void, m.display_link, "addToRunLoop:forMode:", msg(Id, cls("NSRunLoop"), "mainRunLoop"), NSRunLoopCommonModes);
        msg(Void, m.display_link, "setPaused:", true);
    } else if CVDisplayLinkCreateWithActiveCGDisplays(*m.cv_link) == 0 {
        CVDisplayLinkSetOutputCallback(m.cv_link, cast(*void) cv_callback, null);
    }
}

// CoreVideo's display-link thread.
cv_callback :: (link: CVDisplayLinkRef, now: *CVTimeStamp, out_time: *CVTimeStamp, flags_in: u64, flags_out: *u64, user: *void) -> s32 #c_call {
    c := s.ctx; push_context,defer_pop c;
    post_wake(1);
    return 0;
}

set_link_paused :: (paused: bool) {
    if m.link_paused == paused return;
    m.link_paused = paused;
    if m.display_link msg(Void, m.display_link, "setPaused:", paused);
    else if m.cv_link { if paused CVDisplayLinkStop(m.cv_link); else CVDisplayLinkStart(m.cv_link); }
}

// data1: 0 = wake, 1 = tick (CVDisplayLink thread)
post_wake :: (data1: int) {
    if data1 == 0 && atomic_exchange(*m.wake_posted, true) return;
    ev := msg(Id, cls("NSEvent"), "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:",
        cast(NSUInteger) 15, NSPoint.{}, cast(NSUInteger) 0, cast(float64) 0, cast(NSInteger) 0, cast(Id) null, cast(s16) WAKE_SUBTYPE, cast(NSInteger) data1, cast(NSInteger) 0);
    msg(Void, m.app, "postEvent:atStart:", ev, false);
}

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
    // Inside a nested AppKit loop (live resize, title-bar drag, menu tracking): our loop can't run, so
    // render from here.
    pool := autorelease_pool();
    run_frame_callback();
    msg(Void, pool, "drain");
}

pb_has_type :: (pb: Id, types: []string) -> bool {
    for types {
        arr := msg(Id, cls("NSArray"), "arrayWithObject:", nsstr(it));
        if msg(Id, pb, "availableTypeFromArray:", arr) return true;
    }
    return false;
}

ns_data_bytes :: (data: Id, allocator: Allocator) -> []u8 {
    if !data return .[];
    n := cast(int) msg(NSUInteger, data, "length");
    p := msg(*u8, data, "bytes");
    if n == 0 || !p return .[];
    out := NewArray(n, u8, false,, allocator);
    memcpy(out.data, p, n);
    return out;
}

// The file NSURLs on a pasteboard (temp); ok is false when it holds no URLs at all.
file_urls :: (pb: Id) -> urls: []Id, ok: bool {
    urls := msg(Id, pb, "readObjectsForClasses:options:", msg(Id, cls("NSArray"), "arrayWithObject:", cls("NSURL")), cast(Id) null);
    if !urls return .[], false;
    out: [..]Id;
    out.allocator = temp;
    for 0..cast(int) msg(NSUInteger, urls, "count") - 1 {
        u := msg(Id, urls, "objectAtIndex:", cast(NSUInteger) it);
        if msg(bool, u, "isFileURL") array_add(*out, u);
    }
    return out, true;
}

// ---------------------------------------------------------------------------
// Input translation

mods_from_flags :: (flags: NSUInteger) -> Mod {
    r: Mod;
    if flags & (1 << 17) r |= .Shift;
    if flags & (1 << 18) r |= .Ctrl;
    if flags & (1 << 19) r |= .Alt;
    if flags & (1 << 20) r |= .Cmd;
    return r;
}

event_mods :: (ev: Id) -> Mod { return mods_from_flags(msg(NSUInteger, ev, "modifierFlags")); }

KEYCODES :: #run -> [128]Key {
    t: [128]Key;
    t[0x00] = .A; t[0x01] = .S; t[0x02] = .D; t[0x03] = .F; t[0x04] = .H; t[0x05] = .G; t[0x06] = .Z; t[0x07] = .X;
    t[0x08] = .C; t[0x09] = .V; t[0x0B] = .B; t[0x0C] = .Q; t[0x0D] = .W; t[0x0E] = .E; t[0x0F] = .R;
    t[0x10] = .Y; t[0x11] = .T; t[0x12] = .N1; t[0x13] = .N2; t[0x14] = .N3; t[0x15] = .N4; t[0x16] = .N6;
    t[0x17] = .N5; t[0x18] = .Equals; t[0x19] = .N9; t[0x1A] = .N7; t[0x1B] = .Minus; t[0x1C] = .N8;
    t[0x1D] = .N0; t[0x1E] = .Right_Bracket; t[0x1F] = .O; t[0x20] = .U; t[0x21] = .Left_Bracket; t[0x22] = .I;
    t[0x23] = .P; t[0x24] = .Enter; t[0x25] = .L; t[0x26] = .J; t[0x27] = .Apostrophe; t[0x28] = .K;
    t[0x29] = .Semicolon; t[0x2A] = .Backslash; t[0x2B] = .Comma; t[0x2C] = .Slash; t[0x2D] = .N; t[0x2E] = .M;
    t[0x2F] = .Period; t[0x30] = .Tab; t[0x31] = .Space; t[0x32] = .Grave; t[0x33] = .Backspace;
    t[0x35] = .Escape; t[0x36] = .Cmd; t[0x37] = .Cmd; t[0x38] = .Shift; t[0x39] = .Caps_Lock; t[0x3A] = .Alt;
    t[0x3B] = .Ctrl; t[0x3C] = .Shift; t[0x3D] = .Alt; t[0x3E] = .Ctrl; t[0x4C] = .Keypad_Enter;
    t[0x60] = .F5; t[0x61] = .F6; t[0x62] = .F7; t[0x63] = .F3; t[0x64] = .F8; t[0x65] = .F9; t[0x67] = .F11;
    t[0x6D] = .F10; t[0x6F] = .F12; t[0x73] = .Home; t[0x74] = .Page_Up; t[0x75] = .Delete; t[0x76] = .F4;
    t[0x77] = .End; t[0x78] = .F2; t[0x79] = .Page_Down; t[0x7A] = .F1; t[0x7B] = .Left; t[0x7C] = .Right;
    t[0x7D] = .Down; t[0x7E] = .Up;
    return t;
}

keycode_key :: (ev: Id) -> Key {
    code := msg(u16, ev, "keyCode");
    return ifx code < 128 then KEYCODES[code] else .None;
}

key_from_event :: (ev: Id) -> Key {
    k := keycode_key(ev);
    // Letters follow the active keyboard layout (Dvorak, AZERTY...) so cmd+c means "c".
    if (k >= .A && k <= .Z) || k == .None || (k >= .N0 && k <= .N9) {
        chars := msg(Id, ev, "charactersIgnoringModifiers");
        if chars && msg(NSUInteger, chars, "length") == 1 {
            ch := msg(u16, chars, "characterAtIndex:", cast(NSUInteger) 0);
            if ch >= #char "a" && ch <= #char "z" k = cast(Key) (cast(int) Key.A + ch - #char "a");
            else if ch >= #char "A" && ch <= #char "Z" k = cast(Key) (cast(int) Key.A + ch - #char "A");
        }
    }
    return k;
}

view_point :: (p: NSPoint) -> Vector2 {
    v := msg(NSPoint, m.view, "convertPoint:fromView:", p, cast(Id) null); // view is flipped: top-left origin
    return .{xx v.x, xx v.y};
}

mouse_pos :: (ev: Id) -> Vector2 { return view_point(msg(NSPoint, ev, "locationInWindow")); }

push_mouse :: (kind: Event_Kind, ev: Id) {
    e := Event.{kind = kind, pos = mouse_pos(ev), mods = event_mods(ev), time = time_now()};
    if kind == .Mouse_Down || kind == .Mouse_Up {
        n := msg(NSInteger, ev, "buttonNumber");
        e.button = ifx n <= 3 then cast(Mouse_Button) n else .X2; // left, right, middle, X1
        // ctrl+click is a right click on macOS
        if e.button == .Left && (e.mods & .Ctrl) && kind == .Mouse_Down e.button = .Right;
        e.click_count = msg(NSInteger, ev, "clickCount");
    }
    if kind == .Mouse_Move && s.cursor != .Arrow os_apply_cursor();
    push_event(e);
}

scroll_phase :: (p: NSUInteger) -> Scroll_Phase {
    if p & 1  return .Began;
    if p & 4  return .Changed;
    if p & 8  return .Ended;
    if p & 16 return .Cancelled;
    if p & 32 return .May_Begin;
    if p & 2  return .Changed;
    return .None;
}

string_from_text_arg :: (arg: Id) -> string {
    if !arg return "";
    str := ifx msg(bool, arg, "isKindOfClass:", cls("NSAttributedString")) then msg(Id, arg, "string") else arg;
    return to_jai_string(str, temp);
}

end_marked :: () {
    if !m.marked.count return;
    free(m.marked.data);
    m.marked = "";
    push_event(.{kind = .Composition, time = time_now()});
}

push_resize :: () { push_event(.{kind = .Resize, pos = s.size, time = time_now()}); }

// ---------------------------------------------------------------------------
// ObjC classes. Every method runs on the main thread inside an AppKit call made from the UI thread, so it
// pushes that thread's stored context (s.ctx).

register_classes :: () {
    if cls("FCView") return;

    add :: (c: Id, name: *u8, imp: $T, types: *u8) {
        ok := objc.add_method(c, name, cast(*void) imp, types);
        assert(ok, to_string(name));
    }

    // ---- FCView : NSView <NSTextInputClient>
    v := objc.allocate_class(cls("NSView"), "FCView");
    add(v, "acceptsFirstResponder", view_yes, "B@:");
    add(v, "canBecomeKeyView", view_yes, "B@:");
    add(v, "acceptsFirstMouse:", view_yes1, "B@:@");
    add(v, "isFlipped", view_yes, "B@:");
    add(v, "isOpaque", view_yes, "B@:");
    add(v, "wantsUpdateLayer", view_yes, "B@:");
    add(v, "updateLayer", view_update_layer, "v@:");
    add(v, "makeBackingLayer", view_make_backing_layer, "@@:");
    add(v, "setFrameSize:", view_set_frame_size, "v@:{CGSize=dd}");
    add(v, "viewDidChangeBackingProperties", view_did_change_backing, "v@:");
    add(v, "viewWillStartLiveResize", view_will_start_live_resize, "v@:");
    add(v, "viewDidEndLiveResize", view_did_end_live_resize, "v@:");
    add(v, "updateTrackingAreas", view_update_tracking_areas, "v@:");
    add(v, "fcTick:", view_tick, "v@:@");

    add(v, "keyDown:", view_key_down, "v@:@");
    add(v, "keyUp:", view_key_up, "v@:@");
    add(v, "flagsChanged:", view_flags_changed, "v@:@");
    for string.["mouseDown:", "rightMouseDown:", "otherMouseDown:"] add(v, it.data, view_mouse_down, "v@:@");
    for string.["mouseUp:", "rightMouseUp:", "otherMouseUp:"] add(v, it.data, view_mouse_up, "v@:@");
    for string.["mouseMoved:", "mouseDragged:", "rightMouseDragged:", "otherMouseDragged:"] add(v, it.data, view_mouse_moved, "v@:@");
    add(v, "mouseEntered:", view_mouse_entered, "v@:@");
    add(v, "mouseExited:", view_mouse_exited, "v@:@");
    add(v, "scrollWheel:", view_scroll, "v@:@");
    add(v, "cursorUpdate:", view_cursor_update, "v@:@");

    // NSTextInputClient
    add(v, "hasMarkedText", ti_has_marked, "B@:");
    add(v, "markedRange", ti_marked_range, "{_NSRange=QQ}@:");
    add(v, "selectedRange", ti_selected_range, "{_NSRange=QQ}@:");
    add(v, "setMarkedText:selectedRange:replacementRange:", ti_set_marked, "v@:@{_NSRange=QQ}{_NSRange=QQ}");
    add(v, "unmarkText", ti_unmark, "v@:");
    add(v, "validAttributesForMarkedText", ti_valid_attrs, "@@:");
    add(v, "attributedSubstringForProposedRange:actualRange:", ti_attr_substring, "@@:{_NSRange=QQ}^{_NSRange=QQ}");
    add(v, "insertText:replacementRange:", ti_insert_text, "v@:@{_NSRange=QQ}");
    add(v, "insertText:", ti_insert_text_simple, "v@:@");
    add(v, "characterIndexForPoint:", ti_char_index, "Q@:{CGPoint=dd}");
    add(v, "firstRectForCharacterRange:actualRange:", ti_first_rect, "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}");
    add(v, "doCommandBySelector:", ti_do_command, "v@::");

    // Drag and drop
    add(v, "draggingEntered:", dnd_entered, "Q@:@");
    add(v, "draggingUpdated:", dnd_updated, "Q@:@");
    add(v, "draggingExited:", dnd_exited, "v@:@");
    add(v, "performDragOperation:", dnd_perform, "B@:@");

    p := objc.objc_getProtocol("NSTextInputClient");
    if p objc.class_addProtocol(v, p);
    objc.register_class(v);

    // ---- FCWindowDelegate
    w := objc.allocate_class(cls("NSObject"), "FCWindowDelegate");
    add(w, "windowShouldClose:", win_should_close, "B@:@");
    add(w, "windowDidBecomeKey:", win_did_become_key, "v@:@");
    add(w, "windowDidResignKey:", win_did_resign_key, "v@:@");
    add(w, "windowDidChangeScreen:", win_did_change_screen, "v@:@");
    add(w, "windowDidChangeBackingProperties:", win_did_change_screen, "v@:@");
    objc.register_class(w);

    // ---- FCAppDelegate
    a := objc.allocate_class(cls("NSObject"), "FCAppDelegate");
    add(a, "applicationShouldTerminate:", app_should_terminate, "Q@:@");
    add(a, "applicationShouldTerminateAfterLastWindowClosed:", view_no1, "B@:@");
    objc.register_class(a);
}

view_yes :: (self: Id, cmd: SEL) -> bool #c_call { return true; }
view_yes1 :: (self: Id, cmd: SEL, a: Id) -> bool #c_call { return true; }
view_no1 :: (self: Id, cmd: SEL, a: Id) -> bool #c_call { return false; }
view_update_layer :: (self: Id, cmd: SEL) #c_call {}

view_make_backing_layer :: (self: Id, cmd: SEL) -> Id #c_call {
    layer := msg(Id, cls("CAMetalLayer"), "layer");
    msg(Void, layer, "setFramebufferOnly:", true);
    msg(Void, layer, "setOpaque:", true);
    msg(Void, layer, "setNeedsDisplayOnBoundsChange:", false);
    msg(Void, layer, "setPixelFormat:", cast(NSUInteger) 80 /*BGRA8Unorm*/);
    // Our colors are sRGB (the client's CSS); tag the layer so macOS converts to the display's space like
    // Chrome does, instead of showing raw values (oversaturated on P3).
    srgb := CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    msg(Void, layer, "setColorspace:", srgb);
    CGColorSpaceRelease(srgb);
    msg(Void, layer, "setMaximumDrawableCount:", cast(NSUInteger) 3);
    if responds(layer, "setDisplaySyncEnabled:") msg(Void, layer, "setDisplaySyncEnabled:", true);
    // Don't let CA animate resizes/scale changes of our content.
    msg(Void, layer, "setActions:", msg(Id, cls("NSDictionary"), "dictionary"));
    return layer;
}

view_set_frame_size :: (self: Id, cmd: SEL, size: NSSize) #c_call {
    super := cast(#type (self: Id, cmd: SEL, size: NSSize) #c_call) objc.class_getMethodImplementation(cls("NSView"), cmd);
    super(self, cmd, size);
    c := s.ctx; push_context,defer_pop c;
    if !m.view || self != m.view return;
    old := s.size;
    update_size_and_scale();
    if old != s.size {
        push_resize();
        if msg(bool, self, "inLiveResize") {
            pool := autorelease_pool();
            run_frame_callback();
            msg(Void, pool, "drain");
        }
    }
}

view_did_change_backing :: (self: Id, cmd: SEL) #c_call {
    c := s.ctx; push_context,defer_pop c;
    if !m.view return;
    old_scale := s.scale;
    update_size_and_scale();
    update_refresh_rate();
    if old_scale != s.scale push_resize();
}

// Present inside the CA transaction that resizes the window: no stretching or tearing.
view_will_start_live_resize :: (self: Id, cmd: SEL) #c_call {
    if m.layer msg(Void, m.layer, "setPresentsWithTransaction:", true);
}

view_did_end_live_resize :: (self: Id, cmd: SEL) #c_call {
    c := s.ctx; push_context,defer_pop c;
    if m.layer msg(Void, m.layer, "setPresentsWithTransaction:", false);
    push_resize();
}

view_update_tracking_areas :: (self: Id, cmd: SEL) #c_call {
    areas := msg(Id, self, "trackingAreas");
    for < i: 0..cast(int) msg(NSUInteger, areas, "count") - 1 {
        msg(Void, self, "removeTrackingArea:", msg(Id, areas, "objectAtIndex:", cast(NSUInteger) i));
    }
    // MouseEnteredAndExited | MouseMoved | CursorUpdate | ActiveAlways | InVisibleRect | EnabledDuringMouseDrag
    opts := cast(NSUInteger) (0x01 | 0x02 | 0x04 | 0x80 | 0x200 | 0x400);
    bounds := msg(NSRect, self, "bounds");
    area := msg(Id, msg(Id, cls("NSTrackingArea"), "alloc"), "initWithRect:options:owner:userInfo:", bounds, opts, self, cast(Id) null);
    msg(Void, self, "addTrackingArea:", area);
    msg(Void, area, "release");
    super := cast(#type (self: Id, cmd: SEL) #c_call) objc.class_getMethodImplementation(cls("NSView"), cmd);
    super(self, cmd);
}

view_tick :: (self: Id, cmd: SEL, link: Id) #c_call {
    c := s.ctx; push_context,defer_pop c;
    on_tick();
    // Wake nextEventMatchingMask so os_wait sees tick_pending.
    if m.in_next_event && m.tick_pending post_wake(0);
}

view_key_down :: (self: Id, cmd: SEL, ev: Id) #c_call {
    c := s.ctx; push_context,defer_pop c;
    e := Event.{kind = .Key_Down, key = key_from_event(ev), mods = event_mods(ev), is_repeat = msg(bool, ev, "isARepeat"), time = time_now()};
    had_marked := m.marked.count > 0;
    idx := pending_count();
    if !(e.mods & .Cmd) msg(Void, self, "interpretKeyEvents:", msg(Id, cls("NSArray"), "arrayWithObject:", ev));
    // The key goes before the Text events interpretKeyEvents queued, unless the IME took it.
    if !had_marked && !m.marked.count {
        locks.guard(*s.queue_lock);
        array_insert_at(*s.pending, e, min(idx, s.pending.count));
    }
}

view_key_up :: (self: Id, cmd: SEL, ev: Id) #c_call {
    c := s.ctx; push_context,defer_pop c;
    push_event(.{kind = .Key_Up, key = key_from_event(ev), mods = event_mods(ev), time = time_now()});
}

view_flags_changed :: (self: Id, cmd: SEL, ev: Id) #c_call {
    c := s.ctx; push_context,defer_pop c;
    mods := event_mods(ev);
    k := keycode_key(ev);
    mod: Mod;
    if k == {
        case .Shift; mod = .Shift;
        case .Ctrl;  mod = .Ctrl;
        case .Alt;   mod = .Alt;
        case .Cmd;   mod = .Cmd;
        case; return;
    }
    push_event(.{kind = ifx mods & mod then .Key_Down else .Key_Up, key = k, mods = mods, time = time_now()});
}

view_mouse_down :: (self: Id, cmd: SEL, ev: Id) #c_call { c := s.ctx; push_context,defer_pop c; push_mouse(.Mouse_Down, ev); }
view_mouse_up :: (self: Id, cmd: SEL, ev: Id) #c_call { c := s.ctx; push_context,defer_pop c; push_mouse(.Mouse_Up, ev); }
view_mouse_moved :: (self: Id, cmd: SEL, ev: Id) #c_call { c := s.ctx; push_context,defer_pop c; push_mouse(.Mouse_Move, ev); }
view_cursor_update :: (self: Id, cmd: SEL, ev: Id) #c_call { c := s.ctx; push_context,defer_pop c; os_apply_cursor(); }

view_mouse_entered :: (self: Id, cmd: SEL, ev: Id) #c_call {
    c := s.ctx; push_context,defer_pop c;
    os_apply_cursor();
    push_mouse(.Mouse_Move, ev);
}

view_mouse_exited :: (self: Id, cmd: SEL, ev: Id) #c_call {
    c := s.ctx; push_context,defer_pop c;
    if m.cursor_hidden {
        msg(Void, cls("NSCursor"), "unhide");
        m.cursor_hidden = false;
    }
    push_event(.{kind = .Mouse_Leave, pos = mouse_pos(ev), time = time_now()});
}

view_scroll :: (self: Id, cmd: SEL, ev: Id) #c_call {
    c := s.ctx; push_context,defer_pop c;
    d := Vector2.{xx msg(NSFloat, ev, "scrollingDeltaX"), xx msg(NSFloat, ev, "scrollingDeltaY")};
    precise := msg(bool, ev, "hasPreciseScrollingDeltas");
    if !precise d = .{d.x * 40, d.y * 40}; // Chrome: 40px per wheel tick
    momentum := msg(NSUInteger, ev, "momentumPhase");
    push_event(.{
        kind = .Scroll,
        pos = mouse_pos(ev),
        delta = d,
        mods = event_mods(ev),
        precise = precise,
        momentum = momentum != 0,
        scroll_phase = scroll_phase(ifx momentum then momentum else msg(NSUInteger, ev, "phase")),
        time = time_now(),
    });
}

// ---- NSTextInputClient

ti_has_marked :: (self: Id, cmd: SEL) -> bool #c_call { return m.marked.count > 0; }

ti_marked_range :: (self: Id, cmd: SEL) -> NSRange #c_call {
    c := s.ctx; push_context,defer_pop c;
    if !m.marked.count return .{NS_NOT_FOUND, 0};
    return .{0, xx utf16_count(m.marked)};
}

ti_selected_range :: (self: Id, cmd: SEL) -> NSRange #c_call {
    c := s.ctx; push_context,defer_pop c;
    if !m.marked.count return .{0, 0};
    return .{xx utf16_count(m.marked), 0};
}

ti_set_marked :: (self: Id, cmd: SEL, str: Id, sel_range: NSRange, repl: NSRange) #c_call {
    c := s.ctx; push_context,defer_pop c;
    text := string_from_text_arg(str);
    free(m.marked.data);
    m.marked = copy_string(text);
    a := utf16_to_byte(text, xx sel_range.location);
    b := utf16_to_byte(text, xx (sel_range.location + sel_range.length));
    push_event(.{kind = .Composition, text = text, composition_sel = .[a, b], time = time_now()});
}

ti_unmark :: (self: Id, cmd: SEL) #c_call { c := s.ctx; push_context,defer_pop c; end_marked(); }

ti_valid_attrs :: (self: Id, cmd: SEL) -> Id #c_call { return msg(Id, cls("NSArray"), "array"); }

ti_attr_substring :: (self: Id, cmd: SEL, r: NSRange, actual: *NSRange) -> Id #c_call { return null; }

ti_insert_text :: (self: Id, cmd: SEL, str: Id, repl: NSRange) #c_call {
    c := s.ctx; push_context,defer_pop c;
    text := string_from_text_arg(str);
    end_marked();
    if !text return;
    // Drop control chars and AppKit's private-use function-key characters.
    r, n := character_utf8_to_utf32(text.data, text.count);
    if n == text.count && (r < 0x20 || r == 0x7f || (r >= 0xF700 && r <= 0xF8FF)) return;
    push_event(.{kind = .Text, text = text, time = time_now()});
}

ti_insert_text_simple :: (self: Id, cmd: SEL, str: Id) #c_call { ti_insert_text(self, cmd, str, .{NS_NOT_FOUND, 0}); }

ti_char_index :: (self: Id, cmd: SEL, p: NSPoint) -> NSUInteger #c_call { return NS_NOT_FOUND; }

ti_first_rect :: (self: Id, cmd: SEL, r: NSRange, actual: *NSRange) -> NSRect #c_call {
    c := s.ctx; push_context,defer_pop c;
    if actual actual.* = r;
    ir := s.ime_rect;
    // view (flipped) -> window -> screen
    local := NSRect.{.{ir.x, ir.y}, .{max(ir.z, 1), max(ir.w, 1)}};
    in_win := msg(NSRect, m.view, "convertRect:toView:", local, cast(Id) null);
    return msg(NSRect, m.window, "convertRectToScreen:", in_win);
}

// Swallow: keys are delivered as Key_Down events; don't beep.
ti_do_command :: (self: Id, cmd: SEL, command: SEL) #c_call {}

// ---- Drag and drop

dnd_entered :: (self: Id, cmd: SEL, info: Id) -> NSUInteger #c_call {
    c := s.ctx; push_context,defer_pop c;
    push_event(.{kind = .Drag_Enter, pos = view_point(msg(NSPoint, info, "draggingLocation")), time = time_now()});
    return 1; // Copy
}

dnd_updated :: (self: Id, cmd: SEL, info: Id) -> NSUInteger #c_call { return 1; /*Copy*/ }

dnd_exited :: (self: Id, cmd: SEL, info: Id) #c_call {
    c := s.ctx; push_context,defer_pop c;
    push_event(.{kind = .Drag_Leave, time = time_now()});
}

dnd_perform :: (self: Id, cmd: SEL, info: Id) -> bool #c_call {
    c := s.ctx; push_context,defer_pop c;
    pos := view_point(msg(NSPoint, info, "draggingLocation"));
    urls, ok := file_urls(msg(Id, info, "draggingPasteboard"));
    for urls push_event(.{kind = .File_Drop, text = to_jai_string(msg(Id, it, "path"), temp), pos = pos, time = time_now()});
    push_event(.{kind = .Drag_Leave, time = time_now()});
    return ok;
}

// ---- Window / app delegates

push_quit :: () {
    s.quit = true;
    push_event(.{kind = .Quit, time = time_now()});
}

win_should_close :: (self: Id, cmd: SEL, sender: Id) -> bool #c_call {
    c := s.ctx; push_context,defer_pop c;
    push_quit();
    return false; // the app decides; it will exit its loop
}

win_did_become_key :: (self: Id, cmd: SEL, n: Id) #c_call {
    c := s.ctx; push_context,defer_pop c;
    push_event(.{kind = .Focus_Gained, time = time_now()});
}

win_did_resign_key :: (self: Id, cmd: SEL, n: Id) #c_call {
    c := s.ctx; push_context,defer_pop c;
    push_event(.{kind = .Focus_Lost, time = time_now()});
}

win_did_change_screen :: (self: Id, cmd: SEL, n: Id) #c_call {
    c := s.ctx; push_context,defer_pop c;
    if !m.view return;
    update_size_and_scale();
    update_refresh_rate();
}

app_should_terminate :: (self: Id, cmd: SEL, sender: Id) -> NSUInteger #c_call {
    c := s.ctx; push_context,defer_pop c;
    push_quit();
    return 0; // NSTerminateCancel; the app exits its own loop
}
