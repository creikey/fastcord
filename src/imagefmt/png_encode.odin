package imagefmt

import "core:hash"
import "core:mem"

// encode_png writes RGBA8 pixels as a compressed PNG (color type 6, 8 bit): per-row adaptive
// filters and deflate with LZ77 + the fixed Huffman codes. For clipboard bitmaps (pasted
// screenshots), which must fit the upload limit; not a size-optimal encoder.
encode_png :: proc(pixels: []byte, w, h: int, allocator := context.allocator) -> []byte {
	assert(len(pixels) >= w * h * 4)
	stride := w * 4
	raw := make([]byte, (stride + 1) * h, context.temp_allocator)
	cand: [5][]byte
	for &c in cand do c = make([]byte, stride, context.temp_allocator)
	for y in 0 ..< h {
		cur := pixels[y * stride:][:stride]
		prev := y > 0 ? pixels[(y - 1) * stride:][:stride] : nil
		best, best_cost := 0, max(int)
		for ft in 0 ..< 5 {
			out := cand[ft]
			cost := 0
			for i in 0 ..< stride {
				a := i >= 4 ? int(cur[i - 4]) : 0
				b := prev != nil ? int(prev[i]) : 0
				c := i >= 4 && prev != nil ? int(prev[i - 4]) : 0
				pred: int
				switch ft {
				case 0: pred = 0
				case 1: pred = a
				case 2: pred = b
				case 3: pred = (a + b) / 2
				case 4: pred = paeth(a, b, c)
				}
				v := u8(int(cur[i]) - pred)
				out[i] = v
				cost += int(v) if v < 128 else 256 - int(v) // sum of |signed residual|
			}
			if cost < best_cost do best, best_cost = ft, cost
		}
		raw[y * (stride + 1)] = u8(best)
		copy(raw[y * (stride + 1) + 1:], cand[best])
	}

	out := make([dynamic]byte, 0, len(raw) / 4 + 1024, allocator)
	append(&out, 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n')
	ihdr: [13]byte
	put_be32(ihdr[0:], u32(w))
	put_be32(ihdr[4:], u32(h))
	ihdr[8] = 8
	ihdr[9] = 6
	png_chunk(&out, "IHDR", ihdr[:])
	z := zlib_compress(raw, context.temp_allocator)
	png_chunk(&out, "IDAT", z)
	png_chunk(&out, "IEND", nil)
	return out[:]
}

@(private = "file")
paeth :: #force_inline proc(a, b, c: int) -> int {
	p := a + b - c
	pa, pb, pc := abs(p - a), abs(p - b), abs(p - c)
	if pa <= pb && pa <= pc do return a
	if pb <= pc do return b
	return c
}

@(private = "file")
put_be32 :: proc(b: []byte, v: u32) {
	b[0], b[1], b[2], b[3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
}

@(private = "file")
png_chunk :: proc(out: ^[dynamic]byte, type: string, data: []byte) {
	l: [4]byte
	put_be32(l[:], u32(len(data)))
	append(out, ..l[:])
	start := len(out)
	append(out, ..transmute([]byte)type)
	append(out, ..data)
	crc: [4]byte
	put_be32(crc[:], hash.crc32(out[start:]))
	append(out, ..crc[:])
}

// ---- deflate (RFC 1951), fixed Huffman blocks ----

@(private = "file")
Bit_Writer :: struct {
	out:  ^[dynamic]byte,
	acc:  u64,
	nacc: uint,
}

@(private = "file")
bw_put :: #force_inline proc(bw: ^Bit_Writer, bits: u32, n: uint) {
	bw.acc |= u64(bits) << bw.nacc
	bw.nacc += n
	for bw.nacc >= 8 {
		append(bw.out, u8(bw.acc))
		bw.acc >>= 8
		bw.nacc -= 8
	}
}

// Huffman codes go MSB first: reverse them for the LSB-first stream.
@(private = "file")
bw_code :: #force_inline proc(bw: ^Bit_Writer, code: u32, n: uint) {
	r: u32
	for i in 0 ..< n do r |= ((code >> i) & 1) << (n - 1 - i)
	bw_put(bw, r, n)
}

