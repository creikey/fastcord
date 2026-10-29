// A small window showing one page in the system's web view: WebKit on macOS, WebView2 on Windows,
// WebKitGTK on Linux. Each is loaded at run time on the first webview_open, so nothing is loaded, or
// needs installing, until a page is shown (the only one is Discord's captcha). The page claims to be
// at url (its origin) without anything being fetched from there, may navigate nowhere else, keeps no
// cookies or storage, and talks back with
//	window.webkit.messageHandlers.fc.postMessage(text)   (macOS, Linux)
//	window.chrome.webview.postMessage(text)              (Windows)

Webview_Event_Kind :: enum u8 {
	Message; // text: what the page posted
	Closed; // the user closed the window
	Unavailable; // no web view: text names what to install ("" = it failed some other way)
}

Webview_Event :: struct {
	kind: Webview_Event_Kind;
	text: string;
}

// webview_open shows html as the page at url, replacing any page shown. Results come from webview_take.
webview_open :: (title: string, html: string, url: string, width: int, height: int) {
	webview_close();
	os_webview_open(title, html, url, width, height);
}

// webview_close closes the window (no Closed event).
webview_close :: () { os_webview_close(); }

// webview_take: the events since the last call (allocator).
webview_take :: (allocator := temp) -> []Webview_Event {
	locks.guard(*wv.mu);
	out := NewArray(wv.events.count, Webview_Event,, allocator);
	for wv.events {
		out[it_index] = .{it.kind, copy_string(it.text,, allocator)};
		free(it.text);
	}
	wv.events.count = 0;
	return out;
}

#scope_module

wv: struct {
	mu: locks.Mutex;
	events: [..]Webview_Event; // heap strings
};

// webview_push (any thread) queues an event and wakes the UI thread.
webview_push :: (kind: Webview_Event_Kind, text := "") {
	{
		locks.guard(*wv.mu);
		array_add(*wv.events, .{kind, copy_string(text,, context.default_allocator)});
	}
	request_frame();
}

// webview_message_ok: page messages are short printable ASCII (a captcha token is a few KB).
webview_message_ok :: (s: string) -> bool {
	if s.count > 32768 return false;
	for cast([]u8) s if it < 0x20 || it > 0x7e return false;
	return true;
}
