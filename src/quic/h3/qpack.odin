package h3

import "core:mem"
import "core:strings"

import "fc:http"

// QPACK (RFC 9204). The encoder makes QUICHE's choices with no dynamic table
// (Chrome never inserts unless the server grants capacity, and Cloudflare
// grants none): exact static match -> indexed; static name match -> literal
// with name reference; otherwise literal name; Huffman only when strictly
// shorter; cookie split into crumbs. The decoder supports the dynamic table
// (we advertise 64 KiB, as Chrome does).

Static_Entry :: struct {
	name, value: string,
}

@(rodata)
STATIC_TABLE := [99]Static_Entry {
	{":authority", ""},
	{":path", "/"},
	{"age", "0"},
	{"content-disposition", ""},
	{"content-length", "0"},
	{"cookie", ""},
	{"date", ""},
	{"etag", ""},
	{"if-modified-since", ""},
	{"if-none-match", ""},
	{"last-modified", ""},
	{"link", ""},
	{"location", ""},
	{"referer", ""},
	{"set-cookie", ""},
	{":method", "CONNECT"},
	{":method", "DELETE"},
	{":method", "GET"},
	{":method", "HEAD"},
	{":method", "OPTIONS"},
	{":method", "POST"},
	{":method", "PUT"},
	{":scheme", "http"},
	{":scheme", "https"},
	{":status", "103"},
	{":status", "200"},
	{":status", "304"},
	{":status", "404"},
	{":status", "503"},
	{"accept", "*/*"},
	{"accept", "application/dns-message"},
	{"accept-encoding", "gzip, deflate, br"},
	{"accept-ranges", "bytes"},
	{"access-control-allow-headers", "cache-control"},
	{"access-control-allow-headers", "content-type"},
	{"access-control-allow-origin", "*"},
	{"cache-control", "max-age=0"},
	{"cache-control", "max-age=2592000"},
	{"cache-control", "max-age=604800"},
	{"cache-control", "no-cache"},
	{"cache-control", "no-store"},
	{"cache-control", "public, max-age=31536000"},
	{"content-encoding", "br"},
	{"content-encoding", "gzip"},
	{"content-type", "application/dns-message"},
	{"content-type", "application/javascript"},
	{"content-type", "application/json"},
	{"content-type", "application/x-www-form-urlencoded"},
	{"content-type", "image/gif"},
	{"content-type", "image/jpeg"},
	{"content-type", "image/png"},
	{"content-type", "text/css"},
	{"content-type", "text/html; charset=utf-8"},
	{"content-type", "text/plain"},
	{"content-type", "text/plain;charset=utf-8"},
	{"range", "bytes=0-"},
	{"strict-transport-security", "max-age=31536000"},
	{"strict-transport-security", "max-age=31536000; includesubdomains"},
	{"strict-transport-security", "max-age=31536000; includesubdomains; preload"},
	{"vary", "accept-encoding"},
	{"vary", "origin"},
	{"x-content-type-options", "nosniff"},
	{"x-xss-protection", "1; mode=block"},
	{":status", "100"},
	{":status", "204"},
	{":status", "206"},
	{":status", "302"},
	{":status", "400"},
	{":status", "403"},
	{":status", "421"},
	{":status", "425"},
	{":status", "500"},
	{"accept-language", ""},
	{"access-control-allow-credentials", "FALSE"},
	{"access-control-allow-credentials", "TRUE"},
	{"access-control-allow-headers", "*"},
	{"access-control-allow-methods", "get"},
	{"access-control-allow-methods", "get, post, options"},
	{"access-control-allow-methods", "options"},
	{"access-control-expose-headers", "content-length"},
	{"access-control-request-headers", "content-type"},
	{"access-control-request-method", "get"},
	{"access-control-request-method", "post"},
	{"alt-svc", "clear"},
	{"authorization", ""},
	{"content-security-policy", "script-src 'none'; object-src 'none'; base-uri 'none'"},
	{"early-data", "1"},
	{"expect-ct", ""},
	{"forwarded", ""},
	{"if-range", ""},
	{"origin", ""},
	{"purpose", "prefetch"},
	{"server", ""},
	{"timing-allow-origin", "*"},
	{"upgrade-insecure-requests", "1"},
	{"user-agent", ""},
	{"x-forwarded-for", ""},
	{"x-frame-options", "deny"},
	{"x-frame-options", "sameorigin"},
}

