package http

import "core:encoding/hex"
import "core:strings"
import "core:testing"
import "core:thread"
import "fc:netio"

@(private = "file")
unhex :: proc(s: string) -> []byte {
	b, ok := hex.decode(transmute([]byte)s, context.temp_allocator)
	assert(ok)
	return b
}

// parse_raw feeds raw bytes through a pipe (optionally `chunk` bytes per read).
@(private = "file")
parse_raw :: proc(raw: string, method := "GET", chunk := 0) -> (resp: Response, keep: bool, err: Error) {
	a, b := pipe_make(read_timeout = 0, max_chunk = chunk)
	netio.write(b, transmute([]byte)raw)
	netio.close(b)
	r: Reader
	reader_init(&r, a, 64)
	defer reader_destroy(&r)
	resp, keep, err = h1_read_response(&r, method, {max_header_bytes = 4096, max_headers = 64, max_body = 1 << 20})
	netio.close(a)
	return
}

@(test)
test_h1_serialize_exact :: proc(t: ^testing.T) {
	buf := make([dynamic]byte, context.temp_allocator)
	req := Request {
		method    = "GET",
		authority = "gateway.discord.gg",
		path      = "/?encoding=etf&v=9&compress=zstd-stream",
		headers   = {{"Connection", "Upgrade"}, {"Pragma", "no-cache"}, {"X-MiXeD", "v"}},
	}
	testing.expect_value(t, h1_serialize_request(&buf, req), Error.None)
	testing.expect_value(
		t,
		string(buf[:]),
		"GET /?encoding=etf&v=9&compress=zstd-stream HTTP/1.1\r\nHost: gateway.discord.gg\r\nConnection: Upgrade\r\nPragma: no-cache\r\nX-MiXeD: v\r\n\r\n",
	)
	// explicit Host keeps the caller's position
	clear(&buf)
	req.headers = {{"Connection", "keep-alive"}, {"host", "h"}}
	h1_serialize_request(&buf, req)
	testing.expect_value(t, string(buf[:]), "GET /?encoding=etf&v=9&compress=zstd-stream HTTP/1.1\r\nConnection: keep-alive\r\nhost: h\r\n\r\n")
	// header injection rejected
	clear(&buf)
	req.headers = {{"A", "b\r\nEvil: 1"}}
	testing.expect_value(t, h1_serialize_request(&buf, req), Error.Bad_Request)
	req.headers = {{"Bad Name", "x"}}
	testing.expect_value(t, h1_serialize_request(&buf, req), Error.Bad_Request)
}

@(test)
test_h1_content_length :: proc(t: ^testing.T) {
	for chunk in ([]int{0, 1}) {
		resp, keep, err := parse_raw("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX-Dup: 1\r\nX-Dup: 2\r\nContent-Length: 5\r\n\r\nhello", chunk = chunk)
		defer response_destroy(&resp)
		testing.expect_value(t, err, Error.None)
		testing.expect(t, keep)
		testing.expect_value(t, resp.status, 200)
		testing.expect_value(t, resp.reason, "OK")
		testing.expect_value(t, string(resp.body[:]), "hello")
		testing.expect_value(t, len(resp.headers), 4)
		testing.expect_value(t, resp.headers[0].name, "Content-Type") // case preserved
		testing.expect_value(t, resp.headers[2].value, "2") // order preserved
	}
	{
		_, _, err := parse_raw("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello!")
		testing.expect_value(t, err, Error.Protocol)
	}
	{
		_, _, err := parse_raw("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort")
		testing.expect_value(t, err, Error.Closed)
	}
	{
		_, _, err := parse_raw("HTTP/1.1 200 OK\r\nContent-Length: 99999999\r\n\r\n")
		testing.expect_value(t, err, Error.Too_Large)
	}
	{
		resp, keep, err := parse_raw("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", method = "HEAD")
		defer response_destroy(&resp)
		testing.expect(t, err == .None && keep && len(resp.body) == 0)
	}
}

