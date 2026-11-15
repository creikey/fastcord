// fastcord's wrapper over whisper.cpp and its Parakeet runner: a CPU check, load, one utterance to text, free.
// The library itself is built from fc_whisper.sources; src/stt binds this.
#include "include/whisper.h"
#include "include/parakeet.h"
#include <string.h>

static void quiet(enum ggml_log_level level, const char *text, void *data) { (void)level; (void)text; (void)data; }

#if defined(__x86_64__) || defined(_M_X64)
#ifdef _MSC_VER
#include <intrin.h>
static void cpuid(int leaf, unsigned r[4]) { __cpuidex((int *)r, leaf, 0); }
static unsigned xcr0(void) { return (unsigned)_xgetbv(0); }
#else
#include <cpuid.h>
static void cpuid(int leaf, unsigned r[4]) { __cpuid_count(leaf, 0, r[0], r[1], r[2], r[3]); }
static unsigned xcr0(void) { unsigned lo, hi; __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0)); return lo; }
#endif
// The ggml CPU files are built for x86-64-v3 (AVX2, FMA, F16C, BMI2), so nothing may call them on an older
// CPU, nor on an OS that doesn't save the YMM registers (XCR0 bits 1 and 2).
int fc_stt_cpu_ok(void) {
    unsigned r[4];
    cpuid(0, r);
    if (r[0] < 7) return 0;
    cpuid(1, r);
    unsigned c = r[2];
    int fma = (c >> 12) & 1, osxsave = (c >> 27) & 1, avx = (c >> 28) & 1, f16c = (c >> 29) & 1;
    if (!fma || !osxsave || !avx || !f16c) return 0;
    if ((xcr0() & 6) != 6) return 0;
    cpuid(7, r);
    return ((r[1] >> 5) & 1) && ((r[1] >> 8) & 1);  // AVX2, BMI2
}
#else
int fc_stt_cpu_ok(void) { return 1; }
#endif

void *fc_stt_load(const char *path, int kind) {
    whisper_log_set(quiet, 0);
    parakeet_log_set(quiet, 0);
    if (kind == 1) {
        struct parakeet_context_params p = parakeet_context_default_params();
        p.use_gpu = 0;
        return parakeet_init_from_file_with_params(path, p);
    }
    struct whisper_context_params p = whisper_context_default_params();
    p.use_gpu = 0;
    p.flash_attn = 1;
    return whisper_init_from_file_with_params(path, p);
}

static int append(char *out, int cap, int n, const char *s) {
    int k = (int)strlen(s);
    if (n + k > cap) k = cap - n;
    memcpy(out + n, s, k);
    return n + k;
}

// The utterance's text, segments joined, into out; its length, or -1.
int fc_stt_run(void *ctx, int kind, const float *pcm, int n, int threads, const char *lang, char *out, int cap) {
    int len = 0;
    if (kind == 1) {
        struct parakeet_full_params p = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY);
        p.n_threads = threads;
        p.no_context = 1;
        if (parakeet_full((struct parakeet_context *)ctx, p, pcm, n) != 0) return -1;
        int segs = parakeet_full_n_segments((struct parakeet_context *)ctx);
        for (int i = 0; i < segs; i++) len = append(out, cap, len, parakeet_full_get_segment_text((struct parakeet_context *)ctx, i));
        return len;
    }
    struct whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.n_threads = threads;
    p.no_context = 1;
    p.no_timestamps = 1;
    p.print_progress = 0;
    p.print_realtime = 0;
    p.print_timestamps = 0;
    p.print_special = 0;
    p.suppress_blank = 1;
    p.suppress_nst = 1;
    p.language = lang;
    if (whisper_full((struct whisper_context *)ctx, p, pcm, n) != 0) return -1;
    int segs = whisper_full_n_segments((struct whisper_context *)ctx);
    for (int i = 0; i < segs; i++) {
        // A segment the model itself thinks is no speech is dropped (its usual invented "Thank you.").
        if (whisper_full_get_segment_no_speech_prob((struct whisper_context *)ctx, i) > 0.6f) continue;
        len = append(out, cap, len, whisper_full_get_segment_text((struct whisper_context *)ctx, i));
    }
    return len;
}

void fc_stt_free(void *ctx, int kind) {
    if (kind == 1) parakeet_free((struct parakeet_context *)ctx);
    else whisper_free((struct whisper_context *)ctx);
}
