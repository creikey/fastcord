package imagefmt

// 16-lane loop filter (libwebp semantics). Horizontal edges load 16 pixels
// per row directly; vertical edges gather 16 rows. Chroma packs U in lanes
// 0..7 and V in lanes 8..15.

import "base:intrinsics"
import "core:simd"

@(private)
V16 :: #simd[16]i16
@(private)
U16 :: #simd[16]u16

@(private)
FMODE_SIMPLE :: 0
@(private)
FMODE_INNER :: 1
@(private)
FMODE_MB :: 2

@(private)
simd_filter :: #force_inline proc "contextless" (v: ^[8]V16, t2, it, hv: i16, mode: int) -> bool {
	p3, p2, p1, p0, q0, q1, q2, q3 := v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]
	S :: #force_inline proc "contextless" (x: i16) -> V16 {return V16(x)}
	U :: #force_inline proc "contextless" (x: u16) -> U16 {return U16(x)}
	ad :: #force_inline proc "contextless" (a, b: V16) -> V16 {return simd.abs(a - b)}
	m := simd.lanes_le(ad(p0, q0) * S(4) + ad(p1, q1), S(t2))
	if mode != FMODE_SIMPLE {
		itv := S(it)
		m &= simd.lanes_le(ad(p3, p2), itv) & simd.lanes_le(ad(p2, p1), itv) & simd.lanes_le(ad(p1, p0), itv)
		m &= simd.lanes_le(ad(q3, q2), itv) & simd.lanes_le(ad(q2, q1), itv) & simd.lanes_le(ad(q1, q0), itv)
	}
	if simd.reduce_or(m) == 0 do return false
	sc1 :: #force_inline proc "contextless" (x: V16) -> V16 {return simd.clamp(x, S(-128), S(127))}
	sc2 :: #force_inline proc "contextless" (x: V16) -> V16 {return simd.clamp(x, S(-16), S(15))}
	cl :: #force_inline proc "contextless" (x: V16) -> V16 {return simd.clamp(x, S(0), S(255))}
	d3 := (q0 - p0) * S(3)
	a := d3 + sc1(p1 - q1)
	a1 := sc2(simd.shr(a + S(4), U(3)))
	a2 := sc2(simd.shr(a + S(3), U(3)))
	f2p0 := cl(p0 + a2)
	f2q0 := cl(q0 - a1)
	if mode == FMODE_SIMPLE {
		v[3] = simd.select(m, f2p0, p0)
		v[4] = simd.select(m, f2q0, q0)
		return true
	}
	hev := simd.lanes_gt(ad(p1, p0), S(hv)) | simd.lanes_gt(ad(q1, q0), S(hv))
	mh := m & hev
	mn := simd.bit_and_not(m, hev)
	if mode == FMODE_MB {
		w := sc1(a)
		b1 := simd.shr(w * S(27) + S(63), U(7))
		b2 := simd.shr(w * S(18) + S(63), U(7))
		b3 := simd.shr(w * S(9) + S(63), U(7))
		v[1] = simd.select(mn, cl(p2 + b3), p2)
		v[2] = simd.select(mn, cl(p1 + b2), p1)
		v[3] = simd.select(mn, cl(p0 + b1), simd.select(mh, f2p0, p0))
		v[4] = simd.select(mn, cl(q0 - b1), simd.select(mh, f2q0, q0))
		v[5] = simd.select(mn, cl(q1 - b2), q1)
		v[6] = simd.select(mn, cl(q2 - b3), q2)
	} else {
		c1 := sc2(simd.shr(d3 + S(4), U(3)))
		c2 := sc2(simd.shr(d3 + S(3), U(3)))
		c3 := simd.shr(c1 + S(1), U(1))
		v[2] = simd.select(mn, cl(p1 + c3), p1)
		v[3] = simd.select(mn, cl(p0 + c2), simd.select(mh, f2p0, p0))
		v[4] = simd.select(mn, cl(q0 - c1), simd.select(mh, f2q0, q0))
		v[5] = simd.select(mn, cl(q1 - c3), q1)
	}
	return true
}

