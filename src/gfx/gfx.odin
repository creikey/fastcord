// Instanced rect renderer (after Ryan Fleury's UI series).
//
// Everything is a rect instance: fills, borders, rounded corners, shadows
// (softness), gradients (per-corner colors), glyphs and images (texture + src).
// One instance buffer per frame; a new draw call only when texture or clip
// changes. Coordinates are points (top-left origin); the renderer converts to
// pixels with platform.dpi_scale() and snaps edges to the pixel grid.
//
// Blending happens in sRGB (gamma) space with premultiplied alpha, like
// Chrome/Skia, so colors and text weight match the official web client.
package gfx

import "fc:platform"
import "core:math"

Color :: [4]f32 // straight-alpha sRGB, 0..1

Rect :: struct {
	x0, y0, x1, y1: f32,
}

Texture :: distinct u32 // 0 = none

Texture_Format :: enum u8 {
	RGBA8, // straight alpha
	R8, // coverage / alpha mask (tinted by color); also the Y plane of NV12
	RG8, // two-channel (CbCr plane of NV12)
}

// Set on Rect_Params (with tex = Y plane, tex2 = CbCr plane) to draw NV12 video.
Yuv_Matrix :: enum u8 {
	None,
	BT601, // video (limited) range
	BT709,
	BT601_Full,
	BT709_Full,
}

Rect_Params :: struct {
	dst:      Rect, // points
	src:      Rect, // texels; zero = whole texture (when tex != 0)
	tex:      Texture,
	colors:   [4]Color, // TL, TR, BL, BR
	radii:    [4]f32, // TL, TR, BL, BR (points)
	border:   f32, // 0 = filled; else stroke width (points), drawn inside dst
	softness: f32, // edge blur radius (points), for shadows; quad grows by this much
	tex2:     Texture, // second plane for yuv (CbCr, any size; sampled with the same normalized uv)
	yuv:      Yuv_Matrix,
}

// Fill helper for the common case.
rect :: proc(dst: Rect, color: Color, radius: f32 = 0) {
	push_rect({dst = dst, colors = {color, color, color, color}, radii = radius})
}

rect_border :: proc(dst: Rect, color: Color, thickness: f32, radius: f32 = 0) {
	push_rect({dst = dst, colors = {color, color, color, color}, radii = radius, border = thickness})
}

// Shadow under `dst`: blur radius `blur`, offset applied by caller.
rect_shadow :: proc(dst: Rect, color: Color, blur: f32, radius: f32 = 0) {
	push_rect({dst = dst, colors = {color, color, color, color}, radii = radius, softness = blur})
}

image :: proc(dst: Rect, tex: Texture, tint: Color = {1, 1, 1, 1}, radius: f32 = 0) {
	push_rect({dst = dst, tex = tex, colors = {tint, tint, tint, tint}, radii = radius})
}

rect_intersect :: proc(a, b: Rect) -> Rect {
	return {max(a.x0, b.x0), max(a.y0, b.y0), min(a.x1, b.x1), min(a.y1, b.y1)}
}

rect_empty :: proc(r: Rect) -> bool {return r.x1 <= r.x0 || r.y1 <= r.y0}

rgba :: proc(hex: u32) -> Color {
	return {f32((hex >> 24) & 0xff) / 255, f32((hex >> 16) & 0xff) / 255, f32((hex >> 8) & 0xff) / 255, f32(hex & 0xff) / 255}
}

rgb :: proc(hex: u32) -> Color {
	return {f32((hex >> 16) & 0xff) / 255, f32((hex >> 8) & 0xff) / 255, f32(hex & 0xff) / 255, 1}
}

// ---------------------------------------------------------------------------
// GPU instance layout (shared with the shaders; 144 bytes)

Instance :: struct #align (16) {
	dst:    [4]f32, // pixels x0 y0 x1 y1 (quad = dst grown by softness)
	src:    [4]f32, // texels
	colors: [4][4]f32, // premultiplied, TL TR BL BR
	radii:  [4]f32, // pixels TL TR BL BR
	params: [4]f32, // border px, softness px, tex kind (0 none, 1 R8 mask, 2 RGBA, 3 NV12) + 4 * slot, yuv matrix
	clip:   [4]f32, // pixels x0 y0 x1 y1; the vertex shader clamps the quad to it
}

// Each draw call binds up to TEX_SLOTS textures and instances pick one by slot, and clipping is per
// instance, so a frame is a few draw calls rather than one per clip rect or texture change: per-draw
// driver work was most of the render time.
TEX_SLOTS :: 16

Batch :: struct {
	first, count: u32,
	slots:        [TEX_SLOTS]Texture,
	n_slots:      u32,
	tex2:         Texture,
}

