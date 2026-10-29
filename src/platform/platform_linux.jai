// Linux: X11, or native Wayland when WAYLAND_DISPLAY is set and the compositor answers (wayland_linux.jai,
// whose procedures these dispatch to while wl.on). libX11 and libwayland are loaded with dlopen so the binary
// links nothing but glibc and still starts (headless) where neither is present.

// The X Display* and window id, or the wl_display and wl_egl_window, for gfx (EGL); null headless.
native_display :: () -> *void { return ifx wl.on then wl.d else xs.d; }
native_window :: () -> *void { return ifx wl.on then wl.egl_window else cast(*void) xs.win; }
is_wayland :: () -> bool { return wl.on; }

// gfx calls this right before eglSwapBuffers; false skips the present (Wayland: unmapped or unconfigured).
present_begin :: () -> bool { return !wl.on || wl_present_begin(); }

// Wayland compositors without server-side decorations (GNOME): the app draws the caption buttons, and the
// title bar's empty space (set_window_hit_callback) moves the window, as on Windows.
draws_caption :: () -> bool { return wl.on && wl.csd; }
Window_Hit :: enum u8 { Client; Caption; Maximize; }
set_window_hit_callback :: (cb: (p: Vector2) -> Window_Hit) { wl.hit = cb; }
window_minimize :: () { if wl.on wl_toplevel_request(13); }
window_maximized :: () -> bool { return wl.on && wl.maximized; }
window_toggle_maximize :: () { if wl.on wl_toplevel_request(xx ifx wl.maximized then 10 else 9); }
window_close :: () { if wl.on wl_close(); }
native_metal_layer :: () -> *void { return null; }

// X11 has no way to keep a window out of screen captures.
set_capture_hidden :: (hidden: bool) {}

// EGL paces swaps to vsync (eglSwapInterval 1): there is no waitable object.
set_frame_wait_handle :: (h: *void) {}

// GNOME's color-scheme (prefer-dark), else a GTK theme named "...dark", read by gsettings on a thread every
// two seconds. ok is false headless or without gsettings.
system_dark_mode :: () -> dark: bool, ok: bool {
    if s.headless return false, false;
    locks.guard(*xs.prefs_lock);
    return xs.prefs.dark, xs.prefs.known;
}

// GNOME's enable-animations (off -> prefers-reduced-motion) and high-contrast (prefers-contrast: more).
system_a11y :: () -> System_A11y {
    if s.headless return .{};
    locks.guard(*xs.prefs_lock);
    return xs.prefs.a11y;
}

// "Open file" dialog by zenity or kdialog, when one is installed. Returns absolute paths (empty if
// cancelled). Blocks like the other platforms' modal panels.
open_file_dialog :: (allow_multiple := true, allocator := context.allocator) -> []string {
    if s.headless return .[];
    args: [..]string;
    args.allocator = temp;
    if in_path("zenity") {
        array_add(*args, "zenity", "--file-selection", "--separator=\n");
        if allow_multiple array_add(*args, "--multiple");
    } else if in_path("kdialog") {
        array_add(*args, "kdialog", "--getopenfilename");
        if allow_multiple array_add(*args, "--multiple", "--separate-output");
    } else {
        return .[];
    }
    r, out := run_command(..args, capture_and_return_output = true,, temp);
    paths: [..]string;
    paths.allocator = allocator;
    if r.exit_code != 0 return paths;
    for split(out, "\n",, temp) if begins_with(it, "/") array_add(*paths, copy_string(it,, allocator));
    return paths;
}

// "Save file" dialog by zenity or kdialog, offering name in ~/Downloads. The path, or "" if cancelled or
// neither is installed. Blocks like the other platforms' modal panels.
// drag_out: no drag source on Linux yet (it needs an XDND source with XdndDirectSave or text/uri-list).
Drag_Write :: #type (url: string, path: string) -> bool;
drag_out :: (url: string, name: string, write: Drag_Write) -> bool { return false; }

save_file_dialog :: (name: string, allocator := context.allocator) -> string {
    if s.headless return copy_string(name,, allocator);
    start := tprint("%/Downloads/%", to_string(getenv("HOME")), name);
    r: Process_Result;
    out: string;
    if in_path("zenity") r, out = run_command("zenity", "--file-selection", "--save", "--confirm-overwrite", tprint("--filename=%", start), capture_and_return_output = true,, temp);
    else if in_path("kdialog") r, out = run_command("kdialog", "--getsavefilename", start, capture_and_return_output = true,, temp);
    else return "";
    out = trim_right(out, "\n");
    if r.exit_code != 0 || !begins_with(out, "/") return "";
    return copy_string(out,, allocator);
}

// Desktop notifications on Linux: org.freedesktop.Notifications over the session bus, through libdbus
// (opened at run time; every desktop with a notification daemon has it), else notify-send. The unread badge
// is com.canonical.Unity.LauncherEntry, which KDE's task manager and Ubuntu's dock read. All bus traffic
// runs on one thread, so a stuck daemon never holds the UI thread; a click on a notification comes back as a
// Notification_Click event carrying its id.

notify_show :: (title: string, body: string, id: string) -> bool {
    if s.headless return false;
    if !bus_start() {
        if !in_path("notify-send") return false;
        spawn_detached("notify-send", "-a", "fastcord", "-i", "fastcord", "--", title, body);
        return true;
    }
    bus_post(.{title = copy_string(title), body = copy_string(body), id = copy_string(id)});
    return true;
}

set_badge :: (text: string) {
    if s.headless || !bus_start() return;
    bus_post(.{badge = true, id = copy_string(text)});
}

// Opens a file or folder with its default app (Explorer, the file manager).
open_path :: (path: string) { open_url(path); }

// Reads text aloud through speech-dispatcher, cutting off what it was saying. The text goes on spd-say's
// stdin (-e), never in its arguments, so none of it is read as an option.
speak :: (text: string) {
    spawn_detached("sh", "-c", "spd-say -C; printf '%s' \"$1\" | spd-say -e", "sh", text);
}

// Opens a URL in the user's default browser. xdg-open runs whatever it is given: the app's
// `open_url` checks the scheme.
open_url :: (url: string) {
    spawn_detached("xdg-open", url);
}

// Placed by StaticGravity hints, so x, y are the client area's, not the frame's.
window_placement :: () -> Window_Placement, bool {
    if wl.on { p, ok := wl_placement(); return p, ok; }
    if s.headless || !xs.win return .{}, false;
    b: [..]u8;
    b.allocator = temp;
    get_property(xs.d, xs.win, xs.a._NET_WM_STATE, *b);
    states := []Atom.{b.count / 8, cast(*Atom) b.data};
    maxed := array_find(states, xs.a._NET_WM_STATE_MAXIMIZED_VERT) && array_find(states, xs.a._NET_WM_STATE_MAXIMIZED_HORZ);
    if !maxed && !array_find(states, xs.a._NET_WM_STATE_FULLSCREEN) {
        x, y: s32;
        child: Window;
        X.TranslateCoordinates(xs.d, xs.win, xs.root, 0, 0, *x, *y, *child);
        xs.normal = .{x, y, xs.px_w, xs.px_h, false};
    }
    if xs.normal.width <= 0 return .{}, false;
    p := xs.normal;
    p.maximized = maxed;
    return p, true;
}

window_placement_restore :: (p: Window_Placement) { xs.normal = p; }

// The OS's fullscreen (a video's fullscreen takes the whole screen), asked of the window manager (EWMH).
set_fullscreen :: (on: bool) {
    if wl.on && on != xs.fullscreen { wl_fullscreen(on); return; }
    if s.headless || !xs.win || on == xs.fullscreen return;
    xs.fullscreen = on;
    ev: XEvent;
    ev.xclient = .{type = ClientMessage, window = xs.win, message_type = xs.a._NET_WM_STATE, format = 32};
    ev.xclient.l[0] = xx on; // _NET_WM_STATE_ADD / _REMOVE
    ev.xclient.l[1] = xx xs.a._NET_WM_STATE_FULLSCREEN;
    ev.xclient.l[3] = 1; // from an application
    X.SendEvent(xs.d, xs.root, 0, SubstructureRedirectMask | SubstructureNotifyMask, *ev);
    X.Flush(xs.d);
}
is_fullscreen :: () -> bool { return xs.fullscreen; }

// Brings the window to the front: mapped, then _NET_ACTIVE_WINDOW asks the window manager (EWMH).
window_show :: () {
    if wl.on { wl_show(); return; }
    if s.headless || !xs.win return;
    X.MapWindow(xs.d, xs.win);
    ev: XEvent;
    ev.xclient = .{type = ClientMessage, window = xs.win, message_type = xs.a._NET_ACTIVE_WINDOW, format = 32};
    ev.xclient.l[0] = 1; // from an application
    X.SendEvent(xs.d, xs.root, 0, SubstructureRedirectMask | SubstructureNotifyMask, *ev);
    X.Flush(xs.d);
}

// Open at login: an XDG autostart entry ($XDG_CONFIG_HOME/autostart), as the official client writes.
open_at_login :: () -> bool {
    if s.headless return s.headless_login;
    return file_exists(autostart_path());
}

set_open_at_login :: (on: bool) {
    if s.headless { s.headless_login = on; return; }
    p := autostart_path();
    if !on { file_delete(p); return; }
    make_directory_if_it_does_not_exist(path_strip_filename(p), recursive = true);
    exe := replace(replace(get_path_of_running_executable(), "\\", "\\\\",, temp), "\"", "\\\"",, temp);
    write_entire_file(p, tprint("[Desktop Entry]\nType=Application\nName=Fastcord\nExec=\"%\"\nIcon=fastcord\nTerminal=false\nX-GNOME-Autostart-enabled=true\n", exe));
}

autostart_path :: () -> string {
    xdg := to_string(getenv("XDG_CONFIG_HOME"));
    if !begins_with(xdg, "/") xdg = tprint("%/.config", to_string(getenv("HOME")));
    return tprint("%/autostart/fastcord.desktop", xdg);
}

#scope_module

tray_changed :: () { if bus.state == 1 bus_post(.{tray = true}); } // the menu's checkmarks (set_tray_voice)
tray_hides :: () -> bool { return atomic_load(*bus.tray) && s.close_to_tray; } // closing hides to the tray

