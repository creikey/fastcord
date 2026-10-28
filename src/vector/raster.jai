// Flattening tolerance in pixels (max distance between curve and polyline).
TOLERANCE :: cast(float32) 0.01;

// rasterize renders the given layers (by default the primary one; Primary | Secondary gives the
// silhouette a browser draws when both colors are the same) of icon into a width_px x height_px R8
// coverage bitmap (row-major, 0 = empty, 255 = full). The view box is fit with xMidYMid meet.
rasterize :: (icon: *Icon, width_px: int, height_px: int, allocator := context.allocator, layers := Layer.Primary) -> []u8 {
	if width_px <= 0 || height_px <= 0 return .[];
	out := NewArray(width_px * height_px, u8,, allocator);
	cov := rasterize_f32(icon, width_px, height_px, layers);
	defer array_free(cov);
	for cov  out[it_index] = cast(u8) (clamp(it, 0, 1) * 255 + 0.5);
	return out;
}

// view_transform maps the icon's view box onto a w x h pixel grid (xMidYMid meet).
view_transform :: (icon: *Icon, w: int, h: int) -> Mat {
	vb := icon.view_box;
	if vb[2] <= 0 || vb[3] <= 0  vb = .{0, 0, 24, 24};
	s := min(cast(float32) w / vb[2], cast(float32) h / vb[3]);
	tx := (cast(float32) w - vb[2] * s) / 2 - vb[0] * s;
	ty := (cast(float32) h - vb[3] * s) / 2 - vb[1] * s;
	return .[s, 0, 0, s, tx, ty];
}

// rasterize_rgba renders all layers in color: fixed paints and gradients as
// authored, currentColor as `current_color`. Returns STRAIGHT-alpha RGBA8
// (row-major, w*h*4), composited src-over in sRGB like Chrome. Group opacity is
// applied per element (no offscreen group compositing).
rasterize_rgba :: (icon: *Icon, w: int, h: int, current_color := u8.[0, 0, 0, 255], allocator := context.allocator) -> []u8 {
	if w <= 0 || h <= 0 return .[];
	out := NewArray(w * h * 4, u8,, allocator);
	canvas := NewArray(w * h * 4, float32);
	defer array_free(canvas);
	rasterize_premul(icon, w, h, canvas, current_color);
	premul_to_rgba8(canvas, out);
	return out;
}

// rasterize_premul composites the icon (src-over) onto a premultiplied RGBA f32
// canvas of w*h*4 floats (0..1), using the view-box fit of view_transform.
rasterize_premul :: (icon: *Icon, w: int, h: int, canvas: []float32, current_color := u8.[0, 0, 0, 255]) {
	rz: Rasterizer;
	rasterizer_init(*rz, w, h);
	defer rasterizer_destroy(*rz);
	view := view_transform(icon, w, h);
	full := Box.{0, 0, w, h};
	cc := Vector4.{cast(float32) current_color[0] / 255, cast(float32) current_color[1] / 255, cast(float32) current_color[2] / 255, cast(float32) current_color[3] / 255};
	for * op: icon.ops {
		if op.group >= 0 continue;
		cov := op_coverage(*rz, icon, op, view);
		if op.gradient >= 0 {
			if op.grad_fold <= 0 continue;
			inv := 1 / op.grad_fold;
			for * cov  it.* *= inv;
			g := *icon.gradients[op.gradient];
			m := mat_mul(view, op.ctm);
			if g.bbox_units {
				b := op.bbox;
				m = mat_mul(m, .[b[2] - b[0], 0, 0, b[3] - b[1], b[0], b[1]]);
			}
			gradient_fill_premul(g, mat_mul(m, g.transform), cov, canvas, w, full);
		} else if op.current_color {
			solid_fill_premul(cc, cov, canvas, w, full);
		} else {
			c := op.color;
			solid_fill_premul(.{cast(float32) c[0] / 255, cast(float32) c[1] / 255, cast(float32) c[2] / 255, 1}, cov, canvas, w, full);
		}
		rasterizer_reset(*rz);
	}
}

