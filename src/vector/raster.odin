package vector

import "core:math"
import "core:mem"
import "core:mem/virtual"

// Flattening tolerance in pixels (max distance between curve and polyline).
TOLERANCE :: f32(0.01)

// rasterize renders the primary layer of icon into a width_px x height_px R8
// coverage bitmap (row-major, 0 = empty, 255 = full). The view box is fit with
// xMidYMid meet.
rasterize :: proc(icon: ^Icon, width_px, height_px: int, allocator := context.allocator) -> []u8 {
	return rasterize_layers(icon, width_px, height_px, {.Primary}, allocator)
}

// rasterize_layers is rasterize with an explicit layer set ({.Primary, .Secondary}
// gives the silhouette a browser draws when both colors are the same).
rasterize_layers :: proc(icon: ^Icon, width_px, height_px: int, layers: Layers, allocator := context.allocator) -> []u8 {
	if width_px <= 0 || height_px <= 0 do return nil
	out := make([]u8, width_px * height_px, allocator)
	cov := rasterize_f32(icon, width_px, height_px, layers)
	defer delete(cov)
	for v, i in cov do out[i] = u8(clamp(v, 0, 1) * 255 + 0.5)
	return out
}

// view_transform maps the icon's view box onto a w x h pixel grid (xMidYMid meet).
view_transform :: proc(icon: ^Icon, w, h: int) -> Mat {
	vb := icon.view_box
	if vb[2] <= 0 || vb[3] <= 0 do vb = {0, 0, 24, 24}
	s := min(f32(w) / vb[2], f32(h) / vb[3])
	tx := (f32(w) - vb[2] * s) / 2 - vb[0] * s
	ty := (f32(h) - vb[3] * s) / 2 - vb[1] * s
	return {s, 0, 0, s, tx, ty}
}

// rasterize_f32 returns float coverage (allocated with context.allocator).
rasterize_f32 :: proc(icon: ^Icon, w, h: int, layers: Layers) -> []f32 {
	dst := make([]f32, w * h)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return dst
	defer virtual.arena_destroy(&arena)
	r := Raster {
		w     = w,
		h     = h,
		arena = virtual.arena_allocator(&arena),
	}
	r.stride = w + 2
	r.acc = make([]f32, r.stride * h, r.arena)
	r.pts = make([dynamic][2]f32, r.arena)
	r.polys = make([dynamic]Poly, r.arena)
	view := view_transform(icon, w, h)
	for &op in icon.ops {
		if op.group >= 0 || op.layer not_in layers do continue
		c := op_coverage(&r, icon, &op, view)
		for v, i in c do dst[i] += v * (1 - dst[i])
	}
	return dst
}

@(private)
Poly :: struct {
	first, count: int,
	closed:       bool,
}

@(private)
Raster :: struct {
	w, h, stride: int,
	acc:          []f32, // h rows of stride cells
	pts:          [dynamic][2]f32,
	polys:        [dynamic]Poly,
	arena:        mem.Allocator,
}

// op_coverage renders one op (with its alpha, mask and clip) into a new buffer.
@(private)
op_coverage :: proc(r: ^Raster, icon: ^Icon, op: ^Op, g: Mat) -> []f32 {
	flatten(r, icon, op, g)
	rule := op.rule
	if op.kind == .Stroke {
		gc := mat_mul(g, op.ctm)
		scale := math.sqrt(abs(gc[0] * gc[3] - gc[1] * gc[2]))
		hw := op.stroke_width * scale / 2
		polys := r.polys[:]
		for pl in polys do stroke_poly(r, r.pts[pl.first:pl.first + pl.count], pl.closed, hw, op.cap, op.join, op.miter_limit)
		rule = .Nonzero
	} else {
		for pl in r.polys {
			pts := r.pts[pl.first:pl.first + pl.count]
			for i in 0 ..< len(pts) do acc_line(r, pts[i], pts[(i + 1) % len(pts)])
		}
	}
	cov := make([]f32, r.w * r.h, r.arena)
	integrate(r, cov, rule)
	if op.alpha != 1 do for &v in cov do v *= op.alpha
	if op.mask >= 0 do multiply_group(r, icon, cov, op.mask, mat_mul(g, op.ctm), op.bbox)
	if op.clip >= 0 do multiply_group(r, icon, cov, op.clip, mat_mul(g, op.ctm), op.bbox)
	return cov
}

