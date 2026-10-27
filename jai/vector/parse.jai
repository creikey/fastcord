#scope_module

Paint_Type :: enum u8 {
	None;
	Current;
	Color;
}

Paint :: struct {
	type: Paint_Type;
	color: [4]u8;
	gradient: bool;
	grad: s32; // index into Icon.gradients (valid when gradient)
}

Style :: struct {
	fill, stroke: Paint;
	fill_rule: Fill_Rule;
	clip_rule: Fill_Rule;
	fill_opacity: float32;
	stroke_opacity: float32;
	opacity: float32; // product of ancestor `opacity`
	stroke_width: float32;
	miter_limit: float32;
	cap: Line_Cap;
	join: Line_Join;
	secondary: bool;
	mask, clip: s32; // this element's own mask / clip-path
	anc_mask: s32; // nearest ancestor group's mask / clip-path (applied in anc_ctm space)
	anc_clip: s32;
	anc_ctm: Mat;
}

DEFAULT_STYLE :: Style.{
	fill = .{type = .Color, color = .[0, 0, 0, 255]},
	fill_opacity = 1,
	stroke_opacity = 1,
	opacity = 1,
	stroke_width = 1,
	miter_limit = 4,
	mask = -1,
	clip = -1,
	anc_mask = -1,
	anc_clip = -1,
	anc_ctm = MAT_IDENTITY
};

Parser :: struct {
	doc: Doc;
	icon: *Icon;
	groups: Map(s32, s32); // mask/clip node -> group index (-2 = in progress)
	grads: Map(s32, s32); // gradient node -> index in icon.gradients
	depth: int;
	allocator: Allocator; // the icon's allocator
}
#scope_export

// parse_svg parses an SVG document into a resolution-independent Icon.
parse_svg :: (src: string, allocator := context.allocator) -> Icon, bool {
	icon: Icon;
	ok: bool;
	arena: virtual.Arena;
	if virtual.arena_init_growing(*arena) != .None { return .{}, false; }
	defer virtual.arena_destroy(*arena);
	scratch := virtual.arena_allocator(*arena);

	p := Parser.{icon = *icon, allocator = allocator};
	if !xml_parse(src, *p.doc, scratch) { return .{}, false; }
	p.groups = Map(s32, s32).{};
	p.grads = Map(s32, s32).{};
	icon.verbs = make_dynamic(Verb, 0, 0, allocator);
	icon.points = make_dynamic(Vector2, 0, 0, allocator);
	icon.ops = make_dynamic(Op, 0, 0, allocator);
	icon.groups = make_dynamic(Group, 0, 0, allocator);
	icon.gradients = make_dynamic(Gradient, 0, 0, allocator);

	root := p.doc.nodes[0].first_child;
	while root >= 0 && p.doc.nodes[root].name != "svg" { root = p.doc.nodes[root].next; }
	if root < 0 {
		destroy(*icon);
		return .{}, false;
	}
	push_allocator(scratch);
	{ vb, has := attr(*p.doc, root, "viewBox");
	if has {
		nums: Vector4;
		sc := Scanner.{s = vb};
		got := 0;
		while got < 4 {
			v, nok := scan_number(*sc);
			if !nok { break; }
			nums[got] = v;
			got += 1;
		}
		if got == 4 && nums[2] > 0 && nums[3] > 0 { icon.view_box = nums; }
	} }
	if icon.view_box[2] <= 0 {
		w := attr_length(*p, root, "width", 0);
		h := attr_length(*p, root, "height", 0);
		icon.view_box = .{0, 0, ifx w > 0 then w else 24, ifx h > 0 then h else 24};
	}
	st := DEFAULT_STYLE;
	apply_style(*p, root, *st);
	walk_children(*p, root, MAT_IDENTITY, st, -1);
	return icon, true;
}
#scope_module

walk_children :: (p: *Parser, ni: s32, ctm: Mat, st: Style, group: s32) {
	c := p.doc.nodes[ni].first_child;
	while c >= 0 {
		walk(p, c, ctm, st, group);
		c = p.doc.nodes[c].next;
	}
}

