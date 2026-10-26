// Package zstd is a streaming Zstandard decoder (RFC 8878).
//
// It is built for Discord's `compress=zstd-stream`: one zstd frame spans the
// whole gateway connection and every WebSocket message ends on a flushed
// block boundary. Feed each message with `feed`; it returns the bytes that
// message decompressed to. Window history, entropy tables and repeat offsets
// carry over between calls as the format requires.
package zstd

import "core:slice"

Error :: enum {
	None,
	Need_More,       // input ended mid-block; not an error for streaming
	Bad_Magic,
	Bad_Header,
	Bad_Block,
	Bad_Literals,
	Bad_Huffman,
	Bad_Fse,
	Bad_Sequences,
	Bad_Offset,
	Too_Large,
	Unsupported,
}

MAGIC :: 0xFD2FB528
SKIPPABLE_MASK :: 0xFFFFFFF0
SKIPPABLE_MAGIC :: 0x184D2A50
MAX_BLOCK :: 128 * 1024
MAX_WINDOW :: 64 * 1024 * 1024

Decoder :: struct {
	input:        [dynamic]byte, // unconsumed input
	in_frame:     bool,
	window_size:  int,
	checksum:     bool,
	history:      [dynamic]byte, // last window_size bytes of output
	reps:         [3]int,
	huf:          Huffman_Table,
	have_huf:     bool,
	ll, of, ml:   Fse_Table,
	have_seq:     [3]bool,
	literals:     [dynamic]byte,
}

destroy :: proc(d: ^Decoder) {
	delete(d.input)
	delete(d.history)
	delete(d.literals)
	d^ = {}
}

reset :: proc(d: ^Decoder) {
	destroy(d)
}

// Appends `data` and decodes every complete block. Decompressed bytes are
// appended to `out`. Returns .None when all input was consumed.
feed :: proc(d: ^Decoder, data: []byte, out: ^[dynamic]byte) -> Error {
	append(&d.input, ..data)
	pos := 0
	defer {
		if pos > 0 {
			copy(d.input[:], d.input[pos:])
			resize(&d.input, len(d.input) - pos)
		}
	}
	for {
		in_ := d.input[pos:]
		if !d.in_frame {
			if len(in_) == 0 do return .None
			if len(in_) < 4 do return .Need_More
			magic := le32(in_)
			if magic & SKIPPABLE_MASK == SKIPPABLE_MAGIC {
				if len(in_) < 8 do return .Need_More
				n := 8 + int(le32(in_[4:]))
				if len(in_) < n do return .Need_More
				pos += n
				continue
			}
			if magic != MAGIC do return .Bad_Magic
			n, err := parse_frame_header(d, in_)
			if err != .None do return err
			pos += n
			continue
		}
		if len(in_) < 3 do return len(in_) == 0 ? .None : .Need_More
		bh := u32(in_[0]) | u32(in_[1]) << 8 | u32(in_[2]) << 16
		last := bh & 1 != 0
		btype := (bh >> 1) & 3
		bsize := int(bh >> 3)
		if bsize > MAX_BLOCK do return .Bad_Block
		need := 3 + (btype == 1 ? 1 : bsize)
		if len(in_) < need do return .Need_More
		body := in_[3:need]
		start := len(out)
		switch btype {
		case 0:
			append(out, ..body)
		case 1:
			resize(out, start + bsize)
			slice.fill(out[start:], body[0])
		case 2:
			if err := decode_block(d, body, out); err != .None do return err
		case 3:
			return .Bad_Block
		}
		push_history(d, out[start:])
		pos += need
		if last {
			d.in_frame = false
			if d.checksum {
				if len(d.input) - pos < 4 do return .Need_More
				pos += 4
			}
		}
	}
}

