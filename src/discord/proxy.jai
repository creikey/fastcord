// Proxies, as Chromium uses them: the system's HTTPS or SOCKS proxy, or HTTPS_PROXY / ALL_PROXY from the
// environment (which win). Every connection dial_tls_stream makes (REST, gateway, media, login) goes
// through an HTTP CONNECT or SOCKS5 tunnel, with TLS unchanged inside it; QUIC is off while proxied, as
// a tunnel carries only TCP. Voice media (UDP) still goes direct. PAC files and Windows' system setting
// aren't read yet (TODO.md).

Proxy :: struct {
	kind: enum u8 { None; Http; Socks5; };
	host: string;
	port: int;
	user: string; // credentials from the URL (Basic for HTTP, username/password for SOCKS5)
	pass: string;
}

// The proxy in force, found once per process.
proxy_config :: () -> Proxy {
	locks.lock(*proxy_mu);
	defer locks.unlock(*proxy_mu);
	if !proxy_found {
		proxy_found = true;
		push_allocator(context.default_allocator);
		for string.["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"] {
			p, ok := parse_proxy_url(proxy_getenv(it));
			if ok { proxy = p; break; }
		}
		#if OS == .MACOS if proxy.kind == .None proxy = macos_system_proxy();
	}
	return proxy;
}

