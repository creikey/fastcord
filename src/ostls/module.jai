// TLS through the OS's own library, configured as Rust's native-tls 0.2 configures it, for the requests the
// official client's native updater (updater.node: reqwest + hyper-tls + native-tls) makes. Its ClientHello is
// then the OS library's by construction: SecureTransport on macOS (security-framework), SChannel on Windows
// (schannel-rs), the system libssl on Linux (rust-openssl, opened with dlopen). Certificates are checked the
// way native-tls checks them. Everything else in fastcord speaks Chrome's TLS (src/tls).
//
//   s, err := ostls.connect(netio.tcp_stream(tcp), "updates.discord.com");
//   ... netio.read / netio.write on s ...
//   netio.close(s); // closes tcp too; like dropping a native-tls stream, it sends no close_notify
#import "Basic";
netio :: #import "netio";

Error :: enum u8 {
	None;
	Unavailable; // the OS library could not be loaded (Linux without libssl) or set up
	Handshake;   // the handshake failed, or the stream underneath did
	Untrusted;   // the certificate is not trusted for the name
}

// connect runs the handshake for host (SNI and the name the certificate must be valid for) on s, which the
// returned stream owns from then on; on failure s is closed.
connect :: (s: netio.Stream, host: string) -> netio.Stream, Error {
	ss := New(Session);
	ss.inner = s;
	err := os_connect(ss, host);
	if err != .None {
		session_close(ss);
		return .{}, err;
	}
	return .{data = ss, read = session_read, write = session_write, close = session_close, shutdown = session_shutdown, set_timeout = session_set_timeout}, .None;
}

#scope_module

READ_CHUNK :: 16 * 1024;

// in_buf: what a read of the stream underneath brought beyond what the library asked for (SecureTransport and
// libssl take bytes in their own sizes); next is the first unread byte.
In_Buffer :: struct {
	data: [READ_CHUNK]u8;
	next, end: int;
}

// fill_from reads once from s (blocking) when b is empty; false on EOF or error.
fill_from :: (b: *In_Buffer, s: netio.Stream) -> bool {
	if b.next < b.end return true;
	n, err := netio.read(s, b.data);
	if err != .None || n <= 0 return false;
	b.next, b.end = 0, n;
	return true;
}

take :: (b: *In_Buffer, dst: *u8, want: int) -> int {
	n := min(want, b.end - b.next);
	memcpy(dst, b.data.data + b.next, n);
	b.next += n;
	return n;
}

session_write :: (data: *void, src: []u8) -> netio.Error {
	ss := cast(*Session) data;
	if !os_write(ss, src) return .Io;
	return .None;
}

session_read :: (data: *void, dst: []u8) -> int, netio.Error {
	ss := cast(*Session) data;
	n, closed := os_read(ss, dst);
	if n > 0 return n, .None;
	return 0, ifx closed then .Closed else .Io;
}

session_close :: (data: *void) {
	ss := cast(*Session) data;
	os_free(ss);
	netio.close(ss.inner);
	free(ss);
}

session_shutdown :: (data: *void) { netio.shutdown((cast(*Session) data).inner); }
session_set_timeout :: (data: *void, ms: s64) { netio.set_timeout((cast(*Session) data).inner, ms); }

#if OS == .MACOS #load "darwin.jai";
else #if OS == .WINDOWS #load "windows.jai";
else #if OS == .LINUX #load "linux.jai";
