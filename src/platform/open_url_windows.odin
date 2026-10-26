#+build windows
package platform

import win "core:sys/windows"

// Opens a URL in the user's default browser.
open_url :: proc(url: string) {
	w := win.utf8_to_wstring(url)
	win.ShellExecuteW(nil, win.L("open"), w, nil, nil, win.SW_SHOWNORMAL)
}