// ---- public path API (used by lottie) ----

// Path is a standalone path: verbs and their points (Move/Line 1, Quad 2, Cubic 3, Close 0).
Path :: struct {
	verbs: [..]Verb;
	points: [..]Vector2;
}

path_move :: (p: *Path, a: Vector2) { array_add(*p.verbs, Verb.Move); array_add(*p.points, a); }
path_line :: (p: *Path, a: Vector2) { array_add(*p.verbs, Verb.Line); array_add(*p.points, a); }
path_cubic :: (p: *Path, c1: Vector2, c2: Vector2, a: Vector2) { array_add(*p.verbs, Verb.Cubic); array_add(*p.points, c1, c2, a); }
path_close :: (p: *Path) { array_add(*p.verbs, Verb.Close); }

Stroke :: struct {
	width: float32; // in path units (scaled by the transform's area scale)
	cap: Line_Cap;
	join: Line_Join;
	miter_limit: float32;
}

// Box is a pixel rectangle [x0, x1) x [y0, y1); empty when x1 <= x0 or y1 <= y0.
Box :: struct {
	x0, y0, x1, y1: int;
}

box_union :: (a: Box, b: Box) -> Box {
	if a.x1 <= a.x0 || a.y1 <= a.y0 return b;
	if b.x1 <= b.x0 || b.y1 <= b.y0 return a;
	return .{min(a.x0, b.x0), min(a.y0, b.y0), max(a.x1, b.x1), max(a.y1, b.y1)};
}

// Rasterizer is reusable scratch for path coverage at a fixed size. Buffers it
// returns stay valid until rasterizer_reset / rasterizer_destroy. It must not move after init.
// Work is limited to the cells a path touches (dirty), so small paths on a big canvas stay cheap.
Rasterizer :: struct {
	w, h, stride: int;
	acc: []float32; // h rows of stride cells, zero outside dirty
	dirty: Box; // cells of acc written since the last integrate
	cov: []float32; // fill_coverage / stroke_coverage's result, zero outside cov_box
	cov_box: Box;
	tolerance: float32 = TOLERANCE; // curve flattening, pixels
	edges: *[..]Edge; // set: acc_line records edges here (fill_edges, stroke_edges) instead of accumulating
	edge_min, edge_max: Vector2; // bounds of the recorded edges
	pts: [..]Vector2;
	polys: [..]Poly;
	pool: Flat_Pool; // holds pts, polys and every buffer handed out
}

rasterizer_init :: (rz: *Rasterizer, w: int, h: int) {
	rz.* = .{w = w, h = h, stride = w + 2};
	rz.acc = NewArray(rz.stride * h, float32);
	rz.cov = NewArray(w * h, float32);
	rasterizer_reset(rz);
}

rasterizer_reset :: (rz: *Rasterizer) {
	reset(*rz.pool);
	a := rasterizer_allocator(rz);
	pts: [..]Vector2;
	polys: [..]Poly;
	rz.pts, rz.polys = pts, polys;
	rz.pts.allocator, rz.polys.allocator = a, a;
}

rasterizer_destroy :: (rz: *Rasterizer) {
	fini(*rz.pool);
	array_free(rz.acc);
	array_free(rz.cov);
	rz.* = .{};
}

rasterizer_allocator :: (rz: *Rasterizer) -> Allocator { return .{flat_pool_allocator_proc, *rz.pool}; }

// rasterizer_buffer returns a zeroed w*h*n f32 scratch buffer (valid until reset).
rasterizer_buffer :: (rz: *Rasterizer, n := 1) -> []float32 {
	return NewArray(rz.w * rz.h * n, float32,, rasterizer_allocator(rz));
}

// fill_coverage returns w*h coverage (0..1) of the path under transform m: rz.cov, valid until the
// next fill_coverage / stroke_coverage, zero outside rz.cov_box.
fill_coverage :: (rz: *Rasterizer, verbs: []Verb, points: []Vector2, m: Mat, rule: Fill_Rule) -> []float32 {
	flatten_path(rz, verbs, points, m);
	for rz.polys  emit_loop(rz, poly_points(rz, it));
	return scratch_coverage(rz, rule);
}

