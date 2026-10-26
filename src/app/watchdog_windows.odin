package app

import "core:debug/trace"
import "core:fmt"
import "core:strings"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	RtlLookupFunctionEntry :: proc(ControlPc: u64, ImageBase: ^u64, HistoryTable: rawptr) -> rawptr ---
	RtlVirtualUnwind :: proc(HandlerType: u32, ImageBase: u64, ControlPc: u64, FunctionEntry: rawptr, ContextRecord: ^win.CONTEXT, HandlerData: ^rawptr, EstablisherFrame: ^u64, ContextPointers: rawptr) -> rawptr ---
}

// GetThreadContext requires a 16-byte aligned CONTEXT; core:sys/windows does not declare one aligned.
@(private = "file")
Aligned_Context :: struct #align (16) {
	c: win.CONTEXT,
}

@(private = "file")
CONTEXT_FULL_AMD64 :: 0x10000B

@(private = "file")
MAX_FRAMES :: 48

// Suspends the thread only while its stack is unwound into raw addresses; symbol lookup allocates
// and takes DbgHelp locks, so it runs after the thread resumes.
@(private = "file")
capture_thread :: proc(tid: u32, buf: []trace.Capture_Entry) -> int {
	h := win.OpenThread(win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT | win.THREAD_QUERY_INFORMATION, false, tid)
	if h == nil do return 0
	defer win.CloseHandle(h)
	if win.SuspendThread(h) == ~win.DWORD(0) do return 0
	defer win.ResumeThread(h)
	ac: Aligned_Context
	ac.c.ContextFlags = CONTEXT_FULL_AMD64
	if !win.GetThreadContext(h, &ac.c) do return 0
	n := 0
	for n < len(buf) {
		pc := ac.c.Rip
		if pc == 0 do break
		// Return addresses point after the call; step back into it so the line is the call's.
		buf[n] = trace.Capture_Entry(n == 0 ? pc : pc - 1)
		n += 1
		base: u64
		fe := RtlLookupFunctionEntry(pc, &base, nil)
		if fe == nil {
			if ac.c.Rsp == 0 do break
			ac.c.Rip = (^u64)(uintptr(ac.c.Rsp))^
			ac.c.Rsp += 8
		} else {
			hd: rawptr
			est: u64
			RtlVirtualUnwind(0, base, pc, fe, &ac.c, &hd, &est, nil)
		}
	}
	return n
}

write_thread_stacks :: proc(b: ^strings.Builder, main_tid: int) {
	me := win.GetCurrentThreadId()
	pid := win.GetCurrentProcessId()
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPTHREAD, 0)
	if snap == win.INVALID_HANDLE_VALUE do return
	defer win.CloseHandle(snap)
	te := win.THREADENTRY32{dwSize = size_of(win.THREADENTRY32)}
	for ok := win.Thread32First(snap, &te); ok; ok = win.Thread32Next(snap, &te) {
		if te.th32OwnerProcessID != pid || te.th32ThreadID == me do continue
		buf: [MAX_FRAMES]trace.Capture_Entry
		n := capture_thread(te.th32ThreadID, buf[:])
		fmt.sbprintfln(b, "\nthread %d%s", te.th32ThreadID, int(te.th32ThreadID) == main_tid ? " (main)" : "")
		locs, err := trace.resolve(buf[:n], context.temp_allocator)
		if err != nil {
			for e in buf[:n] do fmt.sbprintfln(b, "  0x%x", uintptr(e))
			continue
		}
		for l in locs do fmt.sbprintfln(b, "  %s  %s:%d", l.procedure, l.file_path, l.line)
	}
}
