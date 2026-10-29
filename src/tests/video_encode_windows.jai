// Windows' encoders on synthetic NV12 frames: H.264 (the GPU's asynchronous MFT when there is one, else the
// software one) and H.265 (GPU only, when there is one). Every frame comes out, the first and a forced one
// as keyframes with their parameter sets.
// jai build.jai - run src/tests/video_encode_windows.jai && build\video_encode_windows
#import "Basic";
video :: #import "video";
yuv :: #import "yuv";

W :: 640;
H :: 360;
FRAMES :: 60;

Packet :: struct { keyframe: bool; pts: u32; params: bool; }
packets: [..]Packet;
hevc: bool;

main :: () {
    failures := 0;
    expect :: (ok: bool, what: string, args: ..Any) #expand {
        if !ok { `failures += 1; print("FAIL: %\n", tprint(what, ..args)); }
    }
    for codec: video.Video_Codec.[.H264, .H265] {
        if codec == .H265 && !video.encoder_supported(.H265) { print("no H.265 encoder\n"); continue; }
        hevc = codec == .H265;
        packets.count = 0;
        e := video.encoder_create(codec, W, H, 30, 1_000_000, (user: *void, annexb: []u8, keyframe: bool, pts_90k: u32) {
            params := false;
            for i: 0..annexb.count - 5 if annexb[i] == 0 && annexb[i + 1] == 0 && annexb[i + 2] == 1 {
                b := annexb[i + 3];
                if (hevc && ((b >> 1) & 0x3f) == 32) || (!hevc && (b & 0x1f) == 7) params = true;
            }
            array_add(*packets, .{keyframe, pts_90k, params});
        }, null);
        expect(e != null, "% encoder_create", codec);
        if !e continue;
        for t: 0..FRAMES - 1 {
            f := yuv.nv12_create(W, H);
            for y: 0..H - 1 for x: 0..W - 1 f.data[y * W + x] = cast,trunc(u8) (16 + (x + y + t * 4) % 220);
            for i: W * H..f.data.count - 1 f.data[i] = cast,trunc(u8) (128 + (i / 2 + t) % 32);
            video.encoder_encode(e, f, cast(u32) (t * 3000), force_keyframe = t == 30);
            yuv.nv12_release(f);
            sleep_milliseconds(33); // camera pacing: a hardware encoder answers between frames
        }
        video.encoder_destroy(e);
        print("%: % packets, keyframes at:", codec, packets.count);
        for packets if it.keyframe print(" %", it.pts / 3000);
        print("\n");
        expect(packets.count >= FRAMES - 4, "% output count % (want ~%)", codec, packets.count, FRAMES);
        expect(packets.count > 0 && packets[0].keyframe && packets[0].params, "% first output is a keyframe with its parameter sets", codec);
        forced := false;
        for packets if it.keyframe && it.pts >= 30 * 3000 && it.pts <= 32 * 3000 forced = it.params;
        expect(forced, "% a keyframe with parameter sets at the forced frame", codec);
    }
    print(ifx failures then "FAIL\n" else "PASS\n");
    exit(xx ifx failures then 1 else 0);
}
