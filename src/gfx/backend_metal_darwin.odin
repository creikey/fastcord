#+build darwin
package gfx

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "fc:platform"
import "fc:platform/objc"
import MTL "vendor:darwin/Metal"

// Messaging goes through fc:platform/objc (intrinsics.objc_send crashes this
// compiler build), so vendor:darwin/Metal is used only for C functions and enums.

@(private = "file")
msg :: objc.msg
@(private = "file")
Id :: objc.Id
@(private = "file")
Void :: objc.Void

@(require) foreign import "system:Metal.framework"

@(private = "file")
Ring_Slot :: struct {
	buf:    Id, // MTLBuffer
	cap:    int, // bytes
	cmdbuf: Id, // last submission using this slot (retained)
}

@(private = "file")
Mtl :: struct {
	device:    Id,
	queue:     Id,
	pipeline:  Id,
	layer:     Id, // CAMetalLayer
	ring:      [FRAMES_IN_FLIGHT]Ring_Slot,
	ring_idx:  int,
	offscreen: Id, // headless target
	off_size:  [2]i32,
	readback:  Id,
	last_cmd:  Id,
}

@(private = "file")
mt: Mtl

@(private = "file")
nsstr :: proc(s: string) -> Id {
	o := msg(Id, objc.cls("NSString"), "alloc")
	o = msg(Id, o, "initWithBytes:length:encoding:", raw_data(s), uint(len(s)), uint(4))
	return msg(Id, o, "autorelease")
}

@(private = "file")
err_str :: proc(err: Id) -> string {
	if err == nil do return "?"
	d := msg(Id, err, "localizedDescription")
	return strings.clone_from_cstring(msg(cstring, d, "UTF8String"), context.temp_allocator)
}

@(private = "file")
pool_push :: proc() -> Id {return objc.new_obj("NSAutoreleasePool")}
@(private = "file")
pool_pop :: proc(p: Id) {msg(Void, p, "drain")}

@(private = "file")
Region :: struct {x, y, z, w, h, d: uint}

@(private)
_backend_init :: proc() -> bool {
	pool := pool_push()
	defer pool_pop(pool)

	mt.device = Id(MTL.CreateSystemDefaultDevice())
	if mt.device == nil do return false
	mt.queue = msg(Id, mt.device, "newCommandQueue")

	err: Id
	lib := msg(Id, mt.device, "newLibraryWithSource:options:error:", nsstr(METAL_SHADER_SRC), Id(nil), &err)
	if lib == nil {
		fmt.eprintln("gfx: metal shader:", err_str(err))
		return false
	}
	defer msg(Void, lib, "release")
	vs := msg(Id, lib, "newFunctionWithName:", nsstr("vs_main"))
	fs := msg(Id, lib, "newFunctionWithName:", nsstr("fs_main"))
	defer msg(Void, vs, "release")
	defer msg(Void, fs, "release")

	desc := objc.new_obj("MTLRenderPipelineDescriptor")
	defer msg(Void, desc, "release")
	msg(Void, desc, "setVertexFunction:", vs)
	msg(Void, desc, "setFragmentFunction:", fs)
	ca := msg(Id, msg(Id, desc, "colorAttachments"), "objectAtIndexedSubscript:", uint(0))
	msg(Void, ca, "setPixelFormat:", uint(MTL.PixelFormat.BGRA8Unorm))
	msg(Void, ca, "setBlendingEnabled:", true)
	msg(Void, ca, "setSourceRGBBlendFactor:", uint(MTL.BlendFactor.One))
	msg(Void, ca, "setDestinationRGBBlendFactor:", uint(MTL.BlendFactor.OneMinusSourceAlpha))
	msg(Void, ca, "setSourceAlphaBlendFactor:", uint(MTL.BlendFactor.One))
	msg(Void, ca, "setDestinationAlphaBlendFactor:", uint(MTL.BlendFactor.OneMinusSourceAlpha))
	mt.pipeline = msg(Id, mt.device, "newRenderPipelineStateWithDescriptor:error:", desc, &err)
	if mt.pipeline == nil {
		fmt.eprintln("gfx: metal pipeline:", err_str(err))
		return false
	}

	if !platform.is_headless() {
		mt.layer = Id(platform.native_metal_layer())
		if mt.layer == nil do return false
		msg(Void, mt.layer, "setDevice:", mt.device)
		msg(Void, mt.layer, "setPixelFormat:", uint(MTL.PixelFormat.BGRA8Unorm))
	}
	for &r in mt.ring do ensure_slot(&r, 4096 * size_of(Instance))
	return true
}

@(private)
_backend_native_device :: proc() -> rawptr {return rawptr(mt.device)}

@(private)
_backend_wait_idle :: proc() {
	if mt.last_cmd != nil do msg(Void, mt.last_cmd, "waitUntilCompleted")
}

