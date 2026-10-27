// TCP / UDP sockets with IPv4 and IPv6 endpoints, over Jai's Socket module.
#import "Basic";
#import "fc";
S :: #import "Socket";
time :: #import "fc_time";

Address :: struct {
    kind: enum u8 { None; IP4_Address; IP6_Address; };
    union { ip4_address: [4]u8; ip6_address: [16]u8; }
}
IP4_Address :: [4]u8;
IP6_Address :: [16]u8;
Endpoint :: struct { address: Address; port: int; }
Address_Family :: enum { IP4; IP6; }
IP4_Any :: Address.{kind = .IP4_Address};
IP6_Any :: Address.{kind = .IP6_Address};
IP4_Loopback :: #run ip4(127, 0, 0, 1);
IP6_Loopback :: #run -> Address { a := Address.{kind = .IP6_Address}; a.ip6_address[15] = 1; return a; };
ip4 :: (a: u8, b: u8, c: u8, d: u8) -> Address { r := Address.{kind = .IP4_Address}; r.ip4_address = .[a, b, c, d]; return r; }

TCP_Socket :: S.Socket;
UDP_Socket :: S.Socket;
Error :: enum { None; Timeout; Refused; Resolve; Closed; Failed; }
TCP_Recv_Error :: Error;
TCP_Send_Error :: Error;
Socket_Option :: enum { TCP_Nodelay; Receive_Timeout; Send_Timeout; }
Shutdown_Manner :: enum { Receive; Send; Both; }

family_from_endpoint :: (ep: Endpoint) -> Address_Family { return ifx ep.address.kind == .IP6_Address then .IP6 else .IP4; }

parse_address :: (s: string) -> Address {
    a: Address;
    c := temp_c_string(s);
    if S.inet_pton(S.AF_INET, c, a.ip4_address.data) == 1 { a.kind = .IP4_Address; return a; }
    if S.inet_pton(S.AF_INET6, c, a.ip6_address.data) == 1 { a.kind = .IP6_Address; return a; }
    return .{};
}
resolve :: (host: string) -> ep4: Endpoint, ep6: Endpoint, Error {
    a := parse_address(host);
    if a.kind == .IP4_Address return .{a, 0}, .{}, .None;
    if a.kind == .IP6_Address return .{}, .{a, 0}, .None;
    hints: S.addrinfo;
    hints.ai_socktype = xx S.SOCK.STREAM;
    res: *S.addrinfo;
    if S.getaddrinfo(temp_c_string(host), null, *hints, *res) != 0 return .{}, .{}, .Resolve;
    defer S.freeaddrinfo(res);
    e4, e6: Endpoint;
    p := res;
    while p {
        if p.ai_family == S.AF_INET && e4.address.kind == .None {
            sa := cast(*S.sockaddr_in) p.ai_addr;
            e4.address.kind = .IP4_Address;
            memcpy(e4.address.ip4_address.data, *sa.sin_addr, 4);
        } else if p.ai_family == S.AF_INET6 && e6.address.kind == .None {
            sa := cast(*S.sockaddr_in6) p.ai_addr;
            e6.address.kind = .IP6_Address;
            memcpy(e6.address.ip6_address.data, *sa.sin6_addr, 16);
        }
        p = p.ai_next;
    }
    return e4, e6, ifx e4.address.kind == .None && e6.address.kind == .None then .Resolve else .None;
}
resolve_ip4 :: (host: string) -> Endpoint, Error { e4, _, err := resolve(host); return e4, ifx e4.address.kind == .None then .Resolve else err; }

Sockaddr :: struct { union { v4: S.sockaddr_in; v6: S.sockaddr_in6; } len: u32; }
to_sockaddr :: (ep: Endpoint) -> Sockaddr {
    r: Sockaddr;
    port := cast(u16) ep.port;
    nport := (port >> 8) | (port << 8);
    if ep.address.kind == .IP6_Address {
        r.v6.sin6_family = xx S.AF_INET6;
        r.v6.sin6_port = nport;
        memcpy(*r.v6.sin6_addr, ep.address.ip6_address.data, 16);
        r.len = size_of(S.sockaddr_in6);
    } else {
        r.v4.sin_family = xx S.AF_INET;
        r.v4.sin_port = nport;
        memcpy(*r.v4.sin_addr, ep.address.ip4_address.data, 4);
        r.len = size_of(S.sockaddr_in);
    }
    #if OS == .MACOS { if ep.address.kind == .IP6_Address r.v6.sin6_len = xx r.len; else r.v4.sin_len = xx r.len; }
    return r;
}
from_sockaddr :: (sa: *Sockaddr) -> Endpoint {
    ep: Endpoint;
    if sa.v4.sin_family == S.AF_INET6 {
        ep.address.kind = .IP6_Address;
        memcpy(ep.address.ip6_address.data, *sa.v6.sin6_addr, 16);
        p := sa.v6.sin6_port;
        ep.port = (p >> 8) | ((p & 0xFF) << 8);
    } else {
        ep.address.kind = .IP4_Address;
        memcpy(ep.address.ip4_address.data, *sa.v4.sin_addr, 4);
        p := sa.v4.sin_port;
        ep.port = (p >> 8) | ((p & 0xFF) << 8);
    }
    return ep;
}
af :: (f: Address_Family) -> s32 { return xx ifx f == .IP6 then S.AF_INET6 else S.AF_INET; }

