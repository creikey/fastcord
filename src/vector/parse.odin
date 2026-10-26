package vector

import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"

@(private)
Paint_Type :: enum u8 {
	None,
	Current,
	Color,
}

@(private)
Paint :: struct {
	type:     Paint_Type,
	color:    [4]u8,
	gradient: bool,
	grad:     i32, // index into Icon.gradients (valid when gradient)
}

@(private)
Style :: struct {
	fill, stroke:   Paint,
	fill_rule:      Fill_Rule,
	clip_rule:      Fill_Rule,
	fill_opacity:   f32,
	stroke_opacity: f32,
	opacity:        f32, // product of ancestor `opacity`
	stroke_width:   f32,
	miter_limit:    f32,
	cap:            Line_Cap,
	join:           Line_Join,
	secondary:      bool,
	mask, clip:     i32, // this element's own mask / clip-path
	anc_mask:       i32, // nearest ancestor group's mask / clip-path (applied in anc_ctm space)
	anc_clip:       i32,
	anc_ctm:        Mat,
}

@(private)
DEFAULT_STYLE :: Style {
	fill           = {type = .Color, color = {0, 0, 0, 255}},
	fill_opacity   = 1,
	stroke_opacity = 1,
	opacity        = 1,
	stroke_width   = 1,
	miter_limit    = 4,
	mask           = -1,
	clip           = -1,
	anc_mask       = -1,
	anc_clip       = -1,
	anc_ctm        = MAT_IDENTITY,
}

@(private)
Parser :: struct {
	doc:       Doc,
	icon:      ^Icon,
	groups:    map[i32]i32, // mask/clip node -> group index (-2 = in progress)
	grads:     map[i32]i32, // gradient node -> index in icon.gradients
	depth:     int,
	allocator: mem.Allocator, // the icon's allocator
}

// parse_svg parses an SVG document into a resolution-independent Icon.
parse_svg :: proc(src: string, allocator := context.allocator) -> (icon: Icon, ok: bool) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return {}, false
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)

	p := Parser{icon = &icon, allocator = allocator}
	if !xml_parse(src, &p.doc, scratch) do return {}, false
	p.groups = make(map[i32]i32, 8, scratch)
	p.grads = make(map[i32]i32, 8, scratch)
	icon.verbs = make([dynamic]Verb, allocator)
	icon.points = make([dynamic][2]f32, allocator)
	icon.ops = make([dynamic]Op, allocator)
	icon.groups = make([dynamic]Group, allocator)
	icon.gradients = make([dynamic]Gradient, allocator)

	root := p.doc.nodes[0].first_child
	for root >= 0 && p.doc.nodes[root].name != "svg" do root = p.doc.nodes[root].next
	if root < 0 {
		destroy(&icon)
		return {}, false
	}
	context.allocator = scratch
	if vb, has := attr(&p.doc, root, "viewBox"); has {
		nums: [4]f32
		sc := Scanner{s = vb}
		got := 0
		for got < 4 {
			v, nok := scan_number(&sc)
			if !nok do break
			nums[got] = v
			got += 1
		}
		if got == 4 && nums[2] > 0 && nums[3] > 0 do icon.view_box = nums
	}
	if icon.view_box[2] <= 0 {
		w := attr_length(&p, root, "width", 0)
		h := attr_length(&p, root, "height", 0)
		icon.view_box = {0, 0, w > 0 ? w : 24, h > 0 ? h : 24}
	}
	st := DEFAULT_STYLE
	apply_style(&p, root, &st)
	walk_children(&p, root, MAT_IDENTITY, st, -1)
	return icon, true
}

@(private)
walk_children :: proc(p: ^Parser, ni: i32, ctm: Mat, st: Style, group: i32) {
	c := p.doc.nodes[ni].first_child
	for c >= 0 {
		walk(p, c, ctm, st, group)
		c = p.doc.nodes[c].next
	}
}

