// fastcord's mutex and condition variable: futex-based, valid zero-initialised, and checked.
//
// A plain mutex fails silently: unlocking one this thread does not hold (for example after
// `x = .{}` zeroed the struct around it while it was locked) corrupts it, and the next lock blocks
// forever with nothing pointing at the cause. Every lock in fastcord goes through this module, so
// misuse crashes at the faulty call with its source location, and a stuck thread can be traced to
// the lock it waits on and the code that holds it (see waiting_on).
#module_parameters (DEBUG := true); // true for dev/debug builds, false for app.

Mutex :: struct {
	state: u32; // 0 free, 1 locked, 2 locked with waiters
	owner: int; // Thread id of the holder, 0 when free.
	owner_loc: Source_Code_Location;
}

Cond :: struct { seq: u32; }

lock :: (m: *Mutex, loc := #caller_location) {
	me := current_thread_id();
	if atomic_load(*m.owner) == me fail("lock of a mutex this thread already holds", m, loc);
	if !compare_and_swap(*m.state, 0, 1) {
		s := slot_of(me);
		s.loc = loc;
		atomic_store(*s.m, m);
		atomic_store(*s.thread, me);
		holder := m.owner_loc;
		start := current_time_monotonic();
		raw_lock(m);
		atomic_store(*s.m, null);
		waited_ms := to_milliseconds(current_time_monotonic() - start);
		if waited_ms > UI_LOCK_WAIT_REPORT_MS && on_ui_thread() {
			print("locks: UI thread waited % ms for the lock at %, held since %\n", waited_ms, loc_string(loc), loc_string(holder), to_standard_error = true);
		}
	}
	acquired(m, me, loc);
}

// A UI-thread lock wait longer than this is printed with the lock site and where the holder took it:
// a worker holding a lock the UI needs across slow work drops frames.
UI_LOCK_WAIT_REPORT_MS :: 16;

try_lock :: (m: *Mutex, loc := #caller_location) -> bool {
	me := current_thread_id();
	if atomic_load(*m.owner) == me fail("try_lock of a mutex this thread already holds", m, loc);
	if !compare_and_swap(*m.state, 0, 1) return false;
	acquired(m, me, loc);
	return true;
}

unlock :: (m: *Mutex, loc := #caller_location) {
	check_held(m, "unlock of a mutex this thread does not hold (was its struct overwritten or copied while locked?)", loc);
	atomic_store(*m.owner, 0);
	raw_unlock(m);
}

