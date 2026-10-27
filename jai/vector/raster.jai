// Flattening tolerance in pixels (max distance between curve and polyline).
TOLERANCE :: cast(float32)(0.01);

// rasterize renders the primary layer of icon into a width_px x height_px R8
// coverage bitmap (row-major, 0 = empty, 255 = full). The view box is fit with
// xMidYMid meet.
rasterize :: (icon: *Icon, width_px: int, height_px: int, allocator := context.allocator) -> []u8 {
	return rasterize_layers(icon, width_px, height_px, .Primary, allocator);
}

// rasterize_layers is rasterize with an explicit layer set ({.Primary, .Secondary}
// gives the silhouette a browser draws when both colors are the same).
rasterize_layers :: (icon: *Icon, width_px: int, height_px: int, layers: Layers, allocator := context.allocator) -> []u8 {
	if width_px <= 0 || height_px <= 0 { return .{}; }
	out := make_slice(u8, width_px * height_px, allocator);
	cov := rasterize_f32(icon, width_px, height_px, layers);
	defer delete(cov);
	for v, i: cov { at(*out, i).* = cast(u8)(clamp(v, 0, 1) * 255 + 0.5); }
	return out;
}

// view_transform maps the icon's view box onto a w x h pixel grid (xMidYMid meet).
view_transform :: (icon: *Icon, w: int, h: int) -> Mat {
	vb := icon.view_box;
	if vb[2] <= 0 || vb[3] <= 0 { vb = .{0, 0, 24, 24}; }
	s := min(cast(float32)(w) / vb[2], cast(float32)(h) / vb[3]);
	tx := (cast(float32)(w) - vb[2] * s) / 2 - vb[0] * s;
	ty := (cast(float32)(h) - vb[3] * s) / 2 - vb[1] * s;
	return .[s, 0, 0, s, tx, ty];
}

// rasterize_rgba renders all layers in color: fixed paints and gradients as
// authored, currentColor as `current_color`. Returns STRAIGHT-alpha RGBA8
// (row-major, w*h*4), composited src-over in sRGB like Chrome. Group opacity is
// applied per element (no offscreen group compositing).
rasterize_rgba :: (icon: *Icon, w: int, h: int, current_color := u8.[0, 0, 0, 255], allocator := context.allocator) -> []u8 {
	if w <= 0 || h <= 0 { return .{}; }
	out := make_slice(u8, w * h * 4, allocator);
	canvas := make_slice(float32, w * h * 4);
	defer delete(canvas);
	rasterize_premul(icon, w, h, canvas, current_color);
	premul_to_rgba8(canvas, out);
	return out;
}

// rasterize_premul composites the icon (src-over) onto a premultiplied RGBA f32
// canvas of w*h*4 floats (0..1), using the view-box fit of view_transform.
rasterize_premul :: (icon: *Icon, w: int, h: int, canvas: []float32, current_color := u8.[0, 0, 0, 255]) {
	arena: virtual.Arena;
	if virtual.arena_init_growing(*arena) != .None { return; }
	defer virtual.arena_destroy(*arena);
	r := Raster.{
		w = w,
		h = h,
		arena = virtual.arena_allocator(*arena)
	};
	r.stride = w + 2;
	r.acc = make_slice(float32, r.stride * h, r.arena);
	r.pts = make_dynamic(Vector2, 0, 0, r.arena);
	r.polys = make_dynamic(Poly, 0, 0, r.arena);
	view := view_transform(icon, w, h);
	cc := Vector4.{cast(float32)(current_color[0]) / 255, cast(float32)(current_color[1]) / 255, cast(float32)(current_color[2]) / 255, cast(float32)(current_color[3]) / 255};
	for * op: icon.ops {
		if op.group >= 0 { continue; }
		cov := op_coverage(*r, icon, op, view);
		if op.gradient >= 0 {
			if op.grad_fold <= 0 { continue; }
			inv := 1 / op.grad_fold;
			for * v: cov { v.* *= inv; }
			g := *icon.gradients[op.gradient];
			m := mat_mul(view, op.ctm);
			if g.bbox_units {
				b := op.bbox;
				m = mat_mul(m, .[b[2] - b[0], 0, 0, b[3] - b[1], b[0], b[1]]);
			}
			gradient_fill_premul(g, mat_mul(m, g.transform), cov, canvas, w, h);
		} else if op.current_color {
			solid_fill_premul(cc, cov, canvas);
		} else {
			c := op.color;
			solid_fill_premul(.{cast(float32)(c[0]) / 255, cast(float32)(c[1]) / 255, cast(float32)(c[2]) / 255, 1}, cov, canvas);
		}
		virtual.arena_free_all(*arena);
		r.acc = make_slice(float32, r.stride * h, r.arena);
		r.pts = make_dynamic(Vector2, 0, 0, r.arena);
		r.polys = make_dynamic(Poly, 0, 0, r.arena);
	}
}

