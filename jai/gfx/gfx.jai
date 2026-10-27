Color :: [4]float32; // straight-alpha sRGB, 0..1

Rect :: struct {
	x0, y0, x1, y1: float32;
}

Texture :: u32; // 0 = none

Texture_Format :: enum u8 {
	RGBA8; // callers pass straight alpha; stored premultiplied so filtering never bleeds colour from alpha-0 texels
	R8; // coverage / alpha mask (tinted by color); also the Y plane of NV12
	RG8; // two-channel (CbCr plane of NV12)
}

// Set on Rect_Params (with tex = Y plane, tex2 = CbCr plane) to draw NV12 video.
Yuv_Matrix :: enum u8 {
	None;
	BT601; // video (limited) range
	BT709;
	BT601_Full;
	BT709_Full;
}

Rect_Params :: struct {
	dst: Rect; // points
	src: Rect; // texels; zero = whole texture (when tex != 0)
	tex: Texture;
	colors: [4]Color; // TL, TR, BL, BR
	radii: [4]float32; // TL, TR, BL, BR (points)
	border: float32; // 0 = filled; else stroke width (points), drawn inside dst
	softness: float32; // edge blur radius (points), for shadows; quad grows by this much
	tex2: Texture; // second plane for yuv (CbCr, any size; sampled with the same normalized uv)
	yuv: Yuv_Matrix;
}

// Fill helper for the common case.
rect :: (dst: Rect, color: Color, radius: float32 = 0) {
	push_rect(.{dst = dst, colors = .{color, color, color, color}, radii = radius});
}

rect_border :: (dst: Rect, color: Color, thickness: float32, radius: float32 = 0) {
	push_rect(.{dst = dst, colors = .{color, color, color, color}, radii = radius, border = thickness});
}

// Shadow under `dst`: blur radius `blur`, offset applied by caller.
rect_shadow :: (dst: Rect, color: Color, blur: float32, radius: float32 = 0) {
	push_rect(.{dst = dst, colors = .{color, color, color, color}, radii = radius, softness = blur});
}

image :: (dst: Rect, tex: Texture, tint: Color = .{1, 1, 1, 1}, radius: float32 = 0) {
	push_rect(.{dst = dst, tex = tex, colors = .{tint, tint, tint, tint}, radii = radius});
}

rect_intersect :: (a: Rect, b: Rect) -> Rect {
	return .{max(a.x0, b.x0), max(a.y0, b.y0), min(a.x1, b.x1), min(a.y1, b.y1)};
}

rect_empty :: (r: Rect) -> bool {return r.x1 <= r.x0 || r.y1 <= r.y0;}

rgba :: (hex: u32) -> Color {
	return .{cast(float32)((hex >> 24) & 0xff) / 255, cast(float32)((hex >> 16) & 0xff) / 255, cast(float32)((hex >> 8) & 0xff) / 255, cast(float32)(hex & 0xff) / 255};
}

rgb :: (hex: u32) -> Color {
	return .{cast(float32)((hex >> 16) & 0xff) / 255, cast(float32)((hex >> 8) & 0xff) / 255, cast(float32)(hex & 0xff) / 255, 1};
}

// ---------------------------------------------------------------------------
// GPU instance layout (shared with the shaders; 144 bytes)

Instance :: struct {
	dst: [4]float32; // pixels x0 y0 x1 y1 (quad = dst grown by softness)
	src: [4]float32; // texels
	colors: [4][4]float32; // premultiplied, TL TR BL BR
	radii: [4]float32; // pixels TL TR BL BR
	params: [4]float32; // border px, softness px, tex kind (0 none, 1 R8 mask, 2 RGBA, 3 NV12) + 4 * slot, yuv matrix
	clip: [4]float32; // pixels x0 y0 x1 y1; the vertex shader clamps the quad to it
}

// Each draw call binds up to TEX_SLOTS textures and instances pick one by slot, and clipping is per
// instance, so a frame is a few draw calls rather than one per clip rect or texture change: per-draw
// driver work was most of the render time.
TEX_SLOTS :: 16;

Batch :: struct {
	first, count: u32;
	slots: [TEX_SLOTS]Texture;
	n_slots: u32;
	tex2: Texture;
}
#scope_module

