package lottie

import "core:math"
import "core:mem"
import "core:mem/virtual"
import "fc:vector"

Mat :: vector.Mat

// Player renders frames of one animation at a fixed pixel size.
Player :: struct {
	anim:   ^Animation,
	w, h:   int,
	view:   Mat, // animation space -> pixels (xMidYMid meet)
	rz:     vector.Rasterizer,
	frame:  virtual.Arena, // per-frame geometry
	falloc: mem.Allocator,
	out:    []u8, // last rendered frame, straight RGBA8
	depth:  int, // precomp nesting guard
}

player_init :: proc(p: ^Player, anim: ^Animation, w, h: int, allocator := context.allocator) -> bool {
	p^ = {anim = anim, w = w, h = h}
	if !vector.rasterizer_init(&p.rz, w, h) do return false
	if virtual.arena_init_growing(&p.frame) != nil do return false
	p.falloc = virtual.arena_allocator(&p.frame)
	s := min(f32(w) / anim.w, f32(h) / anim.h)
	p.view = {s, 0, 0, s, (f32(w) - anim.w * s) / 2, (f32(h) - anim.h * s) / 2}
	p.out = make([]u8, w * h * 4, allocator)
	return true
}

player_destroy :: proc(p: ^Player, allocator := context.allocator) {
	vector.rasterizer_destroy(&p.rz)
	virtual.arena_destroy(&p.frame)
	delete(p.out, allocator)
	p^ = {}
}

// frame_at maps seconds to a (looping, fractional) frame number.
frame_at :: proc(anim: ^Animation, seconds: f64) -> f32 {
	dur := f64(anim.op - anim.ip)
	if dur <= 0 do return anim.ip
	f := math.mod(seconds * f64(anim.fr), dur)
	if f < 0 do f += dur
	return anim.ip + f32(f)
}

// render renders frame number `frame` (fractional allowed) and returns the
// player's straight-alpha RGBA8 buffer (w*h*4, valid until the next call).
render :: proc(p: ^Player, frame: f32) -> []u8 {
	vector.rasterizer_reset(&p.rz)
	virtual.arena_free_all(&p.frame)
	canvas := vector.rasterizer_buffer(&p.rz, 4)
	render_comp(p, &p.anim.root, frame, p.view, canvas)
	vector.premul_to_rgba8(canvas, p.out)
	return p.out
}

// ---------------------------------------------------------------------------

@(private)
mat_mul :: proc(a, b: Mat) -> Mat {
	return {
		a[0] * b[0] + a[2] * b[1],
		a[1] * b[0] + a[3] * b[1],
		a[0] * b[2] + a[2] * b[3],
		a[1] * b[2] + a[3] * b[3],
		a[0] * b[4] + a[2] * b[5] + a[4],
		a[1] * b[4] + a[3] * b[5] + a[5],
	}
}

@(private)
apply :: #force_inline proc(m: Mat, p: [2]f32) -> [2]f32 {
	return {m[0] * p.x + m[2] * p.y + m[4], m[1] * p.x + m[3] * p.y + m[5]}
}

@(private)
ev1 :: proc(pr: ^Prop, t: f32, def: f32 = 0) -> f32 {
	v: [4]f32
	if eval(pr, t, v[:]) < 1 do return def
	return v[0]
}

@(private)
ev2 :: proc(pr: ^Prop, t: f32, def: [2]f32 = {}) -> [2]f32 {
	v: [4]f32
	n := eval(pr, t, v[:])
	if n < 1 do return def
	if n < 2 do return {v[0], v[0]}
	return {v[0], v[1]}
}

