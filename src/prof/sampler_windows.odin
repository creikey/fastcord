package prof

import "core:sync"
import "core:time"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	RtlLookupFunctionEntry :: proc(ControlPc: u64, ImageBase: ^u64, HistoryTable: rawptr) -> rawptr ---
	RtlVirtualUnwind :: proc(HandlerType: u32, ImageBase: u64, ControlPc: u64, FunctionEntry: rawptr, ContextRecord: ^win.CONTEXT, HandlerData: ^rawptr, EstablisherFrame: ^u64, ContextPointers: rawptr) -> rawptr ---
}

// A thread id.
Thread_Ref :: u32

current_thread :: proc() -> Thread_Ref {return win.GetCurrentThreadId()}

// GetThreadContext requires a 16-byte aligned CONTEXT; core:sys/windows does not declare one aligned.
@(private = "file")
Aligned_Context :: struct #align (16) {
	c: win.CONTEXT,
}

@(private = "file")
CONTEXT_FULL_AMD64 :: 0x10000B

// Suspends the thread, unwinds its stack into return addresses (innermost first) and resumes it.
// Returns the frame count, 0 on failure. Resolve the addresses with core:debug/trace afterwards.
capture_thread :: proc(t: Thread_Ref, buf: []u64) -> int {
	n, _ := capture_thread_gated(t, buf, nil)
	return n
}

@(private)
capture_thread_gated :: proc(t: Thread_Ref, buf: []u64, gate: ^i32) -> (n: int, open: bool) {
	h := win.OpenThread(win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT | win.THREAD_QUERY_INFORMATION, false, t)
	if h == nil do return 0, true
	defer win.CloseHandle(h)
	if win.SuspendThread(h) == ~win.DWORD(0) do return 0, true
	defer win.ResumeThread(h)
	if gate != nil && sync.atomic_load(gate) == 0 do return 0, false
	ac: Aligned_Context
	ac.c.ContextFlags = CONTEXT_FULL_AMD64
	// GetThreadContext also waits for the suspension to take effect.
	if !win.GetThreadContext(h, &ac.c) do return 0, true
	for n < len(buf) {
		pc := ac.c.Rip
		if pc == 0 do break
		// Return addresses point after the call; step back into it so the line is the call's.
		buf[n] = n == 0 ? pc : pc - 1
		n += 1
		base: u64
		fe := RtlLookupFunctionEntry(pc, &base, nil)
		if fe == nil {
			// A leaf function without unwind data: the return address is on top of the stack.
			if ac.c.Rsp == 0 do break
			ac.c.Rip = (^u64)(uintptr(ac.c.Rsp))^
			ac.c.Rsp += 8
		} else {
			hd: rawptr
			est: u64
			RtlVirtualUnwind(0, base, pc, fe, &ac.c, &hd, &est, nil)
		}
	}
	return n, true
}

// Sleep() rounds up to the 15.6 ms scheduler tick; a high-resolution waitable timer does not.
@(private)
timer_make :: proc() -> win.HANDLE {
	return win.CreateWaitableTimerExW(nil, nil, win.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS)
}

@(private)
timer_destroy :: proc(h: win.HANDLE) {
	if h != nil do win.CloseHandle(h)
}

@(private)
timer_wait :: proc(h: win.HANDLE, d: time.Duration) {
	if h == nil {
		time.sleep(d)
		return
	}
	due := win.LARGE_INTEGER(-max(i64(d / 100), 1)) // relative, in 100 ns units
	win.SetWaitableTimerEx(h, &due, 0, nil, nil, nil, 0)
	win.WaitForSingleObject(h, win.INFINITE)
}
