// Content decoding (Content-Encoding). Built in: gzip/x-gzip/deflate (inflate), br (brotli), zstd (zstd).
// Others can be added, or these replaced, with http.register_decoder("name", proc).
// A Decoder_Proc returns the decoded form of src from context.allocator, at most max_out bytes.
Decoder_Proc :: #type (src: []u8, max_out: int) -> []u8, Error;

// register_decoder adds or replaces a decoder for a content-coding name (case-insensitive).
register_decoder :: (name: string, fn: Decoder_Proc) -> bool {
	locks.guard(*registry_mu);
	for i: 0..registry_count-1 if equal_nocase(registry[i].name, name) { registry[i].fn = fn; return true; }
	if registry_count == registry.count return false;
	registry[registry_count] = .{name, fn};
	registry_count += 1;
	return true;
}

// decode_body undoes Content-Encoding on r.body in place (codings applied in reverse order). The header
// is left as received. "identity" is a no-op.
decode_body :: (r: *Response, max_out := 256 << 20) -> Error {
	enc, ok := header_get(r.headers, "content-encoding");
	if !ok return .None;
	codings: [..]string;
	codings.allocator = temp;
	while enc {
		p := trim(next_part(*enc, #char ","));
		if p && !equal_nocase(p, "identity") array_add(*codings, p);
	}
	for < codings {
		fn := find_decoder(it);
		if !fn return .Unsupported_Encoding;
		out, err := fn(r.body, max_out,, r.allocator);
		if err != .None return err;
		array_free(r.body,, r.allocator);
		r.body.data, r.body.count, r.body.allocated = out.data, out.count, out.count;
	}
	return .None;
}

#scope_module

Registered_Decoder :: struct {
	name: string;
	fn: Decoder_Proc;
}

registry_mu: locks.Mutex;
// The built-in decoders are in the table from the start.
registry := #run -> [16]Registered_Decoder {
	r: [16]Registered_Decoder;
	r[0] = .{"gzip", gzip_decode};
	r[1] = .{"x-gzip", gzip_decode};
	r[2] = .{"deflate", deflate_decode};
	r[3] = .{"br", br_decode};
	r[4] = .{"zstd", zstd_decode};
	return r;
};
registry_count := 5;

find_decoder :: (name: string) -> Decoder_Proc {
	locks.guard(*registry_mu);
	for i: 0..registry_count-1 if equal_nocase(registry[i].name, name) return registry[i].fn;
	return null;
}

inflate_decode :: (src: []u8, max_out: int, kind: inflate.Kind) -> []u8, Error {
	f: inflate.Inflater;
	inflate.init(*f, kind);
	defer inflate.destroy(*f);
	out: [..]u8;
	ended, ok := inflate.feed(*f, src, *out, max_out);
	if ok && ended return out, .None;
	too_large := out.count > max_out;
	array_free(out);
	return .[], ifx too_large then .Too_Large else .Decompress;
}

gzip_decode :: (src: []u8, max_out: int) -> []u8, Error { out, err := inflate_decode(src, max_out, .GZIP); return out, err; }

// deflate: RFC 9110 says zlib-wrapped, but raw deflate is common in the wild; accept both.
deflate_decode :: (src: []u8, max_out: int) -> []u8, Error {
	out, err := inflate_decode(src, max_out, .ZLIB);
	if err == .Decompress out, err = inflate_decode(src, max_out, .RAW);
	return out, err;
}

br_decode :: (src: []u8, max_out: int) -> []u8, Error {
	out, err := brotli.decompress(src, max_out);
	if err == .Output_Too_Large return .[], .Too_Large;
	if err != .None return .[], .Decompress;
	return out, .None;
}

zstd_decode :: (src: []u8, max_out: int) -> []u8, Error {
	out, err := zstd.decompress(src, max_out);
	if err == .Output_Too_Large return .[], .Too_Large;
	if err != .None return .[], .Decompress;
	return out, .None;
}