// multiply_group renders a mask (luminance) or clip (union coverage) and multiplies it into cov.
@(private)
multiply_group :: proc(r: ^Raster, icon: ^Icon, cov: []f32, gi: i32, t: Mat, bbox: [4]f32) {
	grp := icon.groups[gi]
	bw := bbox[2] - bbox[0]
	bh := bbox[3] - bbox[1]
	content := t
	if grp.content_bbox_units do content = mat_mul(t, {bw, 0, 0, bh, bbox[0], bbox[1]})
	buf := make([]f32, r.w * r.h, r.arena)
	for &op in icon.ops {
		if op.group != gi do continue
		c := op_coverage(r, icon, &op, content)
		if grp.kind == .Mask {
			for v, i in c do buf[i] = buf[i] * (1 - v) + op.luminance * v
		} else {
			for v, i in c do buf[i] += v * (1 - buf[i])
		}
	}
	if grp.kind == .Mask {
		reg := grp.region
		if grp.region_bbox_units do reg = {bbox[0] + reg[0] * bw, bbox[1] + reg[1] * bh, reg[2] * bw, reg[3] * bh}
		corners := [4][2]f32{{reg[0], reg[1]}, {reg[0] + reg[2], reg[1]}, {reg[0] + reg[2], reg[1] + reg[3]}, {reg[0], reg[1] + reg[3]}}
		for &c in corners do c = mat_apply(t, c)
		for i in 0 ..< 4 do acc_line(r, corners[i], corners[(i + 1) % 4])
		rc := make([]f32, r.w * r.h, r.arena)
		integrate(r, rc, .Nonzero)
		for &v, i in buf do v *= rc[i]
	}
	for &v, i in cov do v *= buf[i]
}

// flatten converts the op's path (transformed by g) into polylines in r.pts / r.polys.
@(private)
flatten :: proc(r: ^Raster, icon: ^Icon, op: ^Op, g: Mat) {
	clear(&r.pts)
	clear(&r.polys)
	pi := int(op.first_point)
	start := -1
	cur: [2]f32
	finish :: proc(r: ^Raster, start: int, closed: bool) {
		if start < 0 do return
		n := len(r.pts) - start
		if n > 0 do append(&r.polys, Poly{start, n, closed})
	}
	for vi in op.first_verb ..< op.first_verb + op.verb_count {
		switch icon.verbs[vi] {
		case .Move:
			finish(r, start, false)
			cur = mat_apply(g, icon.points[pi])
			pi += 1
			start = len(r.pts)
			append(&r.pts, cur)
		case .Line:
			cur = mat_apply(g, icon.points[pi])
			pi += 1
			append(&r.pts, cur)
		case .Quad:
			c := mat_apply(g, icon.points[pi])
			p := mat_apply(g, icon.points[pi + 1])
			pi += 2
			dd := cur - 2 * c + p
			n := int(math.ceil(math.sqrt(math.sqrt(dd.x * dd.x + dd.y * dd.y) / (4 * TOLERANCE))))
			n = clamp(n, 1, 256)
			for i in 1 ..= n {
				t := f32(i) / f32(n)
				u := 1 - t
				append(&r.pts, u * u * cur + 2 * u * t * c + t * t * p)
			}
			cur = p
		case .Cubic:
			c1 := mat_apply(g, icon.points[pi])
			c2 := mat_apply(g, icon.points[pi + 1])
			p := mat_apply(g, icon.points[pi + 2])
			pi += 3
			d1 := cur - 2 * c1 + c2
			d2 := c1 - 2 * c2 + p
			dd := math.sqrt(max(d1.x * d1.x + d1.y * d1.y, d2.x * d2.x + d2.y * d2.y))
			n := int(math.ceil(math.sqrt(0.75 * dd / TOLERANCE)))
			n = clamp(n, 1, 256)
			for i in 1 ..= n {
				t := f32(i) / f32(n)
				u := 1 - t
				append(&r.pts, u * u * u * cur + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * p)
			}
			cur = p
		case .Close:
			finish(r, start, true)
			// The builder always emits a Move after Close.
			start = -1
		}
	}
	finish(r, start, false)
}