// Transform matrix (lottie-web order: translate(-a), scale, skew, rotate, translate(p)).
@(private)
transform_matrix :: proc(tr: ^Transform, t: f32) -> (Mat, f32) {
	a := ev2(&tr.a, t)
	s := ev2(&tr.s, t, {100, 100}) / 100
	r := ev1(&tr.r, t) * math.PI / 180
	pos: [2]f32
	if tr.split {
		pos = {ev1(&tr.px, t), ev1(&tr.py, t)}
	} else {
		pos = ev2(&tr.p, t)
	}
	m := Mat{s.x, 0, 0, s.y, -a.x * s.x, -a.y * s.y}
	sk := ev1(&tr.sk, t)
	if sk != 0 {
		sa := ev1(&tr.sa, t) * math.PI / 180
		k := math.tan(-sk * math.PI / 180)
		c, sn := math.cos(sa), math.sin(sa)
		rot := Mat{c, sn, -sn, c, 0, 0}
		rinv := Mat{c, -sn, sn, c, 0, 0}
		shear := Mat{1, 0, k, 1, 0, 0}
		m = mat_mul(rot, mat_mul(shear, mat_mul(rinv, m)))
	}
	c, sn := math.cos(r), math.sin(r)
	m = mat_mul(Mat{c, sn, -sn, c, pos.x, pos.y}, m)
	return m, ev1(&tr.o, t, 100) / 100
}

// Keyframe times are in the containing comp's time (lottie-web compares
// frame - st against kf.t - st), so layer properties use the comp frame; only a
// precomp's inner time is shifted/stretched.
@(private)
precomp_time :: proc(l: ^Layer, frame: f32) -> f32 {
	return (frame - l.st) / l.sr
}

// World matrix of a layer within its comp (own transform composed with parents').
@(private)
layer_world :: proc(c: ^Comp, l: ^Layer, frame: f32, depth := 0) -> Mat {
	m, _ := transform_matrix(&l.ks, frame)
	if l.parent >= 0 && depth < 32 {
		for &pl in c.layers {
			if pl.ind == l.parent {
				return mat_mul(layer_world(c, &pl, frame, depth + 1), m)
			}
		}
	}
	return m
}

@(private)
composite :: proc(dst, src: []f32, alpha: f32) {
	for i := 0; i < len(dst); i += 4 {
		a := src[i + 3] * alpha
		if a <= 0 do continue
		k := 1 - a
		dst[i] = src[i] * alpha + dst[i] * k
		dst[i + 1] = src[i + 1] * alpha + dst[i + 1] * k
		dst[i + 2] = src[i + 2] * alpha + dst[i + 2] * k
		dst[i + 3] = a + dst[i + 3] * k
	}
}

@(private)
render_comp :: proc(p: ^Player, c: ^Comp, frame: f32, m: Mat, dst: []f32) {
	for i := len(c.layers) - 1; i >= 0; i -= 1 {
		l := &c.layers[i]
		if l.td || l.hidden || l.ty == 3 do continue
		if !(frame >= l.ip && frame < l.op) do continue
		buf, op := render_layer(p, c, l, frame, m)
		if buf == nil do continue
		if l.tt > 0 && i > 0 && c.layers[i - 1].td {
			ml := &c.layers[i - 1]
			mask_buf: []f32
			mop: f32 = 1
			if frame >= ml.ip && frame < ml.op do mask_buf, mop = render_layer(p, c, ml, frame, m)
			luma := l.tt == 3 || l.tt == 4
			inv := l.tt == 2 || l.tt == 4
			for j := 0; j < len(buf); j += 4 {
				f: f32 = 0
				if mask_buf != nil {
					if luma {
						f = (0.2125 * mask_buf[j] + 0.7154 * mask_buf[j + 1] + 0.0721 * mask_buf[j + 2]) * mop
					} else {
						f = mask_buf[j + 3] * mop
					}
				}
				if inv do f = 1 - f
				buf[j] *= f
				buf[j + 1] *= f
				buf[j + 2] *= f
				buf[j + 3] *= f
			}
		}
		composite(dst, buf, op)
	}
}

