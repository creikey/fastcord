#+build windows
package platform

import "core:strings"
import win "core:sys/windows"

// Opens a URL in the user's default browser.
open_url :: proc(url: string) {
	// ShellExecute runs whatever it is given (files, UNC paths, protocol handlers).
	if !strings.has_prefix(url, "https://") && !strings.has_prefix(url, "http://") do return
	w := win.utf8_to_wstring(url)
	win.ShellExecuteW(nil, win.L("open"), w, nil, nil, win.SW_SHOWNORMAL)
}