@(private)
walk :: proc(p: ^Parser, ni: i32, parent_ctm: Mat, parent_st: Style, group: i32) {
	if p.depth > 64 do return
	p.depth += 1
	defer p.depth -= 1
	name := local_name(p.doc.nodes[ni].name)
	switch name {
	case "defs", "mask", "clipPath", "linearGradient", "radialGradient", "symbol", "style", "title", "desc", "metadata", "pattern", "filter", "marker", "text":
		return
	}
	if v, has := attr(&p.doc, ni, "display"); has && v == "none" do return
	st := parent_st
	apply_style(p, ni, &st)
	ctm := parent_ctm
	if t, has := attr(&p.doc, ni, "transform"); has do ctm = mat_mul(ctm, parse_transform(t))

	switch name {
	case "svg", "g", "a", "switch":
		if name == "svg" && ni != p.doc.nodes[0].first_child {
			// Nested viewport: translate(x, y) then map its viewBox onto width x height.
			x := attr_length(p, ni, "x", 0)
			y := attr_length(p, ni, "y", 0)
			ctm = mat_mul(ctm, {1, 0, 0, 1, x, y})
			if vb, has := attr(&p.doc, ni, "viewBox"); has {
				nums: [4]f32
				sc := Scanner{s = vb}
				got := 0
				for got < 4 {
					v, nok := scan_number(&sc)
					if !nok do break
					nums[got] = v
					got += 1
				}
				w := attr_length(p, ni, "width", nums[2])
				h := attr_length(p, ni, "height", nums[3])
				if got == 4 && nums[2] > 0 && nums[3] > 0 {
					sx := w / nums[2]
					sy := h / nums[3]
					tx, ty: f32
					if par, _ := attr(&p.doc, ni, "preserveAspectRatio"); !strings.has_prefix(par, "none") {
						s := min(sx, sy) // xMidYMid meet
						tx = (w - nums[2] * s) / 2
						ty = (h - nums[3] * s) / 2
						sx = s
						sy = s
					}
					ctm = mat_mul(ctm, {sx, 0, 0, sy, tx - nums[0] * sx, ty - nums[1] * sy})
				}
			}
		}
		cst := st
		if st.clip >= 0 || st.mask >= 0 {
			// a group's clip/mask applies to every descendant, in the group's user space
			if st.clip >= 0 do cst.anc_clip = st.clip
			if st.mask >= 0 do cst.anc_mask = st.mask
			cst.anc_ctm = ctm
		}
		walk_children(p, ni, ctm, cst, group)
	case "use":
		href, has := attr(&p.doc, ni, "href")
		if !has do href, has = attr(&p.doc, ni, "xlink:href")
		if !has || !strings.has_prefix(href, "#") do return
		ref, found := p.doc.ids[href[1:]]
		if !found do return
		x := attr_length(p, ni, "x", 0)
		y := attr_length(p, ni, "y", 0)
		walk(p, ref, mat_mul(ctm, {1, 0, 0, 1, x, y}), st, group)
	case "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
		emit_shape(p, ni, name, ctm, st, group)
	}
}

@(private)
local_name :: proc(s: string) -> string {
	if i := strings.index_byte(s, ':'); i >= 0 do return s[i + 1:]
	return s
}

@(private)
apply_style :: proc(p: ^Parser, ni: i32, st: ^Style) {
	st.mask = -1 // mask/clip-path are not inherited; groups pass theirs down below
	st.clip = -1
	for a in p.doc.nodes[ni].attrs do style_prop(p, st, a.name, a.value)
	if s, has := attr(&p.doc, ni, "style"); has {
		for decl in strings.split_iterator(&s, ";") {
			c := strings.index_byte(decl, ':')
			if c < 0 do continue
			style_prop(p, st, strings.trim_space(decl[:c]), strings.trim_space(decl[c + 1:]))
		}
	}
}

@(private)
style_prop :: proc(p: ^Parser, st: ^Style, name, value: string) {
	switch name {
	case "fill":
		st.fill = parse_paint(p, value, st.fill)
	case "stroke":
		st.stroke = parse_paint(p, value, st.stroke)
	case "fill-rule":
		st.fill_rule = value == "evenodd" ? .Evenodd : .Nonzero
	case "clip-rule":
		st.clip_rule = value == "evenodd" ? .Evenodd : .Nonzero
	case "fill-opacity":
		st.fill_opacity = parse_opacity(value)
	case "stroke-opacity":
		st.stroke_opacity = parse_opacity(value)
	case "opacity":
		st.opacity *= parse_opacity(value)
	case "stroke-width":
		sc := Scanner{s = value}
		if v, ok := scan_number(&sc); ok do st.stroke_width = v
	case "stroke-miterlimit":
		sc := Scanner{s = value}
		if v, ok := scan_number(&sc); ok do st.miter_limit = max(v, 1)
	case "stroke-linecap":
		switch value {
		case "round":
			st.cap = .Round
		case "square":
			st.cap = .Square
		case:
			st.cap = .Butt
		}
	case "stroke-linejoin":
		switch value {
		case "round":
			st.join = .Round
		case "bevel":
			st.join = .Bevel
		case:
			st.join = .Miter
		}
	case "class":
		cls := value
		for c in strings.fields_iterator(&cls) {
			if c == "secondary" do st.secondary = true
		}
	case "mask":
		st.mask = resolve_group(p, value, .Mask)
	case "clip-path":
		st.clip = resolve_group(p, value, .Clip)
	}
}

@(private)
parse_opacity :: proc(v: string) -> f32 {
	sc := Scanner{s = v}
	x, ok := scan_number(&sc)
	if !ok do return 1
	if sc.i < len(v) && v[sc.i] == '%' do x /= 100
	return clamp(x, 0, 1)
}

@(private)
url_id :: proc(v: string) -> (string, bool) {
	s := strings.trim_space(v)
	if !strings.has_prefix(s, "url(") do return "", false
	e := strings.index_byte(s, ')')
	if e < 0 do return "", false
	id := strings.trim(s[4:e], " '\"")
	if !strings.has_prefix(id, "#") do return "", false
	return id[1:], true
}

