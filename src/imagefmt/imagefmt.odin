// Package imagefmt decodes the image formats Discord serves into RGBA8
// (straight alpha) canvases: WebP (VP8 lossy, VP8L lossless, alpha,
// animation), GIF, PNG/APNG and JPEG (baseline + progressive, EXIF
// orientation). Every pixel decoder is Wuffs (vendor/wuffs, linked as C);
// only animated WebP's container and compositing are written here. The one
// encoder, lossless WebP for uploads, is libwebp (vendor/libwebp).
//
// Animated images come back fully composited: every Frame is a whole canvas.
// Frame durations follow browsers: anything <= 10 ms becomes 100 ms.
package imagefmt

import "core:mem"

Format :: enum u8 {
	Unknown,
	PNG,
	GIF,
	JPEG,
	WebP,
}

Error :: enum u8 {
	None,
	Unknown_Format,
	Truncated,
	Corrupt,
	Unsupported,
	Too_Large,
	Out_Of_Memory,
}

Frame :: struct {
	pixels:      []byte, // RGBA8, straight alpha, width*height*4, composited canvas
	duration_ms: int,
}

Image :: struct {
	width, height: int,
	frames:        []Frame, // single image = 1 frame
	loop_count:    int, // times to play the animation; 0 = forever
	format:        Format,
}

// Detect the format from the first bytes.
sniff :: proc(data: []byte) -> Format {
	if len(data) >= 8 && string(data[:8]) == "\x89PNG\r\n\x1a\n" do return .PNG
	if len(data) >= 6 && (string(data[:6]) == "GIF87a" || string(data[:6]) == "GIF89a") do return .GIF
	if len(data) >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF do return .JPEG
	if len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP" do return .WebP
	return .Unknown
}

// Decode all frames. max_pixels limits the canvas (width*height); the sum over
// all frames is limited to 4*max_pixels.
decode :: proc(data: []byte, allocator := context.allocator, max_pixels := 64 << 20) -> (Image, Error) {
	return decode_impl(data, allocator, max_pixels, false)
}

// Decode only the first frame (cheap path for thumbnails / static display).
decode_first_frame :: proc(data: []byte, allocator := context.allocator, max_pixels := 64 << 20) -> (Image, Error) {
	return decode_impl(data, allocator, max_pixels, true)
}

image_destroy :: proc(img: ^Image, allocator := context.allocator) {
	for f in img.frames do delete(f.pixels, allocator)
	delete(img.frames, allocator)
	img^ = {}
}

@(private)
Decode_Ctx :: struct {
	allocator:   mem.Allocator,
	max_pixels:  int,
	first_only:  bool,
	frames:      [dynamic]Frame,
	total_px:    int,
}

@(private)
decode_impl :: proc(data: []byte, allocator: mem.Allocator, max_pixels: int, first_only: bool) -> (img: Image, err: Error) {
	c := Decode_Ctx {
		allocator  = allocator,
		max_pixels = max_pixels,
		first_only = first_only,
		frames     = make([dynamic]Frame, allocator),
	}
	img.format = sniff(data)
	switch img.format {
	case .PNG, .GIF:
		err = wuffs_decode(&c, data, &img, img.format)
	case .JPEG:
		err = jpeg_decode(&c, data, &img)
	case .WebP:
		err = webp_decode(&c, data, &img)
	case .Unknown:
		err = .Unknown_Format
	}
	if err == .None && len(c.frames) == 0 do err = .Corrupt
	if err != .None {
		for f in c.frames do delete(f.pixels, allocator)
		delete(c.frames)
		return {}, err
	}
	shrink(&c.frames)
	img.frames = c.frames[:]
	if len(img.frames) == 1 do img.loop_count = 1
	return img, .None
}

@(private)
check_size :: proc(c: ^Decode_Ctx, w, h: int) -> Error {
	if w <= 0 || h <= 0 do return .Corrupt
	if w > 1 << 16 || h > 1 << 16 || w * h > c.max_pixels do return .Too_Large
	return .None
}

// Append a frame holding a copy of (or ownership of) pixels.
@(private)
push_frame :: proc(c: ^Decode_Ctx, pixels: []byte, duration_ms: int, take := false) -> Error {
	c.total_px += len(pixels) / 4
	if c.total_px > 4 * c.max_pixels {
		if take do delete(pixels, c.allocator)
		return .Too_Large
	}
	p := pixels
	if !take {
		q, aerr := make([]byte, len(pixels), c.allocator)
		if aerr != nil do return .Out_Of_Memory
		copy(q, pixels)
		p = q
	}
	d := duration_ms
	if d <= 10 do d = 100
	append(&c.frames, Frame{p, d})
	return .None
}

@(private)
alloc_pixels :: proc(c: ^Decode_Ctx, w, h: int) -> ([]byte, Error) {
	p, aerr := make([]byte, w * h * 4, c.allocator)
	if aerr != nil do return nil, .Out_Of_Memory
	return p, .None
}

// Straight-alpha "over": src onto dst (libwebp's BlendPixelNonPremult; used by
// WebP). Returns the blended RGBA.
@(private)
blend_over :: #force_inline proc "contextless" (src, dst: [4]u8) -> [4]u8 {
	sa := u32(src[3])
	if sa == 0 do return dst
	da := u32(dst[3])
	dfa := (da * (256 - sa)) >> 8
	ba := sa + dfa
	scale := (u32(1) << 24) / ba
	r: [4]u8
	for i in 0 ..< 3 {
		r[i] = u8(((u32(src[i]) * sa + u32(dst[i]) * dfa) * scale) >> 24)
	}
	r[3] = u8(ba)
	return r
}

@(private)
be16 :: #force_inline proc "contextless" (p: []byte) -> int {return int(p[0]) << 8 | int(p[1])}
@(private)
be32 :: #force_inline proc "contextless" (p: []byte) -> int {return int(p[0]) << 24 | int(p[1]) << 16 | int(p[2]) << 8 | int(p[3])}
@(private)
le16i :: #force_inline proc "contextless" (p: []byte) -> int {return int(p[0]) | int(p[1]) << 8}
@(private)
le24i :: #force_inline proc "contextless" (p: []byte) -> int {return int(p[0]) | int(p[1]) << 8 | int(p[2]) << 16}
@(private)
le32i :: #force_inline proc "contextless" (p: []byte) -> int {return int(p[0]) | int(p[1]) << 8 | int(p[2]) << 16 | int(p[3]) << 24}
