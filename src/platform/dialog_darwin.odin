#+build darwin
package platform

import "base:runtime"
import NS "core:sys/darwin/Foundation"

// Modal "open file" panel. Returns absolute paths (empty if cancelled).
open_file_dialog :: proc(allow_multiple := true, allocator := context.allocator) -> []string {
	if s.headless do return nil
	panel := msg(Id, cls("NSOpenPanel"), "openPanel")
	msg(Void, panel, "setCanChooseFiles:", NS.BOOL(true))
	msg(Void, panel, "setCanChooseDirectories:", NS.BOOL(false))
	msg(Void, panel, "setAllowsMultipleSelection:", NS.BOOL(allow_multiple))
	resp := msg(NS.Integer, panel, "runModal")
	if resp != 1 do return nil // NSModalResponseOK
	urls := msg(Id, panel, "URLs")
	n := int(msg(NS.UInteger, urls, "count"))
	out := make([]string, n, allocator)
	for i in 0 ..< n {
		url := msg(Id, urls, "objectAtIndex:", NS.UInteger(i))
		out[i] = odin_str(msg(Id, url, "path"), allocator)
	}
	return out
}

@(private = "file")
_unused :: runtime.Allocator
