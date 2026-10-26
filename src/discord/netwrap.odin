package discord

import "fc:netio"
import "fc:tls"

// Tls_Stream wraps a TLS session so netio.shutdown reaches the TCP socket
// underneath (waking a reader blocked inside TLS), which h2_close and the
// gateway's close path rely on.
@(private)
Tls_Stream :: struct {
	sess: ^tls.Session,
	tcp:  netio.Stream,
}

@(private)
tls_wrap_read :: proc(data: rawptr, dst: []byte) -> (int, netio.Error) {
	w := cast(^Tls_Stream)data
	s := tls.stream(w.sess)
	return netio.read(s, dst)
}

@(private)
tls_wrap_write :: proc(data: rawptr, src: []byte) -> netio.Error {
	w := cast(^Tls_Stream)data
	return netio.write(tls.stream(w.sess), src)
}

@(private)
tls_wrap_close :: proc(data: rawptr) {
	w := cast(^Tls_Stream)data
	tls.close(w.sess) // closes the TCP stream too
	free(w)
}

@(private)
tls_wrap_shutdown :: proc(data: rawptr) {
	w := cast(^Tls_Stream)data
	netio.shutdown(w.tcp)
}

// dial_tls_stream: TCP + Chrome TLS to host:443 with the given ALPN list.
dial_tls_stream :: proc(host: string, alpn: []string) -> (s: netio.Stream, negotiated: string, ok: bool) {
	tcp, derr := netio.dial_tcp(host, 443)
	if derr != .None do return {}, "", false
	under := netio.tcp_stream(tcp)
	sess, terr := tls.connect(under, tls.Config{alpn = alpn, server_name = host})
	if terr != .None {
		netio.close(under)
		return {}, "", false
	}
	w := new(Tls_Stream)
	w.sess = sess
	w.tcp = under
	return netio.Stream{data = w, read = tls_wrap_read, write = tls_wrap_write, close = tls_wrap_close, shutdown = tls_wrap_shutdown}, tls.negotiated_alpn(sess), true
}
