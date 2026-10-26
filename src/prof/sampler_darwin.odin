package prof

import "base:intrinsics"
import "core:sync"
import "core:time"

foreign import system "system:System.framework"

@(default_calling_convention = "c", private = "file")
foreign system {
	pthread_self :: proc() -> rawptr ---
	pthread_kill :: proc(t: rawptr, sig: i32) -> i32 ---
	sigaction :: proc(sig: i32, act: ^Sigaction, old: ^Sigaction) -> i32 ---
	unw_getcontext :: proc(ctx: ^Unw_Context) -> i32 ---
	unw_init_local :: proc(cursor: ^Unw_Cursor, ctx: ^Unw_Context) -> i32 ---
	unw_get_reg :: proc(cursor: ^Unw_Cursor, reg: i32, val: ^uintptr) -> i32 ---
	unw_step :: proc(cursor: ^Unw_Cursor) -> i32 ---
}

// Odin code on macOS does not keep the frame-pointer chain, so walking frame records from a suspended
// thread skips every Odin frame. Instead the sampler signals the thread, and the handler unwinds its
// own stack with libunwind, which reads the compact unwind info the linker emits for every function.
Thread_Ref :: struct {
	thread: rawptr, // pthread_t
}

// Must be called on the thread to be sampled.
current_thread :: proc() -> Thread_Ref {
	return {pthread_self()}
}

@(private = "file")
SIGPROF :: 27
@(private = "file")
SA_RESTART :: 0x2
@(private = "file")
SA_SIGINFO :: 0x40
@(private = "file")
UNW_REG_IP :: -1

@(private = "file")
Sigaction :: struct {
	handler: proc "c" (sig: i32, info: rawptr, uc: rawptr),
	mask:    u32,
	flags:   i32,
}

// Sizes from libunwind's headers, the largest over architectures.
@(private = "file")
Unw_Context :: struct {
	data: [167]u64,
}
@(private = "file")
Unw_Cursor :: struct {
	data: [204]u64,
}

// The interrupted pc inside ucontext_t: uc_mcontext is the pointer at offset 48, and the thread state
// follows a 16-byte exception state (arm_thread_state64 pc is register 32, x86_thread_state64 rip is 16).
when ODIN_ARCH == .arm64 {
	@(private = "file")
	PC_OFFSET :: 16 + 32 * 8
} else {
	@(private = "file")
	PC_OFFSET :: 16 + 16 * 8
}

// Pointer-authentication bits that system libraries may set in return addresses.
@(private = "file")
ADDR_MASK :: 0x0000_7fff_ffff_ffff

// One capture at a time; busy is taken by the capturing thread and released by whoever finishes last.
@(private = "file")
Shot :: struct {
	busy:      i32,
	installed: i32,
	gate:      ^i32,
	done:      i32,
	abandoned: i32,
	n:         int,
	frames:    [MAX_FRAMES]u64,
}
@(private = "file")
shot: Shot

@(private = "file")
on_sigprof :: proc "c" (sig: i32, info: rawptr, uc: rawptr) {
	defer {
		sync.atomic_store(&shot.done, 1)
		// The capturer gave up waiting, so it left busy for us to release.
		if sync.atomic_exchange(&shot.abandoned, 0) == 1 do sync.atomic_store(&shot.busy, 0)
	}
	if shot.gate != nil && sync.atomic_load(shot.gate) == 0 {
		shot.n = -1
		return
	}
	mc := (^rawptr)(uintptr(uc) + 48)^
	pc := u64((^uintptr)(uintptr(mc) + PC_OFFSET)^) & ADDR_MASK
	shot.frames[0] = pc
	shot.n = 1
	ctx: Unw_Context
	cur: Unw_Cursor
	if unw_getcontext(&ctx) != 0 || unw_init_local(&cur, &ctx) != 0 do return
	// Step out of this handler and _sigtramp until the interrupted frame, then record from there.
	found := false
	for steps := 0; steps < 16 && !found; steps += 1 {
		ip: uintptr
		if unw_get_reg(&cur, UNW_REG_IP, &ip) != 0 do return
		if u64(ip) & ADDR_MASK == pc {
			found = true
			break
		}
		if unw_step(&cur) <= 0 do return
	}
	if !found do return
	for shot.n < MAX_FRAMES && unw_step(&cur) > 0 {
		ip: uintptr
		if unw_get_reg(&cur, UNW_REG_IP, &ip) != 0 || ip == 0 do break
		shot.frames[shot.n] = (u64(ip) & ADDR_MASK) - 1
		shot.n += 1
	}
}

// Interrupts the thread and returns its return addresses (innermost first). Returns the frame count,
// 0 on failure.
capture_thread :: proc(t: Thread_Ref, buf: []u64) -> int {
	n, _ := capture_thread_gated(t, buf, nil)
	return n
}

@(private)
capture_thread_gated :: proc(t: Thread_Ref, buf: []u64, gate: ^i32) -> (n: int, open: bool) {
	if _, ok := sync.atomic_compare_exchange_strong(&shot.busy, 0, 1); !ok do return 0, true
	if sync.atomic_load(&shot.installed) == 0 {
		act := Sigaction{handler = on_sigprof, flags = SA_SIGINFO | SA_RESTART}
		if sigaction(SIGPROF, &act, nil) != 0 {
			sync.atomic_store(&shot.busy, 0)
			return 0, true
		}
		sync.atomic_store(&shot.installed, 1)
	}
	shot.gate = gate
	shot.n = 0
	sync.atomic_store(&shot.done, 0)
	if pthread_kill(t.thread, SIGPROF) != 0 {
		sync.atomic_store(&shot.busy, 0)
		return 0, true
	}
	start := time.tick_now()
	for sync.atomic_load(&shot.done) == 0 {
		if time.tick_since(start) > time.Second {
			// The handler may still run later; it releases busy then.
			sync.atomic_store(&shot.abandoned, 1)
			if sync.atomic_load(&shot.done) == 1 && sync.atomic_exchange(&shot.abandoned, 0) == 1 do sync.atomic_store(&shot.busy, 0)
			return 0, true
		}
		intrinsics.cpu_relax()
	}
	defer sync.atomic_store(&shot.busy, 0)
	if shot.n < 0 do return 0, false
	n = min(shot.n, len(buf))
	copy(buf[:n], shot.frames[:n])
	return n, true
}

@(private)
timer_make :: proc() -> rawptr {return nil}

@(private)
timer_destroy :: proc(_: rawptr) {}

@(private)
timer_wait :: proc(_: rawptr, d: time.Duration) {time.sleep(d)}