@(private)
parse_paint :: proc(p: ^Parser, v: string, inherited: Paint) -> Paint {
	s := strings.trim_space(v)
	switch s {
	case "none", "transparent":
		return {type = .None}
	case "currentColor", "currentcolor":
		return {type = .Current}
	case "inherit":
		return inherited
	}
	if id, ok := url_id(s); ok {
		ref, found := p.doc.ids[id]
		if !found do return {type = .None}
		gi := build_gradient(p, ref)
		if gi < 0 do return {type = .None}
		g := &p.icon.gradients[gi]
		if len(g.stops) == 0 do return {type = .None}
		sum: [4]f32
		for st in g.stops do sum += st.color
		avg := sum / f32(len(g.stops))
		out := Paint{type = .Color, gradient = true, grad = gi}
		for j in 0 ..< 4 do out.color[j] = u8(clamp(avg[j], 0, 1) * 255 + 0.5)
		return out
	}
	return {type = .Color, color = parse_color(s)}
}

@(private)
parse_color :: proc(v: string) -> [4]u8 {
	s := strings.trim_space(v)
	hex :: proc(c: u8) -> u8 {
		switch c {
		case '0' ..= '9':
			return c - '0'
		case 'a' ..= 'f':
			return c - 'a' + 10
		case 'A' ..= 'F':
			return c - 'A' + 10
		}
		return 0
	}
	if strings.has_prefix(s, "#") {
		h := s[1:]
		switch len(h) {
		case 3, 4:
			out := [4]u8{0, 0, 0, 255}
			for j in 0 ..< len(h) do out[j] = hex(h[j]) * 17
			return out
		case 6, 8:
			out := [4]u8{0, 0, 0, 255}
			for j in 0 ..< len(h) / 2 do out[j] = hex(h[2 * j]) << 4 | hex(h[2 * j + 1])
			return out
		}
		return {0, 0, 0, 255}
	}
	if strings.has_prefix(s, "rgb") {
		o := strings.index_byte(s, '(')
		if o >= 0 {
			sc := Scanner{s = s[o + 1:]}
			out := [4]u8{0, 0, 0, 255}
			for j in 0 ..< 4 {
				x, ok := scan_number(&sc)
				if !ok do break
				pct := sc.i < len(sc.s) && sc.s[sc.i] == '%'
				if pct do sc.i += 1
				if j == 3 {
					out[3] = u8(clamp(pct ? x / 100 : x, 0, 1) * 255 + 0.5)
				} else {
					out[j] = u8(clamp(pct ? x * 2.55 : x, 0, 255) + 0.5)
				}
			}
			return out
		}
	}
	switch strings.to_lower(s, context.temp_allocator) {
	case "white":
		return {255, 255, 255, 255}
	case "red":
		return {255, 0, 0, 255}
	case "green":
		return {0, 128, 0, 255}
	case "blue":
		return {0, 0, 255, 255}
	case "gray", "grey":
		return {128, 128, 128, 255}
	}
	return {0, 0, 0, 255}
}

@(private)
luminance :: proc(c: [4]u8) -> f32 {
	// mask-type: luminance (linearRGB coefficients on sRGB values, as browsers do).
	return (0.2125 * f32(c[0]) + 0.7154 * f32(c[1]) + 0.0721 * f32(c[2])) / 255 * f32(c[3]) / 255
}

// attr_length parses a length attribute; % is relative to the root view box.
@(private)
attr_length :: proc(p: ^Parser, ni: i32, name: string, def: f32) -> f32 {
	v, has := attr(&p.doc, ni, name)
	if !has do return def
	sc := Scanner{s = v}
	x, ok := scan_number(&sc)
	if !ok do return def
	if sc.i < len(v) && v[sc.i] == '%' {
		vb := p.icon.view_box
		ref := vb[2] > 0 ? (name == "x" || name == "width" || name == "cx" || name == "rx" || name == "x1" || name == "x2" ? vb[2] : vb[3]) : 0
		return x / 100 * ref
	}
	return x
}

