// A thread id.
Thread_Ref :: u32;

current_thread :: () -> Thread_Ref { return GetCurrentThreadId(); }

// Suspends the thread, unwinds its stack into return addresses (innermost first) and resumes it.
// Returns the frame count, 0 on failure.
capture_thread :: (t: Thread_Ref, buf: []u64) -> int {
	n := capture_thread_gated(t, buf, null);
	return n;
}

#scope_file

kernel32 :: #system_library "kernel32";
SuspendThread_ :: (thread: HANDLE) -> u32 #foreign kernel32 "SuspendThread";
CreateWaitableTimerExW :: (attributes: *void, name: *u16, flags: u32, access: u32) -> HANDLE #foreign kernel32;
SetWaitableTimerEx :: (timer: HANDLE, due: *s64, period: s32, completion: *void, arg: *void, wake_context: *void, tolerable_delay: u32) -> BOOL #foreign kernel32;
RtlLookupFunctionEntry :: (pc: u64, image_base: *u64, history: *void) -> *void #foreign kernel32;
RtlVirtualUnwind :: (handler_type: u32, image_base: u64, pc: u64, entry: *void, ctx: *CONTEXT, handler_data: **void, establisher_frame: *u64, context_pointers: *void) -> *void #foreign kernel32;

THREAD_SUSPEND_RESUME :: 0x0002;
THREAD_GET_CONTEXT :: 0x0008;
THREAD_QUERY_INFORMATION :: 0x0040;
CONTEXT_FULL_AMD64 :: 0x10000B;
CREATE_WAITABLE_TIMER_HIGH_RESOLUTION :: 0x2;
TIMER_ALL_ACCESS :: 0x1F0003;

// GetThreadContext requires a 16-byte aligned CONTEXT.
Aligned_Context :: struct { c: CONTEXT #align 16; }

#scope_module

// Returns the frame count (0 on failure) and false when the gate was closed.
capture_thread_gated :: (t: Thread_Ref, buf: []u64, gate: *s32) -> int, bool {
	h := OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, 0, t);
	if !h return 0, true;
	defer CloseHandle(h);
	if SuspendThread_(h) == 0xFFFF_FFFF return 0, true;
	defer ResumeThread(h);
	if gate && atomic_load(gate) == 0 return 0, false;
	ac: Aligned_Context;
	ac.c.ContextFlags = CONTEXT_FULL_AMD64;
	// GetThreadContext also waits for the suspension to take effect.
	if !GetThreadContext(h, *ac.c) return 0, true;
	n := 0;
	while n < buf.count {
		pc := ac.c.Rip;
		if pc == 0 break;
		// Return addresses point after the call; step back into it so the line is the call's.
		buf[n] = ifx n == 0 then pc else pc - 1;
		n += 1;
		base: u64;
		fe := RtlLookupFunctionEntry(pc, *base, null);
		if !fe {
			// A leaf function without unwind data: the return address is on top of the stack.
			if ac.c.Rsp == 0 break;
			ac.c.Rip = (cast(*u64) ac.c.Rsp).*;
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
timer_make :: () -> HANDLE {
	return CreateWaitableTimerExW(null, null, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
}

timer_destroy :: (h: HANDLE) { if h CloseHandle(h); }

timer_wait :: (h: HANDLE, ns: s64) {
	if !h {
		sleep_milliseconds(xx (ns / 1_000_000));
		return;
	}
	due := -max(ns / 100, 1); // relative, in 100 ns units
	SetWaitableTimerEx(h, *due, 0, null, null, null, 0);
	WaitForSingleObject(h, INFINITE);
}

// Procedure and source line for a code address, from the PDB through DbgHelp.
symbolize :: (addr: u64) -> Symbol {
	process := GetCurrentProcess();
	if !dbghelp_tried {
		dbghelp_tried = true;
		SymSetOptions(.LOAD_LINES | .DEFERRED_LOADS);
		dbghelp_ok = SymInitialize(process, null, 1) != 0;
	}
	if !dbghelp_ok return .{};
	data: [size_of(SYMBOL_INFO) + 256]u8 #align 8;
	si := cast(*SYMBOL_INFO) data.data;
	si.SizeOfStruct = size_of(SYMBOL_INFO);
	si.MaxNameLen = 255;
	disp: u64;
	if !SymFromAddr(process, addr, *disp, si) return .{};
	out := Symbol.{procedure = copy_string(.{si.NameLen, si.Name.data})};
	line: IMAGEHLP_LINE64;
	line.SizeOfStruct = size_of(IMAGEHLP_LINE64);
	ldisp: u32;
	if SymGetLineFromAddr64(process, addr, *ldisp, *line) {
		out.file = copy_string(to_string(line.FileName));
		out.line = line.LineNumber;
	}
	return out;
}

#scope_file
dbghelp_tried, dbghelp_ok: bool;
