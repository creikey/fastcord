package imagefmt

// Every pixel decoder comes from Wuffs (vendor/wuffs), whose decoders are memory-safe by
// construction: every bounds and overflow check is proven at compile time. build.sh / build.bat
// compile it into build/fc_wuffs.obj before any Odin build. Wuffs draws each frame onto our canvas;
// disposal between frames happens here, and animated WebP's container is parsed in webp.odin.

import "core:mem"

when ODIN_OS == .Windows {
	foreign import wuffs "../../build/fc_wuffs.obj"
} else {
	foreign import wuffs "../../build/fc_wuffs.o"
}

@(private = "file")
FC_OK :: 0
@(private = "file")
FC_TRUNCATED :: 1
@(private = "file")
FC_UNSUPPORTED :: 3
@(private = "file")
FC_END :: 5

@(private = "file")
Fc_Image_Info :: struct {
	width, height: u32,
	work_len:      u64,
}

@(private = "file")
Fc_Frame_Info :: struct {
	x0, y0, x1, y1: u32,
	duration_ms:    u64,
	disposal:       u8, // 0 keep, 1 clear the rectangle, 2 restore the canvas from before the frame
}

@(default_calling_convention = "c")
@(private = "file")
foreign wuffs {
	fc_image_state_size :: proc(format: i32) -> uint ---
	fc_image_open :: proc(state: rawptr, state_len: uint, format: i32, src: [^]u8, src_len: uint, info: ^Fc_Image_Info) -> i32 ---
	fc_image_loops :: proc(state: rawptr) -> u32 ---
	fc_image_next_frame :: proc(state: rawptr, fi: ^Fc_Frame_Info) -> i32 ---
	fc_image_decode_frame :: proc(state: rawptr, canvas: [^]u8, canvas_len: uint, stride: uint, work: [^]u8, work_len: uint, replace: i32) -> i32 ---
}

@(private = "file")
fc_error :: proc(r: i32) -> Error {
	switch r {
	case FC_OK: return .None
	case FC_TRUNCATED: return .Truncated
	case FC_UNSUPPORTED: return .Unsupported
	}
	return .Corrupt
}

@(private = "file")
Wuffs_Image :: struct {
	state, work: []byte,
	w, h:        int,
}

@(private = "file")
wuffs_open :: proc(c: ^Decode_Ctx, data: []byte, format: Format) -> (im: Wuffs_Image, err: Error) {
	state_len := fc_image_state_size(i32(format))
	if state_len == 0 do return {}, .Unknown_Format
	serr: mem.Allocator_Error
	im.state, serr = mem.alloc_bytes(int(state_len), 16, c.allocator)
	if serr != nil do return {}, .Out_Of_Memory
	info: Fc_Image_Info
	err = fc_error(fc_image_open(raw_data(im.state), state_len, i32(format), raw_data(data), uint(len(data)), &info))
	im.w, im.h = int(info.width), int(info.height)
	if err == .None do err = check_size(c, im.w, im.h)
	// Progressive JPEG keeps every coefficient (2 bytes each, up to 4 components) until the last scan.
	if err == .None && info.work_len > u64(8 * c.max_pixels) do err = .Too_Large
	if err == .None {
		im.work, serr = make([]byte, int(info.work_len), c.allocator)
		if serr != nil do err = .Out_Of_Memory
	}
	if err != .None do wuffs_close(c, &im)
	return
}

@(private = "file")
wuffs_close :: proc(c: ^Decode_Ctx, im: ^Wuffs_Image) {
	delete(im.state, c.allocator)
	delete(im.work, c.allocator)
	im^ = {}
}

// Decodes a still image that must be w*h into dst (rows stride bytes apart), replacing what is there.
@(private)
wuffs_decode_into :: proc(c: ^Decode_Ctx, data: []byte, format: Format, w, h: int, dst: []byte, stride: int) -> Error {
	im := wuffs_open(c, data, format) or_return
	defer wuffs_close(c, &im)
	if im.w != w || im.h != h do return .Corrupt
	st := raw_data(im.state)
	f: Fc_Frame_Info
	fc_error(fc_image_next_frame(st, &f)) or_return
	return fc_error(fc_image_decode_frame(st, raw_data(dst), uint(len(dst)), uint(stride), raw_data(im.work), uint(len(im.work)), 1))
}

// Decodes every frame (or only the first) into c.frames. A broken frame after the first ends the
// animation there instead of failing it, as browsers do.
@(private)
wuffs_decode :: proc(c: ^Decode_Ctx, data: []byte, img: ^Image, format: Format) -> Error {
	im := wuffs_open(c, data, format) or_return
	defer wuffs_close(c, &im)
	st, work := raw_data(im.state), im.work
	W, H := im.w, im.h
	canvas := alloc_pixels(c, W, H) or_return
	defer delete(canvas, c.allocator)
	saved: []byte
	defer delete(saved, c.allocator)
	img.width, img.height = W, H
	stride := W * 4

	f: Fc_Frame_Info
	fc_error(fc_image_next_frame(st, &f)) or_return
	for {
		if f.disposal == 2 {
			if saved == nil do saved = alloc_pixels(c, W, H) or_return
			copy(saved, canvas)
		}
		r := fc_image_decode_frame(st, raw_data(canvas), uint(len(canvas)), uint(stride), raw_data(work), uint(len(work)), 0)
		if r != FC_OK {
			if len(c.frames) > 0 do break
			return fc_error(r)
		}
		next: Fc_Frame_Info
		if c.first_only || fc_image_next_frame(st, &next) != FC_OK {
			// The last frame: hand the canvas over instead of copying it.
			px := canvas
			canvas = nil
			push_frame(c, px, int(f.duration_ms), true) or_return
			break
		}
		push_frame(c, canvas, int(f.duration_ms)) or_return
		switch f.disposal {
		case 1:
			for y in int(f.y0) ..< int(f.y1) do mem.zero_slice(canvas[y * stride + int(f.x0) * 4:][:int(f.x1 - f.x0) * 4])
		case 2:
			copy(canvas, saved)
		}
		f = next
	}
	img.loop_count = int(fc_image_loops(st))
	return .None
}