// Global input: XInput2 raw key and button events from the root window, on a thread with its own
// connection. Under Wayland (XWayland) they come only while an X11 window has focus.
os_global_input :: (on: bool) -> Global_Input {
    if !on {
        if !gx.on return .Off;
        atomic_store(*gx.stop, true);
        thread_is_done(*gx.thread, -1);
        thread_deinit(*gx.thread);
        X.CloseDisplay(gx.d);
        gx.on, gx.stop, gx.d = false, false, null;
        return .Off;
    }
    if wl.on return .Unavailable; // Wayland has no global input; XInput2 would see only XWayland's windows
    if !gx.lib gx.lib = dlopen("libXi.so.6", RTLD_NOW);
    if !gx.lib || !gx.select gx.select = xx dlsym(gx.lib, "XISelectEvents");
    if !gx.select return .Unavailable;
    gx.d = X.OpenDisplay(null);
    ev, err: s32;
    if !gx.d || !X.QueryExtension(gx.d, "XInputExtension", *gx.opcode, *ev, *err) {
        if gx.d X.CloseDisplay(gx.d);
        gx.d = null;
        return .Unavailable;
    }
    bits: [4]u8;
    for 13..16 bits[it >> 3] |= cast(u8) (1 << (it & 7)); // XI_RawKeyPress, RawKeyRelease, RawButtonPress, RawButtonRelease
    mask := XIEventMask.{deviceid = 1 /*XIAllMasterDevices*/, mask_len = bits.count, mask = bits.data};
    gx.select(gx.d, X.DefaultRootWindow(gx.d), *mask, 1);
    X.Flush(gx.d);
    thread_init(*gx.thread, (t: *Thread) -> s64 {
        fd := X.ConnectionNumber(gx.d);
        while !atomic_load(*gx.stop) {
            pfd := pollfd.{fd = fd, events = POLLIN};
            poll(*pfd, 1, 250);
            while X.Pending(gx.d) {
                e: XEvent;
                X.NextEvent(gx.d, *e);
                c := cast(*XGenericEventCookie) *e;
                if c.type != 35 /*GenericEvent*/ || c.extension != gx.opcode || !X.GetEventData(gx.d, c) continue;
                r := cast(*XIRawEvent) c.data;
                if c.evtype == 13 || c.evtype == 14 global_event(map_keysym(X.kbKeycodeToKeysym(gx.d, xx r.detail, 0, 0)), .Left, c.evtype == 13);
                else if r.detail == 2 || r.detail == 8 || r.detail == 9 global_event(.None, ifx r.detail == 2 then Mouse_Button.Middle else ifx r.detail == 8 then .X1 else .X2, c.evtype == 15);
                X.FreeEventData(gx.d, c);
            }
        }
        return 0;
    });
    thread_start(*gx.thread);
    gx.on = true;
    return .On;
}

gx: struct {
    on: bool;
    stop: bool; // atomic
    lib: *void;
    select: (d: *void, w: Window, masks: *XIEventMask, n: s32) -> s32 #c_call;
    d: *void;
    opcode: s32;
    thread: Thread;
};

XIEventMask :: struct { deviceid: s32; mask_len: s32; mask: *u8; }
XGenericEventCookie :: struct { type: s32; serial: u64; send_event: s32; display: *void; extension: s32; evtype: s32; cookie: u32; data: *void; }
XIRawEvent :: struct { type: s32; serial: u64; send_event: s32; display: *void; extension: s32; evtype: s32; time: u64; deviceid, sourceid, detail, flags: s32; }

