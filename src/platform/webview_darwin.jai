// webview.jai on macOS: a WKWebView in its own NSWindow on the app's main thread. WebKit.framework is
// opened on first use, not linked. The page loads with loadHTMLString:baseURL:, in a non-persistent
// data store; the main frame may not leave the page (subframes, the captcha's, may load).

#scope_module

os_webview_open :: (title: string, html: string, url: string, width: int, height: int) {
    if !wvm.loaded {
        wvm.loaded = true;
        if !dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_LAZY) || !cls("WKWebView") {
            webview_push(.Unavailable, "WebKit");
            return;
        }
        d := objc.allocate_class(cls("NSObject"), "FCWebviewDelegate");
        objc.add_method(d, "userContentController:didReceiveScriptMessage:", cast(*void) wv_message, "v@:@@");
        objc.add_method(d, "webView:decidePolicyForNavigationAction:decisionHandler:", cast(*void) wv_policy, "v@:@@@?");
        objc.add_method(d, "windowWillClose:", cast(*void) wv_will_close, "v@:@");
        objc.register_class(d);
    }
    if !cls("WKWebView") { webview_push(.Unavailable, "WebKit"); return; }
    wvm.url = copy_string(url);
    wvm.delegate = objc.new_obj("FCWebviewDelegate");
    config := objc.new_obj("WKWebViewConfiguration");
    msg(Void, config, "setWebsiteDataStore:", msg(Id, cls("WKWebsiteDataStore"), "nonPersistentDataStore"));
    wvm.ucc = msg(Id, config, "userContentController");
    msg(Void, wvm.ucc, "addScriptMessageHandler:name:", wvm.delegate, nsstr("fc"));
    rect := NSRect.{.{0, 0}, .{xx width, xx height}};
    wvm.view = msg(Id, msg(Id, cls("WKWebView"), "alloc"), "initWithFrame:configuration:", rect, config);
    msg(Void, config, "release");
    msg(Void, wvm.view, "setNavigationDelegate:", wvm.delegate);
    wvm.window = msg(Id, msg(Id, cls("NSWindow"), "alloc"), "initWithContentRect:styleMask:backing:defer:", rect, cast(NSUInteger) (1 | 2), cast(NSUInteger) 2, false); // titled, closable
    msg(Void, wvm.window, "setReleasedWhenClosed:", false);
    msg(Void, wvm.window, "setTitle:", nsstr(title));
    msg(Void, wvm.window, "setContentView:", wvm.view);
    msg(Void, wvm.window, "setDelegate:", wvm.delegate);
    msg(Void, wvm.window, "center");
    msg(Void, wvm.window, "makeKeyAndOrderFront:", cast(Id) null);
    base := msg(Id, cls("NSURL"), "URLWithString:", nsstr(url));
    msg(Id, wvm.view, "loadHTMLString:baseURL:", nsstr(html), base);
}

// os_webview_close is never called from inside the window's own callbacks: a closed window is
// released by the next webview_close or webview_open.
os_webview_close :: () {
    if !wvm.window return;
    w := wvm.window;
    wvm.window = null;
    msg(Void, w, "setDelegate:", cast(Id) null);
    if !wvm.user_closed msg(Void, w, "close");
    wvm.user_closed = false;
    msg(Void, wvm.view, "setNavigationDelegate:", cast(Id) null);
    msg(Void, wvm.ucc, "removeScriptMessageHandlerForName:", nsstr("fc"));
    msg(Void, wvm.view, "release");
    msg(Void, w, "release");
    msg(Void, wvm.delegate, "release");
    free(wvm.url);
    wvm.url = "";
}

#scope_file

wvm: struct {
    loaded: bool;
    window: Id;
    view: Id;
    ucc: Id; // WKUserContentController
    delegate: Id;
    url: string;
    user_closed: bool; // closed by its close button, not released yet
};

RTLD_LAZY :: 1;
dlopen :: (path: *u8, mode: s32) -> *void #foreign libsystem;
libsystem :: #system_library "libSystem";

// These run on the main thread inside an AppKit call made from the UI thread.

wv_message :: (self: Id, cmd: SEL, ucc: Id, message: Id) #c_call {
    c := s.ctx; push_context,defer_pop c;
    body := msg(Id, message, "body");
    if !body || !msg(bool, body, "isKindOfClass:", cls("NSString")) return;
    text := to_jai_string(body, temp);
    if webview_message_ok(text) webview_push(.Message, text);
}

// WKNavigationActionPolicy: Cancel 0, Allow 1. The main frame stays on the page; a new window
// (no target frame) is never opened.
wv_policy :: (self: Id, cmd: SEL, view: Id, action: Id, handler: *Block) #c_call {
    c := s.ctx; push_context,defer_pop c;
    frame := msg(Id, action, "targetFrame");
    allow := frame != null;
    if allow && msg(bool, frame, "isMainFrame") {
        url := msg(Id, msg(Id, action, "request"), "URL");
        allow = url && to_jai_string(msg(Id, url, "absoluteString"), temp) == wvm.url;
    }
    (cast(#type (block: *Block, policy: NSInteger) #c_call) handler.invoke)(handler, ifx allow then 1 else 0);
}

wv_will_close :: (self: Id, cmd: SEL, n: Id) #c_call {
    c := s.ctx; push_context,defer_pop c;
    if !wvm.window || wvm.user_closed return;
    wvm.user_closed = true;
    webview_push(.Closed);
}

Block :: struct {
    isa: *void;
    flags: s32;
    reserved: s32;
    invoke: *void;
}
