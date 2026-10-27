// HPACK encoder for our own requests, making the choices Chrome 148's makes (quiche HpackEncoder, as
// SpdyFramer::SerializeHeaders calls it), so header blocks are byte-identical to the official client's:
//   - exact (name, value) in the static, then the dynamic table: indexed field
//   - otherwise a literal, the name by index when found (static first, then the newest dynamic entry);
//     with incremental indexing for every header but the pseudo-headers, except :authority
//   - Huffman only when strictly shorter; cookies split into crumbs on ';'
//   - a table size update starts the next block after the server's SETTINGS_HEADER_TABLE_SIZE changes
// nghttp2's encoder never indexes authorization, short cookies, content-length and a few others, so
// h2.jai swaps its header blocks for these. Decoding the server's headers stays nghttp2's.

#scope_module

NO_MIN_BOUND :: 0x7fff_ffff_ffff_ffff;

Hpack_Encoder :: struct {
	table: [..]Header; // oldest first; owns its strings (from allocator)
	size: int;
	bound := 4096;     // the server's SETTINGS_HEADER_TABLE_SIZE, our table's maximum
	min_bound := NO_MIN_BOUND; // smallest bound since the last block
	emit_size: bool;
	allocator: Allocator;
}

hpack_destroy :: (e: *Hpack_Encoder) {
	push_allocator(e.allocator);
	clear_headers(*e.table);
	array_free(e.table);
}

// hpack_set_table_size applies one SETTINGS_HEADER_TABLE_SIZE from the server (ApplyHeaderTableSizeSetting).
hpack_set_table_size :: (e: *Hpack_Encoder, size: int) {
	if size == e.bound return;
	if size < e.bound e.min_bound = min(e.min_bound, size);
	e.bound = size;
	evict(e, 0);
	e.emit_size = true;
}

