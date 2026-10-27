package imagefmt

import "core:math"
import "core:slice"

// encode_webp_lossless writes RGBA8 pixels as a lossless WebP (RIFF + VP8L). What Chrome's
// canvas.toBlob("image/webp", 1) produces for the official client's upload conversion; not
// byte-identical to libwebp, but every pixel survives exactly.
//
// Tools used: color-indexing (<= 256 colors, with pixel bundling), else subtract-green +
// per-tile predictors (16x16); then LZ77 (hash chains plus the left / up candidates), an
// optional color cache (picked by estimated size) and one set of canonical prefix codes.
encode_webp_lossless :: proc(rgba: []byte, w, h: int, allocator := context.allocator) -> []byte {
	assert(w >= 1 && h >= 1 && w <= 16384 && h <= 16384 && len(rgba) >= w * h * 4)
	n := w * h
	argb := make([]u32, n, context.temp_allocator)
	has_alpha := false
	for i in 0 ..< n {
		p := rgba[i * 4:]
		argb[i] = u32(p[3]) << 24 | u32(p[0]) << 16 | u32(p[1]) << 8 | u32(p[2])
		if p[3] != 255 do has_alpha = true
	}
	bw: W_Bits
	bw.out = make([dynamic]byte, 0, n / 2 + 64, context.temp_allocator)
	wb_put(&bw, 0x2f, 8)
	wb_put(&bw, u32(w - 1), 14)
	wb_put(&bw, u32(h - 1), 14)
	wb_put(&bw, has_alpha ? 1 : 0, 1)
	wb_put(&bw, 0, 3) // version

	img := argb
	xs := w
	if pal, ok := palette_of(argb); ok {
		// COLOR_INDEXING
		wb_put(&bw, 1, 1)
		wb_put(&bw, 3, 2)
		wb_put(&bw, u32(len(pal) - 1), 8)
		delta := make([]u32, len(pal), context.temp_allocator)
		prev: u32
		for c, i in pal {
			delta[i] = sub_pixels(c, prev)
			prev = c
		}
		write_image(&bw, delta, len(pal), 1, false)
		bits := len(pal) > 16 ? uint(0) : len(pal) > 4 ? 1 : len(pal) > 2 ? 2 : 3
		img, xs = index_pixels(argb, w, h, pal, bits)
	} else {
		// SUBTRACT_GREEN, then PREDICTOR (inverted in the opposite order by the decoder)
		wb_put(&bw, 1, 1)
		wb_put(&bw, 2, 2)
		sg := make([]u32, n, context.temp_allocator)
		for p, i in argb {
			g := (p >> 8) & 0xFF
			sg[i] = (p & 0xFF00FF00) | (((0xFF00FF00 + (p & 0x00FF00FF)) - (g << 16 | g)) & 0x00FF00FF) // no borrow from blue into red
		}
		PRED_BITS :: 4
		wb_put(&bw, 1, 1)
		wb_put(&bw, 0, 2)
		wb_put(&bw, PRED_BITS - 2, 3)
		modes, tw, th := choose_predictors(sg, w, h, PRED_BITS)
		write_image(&bw, modes, tw, th, false)
		img = predict_residuals(sg, w, h, modes, tw, PRED_BITS)
	}
	wb_put(&bw, 0, 1) // no more transforms
	write_image(&bw, img, xs, h, true)
	wb_flush(&bw)

	vp8l := bw.out[:]
	pad := len(vp8l) & 1
	out := make([]byte, 20 + len(vp8l) + pad, allocator)
	copy(out[0:], "RIFF")
	put_le32(out[4:], u32(12 + len(vp8l) + pad))
	copy(out[8:], "WEBPVP8L")
	put_le32(out[16:], u32(len(vp8l)))
	copy(out[20:], vp8l)
	return out
}

@(private = "file")
put_le32 :: proc(b: []byte, v: u32) {
	b[0], b[1], b[2], b[3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
}

@(private = "file")
sub_pixels :: #force_inline proc "contextless" (a, b: u32) -> u32 {
	ag := 0x00FF00FF + (a & 0xFF00FF00) - (b & 0xFF00FF00)
	rb := 0xFF00FF00 + (a & 0x00FF00FF) - (b & 0x00FF00FF)
	return (ag & 0xFF00FF00) | (rb & 0x00FF00FF)
}

