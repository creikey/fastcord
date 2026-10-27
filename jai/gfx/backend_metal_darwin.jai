#scope_module

backend_init :: () -> bool {
    pool := objc.new_obj("NSAutoreleasePool");
    defer msg(Void, pool, "drain");

    mt.device = MTLCreateSystemDefaultDevice();
    if mt.device == null return false;
    mt.queue = msg(Id, mt.device, "newCommandQueue");

    err: Id;
    lib := msg(Id, mt.device, "newLibraryWithSource:options:error:", nsstr(METAL_SHADER_SRC), cast(Id) null, *err);
    if lib == null {
        log_error("gfx: metal shader: %", err_str(err));
        return false;
    }
    defer msg(Void, lib, "release");
    vs := msg(Id, lib, "newFunctionWithName:", nsstr("vs_main"));
    fs := msg(Id, lib, "newFunctionWithName:", nsstr("fs_main"));
    defer msg(Void, vs, "release");
    defer msg(Void, fs, "release");

    desc := objc.new_obj("MTLRenderPipelineDescriptor");
    defer msg(Void, desc, "release");
    msg(Void, desc, "setVertexFunction:", vs);
    msg(Void, desc, "setFragmentFunction:", fs);
    ca := msg(Id, msg(Id, desc, "colorAttachments"), "objectAtIndexedSubscript:", cast(u64) 0);
    msg(Void, ca, "setPixelFormat:", MTLPixelFormat.BGRA8Unorm);
    msg(Void, ca, "setBlendingEnabled:", true);
    msg(Void, ca, "setSourceRGBBlendFactor:", MTLBlendFactorOne);
    msg(Void, ca, "setDestinationRGBBlendFactor:", MTLBlendFactorOneMinusSourceAlpha);
    msg(Void, ca, "setSourceAlphaBlendFactor:", MTLBlendFactorOne);
    msg(Void, ca, "setDestinationAlphaBlendFactor:", MTLBlendFactorOneMinusSourceAlpha);
    mt.pipeline = msg(Id, mt.device, "newRenderPipelineStateWithDescriptor:error:", desc, *err);
    if mt.pipeline == null {
        log_error("gfx: metal pipeline: %", err_str(err));
        return false;
    }

    if !platform.is_headless() {
        mt.layer = platform.native_metal_layer();
        if mt.layer == null return false;
        msg(Void, mt.layer, "setDevice:", mt.device);
        msg(Void, mt.layer, "setPixelFormat:", MTLPixelFormat.BGRA8Unorm);
    }
    for * mt.ring ensure_slot(it, 4096 * size_of(Instance));
    return true;
}

backend_native_device :: () -> *void { return mt.device; }

backend_wait_idle :: () {
    if mt.last_cmd  msg(Void, mt.last_cmd, "waitUntilCompleted");
}

backend_shutdown :: () {
    if mt.last_cmd {
        msg(Void, mt.last_cmd, "waitUntilCompleted");
        msg(Void, mt.last_cmd, "release");
    }
    for mt.ring {
        if it.cmdbuf  msg(Void, it.cmdbuf, "release");
        if it.buf     msg(Void, it.buf, "release");
    }
    if mt.offscreen  msg(Void, mt.offscreen, "release");
    if mt.readback   msg(Void, mt.readback, "release");
    msg(Void, mt.pipeline, "release");
    msg(Void, mt.queue, "release");
    msg(Void, mt.device, "release");
    mt = .{};
}