@(private)
resolve_group :: proc(p: ^Parser, v: string, kind: Group_Kind) -> i32 {
	id, ok := url_id(v)
	if !ok do return -1
	ni, found := p.doc.ids[id]
	if !found do return -1
	want := kind == .Mask ? "mask" : "clipPath"
	if local_name(p.doc.nodes[ni].name) != want do return -1
	if gi, cached := p.groups[ni]; cached do return gi < 0 ? -1 : gi
	p.groups[ni] = -2 // recursion guard
	gi := i32(len(p.icon.groups))
	g := Group {
		kind = kind,
	}
	if kind == .Mask {
		units, _ := attr(&p.doc, ni, "maskUnits")
		cunits, _ := attr(&p.doc, ni, "maskContentUnits")
		g.region_bbox_units = units != "userSpaceOnUse"
		g.content_bbox_units = cunits == "objectBoundingBox"
		frac :: proc(p: ^Parser, ni: i32, name: string, def: f32) -> f32 {
			v, has := attr(&p.doc, ni, name)
			if !has do return def
			sc := Scanner{s = v}
			x, ok := scan_number(&sc)
			if !ok do return def
			if sc.i < len(v) && v[sc.i] == '%' do x /= 100
			return x
		}
		if g.region_bbox_units {
			g.region = {frac(p, ni, "x", -0.1), frac(p, ni, "y", -0.1), frac(p, ni, "width", 1.2), frac(p, ni, "height", 1.2)}
		} else {
			vb := p.icon.view_box
			g.region = {
				attr_length(p, ni, "x", vb[0] - 0.1 * vb[2]),
				attr_length(p, ni, "y", vb[1] - 0.1 * vb[3]),
				attr_length(p, ni, "width", 1.2 * vb[2]),
				attr_length(p, ni, "height", 1.2 * vb[3]),
			}
		}
	} else {
		units, _ := attr(&p.doc, ni, "clipPathUnits")
		g.content_bbox_units = units == "objectBoundingBox"
	}
	append(&p.icon.groups, g)
	ctm := MAT_IDENTITY
	if t, has := attr(&p.doc, ni, "transform"); has && kind == .Clip do ctm = parse_transform(t)
	st := DEFAULT_STYLE
	saved := p.depth
	walk_children(p, ni, ctm, st, gi)
	p.depth = saved
	p.groups[ni] = gi
	return gi
}

@(private)
emit_shape :: proc(p: ^Parser, ni: i32, name: string, ctm: Mat, st: Style, group: i32) {
	icon := p.icon
	fv := i32(len(icon.verbs))
	fp := i32(len(icon.points))
	b := Builder{icon = icon}
	switch name {
	case "path":
		if d, has := attr(&p.doc, ni, "d"); has do parse_path(&b, d)
	case "rect":
		x := attr_length(p, ni, "x", 0)
		y := attr_length(p, ni, "y", 0)
		w := attr_length(p, ni, "width", 0)
		h := attr_length(p, ni, "height", 0)
		if w <= 0 || h <= 0 do return
		_, has_rx := attr(&p.doc, ni, "rx")
		_, has_ry := attr(&p.doc, ni, "ry")
		rx := attr_length(p, ni, "rx", 0)
		ry := attr_length(p, ni, "ry", 0)
		if has_rx && !has_ry do ry = rx
		if has_ry && !has_rx do rx = ry
		rx = clamp(rx, 0, w / 2)
		ry = clamp(ry, 0, h / 2)
		add_round_rect(&b, x, y, w, h, rx, ry)
	case "circle":
		r := attr_length(p, ni, "r", 0)
		if r <= 0 do return
		add_ellipse(&b, attr_length(p, ni, "cx", 0), attr_length(p, ni, "cy", 0), r, r)
	case "ellipse":
		rx := attr_length(p, ni, "rx", 0)
		ry := attr_length(p, ni, "ry", 0)
		if rx <= 0 || ry <= 0 do return
		add_ellipse(&b, attr_length(p, ni, "cx", 0), attr_length(p, ni, "cy", 0), rx, ry)
	case "line":
		move_to(&b, {attr_length(p, ni, "x1", 0), attr_length(p, ni, "y1", 0)})
		line_to(&b, {attr_length(p, ni, "x2", 0), attr_length(p, ni, "y2", 0)})
	case "polyline", "polygon":
		pts, _ := attr(&p.doc, ni, "points")
		sc := Scanner{s = pts}
		first := true
		for {
			x, okx := scan_number(&sc)
			if !okx do break
			y, oky := scan_number(&sc)
			if !oky do break
			if first do move_to(&b, {x, y})
			else do line_to(&b, {x, y})
			first = false
		}
		if name == "polygon" && !first do close_path(&b)
	}
	vc := i32(len(icon.verbs)) - fv
	if vc == 0 do return
	bbox := [4]f32{max(f32), max(f32), -max(f32), -max(f32)}
	for &pt in icon.points[fp:] {
		bbox = {min(bbox[0], pt.x), min(bbox[1], pt.y), max(bbox[2], pt.x), max(bbox[3], pt.y)}
		pt = mat_apply(ctm, pt)
	}
	if bbox[0] > bbox[2] do bbox = {}
	mask := st.mask >= 0 ? st.mask : -1
	clip := st.clip >= 0 ? st.clip : -1
	in_clip := group >= 0 && icon.groups[group].kind == .Clip
	base := Op {
		first_verb  = fv,
		verb_count  = vc,
		first_point = fp,
		layer       = st.secondary ? .Secondary : .Primary,
		cap         = st.cap,
		join        = st.join,
		miter_limit = st.miter_limit,
		group       = group,
		mask        = mask,
		clip        = clip,
		ctm         = ctm,
		bbox        = bbox,
		gradient    = -1,
		anc_mask    = st.anc_mask,
		anc_clip    = st.anc_clip,
		anc_ctm     = st.anc_ctm,
	}
	if st.secondary do icon.has_secondary = true
	if in_clip {
		op := base
		op.kind = .Fill
		op.rule = st.clip_rule
		op.alpha = 1
		op.luminance = 1
		op.current_color = true
		append(&icon.ops, op)
		return
	}
	add_paint :: proc(icon: ^Icon, base: Op, kind: Paint_Kind, paint: Paint, alpha: f32, st: Style) {
		if paint.type == .None || alpha <= 0 do return
		op := base
		op.kind = kind
		op.rule = st.fill_rule
		op.alpha = alpha
		op.stroke_width = st.stroke_width
		if paint.type == .Current {
			op.current_color = true
			op.luminance = 0 // currentColor defaults to black
		} else {
			op.color = paint.color
			op.alpha *= f32(paint.color[3]) / 255
			if paint.gradient {
				op.gradient = paint.grad
				op.grad_fold = f32(paint.color[3]) / 255
			}
			c := paint.color
			c[3] = 255
			op.luminance = luminance(c)
			if op.group < 0 do icon.multicolor = true
		}
		append(&icon.ops, op)
	}
	add_paint(icon, base, .Fill, st.fill, st.fill_opacity * st.opacity, st)
	if st.stroke_width > 0 do add_paint(icon, base, .Stroke, st.stroke, st.stroke_opacity * st.opacity, st)
}

