// webview.jai on Linux: WebKitGTK opened with dlopen on the first page (libwebkit2gtk-4.1, else 4.0, both
// GTK 3, else libwebkitgtk-6.0 on GTK 4, which newer GNOME installs may carry alone), so fastcord never
// needs it otherwise. GTK runs on a thread of its own, on its own display
// connection, from then on (it can be initialised once per process); the UI thread hands it work with
// g_idle_add. GTK prefers X11 (XWayland on Wayland desktops), then Wayland. The page is an ephemeral context's; its main frame may load only the page and the captcha
// providers' hosts (WebKitGTK doesn't say which frame a navigation is for), and new windows never open.

#scope_module

os_webview_open :: (title: string, html: string, url: string, width: int, height: int) {
    req := New(Wk_Request);
    req.title = copy_string(title);
    req.html = copy_string(html);
    req.url = copy_string(url);
    req.width, req.height = width, height;
    locks.guard(*wk.mu);
    if wk.failed {
        wk_request_free(req);
        webview_push(.Unavailable, WEBKITGTK);
        return;
    }
    if !wk.ready {
        if wk.pending wk_request_free(wk.pending);
        wk.pending = req;
        if !wk.started {
            wk.started = true;
            thread_init(*wk.thread, wk_thread);
            thread_start(*wk.thread);
        }
        return;
    }
    G.g_idle_add(wk_idle_open, req);
}

os_webview_close :: () {
    locks.guard(*wk.mu);
    if wk.pending wk_request_free(wk.pending);
    wk.pending = null;
    if wk.ready G.g_idle_add(wk_idle_close, null);
}

#scope_file

WEBKITGTK :: "WebKitGTK (libwebkit2gtk-4.1 or libwebkitgtk-6.0)";

// the hosts the captcha providers load from (main-frame navigations elsewhere are refused)
WK_HOSTS :: string.["hcaptcha.com", "google.com", "gstatic.com", "recaptcha.net", "cloudflare.com"];

Wk_Request :: struct {
    title, html, url: string;
    width, height: int;
}

wk: struct {
    mu: locks.Mutex;
    started, ready, failed: bool;
    pending: *Wk_Request; // an open asked for before GTK was up
    thread: Thread;
    ctx: #Context;
    // the GTK thread's
    window: *void;
    view: *void;
    url: string;
    closing: bool;
};

