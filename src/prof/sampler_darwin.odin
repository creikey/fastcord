package prof

import "base:intrinsics"
import "core:sync"
import "core:time"

foreign import system "system:System.framework"

@(default_calling_convention = "c", private = "file")
foreign system {
	pthread_self :: proc() -> rawptr ---
	pthread_kill :: proc(t: rawptr, sig: i32) -> i32 ---
	pthread_get_stackaddr_np :: proc(t: rawptr) -> rawptr ---
	sigaction :: proc(sig: i32, act: ^Sigaction, old: ^Sigaction) -> i32 ---
	getsectbyname :: proc(seg: cstring, sect: cstring) -> ^Section_64 ---
	_dyld_get_image_vmaddr_slide :: proc(image: u32) -> int ---
}

// Odin code on macOS keeps no frame-pointer chain and has no unwind tables, so neither a frame
// record walk nor libunwind gets past the first Odin frame. Instead the sampler signals the thread and
// the handler scans its live stack for words that point just past a call instruction in the
// executable. The innermost frame (the pc) is exact; outer frames can include a stale return address
// left in an uninitialised slot, so callers on macOS are approximate.
Thread_Ref :: struct {
	thread: rawptr, // pthread_t
	hi:     uintptr, // stack top
}

// Must be called on the thread to be sampled.
current_thread :: proc() -> Thread_Ref {
	t := pthread_self()
	return {t, uintptr(pthread_get_stackaddr_np(t))}
}

@(private = "file")
SIGPROF :: 27
@(private = "file")
SA_RESTART :: 0x2
@(private = "file")
SA_SIGINFO :: 0x40
@(private = "file")
MAX_SCAN :: 64 * 1024 // stack bytes scanned per sample

@(private = "file")
Sigaction :: struct {
	handler: proc "c" (sig: i32, info: rawptr, uc: rawptr),
	mask:    u32,
	flags:   i32,
}

@(private = "file")
Section_64 :: struct {
	sectname, segname: [16]u8,
	addr, size:        u64,
}

// Register offsets inside the mcontext that ucontext_t points to at offset 48: a 16-byte exception
// state, then arm_thread_state64 (x0..x28, fp, lr, sp, pc) or x86_thread_state64 (rsp is 7, rip 16).
when ODIN_ARCH == .arm64 {
	@(private = "file")
	PC_OFFSET :: 16 + 32 * 8
	@(private = "file")
	SP_OFFSET :: 16 + 31 * 8
	@(private = "file")
	LR_OFFSET :: 16 + 30 * 8
} else {
	@(private = "file")
	PC_OFFSET :: 16 + 16 * 8
	@(private = "file")
	SP_OFFSET :: 16 + 7 * 8
}

// Pointer-authentication bits that system libraries may set in return addresses.
@(private = "file")
ADDR_MASK :: 0x0000_7fff_ffff_ffff

// One capture at a time; busy is taken by the capturing thread and released by whoever finishes last.
@(private = "file")
Shot :: struct {
	busy:            i32,
	installed:       i32,
	gate:            ^i32,
	done:            i32,
	abandoned:       i32,
	stack_hi:        uintptr,
	text_lo, text_hi: u64,
	n:               int,
	frames:          [MAX_FRAMES]u64,
}
@(private = "file")
shot: Shot

// Whether a is a return address: inside the executable's code, right after a call.
@(private = "file")
is_return :: proc "contextless" (a: u64) -> bool {
	when ODIN_ARCH == .arm64 {
		if a & 3 != 0 || a < shot.text_lo + 4 || a > shot.text_hi do return false
		ins := (^u32)(uintptr(a - 4))^
		return ins & 0xFC00_0000 == 0x9400_0000 || ins & 0xFFFF_FC1F == 0xD63F_0000 || ins & 0xFFFF_F800 == 0xD63F_0800 // BL, BLR, BLRAA/BLRAB
	} else {
		if a < shot.text_lo + 6 || a > shot.text_hi do return false
		p := ([^]u8)(uintptr(a))
		return (p[-5] == 0xE8) || (p[-2] == 0xFF && (p[-1] >> 3) & 7 == 2) || (p[-3] == 0xFF && (p[-2] >> 3) & 7 == 2) || (p[-6] == 0xFF && (p[-5] >> 3) & 7 == 2) // call rel32, call r/m
	}
}

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
	mc := uintptr((^rawptr)(uintptr(uc) + 48)^)
	shot.frames[0] = u64((^uintptr)(mc + PC_OFFSET)^) & ADDR_MASK
	shot.n = 1
	when ODIN_ARCH == .arm64 {
		// A leaf function keeps its return address only in lr.
		lr := u64((^uintptr)(mc + LR_OFFSET)^) & ADDR_MASK
		if is_return(lr) {
			shot.frames[1] = lr - 1
			shot.n = 2
		}
	}
	sp := (^uintptr)(mc + SP_OFFSET)^ &~ 7
	hi := min(shot.stack_hi, sp + MAX_SCAN)
	for p := sp; p + 8 <= hi && shot.n < MAX_FRAMES; p += 8 {
		a := (^u64)(p)^ & ADDR_MASK
		if !is_return(a) || a - 1 == shot.frames[shot.n - 1] do continue
		shot.frames[shot.n] = a - 1
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
		if s := getsectbyname("__TEXT", "__text"); s != nil {
			slide := u64(_dyld_get_image_vmaddr_slide(0))
			shot.text_lo, shot.text_hi = s.addr + slide, s.addr + slide + s.size
		}
		act := Sigaction{handler = on_sigprof, flags = SA_SIGINFO | SA_RESTART}
		if sigaction(SIGPROF, &act, nil) != 0 {
			sync.atomic_store(&shot.busy, 0)
			return 0, true
		}
		sync.atomic_store(&shot.installed, 1)
	}
	shot.gate = gate
	shot.stack_hi = t.hi
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
