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
	if data.count >= 8 && bytes(data, 0, 8) == "\x89PNG\r\n\x1a\n" return .PNG;
	if data.count >= 6 && (bytes(data, 0, 6) == "GIF87a" || bytes(data, 0, 6) == "GIF89a") return .GIF;
	if data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF return .JPEG;
	if data.count >= 12 && bytes(data, 0, 4) == "RIFF" && bytes(data, 8, 4) == "WEBP" return .WebP;
	return .Unknown;
}

// Decode all frames (or only the first: the cheap path for thumbnails / static display). max_pixels
// limits the canvas (width*height); the sum over all frames is limited to 4*max_pixels.
decode :: (data: []u8, allocator := context.allocator, max_pixels := 64 << 20, first_only := false) -> Image, Error {
	img: Image;
	c := Decode_Ctx.{allocator = allocator, max_pixels = max_pixels, first_only = first_only};
	c.frames.allocator = allocator;
	img.format = sniff(data);
	err: Error;
	if img.format == {
		case .PNG; #through;
		case .GIF;     err = wuffs_decode(*c, data, *img, img.format);
		case .JPEG;    err = jpeg_decode(*c, data, *img);
		case .WebP;    err = webp_decode(*c, data, *img);
		case .Unknown; err = .Unknown_Format;
	}
	if err == .None && c.frames.count == 0  err = .Corrupt;
	if err != .None {
		for c.frames free(it.pixels.data,, allocator);
		array_free(c.frames);
		return .{}, err;
	}
	img.frames = c.frames;
	if img.frames.count == 1  img.loop_count = 1;
	return img, .None;
}

decode_first_frame :: (data: []u8, allocator := context.allocator, max_pixels := 64 << 20) -> Image, Error {
	img, err := decode(data, allocator, max_pixels, true);
	return img, err;
}

image_destroy :: (img: *Image, allocator := context.allocator) {
	for img.frames free(it.pixels.data,, allocator);
	free(img.frames.data,, allocator);
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

check_size :: (c: *Decode_Ctx, w: int, h: int) -> Error {
	if w <= 0 || h <= 0 return .Corrupt;
	if w > (1 << 16) || h > (1 << 16) || w * h > c.max_pixels return .Too_Large;
	return .None;
}

// Append a frame holding a copy of pixels, or taking them over when take is set.
push_frame :: (c: *Decode_Ctx, pixels: []u8, duration_ms: int, take := false) -> Error {
	c.total_px += pixels.count / 4;
	if c.total_px > 4 * c.max_pixels {
		if take free(pixels.data,, c.allocator);
		return .Too_Large;
	}
	array_add(*c.frames, Frame.{ifx take then pixels else array_copy(pixels,, c.allocator), ifx duration_ms <= 10 then 100 else duration_ms});
	return .None;
}

alloc_pixels :: (c: *Decode_Ctx, w: int, h: int) -> []u8 {
	return NewArray(w * h * 4, u8,, c.allocator);
}

bytes :: inline (d: []u8, i: int, n: int) -> string { return to_string(d.data + i, n); }

be16 :: inline (p: []u8, i: int) -> int { return ((cast(int) p[i]) << 8) | (cast(int) p[i + 1]); }
be32 :: inline (p: []u8, i: int) -> int { return (be16(p, i) << 16) | be16(p, i + 2); }
le16 :: inline (p: []u8, i: int) -> int { return (cast(int) p[i]) | ((cast(int) p[i + 1]) << 8); }
le24 :: inline (p: []u8, i: int) -> int { return le16(p, i) | ((cast(int) p[i + 2]) << 16); }
le32 :: inline (p: []u8, i: int) -> int { return le16(p, i) | (le16(p, i + 2) << 16); }

// JPEG decodes through Wuffs, which ignores EXIF, so orientation is applied here.
jpeg_decode :: (c: *Decode_Ctx, data: []u8, img: *Image) -> Error {
	err := wuffs_decode(c, data, img, .JPEG);
	if err != .None return err;
	orientation := jpeg_orientation(data);
	if orientation == 1 return .None;
	W, H := img.width, img.height;
	ow, oh := W, H;
	if orientation >= 5  ow, oh = H, W;
	px := c.frames[0].pixels;
	rot := alloc_pixels(c, ow, oh);
	for y: 0..H-1 for x: 0..W-1 {
		nx, ny: int;
		if orientation == {
			case 2; nx, ny = W - 1 - x, y;
			case 3; nx, ny = W - 1 - x, H - 1 - y;
			case 4; nx, ny = x, H - 1 - y;
			case 5; nx, ny = y, x;
			case 6; nx, ny = H - 1 - y, x;
			case 7; nx, ny = H - 1 - y, W - 1 - x;
			case 8; nx, ny = y, W - 1 - x;
		}
		memcpy(rot.data + (ny * ow + nx) * 4, px.data + (y * W + x) * 4, 4);
	}
	free(px.data,, c.allocator);
	c.frames[0].pixels = rot;
	img.width, img.height = ow, oh;
	return .None;
}

// EXIF orientation (1-8) from the first APP1 segment before the image data; 1 if there is none.
jpeg_orientation :: (data: []u8) -> int {
	p := 2;
	while p + 4 <= data.count {
		if data[p] != 0xFF { p += 1; continue; }
		m := data[p + 1];
		if m == 0xFF { p += 1; continue; }
		p += 2;
		if m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) continue;
		if m == 0xDA || m == 0xD9 break;
		ln := be16(data, p);
		if ln < 2 || p + ln > data.count break;
		if m == 0xE1 {
			o := exif_orientation(array_view(data, p + 2, ln - 2));
			if o != 1 return o;
		}
		p += ln;
	}
	return 1;
}

exif_orientation :: (seg: []u8) -> int {
	if seg.count < 14 || bytes(seg, 0, 6) != "Exif\x00\x00" return 1;
	t := array_view(seg, 6);
	le := t[0] == #char "I";
	rd :: (t: []u8, o: int, n: int, le: bool) -> int {
		if o < 0 || o + n > t.count return 0;
		if n == 2 return ifx le then le16(t, o) else be16(t, o);
		return ifx le then le32(t, o) else be32(t, o);
	}
	ifd := rd(t, 4, 4, le);
	for i: 0..rd(t, ifd, 2, le)-1 {
		e := ifd + 2 + i * 12;
		if e + 12 > t.count break;
		if rd(t, e, 2, le) == 0x0112 {
			v := rd(t, e + 8, 2, le);
			return ifx v >= 1 && v <= 8 then v else 1;
		}
	}
	return 1;
}