// Renders one layer (content + masks) into a new premultiplied buffer; returns
// it with the layer opacity to composite with.
@(private)
render_layer :: proc(p: ^Player, c: ^Comp, l: ^Layer, frame: f32, m: Mat) -> ([]f32, f32) {
	lt := frame
	_, opacity := transform_matrix(&l.ks, lt)
	if opacity <= 0 do return nil, 0
	lm := mat_mul(m, layer_world(c, l, frame))
	buf := vector.rasterizer_buffer(&p.rz, 4)
	switch l.ty {
	case 0:
		if l.ref < 0 do return nil, 0
		pc := &p.anim.assets[l.ref]
		if p.depth > 16 do return nil, 0 // self-referencing precomps
		p.depth += 1
		render_comp(p, pc, precomp_time(l, frame), lm, buf)
		p.depth -= 1
		// precomps are clipped to their bounds
		w := l.w > 0 ? l.w : pc.w
		h := l.h > 0 ? l.h : pc.h
		path: vector.Path
		path.verbs = make([dynamic]vector.Verb, p.falloc)
		path.points = make([dynamic][2]f32, p.falloc)
		vector.path_move(&path, {0, 0})
		vector.path_line(&path, {w, 0})
		vector.path_line(&path, {w, h})
		vector.path_line(&path, {0, h})
		vector.path_close(&path)
		cov := vector.fill_coverage(&p.rz, path.verbs[:], path.points[:], lm, .Nonzero)
		for v, j in cov do for k in 0 ..< 4 do buf[j * 4 + k] *= v
	case 1:
		path: vector.Path
		path.verbs = make([dynamic]vector.Verb, p.falloc)
		path.points = make([dynamic][2]f32, p.falloc)
		vector.path_move(&path, {0, 0})
		vector.path_line(&path, {l.w, 0})
		vector.path_line(&path, {l.w, l.h})
		vector.path_line(&path, {0, l.h})
		vector.path_close(&path)
		cov := vector.fill_coverage(&p.rz, path.verbs[:], path.points[:], lm, .Nonzero)
		vector.solid_fill_premul(l.solid_color, cov, buf)
	case 4:
		draw_shapes(p, l.shapes, lt, lm, buf)
	case:
		return nil, 0
	}
	if len(l.masks) > 0 do apply_masks(p, l, lt, lm, buf)
	return buf, opacity
}

@(private)
apply_masks :: proc(p: ^Player, l: ^Layer, t: f32, lm: Mat, buf: []f32) {
	acc: []f32
	for &mk in l.masks {
		if mk.mode == 'n' do continue
		sd := eval_shape(&mk.path, t, p.falloc)
		path := shape_to_path(p, sd, false)
		cov := vector.fill_coverage(&p.rz, path.verbs[:], path.points[:], lm, .Nonzero)
		o := ev1(&mk.opacity, t, 100) / 100
		for &v in cov {
			v *= o
			if mk.inverted do v = 1 - v
		}
		if acc == nil {
			acc = vector.rasterizer_buffer(&p.rz, 1)
			switch mk.mode {
			case 's':
				for &v, j in acc do v = 1 - cov[j]
			case:
				copy(acc, cov)
			}
			continue
		}
		for &v, j in acc {
			c := cov[j]
			switch mk.mode {
			case 'a':
				v = v + c - v * c
			case 's':
				v *= 1 - c
			case 'i':
				v *= c
			case 'l':
				v = max(v, c)
			case 'd':
				v = min(v, c)
			case 'f':
				v = abs(v - c)
			}
		}
	}
	if acc == nil do return
	for v, j in acc do for k in 0 ..< 4 do buf[j * 4 + k] *= v
}

// ---------------------------------------------------------------------------
// Shape items

// A path slot: trims replace slot.path in place, so (as in lottie-web, where
// modifiers rewrite the shared shape data) they also affect styles listed
// above the trim.
@(private)
Slot :: struct {
	path: ^vector.Path,
}

@(private)
Draw :: struct {
	item:    ^Item,
	paths:   []^Slot, // pixel space
	m:       Mat, // the style's group matrix (gradients, stroke width)
	opacity: f32,
}

@(private)
new_path :: proc(p: ^Player) -> ^vector.Path {
	path := new(vector.Path, p.falloc)
	path.verbs = make([dynamic]vector.Verb, p.falloc)
	path.points = make([dynamic][2]f32, p.falloc)
	return path
}

// Lottie bezier vertices -> path in local space (reversed if requested).
@(private)
shape_to_path :: proc(p: ^Player, sd: Shape_Data, reversed: bool, m: Mat = vector.MAT_IDENTITY) -> ^vector.Path {
	path := new_path(p)
	n := len(sd.v)
	if n == 0 do return path
	idx :: #force_inline proc(j, n: int, rev: bool) -> int {return rev ? (n - j % n) % n : j % n}
	vector.path_move(path, apply(m, sd.v[idx(0, n, reversed)]))
	segs := sd.closed ? n : n - 1
	for k in 0 ..< segs {
		a := idx(k, n, reversed)
		b := idx(k + 1, n, reversed)
		out_t := reversed ? sd.i[a] : sd.o[a]
		in_t := reversed ? sd.o[b] : sd.i[b]
		p0 := sd.v[a]
		p3 := sd.v[b]
		if out_t == {} && in_t == {} {
			vector.path_line(path, apply(m, p3))
		} else {
			vector.path_cubic(path, apply(m, p0 + out_t), apply(m, p3 + in_t), apply(m, p3))
		}
	}
	if sd.closed do vector.path_close(path)
	return path
}

