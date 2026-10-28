// The OS certificate check against live bad certificates (badssl.com): jai build.jai - run
// src/tests/tls_verify.jai, then build/tls_verify.exe. Needs the internet, so no suite runs it.
#import "Basic";
netio :: #import "netio";
tls :: #import "tls";
#if OS == .WINDOWS msvcprt :: #library,system,no_dll,link_always "msvcprt";

main :: () {
	Case :: struct { host: string; ok: bool; }
	CASES :: Case.[
		.{"tls-v1-2.badssl.com", true},
		.{"discord.com", true},
		.{"wrong.host.badssl.com", false},
		.{"self-signed.badssl.com", false},
		.{"untrusted-root.badssl.com", false},
		.{"expired.badssl.com", false},
		.{"revoked.badssl.com", false},
	];
	failed := 0;
	for CASES {
		tcp, derr := netio.dial_tcp(it.host, 443);
		if derr != .None {
			print("SKIP: % unreachable\n", it.host);
			continue;
		}
		under := netio.tcp_stream(tcp);
		start := current_time_monotonic();
		session, _, err := tls.connect(under, .{alpn = .["http/1.1"], server_name = it.host});
		ms := to_milliseconds(current_time_monotonic() - start);
		if session tls.close(session);
		else netio.close(under);
		good := ifx it.ok then err == .None else err == .Untrusted_Certificate;
		print("%: % % (% ms)\n", ifx good then "ok" else "FAIL", it.host, err, ms);
		if !good failed += 1;
	}
	print("% failed\n", failed);
}
