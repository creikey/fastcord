// Package lottie plays Lottie (bodymovin) JSON animations — Discord's standard
// stickers (format_type 3, discord.com/stickers/<id>.json) — rendering frames to
// RGBA through fc:vector's path rasterizer.
//
// Semantics follow lottie-web 5.12 (the official client renders stickers with
// lottie-web's SVG renderer): layer order / parenting / in-out points / start
// time, precomps, shape-item flow (styles paint the paths above them, groups
// nest, trim paths modify the paths above them), keyframes with bezier easing
// (per-dimension), hold keyframes and spatial bezier position paths, masks,
// track mattes (alpha / luma, inverted), solid layers, gradients.
// Not supported: expressions, effects, text/image/audio layers, time remap,
// merge paths (ignored, as lottie-web does), repeaters, dashes, blend modes,
// 3D, auto-orient.
package lottie

import "core:encoding/json"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"

Error :: enum u8 {
	None,
	Bad_Json,
	Unsupported,
	Out_Of_Memory,
}

// A keyframe: segment k -> k+1 is shaped by k's out (o) and in (i) easing.
Keyframe :: struct {
	t:      f32,
	s:      []f32,
	e:      []f32, // old-format explicit end value (else the next keyframe's s)
	hold:   bool,
	ox, oy: []f32, // easing, per dimension (len 1 = shared)
	ix, iy: []f32,
	to, ti: []f32, // spatial tangents (position paths)
}

Prop :: struct {
	value: []f32, // static value
	kfs:   []Keyframe,
}

Shape_Data :: struct {
	v, i, o: [][2]f32,
	closed:  bool,
}

Shape_Keyframe :: struct {
	t:      f32,
	s, e:   Shape_Data,
	has_e:  bool,
	hold:   bool,
	ox, oy: f32,
	ix, iy: f32,
}

Shape_Prop :: struct {
	value: Shape_Data,
	kfs:   []Shape_Keyframe,
}

Transform :: struct {
	a, p, s, r, o: Prop,
	px, py:        Prop,
	split:         bool,
	sk, sa:        Prop,
}

Item_Kind :: enum u8 {
	Ignore,
	Group,
	Path,
	Rect,
	Ellipse,
	Star,
	Fill,
	Stroke,
	Gradient_Fill,
	Gradient_Stroke,
	Trim,
}

Item :: struct {
	kind:     Item_Kind,
	hidden:   bool,
	items:    []Item, // group
	tr:       Transform, // group transform
	has_tr:   bool,
	shape:    Shape_Prop, // path
	reversed: bool, // d == 3
	// rect / ellipse / star
	p, size, r:                Prop,
	star_type:                 int,
	pt, ir, or_, is, os:       Prop,
	// styles
	color, opacity, width:     Prop,
	evenodd:                   bool,
	cap:                       int,
	join:                      int,
	miter:                     f32,
	// gradients
	grad_type:                 int, // 1 linear, 2 radial
	g_start, g_end, g_hl, g_ha: Prop,
	g_colors:                  Prop,
	g_count:                   int,
	// trim
	t_start, t_end, t_off:     Prop,
	t_mode:                    int, // 1 simultaneously, 2 individually
}

Mask :: struct {
	mode:     u8, // 'a' add 's' subtract 'i' intersect 'l' lighten 'd' darken 'f' difference 'n' none
	inverted: bool,
	path:     Shape_Prop,
	opacity:  Prop,
}

Layer :: struct {
	ty:          int, // 0 precomp, 1 solid, 2 image, 3 null, 4 shape, 5 text
	ind:         int,
	parent:      int, // ind of parent or -1
	ip, op, st:  f32,
	sr:          f32,
	ks:          Transform,
	shapes:      []Item,
	ref:         int, // precomp asset index or -1
	w, h:        f32, // precomp / solid size
	solid_color: [4]f32,
	td:          bool, // this layer is a track matte for the next layer
	tt:          int, // track matte type for this layer: 1 alpha 2 alpha-inv 3 luma 4 luma-inv
	hidden:      bool,
	masks:       []Mask,
}

Comp :: struct {
	id:     string,
	w, h:   f32,
	layers: []Layer,
}

Animation :: struct {
	w, h:    f32,
	fr:      f32,
	ip, op:  f32,
	root:    Comp,
	assets:  []Comp,
	arena:   virtual.Arena,
}

