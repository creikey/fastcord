Error :: enum {
	None;
	Io;
	Closed;
	Timeout;
	Protocol; // malformed peer data / protocol violation
	Too_Large; // exceeds a configured limit
	Bad_Request; // caller-supplied request is invalid
	Unsupported_Encoding;
	Decompress;
	Stream_Reset; // h2 RST_STREAM from peer (see Response.h2_error)
	Refused; // h2 REFUSED_STREAM or stream above GOAWAY last-stream-id: safe to retry
	Goaway; // connection is going away; no new streams
	Flow_Control;
	Handshake; // websocket upgrade rejected / invalid
	Out_Of_Memory;
}

Header :: struct {
	name, value: string;
}

Version :: enum u8 {
	Http1_0;
	Http1_1;
	Http2;
	Http3;
}

// Chrome request priorities (net::RequestPriority). The zero value is Medium,
// the priority Chrome gives fetch()/XHR; navigations are Highest.
Priority :: enum u8 {
	Medium;
	Highest;
	Low;
	Lowest;
	Idle;
	Throttled;
}

Request :: struct {
	method: string; // "GET"
	scheme: string; // "https" (h2 :scheme)
	authority: string; // "discord.com" (h2 :authority, h1 Host when no Host header given)
	path: string; // "/api/v9/users/@me"
	headers: []Header; // exact order/case; for h2 names must already be lowercase
	body: []u8;
	priority: Priority; // h2 HEADERS priority fields, h3 priority header
}

Response :: struct {
	version: Version;
	status: int;
	reason: string; // h1 only
	headers: [..]Header;
	trailers: [..]Header;
	body: [..]u8;
	h2_error: u32; // RST_STREAM / GOAWAY error code when the request failed
	allocator: Allocator;
}

response_destroy :: (r: *Response) {
	push_allocator(r.allocator);
	for h: r.headers {
		delete(h.name);
		delete(h.value);
	}
	for h: r.trailers {
		delete(h.name);
		delete(h.value);
	}
	delete(r.headers);
	delete(r.trailers);
	delete(r.body);
	if len(r.reason) > 0 { delete(r.reason); }
	r.* = .{};
}

// header_get returns the first header with a case-insensitive name match.
header_get :: (headers: []Header, name: string) -> string, bool {
	for h: headers {
		if strings.equal_fold(h.name, name) { return h.value, true; }
	}
	return "", false;
}

// header_has_token reports whether a comma-separated header contains token (case-insensitive).
header_has_token :: (headers: []Header, name: string, token: string) -> bool {
	for h: headers {
		if !strings.equal_fold(h.name, name) { continue; }
		v := h.value;
		while true { part, __ok1 := strings.split_iterator(*v, ","); if !__ok1 break;
			if strings.equal_fold(strings.trim_space(part), token) { return true; }
		}
	}
	return false;
}


#scope_module
// Odin's remove_range: drops a[lo:hi], keeping order.
remove_range :: (a: *[..]$T, lo: int, hi: int) {
	n := hi - lo;
	if n <= 0 { return; }
	for i: hi..a.count-1 { a.*[i - n] = a.*[i]; }
	a.count -= n;
}
#scope_export