// put_int appends an RFC 7541 prefix integer; first carries the high bits.
put_int :: proc(b: ^[dynamic]byte, first: u8, prefix: uint, v: u64) {
	m := u64(1) << prefix - 1
	if v < m {
		append(b, first | u8(v))
		return
	}
	append(b, first | u8(m))
	x := v - m
	for x >= 128 {
		append(b, u8(x & 0x7f) | 0x80)
		x >>= 7
	}
	append(b, u8(x))
}

// put_string writes a string with an H bit at bit `prefix` and a prefix-bit length.
put_string :: proc(b: ^[dynamic]byte, first: u8, prefix: uint, s: string) {
	hl := http.huffman_encoded_len(s)
	if hl < len(s) {
		put_int(b, first | u8(1) << prefix, prefix, u64(hl))
		http.huffman_encode(b, s)
	} else {
		put_int(b, first, prefix, u64(len(s)))
		append(b, ..transmute([]byte)s)
	}
}

@(private)
static_lookup :: proc(name, value: string) -> (exact: int, name_idx: int) {
	exact, name_idx = -1, -1
	for e, i in STATIC_TABLE {
		if e.name != name do continue
		if name_idx < 0 do name_idx = i
		if e.value == value do return i, name_idx
	}
	return
}

// encode_field appends one field line (static table only).
encode_field :: proc(b: ^[dynamic]byte, name, value: string) {
	exact, ni := static_lookup(name, value)
	switch {
	case exact >= 0:
		put_int(b, 0xc0, 6, u64(exact)) // indexed, static
	case ni >= 0:
		put_int(b, 0x50, 4, u64(ni)) // literal with static name reference, N=0
		put_string(b, 0, 7, value)
	case:
		put_string(b, 0x20, 3, name) // literal name
		put_string(b, 0, 7, value)
	}
}

// encode_section builds a field section: prefix (RIC 0, base 0) + fields.
// Cookies are split into crumbs on "; " as QUICHE's ValueSplittingHeaderList does.
encode_section :: proc(b: ^[dynamic]byte, fields: []http.Header) {
	append(b, 0, 0)
	for f in fields {
		if f.name == "cookie" {
			v := f.value
			for crumb in strings.split_iterator(&v, ";") {
				encode_field(b, f.name, strings.trim_left(crumb, " "))
			}
			continue
		}
		encode_field(b, f.name, f.value)
	}
}

// --- Decoder ---

Dyn_Entry :: struct {
	name, value: string,
}

Decoder :: struct {
	entries:      [dynamic]Dyn_Entry, // oldest first
	dropped:      u64, // absolute index of entries[0]
	size:         int,
	capacity:     int,
	max_capacity: int,
	enc_buf:      [dynamic]byte, // partial encoder-stream instruction
}

DECODER_MAX_CAPACITY :: 65536

decoder_init :: proc(d: ^Decoder) {
	d.max_capacity = DECODER_MAX_CAPACITY
}

decoder_destroy :: proc(d: ^Decoder) {
	for e in d.entries {
		delete(e.name)
		delete(e.value)
	}
	delete(d.entries)
	delete(d.enc_buf)
}

inserted :: proc(d: ^Decoder) -> u64 {return d.dropped + u64(len(d.entries))}

@(private)
evict_to :: proc(d: ^Decoder, cap: int) {
	for d.size > cap && len(d.entries) > 0 {
		e := d.entries[0]
		d.size -= len(e.name) + len(e.value) + 32
		delete(e.name)
		delete(e.value)
		ordered_remove(&d.entries, 0)
		d.dropped += 1
	}
}

@(private)
insert :: proc(d: ^Decoder, name, value: string) -> bool {
	sz := len(name) + len(value) + 32
	if sz > d.capacity do return false
	evict_to(d, d.capacity - sz)
	append(&d.entries, Dyn_Entry{strings.clone(name), strings.clone(value)})
	d.size += sz
	return true
}

