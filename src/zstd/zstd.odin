// Package zstd is a from-scratch Zstandard (RFC 8878) decoder.
//
// Two entry points:
//   - decompress: whole input (one or more frames, skippable frames allowed).
//   - Stream_Decoder: feed bytes as they arrive (Discord `compress=zstd-stream`
//     sends one endless frame split across WebSocket messages). Input may be
//     split at any byte; history, entropy tables and repeat offsets persist.
//
// Not supported: dictionaries (frames with a non-zero Dictionary_ID are rejected).
package zstd

import "base:intrinsics"
import "base:runtime"
import "core:hash/xxhash"
import "core:mem"

Error :: enum u8 {
	None,
	Truncated, // decompress: input ended inside a frame
	Bad_Magic,
	Bad_Frame_Header,
	Window_Too_Large,
	Dictionary_Unsupported,
	Corrupt,
	Checksum_Mismatch,
	Size_Mismatch, // Frame_Content_Size disagrees with decoded size
	Output_Too_Large,
	Out_Of_Memory,
}

MAGIC :: 0xFD2FB528
BLOCK_MAX :: 128 << 10
// Largest window accepted by default: 128 MB covers `zstd --long` (windowLog 27).
// Discord's gateway uses 8 MB or less. Memory is only used as data arrives.
DEFAULT_MAX_WINDOW :: 1 << 27
@(private)
WILD :: 32 // slack after buffers so copies can overrun in 16-byte chunks

@(private)
State :: enum u8 {
	Magic,
	Header,
	Block_Header,
	Block_Body,
	Checksum,
	Skip,
}

// One decoding-table cell for FSE (sequences and Huffman weights).
@(private)
Seq_Entry :: struct {
	base:       u32, // symbol value baseline (or the symbol itself)
	next_state: u16,
	extra_bits: u8, // extra raw bits added to base
	nb_bits:    u8, // bits to read for next state
}

@(private)
Seq_Table :: struct {
	cells: [512]Seq_Entry,
	log:   u32,
	valid: bool,
}

Stream_Decoder :: struct {
	allocator:        mem.Allocator,
	max_window:       int,
	max_out:          int, // one-shot only
	one_shot:         bool, // hist is the caller's output, never slid
	state:            State,
	err:              Error, // sticky

	// frame
	window:           int,
	has_checksum:     bool,
	has_content_size: bool,
	content_size:     u64,
	frame_out:        u64,
	block_last:       bool,
	block_type:       u8,
	block_size:       int,
	skip_left:        u64,
	hash:             xxhash.XXH64_state,
	rep:              [3]u32,

	hist:             [dynamic]byte, // decoded history (stream) / whole output (one-shot)
	floor:            int, // index in hist where the current frame's data begins
	pending:          [dynamic]byte, // unconsumed input carried between calls
	lit:              []byte, // literal buffer, BLOCK_MAX + WILD

	huf:              [2048]u16, // symbol | nb_bits << 8, indexed by top max_bits bits
	huf_bits:         u32,
	huf_valid:        bool,

	ll, of, ml:       Seq_Table,
}

// ---------------------------------------------------------------------------
// Public API

stream_init :: proc(d: ^Stream_Decoder, allocator := context.allocator, max_window := DEFAULT_MAX_WINDOW) {
	d^ = {}
	d.allocator = allocator
	d.max_window = max_window
	d.max_out = max(int)
	d.hist = make([dynamic]byte, allocator)
	d.pending = make([dynamic]byte, allocator)
	d.lit = make([]byte, BLOCK_MAX + WILD, allocator)
}

stream_destroy :: proc(d: ^Stream_Decoder) {
	if !d.one_shot do delete(d.hist)
	delete(d.pending)
	delete(d.lit, d.allocator)
	d^ = {}
}

// Feed the next chunk; appends all output decodable so far to out.
// Errors are sticky: after one, the decoder must be destroyed and re-initialised.
stream_decode :: proc(d: ^Stream_Decoder, input: []byte, out: ^[dynamic]byte) -> Error {
	if d.err != .None do return d.err
	data := input
	carried := len(d.pending) > 0
	if carried {
		append(&d.pending, ..input)
		data = d.pending[:]
	}
	n, err := process(d, data, out)
	if err != .None {
		d.err = err
		return err
	}
	rest := data[n:]
	if carried {
		copy(d.pending[:], rest)
		resize(&d.pending, len(rest))
	} else if len(rest) > 0 {
		append(&d.pending, ..rest)
	}
	return .None
}

