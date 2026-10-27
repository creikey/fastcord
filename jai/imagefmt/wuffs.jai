// Every pixel decoder comes from Wuffs (vendor/wuffs), whose decoders are memory-safe by
// construction: every bounds and overflow check is proven at compile time. build.sh / build.bat
// compile it into build/fc_wuffs.obj before any Odin build. Wuffs draws each frame onto our canvas;
// disposal between frames happens here, and animated WebP's container is parsed in webp.odin.



#if OS == .WINDOWS {
} else {
}
#scope_file

FC_OK :: 0;
FC_TRUNCATED :: 1;
FC_UNSUPPORTED :: 3;
FC_END :: 5;

Fc_Image_Info :: struct {
	width, height: u32;
	work_len: u64;
}

Fc_Frame_Info :: struct {
	x0, y0, x1, y1: u32;
	duration_ms: u64;
	disposal: u8; // 0 keep, 1 clear the rectangle, 2 restore the canvas from before the frame
}
	fc_image_state_size :: (format: s32) -> u64 #foreign wuffs;
	fc_image_open :: (state: *void, state_len: u64, format: s32, src: *u8, src_len: u64, info: *Fc_Image_Info) -> s32 #foreign wuffs;
	fc_image_loops :: (state: *void) -> u32 #foreign wuffs;
	fc_image_next_frame :: (state: *void, fi: *Fc_Frame_Info) -> s32 #foreign wuffs;
	fc_image_decode_frame :: (state: *void, canvas: *u8, canvas_len: u64, stride: u64, work: *u8, work_len: u64, replace: s32) -> s32 #foreign wuffs;

fc_error :: (r: s32) -> Error {
	if r == {
	case FC_OK; return .None;
	case FC_TRUNCATED; return .Truncated;
	case FC_UNSUPPORTED; return .Unsupported;
	}
	return .Corrupt;
}

Wuffs_Image :: struct {
	state, work: []u8;
	w, h: int;
}

wuffs_open :: (c: *Decode_Ctx, data: []u8, format: Format) -> Wuffs_Image, Error {
	im: Wuffs_Image;
	err: Error;
	state_len := fc_image_state_size(cast(s32)(format));
	if state_len == 0 { return .{}, .Unknown_Format; }
	serr: mem.Allocator_Error;
	im.state, serr = mem.alloc_bytes(cast(int)(state_len), 16, c.allocator);
	if serr != null { return .{}, .Out_Of_Memory; }
	info: Fc_Image_Info;
	err = fc_error(fc_image_open(raw_data(im.state), state_len, cast(s32)(format), raw_data(data), cast(u64)(len(data)), *info));
	im.w, im.h = cast(int)(info.width), cast(int)(info.height);
	if err == .None { err = check_size(c, im.w, im.h); }
	// Progressive JPEG keeps every coefficient (2 bytes each, up to 4 components) until the last scan.
	if err == .None && info.work_len > cast(u64)(8 * c.max_pixels) { err = .Too_Large; }
	if err == .None {
		im.work, serr = make_slice(u8, cast(int)(info.work_len), c.allocator);
		if serr != null { err = .Out_Of_Memory; }
	}
	if err != .None { wuffs_close(c, *im); }
	return im, err;
}

wuffs_close :: (c: *Decode_Ctx, im: *Wuffs_Image) {
	delete(im.state, c.allocator);
	delete(im.work, c.allocator);
	im.* = .{};
}
#scope_module

// Decodes a still image that must be w*h into dst (rows stride bytes apart), replacing what is there.
wuffs_decode_into :: (c: *Decode_Ctx, data: []u8, format: Format, w: int, h: int, dst: []u8, stride: int) -> Error {
	im, __e2 := wuffs_open(c, data, format); if failed(__e2) return __e2;
	defer wuffs_close(c, *im);
	if im.w != w || im.h != h { return .Corrupt; }
	st := raw_data(im.state);
	f: Fc_Frame_Info;
	__e3 := fc_error(fc_image_next_frame(st, *f)); if failed(__e3) return __e3;
	return fc_error(fc_image_decode_frame(st, raw_data(dst), cast(u64)(len(dst)), cast(u64)(stride), raw_data(im.work), cast(u64)(len(im.work)), 1));
}

// Decodes every frame (or only the first) into c.frames. A broken frame after the first ends the
// animation there instead of failing it, as browsers do.
wuffs_decode :: (c: *Decode_Ctx, data: []u8, img: *Image, format: Format) -> Error {
	im, __e4 := wuffs_open(c, data, format); if failed(__e4) return __e4;
	defer wuffs_close(c, *im);
	st, work := raw_data(im.state), im.work;
	W, H := im.w, im.h;
	canvas, __e5 := alloc_pixels(c, W, H); if failed(__e5) return __e5;
	defer delete(canvas, c.allocator);
	saved: []u8;
	defer delete(saved, c.allocator);
	img.width, img.height = W, H;
	stride := W * 4;

	f: Fc_Frame_Info;
	__e6 := fc_error(fc_image_next_frame(st, *f)); if failed(__e6) return __e6;
	while true {
		if f.disposal == 2 {
			if saved == null { __v8, __e7 := alloc_pixels(c, W, H); if failed(__e7) return __e7; saved = __v8; }
			copy(saved, canvas);
		}
		r := fc_image_decode_frame(st, raw_data(canvas), cast(u64)(len(canvas)), cast(u64)(stride), raw_data(work), cast(u64)(len(work)), 0);
		if r != FC_OK {
			if len(c.frames) > 0 { break; }
			return fc_error(r);
		}
		next: Fc_Frame_Info;
		if c.first_only || fc_image_next_frame(st, *next) != FC_OK {
			// The last frame: hand the canvas over instead of copying it.
			px := canvas;
			canvas = null;
			__e9 := push_frame(c, px, cast(int)(f.duration_ms), true); if failed(__e9) return __e9;
			break;
		}
		__e10 := push_frame(c, canvas, cast(int)(f.duration_ms)); if failed(__e10) return __e10;
		if f.disposal == {
		case 1;
			for y: cast(int)(f.y0)..cast(int)(f.y1)-1 { mem.zero_slice(sub(sub_from(canvas, y * stride + cast(int)(f.x0) * 4), 0, cast(int)(f.x1 - f.x0) * 4)); }
		case 2;
			copy(canvas, saved);
		}
		f = next;
	}
	img.loop_count = cast(int)(fc_image_loops(st));
	return .None;
}
#scope_export