// ---- bit writer (LSB first) ----

@(private = "file")
W_Bits :: struct {
	out:  [dynamic]byte,
	acc:  u64,
	nacc: uint,
}

@(private = "file")
wb_put :: #force_inline proc(bw: ^W_Bits, v: u32, n: uint) {
	if n == 0 do return
	bw.acc |= u64(v & ((1 << n) - 1)) << bw.nacc
	bw.nacc += n
	for bw.nacc >= 8 {
		append(&bw.out, u8(bw.acc))
		bw.acc >>= 8
		bw.nacc -= 8
	}
}

@(private = "file")
wb_flush :: proc(bw: ^W_Bits) {
	if bw.nacc > 0 do append(&bw.out, u8(bw.acc))
	bw.acc, bw.nacc = 0, 0
}

// ---- color indexing ----

@(private = "file")
palette_of :: proc(px: []u32) -> ([]u32, bool) {
	seen := make(map[u32]struct{}, 512, context.temp_allocator)
	last := ~px[0]
	for p in px {
		if p == last do continue
		last = p
		seen[p] = {}
		if len(seen) > 256 do return nil, false
	}
	pal := make([]u32, len(seen), context.temp_allocator)
	i := 0
	for k in seen {
		pal[i] = k
		i += 1
	}
	slice.sort(pal)
	return pal, true
}

// Indices in the green channel, 2^bits pixels bundled per output pixel (first pixel in the low bits).
@(private = "file")
index_pixels :: proc(px: []u32, w, h: int, pal: []u32, bits: uint) -> ([]u32, int) {
	idx := make(map[u32]u32, len(pal), context.temp_allocator)
	for c, i in pal do idx[c] = u32(i)
	pw := (w + (1 << bits) - 1) >> bits
	out := make([]u32, pw * h, context.temp_allocator)
	bpp := 8 >> bits
	for y in 0 ..< h {
		for x in 0 ..< w {
			o := &out[y * pw + (x >> bits)]
			o^ |= idx[px[y * w + x]] << (8 + uint(x & ((1 << bits) - 1)) * uint(bpp))
		}
		for x in 0 ..< pw do out[y * pw + x] |= 0xFF000000
	}
	return out, pw
}

// ---- predictor ----

@(private = "file")
residual_cost :: #force_inline proc "contextless" (r: u32) -> u32 {
	c: u32
	for sh := u32(0); sh < 32; sh += 8 {
		v := (r >> sh) & 0xFF
		c += v < 128 ? v : 256 - v
	}
	return c
}

@(private = "file")
choose_predictors :: proc(px: []u32, w, h: int, bits: uint) -> ([]u32, int, int) {
	tw := (w + (1 << bits) - 1) >> bits
	th := (h + (1 << bits) - 1) >> bits
	modes := make([]u32, tw * th, context.temp_allocator)
	p := raw_data(px)
	for ty in 0 ..< th {
		for tx in 0 ..< tw {
			best, best_cost := u32(1), max(u32)
			for mode in u32(0) ..< 14 {
				cost: u32
				for y in ty << bits ..< min((ty + 1) << bits, h) {
					if y == 0 do continue
					for x in tx << bits ..< min((tx + 1) << bits, w) {
						if x == 0 do continue
						i := y * w + x
						pr := predict(mode, p[i - 1], p[i - w:])
						cost += residual_cost(sub_pixels(p[i], pr))
					}
				}
				if cost < best_cost do best, best_cost = mode, cost
			}
			modes[ty * tw + tx] = 0xFF000000 | best << 8
		}
	}
	return modes, tw, th
}