@(private)
parse_frame_header :: proc(d: ^Decoder, in_: []byte) -> (int, Error) {
	if len(in_) < 5 do return 0, .Need_More
	fhd := in_[4]
	fcs_flag := fhd >> 6
	single := fhd & 0x20 != 0
	if fhd & 0x08 != 0 do return 0, .Bad_Header // reserved bit
	d.checksum = fhd & 0x04 != 0
	did_flag := fhd & 3
	n := 5
	window := 0
	if !single {
		if len(in_) < n + 1 do return 0, .Need_More
		wd := in_[n]
		exp := int(wd >> 3)
		base := 1 << uint(10 + exp)
		window = base + (base / 8) * int(wd & 7)
		n += 1
	}
	DID_SIZES := [4]int{0, 1, 2, 4}
	did_size := DID_SIZES[did_flag]
	if did_size != 0 do return 0, .Unsupported // dictionaries
	fcs_sizes := [4]int{single ? 1 : 0, 2, 4, 8}
	fcs_size := fcs_sizes[fcs_flag]
	if len(in_) < n + fcs_size do return 0, .Need_More
	fcs := 0
	for i in 0 ..< fcs_size do fcs |= int(in_[n + i]) << uint(8 * i)
	if fcs_size == 2 do fcs += 256
	n += fcs_size
	if single do window = fcs
	if window > MAX_WINDOW do return 0, .Too_Large
	d.window_size = max(window, MAX_BLOCK)
	d.in_frame = true
	d.reps = {1, 4, 8}
	d.have_huf = false
	d.have_seq = {}
	clear(&d.history)
	return n, .None
}

@(private)
push_history :: proc(d: ^Decoder, b: []byte) {
	append(&d.history, ..b)
	// Trim lazily so the copy is amortized.
	if len(d.history) > 2 * d.window_size {
		keep := d.window_size
		copy(d.history[:], d.history[len(d.history) - keep:])
		resize(&d.history, keep)
	}
}

@(private)
le32 :: #force_inline proc(b: []byte) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

@(private)
highbit :: #force_inline proc(x: u32) -> int {
	n := 0
	v := x
	for v > 1 {
		v >>= 1
		n += 1
	}
	return n
}

// ---------------------------------------------------------------------------
// Bit readers

// Forward little-endian reader (FSE table descriptions).
@(private)
Fwd_Bits :: struct {
	data: []byte,
	pos:  int, // bit position
}

@(private)
fwd_peek :: proc(r: ^Fwd_Bits, n: int) -> u32 {
	v: u32 = 0
	for i in 0 ..< n {
		p := r.pos + i
		if p / 8 < len(r.data) do v |= u32((r.data[p / 8] >> uint(p % 8)) & 1) << uint(i)
	}
	return v
}

// Backward reader: bits are consumed from the end of the buffer toward the
// start. A read of n bits returns stream bits [pos-n, pos) as an LE integer.
@(private)
Back_Bits :: struct {
	data: []byte,
	pos:  int, // may go negative on overread
}

@(private)
back_init :: proc(data: []byte) -> (r: Back_Bits, ok: bool) {
	if len(data) == 0 do return {}, false
	last := data[len(data) - 1]
	if last == 0 do return {}, false
	r.data = data
	r.pos = (len(data) - 1) * 8 + highbit(u32(last))
	return r, true
}

@(private)
back_peek :: #force_inline proc(r: ^Back_Bits, n: int) -> u64 {
	if n == 0 do return 0
	lo := r.pos - n
	// Fast path: gather a 64-bit LE word covering [lo, pos).
	v: u64 = 0
	if lo >= 0 {
		first := lo / 8
		last := (r.pos - 1) / 8
		for i := last; i >= first; i -= 1 do v = v << 8 | u64(r.data[i])
		v >>= uint(lo - first * 8)
	} else {
		// Bits below zero read as 0.
		if r.pos > 0 {
			last := (r.pos - 1) / 8
			for i := last; i >= 0; i -= 1 do v = v << 8 | u64(r.data[i])
			v <<= uint(-lo)
		}
	}
	return v & ((u64(1) << uint(n)) - 1)
}

@(private)
back_read :: #force_inline proc(r: ^Back_Bits, n: int) -> u64 {
	v := back_peek(r, n)
	r.pos -= n
	return v
}

// ---------------------------------------------------------------------------
// FSE

@(private)
Fse_Entry :: struct {
	symbol:   u8,
	nb_bits:  u8,
	baseline: u16,
}

