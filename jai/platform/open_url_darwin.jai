// Opens a URL in the user's default browser.
open_url :: (url: string) {
	u := msg(Id, cls("NSURL"), "URLWithString:", nsstr(url));
	if u == null { return; }
	ws := msg(Id, cls("NSWorkspace"), "sharedWorkspace");
	msg(Void, ws, "openURL:", u);
}

