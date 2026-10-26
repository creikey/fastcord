package http

import "core:mem"
import "core:strings"

// HPACK (RFC 7541): static + dynamic table, Huffman, integer/string codecs.
//
// The encoder reproduces Chromium's quiche HpackEncoder choices:
//   - exact (name,value) hit in static then dynamic table -> indexed field
//   - otherwise "should index" -> literal with incremental indexing,
//     else literal without indexing; the name is referenced by index when
//     found (static table first, then the newest dynamic entry)
//   - should index = every header except pseudo-headers, but :authority IS indexed
//   - Huffman only when strictly shorter than the raw string
//   - cookie values are split into crumbs on ';' (one optional space eaten)
//   - values containing NUL are split into separate fields
//   - pseudo-headers are emitted before regular headers
//   - a dynamic table size update is emitted at the start of the next block
//     after the peer's SETTINGS_HEADER_TABLE_SIZE changes (min first if it shrank)

HPACK_DEFAULT_TABLE_SIZE :: 4096

@(private)
Dyn_Entry :: struct {
	name, value: string,
	raw:         []byte,
}

Dyn_Table :: struct {
	entries:   [dynamic]Dyn_Entry, // oldest first, starting at head
	head:      int,
	size:      int,
	max_size:  int,
	allocator: mem.Allocator,
}

@(private)
entry_size :: #force_inline proc(name, value: string) -> int {return len(name) + len(value) + 32}

dyn_init :: proc(t: ^Dyn_Table, max_size: int, allocator: mem.Allocator) {
	t.allocator = allocator
	t.entries = make([dynamic]Dyn_Entry, 0, 32, allocator)
	t.max_size = max_size
}

dyn_destroy :: proc(t: ^Dyn_Table) {
	for i in t.head ..< len(t.entries) do delete(t.entries[i].raw, t.allocator)
	delete(t.entries)
	t^ = {}
}

dyn_count :: proc(t: ^Dyn_Table) -> int {return len(t.entries) - t.head}

// dyn_get: i = 0 is the newest entry (wire index 62).
@(private)
dyn_get :: proc(t: ^Dyn_Table, i: int) -> ^Dyn_Entry {
	return &t.entries[len(t.entries) - 1 - i]
}

@(private)
dyn_evict_to :: proc(t: ^Dyn_Table, limit: int) {
	for t.size > limit && t.head < len(t.entries) {
		e := &t.entries[t.head]
		t.size -= entry_size(e.name, e.value)
		delete(e.raw, t.allocator)
		e^ = {}
		t.head += 1
	}
	if t.head > 32 && t.head * 2 > len(t.entries) {
		n := copy(t.entries[:], t.entries[t.head:])
		resize(&t.entries, n)
		t.head = 0
	}
}

dyn_set_max :: proc(t: ^Dyn_Table, max_size: int) {
	t.max_size = max_size
	dyn_evict_to(t, max_size)
}

dyn_add :: proc(t: ^Dyn_Table, name, value: string) {
	sz := entry_size(name, value)
	if sz > t.max_size {
		dyn_evict_to(t, 0)
		return
	}
	dyn_evict_to(t, t.max_size - sz)
	raw := make([]byte, len(name) + len(value), t.allocator)
	copy(raw, name)
	copy(raw[len(name):], value)
	append(&t.entries, Dyn_Entry{name = string(raw[:len(name)]), value = string(raw[len(name):]), raw = raw})
	t.size += sz
}

// ---- primitives ----

hpack_put_int :: proc(out: ^[dynamic]byte, first: u8, prefix_bits: uint, value: int) {
	limit := (1 << prefix_bits) - 1
	if value < limit {
		append(out, first | u8(value))
		return
	}
	append(out, first | u8(limit))
	v := value - limit
	for v >= 128 {
		append(out, u8(v & 0x7f) | 0x80)
		v >>= 7
	}
	append(out, u8(v))
}

