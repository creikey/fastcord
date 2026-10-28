// fastcord's translation unit for RNNoise: noise suppression on the mic, 480-sample (10 ms) frames of
// mono 48 kHz f32 in [-1, 1], with the model built into the library. Bound in src/voice/rnnoise.jai.

#include "rnnoise.h"

void *fc_rnnoise_create(void) { return rnnoise_create(NULL); }

void fc_rnnoise_destroy(void *st) { rnnoise_destroy((DenoiseState *) st); }

// Denoises one frame in place. RNNoise works at 16-bit scale and delays its output by one frame.
// Returns the frame's voice probability (0..1).
float fc_rnnoise_process(void *st, float *pcm) {
    float x[480];
    for (int i = 0; i < 480; i++) x[i] = pcm[i] * 32768.0f;
    float vad = rnnoise_process_frame((DenoiseState *) st, x, x);
    for (int i = 0; i < 480; i++) pcm[i] = x[i] * (1.0f / 32768.0f);
    return vad;
}
