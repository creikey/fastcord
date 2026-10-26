// Checked mutex: core:sync's Mutex plus the holding thread and where it locked.
//
// A plain sync.Mutex fails silently: unlocking one this thread does not hold (for example after
// `x = {...}` zeroed the struct around it while it was locked) corrupts the OS lock, and the next
// lock blocks forever with nothing pointing at the cause. Every lock in fastcord goes through this
// package instead, so misuse crashes at the faulty call with its source location, and a stuck
// thread can be traced to the lock it waits on and the code that holds it (see waiting_on).
package locks

import "base:runtime"
import "core:debug/trace"
import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"

Mutex :: struct {
	impl:      sync.Mutex,
	owner:     int, // Thread id of the holder, 0 when free.
	owner_loc: runtime.Source_Code_Location,
}

Cond :: sync.Cond

// The lock each thread is blocked on, indexed by a small hash of its id; read by hang reports.
// Collisions only blur a diagnostic, never correctness.
@(private)
WAIT_SLOTS :: 64
@(private)
Wait_Slot :: struct {
	thread: int,
	m:      ^Mutex,
	loc:    runtime.Source_Code_Location,
}
@(private)
wait_slots: [WAIT_SLOTS]Wait_Slot

@(private)
fail :: proc "contextless" (what: string, m: ^Mutex, loc: runtime.Source_Code_Location) -> ! {
	runtime.print_string("locks: ")
	runtime.print_string(what)
	if m.owner != 0 {
		runtime.print_string("; held by thread ")
		runtime.print_int(m.owner)
		runtime.print_string(" since ")
		runtime.print_caller_location(m.owner_loc)
	}
	runtime.print_string("\n")
	runtime.panic_contextless(what, loc)
}

@(private)
slot_of :: #force_inline proc "contextless" (tid: int) -> ^Wait_Slot {
	return &wait_slots[(u64(tid) * 0x9E3779B97F4A7C15 >> 58) % WAIT_SLOTS]
}

@(private)
acquired :: #force_inline proc "contextless" (m: ^Mutex, me: int, loc: runtime.Source_Code_Location) {
	sync.atomic_store_explicit(&m.owner, me, .Relaxed)
	m.owner_loc = loc
}

@(private)
check_held :: #force_inline proc "contextless" (m: ^Mutex, what: string, loc: runtime.Source_Code_Location) -> int {
	me := sync.current_thread_id()
	if sync.atomic_load_explicit(&m.owner, .Relaxed) != me {
		fail(what, m, loc)
	}
	return me
}

lock :: proc "contextless" (m: ^Mutex, loc := #caller_location) {
	me := sync.current_thread_id()
	if sync.atomic_load_explicit(&m.owner, .Relaxed) == me do fail("lock of a mutex this thread already holds", m, loc)
	if !sync.mutex_try_lock(&m.impl) {
		s := slot_of(me)
		s.loc = loc
		sync.atomic_store_explicit(&s.m, m, .Relaxed)
		sync.atomic_store_explicit(&s.thread, me, .Release)
		holder := m.owner_loc
		start := time.tick_now()
		sync.mutex_lock(&m.impl)
		sync.atomic_store_explicit(&s.m, nil, .Relaxed)
		if waited := time.tick_since(start); waited > UI_LOCK_WAIT_REPORT && on_ui_thread() do report_ui_wait(waited, loc, holder)
	}
	acquired(m, me, loc)
}

// A UI-thread lock wait longer than this is printed with the lock site and where the holder took it:
// a worker holding a lock the UI needs across slow work drops frames.
UI_LOCK_WAIT_REPORT :: 16 * time.Millisecond

@(private)
report_ui_wait :: proc "contextless" (waited: time.Duration, loc, holder: runtime.Source_Code_Location) {
	runtime.print_string("locks: UI thread waited ")
	runtime.print_int(int(waited / time.Millisecond))
	runtime.print_string(" ms for the lock at ")
	runtime.print_caller_location(loc)
	runtime.print_string(", held since ")
	runtime.print_caller_location(holder)
	runtime.print_string("\n")
}

