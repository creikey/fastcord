package imagefmt

import "core:math/rand"
import "core:strconv"
import "core:strings"
import "core:testing"

// Every vector's expected output is a hash of the *reference* decoder's RGBA
// (dwebp / WebPAnimDecoder / djpeg / ImageMagick / ffmpeg), see testdata/gen.sh.
@(private = "file")
FILES := #load_directory("testdata")

@(private = "file")
file :: proc(name: string) -> []byte {
	for f in FILES do if f.name == name do return f.data
	return nil
}

@(private = "file")
fnv64 :: proc(frames: []Frame) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for f in frames do for b in f.pixels do h = (h ~ u64(b)) * 0x100000001b3
	return h
}

@(test)
test_vectors :: proc(t: ^testing.T) {
	manifest := string(file("manifest.txt"))
	n := 0
	for line in strings.split_lines_iterator(&manifest) {
		if len(line) == 0 || line[0] == '#' do continue
		f := strings.fields(line, context.temp_allocator)
		name := f[0]
		w, _ := strconv.parse_int(f[1])
		h, _ := strconv.parse_int(f[2])
		nf, _ := strconv.parse_int(f[3])
		loop, _ := strconv.parse_int(f[4])
		data := file(name)
		testing.expectf(t, data != nil, "%s: missing", name)
		img, err := decode(data)
		defer image_destroy(&img)
		if !testing.expectf(t, err == .None, "%s: %v", name, err) do continue
		testing.expectf(t, img.width == w && img.height == h && len(img.frames) == nf && img.loop_count == loop, "%s: got %dx%d %d frames loop %d", name, img.width, img.height, len(img.frames), img.loop_count)
		if f[5][0] == '~' {
			ref := file(f[5][1:])
			raw := make([]u8, w * h * nf * 4, context.temp_allocator)
			got, ierr := inflate_zlib(ref, raw)
			testing.expect(t, ierr == .None && got == len(raw))
			tol, _ := strconv.parse_int(f[6])
			maxd := 0
			i := 0
			for fr in img.frames do for b in fr.pixels {
				maxd = max(maxd, abs(int(b) - int(raw[i])))
				i += 1
			}
			testing.expectf(t, maxd <= tol, "%s: max diff %d > %d", name, maxd, tol)
		} else {
			want, _ := strconv.parse_u64(f[5], 16)
			testing.expectf(t, fnv64(img.frames) == want, "%s: pixels differ from reference", name)
		}
		// first-frame path must agree with frame 0
		one, ferr := decode_first_frame(data)
		testing.expectf(t, ferr == .None && len(one.frames) == 1 && string(one.frames[0].pixels) == string(img.frames[0].pixels), "%s: decode_first_frame differs", name)
		image_destroy(&one)
		n += 1
	}
	testing.expect(t, n >= 50)
}

@(test)
test_durations :: proc(t: ^testing.T) {
	img, err := decode(file("a_mix.webp"))
	defer image_destroy(&img)
	testing.expect_value(t, err, Error.None)
	want := []int{80, 100, 100, 100, 100, 300} // 5 ms -> 100 ms like browsers
	for f, i in img.frames do testing.expect_value(t, f.duration_ms, want[i])
	g, gerr := decode(file("g_bg.gif"))
	defer image_destroy(&g)
	testing.expect_value(t, gerr, Error.None)
	for f in g.frames do testing.expect_value(t, f.duration_ms, 100) // delay 0
}

@(test)
test_errors :: proc(t: ^testing.T) {
	_, e1 := decode([]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12})
	testing.expect_value(t, e1, Error.Unknown_Format)
	_, e2 := decode(file("j_rose.base.jpg"), max_pixels = 1000)
	testing.expect_value(t, e2, Error.Too_Large)
	_, e3 := decode(file("w_rose.o2.webp"), max_pixels = 1000)
	testing.expect_value(t, e3, Error.Too_Large)
	_, e4 := decode(nil)
	testing.expect_value(t, e4, Error.Unknown_Format)
}

// Truncation at every length and random corruption must never crash.
@(test)
test_corruption :: proc(t: ^testing.T) {
	names := []string{"w_rose.o10.webp", "w_odd.o18.webp", "t_sa_filt.webp", "a_kf.webp", "g_opt.gif", "p_odd.i.png", "ap_anim8m.png", "j_rose.prog.jpg", "j_rose.rst.jpg"}
	r := rand.create(11)
	gen := rand.default_random_generator(&r)
	for name in names {
		src := file(name)
		for n in 0 ..< len(src) {
			img, _ := decode(src[:n])
			image_destroy(&img)
		}
		buf := make([]byte, len(src), context.temp_allocator)
		for _ in 0 ..< 300 {
			copy(buf, src)
			for _ in 0 ..< 1 + rand.int_max(4, gen) {
				buf[rand.int_max(len(buf), gen)] ~= u8(1) << uint(rand.int_max(8, gen))
			}
			img, err := decode(buf, max_pixels = 1 << 20)
			if err == .None do for f in img.frames do testing.expect(t, len(f.pixels) == img.width * img.height * 4)
			image_destroy(&img)
		}
	}
}

