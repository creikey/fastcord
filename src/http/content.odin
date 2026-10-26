package http

import "core:bytes"
import "core:compress/gzip"
import "core:compress/zlib"
import "core:strings"
import "core:sync"
import "fc:brotli"
import "fc:zstd"

// Content decoding registry (Content-Encoding). Built in: gzip/deflate
// (core:compress), br (fc:brotli), zstd (fc:zstd). Others can be added with
//   http.register_decoder("name", proc)
// A Decoder_Proc appends the decoded form of src to dst, never exceeding max_out.
Decoder_Proc :: #type proc(src: []byte, dst: ^[dynamic]byte, max_out: int) -> Error

@(private)
Registered_Decoder :: struct {
	name: string,
	fn:   Decoder_Proc,
}

@(private)
registry_mu: sync.RW_Mutex
@(private)
registry: [16]Registered_Decoder
@(private)
registry_len: int

@(init, private)
register_builtin_decoders :: proc "contextless" () {
	registry[0] = {"gzip", gzip_decode}
	registry[1] = {"x-gzip", gzip_decode}
	registry[2] = {"deflate", deflate_decode}
	registry[3] = {"br", br_decode}
	registry[4] = {"zstd", zstd_decode}
	registry_len = 5
}

// register_decoder adds or replaces a decoder for a content-coding name (case-insensitive).
register_decoder :: proc(name: string, fn: Decoder_Proc) -> bool {
	sync.rw_mutex_lock(&registry_mu)
	defer sync.rw_mutex_unlock(&registry_mu)
	for i in 0 ..< registry_len {
		if strings.equal_fold(registry[i].name, name) {
			registry[i].fn = fn
			return true
		}
	}
	if registry_len == len(registry) do return false
	registry[registry_len] = {name, fn}
	registry_len += 1
	return true
}

find_decoder :: proc(name: string) -> (Decoder_Proc, bool) {
	sync.rw_mutex_shared_lock(&registry_mu)
	defer sync.rw_mutex_shared_unlock(&registry_mu)
	for i in 0 ..< registry_len {
		if strings.equal_fold(registry[i].name, name) do return registry[i].fn, true
	}
	return nil, false
}

// decode_body undoes Content-Encoding on r.body in place (codings applied in
// reverse order). The header is left as received. "identity" is a no-op.
decode_body :: proc(r: ^Response, max_out := 256 << 20) -> Error {
	enc, ok := header_get(r.headers[:], "content-encoding")
	if !ok do return .None
	codings := make([dynamic]string, 0, 2, context.temp_allocator)
	it := enc
	for part in strings.split_iterator(&it, ",") {
		p := strings.trim_space(part)
		if len(p) > 0 && !strings.equal_fold(p, "identity") do append(&codings, p)
	}
	for i := len(codings) - 1; i >= 0; i -= 1 {
		fn, found := find_decoder(codings[i])
		if !found do return .Unsupported_Encoding
		out := make([dynamic]byte, 0, max(len(r.body) * 4, 256), r.allocator)
		if err := fn(r.body[:], &out, max_out); err != .None {
			delete(out)
			return err
		}
		delete(r.body)
		r.body = out
	}
	return .None
}

@(private)
gzip_decode :: proc(src: []byte, dst: ^[dynamic]byte, max_out: int) -> Error {
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	if err := gzip.load(src, &buf); err != nil do return .Decompress
	if len(buf.buf) > max_out do return .Too_Large
	append(dst, ..buf.buf[:])
	return .None
}

// deflate: RFC 9110 says zlib-wrapped, but raw deflate is common in the wild; accept both.
@(private)
deflate_decode :: proc(src: []byte, dst: ^[dynamic]byte, max_out: int) -> Error {
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	if err := zlib.inflate(src, &buf); err != nil {
		bytes.buffer_reset(&buf)
		if err2 := zlib.inflate(src, &buf, true); err2 != nil do return .Decompress
	}
	if len(buf.buf) > max_out do return .Too_Large
	append(dst, ..buf.buf[:])
	return .None
}

@(private)
br_decode :: proc(src: []byte, dst: ^[dynamic]byte, max_out: int) -> Error {
	out, err := brotli.decompress(src, context.temp_allocator, max_out)
	if err == .Output_Too_Large do return .Too_Large
	if err != .None do return .Decompress
	append(dst, ..out)
	return .None
}

@(private)
zstd_decode :: proc(src: []byte, dst: ^[dynamic]byte, max_out: int) -> Error {
	out, err := zstd.decompress(src, context.temp_allocator, max_out)
	if err == .Output_Too_Large do return .Too_Large
	if err != .None do return .Decompress
	append(dst, ..out)
	return .None
}
