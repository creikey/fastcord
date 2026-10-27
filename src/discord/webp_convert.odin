package discord

// The official client's upload "mezzanine" conversion (CloudUpload.tryConvertToWebP and the
// maybeConvertToWebP chunk of web 0.0.419, read from its cached bundle):
//   - gated by the experiment "2025-09-image-attachment-mezzanine-v2" (READY
//     apex_experiments): variation 1 = on, files up to 524288 bytes; 2 = on, up to 262144;
//     off otherwise. When off or the file is bigger, nothing is attempted and the
//     finished event carries no compress_time_ms / conversion_failure_reason;
//   - only image/png (by the file's type, i.e. its extension) is converted: image/webp ->
//     "already_webp", anything else -> "unsupported_format";
//   - the PNG must decode ("corrupted_file"), have no real transparency (color type 4/6 with
//     an alpha < 255: "has_transparency"), not be APNG ("animated_image") or indexed
//     ("png8_format"), and its ICC profile, if any, must describe sRGB
//     ("icc_non_srgb_profile" / "icc_detection_failed");
//   - canvas.toBlob("image/webp", 1) = lossless WebP; the result is decoded again and its
//     pixels compared with the canvas ("pixel_hash_mismatch"; that check's time is
//     hash_time_ms); kept only if not larger than the PNG ("insufficient_savings");
//   - the converted file keeps its name; original_content_type stays image/png.

import "core:strings"
import "core:sync"
import "core:time"
import "fc:etf"
import "fc:imagefmt"

WEBP_EXPERIMENT_HASH :: 881712821 // murmur3("2025-09-image-attachment-mezzanine-v2")

Webp_Conversion :: struct {
	attempted:   bool, // false: the experiment is off or the file too big (no science fields)
	converted:   bool,
	data:        []byte, // the WebP (temp allocator) when converted
	failure:     string, // conversion_failure_reason (static string)
	compress_ms: i64,
	hash_ms:     f64, // only when converted
}

// READY: the user's variation of the conversion experiment (apex assignments [hash, variation, ...]).
note_webp_experiment :: proc(c: ^Client, ready: V) {
	variation: i32
	walk :: proc(v: V, out: ^i32) {
		#partial switch x in v {
		case etf.List:
			if len(x) >= 2 {
				if h, ok := x[0].(i64); ok && h == WEBP_EXPERIMENT_HASH {
					if var, ok2 := x[1].(i64); ok2 do out^ = i32(var)
					return
				}
			}
			for e in x do walk(e, out)
		case etf.Map:
			for p in x do walk(p.value, out)
		}
	}
	walk(vget(vmap(ready), "apex_experiments"), &variation)
	sync.atomic_store(&c.webp_variation, variation)
}

webp_max_bytes :: proc(variation: i32) -> int {
	switch variation {
	case 1:
		return 524288
	case 2:
		return 262144
	}
	return 0
}

// webp_try_convert runs the client's decision and conversion (worker thread).
webp_try_convert :: proc(variation: i32, mime: string, data: []byte) -> (r: Webp_Conversion) {
	max_bytes := webp_max_bytes(variation)
	if max_bytes == 0 || len(data) > max_bytes do return
	r.attempted = true
	t0 := time.tick_now()
	defer r.compress_ms = i64(time.duration_milliseconds(time.tick_since(t0)) + 0.5)
	if mime == "image/webp" {
		r.failure = "already_webp"
		return
	}
	if mime != "image/png" {
		r.failure = "unsupported_format"
		return
	}
	info, ok := png_info(data)
	if !ok {
		r.failure = "corrupted_file"
		return
	}
	img, err := imagefmt.decode_first_frame(data, context.temp_allocator)
	if err != .None || len(img.frames) == 0 {
		r.failure = "corrupted_file"
		return
	}
	px := img.frames[0].pixels
	if info.color_type == 4 || info.color_type == 6 {
		for i := 3; i < len(px); i += 4 {
			if px[i] < 255 {
				r.failure = "has_transparency"
				return
			}
		}
	}
	if info.animated {
		r.failure = "animated_image"
		return
	}
	if info.color_type == 3 && info.depth <= 8 {
		r.failure = "png8_format"
		return
	}
	if info.has_icc {
		desc, iok := icc_description(info.icc)
		if !iok {
			r.failure = "icc_detection_failed"
			return
		}
		if desc == "" || !strings.contains(strings.to_lower(desc, context.temp_allocator), "srgb") {
			r.failure = "icc_non_srgb_profile"
			return
		}
	}
	if img.width > 16384 || img.height > 16384 {
		r.failure = "conversion_failed" // past WebP's dimension limit: Chrome's toBlob fails too
		return
	}
	webp := imagefmt.encode_webp_lossless(px, img.width, img.height, context.temp_allocator)
	// the client's pixel check: decode the WebP again and compare with the source pixels
	th := time.tick_now()
	back, berr := imagefmt.decode(webp, context.temp_allocator)
	same := berr == .None && len(back.frames) == 1 && string(back.frames[0].pixels) == string(px)
	hash_ms := time.duration_milliseconds(time.tick_since(th))
	if !same {
		r.failure = "pixel_hash_mismatch"
		return
	}
	if len(webp) > len(data) {
		r.failure = "insufficient_savings"
		return
	}
	r.converted = true
	r.data = webp
	r.hash_ms = hash_ms
	return
}

