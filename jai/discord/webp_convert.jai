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
//   - canvas.toBlob("image/webp", 1) = lossless WebP, encoded as Chromium does (imagefmt's
//     encode_webp_lossless, with the sRGB profile Skia attaches); the result is decoded again and its
//     pixels compared with the canvas ("pixel_hash_mismatch"; that check's time is
//     hash_time_ms); kept only if not larger than the PNG ("insufficient_savings");
//   - the converted file keeps its name; original_content_type stays image/png.

WEBP_EXPERIMENT_HASH :: 881712821; // murmur3("2025-09-image-attachment-mezzanine-v2")

// The ICC profile Skia's SkWriteICCProfile writes for an sRGB canvas (src/encode/SkICC.cpp), which
// SkWebpEncoder puts in every canvas WebP: copied from Chrome 156's toBlob output.
SKIA_SRGB_ICC :: #run -> string {
	s, ok := read_entire_file(tprint("%/../../src/discord/skia_srgb.icc", #filepath));
	assert(ok, "skia_srgb.icc");
	return s;
};

Webp_Conversion :: struct {
	attempted: bool; // false: the experiment is off or the file too big (no science fields)
	converted: bool;
	data: []u8; // the WebP (temp allocator) when converted
	failure: string; // conversion_failure_reason (static string)
	compress_ms: s64;
	hash_ms: float64; // only when converted
}

// READY: the user's variation of the conversion experiment (apex assignments [hash, variation, ...]).
note_webp_experiment :: (c: *Client, ready: V) {
	walk :: (v: V, out: *s32) {
		if v.kind == {
			case .List;
				x := v.list;
				if x.count >= 2 && x[0].kind == .Int && x[0].i == WEBP_EXPERIMENT_HASH {
					if x[1].kind == .Int out.* = cast(s32) x[1].i;
					return;
				}
				for x walk(it, out);
			case .Map;
				for v.map walk(it.value, out);
		}
	}
	variation: s32;
	walk(vget(vmap(ready), "apex_experiments"), *variation);
	atomic_store(*c.webp_variation, variation);
}

webp_max_bytes :: (variation: s32) -> int {
	if variation == {
		case 1; return 524288;
		case 2; return 262144;
	}
	return 0;
}

// webp_try_convert runs the client's decision and conversion (worker thread).
webp_try_convert :: (variation: s32, mime: string, data: []u8) -> Webp_Conversion {
	r: Webp_Conversion;
	max_bytes := webp_max_bytes(variation);
	if max_bytes == 0 || data.count > max_bytes return r;
	r.attempted = true;
	t0 := current_time_monotonic();
	defer r.compress_ms = cast(s64) (to_float64_seconds(current_time_monotonic() - t0) * 1000 + 0.5);
	if mime == "image/webp" {
		r.failure = "already_webp";
		return r;
	}
	if mime != "image/png" {
		r.failure = "unsupported_format";
		return r;
	}
	info, ok := png_info(data);
	if !ok {
		r.failure = "corrupted_file";
		return r;
	}
	img, err := imagefmt.decode_first_frame(data, temp);
	if err != .None || !img.frames {
		r.failure = "corrupted_file";
		return r;
	}
	px := img.frames[0].pixels;
	if info.color_type == 4 || info.color_type == 6 {
		for i: 0..px.count / 4 - 1 {
			if px[i * 4 + 3] < 255 {
				r.failure = "has_transparency";
				return r;
			}
		}
	}
	if info.animated {
		r.failure = "animated_image";
		return r;
	}
	if info.color_type == 3 && info.depth <= 8 {
		r.failure = "png8_format";
		return r;
	}
	if info.has_icc {
		desc, iok := icc_description(info.icc);
		if !iok {
			r.failure = "icc_detection_failed";
			return r;
		}
		if !contains(to_lower_copy(desc,, temp), "srgb") {
			r.failure = "icc_non_srgb_profile";
			return r;
		}
	}
	if img.width > 16384 || img.height > 16384 {
		r.failure = "conversion_failed"; // past WebP's dimension limit: Chrome's toBlob fails too
		return r;
	}
	webp := imagefmt.encode_webp_lossless(px, img.width, img.height, cast([]u8) SKIA_SRGB_ICC, temp);
	// the client's pixel check: decode the WebP again and compare with the source pixels
	th := current_time_monotonic();
	back, berr := imagefmt.decode(webp, temp);
	same := berr == .None && back.frames.count == 1 && cast(string) back.frames[0].pixels == cast(string) px;
	hash_ms := to_float64_seconds(current_time_monotonic() - th) * 1000;
	if !same {
		r.failure = "pixel_hash_mismatch";
		return r;
	}
	if webp.count > data.count {
		r.failure = "insufficient_savings";
		return r;
	}
	r.converted = true;
	r.data = webp;
	r.hash_ms = hash_ms;
	return r;
}

Png_Info :: struct {
	color_type: u8;
	depth: u8;
	animated: bool;
	has_icc: bool;
	icc: []u8; // inflated profile (temp allocator); empty when unreadable
}

be32 :: (b: []u8, i: int) -> int {
	return ((cast(int) b[i]) << 24) | ((cast(int) b[i + 1]) << 16) | ((cast(int) b[i + 2]) << 8) | (cast(int) b[i + 3]);
}

png_info :: (data: []u8) -> Png_Info, bool {
	info: Png_Info;
	if data.count < 33 || cast(string) array_view(data, 0, 8) != "\x89PNG\r\n\x1a\n" return info, false;
	i := 8;
	while i + 8 <= data.count {
		n := be32(data, i);
		if n < 0 || i + 12 + n > data.count return info, false;
		body := array_view(data, i + 8, n);
		if cast(string) array_view(data, i + 4, 4) == {
			case "IHDR";
				if n < 13 return info, false;
				info.depth = body[8];
				info.color_type = body[9];
			case "acTL";
				info.animated = true;
			case "iCCP";
				// name, NUL, compression method, zlib data
				z := find_index_from_left(cast(string) body, 0);
				if z < 0 || z + 2 > n return info, false;
				info.has_icc = true;
				icc, iok := inflate.inflate(array_view(body, z + 2), .ZLIB,, temp);
				if iok info.icc = icc;
			case "IEND";
				return info, true;
		}
		i += 12 + n;
	}
	return info, true;
}

// The ICC 'desc' tag's text (v2 textDescriptionType or v4 multiLocalizedUnicodeType),
// what ExifReader reports as "ICC Description".
icc_description :: (p: []u8) -> string, bool {
	if p.count < 132 return "", false;
	for k: 0..be32(p, 128) - 1 {
		t := 132 + k * 12;
		if t + 12 > p.count return "", false;
		if cast(string) array_view(p, t, 4) != "desc" continue;
		off, size := be32(p, t + 4), be32(p, t + 8);
		if off < 0 || size < 12 || off + size > p.count return "", false;
		tag := array_view(p, off, size);
		if cast(string) array_view(tag, 0, 4) == {
			case "desc";
				n := be32(tag, 8);
				if n <= 0 || 12 + n > tag.count return "", true;
				return trim_right(cast(string) array_view(tag, 12, n), "\0"), true;
			case "mluc";
				if tag.count < 28 || be32(tag, 8) < 1 return "", true;
				l, o := be32(tag, 20), be32(tag, 24);
				if o < 0 || l < 0 || o + l > tag.count return "", false;
				// UTF-16BE code units as UTF-8 (no surrogate pairing)
				out: [..]u8;
				out.allocator = temp;
				for j: 0..l / 2 - 1 {
					ch := ((cast(u32) tag[o + j * 2]) << 8) | tag[o + j * 2 + 1];
					if ch == 0 continue;
					if ch < 0x80 array_add(*out, cast(u8) ch);
					else if ch < 0x800 array_add(*out, cast(u8) (0xC0 | (ch >> 6)), cast(u8) (0x80 | (ch & 0x3F)));
					else array_add(*out, cast(u8) (0xE0 | (ch >> 12)), cast(u8) (0x80 | ((ch >> 6) & 0x3F)), cast(u8) (0x80 | (ch & 0x3F)));
				}
				return cast(string) out, true;
		}
		return "", true;
	}
	return "", true; // no description: not known to be sRGB
}