// ---------------------------------------------------------------------------
// Loading

@(private)
Loader :: struct {
	alloc:  mem.Allocator,
	assets: map[string]int,
}

load :: proc(data: []byte) -> (anim: ^Animation, err: Error) {
	anim = new(Animation)
	if virtual.arena_init_growing(&anim.arena) != nil {
		free(anim)
		return nil, .Out_Of_Memory
	}
	alloc := virtual.arena_allocator(&anim.arena)
	root, jerr := json.parse(data, .JSON, false, alloc)
	if jerr != .None {
		destroy(anim)
		return nil, .Bad_Json
	}
	obj, ok := root.(json.Object)
	if !ok {
		destroy(anim)
		return nil, .Bad_Json
	}
	L := Loader{alloc = alloc}
	L.assets = make(map[string]int, 8, alloc)
	anim.w = num(obj, "w", 512)
	anim.h = num(obj, "h", 512)
	anim.fr = num(obj, "fr", 60)
	anim.ip = num(obj, "ip", 0)
	anim.op = num(obj, "op", 60)
	if anim.fr <= 0 do anim.fr = 60
	// assets: precomps (index them first so layers can refer by id)
	if arr, aok := obj["assets"].(json.Array); aok {
		anim.assets = make([]Comp, len(arr), alloc)
		for a, i in arr {
			ao, _ := a.(json.Object)
			id := str(ao, "id")
			L.assets[id] = i
			anim.assets[i].id = id
		}
		for a, i in arr {
			ao, _ := a.(json.Object)
			anim.assets[i].w = num(ao, "w", anim.w)
			anim.assets[i].h = num(ao, "h", anim.h)
			if la, lok := ao["layers"].(json.Array); lok do anim.assets[i].layers = load_layers(&L, la)
		}
	}
	anim.root.w, anim.root.h = anim.w, anim.h
	if la, lok := obj["layers"].(json.Array); lok do anim.root.layers = load_layers(&L, la)
	return anim, .None
}

destroy :: proc(anim: ^Animation) {
	if anim == nil do return
	virtual.arena_destroy(&anim.arena)
	free(anim)
}

@(private)
num :: proc(o: json.Object, key: string, def: f32) -> f32 {
	v, ok := o[key]
	if !ok do return def
	return value_f32(v, def)
}

@(private)
value_f32 :: proc(v: json.Value, def: f32) -> f32 {
	#partial switch x in v {
	case json.Float:
		return f32(x)
	case json.Integer:
		return f32(x)
	case json.Boolean:
		return x ? 1 : 0
	case json.Array:
		if len(x) > 0 do return value_f32(x[0], def)
	}
	return def
}

@(private)
str :: proc(o: json.Object, key: string) -> string {
	if s, ok := o[key].(json.String); ok do return string(s)
	return ""
}

@(private)
floats :: proc(L: ^Loader, v: json.Value) -> []f32 {
	#partial switch x in v {
	case json.Array:
		out := make([]f32, len(x), L.alloc)
		for e, i in x do out[i] = value_f32(e, 0)
		return out
	case json.Float, json.Integer:
		out := make([]f32, 1, L.alloc)
		out[0] = value_f32(v, 0)
		return out
	}
	return nil
}

@(private)
load_prop :: proc(L: ^Loader, v: json.Value, def: []f32 = nil) -> Prop {
	o, ok := v.(json.Object)
	if !ok do return {value = def}
	k := o["k"]
	animated := num(o, "a", 0) == 1
	if arr, aok := k.(json.Array); aok && len(arr) > 0 {
		if _, isobj := arr[0].(json.Object); isobj do animated = true
	}
	if !animated do return {value = floats(L, k)}
	arr, _ := k.(json.Array)
	kfs := make([]Keyframe, len(arr), L.alloc)
	for e, i in arr {
		ko, _ := e.(json.Object)
		kf := &kfs[i]
		kf.t = num(ko, "t", 0)
		kf.s = floats(L, ko["s"])
		if ev, has := ko["e"]; has do kf.e = floats(L, ev)
		kf.hold = num(ko, "h", 0) == 1
		if oo, has := ko["o"].(json.Object); has {
			kf.ox = floats(L, oo["x"])
			kf.oy = floats(L, oo["y"])
		}
		if io, has := ko["i"].(json.Object); has {
			kf.ix = floats(L, io["x"])
			kf.iy = floats(L, io["y"])
		}
		if tv, has := ko["to"]; has do kf.to = floats(L, tv)
		if tv, has := ko["ti"]; has do kf.ti = floats(L, tv)
	}
	return {kfs = kfs}
}

