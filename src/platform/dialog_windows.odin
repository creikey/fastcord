package platform

// Modal "open file" dialog. Returns absolute paths (empty if cancelled).
// TODO(windows): IFileOpenDialog.
open_file_dialog :: proc(allow_multiple := true, allocator := context.allocator) -> []string {
	return nil
}