// ---- path building ----

@(private)
Builder :: struct {
	icon:      ^Icon,
	start:     [2]f32,
	cur:       [2]f32,
	ctrl:      [2]f32, // last control point (for S / T reflection)
	last:      u8, // last command, upper-cased
	open:      bool, // a subpath has been started
	need_move: bool, // after Z: implicit moveto to start
}

@(private)
move_to :: proc(b: ^Builder, p: [2]f32) {
	append(&b.icon.verbs, Verb.Move)
	append(&b.icon.points, p)
	b.start = p
	b.cur = p
	b.open = true
	b.need_move = false
}

@(private)
ensure_move :: proc(b: ^Builder) {
	if !b.open || b.need_move do move_to(b, b.cur)
}

@(private)
line_to :: proc(b: ^Builder, p: [2]f32) {
	ensure_move(b)
	append(&b.icon.verbs, Verb.Line)
	append(&b.icon.points, p)
	b.cur = p
}

@(private)
quad_to :: proc(b: ^Builder, c, p: [2]f32) {
	ensure_move(b)
	append(&b.icon.verbs, Verb.Quad)
	append(&b.icon.points, c, p)
	b.cur = p
}

@(private)
cubic_to :: proc(b: ^Builder, c1, c2, p: [2]f32) {
	ensure_move(b)
	append(&b.icon.verbs, Verb.Cubic)
	append(&b.icon.points, c1, c2, p)
	b.cur = p
}

@(private)
close_path :: proc(b: ^Builder) {
	if !b.open || b.need_move do return
	append(&b.icon.verbs, Verb.Close)
	b.cur = b.start
	b.need_move = true
}

@(private)
KAPPA :: 0.5522847498

@(private)
add_ellipse :: proc(b: ^Builder, cx, cy, rx, ry: f32) {
	kx := rx * KAPPA
	ky := ry * KAPPA
	move_to(b, {cx + rx, cy})
	cubic_to(b, {cx + rx, cy + ky}, {cx + kx, cy + ry}, {cx, cy + ry})
	cubic_to(b, {cx - kx, cy + ry}, {cx - rx, cy + ky}, {cx - rx, cy})
	cubic_to(b, {cx - rx, cy - ky}, {cx - kx, cy - ry}, {cx, cy - ry})
	cubic_to(b, {cx + kx, cy - ry}, {cx + rx, cy - ky}, {cx + rx, cy})
	close_path(b)
}

@(private)
add_round_rect :: proc(b: ^Builder, x, y, w, h, rx, ry: f32) {
	if rx <= 0 || ry <= 0 {
		move_to(b, {x, y})
		line_to(b, {x + w, y})
		line_to(b, {x + w, y + h})
		line_to(b, {x, y + h})
		close_path(b)
		return
	}
	kx := rx * (1 - KAPPA)
	ky := ry * (1 - KAPPA)
	r := x + w
	btm := y + h
	move_to(b, {x + rx, y})
	line_to(b, {r - rx, y})
	cubic_to(b, {r - kx, y}, {r, y + ky}, {r, y + ry})
	line_to(b, {r, btm - ry})
	cubic_to(b, {r, btm - ky}, {r - kx, btm}, {r - rx, btm})
	line_to(b, {x + rx, btm})
	cubic_to(b, {x + kx, btm}, {x, btm - ky}, {x, btm - ry})
	line_to(b, {x, y + ry})
	cubic_to(b, {x, y + ky}, {x + kx, y}, {x + rx, y})
	close_path(b)
}