// stroke_coverage is fill_coverage for the path stroked under transform m.
stroke_coverage :: (rz: *Rasterizer, verbs: []Verb, points: []Vector2, m: Mat, s: Stroke) -> []float32 {
	stroke_outline(rz, verbs, points, m, s);
	return scratch_coverage(rz, .Nonzero);
}

// Edge is a line of a flattened outline in pixels (x0, y0, x1, y1), for the GPU to accumulate.
Edge :: [4]float32;

// fill_edges appends the outline that fill_coverage would accumulate to out (horizontal and
// off-canvas edges dropped) and returns the bounds of what it appended, or ok = false for none.
fill_edges :: (rz: *Rasterizer, verbs: []Verb, points: []Vector2, m: Mat, out: *[..]Edge) -> lo: Vector2, hi: Vector2, ok: bool {
	begin_edges(rz, out);
	flatten_path(rz, verbs, points, m);
	for rz.polys  emit_loop(rz, poly_points(rz, it));
	lo, hi, ok := end_edges(rz);
	return lo, hi, ok;
}

stroke_edges :: (rz: *Rasterizer, verbs: []Verb, points: []Vector2, m: Mat, s: Stroke, out: *[..]Edge) -> lo: Vector2, hi: Vector2, ok: bool {
	begin_edges(rz, out);
	stroke_outline(rz, verbs, points, m, s);
	lo, hi, ok := end_edges(rz);
	return lo, hi, ok;
}

#scope_module

stroke_outline :: (rz: *Rasterizer, verbs: []Verb, points: []Vector2, m: Mat, s: Stroke) {
	flatten_path(rz, verbs, points, m);
	hw := s.width * sqrt(abs(m[0] * m[3] - m[1] * m[2])) / 2;
	for rz.polys  stroke_poly(rz, poly_points(rz, it), it.closed, hw, s.cap, s.join, max(s.miter_limit, 1));
}

begin_edges :: (rz: *Rasterizer, out: *[..]Edge) {
	rz.edges = out;
	rz.edge_min, rz.edge_max = .{FLOAT32_MAX, FLOAT32_MAX}, .{-FLOAT32_MAX, -FLOAT32_MAX};
}

end_edges :: (rz: *Rasterizer) -> Vector2, Vector2, bool {
	rz.edges = null;
	return rz.edge_min, rz.edge_max, rz.edge_min.x <= rz.edge_max.x;
}

// Math's floor and ceil are software (cephes) and, in split-module dev builds, calls. These are exact
// for finite values in int range, which every coordinate here is once clipped to the canvas.
floor_fast :: inline (x: float32) -> float32 { f := cast(float32) cast(int) x; return ifx f > x then f - 1 else f; }
ceil_fast :: inline (x: float32) -> float32 { f := cast(float32) cast(int) x; return ifx f < x then f + 1 else f; }

scratch_coverage :: (rz: *Rasterizer, rule: Fill_Rule) -> []float32 {
	b := rz.cov_box;
	for y: b.y0..b.y1-1  memset(rz.cov.data + y * rz.w + b.x0, 0, (b.x1 - b.x0) * size_of(float32));
	rz.cov_box = integrate(rz, rz.cov, rule);
	return rz.cov;
}

// rasterize_f32 returns float coverage (allocated with context.allocator).
rasterize_f32 :: (icon: *Icon, w: int, h: int, layers: Layer) -> []float32 {
	dst := NewArray(w * h, float32);
	rz: Rasterizer;
	rasterizer_init(*rz, w, h);
	defer rasterizer_destroy(*rz);
	view := view_transform(icon, w, h);
	for * op: icon.ops {
		if op.group >= 0 || !(layers & op.layer) continue;
		c := op_coverage(*rz, icon, op, view);
		for c  dst[it_index] += it * (1 - dst[it_index]);
	}
	return dst;
}