// True when the decoder sits between frames with nothing buffered.
stream_at_frame_boundary :: proc(d: ^Stream_Decoder) -> bool {
	return d.state == .Magic && len(d.pending) == 0
}

// Decompress whole frames (any number, skippable frames allowed).
decompress :: proc(input: []byte, allocator := context.allocator, max_out := 1 << 30, max_window := DEFAULT_MAX_WINDOW) -> ([]byte, Error) {
	d: Stream_Decoder
	d.allocator = allocator
	d.max_window = max_window
	d.max_out = max_out
	d.one_shot = true
	d.hist = make([dynamic]byte, allocator)
	d.lit = make([]byte, BLOCK_MAX + WILD, allocator)
	defer delete(d.lit, allocator)

	n, err := process(&d, input, nil)
	if err == .None && (n != len(input) || d.state != .Magic) do err = .Truncated
	if err == .None && len(input) == 0 do err = .Truncated
	if err != .None {
		delete(d.hist)
		return nil, err
	}
	return d.hist[:], .None
}

// ---------------------------------------------------------------------------
// Frame / block state machine

@(private)
le16 :: #force_inline proc "contextless" (p: []byte) -> u32 {return u32(p[0]) | u32(p[1]) << 8}
@(private)
le24 :: #force_inline proc "contextless" (p: []byte) -> u32 {return u32(p[0]) | u32(p[1]) << 8 | u32(p[2]) << 16}
@(private)
le32 :: #force_inline proc "contextless" (p: []byte) -> u32 {return u32(p[0]) | u32(p[1]) << 8 | u32(p[2]) << 16 | u32(p[3]) << 24}

// Consumes as much of data as forms complete units; returns bytes consumed.
@(private)
process :: proc(d: ^Stream_Decoder, data: []byte, out: ^[dynamic]byte) -> (int, Error) {
	p := 0
	for {
		avail := len(data) - p
		switch d.state {
		case .Magic:
			if avail < 4 do return p, .None
			m := le32(data[p:])
			if m == MAGIC {
				p += 4
				d.state = .Header
			} else if m & 0xFFFFFFF0 == 0x184D2A50 {
				if avail < 8 do return p, .None
				d.skip_left = u64(le32(data[p + 4:]))
				p += 8
				d.state = .Skip
			} else {
				return p, .Bad_Magic
			}
		case .Header:
			if avail < 1 do return p, .None
			fhd := data[p]
			fcs_flag := fhd >> 6
			single := (fhd >> 5) & 1 == 1
			if fhd & 0x08 != 0 do return p, .Bad_Frame_Header
			DID_SIZES := [4]int{0, 1, 2, 4}
			FCS_SIZES := [4]int{0, 2, 4, 8}
			did_size := DID_SIZES[fhd & 3]
			fcs_size := FCS_SIZES[fcs_flag]
			if fcs_flag == 0 && single do fcs_size = 1
			size := 1 + (single ? 0 : 1) + did_size + fcs_size
			if avail < size do return p, .None
			h := data[p:p + size]
			q := 1
			window: u64
			if !single {
				wd := h[q]
				q += 1
				wlog := u64(10 + (wd >> 3))
				wbase := u64(1) << wlog
				window = wbase + (wbase / 8) * u64(wd & 7)
			}
			did: u32
			for i in 0 ..< did_size do did |= u32(h[q + i]) << (8 * u32(i))
			q += did_size
			fcs: u64
			for i in 0 ..< fcs_size do fcs |= u64(h[q + i]) << (8 * u64(i))
			if fcs_size == 2 do fcs += 256
			if did != 0 do return p, .Dictionary_Unsupported
			if single do window = fcs
			if window > u64(d.max_window) do return p, .Window_Too_Large
			p += size

			d.window = int(window)
			d.has_checksum = (fhd >> 2) & 1 == 1
			d.has_content_size = fcs_size > 0
			d.content_size = fcs
			d.frame_out = 0
			d.rep = {1, 4, 8}
			d.huf_valid = false
			d.ll.valid, d.of.valid, d.ml.valid = false, false, false
			if d.has_checksum do xxhash.XXH64_reset_state(&d.hash)
			if d.one_shot {
				d.floor = len(d.hist)
				if d.has_content_size && fcs <= u64(d.max_out - len(d.hist)) {
					if grow(&d.hist, len(d.hist) + int(fcs) + BLOCK_MAX + WILD) != nil do return p, .Out_Of_Memory
				}
			} else {
				clear(&d.hist)
				d.floor = 0
			}
			d.state = .Block_Header
		case .Block_Header:
			if avail < 3 do return p, .None
			bh := le24(data[p:])
			p += 3
			d.block_last = bh & 1 == 1
			d.block_type = u8((bh >> 1) & 3)
			d.block_size = int(bh >> 3)
			if d.block_type == 3 || d.block_size > BLOCK_MAX do return p, .Corrupt
			d.state = .Block_Body
		case .Block_Body:
			need := d.block_type == 1 ? 1 : d.block_size
			if avail < need do return p, .None
			if err := decode_block(d, data[p:p + need], out); err != .None do return p, err
			p += need
			if d.block_last {
				if d.has_content_size && d.frame_out != d.content_size do return p, .Size_Mismatch
				d.state = d.has_checksum ? .Checksum : .Magic
			} else {
				d.state = .Block_Header
			}
		case .Checksum:
			if avail < 4 do return p, .None
			want := le32(data[p:])
			p += 4
			if u32(xxhash.XXH64_digest(&d.hash)) != want do return p, .Checksum_Mismatch
			d.state = .Magic
		case .Skip:
			k := min(u64(avail), d.skip_left)
			p += int(k)
			d.skip_left -= k
			if d.skip_left != 0 do return p, .None
			d.state = .Magic
		}
	}
}

