Color :: Vector4; // straight-alpha sRGB, 0..1

Rect :: struct {
    x0, y0, x1, y1: float32;
}

Texture :: u32; // 0 = none

Texture_Format :: enum u8 {
    RGBA8; // callers pass straight alpha; stored premultiplied so filtering never bleeds colour from alpha-0 texels
    R8;    // coverage / alpha mask (tinted by color); also the Y plane of NV12
    RG8;   // two-channel (CbCr plane of NV12)
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
    dst: Rect;          // points
    src: Rect;          // texels; zero = whole texture (when tex != 0)
    tex: Texture;
    colors: [4]Color;   // TL, TR, BL, BR
    radii: [4]float32;  // TL, TR, BL, BR (points)
    border: float32;    // 0 = filled; else stroke width (points), drawn inside dst
    softness: float32;  // edge blur radius (points), for shadows; quad grows by this much
    tex2: Texture;      // second plane for yuv (CbCr, any size; sampled with the same normalized uv)
    yuv: Yuv_Matrix;
}

rect :: (dst: Rect, color: Color, radius: float32 = 0) {
    push_rect(.{dst = dst, colors = .[color, color, color, color], radii = .[radius, radius, radius, radius]});
}

rect_border :: (dst: Rect, color: Color, thickness: float32, radius: float32 = 0) {
    push_rect(.{dst = dst, colors = .[color, color, color, color], radii = .[radius, radius, radius, radius], border = thickness});
}

// Shadow under `dst`: blur radius `blur`, offset applied by caller.
rect_shadow :: (dst: Rect, color: Color, blur: float32, radius: float32 = 0) {
    push_rect(.{dst = dst, colors = .[color, color, color, color], radii = .[radius, radius, radius, radius], softness = blur});
}

image :: (dst: Rect, tex: Texture, tint := Color.{1, 1, 1, 1}, radius: float32 = 0) {
    push_rect(.{dst = dst, tex = tex, colors = .[tint, tint, tint, tint], radii = .[radius, radius, radius, radius]});
}

// Draw an NV12 frame (Y plane + CbCr plane).
video :: (dst: Rect, y_plane: Texture, cbcr_plane: Texture, matrix_: Yuv_Matrix, radius: float32 = 0, tint := Color.{1, 1, 1, 1}) {
    push_rect(.{dst = dst, tex = y_plane, tex2 = cbcr_plane, yuv = matrix_, colors = .[tint, tint, tint, tint], radii = .[radius, radius, radius, radius]});
}

rect_intersect :: (a: Rect, b: Rect) -> Rect {
    return .{max(a.x0, b.x0), max(a.y0, b.y0), min(a.x1, b.x1), min(a.y1, b.y1)};
}

rect_empty :: (r: Rect) -> bool { return r.x1 <= r.x0 || r.y1 <= r.y0; }

rgba :: (hex: u32) -> Color {
    return .{cast(float32) ((hex >> 24) & 0xff) / 255, cast(float32) ((hex >> 16) & 0xff) / 255, cast(float32) ((hex >> 8) & 0xff) / 255, cast(float32) (hex & 0xff) / 255};
}

rgb :: (hex: u32) -> Color {
    return .{cast(float32) ((hex >> 16) & 0xff) / 255, cast(float32) ((hex >> 8) & 0xff) / 255, cast(float32) (hex & 0xff) / 255, 1};
}

