// Call transcription's pieces without a call: clean_text on the model's odd outputs, then a speaker's
// 48 kHz frames through feed (resampling, cutting at pauses, the backlog) into a real model, when one is
// on disk (FASTCORD_STT_MODEL, else build/stt_models/ggml-base.en-q5_1.bin), and the text that comes out.
// jai build.jai - run src/tests/stt.jai && build/stt
#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
stt :: #import "stt";
#if OS == .WINDOWS {
    msvcprt :: #library,system,no_dll,link_always "msvcprt";
    crt :: #system_library "msvcrt";
    getenv :: (name: *u8) -> *u8 #foreign crt;
} else {
    POSIX :: #import "POSIX";
    getenv :: POSIX.getenv;
}

main :: () {
    failed := 0;
    check :: (ok: bool, what: string, args: ..Any) #expand {
        if ok return;
        `failed += 1;
        print("FAIL: ");
        print(what, ..args);
        print("\n");
    }

    Case :: struct { in, out: string; }
    for Case.[
        .{" And so, my fellow Americans.", "And so, my fellow Americans."},
        .{"[BLANK_AUDIO]", ""},
        .{" (music) ", ""},
        .{"(laughs) yes", "(laughs) yes"},
        .{"[a] and [b]", "[a] and [b]"},
        .{"tab\there\nnew  line", "tab here new line"},
        .{"bad \xFF byte", "bad \xEF\xBF\xBD byte"},
        .{"cut \xE2\x82", "cut \xEF\xBF\xBD\xEF\xBF\xBD"},
        .{"\xED\xA0\x80", "\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD"},
        .{"caf\xC3\xA9 \xF0\x9F\x98\x80", "caf\xC3\xA9 \xF0\x9F\x98\x80"},
        .{"", ""},
    ] {
        got := stt.clean_text(it.in);
        check(got == it.out, "clean_text(\"%\") = \"%\", want \"%\"", it.in, got, it.out);
    }

    path := "build/stt_models/ggml-base.en-q5_1.bin";
    env := getenv("FASTCORD_STT_MODEL");
    if env path = to_string(env);
    if !stt.supported() print("skip: this CPU can't run the model\n");
    else if !file_exists(path) print("skip: no model at %\n", path);
    else {
        pcm, ok := read_wav16("tests/data/jfk.wav");
        check(ok, "tests/data/jfk.wav didn't read");
        kind := ifx contains(path, "parakeet") then stt.Model_Kind.Parakeet else .Whisper;
        stt.configure(path, kind, kind == .Whisper, false, 4);
        stt.set_active(true);
        // Our own voice (recordable) and someone with recording off, at 48 kHz in 20 ms stereo frames.
        frame: [960 * 2]float32;
        i := 0;
        while i < pcm.count {
            for f: 0..959 {
                x := ifx i + f / 3 < pcm.count then pcm[i + f / 3] else 0;
                frame[f * 2], frame[f * 2 + 1] = x, x;
            }
            stt.feed(1, frame, 2, true);
            stt.feed(2, frame, 2, false);
            i += 320;
        }
        stt.set_active(false);
        text: String_Builder;
        told := 0;
        start := current_time_monotonic();
        while to_float64_seconds(current_time_monotonic() - start) < 120 {
            lines: [..]stt.Line;
            stt.take(*lines);
            for lines {
                if it.not_recordable { check(it.user_id == 2, "a not-recordable note for %", it.user_id); told += 1; }
                else if it.text { check(it.user_id == 1, "user 2's speech was transcribed"); append(*text, it.text); append(*text, " "); }
            }
            st, backlog := stt.status();
            check(st != .Failed, "the model didn't load");
            if st == .Failed break;
            if backlog == 0 && st == .Off && builder_string_length(*text) break;
            sleep_milliseconds(100);
        }
        got := to_lower_copy(builder_to_string(*text));
        print("transcript: %\n", got);
        check(told == 1, "% not-recordable notes, want 1", told);
        for string.["my fellow americans", "ask not what your country can do for you", "what you can do for your country"]
            check(contains(got, it), "the transcript lacks \"%\"", it);
    }
    if failed { print("% failed\n", failed); exit(1); }
    print("ok\n");
}

// A 16-bit mono PCM WAV of the repo's own, as floats.
read_wav16 :: (path: string) -> []float32, bool {
    data, ok := read_entire_file(path);
    if !ok || data.count < 12 return .[], false;
    p := 12;
    while p + 8 <= data.count {
        size := cast(int) ((cast(u32) data[p + 4]) | ((cast(u32) data[p + 5]) << 8) | ((cast(u32) data[p + 6]) << 16) | ((cast(u32) data[p + 7]) << 24));
        if slice(data, p, 4) == "data" {
            n := min(size, data.count - p - 8) / 2;
            out := NewArray(n, float32);
            for 0..n-1 out[it] = cast,no_check(s16) ((cast(u16) data[p + 8 + 2 * it]) | ((cast(u16) data[p + 9 + 2 * it]) << 8)) / 32768.0;
            return out, true;
        }
        p += 8 + size + (size & 1);
    }
    return .[], false;
}