// Ensure capacity >= n, growing geometrically.
@(private)
grow :: proc(a: ^[dynamic]byte, n: int) -> runtime.Allocator_Error {
	if cap(a) >= n do return nil
	return non_zero_reserve(a, max(n, 2 * cap(a)))
}

@(private)
set_len :: #force_inline proc "contextless" (a: ^[dynamic]byte, n: int) {
	(^runtime.Raw_Dynamic_Array)(a).len = n
}

@(private)
decode_block :: proc(d: ^Stream_Decoder, src: []byte, out: ^[dynamic]byte) -> Error {
	// Stream mode: keep at least `window` bytes of history; slide when the
	// buffer holds two windows' worth so each byte is moved about once.
	if !d.one_shot {
		limit := 2 * max(d.window, BLOCK_MAX)
		if len(d.hist) + BLOCK_MAX > limit {
			keep := min(len(d.hist), d.window)
			n := len(d.hist)
			copy(d.hist[:keep], d.hist[n - keep:n])
			set_len(&d.hist, keep)
			d.floor = 0
		}
	}
	start := len(d.hist)
	if grow(&d.hist, start + BLOCK_MAX + WILD) != nil do return .Out_Of_Memory

	switch d.block_type {
	case 0:
		set_len(&d.hist, start + len(src))
		copy(d.hist[start:], src)
	case 1:
		set_len(&d.hist, start + d.block_size)
		mem.set(raw_data(d.hist)[start:], src[0], d.block_size)
	case 2:
		if err := decode_compressed(d, src); err != .None do return err
	}
	produced := d.hist[start:]
	d.frame_out += u64(len(produced))
	if d.has_content_size && d.frame_out > d.content_size do return .Size_Mismatch
	if d.one_shot && len(d.hist) > d.max_out do return .Output_Too_Large
	if d.has_checksum do xxhash.XXH64_update(&d.hash, produced)
	if out != nil do append(out, ..produced)
	return .None
}

// ---------------------------------------------------------------------------
// Backward bit reader (Huffman / FSE streams are read from the end).

@(private)
Bit_Back :: struct {
	bits:     u64,
	consumed: u32, // bits consumed from the top of `bits`; > 64 means overrun
	pos:      int, // index of the first byte of the 8-byte window
	src:      [^]byte,
}

@(private)
load64 :: #force_inline proc "contextless" (p: [^]byte) -> u64 {
	return u64(intrinsics.unaligned_load((^u64le)(p)))
}

@(private)
highbit32 :: #force_inline proc "contextless" (x: u32) -> u32 {
	return 31 - intrinsics.count_leading_zeros(x)
}

