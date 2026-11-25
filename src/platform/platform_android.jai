// Android: a NativeActivity (the Android module's glue starts main once the window exists). Its looper
// delivers lifecycle commands and input on the UI thread inside os_wait. Touch is a left mouse button for
// now; the rest of the desktop surface is stubbed until TODO.md's Android steps fill it in.

native_display :: () -> *void { return null; }
native_window :: () -> *void { return android.android_app.window; }
is_wayland :: () -> bool { return false; }
present_begin :: () -> bool { return android.android_app.window != null; }
draws_caption :: () -> bool { return false; }
Window_Hit :: enum u8 { Client; Caption; Maximize; }
set_window_hit_callback :: (cb: (p: Vector2) -> Window_Hit) {}
window_minimize :: () {}
window_maximized :: () -> bool { return false; }
window_toggle_maximize :: () {}
window_close :: () {}
native_metal_layer :: () -> *void { return null; }
set_capture_hidden :: (hidden: bool) {}
set_frame_wait_handle :: (h: *void) {}

system_dark_mode :: () -> dark: bool, ok: bool {
    if s.headless || !android.android_app.config return false, false;
    return android.AConfiguration_getUiModeNight(android.android_app.config) == .UI_MODE_NIGHT_YES, true;
}
system_a11y :: () -> System_A11y { return .{}; }

open_file_dialog :: (allow_multiple := true, allocator := context.allocator) -> []string { return .[]; }
Drag_Write :: #type (url: string, path: string) -> bool;
drag_out :: (url: string, name: string, write: Drag_Write) -> bool { return false; }
save_dialog_missing :: () -> bool { return !s.headless; }
save_file_dialog :: (name: string, allocator := context.allocator) -> string { return ""; }
notify_show :: (title: string, body: string, id: string) -> bool { return false; }
set_badge :: (text: string) {}
open_path :: (path: string) {}
speak :: (text: string) {}
open_url :: (url: string) {} // @Incomplete: An ACTION_VIEW intent over JNI (TODO.md's Android step 6).
window_placement :: () -> Window_Placement, bool { return .{}, false; }
window_placement_restore :: (p: Window_Placement) {}
set_fullscreen :: (on: bool) {}
is_fullscreen :: () -> bool { return false; }
window_show :: () {}
open_at_login :: () -> bool { return s.headless && s.headless_login; }
set_open_at_login :: (on: bool) { if s.headless s.headless_login = on; }

// The app's private files directory (Context.getFilesDir), where <state> lives.
app_files_dir :: () -> string { return to_string(android.android_app.activity.internalDataPath); }

// Android drops a native program's stdout and stderr: a thread copies them, line by line, to logcat
// (tag "fastcord").
stdio_to_logcat :: () {
    fds: [2]s32;
    if posix.pipe(*fds) != 0 return;
    posix.dup2(fds[1], 1);
    posix.dup2(fds[1], 2);
    posix.close(fds[1]);
    logcat_fd = fds[0];
    t := New(Thread);
    thread_init(t, (t: *Thread) -> s64 {
        buf: [1024]u8;
        n := 0;
        while true {
            r := posix.read(logcat_fd, buf.data + n, xx (buf.count - 1 - n));
            if r <= 0 return 0;
            n += r;
            start := 0;
            for i: 0..n - 1 {
                if buf[i] != #char "\n" && i - start < buf.count - 2 continue;
                buf[i] = 0;
                android.__android_log_write(.INFO, "fastcord", buf.data + start);
                start = i + 1;
            }
            n -= start;
            memcpy(buf.data, buf.data + start, n);
        }
        return 0;
    });
    thread_start(t);
}

#scope_module

android :: #import "Android";
logcat_fd: s32;

tray_changed :: () {}
tray_hides :: () -> bool { return false; }
os_global_input :: (on: bool) -> Global_Input { return ifx on then .Unavailable else .Off; }

os_init :: (title: string, width: int, height: int) -> bool {
    app := android.android_app;
    if !app || !app.window return false;
    android.__android_handle_command = handle_command;
    android.__android_handle_input_event = handle_input;
    update_size();
    return true;
}

