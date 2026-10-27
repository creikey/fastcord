// HTTP/1.1 client connection. Not thread-safe: one request at a time.
//   c: H1_Conn;
//   h1_init(*c, stream);
//   resp, err := h1_round_trip(*c, req);
//   if !c.reusable { reconnect }
// Response heads and chunked bodies are parsed by picohttpparser (vendor/picohttpparser).
H1_Conn :: struct {
	s: netio.Stream;
	r: Reader;
	reusable: bool; // false after Connection: close / close-delimited body / error
	limits: H1_Limits;
	allocator: Allocator;
}

H1_Limits :: struct {
	max_header_bytes: int; // total header section; 0 = 256 KiB
	max_headers: int;      // 0 = 256
	max_body: int;         // 0 = 256 MiB
}

// h1_init sets c up on s; c's buffers and responses come from context.allocator.
h1_init :: (c: *H1_Conn, s: netio.Stream, limits := H1_Limits.{}) {
	c.s, c.allocator, c.limits = s, context.allocator, limits;
	if c.limits.max_header_bytes <= 0 c.limits.max_header_bytes = 256 << 10;
	if c.limits.max_headers <= 0 c.limits.max_headers = 256;
	if c.limits.max_body <= 0 c.limits.max_body = 256 << 20;
	reader_init(*c.r, s);
	c.reusable = true;
}

h1_destroy :: (c: *H1_Conn, close_stream := true) {
	reader_destroy(*c.r);
	if close_stream netio.close(c.s);
}

// h1_round_trip writes req and reads the response on a keep-alive connection.
h1_round_trip :: (c: *H1_Conn, req: Request) -> Response, Error {
	if !c.reusable return .{}, .Closed;
	err := h1_write_request(c.s, req);
	if err != .None {
		c.reusable = false;
		return .{}, err;
	}
	resp, keep, rerr := h1_read_response(*c.r, req.method, c.limits,, c.allocator);
	err = rerr;
	c.reusable = keep && err == .None && resp.status != 101;
	return resp, err;
}

#scope_module

Phr_Header :: struct {
	name: *u8;
	name_len: u64;
	value: *u8;
	value_len: u64;
}

Phr_Chunked_Decoder :: struct {
	bytes_left_in_chunk: u64;
	consume_trailer: u8;
	_hex_count: u8;
	_state: u8;
	_total_read: u64;
	_total_overhead: u64;
}

phr_parse_response :: (buf: *u8, len: u64, minor_version: *s32, status: *s32, msg: **u8, msg_len: *u64, headers: *Phr_Header, num_headers: *u64, last_len: u64) -> s32 #foreign vendor;
phr_decode_chunked :: (decoder: *Phr_Chunked_Decoder, buf: *u8, bufsz: *u64) -> int #foreign vendor;

valid_token :: (s: string) -> bool {
	if !s return false;
	for s if it <= #char " " || it >= 0x7f || it == #char ":" return false;
	return true;
}

valid_value :: (s: string) -> bool {
	for s if it == 13 || it == 10 || it == 0 return false;
	return true;
}