@(private)
get_abs :: proc(d: ^Decoder, abs: u64) -> (Dyn_Entry, bool) {
	if abs < d.dropped || abs >= inserted(d) do return {}, false
	return d.entries[abs - d.dropped], true
}

// Byte cursor for prefix integers and strings.
Cursor :: struct {
	b:  []byte,
	ok: bool,
}

get_int :: proc(c: ^Cursor, prefix: uint) -> u64 {
	if !c.ok || len(c.b) == 0 {
		c.ok = false
		return 0
	}
	m := u64(1) << prefix - 1
	v := u64(c.b[0]) & m
	c.b = c.b[1:]
	if v < m do return v
	shift: uint
	for {
		if len(c.b) == 0 || shift > 56 {
			c.ok = false
			return 0
		}
		x := c.b[0]
		c.b = c.b[1:]
		v += u64(x & 0x7f) << shift
		shift += 7
		if x & 0x80 == 0 do break
	}
	return v
}

// get_string reads a string whose H bit is bit `prefix` of the first byte.
get_string :: proc(c: ^Cursor, prefix: uint, sb: ^strings.Builder) -> bool {
	if !c.ok || len(c.b) == 0 {
		c.ok = false
		return false
	}
	huff := c.b[0] & (u8(1) << prefix) != 0
	n := get_int(c, prefix)
	if !c.ok || n > u64(len(c.b)) {
		c.ok = false
		return false
	}
	raw := c.b[:n]
	c.b = c.b[n:]
	strings.builder_reset(sb)
	if huff {
		if http.huffman_decode(sb, raw) != .None do return false
	} else {
		strings.write_bytes(sb, raw)
	}
	return true
}

// feed_encoder_stream applies encoder instructions. Returns false on error
// (QPACK_ENCODER_STREAM_ERROR).
feed_encoder_stream :: proc(d: ^Decoder, data: []byte) -> bool {
	append(&d.enc_buf, ..data)
	name, value: strings.Builder
	defer strings.builder_destroy(&name)
	defer strings.builder_destroy(&value)
	for len(d.enc_buf) > 0 {
		c := Cursor{d.enc_buf[:], true}
		first := c.b[0]
		// Parse one instruction; c.ok == false means it is still incomplete.
		kind: int
		idx: u64
		static := false
		good := true
		switch {
		case first & 0x80 != 0:
			kind = 0 // insert with name reference
			static = first & 0x40 != 0
			idx = get_int(&c, 6)
			good = get_string(&c, 7, &value)
		case first & 0x40 != 0:
			kind = 1 // insert with literal name
			good = get_string(&c, 5, &name)
			if good do good = get_string(&c, 7, &value)
		case first & 0x20 != 0:
			kind = 2 // set capacity
			idx = get_int(&c, 5)
		case:
			kind = 3 // duplicate
			idx = get_int(&c, 5)
		}
		if !c.ok do break // wait for the rest of the instruction
		if !good do return false
		switch kind {
		case 0:
			if static {
				if idx >= len(STATIC_TABLE) do return false
				if !insert(d, STATIC_TABLE[idx].name, strings.to_string(value)) do return false
			} else {
				if idx >= inserted(d) do return false
				e, found := get_abs(d, inserted(d) - 1 - idx)
				if !found do return false
				nm := strings.clone(e.name, context.temp_allocator)
				if !insert(d, nm, strings.to_string(value)) do return false
			}
		case 1:
			if !insert(d, strings.to_string(name), strings.to_string(value)) do return false
		case 2:
			if idx > u64(d.max_capacity) do return false
			d.capacity = int(idx)
			evict_to(d, d.capacity)
		case 3:
			if idx >= inserted(d) do return false
			e, found := get_abs(d, inserted(d) - 1 - idx)
			if !found do return false
			nm := strings.clone(e.name, context.temp_allocator)
			vl := strings.clone(e.value, context.temp_allocator)
			if !insert(d, nm, vl) do return false
		}
		remove_range(&d.enc_buf, 0, len(d.enc_buf) - len(c.b))
	}
	return true
}

