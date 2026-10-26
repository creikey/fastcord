#+build darwin
package platform

// Opens a URL in the user's default browser.
open_url :: proc(url: string) {
	u := msg(Id, cls("NSURL"), "URLWithString:", nsstr(url))
	if u == nil do return
	ws := msg(Id, cls("NSWorkspace"), "sharedWorkspace")
	msg(Void, ws, "openURL:", u)
}