@(private)
Tex_Slot :: struct {
	native:  rawptr,
	w, h:    i32,
	format:  Texture_Format,
	alive:   bool,
	release: proc(user: rawptr), // external (wrapped) textures
	user:    rawptr,
}

@(private)
Pending_Destroy :: struct {
	native:  rawptr,
	frame:   u64,
	release: proc(user: rawptr),
	user:    rawptr,
}

FRAMES_IN_FLIGHT :: 3

@(private)
G :: struct {
	initialized:   bool,
	in_frame:      bool,
	frame_index:   u64,
	scale:         f32,
	fb_size:       [2]i32,
	clear:         Color,
	instances:     [dynamic]Instance,
	batches:       [dynamic]Batch,
	clip_stack:    [dynamic][4]i32,
	textures:      [dynamic]Tex_Slot, // index = Texture handle; [0] is the 1x1 white texture
	free_textures: [dynamic]Texture,
	destroy_queue: [dynamic]Pending_Destroy,
	white:         Texture,
	stats:         Frame_Stats,
}

Frame_Stats :: struct {
	instances:   int,
	draw_calls:  int,
	frames:      u64, // total frames submitted
	gpu_ns:      i64, // GPU time of the latest frame whose timer finished (a few frames back); 0 if unknown
	gpu_frame:   u64, // which frame (frame_index) gpu_ns belongs to
}

@(private)
g: G

init :: proc() -> bool {
	if g.initialized do return true
	g.instances = make([dynamic]Instance, 0, 16 * 1024)
	g.batches = make([dynamic]Batch, 0, 256)
	g.clip_stack = make([dynamic][4]i32, 0, 32)
	g.textures = make([dynamic]Tex_Slot, 0, 64)
	append(&g.textures, Tex_Slot{}) // handle 0 = none
	g.scale = platform.dpi_scale()
	if !_backend_init() do return false
	white := [4]u8{255, 255, 255, 255}
	g.white = texture_create(1, 1, .RGBA8, white[:])
	text_init()
	g.initialized = true
	return true
}

shutdown :: proc() {
	if !g.initialized do return
	text_shutdown()
	_backend_wait_idle()
	for d in g.destroy_queue do destroy_now(d)
	for s, i in g.textures do if s.alive && i != 0 do destroy_now({native = s.native, release = s.release, user = s.user})
	_backend_shutdown()
	delete(g.instances)
	delete(g.batches)
	delete(g.clip_stack)
	delete(g.textures)
	delete(g.free_textures)
	delete(g.destroy_queue)
	g = {}
}

stats :: proc() -> Frame_Stats {return g.stats}

// Live textures (for benchmarks: each distinct texture costs per-draw-call driver work).
texture_count :: proc() -> int {
	n := 0
	for s in g.textures do if s.alive do n += 1
	return n
}

// Blocks until the GPU has finished every submitted frame. For latency measurement and shutdown only.
wait_gpu :: proc() {_backend_wait_idle()}

// Points -> pixels factor for the current frame.
scale :: proc() -> f32 {return g.scale}

begin_frame :: proc(clear: Color) {
	assert(!g.in_frame)
	g.in_frame = true
	g.scale = platform.dpi_scale()
	g.fb_size = platform.framebuffer_size()
	g.clear = clear
	clear_dynamic_array(&g.instances)
	clear_dynamic_array(&g.batches)
	clear_dynamic_array(&g.clip_stack)
	append(&g.clip_stack, [4]i32{0, 0, g.fb_size.x, g.fb_size.y})
	text_begin_frame()
}

end_frame :: proc() {
	assert(g.in_frame)
	g.in_frame = false
	g.stats.instances = len(g.instances)
	g.stats.draw_calls = len(g.batches)
	_backend_submit(g.instances[:], g.batches[:], g.clear, g.fb_size)
	g.frame_index += 1
	g.stats.frames += 1
	// Release textures that no in-flight frame can reference anymore.
	for i := 0; i < len(g.destroy_queue); {
		d := g.destroy_queue[i]
		if g.frame_index >= d.frame + FRAMES_IN_FLIGHT + 1 {
			destroy_now(d)
			unordered_remove(&g.destroy_queue, i)
		} else {
			i += 1
		}
	}
	text_end_frame()
}

// ---------------------------------------------------------------------------
// Clip