Fse_Table :: struct {
	log:     int,
	entries: [512]Fse_Entry,
}

// Reads an FSE table description from the start of `data`.
@(private)
read_fse_norm :: proc(data: []byte, max_symbol: int, max_log: int, norm: []i16) -> (log: int, used: int, nsym: int, err: Error) {
	if len(data) == 0 do return 0, 0, 0, .Bad_Fse
	r := Fwd_Bits{data = data}
	log = int(fwd_peek(&r, 4)) + 5
	r.pos += 4
	if log > max_log do return 0, 0, 0, .Bad_Fse
	remaining := (1 << uint(log)) + 1
	threshold := 1 << uint(log)
	nb := log + 1
	sym := 0
	prev0 := false
	for remaining > 1 && sym <= max_symbol {
		if prev0 {
			n0 := sym
			for fwd_peek(&r, 16) == 0xFFFF {
				n0 += 24
				r.pos += 16
			}
			for fwd_peek(&r, 2) == 3 {
				n0 += 3
				r.pos += 2
			}
			n0 += int(fwd_peek(&r, 2))
			r.pos += 2
			if n0 > max_symbol + 1 do return 0, 0, 0, .Bad_Fse
			for sym < n0 {
				norm[sym] = 0
				sym += 1
			}
			if sym > max_symbol do break
		}
		maxv := (2 * threshold - 1) - remaining
		bits := int(fwd_peek(&r, nb))
		count: int
		if bits & (threshold - 1) < maxv {
			count = bits & (threshold - 1)
			r.pos += nb - 1
		} else {
			count = bits & (2 * threshold - 1)
			if count >= threshold do count -= maxv
			r.pos += nb
		}
		count -= 1
		remaining -= abs(count)
		norm[sym] = i16(count)
		sym += 1
		prev0 = count == 0
		for remaining < threshold {
			nb -= 1
			threshold >>= 1
		}
	}
	if remaining != 1 do return 0, 0, 0, .Bad_Fse
	used = (r.pos + 7) / 8
	if used > len(data) do return 0, 0, 0, .Bad_Fse
	return log, used, sym, .None
}

@(private)
build_fse :: proc(t: ^Fse_Table, norm: []i16, log: int) -> Error {
	size := 1 << uint(log)
	if size > len(t.entries) do return .Bad_Fse
	t.log = log
	high := size - 1
	next: [256]u16
	for n, s in norm {
		if n == -1 {
			t.entries[high].symbol = u8(s)
			high -= 1
			next[s] = 1
		} else {
			next[s] = u16(n)
		}
	}
	step := (size >> 1) + (size >> 3) + 3
	mask := size - 1
	pos := 0
	for n, s in norm {
		for _ in 0 ..< int(max(n, 0)) {
			t.entries[pos].symbol = u8(s)
			pos = (pos + step) & mask
			for pos > high do pos = (pos + step) & mask
		}
	}
	if pos != 0 do return .Bad_Fse
	for u in 0 ..< size {
		s := t.entries[u].symbol
		ns := u32(next[s])
		next[s] += 1
		nb := log - highbit(ns)
		t.entries[u].nb_bits = u8(nb)
		t.entries[u].baseline = u16((int(ns) << uint(nb)) - size)
	}
	return .None
}

@(private)
build_fse_rle :: proc(t: ^Fse_Table, sym: u8) {
	t.log = 0
	t.entries[0] = {symbol = sym, nb_bits = 0, baseline = 0}
}

// ---------------------------------------------------------------------------
// Huffman

Huffman_Table :: struct {
	max_bits: int,
	entries:  [1 << 11]struct {
		symbol:  u8,
		nb_bits: u8,
	},
}