// GLib/GObject, GTK, WebKitGTK and JavaScriptCore entry points both generations have, found through
// WebKitGTK's handle (dlsym searches its dependencies).
Gtk :: struct {
    gtk_disable_setlocale: () #c_call;
    gdk_set_allowed_backends: (backends: *u8) #c_call;
    gtk_window_set_title: (w: *void, title: *u8) #c_call;
    gtk_window_set_default_size: (w: *void, width: s32, height: s32) #c_call;
    gtk_window_present: (w: *void) #c_call;
    g_idle_add: (f: (data: *void) -> s32 #c_call, data: *void) -> u32 #c_call;
    g_signal_connect_data: (instance: *void, signal: *u8, handler: *void, data: *void, destroy: *void, flags: s32) -> u64 #c_call;
    g_object_unref: (o: *void) #c_call;
    g_free: (p: *void) #c_call;
    webkit_web_view_get_user_content_manager: (view: *void) -> *void #c_call;
    webkit_web_view_load_html: (view: *void, html: *u8, base_uri: *u8) #c_call;
    jsc_value_is_string: (v: *void) -> s32 #c_call;
    jsc_value_to_string: (v: *void) -> *u8 #c_call;
    webkit_navigation_policy_decision_get_navigation_action: (d: *void) -> *void #c_call;
    webkit_navigation_action_get_request: (a: *void) -> *void #c_call;
    webkit_uri_request_get_uri: (r: *void) -> *u8 #c_call;
    webkit_policy_decision_ignore: (d: *void) #c_call;
}
// GTK 3 and WebKitGTK 4.x only
Gtk3 :: struct {
    gtk_init_check: (argc: *s32, argv: ***u8) -> s32 #c_call;
    gtk_main: () #c_call;
    gtk_window_new: (kind: s32) -> *void #c_call;
    gtk_window_set_position: (w: *void, pos: s32) #c_call;
    gtk_container_add: (c: *void, child: *void) #c_call;
    gtk_widget_show_all: (w: *void) #c_call;
    gtk_widget_destroy: (w: *void) #c_call;
    webkit_web_context_new_ephemeral: () -> *void #c_call;
    webkit_web_view_new_with_context: (ctx: *void) -> *void #c_call;
    webkit_user_content_manager_register_script_message_handler: (ucm: *void, name: *u8) -> s32 #c_call;
    webkit_javascript_result_get_js_value: (r: *void) -> *void #c_call;
}
// GTK 4 and WebKitGTK 6.0 only
Gtk4 :: struct {
    gtk_init_check: () -> s32 #c_call;
    g_main_loop_new: (ctx: *void, running: s32) -> *void #c_call;
    g_main_loop_run: (loop: *void) #c_call;
    gtk_window_new: () -> *void #c_call;
    gtk_window_set_child: (w: *void, child: *void) #c_call;
    gtk_window_destroy: (w: *void) #c_call;
    webkit_network_session_new_ephemeral: () -> *void #c_call;
    webkit_web_view_get_type: () -> u64 #c_call;
    g_object_new_with_properties: (kind: u64, n: u32, names: **u8, values: *GValue) -> *void #c_call;
    g_value_init: (v: *GValue, kind: u64) -> *GValue #c_call;
    g_value_set_object: (v: *GValue, o: *void) #c_call;
    g_value_unset: (v: *GValue) #c_call;
    webkit_user_content_manager_register_script_message_handler: (ucm: *void, name: *u8, world: *u8) -> s32 #c_call;
}
GValue :: struct { kind: u64; data: [2]u64; }
G_TYPE_OBJECT :: 20 << 2;
G: Gtk;
G3: Gtk3;
G4: Gtk4;
gtk4: bool;

wk_request_free :: (r: *Wk_Request) {
    free(r.title);
    free(r.html);
    free(r.url);
    free(r);
}

wk_thread :: (t: *Thread) -> s64 {
    lib := dlopen("libwebkit2gtk-4.1.so.0", RTLD_NOW);
    if !lib lib = dlopen("libwebkit2gtk-4.0.so.37", RTLD_NOW);
    if !lib {
        lib = dlopen("libwebkitgtk-6.0.so.4", RTLD_NOW);
        gtk4 = lib != null;
    }
    ok := lib && load_syms(lib, *G, "") && (ifx gtk4 then load_syms(lib, *G4, "") else load_syms(lib, *G3, ""));
    if ok {
        G.gtk_disable_setlocale(); // gtk_init would set the process's C locale (number parsing, formatting)
        // X11 (XWayland on a Wayland desktop) first: the path tested end to end; native Wayland where there is
        // no X server. GDK_BACKEND still overrides it.
        G.gdk_set_allowed_backends("x11,wayland");
        ok = (ifx gtk4 then G4.gtk_init_check() else G3.gtk_init_check(null, null)) != 0;
    }
    locks.lock(*wk.mu);
    wk.ctx = context;
    wk.ready, wk.failed = ok, !ok;
    req := wk.pending;
    wk.pending = null;
    locks.unlock(*wk.mu);
    if !ok {
        if req wk_request_free(req);
        webview_push(.Unavailable, ifx lib then "" else WEBKITGTK);
        return 0;
    }
    if req G.g_idle_add(wk_idle_open, req);
    if gtk4 G4.g_main_loop_run(G4.g_main_loop_new(null, 0));
    else G3.gtk_main();
    return 0;
}

wk_idle_open :: (data: *void) -> s32 #c_call {
    push_context wk.ctx {
        req := cast(*Wk_Request) data;
        defer wk_request_free(req);
        wk_destroy();
        wk.window = ifx gtk4 then G4.gtk_window_new() else G3.gtk_window_new(0 /*GTK_WINDOW_TOPLEVEL*/);
        G.gtk_window_set_title(wk.window, temp_c_string(req.title));
        G.gtk_window_set_default_size(wk.window, xx req.width, xx req.height);
        G.g_signal_connect_data(wk.window, "destroy", cast(*void) wk_on_destroy, null, null, 0);
        if gtk4 {
            // g_object_new(WEBKIT_TYPE_WEB_VIEW, "network-session", ephemeral, NULL)
            session := G4.webkit_network_session_new_ephemeral();
            v: GValue;
            G4.g_value_init(*v, G_TYPE_OBJECT);
            G4.g_value_set_object(*v, session);
            name := "network-session".data;
            wk.view = G4.g_object_new_with_properties(G4.webkit_web_view_get_type(), 1, *name, *v);
            G4.g_value_unset(*v);
            G.g_object_unref(session);
        } else {
            ctx := G3.webkit_web_context_new_ephemeral();
            wk.view = G3.webkit_web_view_new_with_context(ctx);
            G.g_object_unref(ctx);
        }
        ucm := G.webkit_web_view_get_user_content_manager(wk.view);
        G.g_signal_connect_data(ucm, "script-message-received::fc", cast(*void) wk_on_message, null, null, 0);
        if gtk4 G4.webkit_user_content_manager_register_script_message_handler(ucm, "fc", null);
        else G3.webkit_user_content_manager_register_script_message_handler(ucm, "fc");
        G.g_signal_connect_data(wk.view, "decide-policy", cast(*void) wk_on_policy, null, null, 0);
        wk.url = copy_string(req.url);
        G.webkit_web_view_load_html(wk.view, temp_c_string(req.html), temp_c_string(req.url));
        if gtk4 {
            G4.gtk_window_set_child(wk.window, wk.view);
        } else {
            G3.gtk_window_set_position(wk.window, 1); // GTK_WIN_POS_CENTER
            G3.gtk_container_add(wk.window, wk.view);
            G3.gtk_widget_show_all(wk.window);
        }
        G.gtk_window_present(wk.window);
        reset_temporary_storage();
    }
    return 0; // G_SOURCE_REMOVE
}

