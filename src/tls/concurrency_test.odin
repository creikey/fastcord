package tls

import "core:crypto"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "fc:netio"

// Test_Pipe is one direction of a blocking in-memory byte pipe.
@(private = "file")
Test_Pipe :: struct {
	mu:     sync.Mutex,
	cond:   sync.Cond,
	buf:    [dynamic]byte,
	closed: bool,
}

@(private = "file")
Test_End :: struct {
	rx, tx: ^Test_Pipe,
}

@(private = "file")
end_read :: proc(data: rawptr, dst: []byte) -> (int, netio.Error) {
	e := cast(^Test_End)data
	p := e.rx
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	for len(p.buf) == 0 && !p.closed do sync.cond_wait(&p.cond, &p.mu)
	if len(p.buf) == 0 do return 0, .Closed
	n := copy(dst, p.buf[:])
	remove_range(&p.buf, 0, n)
	return n, .None
}

@(private = "file")
end_write :: proc(data: rawptr, src: []byte) -> netio.Error {
	e := cast(^Test_End)data
	p := e.tx
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	if p.closed do return .Closed
	append(&p.buf, ..src)
	sync.cond_broadcast(&p.cond)
	return .None
}

@(private = "file")
end_close :: proc(data: rawptr) {
	e := cast(^Test_End)data
	for p in ([]^Test_Pipe{e.rx, e.tx}) {
		sync.mutex_lock(&p.mu)
		p.closed = true
		sync.cond_broadcast(&p.cond)
		sync.mutex_unlock(&p.mu)
	}
}

// keyed_session builds a post-handshake Session directly from traffic secrets.
@(private = "file")
keyed_session :: proc(end: ^Test_End, rd_secret, wr_secret: []byte) -> ^Session {
	s := new(Session)
	s.allocator = context.allocator
	s.under = netio.Stream{data = end, read = end_read, write = end_write, close = end_close, shutdown = end_close}
	s.suite = SUITES[0]
	s.handshake_done = true
	set_keys(&s.rd, s.suite, rd_secret)
	set_keys(&s.wr, s.suite, wr_secret)
	return s
}

MSG_COUNT :: 400
MSG_LEN :: 3000

@(private = "file")
Side :: struct {
	s:          ^Session,
	peer_rekey: bool, // writer periodically calls key_update(request_peer = true)
	got_bytes:  int,
	bad:        bool,
}

// The byte at stream offset i is byte(i * 7 + i >> 11), so readers can check order.
@(private = "file")
writer_proc :: proc(side: ^Side) {
	buf: [MSG_LEN]byte
	off := 0
	for m in 0 ..< MSG_COUNT {
		for i in 0 ..< MSG_LEN do buf[i] = byte((off + i) * 7 + (off + i) >> 11)
		off += MSG_LEN
		if write(side.s, buf[:]) != .None {
			side.bad = true
			return
		}
		if side.peer_rekey && m % 37 == 0 && key_update(side.s, true) != .None {
			side.bad = true
			return
		}
	}
}

@(private = "file")
reader_proc :: proc(side: ^Side) {
	buf: [5000]byte
	for side.got_bytes < MSG_COUNT * MSG_LEN {
		n, e := read(side.s, buf[:])
		if e != .None {
			side.bad = true
			return
		}
		for i in 0 ..< n {
			o := side.got_bytes + i
			if buf[i] != byte(o * 7 + o >> 11) do side.bad = true
		}
		side.got_bytes += n
	}
}

// Both ends write and read concurrently from separate threads while one side
// keeps forcing KeyUpdates with update_requested, so the other side's reader
// must answer under the write lock while its writer is busy.
@(test)
concurrent_read_write_with_key_updates :: proc(t: ^testing.T) {
	ab, ba: Test_Pipe
	defer delete(ab.buf)
	defer delete(ba.buf)
	ea := Test_End{rx = &ba, tx = &ab}
	eb := Test_End{rx = &ab, tx = &ba}
	sa, sb: [32]byte
	crypto.rand_bytes(sa[:])
	crypto.rand_bytes(sb[:])
	a := keyed_session(&ea, sb[:], sa[:])
	b := keyed_session(&eb, sa[:], sb[:])

	side_a := Side{s = a}
	side_b := Side{s = b, peer_rekey = true}
	threads := [?]^thread.Thread {
		thread.create_and_start_with_poly_data(&side_a, writer_proc),
		thread.create_and_start_with_poly_data(&side_a, reader_proc),
		thread.create_and_start_with_poly_data(&side_b, writer_proc),
		thread.create_and_start_with_poly_data(&side_b, reader_proc),
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect(t, !side_a.bad && !side_b.bad, "stream corrupted or failed")
	testing.expect_value(t, side_a.got_bytes, MSG_COUNT * MSG_LEN)
	testing.expect_value(t, side_b.got_bytes, MSG_COUNT * MSG_LEN)
	// a rotated its write keys once per request from b.
	testing.expect(t, a.wr.secret != sa_secret_copy(sa[:]), "a never rotated its keys")
	close(a)
	close(b)
}

@(private = "file")
sa_secret_copy :: proc(s: []byte) -> (out: [MAX_HASH]byte) {
	copy(out[:], s)
	return
}

@(private = "file")
Blocked_Reader :: struct {
	s:   ^Session,
	err: Error,
}

// shutdown wakes a reader blocked inside TLS (h2_close relies on this).
@(test)
shutdown_wakes_blocked_reader :: proc(t: ^testing.T) {
	ab, ba: Test_Pipe
	defer delete(ab.buf)
	defer delete(ba.buf)
	ea := Test_End{rx = &ba, tx = &ab}
	secret: [32]byte
	a := keyed_session(&ea, secret[:], secret[:])
	br := Blocked_Reader{s = a}
	th := thread.create_and_start_with_poly_data(&br, proc(br: ^Blocked_Reader) {
		buf: [64]byte
		_, br.err = read(br.s, buf[:])
	})
	time.sleep(50 * time.Millisecond)
	netio.shutdown(stream(a))
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, br.err, Error.Closed)
	testing.expect_value(t, write(a, {1, 2, 3}), Error.Closed)
	testing.expect_value(t, get_failed(a), Error.None) // shutdown is not a failure
	close(a)
}
