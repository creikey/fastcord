// The call view's video paths without a network: an Annex B file (one access unit per AUD, as a remote
// camera arrives) through media's decoder as on_remote_frame feeds it, and the real camera into the encoder.
// jai build.jai - run src/tests/video_call.jai && build/video_call [file.h264|file.h265 ...] [camera]
#import "Basic";
#import "File";
#import "String";
#import "Thread";
#import "Atomics";
video :: #import "video";
media :: #import "media";
voice :: #import "voice";
yuv :: #import "yuv";

failures := 0;
expect :: (ok: bool, what: string, args: ..Any) {
	if ok return;
	failures += 1;
	print("FAIL: %\n", tprint(what, ..args));
}

main :: () {
	args := get_command_line_arguments();
	for a: array_view(args, 1, args.count - 1) {
		if a == "camera" camera();
		else decode_file(a);
	}
	print(ifx failures then "FAILED\n" else "ok\n");
	exit(xx ifx failures then 1 else 0);
}

decode_file :: (path: string) {
	data, ok := read_entire_file(path);
	expect(ok, "read %", path);
	if !ok return;
	codec := ifx ends_with(path, ".h265") then voice.Video_Codec.H265 else .H264;
	h265 := codec == .H265;
	bytes := cast([]u8) data;
	// Access units: split before each AUD.
	aus: [..][]u8;
	start := 0;
	for voice.annexb_nals(bytes) {
		t := voice.nal_type(codec, bytes[it.start]);
		if (h265 && t == 35) || (!h265 && t == 9) {
			s := it.start - 3;
			if s > 0 && bytes[s - 1] == 0 s -= 1;
			if s > start array_add(*aus, array_view(bytes, start, s - start));
			start = s;
		}
	}
	array_add(*aus, array_view(bytes, start, bytes.count - start));

	dec: *media.Video_Decoder;
	decoded, w, h := 0, 0, 0;
	for au: aus {
		params: [..][]u8;
		avcc: [..]u8;
		key := false;
		for voice.annexb_nals(au) {
			nal := array_view(au, it.start, it.end - it.start);
			if !nal.count continue;
			t := voice.nal_type(codec, nal[0]);
			if ifx h265 then t >= 32 && t <= 34 else t == 7 || t == 8 { if params.count < 3 array_add(*params, nal); key = true; continue; }
			if (h265 && t == 35) || (!h265 && t == 9) continue;
			n: [4]u8;
			voice.put_u32(n, cast(u32) nal.count);
			array_add(*avcc, ..n);
			array_add(*avcc, ..nal);
		}
		if key && !dec {
			dec = media.video_decoder_create_from_params(ifx h265 then media.Codec.HEVC else .H264, params);
			expect(dec != null, "% decoder from parameter sets", path);
			if !dec return;
		}
		if !dec continue;
		expect(media.video_decode(dec, avcc, 0, 0, 0), "% decode AU %", path, it_index);
		frames: [..]media.Video_Frame;
		media.video_decoder_take(dec, *frames);
		for * frames {
			w, h = it.width, it.height;
			decoded += 1;
			// the call view's next step: the frame's planes become textures
			n := cast(*yuv.Nv12) it.pixbuf;
			expect(n.data.count == n.width * n.height * 3 / 2, "% frame size", path);
			if decoded == 45 write_entire_file(tprint("%.%x%.nv12", path, n.width, n.height), n.data.data, n.data.count); // to look at
			media.video_frame_release(it);
		}
	}
	media.video_decoder_destroy(dec);
	print("%: % access units, % decoded at %x%\n", path, aus.count, decoded, w, h);
	expect(decoded >= aus.count - 2, "% decoded % of %", path, decoded, aus.count);
}

Cam :: struct {
	frames: s32;
	w, h: int;
	enc: *video.Encoder;
	packets: s32;
	encode_ms: float64;
	start: Apollo_Time;
}

camera :: () {
	c: Cam;
	c.start = current_time_monotonic();
	cap := video.camera_start((user: *void, pixbuf: *void, width: int, height: int) {
		c := cast(*Cam) user;
		if !c.enc {
			c.w, c.h = width, height;
			c.enc = video.encoder_create(.H264, width & ~1, height & ~1, 30, 2_500_000, (user: *void, annexb: []u8, keyframe: bool, pts_90k: u32) {
				atomic_add(*(cast(*Cam) user).packets, 1);
			}, user);
		}
		t := current_time_monotonic();
		if c.enc video.encoder_encode(c.enc, pixbuf, cast(u32) (c.frames * 3000));
		c.encode_ms += to_float64_seconds(current_time_monotonic() - t) * 1000;
		if c.frames == 45 { f := cast(*yuv.Nv12) pixbuf; write_entire_file(tprint("build/camera.%x%.nv12", f.width, f.height), f.data.data, f.data.count); } // to look at
		atomic_add(*c.frames, 1);
	}, *c);
	expect(cap != null, "camera_start");
	for 1..50 { sleep_milliseconds(100); if atomic_load(*c.frames) >= 60 break; }
	video.capture_stop(cap);
	sleep_milliseconds(200);
	secs := to_float64_seconds(current_time_monotonic() - c.start);
	print("camera: % frames at %x% (% fps, opening included), % encoded packets, % ms per encode, camera_supported=%\n",
		c.frames, c.w, c.h, formatFloat(c.frames / secs, trailing_width = 1), c.packets, formatFloat(c.encode_ms / max(c.frames, 1), trailing_width = 1), video.camera_supported());
	expect(c.frames >= 30, "camera delivered % frames", c.frames);
	expect(c.packets >= c.frames - 3, "encoded % of % camera frames", c.packets, c.frames);
	video.encoder_destroy(c.enc);
}
