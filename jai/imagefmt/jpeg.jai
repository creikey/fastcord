#scope_module

// JPEG decodes through Wuffs (wuffs.odin), which ignores EXIF, so orientation is applied here.

jpeg_decode :: (c: *Decode_Ctx, data: []u8, img: *Image) -> Error {
	__e1 := wuffs_decode(c, data, img, .JPEG); if failed(__e1) return __e1;
	orientation := jpeg_orientation(data);
	if orientation == 1 { return .None; }
	W, H := img.width, img.height;
	ow, oh := W, H;
	if orientation >= 5 { ow, oh = H, W; }
	px := c.frames[0].pixels;
	rot, __e2 := alloc_pixels(c, ow, oh); if failed(__e2) return __e2;
	for y: 0..H-1 {
		for x: 0..W-1 {
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
			copy(sub(sub_from(rot, (ny * ow + nx) * 4), 0, 4), sub(sub_from(px, (y * W + x) * 4), 0, 4));
		}
	}
	delete(px, c.allocator);
	c.frames[0].pixels = rot;
	img.width, img.height = ow, oh;
	return .None;
}

// EXIF orientation (1-8) from the first APP1 segment before the image data; 1 if there is none.
jpeg_orientation :: (data: []u8) -> int {
	p := 2;
	while p + 4 <= len(data) {
		if data[p] != 0xFF {
			p += 1;
			continue;
		}
		m := data[p + 1];
		if m == 0xFF {
			p += 1;
			continue;
		}
		p += 2;
		if m == 0xD8 || m == 0x01 || m >= 0xD0 && m <= 0xD7 { continue; }
		if m == 0xDA || m == 0xD9 { break; }
		ln := be16(sub_from(data, p));
		if ln < 2 || p + ln > len(data) { break; }
		if m == 0xE1 {
			{ o := exif_orientation(sub(data, p + 2, p + ln));
			if o != 1 { return o; } }
		}
		p += ln;
	}
	return 1;
}

exif_orientation :: (seg: []u8) -> int {
	if len(seg) < 14 || as_string(sub(seg, 0, 6)) != "Exif\x00\x00" { return 1; }
	t := sub_from(seg, 6);
	le := t[0] == #char "I";
	r16 :: (t: []u8, o: int, le: bool) -> int {
		if o < 0 || o + 2 > len(t) { return 0; }
		return ifx le then le16i(sub_from(t, o)) else be16(sub_from(t, o));
	}
	r32 :: (t: []u8, o: int, le: bool) -> int {
		if o < 0 || o + 4 > len(t) { return 0; }
		return ifx le then le32i(sub_from(t, o)) else be32(sub_from(t, o));
	}
	ifd := r32(t, 4, le);
	n := r16(t, ifd, le);
	for i: 0..n-1 {
		e := ifd + 2 + i * 12;
		if e + 12 > len(t) { break; }
		if r16(t, e, le) == 0x0112 {
			v := r16(t, e + 8, le);
			return ifx v >= 1 && v <= 8 then v else 1;
		}
	}
	return 1;
}
#scope_export

