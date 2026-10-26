package prof

import "core:sync"
import "core:time"

foreign import system "system:System.framework"

@(default_calling_convention = "c", private = "file")
foreign system {
	pthread_self :: proc() -> rawptr ---
	pthread_mach_thread_np :: proc(t: rawptr) -> u32 ---
	pthread_get_stackaddr_np :: proc(t: rawptr) -> rawptr ---
	pthread_get_stacksize_np :: proc(t: rawptr) -> uint ---
	thread_suspend :: proc(t: u32) -> i32 ---
	thread_resume :: proc(t: u32) -> i32 ---
	thread_get_state :: proc(t: u32, flavor: i32, state: ^u32, count: ^u32) -> i32 ---
}

// A Mach thread port plus the thread's stack bounds, which keep the frame-pointer walk from
// reading outside the stack.
Thread_Ref :: struct {
	port:   u32,
	lo, hi: uintptr,
}

// Must be called on the thread to be sampled.
current_thread :: proc() -> Thread_Ref {
	t := pthread_self()
	hi := uintptr(pthread_get_stackaddr_np(t))
	return {port = pthread_mach_thread_np(t), lo = hi - uintptr(pthread_get_stacksize_np(t)), hi = hi}
}

when ODIN_ARCH == .arm64 {
	@(private = "file")
	State :: struct {
		x:                  [29]u64,
		fp, lr, sp, pc:     u64,
		cpsr, flags:        u32,
	}
	@(private = "file")
	FLAVOR :: 6 // ARM_THREAD_STATE64
} else {
	@(private = "file")
	State :: struct {
		rax, rbx, rcx, rdx, rdi, rsi, rbp, rsp: u64,
		r8, r9, r10, r11, r12, r13, r14, r15:   u64,
		rip, rflags, cs, fs, gs:                u64,
	}
	@(private = "file")
	FLAVOR :: 4 // x86_THREAD_STATE64
}

// Pointer-authentication bits that system libraries may set in saved return addresses.
@(private = "file")
ADDR_MASK :: 0x0000_7fff_ffff_ffff

// Suspends the thread, walks its frame-pointer chain into return addresses (innermost first) and
// resumes it. Returns the frame count, 0 on failure.
capture_thread :: proc(t: Thread_Ref, buf: []u64) -> int {
	n, _ := capture_thread_gated(t, buf, nil)
	return n
}

@(private)
capture_thread_gated :: proc(t: Thread_Ref, buf: []u64, gate: ^i32) -> (n: int, open: bool) {
	if thread_suspend(t.port) != 0 do return 0, true
	defer thread_resume(t.port)
	if gate != nil && sync.atomic_load(gate) == 0 do return 0, false
	st: State
	count := u32(size_of(State) / 4)
	if thread_get_state(t.port, FLAVOR, (^u32)(&st), &count) != 0 do return 0, true
	when ODIN_ARCH == .arm64 {
		pc, fp := st.pc, st.fp
	} else {
		pc, fp := st.rip, st.rbp
	}
	if pc == 0 || len(buf) == 0 do return 0, true
	buf[0] = pc & ADDR_MASK
	n = 1
	// Each frame record is {caller's frame pointer, return address}; records sit at increasing
	// addresses towards the outermost frame.
	for n < len(buf) && fp != 0 && fp & 7 == 0 && uintptr(fp) >= t.lo && uintptr(fp) + 16 <= t.hi {
		rec := ([^]u64)(uintptr(fp))
		ret := rec[1] & ADDR_MASK
		if ret == 0 do break
		buf[n] = ret - 1
		n += 1
		next := rec[0]
		if next <= fp do break
		fp = next
	}
	return n, true
}

@(private)
timer_make :: proc() -> rawptr {return nil}

@(private)
timer_destroy :: proc(_: rawptr) {}

@(private)
timer_wait :: proc(_: rawptr, d: time.Duration) {time.sleep(d)}