@(test)
test_h1_chunked :: proc(t: ^testing.T) {
	ok_cases := [][2]string {
		{"5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", "hello world"},
		{"A;name=val\r\n0123456789\r\n0\r\n\r\n", "0123456789"}, // uppercase hex + extension
		{"a\r\n0123456789\r\n0;x\r\nTrailer-A: 1\r\nTrailer-B: 2\r\n\r\n", "0123456789"}, // trailers skipped
		{"0\r\n\r\n", ""},
	}
	for c in ok_cases {
		for chunk in ([]int{0, 1, 3}) {
			resp, keep, err := parse_raw(strings.concatenate({"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", c[0]}, context.temp_allocator), chunk = chunk)
			testing.expectf(t, err == .None, "%q: %v", c[0], err)
			testing.expect_value(t, string(resp.body[:]), c[1])
			testing.expect(t, keep)
			response_destroy(&resp)
		}
	}
	bad := []string {
		"g\r\n",
		"5\r\nhelloXX0\r\n\r\n", // missing CRLF after data
		"fffffffffffffffff\r\n", // too many digits
		"-1\r\n",
		"\r\n",
		"5\r\nhel", // truncated
		"100000\r\n", // > max_body (1 MiB limit + 1)
		"5\r\nhello\r\n", // no last-chunk
	}
	for b in bad {
		r2, _, err := parse_raw(strings.concatenate({"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", b}, context.temp_allocator))
		testing.expectf(t, err != .None, "%q should fail", b)
		response_destroy(&r2)
	}
}

// Bytes after a chunked body belong to the next response on the connection.
@(test)
test_h1_chunked_then_next :: proc(t: ^testing.T) {
	for chunk in ([]int{0, 1, 7}) {
		a, b := pipe_make(read_timeout = 0, max_chunk = chunk)
		netio.write(b, transmute([]byte)string("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi"))
		netio.close(b)
		r: Reader
		reader_init(&r, a, 64)
		r1, _, e1 := h1_read_response(&r, "GET", {max_header_bytes = 4096, max_headers = 64, max_body = 1 << 20})
		r2, _, e2 := h1_read_response(&r, "GET", {max_header_bytes = 4096, max_headers = 64, max_body = 1 << 20})
		testing.expect(t, e1 == .None && e2 == .None)
		testing.expect_value(t, string(r1.body[:]), "abc")
		testing.expect_value(t, string(r2.body[:]), "hi")
		response_destroy(&r1)
		response_destroy(&r2)
		reader_destroy(&r)
		netio.close(a)
	}
}

@(test)
test_h1_misc_responses :: proc(t: ^testing.T) {
	{
		// 100 Continue skipped, close-delimited body
		resp, keep, err := parse_raw("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nConnection: close\r\n\r\nuntil close")
		defer response_destroy(&resp)
		testing.expect_value(t, err, Error.None)
		testing.expect(t, !keep)
		testing.expect_value(t, string(resp.body[:]), "until close")
	}
	{
		resp, keep, err := parse_raw("HTTP/1.1 204 No Content\r\nX: y\r\n\r\n")
		defer response_destroy(&resp)
		testing.expect(t, err == .None && keep && resp.status == 204)
	}
	{
		resp, keep, err := parse_raw("HTTP/1.0 200 OK\r\nContent-Length: 1\r\n\r\nx")
		defer response_destroy(&resp)
		testing.expect(t, err == .None && !keep)
	}
	{
		resp, _, err := parse_raw("HTTP/1.1 200\r\nContent-Length: 0\r\n\r\n") // no reason phrase
		defer response_destroy(&resp)
		testing.expect(t, err == .None && resp.status == 200 && resp.reason == "")
	}
	{
		// The head grows the 64-byte reader buffer, up to max_header_bytes.
		resp, _, err := parse_raw(strings.concatenate({"HTTP/1.1 200 OK\r\nX-Long: ", strings.repeat("v", 1000, context.temp_allocator), "\r\nContent-Length: 0\r\n\r\n"}, context.temp_allocator))
		defer response_destroy(&resp)
		testing.expect(t, err == .None && len(resp.headers[0].value) == 1000)
	}
	{
		_, _, err := parse_raw(strings.concatenate({"HTTP/1.1 200 OK\r\nX-Long: ", strings.repeat("v", 5000, context.temp_allocator), "\r\n\r\n"}, context.temp_allocator))
		testing.expect_value(t, err, Error.Too_Large)
	}
	bad := []string {
		"HTTP/2 200 OK\r\n\r\n",
		"HTTP/1.1 20 OK\r\n\r\n",
		"HTTP/1.1 200 OK\r\n folded\r\n\r\n",
		"HTTP/1.1 200 OK\r\nNoColon\r\n\r\n",
		"HTTP/1.1 200 OK\r\nX: a\x01b\r\n\r\n",
		strings.concatenate({"HTTP/1.1 200 OK\r\n", strings.repeat("X: y\r\n", 65, context.temp_allocator), "\r\n"}, context.temp_allocator), // > max_headers
		"garbage",
	}
	for b in bad {
		r2, _, err := parse_raw(b)
		testing.expectf(t, err != .None, "%q should fail", b)
		response_destroy(&r2)
	}
}

