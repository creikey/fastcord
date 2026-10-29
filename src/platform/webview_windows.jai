// webview.jai on Windows: WebView2 in its own window on the UI thread (its callbacks come through the
// app's message pump). Nothing is linked: the Evergreen runtime is found as WebView2Loader finds it (the
// EdgeUpdate ClientState key's EBWebView folder) and its EmbeddedBrowserWebView.dll is loaded on the first
// page. The page is served for url from WebResourceRequested (so nothing goes to that host), in an
// InPrivate profile under %TEMP%; the main frame may not leave it and new windows never open.

#scope_module

os_webview_open :: (title: string, html: string, url: string, width: int, height: int) {
    if !ww.loaded {
        ww.loaded = true;
        ww.create_env = wv2_runtime();
        wc := win.WNDCLASSEXW.{cbSize = size_of(win.WNDCLASSEXW), lpfnWndProc = xx ww_wndproc, hInstance = win.GetModuleHandleW(null),
            hCursor = win.LoadCursorA(null, win.IDC_ARROW), lpszClassName = wide("fastcord-webview")};
        win.RegisterClassExW(*wc);
    }
    if !ww.create_env {
        webview_push(.Unavailable, "the Microsoft Edge WebView2 Runtime");
        return;
    }
    ww.html = copy_string(html);
    ww.url = copy_string(url);
    scale := cast(float32) GetDpiForSystem() / 96;
    pw, ph := cast(s32) (width * scale), cast(s32) (height * scale);
    x := (GetSystemMetrics(0 /*SM_CXSCREEN*/) - pw) / 2;
    y := (GetSystemMetrics(1 /*SM_CYSCREEN*/) - ph) / 2;
    ww.hwnd = win.CreateWindowExW(0, wide("fastcord-webview"), wide(title), WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX, x, y, pw, ph, null, null, win.GetModuleHandleW(null), null);
    if !ww.hwnd {
        webview_push(.Unavailable);
        return;
    }
    win.ShowWindow(ww.hwnd, win.SW_SHOW);
    SetForegroundWindow(ww.hwnd);
    if ww.env {
        ww_create_controller();
    } else if !ww.env_pending {
        ww.env_pending = true;
        CoInitializeEx(null, 2 /*COINIT_APARTMENTTHREADED*/); // the UI thread's apartment (already one: S_FALSE)
        buf: [261]u16;
        n := GetTempPathW(260, buf.data);
        dir := tprint("%fastcord-webview", utf16_to_utf8(buf.data, n));
        if ww.create_env(1, 0 /*installed*/, wide(dir), null, *env_done) < 0 {
            ww.env_pending = false;
            os_webview_close();
            webview_push(.Unavailable);
        }
    }
}