@(private)
bb_init :: proc "contextless" (br: ^Bit_Back, src: []byte) -> bool {
	n := len(src)
	if n == 0 do return false
	last := src[n - 1]
	if last == 0 do return false
	br.src = raw_data(src)
	if n >= 8 {
		br.pos = n - 8
		br.bits = load64(br.src[br.pos:])
		br.consumed = 8 - highbit32(u32(last))
	} else {
		br.pos = 0
		br.bits = 0
		for i in 0 ..< n do br.bits |= u64(src[i]) << (8 * u64(i))
		br.consumed = 8 - highbit32(u32(last)) + u32(8 - n) * 8
	}
	return true
}

@(private)
bb_peek :: #force_inline proc "contextless" (br: ^Bit_Back, n: u32) -> u32 {
	return u32(((br.bits << (br.consumed & 63)) >> 1) >> ((63 - n) & 63))
}

@(private)
bb_read :: #force_inline proc "contextless" (br: ^Bit_Back, n: u32) -> u32 {
	v := bb_peek(br, n)
	br.consumed += n
	return v
}

@(private)
bb_reload :: #force_inline proc "contextless" (br: ^Bit_Back) {
	if br.consumed > 64 do return
	if br.pos >= 8 {
		br.pos -= int(br.consumed >> 3)
		br.consumed &= 7
		br.bits = load64(br.src[br.pos:])
	} else if br.pos > 0 {
		nb := min(int(br.consumed >> 3), br.pos)
		br.pos -= nb
		br.consumed -= u32(nb) * 8
		br.bits = load64(br.src[br.pos:])
	}
}

@(private)
bb_done :: #force_inline proc "contextless" (br: ^Bit_Back) -> bool {
	return br.pos == 0 && br.consumed == 64
}

// ---------------------------------------------------------------------------
// FSE tables

@(private)
LL_BASE := [36]u32 {
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
	16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
	8192, 16384, 32768, 65536,
}
@(private)
LL_BITS := [36]u8 {
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
	13, 14, 15, 16,
}
@(private)
ML_BASE := [53]u32 {
	3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
	19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
	35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
	4099, 8195, 16387, 32771, 65539,
}
@(private)
ML_BITS := [53]u8 {
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
	12, 13, 14, 15, 16,
}
@(private)
OF_BASE := [32]u32 {
	1 << 0, 1 << 1, 1 << 2, 1 << 3, 1 << 4, 1 << 5, 1 << 6, 1 << 7,
	1 << 8, 1 << 9, 1 << 10, 1 << 11, 1 << 12, 1 << 13, 1 << 14, 1 << 15,
	1 << 16, 1 << 17, 1 << 18, 1 << 19, 1 << 20, 1 << 21, 1 << 22, 1 << 23,
	1 << 24, 1 << 25, 1 << 26, 1 << 27, 1 << 28, 1 << 29, 1 << 30, 1 << 31,
}
@(private)
OF_BITS := [32]u8 {
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
	16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
}
@(private)
LL_DEFAULT := [36]i16 {
	4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
	2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
	-1, -1, -1, -1,
}
@(private)
ML_DEFAULT := [53]i16 {
	1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
	-1, -1, -1, -1, -1,
}
@(private)
OF_DEFAULT := [29]i16 {
	1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
	1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
}

