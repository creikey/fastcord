// Content decoding registry (Content-Encoding). Built in: gzip/deflate
// (core:compress), br (fc:brotli), zstd (fc:zstd). Others can be added with
//   http.register_decoder("name", proc)
// A Decoder_Proc appends the decoded form of src to dst, never exceeding max_out.
Decoder_Proc :: #type (src: []u8, dst: *[..]u8, max_out: int) -> Error;
#scope_module

Registered_Decoder :: struct {
	name: string;
	fn: Decoder_Proc;
}

registry_mu: locks.Mutex;
registry: [16]Registered_Decoder;
registry_len: int;
#scope_export

register_builtin_decoders :: () #no_context {
	registry[0] = .{"gzip", gzip_decode};
	registry[1] = .{"x-gzip", gzip_decode};
	registry[2] = .{"deflate", deflate_decode};
	registry[3] = .{"br", br_decode};
	registry[4] = .{"zstd", zstd_decode};
	registry_len = 5;
}

// register_decoder adds or replaces a decoder for a content-coding name (case-insensitive).
register_decoder :: (name: string, fn: Decoder_Proc) -> bool {
	locks.guard(*registry_mu);
	for i: 0..cast(int)(registry_len)-1 {
		if strings.equal_fold(registry[i].name, name) {
			registry[i].fn = fn;
			return true;
		}
	}
	if registry_len == len(registry) { return false; }
	registry[registry_len] = .{name, fn};
	registry_len += 1;
	return true;
}

find_decoder :: (name: string) -> Decoder_Proc, bool {
	locks.guard(*registry_mu);
	for i: 0..cast(int)(registry_len)-1 {
		if strings.equal_fold(registry[i].name, name) { return registry[i].fn, true; }
	}
	return null, false;
}

// decode_body undoes Content-Encoding on r.body in place (codings applied in
// reverse order). The header is left as received. "identity" is a no-op.
decode_body :: (r: *Response, max_out := 256 << 20) -> Error {
	enc, ok := header_get(view(r.headers), "content-encoding");
	if !ok { return .None; }
	codings := make_dynamic(string, 0, 2, temp);
	it_ := enc;
	while true { part, __ok1 := strings.split_iterator(*it_, ","); if !__ok1 break;
		p := strings.trim_space(part);
		if len(p) > 0 && !strings.equal_fold(p, "identity") { append(*codings, p); }
	}
	for < i: 0..len(codings) - 1 {
		fn, found := find_decoder(codings[i]);
		if !found { return .Unsupported_Encoding; }
		out := make_dynamic(u8, 0, max(len(r.body) * 4, 256), r.allocator);
		{ err := fn(view(r.body), *out, max_out);
		if err != .None {
			delete(out);
			return err;
		} }
		delete(r.body);
		r.body = out;
	}
	return .None;
}
#scope_module

gzip_decode :: (src: []u8, dst: *[..]u8, max_out: int) -> Error {
	buf: bytes.Buffer;
	defer bytes.buffer_destroy(*buf);
	{ err := gzip.load(src, *buf);
	if err != .None { return .Decompress; } }
	if len(buf.buf) > max_out { return .Too_Large; }
	append(dst, ..view(buf.buf));
	return .None;
}

// deflate: RFC 9110 says zlib-wrapped, but raw deflate is common in the wild; accept both.
deflate_decode :: (src: []u8, dst: *[..]u8, max_out: int) -> Error {
	buf: bytes.Buffer;
	defer bytes.buffer_destroy(*buf);
	{ err := zlib.inflate(src, *buf);
	if err != .None {
		bytes.buffer_reset(*buf);
		{ err2 := zlib.inflate(src, *buf, true);
		if err2 != .None { return .Decompress; } }
	} }
	if len(buf.buf) > max_out { return .Too_Large; }
	append(dst, ..view(buf.buf));
	return .None;
}

br_decode :: (src: []u8, dst: *[..]u8, max_out: int) -> Error {
	out, err := brotli.decompress(src, temp, max_out);
	if err == .Output_Too_Large { return .Too_Large; }
	if err != .None { return .Decompress; }
	append(dst, ..out);
	return .None;
}

zstd_decode :: (src: []u8, dst: *[..]u8, max_out: int) -> Error {
	out, err := zstd.decompress(src, temp, max_out);
	if err == .Output_Too_Large { return .Too_Large; }
	if err != .None { return .Decompress; }
	append(dst, ..out);
	return .None;
}
#scope_export

