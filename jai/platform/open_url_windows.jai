// Opens a URL in the user's default browser.
open_url :: (url: string) {
	// ShellExecute runs whatever it is given (files, UNC paths, protocol handlers).
	if !strings.has_prefix(url, "https://") && !strings.has_prefix(url, "http://") { return; }
	w := win.utf8_to_wstring(url);
	win.ShellExecuteW(null, win.L("open"), w, null, null, win.SW_SHOWNORMAL);
}