Poly :: struct {
	first, count: int;
	closed: bool;
}

poly_points :: (rz: *Rasterizer, pl: Poly) -> []Vector2 { return array_view(rz.pts, pl.first, pl.count); }

// op_coverage renders one op (with its alpha, mask and clip) into a new buffer.
op_coverage :: (rz: *Rasterizer, icon: *Icon, op: *Op, g: Mat) -> []float32 {
	flatten_path(rz, array_view(icon.verbs, op.first_verb, op.verb_count), array_view(icon.points, op.first_point), g);
	rule := op.rule;
	if op.kind == .Stroke {
		gc := mat_mul(g, op.ctm);
		hw := op.stroke_width * sqrt(abs(gc[0] * gc[3] - gc[1] * gc[2])) / 2;
		for rz.polys  stroke_poly(rz, poly_points(rz, it), it.closed, hw, op.cap, op.join, op.miter_limit);
		rule = .Nonzero;
	} else {
		for rz.polys  emit_loop(rz, poly_points(rz, it));
	}
	cov := rasterizer_buffer(rz);
	integrate(rz, cov, rule);
	if op.alpha != 1  for * cov  it.* *= op.alpha;
	if op.mask >= 0  multiply_group(rz, icon, cov, op.mask, mat_mul(g, op.ctm), op.bbox);
	if op.clip >= 0  multiply_group(rz, icon, cov, op.clip, mat_mul(g, op.ctm), op.bbox);
	// ancestor group clip/mask (bbox units use the element's bbox: an approximation)
	if op.anc_mask >= 0  multiply_group(rz, icon, cov, op.anc_mask, mat_mul(g, op.anc_ctm), op.bbox);
	if op.anc_clip >= 0  multiply_group(rz, icon, cov, op.anc_clip, mat_mul(g, op.anc_ctm), op.bbox);
	return cov;
}

// multiply_group renders a mask (luminance) or clip (union coverage) and multiplies it into cov.
multiply_group :: (rz: *Rasterizer, icon: *Icon, cov: []float32, gi: s32, t: Mat, bbox: Vector4) {
	grp := icon.groups[gi];
	bw := bbox[2] - bbox[0];
	bh := bbox[3] - bbox[1];
	content := t;
	if grp.content_bbox_units  content = mat_mul(t, .[bw, 0, 0, bh, bbox[0], bbox[1]]);
	buf := rasterizer_buffer(rz);
	for * op: icon.ops {
		if op.group != gi continue;
		c := op_coverage(rz, icon, op, content);
		if grp.kind == .Mask  for c  buf[it_index] = buf[it_index] * (1 - it) + op.luminance * it;
		else                  for c  buf[it_index] += it * (1 - buf[it_index]);
	}
	if grp.kind == .Mask {
		reg := grp.region;
		if grp.region_bbox_units  reg = .{bbox[0] + reg[0] * bw, bbox[1] + reg[1] * bh, reg[2] * bw, reg[3] * bh};
		corners := Vector2.[.{reg[0], reg[1]}, .{reg[0] + reg[2], reg[1]}, .{reg[0] + reg[2], reg[1] + reg[3]}, .{reg[0], reg[1] + reg[3]}];
		for * corners  it.* = mat_apply(t, it.*);
		emit_loop(rz, corners);
		rc := rasterizer_buffer(rz);
		integrate(rz, rc, .Nonzero);
		for * buf  it.* *= rc[it_index];
	}
	for * cov  it.* *= buf[it_index];
}