// GPU instance layout (shared with the shaders; 144 bytes).
Instance :: struct {
    dst: [4]float32;       // pixels x0 y0 x1 y1 (quad = dst grown by softness)
    src: [4]float32;       // texels
    colors: [4][4]float32; // premultiplied, TL TR BL BR
    radii: [4]float32;     // pixels TL TR BL BR
    params: [4]float32;    // border px, softness px, tex kind (0 none, 1 R8 mask, 2 RGBA, 3 NV12) + 4 * slot, yuv matrix
    clip: [4]float32;      // pixels x0 y0 x1 y1; the vertex shader clamps the quad to it
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

FRAMES_IN_FLIGHT :: 3;

// Running totals of things that should never happen; the app logs them when they change.
Diag :: struct {
    dead_tex_draws: int; // rects whose texture handle was not alive (drawn untextured)
    last_dead_tex: Texture;
    tex_create_fails: int;
    present_fails: int;
    last_hresult: s32;   // of the latest failed backend call
    device_removed: s32; // GetDeviceRemovedReason after a failure; 0 = device fine
    atlas_resets: int;
}

Frame_Stats :: struct {
    instances: int;
    draw_calls: int;
    frames: u64;    // total frames submitted
    gpu_ns: s64;    // GPU time of the latest frame whose timer finished (a few frames back); 0 if unknown
    gpu_frame: u64; // which frame (frame_index) gpu_ns belongs to
}

init :: () -> bool {
    if g.initialized return true;
    array_reserve(*g.instances, 16 * 1024);
    array_reserve(*g.batches, 256);
    array_reserve(*g.clip_stack, 32);
    array_reserve(*g.textures, 64);
    array_add(*g.textures, .{}); // handle 0 = none
    g.scale = platform.dpi_scale();
    if !backend_init() return false;
    white := u8.[255, 255, 255, 255];
    g.white = texture_create(1, 1, .RGBA8, white);
    text_init();
    g.initialized = true;
    return true;
}

shutdown :: () {
    if !g.initialized return;
    text_shutdown();
    backend_wait_idle();
    for g.destroy_queue destroy_now(it);
    for g.textures if it.alive && it_index != 0 destroy_now(.{native = it.native, release = it.release, user = it.user});
    backend_shutdown();
    array_free(g.instances);
    array_free(g.batches);
    array_free(g.clip_stack);
    array_free(g.textures);
    array_free(g.free_textures);
    array_free(g.destroy_queue);
    g = .{};
}

stats :: () -> Frame_Stats { return g.stats; }
diag :: () -> Diag { return g.diag; }

// Live textures (for benchmarks: each distinct texture costs per-draw-call driver work).
texture_count :: () -> int {
    n := 0;
    for g.textures if it.alive n += 1;
    return n;
}

// Blocks until the GPU has finished every submitted frame. For latency measurement and shutdown only.
wait_gpu :: () { backend_wait_idle(); }

// Points -> pixels factor for the current frame.
scale :: () -> float32 { return g.scale; }

begin_frame :: (clear: Color) {
    assert(!g.in_frame);
    g.in_frame = true;
    g.scale = platform.dpi_scale();
    g.fb_size = platform.framebuffer_size();
    g.clear = clear;
    g.instances.count = 0;
    g.batches.count = 0;
    g.clip_stack.count = 0;
    array_add(*g.clip_stack, .[0, 0, g.fb_size[0], g.fb_size[1]]);
    text_begin_frame();
}

end_frame :: () {
    assert(g.in_frame);
    g.in_frame = false;
    g.stats.instances = g.instances.count;
    g.stats.draw_calls = g.batches.count;
    backend_submit(g.instances, g.batches, g.clear, g.fb_size);
    g.frame_index += 1;
    g.stats.frames += 1;
    // Release textures that no in-flight frame can reference anymore.
    i := 0;
    while i < g.destroy_queue.count {
        d := g.destroy_queue[i];
        if g.frame_index >= d.frame + FRAMES_IN_FLIGHT + 1 {
            destroy_now(d);
            array_unordered_remove_by_index(*g.destroy_queue, i);
        } else {
            i += 1;
        }
    }
    text_end_frame();
}

push_clip :: (r: Rect) {
    px := snap_rect(r);
    top := peek(g.clip_stack);
    cur := s32.[max(cast(s32) px.x0, top[0]), max(cast(s32) px.y0, top[1]), min(cast(s32) px.x1, top[2]), min(cast(s32) px.y1, top[3])];
    cur[2] = max(cur[2], cur[0]);
    cur[3] = max(cur[3], cur[1]);
    array_add(*g.clip_stack, cur);
}

pop_clip :: () {
    assert(g.clip_stack.count > 1, "pop_clip without push_clip");
    pop(*g.clip_stack);
}

// Current clip in points.
current_clip :: () -> Rect {
    c := peek(g.clip_stack);
    return .{cast(float32) c[0] / g.scale, cast(float32) c[1] / g.scale, cast(float32) c[2] / g.scale, cast(float32) c[3] / g.scale};
}

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
        if d.x1 <= d.x0 && p.dst.x1 > p.dst.x0  d.x1 = d.x0 + 1;
        if d.y1 <= d.y0 && p.dst.y1 > p.dst.y0  d.y1 = d.y0 + 1;
    }
    if d.x1 <= d.x0 || d.y1 <= d.y0 return;
    push_rect_px(p, d);
}

