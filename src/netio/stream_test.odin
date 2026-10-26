package netio

import "core:net"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
test_tcp_shutdown_wakes_reader :: proc(t: ^testing.T) {
	ep := net.Endpoint{address = net.IP4_Loopback, port = 0}
	l, lerr := net.listen_tcp(ep)
	testing.expect(t, lerr == nil)
	defer net.close(l)
	bound, _ := net.bound_endpoint(l)
	tcp, derr := dial_tcp("127.0.0.1", bound.port)
	testing.expect_value(t, derr, Error.None)
	peer, _, aerr := net.accept_tcp(l)
	testing.expect(t, aerr == nil)
	defer net.close(peer)
	s := tcp_stream(tcp)
	R :: struct {
		s:   Stream,
		err: Error,
	}
	r := R{s = s}
	th := thread.create_and_start_with_poly_data(&r, proc(r: ^R) {
		buf: [16]byte
		_, r.err = read(r.s, buf[:])
	})
	time.sleep(50 * time.Millisecond)
	shutdown(s)
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, r.err, Error.Closed)
	testing.expect_value(t, write(s, {1}), Error.Closed)
	close(s)
}