@(private)
load_shape_data :: proc(L: ^Loader, v: json.Value) -> Shape_Data {
	o, ok := v.(json.Object)
	if !ok {
		if arr, aok := v.(json.Array); aok && len(arr) > 0 do return load_shape_data(L, arr[0])
		return {}
	}
	pts :: proc(L: ^Loader, v: json.Value) -> [][2]f32 {
		arr, _ := v.(json.Array)
		out := make([][2]f32, len(arr), L.alloc)
		for e, i in arr {
			p, _ := e.(json.Array)
			if len(p) >= 2 do out[i] = {value_f32(p[0], 0), value_f32(p[1], 0)}
		}
		return out
	}
	sd := Shape_Data {
		v      = pts(L, o["v"]),
		i      = pts(L, o["i"]),
		o      = pts(L, o["o"]),
		closed = num(o, "c", 0) == 1,
	}
	n := len(sd.v)
	if len(sd.i) < n || len(sd.o) < n {
		sd.i = make([][2]f32, n, L.alloc)
		sd.o = make([][2]f32, n, L.alloc)
	}
	return sd
}

@(private)
load_shape_prop :: proc(L: ^Loader, v: json.Value) -> Shape_Prop {
	o, ok := v.(json.Object)
	if !ok do return {}
	k := o["k"]
	arr, isarr := k.(json.Array)
	if !isarr || len(arr) == 0 do return {value = load_shape_data(L, k)}
	first, _ := arr[0].(json.Object)
	if _, has := first["t"]; !has do return {value = load_shape_data(L, k)}
	kfs := make([]Shape_Keyframe, len(arr), L.alloc)
	for e, i in arr {
		ko, _ := e.(json.Object)
		kf := &kfs[i]
		kf.t = num(ko, "t", 0)
		kf.s = load_shape_data(L, ko["s"])
		if ev, has := ko["e"]; has {
			kf.e = load_shape_data(L, ev)
			kf.has_e = true
		}
		kf.hold = num(ko, "h", 0) == 1
		kf.ox, kf.oy, kf.ix, kf.iy = 0, 0, 1, 1
		if oo, has := ko["o"].(json.Object); has {
			kf.ox = value_f32(oo["x"], 0)
			kf.oy = value_f32(oo["y"], 0)
		}
		if io, has := ko["i"].(json.Object); has {
			kf.ix = value_f32(io["x"], 1)
			kf.iy = value_f32(io["y"], 1)
		}
	}
	return {kfs = kfs}
}

@(private)
DEF_ONE := [?]f32{100, 100, 100}
@(private)
DEF_OPACITY := [?]f32{100}
@(private)
DEF_ZERO := [?]f32{0, 0, 0}

@(private)
load_transform :: proc(L: ^Loader, v: json.Value) -> Transform {
	o, _ := v.(json.Object)
	t := Transform {
		a  = load_prop(L, o["a"], DEF_ZERO[:]),
		s  = load_prop(L, o["s"], DEF_ONE[:]),
		o  = load_prop(L, o["o"], DEF_OPACITY[:]),
		sk = load_prop(L, o["sk"], DEF_ZERO[:1]),
		sa = load_prop(L, o["sa"], DEF_ZERO[:1]),
	}
	if rv, has := o["r"]; has {
		t.r = load_prop(L, rv, DEF_ZERO[:1])
	} else {
		t.r = load_prop(L, o["rz"], DEF_ZERO[:1])
	}
	pv, _ := o["p"].(json.Object)
	if num(pv, "s", 0) == 1 {
		t.split = true
		t.px = load_prop(L, pv["x"], DEF_ZERO[:1])
		t.py = load_prop(L, pv["y"], DEF_ZERO[:1])
	} else {
		t.p = load_prop(L, o["p"], DEF_ZERO[:])
	}
	return t
}

