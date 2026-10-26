package http

import "core:mem"
import "core:strings"
import "fc:netio"

// HTTP/1.1 client connection. Not thread-safe: one request at a time.
//   c: H1_Conn
//   h1_init(&c, stream)
//   resp, err := h1_round_trip(&c, req)
//   if !c.reusable { reconnect }
H1_Conn :: struct {
	s:         netio.Stream,
	r:         Reader,
	reusable:  bool, // false after Connection: close / close-delimited body / error
	limits:    H1_Limits,
	allocator: mem.Allocator,
}

H1_Limits :: struct {
	max_header_bytes: int, // total header section; 0 = 256 KiB
	max_headers:      int, // 0 = 256
	max_body:         int, // 0 = 256 MiB
}

h1_init :: proc(c: ^H1_Conn, s: netio.Stream, limits := H1_Limits{}, allocator := context.allocator) {
	c.s = s
	c.allocator = allocator
	c.limits = limits
	if c.limits.max_header_bytes <= 0 do c.limits.max_header_bytes = 256 << 10
	if c.limits.max_headers <= 0 do c.limits.max_headers = 256
	if c.limits.max_body <= 0 do c.limits.max_body = 256 << 20
	reader_init(&c.r, s, READER_SIZE, allocator)
	c.reusable = true
}

h1_destroy :: proc(c: ^H1_Conn, close_stream := true) {
	reader_destroy(&c.r, c.allocator)
	if close_stream do netio.close(c.s)
}

@(private)
valid_token :: proc(s: string) -> bool {
	if len(s) == 0 do return false
	for c in transmute([]byte)s {
		if c <= ' ' || c >= 0x7f || c == ':' do return false
	}
	return true
}

@(private)
valid_value :: proc(s: string) -> bool {
	for c in transmute([]byte)s {
		if c == '\r' || c == '\n' || c == 0 do return false
	}
	return true
}

// h1_serialize_request appends the exact request bytes. Host is emitted first
// from req.authority only if no Host header is present. Content-Length is the
// caller's job (Chrome's position for it varies by request type).
h1_serialize_request :: proc(buf: ^[dynamic]byte, req: Request) -> Error {
	if !valid_token(req.method) do return .Bad_Request
	if len(req.path) == 0 || !valid_value(req.path) || strings.contains_any(req.path, " ") do return .Bad_Request
	append(buf, req.method)
	append(buf, " ")
	append(buf, req.path)
	append(buf, " HTTP/1.1\r\n")
	if _, has_host := header_get(req.headers, "host"); !has_host && len(req.authority) > 0 {
		if !valid_value(req.authority) do return .Bad_Request
		append(buf, "Host: ")
		append(buf, req.authority)
		append(buf, "\r\n")
	}
	for h in req.headers {
		if !valid_token(h.name) || !valid_value(h.value) do return .Bad_Request
		append(buf, h.name)
		append(buf, ": ")
		append(buf, h.value)
		append(buf, "\r\n")
	}
	append(buf, "\r\n")
	append(buf, ..req.body)
	return .None
}

h1_write_request :: proc(s: netio.Stream, req: Request) -> Error {
	buf := make([dynamic]byte, 0, 1024 + len(req.body), context.temp_allocator)
	h1_serialize_request(&buf, req) or_return
	return map_net_error(netio.write(s, buf[:]))
}

// h1_read_head reads a status line + headers. Returns after the blank line.
h1_read_head :: proc(r: ^Reader, resp: ^Response, limits: H1_Limits, allocator: mem.Allocator) -> Error {
	context.allocator = allocator
	resp.allocator = allocator
	line, err := read_line(r)
	if err != .None do return err
	// "HTTP/1.1 200 OK"
	if !strings.has_prefix(line, "HTTP/1.") || len(line) < 12 || line[8] != ' ' do return .Protocol
	switch line[7] {
	case '0':
		resp.version = .Http1_0
	case '1':
		resp.version = .Http1_1
	case:
		return .Protocol
	}
	code := line[9:12]
	status := 0
	for c in transmute([]byte)code {
		if c < '0' || c > '9' do return .Protocol
		status = status * 10 + int(c - '0')
	}
	if len(line) > 12 && line[12] != ' ' do return .Protocol
	resp.status = status
	if len(resp.reason) > 0 do delete(resp.reason)
	resp.reason = strings.clone(line[13:]) if len(line) > 13 else ""
	total := len(line)
	for {
		hl, herr := read_line(r)
		if herr != .None do return herr
		if len(hl) == 0 do break
		total += len(hl) + 2
		if total > limits.max_header_bytes || len(resp.headers) >= limits.max_headers do return .Too_Large
		if hl[0] == ' ' || hl[0] == '\t' do return .Protocol // obs-fold rejected
		colon := strings.index_byte(hl, ':')
		if colon <= 0 do return .Protocol
		name := hl[:colon]
		if !valid_token(name) do return .Protocol
		value := strings.trim(hl[colon + 1:], " \t")
		append(&resp.headers, Header{strings.clone(name), strings.clone(value)})
	}
	return .None
}

@(private)
clear_headers :: proc(resp: ^Response) {
	for h in resp.headers {
		delete(h.name, resp.allocator)
		delete(h.value, resp.allocator)
	}
	clear(&resp.headers)
}

