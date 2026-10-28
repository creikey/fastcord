// The echo canceller on a synthetic room: the far end (noise bursts) comes back into the mic 50 ms late
// at half level, and a near-end tone talks over it half the time. Checks the echo drops by 20 dB and the
// near-end speech survives double talk (VoiceProcessingIO's canceller zeroed it).
// jai build.jai - run src/tests/voice_aec.jai && build/voice_aec
#import "Basic";
#import "Math";

FRAME :: 480;
SECONDS :: 12;
DELAY :: 2400;  // 50 ms

main :: () {
    aec := fc_aec_create();
    defer fc_aec_destroy(aec);
    n := SECONDS * 48000;
    far := NewArray(n, float32);
    near := NewArray(n, float32);
    seed: u32 = 1;
    for 0..n-1 {
        seed = seed * 1664525 + 1013904223;
        on := (it / 24000) % 3 != 2;  // far end speaks 1 s on, 0.5 s off
        far[it] = ifx on then (cast(float32) (seed >> 8) / (1 << 24) - .5) * .5 else 0;
        // the near end speaks every other second in the last half
        if it > n / 2 && (it / 48000) % 2 == 1 near[it] = .1 * sin(TAU * 300 * it / 48000.0);
    }
    echo_in, echo_out, near_in, near_out: float64;
    frame: [FRAME]float32;
    for f: 0..n / FRAME - 1 {
        for 0..FRAME-1 {
            i := f * FRAME + it;
            frame[it] = near[i] + ifx i >= DELAY then .5 * far[i - DELAY] else 0;
        }
        fc_aec_render(aec, far.data + f * FRAME);
        in := frame;
        fc_aec_capture(aec, frame.data);
        if f * FRAME < 4 * 48000 continue;  // converging
        talking := near[f * FRAME + FRAME / 2] != 0 || near[f * FRAME + FRAME / 2 + 1] != 0;
        for 0..FRAME-1 {
            if talking { near_in += near[f * FRAME + it] * near[f * FRAME + it]; near_out += frame[it] * frame[it]; }
            else { echo_in += in[it] * in[it]; echo_out += frame[it] * frame[it]; }
        }
    }
    erle := 10 * log(echo_in / max(echo_out, 0.000000000001)) / log(10.0);
    kept := 10 * log(near_out / max(near_in, 0.000000000001)) / log(10.0);
    print("echo reduced by % dB; near end during double talk at % dB\n", formatFloat(erle, trailing_width = 1), formatFloat(kept, trailing_width = 1));
    ok := erle > 20 && kept > -6;
    print(ifx ok then "voice aec ok\n" else "voice aec FAILED\n");
    exit(xx ifx ok then 0 else 1);
}

vendor :: #library,no_dll "../../build/fc_vendor";
fc_aec_create :: () -> *void #foreign vendor;
fc_aec_destroy :: (a: *void) #foreign vendor;
fc_aec_render :: (a: *void, pcm: *float32) #foreign vendor;
fc_aec_capture :: (a: *void, pcm: *float32) #foreign vendor;