@(private)
ld16 :: #force_inline proc "contextless" (p: [^]u8) -> V16 {
	return cast(V16)intrinsics.unaligned_load((^#simd[16]u8)(p))
}

@(private)
st16 :: #force_inline proc "contextless" (p: [^]u8, v: V16) {
	intrinsics.unaligned_store((^#simd[16]u8)(p), cast(#simd[16]u8)v)
}

@(private)
ld_uv :: #force_inline proc "contextless" (u, v: [^]u8) -> V16 {
	a: [16]u8
	intrinsics.unaligned_store((^u64)(&a[0]), intrinsics.unaligned_load((^u64)(u)))
	intrinsics.unaligned_store((^u64)(&a[8]), intrinsics.unaligned_load((^u64)(v)))
	return cast(V16)intrinsics.unaligned_load((^#simd[16]u8)(&a[0]))
}

@(private)
st_uv :: #force_inline proc "contextless" (u, v: [^]u8, x: V16) {
	a := simd.to_array(cast(#simd[16]u8)x)
	intrinsics.unaligned_store((^u64)(u), intrinsics.unaligned_load((^u64)(&a[0])))
	intrinsics.unaligned_store((^u64)(v), intrinsics.unaligned_load((^u64)(&a[8])))
}

// Filter across a horizontal edge at row p (pixels p[-4*s .. 3*s]), 16 wide.
@(private)
hedge_y :: proc "contextless" (p: [^]u8, s: int, t2, it, hv: i16, mode: int) #no_bounds_check {
	v: [8]V16
	for i in 0 ..< 8 do v[i] = ld16(p[(i - 4) * s:])
	if simd_filter(&v, t2, it, hv, mode) {
		for i in 1 ..< 7 do st16(p[(i - 4) * s:], v[i])
	}
}

@(private)
hedge_uv :: proc "contextless" (u, w: [^]u8, s: int, t2, it, hv: i16, mode: int) #no_bounds_check {
	v: [8]V16
	for i in 0 ..< 8 do v[i] = ld_uv(u[(i - 4) * s:], w[(i - 4) * s:])
	if simd_filter(&v, t2, it, hv, mode) {
		for i in 1 ..< 7 do st_uv(u[(i - 4) * s:], w[(i - 4) * s:], v[i])
	}
}

// Filter across a vertical edge at column p: rows r gathered into lanes.
@(private)
vedge_y :: proc "contextless" (p: [^]u8, s: int, t2, it, hv: i16, mode: int) #no_bounds_check {
	cols: [8][16]i16
	for r in 0 ..< 16 {
		row := p[r * s - 4:]
		for i in 0 ..< 8 do cols[i][r] = i16(row[i])
	}
	v: [8]V16
	for i in 0 ..< 8 do v[i] = simd.from_array(cols[i])
	if simd_filter(&v, t2, it, hv, mode) {
		for i in 1 ..< 7 do cols[i] = simd.to_array(v[i])
		for r in 0 ..< 16 {
			row := p[r * s - 4:]
			for i in 1 ..< 7 do row[i] = u8(cols[i][r])
		}
	}
}

@(private)
vedge_uv :: proc "contextless" (u, w: [^]u8, s: int, t2, it, hv: i16, mode: int) #no_bounds_check {
	cols: [8][16]i16
	for r in 0 ..< 8 {
		ru := u[r * s - 4:]
		rw := w[r * s - 4:]
		for i in 0 ..< 8 {
			cols[i][r] = i16(ru[i])
			cols[i][8 + r] = i16(rw[i])
		}
	}
	v: [8]V16
	for i in 0 ..< 8 do v[i] = simd.from_array(cols[i])
	if simd_filter(&v, t2, it, hv, mode) {
		for i in 1 ..< 7 do cols[i] = simd.to_array(v[i])
		for r in 0 ..< 8 {
			ru := u[r * s - 4:]
			rw := w[r * s - 4:]
			for i in 1 ..< 7 {
				ru[i] = u8(cols[i][r])
				rw[i] = u8(cols[i][8 + r])
			}
		}
	}
}

@(private)
vp8_filter_frame_simd :: proc(d: ^VP8_Dec) #no_bounds_check {
	ys, uvs := d.ystride, d.uvstride
	for mb_y in 0 ..< d.mb_h {
		for mb_x in 0 ..< d.mb_w {
			fi := d.finfo[mb_y * d.mb_w + mb_x]
			limit := i16(fi.limit)
			if limit == 0 do continue
			yd := raw_data(d.y)[mb_y * 16 * ys + mb_x * 16:]
			il := i16(fi.ilevel)
			ht := i16(fi.hev)
			te := 2 * (limit + 4) + 1 // macroblock edge threshold
			ti := 2 * limit + 1 // inner edge threshold
			if d.filter_type == 1 {
				// simple filter: luma only; edges touch only p0/q0 so the
				// 4-pixel guard band never reaches outside the plane
				if mb_x > 0 do simple_filter(yd, 1, ys, i32(limit) + 4)
				if fi.inner do for k in 1 ..= 3 do simple_filter(yd[4 * k:], 1, ys, i32(limit))
				if mb_y > 0 do hedge_y(yd, ys, te, 0, 0, FMODE_SIMPLE)
				if fi.inner do for k in 1 ..= 3 do hedge_y(yd[4 * k * ys:], ys, ti, 0, 0, FMODE_SIMPLE)
				continue
			}
			ud := raw_data(d.u)[mb_y * 8 * uvs + mb_x * 8:]
			vd := raw_data(d.v)[mb_y * 8 * uvs + mb_x * 8:]
			if mb_x > 0 {
				vedge_y(yd, ys, te, il, ht, FMODE_MB)
				vedge_uv(ud, vd, uvs, te, il, ht, FMODE_MB)
			}
			if fi.inner {
				for k in 1 ..= 3 do vedge_y(yd[4 * k:], ys, ti, il, ht, FMODE_INNER)
				vedge_uv(ud[4:], vd[4:], uvs, ti, il, ht, FMODE_INNER)
			}
			if mb_y > 0 {
				hedge_y(yd, ys, te, il, ht, FMODE_MB)
				hedge_uv(ud, vd, uvs, te, il, ht, FMODE_MB)
			}
			if fi.inner {
				for k in 1 ..= 3 do hedge_y(yd[4 * k * ys:], ys, ti, il, ht, FMODE_INNER)
				hedge_uv(ud[4 * uvs:], vd[4 * uvs:], uvs, ti, il, ht, FMODE_INNER)
			}
		}
	}
}