@(private = "file")
predict_residuals :: proc(px: []u32, w, h: int, modes: []u32, tw: int, bits: uint) -> []u32 {
	out := make([]u32, w * h, context.temp_allocator)
	p := raw_data(px)
	for y in 0 ..< h {
		for x in 0 ..< w {
			i := y * w + x
			pr: u32
			switch {
			case y == 0 && x == 0:
				pr = 0xFF000000
			case y == 0:
				pr = p[i - 1]
			case x == 0:
				pr = p[i - w]
			case:
				pr = predict((modes[(y >> bits) * tw + (x >> bits)] >> 8) & 0xF, p[i - 1], p[i - w:])
			}
			out[i] = sub_pixels(p[i], pr)
		}
	}
	return out
}

// ---- entropy-coded image ----

@(private = "file")
Token :: struct {
	kind: u8, // 0 literal (v = argb), 1 copy (v = length, d = distance code), 2 cache (v = index)
	v:    u32,
	d:    u32,
}

MAX_LEN :: 4096

// distance (in pixels) -> distance code: the 120 short 2D codes first, else dist + 120
@(private = "file")
dist_code :: proc(dist: int, xs: int, table: map[int]int) -> u32 {
	if c, ok := table[dist]; ok do return u32(c)
	return u32(dist + 120)
}

@(private = "file")
plane_table :: proc(xs: int) -> map[int]int {
	t := make(map[int]int, 128, context.temp_allocator)
	for pc, i in VP8L_CODE_TO_PLANE {
		d := int(pc >> 4) * xs + 8 - int(pc & 0xF)
		if d < 1 do continue
		if _, ok := t[d]; !ok do t[d] = i + 1
	}
	return t
}

@(private = "file")
lz77 :: proc(px: []u32, xs: int) -> [dynamic]Token {
	n := len(px)
	toks := make([dynamic]Token, 0, n / 2 + 16, context.temp_allocator)
	HB :: 16
	head := make([]i32, 1 << HB, context.temp_allocator)
	for &e in head do e = -1
	prev := make([]i32, n, context.temp_allocator)
	hash :: #force_inline proc(px: []u32, i: int) -> u32 {
		return ((px[i] * 0x1e35a7bd) ~ (px[i + 1] * 0x9E3779B1)) >> (32 - HB)
	}
	insert :: #force_inline proc(head, prev: []i32, px: []u32, i: int) {
		if i + 1 >= len(px) do return
		hv := hash(px, i)
		prev[i] = head[hv]
		head[hv] = i32(i)
	}
	match_len :: #force_inline proc(px: []u32, a, b, maxl: int) -> int {
		l := 0
		for l < maxl && px[a + l] == px[b + l] do l += 1
		return l
	}
	planes := plane_table(xs)
	i := 0
	for i < n {
		maxl := min(MAX_LEN, n - i)
		best, best_d := 0, 0
		// the two cheapest distances first: the left pixel and the one above
		if i >= 1 {
			if l := match_len(px, i - 1, i, maxl); l > best do best, best_d = l, 1
		}
		if i >= xs && best < maxl {
			if l := match_len(px, i - xs, i, maxl); l > best do best, best_d = l, xs
		}
		if i + 1 < n && best < maxl {
			c := int(head[hash(px, i)])
			for chain := 0; c >= 0 && chain < 24 && best < maxl; chain += 1 {
				if i - c > (1 << 20) - 120 do break
				if px[c + best] == px[i + best] {
					if l := match_len(px, c, i, maxl); l > best do best, best_d = l, i - c
				}
				c = int(prev[c])
			}
		}
		if best >= 3 || (best >= 2 && (best_d == 1 || best_d == xs)) {
			append(&toks, Token{kind = 1, v = u32(best), d = dist_code(best_d, xs, planes)})
			for k in 0 ..< best do insert(head, prev, px, i + k)
			i += best
		} else {
			append(&toks, Token{kind = 0, v = px[i]})
			insert(head, prev, px, i)
			i += 1
		}
	}
	return toks
}

@(private = "file")
prefix_encode :: #force_inline proc(v: u32) -> (code, extra_bits, extra: u32) {
	n := v - 1
	if n < 4 do return n, 0, 0
	hb := u32(31 - intrinsics_clz(n))
	second := (n >> (hb - 1)) & 1
	extra_bits = hb - 1
	return 2 * hb + second, extra_bits, n & ((1 << extra_bits) - 1)
}

