// Package brotli is a from-scratch Brotli (RFC 7932) decoder: all meta-block
// kinds, block switching, context modeling, the static dictionary and its
// 121 transforms. One-shot only (whole input in memory).
//
// dictionary.bin is the 122,784-byte RFC 7932 Appendix A dictionary. It was
// dumped from Homebrew's libbrotlicommon 1.2.0 (BrotliGetDictionary()) and its
// SHA-256 matches the one given in the RFC:
//   20e42eb1b511c21806d4d227d07e5dd06877d8ce7b3a817f378f313653f35c70
package brotli

import "base:intrinsics"
import "base:runtime"
import "core:mem"

Error :: enum u8 {
	None,
	Truncated,
	Corrupt,
	Output_Too_Large,
	Out_Of_Memory,
}

@(private)
DICT_DATA :: #load("dictionary.bin")
@(private)
DICT := DICT_DATA

@(private)
DICT_NDBITS := [25]u8{0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5}
@(private)
DICT_OFFSET := [25]u32 {
	0, 0, 0, 0, 0, 4096, 9216, 21504, 35840, 44032, 53248, 63488, 74752, 87040,
	93696, 100864, 104704, 106752, 108928, 113536, 115968, 118528, 119872, 121280, 122016,
}

// ---------------------------------------------------------------------------
// Bit reader: LSB-first, 64-bit buffer. Reading past the end yields zeros and
// is detected by `overrun`.

@(private)
Reader :: struct {
	data:  []byte,
	pos:   int, // may run past len(data) by padding
	bits:  u64,
	nbits: u32,
}

@(private)
fill :: #force_inline proc "contextless" (r: ^Reader) {
	if r.pos + 8 <= len(r.data) {
		v := u64(intrinsics.unaligned_load((^u64le)(raw_data(r.data)[r.pos:])))
		r.bits |= v << (r.nbits & 63)
		r.pos += int((63 - r.nbits) >> 3)
		r.nbits |= 56
	} else {
		fill_slow(r)
	}
}

@(private)
fill_slow :: #force_no_inline proc "contextless" (r: ^Reader) {
	for r.nbits <= 56 {
		b: u64
		if r.pos < len(r.data) do b = u64(r.data[r.pos])
		r.bits |= b << (r.nbits & 63)
		r.pos += 1
		r.nbits += 8
	}
}

@(private)
read :: #force_inline proc "contextless" (r: ^Reader, n: u32) -> u32 {
	if r.nbits < n do fill(r)
	v := u32(r.bits & ((u64(1) << (n & 63)) - 1))
	r.bits >>= n & 63
	r.nbits -= n
	return v
}

@(private)
overrun :: #force_inline proc "contextless" (r: ^Reader) -> bool {
	return r.pos * 8 - int(r.nbits) > len(r.data) * 8
}

// Drop bits to the next byte boundary; they must be zero.
@(private)
align :: proc "contextless" (r: ^Reader) -> bool {
	k := r.nbits & 7
	return read(r, k) == 0
}

// Byte position of the next unread byte (reader must be byte aligned).
@(private)
byte_pos :: proc "contextless" (r: ^Reader) -> int {
	return r.pos - int(r.nbits >> 3)
}

@(private)
seek :: proc "contextless" (r: ^Reader, p: int) {
	r.pos = p
	r.bits = 0
	r.nbits = 0
}

// ---------------------------------------------------------------------------
// Prefix codes. A table entry is value | bits << 16. Root tables index 8 bits;
// a root entry with bits > 8 points (value = absolute index) at a subtable of
// 2^(bits-8) entries.

@(private)
ROOT_BITS :: 8
@(private)
MAX_TABLE :: 2048

@(private)
decode_sym :: #force_inline proc "contextless" (r: ^Reader, t: [^]u32) -> u32 #no_bounds_check {
	if r.nbits < 15 do fill(r)
	e := t[r.bits & 0xFF]
	nb := e >> 16
	if nb > ROOT_BITS {
		r.bits >>= ROOT_BITS
		r.nbits -= ROOT_BITS
		sb := nb - ROOT_BITS
		e = t[(e & 0xFFFF) + u32(r.bits & ((u64(1) << sb) - 1))]
		nb = e >> 16
	}
	r.bits >>= nb
	r.nbits -= nb
	return e & 0xFFFF
}