// flatten_path converts a path (transformed by g) into polylines in rz.pts / rz.polys.
flatten_path :: (rz: *Rasterizer, verbs: []Verb, points: []Vector2, g: Mat) {
	array_reset_keeping_memory(*rz.pts);
	array_reset_keeping_memory(*rz.polys);
	pi := 0;
	start := -1;
	cur: Vector2;
	finish :: (rz: *Rasterizer, start: int, closed: bool) {
		if start < 0 return;
		n := rz.pts.count - start;
		if n > 0  array_add(*rz.polys, Poly.{start, n, closed});
	}
	begin :: (rz: *Rasterizer, start: *int, cur: Vector2) {
		if start.* >= 0 return;
		start.* = rz.pts.count;
		array_add(*rz.pts, cur);
	}
	for v: verbs {
		if v == {
		case .Move;
			finish(rz, start, false);
			cur = mat_apply(g, points[pi]);
			pi += 1;
			start = rz.pts.count;
			array_add(*rz.pts, cur);
		case .Line;
			begin(rz, *start, cur);
			cur = mat_apply(g, points[pi]);
			pi += 1;
			array_add(*rz.pts, cur);
		case .Quad;
			begin(rz, *start, cur);
			c := mat_apply(g, points[pi]);
			p := mat_apply(g, points[pi + 1]);
			pi += 2;
			dd := cur - 2 * c + p;
			n := clamp(cast(int) ceil(sqrt(sqrt(dd.x * dd.x + dd.y * dd.y) / (4 * rz.tolerance))), 1, 256);
			for i: 1..n {
				t := cast(float32) i / cast(float32) n;
				u := 1 - t;
				array_add(*rz.pts, u * u * cur + 2 * u * t * c + t * t * p);
			}
			cur = p;
		case .Cubic;
			begin(rz, *start, cur);
			c1 := mat_apply(g, points[pi]);
			c2 := mat_apply(g, points[pi + 1]);
			p := mat_apply(g, points[pi + 2]);
			pi += 3;
			d1 := cur - 2 * c1 + c2;
			d2 := c1 - 2 * c2 + p;
			dd := sqrt(max(d1.x * d1.x + d1.y * d1.y, d2.x * d2.x + d2.y * d2.y));
			n := clamp(cast(int) ceil(sqrt(0.75 * dd / rz.tolerance)), 1, 256);
			for i: 1..n {
				t := cast(float32) i / cast(float32) n;
				u := 1 - t;
				array_add(*rz.pts, u * u * u * cur + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * p);
			}
			cur = p;
		case .Close;
			if start >= 0  cur = rz.pts[start];
			finish(rz, start, true);
			start = -1;
		}
	}
	finish(rz, start, false);
}

// ---- stroking ----

emit_circle :: (r: *Rasterizer, c: Vector2, radius: float32) {
	if radius <= 0 { return; }
	n := 8;
	if radius > r.tolerance {
		n = max(8, cast(int)(ceil(PI / acos(1 - r.tolerance / radius))));
	}
	n = min(n, 512);
	// Polygon with vertices slightly outside so its area matches the circle's.
	rr := radius * sqrt(2 * PI / (cast(float32)(n) * sin(2 * PI / cast(float32)(n))));
	prev := c + .{rr, 0};
	for i: 1..n {
		a := 2 * PI * cast(float32)(i) / cast(float32)(n);
		p := c + rr * Vector2.{cos(a), sin(a)};
		acc_line(r, prev, p);
		prev = p;
	}
}

// emit_loop accumulates a closed polygon as-is (orientation matters).
emit_loop :: (r: *Rasterizer, pts: []Vector2) {
	for i: 0..pts.count-1 { acc_line(r, pts[i], pts[(i + 1) % pts.count]); }
}

// arc_points appends points on a circle from angle a0 sweeping `sweep`, endpoints excluded.
arc_points :: (out: *[..]Vector2, c: Vector2, radius: float32, a0: float32, sweep: float32, tol: float32) {
	n := 1;
	if radius > tol {
		step := 2 * acos(1 - tol / radius);
		n = max(1, cast(int)(ceil(abs(sweep) / step)));
	}
	n = min(n, 256);
	for i: 1..n-1 {
		a := a0 + sweep * cast(float32)(i) / cast(float32)(n);
		array_add(out, c + radius * Vector2.{cos(a), sin(a)});
	}
}

angle_of :: inline (v: Vector2) -> float32 {
	return atan2(v.y, v.x);
}

