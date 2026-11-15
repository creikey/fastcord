/// Call transcription: each speaker's audio in, timestamped lines out, run through a local model on one worker thread.
#import "Basic";
#import "Math";
#import "String";
#import "Thread";
#import "Atomics";
#import "File";
#import "File_Utilities";
locks :: #import "locks";

// Speakers are cut into utterances by silence (a quiet stretch, or no frames at all: a Discord client stops
// sending when its VAD closes), and the model runs once per utterance. Utterances shorter than MIN_VOICED_MS
// of speech are dropped, since Whisper invents text for clicks and breaths.
SPEECH_DB :: -48.0;
CUT_QUIET_MS :: 700;
GAP_MS :: 400;
MAX_UTTERANCE_MS :: 28_000;  // Whisper's window is 30 s
MIN_VOICED_MS :: 300;
MAX_SPEAKERS :: 64;
MAX_BACKLOG_MS :: 10 * 60 * 1000;  // queued audio past this is dropped and reported, not kept

RATE :: 16000;
FRAME_MS :: 20;

Model_Kind :: enum s32 { Whisper :: 0; Parakeet :: 1; }

Model :: struct {
    id: string;     // settings value
    name: string;
    file: string;
    url: string;
    sha256: string;
    size: s64;
    kind: Model_Kind;
    english_only: bool;
}

State :: enum u8 { Off; Loading; Ready; Failed; }

Line :: struct {
    user_id: u64;
    start_ms, end_ms: s64;    // epoch ms
    text: string;             // heap
    not_recordable: bool;     // they spoke with voice recording off: nothing was transcribed
    dropped_ms: s64;          // audio skipped because transcription fell behind
}

// supported: the model runs on this CPU (x86-64 needs AVX2, FMA and F16C).
supported :: () -> bool { return fc_stt_cpu_ok() != 0; }

// configure: the model file and who is transcribed; takes effect at the next utterance. wake is called, on
// any thread, when new lines are ready to take (UI thread).
// Everything S holds is on the heap whatever the caller's allocator: the worker frees it on its own thread.
configure :: (model_path: string, kind: Model_Kind, english_only: bool, everyone: bool, threads := 4, wake: () = null) {
    push_allocator(context.default_allocator);
    locks.guard(*S.mu);
    if S.want_path != model_path {
        free(S.want_path);
        S.want_path = copy_string(model_path);
    }
    S.want_kind = kind;
    S.english_only = english_only;
    S.everyone = everyone;
    S.threads = threads;
    S.wake = wake;
    locks.cond_signal(*S.cond);
}

configure_everyone :: (everyone: bool) {
    locks.guard(*S.mu);
    S.everyone = everyone;
}

// set_active: transcribe from now on, or stop taking audio (queued audio is still transcribed). The model
// loads on the worker when first needed and is freed once inactive with nothing queued (UI thread).
set_active :: (on: bool) {
    push_allocator(context.default_allocator);
    locks.guard(*S.mu);
    if S.active == on return;
    atomic_store(*S.active, on);
    if !on for * S.speakers flush(it);
    if on for * S.speakers it.told_not_recordable = false;
    if on && !S.thread {
        S.thread = New(Thread);
        thread_init(S.thread, worker);
        thread_start(S.thread);
    }
    locks.cond_signal(*S.cond);
}

status :: () -> State, backlog_ms: s64 {
    locks.guard(*S.mu);
    return S.state, S.queued_ms;
}

// feed: one frame of a speaker's audio (48 kHz, interleaved channels), on the voice thread. Only copies.
feed :: (user_id: u64, pcm: []float32, channels: int, recordable: bool) {
    if channels < 1 || channels > 2 || !atomic_load(*S.active) return;
    push_allocator(context.default_allocator);
    now := now_ms();
    locks.guard(*S.mu);
    if !S.active return;
    sp := speaker(user_id, now);
    if !sp return;
    if !recordable && !S.everyone {
        if !sp.told_not_recordable && frame_db(pcm) > SPEECH_DB {
            sp.told_not_recordable = true;
            array_add(*S.lines, .{user_id = user_id, start_ms = now, end_ms = now, not_recordable = true});
            if S.wake S.wake();
        }
        return;
    }
    if sp.buf.count && now - sp.last_ms > GAP_MS flush(sp);
    segment_push(sp, pcm, channels, now);
    if sp.cut flush(sp);
}

