// Offline reproduction: 20 ms voice writes and 10 ms device reads on independent clocks.
// jai build.jai - run src/tests/audio_playout.jai && build/audio_playout
#import "Basic";
audio :: #import "audio";

main :: () {
    audio.init_null();
    defer audio.shutdown();
    source := audio.source_create(prebuffer_frames = 1920);
    block: [960 * 2]float32;
    for * block it.* = 0.25;
    output: [480 * 2]float32;
    holes := 0;
    // No lost samples: one 20 ms tick out of four is delayed 12 ms, then catches up.
    for ms: 0..999 {
        if ms % 80 == 0 || ms % 80 == 20 || ms % 80 == 40 || ms % 80 == 72 audio.source_write(source, block);
        if ms % 10 == 0 {
            audio.mix(output);
            // Allow startup delay; all subsequent device periods must contain audio.
            if ms >= 40 for output if it == 0 holes += 1;
        }
    }
    print("silent samples during continuous voice: %\n", holes);
    if holes != 0 exit(1);

    // Drain the end of speech, then ensure a new spurt rebuilds the cushion.
    for 0..9 audio.mix(output);
    audio.source_write(source, block);
    audio.mix(output);
    for output if it != 0 exit(2);
    if audio.source_queued_frames(source) != 960 exit(3);
    audio.source_write(source, block);
    audio.mix(output);
    for output if it != 0.25 exit(4);
    if audio.source_queued_frames(source) != 1440 exit(5);

    // A flush also discards the old cushion, and reusing a slot resets the policy.
    audio.source_flush(source);
    audio.mix(output);
    for output if it != 0 exit(6);
    audio.source_write(source, block);
    audio.mix(output);
    for output if it != 0 exit(7);
    audio.source_destroy(source);
    media := audio.source_create();
    audio.source_write(media, block);
    audio.mix(output);
    for output if it != 0.25 exit(8);
    audio.source_destroy(media);
    print("PASS: scheduled jitter, spurt recovery, flush, immediate media, slot reuse\n");
}