Tex_Slot :: struct {
	native: *void;
	w, h: s32;
	format: Texture_Format;
	alive: bool;
	release: (user: *void); // external (wrapped) textures
	user: *void;
}

Pending_Destroy :: struct {
	native: *void;
	frame: u64;
	release: (user: *void);
	user: *void;
}
#scope_export

FRAMES_IN_FLIGHT :: 3;
#scope_module

G :: struct {
	initialized: bool;
	in_frame: bool;
	frame_index: u64;
	scale: float32;
	fb_size: [2]s32;
	clear: Color;
	instances: [..]Instance;
	batches: [..]Batch;
	clip_stack: [..][4]s32;
	textures: [..]Tex_Slot; // index = Texture handle; [0] is the 1x1 white texture
	free_textures: [..]Texture;
	destroy_queue: [..]Pending_Destroy;
	white: Texture;
	stats: Frame_Stats;
	diag: Diag;
}
#scope_export

// Running totals of things that should never happen; the app logs them when they change.
Diag :: struct {
	dead_tex_draws: int; // rects whose texture handle was not alive (drawn untextured)
	last_dead_tex: Texture;
	tex_create_fails: int;
	present_fails: int;
	last_hresult: s32; // of the latest failed backend call
	device_removed: s32; // GetDeviceRemovedReason after a failure; 0 = device fine
	atlas_resets: int;
}

Frame_Stats :: struct {
	instances: int;
	draw_calls: int;
	frames: u64; // total frames submitted
	gpu_ns: s64; // GPU time of the latest frame whose timer finished (a few frames back); 0 if unknown
	gpu_frame: u64; // which frame (frame_index) gpu_ns belongs to
}
#scope_module

g: G;
#scope_export

init :: () -> bool {
	if g.initialized { return true; }
	g.instances = make_dynamic(Instance, 0, 16 * 1024);
	g.batches = make_dynamic(Batch, 0, 256);
	g.clip_stack = make_dynamic([4]s32, 0, 32);
	g.textures = make_dynamic(Tex_Slot, 0, 64);
	append(*g.textures, Tex_Slot.{}); // handle 0 = none
	g.scale = platform.dpi_scale();
	if !_backend_init() { return false; }
	white := u8.[255, 255, 255, 255];
	g.white = texture_create(1, 1, .RGBA8, view(white));
	text_init();
	g.initialized = true;
	return true;
}

shutdown :: () {
	if !g.initialized { return; }
	text_shutdown();
	_backend_wait_idle();
	for d: g.destroy_queue { destroy_now(d); }
	for s, i: g.textures { if s.alive && i != 0 { destroy_now(.{native = s.native, release = s.release, user = s.user}); } }
	_backend_shutdown();
	delete(g.instances);
	delete(g.batches);
	delete(g.clip_stack);
	delete(g.textures);
	delete(g.free_textures);
	delete(g.destroy_queue);
	g = .{};
}

stats :: () -> Frame_Stats {return g.stats;}

diag :: () -> Diag {return g.diag;}

// Live textures (for benchmarks: each distinct texture costs per-draw-call driver work).
texture_count :: () -> int {
	n := 0;
	for s: g.textures { if s.alive { n += 1; } }
	return n;
}

// Blocks until the GPU has finished every submitted frame. For latency measurement and shutdown only.
wait_gpu :: () {_backend_wait_idle();}

// Points -> pixels factor for the current frame.
scale :: () -> float32 {return g.scale;}

begin_frame :: (clear: Color) {
	assert(!g.in_frame);
	g.in_frame = true;
	g.scale = platform.dpi_scale();
	g.fb_size = platform.framebuffer_size();
	g.clear = clear;
	clear_dynamic_array(*g.instances);
	clear_dynamic_array(*g.batches);
	clear_dynamic_array(*g.clip_stack);
	append(*g.clip_stack, s32.[0, 0, g.fb_size.x, g.fb_size.y]);
	text_begin_frame();
}