texture_create :: (w: int, h: int, format: Texture_Format, pixels: []u8 = .[]) -> Texture {
    px := pixels;
    premul := format == .RGBA8 && pixels.data != null;
    if premul px = premultiplied(pixels, w, h, w * 4);
    defer if premul array_free(px);
    native := backend_texture_create(cast(s32) w, cast(s32) h, format, px);
    if native == null {
        g.diag.tex_create_fails += 1;
        return 0;
    }
    return add_texture(.{native = native, w = cast(s32) w, h = cast(s32) h, format = format, alive = true});
}

texture_from_rgba :: (w: int, h: int, pixels: []u8) -> Texture {
    return texture_create(w, h, .RGBA8, pixels);
}

// Replace a sub-rectangle. `pixels` is tightly packed unless stride (bytes per row) is given.
texture_update :: (t: Texture, x: int, y: int, w: int, h: int, pixels: []u8, stride := 0) {
    if !texture_alive(t) return;
    slot := g.textures[t];
    bpp := format_bpp(slot.format);
    row := ifx stride then stride else w * bpp;
    assert(pixels.count >= row * (h - 1) + w * bpp);
    if slot.format == .RGBA8 {
        px := premultiplied(pixels, w, h, row);
        defer array_free(px);
        backend_texture_update(slot.native, slot.format, cast(s32) x, cast(s32) y, cast(s32) w, cast(s32) h, px, cast(s32) (w * 4));
        return;
    }
    backend_texture_update(slot.native, slot.format, cast(s32) x, cast(s32) y, cast(s32) w, cast(s32) h, pixels, cast(s32) row);
}

// Wrap a texture owned by someone else (e.g. a CVMetalTexture's MTLTexture for
// zero-copy video). gfx never frees `native`; when the handle is destroyed and
// no in-flight frame can still use it, release(user) is called (main thread).
texture_wrap_native :: (native: *void, w: int, h: int, format: Texture_Format, release: (user: *void), user: *void) -> Texture {
    return add_texture(.{native = native, w = cast(s32) w, h = cast(s32) h, format = format, alive = true,
        release = ifx release then release else (user: *void) {}, user = user});
}

// The GPU device (MTLDevice on macOS, ID3D11Device on Windows).
native_device :: () -> *void { return backend_native_device(); }

texture_destroy :: (t: Texture) {
    if !texture_alive(t) return;
    s := g.textures[t];
    array_add(*g.destroy_queue, .{s.native, g.frame_index, s.release, s.user});
    g.textures[t] = .{};
    array_add(*g.free_textures, t);
}

texture_size :: (t: Texture) -> [2]int {
    if t == 0 || t >= g.textures.count return .[0, 0];
    return .[g.textures[t].w, g.textures[t].h];
}