walk :: (p: *Parser, ni: s32, parent_ctm: Mat, parent_st: Style, group: s32) {
	if p.depth > 64 { return; }
	p.depth += 1;
	defer p.depth -= 1;
	name := local_name(p.doc.nodes[ni].name);
	if name == {
	case "defs"; #through; case "mask"; #through; case "clipPath"; #through; case "linearGradient"; #through; case "radialGradient"; #through; case "symbol"; #through; case "style"; #through; case "title"; #through; case "desc"; #through; case "metadata"; #through; case "pattern"; #through; case "filter"; #through; case "marker"; #through; case "text";
		return;
	}
	{ v, has := attr(*p.doc, ni, "display");
	if has && v == "none" { return; } }
	st := parent_st;
	apply_style(p, ni, *st);
	ctm := parent_ctm;
	{ t, has := attr(*p.doc, ni, "transform");
	if has { ctm = mat_mul(ctm, parse_transform(t)); } }

	if name == {
	case "svg"; #through; case "g"; #through; case "a"; #through; case "switch";
		if name == "svg" && ni != p.doc.nodes[0].first_child {
			// Nested viewport: translate(x, y) then map its viewBox onto width x height.
			x := attr_length(p, ni, "x", 0);
			y := attr_length(p, ni, "y", 0);
			ctm = mat_mul(ctm, .[1, 0, 0, 1, x, y]);
			{ vb, has := attr(*p.doc, ni, "viewBox");
			if has {
				nums: Vector4;
				sc := Scanner.{s = vb};
				got := 0;
				while got < 4 {
					v, nok := scan_number(*sc);
					if !nok { break; }
					nums[got] = v;
					got += 1;
				}
				w := attr_length(p, ni, "width", nums[2]);
				h := attr_length(p, ni, "height", nums[3]);
				if got == 4 && nums[2] > 0 && nums[3] > 0 {
					sx := w / nums[2];
					sy := h / nums[3];
					tx, ty: float32;
					{ par, _ := attr(*p.doc, ni, "preserveAspectRatio");
					if !strings.has_prefix(par, "none") {
						s := min(sx, sy); // xMidYMid meet
						tx = (w - nums[2] * s) / 2;
						ty = (h - nums[3] * s) / 2;
						sx = s;
						sy = s;
					} }
					ctm = mat_mul(ctm, .[sx, 0, 0, sy, tx - nums[0] * sx, ty - nums[1] * sy]);
				}
			} }
		}
		cst := st;
		if st.clip >= 0 || st.mask >= 0 {
			// a group's clip/mask applies to every descendant, in the group's user space
			if st.clip >= 0 { cst.anc_clip = st.clip; }
			if st.mask >= 0 { cst.anc_mask = st.mask; }
			cst.anc_ctm = ctm;
		}
		walk_children(p, ni, ctm, cst, group);
	case "use";
		href, has := attr(*p.doc, ni, "href");
		if !has { href, has = attr(*p.doc, ni, "xlink:href"); }
		if !has || !strings.has_prefix(href, "#") { return; }
		ref, found := map_find(p.doc.ids, sub_from(href, 1));
		if !found { return; }
		x := attr_length(p, ni, "x", 0);
		y := attr_length(p, ni, "y", 0);
		walk(p, ref, mat_mul(ctm, .[1, 0, 0, 1, x, y]), st, group);
	case "path"; #through; case "rect"; #through; case "circle"; #through; case "ellipse"; #through; case "line"; #through; case "polyline"; #through; case "polygon";
		emit_shape(p, ni, name, ctm, st, group);
	}
}