end_frame :: () {
	assert(g.in_frame);
	g.in_frame = false;
	g.stats.instances = len(g.instances);
	g.stats.draw_calls = len(g.batches);
	_backend_submit(view(g.instances), view(g.batches), g.clear, g.fb_size);
	g.frame_index += 1;
	g.stats.frames += 1;
	// Release textures that no in-flight frame can reference anymore.
	{ i := 0;
	while i < len(g.destroy_queue) {
		d := g.destroy_queue[i];
		if g.frame_index >= d.frame + FRAMES_IN_FLIGHT + 1 {
			destroy_now(d);
			unordered_remove(*g.destroy_queue, i);
		} else {
			i += 1;
		}
	} }
	text_end_frame();
}

// ---------------------------------------------------------------------------
// Clip

push_clip :: (r: Rect) {
	px := snap_rect(r);
	c := s32.[cast(s32)(px.x0), cast(s32)(px.y0), cast(s32)(px.x1), cast(s32)(px.y1)];
	top := g.clip_stack[len(g.clip_stack) - 1];
	cur := s32.[max(c[0], top[0]), max(c[1], top[1]), min(c[2], top[2]), min(c[3], top[3])];
	cur[2] = max(cur[2], cur[0]);
	cur[3] = max(cur[3], cur[1]);
	append(*g.clip_stack, cur);
}

pop_clip :: () {
	assert(len(g.clip_stack) > 1, "pop_clip without push_clip");
	pop(*g.clip_stack);
}

// Current clip in points.
current_clip :: () -> Rect {
	c := g.clip_stack[len(g.clip_stack) - 1];
	return .{cast(float32)(c[0]) / g.scale, cast(float32)(c[1]) / g.scale, cast(float32)(c[2]) / g.scale, cast(float32)(c[3]) / g.scale};
}
#scope_module

// ---------------------------------------------------------------------------
// Rects

snap_rect :: (r: Rect) -> Rect {
	sc := g.scale;
	return .{math.round(r.x0 * sc), math.round(r.y0 * sc), math.round(r.x1 * sc), math.round(r.y1 * sc)};
}

premul :: inline (c: Color) -> [4]float32 {
	return .{c.r * c.a, c.g * c.a, c.b * c.a, c.a};
};
#scope_export

// Pixel snapping rules:
//  - Hard-edged rects (softness 0): every edge is rounded to the nearest device
//    pixel, and a non-empty rect is never thinner than 1px. Fills therefore have
//    no AA fringe, and 1px lines stay 1px.
//  - Borders are rounded to whole device pixels (min 1px) so strokes are crisp.
//  - Corner radii and softness stay fractional (they're AA'd analytically).
//  - Soft rects (shadows) are not snapped.
push_rect :: (p: Rect_Params) {
	assert(g.in_frame, "push_rect outside begin_frame/end_frame");
	sc := g.scale;
	d: Rect;
	if p.softness > 0 {
		d = .{p.dst.x0 * sc, p.dst.y0 * sc, p.dst.x1 * sc, p.dst.y1 * sc};
	} else {
		d = snap_rect(p.dst);
		if d.x1 <= d.x0 && p.dst.x1 > p.dst.x0 { d.x1 = d.x0 + 1; }
		if d.y1 <= d.y0 && p.dst.y1 > p.dst.y0 { d.y1 = d.y0 + 1; }
	}
	if d.x1 <= d.x0 || d.y1 <= d.y0 { return; }
	push_rect_px(p, d);
}
#scope_module