// offset_side appends the left offset (normal (-dy, dx)) of a polyline walked
// forward, with joins. Outer joins get join geometry; inner joins pivot through
// the vertex (the overlap stays inside the stroke, so nonzero fill is exact).
offset_side :: (out: *[..]Vector2, pts: []Vector2, closed: bool, hw: float32, join: Line_Join, miter_limit: float32, tol: float32) {
	n := pts.count;
	nseg := ifx closed then n else n - 1;
	for i: 0..nseg-1 {
		a := pts[i];
		b := pts[(i + 1) % n];
		d := seg_dir(a, b);
		nc := Vector2.{-d.y, d.x} * hw;
		if i == 0 && !closed {
			array_add(out, a + nc);
		} else {
			dp := seg_dir(pts[(i - 1 + n) % n], a);
			np := Vector2.{-dp.y, dp.x} * hw;
			cross := dp.x * d.y - dp.y * d.x;
			dot := dp.x * d.x + dp.y * d.y;
			if abs(cross) < 1.0e-6 && dot > 0 {
				array_add(out, a + nc);
			} else if cross > 0 {
				// Turning left: this (left) side is the inner side. Use the offset
				// lines' intersection when it lies on both segments (no overlap
				// sliver at the edge); otherwise pivot through the vertex.
				un := np / hw;
				uc := nc / hw;
				ndot := un.x * uc.x + un.y * uc.y;
				pv := pts[(i - 1 + n) % n];
				lp := sqrt((a - pv).x * (a - pv).x + (a - pv).y * (a - pv).y);
				lc := sqrt((b - a).x * (b - a).x + (b - a).y * (b - a).y);
				if 1 + ndot > 1.0e-3 && hw * abs(cross) / (1 + ndot) <= min(lp, lc) {
					array_add(out, a + (un + uc) / (1 + ndot) * hw);
				} else {
					array_add(out, a + np, a, a + nc);
				}
			} else {
				array_add(out, a + np);
				if join == {
				case .Round;
					arc_points(out, a, hw, angle_of(np), atan2(np.x * nc.y - np.y * nc.x, np.x * nc.x + np.y * nc.y), tol);
				case .Miter;
					un := np / hw;
					uc := nc / hw;
					ndot := un.x * uc.x + un.y * uc.y;
					if 1 + ndot > 1.0e-6 {
						m := (un + uc) / (1 + ndot);
						if sqrt(m.x * m.x + m.y * m.y) <= miter_limit { array_add(out, a + m * hw); }
					}
				case .Bevel;
				}
				array_add(out, a + nc);
			}
		}
		array_add(out, b + nc);
	}
}

seg_dir :: (a: Vector2, b: Vector2) -> Vector2 {
	d := b - a;
	return d / sqrt(d.x * d.x + d.y * d.y);
}

