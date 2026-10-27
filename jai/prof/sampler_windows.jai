	RtlLookupFunctionEntry :: (ControlPc: u64, ImageBase: *u64, HistoryTable: *void) -> *void #foreign kernel32;
	RtlVirtualUnwind :: (HandlerType: u32, ImageBase: u64, ControlPc: u64, FunctionEntry: *void, ContextRecord: *win.CONTEXT, HandlerData: **void, EstablisherFrame: *u64, ContextPointers: *void) -> *void #foreign kernel32;

// A thread id.
Thread_Ref :: u32;

current_thread :: () -> Thread_Ref {return win.GetCurrentThreadId();}
#scope_file

// GetThreadContext requires a 16-byte aligned CONTEXT; core:sys/windows does not declare one aligned.
Aligned_Context :: struct {
	c: win.CONTEXT;
}

CONTEXT_FULL_AMD64 :: 0x10000B;
#scope_export

// Suspends the thread, unwinds its stack into return addresses (innermost first) and resumes it.
// Returns the frame count, 0 on failure. Resolve the addresses with core:debug/trace afterwards.
capture_thread :: (t: Thread_Ref, buf: []u64) -> int {
	n, _ := capture_thread_gated(t, buf, null);
	return n;
}
#scope_module

capture_thread_gated :: (t: Thread_Ref, buf: []u64, gate: *s32) -> int, bool {
	n: int;
	open: bool;
	h := win.OpenThread(win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT | win.THREAD_QUERY_INFORMATION, false, t);
	if h == null { return 0, true; }
	defer win.CloseHandle(h);
	if win.SuspendThread(h) == ~win.DWORD(0) { return 0, true; }
	defer win.ResumeThread(h);
	if gate != null && sync.atomic_load(gate) == 0 { return 0, false; }
	ac: Aligned_Context;
	ac.c.ContextFlags = CONTEXT_FULL_AMD64;
	// GetThreadContext also waits for the suspension to take effect.
	if !win.GetThreadContext(h, *ac.c) { return 0, true; }
	while n < len(buf) {
		pc := ac.c.Rip;
		if pc == 0 { break; }
		// Return addresses point after the call; step back into it so the line is the call's.
		buf[n] = ifx n == 0 then pc else pc - 1;
		n += 1;
		base: u64;
		fe := RtlLookupFunctionEntry(pc, *base, null);
		if fe == null {
			// A leaf function without unwind data: the return address is on top of the stack.
			if ac.c.Rsp == 0 { break; }
			ac.c.Rip = cast(*u64)(cast(u64)(ac.c.Rsp)).*;
			ac.c.Rsp += 8;
		} else {
			hd: *void;
			est: u64;
			RtlVirtualUnwind(0, base, pc, fe, *ac.c, *hd, *est, null);
		}
	}
	return n, true;
}

// Sleep() rounds up to the 15.6 ms scheduler tick; a high-resolution waitable timer does not.
timer_make :: () -> win.HANDLE {
	return win.CreateWaitableTimerExW(null, null, win.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS);
}

timer_destroy :: (h: win.HANDLE) {
	if h != null { win.CloseHandle(h); }
}

timer_wait :: (h: win.HANDLE, d: time.Duration) {
	if h == null {
		time.sleep(d);
		return;
	}
	due := win.LARGE_INTEGER(-max(cast(s64)(d / 100), 1)); // relative, in 100 ns units
	win.SetWaitableTimerEx(h, *due, 0, null, null, null, 0);
	win.WaitForSingleObject(h, win.INFINITE);
}
#scope_export