// Reads back the last completed frame as tightly packed RGBA8 (straight alpha),
// top row first. Works in headless mode (and windowed, of the last frame).
read_pixels :: (allocator := context.allocator) -> []u8, int, int {
    pixels, w, h := backend_read_pixels(allocator);
    return pixels, w, h;
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

g: struct {
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
};

texture_alive :: (t: Texture) -> bool { return t != 0 && t < g.textures.count && g.textures[t].alive; }

add_texture :: (slot: Tex_Slot) -> Texture {
    if g.free_textures.count {
        t := pop(*g.free_textures);
        g.textures[t] = slot;
        return t;
    }
    array_add(*g.textures, slot);
    return cast(Texture) (g.textures.count - 1);
}

snap_rect :: (r: Rect) -> Rect {
    sc := g.scale;
    return .{round(r.x0 * sc), round(r.y0 * sc), round(r.x1 * sc), round(r.y1 * sc)};
}

premul :: inline (c: Color) -> [4]float32 {
    return .[c.x * c.w, c.y * c.w, c.z * c.w, c.w];
}

// dst already in pixels (glyphs).
push_rect_px :: (p: Rect_Params, d: Rect) {
    sc := g.scale;
    soft := p.softness * sc;
    // Cull against clip (quad extent includes softness).
    clip := peek(g.clip_stack);
    cx0, cy0, cx1, cy1 := cast(float32) clip[0], cast(float32) clip[1], cast(float32) clip[2], cast(float32) clip[3];
    if d.x1 + soft <= cx0 || d.x0 - soft >= cx1 || d.y1 + soft <= cy0 || d.y0 - soft >= cy1 return;
    if clip[2] <= clip[0] || clip[3] <= clip[1] return;

    inst: Instance;
    inst.dst = .[d.x0, d.y0, d.x1, d.y1];
    tex_kind: float32 = 0;
    tex2: Texture;
    if texture_alive(p.tex) {
        t := g.textures[p.tex];
        src := p.src;
        if src.x0 == 0 && src.y0 == 0 && src.x1 == 0 && src.y1 == 0  src = .{0, 0, xx t.w, xx t.h};
        inst.src = .[src.x0, src.y0, src.x1, src.y1];
        tex_kind = ifx t.format == .R8 then 1.0 else 2.0;
        if p.yuv != .None && texture_alive(p.tex2) {
            tex_kind = 3;
            tex2 = p.tex2;
        }
    } else if p.tex != 0 {
        g.diag.dead_tex_draws += 1;
        g.diag.last_dead_tex = p.tex;
    }
    for p.colors inst.colors[it_index] = premul(it);
    half_min := min(d.x1 - d.x0, d.y1 - d.y0) * 0.5;
    for p.radii inst.radii[it_index] = min(max(it * sc, 0), half_min);
    border: float32 = 0;
    if p.border > 0  border = max(1.0, round(p.border * sc));
    inst.clip = .[cx0, cy0, cx1, cy1];

    // Batch: the texture needs a slot in the current draw (untextured rects fit anywhere), and video
    // needs its second plane bound; otherwise start a new draw.
    tex := ifx tex_kind != 0 then p.tex else 0;
    b := ifx g.batches.count then *g.batches[g.batches.count - 1] else null;
    slot := -1;
    if b && (tex2 == 0 || b.tex2 == 0 || b.tex2 == tex2) {
        if tex == 0 {
            slot = 0;
        } else {
            for 0..cast(int) b.n_slots - 1 if b.slots[it] == tex { slot = it; break; }
            if slot < 0 && b.n_slots < TEX_SLOTS {
                slot = b.n_slots;
                b.slots[slot] = tex;
                b.n_slots += 1;
            }
        }
    }
    if slot < 0 {
        b = array_add(*g.batches);
        b.first = cast(u32) g.instances.count;
        slot = 0;
        if tex {
            b.slots[0] = tex;
            b.n_slots = 1;
        }
    }
    if tex2  b.tex2 = tex2;
    inst.params = .[border, soft, tex_kind + 4 * cast(float32) slot, cast(float32) p.yuv];
    array_add(*g.instances, inst);
    b.count += 1;
}

// Straight-alpha RGBA rows (stride bytes apart) to a tightly packed premultiplied copy. The copy comes
// from the heap, not temp storage, because images can be tens of megabytes.
premultiplied :: (pixels: []u8, w: int, h: int, stride: int) -> []u8 {
    // c*a/255 rounded to nearest, without a divide (exact for all 8-bit inputs).
    mul :: inline (c: u8, a: u32) -> u8 {
        t := cast(u32) c * a + 128;
        return cast(u8) ((t + (t >> 8)) >> 8);
    }
    out := NewArray(w * h * 4, u8, initialized = false);
    for y: 0..h-1 {
        src := pixels.data + y * stride;
        dst := out.data + y * w * 4;
        for x: 0..w-1 {
            i := x * 4;
            a := cast(u32) src[i + 3];
            dst[i + 0] = mul(src[i + 0], a);
            dst[i + 1] = mul(src[i + 1], a);
            dst[i + 2] = mul(src[i + 2], a);
            dst[i + 3] = cast(u8) a;
        }
    }
    return out;
}

format_bpp :: (f: Texture_Format) -> int {
    if f == {
        case .R8;  return 1;
        case .RG8; return 2;
    }
    return 4;
}

destroy_now :: (d: Pending_Destroy) {
    if d.release      d.release(d.user);
    else if d.native  backend_texture_destroy(d.native);
}
