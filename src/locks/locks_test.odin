package locks

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
test_lock_tracks_owner :: proc(t: ^testing.T) {
	m: Mutex
	lock(&m)
	testing.expect_value(t, m.owner, sync.current_thread_id())
	unlock(&m)
	testing.expect_value(t, m.owner, 0)
	{
		guard(&m)
		testing.expect(t, !try_lock_other_thread(&m))
	}
	testing.expect(t, try_lock_other_thread(&m))
}

@(private = "file")
try_lock_other_thread :: proc(m: ^Mutex) -> bool {
	Data :: struct {
		m:  ^Mutex,
		ok: bool,
	}
	d := Data{m = m}
	th := thread.create_and_start_with_poly_data(&d, proc(d: ^Data) {
		d.ok = try_lock(d.m)
		if d.ok do unlock(d.m)
	})
	thread.join(th)
	thread.destroy(th)
	return d.ok
}

@(test)
test_cond_timeout_reacquires :: proc(t: ^testing.T) {
	m: Mutex
	c: Cond
	lock(&m)
	cond_wait_with_timeout(&c, &m, time.Millisecond)
	testing.expect_value(t, m.owner, sync.current_thread_id())
	unlock(&m)
}

@(test)
test_waiting_on_reports_holder :: proc(t: ^testing.T) {
	Data :: struct {
		m:   Mutex,
		tid: int,
	}
	d: Data
	lock(&d.m)
	th := thread.create_and_start_with_poly_data(&d, proc(d: ^Data) {
		sync.atomic_store(&d.tid, sync.current_thread_id())
		lock(&d.m)
		unlock(&d.m)
	})
	w: Wait_Info
	for _ in 0 ..< 500 {
		if tid := sync.atomic_load(&d.tid); tid != 0 {
			w = waiting_on(tid)
			if w.waiting do break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, w.waiting)
	testing.expect_value(t, w.owner, sync.current_thread_id())
	unlock(&d.m)
	thread.join(th)
	thread.destroy(th)
}