// Scoped lock: `locks.guard(*x.mu);` holds it until the end of the enclosing scope.
guard :: (m: *Mutex, loc := #caller_location) #expand {
	lock(m, loc);
	`defer unlock(m, loc);
}

cond_wait :: (c: *Cond, m: *Mutex, loc := #caller_location) {
	may_block("untimed cond_wait", loc);
	wait(c, m, -1, "cond_wait on a mutex this thread does not hold", loc);
}

// Returns false on timeout.
cond_wait_with_timeout :: (c: *Cond, m: *Mutex, timeout_ms: s64, loc := #caller_location) -> bool {
	return wait(c, m, timeout_ms, "cond_wait_with_timeout on a mutex this thread does not hold", loc);
}

cond_signal :: (c: *Cond) { atomic_add(*c.seq, 1); futex_wake(*c.seq, false); }
cond_broadcast :: (c: *Cond) { atomic_add(*c.seq, 1); futex_wake(*c.seq, true); }

// set_ui_thread names the calling thread as the UI thread. From then on, in debug builds, every call
// that can wait on the network or on a network thread (socket I/O, dialing, untimed condition waits,
// joining network threads) panics when made on it, so a slow or silent peer can never freeze the
// window. Such work belongs on a worker, with the UI polling for its result.
set_ui_thread :: () { atomic_store(*ui_thread, current_thread_id()); }
clear_ui_thread :: () { atomic_store(*ui_thread, 0); }

on_ui_thread :: () -> bool {
	t := atomic_load(*ui_thread);
	return t != 0 && t == current_thread_id();
}

// may_block marks a call that can wait indefinitely on the network or another thread.
may_block :: (what: string, loc := #caller_location) {
	#if DEBUG {
		if !on_ui_thread() return;
		print("locks: % on the UI thread at %\n", what, loc_string(loc), to_standard_error = true);
		assert(false, "%", what, loc = loc); // prints the stack trace
	}
}

// join waits for a thread that may be blocked on the network, then deinits and frees it
// (allocated with New(Thread) by the caller).
join :: (t: *Thread, loc := #caller_location) {
	may_block("thread join", loc);
	thread_is_done(t, -1);
	thread_deinit(t);
	free(t);
}

Wait_Info :: struct {
	waiting: bool;
	wait_loc: Source_Code_Location;
	owner: int;
	owner_loc: Source_Code_Location;
}

// waiting_on reports the lock thread `tid` is blocked on, if any, and who holds it. Meant for a
// watchdog looking at a thread that has stopped making progress; the fields are read without
// synchronization, which is sound only because a stuck holder is not writing them.
waiting_on :: (tid: int) -> Wait_Info {
	s := slot_of(tid);
	if atomic_load(*s.thread) != tid return .{};
	m := atomic_load(*s.m);
	if m == null return .{};
	return .{waiting = true, wait_loc = s.loc, owner = atomic_load(*m.owner), owner_loc = m.owner_loc};
}

// The OS id of the calling thread (what hang reports and stack dumps print).
#if OS == .MACOS {
	current_thread_id :: () -> int { id: u64; pthread_threadid_np(null, *id); return cast(int) id; }
} else #if OS == .WINDOWS {
	current_thread_id :: () -> int { return cast(int) GetCurrentThreadId(); }
}

#scope_file

#import "Basic";
#import "Atomics";
#import "Thread";
#if OS == .MACOS #import "POSIX";
#if OS == .WINDOWS #import "Windows";

ui_thread: int;

// The lock each thread is blocked on, indexed by a small hash of its id; read by hang reports.
// Collisions only blur a diagnostic, never correctness.
WAIT_SLOTS :: 64;
Wait_Slot :: struct {
	thread: int;
	m: *Mutex;
	loc: Source_Code_Location;
}
wait_slots: [WAIT_SLOTS]Wait_Slot;

slot_of :: inline (tid: int) -> *Wait_Slot {
	return *wait_slots[((cast(u64) tid * 0x9E3779B97F4A7C15) >> 58) % WAIT_SLOTS];
}

loc_string :: (loc: Source_Code_Location) -> string {
	return tprint("%:%:%", loc.fully_pathed_filename, loc.line_number, loc.character_number);
}

fail :: (what: string, m: *Mutex, loc: Source_Code_Location) {
	held := ifx m.owner then tprint("; held by thread % since %", m.owner, loc_string(m.owner_loc));
	print("locks: %1%2\n", what, held, to_standard_error = true);
	assert(false, "%", what, loc = loc);
}

acquired :: inline (m: *Mutex, me: int, loc: Source_Code_Location) {
	atomic_store(*m.owner, me);
	m.owner_loc = loc;
}

check_held :: inline (m: *Mutex, what: string, loc: Source_Code_Location) -> int {
	me := current_thread_id();
	if atomic_load(*m.owner) != me fail(what, m, loc);
	return me;
}

raw_lock :: (m: *Mutex) {
	if compare_and_swap(*m.state, 0, 1) return;
	while atomic_exchange(*m.state, 2) != 0 futex_wait(*m.state, 2, -1);
}

raw_unlock :: (m: *Mutex) {
	if atomic_exchange(*m.state, 0) == 2 futex_wake(*m.state, false);
}

wait :: (c: *Cond, m: *Mutex, timeout_ms: s64, what: string, loc: Source_Code_Location) -> bool {
	me := check_held(m, what, loc);
	atomic_store(*m.owner, 0);
	seq := atomic_load(*c.seq);
	raw_unlock(m);
	ok := futex_wait(*c.seq, seq, timeout_ms);
	raw_lock(m);
	acquired(m, me, loc);
	return ok;
}

// futex_wait sleeps while *addr == expected, up to timeout_ms (-1: forever); false on timeout.
#if OS == .MACOS {
	libsystem :: #system_library "libSystem";
	__ulock_wait :: (op: u32, addr: *void, value: u64, timeout_us: u32) -> s32 #foreign libsystem;
	__ulock_wake :: (op: u32, addr: *void, wake_value: u64) -> s32 #foreign libsystem;
	UL_COMPARE_AND_WAIT :: 1;
	ULF_WAKE_ALL :: 0x100;
	ULF_NO_ERRNO :: 0x1000000;

	futex_wait :: (addr: *u32, expected: u32, timeout_ms: s64) -> bool {
		us: u32 = ifx timeout_ms < 0 then 0 else cast(u32) clamp(timeout_ms * 1000, 1, 0xFFFF_FFFF);
		return __ulock_wait(UL_COMPARE_AND_WAIT | ULF_NO_ERRNO, addr, expected, us) != -60; // ETIMEDOUT
	}
	futex_wake :: (addr: *u32, all: bool) {
		op: u32 = UL_COMPARE_AND_WAIT | ULF_NO_ERRNO | (ifx all then cast(u32) ULF_WAKE_ALL);
		while __ulock_wake(op, addr, 0) == -4 {} // EINTR
	}
} else #if OS == .WINDOWS {
	synch :: #system_library "api-ms-win-core-synch-l1-2-0";
	WaitOnAddress :: (addr: *void, compare: *void, size: u64, ms: u32) -> s32 #foreign synch;
	WakeByAddressSingle :: (addr: *void) #foreign synch;
	WakeByAddressAll :: (addr: *void) #foreign synch;

	futex_wait :: (addr: *u32, expected: u32, timeout_ms: s64) -> bool {
		e := expected;
		ms: u32 = ifx timeout_ms < 0 then 0xFFFF_FFFF else cast(u32) clamp(timeout_ms, 0, 0xFFFF_FFFE);
		return WaitOnAddress(addr, *e, 4, ms) != 0;
	}
	futex_wake :: (addr: *u32, all: bool) { if all WakeByAddressAll(addr); else WakeByAddressSingle(addr); }
}
