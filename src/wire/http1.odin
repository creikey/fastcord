package wire

import "core:fmt"
import "core:strconv"
import "core:strings"

Header :: struct {
	name:  string,
	value: string,
}

Response :: struct {
	status:  int,
	reason:  string,
	headers: [dynamic]Header,
	body:    [dynamic]byte,
}

response_destroy :: proc(r: ^Response) {
	for h in r.headers {
		delete(h.name)
		delete(h.value)
	}
	delete(r.headers)
	delete(r.body)
	delete(r.reason)
}

header_get :: proc(headers: []Header, name: string) -> (string, bool) {
	for h in headers {
		if strings.equal_fold(h.name, name) do return h.value, true
	}
	return "", false
}

// Writes a request head in exactly the order the caller gives the headers.
// Header order is part of a client's fingerprint, so nothing is reordered or added.
write_request :: proc(c: ^Conn, method, target: string, headers: []Header, body: []byte) -> Error {
	b := strings.builder_make(0, 1024, context.temp_allocator)
	fmt.sbprintf(&b, "%s %s HTTP/1.1\r\n", method, target)
	for h in headers {
		fmt.sbprintf(&b, "%s: %s\r\n", h.name, h.value)
	}
	strings.write_string(&b, "\r\n")
	if err := write(c, b.buf[:]); err != .None do return err
	if len(body) > 0 do return write(c, body)
	return .None
}

read_response_head :: proc(c: ^Conn, r: ^Response) -> Error {
	line, err := read_line(c)
	if err != .None do return err
	// "HTTP/1.1 200 OK"
	if !strings.has_prefix(line, "HTTP/1.") || len(line) < 12 do return .Protocol
	status, ok := strconv.parse_int(line[9:12])
	if !ok do return .Protocol
	r.status = status
	r.reason = strings.clone(strings.trim_space(line[12:]))
	for {
		line, err = read_line(c)
		if err != .None do return err
		if line == "" do break
		colon := strings.index_byte(line, ':')
		if colon < 0 do return .Protocol
		append(&r.headers, Header{
			strings.clone(line[:colon]),
			strings.clone(strings.trim_space(line[colon + 1:])),
		})
	}
	return .None
}

MAX_BODY :: 256 * 1024 * 1024

read_response_body :: proc(c: ^Conn, r: ^Response, method: string) -> Error {
	if method == "HEAD" || r.status == 204 || r.status == 304 || r.status / 100 == 1 do return .None
	if te, ok := header_get(r.headers[:], "Transfer-Encoding"); ok && strings.contains(te, "chunked") {
		for {
			line, err := read_line(c)
			if err != .None do return err
			semi := strings.index_byte(line, ';')
			if semi >= 0 do line = line[:semi]
			size, ok2 := strconv.parse_int(strings.trim_space(line), 16)
			if !ok2 || size < 0 do return .Protocol
			if size == 0 {
				// trailers
				for {
					l, e := read_line(c)
					if e != .None do return e
					if l == "" do break
				}
				return .None
			}
			if len(r.body) + size > MAX_BODY do return .Too_Large
			start := len(r.body)
			resize(&r.body, start + size)
			if e := read_full(c, r.body[start:]); e != .None do return e
			if _, e := read_line(c); e != .None do return e
		}
	}
	if cl, ok := header_get(r.headers[:], "Content-Length"); ok {
		n, ok2 := strconv.parse_int(cl)
		if !ok2 || n < 0 do return .Protocol
		if n > MAX_BODY do return .Too_Large
		resize(&r.body, n)
		return read_full(c, r.body[:])
	}
	// Read until close.
	tmp: [16 * 1024]byte
	for {
		n, err := read_some(c, tmp[:])
		if err == .Closed do return .None
		if err != .None do return err
		append(&r.body, ..tmp[:n])
		if len(r.body) > MAX_BODY do return .Too_Large
	}
}

// One request on an existing connection.
round_trip :: proc(c: ^Conn, method, target: string, headers: []Header, body: []byte) -> (r: Response, err: Error) {
	if err = write_request(c, method, target, headers, body); err != .None do return
	if err = read_response_head(c, &r); err != .None do return
	err = read_response_body(c, &r, method)
	return
}
