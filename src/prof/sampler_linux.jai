// The macOS sampler's method (sampler_darwin.jai) on x86_64 Linux: the sampler sends SIGPROF to the target
// thread (tgkill) and the handler records the interrupted pc, then scans the live stack for words that point
// just past a call instruction in the executable's code. The pc is exact; outer frames are approximate (a
// stale return address left in a slot can show up). Addresses resolve through dladdr; Jai's own procedures
// are not in the dynamic symbol table, so they print as "<exe>+0x<vaddr>" for addr2line.
Thread_Ref :: struct {
	tid: s32;
	hi: u64; // stack top
}

// Must be called on the thread to be sampled.
current_thread :: () -> Thread_Ref {
	r := Thread_Ref.{tid = cast(s32) syscall(SYS_gettid)};
	attr: pthread_attr_t;
	if pthread_getattr_np(pthread_self(), *attr) == 0 {
		addr: *void;
		size: u64;
		if pthread_attr_getstack(*attr, *addr, *size) == 0 r.hi = cast(u64) addr + size;
		pthread_attr_destroy(*attr);
	}
	return r;
}

// Interrupts the thread and returns its return addresses (innermost first). Returns the frame count,
// 0 on failure.
capture_thread :: (t: Thread_Ref, buf: []u64) -> int {
	n := capture_thread_gated(t, buf, null);
	return n;
}

#scope_file

libc :: #system_library "libc";
Elf64_Phdr :: struct { p_type, p_flags: u32; p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align: u64; }
Dl_Phdr_Info :: struct { dlpi_addr: u64; dlpi_name: *u8; dlpi_phdr: *Elf64_Phdr; dlpi_phnum: u16; }
dl_iterate_phdr :: (cb: (info: *Dl_Phdr_Info, size: u64, data: *void) -> s32 #c_call, data: *void) -> s32 #foreign libc;
PT_LOAD :: 1;
PF_X :: 1;

MAX_SCAN :: 64 * 1024; // stack bytes scanned per sample

// One capture at a time; busy is taken by the capturing thread and released by whoever finishes last.
Shot :: struct {
	busy: s32;
	installed: s32;
	gate: *s32;
	done: s32;
	abandoned: s32;
	stack_hi: u64;
	text_lo, text_hi: u64;
	bias: u64; // the executable's load address (PIE), subtracted for addr2line
	n: int;
	frames: [MAX_FRAMES]u64;
}
shot: Shot;

// Whether a is a return address: inside the executable's code, right after a call.
is_return :: (a: u64) -> bool #no_context {
	if a < shot.text_lo + 6 || a > shot.text_hi return false;
	p := cast(*u8) a;
	return p[-5] == 0xE8 || (p[-2] == 0xFF && ((p[-1] >> 3) & 7) == 2) || (p[-3] == 0xFF && ((p[-2] >> 3) & 7) == 2) || (p[-6] == 0xFF && ((p[-5] >> 3) & 7) == 2); // call rel32, call r/m
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
	g := (cast(*ucontext_t) uc).uc_mcontext.gregs;
	shot.frames[0] = cast(u64) g[cast(int) REG.RIP];
	shot.n = 1;
	sp := (cast(u64) g[cast(int) REG.RSP]) & ~cast(u64) 7;
	hi := ifx shot.stack_hi < sp + MAX_SCAN then shot.stack_hi else sp + MAX_SCAN; // unknown top (0): the pc only
	p := sp;
	while p + 8 <= hi && shot.n < MAX_FRAMES {
		defer p += 8;
		a := (cast(*u64) p).*;
		if !is_return(a) || a - 1 == shot.frames[shot.n - 1] continue;
		shot.frames[shot.n] = a - 1;
		shot.n += 1;
	}
}

// The first object dl_iterate_phdr reports is the executable: its executable PT_LOAD is the code range.
find_text :: (info: *Dl_Phdr_Info, size: u64, data: *void) -> s32 #c_call {
	for i: 0..cast(int) info.dlpi_phnum - 1 {
		ph := *info.dlpi_phdr[i];
		if ph.p_type != PT_LOAD || (ph.p_flags & PF_X) == 0 continue;
		shot.text_lo, shot.text_hi = info.dlpi_addr + ph.p_vaddr, info.dlpi_addr + ph.p_vaddr + ph.p_memsz;
		shot.bias = info.dlpi_addr;
		break;
	}
	return 1; // stop after the executable
}

#scope_module

// Returns the frame count (0 on failure) and false when the gate was closed.
capture_thread_gated :: (t: Thread_Ref, buf: []u64, gate: *s32) -> int, bool {
	if !compare_and_swap(*shot.busy, 0, 1) return 0, true;
	if atomic_load(*shot.installed) == 0 {
		dl_iterate_phdr(find_text, null);
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
	if syscall(SYS_tgkill, cast(s64) getpid(), cast(s64) t.tid, cast(s64) SIGPROF) != 0 {
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
		#asm { pause; }
	}
	defer atomic_store(*shot.busy, 0);
	if shot.n < 0 return 0, false;
	n := min(shot.n, buf.count);
	memcpy(buf.data, shot.frames.data, n * size_of(u64));
	return n, true;
}

timer_make :: () -> *void { return null; }
timer_destroy :: (_: *void) {}
// usleep, not nanosleep: Basic and POSIX declare nanosleep with different return types.
timer_wait :: (_: *void, ns: s64) { usleep(cast(u32) (ns / 1000)); }

// Procedure for a code address: the nearest dynamic symbol (libc and other shared objects), else the
// executable-relative address, which `addr2line -fe build/fastcord-dev` resolves to a procedure and line.
symbolize :: (addr: u64) -> Symbol {
	info: Dl_info;
	if !dladdr(cast(*void) addr, *info) return .{};
	file := copy_string(to_string(info.dli_fname));
	if info.dli_sname return .{procedure = copy_string(to_string(info.dli_sname)), file = file};
	if addr >= shot.text_lo && addr < shot.text_hi return .{procedure = tprint("%+0x%", path_filename(file), formatInt(addr - shot.bias, base = 16)), file = file};
	return .{procedure = tprint("%+0x%", path_filename(file), formatInt(addr - cast(u64) info.dli_fbase, base = 16)), file = file};
}