@(private)
KAPPA :: 0.5519150244935105707435627

@(private)
build_primitive :: proc(p: ^Player, it: ^Item, t: f32, m: Mat) -> ^vector.Path {
	sd: Shape_Data
	sd.closed = true
	#partial switch it.kind {
	case .Ellipse:
		c := ev2(&it.p, t)
		s := ev2(&it.size, t) / 2
		k := s * KAPPA
		sd.v = make([][2]f32, 4, p.falloc)
		sd.i = make([][2]f32, 4, p.falloc)
		sd.o = make([][2]f32, 4, p.falloc)
		// lottie-web: top, right, bottom, left (clockwise)
		sd.v[0], sd.i[0], sd.o[0] = {c.x, c.y - s.y}, {-k.x, 0}, {k.x, 0}
		sd.v[1], sd.i[1], sd.o[1] = {c.x + s.x, c.y}, {0, -k.y}, {0, k.y}
		sd.v[2], sd.i[2], sd.o[2] = {c.x, c.y + s.y}, {k.x, 0}, {-k.x, 0}
		sd.v[3], sd.i[3], sd.o[3] = {c.x - s.x, c.y}, {0, k.y}, {0, -k.y}
	case .Rect:
		c := ev2(&it.p, t)
		hs := ev2(&it.size, t) / 2
		r := min(ev1(&it.r, t), hs.x, hs.y)
		if r <= 0 {
			sd.v = make([][2]f32, 4, p.falloc)
			sd.i = make([][2]f32, 4, p.falloc)
			sd.o = make([][2]f32, 4, p.falloc)
			// lottie-web starts at the top-right corner
			sd.v[0] = {c.x + hs.x, c.y - hs.y}
			sd.v[1] = {c.x + hs.x, c.y + hs.y}
			sd.v[2] = {c.x - hs.x, c.y + hs.y}
			sd.v[3] = {c.x - hs.x, c.y - hs.y}
		} else {
			k := r * (1 - KAPPA)
			x0, x1, y0, y1 := c.x - hs.x, c.x + hs.x, c.y - hs.y, c.y + hs.y
			sd.v = make([][2]f32, 8, p.falloc)
			sd.i = make([][2]f32, 8, p.falloc)
			sd.o = make([][2]f32, 8, p.falloc)
			pts := [8][2]f32{{x1, y0 + r}, {x1, y1 - r}, {x1 - r, y1}, {x0 + r, y1}, {x0, y1 - r}, {x0, y0 + r}, {x0 + r, y0}, {x1 - r, y0}}
			for q, j in pts do sd.v[j] = q
			cr := r - k
			sd.o[1] = {0, cr};sd.i[2] = {cr, 0}
			sd.o[3] = {-cr, 0};sd.i[4] = {0, cr}
			sd.o[5] = {0, -cr};sd.i[6] = {-cr, 0}
			sd.o[7] = {cr, 0};sd.i[0] = {0, -cr}
		}
	case .Star:
		c := ev2(&it.p, t)
		pts := ev1(&it.pt, t)
		if !(pts >= 2) do return new_path(p) // also rejects NaN
		n := int(min(pts, 1000))
		rot := ev1(&it.r, t) * math.PI / 180
		or_ := ev1(&it.or_, t)
		ir := ev1(&it.ir, t)
		star := it.star_type == 1
		cnt := star ? 2 * n : n
		sd.v = make([][2]f32, cnt, p.falloc)
		sd.i = make([][2]f32, cnt, p.falloc)
		sd.o = make([][2]f32, cnt, p.falloc)
		for j in 0 ..< cnt {
			rr := star ? (j & 1 == 0 ? or_ : ir) : or_
			ang := rot - math.PI / 2 + f32(j) * 2 * math.PI / f32(cnt)
			sd.v[j] = c + rr * [2]f32{math.cos(ang), math.sin(ang)}
		}
	}
	return shape_to_path(p, sd, it.reversed, m)
}

