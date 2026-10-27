#scope_file

MAX_FRAMES :: 48;
#scope_export

write_thread_stacks :: (b: *strings.Builder, main_tid: int) {
	me := win.GetCurrentThreadId();
	pid := win.GetCurrentProcessId();
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPTHREAD, 0);
	if snap == win.INVALID_HANDLE_VALUE { return; }
	defer win.CloseHandle(snap);
	te := win.THREADENTRY32.{dwSize = size_of(win.THREADENTRY32)};
	{ ok := win.Thread32First(snap, *te);
	while ok {
		if te.th32OwnerProcessID != pid || te.th32ThreadID == me { { ok = win.Thread32Next(snap, *te); continue; } }
		// Symbol lookup allocates and takes DbgHelp locks, so it runs after the thread resumes.
		raw: [MAX_FRAMES]u64;
		n := prof.capture_thread(te.th32ThreadID, view(raw));
		buf: [MAX_FRAMES]trace.Capture_Entry;
		for a, i: sub(raw, 0, n) { buf[i] = trace.Capture_Entry(a); }
		fmt.sbprintfln(b, "\nthread %d%s", te.th32ThreadID, ifx cast(int)(te.th32ThreadID) == main_tid then " (main)" else "");
		locs, err := trace.resolve(sub(buf, 0, n), temp);
		if err != null {
			for e: sub(buf, 0, n) { fmt.sbprintfln(b, "  0x%x", cast(u64)(e)); }
			{ ok = win.Thread32Next(snap, *te); continue; }
		}
		for l: locs { fmt.sbprintfln(b, "  %s  %s:%d", l.procedure, l.file_path, l.line); }
		ok = win.Thread32Next(snap, *te);
} }
}

