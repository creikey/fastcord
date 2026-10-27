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
SKIA_SRGB_ICC :: #run load_file("skia_srgb.icc", #filepath);

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
	variation: s32;
	walk :: (v: V, out: *s32) {
		if v.kind == {
		case .List; x := v.list;
			if len(x) >= 2 {
				{ h, ok := x[0].i, x[0].kind == .Int;
				if ok && h == WEBP_EXPERIMENT_HASH {
					{ var, ok2 := x[1].i, x[1].kind == .Int;
					if ok2 { out.* = cast(s32)(var); } }
					return;
				} }
			}
			for e: x { walk(e, out); }
		case .Map; x := v.map;
			for p: x { walk(p.value, out); }
		}
	}
	walk(vget(vmap(ready), "apex_experiments"), *variation);
	atomic_store(*c.webp_variation, variation);
}

webp_max_bytes :: (variation: s32) -> int {
	if variation == {
	case 1;
		return 524288;
	case 2;
		return 262144;
	}
	return 0;
}

// webp_try_convert runs the client's decision and conversion (worker thread).
webp_try_convert :: (variation: s32, mime: string, data: []u8) -> Webp_Conversion {
	r: Webp_Conversion;
	max_bytes := webp_max_bytes(variation);
	if max_bytes == 0 || len(data) > max_bytes { return r; }
	r.attempted = true;
	t0 := time.tick_now();
	defer r.compress_ms = cast(s64)(time.duration_milliseconds(time.tick_since(t0)) + 0.5);
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
	if err != .None || len(img.frames) == 0 {
		r.failure = "corrupted_file";
		return r;
	}
	px := img.frames[0].pixels;
	if info.color_type == 4 || info.color_type == 6 {
		{ i := 3;
		while i < len(px) {
			if px[i] < 255 {
				r.failure = "has_transparency";
				return r;
			}
			i += 4;
} }
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
		if desc == "" || !strings.contains(strings.to_lower(desc, temp), "srgb") {
			r.failure = "icc_non_srgb_profile";
			return r;
		}
	}
	if img.width > 16384 || img.height > 16384 {
		r.failure = "conversion_failed"; // past WebP's dimension limit: Chrome's toBlob fails too
		return r;
	}
	webp := imagefmt.encode_webp_lossless(px, img.width, img.height, SKIA_SRGB_ICC, temp);
	// the client's pixel check: decode the WebP again and compare with the source pixels
	th := time.tick_now();
	back, berr := imagefmt.decode(webp, temp);
	same := berr == .None && len(back.frames) == 1 && as_string(back.frames[0].pixels) == as_string(px);
	hash_ms := time.duration_milliseconds(time.tick_since(th));
	if !same {
		r.failure = "pixel_hash_mismatch";
		return r;
	}
	if len(webp) > len(data) {
		r.failure = "insufficient_savings";
		return r;
	}
	r.converted = true;
	r.data = webp;
	r.hash_ms = hash_ms;
	return r;
}
#scope_module

Png_Info :: struct {
	color_type: u8;
	depth: u8;
	animated: bool;
	has_icc: bool;
	icc: []u8; // inflated profile (temp allocator); empty when unreadable
}

png_info :: (data: []u8) -> Png_Info, bool {
	info: Png_Info;
	ok: bool;
	if len(data) < 33 || as_string(sub(data, 0, 8)) != "\x89PNG\r\n\x1a\n" { return info, ok; }
	be32 :: (b: []u8) -> int {return ((cast(int)(b[0])) << 24) | ((cast(int)(b[1])) << 16) | ((cast(int)(b[2])) << 8) | (cast(int)(b[3]));}
	i := 8;
	while i + 8 <= len(data) {
		n := be32(sub_from(data, i));
		typ := as_string(sub(sub_from(data, i + 4), 0, 4));
		if n < 0 || i + 12 + n > len(data) { return info, ok; }
		body := sub(sub_from(data, i + 8), 0, n);
		if typ == {
		case "IHDR";
			if n < 13 { return info, ok; }
			info.depth = body[8];
			info.color_type = body[9];
		case "acTL";
			info.animated = true;
		case "iCCP";
			// name, NUL, compression method, zlib data
			z := strings.index_byte(as_string(body), 0);
			if z < 0 || z + 2 > n { return info, ok; }
			info.has_icc = true;
			icc: bytes.Buffer;
			push_allocator(temp);
			if zlib.inflate(sub_from(body, z + 2), *icc) == null { info.icc = view(icc.buf); }
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
	be32 :: (b: []u8) -> int {return ((cast(int)(b[0])) << 24) | ((cast(int)(b[1])) << 16) | ((cast(int)(b[2])) << 8) | (cast(int)(b[3]));}
	if len(p) < 132 { return "", false; }
	ntags := be32(sub_from(p, 128));
	for k: 0..ntags-1 {
		t := 132 + k * 12;
		if t + 12 > len(p) { return "", false; }
		if as_string(sub(sub_from(p, t), 0, 4)) != "desc" { continue; }
		off, size := be32(sub_from(p, t + 4)), be32(sub_from(p, t + 8));
		if off < 0 || size < 12 || off + size > len(p) { return "", false; }
		tag := sub(sub_from(p, off), 0, size);
		if as_string(sub(tag, 0, 4)) == {
		case "desc";
			n := be32(sub_from(tag, 8));
			if n <= 0 || 12 + n > len(tag) { return "", true; }
			return strings.trim_right(as_string(sub(sub_from(tag, 12), 0, n)), "\x00"), true;
		case "mluc";
			if len(tag) < 28 || be32(sub_from(tag, 8)) < 1 { return "", true; }
			l, o := be32(sub_from(tag, 20)), be32(sub_from(tag, 24));
			if o < 0 || l < 0 || o + l > len(tag) { return "", false; }
			sb := strings.builder_make(temp);
			{ j := 0;
			while j + 1 < l {
				ch := cast(u32)(((cast(u16)(tag[o + j])) << 8) | (cast(u16)(tag[o + j + 1])));
				if ch != 0 { strings.write_rune(*sb, ch); }
				j += 2;
} }
			return strings.to_string(sb), true;
		}
		return "", true;
	}
	return "", true; // no description: not known to be sRGB
}
#scope_export

