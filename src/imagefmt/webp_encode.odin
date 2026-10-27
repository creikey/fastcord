package imagefmt

import "core:c"
import "core:slice"

// vendor/libwebp: the library (fc_libwebp.sources) and its wrapper (fc_libwebp.c).
when ODIN_OS == .Windows {
	foreign import webp {"../../build/fc_libwebp.obj", "../../build/fc_libwebp.lib"}
} else {
	foreign import webp {"../../build/fc_libwebp.o", "../../build/libfc_libwebp.a"}
}

@(default_calling_convention = "c")
foreign webp {
	fc_webp_lossless :: proc(rgba: [^]byte, w, h: c.int, icc: [^]byte, icc_len: uint, out: ^[^]byte) -> uint ---
	fc_webp_free :: proc(p: rawptr) ---
}

// encode_webp_lossless writes RGBA8 pixels (straight alpha) as Chrome's canvas.toBlob("image/webp", 1)
// does: libwebp lossless, quality 75, method 0, plus icc (the canvas's colour profile) in an ICCP
// chunk when given. Fully transparent pixels lose their colour (exact = 0, as in Chrome); Chrome's
// canvas would also premultiply other translucent pixels, which this doesn't (uploads are opaque).
// nil on failure.
encode_webp_lossless :: proc(rgba: []byte, w, h: int, icc: []byte = nil, allocator := context.allocator) -> []byte {
	assert(len(rgba) >= w * h * 4)
	p: [^]byte
	n := fc_webp_lossless(raw_data(rgba), c.int(w), c.int(h), raw_data(icc), len(icc), &p)
	if n == 0 do return nil
	defer fc_webp_free(p)
	return slice.clone(p[:n], allocator)
}
