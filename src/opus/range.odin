// Pure-Odin Opus codec (RFC 6716 + RFC 8251).
//
// The algorithms follow the normative reference implementation in RFC 6716
// (libopus, BSD-licensed: Copyright 2001-2011 Xiph.Org, Skype Limited,
// Octasic, Jean-Marc Valin, Timothy B. Terriberry, CSIRO, Gregory Maxwell,
// Mark Borgerding, Erik de Castro Lopo; see COPYING in libopus). SILK uses the
// reference fixed-point arithmetic (bit-exact); CELT uses the float path.
package opus

// ---------------------------------------------------------------------------
// Range coder (entcode/entdec/entenc)

EC_SYM_BITS :: 8
EC_CODE_BITS :: 32
EC_SYM_MAX :: 255
EC_CODE_SHIFT :: 23
EC_CODE_TOP :: u32(1) << 31
EC_CODE_BOT :: u32(1) << 23
EC_CODE_EXTRA :: 7
EC_WINDOW_SIZE :: 32
EC_UINT_BITS :: 8
BITRES :: 3

Range :: struct {
	buf:         []u8,
	storage:     u32,
	end_offs:    u32,
	end_window:  u32,
	nend_bits:   i32,
	nbits_total: i32,
	offs:        u32,
	rng:         u32,
	val:         u32,
	ext:         u32,
	rem:         i32,
	error:       i32,
}

ec_ilog :: #force_inline proc "contextless" (x: u32) -> i32 {
	return x == 0 ? 0 : 32 - i32(intrinsics_clz(x))
}

@(private)
intrinsics_clz :: #force_inline proc "contextless" (x: u32) -> u32 {
	n: u32 = 0
	v := x
	if v == 0 do return 32
	if v & 0xFFFF0000 == 0 {n += 16; v <<= 16}
	if v & 0xFF000000 == 0 {n += 8; v <<= 8}
	if v & 0xF0000000 == 0 {n += 4; v <<= 4}
	if v & 0xC0000000 == 0 {n += 2; v <<= 2}
	if v & 0x80000000 == 0 {n += 1}
	return n
}

ec_tell :: #force_inline proc "contextless" (r: ^Range) -> i32 {
	return r.nbits_total - ec_ilog(r.rng)
}

ec_tell_frac :: proc "contextless" (r: ^Range) -> u32 {
	nbits := u32(r.nbits_total) << BITRES
	l := ec_ilog(r.rng)
	rr := r.rng >> u32(l - 16)
	for _ in 0 ..< BITRES {
		rr = rr * rr >> 15
		b := i32(rr >> 16)
		l = l << 1 | b
		rr >>= u32(b)
	}
	return nbits - u32(l)
}

// ---- Decoder

@(private = "file")
read_byte :: #force_inline proc "contextless" (r: ^Range) -> i32 {
	if r.offs < r.storage {
		b := r.buf[r.offs]
		r.offs += 1
		return i32(b)
	}
	return 0
}

@(private = "file")
read_byte_from_end :: #force_inline proc "contextless" (r: ^Range) -> i32 {
	if r.end_offs < r.storage {
		r.end_offs += 1
		return i32(r.buf[r.storage - r.end_offs])
	}
	return 0
}

@(private = "file")
dec_normalize :: #force_inline proc "contextless" (r: ^Range) {
	for r.rng <= EC_CODE_BOT {
		r.nbits_total += EC_SYM_BITS
		r.rng <<= EC_SYM_BITS
		sym := r.rem
		r.rem = read_byte(r)
		sym = (sym << EC_SYM_BITS | r.rem) >> (EC_SYM_BITS - EC_CODE_EXTRA)
		r.val = ((r.val << EC_SYM_BITS) + (EC_SYM_MAX & ~u32(sym))) & (EC_CODE_TOP - 1)
	}
}

ec_dec_init :: proc "contextless" (r: ^Range, buf: []u8) {
	r^ = {}
	r.buf = buf
	r.storage = u32(len(buf))
	r.nbits_total = EC_CODE_BITS + 1 - ((EC_CODE_BITS - EC_CODE_EXTRA) / EC_SYM_BITS) * EC_SYM_BITS
	r.rng = 1 << EC_CODE_EXTRA
	r.rem = read_byte(r)
	r.val = r.rng - 1 - u32(r.rem >> (EC_SYM_BITS - EC_CODE_EXTRA))
	dec_normalize(r)
}

ec_decode :: #force_inline proc "contextless" (r: ^Range, ft: u32) -> u32 {
	r.ext = r.rng / ft
	s := r.val / r.ext
	return ft - min(s + 1, ft)
}

