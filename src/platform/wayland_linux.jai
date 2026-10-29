// Linux: native Wayland, picked over X11 when WAYLAND_DISPLAY is set and the compositor answers (os_init).
// libwayland-client, libwayland-egl and libxkbcommon are opened with dlopen like libX11, so the binary still
// runs where they are missing. The protocols outside wayland.xml (xdg-shell, xdg-decoration, fractional
// scale, viewporter, text-input-v3, cursor-shape) are small tables built here instead of scanner output.
// Every proxy shares one dispatcher (wl_proxy_add_dispatcher), keyed by the Obj tag it was given.

#scope_module

wl: struct {
    on: bool;
    csd: bool; // no server-side decorations: the app draws the caption buttons (draws_caption)
    d, registry, compositor, shm, seat, wm_base, deco_mgr, frac_mgr, viewporter, ti_mgr, shape_mgr, ddm: *void;
    surface, xdg_surface, toplevel, decoration, fractional, viewport, egl_window: *void;
    pointer, keyboard, shape_dev, data_device, text_input: *void;
    cursor_surface, cursor_theme: *void;
    cursor_theme_scale: s32;
    outputs: [..]struct { p: *void; scale: s32; };
    entered: [..]*void; // outputs the surface is on

    w, h: s32; // logical size (points)
    pend_w, pend_h: s32;
    pend_max, pend_full: bool;
    configured, hidden, maximized: bool;
    scale120: u32;       // fractional-scale-v1's, 0 until it arrives
    buffer_scale: s32 = 1;
    preferred_scale: s32; // wl_surface v6's preferred_buffer_scale, 0 = none
    frame_pending: bool;

    serial: u32;       // the last key or button press, for set_selection, move and resize
    enter_serial: u32; // the pointer's enter, for its cursor
    pos: Vector2;
    edge: u32;         // the resize edge under the pointer (csd), 0 = none
    hit: (p: Vector2) -> Window_Hit;
    axis: [2]float32;
    v120: [2]s32;
    discrete: bool;

    xkb_ctx, keymap, xkb_state, compose: *void;
    mods: Mod;
    numlock: bool;
    repeat_rate, repeat_delay: s32;
    repeat_key: u32;
    repeat_at: float64;

    ti_on: bool;
    ime_rect: Vector4;
    preedit, commit: string; // heap, pending until done
    preedit_sel: [2]int;
    composing: bool;

    offers: [..]Offer;
    clip_lock: locks.Mutex; // sel and sel_mimes, read from clipboard threads
    sel: *void;
    sel_mimes: Mime;
    own_lock: locks.Mutex;
    own_source: *void; // ours while we own the selection
    own_text: string;
    own_png: []u8;
    writes: [..]struct { fd: s32; data: []u8; off: int; };
    dnd_offer: *void;
    dnd_entered: bool;
    drop_fd: s32 = -1;
    drop_buf: [..]u8;
};

wl_init :: (title: string, width: int, height: int) -> bool {
    lib := dlopen("libwayland-client.so.0", RTLD_NOW);
    egl_lib := dlopen("libwayland-egl.so.1", RTLD_NOW);
    xkb_lib := dlopen("libxkbcommon.so.0", RTLD_NOW);
    if !lib || !egl_lib || !xkb_lib || !load_syms(lib, *W, "wl_") || !load_syms(lib, *CORE, "wl_") || !load_syms(egl_lib, *WE, "wl_egl_") || !load_syms(xkb_lib, *XKB, "xkb_") return false;
    wl.d = W.display_connect(null);
    if !wl.d return false;
    cur_lib := dlopen("libwayland-cursor.so.0", RTLD_NOW);
    if cur_lib && !load_syms(cur_lib, *WC, "wl_cursor_") WC.theme_load = null;
    make_protocols();
    wl.registry = make(wl.d, 1, CORE.registry_interface, 0);
    listen(wl.registry, .Registry);
    W.display_roundtrip(wl.d);
    if !wl.compositor || !wl.wm_base {
        W.display_disconnect(wl.d);
        wl.d = null;
        return false;
    }
    W.display_roundtrip(wl.d); // the seat's capabilities, the outputs' scales
    wl.xkb_ctx = XKB.context_new(0);
    locale := "C";
    for string.["LC_ALL", "LC_CTYPE", "LANG"] if getenv(temp_c_string(it)) { locale = to_string(getenv(temp_c_string(it))); break; }
    table := XKB.compose_table_new_from_locale(wl.xkb_ctx, temp_c_string(locale), 0);
    if table wl.compose = XKB.compose_state_new(table, 0); // dead keys and Compose sequences

    wl.surface = make(wl.compositor, 0, CORE.surface_interface, 0);
    listen(wl.surface, .Surface);
    if wl.frac_mgr && wl.viewporter {
        wl.fractional = make(wl.frac_mgr, 1, FRACTIONAL, 0, 0, xx wl.surface);
        listen(wl.fractional, .Fractional);
        wl.viewport = make(wl.viewporter, 1, VIEWPORT, 0, 0, xx wl.surface);
    }
    wl.xdg_surface = make(wl.wm_base, 2, XDG_SURFACE, 0, 0, xx wl.surface);
    listen(wl.xdg_surface, .Xdg_Surface);
    wl.toplevel = make(wl.xdg_surface, 1, TOPLEVEL, 0);
    listen(wl.toplevel, .Toplevel);
    req(wl.toplevel, 2, xx temp_c_string(title));
    req(wl.toplevel, 3, xx "fastcord".data); // the desktop entry's name
    req(wl.toplevel, 8, MIN_WINDOW_W, MIN_WINDOW_H);
    wl.csd = true;
    if wl.deco_mgr {
        wl.decoration = make(wl.deco_mgr, 1, DECORATION, 0, 0, xx wl.toplevel);
        listen(wl.decoration, .Decoration);
        req(wl.decoration, 1, 2); // server_side
    }
    r := xs.normal; // logical size on Wayland
    wl.w, wl.h = xx ifx r.width > 0 then r.width else width, xx ifx r.height > 0 then r.height else height;
    if r.maximized req(wl.toplevel, 9);
    req(wl.surface, 6); // the initial commit asks for the first configure
    for 1..50 if !wl.configured W.display_roundtrip(wl.d);
    if !wl.configured {
        W.display_disconnect(wl.d);
        wl.d = null;
        return false;
    }
    scale := surface_scale();
    wl.egl_window = WE.window_create(wl.surface, xx (wl.w * scale + 0.5), xx (wl.h * scale + 0.5));
    if wl.ti_mgr && wl.seat {
        wl.text_input = make(wl.ti_mgr, 1, TEXT_INPUT, 0, 0, xx wl.seat);
        listen(wl.text_input, .Text_Input);
    }
    if wl.ddm && wl.seat {
        wl.data_device = make(wl.ddm, 1, CORE.data_device_interface, 0, 0, xx wl.seat);
        listen(wl.data_device, .Data_Device);
    }
    wl.on = true;
    apply_size();
    return true;
}