// Walks a group's items top to bottom: paths accumulate in `geo`, groups add
// their (transformed) geometry, trims rewrite geo, styles snapshot geo.
@(private)
walk_items :: proc(p: ^Player, items: []Item, t: f32, m: Mat, opacity: f32, geo: ^[dynamic]^Slot, draws: ^[dynamic]Draw) {
	for &it in items {
		if it.hidden do continue
		switch it.kind {
		case .Ignore:
		case .Group:
			gm := m
			go := opacity
			if it.has_tr {
				tm, o := transform_matrix(&it.tr, t)
				gm = mat_mul(m, tm)
				go *= o
			}
			sub := make([dynamic]^Slot, p.falloc)
			walk_items(p, it.items, t, gm, go, &sub, draws)
			append(geo, ..sub[:])
		case .Path:
			sd := eval_shape(&it.shape, t, p.falloc)
			append(geo, new_slot(p, shape_to_path(p, sd, it.reversed, m)))
		case .Rect, .Ellipse, .Star:
			append(geo, new_slot(p, build_primitive(p, &it, t, m)))
		case .Fill, .Stroke, .Gradient_Fill, .Gradient_Stroke:
			snap := make([]^Slot, len(geo), p.falloc)
			copy(snap, geo[:])
			append(draws, Draw{item = &it, paths = snap, m = m, opacity = opacity})
		case .Trim:
			apply_trim(p, &it, t, geo)
		}
	}
}

@(private)
new_slot :: proc(p: ^Player, path: ^vector.Path) -> ^Slot {
	sl := new(Slot, p.falloc)
	sl.path = path
	return sl
}

@(private)
draw_shapes :: proc(p: ^Player, items: []Item, t: f32, m: Mat, buf: []f32) {
	geo := make([dynamic]^Slot, p.falloc)
	draws := make([dynamic]Draw, p.falloc)
	walk_items(p, items, t, m, 1, &geo, &draws)
	// the first style in document order is on top
	for k := len(draws) - 1; k >= 0; k -= 1 {
		d := &draws[k]
		it := d.item
		op := ev1(&it.opacity, t, 100) / 100 * d.opacity
		if op <= 0 || len(d.paths) == 0 do continue
		// merge the snapshot into one path so overlapping sub-paths fill once
		merged := new_path(p)
		for sl in d.paths {
			append(&merged.verbs, ..sl.path.verbs[:])
			append(&merged.points, ..sl.path.points[:])
		}
		if len(merged.verbs) == 0 do continue
		cov: []f32
		if it.kind == .Fill || it.kind == .Gradient_Fill {
			cov = vector.fill_coverage(&p.rz, merged.verbs[:], merged.points[:], vector.MAT_IDENTITY, it.evenodd ? .Evenodd : .Nonzero)
		} else {
			w := ev1(&it.width, t)
			if w <= 0 do continue
			scale := math.sqrt(abs(d.m[0] * d.m[3] - d.m[1] * d.m[2]))
			cap := it.cap == 1 ? vector.Line_Cap.Butt : it.cap == 3 ? vector.Line_Cap.Square : vector.Line_Cap.Round
			join := it.join == 1 ? vector.Line_Join.Miter : it.join == 3 ? vector.Line_Join.Bevel : vector.Line_Join.Round
			cov = vector.stroke_coverage(&p.rz, merged.verbs[:], merged.points[:], vector.MAT_IDENTITY, {width = w * scale, cap = cap, join = join, miter_limit = it.miter})
		}
		if it.kind == .Fill || it.kind == .Stroke {
			c: [4]f32 = {0, 0, 0, 1}
			eval(&it.color, t, c[:])
			c[3] = op
			vector.solid_fill_premul(c, cov, buf)
		} else {
			g := build_gradient(p, it, t, op)
			vector.gradient_fill_premul(&g, d.m, cov, buf, p.w, p.h)
		}
	}
}

