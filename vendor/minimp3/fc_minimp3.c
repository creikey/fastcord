// fastcord's translation unit for minimp3: MP3 frames to f32 PCM on Windows and Linux (macOS uses
// AudioToolbox). The caller owns the decoder state (fc_mp3_state_size bytes). Bound in src/media/decode_none.jai.

#define MINIMP3_IMPLEMENTATION
#define MINIMP3_FLOAT_OUTPUT
#include "minimp3.h"

int fc_mp3_state_size(void) { return (int) sizeof(mp3dec_t); }

void fc_mp3_init(void *state) { mp3dec_init((mp3dec_t *) state); }

// Decodes the first frame in data into pcm (room for MINIMP3_MAX_SAMPLES_PER_FRAME floats). Returns
// samples per channel (0: none yet, or skipped data) and sets *used to the bytes consumed.
int fc_mp3_decode(void *state, const unsigned char *data, int count, float *pcm, int *channels, int *hz, int *used) {
    mp3dec_frame_info_t info;
    int n = mp3dec_decode_frame((mp3dec_t *) state, data, count, pcm, &info);
    *channels = info.channels;
    *hz = info.hz;
    *used = info.frame_bytes;
    return n;
}