wl_shutdown :: () {
    if wl.egl_window WE.window_destroy(wl.egl_window);
    W.display_disconnect(wl.d);
    wl.on = false;
}

// Pumps Wayland events until there is something to do, like the X11 os_wait; also runs key repeat, which
// Wayland leaves to the client.
wl_wait :: (timeout: float64) {
    start := time_now();
    if wl.ti_on && s.ime_rect != wl.ime_rect {
        wl.ime_rect = s.ime_rect;
        r := s.ime_rect;
        req(wl.text_input, 6, I(r.x), I(r.y), I(max(r.z, 1)), I(max(r.w, 1)));
        req(wl.text_input, 7);
    }
    while true {
        n: u64;
        read(xs.wake_fd, *n, 8);
        if W.display_dispatch_pending(wl.d) < 0 { connection_lost(); return; }
        now := time_now();
        if wl.repeat_key && now >= wl.repeat_at {
            if now - wl.repeat_at > 0.25 wl.repeat_at = now; // no burst after a stall
            wl.repeat_at += 1.0 / wl.repeat_rate;
            key_event(wl.repeat_key, true, true);
        }
        if s.quit || atomic_load(*s.frame_requested) || pending_count() > 0 return;
        ms: s32 = -1;
        if timeout >= 0 {
            remaining := timeout - (now - start);
            if remaining <= 0 return;
            ms = cast(s32) (remaining * 1000 + 0.999);
        }
        if wl.repeat_key {
            r := cast(s32) ((wl.repeat_at - now) * 1000 + 0.999);
            if ms < 0 || r < ms ms = max(r, 0);
        }
        poll_once(ms);
    }
}

// Waits (up to 100 ms, so a hidden window still draws slowly) for the compositor's frame callback from the
// last present: the vsync pacing EGL's own swap interval would block on forever while the window is hidden.
wl_frame_wait :: () {
    deadline := time_now() + 0.1;
    while wl.frame_pending && !s.quit {
        left := deadline - time_now();
        if left <= 0 break;
        poll_once(cast(s32) (left * 1000 + 0.999));
        if W.display_dispatch_pending(wl.d) < 0 { connection_lost(); return; }
    }
}

// Before eglSwapBuffers commits: asks for this frame's callback. False while the surface may not take a
// buffer (hidden to the tray, or not configured since).
wl_present_begin :: () -> bool {
    if wl.hidden || !wl.configured return false;
    listen(make(wl.surface, 3, CORE.callback_interface, 0), .Frame);
    wl.frame_pending = true;
    return true;
}

wl_placement :: () -> Window_Placement, bool {
    if !wl.maximized && !xs.fullscreen xs.normal = .{0, 0, wl.w, wl.h, false};
    p := xs.normal;
    p.maximized = wl.maximized;
    return p, p.width > 0;
}

wl_fullscreen :: (on: bool) {
    xs.fullscreen = on;
    if on req(wl.toplevel, 11, 0); else req(wl.toplevel, 12);
    W.display_flush(wl.d);
}

// Remaps a window hidden to the tray: a commit with no buffer asks for a new configure. Raising a shown
// window needs an xdg-activation token, which only a launcher hands over.
wl_show :: () {
    if !wl.hidden return;
    wl.hidden = false;
    req(wl.surface, 6);
    W.display_flush(wl.d);
}

wl_close :: () {
    if tray_hides() {
        // a null buffer unmaps the window; present_begin keeps EGL from attaching one until wl_show
        req(wl.surface, 1, 0, 0, 0);
        req(wl.surface, 6);
        W.display_flush(wl.d);
        wl.hidden, wl.configured = true, false;
        return;
    }
    s.quit = true;
    push_event(.{kind = .Quit, time = time_now()});
}

wl_toplevel_request :: (op: u32) { req(wl.toplevel, op); W.display_flush(wl.d); }

wl_apply_cursor :: () { if !wl.edge set_pointer_cursor(s.cursor); }