// rasterize_f32 returns float coverage (allocated with context.allocator).
rasterize_f32 :: (icon: *Icon, w: int, h: int, layers: Layers) -> []float32 {
	dst := make_slice(float32, w * h);
	arena: virtual.Arena;
	if virtual.arena_init_growing(*arena) != .None { return dst; }
	defer virtual.arena_destroy(*arena);
	r := Raster.{
		w = w,
		h = h,
		arena = virtual.arena_allocator(*arena)
	};
	r.stride = w + 2;
	r.acc = make_slice(float32, r.stride * h, r.arena);
	r.pts = make_dynamic(Vector2, 0, 0, r.arena);
	r.polys = make_dynamic(Poly, 0, 0, r.arena);
	view := view_transform(icon, w, h);
	for * op: icon.ops {
		if op.group >= 0 || !has(layers, op.layer) { continue; }
		c := op_coverage(*r, icon, op, view);
		for v, i: c { dst[i] += v * (1 - dst[i]); }
	}
	return dst;
}
#scope_module

Poly :: struct {
	first, count: int;
	closed: bool;
}

Raster :: struct {
	w, h, stride: int;
	acc: []float32; // h rows of stride cells
	pts: [..]Vector2;
	polys: [..]Poly;
	arena: Allocator;
}

// op_coverage renders one op (with its alpha, mask and clip) into a new buffer.
op_coverage :: (r: *Raster, icon: *Icon, op: *Op, g: Mat) -> []float32 {
	flatten(r, icon, op, g);
	rule := op.rule;
	if op.kind == .Stroke {
		gc := mat_mul(g, op.ctm);
		scale := math.sqrt(abs(gc[0] * gc[3] - gc[1] * gc[2]));
		hw := op.stroke_width * scale / 2;
		polys := view(r.polys);
		for pl: polys { stroke_poly(r, sub(r.pts, pl.first, pl.first + pl.count), pl.closed, hw, op.cap, op.join, op.miter_limit); }
		rule = .Nonzero;
	} else {
		for pl: r.polys {
			pts := sub(r.pts, pl.first, pl.first + pl.count);
			for i: 0..len(pts)-1 { acc_line(r, pts[i], pts[(i + 1) % len(pts)]); }
		}
	}
	cov := make_slice(float32, r.w * r.h, r.arena);
	integrate(r, cov, rule);
	if op.alpha != 1 { for * v: cov { v.* *= op.alpha; } }
	if op.mask >= 0 { multiply_group(r, icon, cov, op.mask, mat_mul(g, op.ctm), op.bbox); }
	if op.clip >= 0 { multiply_group(r, icon, cov, op.clip, mat_mul(g, op.ctm), op.bbox); }
	// ancestor group clip/mask (bbox units use the element's bbox: an approximation)
	if op.anc_mask >= 0 { multiply_group(r, icon, cov, op.anc_mask, mat_mul(g, op.anc_ctm), op.bbox); }
	if op.anc_clip >= 0 { multiply_group(r, icon, cov, op.anc_clip, mat_mul(g, op.anc_ctm), op.bbox); }
	return cov;
}

