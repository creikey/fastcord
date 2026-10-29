// rustls 0.23 as reqwest 0.12 sets it up through hyper-rustls 0.27 (the ring provider, webpki-roots): src/tls's
// rustls profile, ALPN h2 then http/1.1, and certificates checked against the distro's roots as src/tls checks
// every other connection (trust_linux.jai; rustls's are webpki-roots' built-in copy of Mozilla's).
tls :: #import "tls";

rustls_connect :: (s: netio.Stream, host: string) -> netio.Stream, Error, h2: bool {
	t, _, err := tls.connect(s, .{server_name = host, alpn = RUSTLS_ALPN, rustls = true});
	if !t {
		netio.close(s);
		return .{}, ifx err == .Untrusted_Certificate || err == .Bad_Certificate then .Untrusted else .Handshake, false;
	}
	return tls.stream(t), .None, tls.negotiated_alpn(t) == "h2";
}

RUSTLS_ALPN :: string.["h2", "http/1.1"];
