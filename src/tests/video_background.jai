// Camera background effects on the GPU (video.background_apply, src/video/segment.jai), offline: a frame
// is blurred, then replaced by a picture. The built-in frame has no one in it, so all of it is background;
// a photo given as the argument is processed too, for a look at build/video_background_*.png.
//   jai build.jai - run src/tests/video_background.jai && build/video_background [photo]
#import "Basic";
#import "File";
#import "Math";
video :: #import "video";
yuv :: #import "yuv";
gfx :: #import "gfx";
imagefmt :: #import "imagefmt";

W :: 640;
H :: 360;

failures := 0;
expect :: (ok: bool, what: string, args: ..Any) {
	if ok return;
	failures += 1;
	print("FAIL: %\n", tprint(what, ..args));
}

main :: () {
	// Stripes 16 pixels wide, black and white: sharp edges for the blur to soften.
	f := yuv.nv12_create(W, H);
	for y: 0..H - 1 for x: 0..W - 1 f.data[y * W + x] = xx ifx (x / 16) % 2 then 235 else 16;
	for W * H..f.data.count - 1 f.data[it] = 128;
	write_entire_file("build/video_background_red.png", cast(string) gfx.encode_png(solid(255, 0, 0, 64, 64), 64, 64));

	video.background_set(.Blur, "");
	out := cast(*yuv.Nv12) video.background_apply(f);
	expect(out != null, "blur ran (%)", video.background_error());
	if out {
		edge := 0;
		for x: 1..W - 1 edge = max(edge, abs(cast(int) out.data[H / 2 * W + x] - out.data[H / 2 * W + x - 1]));
		expect(edge < 20, "blurred: the sharpest step is % (the frame's is 219)", edge);
		mid := out.data[H / 2 * W + W / 2];
		expect(mid > 100 && mid < 150, "blurred stripes average to grey: %", mid);
		video.pixbuf_release(out);
	}

	video.background_set(.Image, "build/video_background_red.png");
	out = video.background_apply(f);
	expect(out != null, "picture ran (%)", video.background_error());
	if out {
		// Red, limited range BT.601: Y 82, Cb 90, Cr 240.
		y, cb, cr := out.data[H / 2 * W + W / 2], out.data[W * H + H / 4 * W + W / 2], out.data[W * H + H / 4 * W + W / 2 + 1];
		expect(abs(cast(int) y - 82) <= 2 && abs(cast(int) cb - 90) <= 2 && abs(cast(int) cr - 240) <= 2, "the picture replaces the frame: Y % Cb % Cr %", y, cb, cr);
		video.pixbuf_release(out);
	}
	yuv.nv12_release(f);

	// The cost of a 720p frame, blurred.
	video.background_set(.Blur, "");
	hd := yuv.nv12_create(1280, 720);
	yuv.nv12_release(video.background_apply(hd));
	start := current_time_monotonic();
	for 1..30 yuv.nv12_release(video.background_apply(hd));
	print("1280x720 blurred: % ms a frame\n", formatFloat(to_float64_seconds(current_time_monotonic() - start) * 1000 / 30, trailing_width = 2));
	yuv.nv12_release(hd);

	args := get_command_line_arguments();
	if args.count > 1 {
		data, ok := read_entire_file(args[1]);
		img, err := imagefmt.decode_first_frame(cast([]u8) data);
		expect(ok && err == .None, "photo % decodes", args[1]);
		if ok && err == .None {
			w, h := img.width & ~3, img.height & ~1;
			p := to_nv12(img.frames[0].pixels, img.width, w, h);
			for mode: video.Background.[.Blur, .Image] {
				video.background_set(mode, "build/video_background_red.png");
				o := cast(*yuv.Nv12) video.background_apply(p);
				expect(o != null, "photo %", mode);
				if o {
					name := tprint("build/video_background_%.png", ifx mode == .Blur then "blur" else "picture");
					write_entire_file(name, cast(string) gfx.encode_png(to_rgba(o), w, h));
					print("wrote %\n", name);
					video.pixbuf_release(o);
				}
			}
		}
	}
	if failures exit(1);
	print("video_background: ok\n");
}

solid :: (r: u8, g: u8, b: u8, w: int, h: int) -> []u8 {
	px := NewArray(w * h * 4, u8);
	for 0..w * h - 1 { px[it * 4] = r; px[it * 4 + 1] = g; px[it * 4 + 2] = b; px[it * 4 + 3] = 255; }
	return px;
}

// RGBA (stride iw) to limited-range BT.601 NV12 of w x h.
to_nv12 :: (rgba: []u8, iw: int, w: int, h: int) -> *yuv.Nv12 {
	f := yuv.nv12_create(w, h);
	for y: 0..h - 1 for x: 0..w - 1 {
		p := rgba.data + (y * iw + x) * 4;
		r, g, b := cast(float) p[0], cast(float) p[1], cast(float) p[2];
		l := 0.299 * r + 0.587 * g + 0.114 * b;
		f.data[y * w + x] = xx (l * 219 / 255 + 16.5);
		if (x | y) & 1 continue;
		f.data[w * h + y / 2 * w + x] = xx clamp((b - l) / 1.772 * 224 / 255 + 128.5, 0, 255);
		f.data[w * h + y / 2 * w + x + 1] = xx clamp((r - l) / 1.402 * 224 / 255 + 128.5, 0, 255);
	}
	return f;
}

to_rgba :: (f: *yuv.Nv12) -> []u8 {
	w, h := f.width, f.height;
	px := NewArray(w * h * 4, u8);
	for y: 0..h - 1 for x: 0..w - 1 {
		l := (cast(float) f.data[y * w + x] - 16) * 255 / 219;
		uv := w * h + y / 2 * w + x / 2 * 2;
		u, v := (cast(float) f.data[uv] - 128) * 255 / 224, (cast(float) f.data[uv + 1] - 128) * 255 / 224;
		o := px.data + (y * w + x) * 4;
		o[0] = xx clamp(l + 1.402 * v, 0, 255);
		o[1] = xx clamp(l - 0.344136 * u - 0.714136 * v, 0, 255);
		o[2] = xx clamp(l + 1.772 * u, 0, 255);
		o[3] = 255;
	}
	return px;
}