@(private)
build_gradient :: proc(p: ^Player, it: ^Item, t: f32, opacity: f32) -> vector.Gradient {
	g := vector.Gradient {
		radial    = it.grad_type == 2,
		transform = vector.MAT_IDENTITY,
	}
	vals: [256]f32
	n := eval(&it.g_colors, t, vals[:])
	cnt := clamp(it.g_count, 0, n / 4)
	stops := make([]vector.Gradient_Stop, cnt, p.falloc)
	nop := (n - cnt * 4) / 2 // opacity stops follow the colour stops
	for k in 0 ..< cnt {
		off := vals[k * 4]
		stops[k] = {off, {vals[k * 4 + 1], vals[k * 4 + 2], vals[k * 4 + 3], 1}}
		if nop > 0 {
			// opacity at this offset (linear between opacity stops)
			ob := cnt * 4
			a := vals[ob + 1]
			for q in 0 ..< nop {
				o0, a0 := vals[ob + q * 2], vals[ob + q * 2 + 1]
				if off <= o0 {
					if q == 0 {
						a = a0
					} else {
						o1, a1 := vals[ob + q * 2 - 2], vals[ob + q * 2 - 1]
						f := o0 > o1 ? (off - o1) / (o0 - o1) : 0
						a = a1 + (a0 - a1) * f
					}
					break
				}
				a = a0
			}
			stops[k].color[3] = a
		}
		stops[k].color[3] *= opacity
	}
	g.stops = stops
	s := ev2(&it.g_start, t)
	e := ev2(&it.g_end, t)
	if !g.radial {
		g.p0, g.p1 = s, e
	} else {
		r := math.sqrt((e.x - s.x) * (e.x - s.x) + (e.y - s.y) * (e.y - s.y))
		hl := clamp(ev1(&it.g_hl, t) / 100, -0.99, 0.99)
		ha := ev1(&it.g_ha, t) * math.PI / 180
		base := math.atan2(e.y - s.y, e.x - s.x)
		g.p0 = s
		g.r = r
		g.p1 = s + r * hl * [2]f32{math.cos(base + ha), math.sin(base + ha)}
	}
	return g
}

// ---------------------------------------------------------------------------
// Trim paths

@(private)
Seg :: struct {
	p: [4][2]f32,
	l: f32,
}

@(private)
cubic_len :: proc(s: [4][2]f32) -> f32 {
	N :: 24
	l: f32
	prev := s[0]
	for i in 1 ..= N {
		t := f32(i) / N
		m := 1 - t
		q := m * m * m * s[0] + 3 * m * m * t * s[1] + 3 * m * t * t * s[2] + t * t * t * s[3]
		d := q - prev
		l += math.sqrt(d.x * d.x + d.y * d.y)
		prev = q
	}
	return l
}

// parameter u where the arc length from 0 reaches `target` (by sampling)
@(private)
cubic_param :: proc(s: [4][2]f32, target: f32) -> f32 {
	N :: 48
	l: f32
	prev := s[0]
	for i in 1 ..= N {
		t := f32(i) / N
		m := 1 - t
		q := m * m * m * s[0] + 3 * m * m * t * s[1] + 3 * m * t * t * s[2] + t * t * t * s[3]
		d := q - prev
		dl := math.sqrt(d.x * d.x + d.y * d.y)
		if l + dl >= target {
			f := dl > 0 ? (target - l) / dl : 0
			return (f32(i - 1) + f) / N
		}
		l += dl
		prev = q
	}
	return 1
}

@(private)
split_cubic :: proc(s: [4][2]f32, u0, u1: f32) -> [4][2]f32 {
	// de Casteljau: keep [u0, u1]
	sub :: proc(s: [4][2]f32, t: f32) -> (left, right: [4][2]f32) {
		a := s[0] + (s[1] - s[0]) * t
		b := s[1] + (s[2] - s[1]) * t
		c := s[2] + (s[3] - s[2]) * t
		d := a + (b - a) * t
		e := b + (c - b) * t
		f := d + (e - d) * t
		return {s[0], a, d, f}, {f, e, c, s[3]}
	}
	_, r := sub(s, u0)
	if u0 >= 1 do return {s[3], s[3], s[3], s[3]}
	t := (u1 - u0) / (1 - u0)
	l, _ := sub(r, clamp(t, 0, 1))
	return l
}