@(private = "file")
intrinsics_clz :: #force_inline proc "contextless" (v: u32) -> u32 {
	n: u32 = 0
	x := v
	if x == 0 do return 32
	for x & 0x80000000 == 0 {
		x <<= 1
		n += 1
	}
	return n
}

@(private = "file")
Histos :: struct {
	g:    []u32, // 256 + 24 + cache
	r, b, a: [256]u32,
	d:    [40]u32,
	extra: u64,
}

@(private = "file")
apply_cache :: proc(toks: []Token, px_src: []u32, cache_bits: uint) -> [dynamic]Token {
	out := make([dynamic]Token, 0, len(toks), context.temp_allocator)
	cache := make([]u32, 1 << cache_bits, context.temp_allocator)
	shift := 32 - cache_bits
	i := 0
	for t in toks {
		switch t.kind {
		case 0:
			k := (0x1e35a7bd * t.v) >> shift
			if cache[k] == t.v {
				append(&out, Token{kind = 2, v = k})
			} else {
				append(&out, t)
				cache[k] = t.v
			}
			i += 1
		case 1:
			append(&out, t)
			for j in 0 ..< int(t.v) do cache[(0x1e35a7bd * px_src[i + j]) >> shift] = px_src[i + j]
			i += int(t.v)
		}
	}
	return out
}

@(private = "file")
histograms :: proc(toks: []Token, cache_bits: uint) -> Histos {
	h: Histos
	h.g = make([]u32, 256 + 24 + (cache_bits > 0 ? 1 << cache_bits : 0), context.temp_allocator)
	for t in toks {
		switch t.kind {
		case 0:
			h.g[(t.v >> 8) & 0xFF] += 1
			h.r[(t.v >> 16) & 0xFF] += 1
			h.b[t.v & 0xFF] += 1
			h.a[t.v >> 24] += 1
		case 1:
			lc, lb, _ := prefix_encode(t.v)
			h.g[256 + lc] += 1
			dc, db, _ := prefix_encode(t.d)
			h.d[dc] += 1
			h.extra += u64(lb + db)
		case 2:
			h.g[280 + t.v] += 1
		}
	}
	return h
}

@(private = "file")
entropy_bits :: proc(counts: []u32) -> f64 {
	total: u64
	for c in counts do total += u64(c)
	if total == 0 do return 0
	bits: f64
	ft := f64(total)
	for c in counts do if c > 0 do bits -= f64(c) * math.log2(f64(c) / ft)
	return bits
}

@(private = "file")
estimate :: proc(h: ^Histos) -> f64 {
	return entropy_bits(h.g) + entropy_bits(h.r[:]) + entropy_bits(h.b[:]) + entropy_bits(h.a[:]) + entropy_bits(h.d[:]) + f64(h.extra)
}

@(private = "file")
write_image :: proc(bw: ^W_Bits, px: []u32, xs, ys: int, main: bool) {
	toks := lz77(px, xs)
	best_bits := uint(0)
	h0 := histograms(toks[:], 0)
	best_est := estimate(&h0)
	best_toks := toks
	if len(px) >= 64 {
		for cb in ([]uint{4, 6, 8, 10}) {
			ct := apply_cache(toks[:], px, cb)
			hc := histograms(ct[:], cb)
			// the larger green alphabet costs a little in the code header
			est := estimate(&hc) + f64(cb) * 8
			if est < best_est do best_est, best_bits, best_toks = est, cb, ct
		}
	}
	if best_bits > 0 {
		wb_put(bw, 1, 1)
		wb_put(bw, u32(best_bits), 4)
	} else {
		wb_put(bw, 0, 1)
	}
	if main do wb_put(bw, 0, 1) // no meta prefix codes
	hist := histograms(best_toks[:], best_bits)
	codes: [5]Prefix_Code
	codes[0] = build_code(hist.g, 15)
	codes[1] = build_code(hist.r[:], 15)
	codes[2] = build_code(hist.b[:], 15)
	codes[3] = build_code(hist.a[:], 15)
	codes[4] = build_code(hist.d[:], 15)
	for &c in codes do write_code(bw, &c)
	for t in best_toks {
		switch t.kind {
		case 0:
			put_sym(bw, &codes[0], (t.v >> 8) & 0xFF)
			put_sym(bw, &codes[1], (t.v >> 16) & 0xFF)
			put_sym(bw, &codes[2], t.v & 0xFF)
			put_sym(bw, &codes[3], t.v >> 24)
		case 1:
			lc, lb, le := prefix_encode(t.v)
			put_sym(bw, &codes[0], 256 + lc)
			wb_put(bw, le, uint(lb))
			dc, db, de := prefix_encode(t.d)
			put_sym(bw, &codes[4], dc)
			wb_put(bw, de, uint(db))
		case 2:
			put_sym(bw, &codes[0], 280 + t.v)
		}
	}
}