local_name :: (s: string) -> string {
	{ i := strings.index_byte(s, #char ":");
	if i >= 0 { return sub_from(s, i + 1); } }
	return s;
}

apply_style :: (p: *Parser, ni: s32, st: *Style) {
	st.mask = -1; // mask/clip-path are not inherited; groups pass theirs down below
	st.clip = -1;
	for a: p.doc.nodes[ni].attrs { style_prop(p, st, a.name, a.value); }
	{ s, has := attr(*p.doc, ni, "style");
	if has {
		while true { decl, __ok3 := strings.split_iterator(*s, ";"); if !__ok3 break;
			c := strings.index_byte(decl, #char ":");
			if c < 0 { continue; }
			style_prop(p, st, strings.trim_space(sub(decl, 0, c)), strings.trim_space(sub_from(decl, c + 1)));
		}
	} }
}

style_prop :: (p: *Parser, st: *Style, name: string, value: string) {
	if name == {
	case "fill";
		st.fill = parse_paint(p, value, st.fill);
	case "stroke";
		st.stroke = parse_paint(p, value, st.stroke);
	case "fill-rule";
		st.fill_rule = ifx value == "evenodd" then .Evenodd else .Nonzero;
	case "clip-rule";
		st.clip_rule = ifx value == "evenodd" then .Evenodd else .Nonzero;
	case "fill-opacity";
		st.fill_opacity = parse_opacity(value);
	case "stroke-opacity";
		st.stroke_opacity = parse_opacity(value);
	case "opacity";
		st.opacity *= parse_opacity(value);
	case "stroke-width";
		sc := Scanner.{s = value};
		{ v, ok := scan_number(*sc);
		if ok { st.stroke_width = v; } }
	case "stroke-miterlimit";
		sc := Scanner.{s = value};
		{ v, ok := scan_number(*sc);
		if ok { st.miter_limit = max(v, 1); } }
	case "stroke-linecap";
		if value == {
		case "round";
			st.cap = .Round;
		case "square";
			st.cap = .Square;
		case;
			st.cap = .Butt;
		}
	case "stroke-linejoin";
		if value == {
		case "round";
			st.join = .Round;
		case "bevel";
			st.join = .Bevel;
		case;
			st.join = .Miter;
		}
	case "class";
		cls := value;
		while true { c, __ok7 := strings.fields_iterator(*cls); if !__ok7 break;
			if c == "secondary" { st.secondary = true; }
		}
	case "mask";
		st.mask = resolve_group(p, value, .Mask);
	case "clip-path";
		st.clip = resolve_group(p, value, .Clip);
	}
}

parse_opacity :: (v: string) -> float32 {
	sc := Scanner.{s = v};
	x, ok := scan_number(*sc);
	if !ok { return 1; }
	if sc.i < len(v) && v[sc.i] == #char "%" { x /= 100; }
	return clamp(x, 0, 1);
}

url_id :: (v: string) -> string, bool {
	s := strings.trim_space(v);
	if !strings.has_prefix(s, "url(") { return "", false; }
	e := strings.index_byte(s, #char ")");
	if e < 0 { return "", false; }
	id := strings.trim(sub(s, 4, e), " '\"");
	if !strings.has_prefix(id, "#") { return "", false; }
	return sub_from(id, 1), true;
}

parse_paint :: (p: *Parser, v: string, inherited: Paint) -> Paint {
	s := strings.trim_space(v);
	if s == {
	case "none"; #through; case "transparent";
		return .{type = .None};
	case "currentColor"; #through; case "currentcolor";
		return .{type = .Current};
	case "inherit";
		return inherited;
	}
	{ id, ok := url_id(s);
	if ok {
		ref, found := map_find(p.doc.ids, id);
		if !found { return .{type = .None}; }
		gi := build_gradient(p, ref);
		if gi < 0 { return .{type = .None}; }
		g := *p.icon.gradients[gi];
		if len(g.stops) == 0 { return .{type = .None}; }
		sum: Vector4;
		for st: g.stops { sum += st.color; }
		avg := sum / cast(float32)(len(g.stops));
		out := Paint.{type = .Color, gradient = true, grad = gi};
		for j: 0..3 { out.color[j] = cast(u8)(clamp(avg[j], 0, 1) * 255 + 0.5); }
		return out;
	} }
	return .{type = .Color, color = parse_color(s)};
}

parse_color :: (v: string) -> [4]u8 {
	s := strings.trim_space(v);
	hex :: (c: u8) -> u8 {
		if (c >= #char "0" && c <= #char "9") {
			return c - #char "0";
		} else if (c >= #char "a" && c <= #char "f") {
			return c - #char "a" + 10;
		} else if (c >= #char "A" && c <= #char "F") {
			return c - #char "A" + 10;
		}
		return 0;
	}
	if strings.has_prefix(s, "#") {
		h := sub_from(s, 1);
		if len(h) == {
		case 3; #through; case 4;
			out := u8.[0, 0, 0, 255];
			for j: 0..len(h)-1 { at(*out, j).* = hex(h[j]) * 17; }
			return out;
		case 6; #through; case 8;
			out := u8.[0, 0, 0, 255];
			for j: 0..(len(h) / 2)-1 { at(*out, j).* = hex(h[2 * j]) << 4 | hex(h[2 * j + 1]); }
			return out;
		}
		return .[0, 0, 0, 255];
	}
	if strings.has_prefix(s, "rgb") {
		o := strings.index_byte(s, #char "(");
		if o >= 0 {
			sc := Scanner.{s = sub_from(s, o + 1)};
			out := u8.[0, 0, 0, 255];
			for j: 0..3 {
				x, ok := scan_number(*sc);
				if !ok { break; }
				pct := sc.i < len(sc.s) && sc.s[sc.i] == #char "%";
				if pct { sc.i += 1; }
				if j == 3 {
					at(*out, 3).* = cast(u8)(clamp(ifx pct then x / 100 else x, 0, 1) * 255 + 0.5);
				} else {
					at(*out, j).* = cast(u8)(clamp(ifx pct then x * 2.55 else x, 0, 255) + 0.5);
				}
			}
			return out;
		}
	}
	if strings.to_lower(s, temp) == {
	case "white";
		return .[255, 255, 255, 255];
	case "red";
		return .[255, 0, 0, 255];
	case "green";
		return .[0, 128, 0, 255];
	case "blue";
		return .[0, 0, 255, 255];
	case "gray"; #through; case "grey";
		return .[128, 128, 128, 255];
	}
	return .[0, 0, 0, 255];
}

luminance :: (c: [4]u8) -> float32 {
	// mask-type: luminance (linearRGB coefficients on sRGB values, as browsers do).
	return (0.2125 * cast(float32)(c[0]) + 0.7154 * cast(float32)(c[1]) + 0.0721 * cast(float32)(c[2])) / 255 * cast(float32)(c[3]) / 255;
}

// attr_length parses a length attribute; % is relative to the root view box.
attr_length :: (p: *Parser, ni: s32, name: string, def: float32) -> float32 {
	v, has := attr(*p.doc, ni, name);
	if !has { return def; }
	sc := Scanner.{s = v};
	x, ok := scan_number(*sc);
	if !ok { return def; }
	if sc.i < len(v) && v[sc.i] == #char "%" {
		vb := p.icon.view_box;
		ref := ifx vb[2] > 0 then (ifx name == "x" || name == "width" || name == "cx" || name == "rx" || name == "x1" || name == "x2" then vb[2] else vb[3]) else 0;
		return x / 100 * ref;
	}
	return x;
}

resolve_group :: (p: *Parser, v: string, kind: Group_Kind) -> s32 {
	id, ok := url_id(v);
	if !ok { return -1; }
	ni, found := map_find(p.doc.ids, id);
	if !found { return -1; }
	want := ifx kind == .Mask then "mask" else "clipPath";
	if local_name(p.doc.nodes[ni].name) != want { return -1; }
	{ gi, cached := map_find(p.groups, ni);
	if cached { return ifx gi < 0 then -1 else gi; } }
	at(*p.groups, ni).* = -2; // recursion guard
	gi := cast(s32)(len(p.icon.groups));
	g := Group.{
		kind = kind
	};
	if kind == .Mask {
		units, _ := attr(*p.doc, ni, "maskUnits");
		cunits, _ := attr(*p.doc, ni, "maskContentUnits");
		g.region_bbox_units = units != "userSpaceOnUse";
		g.content_bbox_units = cunits == "objectBoundingBox";
		frac :: (p: *Parser, ni: s32, name: string, def: float32) -> float32 {
			v, has := attr(*p.doc, ni, name);
			if !has { return def; }
			sc := Scanner.{s = v};
			x, ok := scan_number(*sc);
			if !ok { return def; }
			if sc.i < len(v) && v[sc.i] == #char "%" { x /= 100; }
			return x;
		}
		if g.region_bbox_units {
			g.region = .{frac(p, ni, "x", -0.1), frac(p, ni, "y", -0.1), frac(p, ni, "width", 1.2), frac(p, ni, "height", 1.2)};
		} else {
			vb := p.icon.view_box;
			g.region = .{
				attr_length(p, ni, "x", vb[0] - 0.1 * vb[2]),
				attr_length(p, ni, "y", vb[1] - 0.1 * vb[3]),
				attr_length(p, ni, "width", 1.2 * vb[2]),
				attr_length(p, ni, "height", 1.2 * vb[3])
			};
		}
	} else {
		units, _ := attr(*p.doc, ni, "clipPathUnits");
		g.content_bbox_units = units == "objectBoundingBox";
	}
	append(*p.icon.groups, g);
	ctm := MAT_IDENTITY;
	{ t, has := attr(*p.doc, ni, "transform");
	if has && kind == .Clip { ctm = parse_transform(t); } }
	st := DEFAULT_STYLE;
	saved := p.depth;
	walk_children(p, ni, ctm, st, gi);
	p.depth = saved;
	at(*p.groups, ni).* = gi;
	return gi;
}

emit_shape :: (p: *Parser, ni: s32, name: string, ctm: Mat, st: Style, group: s32) {
	icon := p.icon;
	fv := cast(s32)(len(icon.verbs));
	fp := cast(s32)(len(icon.points));
	b := Builder.{icon = icon};
	if name == {
	case "path";
		{ d, has := attr(*p.doc, ni, "d");
		if has { parse_path(*b, d); } }
	case "rect";
		x := attr_length(p, ni, "x", 0);
		y := attr_length(p, ni, "y", 0);
		w := attr_length(p, ni, "width", 0);
		h := attr_length(p, ni, "height", 0);
		if w <= 0 || h <= 0 { return; }
		_, has_rx := attr(*p.doc, ni, "rx");
		_, has_ry := attr(*p.doc, ni, "ry");
		rx := attr_length(p, ni, "rx", 0);
		ry := attr_length(p, ni, "ry", 0);
		if has_rx && !has_ry { ry = rx; }
		if has_ry && !has_rx { rx = ry; }
		rx = clamp(rx, 0, w / 2);
		ry = clamp(ry, 0, h / 2);
		add_round_rect(*b, x, y, w, h, rx, ry);
	case "circle";
		r := attr_length(p, ni, "r", 0);
		if r <= 0 { return; }
		add_ellipse(*b, attr_length(p, ni, "cx", 0), attr_length(p, ni, "cy", 0), r, r);
	case "ellipse";
		rx := attr_length(p, ni, "rx", 0);
		ry := attr_length(p, ni, "ry", 0);
		if rx <= 0 || ry <= 0 { return; }
		add_ellipse(*b, attr_length(p, ni, "cx", 0), attr_length(p, ni, "cy", 0), rx, ry);
	case "line";
		move_to(*b, .{attr_length(p, ni, "x1", 0), attr_length(p, ni, "y1", 0)});
		line_to(*b, .{attr_length(p, ni, "x2", 0), attr_length(p, ni, "y2", 0)});
	case "polyline"; #through; case "polygon";
		pts, _ := attr(*p.doc, ni, "points");
		sc := Scanner.{s = pts};
		first := true;
		while true {
			x, okx := scan_number(*sc);
			if !okx { break; }
			y, oky := scan_number(*sc);
			if !oky { break; }
			if first { move_to(*b, .{x, y}); } else { line_to(*b, .{x, y}); }
			first = false;
		}
		if name == "polygon" && !first { close_path(*b); }
	}
	vc := cast(s32)(len(icon.verbs)) - fv;
	if vc == 0 { return; }
	bbox := Vector4.{FLOAT32_MAX, FLOAT32_MAX, -FLOAT32_MAX, -FLOAT32_MAX};
	for * pt: sub_from(icon.points, fp) {
		bbox = .{min(bbox[0], pt.x), min(bbox[1], pt.y), max(bbox[2], pt.x), max(bbox[3], pt.y)};
		pt.* = mat_apply(ctm, pt.*);
	}
	if bbox[0] > bbox[2] { bbox = .{}; }
	mask := ifx st.mask >= 0 then st.mask else -1;
	clip := ifx st.clip >= 0 then st.clip else -1;
	in_clip := group >= 0 && get(icon.groups, group).kind == .Clip;
	base := Op.{
		first_verb = fv,
		verb_count = vc,
		first_point = fp,
		layer = ifx st.secondary then .Secondary else .Primary,
		cap = st.cap,
		join = st.join,
		miter_limit = st.miter_limit,
		group = group,
		mask = mask,
		clip = clip,
		ctm = ctm,
		bbox = bbox,
		gradient = -1,
		anc_mask = st.anc_mask,
		anc_clip = st.anc_clip,
		anc_ctm = st.anc_ctm
	};
	if st.secondary { icon.has_secondary = true; }
	if in_clip {
		op := base;
		op.kind = .Fill;
		op.rule = st.clip_rule;
		op.alpha = 1;
		op.luminance = 1;
		op.current_color = true;
		append(*icon.ops, op);
		return;
	}
	add_paint :: (icon: *Icon, base: Op, kind: Paint_Kind, paint: Paint, alpha: float32, st: Style) {
		if paint.type == .None || alpha <= 0 { return; }
		op := base;
		op.kind = kind;
		op.rule = st.fill_rule;
		op.alpha = alpha;
		op.stroke_width = st.stroke_width;
		if paint.type == .Current {
			op.current_color = true;
			op.luminance = 0; // currentColor defaults to black
		} else {
			op.color = paint.color;
			op.alpha *= cast(float32)(paint.color[3]) / 255;
			if paint.gradient {
				op.gradient = paint.grad;
				op.grad_fold = cast(float32)(paint.color[3]) / 255;
			}
			c := paint.color;
			c[3] = 255;
			op.luminance = luminance(c);
			if op.group < 0 { icon.multicolor = true; }
		}
		append(*icon.ops, op);
	}
	add_paint(icon, base, .Fill, st.fill, st.fill_opacity * st.opacity, st);
	if st.stroke_width > 0 { add_paint(icon, base, .Stroke, st.stroke, st.stroke_opacity * st.opacity, st); }
}

// ---- path building ----

Builder :: struct {
	icon: *Icon;
	start: Vector2;
	cur: Vector2;
	ctrl: Vector2; // last control point (for S / T reflection)
	last: u8; // last command, upper-cased
	open: bool; // a subpath has been started
	need_move: bool; // after Z: implicit moveto to start
}

move_to :: (b: *Builder, p: Vector2) {
	append(*b.icon.verbs, Verb.Move);
	append(*b.icon.points, p);
	b.start = p;
	b.cur = p;
	b.open = true;
	b.need_move = false;
}

ensure_move :: (b: *Builder) {
	if !b.open || b.need_move { move_to(b, b.cur); }
}

line_to :: (b: *Builder, p: Vector2) {
	ensure_move(b);
	append(*b.icon.verbs, Verb.Line);
	append(*b.icon.points, p);
	b.cur = p;
}

quad_to :: (b: *Builder, c: Vector2, p: Vector2) {
	ensure_move(b);
	append(*b.icon.verbs, Verb.Quad);
	append(*b.icon.points, c, p);
	b.cur = p;
}

cubic_to :: (b: *Builder, c1: Vector2, c2: Vector2, p: Vector2) {
	ensure_move(b);
	append(*b.icon.verbs, Verb.Cubic);
	append(*b.icon.points, c1, c2, p);
	b.cur = p;
}

close_path :: (b: *Builder) {
	if !b.open || b.need_move { return; }
	append(*b.icon.verbs, Verb.Close);
	b.cur = b.start;
	b.need_move = true;
}

KAPPA :: 0.5522847498;

add_ellipse :: (b: *Builder, cx: float32, cy: float32, rx: float32, ry: float32) {
	kx := rx * cast(float32) KAPPA;
	ky := ry * cast(float32) KAPPA;
	move_to(b, .{cx + rx, cy});
	cubic_to(b, .{cx + rx, cy + ky}, .{cx + kx, cy + ry}, .{cx, cy + ry});
	cubic_to(b, .{cx - kx, cy + ry}, .{cx - rx, cy + ky}, .{cx - rx, cy});
	cubic_to(b, .{cx - rx, cy - ky}, .{cx - kx, cy - ry}, .{cx, cy - ry});
	cubic_to(b, .{cx + kx, cy - ry}, .{cx + rx, cy - ky}, .{cx + rx, cy});
	close_path(b);
}

add_round_rect :: (b: *Builder, x: float32, y: float32, w: float32, h: float32, rx: float32, ry: float32) {
	if rx <= 0 || ry <= 0 {
		move_to(b, .{x, y});
		line_to(b, .{x + w, y});
		line_to(b, .{x + w, y + h});
		line_to(b, .{x, y + h});
		close_path(b);
		return;
	}
	kx := rx * cast(float32) (1 - KAPPA);
	ky := ry * cast(float32) (1 - KAPPA);
	r := x + w;
	btm := y + h;
	move_to(b, .{x + rx, y});
	line_to(b, .{r - rx, y});
	cubic_to(b, .{r - kx, y}, .{r, y + ky}, .{r, y + ry});
	line_to(b, .{r, btm - ry});
	cubic_to(b, .{r, btm - ky}, .{r - kx, btm}, .{r - rx, btm});
	line_to(b, .{x + rx, btm});
	cubic_to(b, .{x + kx, btm}, .{x, btm - ky}, .{x, btm - ry});
	line_to(b, .{x, y + ry});
	cubic_to(b, .{x, y + ky}, .{x + kx, y}, .{x + rx, y});
	close_path(b);
}

// arc_to appends an SVG elliptical arc (endpoint parameterization) as cubics.
arc_to :: (b: *Builder, rx_in: float32, ry_in: float32, phi_deg: float32, large: bool, sweep: bool, p: Vector2) {
	p0 := b.cur;
	if p0 == p { return; }
	rx := abs(cast(float64)(rx_in));
	ry := abs(cast(float64)(ry_in));
	if rx == 0 || ry == 0 {
		line_to(b, p);
		return;
	}
	phi := cast(float64)(phi_deg) * math.PI / 180;
	cs := math.cos(phi);
	sn := math.sin(phi);
	x1 := cast(float64)(p0.x);
	y1 := cast(float64)(p0.y);
	x2 := cast(float64)(p.x);
	y2 := cast(float64)(p.y);
	dx2 := (x1 - x2) / 2;
	dy2 := (y1 - y2) / 2;
	x1p := cs * dx2 + sn * dy2;
	y1p := -sn * dx2 + cs * dy2;
	lambda := x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry);
	if lambda > 1 {
		s := math.sqrt(lambda);
		rx *= s;
		ry *= s;
	}
	num := rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
	den := rx * rx * y1p * y1p + ry * ry * x1p * x1p;
	coef := ifx den > 0 then math.sqrt(max(num / den, 0)) else 0;
	if large == sweep { coef = -coef; }
	cxp := coef * rx * y1p / ry;
	cyp := -coef * ry * x1p / rx;
	cx := cs * cxp - sn * cyp + (x1 + x2) / 2;
	cy := sn * cxp + cs * cyp + (y1 + y2) / 2;
	angle :: (ux: float64, uy: float64, vx: float64, vy: float64) -> float64 {
		return math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
	}
	ux := (x1p - cxp) / rx;
	uy := (y1p - cyp) / ry;
	vx := (-x1p - cxp) / rx;
	vy := (-y1p - cyp) / ry;
	theta1 := angle(1, 0, ux, uy);
	dtheta := angle(ux, uy, vx, vy);
	if !sweep && dtheta > 0 { dtheta -= 2 * math.PI; }
	if sweep && dtheta < 0 { dtheta += 2 * math.PI; }
	n := max(1, cast(int)(math.ceil(abs(dtheta) / (math.PI / 2) - 1.0e-9)));
	d := dtheta / cast(float64)(n);
	k := 4.0 / 3.0 * math.tan(d / 4);
	ept :: (cx: float64, cy: float64, rx: float64, ry: float64, cs: float64, sn: float64, t: float64) -> float64, float64 {
		return cx + rx * math.cos(t) * cs - ry * math.sin(t) * sn, cy + rx * math.cos(t) * sn + ry * math.sin(t) * cs;
	}
	eder :: (rx: float64, ry: float64, cs: float64, sn: float64, t: float64) -> float64, float64 {
		return -rx * math.sin(t) * cs - ry * math.cos(t) * sn, -rx * math.sin(t) * sn + ry * math.cos(t) * cs;
	}
	for i: 0..n-1 {
		t1 := theta1 + cast(float64)(i) * d;
		t2 := t1 + d;
		ax, ay := ept(cx, cy, rx, ry, cs, sn, t1);
		ex, ey := ept(cx, cy, rx, ry, cs, sn, t2);
		dax, day := eder(rx, ry, cs, sn, t1);
		dex, dey := eder(rx, ry, cs, sn, t2);
		end := ifx i == n - 1 then p else Vector2.{cast(float32)(ex), cast(float32)(ey)};
		cubic_to(b, .{cast(float32)(ax + k * dax), cast(float32)(ay + k * day)}, .{cast(float32)(ex - k * dex), cast(float32)(ey - k * dey)}, end);
	}
}

// ---- number scanning ----

Scanner :: struct {
	s: string;
	i: int;
}

skip_sep :: (sc: *Scanner) {
	while sc.i < len(sc.s) && is_space(sc.s[sc.i]) { sc.i += 1; }
	if sc.i < len(sc.s) && sc.s[sc.i] == #char "," {
		sc.i += 1;
		while sc.i < len(sc.s) && is_space(sc.s[sc.i]) { sc.i += 1; }
	}
}

scan_number :: (sc: *Scanner) -> float32, bool {
	skip_sep(sc);
	s := sc.s;
	i := sc.i;
	st := i;
	if i < len(s) && (s[i] == #char "+" || s[i] == #char "-") { i += 1; }
	digits := 0;
	while i < len(s) && s[i] >= #char "0" && s[i] <= #char "9" {
		i += 1;
		digits += 1;
	}
	if i < len(s) && s[i] == #char "." {
		i += 1;
		while i < len(s) && s[i] >= #char "0" && s[i] <= #char "9" {
			i += 1;
			digits += 1;
		}
	}
	if digits == 0 { return 0, false; }
	if i < len(s) && (s[i] == #char "e" || s[i] == #char "E") {
		j := i + 1;
		if j < len(s) && (s[j] == #char "+" || s[j] == #char "-") { j += 1; }
		if j < len(s) && s[j] >= #char "0" && s[j] <= #char "9" {
			while j < len(s) && s[j] >= #char "0" && s[j] <= #char "9" { j += 1; }
			i = j;
		}
	}
	v, ok := strconv.parse_f64(sub(s, st, i));
	if !ok { return 0, false; }
	sc.i = i;
	return cast(float32)(v), true;
}