ec_decode_bin :: #force_inline proc "contextless" (r: ^Range, bits: u32) -> u32 {
	r.ext = r.rng >> bits
	s := r.val / r.ext
	return (u32(1) << bits) - min(s + 1, u32(1) << bits)
}

ec_dec_update :: #force_inline proc "contextless" (r: ^Range, fl, fh, ft: u32) {
	s := r.ext * (ft - fh)
	r.val -= s
	r.rng = fl > 0 ? r.ext * (fh - fl) : r.rng - s
	dec_normalize(r)
}

ec_dec_bit_logp :: proc "contextless" (r: ^Range, logp: u32) -> bool {
	rr := r.rng
	d := r.val
	s := rr >> logp
	ret := d < s
	if !ret do r.val = d - s
	r.rng = ret ? s : rr - s
	dec_normalize(r)
	return ret
}

ec_dec_icdf :: proc "contextless" (r: ^Range, icdf: []u8, ftb: u32) -> i32 {
	s := r.rng
	d := r.val
	rr := s >> ftb
	ret: i32 = -1
	t: u32
	for {
		t = s
		ret += 1
		s = rr * u32(icdf[ret])
		if d >= s do break
	}
	r.val = d - s
	r.rng = t - s
	dec_normalize(r)
	return ret
}

ec_dec_uint :: proc "contextless" (r: ^Range, ft_: u32) -> u32 {
	ft := ft_ - 1
	ftb := ec_ilog(ft)
	if ftb > EC_UINT_BITS {
		ftb -= EC_UINT_BITS
		f := (ft >> u32(ftb)) + 1
		s := ec_decode(r, f)
		ec_dec_update(r, s, s + 1, f)
		t := s << u32(ftb) | ec_dec_bits(r, u32(ftb))
		if t <= ft do return t
		r.error = 1
		return ft
	}
	ft += 1
	s := ec_decode(r, ft)
	ec_dec_update(r, s, s + 1, ft)
	return s
}

ec_dec_bits :: proc "contextless" (r: ^Range, bits: u32) -> u32 {
	window := r.end_window
	available := r.nend_bits
	if u32(available) < bits {
		for {
			window |= u32(read_byte_from_end(r)) << u32(available)
			available += EC_SYM_BITS
			if available > EC_WINDOW_SIZE - EC_SYM_BITS do break
		}
	}
	ret := window & ((u32(1) << bits) - 1)
	window = bits >= 32 ? 0 : window >> bits
	available -= i32(bits)
	r.end_window = window
	r.nend_bits = available
	r.nbits_total += i32(bits)
	return ret
}

// ---- Encoder

@(private = "file")
write_byte :: proc "contextless" (r: ^Range, v: u32) -> i32 {
	if r.offs + r.end_offs >= r.storage do return -1
	r.buf[r.offs] = u8(v)
	r.offs += 1
	return 0
}

@(private = "file")
write_byte_at_end :: proc "contextless" (r: ^Range, v: u32) -> i32 {
	if r.offs + r.end_offs >= r.storage do return -1
	r.end_offs += 1
	r.buf[r.storage - r.end_offs] = u8(v)
	return 0
}

@(private = "file")
carry_out :: proc "contextless" (r: ^Range, c: i32) {
	if c != EC_SYM_MAX {
		carry := c >> EC_SYM_BITS
		if r.rem >= 0 do r.error |= write_byte(r, u32(r.rem + carry))
		if r.ext > 0 {
			sym := u32(EC_SYM_MAX + carry) & EC_SYM_MAX
			for {
				r.error |= write_byte(r, sym)
				r.ext -= 1
				if r.ext == 0 do break
			}
		}
		r.rem = c & EC_SYM_MAX
	} else {
		r.ext += 1
	}
}

@(private = "file")
enc_normalize :: #force_inline proc "contextless" (r: ^Range) {
	for r.rng <= EC_CODE_BOT {
		carry_out(r, i32(r.val >> EC_CODE_SHIFT))
		r.val = (r.val << EC_SYM_BITS) & (EC_CODE_TOP - 1)
		r.rng <<= EC_SYM_BITS
		r.nbits_total += EC_SYM_BITS
	}
}

ec_enc_init :: proc "contextless" (r: ^Range, buf: []u8) {
	r^ = {}
	r.buf = buf
	r.nbits_total = EC_CODE_BITS + 1
	r.rng = EC_CODE_TOP
	r.rem = -1
	r.storage = u32(len(buf))
}

ec_encode :: proc "contextless" (r: ^Range, fl, fh, ft: u32) {
	rr := r.rng / ft
	if fl > 0 {
		r.val += r.rng - rr * (ft - fl)
		r.rng = rr * (fh - fl)
	} else {
		r.rng -= rr * (ft - fh)
	}
	enc_normalize(r)
}

