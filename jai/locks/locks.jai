Mutex :: struct {
	impl: sync.Mutex;
	owner: int; // Thread id of the holder, 0 when free.
	owner_loc: Source_Code_Location;
}

Cond :: sync.Cond;
#scope_module

// The lock each thread is blocked on, indexed by a small hash of its id; read by hang reports.
// Collisions only blur a diagnostic, never correctness.
WAIT_SLOTS :: 64;
Wait_Slot :: struct {
	thread: int;
	m: *Mutex;
	loc: Source_Code_Location;
}
wait_slots: [WAIT_SLOTS]Wait_Slot;

fail :: (what: string, m: *Mutex, loc: Source_Code_Location) {
	runtime.print_string("locks: ");
	runtime.print_string(what);
	if m.owner != 0 {
		runtime.print_string("; held by thread ");
		runtime.print_int(m.owner);
		runtime.print_string(" since ");
		runtime.print_caller_location(m.owner_loc);
	}
	runtime.print_string("\n");
	runtime.panic_contextless(what, loc);
}

slot_of :: inline (tid: int) -> *Wait_Slot {
	return *wait_slots[((cast(u64)(tid) * 0x9E3779B97F4A7C15) >> 58) % WAIT_SLOTS];
}

acquired :: inline (m: *Mutex, me: int, loc: Source_Code_Location) {
	sync.atomic_store_explicit(*m.owner, me, .Relaxed);
	m.owner_loc = loc;
}

check_held :: inline (m: *Mutex, what: string, loc: Source_Code_Location) -> int {
	me := sync.current_thread_id();
	if sync.atomic_load_explicit(*m.owner, .Relaxed) != me {
		fail(what, m, loc);
	}
	return me;
}
#scope_export

lock :: (m: *Mutex, loc := #caller_location) {
	me := sync.current_thread_id();
	if sync.atomic_load_explicit(*m.owner, .Relaxed) == me { fail("lock of a mutex this thread already holds", m, loc); }
	if !sync.mutex_try_lock(*m.impl) {
		s := slot_of(me);
		s.loc = loc;
		sync.atomic_store_explicit(*s.m, m, .Relaxed);
		sync.atomic_store_explicit(*s.thread, me, .Release);
		holder := m.owner_loc;
		start := time.tick_now();
		sync.mutex_lock(*m.impl);
		sync.atomic_store_explicit(*s.m, null, .Relaxed);
		{ waited := time.tick_since(start);
		if waited > UI_LOCK_WAIT_REPORT && on_ui_thread() { report_ui_wait(waited, loc, holder); } }
	}
	acquired(m, me, loc);
}

// A UI-thread lock wait longer than this is printed with the lock site and where the holder took it:
// a worker holding a lock the UI needs across slow work drops frames.
UI_LOCK_WAIT_REPORT :: 16 * time.Millisecond;
#scope_module

report_ui_wait :: (waited: time.Duration, loc: Source_Code_Location, holder: Source_Code_Location) {
	runtime.print_string("locks: UI thread waited ");
	runtime.print_int(cast(int)(waited / time.Millisecond));
	runtime.print_string(" ms for the lock at ");
	runtime.print_caller_location(loc);
	runtime.print_string(", held since ");
	runtime.print_caller_location(holder);
	runtime.print_string("\n");
}
#scope_export

try_lock :: (m: *Mutex, loc := #caller_location) -> bool {
	me := sync.current_thread_id();
	if sync.atomic_load_explicit(*m.owner, .Relaxed) == me { fail("try_lock of a mutex this thread already holds", m, loc); }
	if !sync.mutex_try_lock(*m.impl) { return false; }
	acquired(m, me, loc);
	return true;
}

unlock :: (m: *Mutex, loc := #caller_location) {
	check_held(m, "unlock of a mutex this thread does not hold (was its struct overwritten or copied while locked?)", loc);
	sync.atomic_store_explicit(*m.owner, 0, .Relaxed);
	sync.mutex_unlock(*m.impl);
}

// Scoped lock: `locks.guard(*x.mu);` holds it until the end of the enclosing scope.
guard :: (m: *Mutex, loc := #caller_location) #expand {
	lock(m, loc);
	`defer unlock(m, loc);
}

cond_wait :: (c: *Cond, m: *Mutex, loc := #caller_location) {
	me := check_held(m, "cond_wait on a mutex this thread does not hold", loc);
	may_block("untimed cond_wait", loc);
	sync.atomic_store_explicit(*m.owner, 0, .Relaxed);
	sync.cond_wait(c, *m.impl);
	acquired(m, me, loc);
}

cond_wait_with_timeout :: (c: *Cond, m: *Mutex, duration: time.Duration, loc := #caller_location) -> bool {
	me := check_held(m, "cond_wait_with_timeout on a mutex this thread does not hold", loc);
	sync.atomic_store_explicit(*m.owner, 0, .Relaxed);
	ok := sync.cond_wait_with_timeout(c, *m.impl, duration);
	acquired(m, me, loc);
	return ok;
}

cond_signal :: sync.cond_signal;
cond_broadcast :: sync.cond_broadcast;
#scope_module

ui_thread: int;
#scope_export

// set_ui_thread names the calling thread as the UI thread. From then on, in debug builds, every call
// that can wait on the network or on a network thread (socket I/O, dialing, untimed condition waits,
// joining network threads) panics when made on it, so a slow or silent peer can never freeze the
// window. Such work belongs on a worker, with the UI polling for its result.
set_ui_thread :: () {
	atomic_store(*ui_thread, sync.current_thread_id());
}

clear_ui_thread :: () {
	atomic_store(*ui_thread, 0);
}

on_ui_thread :: () -> bool {
	t := sync.atomic_load_explicit(*ui_thread, .Relaxed);
	return t != 0 && t == sync.current_thread_id();
}

// may_block marks a call that can wait indefinitely on the network or another thread.
may_block :: (what: string, loc := #caller_location) {
	#if DEBUG {
		if !on_ui_thread() { return; }
		fmt.eprintfln("locks: %s on the UI thread at %v", what, loc);
		bt := trace.capture();
		{ frames, err := trace.resolve(bt, temp);
		if err == null { trace.print(frames); } }
		panic(what, loc);
	}
}

// join waits for a thread that may be blocked on the network, then destroys it.
join :: (t: *thread.Thread, loc := #caller_location) {
	may_block("thread join", loc);
	thread.join(t);
	thread.destroy(t);
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
	w: Wait_Info;
	s := slot_of(tid);
	if sync.atomic_load_explicit(*s.thread, .Acquire) != tid { return w; }
	m := sync.atomic_load_explicit(*s.m, .Relaxed);
	if m == null { return w; }
	return .{waiting = true, wait_loc = s.loc, owner = sync.atomic_load_explicit(*m.owner, .Relaxed), owner_loc = m.owner_loc};
}