dial_tcp :: (ep: Endpoint) -> TCP_Socket, Error {
    s := S.socket(af(family_from_endpoint(ep)), .STREAM, .TCP);
    if s == S.INVALID_SOCKET return s, .Failed;
    sa := to_sockaddr(ep);
    if S.connect(s, cast(*S.sockaddr) *sa, sa.len) != 0 { close(s); return S.INVALID_SOCKET, .Refused; }
    return s, .None;
}
dial_tcp_from_hostname_with_port_override :: (host: string, port: int) -> TCP_Socket, Error {
    e4, e6, err := resolve(host);
    if err != .None return S.INVALID_SOCKET, err;
    if e4.address.kind != .None { e4.port = port; s, e := dial_tcp(e4); if e == .None return s, e; }
    if e6.address.kind != .None { e6.port = port; s, e := dial_tcp(e6); return s, e; }
    return S.INVALID_SOCKET, .Refused;
}
listen_tcp :: (ep: Endpoint) -> TCP_Socket, Error {
    s := S.socket(af(family_from_endpoint(ep)), .STREAM, .TCP);
    sa := to_sockaddr(ep);
    if S.bind(s, cast(*S.sockaddr) *sa, sa.len) != 0 || S.listen(s, 16) != 0 { close(s); return S.INVALID_SOCKET, .Failed; }
    return s, .None;
}
accept_tcp :: (s: TCP_Socket) -> TCP_Socket, Endpoint, Error {
    sa: Sockaddr; n: S.socklen_t = size_of(Sockaddr);
    c := S.accept(s, cast(*S.sockaddr) *sa, *n);
    if c == S.INVALID_SOCKET return c, .{}, .Failed;
    return c, from_sockaddr(*sa), .None;
}
make_unbound_udp_socket :: (f: Address_Family) -> UDP_Socket, Error {
    s := S.socket(af(f), .DGRAM, .UDP);
    return s, ifx s == S.INVALID_SOCKET then .Failed else .None;
}
make_bound_udp_socket :: (a: Address, port: int) -> UDP_Socket, Error {
    s, err := make_unbound_udp_socket(ifx a.kind == .IP6_Address then .IP6 else .IP4);
    if err != .None return s, err;
    if bind(s, .{a, port}) != .None { close(s); return S.INVALID_SOCKET, .Failed; }
    return s, .None;
}
bind :: (s: UDP_Socket, ep: Endpoint) -> Error {
    sa := to_sockaddr(ep);
    return ifx S.bind(s, cast(*S.sockaddr) *sa, sa.len) == 0 then .None else .Failed;
}
bound_endpoint :: (s: S.Socket) -> Endpoint, Error {
    sa: Sockaddr; n: S.socklen_t = size_of(Sockaddr);
    if S.getsockname(s, cast(*S.sockaddr) *sa, *n) != 0 return .{}, .Failed;
    return from_sockaddr(*sa), .None;
}
close :: (s: S.Socket) { ss := s; S.close_and_reset(*ss); }
shutdown :: (s: S.Socket, m: Shutdown_Manner) { S.shutdown(s, ifx m == .Both then .RDWR else ifx m == .Send then .WR else .RD); }
set_option :: (s: S.Socket, o: Socket_Option, v: $T) -> Error {
    #if T == bool {
        one: s32 = xx v;
        S.setsockopt(s, xx S.IPPROTO.TCP, S.TCP_NODELAY, *one, size_of(s32));
    } else {
        tv: S.timeval;
        tv.tv_sec = xx (v / time.Second);
        tv.tv_usec = xx ((v % time.Second) / time.Microsecond);
        S.setsockopt(s, S.SOL_SOCKET, xx ifx o == .Receive_Timeout then S.SO_RCVTIMEO else S.SO_SNDTIMEO, *tv, size_of(S.timeval));
    }
    return .None;
}
would_block :: () -> bool { e := S.get_last_socket_error(); return e == 35 || e == 60; } // EAGAIN / ETIMEDOUT (SO_RCVTIMEO)
send_tcp :: (s: TCP_Socket, b: []u8) -> int, Error {
    n := S.send(s, b.data, xx b.count, .NOSIGNAL);
    if n < 0 return 0, ifx would_block() then .Timeout else .Closed;
    return n, .None;
}
recv_tcp :: (s: TCP_Socket, b: []u8) -> int, Error {
    n := S.recv(s, b.data, xx b.count, 0);
    if n < 0 return 0, ifx would_block() then .Timeout else .Closed;
    return n, .None;
}
send_udp :: (s: UDP_Socket, b: []u8, to: Endpoint) -> int, Error {
    sa := to_sockaddr(to);
    n := S.sendto(s, b.data, xx b.count, 0, cast(*S.sockaddr) *sa, sa.len);
    return ifx n < 0 then 0 else n, ifx n < 0 then .Failed else .None;
}
recv_udp :: (s: UDP_Socket, b: []u8) -> int, Endpoint, Error {
    sa: Sockaddr; n: S.socklen_t = size_of(Sockaddr);
    r := S.recvfrom(s, b.data, xx b.count, 0, cast(*S.sockaddr) *sa, *n);
    if r < 0 return 0, .{}, ifx would_block() then .Timeout else .Failed;
    return r, from_sockaddr(*sa), .None;
}