// dst already in pixels (glyphs).
push_rect_px :: (p: Rect_Params, d: Rect) {
	sc := g.scale;
	soft := p.softness * sc;
	// Cull against clip (quad extent includes softness).
	clip := g.clip_stack[len(g.clip_stack) - 1];
	if d.x1 + soft <= cast(float32)(clip[0]) || d.x0 - soft >= cast(float32)(clip[2]) || d.y1 + soft <= cast(float32)(clip[1]) || d.y0 - soft >= cast(float32)(clip[3]) { return; }
	if clip[2] <= clip[0] || clip[3] <= clip[1] { return; }

	inst: Instance;
	inst.dst = .{d.x0, d.y0, d.x1, d.y1};
	tex_kind: float32 = 0;
	tex2: Texture;
	if p.tex != 0 && cast(int)(p.tex) < len(g.textures) && g.textures[p.tex].alive {
		t := g.textures[p.tex];
		src := p.src;
		if src == .{} { src = .{0, 0, cast(float32)(t.w), cast(float32)(t.h)}; }
		inst.src = .{src.x0, src.y0, src.x1, src.y1};
		tex_kind = ifx t.format == .R8 then 1 else 2;
		if p.yuv != .None && p.tex2 != 0 && cast(int)(p.tex2) < len(g.textures) && g.textures[p.tex2].alive {
			tex_kind = 3;
			tex2 = p.tex2;
		}
	} else if p.tex != 0 {
		g.diag.dead_tex_draws += 1;
		g.diag.last_dead_tex = p.tex;
	}
	for c, i: p.colors { inst.colors[i] = premul(c); }
	half_min := min(d.x1 - d.x0, d.y1 - d.y0) * 0.5;
	for r, i: p.radii { inst.radii[i] = min(max(r * sc, 0), half_min); }
	border: float32 = 0;
	if p.border > 0 { border = max(1, math.round(p.border * sc)); }
	inst.clip = .{cast(float32)(clip[0]), cast(float32)(clip[1]), cast(float32)(clip[2]), cast(float32)(clip[3])};

	// Batch: the texture needs a slot in the current draw (untextured rects fit anywhere), and video
	// needs its second plane bound; otherwise start a new draw.
	tex := ifx tex_kind != 0 then p.tex else 0;
	nb := len(g.batches);
	b := ifx nb > 0 then *g.batches[nb - 1] else null;
	slot := -1;
	if b != null && (tex2 == 0 || b.tex2 == 0 || b.tex2 == tex2) {
		if tex == 0 {
			slot = 0;
		} else {
			for i: 0..b.n_slots-1 {
				if b.slots[i] == tex {
					slot = cast(int)(i);
					break;
				}
			}
			if slot < 0 && b.n_slots < TEX_SLOTS {
				slot = cast(int)(b.n_slots);
				b.slots[slot] = tex;
				b.n_slots += 1;
			}
		}
	}
	if slot < 0 {
		append(*g.batches, Batch.{first = cast(u32)(len(g.instances))});
		b = *g.batches[nb];
		slot = 0;
		if tex != 0 {
			b.slots[0] = tex;
			b.n_slots = 1;
		}
	}
	if tex2 != 0 { b.tex2 = tex2; }
	inst.params = .{border, soft, tex_kind + 4 * cast(float32)(slot), cast(float32)(p.yuv)};
	append(*g.instances, inst);
	b.count += 1;
}
#scope_file

// ---------------------------------------------------------------------------
// Textures

// Straight-alpha RGBA rows (stride bytes apart) to a tightly packed premultiplied copy. The copy comes
// from the heap, not temp storage, because images can be tens of megabytes.
premultiplied :: (pixels: []u8, w: int, h: int, stride: int) -> []u8 {
	out := make_slice(u8, w * h * 4);
	for y: 0..h-1 {
		src := sub(sub_from(pixels, y * stride), 0, w * 4);
		dst := sub(sub_from(out, y * w * 4), 0, w * 4);
		{ x := 0;
		while x < w * 4 {
			a := cast(u32)(src[x + 3]);
			// c*a/255 rounded to nearest, without a divide (exact for all 8-bit inputs).
			mul :: inline (c: u32, a: u32) -> u8 #no_context {
				t := c * a + 128;
				return cast(u8)((t + (t >> 8)) >> 8);
			};
			dst[x + 0] = mul(cast(u32)(src[x + 0]), a);
			dst[x + 1] = mul(cast(u32)(src[x + 1]), a);
			dst[x + 2] = mul(cast(u32)(src[x + 2]), a);
			dst[x + 3] = cast(u8)(a);
			x += 4;
} }
	}
	return out;
}
#scope_export

texture_create :: (w: int, h: int, format: Texture_Format, pixels: []u8 = .{}) -> Texture {
	px := pixels;
	if format == .RGBA8 && pixels != null {
		px = premultiplied(pixels, w, h, w * 4);
	}
	defer if format == .RGBA8 && pixels != null { delete(px); }
	native := _backend_texture_create(cast(s32)(w), cast(s32)(h), format, px);
	if native == null {
		g.diag.tex_create_fails += 1;
		return 0;
	}
	slot := Tex_Slot.{native = native, w = cast(s32)(w), h = cast(s32)(h), format = format, alive = true};
	if len(g.free_textures) > 0 {
		t := pop(*g.free_textures);
		g.textures[t] = slot;
		return t;
	}
	append(*g.textures, slot);
	return Texture(len(g.textures) - 1);
}