@(private)
read_huffman :: proc(t: ^Huffman_Table, data: []byte) -> (used: int, err: Error) {
	if len(data) == 0 do return 0, .Bad_Huffman
	weights: [256]u8
	nw := 0
	header := int(data[0])
	if header < 128 {
		// FSE-compressed weights.
		if 1 + header > len(data) do return 0, .Bad_Huffman
		src := data[1:1 + header]
		norm: [256]i16
		log, hused, nsym, ferr := read_fse_norm(src, 255, 6, norm[:])
		if ferr != .None do return 0, .Bad_Huffman
		ft: Fse_Table
		if build_fse(&ft, norm[:nsym], log) != .None do return 0, .Bad_Huffman
		br, ok := back_init(src[hused:])
		if !ok do return 0, .Bad_Huffman
		s1 := int(back_read(&br, log))
		s2 := int(back_read(&br, log))
		for {
			if nw >= 255 do return 0, .Bad_Huffman
			e := ft.entries[s1]
			weights[nw] = e.symbol
			nw += 1
			s1 = int(e.baseline) + int(back_read(&br, int(e.nb_bits)))
			if br.pos < 0 {
				weights[nw] = ft.entries[s2].symbol
				nw += 1
				break
			}
			if nw >= 255 do return 0, .Bad_Huffman
			e = ft.entries[s2]
			weights[nw] = e.symbol
			nw += 1
			s2 = int(e.baseline) + int(back_read(&br, int(e.nb_bits)))
			if br.pos < 0 {
				weights[nw] = ft.entries[s1].symbol
				nw += 1
				break
			}
		}
		used = 1 + header
	} else {
		nw = header - 127
		nbytes := (nw + 1) / 2
		if 1 + nbytes > len(data) do return 0, .Bad_Huffman
		for i in 0 ..< nw {
			b := data[1 + i / 2]
			weights[i] = i % 2 == 0 ? b >> 4 : b & 0xF
		}
		used = 1 + nbytes
	}
	// The last weight is implied.
	sum: u32 = 0
	for i in 0 ..< nw {
		w := weights[i]
		if w > 11 do return 0, .Bad_Huffman
		if w > 0 do sum += 1 << (w - 1)
	}
	if sum == 0 do return 0, .Bad_Huffman
	max_bits := highbit(sum) + 1
	left := (u32(1) << uint(max_bits)) - sum
	if left & (left - 1) != 0 do return 0, .Bad_Huffman
	weights[nw] = u8(highbit(left) + 1)
	nw += 1
	if max_bits > 11 do return 0, .Bad_Huffman
	t.max_bits = max_bits
	// Fill: ascending weight, then ascending symbol, from index 0.
	pos := 0
	for w in 1 ..= max_bits {
		span := 1 << uint(w - 1)
		nb := u8(max_bits + 1 - w)
		for s in 0 ..< nw {
			if int(weights[s]) != w do continue
			for k in 0 ..< span {
				t.entries[pos + k] = {u8(s), nb}
			}
			pos += span
		}
	}
	if pos != 1 << uint(max_bits) do return 0, .Bad_Huffman
	return used, .None
}

@(private)
huf_stream :: proc(t: ^Huffman_Table, src: []byte, dst: []byte) -> Error {
	br, ok := back_init(src)
	if !ok do return .Bad_Huffman
	mb := t.max_bits
	for i in 0 ..< len(dst) {
		e := t.entries[back_peek(&br, mb)]
		dst[i] = e.symbol
		br.pos -= int(e.nb_bits)
	}
	if br.pos != 0 do return .Bad_Huffman
	return .None
}

// ---------------------------------------------------------------------------
// Blocks

@(private)
decode_block :: proc(d: ^Decoder, body: []byte, out: ^[dynamic]byte) -> Error {
	used, err := decode_literals(d, body)
	if err != .None do return err
	return decode_sequences(d, body[used:], out)
}

