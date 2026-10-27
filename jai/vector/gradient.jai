Spread :: enum u8 {
	Pad;
	Reflect;
	Repeat;
}

Gradient_Stop :: struct {
	offset: float32;
	color: Vector4; // straight RGBA, 0..1 (stop-opacity folded into alpha)
}

// Gradient is a linear (p0 -> p1) or two-point conical radial gradient
// (focal circle p1/fr -> end circle p0/r, the SVG model). Coordinates are in
// gradient space; `transform` maps gradient space to the space the paint is
// used in (for SVG: user space incl. objectBoundingBox and gradientTransform).
Gradient :: struct {
	radial: bool;
	spread: Spread;
	p0, p1: Vector2; // linear: start, end. radial: center, focal point
	r, fr: float32; // radial: radius, focal radius
	transform: Mat;
	stops: []Gradient_Stop; // sorted by offset
	bbox_units: bool; // SVG only: transform is relative to the shape's bbox
}

mat_invert :: (m: Mat) -> Mat, bool {
	det := get(m, 0) * get(m, 3) - get(m, 1) * get(m, 2);
	if abs(det) < 1.0e-12 { return zero(Mat), false; }
	id := 1 / det;
	return .[
		get(m, 3) * id,
		-get(m, 1) * id,
		-get(m, 2) * id,
		get(m, 0) * id,
		(get(m, 2) * get(m, 5) - get(m, 3) * get(m, 4)) * id,
		(get(m, 1) * get(m, 4) - get(m, 0) * get(m, 5)) * id
	], true;
}

// gradient_t returns the gradient parameter at point q (gradient space) or
// ok=false where a conical gradient is undefined (drawn transparent).
gradient_t :: (g: *Gradient, q: Vector2) -> float32, bool {
	t: float32;
	ok: bool;
	if !g.radial {
		d := g.p1 - g.p0;
		l2 := d.x * d.x + d.y * d.y;
		if l2 <= 0 { return 0, true; }
		return ((q.x - g.p0.x) * d.x + (q.y - g.p0.y) * d.y) / l2, true;
	}
	// circles C(t) = f + t*(c - f), radius fr + t*(r - fr); take the largest t with radius >= 0
	f := g.p1;
	cd := g.p0 - f;
	dr := g.r - g.fr;
	qf := q - f;
	a := cd.x * cd.x + cd.y * cd.y - dr * dr;
	b := qf.x * cd.x + qf.y * cd.y + g.fr * dr;
	c := qf.x * qf.x + qf.y * qf.y - g.fr * g.fr;
	if abs(a) < 1.0e-9 {
		if abs(b) < 1.0e-12 { return 0, false; }
		t = c / (2 * b);
		return t, g.fr + t * dr >= 0;
	}
	disc := b * b - a * c;
	if disc < 0 { return 0, false; }
	s := math.sqrt(disc);
	t1 := (b + s) / a;
	t2 := (b - s) / a;
	hi, lo := max(t1, t2), min(t1, t2);
	if g.fr + hi * dr >= 0 { return hi, true; }
	if g.fr + lo * dr >= 0 { return lo, true; }
	return 0, false;
}

// gradient_color evaluates straight RGBA (0..1) at parameter t.
gradient_color :: (g: *Gradient, t_in: float32) -> Vector4 {
	n := len(g.stops);
	if n == 0 { return .{}; }
	t := t_in;
	if g.spread == {
	case .Pad;
		t = clamp(t, 0, 1);
	case .Repeat;
		t = t - math.floor(t);
	case .Reflect;
		t = abs(t);
		k := math.floor(t);
		t = t - k;
		if ((cast(int)(k)) & 1) == 1 { t = 1 - t; }
	}
	if t <= g.stops[0].offset { return g.stops[0].color; }
	for i: 1..n-1 {
		s1 := g.stops[i];
		if t <= s1.offset {
			s0 := g.stops[i - 1];
			span := s1.offset - s0.offset;
			u := ifx span > 0 then (t - s0.offset) / span else 1;
			return s0.color + (s1.color - s0.color) * u;
		}
	}
	return g.stops[n - 1].color;
}

// gradient_fill_premul composites `cov * gradient` (src-over) into a premultiplied
// RGBA f32 canvas. m maps gradient space to pixel space.
gradient_fill_premul :: (g: *Gradient, m: Mat, cov: []float32, dst: []float32, w: int, h: int) {
	inv, ok := mat_invert(m);
	if !ok { return; }
	for y: 0..h-1 {
		for x: 0..w-1 {
			i := y * w + x;
			c := cov[i];
			if c <= 0 { continue; }
			q := mat_apply(inv, .{cast(float32)(x) + 0.5, cast(float32)(y) + 0.5});
			t, tok := gradient_t(g, q);
			if !tok { continue; }
			col := gradient_color(g, t);
			a := col[3] * c;
			d := sub_from(dst, i * 4);
			k := 1 - a;
			d[0] = col[0] * a + d[0] * k;
			d[1] = col[1] * a + d[1] * k;
			d[2] = col[2] * a + d[2] * k;
			d[3] = a + d[3] * k;
		}
	}
}

// solid_fill_premul composites `cov * color` (straight RGBA 0..1) into dst.
solid_fill_premul :: (color: Vector4, cov: []float32, dst: []float32) {
	for c, i: cov {
		if c <= 0 { continue; }
		a := color[3] * c;
		k := 1 - a;
		d := sub_from(dst, i * 4);
		d[0] = color[0] * a + d[0] * k;
		d[1] = color[1] * a + d[1] * k;
		d[2] = color[2] * a + d[2] * k;
		d[3] = a + d[3] * k;
	}
}

// premul_to_rgba8 converts a premultiplied f32 canvas to straight-alpha RGBA8.
premul_to_rgba8 :: (src: []float32, out: []u8) {
	for i: 0..(len(src) / 4)-1 {
		a := src[i * 4 + 3];
		if a <= 0 {
			at(*out, i * 4).*, at(*out, i * 4 + 1).*, at(*out, i * 4 + 2).*, at(*out, i * 4 + 3).* = 0, 0, 0, 0;
			continue;
		}
		for j: 0..2 { at(*out, i * 4 + j).* = cast(u8)(clamp(src[i * 4 + j] / a, 0, 1) * 255 + 0.5); }
		at(*out, i * 4 + 3).* = cast(u8)(clamp(a, 0, 1) * 255 + 0.5);
	}
}