// h1_read_response reads a full response (skipping 1xx except 101) and its body.
// keep_alive reports whether the connection can carry another request.
h1_read_response :: proc(
	r: ^Reader,
	method: string,
	limits: H1_Limits,
	allocator := context.allocator,
) -> (
	resp: Response,
	keep_alive: bool,
	err: Error,
) {
	resp.allocator = allocator
	resp.headers = make([dynamic]Header, 0, 16, allocator)
	resp.body = make([dynamic]byte, 0, 0, allocator)
	resp.trailers = make([dynamic]Header, 0, 0, allocator)
	for {
		if err = h1_read_head(r, &resp, limits, allocator); err != .None {
			response_destroy(&resp)
			return {}, false, err
		}
		if resp.status >= 100 && resp.status < 200 && resp.status != 101 {
			clear_headers(&resp)
			continue
		}
		break
	}
	keep_alive = resp.version == .Http1_1
	if header_has_token(resp.headers[:], "connection", "close") do keep_alive = false
	if resp.version == .Http1_0 && header_has_token(resp.headers[:], "connection", "keep-alive") do keep_alive = true

	no_body := method == "HEAD" || resp.status == 204 || resp.status == 304 || (resp.status >= 100 && resp.status < 200)
	if no_body do return resp, keep_alive, .None

	if te, has_te := header_get(resp.headers[:], "transfer-encoding"); has_te {
		// chunked must be the final coding; anything else is close-delimited
		last := te
		if i := strings.last_index_byte(te, ','); i >= 0 do last = te[i + 1:]
		if strings.equal_fold(strings.trim_space(last), "chunked") {
			err = read_chunked(r, &resp, limits)
		} else {
			err = read_until_close(r, &resp, limits)
			keep_alive = false
		}
	} else if _, has_cl := header_get(resp.headers[:], "content-length"); has_cl {
		n, ok := parse_content_length(resp.headers[:])
		if !ok {
			err = .Protocol
		} else if n > limits.max_body {
			err = .Too_Large
		} else {
			err = read_body_n(r, &resp.body, n)
		}
	} else {
		err = read_until_close(r, &resp, limits)
		keep_alive = false
	}
	if err != .None {
		response_destroy(&resp)
		return {}, false, err
	}
	return resp, keep_alive, .None
}

// Multiple Content-Length headers / list values must all agree (RFC 9110 8.6).
@(private)
parse_content_length :: proc(headers: []Header) -> (int, bool) {
	result := -1
	for h in headers {
		if !strings.equal_fold(h.name, "content-length") do continue
		v := h.value
		for part in strings.split_iterator(&v, ",") {
			p := strings.trim_space(part)
			if len(p) == 0 || len(p) > 18 do return 0, false
			n := 0
			for c in transmute([]byte)p {
				if c < '0' || c > '9' do return 0, false
				n = n * 10 + int(c - '0')
			}
			if result >= 0 && result != n do return 0, false
			result = n
		}
	}
	return result, result >= 0
}

// read_body_n appends exactly n bytes, growing in steps so a lying length can't force a huge allocation.
@(private)
read_body_n :: proc(r: ^Reader, body: ^[dynamic]byte, n: int) -> Error {
	left := n
	for left > 0 {
		step := min(left, 64 << 10)
		old := len(body)
		resize(body, old + step)
		if e := read_exact(r, body[old:]); e != .None do return e
		left -= step
	}
	return .None
}

@(private)
hexval :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a' + 10)
	case 'A' ..= 'F':
		return int(c - 'A' + 10)
	}
	return -1
}

@(private)
read_until_close :: proc(r: ^Reader, resp: ^Response, limits: H1_Limits) -> Error {
	tmp: [16 * 1024]byte
	for {
		n, err := read_some(r, tmp[:])
		if err == .Closed do return .None
		if err != .None do return err
		if len(resp.body) + n > limits.max_body do return .Too_Large
		append(&resp.body, ..tmp[:n])
	}
}

@(private)
read_chunked :: proc(r: ^Reader, resp: ^Response, limits: H1_Limits) -> Error {
	for {
		line, err := read_line(r)
		if err != .None do return err
		if i := strings.index_byte(line, ';'); i >= 0 do line = line[:i] // chunk extensions
		line = strings.trim_right(line, " \t")
		if len(line) == 0 || len(line) > 15 do return .Protocol
		size := 0
		for c in transmute([]byte)line {
			d := hexval(c)
			if d < 0 do return .Protocol
			size = size << 4 | d
		}
		if size == 0 do break
		if len(resp.body) + size > limits.max_body do return .Too_Large
		if e := read_body_n(r, &resp.body, size); e != .None do return e
		crlf, cerr := read_line(r)
		if cerr != .None do return cerr
		if len(crlf) != 0 do return .Protocol
	}
	// trailers
	total := 0
	for {
		line, err := read_line(r)
		if err != .None do return err
		if len(line) == 0 do return .None
		total += len(line)
		if total > limits.max_header_bytes || len(resp.trailers) >= limits.max_headers do return .Too_Large
		colon := strings.index_byte(line, ':')
		if colon <= 0 do return .Protocol
		append(
			&resp.trailers,
			Header{strings.clone(line[:colon], resp.allocator), strings.clone(strings.trim(line[colon + 1:], " \t"), resp.allocator)},
		)
	}
}

// h1_round_trip writes req and reads the response on a keep-alive connection.
h1_round_trip :: proc(c: ^H1_Conn, req: Request) -> (resp: Response, err: Error) {
	if !c.reusable do return {}, .Closed
	if err = h1_write_request(c.s, req); err != .None {
		c.reusable = false
		return
	}
	keep: bool
	resp, keep, err = h1_read_response(&c.r, req.method, c.limits, c.allocator)
	c.reusable = keep && err == .None && resp.status != 101
	return
}