// ---- prefix codes ----

@(private = "file")
Prefix_Code :: struct {
	lengths: []u8,
	codes:   []u32, // bit-reversed, ready to write LSB first
	used:    int,
	simple:  [2]u32,
}

@(private = "file")
put_sym :: #force_inline proc(bw: ^W_Bits, c: ^Prefix_Code, s: u32) {
	if c.used <= 1 do return // a single symbol is coded in zero bits
	wb_put(bw, c.codes[s], uint(c.lengths[s]))
}

// Huffman code lengths limited to max_len (frequencies flattened until they fit).
@(private = "file")
code_lengths :: proc(counts: []u32, max_len: int, out: []u8) {
	for &l in out do l = 0
	n := len(counts)
	syms := make([dynamic]int, 0, n, context.temp_allocator)
	for c, i in counts do if c > 0 do append(&syms, i)
	if len(syms) == 0 do return
	if len(syms) == 1 {
		out[syms[0]] = 1
		return
	}
	freq := make([]u64, n, context.temp_allocator)
	for s in syms do freq[s] = u64(counts[s])
	for {
		// classic Huffman over (weight, node) with parent links
		Node :: struct {
			w:      u64,
			parent: int,
		}
		nodes := make([dynamic]Node, 0, 2 * len(syms), context.temp_allocator)
		Item :: struct {
			w:  u64,
			id: int,
		}
		items := make([dynamic]Item, 0, len(syms), context.temp_allocator)
		for s in syms {
			append(&nodes, Node{freq[s], -1})
			append(&items, Item{freq[s], len(nodes) - 1})
		}
		for len(items) > 1 {
			slice.sort_by(items[:], proc(a, b: Item) -> bool {return a.w > b.w || (a.w == b.w && a.id > b.id)})
			x := pop(&items)
			y := pop(&items)
			append(&nodes, Node{x.w + y.w, -1})
			p := len(nodes) - 1
			nodes[x.id].parent = p
			nodes[y.id].parent = p
			append(&items, Item{x.w + y.w, p})
		}
		maxl := 0
		for s, k in syms {
			d := 0
			for j := k; nodes[j].parent >= 0; j = nodes[j].parent do d += 1
			out[s] = u8(d)
			maxl = max(maxl, d)
		}
		if maxl <= max_len do return
		for s in syms do freq[s] = max(1, freq[s] >> 1) + 1
	}
}

@(private = "file")
canonical :: proc(lengths: []u8, codes: []u32) {
	count: [16]u32
	for l in lengths do count[l] += 1
	count[0] = 0
	next: [16]u32
	code: u32
	for b in 1 ..< 16 {
		code = (code + count[b - 1]) << 1
		next[b] = code
	}
	for l, s in lengths {
		if l == 0 do continue
		c := next[l]
		next[l] += 1
		r: u32
		for i in 0 ..< u32(l) do r |= ((c >> i) & 1) << (u32(l) - 1 - i)
		codes[s] = r
	}
}