os_init :: (title: string, width: int, height: int) -> bool {
    xs.wake_fd = eventfd(0, xx (EFD.NONBLOCK | .CLOEXEC));
    if in_path("gsettings") {
        thread_init(*xs.prefs_thread, prefs_proc);
        thread_start(*xs.prefs_thread);
    }
    if getenv("WAYLAND_DISPLAY") && !getenv("FASTCORD_X11") && wl_init(title, width, height) {
        if bus_start() bus_post(.{tray = true});
        return true;
    }
    xs.lib = dlopen("libX11.so.6", RTLD_NOW);
    if !xs.lib || !load_syms(xs.lib, *X, "X") return false;
    X.InitThreads(); // clipboard reads run on worker threads, on their own connection
    // XIM needs a locale; the user's, else a UTF-8 one
    if !setlocale(LC_CTYPE, "") || !X.SupportsLocale() setlocale(LC_CTYPE, "C.UTF-8");
    xs.d = X.OpenDisplay(null);
    if !xs.d return false;
    // the default handler exits on BadWindow (a drag source or paste requestor that went away)
    X.SetErrorHandler((d: *void, e: *void) -> s32 #c_call { return 0; });
    xs.root = X.DefaultRootWindow(xs.d);
    a := *xs.a;
    for type_info(Atoms).members {
        name := ifx it_index < ATOMS_NAMED then it.name else ATOM_NAMES[it_index - ATOMS_NAMED];
        (cast(*Atom) a)[it_index] = X.InternAtom(xs.d, temp_c_string(name), 0);
    }

    s.scale = read_scale();
    xs.px_w, xs.px_h = xx (width * s.scale), xx (height * s.scale);
    r := xs.normal;
    placed := false;
    if r.width > 0 && r.height > 0 {
        root: Window;
        rx, ry: s32;
        rw, rh, border, depth: u32;
        X.GetGeometry(xs.d, xs.root, *root, *rx, *ry, *rw, *rh, *border, *depth);
        // Only where the top edge is on the screen (a monitor may be gone since).
        placed = r.x + r.width > 40 && r.x < cast(s32) rw - 40 && r.y >= 0 && r.y < cast(s32) rh - 40;
        if placed xs.px_w, xs.px_h = r.width, r.height;
    }
    attrs := XSetWindowAttributes.{bit_gravity = 1 /*NorthWest*/, event_mask = EVENT_MASK};
    // depth and visual from the root (the default 24-bit TrueColor); background None: no flicker on resize
    xs.win = X.CreateWindow(xs.d, xs.root, ifx placed then r.x else 0, ifx placed then r.y else 0, xx xs.px_w, xx xs.px_h, 0, 0, 1 /*InputOutput*/, null,
        0x1 /*CWBackPixmap*/ | 0x10 /*CWBitGravity*/ | 0x800 /*CWEventMask*/, *attrs);
    if !xs.win return false;
    X.SelectInput(xs.d, xs.root, PropertyChangeMask); // RESOURCE_MANAGER (Xft.dpi) changes

    X.StoreName(xs.d, xs.win, temp_c_string(title));
    X.ChangeProperty(xs.d, xs.win, a._NET_WM_NAME, a.UTF8_STRING, 8, 0, title.data, xx title.count);
    pid: s64 = getpid(); // format-32 property items are C longs
    X.ChangeProperty(xs.d, xs.win, a._NET_WM_PID, XA_CARDINAL, 32, 0, xx *pid, 1);
    class := XClassHint.{temp_c_string("fastcord"), temp_c_string("fastcord")};
    X.SetClassHint(xs.d, xs.win, *class);
    X.SetWMProtocols(xs.d, xs.win, *a.WM_DELETE_WINDOW, 1);
    set_min_size(placed);
    if r.maximized {
        // Set before mapping, the window manager maps it maximized (EWMH).
        st := Atom.[xs.a._NET_WM_STATE_MAXIMIZED_VERT, xs.a._NET_WM_STATE_MAXIMIZED_HORZ];
        X.ChangeProperty(xs.d, xs.win, a._NET_WM_STATE, XA_ATOM, 32, 0, xx st.data, 2);
    }
    dnd_version: s64 = 5;
    X.ChangeProperty(xs.d, xs.win, a.XdndAware, XA_ATOM, 32, 0, xx *dnd_version, 1);

    // input method: XMODIFIERS (@im=ibus, fcitx), else Xlib's own compose (dead keys). The IM draws its own
    // preedit and candidate windows.
    for string.["", "@im=none"] {
        X.SetLocaleModifiers(it.data);
        xs.im = X.OpenIM(xs.d, null, null, null);
        if xs.im xs.ic = X.CreateIC(xs.im, "inputStyle", XIMPreeditNothing | XIMStatusNothing, "clientWindow", xs.win, "focusWindow", xs.win, null);
        if xs.ic break;
        if xs.im X.CloseIM(xs.im);
        xs.im = null;
    }
    // key repeat without the fake KeyRelease between repeats
    supported: s32;
    X.kbSetDetectableAutoRepeat(xs.d, 1, *supported);
    X.MapWindow(xs.d, xs.win);
    X.Flush(xs.d);
    update_size();

    if bus_start() bus_post(.{tray = true});
    // the second connection reads the clipboard from any thread without touching the UI thread's events
    xs.clip_d = X.OpenDisplay(null);
    if xs.clip_d {
        xs.clip_win = X.CreateSimpleWindow(xs.clip_d, X.DefaultRootWindow(xs.clip_d), 0, 0, 1, 1, 0, 0, 0);
        X.SelectInput(xs.clip_d, xs.clip_win, PropertyChangeMask);
    }
    // themed cursors by CSS name (optional)
    xs.xcursor = dlopen("libXcursor.so.1", RTLD_NOW);
    if xs.xcursor && !load_syms(xs.xcursor, *XC, "Xcursor") xs.xcursor = null;
    return true;
}

os_shutdown :: () {
    if wl.on {
        wl_shutdown();
        close(xs.wake_fd);
        xs.wake_fd = -1;
        return;
    }
    if xs.ic X.DestroyIC(xs.ic);
    if xs.im X.CloseIM(xs.im);
    if xs.win X.DestroyWindow(xs.d, xs.win);
    X.CloseDisplay(xs.d);
    {
        locks.guard(*xs.read_lock);
        if xs.clip_d X.CloseDisplay(xs.clip_d);
        xs.clip_d = null;
    }
    if xs.wake_fd >= 0 close(xs.wake_fd);
    xs.d, xs.win, xs.im, xs.ic, xs.wake_fd = null, 0, null, null, -1;
}

os_wake :: () {
    one: u64 = 1;
    write(xs.wake_fd, *one, 8);
}

os_frame_wait :: () { if wl.on wl_frame_wait(); }

os_window_visible :: () -> bool { return ifx wl.on then !wl.hidden else xs.mapped && !xs.obscured; }

// Pumps X events until there is something to do: events, a requested frame (EGL's swap waits for vsync,
// so no sleep here), a wake from another thread, or the timeout.
os_wait :: (timeout: float64) {
    if wl.on { wl_wait(timeout); return; }
    start := time_now();
    // The caret, for the input method's candidate window (ibus and fcitx read the spot even with
    // XIMPreeditNothing, which keeps preedit drawing theirs).
    if xs.ic && s.ime_rect != xs.ime_spot {
        xs.ime_spot = s.ime_rect;
        p := XPoint.{xx (s.ime_rect.x * s.scale), xx ((s.ime_rect.y + s.ime_rect.w) * s.scale)};
        list := X.VaCreateNestedList(0, "spotLocation", *p, null);
        if list {
            X.SetICValues(xs.ic, "preeditAttributes", list, null);
            X.Free(list);
        }
    }
    while true {
        n: u64;
        read(xs.wake_fd, *n, 8);
        pump();
        if s.quit || atomic_load(*s.frame_requested) || pending_count() > 0 return;
        ms: s32 = -1;
        if timeout >= 0 {
            remaining := timeout - (time_now() - start);
            if remaining <= 0 return;
            ms = cast(s32) (remaining * 1000 + 0.999);
        }
        fds := pollfd.[.{fd = X.ConnectionNumber(xs.d), events = POLLIN}, .{fd = xs.wake_fd, events = POLLIN}];
        poll(fds.data, 2, ms);
    }
}

os_clipboard_get :: (allocator: Allocator) -> string {
    if wl.on return wl_clipboard_get(allocator);
    locks.guard(*xs.read_lock);
    if !xs.clip_d return "";
    if X.GetSelectionOwner(xs.clip_d, xs.a.CLIPBOARD) == xs.win {
        locks.guard(*xs.own_lock);
        return copy_string(xs.own_text,, allocator);
    }
    for Atom.[xs.a.UTF8_STRING, xs.a.text_plain, xs.a.TEXT, XA_STRING] {
        b, ok, type := read_selection(it, allocator);
        if ok && (type == xs.a.UTF8_STRING || type == xs.a.text_plain) return string.{b.count, b.data};
        if ok && type == XA_STRING {
            // X11 STRING is Latin-1, not UTF-8 (TEXT can negotiate either).
            text := string.{0, NewArray(b.count * 2, u8,, allocator).data};
            for b {
                ch := string.{0, text.data + text.count};
                character_utf32_to_utf8(it, *ch);
                text.count += ch.count;
            }
            array_free(b);
            return text;
        }
        array_free(b);
    }
    return "";
}

// A PNG (the app re-encodes other formats): we own CLIPBOARD and serve it as image/png. No INCR, so an
// image over the server's request size (usually 16 MiB with BIG-REQUESTS) doesn't reach the other program.
os_clipboard_set_image :: (png: []u8) {
    if wl.on { wl_clipboard_set("", png); return; }
    {
        locks.guard(*xs.own_lock);
        own_reset();
        xs.own_png = array_copy(png);
    }
    X.SetSelectionOwner(xs.d, xs.a.CLIPBOARD, xs.win, 0 /*CurrentTime*/);
    X.Flush(xs.d);
}

// We own CLIPBOARD and answer SelectionRequest from the event pump.
os_clipboard_set :: (str: string) {
    if wl.on { wl_clipboard_set(str, .[]); return; }
    {
        locks.guard(*xs.own_lock);
        own_reset();
        xs.own_text = copy_string(str);
    }
    X.SetSelectionOwner(xs.d, xs.a.CLIPBOARD, xs.win, 0 /*CurrentTime*/);
    X.Flush(xs.d);
}

// Asks the owner for its TARGETS: one round trip, made on paste.
os_clipboard_kind :: () -> Clipboard_Kind {
    if wl.on return wl_clipboard_kind();
    locks.guard(*xs.read_lock);
    if !xs.clip_d return .None;
    owner := X.GetSelectionOwner(xs.clip_d, xs.a.CLIPBOARD);
    if owner == xs.win {
        locks.guard(*xs.own_lock);
        return ifx xs.own_png then .Image else .Text;
    }
    if !owner return .None;
    b, ok := read_selection(xs.a.TARGETS, temp);
    if !ok return .None;
    targets := []Atom.{b.count / 8, cast(*Atom) b.data};
    // a link copied in a browser can be a uri-list too: only file URLs count
    if (array_find(targets, xs.a.uri_list) || array_find(targets, xs.a.gnome_files)) && read_files(temp).count return .Files;
    if array_find(targets, xs.a.png) return .Image;
    if array_find(targets, xs.a.UTF8_STRING) || array_find(targets, xs.a.text_plain) || array_find(targets, xs.a.TEXT) || array_find(targets, XA_STRING) return .Text;
    return .None;
}

// image/png, which GTK, Qt and browsers all offer for a copied bitmap.
os_clipboard_image :: (allocator: Allocator) -> []u8, bool {
    if wl.on { b, ok := wl_clipboard_image(allocator); return b, ok; }
    locks.guard(*xs.read_lock);
    if !foreign_owner() {
        locks.guard(*xs.own_lock);
        return array_copy(xs.own_png,, allocator), xs.own_png.count > 0;
    }
    b, ok := read_selection(xs.a.png, allocator);
    if ok && b.count return b, true;
    array_free(b);
    return .[], false;
}

os_clipboard_files :: (allocator: Allocator) -> []string {
    if wl.on return wl_clipboard_files(allocator);
    locks.guard(*xs.read_lock);
    if !foreign_owner() return .[];
    return read_files(allocator);
}

os_apply_cursor :: () {
    if wl.on { wl_apply_cursor(); return; }
    c := *xs.cursors[s.cursor];
    if !c.* c.* = make_cursor(s.cursor);
    X.DefineCursor(xs.d, xs.win, c.*);
    X.Flush(xs.d);
}

#scope_file

#import "Process";
#import "File";
#import "File_Utilities";
#import "System";
#import "Thread";
#import "POSIX"; // dlopen (libdl in glibc 2.17, which the link adds), poll, eventfd

libc :: #system_library "libc";
setlocale :: (category: s32, locale: *u8) -> *u8 #foreign libc;
LC_CTYPE :: 0;

// ---- Xlib (x86_64 LP64: long and XID are 8 bytes, int 4)

Window :: u64;
Atom :: u64;

// Every field is looked up as prefix + its name.
Xlib :: struct {
    InitThreads: () -> s32 #c_call;
    SupportsLocale: () -> s32 #c_call;
    SetLocaleModifiers: (mods: *u8) -> *u8 #c_call;
    OpenDisplay: (name: *u8) -> *void #c_call;
    CloseDisplay: (d: *void) -> s32 #c_call;
    SetErrorHandler: (handler: (d: *void, e: *void) -> s32 #c_call) -> *void #c_call;
    DefaultRootWindow: (d: *void) -> Window #c_call;
    ConnectionNumber: (d: *void) -> s32 #c_call;
    InternAtom: (d: *void, name: *u8, only_if_exists: s32) -> Atom #c_call;
    CreateWindow: (d: *void, parent: Window, x: s32, y: s32, w: u32, h: u32, border: u32, depth: s32, class: u32, visual: *void, mask: u64, attrs: *XSetWindowAttributes) -> Window #c_call;
    CreateSimpleWindow: (d: *void, parent: Window, x: s32, y: s32, w: u32, h: u32, border: u32, border_pixel: u64, background: u64) -> Window #c_call;
    DestroyWindow: (d: *void, w: Window) -> s32 #c_call;
    MapWindow: (d: *void, w: Window) -> s32 #c_call;
    SelectInput: (d: *void, w: Window, mask: s64) -> s32 #c_call;
    StoreName: (d: *void, w: Window, name: *u8) -> s32 #c_call;
    SetClassHint: (d: *void, w: Window, hint: *XClassHint) -> s32 #c_call;
    SetWMProtocols: (d: *void, w: Window, protocols: *Atom, count: s32) -> s32 #c_call;
    SetWMNormalHints: (d: *void, w: Window, hints: *XSizeHints) #c_call;
    ChangeProperty: (d: *void, w: Window, prop: Atom, type: Atom, format: s32, mode: s32, data: *u8, n: s32) -> s32 #c_call;
    GetWindowProperty: (d: *void, w: Window, prop: Atom, offset: s64, length: s64, delete: s32, req_type: Atom,
        type: *Atom, format: *s32, n: *u64, bytes_after: *u64, data: **u8) -> s32 #c_call;
    Free: (p: *void) -> s32 #c_call;
    Flush: (d: *void) -> s32 #c_call;
    Pending: (d: *void) -> s32 #c_call;
    NextEvent: (d: *void, ev: *XEvent) -> s32 #c_call;
    CheckTypedWindowEvent: (d: *void, w: Window, type: s32, ev: *XEvent) -> s32 #c_call;
    SendEvent: (d: *void, w: Window, propagate: s32, mask: s64, ev: *XEvent) -> s32 #c_call;
    FilterEvent: (ev: *XEvent, w: Window) -> s32 #c_call;
    GetGeometry: (d: *void, w: Window, root: *Window, x: *s32, y: *s32, width: *u32, height: *u32, border: *u32, depth: *u32) -> s32 #c_call;
    TranslateCoordinates: (d: *void, src: Window, dst: Window, x: s32, y: s32, dx: *s32, dy: *s32, child: *Window) -> s32 #c_call;
    kbLookupKeySym: (d: *void, code: u8, state: u32, consumed: *u32, sym: *u64) -> s32 #c_call;
    RefreshKeyboardMapping: (ev: *XEvent) -> s32 #c_call;
    kbSetDetectableAutoRepeat: (d: *void, detectable: s32, supported: *s32) -> s32 #c_call;
    OpenIM: (d: *void, db: *void, res_name: *u8, res_class: *u8) -> *void #c_call;
    CloseIM: (im: *void) -> s32 #c_call;
    // variadic in C: name/value pairs ending in null (integer arguments pass the same way)
    CreateIC: (im: *void, n1: *u8, v1: s64, n2: *u8, v2: Window, n3: *u8, v3: Window, end: *void) -> *void #c_call;
    SetICValues: (ic: *void, n1: *u8, v1: *void, end: *void) -> *u8 #c_call;
    VaCreateNestedList: (unused: s32, n1: *u8, v1: *XPoint, end: *void) -> *void #c_call;
    DestroyIC: (ic: *void) #c_call;
    SetICFocus: (ic: *void) #c_call;
    UnsetICFocus: (ic: *void) #c_call;
    utf8LookupString: (ic: *void, ev: *XKeyEvent, buf: *u8, size: s32, sym: *u64, status: *s32) -> s32 #c_call;
    ConvertSelection: (d: *void, selection: Atom, target: Atom, prop: Atom, requestor: Window, time: u64) -> s32 #c_call;
    SetSelectionOwner: (d: *void, selection: Atom, owner: Window, time: u64) -> s32 #c_call;
    GetSelectionOwner: (d: *void, selection: Atom) -> Window #c_call;
    CreateFontCursor: (d: *void, shape: u32) -> u64 #c_call;
    CreateBitmapFromData: (d: *void, w: Window, data: *u8, width: u32, height: u32) -> u64 #c_call;
    CreatePixmapCursor: (d: *void, src: u64, mask: u64, fg: *XColor, bg: *XColor, x: u32, y: u32) -> u64 #c_call;
    FreePixmap: (d: *void, p: u64) -> s32 #c_call;
    DefineCursor: (d: *void, w: Window, c: u64) -> s32 #c_call;
    WithdrawWindow: (d: *void, w: Window, screen: s32) -> s32 #c_call;
    DefaultScreen: (d: *void) -> s32 #c_call;
    QueryExtension: (d: *void, name: *u8, opcode: *s32, event: *s32, error: *s32) -> s32 #c_call;
    GetEventData: (d: *void, cookie: *XGenericEventCookie) -> s32 #c_call;
    FreeEventData: (d: *void, cookie: *XGenericEventCookie) #c_call;
    kbKeycodeToKeysym: (d: *void, keycode: u8, group: s32, level: s32) -> u64 #c_call;
}
X: Xlib;

Xcursor :: struct {
    LibraryLoadCursor: (d: *void, name: *u8) -> u64 #c_call;
}
XC: Xcursor;

#scope_module

load_syms :: (lib: *void, table: *$T, prefix: string) -> bool {
    for type_info(T).members {
        p := dlsym(lib, temp_c_string(join(prefix, it.name,, temp)));
        if !p return false;
        (cast(**void) (cast(*u8) table + it.offset_in_bytes)).* = p;
    }
    return true;
}

#scope_file

XSetWindowAttributes :: struct {
    background_pixmap, background_pixel, border_pixmap, border_pixel: u64;
    bit_gravity, win_gravity, backing_store: s32;
    backing_planes, backing_pixel: u64;
    save_under: s32;
    event_mask, do_not_propagate_mask: s64;
    override_redirect: s32;
    colormap, cursor: u64;
}
#assert size_of(XSetWindowAttributes) == 112;

XSizeHints :: struct {
    flags: s64;
    x, y, width, height, min_width, min_height, max_width, max_height, width_inc, height_inc: s32;
    min_aspect_x, min_aspect_y, max_aspect_x, max_aspect_y: s32;
    base_width, base_height, win_gravity: s32;
}
#assert size_of(XSizeHints) == 80;

XClassHint :: struct { res_name, res_class: *u8; }
XPoint :: struct { x, y: s16; }
XColor :: struct { pixel: u64; red, green, blue: u16; flags, pad: u8; }

// The event structs' shared head: type, serial, send_event, display, then the window at 32.
XKeyEvent :: struct {
    type: s32; serial: u64; send_event: s32; display: *void;
    window, root, subwindow: Window;
    time: u64;
    x, y, x_root, y_root: s32;
    state, keycode: u32;
    same_screen: s32;
}
#assert size_of(XKeyEvent) == 96;
XButtonEvent :: struct {
    type: s32; serial: u64; send_event: s32; display: *void;
    window, root, subwindow: Window;
    time: u64;
    x, y, x_root, y_root: s32;
    state, button: u32;
    same_screen: s32;
}
XMotionEvent :: struct {
    type: s32; serial: u64; send_event: s32; display: *void;
    window, root, subwindow: Window;
    time: u64;
    x, y, x_root, y_root: s32;
    state: u32;
    is_hint: u8;
    same_screen: s32;
}
XCrossingEvent :: struct {
    type: s32; serial: u64; send_event: s32; display: *void;
    window, root, subwindow: Window;
    time: u64;
    x, y, x_root, y_root: s32;
    mode, detail, same_screen, focus: s32;
    state: u32;
}
#assert size_of(XCrossingEvent) == 104;
XFocusChangeEvent :: struct {
    type: s32; serial: u64; send_event: s32; display: *void;
    window: Window;
    mode, detail: s32;
}
XConfigureEvent :: struct {
    type: s32; serial: u64; send_event: s32; display: *void;
    event, window: Window;
    x, y, width, height, border_width: s32;
    above: Window;
    override_redirect: s32;
}
#assert size_of(XConfigureEvent) == 88;
XPropertyEvent :: struct {
    type: s32; serial: u64; send_event: s32; display: *void;
    window: Window;
    atom: Atom;
    time: u64;
    state: s32;
}
XSelectionClearEvent :: struct {
    type: s32; serial: u64; send_event: s32; display: *void;
    window: Window;
    selection: Atom;
    time: u64;
}
XSelectionRequestEvent :: struct {
    type: s32; serial: u64; send_event: s32; display: *void;
    owner, requestor: Window;
    selection, target, property: Atom;
    time: u64;
}
#assert size_of(XSelectionRequestEvent) == 80;
XSelectionEvent :: struct {
    type: s32; serial: u64; send_event: s32; display: *void;
    requestor: Window;
    selection, target, property: Atom;
    time: u64;
}
#assert size_of(XSelectionEvent) == 72;
XClientMessageEvent :: struct {
    type: s32; serial: u64; send_event: s32; display: *void;
    window: Window;
    message_type: Atom;
    format: s32;
    l: [5]s64; // the data union, read as format 32
}
#assert size_of(XClientMessageEvent) == 96;

XVisibilityEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *void;
    window: Window;
    state: s32;
}

XEvent :: union {
    type: s32;
    xkey: XKeyEvent;
    xbutton: XButtonEvent;
    xmotion: XMotionEvent;
    xcrossing: XCrossingEvent;
    xfocus: XFocusChangeEvent;
    xconfigure: XConfigureEvent;
    xproperty: XPropertyEvent;
    xselectionclear: XSelectionClearEvent;
    xselectionrequest: XSelectionRequestEvent;
    xselection: XSelectionEvent;
    xclient: XClientMessageEvent;
    xvisibility: XVisibilityEvent;
    pad: [24]s64;
}
#assert size_of(XEvent) == 192;

KeyPress :: 2;
KeyRelease :: 3;
ButtonPress :: 4;
ButtonRelease :: 5;
MotionNotify :: 6;
LeaveNotify :: 8;
FocusIn :: 9;
FocusOut :: 10;
Expose :: 12;
VisibilityNotify :: 15;
UnmapNotify :: 18;
MapNotify :: 19;
ConfigureNotify :: 22;
PropertyNotify :: 28;
SelectionClear :: 29;
SelectionRequest :: 30;
SelectionNotify :: 31;
ClientMessage :: 33;
SubstructureNotifyMask :: 1 << 19;
SubstructureRedirectMask :: 1 << 20;
MappingNotify :: 34;

PropertyChangeMask :: 0x400000;
EVENT_MASK :: 0x1 /*KeyPress*/ | 0x2 /*KeyRelease*/ | 0x4 /*ButtonPress*/ | 0x8 /*ButtonRelease*/ | 0x20 /*LeaveWindow*/ |
    0x40 /*PointerMotion*/ | 0x8000 /*Exposure*/ | 0x10000 /*VisibilityChange*/ | 0x20000 /*StructureNotify*/ | 0x200000 /*FocusChange*/;
XIMPreeditNothing :: 0x8;
XIMStatusNothing :: 0x400;
NotifyGrab :: 1;
NotifyUngrab :: 2;

XA_ATOM :: 4;
XA_CARDINAL :: 6;
XA_RESOURCE_MANAGER :: 23;
XA_STRING :: 31;

// Interned in os_init in field order; the last ATOM_NAMES.count fields take their names from ATOM_NAMES.
Atoms :: struct {
    WM_PROTOCOLS, WM_DELETE_WINDOW, _NET_WM_NAME, _NET_WM_PID, UTF8_STRING, TEXT, CLIPBOARD, TARGETS, INCR,
    XdndAware, XdndEnter, XdndPosition, XdndStatus, XdndLeave, XdndDrop, XdndFinished, XdndSelection,
    XdndTypeList, XdndActionCopy, FC_SELECTION, _NET_WM_STATE, _NET_WM_STATE_MAXIMIZED_VERT,
    _NET_WM_STATE_MAXIMIZED_HORZ, _NET_WM_STATE_FULLSCREEN, _NET_ACTIVE_WINDOW: Atom;
    text_plain, uri_list, gnome_files, png: Atom;
}
ATOM_NAMES :: string.["text/plain;charset=utf-8", "text/uri-list", "x-special/gnome-copied-files", "image/png"];
ATOMS_NAMED :: #run type_info(Atoms).members.count - ATOM_NAMES.count;

Prefs :: struct {
    known: bool;
    dark: bool;
    a11y: System_A11y;
}

#scope_module

xs: struct {
    lib, xcursor: *void;
    d: *void;      // the UI thread's connection
    root, win: Window;
    im, ic: *void;
    a: Atoms;
    wake_fd: s32 = -1;
    px_w, px_h: s32;
    normal: Window_Placement; // the client area when neither maximized nor full screen (root pixels)
    fullscreen: bool; // set_fullscreen's
    ime_spot: Vector4; // the ime_rect last sent to the input method
    focused: bool;
    mapped, obscured: bool; // MapNotify / UnmapNotify, VisibilityNotify: window_visible
    keys_down: [256]bool; // by keycode: repeats
    cursors: [#run enum_highest_value(Cursor) + 1]u64;
    last_click_time: float64;
    last_click_pos: Vector2;
    last_click_btn: Mouse_Button;
    click_count: int;

    dnd_source: Window;
    dnd_version: s64;
    dnd_files: bool;   // the drag offers text/uri-list
    dnd_entered: bool; // Drag_Enter was pushed

    read_lock: locks.Mutex; // the clipboard reading connection
    clip_d: *void;
    clip_win: Window;
    own_lock: locks.Mutex;
    own_text: string;       // what we serve while we own CLIPBOARD
    own_png: []u8;          // or this image (heap)

    prefs_lock: locks.Mutex;
    prefs: Prefs;
    prefs_thread: Thread;
};

#scope_file

in_path :: (name: string) -> bool {
    p := getenv("PATH");
    if !p return false;
    for split(to_string(p), ":",, temp) if it && access(temp_c_string(tprint("%/%", it, name)), X_OK) == 0 return true;
    return false;
}

// Runs a program without waiting for it: sh puts it in the background and exits at once, so it neither
// blocks the caller nor stays a zombie.
spawn_detached :: (args: ..string) {
    a: [..]string;
    a.allocator = temp;
    array_add(*a, "sh", "-c", "\"$@\" >/dev/null 2>&1 &", "sh");
    array_add(*a, ..args);
    run_command(..a,, temp);
}

// One gsettings line per key (empty when the key or gsettings is missing).
PREFS_SCRIPT :: #string END
for k in "org.gnome.desktop.interface color-scheme" "org.gnome.desktop.interface gtk-theme" "org.gnome.desktop.interface enable-animations" "org.gnome.desktop.a11y.interface high-contrast"; do gsettings get $k 2>/dev/null || echo; done
END

prefs_proc :: (t: *Thread) -> s64 {
    while true {
        _, out := run_command("sh", "-c", PREFS_SCRIPT, capture_and_return_output = true,, temp);
        l := split(out, "\n",, temp);
        p: Prefs;
        if l.count >= 4 && (l[0] || l[1]) {
            p.known = true;
            p.dark = contains(l[0], "prefer-dark") || (!contains(l[0], "prefer-light") && contains(to_lower_copy(l[1],, temp), "dark"));
            p.a11y.reduce_motion = trim(l[2]) == "false";
            p.a11y.contrast_more = trim(l[3]) == "true";
        }
        {
            locks.guard(*xs.prefs_lock);
            xs.prefs = p;
        }
        reset_temporary_storage();
        sleep_milliseconds(2000);
    }
    return 0;
}

// Xft.dpi from the root's RESOURCE_MANAGER (what GNOME, KDE and xrdb set) / 96.
read_scale :: () -> float32 {
    b: [..]u8;
    b.allocator = temp;
    get_property(xs.d, xs.root, XA_RESOURCE_MANAGER, *b);
    text := string.{b.count, b.data};
    i := find_index_from_left(text, "Xft.dpi:");
    if i < 0 return 1;
    advance(*text, i + 8);
    end := find_index_from_left(text, #char "\n");
    if end >= 0 text.count = end;
    dpi, ok := string_to_float(trim(text, " \t\r"));
    return ifx ok && dpi >= 48 then dpi / 96 else 1;
}

update_size :: () { s.size = .{xs.px_w / s.scale, xs.px_h / s.scale}; }

set_min_size :: (placed := false) {
    h := XSizeHints.{flags = 1 << 4 /*PMinSize*/, min_width = xx (MIN_WINDOW_W * s.scale), min_height = xx (MIN_WINDOW_H * s.scale)};
    // USPosition, USSize and StaticGravity: the saved spot is the client area's, as window_placement reads it.
    if placed h.flags |= 1 | 2 | (1 << 9);
    h.win_gravity = 10;
    X.SetWMNormalHints(xs.d, xs.win, *h);
}

// Appends a window property's bytes to out (format-32 items are C longs). type is None when it is missing.
get_property :: (d: *void, win: Window, prop: Atom, out: *[..]u8, delete := false) -> type: Atom, count: int {
    type: Atom;
    format: s32;
    n, after: u64;
    p: *u8;
    if X.GetWindowProperty(d, win, prop, 0, 0x7fff_ffff, xx delete, 0 /*AnyPropertyType*/, *type, *format, *n, *after, *p) != 0 return 0, 0;
    if !p return type, 0;
    defer X.Free(p);
    bytes := cast(int) n * (ifx format == 32 then 8 else format / 8);
    old := out.count;
    array_resize(out, old + bytes, false);
    memcpy(out.data + old, p, bytes);
    return type, bytes;
}

pump :: () {
    ev: XEvent;
    while X.Pending(xs.d) > 0 {
        X.NextEvent(xs.d, *ev);
        if X.FilterEvent(*ev, 0) continue; // the input method's (dead keys, IME composition)
        handle(*ev);
    }
}

handle :: (ev: *XEvent) {
    now := time_now();
    if ev.type == {
        case KeyPress;
            key_press(*ev.xkey);
        case KeyRelease;
            k := *ev.xkey;
            if k.keycode < 256 xs.keys_down[k.keycode] = false;
            if k.keycode push_event(.{kind = .Key_Up, key = map_key(k), mods = mods_of(k.state), time = now});
        case ButtonPress; #through;
        case ButtonRelease;
            mouse_button(*ev.xbutton, ev.type == ButtonPress);
        case MotionNotify;
            m := *ev.xmotion;
            push_event(.{kind = .Mouse_Move, pos = point(m.x, m.y), mods = mods_of(m.state), time = now});
        case LeaveNotify;
            c := *ev.xcrossing;
            // not while a button is held: the implicit grab keeps the drag ours
            if c.mode != NotifyGrab && !(c.state & 0x1f00) push_event(.{kind = .Mouse_Leave, time = now});
        case FocusIn; #through;
        case FocusOut;
            // keyboard grabs (window menu, Alt+Tab, dragging the window) are not focus changes
            if ev.xfocus.mode == NotifyGrab || ev.xfocus.mode == NotifyUngrab return;
            in := ev.type == FocusIn;
            if in == xs.focused return;
            xs.focused = in;
            if xs.ic { if in X.SetICFocus(xs.ic); else X.UnsetICFocus(xs.ic); }
            if !in memset(xs.keys_down.data, 0, xs.keys_down.count);
            push_event(.{kind = ifx in then .Focus_Gained else .Focus_Lost, time = now});
        case ConfigureNotify;
            c := *ev.xconfigure;
            if c.width == xs.px_w && c.height == xs.px_h return;
            xs.px_w, xs.px_h = c.width, c.height;
            update_size();
            push_event(.{kind = .Resize, pos = s.size, time = now});
        case UnmapNotify;
            xs.mapped = false;
        case VisibilityNotify;
            VisibilityFullyObscured :: 2;
            xs.obscured = ev.xvisibility.state == VisibilityFullyObscured;
            atomic_store(*s.frame_requested, true);
        case MapNotify;
            xs.mapped = true;
            atomic_store(*s.frame_requested, true); // redraw
        case Expose;
            atomic_store(*s.frame_requested, true);
        case PropertyNotify;
            p := *ev.xproperty;
            if p.window != xs.root || p.atom != XA_RESOURCE_MANAGER return;
            scale := read_scale();
            if scale == s.scale return;
            s.scale = scale;
            set_min_size();
            update_size();
            push_event(.{kind = .Resize, pos = s.size, time = now});
        case MappingNotify;
            X.RefreshKeyboardMapping(ev); // the keyboard layout changed
        case ClientMessage;
            client_message(*ev.xclient);
        case SelectionRequest;
            answer_selection(*ev.xselectionrequest);
        case SelectionClear;
            if ev.xselectionclear.selection != xs.a.CLIPBOARD return;
            locks.guard(*xs.own_lock);
            own_reset();
        case SelectionNotify;
            dnd_data(*ev.xselection);
    }
}

point :: (x: s32, y: s32) -> Vector2 { return .{x / s.scale, y / s.scale}; }

mods_of :: (state: u32) -> Mod {
    m: Mod;
    if state & 0x1 m |= .Shift;
    if state & 0x4 m |= .Ctrl;
    if state & 0x8 m |= .Alt;  // Mod1
    if state & 0x40 m |= .Cmd; // Mod4: Super
    return m;
}

key_press :: (k: *XKeyEvent) {
    now := time_now();
    mods := mods_of(k.state);
    // keycode 0: text the input method committed
    if k.keycode {
        repeat := k.keycode < 256 && xs.keys_down[k.keycode];
        if k.keycode < 256 xs.keys_down[k.keycode] = true;
        push_event(.{kind = .Key_Down, key = map_key(k), mods = mods, is_repeat = repeat, time = now});
    }
    if !xs.ic return;
    buf: [256]u8;
    text := string.{0, buf.data};
    sym: u64;
    status: s32;
    text.count = X.utf8LookupString(xs.ic, k, buf.data, buf.count, *sym, *status);
    if status == -1 /*XBufferOverflow*/ {
        text = talloc_string(text.count);
        text.count = X.utf8LookupString(xs.ic, k, text.data, xx text.count, *sym, *status);
    }
    if (status != 2 /*XLookupChars*/ && status != 4 /*XLookupBoth*/) || text.count <= 0 return;
    if text.count == 1 && (text[0] < 0x20 || text[0] == 0x7f) return;
    if mods & (.Ctrl | .Alt | .Cmd) return; // shortcuts are Key_Down only (AltGr is Mod5 and types text)
    push_event(.{kind = .Text, text = text, time = now});
}

// Logical keys in the active XKB group; Shift/Caps affect modifiers/text, not shortcut identity.
map_key :: (k: *XKeyEvent) -> Key {
    sym: u64;
    consumed: u32;
    if !X.kbLookupKeySym(k.display, cast(u8) k.keycode, k.state & ~cast(u32) 3 /*Shift|Lock*/, *consumed, *sym) return .None;
    if sym >= 0xff95 && sym <= 0xff9f && (k.state & 0x10) return .None; // keypad with NumLock (Mod2) types digits
    return map_keysym(sym);
}

#scope_module

// The layout's unshifted keysym of the first group (Latin on most multi-layout setups), else the key's
// position on a US keyboard (X keycodes, evdev + 8) so shortcuts work on single non-Latin layouts, as on
// Windows.
map_key_code :: (sym: u64, keycode: int, numlock: bool) -> Key {
    if sym >= 0xff95 && sym <= 0xff9f && numlock return .None; // keypad with NumLock (Mod2) types digits
    key := map_keysym(sym);
    c := keycode;
    if key != .None || c < 10 return key;
    if c <= 19 return ifx c == 19 then .N0 else cast(Key) (cast(int) Key.N1 + c - 10);
    ROWS :: string.["qwertyuiop", "asdfghjkl", "zxcvbnm"];
    for row, r: ROWS {
        first := 24 + 14 * r;
        if c >= first && c < first + row.count return cast(Key) (cast(int) Key.A + row[c - first] - #char "a");
    }
    return .None;
}

map_keysym :: (sym: u64) -> Key {
    if sym >= #char "a" && sym <= #char "z" return cast(Key) (cast(int) Key.A + cast(int) (sym - #char "a"));
    if sym >= #char "A" && sym <= #char "Z" return cast(Key) (cast(int) Key.A + cast(int) (sym - #char "A"));
    if sym >= #char "0" && sym <= #char "9" return cast(Key) (cast(int) Key.N0 + cast(int) (sym - #char "0"));
    if sym >= 0xffbe && sym <= 0xffc9 return cast(Key) (cast(int) Key.F1 + cast(int) (sym - 0xffbe));
    // keypad keys come as their NumLock-off keysyms (index 0)
    if sym == {
        case #char " "; return .Space;
        case 0xff0d; return .Enter;
        case 0xff8d; return .Keypad_Enter;
        case 0xff09; #through; case 0xfe20 /*ISO_Left_Tab*/; return .Tab;
        case 0xff08; return .Backspace;
        case 0xffff; #through; case 0xff9f; return .Delete;
        case 0xff1b; return .Escape;
        case 0xff51; #through; case 0xff96; return .Left;
        case 0xff52; #through; case 0xff97; return .Up;
        case 0xff53; #through; case 0xff98; return .Right;
        case 0xff54; #through; case 0xff99; return .Down;
        case 0xff50; #through; case 0xff95; return .Home;
        case 0xff57; #through; case 0xff9c; return .End;
        case 0xff55; #through; case 0xff9a; return .Page_Up;
        case 0xff56; #through; case 0xff9b; return .Page_Down;
        case 0xffe1; #through; case 0xffe2; return .Shift;
        case 0xffe3; #through; case 0xffe4; return .Ctrl;
        case 0xffe7; #through; case 0xffe8; #through; case 0xffe9; #through; case 0xffea; return .Alt; // Meta, Alt
        case 0xffeb; #through; case 0xffec; return .Cmd; // Super
        case 0xffe5; return .Caps_Lock;
        case #char "-"; return .Minus;
        case #char "="; return .Equals;
        case #char "["; return .Left_Bracket;
        case #char "]"; return .Right_Bracket;
        case #char "\\"; return .Backslash;
        case #char ";"; return .Semicolon;
        case #char "'"; return .Apostrophe;
        case #char ","; return .Comma;
        case #char "."; return .Period;
        case #char "/"; return .Slash;
        case #char "`"; return .Grave;
    }
    return .None;
}

// A press's click count: 2 and 3 for presses of the same button within half a second and 2pt.
count_click :: (btn: Mouse_Button, pos: Vector2, now: float64) -> int {
    d := pos - xs.last_click_pos;
    if btn == xs.last_click_btn && now - xs.last_click_time <= 0.5 && d.x * d.x + d.y * d.y < 16 xs.click_count += 1;
    else xs.click_count = 1;
    xs.last_click_time = now;
    xs.last_click_pos = pos;
    xs.last_click_btn = btn;
    return xs.click_count;
}

#scope_file

mouse_button :: (b: *XButtonEvent, down: bool) {
    pos := point(b.x, b.y);
    now := time_now();
    mods := mods_of(b.state);
    btn: Mouse_Button;
    if b.button == {
        case 1; btn = .Left;
        case 2; btn = .Middle;
        case 3; btn = .Right;
        case 8; btn = .X1;
        case 9; btn = .X2;
        case 4; #through; case 5; #through; case 6; #through; case 7;
            // wheel notches are buttons 4-7 (up, down, left, right); Chromium on X11: 53px per notch
            // (kWheelScrollAmount in ui/events/x/events_x_utils.cc)
            if !down return;
            e := Event.{kind = .Scroll, pos = pos, mods = mods, time = now};
            if b.button == {
                case 4; e.delta.y = 53;
                case 5; e.delta.y = -53;
                case 6; e.delta.x = 53;
                case 7; e.delta.x = -53;
            }
            push_event(e);
            return;
        case; return;
    }
    if down count_click(btn, pos, now);
    push_event(.{kind = ifx down then .Mouse_Down else .Mouse_Up, button = btn, pos = pos, mods = mods, click_count = xs.click_count, time = now});
}

make_cursor :: (c: Cursor) -> u64 {
    if c == .Hidden {
        zero: u8;
        black: XColor;
        pm := X.CreateBitmapFromData(xs.d, xs.win, *zero, 1, 1);
        cur := X.CreatePixmapCursor(xs.d, pm, pm, *black, *black, 0, 0);
        X.FreePixmap(xs.d, pm);
        return cur;
    }
    // the theme's CSS names, else the core cursor font (left_ptr, hand2, xterm, sb_h/v_double_arrow,
    // bottom_right/left_corner, fleur, X_cursor, crosshair)
    NAMES :: string.["default", "pointer", "text", "ew-resize", "ns-resize", "nwse-resize", "nesw-resize", "move", "not-allowed", "crosshair"];
    SHAPES :: u32.[68, 60, 152, 108, 116, 14, 12, 52, 0, 34];
    if xs.xcursor {
        cur := XC.LibraryLoadCursor(xs.d, temp_c_string(NAMES[c]));
        if cur return cur;
    }
    return X.CreateFontCursor(xs.d, SHAPES[c]);
}

// ---- Clipboard

own_reset :: () { // own_lock held
    free(xs.own_text.data);
    array_free(xs.own_png);
    xs.own_text, xs.own_png = "", .[];
}

answer_selection :: (r: *XSelectionRequestEvent) {
    a := *xs.a;
    reply: XEvent;
    reply.xselection = .{type = SelectionNotify, requestor = r.requestor, selection = r.selection, target = r.target, time = r.time};
    prop := ifx r.property then r.property else r.target; // obsolete clients pass None
    if r.selection == a.CLIPBOARD {
        locks.guard(*xs.own_lock);
        if r.target == a.TARGETS {
            text := Atom.[a.TARGETS, a.UTF8_STRING, a.text_plain, a.TEXT];
            png := Atom.[a.TARGETS, a.png];
            targets := ifx xs.own_png then array_view(png, 0) else array_view(text, 0);
            X.ChangeProperty(xs.d, r.requestor, prop, XA_ATOM, 32, 0, xx targets.data, xx targets.count);
            reply.xselection.property = prop;
        } else if r.target == a.png && xs.own_png {
            X.ChangeProperty(xs.d, r.requestor, prop, a.png, 8, 0, xs.own_png.data, xx xs.own_png.count);
            reply.xselection.property = prop;
        } else if (r.target == a.UTF8_STRING || r.target == a.text_plain || r.target == a.TEXT) && !xs.own_png {
            X.ChangeProperty(xs.d, r.requestor, prop, ifx r.target == a.TEXT then a.UTF8_STRING else r.target, 8, 0, xs.own_text.data, xx xs.own_text.count);
            reply.xselection.property = prop;
        }
    }
    X.SendEvent(xs.d, r.requestor, 0, 0, *reply);
    X.Flush(xs.d);
}

// read_lock held: another program owns CLIPBOARD (reading our own selection would wait on our own pump).
foreign_owner :: () -> bool {
    if !xs.clip_d return false;
    owner := X.GetSelectionOwner(xs.clip_d, xs.a.CLIPBOARD);
    return owner != 0 && owner != xs.win;
}

// read_lock held: converts CLIPBOARD to target on the reading connection and returns the bytes, INCR
// transfers (large images) included.
read_selection :: (target: Atom, allocator: Allocator) -> [..]u8, bool, Atom {
    d, win, prop := xs.clip_d, xs.clip_win, xs.a.FC_SELECTION;
    out: [..]u8;
    out.allocator = allocator;
    ev: XEvent;
    while X.CheckTypedWindowEvent(d, win, PropertyNotify, *ev) {}
    X.ConvertSelection(d, xs.a.CLIPBOARD, target, prop, win, 0);
    if !wait_event(d, win, SelectionNotify, *ev) || !ev.xselection.property return out, false, 0;
    while X.CheckTypedWindowEvent(d, win, PropertyNotify, *ev) {} // the owner's write, read below
    type := get_property(d, win, prop, *out, delete = true);
    if type != xs.a.INCR return out, type != 0, type;
    // INCR: deleting the property asked for the first chunk; each comes as a new value, an empty one ends it
    out.count = 0;
    while wait_event(d, win, PropertyNotify, *ev) {
        if ev.xproperty.atom != prop || ev.xproperty.state != 0 /*NewValue*/ continue;
        t, n := get_property(d, win, prop, *out, delete = true);
        if t && !n return out, true, t;
    }
    array_reset(*out);
    return out, false, 0;
}

// The next event of a type for win on d, waiting up to a second.
wait_event :: (d: *void, win: Window, type: s32, ev: *XEvent) -> bool {
    deadline := time_now() + 1;
    X.Flush(d);
    while !X.CheckTypedWindowEvent(d, win, type, ev) {
        left := deadline - time_now();
        if left <= 0 return false;
        fd := pollfd.{fd = X.ConnectionNumber(d), events = POLLIN};
        poll(*fd, 1, cast(s32) (left * 1000 + 1));
    }
    return true;
}

// read_lock held. text/uri-list (Dolphin, Nautilus) or GNOME's copied-files list.
read_files :: (allocator: Allocator) -> []string {
    for Atom.[xs.a.uri_list, xs.a.gnome_files] {
        b, ok := read_selection(it, temp);
        if ok return uri_paths(string.{b.count, b.data}, allocator);
    }
    return .[];
}

#scope_module

// The local paths of the file:// URIs in a uri-list (other lines are skipped).
uri_paths :: (list: string, allocator: Allocator) -> []string {
    out: [..]string;
    out.allocator = allocator;
    for split(list, "\n",, temp) {
        u := trim(it, " \t\r");
        if !begins_with(u, "file://") continue;
        advance(*u, 7);
        slash := find_index_from_left(u, #char "/"); // past a host name
        if slash < 0 continue;
        advance(*u, slash);
        path := alloc_string(u.count,, allocator);
        path.count = 0;
        i := 0;
        while i < u.count {
            c := u[i];
            hi, lo := ifx i + 2 < u.count then hex(u[i + 1]) else -1, ifx i + 2 < u.count then hex(u[i + 2]) else -1;
            if c == #char "%" && hi >= 0 && lo >= 0 {
                c = xx (hi * 16 + lo);
                i += 2;
            }
            path.data[path.count] = c;
            path.count += 1;
            i += 1;
        }
        array_add(*out, path);
    }
    return out;
}

hex :: (c: u8) -> int {
    if c >= #char "0" && c <= #char "9" return c - #char "0";
    if c >= #char "a" && c <= #char "f" return c - #char "a" + 10;
    if c >= #char "A" && c <= #char "F" return c - #char "A" + 10;
    return -1;
}

#scope_file

// ---- Drag and drop: an XDND target

client_message :: (c: *XClientMessageEvent) {
    a := *xs.a;
    t := c.message_type;
    if t == a.WM_PROTOCOLS {
        if cast(Atom) c.l[0] == a.WM_DELETE_WINDOW {
            if atomic_load(*bus.tray) && s.close_to_tray {
                X.WithdrawWindow(xs.d, xs.win, X.DefaultScreen(xs.d)); // to the tray; window_show maps it again
                X.Flush(xs.d);
                return;
            }
            s.quit = true;
            push_event(.{kind = .Quit, time = time_now()});
        }
    } else if t == a.XdndEnter {
        xs.dnd_source = xx c.l[0];
        xs.dnd_version = c.l[1] >> 24;
        xs.dnd_entered = false;
        xs.dnd_files = false;
        if c.l[1] & 1 { // more than three types: the source's XdndTypeList
            b: [..]u8;
            b.allocator = temp;
            get_property(xs.d, xs.dnd_source, a.XdndTypeList, *b);
            xs.dnd_files = array_find([]Atom.{b.count / 8, cast(*Atom) b.data}, a.uri_list);
        } else {
            for 2..4 if cast(Atom) c.l[it] == a.uri_list xs.dnd_files = true;
        }
    } else if t == a.XdndPosition {
        if xs.dnd_files && !xs.dnd_entered {
            x, y: s32;
            child: Window;
            X.TranslateCoordinates(xs.d, xs.root, xs.win, xx ((c.l[2] >> 16) & 0xffff), xx (c.l[2] & 0xffff), *x, *y, *child);
            push_event(.{kind = .Drag_Enter, pos = point(x, y), time = time_now()});
            xs.dnd_entered = true;
        }
        dnd_send(a.XdndStatus, .[xx xs.dnd_files, 0, 0, ifx xs.dnd_files then cast(s64) a.XdndActionCopy else 0]);
    } else if t == a.XdndLeave {
        dnd_end();
    } else if t == a.XdndDrop {
        if !xs.dnd_files {
            dnd_send(a.XdndFinished, .[0, 0, 0, 0]);
            dnd_end();
            return;
        }
        X.ConvertSelection(xs.d, a.XdndSelection, a.uri_list, a.FC_SELECTION, xs.win, xx ifx xs.dnd_version >= 1 then c.l[2] else 0);
        X.Flush(xs.d);
    }
}

// The dropped uri-list arrived.
dnd_data :: (e: *XSelectionEvent) {
    a := *xs.a;
    if e.selection != a.XdndSelection return;
    ok := e.property != 0;
    if ok {
        b: [..]u8;
        b.allocator = temp;
        get_property(xs.d, xs.win, a.FC_SELECTION, *b, delete = true);
        for uri_paths(string.{b.count, b.data}, temp) push_event(.{kind = .File_Drop, text = it, time = time_now()});
    }
    dnd_send(a.XdndFinished, .[xx ok, ifx ok then cast(s64) a.XdndActionCopy else 0, 0, 0]);
    dnd_end();
}

dnd_end :: () {
    if xs.dnd_entered push_event(.{kind = .Drag_Leave, time = time_now()});
    xs.dnd_entered = false;
    xs.dnd_files = false;
}

// A format-32 XDND message to the drag source: l[0] is our window, then data.
dnd_send :: (type: Atom, data: [4]s64) {
    ev: XEvent;
    ev.xclient = .{type = ClientMessage, window = xs.dnd_source, message_type = type, format = 32};
    ev.xclient.l[0] = xx xs.win;
    for data ev.xclient.l[it_index + 1] = it;
    X.SendEvent(xs.d, xs.dnd_source, 0, 0, *ev);
    X.Flush(xs.d);
}

// ---- Notifications over D-Bus (notify_show, set_badge)

Bus_Job :: struct {
    badge: bool; // a badge update (id = its text, "" = none), else a notification
    tray: bool; // the tray menu's checkmarks changed (or, the first time, register the tray)
    title, body, id: string; // heap
}

bus: struct {
    state: s32; // 0 not tried, 1 running, 2 unavailable
    conn: *void;
    lock: locks.Mutex;
    jobs: [..]Bus_Job;
    wake: s32 = -1; // eventfd: jobs waiting
    thread: Thread;
    sent: [64]struct { server_id: u32; id: string; }; // recent notifications, for ActionInvoked (ring)
    sent_next: int;
    tray: bool; // atomic: a StatusNotifierWatcher took our item, so closing hides the window
    tray_name: string;
    tray_rev: u32; // the menu's layout revision
    unread: bool; // the badge: Status NeedsAttention
};

bus_post :: (j: Bus_Job) {
    {
        locks.guard(*bus.lock);
        array_add(*bus.jobs, j);
    }
    one: u64 = 1;
    write(bus.wake, *one, 8);
}

// Loads libdbus and connects on first use (UI thread); false when there is no session bus.
bus_start :: () -> bool {
    if bus.state == 1 return true;
    if bus.state == 2 return false;
    bus.state = 2;
    lib := dlopen("libdbus-1.so.3", RTLD_NOW);
    if !lib || !load_syms(lib, *D, "dbus_") return false;
    D.threads_init_default();
    err: DBus_Error;
    D.error_init(*err);
    bus.conn = D.bus_get_private(0 /*DBUS_BUS_SESSION*/, *err);
    if !bus.conn { D.error_free(*err); return false; }
    D.connection_set_exit_on_disconnect(bus.conn, 0);
    D.bus_add_match(bus.conn, "type='signal',interface='org.freedesktop.Notifications',member='ActionInvoked'", *err);
    D.error_free(*err);
    bus.wake = eventfd(0, xx (EFD.NONBLOCK | .CLOEXEC));
    thread_init(*bus.thread, bus_proc);
    thread_start(*bus.thread);
    bus.state = 1;
    return true;
}

bus_proc :: (t: *Thread) -> s64 {
    fd: s32 = -1;
    D.connection_get_unix_fd(bus.conn, *fd);
    while true {
        fds := pollfd.[.{fd = fd, events = POLLIN}, .{fd = bus.wake, events = POLLIN}];
        poll(fds.data, 2, -1);
        n: u64;
        read(bus.wake, *n, 8);
        jobs: [..]Bus_Job;
        {
            locks.guard(*bus.lock);
            jobs, bus.jobs = bus.jobs, jobs;
        }
        for jobs {
            if it.tray tray_job();
            else if it.badge { send_badge(it.id); bus.unread = it.id != ""; tray_signal(false); }
            else send_notify(it);
            free(it.title.data); free(it.body.data); free(it.id.data);
        }
        array_free(jobs);
        if !D.connection_read_write(bus.conn, 0) return 0; // disconnected
        while true {
            m := D.connection_pop_message(bus.conn);
            if !m break;
            defer D.message_unref(m);
            if D.message_get_type(m) == 1 { tray_call(m); continue; } // a method call: the tray's
            if D.message_is_signal(m, "org.freedesktop.DBus", "NameOwnerChanged") { tray_register(); continue; } // a new watcher
            if !D.message_is_signal(m, "org.freedesktop.Notifications", "ActionInvoked") continue;
            mi: DBus_Iter;
            server_id: u32;
            if !D.message_iter_init(m, *mi) || D.message_iter_get_arg_type(*mi) != #char "u" continue;
            D.message_iter_get_basic(*mi, *server_id);
            for bus.sent if it.server_id == server_id && it.id {
                push_event(.{kind = .Notification_Click, text = it.id, time = time_now()});
                request_frame();
                break;
            }
        }
        reset_temporary_storage();
    }
    return 0;
}

// Notify(app_name s, replaces_id u, app_icon s, summary s, body s, actions as, hints a{sv}, timeout i) -> u
send_notify :: (j: Bus_Job) {
    m := D.message_new_method_call("org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify");
    if !m return;
    defer D.message_unref(m);
    it, arr: DBus_Iter;
    D.message_iter_init_append(m, *it);
    str :: (it: *DBus_Iter, v: string) { p := temp_c_string(v); D.message_iter_append_basic(it, #char "s", *p); }
    zero: u32;
    str(*it, "fastcord");
    D.message_iter_append_basic(*it, #char "u", *zero);
    str(*it, "fastcord"); // the icon the desktop entry installs
    str(*it, j.title);
    str(*it, j.body);
    D.message_iter_open_container(*it, #char "a", "s", *arr);
    str(*arr, "default"); // a click on the notification
    str(*arr, "Open");
    D.message_iter_close_container(*it, *arr);
    D.message_iter_open_container(*it, #char "a", "{sv}", *arr);
    D.message_iter_close_container(*it, *arr);
    timeout: s32 = -1;
    D.message_iter_append_basic(*it, #char "i", *timeout);
    err: DBus_Error;
    D.error_init(*err);
    reply := D.connection_send_with_reply_and_block(bus.conn, m, 5000, *err);
    D.error_free(*err);
    if !reply return;
    defer D.message_unref(reply);
    server_id: u32;
    if !D.message_iter_init(reply, *it) || D.message_iter_get_arg_type(*it) != #char "u" return;
    D.message_iter_get_basic(*it, *server_id);
    slot := *bus.sent[bus.sent_next];
    bus.sent_next = (bus.sent_next + 1) % bus.sent.count;
    free(slot.id.data);
    slot.* = .{server_id, copy_string(j.id)};
}

// Update(app_uri s, properties a{sv}) on com.canonical.Unity.LauncherEntry: count and count-visible.
send_badge :: (text: string) {
    m := D.message_new_signal("/com/creikey/fastcord", "com.canonical.Unity.LauncherEntry", "Update");
    if !m return;
    defer D.message_unref(m);
    it, arr, entry, v: DBus_Iter;
    D.message_iter_init_append(m, *it);
    uri := "application://fastcord.desktop".data;
    D.message_iter_append_basic(*it, #char "s", *uri);
    D.message_iter_open_container(*it, #char "a", "{sv}", *arr);
    count: s64 = ifx text then max(string_to_int(text), 1) else 0;
    visible: u32 = xx (text != "");
    D.message_iter_open_container(*arr, #char "e", null, *entry);
    key := "count".data;
    D.message_iter_append_basic(*entry, #char "s", *key);
    D.message_iter_open_container(*entry, #char "v", "x", *v);
    D.message_iter_append_basic(*v, #char "x", *count);
    D.message_iter_close_container(*entry, *v);
    D.message_iter_close_container(*arr, *entry);
    D.message_iter_open_container(*arr, #char "e", null, *entry);
    key = "count-visible".data;
    D.message_iter_append_basic(*entry, #char "s", *key);
    D.message_iter_open_container(*entry, #char "v", "b", *v);
    D.message_iter_append_basic(*v, #char "b", *visible);
    D.message_iter_close_container(*entry, *v);
    D.message_iter_close_container(*arr, *entry);
    D.message_iter_close_container(*it, *arr);
    D.connection_send(bus.conn, m, null);
    D.connection_flush(bus.conn);
}

DBus_Error :: struct { name, message: *u8; dummy: u32; padding: *void; } // DBusError
DBus_Iter :: struct { data: [16]u64; } // DBusMessageIter (72 bytes on 64-bit), opaque

// libdbus, loaded by load_syms (each name prefixed "dbus_").
D: struct {
    threads_init_default: () -> u32 #c_call;
    error_init: (e: *DBus_Error) #c_call;
    error_free: (e: *DBus_Error) #c_call;
    bus_get_private: (type: s32, e: *DBus_Error) -> *void #c_call;
    bus_add_match: (c: *void, rule: *u8, e: *DBus_Error) #c_call;
    connection_set_exit_on_disconnect: (c: *void, exit: u32) #c_call;
    connection_get_unix_fd: (c: *void, fd: *s32) -> u32 #c_call;
    connection_read_write: (c: *void, timeout_ms: s32) -> u32 #c_call;
    connection_pop_message: (c: *void) -> *void #c_call;
    connection_send: (c: *void, m: *void, serial: *u32) -> u32 #c_call;
    connection_send_with_reply_and_block: (c: *void, m: *void, timeout_ms: s32, e: *DBus_Error) -> *void #c_call;
    connection_flush: (c: *void) #c_call;
    message_new_method_call: (dest: *u8, path: *u8, iface: *u8, method: *u8) -> *void #c_call;
    message_new_signal: (path: *u8, iface: *u8, name: *u8) -> *void #c_call;
    message_unref: (m: *void) #c_call;
    message_is_signal: (m: *void, iface: *u8, name: *u8) -> u32 #c_call;
    message_iter_init: (m: *void, it: *DBus_Iter) -> u32 #c_call;
    message_iter_init_append: (m: *void, it: *DBus_Iter) #c_call;
    message_iter_get_arg_type: (it: *DBus_Iter) -> s32 #c_call;
    message_iter_get_basic: (it: *DBus_Iter, value: *void) #c_call;
    message_iter_append_basic: (it: *DBus_Iter, type: s32, value: *void) -> u32 #c_call;
    message_iter_open_container: (it: *DBus_Iter, type: s32, signature: *u8, sub: *DBus_Iter) -> u32 #c_call;
    message_iter_close_container: (it: *DBus_Iter, sub: *DBus_Iter) -> u32 #c_call;
    message_iter_next: (it: *DBus_Iter) -> u32 #c_call;
    message_iter_recurse: (it: *DBus_Iter, sub: *DBus_Iter) #c_call;
    message_get_type: (m: *void) -> s32 #c_call;
    message_get_path: (m: *void) -> *u8 #c_call;
    message_get_interface: (m: *void) -> *u8 #c_call;
    message_get_member: (m: *void) -> *u8 #c_call;
    message_new_method_return: (m: *void) -> *void #c_call;
    message_new_error: (m: *void, name: *u8, text: *u8) -> *void #c_call;
    bus_request_name: (c: *void, name: *u8, flags: u32, e: *DBus_Error) -> s32 #c_call;
};

// ---- Tray: a StatusNotifierItem (KDE, GNOME's AppIndicator extension, waybar...) with a com.canonical.dbusmenu
// menu like the Windows tray's: Open, Mute and Deafen checked while on, Quit. A click opens the window;
// unread mentions set Status NeedsAttention. With no StatusNotifierWatcher there is no tray and closing quits.

SNI :: "org.kde.StatusNotifierItem";
MENU :: "com.canonical.dbusmenu";
TRAY_ITEMS :: string.["Open Fastcord", "", "Mute", "Deafen", "", "Quit Fastcord"]; // ids 1..6; "" = separator

tray_job :: () {
    if !bus.tray_name {
        bus.tray_name = sprint("org.kde.StatusNotifierItem-%-1", getpid());
        err: DBus_Error;
        D.error_init(*err);
        D.bus_request_name(bus.conn, temp_c_string(bus.tray_name), 0, *err);
        D.error_free(*err);
        D.error_init(*err);
        D.bus_add_match(bus.conn, "type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.kde.StatusNotifierWatcher'", *err);
        D.error_free(*err);
        tray_register();
        return;
    }
    bus.tray_rev += 1;
    tray_signal(true);
}

tray_register :: () {
    m := D.message_new_method_call("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem");
    if !m return;
    defer D.message_unref(m);
    it: DBus_Iter;
    D.message_iter_init_append(m, *it);
    name := temp_c_string(bus.tray_name);
    D.message_iter_append_basic(*it, #char "s", *name);
    err: DBus_Error;
    D.error_init(*err);
    reply := D.connection_send_with_reply_and_block(bus.conn, m, 2000, *err);
    D.error_free(*err);
    if reply D.message_unref(reply);
    atomic_store(*bus.tray, reply != null);
}

// LayoutUpdated (u revision, i parent 0) on the menu, or NewStatus (s) on the item.
tray_signal :: (menu: bool) {
    if !bus.tray_name return;
    m := ifx menu then D.message_new_signal("/MenuBar", MENU, "LayoutUpdated") else D.message_new_signal("/StatusNotifierItem", SNI, "NewStatus");
    if !m return;
    defer D.message_unref(m);
    it: DBus_Iter;
    D.message_iter_init_append(m, *it);
    if menu {
        zero: s32;
        D.message_iter_append_basic(*it, #char "u", *bus.tray_rev);
        D.message_iter_append_basic(*it, #char "i", *zero);
    } else {
        st := ifx bus.unread then "NeedsAttention".data else "Active".data;
        D.message_iter_append_basic(*it, #char "s", *st);
    }
    D.connection_send(bus.conn, m, null);
    D.connection_flush(bus.conn);
}

// The item's and the menu's methods and properties. Anything else gets UnknownMethod.
tray_call :: (m: *void) {
    path := to_string(D.message_get_path(m));
    iface := to_string(D.message_get_interface(m));
    member := to_string(D.message_get_member(m));
    in, it, arr: DBus_Iter;
    has_args := D.message_iter_init(m, *in) != 0;
    reply := D.message_new_method_return(m);
    if !reply return;
    defer { D.connection_send(bus.conn, reply, null); D.connection_flush(bus.conn); D.message_unref(reply); }
    D.message_iter_init_append(reply, *it);
    item := path == "/StatusNotifierItem";
    if path != "/MenuBar" && !item { unknown(m, *reply); return; }
    if iface == "org.freedesktop.DBus.Properties" {
        want: *u8;
        if has_args && D.message_iter_next(*in) && D.message_iter_get_arg_type(*in) == #char "s" D.message_iter_get_basic(*in, *want); // Get's second argument
        if member == "Get" && want { if !tray_prop(*it, item, to_string(want)) unknown(m, *reply); return; }
        if member != "GetAll" { unknown(m, *reply); return; }
        D.message_iter_open_container(*it, #char "a", "{sv}", *arr);
        ITEM_PROPS :: string.["Category", "Id", "Title", "Status", "IconName", "AttentionIconName", "Menu", "ItemIsMenu"];
        MENU_PROPS :: string.["Version", "Status", "TextDirection"];
        names: []string = MENU_PROPS;
        if item names = ITEM_PROPS;
        for names {
            e: DBus_Iter;
            D.message_iter_open_container(*arr, #char "e", null, *e);
            key := temp_c_string(it);
            D.message_iter_append_basic(*e, #char "s", *key);
            tray_prop(*e, item, it);
            D.message_iter_close_container(*arr, *e);
        }
        D.message_iter_close_container(*it, *arr);
        return;
    }
    if item {
        if member == "Activate" || member == "SecondaryActivate" { push_event(.{kind = .Open_Url, time = time_now()}); request_frame(); }
        else if member != "ContextMenu" && member != "Scroll" unknown(m, *reply);
        return;
    }
    if member == {
    case "GetLayout";
        D.message_iter_append_basic(*it, #char "u", *bus.tray_rev);
        menu_node(*it, 0);
    case "GetGroupProperties";
        D.message_iter_open_container(*it, #char "a", "(ia{sv})", *arr);
        for 1..TRAY_ITEMS.count {
            st: DBus_Iter;
            id: s32 = xx it;
            D.message_iter_open_container(*arr, #char "r", null, *st);
            D.message_iter_append_basic(*st, #char "i", *id);
            menu_props(*st, id);
            D.message_iter_close_container(*arr, *st);
        }
        D.message_iter_close_container(*it, *arr);
    case "Event";
        if has_args menu_event(*in);
    case "EventGroup"; // a(isvu)
        if has_args && D.message_iter_get_arg_type(*in) == #char "a" {
            ev: DBus_Iter;
            D.message_iter_recurse(*in, *ev);
            while D.message_iter_get_arg_type(*ev) == #char "r" {
                f: DBus_Iter;
                D.message_iter_recurse(*ev, *f);
                menu_event(*f);
                D.message_iter_next(*ev);
            }
        }
        D.message_iter_open_container(*it, #char "a", "i", *arr);
        D.message_iter_close_container(*it, *arr);
    case "AboutToShow";
        no: u32;
        D.message_iter_append_basic(*it, #char "b", *no);
    case "AboutToShowGroup";
        for _: 0..1 { D.message_iter_open_container(*it, #char "a", "i", *arr); D.message_iter_close_container(*it, *arr); }
    case; unknown(m, *reply);
    }
}

unknown :: (m: *void, reply: **void) {
    D.message_unref(reply.*);
    reply.* = D.message_new_error(m, "org.freedesktop.DBus.Error.UnknownMethod", "unknown");
}

// A property as a variant; false if there is no such property.
tray_prop :: (it: *DBus_Iter, item: bool, name: string) -> bool {
    basic :: (it: *DBus_Iter, sig: *u8, value: *void) {
        v: DBus_Iter;
        D.message_iter_open_container(it, #char "v", sig, *v);
        D.message_iter_append_basic(*v, sig[0], value);
        D.message_iter_close_container(it, *v);
    }
    str :: (it: *DBus_Iter, sig: *u8, value: string) { p := temp_c_string(value); basic(it, sig, *p); }
    no: u32;
    three: u32 = 3;
    if item {
        if name == {
        case "Category"; str(it, "s", "Communications");
        case "Id"; str(it, "s", "fastcord");
        case "Title"; str(it, "s", "Fastcord");
        case "Status"; str(it, "s", ifx bus.unread then "NeedsAttention" else "Active");
        case "IconName"; #through; case "AttentionIconName"; str(it, "s", "fastcord"); // the icon the desktop entry installs
        case "Menu"; str(it, "o", "/MenuBar");
        case "ItemIsMenu"; basic(it, "b", *no);
        case; return false;
        }
        return true;
    }
    if name == {
    case "Version"; basic(it, "u", *three);
    case "Status"; str(it, "s", "normal");
    case "TextDirection"; str(it, "s", "ltr");
    case; return false;
    }
    return true;
}

// (ia{sv}av): the root (0) with every item as a child, or one item.
menu_node :: (it: *DBus_Iter, id: s32) {
    st, kids: DBus_Iter;
    D.message_iter_open_container(it, #char "r", null, *st);
    D.message_iter_append_basic(*st, #char "i", *id);
    menu_props(*st, id);
    D.message_iter_open_container(*st, #char "a", "v", *kids);
    if id == 0 for 1..TRAY_ITEMS.count {
        v: DBus_Iter;
        D.message_iter_open_container(*kids, #char "v", "(ia{sv}av)", *v);
        menu_node(*v, xx it); // depth 1: items have no children
        D.message_iter_close_container(*kids, *v);
    }
    D.message_iter_close_container(*st, *kids);
    D.message_iter_close_container(it, *st);
}

menu_props :: (it: *DBus_Iter, id: s32) {
    arr: DBus_Iter;
    D.message_iter_open_container(it, #char "a", "{sv}", *arr);
    prop :: (arr: *DBus_Iter, key: string, sig: *u8, value: *void) {
        e, v: DBus_Iter;
        D.message_iter_open_container(arr, #char "e", null, *e);
        k := temp_c_string(key);
        D.message_iter_append_basic(*e, #char "s", *k);
        D.message_iter_open_container(*e, #char "v", sig, *v);
        D.message_iter_append_basic(*v, sig[0], value);
        D.message_iter_close_container(*e, *v);
        D.message_iter_close_container(arr, *e);
    }
    if id == 0 {
        sub := "submenu".data;
        prop(*arr, "children-display", "s", *sub);
    } else if TRAY_ITEMS[id - 1] == "" {
        sep := "separator".data;
        prop(*arr, "type", "s", *sep);
    } else {
        text := temp_c_string(TRAY_ITEMS[id - 1]);
        prop(*arr, "label", "s", *text);
        if id == 3 || id == 4 {
            check := "checkmark".data;
            on: s32 = xx ifx id == 3 then s.tray_mute else s.tray_deaf;
            prop(*arr, "toggle-type", "s", *check);
            prop(*arr, "toggle-state", "i", *on);
        }
    }
    D.message_iter_close_container(it, *arr);
}

// An event (i id, s type, v data, u time): a click runs its item.
menu_event :: (f: *DBus_Iter) {
    id: s32;
    kind: *u8;
    if D.message_iter_get_arg_type(f) != #char "i" return;
    D.message_iter_get_basic(f, *id);
    if !D.message_iter_next(f) || D.message_iter_get_arg_type(f) != #char "s" return;
    D.message_iter_get_basic(f, *kind);
    if to_string(kind) != "clicked" return;
    if id == 1 push_event(.{kind = .Open_Url, time = time_now()});
    else if id == 3 push_event(.{kind = .Tray_Mute, time = time_now()});
    else if id == 4 push_event(.{kind = .Tray_Deafen, time = time_now()});
    else if id == 6 { s.quit = true; push_event(.{kind = .Quit, time = time_now()}); }
    else return;
    request_frame();
}