@(private)
decode_literals :: proc(d: ^Decoder, b: []byte) -> (int, Error) {
	if len(b) == 0 do return 0, .Bad_Literals
	ltype := b[0] & 3
	sf := (b[0] >> 2) & 3
	clear(&d.literals)
	switch ltype {
	case 0, 1:
		regen, hsize: int
		switch sf {
		case 0, 2:
			regen = int(b[0] >> 3)
			hsize = 1
		case 1:
			if len(b) < 2 do return 0, .Bad_Literals
			regen = int(b[0] >> 4) + int(b[1]) << 4
			hsize = 2
		case 3:
			if len(b) < 3 do return 0, .Bad_Literals
			regen = int(b[0] >> 4) + int(b[1]) << 4 + int(b[2]) << 12
			hsize = 3
		}
		if ltype == 0 {
			if len(b) < hsize + regen do return 0, .Bad_Literals
			append(&d.literals, ..b[hsize:hsize + regen])
			return hsize + regen, .None
		}
		if len(b) < hsize + 1 do return 0, .Bad_Literals
		resize(&d.literals, regen)
		slice.fill(d.literals[:], b[hsize])
		return hsize + 1, .None
	case 2, 3:
		hsize, bits: int
		streams := 4
		switch sf {
		case 0:
			streams = 1
			hsize, bits = 3, 10
		case 1:
			hsize, bits = 3, 10
		case 2:
			hsize, bits = 4, 14
		case 3:
			hsize, bits = 5, 18
		}
		if len(b) < hsize do return 0, .Bad_Literals
		h: u64 = 0
		for i in 0 ..< hsize do h |= u64(b[i]) << uint(8 * i)
		mask := (u64(1) << uint(bits)) - 1
		regen := int((h >> 4) & mask)
		comp := int((h >> uint(4 + bits)) & mask)
		if len(b) < hsize + comp do return 0, .Bad_Literals
		src := b[hsize:hsize + comp]
		if ltype == 2 {
			n, herr := read_huffman(&d.huf, src)
			if herr != .None do return 0, herr
			d.have_huf = true
			src = src[n:]
		} else if !d.have_huf {
			return 0, .Bad_Literals
		}
		resize(&d.literals, regen)
		if streams == 1 {
			if e := huf_stream(&d.huf, src, d.literals[:]); e != .None do return 0, e
		} else {
			if len(src) < 6 do return 0, .Bad_Literals
			s1 := int(src[0]) | int(src[1]) << 8
			s2 := int(src[2]) | int(src[3]) << 8
			s3 := int(src[4]) | int(src[5]) << 8
			rest := src[6:]
			if s1 + s2 + s3 > len(rest) do return 0, .Bad_Literals
			seg := (regen + 3) / 4
			if 3 * seg > regen do return 0, .Bad_Literals
			parts := [4][]byte{rest[:s1], rest[s1:s1 + s2], rest[s1 + s2:s1 + s2 + s3], rest[s1 + s2 + s3:]}
			for i in 0 ..< 4 {
				lo := i * seg
				hi := i == 3 ? regen : lo + seg
				if e := huf_stream(&d.huf, parts[i], d.literals[lo:hi]); e != .None do return 0, e
			}
		}
		return hsize + comp, .None
	}
	return 0, .Bad_Literals
}

LL_DEFAULT := [36]i16{4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1}
ML_DEFAULT := [53]i16{1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1}
OF_DEFAULT := [29]i16{1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1}