// Build an FSE decoding table from normalized counts. base/extra == nil means
// the cell's base is the symbol itself (Huffman weights).
@(private)
build_fse :: proc "contextless" (cells: []Seq_Entry, norm: []i16, log: u32, base: []u32, extra: []u8) -> bool {
	size := 1 << log
	high := size - 1
	next: [256]u16
	syms: [512]u8
	for n, s in norm {
		if n == -1 {
			syms[high] = u8(s)
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
		for _ in 0 ..< int(n) {
			syms[pos] = u8(s)
			pos = (pos + step) & mask
			for pos > high do pos = (pos + step) & mask
		}
	}
	if pos != 0 do return false
	for u in 0 ..< size {
		s := syms[u]
		ns := u32(next[s])
		next[s] += 1
		nb := log - highbit32(ns)
		c := &cells[u]
		c.nb_bits = u8(nb)
		c.next_state = u16((ns << nb) - u32(size))
		if base != nil {
			c.base = base[s]
			c.extra_bits = extra[s]
		} else {
			c.base = u32(s)
			c.extra_bits = 0
		}
	}
	return true
}

// Read an FSE table description (normalized counts), forward little-endian bits.
// Returns bytes consumed, the accuracy log and number of symbols present.
@(private)
read_fse_norm :: proc "contextless" (src: []byte, norm: []i16, max_log: u32) -> (consumed: int, log: u32, ok: bool) {
	max_sym := len(norm) - 1
	for &n in norm do n = 0
	bp := 0 // bit position
	peek :: #force_inline proc "contextless" (src: []byte, bp: int, n: uint) -> u32 {
		i := bp >> 3
		v: u32
		for k in 0 ..< 4 {
			if i + k < len(src) do v |= u32(src[i + k]) << (8 * uint(k))
		}
		return (v >> uint(bp & 7)) & ((1 << n) - 1)
	}
	log = peek(src, bp, 4) + 5
	bp += 4
	if log > max_log do return
	remaining := (1 << log) + 1
	threshold := 1 << log
	nbits := uint(log + 1)
	s := 0
	for remaining > 1 {
		if s > max_sym do return
		v := int(peek(src, bp, nbits))
		mx := (2 * threshold - 1) - remaining
		cnt: int
		if v & (threshold - 1) < mx {
			cnt = v & (threshold - 1)
			bp += int(nbits) - 1
		} else {
			cnt = v & (2 * threshold - 1)
			if cnt >= threshold do cnt -= mx
			bp += int(nbits)
		}
		cnt -= 1
		remaining -= abs(cnt)
		norm[s] = i16(cnt)
		s += 1
		if cnt == 0 {
			for {
				r := int(peek(src, bp, 2))
				bp += 2
				s += r
				if r != 3 do break
			}
			if s > max_sym + 1 do return
		}
		for remaining < threshold {
			nbits -= 1
			threshold >>= 1
		}
	}
	if remaining != 1 || bp > len(src) * 8 do return
	return (bp + 7) / 8, log, true
}

// ---------------------------------------------------------------------------
// Literals

@(private)
read_huffman_tree :: proc(d: ^Stream_Decoder, src: []byte) -> (consumed: int, err: Error) {
	if len(src) < 1 do return 0, .Corrupt
	hb := int(src[0])
	weights: [256]u8
	nw := 0
	if hb < 128 {
		if len(src) < 1 + hb || hb == 0 do return 0, .Corrupt
		desc := src[1:1 + hb]
		norm: [256]i16
		used, log, ok := read_fse_norm(desc, norm[:], 6)
		if !ok do return 0, .Corrupt
		cells: [64]Seq_Entry
		if !build_fse(cells[:], norm[:], log, nil, nil) do return 0, .Corrupt
		br: Bit_Back
		if !bb_init(&br, desc[used:]) do return 0, .Corrupt
		s1 := bb_read(&br, log)
		s2 := bb_read(&br, log)
		bb_reload(&br)
		for {
			if nw > 253 do return 0, .Corrupt
			c := cells[s1]
			weights[nw] = u8(c.base)
			nw += 1
			s1 = u32(c.next_state) + bb_read(&br, u32(c.nb_bits))
			bb_reload(&br)
			if br.consumed > 64 {
				weights[nw] = u8(cells[s2].base)
				nw += 1
				break
			}
			c = cells[s2]
			weights[nw] = u8(c.base)
			nw += 1
			s2 = u32(c.next_state) + bb_read(&br, u32(c.nb_bits))
			bb_reload(&br)
			if br.consumed > 64 {
				weights[nw] = u8(cells[s1].base)
				nw += 1
				break
			}
		}
		consumed = 1 + hb
	} else {
		nw = hb - 127
		nbytes := (nw + 1) / 2
		if len(src) < 1 + nbytes do return 0, .Corrupt
		for i in 0 ..< nw {
			b := src[1 + i / 2]
			weights[i] = i & 1 == 0 ? b >> 4 : b & 15
		}
		consumed = 1 + nbytes
	}
	if nw > 255 do return 0, .Corrupt
	sum: u32
	for w in weights[:nw] {
		if w > 11 do return 0, .Corrupt
		if w > 0 do sum += 1 << (w - 1)
	}
	if sum == 0 do return 0, .Corrupt
	max_bits := highbit32(sum) + 1
	if max_bits > 11 do return 0, .Corrupt
	rest := (u32(1) << max_bits) - sum
	if rest & (rest - 1) != 0 do return 0, .Corrupt
	weights[nw] = u8(highbit32(rest) + 1)
	nw += 1

	rank_count: [13]u32
	for w in weights[:nw] do rank_count[w] += 1
	rank_start: [13]u32
	next: u32
	for w in 1 ..= max_bits {
		rank_start[w] = next
		next += rank_count[w] << (w - 1)
	}
	for s in 0 ..< nw {
		w := u32(weights[s])
		if w == 0 do continue
		n := u32(1) << (w - 1)
		e := u16(s) | u16(max_bits + 1 - w) << 8
		st := rank_start[w]
		for i in st ..< st + n do d.huf[i] = e
		rank_start[w] = st + n
	}
	d.huf_bits = max_bits
	d.huf_valid = true
	return consumed, .None
}