// arc_to appends an SVG elliptical arc (endpoint parameterization) as cubics.
@(private)
arc_to :: proc(b: ^Builder, rx_in, ry_in, phi_deg: f32, large, sweep: bool, p: [2]f32) {
	p0 := b.cur
	if p0 == p do return
	rx := abs(f64(rx_in))
	ry := abs(f64(ry_in))
	if rx == 0 || ry == 0 {
		line_to(b, p)
		return
	}
	phi := f64(phi_deg) * math.PI / 180
	cs := math.cos(phi)
	sn := math.sin(phi)
	x1 := f64(p0.x)
	y1 := f64(p0.y)
	x2 := f64(p.x)
	y2 := f64(p.y)
	dx2 := (x1 - x2) / 2
	dy2 := (y1 - y2) / 2
	x1p := cs * dx2 + sn * dy2
	y1p := -sn * dx2 + cs * dy2
	lambda := x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
	if lambda > 1 {
		s := math.sqrt(lambda)
		rx *= s
		ry *= s
	}
	num := rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
	den := rx * rx * y1p * y1p + ry * ry * x1p * x1p
	coef := den > 0 ? math.sqrt(max(0, num / den)) : 0
	if large == sweep do coef = -coef
	cxp := coef * rx * y1p / ry
	cyp := -coef * ry * x1p / rx
	cx := cs * cxp - sn * cyp + (x1 + x2) / 2
	cy := sn * cxp + cs * cyp + (y1 + y2) / 2
	angle :: proc(ux, uy, vx, vy: f64) -> f64 {
		return math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
	}
	ux := (x1p - cxp) / rx
	uy := (y1p - cyp) / ry
	vx := (-x1p - cxp) / rx
	vy := (-y1p - cyp) / ry
	theta1 := angle(1, 0, ux, uy)
	dtheta := angle(ux, uy, vx, vy)
	if !sweep && dtheta > 0 do dtheta -= 2 * math.PI
	if sweep && dtheta < 0 do dtheta += 2 * math.PI
	n := max(1, int(math.ceil(abs(dtheta) / (math.PI / 2) - 1e-9)))
	d := dtheta / f64(n)
	k := 4.0 / 3.0 * math.tan(d / 4)
	ept :: proc(cx, cy, rx, ry, cs, sn, t: f64) -> [2]f64 {
		return {cx + rx * math.cos(t) * cs - ry * math.sin(t) * sn, cy + rx * math.cos(t) * sn + ry * math.sin(t) * cs}
	}
	eder :: proc(rx, ry, cs, sn, t: f64) -> [2]f64 {
		return {-rx * math.sin(t) * cs - ry * math.cos(t) * sn, -rx * math.sin(t) * sn + ry * math.cos(t) * cs}
	}
	for i in 0 ..< n {
		t1 := theta1 + f64(i) * d
		t2 := t1 + d
		a := ept(cx, cy, rx, ry, cs, sn, t1)
		e := ept(cx, cy, rx, ry, cs, sn, t2)
		da := eder(rx, ry, cs, sn, t1)
		de := eder(rx, ry, cs, sn, t2)
		c1 := a + k * da
		c2 := e - k * de
		end := i == n - 1 ? p : [2]f32{f32(e.x), f32(e.y)}
		cubic_to(b, {f32(c1.x), f32(c1.y)}, {f32(c2.x), f32(c2.y)}, end)
	}
}

// ---- number scanning ----

@(private)
Scanner :: struct {
	s: string,
	i: int,
}

@(private)
skip_sep :: proc(sc: ^Scanner) {
	for sc.i < len(sc.s) && is_space(sc.s[sc.i]) do sc.i += 1
	if sc.i < len(sc.s) && sc.s[sc.i] == ',' {
		sc.i += 1
		for sc.i < len(sc.s) && is_space(sc.s[sc.i]) do sc.i += 1
	}
}

@(private)
scan_number :: proc(sc: ^Scanner) -> (f32, bool) {
	skip_sep(sc)
	s := sc.s
	i := sc.i
	st := i
	if i < len(s) && (s[i] == '+' || s[i] == '-') do i += 1
	digits := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i += 1
		digits += 1
	}
	if i < len(s) && s[i] == '.' {
		i += 1
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i += 1
			digits += 1
		}
	}
	if digits == 0 do return 0, false
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		j := i + 1
		if j < len(s) && (s[j] == '+' || s[j] == '-') do j += 1
		if j < len(s) && s[j] >= '0' && s[j] <= '9' {
			for j < len(s) && s[j] >= '0' && s[j] <= '9' do j += 1
			i = j
		}
	}
	v, ok := strconv.parse_f64(s[st:i])
	if !ok do return 0, false
	sc.i = i
	return f32(v), true
}

@(private)
scan_flag :: proc(sc: ^Scanner) -> (bool, bool) {
	skip_sep(sc)
	if sc.i < len(sc.s) && (sc.s[sc.i] == '0' || sc.s[sc.i] == '1') {
		f := sc.s[sc.i] == '1'
		sc.i += 1
		return f, true
	}
	return false, false
}

