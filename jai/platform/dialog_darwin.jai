// Modal "open file" panel. Returns absolute paths (empty if cancelled).
open_file_dialog :: (allow_multiple := true, allocator := context.allocator) -> []string {
	if s.headless { return .{}; }
	panel := msg(Id, cls("NSOpenPanel"), "openPanel");
	msg(Void, panel, "setCanChooseFiles:", cast(NS.BOOL)(true));
	msg(Void, panel, "setCanChooseDirectories:", cast(NS.BOOL)(false));
	msg(Void, panel, "setAllowsMultipleSelection:", cast(NS.BOOL)(allow_multiple));
	resp := msg(NS.Integer, panel, "runModal");
	if resp != 1 { return .{}; } // NSModalResponseOK
	urls := msg(Id, panel, "URLs");
	n := cast(int)(msg(NS.UInteger, urls, "count"));
	out := make_slice(string, n, allocator);
	for i: 0..n-1 {
		url := msg(Id, urls, "objectAtIndex:", cast(NS.UInteger)(i));
		at(*out, i).* = odin_str(msg(Id, url, "path"), allocator);
	}
	return out;
}
#scope_file

_unused :: Allocator;
#scope_export

