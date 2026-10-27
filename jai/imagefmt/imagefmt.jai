Format :: enum u8 {
	Unknown;
	PNG;
	GIF;
	JPEG;
	WebP;
}

Error :: enum u8 {
	None;
	Unknown_Format;
	Truncated;
	Corrupt;
	Unsupported;
	Too_Large;
	Out_Of_Memory;
}

Frame :: struct {
	pixels: []u8; // RGBA8, straight alpha, width*height*4, composited canvas
	duration_ms: int;
}

Image :: struct {
	width, height: int;
	frames: []Frame; // single image = 1 frame
	loop_count: int; // times to play the animation; 0 = forever
	format: Format;
}

// Detect the format from the first bytes.
sniff :: (data: []u8) -> Format {
	if len(data) >= 8 && as_string(sub(data, 0, 8)) == "\x89PNG\r\n\x1a\n" { return .PNG; }
	if len(data) >= 6 && (as_string(sub(data, 0, 6)) == "GIF87a" || as_string(sub(data, 0, 6)) == "GIF89a") { return .GIF; }
	if len(data) >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF { return .JPEG; }
	if len(data) >= 12 && as_string(sub(data, 0, 4)) == "RIFF" && as_string(sub(data, 8, 12)) == "WEBP" { return .WebP; }
	return .Unknown;
}

// Decode all frames. max_pixels limits the canvas (width*height); the sum over
// all frames is limited to 4*max_pixels.
decode :: (data: []u8, allocator := context.allocator, max_pixels := 64 << 20) -> Image, Error {
	{ __r1, __r2 := decode_impl(data, allocator, max_pixels, false); return __r1, __r2; }
}

// Decode only the first frame (cheap path for thumbnails / static display).
decode_first_frame :: (data: []u8, allocator := context.allocator, max_pixels := 64 << 20) -> Image, Error {
	{ __r3, __r4 := decode_impl(data, allocator, max_pixels, true); return __r3, __r4; }
}

image_destroy :: (img: *Image, allocator := context.allocator) {
	for f: img.frames { delete(f.pixels, allocator); }
	delete(img.frames, allocator);
	img.* = .{};
}
#scope_module

Decode_Ctx :: struct {
	allocator: Allocator;
	max_pixels: int;
	first_only: bool;
	frames: [..]Frame;
	total_px: int;
}

decode_impl :: (data: []u8, allocator: Allocator, max_pixels: int, first_only: bool) -> Image, Error {
	img: Image;
	err: Error;
	c := Decode_Ctx.{
		allocator = allocator,
		max_pixels = max_pixels,
		first_only = first_only,
		frames = make_dynamic(Frame, 0, 0, allocator)
	};
	img.format = sniff(data);
	if img.format == {
	case .PNG; #through; case .GIF;
		err = wuffs_decode(*c, data, *img, img.format);
	case .JPEG;
		err = jpeg_decode(*c, data, *img);
	case .WebP;
		err = webp_decode(*c, data, *img);
	case .Unknown;
		err = .Unknown_Format;
	}
	if err == .None && len(c.frames) == 0 { err = .Corrupt; }
	if err != .None {
		for f: c.frames { delete(f.pixels, allocator); }
		delete(c.frames);
		return .{}, err;
	}
	img.frames = view(c.frames);
	if len(img.frames) == 1 { img.loop_count = 1; }
	return img, .None;
}

check_size :: (c: *Decode_Ctx, w: int, h: int) -> Error {
	if w <= 0 || h <= 0 { return .Corrupt; }
	if w > 1 << 16 || h > 1 << 16 || w * h > c.max_pixels { return .Too_Large; }
	return .None;
}

// Append a frame holding a copy of (or ownership of) pixels.
push_frame :: (c: *Decode_Ctx, pixels: []u8, duration_ms: int, take := false) -> Error {
	c.total_px += len(pixels) / 4;
	if c.total_px > 4 * c.max_pixels {
		if take { delete(pixels, c.allocator); }
		return .Too_Large;
	}
	p := pixels;
	if !take {
		q := make_slice(u8, len(pixels), c.allocator);
		if !q.data { return .Out_Of_Memory; }
		copy(q, pixels);
		p = q;
	}
	d := duration_ms;
	if d <= 10 { d = 100; }
	append(*c.frames, Frame.{p, d});
	return .None;
}

alloc_pixels :: (c: *Decode_Ctx, w: int, h: int) -> []u8, Error {
	p := make_slice(u8, w * h * 4, c.allocator);
	if !p.data { return .{}, .Out_Of_Memory; }
	return p, .None;
}

// Straight-alpha "over": src onto dst (libwebp's BlendPixelNonPremult; used by
// WebP). Returns the blended RGBA.
// Straight-alpha "over": src onto dst (libwebp's BlendPixelNonPremult; used by
// WebP). Returns the blended RGBA.
blend_over :: inline (src: [4]u8, dst: [4]u8) -> [4]u8 #no_context {
	sa := cast(u32)(src[3]);
	if sa == 0 { return dst; }
	da := cast(u32)(dst[3]);
	dfa := (da * (256 - sa)) >> 8;
	ba := sa + dfa;
	scale := ((cast(u32)(1)) << 24) / ba;
	r: [4]u8;
	for i: 0..2 {
		r[i] = cast(u8)(((cast(u32)(src[i]) * sa + cast(u32)(dst[i]) * dfa) * scale) >> 24);
	}
	r[3] = cast(u8)(ba);
	return r;
};

be16 :: inline (p: []u8) -> int #no_context {return ((cast(int)(p[0])) << 8) | cast(int)(p[1]);};
be32 :: inline (p: []u8) -> int #no_context {return ((cast(int)(p[0])) << 24) | ((cast(int)(p[1])) << 16) | ((cast(int)(p[2])) << 8) | cast(int)(p[3]);};
le16i :: inline (p: []u8) -> int #no_context {return (cast(int)(p[0])) | ((cast(int)(p[1])) << 8);};
le24i :: inline (p: []u8) -> int #no_context {return (cast(int)(p[0])) | ((cast(int)(p[1])) << 8) | ((cast(int)(p[2])) << 16);};
le32i :: inline (p: []u8) -> int #no_context {return (cast(int)(p[0])) | ((cast(int)(p[1])) << 8) | ((cast(int)(p[2])) << 16) | ((cast(int)(p[3])) << 24);};
#scope_export