@(private)
load_items :: proc(L: ^Loader, arr: json.Array) -> []Item {
	out := make([dynamic]Item, 0, len(arr), L.alloc)
	for e in arr {
		o, ok := e.(json.Object)
		if !ok do continue
		it := Item {
			hidden = num(o, "hd", 0) == 1,
		}
		switch str(o, "ty") {
		case "gr":
			it.kind = .Group
			sub, _ := o["it"].(json.Array)
			// the group transform is the 'tr' item
			for s in sub {
				so, _ := s.(json.Object)
				if str(so, "ty") == "tr" {
					it.tr = load_transform(L, s)
					it.has_tr = true
				}
			}
			it.items = load_items(L, sub)
		case "sh":
			it.kind = .Path
			it.shape = load_shape_prop(L, o["ks"])
			it.reversed = num(o, "d", 1) == 3
		case "rc":
			it.kind = .Rect
			it.p = load_prop(L, o["p"], DEF_ZERO[:2])
			it.size = load_prop(L, o["s"], DEF_ZERO[:2])
			it.r = load_prop(L, o["r"], DEF_ZERO[:1])
			it.reversed = num(o, "d", 1) == 3
		case "el":
			it.kind = .Ellipse
			it.p = load_prop(L, o["p"], DEF_ZERO[:2])
			it.size = load_prop(L, o["s"], DEF_ZERO[:2])
			it.reversed = num(o, "d", 1) == 3
		case "sr":
			it.kind = .Star
			it.star_type = int(num(o, "sy", 1))
			it.p = load_prop(L, o["p"], DEF_ZERO[:2])
			it.pt = load_prop(L, o["pt"], DEF_ZERO[:1])
			it.r = load_prop(L, o["r"], DEF_ZERO[:1])
			it.or_ = load_prop(L, o["or"], DEF_ZERO[:1])
			it.os = load_prop(L, o["os"], DEF_ZERO[:1])
			it.ir = load_prop(L, o["ir"], DEF_ZERO[:1])
			it.is = load_prop(L, o["is"], DEF_ZERO[:1])
			it.reversed = num(o, "d", 1) == 3
		case "fl", "st", "gf", "gs":
			ty := str(o, "ty")
			it.kind = ty == "fl" ? .Fill : ty == "st" ? .Stroke : ty == "gf" ? .Gradient_Fill : .Gradient_Stroke
			it.color = load_prop(L, o["c"], DEF_ZERO[:])
			it.opacity = load_prop(L, o["o"], DEF_OPACITY[:])
			it.width = load_prop(L, o["w"], DEF_ZERO[:1])
			it.evenodd = num(o, "r", 1) == 2
			it.cap = int(num(o, "lc", 2))
			it.join = int(num(o, "lj", 2))
			it.miter = num(o, "ml", 4)
			if ty == "gf" || ty == "gs" {
				it.grad_type = int(num(o, "t", 1))
				it.g_start = load_prop(L, o["s"], DEF_ZERO[:2])
				it.g_end = load_prop(L, o["e"], DEF_ZERO[:2])
				it.g_hl = load_prop(L, o["h"], DEF_ZERO[:1])
				it.g_ha = load_prop(L, o["a"], DEF_ZERO[:1])
				if go, has := o["g"].(json.Object); has {
					it.g_count = int(num(go, "p", 0))
					it.g_colors = load_prop(L, go["k"])
				}
			}
		case "tm":
			it.kind = .Trim
			it.t_start = load_prop(L, o["s"], DEF_ZERO[:1])
			it.t_end = load_prop(L, o["e"], DEF_OPACITY[:])
			it.t_off = load_prop(L, o["o"], DEF_ZERO[:1])
			it.t_mode = int(num(o, "m", 1))
		case:
			continue // tr (handled by the group), mm, rp, ...
		}
		append(&out, it)
	}
	return out[:]
}