// scheme://[user:pass@]host:port, scheme http (CONNECT) or socks5 / socks5h / socks; a bare host:port is HTTP.
// The result's strings are in the context allocator.
parse_proxy_url :: (url: string) -> Proxy, bool {
	s := trim(url);
	if !s return .{}, false;
	p: Proxy;
	p.kind = .Http;
	i := find_index_from_left(s, "://");
	if i >= 0 {
		scheme := to_lower_copy(slice(s, 0, i),, temp);
		if scheme == "socks5" || scheme == "socks5h" || scheme == "socks" p.kind = .Socks5;
		else if scheme != "http" return .{}, false; // https:// (TLS to the proxy) isn't supported
		advance(*s, i + 3);
	}
	j := find_index_from_left(s, #char "/");
	if j >= 0 s.count = j;
	at := find_index_from_right(s, #char "@");
	if at >= 0 {
		cred := slice(s, 0, at);
		advance(*s, at + 1);
		c := find_index_from_left(cred, #char ":");
		p.user = copy_string(ifx c >= 0 then slice(cred, 0, c) else cred);
		p.pass = copy_string(ifx c >= 0 then slice(cred, c + 1, cred.count - c - 1) else "");
	}
	colon := find_index_from_right(s, #char ":");
	if colon <= 0 || s[0] == #char "[" return .{}, false; // a port is required; IPv6 literals unsupported
	port, ok := string_to_int(slice(s, colon + 1, s.count - colon - 1));
	if !ok || port <= 0 || port > 65535 return .{}, false;
	p.host = copy_string(slice(s, 0, colon));
	p.port = port;
	return p, true;
}

// proxy_tunnel opens a stream to host:port through the proxy (the TCP dial's I/O timeout applies).
proxy_tunnel :: (p: Proxy, host: string, port: int) -> netio.Stream, bool {
	tcp, derr := netio.dial_tcp(p.host, p.port);
	if derr != .None return .{}, false;
	s := netio.tcp_stream(tcp);
	ok := ifx p.kind == .Socks5 then socks5_connect(s, p, host, port) else http_connect(s, p, host, port);
	if !ok netio.close(s);
	return s, ok;
}

#scope_file

proxy_mu: locks.Mutex;
proxy_found: bool;
proxy: Proxy;

// Chromium's CONNECT: the request line, Host, Proxy-Connection; the reply's status line must say 200.
http_connect :: (s: netio.Stream, p: Proxy, host: string, port: int) -> bool {
	sb: String_Builder;
	sb.allocator = temp;
	print_to_builder(*sb, "CONNECT %1:%2 HTTP/1.1\r\nHost: %1:%2\r\nProxy-Connection: keep-alive\r\n", host, port);
	if p.user print_to_builder(*sb, "Proxy-Authorization: Basic %\r\n", base64_encode(tprint("%:%", p.user, p.pass),, temp));
	append(*sb, "\r\n");
	if netio.write(s, cast([]u8) builder_to_string(*sb,, temp)) != .None return false;
	// read the reply up to its blank line, one byte at a time: nothing past it may be consumed, since
	// the TLS handshake follows on the same stream
	MAX :: 8192;
	head: [..]u8;
	head.allocator = temp;
	b: [1]u8;
	while head.count < MAX {
		n, err := netio.read(s, b);
		if err != .None || n != 1 return false;
		array_add(*head, b[0]);
		if head.count >= 4 && slice(cast(string) head, head.count - 4, 4) == "\r\n\r\n" break;
	}
	line := cast(string) head;
	return begins_with(line, "HTTP/1.") && line.count >= 12 && slice(line, 8, 4) == " 200";
}

// RFC 1928 / 1929: no auth (or username/password), CONNECT by domain name so the proxy resolves it.
socks5_connect :: (s: netio.Stream, p: Proxy, host: string, port: int) -> bool {
	read_n :: (s: netio.Stream, out: []u8) -> bool {
		got := 0;
		while got < out.count {
			n, err := netio.read(s, .{out.count - got, out.data + got});
			if err != .None || n <= 0 return false;
			got += n;
		}
		return true;
	}
	if host.count > 255 || p.user.count > 255 || p.pass.count > 255 return false;
	method: u8 = xx ifx p.user then 2 else 0;
	if netio.write(s, .[5, 1, method]) != .None return false;
	r: [2]u8;
	if !read_n(s, r) || r[0] != 5 || r[1] != method return false;
	if method == 2 {
		a: [..]u8;
		a.allocator = temp;
		array_add(*a, 1, cast(u8) p.user.count);
		array_add(*a, ..cast([]u8) p.user);
		array_add(*a, cast(u8) p.pass.count);
		array_add(*a, ..cast([]u8) p.pass);
		if netio.write(s, a) != .None || !read_n(s, r) || r[1] != 0 return false;
	}
	req: [..]u8;
	req.allocator = temp;
	array_add(*req, 5, 1, 0, 3, cast(u8) host.count);
	array_add(*req, ..cast([]u8) host);
	array_add(*req, cast(u8) (port >> 8), cast(u8) port);
	if netio.write(s, req) != .None return false;
	hdr: [4]u8;
	if !read_n(s, hdr) || hdr[0] != 5 || hdr[1] != 0 return false;
	// the bound address that follows, by its type: IPv4, a name, IPv6; then the port
	rest: int;
	if hdr[3] == {
	case 1; rest = 4;
	case 4; rest = 16;
	case 3;
		l: [1]u8;
		if !read_n(s, l) return false;
		rest = l[0];
	case; return false;
	}
	skip: [258]u8;
	return read_n(s, array_view(skip, 0, rest + 2));
}

proxy_getenv :: (name: string) -> string {
	p := proxy_libc_getenv(temp_c_string(name));
	return ifx p then to_string(p) else "";
}

#if OS == .WINDOWS {
	proxy_crt :: #system_library "msvcrt";
	proxy_libc_getenv :: (name: *u8) -> *u8 #foreign proxy_crt "getenv";
} else {
	proxy_libc :: #system_library "libc";
	proxy_libc_getenv :: (name: *u8) -> *u8 #foreign proxy_libc "getenv";
}

#if OS == .MACOS {
	// System Settings > Network > Proxies: Secure Web Proxy (HTTPS), else SOCKS.
	macos_system_proxy :: () -> Proxy {
		d := CFNetworkCopySystemProxySettings();
		if !d return .{};
		defer CFRelease(d);
		get :: (d: *void, enable: *void, host: *void, port: *void, kind: type_of(Proxy.kind)) -> Proxy {
			on: s32;
			n := CFDictionaryGetValue(d, enable);
			if !n || !CFNumberGetValue(n, 3, *on) || !on return .{};
			h := CFDictionaryGetValue(d, host);
			buf: [256]u8;
			if !h || !CFStringGetCString(h, buf.data, buf.count, 0x0800_0100) return .{};
			pn := CFDictionaryGetValue(d, port);
			pv: s32;
			if !pn || !CFNumberGetValue(pn, 3, *pv) || pv <= 0 || pv > 65535 return .{};
			return .{kind = kind, host = copy_string(to_string(buf.data)), port = pv};
		}
		p := get(d, kCFNetworkProxiesHTTPSEnable, kCFNetworkProxiesHTTPSProxy, kCFNetworkProxiesHTTPSPort, .Http);
		if p.kind == .None p = get(d, kCFNetworkProxiesSOCKSEnable, kCFNetworkProxiesSOCKSProxy, kCFNetworkProxiesSOCKSPort, .Socks5);
		return p;
	}
	CoreFoundation :: #system_library "CoreFoundation";
	CFNetwork :: #system_library "CFNetwork";
	CFNetworkCopySystemProxySettings :: () -> *void #foreign CFNetwork;
	CFRelease :: (cf: *void) #foreign CoreFoundation;
	CFDictionaryGetValue :: (d: *void, key: *void) -> *void #foreign CoreFoundation;
	CFNumberGetValue :: (n: *void, type: int, value: *void) -> bool #foreign CoreFoundation;
	CFStringGetCString :: (s: *void, buf: *u8, size: int, encoding: u32) -> bool #foreign CoreFoundation;
	kCFNetworkProxiesHTTPSEnable: *void #elsewhere CFNetwork;
	kCFNetworkProxiesHTTPSProxy: *void #elsewhere CFNetwork;
	kCFNetworkProxiesHTTPSPort: *void #elsewhere CFNetwork;
	kCFNetworkProxiesSOCKSEnable: *void #elsewhere CFNetwork;
	kCFNetworkProxiesSOCKSProxy: *void #elsewhere CFNetwork;
	kCFNetworkProxiesSOCKSPort: *void #elsewhere CFNetwork;
}