LL_BASE := [36]u32{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536}
LL_BITS := [36]u8{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
ML_BASE := [53]u32{3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539}
ML_BITS := [53]u8{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}

@(private)
seq_table :: proc(d: ^Decoder, which: int, mode: u8, b: []byte, pos: ^int) -> Error {
	t := which == 0 ? &d.ll : which == 1 ? &d.of : &d.ml
	MAX_SYM := [3]int{35, 31, 52}
	MAX_LOG := [3]int{9, 8, 9}
	max_sym := MAX_SYM[which]
	max_log := MAX_LOG[which]
	switch mode {
	case 0:
		switch which {
		case 0: build_fse(t, LL_DEFAULT[:], 6)
		case 1: build_fse(t, OF_DEFAULT[:], 5)
		case 2: build_fse(t, ML_DEFAULT[:], 6)
		}
	case 1:
		if pos^ >= len(b) do return .Bad_Sequences
		s := b[pos^]
		if int(s) > max_sym do return .Bad_Sequences
		build_fse_rle(t, s)
		pos^ += 1
	case 2:
		norm: [64]i16
		log, used, nsym, err := read_fse_norm(b[pos^:], max_sym, max_log, norm[:])
		if err != .None do return .Bad_Sequences
		if build_fse(t, norm[:nsym], log) != .None do return .Bad_Sequences
		pos^ += used
	case 3:
		if !d.have_seq[which] do return .Bad_Sequences
	}
	d.have_seq[which] = true
	return .None
}

@(private)
decode_sequences :: proc(d: ^Decoder, b: []byte, out: ^[dynamic]byte) -> Error {
	if len(b) == 0 do return .Bad_Sequences
	nseq := 0
	pos := 0
	b0 := int(b[0])
	switch {
	case b0 == 0:
		nseq = 0
		pos = 1
	case b0 < 128:
		nseq = b0
		pos = 1
	case b0 < 255:
		if len(b) < 2 do return .Bad_Sequences
		nseq = (b0 - 128) << 8 + int(b[1])
		pos = 2
	case:
		if len(b) < 3 do return .Bad_Sequences
		nseq = int(b[1]) + int(b[2]) << 8 + 0x7F00
		pos = 3
	}
	lits := d.literals[:]
	if nseq == 0 {
		append(out, ..lits)
		return .None
	}
	if pos >= len(b) do return .Bad_Sequences
	modes := b[pos]
	pos += 1
	if modes & 3 != 0 do return .Bad_Sequences
	if e := seq_table(d, 0, (modes >> 6) & 3, b, &pos); e != .None do return e
	if e := seq_table(d, 1, (modes >> 4) & 3, b, &pos); e != .None do return e
	if e := seq_table(d, 2, (modes >> 2) & 3, b, &pos); e != .None do return e

	br, ok := back_init(b[pos:])
	if !ok do return .Bad_Sequences
	ll_s := int(back_read(&br, d.ll.log))
	of_s := int(back_read(&br, d.of.log))
	ml_s := int(back_read(&br, d.ml.log))

	block_start := len(out)
	lit_pos := 0
	for i in 0 ..< nseq {
		lle := d.ll.entries[ll_s]
		ofe := d.of.entries[of_s]
		mle := d.ml.entries[ml_s]
		ll_code := int(lle.symbol)
		of_code := int(ofe.symbol)
		ml_code := int(mle.symbol)
		if ll_code > 35 || ml_code > 52 || of_code > 31 do return .Bad_Sequences

		of_val := int((u64(1) << uint(of_code)) + back_read(&br, of_code))
		ml := int(ML_BASE[ml_code]) + int(back_read(&br, int(ML_BITS[ml_code])))
		ll := int(LL_BASE[ll_code]) + int(back_read(&br, int(LL_BITS[ll_code])))

		if i != nseq - 1 {
			ll_s = int(lle.baseline) + int(back_read(&br, int(lle.nb_bits)))
			ml_s = int(mle.baseline) + int(back_read(&br, int(mle.nb_bits)))
			of_s = int(ofe.baseline) + int(back_read(&br, int(ofe.nb_bits)))
		}

		offset: int
		if of_val > 3 {
			offset = of_val - 3
			d.reps = {offset, d.reps[0], d.reps[1]}
		} else {
			idx := of_val
			if ll == 0 do idx += 1
			switch idx {
			case 1:
				offset = d.reps[0]
			case 2:
				offset = d.reps[1]
				d.reps = {offset, d.reps[0], d.reps[2]}
			case 3:
				offset = d.reps[2]
				d.reps = {offset, d.reps[0], d.reps[1]}
			case 4:
				offset = d.reps[0] - 1
				if offset <= 0 do return .Bad_Offset
				d.reps = {offset, d.reps[0], d.reps[1]}
			}
		}

		if lit_pos + ll > len(lits) do return .Bad_Sequences
		append(out, ..lits[lit_pos:lit_pos + ll])
		lit_pos += ll

		// Match: source may be in this block's output or in history.
		produced := len(out) - block_start
		if offset > produced + len(d.history) || offset > d.window_size + produced do return .Bad_Offset
		for _ in 0 ..< ml {
			cur := len(out) - block_start
			if offset <= cur {
				append(out, out[len(out) - offset])
			} else {
				back := offset - cur
				append(out, d.history[len(d.history) - back])
			}
		}
	}
	if br.pos != 0 do return .Bad_Sequences
	append(out, ..lits[lit_pos:])
	return .None
}
