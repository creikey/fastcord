#scope_file

// Messaging goes through fc:platform/objc (intrinsics.objc_send crashes this
// compiler build), so vendor:darwin/Metal is used only for C functions and enums.

// Messaging goes through fc:platform/objc (intrinsics.objc_send crashes this
// compiler build), so vendor:darwin/Metal is used only for C functions and enums.

msg :: objc.msg;
Id :: objc.Id;
Void :: objc.Void;

Ring_Slot :: struct {
	buf: Id; // MTLBuffer
	cap: int; // bytes
	cmdbuf: Id; // last submission using this slot (retained)
}

Mtl :: struct {
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
}

mt: Mtl;

nsstr :: (s: string) -> Id {
	o := msg(Id, objc.cls("NSString"), "alloc");
	o = msg(Id, o, "initWithBytes:length:encoding:", raw_data(s), cast(u64)(len(s)), cast(u64)(4));
	return msg(Id, o, "autorelease");
}

err_str :: (err: Id) -> string {
	if err == null { return "?"; }
	d := msg(Id, err, "localizedDescription");
	return strings.clone_from_cstring(msg(*u8, d, "UTF8String"), temp);
}

pool_push :: () -> Id {return objc.new_obj("NSAutoreleasePool");}
pool_pop :: (p: Id) {msg(Void, p, "drain");}

Region :: struct {x, y, z, w, h, d: u64;}
#scope_module