// ---- stroking ----

@(private)
emit_circle :: proc(r: ^Raster, c: [2]f32, radius: f32) {
	if radius <= 0 do return
	n := 8
	if radius > TOLERANCE {
		n = max(8, int(math.ceil(math.PI / math.acos(1 - TOLERANCE / radius))))
	}
	n = min(n, 512)
	// Polygon with vertices slightly outside so its area matches the circle's.
	rr := radius * math.sqrt(2 * math.PI / (f32(n) * math.sin(2 * math.PI / f32(n))))
	prev := c + {rr, 0}
	for i in 1 ..= n {
		a := 2 * math.PI * f32(i) / f32(n)
		p := c + rr * [2]f32{math.cos(a), math.sin(a)}
		acc_line(r, prev, p)
		prev = p
	}
}

// emit_loop accumulates a closed polygon as-is (orientation matters).
@(private)
emit_loop :: proc(r: ^Raster, pts: [][2]f32) {
	for i in 0 ..< len(pts) do acc_line(r, pts[i], pts[(i + 1) % len(pts)])
}

// arc_points appends points on a circle from angle a0 sweeping `sweep`, endpoints excluded.
@(private)
arc_points :: proc(out: ^[dynamic][2]f32, c: [2]f32, radius, a0, sweep: f32) {
	n := 1
	if radius > TOLERANCE {
		step := 2 * math.acos(1 - TOLERANCE / radius)
		n = max(1, int(math.ceil(abs(sweep) / step)))
	}
	n = min(n, 256)
	for i in 1 ..< n {
		a := a0 + sweep * f32(i) / f32(n)
		append(out, c + radius * [2]f32{math.cos(a), math.sin(a)})
	}
}

@(private)
angle_of :: #force_inline proc(v: [2]f32) -> f32 {
	return math.atan2(v.y, v.x)
}

// offset_side appends the left offset (normal (-dy, dx)) of a polyline walked
// forward, with joins. Outer joins get join geometry; inner joins pivot through
// the vertex (the overlap stays inside the stroke, so nonzero fill is exact).
@(private)
offset_side :: proc(out: ^[dynamic][2]f32, pts: [][2]f32, closed: bool, hw: f32, join: Line_Join, miter_limit: f32) {
	n := len(pts)
	nseg := closed ? n : n - 1
	for i in 0 ..< nseg {
		a := pts[i]
		b := pts[(i + 1) % n]
		d := seg_dir(a, b)
		nc := [2]f32{-d.y, d.x} * hw
		if i == 0 && !closed {
			append(out, a + nc)
		} else {
			dp := seg_dir(pts[(i - 1 + n) % n], a)
			np := [2]f32{-dp.y, dp.x} * hw
			cross := dp.x * d.y - dp.y * d.x
			dot := dp.x * d.x + dp.y * d.y
			if abs(cross) < 1e-6 && dot > 0 {
				append(out, a + nc)
			} else if cross > 0 {
				// Turning left: this (left) side is the inner side. Use the offset
				// lines' intersection when it lies on both segments (no overlap
				// sliver at the edge); otherwise pivot through the vertex.
				un := np / hw
				uc := nc / hw
				ndot := un.x * uc.x + un.y * uc.y
				pv := pts[(i - 1 + n) % n]
				lp := math.sqrt((a - pv).x * (a - pv).x + (a - pv).y * (a - pv).y)
				lc := math.sqrt((b - a).x * (b - a).x + (b - a).y * (b - a).y)
				if 1 + ndot > 1e-3 && hw * abs(cross) / (1 + ndot) <= min(lp, lc) {
					append(out, a + (un + uc) / (1 + ndot) * hw)
				} else {
					append(out, a + np, a, a + nc)
				}
			} else {
				append(out, a + np)
				switch join {
				case .Round:
					arc_points(out, a, hw, angle_of(np), math.atan2(np.x * nc.y - np.y * nc.x, np.x * nc.x + np.y * nc.y))
				case .Miter:
					un := np / hw
					uc := nc / hw
					ndot := un.x * uc.x + un.y * uc.y
					if 1 + ndot > 1e-6 {
						m := (un + uc) / (1 + ndot)
						if math.sqrt(m.x * m.x + m.y * m.y) <= miter_limit do append(out, a + m * hw)
					}
				case .Bevel:
				}
				append(out, a + nc)
			}
		}
		append(out, b + nc)
	}
}