@(private)
load_layers :: proc(L: ^Loader, arr: json.Array) -> []Layer {
	out := make([]Layer, len(arr), L.alloc)
	for e, i in arr {
		o, _ := e.(json.Object)
		l := &out[i]
		l.ty = int(num(o, "ty", 3))
		l.ind = int(num(o, "ind", f32(i + 1)))
		l.parent = -1
		if pv, has := o["parent"]; has do l.parent = int(value_f32(pv, -1))
		l.ip = num(o, "ip", 0)
		l.op = num(o, "op", 1e9)
		l.st = num(o, "st", 0)
		l.sr = num(o, "sr", 1)
		if l.sr == 0 do l.sr = 1
		l.ks = load_transform(L, o["ks"])
		l.hidden = num(o, "hd", 0) == 1
		l.td = num(o, "td", 0) != 0
		l.tt = int(num(o, "tt", 0))
		l.ref = -1
		l.w = num(o, "w", 0)
		l.h = num(o, "h", 0)
		if r := str(o, "refId"); r != "" {
			if idx, ok := L.assets[r]; ok do l.ref = idx
		}
		if l.ty == 1 {
			l.w = num(o, "sw", 0)
			l.h = num(o, "sh", 0)
			l.solid_color = parse_hex(str(o, "sc"))
		}
		if sh, ok := o["shapes"].(json.Array); ok do l.shapes = load_items(L, sh)
		if ma, ok := o["masksProperties"].(json.Array); ok {
			l.masks = make([]Mask, len(ma), L.alloc)
			for m, j in ma {
				mo, _ := m.(json.Object)
				mode := str(mo, "mode")
				l.masks[j] = Mask {
					mode     = len(mode) > 0 ? mode[0] : 'a',
					inverted = num(mo, "inv", 0) == 1,
					path     = load_shape_prop(L, mo["pt"]),
					opacity  = load_prop(L, mo["o"], DEF_OPACITY[:]),
				}
			}
		}
	}
	return out
}

@(private)
parse_hex :: proc(s: string) -> [4]f32 {
	h := s
	if len(h) > 0 && h[0] == '#' do h = h[1:]
	if len(h) < 6 do return {0, 0, 0, 1}
	r, _ := strconv.parse_int(h[0:2], 16)
	g, _ := strconv.parse_int(h[2:4], 16)
	b, _ := strconv.parse_int(h[4:6], 16)
	return {f32(r) / 255, f32(g) / 255, f32(b) / 255, 1}
}

// ---------------------------------------------------------------------------
// Keyframe evaluation

// bezier_ease solves the CSS-style cubic bezier (0,0)-(x1,y1)-(x2,y2)-(1,1) at x.
@(private)
bezier_ease :: proc(x1, y1, x2, y2, x: f32) -> f32 {
	if x <= 0 do return 0
	if x >= 1 do return 1
	if x1 == y1 && x2 == y2 do return x
	bx :: proc(a, b, u: f32) -> f32 {return 3 * a * u * (1 - u) * (1 - u) + 3 * b * u * u * (1 - u) + u * u * u}
	dbx :: proc(a, b, u: f32) -> f32 {return 3 * a * (1 - u) * (1 - u) + 6 * (b - a) * u * (1 - u) + 3 * (1 - b) * u * u}
	u := x
	for _ in 0 ..< 8 {
		d := dbx(x1, x2, u)
		if abs(d) < 1e-6 do break
		e := bx(x1, x2, u) - x
		if abs(e) < 1e-7 do return bx(y1, y2, u)
		u -= e / d
	}
	if u < 0 || u > 1 || abs(bx(x1, x2, u) - x) > 1e-5 {
		lo, hi: f32 = 0, 1
		u = x
		for _ in 0 ..< 40 {
			v := bx(x1, x2, u)
			if abs(v - x) < 1e-7 do break
			if v < x do lo = u
			else do hi = u
			u = (lo + hi) / 2
		}
	}
	return bx(y1, y2, u)
}

@(private)
pick :: #force_inline proc(a: []f32, i: int, def: f32) -> f32 {
	if len(a) == 0 do return def
	return a[min(i, len(a) - 1)]
}