@(private)
next_key :: #force_inline proc "contextless" (key: u32, length: u32) -> u32 {
	step := u32(1) << (length - 1)
	for key & step != 0 do step >>= 1
	return (key & (step - 1)) + step
}

// Builds a table for the given code lengths (a complete prefix code, or a
// single symbol with length 0 handled by the caller). Returns table size.
@(private)
build_table :: proc "contextless" (out: []u32, lengths: []u8, root: u32) -> (int, bool) {
	count: [16]int
	for l in lengths do count[l] += 1
	count[0] = 0
	offs: [17]int
	for l in 1 ..= 15 do offs[l + 1] = offs[l] + count[l]
	sorted: [1024]u16
	for l, s in lengths {
		if l != 0 {
			sorted[offs[l]] = u16(s)
			offs[l] += 1
		}
	}
	root_size := 1 << root
	key: u32
	si := 0
	for length in 1 ..= root {
		for _ in 0 ..< count[length] {
			e := u32(sorted[si]) | length << 16
			si += 1
			for k := int(key); k < root_size; k += 1 << length do out[k] = e
			key = next_key(key, length)
		}
	}
	total := root_size
	mask := u32(root_size - 1)
	sub_low := ~u32(0)
	sub_start, sub_size := 0, 0
	for length in root + 1 ..= 15 {
		for count[length] > 0 {
			low := key & mask
			if low != sub_low {
				// size the subtable by the remaining code space under this prefix
				l := int(length)
				left := 1 << (u32(l) - root)
				for l < 15 {
					left -= count[l]
					if left <= 0 do break
					l += 1
					left <<= 1
				}
				sub_bits := u32(l) - root
				sub_start = total
				sub_size = 1 << sub_bits
				total += sub_size
				if total > len(out) do return 0, false
				out[low] = u32(sub_start) | (sub_bits + root) << 16
				sub_low = low
			}
			e := u32(sorted[si]) | (length - root) << 16
			si += 1
			for k := int(key >> root); k < sub_size; k += 1 << (length - root) do out[sub_start + k] = e
			key = next_key(key, length)
			count[length] -= 1
		}
	}
	return total, true
}

@(private)
CODE_LENGTH_ORDER := [18]u8{1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15}
@(private)
CLC_LEN := [16]u8{2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4}
@(private)
CLC_VAL := [16]u8{0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5}