@(private)
seg_dir :: proc(a, b: [2]f32) -> [2]f32 {
	d := b - a
	return d / math.sqrt(d.x * d.x + d.y * d.y)
}

// stroke_poly fills the stroke outline of one polyline (pixel space, half width hw).
@(private)
stroke_poly :: proc(r: ^Raster, src: [][2]f32, closed_in: bool, hw: f32, cap: Line_Cap, join: Line_Join, miter_limit: f32) {
	if hw <= 0 || len(src) == 0 do return
	// Drop repeated points.
	pts := make([dynamic][2]f32, 0, len(src), r.arena)
	for p in src {
		if len(pts) > 0 {
			d := p - pts[len(pts) - 1]
			if d.x * d.x + d.y * d.y < 1e-12 do continue
		}
		append(&pts, p)
	}
	closed := closed_in
	if closed && len(pts) > 1 {
		d := pts[0] - pts[len(pts) - 1]
		if d.x * d.x + d.y * d.y < 1e-12 do pop(&pts)
	}
	n := len(pts)
	if n == 1 {
		p := pts[0]
		switch cap {
		case .Round:
			emit_circle(r, p, hw)
		case .Square:
			q := [4][2]f32{p + {-hw, -hw}, p + {hw, -hw}, p + {hw, hw}, p + {-hw, hw}}
			emit_loop(r, q[:])
		case .Butt:
		}
		return
	}
	if n == 2 do closed = false
	rev := make([][2]f32, n, r.arena)
	for p, i in pts do rev[n - 1 - i] = p
	out := make([dynamic][2]f32, r.arena)
	if closed {
		offset_side(&out, pts[:], true, hw, join, miter_limit)
		emit_loop(r, out[:])
		clear(&out)
		offset_side(&out, rev, true, hw, join, miter_limit)
		emit_loop(r, out[:])
		return
	}
	if cap == .Square {
		ds := seg_dir(pts[0], pts[1])
		de := seg_dir(pts[n - 2], pts[n - 1])
		pts[0] -= ds * hw
		pts[n - 1] += de * hw
		rev[n - 1] = pts[0]
		rev[0] = pts[n - 1]
	}
	offset_side(&out, pts[:], false, hw, join, miter_limit)
	if cap == .Round {
		de := seg_dir(pts[n - 2], pts[n - 1])
		arc_points(&out, pts[n - 1], hw, angle_of({-de.y, de.x}), -math.PI)
	}
	offset_side(&out, rev, false, hw, join, miter_limit)
	if cap == .Round {
		ds := seg_dir(pts[0], pts[1])
		arc_points(&out, pts[0], hw, angle_of({ds.y, -ds.x}), -math.PI)
	}
	emit_loop(r, out[:])
}

// ---- coverage accumulation ----