@(private)
path_segments :: proc(p: ^Player, path: ^vector.Path) -> [dynamic][dynamic]Seg {
	out := make([dynamic][dynamic]Seg, p.falloc)
	pi := 0
	cur, start: [2]f32
	segs: ^[dynamic]Seg
	for v in path.verbs {
		switch v {
		case .Move:
			cur = path.points[pi]
			start = cur
			pi += 1
			append(&out, make([dynamic]Seg, p.falloc))
			segs = &out[len(out) - 1]
		case .Line:
			q := path.points[pi]
			pi += 1
			if segs != nil do append(segs, Seg{p = {cur, cur + (q - cur) / 3, cur + (q - cur) * 2 / 3, q}})
			cur = q
		case .Quad:
			c, q := path.points[pi], path.points[pi + 1]
			pi += 2
			if segs != nil do append(segs, Seg{p = {cur, cur + (c - cur) * 2 / 3, q + (c - q) * 2 / 3, q}})
			cur = q
		case .Cubic:
			if segs != nil do append(segs, Seg{p = {cur, path.points[pi], path.points[pi + 1], path.points[pi + 2]}})
			cur = path.points[pi + 2]
			pi += 3
		case .Close:
			if segs != nil && cur != start do append(segs, Seg{p = {cur, cur + (start - cur) / 3, cur + (start - cur) * 2 / 3, start}})
			cur = start
		}
	}
	for &sl in out do for &s in sl do s.l = cubic_len(s.p)
	return out
}

// Emits the arc-length range [a, b] of the contour list (as one continuous run).
@(private)
emit_range :: proc(dst: ^vector.Path, contours: [][dynamic]Seg, a, b: f32) {
	pos: f32
	for sl in contours {
		started := false
		for s in sl {
			s0, s1 := pos, pos + s.l
			pos = s1
			lo := max(a, s0)
			hi := min(b, s1)
			if hi < lo || s.l <= 0 do continue
			u0 := cubic_param(s.p, lo - s0)
			u1 := cubic_param(s.p, hi - s0)
			piece := split_cubic(s.p, u0, u1)
			if !started {
				vector.path_move(dst, piece[0])
				started = true
			}
			vector.path_cubic(dst, piece[1], piece[2], piece[3])
		}
	}
}

@(private)
apply_trim :: proc(p: ^Player, it: ^Item, t: f32, geo: ^[dynamic]^Slot) {
	s := ev1(&it.t_start, t) / 100
	e := ev1(&it.t_end, t, 100) / 100
	o := ev1(&it.t_off, t) / 360
	if s > e do s, e = e, s
	s += o
	e += o
	if e - s >= 1 do return // full
	if e - s <= 0 {
		for sl in geo do sl.path = new_path(p)
		return
	}
	k := math.floor(s)
	s -= k
	e -= k
	// keep [lo, hi] (absolute lengths) of a contour list whose run is [base, base+len] of total
	keep :: proc(p: ^Player, cs: [][dynamic]Seg, base, length, a, b: f32, dst: ^vector.Path) {
		lo := max(a, base)
		hi := min(b, base + length)
		if hi > lo do emit_range(dst, cs, lo - base, hi - base)
	}
	if it.t_mode == 2 {
		// individually: the paths form one sequence
		segs := make([][dynamic][dynamic]Seg, len(geo), p.falloc)
		lens := make([]f32, len(geo), p.falloc)
		total: f32
		for sl, i in geo {
			segs[i] = path_segments(p, sl.path)
			for c in segs[i] do for sg in c do lens[i] += sg.l
			total += lens[i]
		}
		base: f32
		for sl, i in geo {
			dst := new_path(p)
			keep(p, segs[i][:], base, lens[i], s * total, min(e, 1) * total, dst)
			if e > 1 do keep(p, segs[i][:], base, lens[i], 0, (e - 1) * total, dst)
			sl.path = dst
			base += lens[i]
		}
		return
	}
	for sl in geo {
		cs := path_segments(p, sl.path)
		total: f32
		for c in cs do for sg in c do total += sg.l
		dst := new_path(p)
		keep(p, cs[:], 0, total, s * total, min(e, 1) * total, dst)
		if e > 1 do keep(p, cs[:], 0, total, 0, (e - 1) * total, dst)
		sl.path = dst
	}
}