// Reads one prefix code over `alphabet` symbols and appends its table to tabs.
// Returns the table's offset in tabs.
@(private)
read_prefix_code :: proc(r: ^Reader, alphabet: int, tabs: ^[dynamic]u32) -> (int, Error) {
	lengths: [1024]u8
	scratch: [MAX_TABLE]u32
	size := 0
	hskip := read(r, 2)
	if hskip == 1 {
		abits := 32 - intrinsics.count_leading_zeros(u32(alphabet - 1))
		nsym := int(read(r, 2)) + 1
		syms: [4]u32
		for i in 0 ..< nsym {
			syms[i] = read(r, abits)
			if int(syms[i]) >= alphabet do return 0, .Corrupt
			for j in 0 ..< i do if syms[j] == syms[i] do return 0, .Corrupt
		}
		switch nsym {
		case 1:
			for i in 0 ..< 1 << ROOT_BITS do scratch[i] = syms[0]
			size = 1 << ROOT_BITS
		case 2:
			lengths[syms[0]], lengths[syms[1]] = 1, 1
		case 3:
			lengths[syms[0]], lengths[syms[1]], lengths[syms[2]] = 1, 2, 2
		case 4:
			if read(r, 1) == 0 {
				for s in syms do lengths[s] = 2
			} else {
				lengths[syms[0]], lengths[syms[1]], lengths[syms[2]], lengths[syms[3]] = 1, 2, 3, 3
			}
		}
	} else {
		clcl: [18]u8
		space := 32
		num := 0
		for i := int(hskip); i < 18; i += 1 {
			if r.nbits < 4 do fill(r)
			k := r.bits & 15
			r.bits >>= CLC_LEN[k]
			r.nbits -= u32(CLC_LEN[k])
			v := CLC_VAL[k]
			clcl[CODE_LENGTH_ORDER[i]] = v
			if v != 0 {
				space -= 32 >> v
				num += 1
				if space <= 0 do break
			}
		}
		if !(num == 1 || space == 0) do return 0, .Corrupt
		clt: [32]u32
		if num == 1 {
			for l, s in clcl do if l != 0 do for i in 0 ..< 32 do clt[i] = u32(s)
		} else {
			if _, ok := build_table(clt[:], clcl[:], 5); !ok do return 0, .Corrupt
		}
		sym := 0
		prev_len := u8(8)
		repeat := 0
		repeat_len := u8(0)
		sp := 32768
		for sym < alphabet && sp > 0 {
			if r.nbits < 5 do fill(r)
			e := clt[r.bits & 31]
			nb := e >> 16
			r.bits >>= nb
			r.nbits -= nb
			p := u8(e & 0xFFFF)
			if p < 16 {
				repeat = 0
				lengths[sym] = p
				sym += 1
				if p != 0 {
					prev_len = p
					sp -= 32768 >> p
				}
			} else {
				extra := p == 16 ? u32(2) : u32(3)
				new_len := p == 16 ? prev_len : 0
				if repeat_len != new_len {
					repeat = 0
					repeat_len = new_len
				}
				old := repeat
				if repeat > 0 {
					repeat -= 2
					repeat <<= extra
				}
				repeat += int(read(r, extra)) + 3
				delta := repeat - old
				if sym + delta > alphabet do return 0, .Corrupt
				for i in 0 ..< delta do lengths[sym + i] = repeat_len
				sym += delta
				if repeat_len != 0 do sp -= delta << (15 - repeat_len)
			}
		}
		if sp != 0 do return 0, .Corrupt
	}
	if overrun(r) do return 0, .Truncated
	if size == 0 {
		ok: bool
		size, ok = build_table(scratch[:], lengths[:alphabet], ROOT_BITS)
		if !ok do return 0, .Corrupt
	}
	off := len(tabs)
	append(tabs, ..scratch[:size])
	return off, .None
}

// ---------------------------------------------------------------------------
// Block switching

@(private)
BLEN_BASE := [26]u32 {
	1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209,
	241, 305, 369, 497, 753, 1265, 2289, 4337, 8433, 16625,
}
@(private)
BLEN_BITS := [26]u8{2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24}

@(private)
Block_Cat :: struct {
	ntypes:    u32,
	type_tab:  int,
	count_tab: int,
	cur, prev: u32,
	left:      u32,
}

@(private)
read_varlen8 :: proc "contextless" (r: ^Reader) -> u32 {
	if read(r, 1) == 0 do return 1
	n := read(r, 3)
	if n == 0 do return 2
	return (u32(1) << n) + 1 + read(r, n)
}

@(private)
read_block_len :: #force_inline proc "contextless" (r: ^Reader, t: [^]u32) -> u32 {
	s := decode_sym(r, t)
	return BLEN_BASE[s] + read(r, u32(BLEN_BITS[s]))
}

@(private)
read_block_cat :: proc(r: ^Reader, c: ^Block_Cat, tabs: ^[dynamic]u32) -> Error {
	c^ = {}
	c.ntypes = read_varlen8(r)
	c.prev = 1
	if c.ntypes < 2 {
		c.left = 1 << 28
		return .None
	}
	c.type_tab = read_prefix_code(r, int(c.ntypes) + 2, tabs) or_return
	c.count_tab = read_prefix_code(r, 26, tabs) or_return
	c.left = read_block_len(r, raw_data(tabs[c.count_tab:]))
	return .None
}