@(test)
test_png_encode_roundtrip :: proc(t: ^testing.T) {
	// a gradient with a flat area and noise: every filter and both literals and matches
	w, h := 97, 61
	px := make([]byte, w * h * 4, context.temp_allocator)
	for y in 0 ..< h do for x in 0 ..< w {
		p := px[(y * w + x) * 4:]
		p[0] = u8(x * 2)
		p[1] = y < 30 ? 40 : u8(rand.uint32())
		p[2] = u8(x + y)
		p[3] = u8(255 - y)
	}
	png := encode_png(px, w, h, context.temp_allocator)
	testing.expect_value(t, sniff(png), Format.PNG)
	img, err := decode(png, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, img.width, w)
	testing.expect_value(t, img.height, h)
	if len(img.frames) == 1 do testing.expect(t, string(img.frames[0].pixels) == string(px), "pixels differ after encode + decode")
	// flat images compress well (stored would be > 4 * w * h)
	flat := make([]byte, 512 * 512 * 4, context.temp_allocator)
	testing.expect(t, len(encode_png(flat, 512, 512, context.temp_allocator)) < 16384)
	// a 1x1 image and an empty stream are valid
	one := []byte{1, 2, 3, 4}
	d1, e1 := decode(encode_png(one, 1, 1, context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, e1, Error.None)
	if len(d1.frames) == 1 do testing.expect(t, string(d1.frames[0].pixels) == string(one))
}

@(private = "file")
webp_roundtrip :: proc(t: ^testing.T, px: []byte, w, h: int, loc := #caller_location) -> int {
	webp := encode_webp_lossless(px, w, h, context.temp_allocator)
	testing.expect_value(t, sniff(webp), Format.WebP, loc = loc)
	img, err := decode(webp, context.temp_allocator)
	testing.expect_value(t, err, Error.None, loc = loc)
	if err == .None && len(img.frames) == 1 {
		testing.expect_value(t, img.width, w, loc = loc)
		testing.expect_value(t, img.height, h, loc = loc)
		got := img.frames[0].pixels
		for i in 0 ..< w * h {
			if string(got[i * 4:][:4]) != string(px[i * 4:][:4]) {
				testing.expectf(t, false, "WebP round trip: pixel %d (x %d y %d) got %v want %v", i, i % w, i / w, got[i * 4:][:4], px[i * 4:][:4], loc = loc)
				break
			}
		}
	}
	return len(webp)
}

@(test)
test_webp_lossless_roundtrip :: proc(t: ^testing.T) {
	// a smooth gradient (predictors), noise (literals), flat runs (LZ77 / cache), alpha
	w, h := 131, 77
	px := make([]byte, w * h * 4, context.temp_allocator)
	for y in 0 ..< h do for x in 0 ..< w {
		p := px[(y * w + x) * 4:]
		p[0] = u8(x * 2)
		p[1] = y < 20 ? 40 : (y < 50 ? u8(x + y) : u8(rand.uint32()))
		p[2] = u8(x ~ y)
		p[3] = x < 60 ? 255 : u8(y * 3)
	}
	webp_roundtrip(t, px, w, h)
	// palette images: <= 2, <= 4, <= 16, <= 256 colors (pixel bundling)
	for ncol in ([]int{1, 2, 3, 11, 200}) {
		for i in 0 ..< w * h {
			c := (i * 7 + i / w) % ncol
			px[i * 4 + 0], px[i * 4 + 1], px[i * 4 + 2], px[i * 4 + 3] = u8(c * 37), u8(c * 11), u8(c), 255
		}
		webp_roundtrip(t, px, w, h)
	}
	// 1x1 and a single row / column
	webp_roundtrip(t, []byte{9, 8, 7, 255}, 1, 1)
	webp_roundtrip(t, px[:w * 4], w, 1)
	webp_roundtrip(t, px[:h * 4], 1, h)
	// the parity test image (a 64x48 gradient PNG)
	src := file("t_basn2c08.png")
	if src != nil {
		img, err := decode(src, context.temp_allocator)
		if err == .None do webp_roundtrip(t, img.frames[0].pixels, img.width, img.height)
	}
}
