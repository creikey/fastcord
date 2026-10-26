package app

import "core:debug/trace"
import "core:fmt"
import "core:strings"
import win "core:sys/windows"
import "fc:prof"

@(private = "file")
MAX_FRAMES :: 48

write_thread_stacks :: proc(b: ^strings.Builder, main_tid: int) {
	me := win.GetCurrentThreadId()
	pid := win.GetCurrentProcessId()
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPTHREAD, 0)
	if snap == win.INVALID_HANDLE_VALUE do return
	defer win.CloseHandle(snap)
	te := win.THREADENTRY32{dwSize = size_of(win.THREADENTRY32)}
	for ok := win.Thread32First(snap, &te); ok; ok = win.Thread32Next(snap, &te) {
		if te.th32OwnerProcessID != pid || te.th32ThreadID == me do continue
		// Symbol lookup allocates and takes DbgHelp locks, so it runs after the thread resumes.
		raw: [MAX_FRAMES]u64
		n := prof.capture_thread(te.th32ThreadID, raw[:])
		buf: [MAX_FRAMES]trace.Capture_Entry
		for a, i in raw[:n] do buf[i] = trace.Capture_Entry(a)
		fmt.sbprintfln(b, "\nthread %d%s", te.th32ThreadID, int(te.th32ThreadID) == main_tid ? " (main)" : "")
		locs, err := trace.resolve(buf[:n], context.temp_allocator)
		if err != nil {
			for e in buf[:n] do fmt.sbprintfln(b, "  0x%x", uintptr(e))
			continue
		}
		for l in locs do fmt.sbprintfln(b, "  %s  %s:%d", l.procedure, l.file_path, l.line)
	}
}