Decode_Result :: enum {
	Ok,
	Blocked, // needs more encoder-stream inserts
	Error,
}

// required_insert_count decodes the section prefix's RIC (RFC 9204 4.5.1.1).
required_insert_count :: proc(d: ^Decoder, block: []byte) -> (ric: u64, ok: bool) {
	c := Cursor{block, true}
	enc := get_int(&c, 8)
	if !c.ok do return 0, false
	if enc == 0 do return 0, true
	max_entries := u64(d.max_capacity / 32)
	full := 2 * max_entries
	if max_entries == 0 || enc > full do return 0, false
	total := inserted(d)
	max_value := total + max_entries
	max_wrapped := (max_value / full) * full
	ric = max_wrapped + enc - 1
	if ric > max_value {
		if ric <= full do return 0, false
		ric -= full
	}
	if ric == 0 do return 0, false
	return ric, true
}

// decode_section decodes a field section into headers (allocated with allocator).
decode_section :: proc(d: ^Decoder, block: []byte, out: ^[dynamic]http.Header, allocator := context.allocator) -> (Decode_Result, u64) {
	ric, ok := required_insert_count(d, block)
	if !ok do return .Error, 0
	if ric > inserted(d) do return .Blocked, ric
	c := Cursor{block, true}
	get_int(&c, 8)
	sign := len(c.b) > 0 && c.b[0] & 0x80 != 0
	delta := get_int(&c, 7)
	if !c.ok do return .Error, ric
	base: u64
	if sign {
		if delta + 1 > ric do return .Error, ric
		base = ric - delta - 1
	} else {
		base = ric + delta
	}
	name, value: strings.Builder
	defer strings.builder_destroy(&name)
	defer strings.builder_destroy(&value)
	emit :: proc(out: ^[dynamic]http.Header, n, v: string, allocator: mem.Allocator) {
		append(out, http.Header{strings.clone(n, allocator), strings.clone(v, allocator)})
	}
	dyn :: proc(d: ^Decoder, abs, ric: u64) -> (Dyn_Entry, bool) {
		if abs >= ric do return {}, false
		return get_abs(d, abs)
	}
	for len(c.b) > 0 && c.ok {
		first := c.b[0]
		switch {
		case first & 0x80 != 0:
			static := first & 0x40 != 0
			idx := get_int(&c, 6)
			if !c.ok do return .Error, ric
			if static {
				if idx >= len(STATIC_TABLE) do return .Error, ric
				emit(out, STATIC_TABLE[idx].name, STATIC_TABLE[idx].value, allocator)
			} else {
				if idx + 1 > base do return .Error, ric
				e, found := dyn(d, base - 1 - idx, ric)
				if !found do return .Error, ric
				emit(out, e.name, e.value, allocator)
			}
		case first & 0x40 != 0:
			static := first & 0x10 != 0
			idx := get_int(&c, 4)
			if !get_string(&c, 7, &value) do return .Error, ric
			n: string
			if static {
				if idx >= len(STATIC_TABLE) do return .Error, ric
				n = STATIC_TABLE[idx].name
			} else {
				if idx + 1 > base do return .Error, ric
				e, found := dyn(d, base - 1 - idx, ric)
				if !found do return .Error, ric
				n = e.name
			}
			emit(out, n, strings.to_string(value), allocator)
		case first & 0x20 != 0:
			if !get_string(&c, 3, &name) do return .Error, ric
			if !get_string(&c, 7, &value) do return .Error, ric
			emit(out, strings.to_string(name), strings.to_string(value), allocator)
		case first & 0x10 != 0:
			idx := get_int(&c, 4)
			if !c.ok do return .Error, ric
			e, found := dyn(d, base + idx, ric)
			if !found do return .Error, ric
			emit(out, e.name, e.value, allocator)
		case:
			idx := get_int(&c, 3)
			if !get_string(&c, 7, &value) do return .Error, ric
			e, found := dyn(d, base + idx, ric)
			if !found do return .Error, ric
			emit(out, e.name, strings.to_string(value), allocator)
		}
	}
	if !c.ok do return .Error, ric
	return .Ok, ric
}