backend_submit :: (insts: []Instance, batches: []Batch, clear: Color, fb: [2]s32) {
    if fb[0] <= 0 || fb[1] <= 0 return;
    pool := objc.new_obj("NSAutoreleasePool");
    defer msg(Void, pool, "drain");

    slot := *mt.ring[mt.ring_idx];
    mt.ring_idx = (mt.ring_idx + 1) % FRAMES_IN_FLIGHT;
    if slot.cmdbuf {
        msg(Void, slot.cmdbuf, "waitUntilCompleted"); // normally long done; bounds CPU run-ahead
        msg(Void, slot.cmdbuf, "release");
        slot.cmdbuf = null;
    }
    bytes := insts.count * size_of(Instance);
    ensure_slot(slot, bytes);
    if bytes > 0  memcpy(msg(*void, slot.buf, "contents"), insts.data, bytes);

    cmd := msg(Id, mt.queue, "commandBuffer");
    target, drawable: Id;
    if mt.layer {
        // Acquire as late as possible (after CPU work) for lowest latency.
        drawable = msg(Id, mt.layer, "nextDrawable");
        if drawable == null return;
        target = msg(Id, drawable, "texture");
    } else {
        ensure_offscreen(fb);
        target = mt.offscreen;
    }
    tw := cast(float32) msg(u64, target, "width");
    th := cast(float32) msg(u64, target, "height");

    rp := msg(Id, objc.cls("MTLRenderPassDescriptor"), "renderPassDescriptor");
    att := msg(Id, msg(Id, rp, "colorAttachments"), "objectAtIndexedSubscript:", cast(u64) 0);
    msg(Void, att, "setTexture:", target);
    msg(Void, att, "setLoadAction:", MTLLoadActionClear);
    msg(Void, att, "setStoreAction:", MTLStoreActionStore);
    cc := premul(clear);
    msg(Void, att, "setClearColor:", MTLClearColor.{cc[0], cc[1], cc[2], cc[3]});

    enc := msg(Id, cmd, "renderCommandEncoderWithDescriptor:", rp);
    msg(Void, enc, "setRenderPipelineState:", mt.pipeline);
    u := float32.[tw, th, 0, 0]; // viewport, pad
    msg(Void, enc, "setVertexBytes:length:atIndex:", cast(*void) *u, cast(u64) size_of(type_of(u)), cast(u64) 1);
    msg(Void, enc, "setVertexBuffer:offset:atIndex:", slot.buf, cast(u64) 0, cast(u64) 0);

    white := cast(Id) g.textures[g.white].native;
    bound: [TEX_SLOTS + 1]Id;
    for * bound {
        msg(Void, enc, "setFragmentTexture:atIndex:", white, cast(u64) it_index);
        it.* = white;
    }
    for b: batches {
        for i: 0..cast(int) b.n_slots - 1 {
            tex := cast(Id) g.textures[b.slots[i]].native;
            if tex != bound[i] {
                msg(Void, enc, "setFragmentTexture:atIndex:", tex, cast(u64) i);
                bound[i] = tex;
            }
        }
        tex2 := cast(Id) g.textures[ifx b.tex2 then b.tex2 else g.white].native;
        if tex2 != bound[TEX_SLOTS] {
            msg(Void, enc, "setFragmentTexture:atIndex:", tex2, cast(u64) TEX_SLOTS);
            bound[TEX_SLOTS] = tex2;
        }
        msg(Void, enc, "setVertexBufferOffset:atIndex:", cast(u64) b.first * size_of(Instance), cast(u64) 0);
        msg(Void, enc, "drawPrimitives:vertexStart:vertexCount:instanceCount:", MTLPrimitiveTypeTriangleStrip, cast(u64) 0, cast(u64) 4, cast(u64) b.count);
    }
    msg(Void, enc, "endEncoding");

    if drawable && msg(bool, mt.layer, "presentsWithTransaction") {
        // Live resize: present synchronously within the window's CA transaction.
        msg(Void, cmd, "commit");
        msg(Void, cmd, "waitUntilScheduled");
        msg(Void, drawable, "present");
    } else {
        if drawable  msg(Void, cmd, "presentDrawable:", drawable);
        msg(Void, cmd, "commit");
    }
    msg(Id, cmd, "retain");
    slot.cmdbuf = cmd;
    if mt.last_cmd  msg(Void, mt.last_cmd, "release");
    msg(Id, cmd, "retain");
    mt.last_cmd = cmd;
}

backend_texture_create :: (w: s32, h: s32, format: Texture_Format, pixels: []u8) -> *void {
    pool := objc.new_obj("NSAutoreleasePool");
    defer msg(Void, pool, "drain");
    pf := ifx format == .R8 then MTLPixelFormat.R8Unorm else ifx format == .RG8 then MTLPixelFormat.RG8Unorm else .RGBA8Unorm;
    t := msg(Id, mt.device, "newTextureWithDescriptor:", tex_desc(pf, w, h, MTLTextureUsageShaderRead, MTLStorageModeManaged));
    if t == null return null;
    if pixels  backend_texture_update(t, format, 0, 0, w, h, pixels, w * cast(s32) format_bpp(format));
    return t;
}