@(private)
switch_block :: proc "contextless" (r: ^Reader, c: ^Block_Cat, tabs: [^]u32) {
	s := decode_sym(r, tabs[c.type_tab:])
	t: u32
	switch s {
	case 0:
		t = c.prev
	case 1:
		t = c.cur + 1
		if t >= c.ntypes do t -= c.ntypes
	case:
		t = s - 2
	}
	c.prev = c.cur
	c.cur = t
	c.left = read_block_len(r, tabs[c.count_tab:])
}

// ---------------------------------------------------------------------------
// Context map

@(private)
read_context_map :: proc(r: ^Reader, cmap: []u8, ntrees: u32, tabs: ^[dynamic]u32) -> Error {
	for &v in cmap do v = 0
	if ntrees < 2 do return .None
	rlemax: u32
	if read(r, 1) == 1 do rlemax = read(r, 4) + 1
	t := read_prefix_code(r, int(ntrees + rlemax), tabs) or_return
	tab := raw_data(tabs[t:])
	i := 0
	for i < len(cmap) {
		s := decode_sym(r, tab)
		if s == 0 {
			cmap[i] = 0
			i += 1
		} else if s <= rlemax {
			reps := int((u32(1) << s) + read(r, s))
			if i + reps > len(cmap) do return .Corrupt
			for k in 0 ..< reps do cmap[i + k] = 0
			i += reps
		} else {
			cmap[i] = u8(s - rlemax)
			i += 1
		}
		if overrun(r) do return .Truncated
	}
	if read(r, 1) == 1 {
		mtf: [256]u8
		for k in 0 ..< 256 do mtf[k] = u8(k)
		for &v in cmap {
			idx := v
			val := mtf[idx]
			v = val
			for k := int(idx); k > 0; k -= 1 do mtf[k] = mtf[k - 1]
			mtf[0] = val
		}
	}
	return .None
}

// ---------------------------------------------------------------------------
// Literal context lookup (RFC 7932 section 7.1). CTX[mode][p1] | CTX[mode][256+p2].

@(private)
LUT0 := [256]u8 {
	0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 4, 0, 0, 4, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	8, 12, 16, 12, 12, 20, 12, 16, 24, 28, 12, 12, 32, 12, 36, 12,
	44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 32, 32, 24, 40, 28, 12,
	12, 48, 52, 52, 52, 48, 52, 52, 52, 48, 52, 52, 52, 52, 52, 48,
	52, 52, 52, 52, 52, 48, 52, 52, 52, 52, 52, 24, 12, 28, 12, 12,
	12, 56, 60, 60, 60, 56, 60, 60, 60, 56, 60, 60, 60, 60, 60, 56,
	60, 60, 60, 60, 60, 56, 60, 60, 60, 60, 60, 24, 12, 28, 12, 0,
	0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
	0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
	0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
	0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
	2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3,
	2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3,
	2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3,
	2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3,
}
@(private)
LUT1 := [256]u8 {
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
	2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1,
	1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
	2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1,
	1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
	3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 1, 1, 1, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
	2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
}

@(private)
CTX: [4][512]u8

@(private, init)
init_ctx :: proc "contextless" () {
	for i in 0 ..< 256 {
		lut2: u8
		switch {
		case i == 0: lut2 = 0
		case i < 16: lut2 = 1
		case i < 64: lut2 = 2
		case i < 128: lut2 = 3
		case i < 192: lut2 = 4
		case i < 240: lut2 = 5
		case i < 255: lut2 = 6
		case: lut2 = 7
		}
		CTX[0][i] = u8(i & 63)
		CTX[1][i] = u8(i >> 2)
		CTX[2][i] = LUT0[i]
		CTX[2][256 + i] = LUT1[i]
		CTX[3][i] = lut2 << 3
		CTX[3][256 + i] = lut2
	}
}

// ---------------------------------------------------------------------------
// Commands