wl_clipboard_set :: (text: string, png: []u8) {
    {
        locks.guard(*wl.own_lock);
        free(wl.own_text.data);
        array_free(wl.own_png);
        wl.own_text, wl.own_png = copy_string(text), array_copy(png);
    }
    if !wl.ddm || !wl.data_device return;
    old := wl.own_source;
    src := make(wl.ddm, 0, CORE.data_source_interface, 0);
    listen(src, .Source);
    names: []string = string.["text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "TEXT", "STRING"];
    if png names = string.["image/png"];
    for names req(src, 0, xx temp_c_string(it));
    req(wl.data_device, 1, xx src, wl.serial);
    {
        locks.guard(*wl.clip_lock);
        wl.own_source = src;
    }
    if old { req(old, 1); W.proxy_destroy(old); }
    W.display_flush(wl.d);
}

wl_clipboard_kind :: () -> Clipboard_Kind {
    locks.guard(*wl.clip_lock);
    if wl.own_source {
        locks.guard(*wl.own_lock);
        return ifx wl.own_png then .Image else .Text;
    }
    if !wl.sel return .None;
    m := wl.sel_mimes;
    if (m & (.Uri | .Gnome)) != 0 && read_files_wl(temp).count return .Files;
    if (m & .Png) != 0 return .Image;
    if (m & (.Text | .Utf8 | .Plain)) != 0 return .Text;
    return .None;
}

wl_clipboard_get :: (allocator: Allocator) -> string {
    locks.guard(*wl.clip_lock);
    if wl.own_source {
        locks.guard(*wl.own_lock);
        return copy_string(wl.own_text,, allocator);
    }
    m := wl.sel_mimes;
    mime := ifx (m & .Text) != 0 then "text/plain;charset=utf-8" else ifx (m & .Utf8) != 0 then "UTF8_STRING" else ifx (m & .Plain) != 0 then "text/plain" else "";
    if !wl.sel || !mime return "";
    b, ok := read_offer(wl.sel, mime, allocator);
    return ifx ok then string.{b.count, b.data} else "";
}

wl_clipboard_image :: (allocator: Allocator) -> []u8, bool {
    locks.guard(*wl.clip_lock);
    if wl.own_source {
        locks.guard(*wl.own_lock);
        return array_copy(wl.own_png,, allocator), wl.own_png.count > 0;
    }
    if !wl.sel || (wl.sel_mimes & .Png) == 0 return .[], false;
    b, ok := read_offer(wl.sel, "image/png", allocator);
    if ok && b.count return b, true;
    array_free(b);
    return .[], false;
}

wl_clipboard_files :: (allocator: Allocator) -> []string {
    locks.guard(*wl.clip_lock);
    if wl.own_source || !wl.sel return .[];
    return read_files_wl(allocator);
}

// Wayland axis 0 is vertical, 1 horizontal (not Vector2's component order).
wl_scroll_delta :: (axis: [2]float32, v120: [2]s32, discrete: bool) -> Vector2 {
    if discrete return .{-v120[1] * 53.0 / 120, -v120[0] * 53.0 / 120};
    return .{-axis[1], -axis[0]};
}

#scope_file

#import "POSIX";


Wl_Message :: struct { name, signature: *u8; types: **Wl_Interface; }
Wl_Interface :: struct {
    name: *u8;
    version: s32;
    method_count: s32;
    methods: *Wl_Message;
    event_count: s32;
    events: *Wl_Message;
}
#assert size_of(Wl_Interface) == 40;

// libwayland-client (each field is "wl_" + its name)
W: struct {
    display_connect: (name: *u8) -> *void #c_call;
    display_disconnect: (d: *void) #c_call;
    display_get_fd: (d: *void) -> s32 #c_call;
    display_roundtrip: (d: *void) -> s32 #c_call;
    display_flush: (d: *void) -> s32 #c_call;
    display_dispatch_pending: (d: *void) -> s32 #c_call;
    display_prepare_read: (d: *void) -> s32 #c_call;
    display_read_events: (d: *void) -> s32 #c_call;
    display_cancel_read: (d: *void) #c_call;
    proxy_marshal_array_constructor_versioned: (p: *void, opcode: u32, args: *u64, iface: *Wl_Interface, version: u32) -> *void #c_call;
    proxy_add_dispatcher: (p: *void, f: (impl: *void, p: *void, opcode: u32, msg: *Wl_Message, args: *u64) -> s32 #c_call, impl: *void, data: *void) -> s32 #c_call;
    proxy_destroy: (p: *void) #c_call;
    proxy_get_version: (p: *void) -> u32 #c_call;
};

// wayland.xml's interfaces, exported by libwayland-client.
CORE: struct {
    registry_interface, compositor_interface, surface_interface, callback_interface, seat_interface,
    pointer_interface, keyboard_interface, output_interface, shm_interface, data_device_manager_interface,
    data_device_interface, data_offer_interface, data_source_interface: *Wl_Interface;
};

WE: struct { // libwayland-egl
    window_create: (surface: *void, w: s32, h: s32) -> *void #c_call;
    window_resize: (win: *void, w: s32, h: s32, dx: s32, dy: s32) #c_call;
    window_destroy: (win: *void) #c_call;
};

Wl_Cursor_Image :: struct { width, height, hotspot_x, hotspot_y, delay: u32; }
Wl_Cursor :: struct { image_count: u32; images: **Wl_Cursor_Image; name: *u8; }
WC: struct { // libwayland-cursor (optional: the themed cursors where cursor-shape-v1 is missing)
    theme_load: (name: *u8, size: s32, shm: *void) -> *void #c_call;
    theme_destroy: (theme: *void) #c_call;
    theme_get_cursor: (theme: *void, name: *u8) -> *Wl_Cursor #c_call;
    image_get_buffer: (image: *Wl_Cursor_Image) -> *void #c_call;
};

XKB: struct { // libxkbcommon
    context_new: (flags: s32) -> *void #c_call;
    keymap_new_from_string: (ctx: *void, s: *u8, format: s32, flags: s32) -> *void #c_call;
    keymap_unref: (k: *void) #c_call;
    keymap_key_get_syms_by_level: (k: *void, key: u32, layout: u32, level: u32, syms: **u32) -> s32 #c_call;
    keymap_key_repeats: (k: *void, key: u32) -> s32 #c_call;
    state_new: (k: *void) -> *void #c_call;
    state_unref: (st: *void) #c_call;
    state_update_mask: (st: *void, depressed: u32, latched: u32, locked: u32, d_layout: u32, l_layout: u32, layout: u32) -> s32 #c_call;
    state_key_get_one_sym: (st: *void, key: u32) -> u32 #c_call;
    state_key_get_utf8: (st: *void, key: u32, buf: *u8, size: u64) -> s32 #c_call;
    state_mod_name_is_active: (st: *void, name: *u8, type: s32) -> s32 #c_call;
    compose_table_new_from_locale: (ctx: *void, locale: *u8, flags: s32) -> *void #c_call;
    compose_state_new: (table: *void, flags: s32) -> *void #c_call;
    compose_state_feed: (st: *void, sym: u32) -> s32 #c_call;
    compose_state_get_status: (st: *void) -> s32 #c_call;
    compose_state_get_utf8: (st: *void, buf: *u8, size: u64) -> s32 #c_call;
    compose_state_reset: (st: *void) #c_call;
};

// The protocols libwayland-client doesn't carry: request and event signatures in opcode order, every
// event of the version bound (an unknown opcode is fatal), object types left null (no new_id events).
WM_BASE, XDG_SURFACE, TOPLEVEL, DECO_MGR, DECORATION, FRAC_MGR, FRACTIONAL, VIEWPORTER, VIEWPORT, TI_MGR,
    TEXT_INPUT, SHAPE_MGR, SHAPE_DEV: *Wl_Interface;

make_protocols :: () {
    proto :: (name: string, version: s32, requests: string, events: string) -> *Wl_Interface {
        NULLS :: #run -> [8]*Wl_Interface { n: [8]*Wl_Interface; return n; };
        msgs :: (spec: string) -> s32, *Wl_Message {
            if !spec return 0, null;
            parts := split(spec, " ",, temp);
            out := NewArray(parts.count, Wl_Message);
            for parts {
                c := find_index_from_left(it, #char ":");
                out[it_index] = .{to_c_string(slice(it, 0, c)), to_c_string(slice(it, c + 1, it.count - c - 1)), NULLS.data};
            }
            return xx out.count, out.data;
        }
        i := New(Wl_Interface);
        i.name, i.version = to_c_string(name), version;
        i.method_count, i.methods = msgs(requests);
        i.event_count, i.events = msgs(events);
        return i;
    }
    WM_BASE = proto("xdg_wm_base", 6, "destroy: create_positioner:n get_xdg_surface:no pong:u", "ping:u");
    XDG_SURFACE = proto("xdg_surface", 6, "destroy: get_toplevel:n get_popup:n?oo set_window_geometry:iiii ack_configure:u", "configure:u");
    TOPLEVEL = proto("xdg_toplevel", 6, "destroy: set_parent:?o set_title:s set_app_id:s show_window_menu:ouii move:ou resize:ouu set_max_size:ii set_min_size:ii set_maximized: unset_maximized: set_fullscreen:?o unset_fullscreen: set_minimized:",
        "configure:iia close: configure_bounds:ii wm_capabilities:a");
    DECO_MGR = proto("zxdg_decoration_manager_v1", 1, "destroy: get_toplevel_decoration:no", "");
    DECORATION = proto("zxdg_toplevel_decoration_v1", 1, "destroy: set_mode:u unset_mode:", "configure:u");
    FRAC_MGR = proto("wp_fractional_scale_manager_v1", 1, "destroy: get_fractional_scale:no", "");
    FRACTIONAL = proto("wp_fractional_scale_v1", 1, "destroy:", "preferred_scale:u");
    VIEWPORTER = proto("wp_viewporter", 1, "destroy: get_viewport:no", "");
    VIEWPORT = proto("wp_viewport", 1, "destroy: set_source:ffff set_destination:ii", "");
    TI_MGR = proto("zwp_text_input_manager_v3", 1, "destroy: get_text_input:no", "");
    TEXT_INPUT = proto("zwp_text_input_v3", 1, "destroy: enable: disable: set_surrounding_text:sii set_text_change_cause:u set_content_type:uu set_cursor_rectangle:iiii commit:",
        "enter:o leave:o preedit_string:?sii commit_string:?s delete_surrounding_text:uu done:u");
    SHAPE_MGR = proto("wp_cursor_shape_manager_v1", 1, "destroy: get_pointer:no get_tablet_tool_v2:no", "");
    SHAPE_DEV = proto("wp_cursor_shape_device_v1", 1, "destroy: set_shape:uu", "");
}

// A request with no new object; arguments are wl_argument slots (ints in the low 32 bits).
req :: (p: *void, opcode: u32, args: ..u64) {
    a: [8]u64;
    for args a[it_index] = it;
    W.proxy_marshal_array_constructor_versioned(p, opcode, a.data, null, 0);
}

// A request that creates an object of iface (its new_id slot is one of args, 0); version 0 = the parent's.
make :: (p: *void, opcode: u32, iface: *Wl_Interface, version: u32, args: ..u64) -> *void {
    a: [8]u64;
    for args a[it_index] = it;
    if !args.count a[0] = 0;
    return W.proxy_marshal_array_constructor_versioned(p, opcode, a.data, iface, ifx version then version else W.proxy_get_version(p));
}

I :: (v: float32) -> u64 { return cast(u32) cast(s32) v; }

Obj :: enum u64 { None; Registry; Wm_Base; Xdg_Surface; Toplevel; Decoration; Fractional; Surface; Seat; Pointer; Keyboard; Frame; Output; Data_Device; Offer; Source; Text_Input; }

listen :: (p: *void, kind: Obj) {
    W.proxy_add_dispatcher(p, dispatch, cast(*void) cast(u64) kind, null);
}

dispatch :: (impl: *void, p: *void, op: u32, msg: *Wl_Message, args: *u64) -> s32 #c_call {
    c := s.ctx;
    push_context,defer_pop c;
    on_event(cast(Obj) cast(u64) impl, p, op, args);
    return 0;
}

Mime :: enum_flags u8 { Text; Utf8; Plain; Uri; Gnome; Png; }
MIMES :: string.["text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "text/uri-list", "x-special/gnome-copied-files", "image/png"];
Offer :: struct { p: *void; mimes: Mime; }

on_event :: (kind: Obj, p: *void, op: u32, args: *u64) {
    u :: (n: int) -> u32 #expand { return cast(u32) `args[n]; }
    i :: (n: int) -> s32 #expand { return cast(s32) `args[n]; }
    ptr :: (n: int) -> *void #expand { return cast(*void) `args[n]; }
    now := time_now();
    if kind == {
    case .Registry;
        if op != 0 return;
        name, iface, have := u(0), to_string(cast(*u8) args[1]), u(2);
        bind :: (want: u32, ifc: *Wl_Interface, kind := Obj.None) -> *void #expand {
            v := min(min(`have, want), cast(u32) ifc.version);
            o := make(wl.registry, 0, ifc, v, `name, xx ifc.name, v, 0);
            if kind != .None listen(o, kind);
            return o;
        }
        if iface == {
        case "wl_compositor"; wl.compositor = bind(6, CORE.compositor_interface);
        case "wl_shm"; wl.shm = bind(1, CORE.shm_interface);
        case "wl_seat"; if !wl.seat wl.seat = bind(8, CORE.seat_interface, .Seat);
        case "wl_output"; array_add(*wl.outputs, .{bind(2, CORE.output_interface, .Output), 1});
        case "wl_data_device_manager"; wl.ddm = bind(3, CORE.data_device_manager_interface);
        case "xdg_wm_base"; wl.wm_base = bind(6, WM_BASE, .Wm_Base);
        case "zxdg_decoration_manager_v1"; wl.deco_mgr = bind(1, DECO_MGR);
        case "wp_fractional_scale_manager_v1"; wl.frac_mgr = bind(1, FRAC_MGR);
        case "wp_viewporter"; wl.viewporter = bind(1, VIEWPORTER);
        case "zwp_text_input_manager_v3"; wl.ti_mgr = bind(1, TI_MGR);
        case "wp_cursor_shape_manager_v1"; wl.shape_mgr = bind(1, SHAPE_MGR);
        }
    case .Wm_Base;
        req(p, 3, u(0)); // pong
    case .Xdg_Surface;
        req(p, 4, u(0)); // ack_configure
        wl.configured = true;
        if wl.pend_w > 0 && wl.pend_h > 0 wl.w, wl.h = wl.pend_w, wl.pend_h;
        wl.maximized, xs.fullscreen = wl.pend_max, wl.pend_full;
        apply_size();
    case .Toplevel;
        if op == 0 {
            wl.pend_w, wl.pend_h = i(0), i(1);
            a := cast(*struct { size, alloc: u64; data: *u32; }) ptr(2);
            states := []u32.{xx min(a.size / 4, 64), a.data};
            wl.pend_max, wl.pend_full = array_find(states, 1), array_find(states, 2);
        } else if op == 1 wl_close();
    case .Decoration;
        wl.csd = u(0) == 1;
        request_frame();
    case .Fractional;
        if u(0) != wl.scale120 { wl.scale120 = u(0); apply_size(); }
    case .Surface;
        if op == 0 array_add(*wl.entered, ptr(0));
        else if op == 1 array_unordered_remove_by_value(*wl.entered, ptr(0));
        else if op == 2 wl.preferred_scale = i(0);
        else return;
        apply_size();
    case .Output;
        if op != 3 return;
        for * wl.outputs if it.p == p it.scale = i(0);
        apply_size();
    case .Frame;
        W.proxy_destroy(p);
        wl.frame_pending = false;
    case .Seat;
        if op != 0 return;
        caps := u(0);
        if (caps & 1) && !wl.pointer {
            wl.pointer = make(p, 0, CORE.pointer_interface, 0);
            listen(wl.pointer, .Pointer);
            if wl.shape_mgr wl.shape_dev = make(wl.shape_mgr, 1, SHAPE_DEV, 0, 0, xx wl.pointer);
        }
        if (caps & 2) && !wl.keyboard {
            wl.keyboard = make(p, 1, CORE.keyboard_interface, 0);
            listen(wl.keyboard, .Keyboard);
        }
        // the last keyboard or mouse went away (unplugged; a virtual keyboard's client quit): a new one
        // comes with the next capabilities event
        release :: (o: **void) { if W.proxy_get_version(o.*) >= 3 req(o.*, xx ifx o == *wl.pointer then 1 else 0); W.proxy_destroy(o.*); o.* = null; }
        if !(caps & 1) && wl.pointer {
            if wl.shape_dev { req(wl.shape_dev, 0); W.proxy_destroy(wl.shape_dev); wl.shape_dev = null; }
            release(*wl.pointer);
        }
        if !(caps & 2) && wl.keyboard { release(*wl.keyboard); wl.repeat_key = 0; }
    case .Pointer;
        pointer_event(op, args, now);
    case .Keyboard;
        if op == {
        case 0; // keymap: format, fd, size
            fd, size := i(1), u(2);
            if u(0) == 1 && size > 0 && size < 1 << 24 { // xkb v1, under 16 MiB
                m := mmap(null, size, PROT_READ, MAP_PRIVATE, fd, 0);
                if m != MAP_FAILED {
                    km := XKB.keymap_new_from_string(wl.xkb_ctx, m, 1, 0);
                    munmap(m, size);
                    if km {
                        if wl.xkb_state XKB.state_unref(wl.xkb_state);
                        if wl.keymap XKB.keymap_unref(wl.keymap);
                        wl.keymap, wl.xkb_state = km, XKB.state_new(km);
                    }
                }
            }
            close(fd);
        case 1;
            wl.serial = u(0);
            push_event(.{kind = .Focus_Gained, time = now});
        case 2;
            wl.repeat_key = 0;
            push_event(.{kind = .Focus_Lost, time = now});
        case 3; // key: serial, time, key, state
            if u(3) == 1 wl.serial = u(0);
            key_event(u(2), u(3) == 1, false);
        case 4; // modifiers
            if !wl.xkb_state return;
            XKB.state_update_mask(wl.xkb_state, u(1), u(2), u(3), 0, 0, u(4));
            on :: (name: *u8) -> bool { return XKB.state_mod_name_is_active(wl.xkb_state, name, 1 << 3 /*EFFECTIVE*/) > 0; }
            wl.mods = 0;
            if on("Shift") wl.mods |= .Shift;
            if on("Control") wl.mods |= .Ctrl;
            if on("Mod1") wl.mods |= .Alt;
            if on("Mod4") wl.mods |= .Cmd;
            wl.numlock = on("Mod2");
        case 5;
            wl.repeat_rate, wl.repeat_delay = i(0), i(1);
        }
    case .Data_Device;
        data_device_event(op, args, now);
    case .Offer;
        if op != 0 return;
        mime := to_string(cast(*u8) args[0]);
        for * o: wl.offers if o.p == p for m, mi: MIMES if m == mime o.mimes |= cast(Mime) (1 << mi);
    case .Source;
        if op == 1 { // send: mime, fd
            fd := i(1);
            data: []u8;
            {
                locks.guard(*wl.own_lock);
                data = ifx wl.own_png then array_copy(wl.own_png) else array_copy(cast([]u8) wl.own_text);
            }
            fcntl(fd, F_SETFL, cast(s32) O_NONBLOCK);
            array_add(*wl.writes, .{fd, data, 0});
        } else if op == 2 { // cancelled
            if p == wl.own_source {
                locks.guard(*wl.clip_lock);
                wl.own_source = null;
            }
            W.proxy_destroy(p);
        }
    case .Text_Input;
        ti := wl.text_input;
        if op == {
        case 0;
            wl.ti_on = true;
            wl.ime_rect = .{-1, -1, -1, -1}; // sent by the next wl_wait
            req(ti, 1);
            req(ti, 5, 0, 0);
            req(ti, 7);
        case 1;
            wl.ti_on = false;
            req(ti, 2);
            req(ti, 7);
        case 2;
            free(wl.preedit.data);
            wl.preedit = copy_string(to_string(cast(*u8) args[0]));
            b, e: int = i(1), i(2);
            wl.preedit_sel = .[ifx b < 0 then wl.preedit.count else min(b, wl.preedit.count), ifx e < 0 then wl.preedit.count else min(e, wl.preedit.count)];
        case 3;
            free(wl.commit.data);
            wl.commit = copy_string(to_string(cast(*u8) args[0]));
        case 5; // done: the commit, then the new preedit
            if wl.commit push_event(.{kind = .Text, text = wl.commit, time = now});
            if wl.preedit push_event(.{kind = .Composition, text = wl.preedit, composition_sel = wl.preedit_sel, time = now});
            else if wl.composing push_event(.{kind = .Composition, time = now});
            wl.composing = wl.preedit != "";
            free(wl.preedit.data);
            free(wl.commit.data);
            wl.preedit, wl.commit = "", "";
        }
    }
}

pointer_event :: (op: u32, args: *u64, now: float64) {
    f :: (n: int) -> float32 #expand { return cast(s32) `args[n] / 256.0; }
    if op == {
    case 0; // enter: serial, surface, x, y
        wl.enter_serial = xx args[0];
        wl.pos = .{f(2), f(3)};
        wl.edge = 0;
        set_pointer_cursor(s.cursor);
        push_event(.{kind = .Mouse_Move, pos = wl.pos, mods = wl.mods, time = now});
    case 1;
        push_event(.{kind = .Mouse_Leave, time = now});
    case 2; // motion: time, x, y
        wl.pos = .{f(1), f(2)};
        e := edge_at(wl.pos);
        if e != wl.edge {
            wl.edge = e;
            EDGE_CURSORS :: Cursor.[.Arrow, .Resize_V, .Resize_V, .Arrow, .Resize_H, .Resize_NWSE, .Resize_NESW, .Arrow, .Resize_H, .Resize_NESW, .Resize_NWSE];
            set_pointer_cursor(ifx e then EDGE_CURSORS[e] else s.cursor);
        }
        push_event(.{kind = .Mouse_Move, pos = wl.pos, mods = wl.mods, time = now});
    case 3; // button: serial, time, button, state
        code, down := cast(u32) args[2], cast(u32) args[3] == 1;
        if code < 272 || code > 276 return; // BTN_LEFT, RIGHT, MIDDLE, SIDE, EXTRA
        btn := Mouse_Button.[.Left, .Right, .Middle, .X1, .X2][code - 272];
        if down wl.serial = xx args[0];
        cc := ifx down then count_click(btn, wl.pos, now) else xs.click_count;
        // our own frame: the edges resize, the title bar's empty space moves, maximizes, or opens the window menu
        if down && wl.csd && (btn == .Left || btn == .Right) {
            if wl.edge && btn == .Left { req(wl.toplevel, 6, xx wl.seat, wl.serial, wl.edge); return; }
            if wl.hit && wl.hit(wl.pos / s.zoom) == .Caption {
                if btn == .Right req(wl.toplevel, 4, xx wl.seat, wl.serial, I(wl.pos.x), I(wl.pos.y));
                else if cc == 2 req(wl.toplevel, xx ifx wl.maximized then 10 else 9);
                else req(wl.toplevel, 5, xx wl.seat, wl.serial);
                return;
            }
        }
        push_event(.{kind = ifx down then .Mouse_Down else .Mouse_Up, button = btn, pos = wl.pos, mods = wl.mods, click_count = cc, time = now});
    case 4; // axis: time, axis, value
        a := cast(u32) args[1];
        if a < 2 wl.axis[a] += f(2);
        if W.proxy_get_version(wl.pointer) < 5 scroll(now);
    case 5;
        scroll(now);
    case 8; // axis_discrete
        a := cast(u32) args[0];
        if a < 2 { wl.v120[a] += cast(s32) args[1] * 120; wl.discrete = true; }
    case 9; // axis_value120
        a := cast(u32) args[0];
        if a < 2 { wl.v120[a] = cast(s32) args[1]; wl.discrete = true; }
    }
}

// A frame's axis events as one Scroll: wheels as Chromium's X11 53px per notch, touchpads in pixels.
scroll :: (now: float64) {
    d := wl_scroll_delta(wl.axis, wl.v120, wl.discrete);
    if d.x || d.y push_event(.{kind = .Scroll, pos = wl.pos, delta = d, precise = !wl.discrete, mods = wl.mods, time = now});
    wl.axis, wl.v120, wl.discrete = .[0, 0], .[0, 0], false;
}

// The 8pt resize band of our own frame (xdg_toplevel resize_edge), 16pt along each edge at the corners.
edge_at :: (p: Vector2) -> u32 {
    if !wl.csd || wl.maximized || xs.fullscreen return 0;
    w, h := cast(float32) wl.w, cast(float32) wl.h;
    l, t, r, b := p.x < 8, p.y < 8, p.x >= w - 8, p.y >= h - 8;
    if !(l || t || r || b) return 0;
    cl, ct, cr, cb := p.x < 16, p.y < 16, p.x >= w - 16, p.y >= h - 16;
    if (t && cl) || (l && ct) return 5;
    if (t && cr) || (r && ct) return 9;
    if (b && cl) || (l && cb) return 6;
    if (b && cr) || (r && cb) return 10;
    if t return 1;
    if b return 2;
    return ifx l then cast(u32) 4 else 8;
}

set_pointer_cursor :: (c: Cursor) {
    if !wl.pointer return;
    if c == .Hidden { req(wl.pointer, 0, wl.enter_serial, 0, 0, 0); return; }
    if wl.shape_dev {
        SHAPES :: u32.[1, 4, 9, 26, 27, 29, 28, 13, 15, 8]; // default, pointer, text, ew, ns, nwse, nesw, move, not-allowed, crosshair
        req(wl.shape_dev, 1, wl.enter_serial, SHAPES[c]);
        return;
    }
    if !WC.theme_load || !wl.shm return;
    sc := cast(s32) (s.scale + 0.99);
    if !wl.cursor_theme || wl.cursor_theme_scale != sc {
        if wl.cursor_theme WC.theme_destroy(wl.cursor_theme);
        size := ifx getenv("XCURSOR_SIZE") then string_to_int(to_string(getenv("XCURSOR_SIZE"))) else 0;
        wl.cursor_theme = WC.theme_load(getenv("XCURSOR_THEME"), xx (ifx size > 0 && size < 256 then size else 24) * sc, wl.shm);
        wl.cursor_theme_scale = sc;
        if !wl.cursor_theme return;
    }
    NAMES :: string.["default", "pointer", "text", "ew-resize", "ns-resize", "nwse-resize", "nesw-resize", "move", "not-allowed", "crosshair"];
    cur := WC.theme_get_cursor(wl.cursor_theme, NAMES[c].data);
    if !cur cur = WC.theme_get_cursor(wl.cursor_theme, "left_ptr");
    if !cur || !cur.image_count return;
    img := cur.images[0];
    if !wl.cursor_surface wl.cursor_surface = make(wl.compositor, 0, CORE.surface_interface, 0);
    req(wl.pointer, 0, wl.enter_serial, xx wl.cursor_surface, img.hotspot_x / cast(u32) sc, img.hotspot_y / cast(u32) sc);
    req(wl.cursor_surface, 1, xx WC.image_get_buffer(img), 0, 0);
    req(wl.cursor_surface, 8, xx sc);
    req(wl.cursor_surface, 2, 0, 0, 0x7fff_ffff, 0x7fff_ffff);
    req(wl.cursor_surface, 6);
}

key_event :: (code: u32, down: bool, repeat: bool) {
    if !wl.xkb_state return;
    now := time_now();
    kc := code + 8; // evdev to xkb (X) keycodes
    syms: *u32;
    base: u32;
    if XKB.keymap_key_get_syms_by_level(wl.keymap, kc, 0, 0, *syms) > 0 base = syms[0];
    key := map_key_code(base, xx kc, wl.numlock);
    if !down {
        if code == wl.repeat_key wl.repeat_key = 0;
        push_event(.{kind = .Key_Up, key = key, mods = wl.mods, time = now});
        return;
    }
    if !repeat && wl.repeat_rate > 0 && XKB.keymap_key_repeats(wl.keymap, kc) {
        wl.repeat_key, wl.repeat_at = code, now + wl.repeat_delay / 1000.0;
    }
    push_event(.{kind = .Key_Down, key = key, mods = wl.mods, is_repeat = repeat, time = now});
    buf: [64]u8;
    n: s32;
    sym := XKB.state_key_get_one_sym(wl.xkb_state, kc);
    if wl.compose && XKB.compose_state_feed(wl.compose, sym) == 1 /*ACCEPTED*/ {
        st := XKB.compose_state_get_status(wl.compose);
        if st == 1 /*COMPOSING*/ return;
        if st == 3 /*CANCELLED*/ { XKB.compose_state_reset(wl.compose); return; }
        if st == 2 /*COMPOSED*/ {
            n = XKB.compose_state_get_utf8(wl.compose, buf.data, buf.count);
            XKB.compose_state_reset(wl.compose);
        }
    }
    if !n n = XKB.state_key_get_utf8(wl.xkb_state, kc, buf.data, buf.count);
    text := string.{min(cast(int) n, buf.count - 1), buf.data};
    if text.count <= 0 || (text.count == 1 && (text[0] < 0x20 || text[0] == 0x7f)) return;
    if wl.mods & (.Ctrl | .Alt | .Cmd) return; // shortcuts are Key_Down only (AltGr is Mod5 and types text)
    push_event(.{kind = .Text, text = text, time = now});
}

data_device_event :: (op: u32, args: *u64, now: float64) {
    if op == {
    case 0; // data_offer: a new offer, its mime types follow
        o := cast(*void) args[0];
        listen(o, .Offer);
        array_add(*wl.offers, .{o, 0});
    case 1; // enter: serial, surface, x, y, offer
        if wl.drop_fd >= 0 { drop_offer(cast(*void) args[4]); return; } // still reading the last drop
        drop_offer(wl.dnd_offer);
        wl.dnd_offer = cast(*void) args[4];
        files := (offer_mimes(wl.dnd_offer) & .Uri) != 0;
        if wl.dnd_offer {
            req(wl.dnd_offer, 0, args[0], xx ifx files then "text/uri-list".data else null);
            if files && W.proxy_get_version(wl.dnd_offer) >= 3 req(wl.dnd_offer, 4, 1, 1); // copy
        }
        if files {
            wl.dnd_entered = true;
            push_event(.{kind = .Drag_Enter, pos = .{cast(s32) args[2] / 256.0, cast(s32) args[3] / 256.0}, time = now});
        }
    case 2; // leave
        if wl.drop_fd >= 0 return; // read_drop ends it
        drop_offer(wl.dnd_offer);
        wl.dnd_offer = null;
        dnd_end();
    case 4; // drop: read the uri-list without blocking (os_wait polls it)
        fds: [2]s32;
        if !wl.dnd_entered || pipe2(*fds, O_CLOEXEC) != 0 { dnd_end(); return; }
        req(wl.dnd_offer, 1, xx "text/uri-list".data, xx fds[1]);
        W.display_flush(wl.d);
        close(fds[1]);
        fcntl(fds[0], F_SETFL, cast(s32) O_NONBLOCK);
        wl.drop_fd = fds[0];
        wl.drop_buf.count = 0;
    case 5; // selection: the clipboard's offer, or none
        o := cast(*void) args[0];
        locks.guard(*wl.clip_lock);
        if wl.sel != wl.dnd_offer drop_offer(wl.sel);
        wl.sel, wl.sel_mimes = o, offer_mimes(o);
    }
}

dnd_end :: () {
    if wl.dnd_entered push_event(.{kind = .Drag_Leave, time = time_now()});
    wl.dnd_entered = false;
}

offer_mimes :: (o: *void) -> Mime {
    for wl.offers if it.p == o return it.mimes;
    return 0;
}

drop_offer :: (o: *void) {
    if !o return;
    for wl.offers if it.p == o { remove it; break; }
    req(o, 2);
    W.proxy_destroy(o);
}

// Waits up to ms for the display, the wake fd, pending clipboard writes and a drop's read, and handles them.
poll_once :: (ms: s32) {
    while W.display_prepare_read(wl.d) != 0 if W.display_dispatch_pending(wl.d) < 0 { connection_lost(); return; }
    W.display_flush(wl.d);
    fds: [..]pollfd;
    fds.allocator = temp;
    array_add(*fds, .{fd = W.display_get_fd(wl.d), events = POLLIN}, .{fd = xs.wake_fd, events = POLLIN}, .{fd = wl.drop_fd, events = POLLIN});
    for wl.writes array_add(*fds, .{fd = it.fd, events = POLLOUT});
    poll(fds.data, xx fds.count, ms);
    if fds[0].revents & POLLIN W.display_read_events(wl.d);
    else W.display_cancel_read(wl.d);
    if fds[2].revents read_drop();
    for * wl.writes {
        if !fds[it_index + 3].revents continue;
        n := write(it.fd, it.data.data + it.off, xx (it.data.count - it.off));
        if n > 0 it.off += n;
        if it.off >= it.data.count || (n < 0 && errno() != EAGAIN) || (fds[it_index + 3].revents & (POLLERR | POLLHUP)) {
            close(it.fd);
            array_free(it.data);
            remove it;
        }
    }
}

read_drop :: () {
    buf: [16384]u8;
    while true {
        n := read(wl.drop_fd, buf.data, buf.count);
        if n < 0 && errno() == EAGAIN return;
        if n > 0 && wl.drop_buf.count + n <= 1 << 20 { array_add(*wl.drop_buf, ..array_view(buf, 0, n)); continue; }
        break; // the end, an error, or over 1 MiB of paths
    }
    close(wl.drop_fd);
    wl.drop_fd = -1;
    for uri_paths(string.{wl.drop_buf.count, wl.drop_buf.data}, temp) push_event(.{kind = .File_Drop, text = it, time = time_now()});
    if W.proxy_get_version(wl.dnd_offer) >= 3 req(wl.dnd_offer, 3); // finish
    drop_offer(wl.dnd_offer);
    wl.dnd_offer = null;
    dnd_end();
    request_frame();
}

// clip_lock held: the offer's data in mime, through a pipe, waiting up to a second; at most 64 MiB.
read_offer :: (offer: *void, mime: string, allocator: Allocator) -> [..]u8, bool {
    out: [..]u8;
    out.allocator = allocator;
    fds: [2]s32;
    if pipe2(*fds, O_CLOEXEC) != 0 return out, false;
    req(offer, 1, xx temp_c_string(mime), xx fds[1]);
    W.display_flush(wl.d);
    close(fds[1]);
    defer close(fds[0]);
    fcntl(fds[0], F_SETFL, cast(s32) O_NONBLOCK);
    deadline := time_now() + 1;
    buf: [65536]u8;
    while true {
        n := read(fds[0], buf.data, buf.count);
        if n == 0 return out, true;
        if n > 0 && out.count + n <= 64 << 20 { array_add(*out, ..array_view(buf, 0, n)); continue; }
        left := deadline - time_now();
        if n > 0 || errno() != EAGAIN || left <= 0 break;
        pfd := pollfd.{fd = fds[0], events = POLLIN};
        poll(*pfd, 1, cast(s32) (left * 1000 + 1));
    }
    array_reset(*out);
    return out, false;
}

// clip_lock held. text/uri-list (Dolphin, Nautilus) or GNOME's copied-files list.
read_files_wl :: (allocator: Allocator) -> []string {
    for Mime.[.Uri, .Gnome] {
        if (wl.sel_mimes & it) == 0 continue;
        b, ok := read_offer(wl.sel, ifx it == .Uri then "text/uri-list" else "x-special/gnome-copied-files", temp);
        if ok return uri_paths(string.{b.count, b.data}, allocator);
    }
    return .[];
}

// The fractional scale, else the compositor's preferred integer scale, else the largest of the outputs the
// window is on.
surface_scale :: () -> float32 {
    wl.buffer_scale = 1;
    if wl.scale120 return wl.scale120 / 120.0;
    if wl.preferred_scale > 0 wl.buffer_scale = wl.preferred_scale;
    else for o: wl.outputs if array_find(wl.entered, o.p) wl.buffer_scale = max(wl.buffer_scale, o.scale);
    return xx wl.buffer_scale;
}

// The logical size or scale changed: the buffer follows (at the next swap) and the app relayouts.
apply_size :: () {
    scale := surface_scale();
    if !wl.egl_window return;
    if wl.viewport req(wl.viewport, 2, xx wl.w, xx wl.h);
    req(wl.surface, 8, xx ifx wl.viewport then 1 else wl.buffer_scale); // a viewport scales any buffer size
    WE.window_resize(wl.egl_window, xx (wl.w * scale + 0.5), xx (wl.h * scale + 0.5), 0, 0);
    size := Vector2.{xx wl.w, xx wl.h};
    if size == s.size && scale == s.scale { request_frame(); return; }
    s.scale, s.size = scale, size;
    push_event(.{kind = .Resize, pos = s.size, time = time_now()});
    request_frame();
}

connection_lost :: () {
    if s.quit return;
    s.quit = true;
    push_event(.{kind = .Quit, time = time_now()});
}
