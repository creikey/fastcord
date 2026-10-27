	pthread_self :: () -> *void #foreign system;
	pthread_kill :: (t: *void, sig: s32) -> s32 #foreign system;
	pthread_get_stackaddr_np :: (t: *void) -> *void #foreign system;
	sigaction :: (sig: s32, act: *Sigaction, old: *Sigaction) -> s32 #foreign system;
	getsectbyname :: (seg: *u8, sect: *u8) -> *Section_64 #foreign system;
	_dyld_get_image_vmaddr_slide :: (image: u32) -> int #foreign system;

// Odin code on macOS keeps no frame-pointer chain and has no unwind tables, so neither a frame
// record walk nor libunwind gets past the first Odin frame. Instead the sampler signals the thread and
// the handler scans its live stack for words that point just past a call instruction in the
// executable. The innermost frame (the pc) is exact; outer frames can include a stale return address
// left in an uninitialised slot, so callers on macOS are approximate.
Thread_Ref :: struct {
	thread: *void; // pthread_t
	hi: u64; // stack top
}

// Must be called on the thread to be sampled.
current_thread :: () -> Thread_Ref {
	t := pthread_self();
	return .{t, cast(u64)(pthread_get_stackaddr_np(t))};
}
#scope_file

SIGPROF :: 27;
SA_RESTART :: 0x2;
SA_SIGINFO :: 0x40;
MAX_SCAN :: 64 * 1024;
#scope_export
#scope_file // stack bytes scanned per sample

Sigaction :: struct {
	handler: (sig: s32, info: *void, uc: *void) #c_call;
	mask: u32;
	flags: s32;
}
#scope_file

Section_64 :: struct {
	sectname, segname: [16]u8;
	addr, size: u64;
}
#scope_export

// Register offsets inside the mcontext that ucontext_t points to at offset 48: a 16-byte exception
// state, then arm_thread_state64 (x0..x28, fp, lr, sp, pc) or x86_thread_state64 (rsp is 7, rip 16).
#if CPU == .ARM64 {
#scope_file
	PC_OFFSET :: 16 + 32 * 8;
	SP_OFFSET :: 16 + 31 * 8;
	LR_OFFSET :: 16 + 30 * 8;
#scope_export
} else {
#scope_file
	PC_OFFSET :: 16 + 16 * 8;
	SP_OFFSET :: 16 + 7 * 8;
#scope_export
}
#scope_file

// Pointer-authentication bits that system libraries may set in return addresses.
// Pointer-authentication bits that system libraries may set in return addresses.
ADDR_MASK :: 0x0000_7fff_ffff_ffff;

// One capture at a time; busy is taken by the capturing thread and released by whoever finishes last.
Shot :: struct {
	busy: s32;
	installed: s32;
	gate: *s32;
	done: s32;
	abandoned: s32;
	stack_hi: u64;
	text_lo, text_hi: u64;
	n: int;
	frames: [MAX_FRAMES]u64;
}
shot: Shot;

// Whether a is a return address: inside the executable's code, right after a call.
is_return :: (a: u64) -> bool #no_context {
	#if CPU == .ARM64 {
		if a & 3 != 0 || a < shot.text_lo + 4 || a > shot.text_hi { return false; }
		ins := cast(*u32)(cast(u64)(a - 4)).*;
		return ins & 0xFC00_0000 == 0x9400_0000 || ins & 0xFFFF_FC1F == 0xD63F_0000 || ins & 0xFFFF_F800 == 0xD63F_0800; // BL, BLR, BLRAA/BLRAB
	} else {
		if a < shot.text_lo + 6 || a > shot.text_hi { return false; }
		p := cast(*u8)(cast(u64)(a));
		return (p[-5] == 0xE8) || (p[-2] == 0xFF && (p[-1] >> 3) & 7 == 2) || (p[-3] == 0xFF && (p[-2] >> 3) & 7 == 2) || (p[-6] == 0xFF && (p[-5] >> 3) & 7 == 2); // call rel32, call r/m
	}
}