push_clip :: proc(r: Rect) {
	px := snap_rect(r)
	c := [4]i32{i32(px.x0), i32(px.y0), i32(px.x1), i32(px.y1)}
	top := g.clip_stack[len(g.clip_stack) - 1]
	cur := [4]i32{max(c[0], top[0]), max(c[1], top[1]), min(c[2], top[2]), min(c[3], top[3])}
	cur[2] = max(cur[2], cur[0])
	cur[3] = max(cur[3], cur[1])
	append(&g.clip_stack, cur)
}

pop_clip :: proc() {
	assert(len(g.clip_stack) > 1, "pop_clip without push_clip")
	pop(&g.clip_stack)
}

// Current clip in points.
current_clip :: proc() -> Rect {
	c := g.clip_stack[len(g.clip_stack) - 1]
	return {f32(c[0]) / g.scale, f32(c[1]) / g.scale, f32(c[2]) / g.scale, f32(c[3]) / g.scale}
}

// ---------------------------------------------------------------------------
// Rects

@(private)
snap_rect :: proc(r: Rect) -> Rect {
	sc := g.scale
	return {math.round(r.x0 * sc), math.round(r.y0 * sc), math.round(r.x1 * sc), math.round(r.y1 * sc)}
}

@(private)
premul :: #force_inline proc(c: Color) -> [4]f32 {
	return {c.r * c.a, c.g * c.a, c.b * c.a, c.a}
}

// Pixel snapping rules:
//  - Hard-edged rects (softness 0): every edge is rounded to the nearest device
//    pixel, and a non-empty rect is never thinner than 1px. Fills therefore have
//    no AA fringe, and 1px lines stay 1px.
//  - Borders are rounded to whole device pixels (min 1px) so strokes are crisp.
//  - Corner radii and softness stay fractional (they're AA'd analytically).
//  - Soft rects (shadows) are not snapped.
push_rect :: proc(p: Rect_Params) {
	assert(g.in_frame, "push_rect outside begin_frame/end_frame")
	sc := g.scale
	d: Rect
	if p.softness > 0 {
		d = {p.dst.x0 * sc, p.dst.y0 * sc, p.dst.x1 * sc, p.dst.y1 * sc}
	} else {
		d = snap_rect(p.dst)
		if d.x1 <= d.x0 && p.dst.x1 > p.dst.x0 do d.x1 = d.x0 + 1
		if d.y1 <= d.y0 && p.dst.y1 > p.dst.y0 do d.y1 = d.y0 + 1
	}
	if d.x1 <= d.x0 || d.y1 <= d.y0 do return
	push_rect_px(p, d)
}

// dst already in pixels (glyphs).
@(private)
push_rect_px :: proc(p: Rect_Params, d: Rect) {
	sc := g.scale
	soft := p.softness * sc
	// Cull against clip (quad extent includes softness).
	clip := g.clip_stack[len(g.clip_stack) - 1]
	if d.x1 + soft <= f32(clip[0]) || d.x0 - soft >= f32(clip[2]) || d.y1 + soft <= f32(clip[1]) || d.y0 - soft >= f32(clip[3]) do return
	if clip[2] <= clip[0] || clip[3] <= clip[1] do return

	inst: Instance
	inst.dst = {d.x0, d.y0, d.x1, d.y1}
	tex_kind: f32 = 0
	tex2: Texture
	if p.tex != 0 && int(p.tex) < len(g.textures) && g.textures[p.tex].alive {
		t := g.textures[p.tex]
		src := p.src
		if src == {} do src = {0, 0, f32(t.w), f32(t.h)}
		inst.src = {src.x0, src.y0, src.x1, src.y1}
		tex_kind = t.format == .R8 ? 1 : 2
		if p.yuv != .None && p.tex2 != 0 && int(p.tex2) < len(g.textures) && g.textures[p.tex2].alive {
			tex_kind = 3
			tex2 = p.tex2
		}
	}
	for c, i in p.colors do inst.colors[i] = premul(c)
	half_min := min(d.x1 - d.x0, d.y1 - d.y0) * 0.5
	for r, i in p.radii do inst.radii[i] = min(max(r * sc, 0), half_min)
	border: f32 = 0
	if p.border > 0 do border = max(1, math.round(p.border * sc))
	inst.clip = {f32(clip[0]), f32(clip[1]), f32(clip[2]), f32(clip[3])}

	// Batch: the texture needs a slot in the current draw (untextured rects fit anywhere), and video
	// needs its second plane bound; otherwise start a new draw.
	tex := tex_kind != 0 ? p.tex : 0
	nb := len(g.batches)
	b := nb > 0 ? &g.batches[nb - 1] : nil
	slot := -1
	if b != nil && (tex2 == 0 || b.tex2 == 0 || b.tex2 == tex2) {
		if tex == 0 {
			slot = 0
		} else {
			for i in 0 ..< b.n_slots {
				if b.slots[i] == tex {
					slot = int(i)
					break
				}
			}
			if slot < 0 && b.n_slots < TEX_SLOTS {
				slot = int(b.n_slots)
				b.slots[slot] = tex
				b.n_slots += 1
			}
		}
	}
	if slot < 0 {
		append(&g.batches, Batch{first = u32(len(g.instances))})
		b = &g.batches[nb]
		slot = 0
		if tex != 0 {
			b.slots[0] = tex
			b.n_slots = 1
		}
	}
	if tex2 != 0 do b.tex2 = tex2
	inst.params = {border, soft, tex_kind + 4 * f32(slot), f32(p.yuv)}
	append(&g.instances, inst)
	b.count += 1
}