// stroke_poly fills the stroke outline of one polyline (pixel space, half width hw).
stroke_poly :: (r: *Rasterizer, src: []Vector2, closed_in: bool, hw: float32, cap: Line_Cap, join: Line_Join, miter_limit: float32) {
	if hw <= 0 || src.count == 0 { return; }
	// Drop repeated points.
	pts: [..]Vector2;
	pts.allocator = rasterizer_allocator(r);
	array_reserve(*pts, src.count);
	for p: src {
		if pts.count > 0 {
			d := p - pts[pts.count - 1];
			if d.x * d.x + d.y * d.y < 1.0e-12 { continue; }
		}
		array_add(*pts, p);
	}
	closed := closed_in;
	if closed && pts.count > 1 {
		d := pts[0] - pts[pts.count - 1];
		if d.x * d.x + d.y * d.y < 1.0e-12 { pts.count -= 1; }
	}
	n := pts.count;
	if n == 1 {
		p := pts[0];
		if cap == {
		case .Round;
			emit_circle(r, p, hw);
		case .Square;
			q := Vector2.[p + .{-hw, -hw}, p + .{hw, -hw}, p + .{hw, hw}, p + .{-hw, hw}];
			emit_loop(r, q);
		case .Butt;
		}
		return;
	}
	if n == 2 { closed = false; }
	rev := NewArray(n, Vector2,, rasterizer_allocator(r));
	for p, i: pts { rev[n - 1 - i] = p; }
	out: [..]Vector2;
	out.allocator = rasterizer_allocator(r);
	if closed {
		offset_side(*out, pts, true, hw, join, miter_limit, r.tolerance);
		emit_loop(r, out);
		array_reset_keeping_memory(*out);
		offset_side(*out, rev, true, hw, join, miter_limit, r.tolerance);
		emit_loop(r, out);
		return;
	}
	if cap == .Square {
		ds := seg_dir(pts[0], pts[1]);
		de := seg_dir(pts[n - 2], pts[n - 1]);
		pts[0] -= ds * hw;
		pts[n - 1] += de * hw;
		rev[n - 1] = pts[0];
		rev[0] = pts[n - 1];
	}
	offset_side(*out, pts, false, hw, join, miter_limit, r.tolerance);
	if cap == .Round {
		de := seg_dir(pts[n - 2], pts[n - 1]);
		arc_points(*out, pts[n - 1], hw, angle_of(.{-de.y, de.x}), -PI, r.tolerance);
	}
	offset_side(*out, rev, false, hw, join, miter_limit, r.tolerance);
	if cap == .Round {
		ds := seg_dir(pts[0], pts[1]);
		arc_points(*out, pts[0], hw, angle_of(.{ds.y, -ds.x}), -PI, r.tolerance);
	}
	emit_loop(r, out);
}

// ---- coverage accumulation ----

// acc_line adds the signed area/cover of a line (pixel coords) to r.acc.
// Parts left of x=0 are folded onto x=0; parts right of x=w are dropped.
acc_line :: (r: *Rasterizer, p0: Vector2, p1: Vector2) {
	a := p0;
	b := p1;
	if a.y == b.y { return; }
	h := cast(float32)(r.h);
	w := cast(float32)(r.w);
	if (a.y <= 0 && b.y <= 0) || (a.y >= h && b.y >= h) { return; }
	if r.edges {
		// right of the canvas the edge adds nothing, but the rows left of it stay covered up to the edge
		if a.x < w || b.x < w  array_add(r.edges, .[a.x, a.y, b.x, b.y]);
		r.edge_min = .{min(r.edge_min.x, a.x, b.x), min(r.edge_min.y, a.y, b.y)};
		r.edge_max = .{max(r.edge_max.x, a.x, b.x), max(r.edge_max.y, a.y, b.y)};
		return;
	}
	if a.x >= w && b.x >= w { return; }
	// Clip y to [0, h].
	clip_y :: (a: Vector2, b: Vector2, y: float32) -> Vector2 {
		t := (y - a.y) / (b.y - a.y);
		return .{a.x + (b.x - a.x) * t, y};
	}
	if a.y < 0 { a = clip_y(a, b, 0); } else if a.y > h { a = clip_y(a, b, h); }
	if b.y < 0 { b = clip_y(a, b, 0); } else if b.y > h { b = clip_y(a, b, h); }
	// Split at x = 0 and x = w.
	ts: Vector4;
	nt := 0;
	ts[nt] = 0;
	nt += 1;
	for xc: (float32.[0, w]) {
		if (a.x < xc) != (b.x < xc) && a.x != b.x {
			t := (xc - a.x) / (b.x - a.x);
			if t > 0 && t < 1 {
				ts[nt] = t;
				nt += 1;
			}
		}
	}
	ts[nt] = 1;
	nt += 1;
	if nt == 4 && ts[1] > ts[2] { ts[1], ts[2] = ts[2], ts[1]; }
	for k: 0..(nt - 1)-1 {
		q0 := a + (b - a) * ts[k];
		q1 := a + (b - a) * ts[k + 1];
		mid := (q0.x + q1.x) / 2;
		if mid >= w { continue; }
		if mid <= 0 {
			q0.x = 0;
			q1.x = 0;
		}
		q0.x = clamp(q0.x, 0, w);
		q1.x = clamp(q1.x, 0, w);
		acc_line_inside(r, q0, q1);
	}
}