scan_flag :: (sc: *Scanner) -> bool, bool {
	skip_sep(sc);
	if sc.i < len(sc.s) && (sc.s[sc.i] == #char "0" || sc.s[sc.i] == #char "1") {
		f := sc.s[sc.i] == #char "1";
		sc.i += 1;
		return f, true;
	}
	return false, false;
}

// parse_path appends path data; on a syntax error the path so far is kept (as browsers do).
parse_path :: (b: *Builder, d: string) {
	sc := Scanner.{s = d};
	cmd: u8 = 0;
	while true {
		skip_sep(*sc);
		if sc.i >= len(d) { return; }
		c := d[sc.i];
		if (c >= #char "A" && c <= #char "Z") || (c >= #char "a" && c <= #char "z") {
			cmd = c;
			sc.i += 1;
		} else if cmd == 0 || cmd == #char "Z" || cmd == #char "z" {
			return;
		}
		rel := cmd >= #char "a";
		up := ifx rel then cmd - 32 else cmd;
		o := ifx rel then b.cur else Vector2.{0, 0};
		num :: (sc: *Scanner, ok: *bool) -> float32 {
			v, k := scan_number(sc);
			if !k { ok.* = false; }
			return v;
		}
		ok := true;
		if up == {
		case #char "M";
			x := num(*sc, *ok);
			y := num(*sc, *ok);
			if !ok { return; }
			move_to(b, o + .{x, y});
			cmd = cast(u8) ifx rel then #char "l" else #char "L";
		case #char "L";
			x := num(*sc, *ok);
			y := num(*sc, *ok);
			if !ok { return; }
			line_to(b, o + .{x, y});
		case #char "H";
			x := num(*sc, *ok);
			if !ok { return; }
			line_to(b, .{ifx rel then b.cur.x + x else x, b.cur.y});
		case #char "V";
			y := num(*sc, *ok);
			if !ok { return; }
			line_to(b, .{b.cur.x, ifx rel then b.cur.y + y else y});
		case #char "C";
			x1 := num(*sc, *ok);
			y1 := num(*sc, *ok);
			x2 := num(*sc, *ok);
			y2 := num(*sc, *ok);
			x := num(*sc, *ok);
			y := num(*sc, *ok);
			if !ok { return; }
			c2 := o + .{x2, y2};
			cubic_to(b, o + .{x1, y1}, c2, o + .{x, y});
			b.ctrl = c2;
		case #char "S";
			x2 := num(*sc, *ok);
			y2 := num(*sc, *ok);
			x := num(*sc, *ok);
			y := num(*sc, *ok);
			if !ok { return; }
			c1 := ifx b.last == #char "C" || b.last == #char "S" then 2 * b.cur - b.ctrl else b.cur;
			c2 := o + .{x2, y2};
			cubic_to(b, c1, c2, o + .{x, y});
			b.ctrl = c2;
		case #char "Q";
			x1 := num(*sc, *ok);
			y1 := num(*sc, *ok);
			x := num(*sc, *ok);
			y := num(*sc, *ok);
			if !ok { return; }
			c1 := o + .{x1, y1};
			quad_to(b, c1, o + .{x, y});
			b.ctrl = c1;
		case #char "T";
			x := num(*sc, *ok);
			y := num(*sc, *ok);
			if !ok { return; }
			c1 := ifx b.last == #char "Q" || b.last == #char "T" then 2 * b.cur - b.ctrl else b.cur;
			quad_to(b, c1, o + .{x, y});
			b.ctrl = c1;
		case #char "A";
			rx := num(*sc, *ok);
			ry := num(*sc, *ok);
			rot := num(*sc, *ok);
			large, lok := scan_flag(*sc);
			sweep, sok := scan_flag(*sc);
			x := num(*sc, *ok);
			y := num(*sc, *ok);
			if !ok || !lok || !sok { return; }
			arc_to(b, rx, ry, rot, large, sweep, o + .{x, y});
		case #char "Z";
			close_path(b);
		case;
			return;
		}
		b.last = up;
	}
}