texture_from_rgba :: (w: int, h: int, pixels: []u8) -> Texture {
	return texture_create(w, h, .RGBA8, pixels);
}

// Replace a sub-rectangle. `pixels` is tightly packed unless stride (bytes per row) is given.
texture_update :: (t: Texture, x: int, y: int, w: int, h: int, pixels: []u8, stride: int = 0) {
	if t == 0 || cast(int)(t) >= len(g.textures) || !g.textures[t].alive { return; }
	slot := g.textures[t];
	bpp := format_bpp(slot.format);
	row := ifx stride != 0 then stride else w * bpp;
	assert(len(pixels) >= row * (h - 1) + w * bpp);
	if slot.format == .RGBA8 {
		px := premultiplied(pixels, w, h, row);
		defer delete(px);
		_backend_texture_update(slot.native, slot.format, cast(s32)(x), cast(s32)(y), cast(s32)(w), cast(s32)(h), px, cast(s32)(w * 4));
		return;
	}
	_backend_texture_update(slot.native, slot.format, cast(s32)(x), cast(s32)(y), cast(s32)(w), cast(s32)(h), pixels, cast(s32)(row));
}

// Wrap a texture owned by someone else (e.g. a CVMetalTexture's MTLTexture for
// zero-copy video). gfx never frees `native`; when the handle is destroyed and
// no in-flight frame can still use it, release(user) is called (main thread).
texture_wrap_native :: (native: *void, w: int, h: int, format: Texture_Format, release: (user: *void), user: *void) -> Texture {
	slot := Tex_Slot.{native = native, w = cast(s32)(w), h = cast(s32)(h), format = format, alive = true, release = release, user = user};
	if slot.release == null { slot.release = (user: *void) {}; }
	if len(g.free_textures) > 0 {
		t := pop(*g.free_textures);
		g.textures[t] = slot;
		return t;
	}
	append(*g.textures, slot);
	return Texture(len(g.textures) - 1);
}

// The GPU device (MTLDevice on macOS, ID3D11Device on Windows).
native_device :: () -> *void {return _backend_native_device();}

// Draw an NV12 frame (Y plane + CbCr plane).
video :: (dst: Rect, y_plane: Texture, cbcr_plane: Texture, matrix_: Yuv_Matrix, radius: float32 = 0, tint: Color = .{1, 1, 1, 1}) {
	push_rect(.{dst = dst, tex = y_plane, tex2 = cbcr_plane, yuv = matrix_, colors = .{tint, tint, tint, tint}, radii = radius});
}
#scope_module

format_bpp :: (f: Texture_Format) -> int {
	if f == {
	case .R8; return 1;
	case .RG8; return 2;
	case .RGBA8; return 4;
	}
	return 4;
}

destroy_now :: (d: Pending_Destroy) {
	if d.release != null {
		d.release(d.user);
	} else if d.native != null {
		_backend_texture_destroy(d.native);
	}
}
#scope_export

texture_destroy :: (t: Texture) {
	if t == 0 || cast(int)(t) >= len(g.textures) || !g.textures[t].alive { return; }
	s := g.textures[t];
	append(*g.destroy_queue, Pending_Destroy.{s.native, g.frame_index, s.release, s.user});
	g.textures[t] = .{};
	append(*g.free_textures, t);
}

texture_size :: (t: Texture) -> [2]int {
	if t == 0 || cast(int)(t) >= len(g.textures) { return .{}; }
	return .{cast(int)(g.textures[t].w), cast(int)(g.textures[t].h)};
}

// Reads back the last completed frame as tightly packed RGBA8 (straight alpha),
// top row first. Works in headless mode (and windowed, of the last frame).
read_pixels :: (allocator := context.allocator) -> []u8, int, int {
	pixels: []u8;
	w: int;
	h: int;
	{ __r2, __r3, __r4 := _backend_read_pixels(allocator); return __r2, __r3, __r4; }
}