@(private)
hpack_get_int :: proc(data: []byte, pos: ^int, prefix_bits: uint) -> (int, Error) {
	if pos^ >= len(data) do return 0, .Protocol
	limit := (1 << prefix_bits) - 1
	v := int(data[pos^]) & limit
	pos^ += 1
	if v < limit do return v, .None
	shift: uint = 0
	for {
		if pos^ >= len(data) do return 0, .Protocol
		b := data[pos^]
		pos^ += 1
		if shift > 28 do return 0, .Protocol
		v += int(b & 0x7f) << shift
		shift += 7
		if b & 0x80 == 0 do break
	}
	if v > 1 << 30 do return 0, .Protocol
	return v, .None
}

huffman_encoded_len :: proc(s: string) -> int {
	bits := 0
	for c in transmute([]byte)s do bits += int(HUFFMAN_LENS[c])
	return (bits + 7) / 8
}

huffman_encode :: proc(out: ^[dynamic]byte, s: string) {
	acc: u64
	nbits: uint
	for c in transmute([]byte)s {
		l := uint(HUFFMAN_LENS[c])
		acc = acc << l | u64(HUFFMAN_CODES[c])
		nbits += l
		for nbits >= 8 {
			nbits -= 8
			append(out, u8(acc >> nbits))
		}
	}
	if nbits > 0 {
		// pad with the EOS prefix (all ones)
		append(out, u8(acc << (8 - nbits)) | u8(0xff >> nbits))
	}
}

// Decoding tree: node i has children [0],[1]; value >= 0 is a node, < 0 is -(sym+1).
@(private)
huff_tree: [512][2]i16
@(private)
huff_nodes: int

@(init, private)
build_huffman_tree :: proc "contextless" () {
	huff_nodes = 1
	add :: proc "contextless" (sym: int, code: u32, length: uint) {
		node := 0
		for i := int(length) - 1; i >= 0; i -= 1 {
			bit := (code >> uint(i)) & 1
			if i == 0 {
				huff_tree[node][bit] = i16(-(sym + 1))
			} else {
				if huff_tree[node][bit] == 0 {
					huff_tree[node][bit] = i16(huff_nodes)
					huff_nodes += 1
				}
				node = int(huff_tree[node][bit])
			}
		}
	}
	for s in 0 ..< 256 do add(s, HUFFMAN_CODES[s], uint(HUFFMAN_LENS[s]))
	add(256, 0x3fffffff, 30)
}

huffman_decode :: proc(sb: ^strings.Builder, data: []byte) -> Error {
	node := 0
	depth := 0
	ones := true
	for b in data {
		for i := 7; i >= 0; i -= 1 {
			bit := (b >> uint(i)) & 1
			next := huff_tree[node][bit]
			depth += 1
			if bit == 0 do ones = false
			if next < 0 {
				sym := int(-next) - 1
				if sym == 256 do return .Protocol // EOS in string
				strings.write_byte(sb, u8(sym))
				node = 0
				depth = 0
				ones = true
			} else if next == 0 {
				return .Protocol
			} else {
				node = int(next)
			}
		}
	}
	if depth > 7 || !ones do return .Protocol
	return .None
}

@(private)
put_string :: proc(out: ^[dynamic]byte, s: string, use_huffman: bool, on_tie := false) {
	if use_huffman {
		hl := huffman_encoded_len(s)
		if hl < len(s) || (on_tie && hl == len(s)) {
			hpack_put_int(out, 0x80, 7, hl)
			huffman_encode(out, s)
			return
		}
	}
	hpack_put_int(out, 0, 7, len(s))
	append(out, s)
}

@(private)
get_string :: proc(data: []byte, pos: ^int, sb: ^strings.Builder) -> (s: string, err: Error) {
	if pos^ >= len(data) do return "", .Protocol
	huff := data[pos^] & 0x80 != 0
	n := hpack_get_int(data, pos, 7) or_return
	if n > len(data) - pos^ do return "", .Protocol
	raw := data[pos^:][:n]
	pos^ += n
	strings.builder_reset(sb)
	if huff {
		huffman_decode(sb, raw) or_return
	} else {
		strings.write_bytes(sb, raw)
	}
	return strings.to_string(sb^), .None
}

// ---- encoder ----

Index_Policy :: #type proc(name, value: string) -> bool

// chrome_index_policy is quiche's HpackEncoder::DefaultPolicy.
chrome_index_policy :: proc(name, value: string) -> bool {
	if len(name) == 0 do return false
	if name[0] == ':' do return name == ":authority"
	return true
}