// parse_path appends path data; on a syntax error the path so far is kept (as browsers do).
@(private)
parse_path :: proc(b: ^Builder, d: string) {
	sc := Scanner{s = d}
	cmd: u8 = 0
	for {
		skip_sep(&sc)
		if sc.i >= len(d) do return
		c := d[sc.i]
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') {
			cmd = c
			sc.i += 1
		} else if cmd == 0 || cmd == 'Z' || cmd == 'z' {
			return
		}
		rel := cmd >= 'a'
		up := rel ? cmd - 32 : cmd
		o := rel ? b.cur : [2]f32{0, 0}
		num :: proc(sc: ^Scanner, ok: ^bool) -> f32 {
			v, k := scan_number(sc)
			if !k do ok^ = false
			return v
		}
		ok := true
		switch up {
		case 'M':
			x := num(&sc, &ok)
			y := num(&sc, &ok)
			if !ok do return
			move_to(b, o + {x, y})
			cmd = rel ? 'l' : 'L'
		case 'L':
			x := num(&sc, &ok)
			y := num(&sc, &ok)
			if !ok do return
			line_to(b, o + {x, y})
		case 'H':
			x := num(&sc, &ok)
			if !ok do return
			line_to(b, {rel ? b.cur.x + x : x, b.cur.y})
		case 'V':
			y := num(&sc, &ok)
			if !ok do return
			line_to(b, {b.cur.x, rel ? b.cur.y + y : y})
		case 'C':
			x1 := num(&sc, &ok)
			y1 := num(&sc, &ok)
			x2 := num(&sc, &ok)
			y2 := num(&sc, &ok)
			x := num(&sc, &ok)
			y := num(&sc, &ok)
			if !ok do return
			c2 := o + {x2, y2}
			cubic_to(b, o + {x1, y1}, c2, o + {x, y})
			b.ctrl = c2
		case 'S':
			x2 := num(&sc, &ok)
			y2 := num(&sc, &ok)
			x := num(&sc, &ok)
			y := num(&sc, &ok)
			if !ok do return
			c1 := b.last == 'C' || b.last == 'S' ? 2 * b.cur - b.ctrl : b.cur
			c2 := o + {x2, y2}
			cubic_to(b, c1, c2, o + {x, y})
			b.ctrl = c2
		case 'Q':
			x1 := num(&sc, &ok)
			y1 := num(&sc, &ok)
			x := num(&sc, &ok)
			y := num(&sc, &ok)
			if !ok do return
			c1 := o + {x1, y1}
			quad_to(b, c1, o + {x, y})
			b.ctrl = c1
		case 'T':
			x := num(&sc, &ok)
			y := num(&sc, &ok)
			if !ok do return
			c1 := b.last == 'Q' || b.last == 'T' ? 2 * b.cur - b.ctrl : b.cur
			quad_to(b, c1, o + {x, y})
			b.ctrl = c1
		case 'A':
			rx := num(&sc, &ok)
			ry := num(&sc, &ok)
			rot := num(&sc, &ok)
			large, lok := scan_flag(&sc)
			sweep, sok := scan_flag(&sc)
			x := num(&sc, &ok)
			y := num(&sc, &ok)
			if !ok || !lok || !sok do return
			arc_to(b, rx, ry, rot, large, sweep, o + {x, y})
		case 'Z':
			close_path(b)
		case:
			return
		}
		b.last = up
	}
}

// parse_transform parses an SVG transform list into one matrix.
@(private)
parse_transform :: proc(s: string) -> Mat {
	m := MAT_IDENTITY
	i := 0
	for i < len(s) {
		for i < len(s) && (is_space(s[i]) || s[i] == ',') do i += 1
		ns := i
		for i < len(s) && ((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= 'A' && s[i] <= 'Z')) do i += 1
		name := s[ns:i]
		for i < len(s) && is_space(s[i]) do i += 1
		if i >= len(s) || s[i] != '(' do return m
		e := strings.index_byte(s[i:], ')')
		if e < 0 do return m
		sc := Scanner{s = s[i + 1:i + e]}
		i += e + 1
		a: [6]f32
		n := 0
		for n < 6 {
			v, ok := scan_number(&sc)
			if !ok do break
			a[n] = v
			n += 1
		}
		t := MAT_IDENTITY
		switch name {
		case "matrix":
			if n == 6 do t = a
		case "translate":
			t = {1, 0, 0, 1, a[0], n > 1 ? a[1] : 0}
		case "scale":
			t = {a[0], 0, 0, n > 1 ? a[1] : a[0], 0, 0}
		case "rotate":
			r := a[0] * math.PI / 180
			c := math.cos(r)
			sn := math.sin(r)
			t = {c, sn, -sn, c, 0, 0}
			if n == 3 do t = mat_mul(mat_mul({1, 0, 0, 1, a[1], a[2]}, t), {1, 0, 0, 1, -a[1], -a[2]})
		case "skewX":
			t = {1, 0, math.tan(a[0] * math.PI / 180), 1, 0, 0}
		case "skewY":
			t = {1, math.tan(a[0] * math.PI / 180), 0, 1, 0, 0}
		case:
			return m
		}
		m = mat_mul(m, t)
	}
	return m
}