// h1_serialize_request appends the exact request bytes. Host is emitted first from req.authority only if
// no Host header is present. Content-Length is the caller's job (Chrome's position for it varies by
// request type).
h1_serialize_request :: (buf: *String_Builder, req: Request) -> Error {
	if !valid_token(req.method) return .Bad_Request;
	if !req.path || !valid_value(req.path) || contains(req.path, #char " ") return .Bad_Request;
	print_to_builder(buf, "% % HTTP/1.1\r\n", req.method, req.path);
	_, has_host := header_get(req.headers, "host");
	if !has_host && req.authority {
		if !valid_value(req.authority) return .Bad_Request;
		print_to_builder(buf, "Host: %\r\n", req.authority);
	}
	for req.headers {
		if !valid_token(it.name) || !valid_value(it.value) return .Bad_Request;
		print_to_builder(buf, "%: %\r\n", it.name, it.value);
	}
	append(buf, "\r\n");
	append(buf, req.body.data, req.body.count);
	return .None;
}

h1_write_request :: (s: netio.Stream, req: Request) -> Error {
	b: String_Builder;
	b.allocator = temp;
	err := h1_serialize_request(*b, req);
	if err != .None return err;
	return map_net_error(netio.write(s, cast([]u8) builder_to_string(*b,, temp)));
}

// h1_read_head reads a status line + headers into resp (strings from context.allocator), growing the
// reader's buffer up to limits.max_header_bytes. Returns after the blank line.
h1_read_head :: (r: *Reader, resp: *Response, limits: H1_Limits) -> Error {
	fields := NewArray(limits.max_headers, Phr_Header,, temp);
	last := 0;
	while true {
		buf := array_view(r.buf, r.start, r.end - r.start);
		minor, status: s32;
		msg: *u8;
		msg_len: u64;
		n := cast(u64) fields.count;
		ret := phr_parse_response(buf.data, xx buf.count, *minor, *status, *msg, *msg_len, fields.data, *n, xx last);
		if ret == -1 return .Protocol;
		if ret > 0 {
			resp.version = ifx minor == 0 then .Http1_0 else .Http1_1;
			resp.status = status;
			free_string(resp.reason);
			resp.reason = copy_string(to_string(msg, xx msg_len));
			for array_view(fields, 0, xx n) {
				if !it.name return .Protocol; // obs-fold
				array_add(*resp.headers, copy_header(to_string(it.name, xx it.name_len), to_string(it.value, xx it.value_len), context.allocator));
			}
			r.start += ret;
			return .None;
		}
		last = buf.count;
		if last >= limits.max_header_bytes return .Too_Large;
		if r.start == 0 && r.end == r.buf.count reader_grow(r, min(2 * r.buf.count, limits.max_header_bytes));
		err := fill(r);
		if err != .None return err;
	}
	return .None;
}

// h1_read_response reads a full response (skipping 1xx except 101) and its body, from context.allocator.
// keep_alive reports whether the connection can carry another request.
h1_read_response :: (r: *Reader, method: string, limits: H1_Limits) -> Response, keep_alive: bool, Error {
	resp := make_response(.Http1_1);
	while true {
		err := h1_read_head(r, *resp, limits);
		if err != .None {
			response_destroy(*resp);
			return .{}, false, err;
		}
		if resp.status < 100 || resp.status >= 200 || resp.status == 101 break;
		clear_headers(*resp.headers);
	}
	keep_alive := resp.version == .Http1_1;
	if header_has_token(resp.headers, "connection", "close") keep_alive = false;
	if resp.version == .Http1_0 && header_has_token(resp.headers, "connection", "keep-alive") keep_alive = true;

	no_body := method == "HEAD" || resp.status == 204 || resp.status == 304 || (resp.status >= 100 && resp.status < 200);
	if no_body return resp, keep_alive, .None;

	err: Error;
	te, has_te := header_get(resp.headers, "transfer-encoding");
	_, has_cl := header_get(resp.headers, "content-length");
	if has_te {
		// chunked must be the final coding; anything else is close-delimited
		found, _, last := split_from_right(te, #char ",");
		if equal_nocase(trim(last), "chunked") {
			err = read_chunked(r, *resp, limits);
		} else {
			err = read_until_close(r, *resp, limits);
			keep_alive = false;
		}
	} else if has_cl {
		n, ok := parse_content_length(resp.headers);
		if !ok                     err = .Protocol;
		else if n > limits.max_body err = .Too_Large;
		else                        err = read_body_n(r, *resp.body, n);
	} else {
		err = read_until_close(r, *resp, limits);
		keep_alive = false;
	}
	if err != .None {
		response_destroy(*resp);
		return .{}, false, err;
	}
	return resp, keep_alive, .None;
}

// Multiple Content-Length headers / list values must all agree (RFC 9110 8.6).
parse_content_length :: (headers: []Header) -> int, bool {
	result := -1;
	for headers {
		if !equal_nocase(it.name, "content-length") continue;
		v := it.value;
		while v {
			p := trim(next_part(*v, #char ","));
			if !p || p.count > 18 return 0, false;
			n := 0;
			for p {
				if it < #char "0" || it > #char "9" return 0, false;
				n = n * 10 + (it - #char "0");
			}
			if result >= 0 && result != n return 0, false;
			result = n;
		}
	}
	return result, result >= 0;
}

// read_body_n appends exactly n bytes, growing in steps so a lying length can't force a huge allocation.
read_body_n :: (r: *Reader, body: *[..]u8, n: int) -> Error {
	left := n;
	while left > 0 {
		step := min(left, 64 << 10);
		err := read_exact(r, grow(body, step));
		if err != .None return err;
		left -= step;
	}
	return .None;
}

read_until_close :: (r: *Reader, resp: *Response, limits: H1_Limits) -> Error {
	tmp: [16 * 1024]u8 = ---;
	while true {
		n, err := read_some(r, tmp);
		if err == .Closed return .None;
		if err != .None return err;
		if resp.body.count + n > limits.max_body return .Too_Large;
		array_add(*resp.body, ..array_view(tmp, 0, n));
	}
	return .None;
}

// read_chunked moves the reader's buffered bytes onto the end of the body and lets phr_decode_chunked
// decode them in place. Bytes after the last chunk and its trailers (discarded) belong to the next
// response: they are still in the reader's buffer, so they are given back by rewinding r.start.
read_chunked :: (r: *Reader, resp: *Response, limits: H1_Limits) -> Error {
	dec := Phr_Chunked_Decoder.{consume_trailer = 1};
	while true {
		if r.start == r.end {
			err := fill(r);
			if err != .None return err;
		}
		raw := r.end - r.start;
		done := resp.body.count;
		memcpy(grow(*resp.body, raw).data, r.buf.data + r.start, raw);
		r.start = r.end;
		n := cast(u64) raw;
		ret := phr_decode_chunked(*dec, resp.body.data + done, *n);
		resp.body.count = done + cast(int) n;
		if ret == -1 return .Protocol;
		if resp.body.count > limits.max_body return .Too_Large;
		if ret >= 0 {
			r.start -= ret;
			return .None;
		}
	}
	return .None;
}