_backend_init :: () -> bool {
	pool := pool_push();
	defer pool_pop(pool);

	mt.device = cast(Id)(MTLCreateSystemDefaultDevice());
	if mt.device == null { return false; }
	mt.queue = msg(Id, mt.device, "newCommandQueue");

	err: Id;
	lib := msg(Id, mt.device, "newLibraryWithSource:options:error:", nsstr(METAL_SHADER_SRC), cast(Id)(null), *err);
	if lib == null {
		fmt.eprintln("gfx: metal shader:", err_str(err));
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
	ca := msg(Id, msg(Id, desc, "colorAttachments"), "objectAtIndexedSubscript:", cast(u64)(0));
	msg(Void, ca, "setPixelFormat:", cast(u64)(MTL.PixelFormat.BGRA8Unorm));
	msg(Void, ca, "setBlendingEnabled:", true);
	msg(Void, ca, "setSourceRGBBlendFactor:", cast(u64)(MTL.BlendFactor.One));
	msg(Void, ca, "setDestinationRGBBlendFactor:", cast(u64)(MTL.BlendFactor.OneMinusSourceAlpha));
	msg(Void, ca, "setSourceAlphaBlendFactor:", cast(u64)(MTL.BlendFactor.One));
	msg(Void, ca, "setDestinationAlphaBlendFactor:", cast(u64)(MTL.BlendFactor.OneMinusSourceAlpha));
	mt.pipeline = msg(Id, mt.device, "newRenderPipelineStateWithDescriptor:error:", desc, *err);
	if mt.pipeline == null {
		fmt.eprintln("gfx: metal pipeline:", err_str(err));
		return false;
	}

	if !platform.is_headless() {
		mt.layer = cast(Id)(platform.native_metal_layer());
		if mt.layer == null { return false; }
		msg(Void, mt.layer, "setDevice:", mt.device);
		msg(Void, mt.layer, "setPixelFormat:", cast(u64)(MTL.PixelFormat.BGRA8Unorm));
	}
	for * r: mt.ring { ensure_slot(r, 4096 * size_of(Instance)); }
	return true;
}

_backend_native_device :: () -> *void {return cast(*void)(mt.device);}

_backend_wait_idle :: () {
	if mt.last_cmd != null { msg(Void, mt.last_cmd, "waitUntilCompleted"); }
}

_backend_shutdown :: () {
	if mt.last_cmd != null {
		msg(Void, mt.last_cmd, "waitUntilCompleted");
		msg(Void, mt.last_cmd, "release");
	}
	for * r: mt.ring {
		if r.cmdbuf != null { msg(Void, r.cmdbuf, "release"); }
		if r.buf != null { msg(Void, r.buf, "release"); }
		r.* = .{};
	}
	if mt.offscreen != null { msg(Void, mt.offscreen, "release"); }
	if mt.readback != null { msg(Void, mt.readback, "release"); }
	msg(Void, mt.pipeline, "release");
	msg(Void, mt.queue, "release");
	msg(Void, mt.device, "release");
	mt = .{};
}
#scope_file

ensure_slot :: (r: *Ring_Slot, bytes: int) {
	if r.cap >= bytes && r.buf != null { return; }
	if r.buf != null { msg(Void, r.buf, "release"); }
	n := max(bytes, r.cap * 2, 64 * 1024);
	// StorageModeShared | CPUCacheModeWriteCombined
	r.buf = msg(Id, mt.device, "newBufferWithLength:options:", cast(u64)(n), cast(u64)(1));
	r.cap = n;
}

tex_desc :: (pf: MTL.PixelFormat, w: s32, h: s32, usage: MTL.TextureUsage, storage: MTL.StorageMode) -> Id {
	d := msg(Id, objc.cls("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", cast(u64)(pf), cast(u64)(w), cast(u64)(h), false);
	msg(Void, d, "setUsage:", cast(u64) usage);
	msg(Void, d, "setStorageMode:", cast(u64)(storage));
	return d;
}

ensure_offscreen :: (size: [2]s32) {
	if mt.offscreen != null && mt.off_size[0] == size[0] && mt.off_size[1] == size[1] { return; }
	if mt.offscreen != null { msg(Void, mt.offscreen, "release"); }
	d := tex_desc(.BGRA8Unorm, size[0], size[1], MTL.TextureUsage.RenderTarget | .ShaderRead, .Private);
	mt.offscreen = msg(Id, mt.device, "newTextureWithDescriptor:", d);
	mt.off_size = size;
}
#scope_module

_backend_submit :: (insts: []Instance, batches: []Batch, clear: Color, fb: [2]s32) {
	if fb[0] <= 0 || fb[1] <= 0 { return; }
	pool := pool_push();
	defer pool_pop(pool);

	slot := *mt.ring[mt.ring_idx];
	mt.ring_idx = (mt.ring_idx + 1) % FRAMES_IN_FLIGHT;
	if slot.cmdbuf != null {
		msg(Void, slot.cmdbuf, "waitUntilCompleted"); // normally long done; bounds CPU run-ahead
		msg(Void, slot.cmdbuf, "release");
		slot.cmdbuf = null;
	}
	bytes := len(insts) * size_of(Instance);
	ensure_slot(slot, bytes);
	if bytes > 0 {
		dst := msg(*void, slot.buf, "contents");
		mem.copy_non_overlapping(dst, raw_data(insts), bytes);
	}

	cmd := msg(Id, mt.queue, "commandBuffer");
	target: Id;
	drawable: Id;
	if mt.layer != null {
		// Acquire as late as possible (after CPU work) for lowest latency.
		drawable = msg(Id, mt.layer, "nextDrawable");
		if drawable == null { return; }
		target = msg(Id, drawable, "texture");
	} else {
		ensure_offscreen(fb);
		target = mt.offscreen;
	}
	tw := cast(s32)(msg(u64, target, "width"));
	th := cast(s32)(msg(u64, target, "height"));

	rp := msg(Id, objc.cls("MTLRenderPassDescriptor"), "renderPassDescriptor");
	att := msg(Id, msg(Id, rp, "colorAttachments"), "objectAtIndexedSubscript:", cast(u64)(0));
	msg(Void, att, "setTexture:", target);
	msg(Void, att, "setLoadAction:", cast(u64)(MTL.LoadAction.Clear));
	msg(Void, att, "setStoreAction:", cast(u64)(MTL.StoreAction.Store));
	cc := premul(clear);
	msg(Void, att, "setClearColor:", MTL.ClearColor.{cc[0], cc[1], cc[2], cc[3]});

	enc := msg(Id, cmd, "renderCommandEncoderWithDescriptor:", rp);
	msg(Void, enc, "setRenderPipelineState:", mt.pipeline);
	Uniforms :: struct {viewport: Vector2; pad: Vector2;}
	u := Uniforms.{viewport = .{cast(float32)(tw), cast(float32)(th)}};
	msg(Void, enc, "setVertexBytes:length:atIndex:", cast(*void)(*u), cast(u64)(size_of(Uniforms)), cast(u64)(1));
	msg(Void, enc, "setVertexBuffer:offset:atIndex:", slot.buf, cast(u64)(0), cast(u64)(0));

	white := cast(Id)(g.textures[g.white].native);
	bound: [TEX_SLOTS + 1]Id;
	for * t, i: bound {
		msg(Void, enc, "setFragmentTexture:atIndex:", white, cast(u64)(i));
		t.* = white;
	}
	for b: batches {
		for i: 0..b.n_slots-1 {
			tex := cast(Id)(g.textures[b.slots[i]].native);
			if tex != bound[i] {
				msg(Void, enc, "setFragmentTexture:atIndex:", tex, cast(u64)(i));
				bound[i] = tex;
			}
		}
		t2 := ifx b.tex2 != 0 then b.tex2 else g.white;
		tex2 := cast(Id)(g.textures[t2].native);
		if tex2 != bound[TEX_SLOTS] {
			msg(Void, enc, "setFragmentTexture:atIndex:", tex2, cast(u64)(TEX_SLOTS));
			bound[TEX_SLOTS] = tex2;
		}
		msg(Void, enc, "setVertexBufferOffset:atIndex:", cast(u64)(b.first) * size_of(Instance), cast(u64)(0));
		msg(Void, enc, "drawPrimitives:vertexStart:vertexCount:instanceCount:", cast(u64)(MTL.PrimitiveType.TriangleStrip), cast(u64)(0), cast(u64)(4), cast(u64)(b.count));
	}
	msg(Void, enc, "endEncoding");

	if drawable != null {
		if msg(bool, mt.layer, "presentsWithTransaction") {
			// Live resize: present synchronously within the window's CA transaction.
			msg(Void, cmd, "commit");
			msg(Void, cmd, "waitUntilScheduled");
			msg(Void, drawable, "present");
		} else {
			msg(Void, cmd, "presentDrawable:", drawable);
			msg(Void, cmd, "commit");
		}
	} else {
		msg(Void, cmd, "commit");
	}
	msg(Id, cmd, "retain");
	slot.cmdbuf = cmd;
	if mt.last_cmd != null { msg(Void, mt.last_cmd, "release"); }
	msg(Id, cmd, "retain");
	mt.last_cmd = cmd;
}

_backend_texture_create :: (w: s32, h: s32, format: Texture_Format, pixels: []u8) -> *void {
	pool := pool_push();
	defer pool_pop(pool);
	pf: MTL.PixelFormat = ifx format == .R8 then .R8Unorm else (ifx format == .RG8 then .RG8Unorm else .RGBA8Unorm);
	d := tex_desc(pf, w, h, .ShaderRead, .Managed);
	t := msg(Id, mt.device, "newTextureWithDescriptor:", d);
	if t == null { return null; }
	if len(pixels) > 0 {
		_backend_texture_update(cast(*void)(t), format, 0, 0, w, h, pixels, w * cast(s32)(format_bpp(format)));
	}
	return cast(*void)(t);
}

_backend_texture_update :: (native: *void, format: Texture_Format, x: s32, y: s32, w: s32, h: s32, pixels: []u8, stride: s32) {
	region := Region.{cast(u64)(x), cast(u64)(y), 0, cast(u64)(w), cast(u64)(h), 1};
	msg(Void, cast(Id)(native), "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", region, cast(u64)(0), raw_data(pixels), cast(u64)(stride));
}

_backend_texture_destroy :: (native: *void) {
	if native != null { msg(Void, cast(Id)(native), "release"); }
}

_backend_read_pixels :: (allocator: Allocator) -> []u8, int, int {
	if mt.offscreen == null { return .{}, 0, 0; }
	pool := pool_push();
	defer pool_pop(pool);
	w, h := cast(int)(mt.off_size[0]), cast(int)(mt.off_size[1]);
	bytes := w * h * 4;
	if mt.readback == null || cast(int)(msg(u64, mt.readback, "length")) < bytes {
		if mt.readback != null { msg(Void, mt.readback, "release"); }
		mt.readback = msg(Id, mt.device, "newBufferWithLength:options:", cast(u64)(bytes), cast(u64)(0));
	}
	if mt.last_cmd != null { msg(Void, mt.last_cmd, "waitUntilCompleted"); }
	cmd := msg(Id, mt.queue, "commandBuffer");
	blit := msg(Id, cmd, "blitCommandEncoder");
	Origin :: struct {x, y, z: u64;}
	Size :: struct {w, h, d: u64;}
	msg(Void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:",
		mt.offscreen, cast(u64)(0), cast(u64)(0), Origin.{}, Size.{cast(u64)(w), cast(u64)(h), 1}, mt.readback, cast(u64)(0), cast(u64)(w * 4), cast(u64)(bytes));
	msg(Void, blit, "endEncoding");
	msg(Void, cmd, "commit");
	msg(Void, cmd, "waitUntilCompleted");
	src := cast(*u8)(msg(*void, mt.readback, "contents"));
	out := make_slice(u8, bytes, allocator);
	// BGRA (opaque after clear) -> RGBA
	{ i := 0;
	while i < bytes {
		at(*out, i + 0).* = src[i + 2];
		at(*out, i + 1).* = src[i + 1];
		at(*out, i + 2).* = src[i + 0];
		at(*out, i + 3).* = src[i + 3];
		i += 4;
} }
	return out, w, h;
}
#scope_export