on_sigprof :: (sig: s32, info: *void, uc: *void) #c_call {
	defer {
		sync.atomic_store(*shot.done, 1);
		// The capturer gave up waiting, so it left busy for us to release.
		if sync.atomic_exchange(*shot.abandoned, 0) == 1 { sync.atomic_store(*shot.busy, 0); }
	}
	if shot.gate != null && sync.atomic_load(shot.gate) == 0 {
		shot.n = -1;
		return;
	}
	mc := cast(u64)(cast(**void)(cast(u64)(uc) + 48).*);
	shot.frames[0] = cast(u64)(cast(*u64)(mc + PC_OFFSET).*) & ADDR_MASK;
	shot.n = 1;
	#if CPU == .ARM64 {
		// A leaf function keeps its return address only in lr.
		lr := cast(u64)(cast(*u64)(mc + LR_OFFSET).*) & ADDR_MASK;
		if is_return(lr) {
			shot.frames[1] = lr - 1;
			shot.n = 2;
		}
	}
	sp := cast(*u64)(mc + SP_OFFSET).* & ~ 7;
	hi := min(shot.stack_hi, sp + MAX_SCAN);
	{ p := sp;
	while p + 8 <= hi && shot.n < MAX_FRAMES {
		a := cast(*u64)(p).* & ADDR_MASK;
		if !is_return(a) || a - 1 == shot.frames[shot.n - 1] { { p += 8; continue; } }
		shot.frames[shot.n] = a - 1;
		shot.n += 1;
		p += 8;
} }
}
#scope_export

// Interrupts the thread and returns its return addresses (innermost first). Returns the frame count,
// 0 on failure.
capture_thread :: (t: Thread_Ref, buf: []u64) -> int {
	n, _ := capture_thread_gated(t, buf, null);
	return n;
}
#scope_module

capture_thread_gated :: (t: Thread_Ref, buf: []u64, gate: *s32) -> int, bool {
	n: int;
	open: bool;
	{ _, ok := sync.atomic_compare_exchange_strong(*shot.busy, 0, 1);
	if !ok { return 0, true; } }
	if sync.atomic_load(*shot.installed) == 0 {
		{ s := getsectbyname("__TEXT", "__text");
		if s != null {
			slide := cast(u64)(_dyld_get_image_vmaddr_slide(0));
			shot.text_lo, shot.text_hi = s.addr + slide, s.addr + slide + s.size;
		} }
		act := Sigaction.{handler = on_sigprof, flags = SA_SIGINFO | SA_RESTART};
		if sigaction(SIGPROF, *act, null) != 0 {
			sync.atomic_store(*shot.busy, 0);
			return 0, true;
		}
		sync.atomic_store(*shot.installed, 1);
	}
	shot.gate = gate;
	shot.stack_hi = t.hi;
	shot.n = 0;
	sync.atomic_store(*shot.done, 0);
	if pthread_kill(t.thread, SIGPROF) != 0 {
		sync.atomic_store(*shot.busy, 0);
		return 0, true;
	}
	start := time.tick_now();
	while sync.atomic_load(*shot.done) == 0 {
		if time.tick_since(start) > time.Second {
			// The handler may still run later; it releases busy then.
			sync.atomic_store(*shot.abandoned, 1);
			if sync.atomic_load(*shot.done) == 1 && sync.atomic_exchange(*shot.abandoned, 0) == 1 { sync.atomic_store(*shot.busy, 0); }
			return 0, true;
		}
		intrinsics.cpu_relax();
	}
	defer sync.atomic_store(*shot.busy, 0);
	if shot.n < 0 { return 0, false; }
	n = min(shot.n, len(buf));
	copy(sub(buf, 0, n), sub(shot.frames, 0, n));
	return n, true;
}

timer_make :: () -> *void {return null;}

timer_destroy :: (_: *void) {}

timer_wait :: (_: *void, d: time.Duration) {time.sleep(d);}
#scope_export