@(private)
huf_dec :: #force_inline proc "contextless" (br: ^Bit_Back, tab: [^]u16, bits: u32) -> u8 {
	e := tab[bb_peek(br, bits)]
	br.consumed += u32(e >> 8)
	return u8(e)
}

// Decode one Huffman stream into dst (finishing loop shared by 1- and 4-stream modes).
@(private)
huf_finish :: #force_no_inline proc "contextless" (br: ^Bit_Back, tab: [^]u16, bits: u32, dst: [^]byte, op, end: int) -> bool {
	op := op
	for op < end {
		if br.pos >= 8 && end - op >= 4 {
			bb_reload(br)
			dst[op] = huf_dec(br, tab, bits)
			dst[op + 1] = huf_dec(br, tab, bits)
			dst[op + 2] = huf_dec(br, tab, bits)
			dst[op + 3] = huf_dec(br, tab, bits)
			op += 4
		} else {
			bb_reload(br)
			dst[op] = huf_dec(br, tab, bits)
			op += 1
		}
	}
	return bb_done(br)
}

@(private)
decode_huf_literals :: proc(d: ^Stream_Decoder, src: []byte, regen: int, four: bool) -> Error #no_bounds_check {
	tab := raw_data(d.huf[:])
	bits := d.huf_bits
	dst := raw_data(d.lit)
	if !four {
		br: Bit_Back
		if !bb_init(&br, src) do return .Corrupt
		return huf_finish(&br, tab, bits, dst, 0, regen) ? .None : .Corrupt
	}
	if len(src) < 10 || regen < 6 do return .Corrupt
	s1 := int(le16(src[0:]))
	s2 := int(le16(src[2:]))
	s3 := int(le16(src[4:]))
	total := len(src) - 6
	s4 := total - s1 - s2 - s3
	if s4 < 1 do return .Corrupt
	seg := (regen + 3) / 4
	b: [4]Bit_Back
	off := 6
	sizes := [4]int{s1, s2, s3, s4}
	for i in 0 ..< 4 {
		if !bb_init(&b[i], src[off:off + sizes[i]]) do return .Corrupt
		off += sizes[i]
	}
	op := [4]int{0, seg, 2 * seg, 3 * seg}
	end := [4]int{seg, 2 * seg, 3 * seg, regen}
	if end[3] < op[3] do return .Corrupt
	for b[0].pos >= 8 && b[1].pos >= 8 && b[2].pos >= 8 && b[3].pos >= 8 && end[3] - op[3] >= 4 {
		bb_reload(&b[0]);bb_reload(&b[1]);bb_reload(&b[2]);bb_reload(&b[3])
		for k in 0 ..< 4 {
			dst[op[0] + k] = huf_dec(&b[0], tab, bits)
			dst[op[1] + k] = huf_dec(&b[1], tab, bits)
			dst[op[2] + k] = huf_dec(&b[2], tab, bits)
			dst[op[3] + k] = huf_dec(&b[3], tab, bits)
		}
		op[0] += 4;op[1] += 4;op[2] += 4;op[3] += 4
	}
	for i in 0 ..< 4 {
		if !huf_finish(&b[i], tab, bits, dst, op[i], end[i]) do return .Corrupt
	}
	return .None
}

