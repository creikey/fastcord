package tls

import "core:testing"
import "core:thread"
import "core:time"

import "fc:netio"

@(test)
session_roundtrip :: proc(t: ^testing.T) {
	lb: Loopback
	s, err := loopback_connect(&lb, {alpn = {"h2", "http/1.1"}, server_name = "localhost", insecure_skip_verify = true})
	defer loopback_destroy(&lb)
	if !testing.expect_value(t, err, netio.Error.None) do return
	defer close(s)
	testing.expect_value(t, lb.server_err, Error.None)
	testing.expect_value(t, negotiated_alpn(s), "h2")
	testing.expect_value(t, negotiated_group(s), u16(0x11ec))
	testing.expect_value(t, write(s, transmute([]byte)string("ping")), Error.None)
	buf: [4]byte
	n, rerr := read(lb.server, buf[:])
	testing.expect_value(t, rerr, Error.None)
	testing.expect_value(t, string(buf[:n]), "ping")
}

@(test)
session_rejects_untrusted_certificate :: proc(t: ^testing.T) {
	lb: Loopback
	s, err := loopback_connect(&lb, {server_name = "localhost"})
	defer loopback_destroy(&lb)
	testing.expect(t, s == nil)
	testing.expect_value(t, err, netio.Error.Tls)
	testing.expect_value(t, last_error(), Error.Untrusted_Certificate)
}

@(test)
session_rejects_garbage_and_eof :: proc(t: ^testing.T) {
	for reply in ([]string{"HTTP/1.1 400 Bad Request\r\n\r\n", ""}) {
		ab, ba: Test_Pipe
		append(&ba.buf, ..transmute([]byte)reply)
		ba.closed = true
		e := Test_End{rx = &ba, tx = &ab}
		s, err := connect(pipe_stream(&e), {server_name = "localhost"})
		testing.expect(t, s == nil)
		testing.expect_value(t, err, netio.Error.Tls if reply != "" else netio.Error.Closed)
		delete(ab.buf)
		delete(ba.buf)
	}
	_, err := connect({}, {server_name = ""})
	testing.expect_value(t, err, netio.Error.Tls)
	testing.expect_value(t, last_error(), Error.Internal)
}

// One thread writes and one reads on each side at once, with the writers rotating keys as they go.
@(test)
session_concurrent_read_write_with_key_updates :: proc(t: ^testing.T) {
	lb: Loopback
	s, err := loopback_connect(&lb, {server_name = "localhost", insecure_skip_verify = true})
	defer loopback_destroy(&lb)
	if !testing.expect_value(t, err, netio.Error.None) do return
	defer close(s)
	MSGS :: 400
	SIZE :: 3000
	Job :: struct {
		s:     ^Session,
		write: bool,
		ok:    bool,
	}
	jobs := [4]Job{{s, true, false}, {lb.server, false, false}, {lb.server, true, false}, {s, false, false}}
	run :: proc(j: ^Job) {
		buf: [SIZE]byte
		o := 0
		j.ok = true
		for m in 0 ..< MSGS {
			if j.write {
				for &b in buf {
					b = byte(o * 7 + o >> 11)
					o += 1
				}
				if m % 37 == 36 && key_update(j.s) != .None do j.ok = false
				if write(j.s, buf[:]) != .None do j.ok = false
				continue
			}
			for got := 0; got < SIZE && j.ok; {
				n, e := read(j.s, buf[got:])
				if e != .None do j.ok = false
				for b in buf[got:got + n] {
					if b != byte(o * 7 + o >> 11) do j.ok = false
					o += 1
				}
				got += n
			}
		}
	}
	threads: [4]^thread.Thread
	for &j, i in jobs do threads[i] = thread.create_and_start_with_poly_data(&j, run)
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	for j in jobs do testing.expect(t, j.ok)
}

@(test)
session_shutdown_wakes_blocked_reader :: proc(t: ^testing.T) {
	lb: Loopback
	s, err := loopback_connect(&lb, {server_name = "localhost", insecure_skip_verify = true})
	defer loopback_destroy(&lb)
	if !testing.expect_value(t, err, netio.Error.None) do return
	defer close(s)
	Res :: struct {
		s:   ^Session,
		err: Error,
	}
	r := Res{s = s}
	th := thread.create_and_start_with_poly_data(&r, proc(r: ^Res) {
		buf: [16]byte
		_, r.err = read(r.s, buf[:])
	})
	time.sleep(50 * time.Millisecond)
	shutdown(s)
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, r.err, Error.Closed)
	testing.expect_value(t, write(s, {1}), Error.Closed)
}
