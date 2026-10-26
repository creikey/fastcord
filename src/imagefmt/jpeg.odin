package imagefmt

import "core:mem"

// JPEG comes from Wuffs (vendor/wuffs), whose decoders are memory-safe by construction: every
// bounds and overflow check is proven at compile time. build.sh / build.bat compile it into
// build/fc_wuffs.obj before any Odin build. Wuffs ignores EXIF, so orientation is applied here.

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

@(default_calling_convention = "c")
@(private = "file")
foreign wuffs {
	fc_jpeg_state_size :: proc() -> uint ---
	fc_jpeg_info :: proc(state: rawptr, state_len: uint, src: [^]u8, src_len: uint, width, height: ^u32, work_len: ^u64) -> i32 ---
	fc_jpeg_decode :: proc(state: rawptr, state_len: uint, src: [^]u8, src_len: uint, rgba: [^]u8, rgba_len: uint, work: [^]u8, work_len: uint) -> i32 ---
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

@(private)
jpeg_decode :: proc(c: ^Decode_Ctx, data: []byte, img: ^Image) -> Error {
	state_len := fc_jpeg_state_size()
	state, serr := mem.alloc_bytes(int(state_len), 16, c.allocator)
	if serr != nil do return .Out_Of_Memory
	defer delete(state, c.allocator)

	w, h: u32
	work_len: u64
	fc_error(fc_jpeg_info(raw_data(state), state_len, raw_data(data), uint(len(data)), &w, &h, &work_len)) or_return
	W, H := int(w), int(h)
	check_size(c, W, H) or_return
	// Progressive files keep every coefficient (2 bytes each, up to 4 components) until the last scan.
	if work_len > u64(8 * c.max_pixels) do return .Too_Large
	work, werr := make([]byte, int(work_len), c.allocator)
	if werr != nil do return .Out_Of_Memory
	defer delete(work, c.allocator)
	px := alloc_pixels(c, W, H) or_return
	if r := fc_jpeg_decode(raw_data(state), state_len, raw_data(data), uint(len(data)), raw_data(px), uint(len(px)), raw_data(work), uint(len(work))); r != FC_OK {
		delete(px, c.allocator)
		return fc_error(r)
	}

	orientation := jpeg_orientation(data)
	ow, oh := W, H
	if orientation != 1 {
		if orientation >= 5 do ow, oh = H, W
		rot, rerr := alloc_pixels(c, ow, oh)
		if rerr != .None {
			delete(px, c.allocator)
			return rerr
		}
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
		px = rot
	}
	img.width, img.height = ow, oh
	img.loop_count = 1
	return push_frame(c, px, 0, true)
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