// acc_line adds the signed area/cover of a line (pixel coords) to r.acc.
// Parts left of x=0 are folded onto x=0; parts right of x=w are dropped.
@(private)
acc_line :: proc(r: ^Raster, p0, p1: [2]f32) {
	a := p0
	b := p1
	if a.y == b.y do return
	h := f32(r.h)
	w := f32(r.w)
	if (a.y <= 0 && b.y <= 0) || (a.y >= h && b.y >= h) do return
	if a.x >= w && b.x >= w do return
	// Clip y to [0, h].
	clip_y :: proc(a, b: [2]f32, y: f32) -> [2]f32 {
		t := (y - a.y) / (b.y - a.y)
		return {a.x + (b.x - a.x) * t, y}
	}
	if a.y < 0 do a = clip_y(a, b, 0)
	else if a.y > h do a = clip_y(a, b, h)
	if b.y < 0 do b = clip_y(a, b, 0)
	else if b.y > h do b = clip_y(a, b, h)
	// Split at x = 0 and x = w.
	ts: [4]f32
	nt := 0
	ts[nt] = 0
	nt += 1
	for xc in ([2]f32{0, w}) {
		if (a.x < xc) != (b.x < xc) && a.x != b.x {
			t := (xc - a.x) / (b.x - a.x)
			if t > 0 && t < 1 {
				ts[nt] = t
				nt += 1
			}
		}
	}
	ts[nt] = 1
	nt += 1
	if nt == 4 && ts[1] > ts[2] do ts[1], ts[2] = ts[2], ts[1]
	for k in 0 ..< nt - 1 {
		q0 := a + (b - a) * ts[k]
		q1 := a + (b - a) * ts[k + 1]
		mid := (q0.x + q1.x) / 2
		if mid >= w do continue
		if mid <= 0 {
			q0.x = 0
			q1.x = 0
		}
		q0.x = clamp(q0.x, 0, w)
		q1.x = clamp(q1.x, 0, w)
		acc_line_inside(r, q0, q1)
	}
}

// acc_line_inside: font-rs style exact-area accumulation; 0 <= x <= w, 0 <= y <= h.
@(private)
acc_line_inside :: proc(r: ^Raster, p0, p1: [2]f32) {
	if p0.y == p1.y do return
	dir: f32 = 1
	a := p0
	b := p1
	if a.y > b.y {
		dir = -1
		a, b = b, a
	}
	dxdy := (b.x - a.x) / (b.y - a.y)
	x := a.x
	y0 := int(a.y)
	y1 := min(r.h, int(math.ceil(b.y)))
	acc := r.acc
	for y in y0 ..< y1 {
		ls := y * r.stride
		dy := min(f32(y + 1), b.y) - max(f32(y), a.y)
		xnext := x + dxdy * dy
		d := dy * dir
		x0, x1 := x, xnext
		if x0 > x1 do x0, x1 = x1, x0
		x0f := math.floor(x0)
		x0i := int(x0f)
		x1c := math.ceil(x1)
		x1i := int(x1c)
		if x1i <= x0i + 1 {
			xmf := 0.5 * (x + xnext) - x0f
			acc[ls + x0i] += d - d * xmf
			acc[ls + x0i + 1] += d * xmf
		} else {
			s := 1 / (x1 - x0)
			x0r := x0 - x0f
			a0 := 0.5 * s * (1 - x0r) * (1 - x0r)
			x1r := x1 - x1c + 1
			am := 0.5 * s * x1r * x1r
			acc[ls + x0i] += d * a0
			if x1i == x0i + 2 {
				acc[ls + x0i + 1] += d * (1 - a0 - am)
			} else {
				a1 := s * (1.5 - x0r)
				acc[ls + x0i + 1] += d * (a1 - a0)
				for xi in x0i + 2 ..< x1i - 1 do acc[ls + xi] += d * s
				a2 := a1 + f32(x1i - x0i - 3) * s
				acc[ls + x1i - 1] += d * (1 - a2 - am)
			}
			acc[ls + x1i] += d * am
		}
		x = xnext
	}
}

// integrate turns accumulated cells into coverage and clears the accumulator.
@(private)
integrate :: proc(r: ^Raster, cov: []f32, rule: Fill_Rule) {
	for y in 0 ..< r.h {
		row := r.acc[y * r.stride:(y + 1) * r.stride]
		out := cov[y * r.w:(y + 1) * r.w]
		sum: f32 = 0
		for x in 0 ..< r.w {
			sum += row[x]
			v := abs(sum)
			if rule == .Nonzero {
				out[x] = min(v, 1)
			} else {
				v = v - 2 * math.floor(v / 2)
				out[x] = v > 1 ? 2 - v : v
			}
		}
		for &c in row do c = 0
	}
}
