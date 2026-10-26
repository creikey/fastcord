package discord

import "fc:netio"
import "fc:tls"

// dial_tls_stream: TCP + Chrome TLS to host:443 with the given ALPN list.
// tls.stream forwards shutdown to the socket, so h2_close / the gateway can
// wake a reader blocked inside TLS.
dial_tls_stream :: proc(host: string, alpn: []string) -> (s: netio.Stream, negotiated: string, ok: bool) {
	tcp, derr := netio.dial_tcp(host, 443)
	if derr != .None do return {}, "", false
	under := netio.tcp_stream(tcp)
	sess, terr := tls.connect(under, tls.Config{alpn = alpn, server_name = host})
	if terr != .None {
		netio.close(under)
		return {}, "", false
	}
	return tls.stream(sess), tls.negotiated_alpn(sess), true
}