// ---------------------------------------------------------------------------
// Textures

texture_create :: proc(w, h: int, format: Texture_Format, pixels: []u8 = nil) -> Texture {
	native := _backend_texture_create(i32(w), i32(h), format, pixels)
	if native == nil do return 0
	slot := Tex_Slot{native = native, w = i32(w), h = i32(h), format = format, alive = true}
	if len(g.free_textures) > 0 {
		t := pop(&g.free_textures)
		g.textures[t] = slot
		return t
	}
	append(&g.textures, slot)
	return Texture(len(g.textures) - 1)
}

texture_from_rgba :: proc(w, h: int, pixels: []u8) -> Texture {
	return texture_create(w, h, .RGBA8, pixels)
}

// Replace a sub-rectangle. `pixels` is tightly packed unless stride (bytes per row) is given.
texture_update :: proc(t: Texture, x, y, w, h: int, pixels: []u8, stride: int = 0) {
	if t == 0 || int(t) >= len(g.textures) || !g.textures[t].alive do return
	slot := g.textures[t]
	bpp := format_bpp(slot.format)
	row := stride != 0 ? stride : w * bpp
	assert(len(pixels) >= row * (h - 1) + w * bpp)
	_backend_texture_update(slot.native, slot.format, i32(x), i32(y), i32(w), i32(h), pixels, i32(row))
}

// Wrap a texture owned by someone else (e.g. a CVMetalTexture's MTLTexture for
// zero-copy video). gfx never frees `native`; when the handle is destroyed and
// no in-flight frame can still use it, release(user) is called (main thread).
texture_wrap_native :: proc(native: rawptr, w, h: int, format: Texture_Format, release: proc(user: rawptr), user: rawptr) -> Texture {
	slot := Tex_Slot{native = native, w = i32(w), h = i32(h), format = format, alive = true, release = release, user = user}
	if slot.release == nil do slot.release = proc(user: rawptr) {}
	if len(g.free_textures) > 0 {
		t := pop(&g.free_textures)
		g.textures[t] = slot
		return t
	}
	append(&g.textures, slot)
	return Texture(len(g.textures) - 1)
}

// The GPU device (MTLDevice on macOS, ID3D11Device on Windows).
native_device :: proc() -> rawptr {return _backend_native_device()}

// Draw an NV12 frame (Y plane + CbCr plane).
video :: proc(dst: Rect, y_plane, cbcr_plane: Texture, matrix_: Yuv_Matrix, radius: f32 = 0, tint: Color = {1, 1, 1, 1}) {
	push_rect({dst = dst, tex = y_plane, tex2 = cbcr_plane, yuv = matrix_, colors = {tint, tint, tint, tint}, radii = radius})
}

@(private)
format_bpp :: proc(f: Texture_Format) -> int {
	switch f {
	case .R8: return 1
	case .RG8: return 2
	case .RGBA8: return 4
	}
	return 4
}

@(private)
destroy_now :: proc(d: Pending_Destroy) {
	if d.release != nil {
		d.release(d.user)
	} else if d.native != nil {
		_backend_texture_destroy(d.native)
	}
}

texture_destroy :: proc(t: Texture) {
	if t == 0 || int(t) >= len(g.textures) || !g.textures[t].alive do return
	s := g.textures[t]
	append(&g.destroy_queue, Pending_Destroy{s.native, g.frame_index, s.release, s.user})
	g.textures[t] = {}
	append(&g.free_textures, t)
}

texture_size :: proc(t: Texture) -> [2]int {
	if t == 0 || int(t) >= len(g.textures) do return {}
	return {int(g.textures[t].w), int(g.textures[t].h)}
}

// Reads back the last completed frame as tightly packed RGBA8 (straight alpha),
// top row first. Works in headless mode (and windowed, of the last frame).
read_pixels :: proc(allocator := context.allocator) -> (pixels: []u8, w, h: int) {
	return _backend_read_pixels(allocator)
}