@(private)
INS_BASE := [24]u32{0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594}
@(private)
INS_BITS := [24]u8{0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24}
@(private)
COPY_BASE := [24]u32{2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118}
@(private)
COPY_BITS := [24]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24}
@(private)
CELL_INS := [11]u32{0, 0, 0, 0, 8, 8, 0, 16, 8, 16, 16}
@(private)
CELL_COPY := [11]u32{0, 8, 0, 8, 0, 8, 16, 0, 16, 8, 16}
@(private)
DIST_IDX := [16]u32{0, 1, 2, 3, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1}
@(private)
DIST_DELTA := [16]i32{0, 0, 0, 0, -1, 1, -2, 2, -3, 3, -1, 1, -2, 2, -3, 3}

@(private)
Decoder :: struct {
	r:        Reader,
	out:      [dynamic]byte,
	max_out:  int,
	window:   int,
	dist_rb:  [4]i32,
	dist_idx: u32,
	tabs:     [dynamic]u32,
	cmap_l:   [dynamic]u8,
	cmap_d:   [dynamic]u8,
	lit_off:  [dynamic]int,
	cmd_off:  [dynamic]int,
	dist_off: [dynamic]int,
}

@(private)
to_upper :: #force_inline proc "contextless" (p: []byte) -> int {
	if p[0] < 0xC0 {
		if p[0] >= 'a' && p[0] <= 'z' do p[0] ~= 32
		return 1
	}
	if p[0] < 0xE0 {
		if len(p) > 1 do p[1] ~= 32
		return 2
	}
	if len(p) > 2 do p[2] ~= 5
	return 3
}

// Writes the transformed dictionary word into dst (>= 24+2*max affix bytes);
// returns its length.
@(private)
transform_word :: proc "contextless" (dst: []byte, word: []byte, t: Transform) -> int {
	n := copy(dst, t.prefix)
	w := word
	if t.type >= 1 && t.type <= 9 {
		w = w[:max(0, len(w) - int(t.type))]
	} else if t.type >= 12 && t.type <= 20 {
		skip := int(t.type) - 11
		w = skip >= len(w) ? w[:0] : w[skip:]
	}
	ws := n
	n += copy(dst[n:], w)
	if n > ws {
		if t.type == 10 {
			to_upper(dst[ws:n])
		} else if t.type == 11 {
			for i := ws; i < n; i += to_upper(dst[i:n]) {}
		}
	}
	n += copy(dst[n:], t.suffix)
	return n
}

@(private)
grow :: proc(a: ^[dynamic]byte, n: int) -> bool {
	if cap(a) >= n do return true
	return non_zero_reserve(a, max(n, 2 * cap(a))) == nil
}