// multiply_group renders a mask (luminance) or clip (union coverage) and multiplies it into cov.
multiply_group :: (r: *Raster, icon: *Icon, cov: []float32, gi: s32, t: Mat, bbox: Vector4) {
	grp := get(icon.groups, gi);
	bw := bbox[2] - bbox[0];
	bh := bbox[3] - bbox[1];
	content := t;
	if grp.content_bbox_units { content = mat_mul(t, .[bw, 0, 0, bh, bbox[0], bbox[1]]); }
	buf := make_slice(float32, r.w * r.h, r.arena);
	for * op: icon.ops {
		if op.group != gi { continue; }
		c := op_coverage(r, icon, op, content);
		if grp.kind == .Mask {
			for v, i: c { buf[i] = buf[i] * (1 - v) + op.luminance * v; }
		} else {
			for v, i: c { buf[i] += v * (1 - buf[i]); }
		}
	}
	if grp.kind == .Mask {
		reg := grp.region;
		if grp.region_bbox_units { reg = .{bbox[0] + reg[0] * bw, bbox[1] + reg[1] * bh, reg[2] * bw, reg[3] * bh}; }
		corners := Vector2.[.{reg[0], reg[1]}, .{reg[0] + reg[2], reg[1]}, .{reg[0] + reg[2], reg[1] + reg[3]}, .{reg[0], reg[1] + reg[3]}];
		for * c: corners { c.* = mat_apply(t, c.*); }
		for i: 0..3 { acc_line(r, corners[i], corners[(i + 1) % 4]); }
		rc := make_slice(float32, r.w * r.h, r.arena);
		integrate(r, rc, .Nonzero);
		for * v, i: buf { v.* *= rc[i]; }
	}
	for * v, i: cov { v.* *= buf[i]; }
}

// flatten converts the op's path (transformed by g) into polylines in r.pts / r.polys.
flatten :: (r: *Raster, icon: *Icon, op: *Op, g: Mat) {
	verbs := sub(icon.verbs, op.first_verb, op.first_verb + op.verb_count);
	flatten_path(r, verbs, sub_from(icon.points, op.first_point), g);
}

flatten_path :: (r: *Raster, verbs: []Verb, points: []Vector2, g: Mat) {
	clear(*r.pts);
	clear(*r.polys);
	pi := 0;
	start := -1;
	cur: Vector2;
	finish :: (r: *Raster, start: int, closed: bool) {
		if start < 0 { return; }
		n := len(r.pts) - start;
		if n > 0 { append(*r.polys, Poly.{start, n, closed}); }
	}
	for v: verbs {
		if v == {
		case .Move;
			finish(r, start, false);
			cur = mat_apply(g, points[pi]);
			pi += 1;
			start = len(r.pts);
			append(*r.pts, cur);
		case .Line;
			if start < 0 {
				start = len(r.pts);
				append(*r.pts, cur);
			}
			cur = mat_apply(g, points[pi]);
			pi += 1;
			append(*r.pts, cur);
		case .Quad;
			if start < 0 {
				start = len(r.pts);
				append(*r.pts, cur);
			}
			c := mat_apply(g, points[pi]);
			p := mat_apply(g, points[pi + 1]);
			pi += 2;
			dd := cur - 2 * c + p;
			n := cast(int)(math.ceil(math.sqrt(math.sqrt(dd.x * dd.x + dd.y * dd.y) / (4 * TOLERANCE))));
			n = clamp(n, 1, 256);
			for i: 1..n {
				t := cast(float32)(i) / cast(float32)(n);
				u := 1 - t;
				append(*r.pts, u * u * cur + 2 * u * t * c + t * t * p);
			}
			cur = p;
		case .Cubic;
			if start < 0 {
				start = len(r.pts);
				append(*r.pts, cur);
			}
			c1 := mat_apply(g, points[pi]);
			c2 := mat_apply(g, points[pi + 1]);
			p := mat_apply(g, points[pi + 2]);
			pi += 3;
			d1 := cur - 2 * c1 + c2;
			d2 := c1 - 2 * c2 + p;
			dd := math.sqrt(max(d1.x * d1.x + d1.y * d1.y, d2.x * d2.x + d2.y * d2.y));
			n := cast(int)(math.ceil(math.sqrt(0.75 * dd / TOLERANCE)));
			n = clamp(n, 1, 256);
			for i: 1..n {
				t := cast(float32)(i) / cast(float32)(n);
				u := 1 - t;
				append(*r.pts, u * u * u * cur + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * p);
			}
			cur = p;
		case .Close;
			if start >= 0 { cur = r.pts[start]; }
			finish(r, start, true);
			start = -1;
		}
	}
	finish(r, start, false);
}
#scope_export

// ---- public path API (used by fc:lottie) ----

