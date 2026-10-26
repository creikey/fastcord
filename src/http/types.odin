// Package http: HTTP/1.1, HTTP/2 and WebSocket clients over netio.Stream, on
// vendored parsers: picohttpparser (HTTP/1.1), nghttp2 (HTTP/2), wslay (WebSocket).
//
// Everything here runs on a netio.Stream, so TLS (fc:tls), plain TCP and the
// in-memory Pipe (tests) are interchangeable. Request/Response are shared by
// the h1, h2 and h3 paths so callers can swap transports.
//
// Header fidelity: request headers are written in exactly the order and
// casing given. Nothing is added implicitly except, for HTTP/1.1, a leading
// `Host:` taken from Request.authority when the caller didn't include one,
// and for HTTP/2 the pseudo-headers (:method :authority :scheme :path, the
// Chrome order) built from the Request fields.
package http

import "core:mem"
import "core:strings"

Error :: enum {
	None,
	Io,
	Closed,
	Timeout,
	Protocol, // malformed peer data / protocol violation
	Too_Large, // exceeds a configured limit
	Bad_Request, // caller-supplied request is invalid
	Unsupported_Encoding,
	Decompress,
	Stream_Reset, // h2 RST_STREAM from peer (see Response.h2_error)
	Refused, // h2 REFUSED_STREAM or stream above GOAWAY last-stream-id: safe to retry
	Goaway, // connection is going away; no new streams
	Flow_Control,
	Handshake, // websocket upgrade rejected / invalid
	Out_Of_Memory,
}

Header :: struct {
	name, value: string,
}

Version :: enum u8 {
	Http1_0,
	Http1_1,
	Http2,
	Http3,
}

// Chrome request priorities (net::RequestPriority). The zero value is Medium,
// the priority Chrome gives fetch()/XHR; navigations are Highest.
Priority :: enum u8 {
	Medium,
	Highest,
	Low,
	Lowest,
	Idle,
	Throttled,
}

Request :: struct {
	method:    string, // "GET"
	scheme:    string, // "https" (h2 :scheme)
	authority: string, // "discord.com" (h2 :authority, h1 Host when no Host header given)
	path:      string, // "/api/v9/users/@me"
	headers:   []Header, // exact order/case; for h2 names must already be lowercase
	body:      []byte,
	priority:  Priority, // h2 HEADERS priority fields, h3 priority header
}

Response :: struct {
	version:   Version,
	status:    int,
	reason:    string, // h1 only
	headers:   [dynamic]Header,
	trailers:  [dynamic]Header,
	body:      [dynamic]byte,
	h2_error:  u32, // RST_STREAM / GOAWAY error code when the request failed
	allocator: mem.Allocator,
}

response_destroy :: proc(r: ^Response) {
	context.allocator = r.allocator
	for h in r.headers {
		delete(h.name)
		delete(h.value)
	}
	for h in r.trailers {
		delete(h.name)
		delete(h.value)
	}
	delete(r.headers)
	delete(r.trailers)
	delete(r.body)
	if len(r.reason) > 0 do delete(r.reason)
	r^ = {}
}

// header_get returns the first header with a case-insensitive name match.
header_get :: proc(headers: []Header, name: string) -> (string, bool) {
	for h in headers {
		if strings.equal_fold(h.name, name) do return h.value, true
	}
	return "", false
}

// header_has_token reports whether a comma-separated header contains token (case-insensitive).
header_has_token :: proc(headers: []Header, name, token: string) -> bool {
	for h in headers {
		if !strings.equal_fold(h.name, name) do continue
		v := h.value
		for part in strings.split_iterator(&v, ",") {
			if strings.equal_fold(strings.trim_space(part), token) do return true
		}
	}
	return false
}