@(private = "file")
Ka_Server :: struct {
	s:   netio.Stream,
	got: [dynamic]byte,
}

// Two requests on one connection; the server answers each after reading it.
@(test)
test_h1_keepalive :: proc(t: ^testing.T) {
	a, b := pipe_make()
	srv := Ka_Server{s = b}
	th := thread.create_and_start_with_poly_data(&srv, proc(srv: ^Ka_Server) {
		buf: [256]byte
		for want in ([]string{"*/*\r\n\r\n", "hi"}) {
			for !strings.has_suffix(string(srv.got[:]), want) {
				n, err := netio.read(srv.s, buf[:])
				if err != .None do return
				append(&srv.got, ..buf[:n])
			}
			resp := "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nfirst" if want != "hi" else "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nsecond!"
			netio.write(srv.s, transmute([]byte)resp)
		}
	})
	c: H1_Conn
	h1_init(&c, a)
	r1, e1 := h1_round_trip(&c, {method = "GET", authority = "x", path = "/1", headers = {{"Accept", "*/*"}}})
	testing.expect_value(t, e1, Error.None)
	testing.expect_value(t, string(r1.body[:]), "first")
	testing.expect(t, c.reusable)
	r2, e2 := h1_round_trip(&c, {method = "POST", authority = "x", path = "/2", headers = {{"Content-Length", "2"}}, body = transmute([]byte)string("hi")})
	testing.expect_value(t, e2, Error.None)
	testing.expect_value(t, string(r2.body[:]), "second!")
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, string(srv.got[:]), "GET /1 HTTP/1.1\r\nHost: x\r\nAccept: */*\r\n\r\nPOST /2 HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi")
	delete(srv.got)
	response_destroy(&r1)
	response_destroy(&r2)
	h1_destroy(&c)
	netio.close(b)
}

@(test)
test_content_decoding :: proc(t: ^testing.T) {
	cases := [][3]string {
		{"gzip", "1f8b08000000000002ffcb48cdc9c95748afca2c5028cf2fca4901006b7de8b710000000", "hello gzip world"},
		{"deflate", "789ccb48cdc9c95748494dcb492c490500230c050a", "hello deflate"},
		{"deflate", "2b4a2c5748494dcb492c490500", "raw deflate"},
		{"identity", "6869", "hi"},
		{"zstd", "28b52ffd045851000068656c6c6f207a737464cfdb609c", "hello zstd"},
		{"br", "8f058068656c6c6f2062726f746c6903", "hello brotli"},
		{"gzip, br", "0f0d801f8b08000000000002ff2b2e494cce4e4d01006d42494b0700000003", "stacked"}, // br applied last, undone first
	}
	for c in cases {
		resp: Response
		resp.allocator = context.allocator
		append(&resp.headers, Header{strings.clone("Content-Encoding"), strings.clone(c[0])})
		append(&resp.body, ..unhex(c[1]))
		testing.expect_value(t, decode_body(&resp), Error.None)
		testing.expect_value(t, string(resp.body[:]), c[2])
		response_destroy(&resp)
	}
	resp: Response
	resp.allocator = context.allocator
	append(&resp.headers, Header{strings.clone("content-encoding"), strings.clone("x-unknown")})
	testing.expect_value(t, decode_body(&resp), Error.Unsupported_Encoding)
	// a registered decoder is used
	register_decoder("x-unknown", proc(src: []byte, dst: ^[dynamic]byte, max_out: int) -> Error {
		append(dst, "fake")
		return .None
	})
	testing.expect_value(t, decode_body(&resp), Error.None)
	testing.expect_value(t, string(resp.body[:]), "fake")
	response_destroy(&resp)
}