ec_encode_bin :: proc "contextless" (r: ^Range, fl, fh, bits: u32) {
	rr := r.rng >> bits
	if fl > 0 {
		r.val += r.rng - rr * ((u32(1) << bits) - fl)
		r.rng = rr * (fh - fl)
	} else {
		r.rng -= rr * ((u32(1) << bits) - fh)
	}
	enc_normalize(r)
}

ec_enc_bit_logp :: proc "contextless" (r: ^Range, val: bool, logp: u32) {
	rr := r.rng
	l := r.val
	s := rr >> logp
	rr -= s
	if val do r.val = l + rr
	r.rng = val ? s : rr
	enc_normalize(r)
}

ec_enc_icdf :: proc "contextless" (r: ^Range, s: i32, icdf: []u8, ftb: u32) {
	rr := r.rng >> ftb
	if s > 0 {
		r.val += r.rng - rr * u32(icdf[s - 1])
		r.rng = rr * u32(icdf[s - 1] - icdf[s])
	} else {
		r.rng -= rr * u32(icdf[s])
	}
	enc_normalize(r)
}

ec_enc_uint :: proc "contextless" (r: ^Range, fl_: u32, ft_: u32) {
	ft := ft_ - 1
	ftb := ec_ilog(ft)
	if ftb > EC_UINT_BITS {
		ftb -= EC_UINT_BITS
		f := (ft >> u32(ftb)) + 1
		fl := fl_ >> u32(ftb)
		ec_encode(r, fl, fl + 1, f)
		ec_enc_bits(r, fl_ & ((u32(1) << u32(ftb)) - 1), u32(ftb))
	} else {
		ec_encode(r, fl_, fl_ + 1, ft + 1)
	}
}

ec_enc_bits :: proc "contextless" (r: ^Range, fl: u32, bits: u32) {
	window := r.end_window
	used := r.nend_bits
	if used + i32(bits) > EC_WINDOW_SIZE {
		for {
			r.error |= write_byte_at_end(r, window & EC_SYM_MAX)
			window >>= EC_SYM_BITS
			used -= EC_SYM_BITS
			if used < EC_SYM_BITS do break
		}
	}
	window |= fl << u32(used)
	used += i32(bits)
	r.end_window = window
	r.nend_bits = used
	r.nbits_total += i32(bits)
}

ec_enc_patch_initial_bits :: proc "contextless" (r: ^Range, val: u32, nbits: u32) {
	shift := EC_SYM_BITS - nbits
	mask := ((u32(1) << nbits) - 1) << shift
	if r.offs > 0 {
		r.buf[0] = u8((u32(r.buf[0]) & ~mask) | val << shift)
	} else if r.rem >= 0 {
		r.rem = i32((u32(r.rem) & ~mask) | val << shift)
	} else if r.rng <= (EC_CODE_TOP >> nbits) {
		r.val = (r.val & ~(mask << EC_CODE_SHIFT)) | val << (EC_CODE_SHIFT + shift)
	} else {
		r.error = -1
	}
}

ec_enc_shrink :: proc "contextless" (r: ^Range, size: u32) {
	copy(r.buf[size - r.end_offs:size], r.buf[r.storage - r.end_offs:r.storage])
	r.storage = size
}

ec_enc_done :: proc "contextless" (r: ^Range) {
	l := EC_CODE_BITS - ec_ilog(r.rng)
	msk := (EC_CODE_TOP - 1) >> u32(l)
	end := (r.val + msk) & ~msk
	if (end | msk) >= r.val + r.rng {
		l += 1
		msk >>= 1
		end = (r.val + msk) & ~msk
	}
	for l > 0 {
		carry_out(r, i32(end >> EC_CODE_SHIFT))
		end = (end << EC_SYM_BITS) & (EC_CODE_TOP - 1)
		l -= EC_SYM_BITS
	}
	if r.rem >= 0 || r.ext > 0 do carry_out(r, 0)
	window := r.end_window
	used := r.nend_bits
	for used >= EC_SYM_BITS {
		r.error |= write_byte_at_end(r, window & EC_SYM_MAX)
		window >>= EC_SYM_BITS
		used -= EC_SYM_BITS
	}
	if r.error == 0 {
		for i in r.offs ..< r.storage - r.end_offs do r.buf[i] = 0
		if used > 0 {
			if r.end_offs >= r.storage {
				r.error = -1
			} else {
				l = -l
				if r.offs + r.end_offs >= r.storage && l < used {
					window &= (u32(1) << u32(l)) - 1
					r.error = -1
				}
				r.buf[r.storage - r.end_offs - 1] |= u8(window)
			}
		}
	}
}