os_webview_close :: () {
    if ww.controller {
        vt(ww.controller, 24, #type (*void) -> s32 #c_call)(ww.controller); // Close
        release(ww.view);
        release(ww.controller);
        ww.controller, ww.view = null, null;
    }
    if ww.hwnd {
        h := ww.hwnd;
        ww.hwnd = null;
        win.DestroyWindow(h);
    }
    free(ww.html);
    free(ww.url);
    ww.html, ww.url = "", "";
}

#scope_file

win :: #import "Windows";
#import "Windows_Utf8";

ww: struct {
    loaded: bool;
    create_env: Create_Env;
    env: *void; // ICoreWebView2Environment
    env_pending: bool;
    hwnd: win.HWND;
    controller: *void; // ICoreWebView2Controller
    view: *void; // ICoreWebView2
    html: string;
    url: string;
};

// EmbeddedBrowserWebView.dll's CreateWebViewEnvironmentWithOptionsInternal(checkRunningInstance,
// runtimeType, userDataFolder, environmentOptions, handler), what WebView2Loader calls.
Create_Env :: #type (check_running: s32, runtime_type: s32, user_data: *u16, options: *void, handler: *void) -> s32 #c_call;

// wv2_runtime: the installed Evergreen runtime's entry point (per machine, else per user), or null.
wv2_runtime :: () -> Create_Env {
    KEY :: "SOFTWARE\\Microsoft\\EdgeUpdate\\ClientState\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
    for root: u64.[0x8000_0002 /*HKLM*/, 0x8000_0001 /*HKCU*/] {
        buf: [1024]u16;
        size: u32 = size_of(type_of(buf));
        if RegGetValueW(cast(*void) root, wide(KEY), wide("EBWebView"), 0x2 /*RRF_RT_REG_SZ*/ | 0x2_0000 /*RRF_SUBKEY_WOW6432KEY*/, null, buf.data, *size) != 0 continue;
        dir := utf16_to_utf8(buf.data, -1);
        if !dir continue;
        arch := ifx CPU == .ARM64 then "arm64" else "x64";
        lib := win.LoadLibraryW(wide(tprint("%\\EBWebView\\%\\EmbeddedBrowserWebView.dll", trim_right(dir, "\\"), arch)));
        if !lib continue;
        f := win.GetProcAddress(lib, "CreateWebViewEnvironmentWithOptionsInternal".data);
        if f return cast(Create_Env) f;
    }
    return null;
}

ww_create_controller :: () {
    env10: *void;
    IID_ENV10 := win.GUID.{0xee0eb9df, 0x6f12, 0x46ce, .[0xb5, 0x3f, 0x3f, 0x47, 0xb9, 0xc9, 0x28, 0xe0]};
    if vt(ww.env, 0, #type (*void, *win.GUID, **void) -> s32 #c_call)(ww.env, *IID_ENV10, *env10) >= 0 && env10 {
        defer release(env10);
        opts: *void;
        if vt(env10, 20, #type (*void, **void) -> s32 #c_call)(env10, *opts) >= 0 && opts { // CreateCoreWebView2ControllerOptions
            defer release(opts);
            vt(opts, 6, #type (*void, s32) -> s32 #c_call)(opts, 1); // put_IsInPrivateModeEnabled
            if vt(env10, 21, #type (*void, win.HWND, *void, *void) -> s32 #c_call)(env10, ww.hwnd, opts, *controller_done) >= 0 return;
        }
    }
    vt(ww.env, 3, #type (*void, win.HWND, *void) -> s32 #c_call)(ww.env, ww.hwnd, *controller_done); // CreateCoreWebView2Controller
}

ww_bounds :: () {
    if !ww.controller return;
    r: win.RECT;
    GetClientRect(ww.hwnd, *r);
    vt(ww.controller, 6, #type (*void, *win.RECT) -> s32 #c_call)(ww.controller, *r); // put_Bounds (a RECT by value goes by pointer on x64)
}

ww_wndproc :: (hwnd: win.HWND, msg: u32, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT #c_call {
    c := s.ctx; push_context,defer_pop c;
    if hwnd == ww.hwnd {
        if msg == WM_SIZE { ww_bounds(); return 0; }
        if msg == WM_CLOSE {
            win.ShowWindow(hwnd, win.SW_HIDE); // released by the next webview_close
            webview_push(.Closed);
            return 0;
        }
    }
    return win.DefWindowProcW(hwnd, msg, wp, lp);
}

// ---- COM handlers: static objects (a pointer to their vtable), called on the UI thread

// A handler object is a pointer to its vtable; it is passed as the address of that pointer.
Vtbl :: struct (Invoke: Type) {
    QueryInterface: (this: *void, iid: *win.GUID, out: **void) -> s32 #c_call;
    AddRef: (this: *void) -> u32 #c_call;
    Release: (this: *void) -> u32 #c_call;
    invoke: Invoke;
}
Done :: #type (this: *void, hr: s32, result: *void) -> s32 #c_call;
Event :: #type (this: *void, sender: *void, args: *void) -> s32 #c_call;
qi :: (this: *void, iid: *win.GUID, out: **void) -> s32 #c_call { out.* = this; return 0; } // only WebView2 asks
one :: (this: *void) -> u32 #c_call { return 1; }

env_vtbl := Vtbl(Done).{qi, one, one, (this: *void, hr: s32, env: *void) -> s32 #c_call {
    c := s.ctx; push_context,defer_pop c;
    ww.env_pending = false;
    if hr < 0 || !env {
        os_webview_close();
        webview_push(.Unavailable);
        return 0;
    }
    vt(env, 1, #type (*void) -> u32 #c_call)(env); // AddRef: kept for the next page
    ww.env = env;
    if ww.hwnd ww_create_controller();
    return 0;
}};
env_done := *env_vtbl;

controller_vtbl := Vtbl(Done).{qi, one, one, (this: *void, hr: s32, controller: *void) -> s32 #c_call {
    c := s.ctx; push_context,defer_pop c;
    if hr < 0 || !controller {
        os_webview_close();
        webview_push(.Unavailable);
        return 0;
    }
    if !ww.hwnd || ww.controller { // closed (or reopened) meanwhile
        vt(controller, 24, #type (*void) -> s32 #c_call)(controller);
        return 0;
    }
    vt(controller, 1, #type (*void) -> u32 #c_call)(controller);
    ww.controller = controller;
    vt(controller, 25, #type (*void, **void) -> s32 #c_call)(controller, *ww.view); // get_CoreWebView2
    ww_bounds();
    v := ww.view;
    settings: *void;
    if vt(v, 3, #type (*void, **void) -> s32 #c_call)(v, *settings) >= 0 && settings { // get_Settings
        // put_IsStatusBarEnabled, put_AreDevToolsEnabled, put_AreDefaultContextMenusEnabled, put_AreHostObjectsAllowed,
        // put_IsZoomControlEnabled: all off
        for slot: int.[10, 12, 14, 16, 18] vt(settings, slot, #type (*void, s32) -> s32 #c_call)(settings, 0);
        release(settings);
    }
    token: s64;
    add :: (v: *void, slot: int, h: *void, token: *s64) { vt(v, slot, #type (*void, *void, *s64) -> s32 #c_call)(v, h, token); }
    add(v, 7, *navigation_starting, *token);
    add(v, 34, *message_received, *token);
    add(v, 44, *new_window, *token);
    add(v, 55, *resource_requested, *token);
    origin := slice(ww.url, 0, find_index_from_left(ww.url, "/", 8) + 1); // "https://host/"
    vt(v, 57, #type (*void, *u16, s32) -> s32 #c_call)(v, wide(join(origin, "*",, temp)), 0 /*ALL*/); // AddWebResourceRequestedFilter
    vt(v, 5, #type (*void, *u16) -> s32 #c_call)(v, wide(ww.url)); // Navigate
    return 0;
}};
controller_done := *controller_vtbl;

// NavigationStarting (the main frame's): only the page itself.
navigation_vtbl := Vtbl(Event).{qi, one, one, (this: *void, sender: *void, args: *void) -> s32 #c_call {
    c := s.ctx; push_context,defer_pop c;
    p: *u16;
    vt(args, 3, #type (*void, **u16) -> s32 #c_call)(args, *p); // get_Uri
    uri := utf16_to_utf8(p, -1);
    CoTaskMemFree(p);
    if uri != ww.url vt(args, 8, #type (*void, s32) -> s32 #c_call)(args, 1); // put_Cancel
    return 0;
}};
navigation_starting := *navigation_vtbl;

message_vtbl := Vtbl(Event).{qi, one, one, (this: *void, sender: *void, args: *void) -> s32 #c_call {
    c := s.ctx; push_context,defer_pop c;
    p: *u16;
    if vt(args, 5, #type (*void, **u16) -> s32 #c_call)(args, *p) < 0 || !p return 0; // TryGetWebMessageAsString
    text := utf16_to_utf8(p, -1);
    CoTaskMemFree(p);
    if webview_message_ok(text) webview_push(.Message, text);
    return 0;
}};
message_received := *message_vtbl;

new_window_vtbl := Vtbl(Event).{qi, one, one, (this: *void, sender: *void, args: *void) -> s32 #c_call {
    vt(args, 6, #type (*void, s32) -> s32 #c_call)(args, 1); // put_Handled: no window opens
    return 0;
}};
new_window := *new_window_vtbl;

// WebResourceRequested for the page's origin: the page itself, anything else a 404 (nothing goes there).
resource_vtbl := Vtbl(Event).{qi, one, one, (this: *void, sender: *void, args: *void) -> s32 #c_call {
    c := s.ctx; push_context,defer_pop c;
    req: *void;
    if vt(args, 3, #type (*void, **void) -> s32 #c_call)(args, *req) < 0 || !req return 0; // get_Request
    p: *u16;
    vt(req, 3, #type (*void, **u16) -> s32 #c_call)(req, *p); // get_Uri
    release(req);
    uri := utf16_to_utf8(p, -1);
    CoTaskMemFree(p);
    page := uri == ww.url;
    body := ifx page then ww.html else "";
    stream := SHCreateMemStream(body.data, xx body.count);
    resp: *void;
    vt(ww.env, 4, #type (*void, *void, s32, *u16, *u16, **void) -> s32 #c_call)(ww.env, stream, cast(s32) ifx page then 200 else 404, wide(ifx page then "OK" else "Not Found"),
        wide("Content-Type: text/html; charset=utf-8"), *resp); // CreateWebResourceResponse
    release(stream);
    if resp {
        vt(args, 5, #type (*void, *void) -> s32 #c_call)(args, resp); // put_Response
        release(resp);
    }
    return 0;
}};
resource_requested := *resource_vtbl;

vt :: inline (obj: *void, idx: int, $T: Type) -> T #no_context { return cast(T) (cast(***void) obj).*[idx]; }
release :: (obj: *void) #no_context { if obj vt(obj, 2, #type (*void) -> u32 #c_call)(obj); }

wide :: (str: string) -> *u16 { return utf8_to_wide(str,, temp); }

// count -1: zero-terminated (temp)
utf16_to_utf8 :: (p: *u16, count: int) -> string {
    if !p || count == 0 return "";
    return wide_to_utf8(p, xx count,, temp);
}

WS_CAPTION :: 0x00C0_0000;
WS_SYSMENU :: 0x0008_0000;
WS_MINIMIZEBOX :: 0x0002_0000;
WM_SIZE :: 0x0005;
WM_CLOSE :: 0x0010;

user32 :: #system_library "user32";
kernel32 :: #system_library "kernel32";
advapi32 :: #system_library "advapi32";
ole32 :: #system_library "ole32";
shlwapi :: #system_library "shlwapi";
GetDpiForSystem :: () -> u32 #foreign user32;
GetSystemMetrics :: (index: s32) -> s32 #foreign user32;
GetClientRect :: (hwnd: win.HWND, r: *win.RECT) -> s32 #foreign user32;
SetForegroundWindow :: (hwnd: win.HWND) -> s32 #foreign user32;
GetTempPathW :: (n: u32, buf: *u16) -> u32 #foreign kernel32;
RegGetValueW :: (key: *void, sub_key: *u16, value: *u16, flags: u32, kind: *u32, data: *void, size: *u32) -> s32 #foreign advapi32;
CoInitializeEx :: (reserved: *void, coinit: u32) -> s32 #foreign ole32;
CoTaskMemFree :: (p: *void) #foreign ole32;
SHCreateMemStream :: (data: *u8, size: u32) -> *void #foreign shlwapi;