os_shutdown :: () {}
os_wake :: () { android.ALooper_wake(android.android_app.looper); }
os_frame_wait :: () {}
os_window_visible :: () -> bool { return android.android_app.window != null && as.focused; }

os_wait :: (timeout: float64) {
    start := time_now();
    while true {
        ms: s32 = 0;
        if !s.quit && !atomic_load(*s.frame_requested) && pending_count() == 0 {
            ms = -1;
            if timeout >= 0 {
                remaining := timeout - (time_now() - start);
                ms = ifx remaining <= 0 then cast(s32) 0 else cast(s32) (remaining * 1000 + 0.999);
            }
        }
        events: s32;
        source: *android.Android_Poll_Source;
        r := android.ALooper_pollOnce(ms, null, *events, cast(**void) *source);
        if r >= 0 && source source.process(android.android_app, source);
        if android.android_app.destroyRequested && !s.quit {
            s.quit = true;
            push_event(.{kind = .Quit, time = time_now()});
        }
        if ms == 0 || r == xx android.ALOOPER_POLL.TIMEOUT return;
    }
}

os_clipboard_get :: (allocator: Allocator) -> string { return ""; }
os_clipboard_set_image :: (png: []u8) {}
os_clipboard_set :: (str: string) {}
os_clipboard_kind :: () -> Clipboard_Kind { return .None; }
os_clipboard_image :: (allocator: Allocator) -> []u8, bool { return .[], false; }
os_clipboard_files :: (allocator: Allocator) -> []string { return .[]; }
os_apply_cursor :: () {}

os_webview_open :: (title: string, html: string, url: string, width: int, height: int) { webview_push(.Unavailable); }
os_webview_close :: () {}

#scope_file

as: struct {
    focused := true;
    px_w, px_h: s32;
};

// Android's density is dots per inch over 160, the scale of its dp unit.
update_size :: () {
    app := android.android_app;
    if !app.window return;
    density := ifx app.config then cast(s32) android.AConfiguration_getDensity(app.config) else 0;
    s.scale = ifx density > 0 && density < 0xfffe then density / 160.0 else 1;
    as.px_w = android.ANativeWindow_getWidth(app.window);
    as.px_h = android.ANativeWindow_getHeight(app.window);
    s.size = .{as.px_w / s.scale, as.px_h / s.scale};
}

handle_command :: (app: *android.Android_App, cmd: s32) {
    now := time_now();
    c := cast(android.APP_CMD) cmd;
    if c == {
        case .INIT_WINDOW; #through;
        case .WINDOW_RESIZED; #through;
        case .CONFIG_CHANGED; #through;
        case .CONTENT_RECT_CHANGED;
            update_size();
            push_event(.{kind = .Resize, pos = s.size, time = now});
        case .GAINED_FOCUS;
            as.focused = true;
            push_event(.{kind = .Focus_Gained, time = now});
        case .LOST_FOCUS;
            as.focused = false;
            push_event(.{kind = .Focus_Lost, time = now});
    }
    request_frame();
}

handle_input :: (event: *android.AInputEvent) -> bool {
    now := time_now();
    if android.AInputEvent_getType(event) != .MOTION return false;
    a := cast(u32) android.AMotionEvent_getAction(event);
    action := a & 0xff;
    if (a >> 8) & 0xff != 0 return true; // Only the first finger is the mouse.
    pos := Vector2.{android.AMotionEvent_getX(event, 0) / s.scale, android.AMotionEvent_getY(event, 0) / s.scale};
    if action == {
        case 0; // DOWN
            push_event(.{kind = .Mouse_Move, pos = pos, time = now});
            push_event(.{kind = .Mouse_Down, button = .Left, pos = pos, click_count = 1, time = now});
        case 2; // MOVE
            push_event(.{kind = .Mouse_Move, pos = pos, time = now});
        case 1; #through; // UP
        case 3; // CANCEL
            push_event(.{kind = .Mouse_Up, button = .Left, pos = pos, click_count = 1, time = now});
            push_event(.{kind = .Mouse_Leave, time = now});
        case; return false;
    }
    request_frame();
    return true;
}