backend_texture_update :: (native: *void, format: Texture_Format, x: s32, y: s32, w: s32, h: s32, pixels: []u8, stride: s32) {
    region := MTLRegion.{cast(u64) x, cast(u64) y, 0, cast(u64) w, cast(u64) h, 1};
    msg(Void, native, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", region, cast(u64) 0, pixels.data, cast(u64) stride);
}

backend_texture_destroy :: (native: *void) {
    if native  msg(Void, native, "release");
}

backend_read_pixels :: (allocator: Allocator) -> []u8, int, int {
    if mt.offscreen == null return .[], 0, 0;
    pool := objc.new_obj("NSAutoreleasePool");
    defer msg(Void, pool, "drain");
    w, h := cast(int) mt.off_size[0], cast(int) mt.off_size[1];
    bytes := w * h * 4;
    if mt.readback == null || cast(int) msg(u64, mt.readback, "length") < bytes {
        if mt.readback  msg(Void, mt.readback, "release");
        mt.readback = msg(Id, mt.device, "newBufferWithLength:options:", cast(u64) bytes, cast(u64) 0);
    }
    if mt.last_cmd  msg(Void, mt.last_cmd, "waitUntilCompleted");
    cmd := msg(Id, mt.queue, "commandBuffer");
    blit := msg(Id, cmd, "blitCommandEncoder");
    Origin :: struct { x, y, z: u64; }
    Size :: struct { w, h, d: u64; }
    msg(Void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:",
        mt.offscreen, cast(u64) 0, cast(u64) 0, Origin.{}, Size.{cast(u64) w, cast(u64) h, 1}, mt.readback, cast(u64) 0, cast(u64) (w * 4), cast(u64) bytes);
    msg(Void, blit, "endEncoding");
    msg(Void, cmd, "commit");
    msg(Void, cmd, "waitUntilCompleted");
    src := cast(*u8) msg(*void, mt.readback, "contents");
    out := NewArray(bytes, u8, initialized = false,, allocator);
    // BGRA (opaque after clear) -> RGBA
    for i: 0..w*h-1 {
        p := i * 4;
        out[p + 0] = src[p + 2];
        out[p + 1] = src[p + 1];
        out[p + 2] = src[p + 0];
        out[p + 3] = src[p + 3];
    }
    return out, w, h;
}

#scope_file

msg :: objc.msg;
Id :: objc.Id;
Void :: objc.Void;

// The Metal enums and the one C function the backend uses.
MTLPixelFormat :: enum u64 { R8Unorm :: 10; RG8Unorm :: 30; RGBA8Unorm :: 70; BGRA8Unorm :: 80; }
MTLBlendFactorOne :u64: 1;
MTLBlendFactorOneMinusSourceAlpha :u64: 5;
MTLLoadActionClear :u64: 2;
MTLStoreActionStore :u64: 1;
MTLPrimitiveTypeTriangleStrip :u64: 4;
MTLStorageModeManaged :u64: 1;
MTLStorageModePrivate :u64: 2;
MTLTextureUsageShaderRead :u64: 1;
MTLTextureUsageRenderTarget :u64: 4;
MTLClearColor :: struct { r, g, b, a: float64; }
MTLRegion :: struct { x, y, z, w, h, d: u64; }
MTLCreateSystemDefaultDevice :: () -> Id #foreign Metal;

Ring_Slot :: struct {
    buf: Id;    // MTLBuffer
    cap: int;   // bytes
    cmdbuf: Id; // last submission using this slot (retained)
}

mt: struct {
    device: Id;
    queue: Id;
    pipeline: Id;
    layer: Id; // CAMetalLayer
    ring: [FRAMES_IN_FLIGHT]Ring_Slot;
    ring_idx: int;
    offscreen: Id; // headless target
    off_size: [2]s32;
    readback: Id;
    last_cmd: Id;
};

nsstr :: (s: string) -> Id {
    o := msg(Id, objc.cls("NSString"), "alloc");
    o = msg(Id, o, "initWithBytes:length:encoding:", s.data, cast(u64) s.count, cast(u64) 4);
    return msg(Id, o, "autorelease");
}

err_str :: (err: Id) -> string {
    if err == null return "?";
    return to_string(msg(*u8, msg(Id, err, "localizedDescription"), "UTF8String"));
}

ensure_slot :: (r: *Ring_Slot, bytes: int) {
    if r.cap >= bytes && r.buf return;
    if r.buf  msg(Void, r.buf, "release");
    n := max(bytes, r.cap * 2, 64 * 1024);
    // StorageModeShared | CPUCacheModeWriteCombined
    r.buf = msg(Id, mt.device, "newBufferWithLength:options:", cast(u64) n, cast(u64) 1);
    r.cap = n;
}

tex_desc :: (pf: MTLPixelFormat, w: s32, h: s32, usage: u64, storage: u64) -> Id {
    d := msg(Id, objc.cls("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", pf, cast(u64) w, cast(u64) h, false);
    msg(Void, d, "setUsage:", usage);
    msg(Void, d, "setStorageMode:", storage);
    return d;
}

ensure_offscreen :: (size: [2]s32) {
    if mt.offscreen && mt.off_size[0] == size[0] && mt.off_size[1] == size[1] return;
    if mt.offscreen  msg(Void, mt.offscreen, "release");
    d := tex_desc(.BGRA8Unorm, size[0], size[1], MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead, MTLStorageModePrivate);
    mt.offscreen = msg(Id, mt.device, "newTextureWithDescriptor:", d);
    mt.off_size = size;
}