// Path is a standalone path: verbs and their points (Move/Line 1, Quad 2, Cubic 3, Close 0).
Path :: struct {
	verbs: [..]Verb;
	points: [..]Vector2;
}

path_clear :: (p: *Path) {clear(*p.verbs); clear(*p.points);}
path_destroy :: (p: *Path) {delete(p.verbs); delete(p.points);}
path_move :: (p: *Path, a: Vector2) {append(*p.verbs, Verb.Move); append(*p.points, a);}
path_line :: (p: *Path, a: Vector2) {append(*p.verbs, Verb.Line); append(*p.points, a);}
path_cubic :: (p: *Path, c1: Vector2, c2: Vector2, a: Vector2) {append(*p.verbs, Verb.Cubic); append(*p.points, c1, c2, a);}
path_close :: (p: *Path) {append(*p.verbs, Verb.Close);}

Stroke :: struct {
	width: float32; // in path units (scaled by the transform's area scale)
	cap: Line_Cap;
	join: Line_Join;
	miter_limit: float32;
}

// Rasterizer is reusable scratch for path coverage at a fixed size. Buffers it
// returns stay valid until rasterizer_reset / rasterizer_destroy.
Rasterizer :: struct {
	r: Raster;
	arena: virtual.Arena;
}

rasterizer_init :: (rz: *Rasterizer, w: int, h: int) -> bool {
	if virtual.arena_init_growing(*rz.arena) != .None { return false; }
	rz.r = Raster.{
		w = w,
		h = h,
		stride = w + 2,
		arena = virtual.arena_allocator(*rz.arena)
	};
	rasterizer_reset(rz);
	return true;
}

rasterizer_reset :: (rz: *Rasterizer) {
	virtual.arena_free_all(*rz.arena);
	rz.r.acc = make_slice(float32, rz.r.stride * rz.r.h, rz.r.arena);
	rz.r.pts = make_dynamic(Vector2, 0, 0, rz.r.arena);
	rz.r.polys = make_dynamic(Poly, 0, 0, rz.r.arena);
}

rasterizer_destroy :: (rz: *Rasterizer) {
	virtual.arena_destroy(*rz.arena);
	rz.* = .{};
}

// rasterizer_buffer returns a zeroed w*h*n f32 scratch buffer (valid until reset).
rasterizer_buffer :: (rz: *Rasterizer, n := 1) -> []float32 {
	return make_slice(float32, rz.r.w * rz.r.h * n, rz.r.arena);
}

// fill_coverage returns w*h coverage (0..1) of the path under transform m.
fill_coverage :: (rz: *Rasterizer, verbs: []Verb, points: []Vector2, m: Mat, rule: Fill_Rule) -> []float32 {
	r := *rz.r;
	flatten_path(r, verbs, points, m);
	for pl: r.polys {
		pts := sub(r.pts, pl.first, pl.first + pl.count);
		for i: 0..len(pts)-1 { acc_line(r, pts[i], pts[(i + 1) % len(pts)]); }
	}
	cov := make_slice(float32, r.w * r.h, r.arena);
	integrate(r, cov, rule);
	return cov;
}

// stroke_coverage returns w*h coverage of the path stroked under transform m.
stroke_coverage :: (rz: *Rasterizer, verbs: []Verb, points: []Vector2, m: Mat, s: Stroke) -> []float32 {
	r := *rz.r;
	flatten_path(r, verbs, points, m);
	scale := math.sqrt(abs(get(m, 0) * get(m, 3) - get(m, 1) * get(m, 2)));
	hw := s.width * scale / 2;
	polys := view(r.polys);
	for pl: polys { stroke_poly(r, sub(r.pts, pl.first, pl.first + pl.count), pl.closed, hw, s.cap, s.join, max(s.miter_limit, 1)); }
	cov := make_slice(float32, r.w * r.h, r.arena);
	integrate(r, cov, .Nonzero);
	return cov;
}
#scope_module

// ---- stroking ----

