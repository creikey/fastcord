package tls

import "core:bytes"
import "core:log"
import "core:os"
import "core:strconv"
import "core:testing"
import "core:time"

import "fc:netio"

// Interop against a local `openssl s_server` (see the report / README for the
// script). Gated on FASTCORD_INTEROP_PORT; FASTCORD_INTEROP_EXPECT is the text
// the server is expected to send back after our "ping\n".
@(test)
interop_openssl :: proc(t: ^testing.T) {
	port_s := os.get_env("FASTCORD_INTEROP_PORT", context.temp_allocator)
	if port_s == "" do return
	expect_s := os.get_env("FASTCORD_INTEROP_EXPECT", context.temp_allocator)
	port, _ := strconv.parse_int(port_s)
	tcp, err := netio.dial_tcp("127.0.0.1", port)
	if !testing.expect_value(t, err, netio.Error.None) do return
	netio.tcp_set_timeout(tcp, 10 * time.Second)
	under := netio.tcp_stream(tcp)
	s, terr := connect(under, {alpn = {"http/1.1"}, server_name = "localhost", insecure_skip_verify = true})
	if terr != .None {
		testing.expectf(t, false, "connect: %v / %v", terr, last_error())
		netio.close(under)
		return
	}
	defer close(s)
	log.infof("interop: suite=%04x group=%04x alpn=%q", negotiated_suite(s), negotiated_group(s), negotiated_alpn(s))
	testing.expect_value(t, write(s, transmute([]byte)string("ping\n")), Error.None)
	buf: [256]byte
	n := 0
	for n < len(buf) {
		got, e := read(s, buf[n:])
		if e != .None {
			log.infof("read ended: %v", e)
			break
		}
		n += got
		if expect_s != "" && bytes.contains(buf[:n], transmute([]byte)expect_s) do break
	}
	log.infof("interop: got %q", string(buf[:n]))
	if expect_s != "" do testing.expectf(t, bytes.contains(buf[:n], transmute([]byte)expect_s), "missing %q", expect_s)
	testing.expect_value(t, write(s, transmute([]byte)string("after\n")), Error.None)
	time.sleep(200 * time.Millisecond)
}