wk_idle_close :: (data: *void) -> s32 #c_call {
    push_context wk.ctx { wk_destroy(); }
    return 0;
}

wk_destroy :: () {
    if !wk.window return;
    wk.closing = true;
    if gtk4 G4.gtk_window_destroy(wk.window);
    else G3.gtk_widget_destroy(wk.window);
    wk.closing = false;
    wk.window, wk.view = null, null;
    free(wk.url);
    wk.url = "";
}

wk_on_destroy :: (w: *void, data: *void) #c_call {
    push_context wk.ctx {
        if wk.closing return;
        wk.window, wk.view = null, null;
        webview_push(.Closed);
    }
}

// The page's message: a WebKitJavascriptResult (4.x), or the JSCValue itself (6.0).
wk_on_message :: (ucm: *void, result: *void, data: *void) #c_call {
    push_context wk.ctx {
        v := ifx gtk4 then result else G3.webkit_javascript_result_get_js_value(result);
        if !v || !G.jsc_value_is_string(v) return;
        p := G.jsc_value_to_string(v);
        if !p return;
        text := to_string(p);
        if webview_message_ok(text) webview_push(.Message, text);
        G.g_free(p);
    }
}

// decide-policy: WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION 0, NEW_WINDOW_ACTION 1, RESPONSE 2.
wk_on_policy :: (view: *void, decision: *void, kind: s32, data: *void) -> s32 #c_call {
    push_context wk.ctx {
        if kind == 2 return 0; // a response: the default
        allow := false;
        if kind == 0 {
            action := G.webkit_navigation_policy_decision_get_navigation_action(decision);
            uri := to_string(G.webkit_uri_request_get_uri(G.webkit_navigation_action_get_request(action)));
            allow = uri == wk.url || uri == "about:blank" || begins_with(uri, "about:srcdoc") || wk_provider(uri);
        }
        if allow return 0;
        G.webkit_policy_decision_ignore(decision);
        return 1;
    }
}

// wk_provider: an https URL on one of WK_HOSTS or a subdomain of one.
wk_provider :: (uri: string) -> bool {
    if !begins_with(uri, "https://") return false;
    host := advance(uri, 8);
    for i: 0..host.count-1 if host[i] == #char "/" || host[i] == #char ":" || host[i] == #char "?" || host[i] == #char "#" { host.count = i; break; }
    for WK_HOSTS if host == it || ends_with(host, join(".", it,, temp)) return true;
    return false;
}

#import "POSIX"; // dlopen
