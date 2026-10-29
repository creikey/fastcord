Error :: enum {
	None;
	Io;
	Closed;
	Timeout;
	Protocol;             // malformed peer data / protocol violation
	Too_Large;            // exceeds a configured limit
	Bad_Request;          // caller-supplied request is invalid
	Unsupported_Encoding;
	Decompress;
	Stream_Reset;         // h2 RST_STREAM from peer (see Response.h2_error)
	Refused;              // h2 REFUSED_STREAM or stream above GOAWAY last-stream-id: safe to retry
	Goaway;               // connection is going away; no new streams
	Flow_Control;
	Handshake;            // websocket upgrade rejected / invalid
	Out_Of_Memory;
}

Header :: struct {
	name, value: string;
}

Version :: enum u8 { Http1_0; Http1_1; Http2; Http3; }

// Chrome request priorities (net::RequestPriority). The zero value is Medium, the priority Chrome gives
// fetch()/XHR; navigations are Highest.
Priority :: enum u8 { Medium; Highest; Low; Lowest; Idle; Throttled; }

Request :: struct {
	method: string;      // "GET"
	scheme: string;      // "https" (h2 :scheme)
	authority: string;   // "discord.com" (h2 :authority, h1 Host when no Host header given)
	path: string;        // "/api/v9/users/@me"
	headers: []Header;   // exact order/case; for h2 names must already be lowercase
	body: []u8;
	priority: Priority;  // h2 HEADERS priority fields, h3 priority header
	sink: Body_Sink;     // set: the response body goes here as it arrives instead of into resp.body
}

// Body_Sink takes a response body piece by piece as it arrives, so a large download is never held whole
// (resp.body stays empty); returning false abandons the response. h2 and h3 sink only an unencoded body:
// one with a content-encoding still collects in resp.body, for decode_body.
Body_Sink :: struct {
	data: *void;
	take: (data: *void, piece: []u8) -> bool;
}

sinking :: (sink: Body_Sink, resp: *Response) -> bool {
	if !sink.take return false;
	enc, has := header_get(resp.headers, "content-encoding");
	return !has || enc == "identity";
}

// A Response's memory (its arrays and strings) all comes from its allocator.
Response :: struct {
	version: Version;
	status: int;
	reason: string;       // h1 only
	headers: [..]Header;
	trailers: [..]Header;
	body: [..]u8;
	h2_error: u32;        // RST_STREAM / GOAWAY error code when the request failed
	allocator: Allocator;
}

// make_response returns an empty Response that allocates from context.allocator.
make_response :: (version: Version) -> Response {
	r := Response.{version = version, allocator = context.allocator};
	r.headers.allocator, r.trailers.allocator, r.body.allocator = context.allocator, context.allocator, context.allocator;
	return r;
}

response_destroy :: (r: *Response) {
	if !r.allocator.proc return; // nothing was allocated for it
	push_allocator(r.allocator);
	clear_headers(*r.headers);
	clear_headers(*r.trailers);
	array_free(r.headers);
	array_free(r.trailers);
	array_free(r.body);
	free_string(r.reason);
	r.* = .{};
}

// header_get returns the first header with a case-insensitive name match.
header_get :: (headers: []Header, name: string) -> string, bool {
	for headers if equal_nocase(it.name, name) return it.value, true;
	return "", false;
}

#scope_module

// header_has_token reports whether a comma-separated header contains token (case-insensitive).
header_has_token :: (headers: []Header, name: string, token: string) -> bool {
	for h: headers {
		if !equal_nocase(h.name, name) continue;
		v := h.value;
		while v if equal_nocase(trim(next_part(*v, #char ",")), token) return true;
	}
	return false;
}

// next_part cuts s at its first sep and returns what came before. Looping `while s` visits every part but
// a trailing empty one.
next_part :: (s: *string, sep: u8) -> string {
	found, part, rest := split_from_left(s.*, sep);
	s.* = rest;
	return part;
}

// clear_headers frees the strings of headers (from context.allocator) and empties it.
clear_headers :: (headers: *[..]Header) {
	for headers.* { free_string(it.name); free_string(it.value); }
	headers.count = 0;
}

// free_string frees a string from copy_string, which returns a literal "" for an empty one.
free_string :: (s: string) { if s.count free(s.data); }

copy_header :: (name: string, value: string, a: Allocator) -> Header {
	return .{copy_string(name,, a), copy_string(value,, a)};
}

// grow adds n uninitialised bytes to b, doubling its capacity as needed so appending stays linear, and
// returns them.
grow :: (b: *[..]u8, n: int) -> []u8 {
	if b.count + n > b.allocated array_reserve(b, max(2 * b.allocated, b.count + n));
	b.count += n;
	return .{n, b.data + b.count - n};
}