// hpack_encode appends req's header block: pseudo-headers in Chrome's order, then req.headers.
hpack_encode :: (e: *Hpack_Encoder, out: *[..]u8, req: Request) {
	if e.emit_size {
		if e.min_bound < e.bound put_int(out, 0x20, 5, e.min_bound);
		put_int(out, 0x20, 5, e.bound);
		e.emit_size = false;
		e.min_bound = NO_MIN_BOUND;
	}
	field(e, out, ":method", req.method);
	field(e, out, ":authority", req.authority);
	field(e, out, ":scheme", req.scheme);
	field(e, out, ":path", req.path);
	for h: req.headers {
		if h.name != "cookie" { field(e, out, h.name, h.value); continue; }
		v := trim(h.value, " \t");
		while true {
			found, crumb, rest := split_from_left(v, #char ";");
			field(e, out, h.name, crumb);
			if !found break;
			v = rest;
			if v && v[0] == #char " " advance(*v);
		}
	}
}

#scope_file

// evict drops the oldest entries until `room` more bytes fit.
evict :: (e: *Hpack_Encoder, room: int) {
	n := 0;
	while n < e.table.count && e.size + room > e.bound {
		h := e.table[n];
		e.size -= h.name.count + h.value.count + 32;
		free_string(h.name,, e.allocator);
		free_string(h.value,, e.allocator);
		n += 1;
	}
	if !n return;
	for i: n..e.table.count-1 e.table[i - n] = e.table[i];
	e.table.count -= n;
}

field :: (e: *Hpack_Encoder, out: *[..]u8, name: string, value: string) {
	full, by_name := 0, 0;
	for HPACK_STATIC {
		if it.name != name continue;
		if !by_name by_name = it_index + 1;
		if it.value == value { full = it_index + 1; break; }
	}
	if !full for < e.table {
		if it.name != name continue;
		idx := HPACK_STATIC.count + e.table.count - it_index;
		if !by_name by_name = idx;
		if it.value == value { full = idx; break; }
	}
	if full { put_int(out, 0x80, 7, full); return; }
	index := name[0] != #char ":" || name == ":authority";
	if index put_int(out, 0x40, 6, by_name);
	else     put_int(out, 0x00, 4, by_name);
	if !by_name put_string(out, name);
	put_string(out, value);
	if !index return;
	size := name.count + value.count + 32;
	evict(e, size);
	if e.size + size > e.bound return;
	array_add(*e.table, copy_header(name, value, e.allocator));
	e.size += size;
}

put_int :: (out: *[..]u8, first: u8, prefix: int, v: int) {
	limit := (1 << prefix) - 1;
	if v < limit { array_add(out, first | (cast(u8) v)); return; }
	array_add(out, first | (cast(u8) limit));
	r := v - limit;
	while r >= 128 {
		array_add(out, (cast(u8) (r & 0x7f)) | 0x80);
		r >>= 7;
	}
	array_add(out, cast(u8) r);
}

put_string :: (out: *[..]u8, s: string) {
	bits := 0;
	for s bits += HUFFMAN_LENS[it];
	if (bits + 7) / 8 >= s.count {
		put_int(out, 0, 7, s.count);
		array_add(out, ..cast([]u8) s);
		return;
	}
	put_int(out, 0x80, 7, (bits + 7) / 8);
	acc: u64;
	n: u64;
	for s {
		acc = (acc << HUFFMAN_LENS[it]) | (cast(u64) HUFFMAN_CODES[it]);
		n += HUFFMAN_LENS[it];
		while n >= 8 { array_add(out, cast(u8) (acc >> (n - 8))); n -= 8; }
	}
	if n array_add(out, (cast(u8) (acc << (8 - n))) | (cast(u8) (0xff >> n))); // padded with EOS's leading ones
}

// RFC 7541 Appendix A, 1-based on the wire.
HPACK_STATIC := Header.[
	.{":authority", ""}, .{":method", "GET"}, .{":method", "POST"}, .{":path", "/"}, .{":path", "/index.html"},
	.{":scheme", "http"}, .{":scheme", "https"}, .{":status", "200"}, .{":status", "204"}, .{":status", "206"},
	.{":status", "304"}, .{":status", "400"}, .{":status", "404"}, .{":status", "500"}, .{"accept-charset", ""},
	.{"accept-encoding", "gzip, deflate"}, .{"accept-language", ""}, .{"accept-ranges", ""}, .{"accept", ""},
	.{"access-control-allow-origin", ""}, .{"age", ""}, .{"allow", ""}, .{"authorization", ""},
	.{"cache-control", ""}, .{"content-disposition", ""}, .{"content-encoding", ""}, .{"content-language", ""},
	.{"content-length", ""}, .{"content-location", ""}, .{"content-range", ""}, .{"content-type", ""},
	.{"cookie", ""}, .{"date", ""}, .{"etag", ""}, .{"expect", ""}, .{"expires", ""}, .{"from", ""}, .{"host", ""},
	.{"if-match", ""}, .{"if-modified-since", ""}, .{"if-none-match", ""}, .{"if-range", ""},
	.{"if-unmodified-since", ""}, .{"last-modified", ""}, .{"link", ""}, .{"location", ""}, .{"max-forwards", ""},
	.{"proxy-authenticate", ""}, .{"proxy-authorization", ""}, .{"range", ""}, .{"referer", ""}, .{"refresh", ""},
	.{"retry-after", ""}, .{"server", ""}, .{"set-cookie", ""}, .{"strict-transport-security", ""},
	.{"transfer-encoding", ""}, .{"user-agent", ""}, .{"vary", ""}, .{"via", ""}, .{"www-authenticate", ""}
];

// RFC 7541 Appendix B. Index = byte value.
HUFFMAN_CODES := u32.[
	0x00001ff8, 0x007fffd8, 0x0fffffe2, 0x0fffffe3, 0x0fffffe4, 0x0fffffe5, 0x0fffffe6, 0x0fffffe7,
	0x0fffffe8, 0x00ffffea, 0x3ffffffc, 0x0fffffe9, 0x0fffffea, 0x3ffffffd, 0x0fffffeb, 0x0fffffec,
	0x0fffffed, 0x0fffffee, 0x0fffffef, 0x0ffffff0, 0x0ffffff1, 0x0ffffff2, 0x3ffffffe, 0x0ffffff3,
	0x0ffffff4, 0x0ffffff5, 0x0ffffff6, 0x0ffffff7, 0x0ffffff8, 0x0ffffff9, 0x0ffffffa, 0x0ffffffb,
	0x00000014, 0x000003f8, 0x000003f9, 0x00000ffa, 0x00001ff9, 0x00000015, 0x000000f8, 0x000007fa,
	0x000003fa, 0x000003fb, 0x000000f9, 0x000007fb, 0x000000fa, 0x00000016, 0x00000017, 0x00000018,
	0x00000000, 0x00000001, 0x00000002, 0x00000019, 0x0000001a, 0x0000001b, 0x0000001c, 0x0000001d,
	0x0000001e, 0x0000001f, 0x0000005c, 0x000000fb, 0x00007ffc, 0x00000020, 0x00000ffb, 0x000003fc,
	0x00001ffa, 0x00000021, 0x0000005d, 0x0000005e, 0x0000005f, 0x00000060, 0x00000061, 0x00000062,
	0x00000063, 0x00000064, 0x00000065, 0x00000066, 0x00000067, 0x00000068, 0x00000069, 0x0000006a,
	0x0000006b, 0x0000006c, 0x0000006d, 0x0000006e, 0x0000006f, 0x00000070, 0x00000071, 0x00000072,
	0x000000fc, 0x00000073, 0x000000fd, 0x00001ffb, 0x0007fff0, 0x00001ffc, 0x00003ffc, 0x00000022,
	0x00007ffd, 0x00000003, 0x00000023, 0x00000004, 0x00000024, 0x00000005, 0x00000025, 0x00000026,
	0x00000027, 0x00000006, 0x00000074, 0x00000075, 0x00000028, 0x00000029, 0x0000002a, 0x00000007,
	0x0000002b, 0x00000076, 0x0000002c, 0x00000008, 0x00000009, 0x0000002d, 0x00000077, 0x00000078,
	0x00000079, 0x0000007a, 0x0000007b, 0x00007ffe, 0x000007fc, 0x00003ffd, 0x00001ffd, 0x0ffffffc,
	0x000fffe6, 0x003fffd2, 0x000fffe7, 0x000fffe8, 0x003fffd3, 0x003fffd4, 0x003fffd5, 0x007fffd9,
	0x003fffd6, 0x007fffda, 0x007fffdb, 0x007fffdc, 0x007fffdd, 0x007fffde, 0x00ffffeb, 0x007fffdf,
	0x00ffffec, 0x00ffffed, 0x003fffd7, 0x007fffe0, 0x00ffffee, 0x007fffe1, 0x007fffe2, 0x007fffe3,
	0x007fffe4, 0x001fffdc, 0x003fffd8, 0x007fffe5, 0x003fffd9, 0x007fffe6, 0x007fffe7, 0x00ffffef,
	0x003fffda, 0x001fffdd, 0x000fffe9, 0x003fffdb, 0x003fffdc, 0x007fffe8, 0x007fffe9, 0x001fffde,
	0x007fffea, 0x003fffdd, 0x003fffde, 0x00fffff0, 0x001fffdf, 0x003fffdf, 0x007fffeb, 0x007fffec,
	0x001fffe0, 0x001fffe1, 0x003fffe0, 0x001fffe2, 0x007fffed, 0x003fffe1, 0x007fffee, 0x007fffef,
	0x000fffea, 0x003fffe2, 0x003fffe3, 0x003fffe4, 0x007ffff0, 0x003fffe5, 0x003fffe6, 0x007ffff1,
	0x03ffffe0, 0x03ffffe1, 0x000fffeb, 0x0007fff1, 0x003fffe7, 0x007ffff2, 0x003fffe8, 0x01ffffec,
	0x03ffffe2, 0x03ffffe3, 0x03ffffe4, 0x07ffffde, 0x07ffffdf, 0x03ffffe5, 0x00fffff1, 0x01ffffed,
	0x0007fff2, 0x001fffe3, 0x03ffffe6, 0x07ffffe0, 0x07ffffe1, 0x03ffffe7, 0x07ffffe2, 0x00fffff2,
	0x001fffe4, 0x001fffe5, 0x03ffffe8, 0x03ffffe9, 0x0ffffffd, 0x07ffffe3, 0x07ffffe4, 0x07ffffe5,
	0x000fffec, 0x00fffff3, 0x000fffed, 0x001fffe6, 0x003fffe9, 0x001fffe7, 0x001fffe8, 0x007ffff3,
	0x003fffea, 0x003fffeb, 0x01ffffee, 0x01ffffef, 0x00fffff4, 0x00fffff5, 0x03ffffea, 0x007ffff4,
	0x03ffffeb, 0x07ffffe6, 0x03ffffec, 0x03ffffed, 0x07ffffe7, 0x07ffffe8, 0x07ffffe9, 0x07ffffea,
	0x07ffffeb, 0x0ffffffe, 0x07ffffec, 0x07ffffed, 0x07ffffee, 0x07ffffef, 0x07fffff0, 0x03ffffee
];

HUFFMAN_LENS := u8.[
	13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28,
	28, 28, 28, 28, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28,
	6, 10, 10, 12, 13, 6, 8, 11, 10, 10, 8, 11, 8, 6, 6, 6,
	5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 7, 8, 15, 6, 12, 10,
	13, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
	7, 7, 7, 7, 7, 7, 7, 7, 8, 7, 8, 13, 19, 13, 14, 6,
	15, 5, 6, 5, 6, 5, 6, 6, 6, 5, 7, 7, 6, 6, 6, 5,
	6, 7, 6, 5, 5, 6, 7, 7, 7, 7, 7, 15, 11, 14, 13, 28,
	20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23,
	24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24,
	22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23,
	21, 21, 22, 21, 23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23,
	26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24, 25,
	19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27,
	20, 24, 20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23,
	26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26
];

