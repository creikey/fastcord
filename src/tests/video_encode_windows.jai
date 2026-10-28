// Round-trips synthetic NV12 frames through video's encoder and media's decoder (Media Foundation).
// jai build.jai - run src/tests/video_encode_windows.jai && build/video_encode_windows
#import "Basic";
video :: #import "video";
media :: #import "media";
voice :: #import "voice";
mf :: #import "mf";

W :: 640;
H :: 360;
FRAMES :: 60;

Packet :: struct { data: []u8; keyframe: bool; pts: u32; }
packets: [..]Packet;

failures := 0;
expect :: (ok: bool, what: string, args: ..Any) {
	if ok return;
	failures += 1;
	print("FAIL: %\n", tprint(what, ..args));
}

on_output :: (user: *void, annexb: []u8, keyframe: bool, pts_90k: u32) {
	array_add(*packets, .{array_copy(annexb), keyframe, pts_90k});
}

make_frame :: (t: int) -> *mf.Nv12 {
	f := mf.nv12_create(W, H);
	for y: 0..H - 1 for x: 0..W - 1 f.data[y * W + x] = cast,trunc(u8) (16 + (x + y + t * 4) % 220);
	for i: W * H..f.data.count - 1 f.data[i] = cast,trunc(u8) (128 + (i / 2 + t) % 32);
	return f;
}

main :: () {
	expect(video.encoder_supported(.H264), "H.264 encoder");
	e := video.encoder_create(.H264, W, H, 30, 1_000_000, on_output, null);
	expect(e != null, "encoder_create");
	if !e exit(1);
	for t: 0..FRAMES - 1 {
		f := make_frame(t);
		video.encoder_encode(e, f, cast(u32) (t * 3000), force_keyframe = t == 30);
		mf.nv12_release(f);
	}
	video.encoder_destroy(e);

	print("% packets, keyframes at:", packets.count);
	for packets if it.keyframe print(" %", it.pts / 3000);
	print("\n");
	expect(packets.count >= FRAMES - 2 && packets.count <= FRAMES, "output count % (want ~%)", packets.count, FRAMES);
	if !packets.count exit(1);
	expect(packets[0].keyframe, "first output is a keyframe");
	forced := false;
	for packets if it.pts == 30 * 3000 forced = it.keyframe;
	expect(forced, "forced keyframe at frame 30");

	// Decode as the call view does: parameter sets out of band, the rest as AVCC.
	dec: *media.Video_Decoder;
	decoded, bad_size := 0, 0;
	for pk: packets {
		expect(pk.data.count > 4 && pk.data[0] == 0 && pk.data[1] == 0 && pk.data[2] == 0 && pk.data[3] == 1, "packet % starts with a 4-byte start code", it_index);
		params: [..][]u8;
		avcc: [..]u8;
		for voice.annexb_nals(pk.data) {
			nal := array_view(pk.data, it.start, it.end - it.start);
			t := nal[0] & 0x1f;
			if t == 7 || t == 8 { array_add(*params, nal); continue; }
			if t == 9 continue;
			n: [4]u8;
			voice.put_u32(n, cast(u32) nal.count);
			array_add(*avcc, ..n);
			array_add(*avcc, ..nal);
		}
		if pk.keyframe expect(params.count == 2, "keyframe % carries SPS and PPS (% params)", pk.pts / 3000, params.count);
		if !dec && params.count {
			ok: bool;
			dec, ok = media.video_decoder_create_from_params(.H264, params);
			expect(ok, "decoder from parameter sets");
		}
		if !dec continue;
		expect(media.video_decode(dec, avcc, 0, 0, 0), "decode packet %", it_index);
		frames: [..]media.Video_Frame;
		media.video_decoder_take(dec, *frames);
		for * frames {
			// Output order is input order (no B-frames), so frame `decoded` is source frame `decoded`.
			if it.width != W || it.height != H { bad_size += 1; }
			else {
				got := cast(*mf.Nv12) it.pixbuf;
				src := make_frame(decoded);
				diff := 0;
				for i: 0..got.data.count - 1 diff += max(got.data[i], src.data[i]) - min(got.data[i], src.data[i]);
				mf.nv12_release(src);
				expect(diff / got.data.count < 4, "frame % differs from its source by % per byte", decoded, diff / got.data.count);
			}
			decoded += 1;
			media.video_frame_release(it);
		}
	}
	print("decoded %\n", decoded);
	expect(decoded >= packets.count - 2, "decoded % of % (low latency: about one out per one in)", decoded, packets.count);
	expect(bad_size == 0, "% frames at the wrong size", bad_size);
	media.video_decoder_destroy(dec);
	print(ifx failures then "FAILED\n" else "ok\n");
	exit(xx ifx failures then 1 else 0);
}