// Returns number of literals in d.lit and bytes consumed from src.
@(private)
decode_literals :: proc(d: ^Stream_Decoder, src: []byte) -> (nlit: int, consumed: int, err: Error) {
	if len(src) < 1 do return 0, 0, .Corrupt
	b0 := u32(src[0])
	lt := b0 & 3
	sf := (b0 >> 2) & 3
	switch lt {
	case 0, 1:
		hs: int
		regen: int
		switch sf {
		case 0, 2:
			hs, regen = 1, int(b0 >> 3)
		case 1:
			if len(src) < 2 do return 0, 0, .Corrupt
			hs, regen = 2, int(b0 >> 4 | u32(src[1]) << 4)
		case 3:
			if len(src) < 3 do return 0, 0, .Corrupt
			hs, regen = 3, int(b0 >> 4 | u32(src[1]) << 4 | u32(src[2]) << 12)
		}
		if regen > BLOCK_MAX do return 0, 0, .Corrupt
		if lt == 0 {
			if len(src) < hs + regen do return 0, 0, .Corrupt
			copy(d.lit, src[hs:hs + regen])
			return regen, hs + regen, .None
		}
		if len(src) < hs + 1 do return 0, 0, .Corrupt
		mem.set(raw_data(d.lit), src[hs], regen)
		return regen, hs + 1, .None
	case:
		HS := [4]int{3, 3, 4, 5}
		hs := HS[sf]
		if len(src) < hs do return 0, 0, .Corrupt
		v: u64
		for i in 0 ..< hs do v |= u64(src[i]) << (8 * u64(i))
		regen, comp: int
		switch sf {
		case 0, 1:
			regen, comp = int((v >> 4) & 0x3FF), int((v >> 14) & 0x3FF)
		case 2:
			regen, comp = int((v >> 4) & 0x3FFF), int((v >> 18) & 0x3FFF)
		case 3:
			regen, comp = int((v >> 4) & 0x3FFFF), int((v >> 22) & 0x3FFFF)
		}
		if regen > BLOCK_MAX || len(src) < hs + comp do return 0, 0, .Corrupt
		data := src[hs:hs + comp]
		if lt == 2 {
			n := read_huffman_tree(d, data) or_return
			data = data[n:]
		} else if !d.huf_valid {
			return 0, 0, .Corrupt
		}
		decode_huf_literals(d, data, regen, sf != 0) or_return
		return regen, hs + comp, .None
	}
}

// ---------------------------------------------------------------------------
// Sequences

@(private)
build_seq_table :: proc(t: ^Seq_Table, mode: u32, src: []byte, base: []u32, extra: []u8, def: []i16, def_log: u32, max_log: u32) -> (consumed: int, err: Error) {
	switch mode {
	case 0:
		build_fse(t.cells[:], def, def_log, base, extra)
		t.log = def_log
	case 1:
		if len(src) < 1 do return 0, .Corrupt
		s := int(src[0])
		if s >= len(base) do return 0, .Corrupt
		t.cells[0] = {base[s], 0, extra[s], 0}
		t.log = 0
		consumed = 1
	case 2:
		norm: [53]i16
		used, log, ok := read_fse_norm(src, norm[:len(base)], max_log)
		if !ok do return 0, .Corrupt
		if !build_fse(t.cells[:], norm[:len(base)], log, base, extra) do return 0, .Corrupt
		t.log = log
		consumed = used
	case 3:
		if !t.valid do return 0, .Corrupt
		return 0, .None
	}
	t.valid = true
	return consumed, .None
}

@(private)
copy16 :: #force_inline proc "contextless" (dst, src: [^]byte) {
	intrinsics.unaligned_store((^#simd[16]u8)(dst), intrinsics.unaligned_load((^#simd[16]u8)(src)))
}

@(private)
copy8 :: #force_inline proc "contextless" (dst, src: [^]byte) {
	intrinsics.unaligned_store((^u64)(dst), intrinsics.unaligned_load((^u64)(src)))
}

// Copies n bytes in 16-byte chunks; may write up to 15 bytes past dst+n.
@(private)
wildcopy :: #force_inline proc "contextless" (dst, src: [^]byte, n: int) {
	copy16(dst, src)
	for i := 16; i < n; i += 16 do copy16(dst[i:], src[i:])
}