// take: lines finished since the last call, moved into out (UI thread). Free each text.
take :: (out: *[..]Line) {
    locks.guard(*S.mu);
    for S.lines array_add(out, it);
    S.lines.count = 0;
}

// append_file: text appended to path in order with the other writes, on the worker (UI thread).
append_file :: (path: string, text: string) {
    push_allocator(context.default_allocator);
    locks.guard(*S.mu);
    array_add(*S.writes, .{copy_string(path), copy_string(text)});
    locks.cond_signal(*S.cond);
}

// clean_text: the model's text as valid UTF-8 with control characters and runs of spaces dropped, trimmed;
// "" when it is only a non-speech tag like "[BLANK_AUDIO]" or "(music)".
clean_text :: (s: string, allocator := temp) -> string {
    b: String_Builder;
    b.allocator = allocator;
    i := 0;
    space := true;
    while i < s.count {
        c := s[i];
        n := utf8_len(s, i);
        if n == 0 { append(*b, "\xEF\xBF\xBD"); i += 1; space = false; continue; }
        if n == 1 {
            if c < 0x20 || c == 0x7F || c == #char " " {
                if !space { append(*b, #char " "); space = true; }
            } else { append(*b, c); space = false; }
        } else { append(*b, slice(s, i, n)); space = false; }
        i += n;
    }
    out := trim_right(builder_to_string(*b,, allocator), " ");
    if out.count >= 2 && ((out[0] == #char "[" && out[out.count - 1] == #char "]") || (out[0] == #char "(" && out[out.count - 1] == #char ")"))
        && !contains(slice(out, 1, out.count - 2), "]") && !contains(slice(out, 1, out.count - 2), ")") return "";
    return out;
}

// ---------------------------------------------------------------------------
#scope_module

Speaker :: struct {
    user_id: u64;
    hist: [FIR_TAPS]float32;  // the last 48 kHz mono samples, a ring at pos
    pos: int;
    phase: int;
    buf: [..]float32;         // this utterance at 16 kHz
    start_ms, last_ms: s64;
    voiced_ms, quiet_ms: s64;
    cut: bool;
    told_not_recordable: bool;
}

Utterance :: struct {
    user_id: u64;
    start_ms, end_ms: s64;
    pcm: []float32;  // heap
}

Write :: struct { path, text: string; }

Shared :: struct {
    mu: locks.Mutex;
    cond: locks.Cond;
    thread: *Thread;
    active: bool;
    everyone: bool;
    want_path: string;
    want_kind: Model_Kind;
    english_only: bool;
    threads := 4;
    wake: ();
    state: State;
    speakers: [..]Speaker;
    queue: [..]Utterance;
    queued_ms: s64;
    dropped_ms: s64;
    lines: [..]Line;
    writes: [..]Write;
}
S: Shared;

now_ms :: () -> s64 { return to_milliseconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970); }

speaker :: (user_id: u64, now: s64) -> *Speaker {
    for * S.speakers if it.user_id == user_id return it;
    if S.speakers.count >= MAX_SPEAKERS {
        // the one heard least recently, with nothing pending, makes room
        best := -1;
        for S.speakers if !it.buf.count && (best < 0 || it.last_ms < S.speakers[best].last_ms) best = it_index;
        if best < 0 return null;
        array_free(S.speakers[best].buf);
        array_unordered_remove_by_index(*S.speakers, best);
    }
    sp := array_add(*S.speakers);
    sp.user_id = user_id;
    sp.last_ms = now;
    return sp;
}

frame_db :: (pcm: []float32) -> float32 {
    if !pcm.count return -127;
    acc: float64;
    for pcm acc += cast(float64) it * it;
    return cast(float32) (10 * log(acc / pcm.count + 0.000000000001) / log(10.0));
}

// FIR_TAPS-tap windowed-sinc low-pass at 7 kHz for 48 kHz, so decimating by 3 to 16 kHz doesn't alias.
FIR_TAPS :: 48;
FIR :: #run fir_taps();
fir_taps :: () -> [FIR_TAPS]float32 {
    t: [FIR_TAPS]float32;
    sum: float64;
    fc := 7000.0 / 48000.0;
    for i: 0..FIR_TAPS-1 {
        x := cast(float64) i - (FIR_TAPS - 1) / 2.0;
        sinc := ifx x == 0 then 2 * fc else sin(2 * PI64 * fc * x) / (PI64 * x);
        w := 0.42 - 0.5 * cos(2 * PI64 * i / (FIR_TAPS - 1)) + 0.08 * cos(4 * PI64 * i / (FIR_TAPS - 1));  // Blackman
        t[i] = cast(float32) (sinc * w);
        sum += sinc * w;
    }
    for * t it.* = cast(float32) (it.* / sum);
    return t;
}

// segment_push: one frame into the speaker's utterance, setting cut when it should end here.
segment_push :: (sp: *Speaker, pcm: []float32, channels: int, now: s64) {
    if !sp.buf.count sp.start_ms = now - FRAME_MS;
    sp.last_ms = now;
    frames := pcm.count / channels;
    for f: 0..frames-1 {
        x := pcm[f * channels];
        if channels == 2 x = (x + pcm[f * 2 + 1]) * 0.5;
        sp.hist[sp.pos] = x;
        sp.pos = (sp.pos + 1) % FIR_TAPS;
        sp.phase += 1;
        if sp.phase < 3 continue;
        sp.phase = 0;
        acc: float32;
        for k: 0..FIR_TAPS-1 acc += FIR[k] * sp.hist[(sp.pos + k) % FIR_TAPS];
        array_add(*sp.buf, acc);
    }
    ms := cast(s64) frames * 1000 / 48000;
    if frame_db(pcm) > SPEECH_DB { sp.voiced_ms += ms; sp.quiet_ms = 0; }
    else sp.quiet_ms += ms;
    if (sp.voiced_ms && sp.quiet_ms >= CUT_QUIET_MS) || sp.buf.count >= MAX_UTTERANCE_MS * RATE / 1000 sp.cut = true;
    if !sp.voiced_ms && sp.quiet_ms >= CUT_QUIET_MS { sp.buf.count = 0; sp.quiet_ms = 0; }  // silence alone: nothing to keep
}

// flush: the speaker's utterance onto the queue if it holds speech (under S.mu).
flush :: (sp: *Speaker) {
    defer { sp.buf.count = 0; sp.voiced_ms = 0; sp.quiet_ms = 0; sp.cut = false; }
    if sp.voiced_ms < MIN_VOICED_MS || !sp.buf.count return;
    keep := sp.buf.count - (min(sp.quiet_ms, CUT_QUIET_MS) - 200) * RATE / 1000;  // trailing quiet, less 200 ms
    keep = clamp(keep, 1, sp.buf.count);
    ms := cast(s64) keep * 1000 / RATE;
    if S.queued_ms + ms > MAX_BACKLOG_MS { S.dropped_ms += ms; return; }
    u := array_add(*S.queue);
    u.* = .{user_id = sp.user_id, start_ms = sp.start_ms, end_ms = sp.start_ms + ms, pcm = array_copy(array_view(sp.buf, 0, keep))};
    S.queued_ms += ms;
    locks.cond_signal(*S.cond);
}

utf8_len :: (s: string, i: int) -> int {
    c := s[i];
    n := 0;
    lo, hi: u8 = 0x80, 0xBF;
    if c < 0x80 return 1;
    else if c >= 0xC2 && c <= 0xDF n = 2;
    else if c >= 0xE0 && c <= 0xEF { n = 3; if c == 0xE0 lo = 0xA0; if c == 0xED hi = 0x9F; }
    else if c >= 0xF0 && c <= 0xF4 { n = 4; if c == 0xF0 lo = 0x90; if c == 0xF4 hi = 0x8F; }
    else return 0;
    if i + n > s.count return 0;
    for k: 1..n-1 {
        b := s[i + k];
        if k == 1 { if b < lo || b > hi return 0; }
        else if b < 0x80 || b > 0xBF return 0;
    }
    return n;
}

worker :: (th: *Thread) -> s64 {
    ctx: *void;
    loaded_path: string;
    loaded_kind: Model_Kind;
    out: [..]u8;
    array_resize(*out, 64 * 1024);
    while true {
        reset_temporary_storage();
        locks.lock(*S.mu);
        now := now_ms();
        for * S.speakers if it.buf.count && now - it.last_ms > GAP_MS flush(it);
        if S.dropped_ms {
            array_add(*S.lines, .{start_ms = now, end_ms = now, dropped_ms = S.dropped_ms});
            S.dropped_ms = 0;
            if S.wake S.wake();
        }
        writes := S.writes;
        S.writes = ([..]Write).{};
        has_job := S.queue.count > 0;
        job: Utterance;
        if has_job { job = S.queue[0]; array_ordered_remove_by_index(*S.queue, 0); }
        want_path, want_kind, threads := copy_string(S.want_path,, temp), S.want_kind, S.threads;
        lang := ifx S.english_only then "en" else "auto";
        idle := !has_job && !writes.count;
        if idle && !S.active && ctx {
            fc_stt_free(ctx, loaded_kind);
            ctx = null;
            free(loaded_path);
            loaded_path = "";
            S.state = .Off;
        }
        if idle locks.cond_wait_with_timeout(*S.cond, *S.mu, 100);
        locks.unlock(*S.mu);

        for writes {
            f, ok := file_open(it.path, for_writing = true, keep_existing_content = true, log_errors = false);
            if !ok {
                make_directory_if_it_does_not_exist(path_strip_filename(it.path), recursive = true);
                f, ok = file_open(it.path, for_writing = true, keep_existing_content = true, log_errors = false);
            }
            if ok { file_seek(f, 0, .END); file_write(*f, it.text); file_close(*f); }
            else log_error("cannot write the transcript %", it.path);
            free(it.path);
            free(it.text);
        }
        array_free(writes);
        if !has_job continue;

        if ctx && (loaded_path != want_path || loaded_kind != want_kind) {
            fc_stt_free(ctx, loaded_kind);
            ctx = null;
        }
        if !ctx && want_path {
            set_state(.Loading);
            if supported() ctx = fc_stt_load(temp_c_string(want_path), want_kind);
            free(loaded_path);
            loaded_path, loaded_kind = copy_string(want_path), want_kind;
            set_state(ifx ctx then State.Ready else .Failed);
        }
        text := "";
        if ctx {
            n := fc_stt_run(ctx, loaded_kind, job.pcm.data, xx job.pcm.count, xx threads, temp_c_string(lang), out.data, xx out.count);
            if n > 0 text = clean_text(to_string(out.data, min(cast(s64) n, out.count)));
        }
        locks.lock(*S.mu);
        S.queued_ms -= job.end_ms - job.start_ms;
        if text array_add(*S.lines, .{user_id = job.user_id, start_ms = job.start_ms, end_ms = job.end_ms, text = copy_string(text)});
        if text && S.wake S.wake();
        locks.unlock(*S.mu);
        array_free(job.pcm);
    }
    return 0;
}

set_state :: (s: State) {
    locks.guard(*S.mu);
    S.state = s;
}

lib :: #library,no_dll "../../build/fc_vendor";
fc_stt_cpu_ok :: () -> s32 #foreign lib;
fc_stt_load :: (path: *u8, kind: Model_Kind) -> *void #foreign lib;
fc_stt_run :: (ctx: *void, kind: Model_Kind, pcm: *float32, n: s32, threads: s32, lang: *u8, out: *u8, cap: s32) -> s32 #foreign lib;
fc_stt_free :: (ctx: *void, kind: Model_Kind) #foreign lib;