@(private)
Png_Info :: struct {
	color_type: u8,
	depth:      u8,
	animated:   bool,
	has_icc:    bool,
	icc:        []byte, // inflated profile (temp allocator); empty when unreadable
}

@(private)
png_info :: proc(data: []byte) -> (info: Png_Info, ok: bool) {
	if len(data) < 33 || string(data[:8]) != "\x89PNG\r\n\x1a\n" do return
	be32 :: proc(b: []byte) -> int {return int(b[0]) << 24 | int(b[1]) << 16 | int(b[2]) << 8 | int(b[3])}
	i := 8
	for i + 8 <= len(data) {
		n := be32(data[i:])
		typ := string(data[i + 4:][:4])
		if n < 0 || i + 12 + n > len(data) do return
		body := data[i + 8:][:n]
		switch typ {
		case "IHDR":
			if n < 13 do return
			info.depth = body[8]
			info.color_type = body[9]
		case "acTL":
			info.animated = true
		case "iCCP":
			// name, NUL, compression method, zlib data
			z := strings.index_byte(string(body), 0)
			if z < 0 || z + 2 > n do return
			info.has_icc = true
			info.icc = imagefmt.zlib_inflate(body[z + 2:], 16 << 20, context.temp_allocator)
		case "IEND":
			return info, true
		}
		i += 12 + n
	}
	return info, true
}

// The ICC 'desc' tag's text (v2 textDescriptionType or v4 multiLocalizedUnicodeType),
// what ExifReader reports as "ICC Description".
@(private)
icc_description :: proc(p: []byte) -> (string, bool) {
	be32 :: proc(b: []byte) -> int {return int(b[0]) << 24 | int(b[1]) << 16 | int(b[2]) << 8 | int(b[3])}
	if len(p) < 132 do return "", false
	ntags := be32(p[128:])
	for k in 0 ..< ntags {
		t := 132 + k * 12
		if t + 12 > len(p) do return "", false
		if string(p[t:][:4]) != "desc" do continue
		off, size := be32(p[t + 4:]), be32(p[t + 8:])
		if off < 0 || size < 12 || off + size > len(p) do return "", false
		tag := p[off:][:size]
		switch string(tag[:4]) {
		case "desc":
			n := be32(tag[8:])
			if n <= 0 || 12 + n > len(tag) do return "", true
			return strings.trim_right(string(tag[12:][:n]), "\x00"), true
		case "mluc":
			if len(tag) < 28 || be32(tag[8:]) < 1 do return "", true
			l, o := be32(tag[20:]), be32(tag[24:])
			if o < 0 || l < 0 || o + l > len(tag) do return "", false
			sb := strings.builder_make(context.temp_allocator)
			for j := 0; j + 1 < l; j += 2 {
				ch := rune(u16(tag[o + j]) << 8 | u16(tag[o + j + 1]))
				if ch != 0 do strings.write_rune(&sb, ch)
			}
			return strings.to_string(sb), true
		}
		return "", true
	}
	return "", true // no description: not known to be sRGB
}