Hpack_Encoder :: struct {
	table:                   Dyn_Table,
	settings_bound:          int,
	min_size_received:       int,
	should_emit_size:        bool,
	huffman:                 bool,
	policy:                  Index_Policy,
	split_cookies:           bool,
	huffman_on_tie:          bool, // false (Chrome): Huffman only when strictly shorter
}

hpack_encoder_init :: proc(e: ^Hpack_Encoder, allocator := context.allocator) {
	dyn_init(&e.table, HPACK_DEFAULT_TABLE_SIZE, allocator)
	e.settings_bound = HPACK_DEFAULT_TABLE_SIZE
	e.min_size_received = max(int)
	e.huffman = true
	e.policy = chrome_index_policy
	e.split_cookies = true
}

hpack_encoder_destroy :: proc(e: ^Hpack_Encoder) {dyn_destroy(&e.table)}

// hpack_encoder_set_peer_table_size applies the peer's SETTINGS_HEADER_TABLE_SIZE.
hpack_encoder_set_peer_table_size :: proc(e: ^Hpack_Encoder, size: int) {
	if size == e.settings_bound do return
	if size < e.settings_bound do e.min_size_received = min(size, e.min_size_received)
	e.settings_bound = size
	dyn_set_max(&e.table, size)
	e.should_emit_size = true
}

@(private)
find_static :: proc(name, value: string) -> (full: int, name_only: int) {
	for h, i in STATIC_TABLE {
		if h.name == name {
			if name_only == 0 do name_only = i + 1
			if h.value == value do return i + 1, name_only
		}
	}
	return 0, name_only
}

@(private)
find_dynamic :: proc(t: ^Dyn_Table, name, value: string) -> (full: int, name_only: int) {
	n := dyn_count(t)
	for i in 0 ..< n {
		en := dyn_get(t, i)
		if en.name == name {
			if name_only == 0 do name_only = 62 + i
			if en.value == value do return 62 + i, name_only
		}
	}
	return 0, name_only
}

@(private)
encode_one :: proc(e: ^Hpack_Encoder, out: ^[dynamic]byte, name, value: string) {
	sfull, sname := find_static(name, value)
	if sfull != 0 {
		hpack_put_int(out, 0x80, 7, sfull)
		return
	}
	dfull, dname := find_dynamic(&e.table, name, value)
	if dfull != 0 {
		hpack_put_int(out, 0x80, 7, dfull)
		return
	}
	name_idx := sname if sname != 0 else dname
	if e.policy(name, value) {
		hpack_put_int(out, 0x40, 6, name_idx)
		if name_idx == 0 do put_string(out, name, e.huffman, e.huffman_on_tie)
		put_string(out, value, e.huffman, e.huffman_on_tie)
		dyn_add(&e.table, name, value)
	} else {
		hpack_put_int(out, 0x00, 4, name_idx)
		if name_idx == 0 do put_string(out, name, e.huffman, e.huffman_on_tie)
		put_string(out, value, e.huffman, e.huffman_on_tie)
	}
}

@(private)
encode_decomposed :: proc(e: ^Hpack_Encoder, out: ^[dynamic]byte, name, value: string) {
	v := value
	for {
		i := strings.index_byte(v, 0)
		if i < 0 {
			encode_one(e, out, name, v)
			return
		}
		encode_one(e, out, name, v[:i])
		v = v[i + 1:]
	}
}

@(private)
encode_cookie :: proc(e: ^Hpack_Encoder, out: ^[dynamic]byte, name, value: string) {
	v := strings.trim(value, " \t")
	pos := 0
	for {
		end := strings.index_byte(v[pos:], ';')
		if end < 0 {
			encode_one(e, out, name, v[pos:])
			return
		}
		encode_one(e, out, name, v[pos:][:end])
		pos += end + 1
		if pos != len(v) && v[pos] == ' ' do pos += 1
	}
}