// parse_transform parses an SVG transform list into one matrix.
parse_transform :: (s: string) -> Mat {
	m := MAT_IDENTITY;
	i := 0;
	while i < len(s) {
		while i < len(s) && (is_space(s[i]) || s[i] == #char ",") { i += 1; }
		ns := i;
		while i < len(s) && ((s[i] >= #char "a" && s[i] <= #char "z") || (s[i] >= #char "A" && s[i] <= #char "Z")) { i += 1; }
		name := sub(s, ns, i);
		while i < len(s) && is_space(s[i]) { i += 1; }
		if i >= len(s) || s[i] != #char "(" { return m; }
		e := strings.index_byte(sub_from(s, i), #char ")");
		if e < 0 { return m; }
		sc := Scanner.{s = sub(s, i + 1, i + e)};
		i += e + 1;
		a: [6]float32;
		n := 0;
		while n < 6 {
			v, ok := scan_number(*sc);
			if !ok { break; }
			a[n] = v;
			n += 1;
		}
		t := MAT_IDENTITY;
		if name == {
		case "matrix";
			if n == 6 { t = a; }
		case "translate";
			t = .[1, 0, 0, 1, a[0], ifx n > 1 then a[1] else 0];
		case "scale";
			t = .[a[0], 0, 0, ifx n > 1 then a[1] else a[0], 0, 0];
		case "rotate";
			r := a[0] * PI32 / 180;
			c := math.cos(r);
			sn := math.sin(r);
			t = .[c, sn, -sn, c, 0, 0];
			if n == 3 { t = mat_mul(mat_mul(.[1, 0, 0, 1, a[1], a[2]], t), .[1, 0, 0, 1, -a[1], -a[2]]); }
		case "skewX";
			t = .[1, 0, math.tan(a[0] * PI32 / 180), 1, 0, 0];
		case "skewY";
			t = .[1, math.tan(a[0] * PI32 / 180), 0, 1, 0, 0];
		case;
			return m;
		}
		m = mat_mul(m, t);
	}
	return m;
}

// Gradient attribute chain: own attribute, else inherited through href.
grad_attr :: (p: *Parser, ni: s32, name: string) -> string, bool {
	n := ni;
	for _: 0..7 {
		{ v, has := attr(*p.doc, n, name);
		if has { return v, true; } }
		href, has := attr(*p.doc, n, "href");
		if !has { href, has = attr(*p.doc, n, "xlink:href"); }
		if !has || !strings.has_prefix(href, "#") { return "", false; }
		next, found := map_find(p.doc.ids, sub_from(href, 1));
		if !found { return "", false; }
		n = next;
	}
	return "", false;
}

build_gradient :: (p: *Parser, ni: s32) -> s32 {
	{ gi, ok := map_find(p.grads, ni);
	if ok { return gi; } }
	kind := local_name(p.doc.nodes[ni].name);
	if kind != "linearGradient" && kind != "radialGradient" { return -1; }
	g := Gradient.{
		radial = kind == "radialGradient",
		transform = MAT_IDENTITY
	};
	units, _ := grad_attr(p, ni, "gradientUnits");
	g.bbox_units = units != "userSpaceOnUse";
	{ t, has := grad_attr(p, ni, "gradientTransform");
	if has { g.transform = parse_transform(t); } }
	{ sm, has := grad_attr(p, ni, "spreadMethod");
	if has {
		g.spread = ifx sm == "reflect" then .Reflect else ifx sm == "repeat" then .Repeat else .Pad;
	} }
	coord :: (p: *Parser, ni: s32, name: string, def: float32, bbox: bool, axis: int) -> float32 {
		v, has := grad_attr(p, ni, name);
		if !has { return def; }
		sc := Scanner.{s = v};
		x, ok := scan_number(*sc);
		if !ok { return def; }
		if sc.i < len(v) && v[sc.i] == #char "%" {
			x /= 100;
			if !bbox {
				vb := p.icon.view_box;
				ref := ifx axis == 0 then vb[2] else ifx axis == 1 then vb[3] else math.sqrt((vb[2] * vb[2] + vb[3] * vb[3]) / 2);
				x *= ref;
			}
		}
		return x;
	}
	bb := g.bbox_units;
	vb := p.icon.view_box;
	pct :: (bb: bool, v: float32, ref: float32) -> float32 {return ifx bb then v else v * ref;}
	diag := math.sqrt((vb[2] * vb[2] + vb[3] * vb[3]) / 2);
	if !g.radial {
		g.p0 = .{coord(p, ni, "x1", 0, bb, 0), coord(p, ni, "y1", 0, bb, 1)};
		g.p1 = .{coord(p, ni, "x2", pct(bb, 1, vb[2]), bb, 0), coord(p, ni, "y2", 0, bb, 1)};
	} else {
		g.p0 = .{coord(p, ni, "cx", pct(bb, 0.5, vb[2]), bb, 0), coord(p, ni, "cy", pct(bb, 0.5, vb[3]), bb, 1)};
		g.r = coord(p, ni, "r", pct(bb, 0.5, diag), bb, 2);
		g.p1 = .{coord(p, ni, "fx", g.p0.x, bb, 0), coord(p, ni, "fy", g.p0.y, bb, 1)};
		g.fr = coord(p, ni, "fr", 0, bb, 2);
	}
	// stops: first gradient in the href chain that has any
	stops := make_dynamic(Gradient_Stop, 0, 0, p.allocator);
	n := ni;
	for _: 0..7 {
		c := p.doc.nodes[n].first_child;
		while c >= 0 {
			if local_name(p.doc.nodes[c].name) == "stop" {
				col := u8.[0, 0, 0, 255];
				op: float32 = 1;
				off: float32 = 0;
				{ ov, has := attr(*p.doc, c, "offset");
				if has {
					sc := Scanner.{s = ov};
					{ x, ok := scan_number(*sc);
					if ok {
						off = ifx sc.i < len(ov) && ov[sc.i] == #char "%" then x / 100 else x;
					} }
				} }
				{ sc, has := attr(*p.doc, c, "stop-color");
				if has { col = parse_color(sc); } }
				{ so, has := attr(*p.doc, c, "stop-opacity");
				if has { op = parse_opacity(so); } }
				{ sv, has := attr(*p.doc, c, "style");
				if has {
					while true { decl, __ok15 := strings.split_iterator(*sv, ";"); if !__ok15 break;
						k := strings.index_byte(decl, #char ":");
						if k < 0 { continue; }
						key := strings.trim_space(sub(decl, 0, k));
						val := strings.trim_space(sub_from(decl, k + 1));
						if key == "stop-color" { col = parse_color(val); }
						if key == "stop-opacity" { op = parse_opacity(val); }
					}
				} }
				off = clamp(off, 0, 1);
				if len(stops) > 0 { off = max(off, stops[len(stops) - 1].offset); }
				append(*stops, Gradient_Stop.{off, .{cast(float32)(col[0]) / 255, cast(float32)(col[1]) / 255, cast(float32)(col[2]) / 255, cast(float32)(col[3]) / 255 * op}});
			}
			c = p.doc.nodes[c].next;
		}
		if len(stops) > 0 { break; }
		href, has := attr(*p.doc, n, "href");
		if !has { href, has = attr(*p.doc, n, "xlink:href"); }
		if !has || !strings.has_prefix(href, "#") { break; }
		next, found := map_find(p.doc.ids, sub_from(href, 1));
		if !found { break; }
		n = next;
	}
	g.stops = view(stops);
	gi := cast(s32)(len(p.icon.gradients));
	append(*p.icon.gradients, g);
	at(*p.grads, ni).* = gi;
	return gi;
}
#scope_export