// acc_line_inside: font-rs style exact-area accumulation; 0 <= x <= w, 0 <= y <= h.
acc_line_inside :: (r: *Rasterizer, p0: Vector2, p1: Vector2) {
	if p0.y == p1.y { return; }
	dir: float32 = 1;
	a := p0;
	b := p1;
	if a.y > b.y {
		dir = -1;
		a, b = b, a;
	}
	dxdy := (b.x - a.x) / (b.y - a.y);
	x := a.x;
	y0 := cast(int)(a.y);
	y1 := min(r.h, cast(int)(ceil_fast(b.y)));
	acc := r.acc;
	xmin, xmax := r.stride, 0;
	for y: y0..y1-1 {
		ls := y * r.stride;
		yt, yb := cast(float32) y, cast(float32)(y + 1);
		dy := (ifx yb < b.y then yb else b.y) - (ifx yt > a.y then yt else a.y);
		xnext := x + dxdy * dy;
		d := dy * dir;
		x0, x1 := x, xnext;
		if x0 > x1 { x0, x1 = x1, x0; }
		x0f := floor_fast(x0);
		x0i := cast(int)(x0f);
		x1c := ceil_fast(x1);
		x1i := cast(int)(x1c);
		if x0i < xmin  xmin = x0i;
		if x1i <= x0i + 1 {
			if x0i + 2 > xmax  xmax = x0i + 2;
			xmf := 0.5 * (x + xnext) - x0f;
			acc[ls + x0i] += d - d * xmf;
			acc[ls + x0i + 1] += d * xmf;
		} else {
			s := 1 / (x1 - x0);
			x0r := x0 - x0f;
			a0 := 0.5 * s * (1 - x0r) * (1 - x0r);
			x1r := x1 - x1c + 1;
			am := 0.5 * s * x1r * x1r;
			acc[ls + x0i] += d * a0;
			if x1i == x0i + 2 {
				acc[ls + x0i + 1] += d * (1 - a0 - am);
			} else {
				a1 := s * (1.5 - x0r);
				acc[ls + x0i + 1] += d * (a1 - a0);
				for xi: x0i + 2..(x1i - 1)-1 { acc[ls + xi] += d * s; }
				a2 := a1 + cast(float32)(x1i - x0i - 3) * s;
				acc[ls + x1i - 1] += d * (1 - a2 - am);
			}
			acc[ls + x1i] += d * am;
			if x1i + 1 > xmax  xmax = x1i + 1;
		}
		x = xnext;
	}
	// float drift can put x0i at -1: the previous row's padding, which integrate never reads
	if y1 > y0  r.dirty = box_union(r.dirty, .{max(xmin, 0), y0, xmax, y1});
}

// integrate turns accumulated cells into coverage and clears the accumulator. It writes only the
// dirty rows, from the first dirty column to the last, or to the right edge where a row's winding
// stays open (its right side was clipped). It returns that box: cov must already be zero outside it.
integrate :: (r: *Rasterizer, cov: []float32, rule: Fill_Rule) -> Box {
	d := r.dirty;
	r.dirty = .{};
	if d.x1 <= d.x0 || d.y1 <= d.y0 return .{};
	x1 := min(d.x1, r.w);
	b := Box.{d.x0, d.y0, x1, d.y1};
	for y: d.y0..d.y1-1 {
		row := r.acc.data + y * r.stride;
		out := cov.data + y * r.w;
		sum: float32 = 0;
		v: float32;
		for x: d.x0..r.w-1 {
			if x < x1  sum += row[x];
			else if sum == 0 break;
			v = abs(sum);
			if rule == .Nonzero {
				out[x] = ifx v < 1 then v else 1;
			} else {
				v = v - 2 * floor_fast(v / 2);
				out[x] = ifx v > 1 then 2 - v else v;
			}
			if x >= x1  b.x1 = r.w;
		}
		memset(row + d.x0, 0, (d.x1 - d.x0) * size_of(float32));
	}
	return b;
}

