// The UDP a QUIC connection needs: a socket bound to an ephemeral port, datagrams to and from one peer,
// and receive timeouts. Jai's Socket module, behind small procedures so its names stay in this file.

#scope_module

Udp_Socket :: Socket;
INVALID_UDP_SOCKET :: INVALID_SOCKET;

// Udp_Addr is a sockaddr_in or sockaddr_in6.
Udp_Addr :: struct {
	bytes: [128]u8 #align 8;
	len: u32;
}

// udp_resolve returns host's first IPv4 address, else its first IPv6 one, with port.
udp_resolve :: (host: string, port: int) -> Udp_Addr, bool {
	locks.may_block("DNS lookup");
	hints: addrinfo;
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = .DGRAM;
	res: *addrinfo;
	a: Udp_Addr;
	if getaddrinfo(temp_c_string(host), temp_c_string(tprint("%", port)), *hints, *res) != 0 return a, false;
	defer freeaddrinfo(res);
	ai: *addrinfo;
	p := res;
	while p {
		if p.ai_family == AF_INET { ai = p; break; }
		if p.ai_family == AF_INET6 && !ai ai = p;
		p = p.ai_next;
	}
	if !ai || ai.ai_addrlen > a.bytes.count return a, false;
	memcpy(a.bytes.data, ai.ai_addr, xx ai.ai_addrlen);
	a.len = xx ai.ai_addrlen;
	return a, true;
}

udp_is_ip4 :: (a: Udp_Addr) -> bool { return (cast(*sockaddr) a.bytes.data).sa_family == AF_INET; }

udp_port :: (a: Udp_Addr) -> int { return ((cast(int) a.bytes[2]) << 8) | a.bytes[3]; } // sin_port / sin6_port, big-endian

// udp_ip returns the address's 4 or 16 bytes, in network order.
udp_ip :: (a: *Udp_Addr) -> []u8 {
	if udp_is_ip4(a) return .{4, cast(*u8) *(cast(*sockaddr_in) a.bytes.data).sin_addr};
	return .{16, cast(*u8) *(cast(*sockaddr_in6) a.bytes.data).sin6_addr};
}

// udp_local is the any (or loopback) address of a's family, at port.
udp_local :: (a: Udp_Addr, port: int, loopback: bool) -> Udp_Addr {
	l := a;
	ip := udp_ip(*l);
	memset(ip.data, 0, ip.count);
	if loopback && ip.count == 4 ip[0], ip[3] = 127, 1;
	else if loopback ip[15] = 1;
	l.bytes[2], l.bytes[3] = xx (port >> 8), xx port;
	return l;
}

same_addr :: (a: Udp_Addr, b: Udp_Addr) -> bool {
	ia, ib := udp_ip(*a), udp_ip(*b);
	return a.len == b.len && ia.count == ib.count && udp_port(a) == udp_port(b) && memcmp(ia.data, ib.data, ia.count) == 0;
}

// udp_open makes a socket of family's kind and, with bind, binds it to an ephemeral port, which it returns.
udp_open :: (family: Udp_Addr, bound_port := false) -> Udp_Socket, port: int, ok: bool {
	s := socket(xx (cast(*sockaddr) family.bytes.data).sa_family, .DGRAM, .UDP);
	if s == INVALID_SOCKET return s, 0, false;
	if !bound_port return s, 0, true;
	any := udp_local(family, 0, loopback = false);
	bound: Udp_Addr;
	bound.len = bound.bytes.count;
	if bind(s, cast(*sockaddr) any.bytes.data, any.len) != 0 || getsockname(s, cast(*sockaddr) bound.bytes.data, *bound.len) != 0 {
		udp_close(*s);
		return s, 0, false;
	}
	return s, udp_port(bound), true;
}

udp_close :: (s: *Udp_Socket) { close_and_reset(s); }

udp_send :: (s: Udp_Socket, b: []u8, to: Udp_Addr) {
	sendto(s, b.data, xx b.count, 0, cast(*sockaddr) to.bytes.data, to.len);
}

// udp_recv waits up to timeout_us for one datagram; n < 0 on timeout or error.
udp_recv :: (s: Udp_Socket, b: []u8, timeout_us: s64) -> n: int, from: Udp_Addr {
	#if OS == .WINDOWS {
		v: u32 = xx (timeout_us / 1000);
	} else {
		v: timeval;
		v.tv_sec = xx (timeout_us / 1_000_000);
		v.tv_usec = xx (timeout_us % 1_000_000);
	}
	setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, xx *v, size_of(type_of(v)));
	from: Udp_Addr;
	from.len = from.bytes.count;
	n := recvfrom(s, b.data, xx b.count, 0, cast(*sockaddr) from.bytes.data, *from.len);
	return n, from;
}

#scope_file

#import "Socket";
#if OS != .WINDOWS #import "POSIX";