@(private = "file")
build_code :: proc(counts: []u32, max_len: int) -> Prefix_Code {
	c: Prefix_Code
	c.lengths = make([]u8, len(counts), context.temp_allocator)
	c.codes = make([]u32, len(counts), context.temp_allocator)
	code_lengths(counts, max_len, c.lengths)
	for l, s in c.lengths {
		if l == 0 do continue
		if c.used < 2 do c.simple[c.used] = u32(s)
		c.used += 1
	}
	canonical(c.lengths, c.codes)
	return c
}

@(private = "file")
CL_ORDER := [19]u8{17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}

@(private = "file")
write_code :: proc(bw: ^W_Bits, c: ^Prefix_Code) {
	// simple codes: no symbol (an unused alphabet: one zero-length symbol 0), or 1-2 symbols < 256
	if c.used == 0 {
		wb_put(bw, 1, 1)
		wb_put(bw, 0, 1) // one symbol
		wb_put(bw, 0, 1) // 1-bit symbol
		wb_put(bw, 0, 1)
		return
	}
	if c.used <= 2 && c.simple[0] < 256 && (c.used == 1 || c.simple[1] < 256) {
		wb_put(bw, 1, 1)
		wb_put(bw, u32(c.used - 1), 1)
		if c.simple[0] < 2 {
			wb_put(bw, 0, 1)
			wb_put(bw, c.simple[0], 1)
		} else {
			wb_put(bw, 1, 1)
			wb_put(bw, c.simple[0], 8)
		}
		if c.used == 2 do wb_put(bw, c.simple[1], 8)
		if c.used == 2 {
			// both 1 bit long; canonical order is by symbol
			c.lengths[c.simple[0]], c.lengths[c.simple[1]] = 1, 1
			lo, hi := min(c.simple[0], c.simple[1]), max(c.simple[0], c.simple[1])
			c.codes[lo], c.codes[hi] = 0, 1
		}
		return
	}
	// normal code: code lengths run-length coded with symbols 0-15, 16 (repeat previous
	// 3-6), 17 (zeros 3-10), 18 (zeros 11-138)
	Rle :: struct {
		sym:   u8,
		extra: u32,
	}
	rle := make([dynamic]Rle, 0, len(c.lengths), context.temp_allocator)
	ls := c.lengths
	i := 0
	prev := u8(8)
	for i < len(ls) {
		v := ls[i]
		run := 1
		for i + run < len(ls) && ls[i + run] == v do run += 1
		if v == 0 {
			r := run
			for r >= 11 {
				k := min(r, 138)
				append(&rle, Rle{18, u32(k - 11)})
				r -= k
			}
			for r >= 3 {
				k := min(r, 10)
				append(&rle, Rle{17, u32(k - 3)})
				r -= k
			}
			for _ in 0 ..< r do append(&rle, Rle{0, 0})
		} else {
			r := run
			if v != prev {
				append(&rle, Rle{v, 0})
				r -= 1
				prev = v
			}
			for r >= 3 {
				k := min(r, 6)
				append(&rle, Rle{16, u32(k - 3)})
				r -= k
			}
			for _ in 0 ..< r do append(&rle, Rle{v, 0})
		}
		i += run
	}
	cl_counts: [19]u32
	for e in rle do cl_counts[e.sym] += 1
	cl_len: [19]u8
	cl_code: [19]u32
	code_lengths(cl_counts[:], 7, cl_len[:])
	nused := 0
	for l in cl_len do if l > 0 do nused += 1
	canonical(cl_len[:], cl_code[:])
	ncl := 4
	for k in 0 ..< 19 do if cl_len[CL_ORDER[k]] != 0 do ncl = max(ncl, k + 1)
	wb_put(bw, 0, 1)
	wb_put(bw, u32(ncl - 4), 4)
	for k in 0 ..< ncl do wb_put(bw, u32(cl_len[CL_ORDER[k]]), 3)
	wb_put(bw, 0, 1) // max_symbol: the whole alphabet
	EXTRA := [3]uint{2, 3, 7}
	for e in rle {
		if nused > 1 do wb_put(bw, cl_code[e.sym], uint(cl_len[e.sym]))
		if e.sym >= 16 do wb_put(bw, e.extra, EXTRA[e.sym - 16])
	}
}