// eval writes the property value at frame t into out (returns dims).
eval :: proc(p: ^Prop, t: f32, out: []f32) -> int {
	if len(p.kfs) == 0 {
		n := min(len(p.value), len(out))
		copy(out, p.value[:n])
		return n
	}
	kfs := p.kfs
	if t <= kfs[0].t || len(kfs) == 1 {
		n := min(len(kfs[0].s), len(out))
		copy(out, kfs[0].s[:n])
		return n
	}
	k := 0
	for k + 1 < len(kfs) && t >= kfs[k + 1].t do k += 1
	a := &kfs[k]
	if k + 1 >= len(kfs) {
		// past the last keyframe: its start value (or the previous end value)
		src := len(a.s) > 0 ? a.s : (k > 0 && len(kfs[k - 1].e) > 0 ? kfs[k - 1].e : kfs[k - 1].s)
		n := min(len(src), len(out))
		copy(out, src[:n])
		return n
	}
	b := &kfs[k + 1]
	s := a.s
	e := len(a.e) > 0 ? a.e : b.s
	n := min(len(s), len(out))
	if a.hold || len(e) < n {
		copy(out, s[:n])
		return n
	}
	x := (t - a.t) / max(b.t - a.t, 1e-6)
	spatial := len(a.to) >= 2 && len(a.ti) >= 2 && n >= 2 && (a.to[0] != 0 || a.to[1] != 0 || a.ti[0] != 0 || a.ti[1] != 0)
	if spatial {
		u := bezier_ease(pick(a.ox, 0, 0), pick(a.oy, 0, 0), pick(a.ix, 0, 1), pick(a.iy, 0, 1), x)
		pt := spatial_point(s, e, a.to, a.ti, u)
		out[0], out[1] = pt.x, pt.y
		for d in 2 ..< n do out[d] = s[d] + (e[d] - s[d]) * u
		return n
	}
	for d in 0 ..< n {
		u := bezier_ease(pick(a.ox, d, 0), pick(a.oy, d, 0), pick(a.ix, d, 1), pick(a.iy, d, 1), x)
		out[d] = s[d] + (e[d] - s[d]) * u
	}
	return n
}

// Point at fraction u of the arc length of the bezier s -> e (lottie-web: 150-sample LUT).
@(private)
spatial_point :: proc(s, e, to, ti: []f32, u: f32) -> [2]f32 {
	p0 := [2]f32{s[0], s[1]}
	p3 := [2]f32{e[0], e[1]}
	p1 := p0 + {to[0], to[1]}
	p2 := p3 + {ti[0], ti[1]}
	bez :: proc(p0, p1, p2, p3: [2]f32, t: f32) -> [2]f32 {
		m := 1 - t
		return m * m * m * p0 + 3 * m * m * t * p1 + 3 * m * t * t * p2 + t * t * t * p3
	}
	N :: 150
	lens: [N + 1]f32
	prev := p0
	for i in 1 ..= N {
		q := bez(p0, p1, p2, p3, f32(i) / N)
		d := q - prev
		lens[i] = lens[i - 1] + math.sqrt(d.x * d.x + d.y * d.y)
		prev = q
	}
	total := lens[N]
	if total <= 0 do return p0 + (p3 - p0) * u
	target := clamp(u, 0, 1) * total
	if u >= 1 do return p3
	if u <= 0 do return p0
	for i in 1 ..= N {
		if lens[i] >= target {
			seg := lens[i] - lens[i - 1]
			f := seg > 0 ? (target - lens[i - 1]) / seg : 0
			a := bez(p0, p1, p2, p3, f32(i - 1) / N)
			b := bez(p0, p1, p2, p3, f32(i) / N)
			return a + (b - a) * f
		}
	}
	return p3
}

// eval_shape returns the path at frame t (vertex arrays allocated with alloc when interpolated).
eval_shape :: proc(p: ^Shape_Prop, t: f32, alloc: mem.Allocator) -> Shape_Data {
	if len(p.kfs) == 0 do return p.value
	kfs := p.kfs
	if t <= kfs[0].t || len(kfs) == 1 do return kfs[0].s
	k := 0
	for k + 1 < len(kfs) && t >= kfs[k + 1].t do k += 1
	a := &kfs[k]
	if k + 1 >= len(kfs) {
		if len(a.s.v) > 0 do return a.s
		return k > 0 && kfs[k - 1].has_e ? kfs[k - 1].e : kfs[k - 1].s
	}
	b := &kfs[k + 1]
	e := a.has_e ? a.e : b.s
	s := a.s
	if a.hold || len(e.v) != len(s.v) do return s
	x := (t - a.t) / max(b.t - a.t, 1e-6)
	u := bezier_ease(a.ox, a.oy, a.ix, a.iy, x)
	n := len(s.v)
	out := Shape_Data {
		v      = make([][2]f32, n, alloc),
		i      = make([][2]f32, n, alloc),
		o      = make([][2]f32, n, alloc),
		closed = s.closed,
	}
	for j in 0 ..< n {
		out.v[j] = s.v[j] + (e.v[j] - s.v[j]) * u
		out.i[j] = s.i[j] + (e.i[j] - s.i[j]) * u
		out.o[j] = s.o[j] + (e.o[j] - s.o[j]) * u
	}
	return out
}
