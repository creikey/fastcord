package tls

import "core:log"
import "core:os"
import "core:testing"
import "core:time"

import "fc:netio"

// Live tests reach public hosts (no Discord account); run with FASTCORD_LIVE=1.
@(private = "file")
live :: proc() -> bool {
	return os.get_env("FASTCORD_LIVE", context.temp_allocator) == "1"
}

@(private = "file")
dial :: proc(host: string, alpn: []string) -> (Error, ^Session) {
	tcp, err := netio.dial_tcp(host, 443)
	if err != .None do return .Io, nil
	netio.tcp_set_timeout(tcp, 10 * time.Second)
	under := netio.tcp_stream(tcp)
	s, terr := connect(under, {alpn = alpn, server_name = host})
	if terr != .None {
		netio.close(under)
		return last_error(), nil
	}
	return .None, s
}

// Every certificate failure must stop the connection; the good hosts must connect and resume.
@(test)
live_certificates :: proc(t: ^testing.T) {
	if !live() do return
	for host in ([]string{"expired.badssl.com", "wrong.host.badssl.com", "self-signed.badssl.com", "untrusted-root.badssl.com"}) {
		e, s := dial(host, {"http/1.1"})
		testing.expectf(t, s == nil && e == .Untrusted_Certificate, "%s: %v", host, e)
		if s != nil do close(s)
	}
	for host, i in ([]string{"badssl.com", "discord.com", "discord.com"}) {
		e, s := dial(host, {"h2", "http/1.1"})
		if !testing.expectf(t, e == .None, "%s: %v", host, e) do continue
		log.infof("%s: suite=%04x group=%04x alpn=%q resumed=%v", host, negotiated_suite(s), negotiated_group(s), negotiated_alpn(s), resumed(s))
		if i == 2 do testing.expect(t, resumed(s), "second discord.com connection did not resume")
		// TLS 1.3 tickets follow the handshake; an h2 server's SETTINGS frame carries them in.
		buf: [64]byte
		if i > 0 do read(s, buf[:])
		close(s)
	}
}
