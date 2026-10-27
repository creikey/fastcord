// The code this was written for (Odin) keeps no frame-pointer chain and has no unwind tables on
// macOS, so neither a frame record walk nor libunwind gets past its first frame. Instead the sampler
// signals the thread and the handler scans its live stack for words that point just past a call
// instruction in the executable. The innermost frame (the pc) is exact; outer frames can include a
// stale return address left in an uninitialised slot, so callers on macOS are approximate.
Thread_Ref :: struct {
	thread: pthread_t;
	hi: u64; // stack top
}

// Must be called on the thread to be sampled.
current_thread :: () -> Thread_Ref {
	t := pthread_self();
	return .{t, cast(u64) pthread_get_stackaddr_np(t)};
}

// Interrupts the thread and returns its return addresses (innermost first). Returns the frame count,
// 0 on failure.
capture_thread :: (t: Thread_Ref, buf: []u64) -> int {
	n := capture_thread_gated(t, buf, null);
	return n;
}

#scope_file

getsectbyname :: (seg: *u8, sect: *u8) -> *Section_64 #foreign libsystem;
_dyld_get_image_vmaddr_slide :: (image: u32) -> int #foreign libsystem;
libsystem :: #system_library "libSystem";

MAX_SCAN :: 64 * 1024; // stack bytes scanned per sample

Section_64 :: struct {
	sectname, segname: [16]u8;
	addr, size: u64;
}

// Register offsets inside the mcontext that ucontext_t points to at offset 48: a 16-byte exception
// state, then arm_thread_state64 (x0..x28, fp, lr, sp, pc) or x86_thread_state64 (rsp is 7, rip 16).
#if CPU == .ARM64 {
	PC_OFFSET :: 16 + 32 * 8;
	SP_OFFSET :: 16 + 31 * 8;
	LR_OFFSET :: 16 + 30 * 8;
} else {
	PC_OFFSET :: 16 + 16 * 8;
	SP_OFFSET :: 16 + 7 * 8;
}

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
		if (a & 3) != 0 || a < shot.text_lo + 4 || a > shot.text_hi return false;
		ins := (cast(*u32) (a - 4)).*;
		return (ins & 0xFC00_0000) == 0x9400_0000 || (ins & 0xFFFF_FC1F) == 0xD63F_0000 || (ins & 0xFFFF_F800) == 0xD63F_0800; // BL, BLR, BLRAA/BLRAB
	} else {
		if a < shot.text_lo + 6 || a > shot.text_hi return false;
		p := cast(*u8) a;
		return p[-5] == 0xE8 || (p[-2] == 0xFF && ((p[-1] >> 3) & 7) == 2) || (p[-3] == 0xFF && ((p[-2] >> 3) & 7) == 2) || (p[-6] == 0xFF && ((p[-5] >> 3) & 7) == 2); // call rel32, call r/m
	}
}

on_sigprof :: (sig: s32, info: *siginfo_t, uc: *void) #c_call {
	defer {
		atomic_store(*shot.done, 1);
		// The capturer gave up waiting, so it left busy for us to release.
		if atomic_exchange(*shot.abandoned, 0) == 1 atomic_store(*shot.busy, 0);
	}
	if shot.gate && atomic_load(shot.gate) == 0 {
		shot.n = -1;
		return;
	}
	mc := (cast(*u64) (cast(u64) uc + 48)).*;
	shot.frames[0] = (cast(*u64) (mc + PC_OFFSET)).* & ADDR_MASK;
	shot.n = 1;
	#if CPU == .ARM64 {
		// A leaf function keeps its return address only in lr.
		lr := (cast(*u64) (mc + LR_OFFSET)).* & ADDR_MASK;
		if is_return(lr) {
			shot.frames[1] = lr - 1;
			shot.n = 2;
		}
	}
	sp := (cast(*u64) (mc + SP_OFFSET)).* & ~cast(u64) 7;
	hi := ifx shot.stack_hi < sp + MAX_SCAN then shot.stack_hi else sp + MAX_SCAN;
	p := sp;
	while p + 8 <= hi && shot.n < MAX_FRAMES {
		defer p += 8;
		a := (cast(*u64) p).* & ADDR_MASK;
		if !is_return(a) || a - 1 == shot.frames[shot.n - 1] continue;
		shot.frames[shot.n] = a - 1;
		shot.n += 1;
	}
}

#scope_module

