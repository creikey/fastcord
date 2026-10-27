// Every pixel decoder comes from Wuffs (vendor/wuffs), whose decoders are memory-safe by
// construction: every bounds and overflow check is proven at compile time. build.sh / build.bat
// compile it into build/fc_vendor. Wuffs draws each frame onto our canvas; disposal between frames
// happens here, and animated WebP's container is parsed in webp.jai.

#scope_module

// Decodes a still image that must be w*h into dst (rows stride bytes apart), replacing what is there.
wuffs_decode_into :: (c: *Decode_Ctx, data: []u8, format: Format, w: int, h: int, dst: []u8, stride: int) -> Error {
	im, err := wuffs_open(c, data, format);
	if err != .None return err;
	defer wuffs_close(c, *im);
	if im.w != w || im.h != h return .Corrupt;
	f: Fc_Frame_Info;
	err = fc_error(fc_image_next_frame(im.state.data, *f));
	if err != .None return err;
	return fc_error(fc_image_decode_frame(im.state.data, dst.data, xx dst.count, xx stride, im.work.data, xx im.work.count, 1));
}

// Decodes every frame (or only the first) into c.frames. A broken frame after the first ends the
// animation there instead of failing it, as browsers do.
wuffs_decode :: (c: *Decode_Ctx, data: []u8, img: *Image, format: Format) -> Error {
	im, err := wuffs_open(c, data, format);
	if err != .None return err;
	defer wuffs_close(c, *im);
	st, work := im.state.data, im.work;
	canvas := alloc_pixels(c, im.w, im.h);
	defer free(canvas.data,, c.allocator);
	saved: []u8;
	defer free(saved.data,, c.allocator);
	img.width, img.height = im.w, im.h;
	stride := im.w * 4;

	f: Fc_Frame_Info;
	err = fc_error(fc_image_next_frame(st, *f));
	if err != .None return err;
	while true {
		if f.disposal == 2 {
			if !saved.data  saved = alloc_pixels(c, im.w, im.h);
			memcpy(saved.data, canvas.data, canvas.count);
		}
		r := fc_image_decode_frame(st, canvas.data, xx canvas.count, xx stride, work.data, xx work.count, 0);
		if r != FC_OK {
			if c.frames.count > 0 break;
			return fc_error(r);
		}
		next: Fc_Frame_Info;
		if c.first_only || fc_image_next_frame(st, *next) != FC_OK {
			// The last frame: hand the canvas over instead of copying it.
			px := canvas;
			canvas = .[];
			err = push_frame(c, px, xx f.duration_ms, true);
			if err != .None return err;
			break;
		}
		err = push_frame(c, canvas, xx f.duration_ms);
		if err != .None return err;
		if f.disposal == {
			case 1;
				x0, x1, y0, y1: int = f.x0, f.x1, f.y0, f.y1;
				for y: y0..y1-1  memset(canvas.data + y * stride + x0 * 4, 0, (x1 - x0) * 4);
			case 2;
				memcpy(canvas.data, saved.data, canvas.count);
		}
		f = next;
	}
	img.loop_count = fc_image_loops(st);
	return .None;
}

#scope_file

FC_OK :: 0;
FC_TRUNCATED :: 1;
FC_UNSUPPORTED :: 3;

Fc_Image_Info :: struct {
	width, height: u32;
	work_len: u64;
}

Fc_Frame_Info :: struct {
	x0, y0, x1, y1: u32;
	duration_ms: u64;
	disposal: u8; // 0 keep, 1 clear the rectangle, 2 restore the canvas from before the frame
}

fc_image_state_size :: (format: s32) -> u64 #foreign vendor;
fc_image_open :: (state: *void, state_len: u64, format: s32, src: *u8, src_len: u64, info: *Fc_Image_Info) -> s32 #foreign vendor;
fc_image_loops :: (state: *void) -> u32 #foreign vendor;
fc_image_next_frame :: (state: *void, fi: *Fc_Frame_Info) -> s32 #foreign vendor;
fc_image_decode_frame :: (state: *void, canvas: *u8, canvas_len: u64, stride: u64, work: *u8, work_len: u64, replace: s32) -> s32 #foreign vendor;

fc_error :: (r: s32) -> Error {
	if r == {
		case FC_OK;          return .None;
		case FC_TRUNCATED;   return .Truncated;
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
	state_len := fc_image_state_size(xx format);
	if state_len == 0 return im, .Unknown_Format;
	im.state = NewArray(xx state_len, u8,, c.allocator);
	info: Fc_Image_Info;
	err := fc_error(fc_image_open(im.state.data, state_len, xx format, data.data, xx data.count, *info));
	im.w, im.h = info.width, info.height;
	if err == .None  err = check_size(c, im.w, im.h);
	// Progressive JPEG keeps every coefficient (2 bytes each, up to 4 components) until the last scan.
	if err == .None && info.work_len > cast(u64) (8 * c.max_pixels)  err = .Too_Large;
	if err == .None  im.work = NewArray(xx info.work_len, u8,, c.allocator);
	if err != .None  wuffs_close(c, *im);
	return im, err;
}

wuffs_close :: (c: *Decode_Ctx, im: *Wuffs_Image) {
	free(im.state.data,, c.allocator);
	free(im.work.data,, c.allocator);
	im.* = .{};
}