@(private)
decode_compressed :: proc(d: ^Stream_Decoder, src: []byte) -> Error #no_bounds_check {
	nlit, p := decode_literals(d, src) or_return
	start := len(d.hist)
	base := raw_data(d.hist)
	lit := raw_data(d.lit)

	if p >= len(src) do return .Corrupt
	nseq := int(src[p])
	p += 1
	if nseq >= 128 {
		if nseq < 255 {
			if p >= len(src) do return .Corrupt
			nseq = ((nseq - 128) << 8) + int(src[p])
			p += 1
		} else {
			if p + 2 > len(src) do return .Corrupt
			nseq = int(le16(src[p:])) + 0x7F00
			p += 2
		}
	}
	if nseq == 0 {
		mem.copy_non_overlapping(base[start:], lit, nlit)
		set_len(&d.hist, start + nlit)
		return .None
	}
	if p >= len(src) do return .Corrupt
	modes := u32(src[p])
	p += 1
	if modes & 3 != 0 do return .Corrupt
	n: int
	n = build_seq_table(&d.ll, modes >> 6, src[p:], LL_BASE[:], LL_BITS[:], LL_DEFAULT[:], 6, 9) or_return
	p += n
	n = build_seq_table(&d.of, (modes >> 4) & 3, src[p:], OF_BASE[:], OF_BITS[:], OF_DEFAULT[:], 5, 8) or_return
	p += n
	n = build_seq_table(&d.ml, (modes >> 2) & 3, src[p:], ML_BASE[:], ML_BITS[:], ML_DEFAULT[:], 6, 9) or_return
	p += n

	br: Bit_Back
	if !bb_init(&br, src[p:]) do return .Corrupt
	llt := raw_data(d.ll.cells[:])
	oft := raw_data(d.of.cells[:])
	mlt := raw_data(d.ml.cells[:])
	lls := bb_read(&br, d.ll.log)
	ofs := bb_read(&br, d.of.log)
	mls := bb_read(&br, d.ml.log)
	r1, r2, r3 := d.rep[0], d.rep[1], d.rep[2]

	op := start
	oend := start + BLOCK_MAX
	lp := 0
	floor := d.floor

	for i in 0 ..< nseq {
		bb_reload(&br)
		lle := llt[lls]
		mle := mlt[mls]
		ofe := oft[ofs]

		ov := ofe.base + bb_read(&br, u32(ofe.extra_bits))
		ml := int(mle.base + bb_read(&br, u32(mle.extra_bits)))
		if u32(ofe.extra_bits) + u32(mle.extra_bits) > 14 do bb_reload(&br)
		ll := int(lle.base + bb_read(&br, u32(lle.extra_bits)))

		off: u32
		if ov > 3 {
			off = ov - 3
			r3 = r2
			r2 = r1
			r1 = off
		} else {
			idx := ov - 1 + (ll == 0 ? 1 : 0)
			switch idx {
			case 0:
				off = r1
			case 1:
				off = r2
				r2 = r1
				r1 = off
			case 2:
				off = r3
				r3 = r2
				r2 = r1
				r1 = off
			case:
				off = r1 - 1
				r3 = r2
				r2 = r1
				r1 = off
			}
		}

		if i != nseq - 1 {
			lls = u32(lle.next_state) + bb_read(&br, u32(lle.nb_bits))
			mls = u32(mle.next_state) + bb_read(&br, u32(mle.nb_bits))
			ofs = u32(ofe.next_state) + bb_read(&br, u32(ofe.nb_bits))
		}

		// execute
		if lp + ll > nlit || op + ll + ml > oend do return .Corrupt
		if ll > 0 {
			wildcopy(base[op:], lit[lp:], ll)
			op += ll
			lp += ll
		}
		o := int(off)
		if o == 0 || o > op - floor do return .Corrupt
		dst := base[op:]
		ms := base[op - o:]
		if o >= 16 {
			wildcopy(dst, ms, ml)
		} else if o >= 8 {
			for k := 0; k < ml; k += 8 do copy8(dst[k:], ms[k:])
		} else {
			for k in 0 ..< ml do dst[k] = ms[k]
		}
		op += ml
	}
	if !bb_done(&br) do return .Corrupt
	d.rep = {r1, r2, r3}

	rest := nlit - lp
	if op + rest > oend do return .Corrupt
	mem.copy_non_overlapping(base[op:], lit[lp:], rest)
	op += rest
	set_len(&d.hist, op)
	return .None
}