@(private)
_backend_shutdown :: proc() {
	if mt.last_cmd != nil {
		msg(Void, mt.last_cmd, "waitUntilCompleted")
		msg(Void, mt.last_cmd, "release")
	}
	for &r in mt.ring {
		if r.cmdbuf != nil do msg(Void, r.cmdbuf, "release")
		if r.buf != nil do msg(Void, r.buf, "release")
		r = {}
	}
	if mt.offscreen != nil do msg(Void, mt.offscreen, "release")
	if mt.readback != nil do msg(Void, mt.readback, "release")
	msg(Void, mt.pipeline, "release")
	msg(Void, mt.queue, "release")
	msg(Void, mt.device, "release")
	mt = {}
}

@(private = "file")
ensure_slot :: proc(r: ^Ring_Slot, bytes: int) {
	if r.cap >= bytes && r.buf != nil do return
	if r.buf != nil do msg(Void, r.buf, "release")
	n := max(bytes, r.cap * 2, 64 * 1024)
	// StorageModeShared | CPUCacheModeWriteCombined
	r.buf = msg(Id, mt.device, "newBufferWithLength:options:", uint(n), uint(1))
	r.cap = n
}

@(private = "file")
tex_desc :: proc(pf: MTL.PixelFormat, w, h: i32, usage: MTL.TextureUsage, storage: MTL.StorageMode) -> Id {
	d := msg(Id, objc.cls("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", uint(pf), uint(w), uint(h), false)
	msg(Void, d, "setUsage:", transmute(uint)usage)
	msg(Void, d, "setStorageMode:", uint(storage))
	return d
}

@(private = "file")
ensure_offscreen :: proc(size: [2]i32) {
	if mt.offscreen != nil && mt.off_size == size do return
	if mt.offscreen != nil do msg(Void, mt.offscreen, "release")
	d := tex_desc(.BGRA8Unorm, size.x, size.y, {.RenderTarget, .ShaderRead}, .Private)
	mt.offscreen = msg(Id, mt.device, "newTextureWithDescriptor:", d)
	mt.off_size = size
}

@(private)
_backend_submit :: proc(insts: []Instance, batches: []Batch, clear: Color, fb: [2]i32) {
	if fb.x <= 0 || fb.y <= 0 do return
	pool := pool_push()
	defer pool_pop(pool)

	slot := &mt.ring[mt.ring_idx]
	mt.ring_idx = (mt.ring_idx + 1) % FRAMES_IN_FLIGHT
	if slot.cmdbuf != nil {
		msg(Void, slot.cmdbuf, "waitUntilCompleted") // normally long done; bounds CPU run-ahead
		msg(Void, slot.cmdbuf, "release")
		slot.cmdbuf = nil
	}
	bytes := len(insts) * size_of(Instance)
	ensure_slot(slot, bytes)
	if bytes > 0 {
		dst := msg(rawptr, slot.buf, "contents")
		mem.copy_non_overlapping(dst, raw_data(insts), bytes)
	}

	cmd := msg(Id, mt.queue, "commandBuffer")
	target: Id
	drawable: Id
	if mt.layer != nil {
		// Acquire as late as possible (after CPU work) for lowest latency.
		drawable = msg(Id, mt.layer, "nextDrawable")
		if drawable == nil do return
		target = msg(Id, drawable, "texture")
	} else {
		ensure_offscreen(fb)
		target = mt.offscreen
	}
	tw := i32(msg(uint, target, "width"))
	th := i32(msg(uint, target, "height"))

	rp := msg(Id, objc.cls("MTLRenderPassDescriptor"), "renderPassDescriptor")
	att := msg(Id, msg(Id, rp, "colorAttachments"), "objectAtIndexedSubscript:", uint(0))
	msg(Void, att, "setTexture:", target)
	msg(Void, att, "setLoadAction:", uint(MTL.LoadAction.Clear))
	msg(Void, att, "setStoreAction:", uint(MTL.StoreAction.Store))
	cc := premul(clear)
	msg(Void, att, "setClearColor:", MTL.ClearColor{f64(cc.r), f64(cc.g), f64(cc.b), f64(cc.a)})

	enc := msg(Id, cmd, "renderCommandEncoderWithDescriptor:", rp)
	msg(Void, enc, "setRenderPipelineState:", mt.pipeline)
	Uniforms :: struct {viewport: [2]f32, pad: [2]f32}
	u := Uniforms{viewport = {f32(tw), f32(th)}}
	msg(Void, enc, "setVertexBytes:length:atIndex:", rawptr(&u), uint(size_of(u)), uint(1))
	msg(Void, enc, "setVertexBuffer:offset:atIndex:", slot.buf, uint(0), uint(0))

	white := Id(g.textures[g.white].native)
	bound: [TEX_SLOTS + 1]Id
	for &t, i in bound {
		msg(Void, enc, "setFragmentTexture:atIndex:", white, uint(i))
		t = white
	}
	for b in batches {
		for i in 0 ..< b.n_slots {
			tex := Id(g.textures[b.slots[i]].native)
			if tex != bound[i] {
				msg(Void, enc, "setFragmentTexture:atIndex:", tex, uint(i))
				bound[i] = tex
			}
		}
		t2 := b.tex2 != 0 ? b.tex2 : g.white
		tex2 := Id(g.textures[t2].native)
		if tex2 != bound[TEX_SLOTS] {
			msg(Void, enc, "setFragmentTexture:atIndex:", tex2, uint(TEX_SLOTS))
			bound[TEX_SLOTS] = tex2
		}
		msg(Void, enc, "setVertexBufferOffset:atIndex:", uint(b.first) * size_of(Instance), uint(0))
		msg(Void, enc, "drawPrimitives:vertexStart:vertexCount:instanceCount:", uint(MTL.PrimitiveType.TriangleStrip), uint(0), uint(4), uint(b.count))
	}
	msg(Void, enc, "endEncoding")

	if drawable != nil {
		if msg(bool, mt.layer, "presentsWithTransaction") {
			// Live resize: present synchronously within the window's CA transaction.
			msg(Void, cmd, "commit")
			msg(Void, cmd, "waitUntilScheduled")
			msg(Void, drawable, "present")
		} else {
			msg(Void, cmd, "presentDrawable:", drawable)
			msg(Void, cmd, "commit")
		}
	} else {
		msg(Void, cmd, "commit")
	}
	msg(Id, cmd, "retain")
	slot.cmdbuf = cmd
	if mt.last_cmd != nil do msg(Void, mt.last_cmd, "release")
	msg(Id, cmd, "retain")
	mt.last_cmd = cmd
}

@(private)
_backend_texture_create :: proc(w, h: i32, format: Texture_Format, pixels: []u8) -> rawptr {
	pool := pool_push()
	defer pool_pop(pool)
	pf: MTL.PixelFormat = format == .R8 ? .R8Unorm : (format == .RG8 ? .RG8Unorm : .RGBA8Unorm)
	d := tex_desc(pf, w, h, {.ShaderRead}, .Managed)
	t := msg(Id, mt.device, "newTextureWithDescriptor:", d)
	if t == nil do return nil
	if len(pixels) > 0 {
		_backend_texture_update(rawptr(t), format, 0, 0, w, h, pixels, w * i32(format_bpp(format)))
	}
	return rawptr(t)
}

@(private)
_backend_texture_update :: proc(native: rawptr, format: Texture_Format, x, y, w, h: i32, pixels: []u8, stride: i32) {
	region := Region{uint(x), uint(y), 0, uint(w), uint(h), 1}
	msg(Void, Id(native), "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", region, uint(0), raw_data(pixels), uint(stride))
}

@(private)
_backend_texture_destroy :: proc(native: rawptr) {
	if native != nil do msg(Void, Id(native), "release")
}

@(private)
_backend_read_pixels :: proc(allocator: runtime.Allocator) -> ([]u8, int, int) {
	if mt.offscreen == nil do return nil, 0, 0
	pool := pool_push()
	defer pool_pop(pool)
	w, h := int(mt.off_size.x), int(mt.off_size.y)
	bytes := w * h * 4
	if mt.readback == nil || int(msg(uint, mt.readback, "length")) < bytes {
		if mt.readback != nil do msg(Void, mt.readback, "release")
		mt.readback = msg(Id, mt.device, "newBufferWithLength:options:", uint(bytes), uint(0))
	}
	if mt.last_cmd != nil do msg(Void, mt.last_cmd, "waitUntilCompleted")
	cmd := msg(Id, mt.queue, "commandBuffer")
	blit := msg(Id, cmd, "blitCommandEncoder")
	Origin :: struct {x, y, z: uint}
	Size :: struct {w, h, d: uint}
	msg(Void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:",
		mt.offscreen, uint(0), uint(0), Origin{}, Size{uint(w), uint(h), 1}, mt.readback, uint(0), uint(w * 4), uint(bytes))
	msg(Void, blit, "endEncoding")
	msg(Void, cmd, "commit")
	msg(Void, cmd, "waitUntilCompleted")
	src := ([^]u8)(msg(rawptr, mt.readback, "contents"))
	out := make([]u8, bytes, allocator)
	// BGRA (opaque after clear) -> RGBA
	for i := 0; i < bytes; i += 4 {
		out[i + 0] = src[i + 2]
		out[i + 1] = src[i + 1]
		out[i + 2] = src[i + 0]
		out[i + 3] = src[i + 3]
	}
	return out, w, h
}
