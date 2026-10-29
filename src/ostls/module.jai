// The TLS of the official client's native updater (updater.node: reqwest + hyper), for the requests it makes.
// On macOS and Windows that is the OS's own library, configured as Rust's native-tls 0.2 configures it, so the
// ClientHello is the OS library's by construction: SecureTransport on macOS (security-framework), SChannel on
// Windows (schannel-rs), with certificates checked the way native-tls checks them. The Linux updater links
// rustls 0.23 (hyper-rustls) instead, which src/tls's BoringSSL imitates (tls.Config.rustls), offering h2.
// Everything else in fastcord speaks Chrome's TLS (src/tls).
//
//   s, err, h2 := ostls.connect(netio.tcp_stream(tcp), "updates.discord.com");
//   ... HTTP/2 when h2, else HTTP/1.1, with netio.read / netio.write on s ...
//   netio.close(s); // closes tcp too; like dropping a native-tls stream, it sends no close_notify (rustls: does)
#import "Basic";
netio :: #import "netio";

Error :: enum u8 {
	None;
	Unavailable; // the OS library could not be set up
	Handshake;   // the handshake failed, or the stream underneath did
	Untrusted;   // the certificate is not trusted for the name
}

// connect runs the handshake for host (SNI and the name the certificate must be valid for) on s, which the
// returned stream owns from then on; on failure s is closed. h2: the server picked HTTP/2 (ALPN, Linux only).
connect :: (s: netio.Stream, host: string) -> netio.Stream, Error, h2: bool {
	#if OS == .LINUX {
		st, err, h2 := rustls_connect(s, host);
		return st, err, h2;
	} else {
		ss := New(Session);
		ss.inner = s;
		err := os_connect(ss, host);
		if err != .None {
			session_close(ss);
			return .{}, err, false;
		}
		return .{data = ss, read = session_read, write = session_write, close = session_close, shutdown = session_shutdown, set_timeout = session_set_timeout}, .None, false;
	}
}

#scope_module

#if OS == .LINUX #load "linux.jai";
else {

READ_CHUNK :: 16 * 1024;

// in_buf: what a read of the stream underneath brought beyond what the library asked for (SecureTransport
// takes bytes in its own sizes); next is the first unread byte.
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
else #load "windows.jai";
}