@(private)
decode_metablock :: proc(d: ^Decoder, mlen: int) -> Error #no_bounds_check {
	r := &d.r
	clear(&d.tabs)
	cats: [3]Block_Cat // literal, insert&copy, distance
	for i in 0 ..< 3 do read_block_cat(r, &cats[i], &d.tabs) or_return
	if overrun(r) do return .Truncated
	npostfix := read(r, 2)
	ndirect := read(r, 4) << npostfix
	modes: [256]u8
	for i in 0 ..< cats[0].ntypes do modes[i] = u8(read(r, 2))

	ntrees_l := read_varlen8(r)
	resize(&d.cmap_l, int(cats[0].ntypes) * 64)
	read_context_map(r, d.cmap_l[:], ntrees_l, &d.tabs) or_return
	ntrees_d := read_varlen8(r)
	resize(&d.cmap_d, int(cats[2].ntypes) * 4)
	read_context_map(r, d.cmap_d[:], ntrees_d, &d.tabs) or_return

	clear(&d.lit_off)
	clear(&d.cmd_off)
	clear(&d.dist_off)
	for _ in 0 ..< ntrees_l do append(&d.lit_off, read_prefix_code(r, 256, &d.tabs) or_return)
	for _ in 0 ..< cats[1].ntypes do append(&d.cmd_off, read_prefix_code(r, 704, &d.tabs) or_return)
	dist_alphabet := 16 + ndirect + (48 << npostfix)
	for _ in 0 ..< ntrees_d do append(&d.dist_off, read_prefix_code(r, int(dist_alphabet), &d.tabs) or_return)
	if overrun(r) do return .Truncated

	pos := len(d.out)
	if mlen > d.max_out - pos do return .Output_Too_Large
	if !grow(&d.out, pos + mlen + 64) do return .Out_Of_Memory
	(^runtime.Raw_Dynamic_Array)(&d.out).len = pos + mlen
	out := raw_data(d.out)
	end := pos + mlen

	tabs := raw_data(d.tabs)
	lc := &cats[0]
	ic := &cats[1]
	dc := &cats[2]
	lit_off := d.lit_off[:]
	cmd_off := d.cmd_off[:]
	dist_off := d.dist_off[:]
	cmap_l := d.cmap_l[:]
	cmap_d := d.cmap_d[:]
	lcm := cmap_l[0:64]
	ctx := &CTX[modes[0]]
	cmd_tab := tabs[cmd_off[0]:]
	postfix_mask := (u32(1) << npostfix) - 1

	p1 := pos > 0 ? out[pos - 1] : 0
	p2 := pos > 1 ? out[pos - 2] : 0

	for pos < end {
		if ic.left == 0 {
			switch_block(r, ic, tabs)
			cmd_tab = tabs[cmd_off[ic.cur]:]
		}
		ic.left -= 1
		sym := decode_sym(r, cmd_tab)
		cell := sym >> 6
		ic_code := CELL_INS[cell] + ((sym >> 3) & 7)
		cc_code := CELL_COPY[cell] + (sym & 7)
		ins := int(INS_BASE[ic_code] + read(r, u32(INS_BITS[ic_code])))
		cpy := int(COPY_BASE[cc_code] + read(r, u32(COPY_BITS[cc_code])))
		if ins > end - pos do return .Corrupt

		for _ in 0 ..< ins {
			if lc.left == 0 {
				switch_block(r, lc, tabs)
				lcm = cmap_l[lc.cur * 64:][:64]
				ctx = &CTX[modes[lc.cur]]
			}
			lc.left -= 1
			c := ctx[p1] | ctx[256 + int(p2)]
			b := u8(decode_sym(r, tabs[lit_off[lcm[c]]:]))
			out[pos] = b
			pos += 1
			p2 = p1
			p1 = b
		}
		if overrun(r) do return .Truncated
		if pos >= end do break

		dist: i32
		dcode: u32
		if cell >= 2 {
			if dc.left == 0 do switch_block(r, dc, tabs)
			dc.left -= 1
			dctx := cpy > 4 ? 3 : cpy - 2
			dcode = decode_sym(r, tabs[dist_off[cmap_d[int(dc.cur) * 4 + dctx]]:])
		}
		if dcode < 16 {
			dist = d.dist_rb[(d.dist_idx - 1 - DIST_IDX[dcode]) & 3] + DIST_DELTA[dcode]
			if dist <= 0 do return .Corrupt
		} else if dcode < 16 + ndirect {
			dist = i32(dcode - 15)
		} else {
			x := dcode - ndirect - 16
			ndistbits := 1 + (x >> (npostfix + 1))
			hcode := x >> npostfix
			lcode := x & postfix_mask
			offset := ((2 + (hcode & 1)) << ndistbits) - 4
			dist = i32(((offset + read(r, ndistbits)) << npostfix) + lcode + ndirect + 1)
		}

		max_dist := min(pos, d.window)
		if int(dist) > max_dist {
			// static dictionary reference
			if cpy < 4 || cpy > 24 do return .Corrupt
			word_id := int(dist) - max_dist - 1
			nbits := u32(DICT_NDBITS[cpy])
			idx := word_id & ((1 << nbits) - 1)
			tid := word_id >> nbits
			if tid >= len(TRANSFORMS) do return .Corrupt
			off := int(DICT_OFFSET[cpy]) + idx * cpy
			buf: [64]byte
			n := transform_word(buf[:], DICT[off:off + cpy], TRANSFORMS[tid])
			if n > end - pos do return .Corrupt
			mem.copy_non_overlapping(out[pos:], &buf[0], n)
			pos += n
		} else {
			if dcode != 0 {
				d.dist_rb[d.dist_idx & 3] = dist
				d.dist_idx += 1
			}
			if cpy > end - pos do return .Corrupt
			// out has >= 64 bytes of slack past end, so chunked copies may overrun
			dst := out[pos:]
			src := out[pos - int(dist):]
			if dist >= 16 {
				for k := 0; k < cpy; k += 16 {
					intrinsics.unaligned_store((^#simd[16]u8)(dst[k:]), intrinsics.unaligned_load((^#simd[16]u8)(src[k:])))
				}
			} else if dist >= 8 {
				for k := 0; k < cpy; k += 8 {
					intrinsics.unaligned_store((^u64)(dst[k:]), intrinsics.unaligned_load((^u64)(src[k:])))
				}
			} else {
				for k in 0 ..< cpy do dst[k] = src[k]
			}
			pos += cpy
		}
		if pos > 0 do p1 = out[pos - 1]
		if pos > 1 do p2 = out[pos - 2]
	}
	if overrun(r) do return .Truncated
	return .None
}

// Decompress a complete brotli stream.
decompress :: proc(input: []byte, allocator := context.allocator, max_out := 256 << 20) -> ([]byte, Error) {
	d: Decoder
	d.r.data = input
	d.max_out = max_out
	d.out = make([dynamic]byte, allocator)
	d.tabs = make([dynamic]u32, allocator)
	d.cmap_l = make([dynamic]u8, allocator)
	d.cmap_d = make([dynamic]u8, allocator)
	d.lit_off = make([dynamic]int, allocator)
	d.cmd_off = make([dynamic]int, allocator)
	d.dist_off = make([dynamic]int, allocator)
	d.dist_rb = {16, 15, 11, 4}
	err := run(&d)
	delete(d.tabs)
	delete(d.cmap_l)
	delete(d.cmap_d)
	delete(d.lit_off)
	delete(d.cmd_off)
	delete(d.dist_off)
	if err != .None {
		delete(d.out)
		return nil, err
	}
	return d.out[:], .None
}

@(private)
run :: proc(d: ^Decoder) -> Error {
	r := &d.r
	if len(r.data) == 0 do return .Truncated
	wbits: u32 = 16
	if read(r, 1) == 1 {
		n := read(r, 3)
		if n != 0 {
			wbits = 17 + n
		} else {
			m := read(r, 3)
			if m == 1 do return .Corrupt // large-window brotli is not RFC 7932
			wbits = m == 0 ? 17 : 8 + m
		}
	}
	d.window = (1 << wbits) - 16
	for {
		last := read(r, 1) == 1
		if last && read(r, 1) == 1 do break // ISLASTEMPTY
		nib := read(r, 2)
		if nib == 3 {
			// metadata
			if read(r, 1) != 0 do return .Corrupt
			nbytes := read(r, 2)
			skip := 0
			if nbytes > 0 {
				v := 0
				for i in 0 ..< nbytes {
					b := read(r, 8)
					if i == nbytes - 1 && nbytes > 1 && b == 0 do return .Corrupt
					v |= int(b) << (8 * i)
				}
				skip = v + 1
			}
			if !align(r) do return .Corrupt
			p := byte_pos(r)
			if p + skip > len(r.data) do return .Truncated
			seek(r, p + skip)
			if last do break
			continue
		}
		nnib := nib + 4
		mlen := 0
		for i in 0 ..< nnib {
			v := read(r, 4)
			if i == nnib - 1 && nnib > 4 && v == 0 do return .Corrupt
			mlen |= int(v) << (4 * i)
		}
		mlen += 1
		if !last && read(r, 1) == 1 {
			// uncompressed
			if !align(r) do return .Corrupt
			p := byte_pos(r)
			if p + mlen > len(r.data) do return .Truncated
			if mlen > d.max_out - len(d.out) do return .Output_Too_Large
			append(&d.out, ..r.data[p:p + mlen])
			seek(r, p + mlen)
			continue
		}
		decode_metablock(d, mlen) or_return
		if last do break
	}
	if overrun(r) do return .Truncated
	if !align(r) do return .Corrupt
	if byte_pos(r) != len(r.data) do return .Corrupt // trailing garbage
	return .None
}
