package imagefmt

// JPEG decodes through Wuffs (wuffs.odin), which ignores EXIF, so orientation is applied here.

@(private)
jpeg_decode :: proc(c: ^Decode_Ctx, data: []byte, img: ^Image) -> Error {
	wuffs_decode(c, data, img, .JPEG) or_return
	orientation := jpeg_orientation(data)
	if orientation == 1 do return .None
	W, H := img.width, img.height
	ow, oh := W, H
	if orientation >= 5 do ow, oh = H, W
	px := c.frames[0].pixels
	rot := alloc_pixels(c, ow, oh) or_return
	for y in 0 ..< H {
		for x in 0 ..< W {
			nx, ny: int
			switch orientation {
			case 2: nx, ny = W - 1 - x, y
			case 3: nx, ny = W - 1 - x, H - 1 - y
			case 4: nx, ny = x, H - 1 - y
			case 5: nx, ny = y, x
			case 6: nx, ny = H - 1 - y, x
			case 7: nx, ny = H - 1 - y, W - 1 - x
			case 8: nx, ny = y, W - 1 - x
			}
			copy(rot[(ny * ow + nx) * 4:][:4], px[(y * W + x) * 4:][:4])
		}
	}
	delete(px, c.allocator)
	c.frames[0].pixels = rot
	img.width, img.height = ow, oh
	return .None
}

// EXIF orientation (1-8) from the first APP1 segment before the image data; 1 if there is none.
@(private)
jpeg_orientation :: proc(data: []byte) -> int {
	p := 2
	for p + 4 <= len(data) {
		if data[p] != 0xFF {
			p += 1
			continue
		}
		m := data[p + 1]
		if m == 0xFF {
			p += 1
			continue
		}
		p += 2
		if m == 0xD8 || m == 0x01 || m >= 0xD0 && m <= 0xD7 do continue
		if m == 0xDA || m == 0xD9 do break
		ln := be16(data[p:])
		if ln < 2 || p + ln > len(data) do break
		if m == 0xE1 {
			if o := exif_orientation(data[p + 2:p + ln]); o != 1 do return o
		}
		p += ln
	}
	return 1
}

@(private)
exif_orientation :: proc(seg: []byte) -> int {
	if len(seg) < 14 || string(seg[:6]) != "Exif\x00\x00" do return 1
	t := seg[6:]
	le := t[0] == 'I'
	r16 :: proc(t: []byte, o: int, le: bool) -> int {
		if o < 0 || o + 2 > len(t) do return 0
		return le ? le16i(t[o:]) : be16(t[o:])
	}
	r32 :: proc(t: []byte, o: int, le: bool) -> int {
		if o < 0 || o + 4 > len(t) do return 0
		return le ? le32i(t[o:]) : be32(t[o:])
	}
	ifd := r32(t, 4, le)
	n := r16(t, ifd, le)
	for i in 0 ..< n {
		e := ifd + 2 + i * 12
		if e + 12 > len(t) do break
		if r16(t, e, le) == 0x0112 {
			v := r16(t, e + 8, le)
			return v >= 1 && v <= 8 ? v : 1
		}
	}
	return 1
}