// Gradient attribute chain: own attribute, else inherited through href.
@(private)
grad_attr :: proc(p: ^Parser, ni: i32, name: string) -> (string, bool) {
	n := ni
	for _ in 0 ..< 8 {
		if v, has := attr(&p.doc, n, name); has do return v, true
		href, has := attr(&p.doc, n, "href")
		if !has do href, has = attr(&p.doc, n, "xlink:href")
		if !has || !strings.has_prefix(href, "#") do return "", false
		next, found := p.doc.ids[href[1:]]
		if !found do return "", false
		n = next
	}
	return "", false
}

@(private)
build_gradient :: proc(p: ^Parser, ni: i32) -> i32 {
	if gi, ok := p.grads[ni]; ok do return gi
	kind := local_name(p.doc.nodes[ni].name)
	if kind != "linearGradient" && kind != "radialGradient" do return -1
	g := Gradient {
		radial    = kind == "radialGradient",
		transform = MAT_IDENTITY,
	}
	units, _ := grad_attr(p, ni, "gradientUnits")
	g.bbox_units = units != "userSpaceOnUse"
	if t, has := grad_attr(p, ni, "gradientTransform"); has do g.transform = parse_transform(t)
	if sm, has := grad_attr(p, ni, "spreadMethod"); has {
		g.spread = sm == "reflect" ? .Reflect : sm == "repeat" ? .Repeat : .Pad
	}
	coord :: proc(p: ^Parser, ni: i32, name: string, def: f32, bbox: bool, axis: int) -> f32 {
		v, has := grad_attr(p, ni, name)
		if !has do return def
		sc := Scanner{s = v}
		x, ok := scan_number(&sc)
		if !ok do return def
		if sc.i < len(v) && v[sc.i] == '%' {
			x /= 100
			if !bbox {
				vb := p.icon.view_box
				ref := axis == 0 ? vb[2] : axis == 1 ? vb[3] : math.sqrt((vb[2] * vb[2] + vb[3] * vb[3]) / 2)
				x *= ref
			}
		}
		return x
	}
	bb := g.bbox_units
	vb := p.icon.view_box
	pct :: proc(bb: bool, v, ref: f32) -> f32 {return bb ? v : v * ref}
	diag := math.sqrt((vb[2] * vb[2] + vb[3] * vb[3]) / 2)
	if !g.radial {
		g.p0 = {coord(p, ni, "x1", 0, bb, 0), coord(p, ni, "y1", 0, bb, 1)}
		g.p1 = {coord(p, ni, "x2", pct(bb, 1, vb[2]), bb, 0), coord(p, ni, "y2", 0, bb, 1)}
	} else {
		g.p0 = {coord(p, ni, "cx", pct(bb, 0.5, vb[2]), bb, 0), coord(p, ni, "cy", pct(bb, 0.5, vb[3]), bb, 1)}
		g.r = coord(p, ni, "r", pct(bb, 0.5, diag), bb, 2)
		g.p1 = {coord(p, ni, "fx", g.p0.x, bb, 0), coord(p, ni, "fy", g.p0.y, bb, 1)}
		g.fr = coord(p, ni, "fr", 0, bb, 2)
	}
	// stops: first gradient in the href chain that has any
	stops := make([dynamic]Gradient_Stop, p.allocator)
	n := ni
	for _ in 0 ..< 8 {
		c := p.doc.nodes[n].first_child
		for c >= 0 {
			if local_name(p.doc.nodes[c].name) == "stop" {
				col := [4]u8{0, 0, 0, 255}
				op: f32 = 1
				off: f32 = 0
				if ov, has := attr(&p.doc, c, "offset"); has {
					sc := Scanner{s = ov}
					if x, ok := scan_number(&sc); ok {
						off = sc.i < len(ov) && ov[sc.i] == '%' ? x / 100 : x
					}
				}
				if sc, has := attr(&p.doc, c, "stop-color"); has do col = parse_color(sc)
				if so, has := attr(&p.doc, c, "stop-opacity"); has do op = parse_opacity(so)
				if sv, has := attr(&p.doc, c, "style"); has {
					for decl in strings.split_iterator(&sv, ";") {
						k := strings.index_byte(decl, ':')
						if k < 0 do continue
						key := strings.trim_space(decl[:k])
						val := strings.trim_space(decl[k + 1:])
						if key == "stop-color" do col = parse_color(val)
						if key == "stop-opacity" do op = parse_opacity(val)
					}
				}
				off = clamp(off, 0, 1)
				if len(stops) > 0 do off = max(off, stops[len(stops) - 1].offset)
				append(&stops, Gradient_Stop{off, {f32(col[0]) / 255, f32(col[1]) / 255, f32(col[2]) / 255, f32(col[3]) / 255 * op}})
			}
			c = p.doc.nodes[c].next
		}
		if len(stops) > 0 do break
		href, has := attr(&p.doc, n, "href")
		if !has do href, has = attr(&p.doc, n, "xlink:href")
		if !has || !strings.has_prefix(href, "#") do break
		next, found := p.doc.ids[href[1:]]
		if !found do break
		n = next
	}
	shrink(&stops)
	g.stops = stops[:]
	gi := i32(len(p.icon.gradients))
	append(&p.icon.gradients, g)
	p.grads[ni] = gi
	return gi
}
