package imagefmt

// zlib/DEFLATE decoder (RFC 1950/1951) for PNG, into a buffer of known size.
// Faster than core:compress/zlib for this use: 64-bit bit buffer, two-level
// tables, chunked match copies. The Adler-32 trailer is not checked.

import "base:intrinsics"

@(private)
LEN_BASE := [29]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private)
LEN_EXTRA := [29]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private)
DIST_BASE := [30]u16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
@(private)
DIST_EXTRA := [30]u8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}
@(private)
CL_ORDER := [19]u8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

// Invalid table entries decode as this symbol (bits 1) and are rejected.
@(private)
INFL_BAD :: 0xFFFF

@(private)
infl_build :: proc(out: []u32, lengths: []u8) -> bool {
	used := 0
	for l in lengths do if l != 0 do used += 1
	if used == 1 {
		// a lone code is one bit long: '0' is the symbol, '1' is invalid
		for l, s in lengths {
			if l != 0 {
				for i in 0 ..< 1 << HROOT do out[i] = i & 1 == 0 ? u32(s) | 1 << 16 : INFL_BAD | 1 << 16
			}
		}
		return true
	}
	return huff_build(out, lengths, HROOT) != 0
}

// Inflates a zlib stream into out; returns bytes written.
@(private)
inflate_zlib :: proc(src: []byte, out: []u8) -> (int, Error) #no_bounds_check {
	if len(src) < 2 do return 0, .Truncated
	cmf, flg := src[0], src[1]
	if cmf & 15 != 8 || (int(cmf) * 256 + int(flg)) % 31 != 0 || flg & 0x20 != 0 do return 0, .Corrupt
	br := LBits{data = src, pos = 2}
	lit_t: [2048]u32
	dist_t: [2048]u32
	n := len(out)
	o := 0
	dst := raw_data(out)
	for {
		final := lb_read(&br, 1)
		typ := lb_read(&br, 2)
		switch typ {
		case 0:
			// stored: align, LEN, NLEN
			lb_read(&br, br.nbits & 7)
			l := int(lb_read(&br, 16))
			nl := int(lb_read(&br, 16))
			if l != (~nl & 0xFFFF) do return o, .Corrupt
			// drain whole bytes still in the bit buffer first
			for l > 0 && br.nbits >= 8 {
				b := u8(lb_read(&br, 8))
				if o < n do dst[o] = b
				o += 1
				l -= 1
			}
			if l == 0 do break
			p := br.pos
			if p > len(src) do return min(o, n), .Truncated
			k := min(l, len(src) - p)
			c := min(k, max(n - o, 0))
			if c > 0 do intrinsics.mem_copy_non_overlapping(&dst[o], &src[p], c)
			o += k
			br.pos = p + k
			br.bits, br.nbits = 0, 0
			if k < l do return min(o, n), .Truncated
		case 1, 2:
			lengths: [320]u8
			hlit, hdist := 288, 32
			if typ == 1 {
				for i in 0 ..< 144 do lengths[i] = 8
				for i in 144 ..< 256 do lengths[i] = 9
				for i in 256 ..< 280 do lengths[i] = 7
				for i in 280 ..< 288 do lengths[i] = 8
				for i in 0 ..< 32 do lengths[288 + i] = 5
			} else {
				hlit = int(lb_read(&br, 5)) + 257
				hdist = int(lb_read(&br, 5)) + 1
				hclen := int(lb_read(&br, 4)) + 4
				cl: [19]u8
				for i in 0 ..< hclen do cl[CL_ORDER[i]] = u8(lb_read(&br, 3))
				clt: [256]u32
				if !infl_build(clt[:], cl[:]) do return o, .Corrupt
				i := 0
				for i < hlit + hdist {
					s := huff_sym(&br, raw_data(clt[:]))
					switch s {
					case 0 ..= 15:
						lengths[i] = u8(s)
						i += 1
					case 16:
						if i == 0 do return o, .Corrupt
						r := 3 + int(lb_read(&br, 2))
						if i + r > hlit + hdist do return o, .Corrupt
						for _ in 0 ..< r {
							lengths[i] = lengths[i - 1]
							i += 1
						}
					case 17, 18:
						r := s == 17 ? 3 + int(lb_read(&br, 3)) : 11 + int(lb_read(&br, 7))
						if i + r > hlit + hdist do return o, .Corrupt
						i += r // already zero
					case:
						return o, .Corrupt
					}
					if lb_overrun(&br) do return o, .Truncated
				}
				if lengths[256] == 0 do return o, .Corrupt
			}
			// distance lengths start at hlit in `lengths`
			if !infl_build(lit_t[:], lengths[:hlit]) do return o, .Corrupt
			dl: [32]u8
			copy(dl[:], lengths[hlit:hlit + hdist])
			nd := 0
			for l in dl do if l != 0 do nd += 1
			if nd > 0 {
				if !infl_build(dist_t[:], dl[:hdist]) do return o, .Corrupt
			}
			lt := raw_data(lit_t[:])
			dt := raw_data(dist_t[:])
			for {
				s := huff_sym(&br, lt)
				if s < 256 {
					if o >= n do return n, .None
					dst[o] = u8(s)
					o += 1
					continue
				}
				if s == 256 do break
				s -= 257
				if s >= 29 do return o, .Corrupt
				if br.nbits < 32 do lb_fill(&br)
				length := int(LEN_BASE[s]) + int(lb_read(&br, u32(LEN_EXTRA[s])))
				if nd == 0 do return o, .Corrupt
				ds := huff_sym(&br, dt)
				if ds >= 30 do return o, .Corrupt
				dist := int(DIST_BASE[ds]) + int(lb_read(&br, u32(DIST_EXTRA[ds])))
				if dist > o do return o, .Corrupt
				if o + length > n {
					// the image needs no more than n bytes; finish what fits
					for k in 0 ..< n - o do dst[o + k] = dst[o + k - dist]
					return n, .None
				}
				sp := o - dist
				if dist >= 8 && o + length + 8 <= n {
					for k := 0; k < length; k += 8 {
						intrinsics.unaligned_store((^u64)(&dst[o + k]), intrinsics.unaligned_load((^u64)(&dst[sp + k])))
					}
				} else {
					for k in 0 ..< length do dst[o + k] = dst[sp + k]
				}
				o += length
				if lb_overrun(&br) do return o, .Truncated
			}
		case:
			return o, .Corrupt
		}
		if lb_overrun(&br) do return min(o, n), .Truncated
		if final == 1 do break
	}
	return min(o, n), .None
}