// hpack_encode appends one header block. Names must be lowercase (h2).
hpack_encode :: proc(e: ^Hpack_Encoder, headers: []Header, out: ^[dynamic]byte) {
	if e.should_emit_size {
		if e.min_size_received < e.settings_bound do hpack_put_int(out, 0x20, 5, e.min_size_received)
		hpack_put_int(out, 0x20, 5, e.settings_bound)
		e.should_emit_size = false
		e.min_size_received = max(int)
	}
	for h in headers {
		if len(h.name) > 0 && h.name[0] == ':' do encode_decomposed(e, out, h.name, h.value)
	}
	for h in headers {
		if len(h.name) > 0 && h.name[0] == ':' do continue
		if e.split_cookies && h.name == "cookie" {
			encode_cookie(e, out, h.name, h.value)
		} else {
			encode_decomposed(e, out, h.name, h.value)
		}
	}
}

// ---- decoder ----

Hpack_Decoder :: struct {
	table:           Dyn_Table,
	max_allowed:     int, // our SETTINGS_HEADER_TABLE_SIZE
	max_header_list: int, // our SETTINGS_MAX_HEADER_LIST_SIZE (0 = unlimited)
	sb_name:         strings.Builder,
	sb_value:        strings.Builder,
}

hpack_decoder_init :: proc(d: ^Hpack_Decoder, max_table := HPACK_DEFAULT_TABLE_SIZE, max_header_list := 0, allocator := context.allocator) {
	// The decoder's table starts at the protocol default 4096 until the encoder
	// sends a size update; it may grow to max_allowed once our SETTINGS is acked.
	dyn_init(&d.table, HPACK_DEFAULT_TABLE_SIZE, allocator)
	d.max_allowed = max_table
	d.max_header_list = max_header_list
	d.sb_name = strings.builder_make(allocator)
	d.sb_value = strings.builder_make(allocator)
}

hpack_decoder_destroy :: proc(d: ^Hpack_Decoder) {
	dyn_destroy(&d.table)
	strings.builder_destroy(&d.sb_name)
	strings.builder_destroy(&d.sb_value)
}

// hpack_decode decodes a complete header block, appending fields (allocated
// with `allocator`) to out. Errors are COMPRESSION_ERROR-class (connection fatal)
// except .Too_Large, which is reported after the whole block was processed so
// the dynamic table stays in sync.
hpack_decode :: proc(d: ^Hpack_Decoder, block: []byte, out: ^[dynamic]Header, allocator := context.allocator) -> Error {
	pos := 0
	list_size := 0
	too_large := false
	seen_field := false
	for pos < len(block) {
		b := block[pos]
		name, value: string
		switch {
		case b & 0x80 != 0: // indexed
			idx := hpack_get_int(block, &pos, 7) or_return
			n, v, ok := lookup(d, idx)
			if !ok do return .Protocol
			name, value = n, v
		case b & 0xe0 == 0x20: // dynamic table size update
			if seen_field do return .Protocol
			sz := hpack_get_int(block, &pos, 5) or_return
			if sz > d.max_allowed do return .Protocol
			dyn_set_max(&d.table, sz)
			continue
		case:
			prefix: uint = 4
			indexing := false
			if b & 0x40 != 0 {
				prefix = 6
				indexing = true
			}
			idx := hpack_get_int(block, &pos, prefix) or_return
			if idx == 0 {
				s := get_string(block, &pos, &d.sb_name) or_return
				name = s
			} else {
				n, _, ok := lookup(d, idx)
				if !ok do return .Protocol
				strings.builder_reset(&d.sb_name)
				strings.write_string(&d.sb_name, n)
				name = strings.to_string(d.sb_name)
			}
			value = get_string(block, &pos, &d.sb_value) or_return
			if indexing do dyn_add(&d.table, name, value)
		}
		seen_field = true
		list_size += entry_size(name, value)
		if d.max_header_list > 0 && list_size > d.max_header_list {
			too_large = true
			continue
		}
		append(out, Header{strings.clone(name, allocator), strings.clone(value, allocator)})
	}
	return .Too_Large if too_large else .None
}

@(private)
lookup :: proc(d: ^Hpack_Decoder, idx: int) -> (string, string, bool) {
	if idx <= 0 do return "", "", false
	if idx <= len(STATIC_TABLE) {
		h := STATIC_TABLE[idx - 1]
		return h.name, h.value, true
	}
	i := idx - len(STATIC_TABLE) - 1
	if i >= dyn_count(&d.table) do return "", "", false
	e := dyn_get(&d.table, i)
	return e.name, e.value, true
}