emit_circle :: (r: *Raster, c: Vector2, radius: float32) {
	if radius <= 0 { return; }
	n := 8;
	if radius > TOLERANCE {
		n = max(8, cast(int)(math.ceil(PI32 / math.acos(1 - TOLERANCE / radius))));
	}
	n = min(n, 512);
	// Polygon with vertices slightly outside so its area matches the circle's.
	rr := radius * math.sqrt(2 * PI32 / (cast(float32)(n) * math.sin(2 * PI32 / cast(float32)(n))));
	prev := c + .{rr, 0};
	for i: 1..n {
		a := 2 * PI32 * cast(float32)(i) / cast(float32)(n);
		p := c + rr * Vector2.{math.cos(a), math.sin(a)};
		acc_line(r, prev, p);
		prev = p;
	}
}

// emit_loop accumulates a closed polygon as-is (orientation matters).
emit_loop :: (r: *Raster, pts: []Vector2) {
	for i: 0..len(pts)-1 { acc_line(r, pts[i], pts[(i + 1) % len(pts)]); }
}

// arc_points appends points on a circle from angle a0 sweeping `sweep`, endpoints excluded.
arc_points :: (out: *[..]Vector2, c: Vector2, radius: float32, a0: float32, sweep: float32) {
	n := 1;
	if radius > TOLERANCE {
		step := 2 * math.acos(1 - TOLERANCE / radius);
		n = max(1, cast(int)(math.ceil(abs(sweep) / step)));
	}
	n = min(n, 256);
	for i: 1..n-1 {
		a := a0 + sweep * cast(float32)(i) / cast(float32)(n);
		append(out, c + radius * Vector2.{math.cos(a), math.sin(a)});
	}
}

angle_of :: inline (v: Vector2) -> float32 {
	return math.atan2(v.y, v.x);
};

// offset_side appends the left offset (normal (-dy, dx)) of a polyline walked
// forward, with joins. Outer joins get join geometry; inner joins pivot through
// the vertex (the overlap stays inside the stroke, so nonzero fill is exact).
offset_side :: (out: *[..]Vector2, pts: []Vector2, closed: bool, hw: float32, join: Line_Join, miter_limit: float32) {
	n := len(pts);
	nseg := ifx closed then n else n - 1;
	for i: 0..nseg-1 {
		a := pts[i];
		b := pts[(i + 1) % n];
		d := seg_dir(a, b);
		nc := Vector2.{-d.y, d.x} * hw;
		if i == 0 && !closed {
			append(out, a + nc);
		} else {
			dp := seg_dir(pts[(i - 1 + n) % n], a);
			np := Vector2.{-dp.y, dp.x} * hw;
			cross := dp.x * d.y - dp.y * d.x;
			dot := dp.x * d.x + dp.y * d.y;
			if abs(cross) < 1.0e-6 && dot > 0 {
				append(out, a + nc);
			} else if cross > 0 {
				// Turning left: this (left) side is the inner side. Use the offset
				// lines' intersection when it lies on both segments (no overlap
				// sliver at the edge); otherwise pivot through the vertex.
				un := np / hw;
				uc := nc / hw;
				ndot := un.x * uc.x + un.y * uc.y;
				pv := pts[(i - 1 + n) % n];
				lp := math.sqrt((a - pv).x * (a - pv).x + (a - pv).y * (a - pv).y);
				lc := math.sqrt((b - a).x * (b - a).x + (b - a).y * (b - a).y);
				if 1 + ndot > 1.0e-3 && hw * abs(cross) / (1 + ndot) <= min(lp, lc) {
					append(out, a + (un + uc) / (1 + ndot) * hw);
				} else {
					append(out, a + np, a, a + nc);
				}
			} else {
				append(out, a + np);
				if join == {
				case .Round;
					arc_points(out, a, hw, angle_of(np), math.atan2(np.x * nc.y - np.y * nc.x, np.x * nc.x + np.y * nc.y));
				case .Miter;
					un := np / hw;
					uc := nc / hw;
					ndot := un.x * uc.x + un.y * uc.y;
					if 1 + ndot > 1.0e-6 {
						m := (un + uc) / (1 + ndot);
						if math.sqrt(m.x * m.x + m.y * m.y) <= miter_limit { append(out, a + m * hw); }
					}
				case .Bevel;
				}
				append(out, a + nc);
			}
		}
		append(out, b + nc);
	}
}

seg_dir :: (a: Vector2, b: Vector2) -> Vector2 {
	d := b - a;
	return d / math.sqrt(d.x * d.x + d.y * d.y);
}