try_lock :: proc "contextless" (m: ^Mutex, loc := #caller_location) -> bool {
	me := sync.current_thread_id()
	if sync.atomic_load_explicit(&m.owner, .Relaxed) == me do fail("try_lock of a mutex this thread already holds", m, loc)
	if !sync.mutex_try_lock(&m.impl) do return false
	acquired(m, me, loc)
	return true
}

unlock :: proc "contextless" (m: ^Mutex, loc := #caller_location) {
	check_held(m, "unlock of a mutex this thread does not hold (was its struct overwritten or copied while locked?)", loc)
	sync.atomic_store_explicit(&m.owner, 0, .Relaxed)
	sync.mutex_unlock(&m.impl)
}

// Scoped lock: `locks.guard(&x.mu)` holds it until the end of the enclosing scope.
@(deferred_in = unlock)
guard :: proc "contextless" (m: ^Mutex, loc := #caller_location) -> bool {
	lock(m, loc)
	return true
}

cond_wait :: proc(c: ^Cond, m: ^Mutex, loc := #caller_location) {
	me := check_held(m, "cond_wait on a mutex this thread does not hold", loc)
	may_block("untimed cond_wait", loc)
	sync.atomic_store_explicit(&m.owner, 0, .Relaxed)
	sync.cond_wait(c, &m.impl)
	acquired(m, me, loc)
}

cond_wait_with_timeout :: proc "contextless" (c: ^Cond, m: ^Mutex, duration: time.Duration, loc := #caller_location) -> bool {
	me := check_held(m, "cond_wait_with_timeout on a mutex this thread does not hold", loc)
	sync.atomic_store_explicit(&m.owner, 0, .Relaxed)
	ok := sync.cond_wait_with_timeout(c, &m.impl, duration)
	acquired(m, me, loc)
	return ok
}

cond_signal :: sync.cond_signal
cond_broadcast :: sync.cond_broadcast

@(private)
ui_thread: int

// set_ui_thread names the calling thread as the UI thread. From then on, in debug builds, every call
// that can wait on the network or on a network thread (socket I/O, dialing, untimed condition waits,
// joining network threads) panics when made on it, so a slow or silent peer can never freeze the
// window. Such work belongs on a worker, with the UI polling for its result.
set_ui_thread :: proc "contextless" () {
	sync.atomic_store(&ui_thread, sync.current_thread_id())
}

clear_ui_thread :: proc "contextless" () {
	sync.atomic_store(&ui_thread, 0)
}

on_ui_thread :: proc "contextless" () -> bool {
	t := sync.atomic_load_explicit(&ui_thread, .Relaxed)
	return t != 0 && t == sync.current_thread_id()
}

// may_block marks a call that can wait indefinitely on the network or another thread.
may_block :: proc(what: string, loc := #caller_location) {
	when ODIN_DEBUG {
		if !on_ui_thread() do return
		fmt.eprintfln("locks: %s on the UI thread at %v", what, loc)
		bt := trace.capture()
		if frames, err := trace.resolve(bt, context.temp_allocator); err == nil do trace.print(frames)
		panic(what, loc)
	}
}

// join waits for a thread that may be blocked on the network, then destroys it.
join :: proc(t: ^thread.Thread, loc := #caller_location) {
	may_block("thread join", loc)
	thread.join(t)
	thread.destroy(t)
}

Wait_Info :: struct {
	waiting:   bool,
	wait_loc:  runtime.Source_Code_Location,
	owner:     int,
	owner_loc: runtime.Source_Code_Location,
}

// waiting_on reports the lock thread `tid` is blocked on, if any, and who holds it. Meant for a
// watchdog looking at a thread that has stopped making progress; the fields are read without
// synchronization, which is sound only because a stuck holder is not writing them.
waiting_on :: proc "contextless" (tid: int) -> (w: Wait_Info) {
	s := slot_of(tid)
	if sync.atomic_load_explicit(&s.thread, .Acquire) != tid do return
	m := sync.atomic_load_explicit(&s.m, .Relaxed)
	if m == nil do return
	return {waiting = true, wait_loc = s.loc, owner = sync.atomic_load_explicit(&m.owner, .Relaxed), owner_loc = m.owner_loc}
}
