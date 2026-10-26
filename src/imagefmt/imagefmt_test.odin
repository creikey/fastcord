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