// stroke_poly fills the stroke outline of one polyline (pixel space, half width hw).
stroke_poly :: (r: *Raster, src: []Vector2, closed_in: bool, hw: float32, cap: Line_Cap, join: Line_Join, miter_limit: float32) {
	if hw <= 0 || len(src) == 0 { return; }
	// Drop repeated points.
	pts := make_dynamic(Vector2, 0, len(src), r.arena);
	for p: src {
		if len(pts) > 0 {
			d := p - pts[len(pts) - 1];
			if d.x * d.x + d.y * d.y < 1.0e-12 { continue; }
		}
		append(*pts, p);
	}
	closed := closed_in;
	if closed && len(pts) > 1 {
		d := pts[0] - pts[len(pts) - 1];
		if d.x * d.x + d.y * d.y < 1.0e-12 { pop(*pts); }
	}
	n := len(pts);
	if n == 1 {
		p := pts[0];
		if cap == {
		case .Round;
			emit_circle(r, p, hw);
		case .Square;
			q := Vector2.[p + .{-hw, -hw}, p + .{hw, -hw}, p + .{hw, hw}, p + .{-hw, hw}];
			emit_loop(r, view(q));
		case .Butt;
		}
		return;
	}
	if n == 2 { closed = false; }
	rev := make_slice(Vector2, n, r.arena);
	for p, i: pts { rev[n - 1 - i] = p; }
	out := make_dynamic(Vector2, 0, 0, r.arena);
	if closed {
		offset_side(*out, view(pts), true, hw, join, miter_limit);
		emit_loop(r, view(out));
		clear(*out);
		offset_side(*out, rev, true, hw, join, miter_limit);
		emit_loop(r, view(out));
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
	offset_side(*out, view(pts), false, hw, join, miter_limit);
	if cap == .Round {
		de := seg_dir(pts[n - 2], pts[n - 1]);
		arc_points(*out, pts[n - 1], hw, angle_of(.{-de.y, de.x}), -PI32);
	}
	offset_side(*out, rev, false, hw, join, miter_limit);
	if cap == .Round {
		ds := seg_dir(pts[0], pts[1]);
		arc_points(*out, pts[0], hw, angle_of(.{ds.y, -ds.x}), -PI32);
	}
	emit_loop(r, view(out));
}

// ---- coverage accumulation ----

// acc_line adds the signed area/cover of a line (pixel coords) to r.acc.
// Parts left of x=0 are folded onto x=0; parts right of x=w are dropped.
acc_line :: (r: *Raster, p0: Vector2, p1: Vector2) {
	a := p0;
	b := p1;
	if a.y == b.y { return; }
	h := cast(float32)(r.h);
	w := cast(float32)(r.w);
	if (a.y <= 0 && b.y <= 0) || (a.y >= h && b.y >= h) { return; }
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
acc_line_inside :: (r: *Raster, p0: Vector2, p1: Vector2) {
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
	y1 := min(r.h, cast(int)(math.ceil(b.y)));
	acc := r.acc;
	for y: y0..y1-1 {
		ls := y * r.stride;
		dy := min(cast(float32)(y + 1), b.y) - max(cast(float32)(y), a.y);
		xnext := x + dxdy * dy;
		d := dy * dir;
		x0, x1 := x, xnext;
		if x0 > x1 { x0, x1 = x1, x0; }
		x0f := math.floor(x0);
		x0i := cast(int)(x0f);
		x1c := math.ceil(x1);
		x1i := cast(int)(x1c);
		if x1i <= x0i + 1 {
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
		}
		x = xnext;
	}
}

// integrate turns accumulated cells into coverage and clears the accumulator.
integrate :: (r: *Raster, cov: []float32, rule: Fill_Rule) {
	for y: 0..r.h-1 {
		row := sub(r.acc, y * r.stride, (y + 1) * r.stride);
		out := sub(cov, y * r.w, (y + 1) * r.w);
		sum: float32 = 0;
		for x: 0..r.w-1 {
			sum += row[x];
			v := abs(sum);
			if rule == .Nonzero {
				at(*out, x).* = min(v, 1);
			} else {
				v = v - 2 * math.floor(v / 2);
				at(*out, x).* = ifx v > 1 then 2 - v else v;
			}
		}
		for * c: row { c.* = 0; }
	}
}
#scope_export