@(private = "file")
lit :: proc(bw: ^Bit_Writer, v: int) {
	switch {
	case v <= 143: bw_code(bw, u32(0x30 + v), 8)
	case v <= 255: bw_code(bw, u32(0x190 + v - 144), 9)
	case v <= 279: bw_code(bw, u32(v - 256), 7)
	case: bw_code(bw, u32(0xC0 + v - 280), 8)
	}
}

@(private = "file")
LEN_BASE := [29]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private = "file")
LEN_EXTRA := [29]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private = "file")
DIST_BASE := [30]u16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
@(private = "file")
DIST_EXTRA := [30]u8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}

@(private = "file")
put_match :: proc(bw: ^Bit_Writer, length, dist: int) {
	li := 28
	for li > 0 && int(LEN_BASE[li]) > length do li -= 1
	lit(bw, 257 + li)
	if LEN_EXTRA[li] > 0 do bw_put(bw, u32(length - int(LEN_BASE[li])), uint(LEN_EXTRA[li]))
	di := 29
	for di > 0 && int(DIST_BASE[di]) > dist do di -= 1
	bw_code(bw, u32(di), 5)
	if DIST_EXTRA[di] > 0 do bw_put(bw, u32(dist - int(DIST_BASE[di])), uint(DIST_EXTRA[di]))
}

@(private = "file")
WINDOW :: 32768
@(private = "file")
HASH_BITS :: 15
@(private = "file")
MAX_CHAIN :: 24
@(private = "file")
NICE_LEN :: 128

// zlib stream: header, one fixed-Huffman block, adler32.
zlib_compress :: proc(src: []byte, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, 0, len(src) / 4 + 64, allocator)
	append(&out, 0x78, 0x01)
	bw := Bit_Writer{out = &out}
	bw_put(&bw, 1, 1) // BFINAL
	bw_put(&bw, 1, 2) // BTYPE = fixed
	head := make([]i32, 1 << HASH_BITS, context.temp_allocator)
	mem.set(raw_data(head), 0xff, len(head) * size_of(i32)) // -1
	prev := make([]i32, WINDOW, context.temp_allocator)
	hash3 :: #force_inline proc(p: []byte) -> u32 {
		return ((u32(p[0]) << 16 | u32(p[1]) << 8 | u32(p[2])) * 2654435761) >> (32 - HASH_BITS)
	}
	insert :: #force_inline proc(head, prev: []i32, src: []byte, i: int) {
		hv := hash3(src[i:])
		prev[i & (WINDOW - 1)] = head[hv]
		head[hv] = i32(i)
	}
	n := len(src)
	i := 0
	for i < n {
		best_len, best_dist := 0, 0
		if i + 3 <= n {
			cand := int(head[hash3(src[i:])])
			maxlen := min(258, n - i)
			for chain := 0; cand >= 0 && i - cand <= WINDOW - 1 && chain < MAX_CHAIN; chain += 1 {
				if src[cand + best_len] == src[i + best_len] || best_len == 0 {
					l := 0
					for l < maxlen && src[cand + l] == src[i + l] do l += 1
					if l > best_len {
						best_len, best_dist = l, i - cand
						if l >= NICE_LEN || l == maxlen do break
					}
				}
				nxt := int(prev[cand & (WINDOW - 1)])
				if nxt >= cand do break
				cand = nxt
			}
		}
		if best_len >= 3 {
			put_match(&bw, best_len, best_dist)
			end := min(i + best_len, n - 2)
			for k := i; k < end; k += 1 do insert(head, prev, src, k)
			i += best_len
		} else {
			lit(&bw, int(src[i]))
			if i + 3 <= n do insert(head, prev, src, i)
			i += 1
		}
	}
	lit(&bw, 256)
	if bw.nacc > 0 do append(&out, u8(bw.acc))
	ad: [4]byte
	put_be32(ad[:], hash.adler32(src))
	append(&out, ..ad[:])
	return out[:]
}