// Returns the frame count (0 on failure) and false when the gate was closed.
capture_thread_gated :: (t: Thread_Ref, buf: []u64, gate: *s32) -> int, bool {
	if !compare_and_swap(*shot.busy, 0, 1) return 0, true;
	if atomic_load(*shot.installed) == 0 {
		s := getsectbyname("__TEXT", "__text");
		if s {
			slide := cast(u64) _dyld_get_image_vmaddr_slide(0);
			shot.text_lo, shot.text_hi = s.addr + slide, s.addr + slide + s.size;
		}
		act: sigaction_t;
		act.sa_sigaction = on_sigprof;
		act.sa_flags = SA_SIGINFO | SA_RESTART;
		if sigaction(SIGPROF, *act, null) != 0 {
			atomic_store(*shot.busy, 0);
			return 0, true;
		}
		atomic_store(*shot.installed, 1);
	}
	shot.gate = gate;
	shot.stack_hi = t.hi;
	shot.n = 0;
	atomic_store(*shot.done, 0);
	if pthread_kill(t.thread, SIGPROF) != 0 {
		atomic_store(*shot.busy, 0);
		return 0, true;
	}
	start := current_time_monotonic();
	while atomic_load(*shot.done) == 0 {
		if to_milliseconds(current_time_monotonic() - start) > 1000 {
			// The handler may still run later; it releases busy then.
			atomic_store(*shot.abandoned, 1);
			if atomic_load(*shot.done) == 1 && atomic_exchange(*shot.abandoned, 0) == 1 atomic_store(*shot.busy, 0);
			return 0, true;
		}
		#if CPU == .X64 #asm { pause; }
	}
	defer atomic_store(*shot.busy, 0);
	if shot.n < 0 return 0, false;
	n := min(shot.n, buf.count);
	memcpy(buf.data, shot.frames.data, n * size_of(u64));
	return n, true;
}

timer_make :: () -> *void { return null; }
timer_destroy :: (_: *void) {}
timer_wait :: (_: *void, ns: s64) {
	ts := timespec.{tv_sec = ns / 1_000_000_000, tv_nsec = ns % 1_000_000_000};
	nanosleep(*ts, null);
}

// Procedure and source line for a code address, through the private CoreSymbolication framework
// (what Odin's core:debug/trace uses on macOS), loaded on first use.
symbolize :: (addr: u64) -> Symbol {
	if !cs.loaded {
		cs.loaded = true;
		lib := dlopen("/System/Library/PrivateFrameworks/CoreSymbolication.framework/CoreSymbolication", RTLD_LAZY);
		if !lib return .{};
		cs.create = xx dlsym(lib, "CSSymbolicatorCreateWithPid");
		cs.symbol_at = xx dlsym(lib, "CSSymbolicatorGetSymbolWithAddressAtTime");
		cs.source_at = xx dlsym(lib, "CSSymbolicatorGetSourceInfoWithAddressAtTime");
		cs.symbol_name = xx dlsym(lib, "CSSymbolGetName");
		cs.symbol_owner = xx dlsym(lib, "CSSymbolGetSymbolOwner");
		cs.owner_path = xx dlsym(lib, "CSSymbolOwnerGetPath");
		cs.source_path = xx dlsym(lib, "CSSourceInfoGetPath");
		cs.source_line = xx dlsym(lib, "CSSourceInfoGetLineNumber");
		if !cs.create || !cs.symbol_at || !cs.source_at || !cs.symbol_name || !cs.symbol_owner || !cs.owner_path || !cs.source_path || !cs.source_line return .{};
		cs.symbolicator = cs.create(getpid());
		cs.ok = cs.symbolicator.obj != null;
	}
	if !cs.ok return .{};
	sym := cs.symbol_at(cs.symbolicator, addr, CS_NOW);
	info := cs.source_at(cs.symbolicator, addr, CS_NOW);
	out := Symbol.{procedure = copy_string(to_string(cs.symbol_name(sym)))};
	if !info.obj {
		out.file = copy_string(to_string(cs.owner_path(cs.symbol_owner(sym))));
	} else {
		out.file = copy_string(to_string(cs.source_path(info)));
		out.line = cs.source_line(info);
	}
	return out;
}

#scope_file

CS_Ref :: struct { data, obj: *void; } // null when obj is null
CS_NOW :: 0x80000000;
cs: struct {
	create: (pid: s32) -> CS_Ref #c_call;
	symbol_at: (s: CS_Ref, addr: u64, time: u64) -> CS_Ref #c_call;
	source_at: (s: CS_Ref, addr: u64, time: u64) -> CS_Ref #c_call;
	symbol_name: (sym: CS_Ref) -> *u8 #c_call;
	symbol_owner: (sym: CS_Ref) -> CS_Ref #c_call;
	owner_path: (owner: CS_Ref) -> *u8 #c_call;
	source_path: (info: CS_Ref) -> *u8 #c_call;
	source_line: (info: CS_Ref) -> s32 #c_call;
	symbolicator: CS_Ref;
	loaded, ok: bool;
};

