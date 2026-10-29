// fastcord's AAC decoder for Linux: FFmpeg's native AAC decoder (LGPL-2.1-or-later), linked by build.jai into
// its own libfc_aac.so, which src/media/decode_none.jai opens with dlopen so a user can swap it. The input
// is any user's attachment: every size is checked before it is used.
#include <string.h>
#include "libavcodec/avcodec.h"
#include "libavutil/log.h"
#include "libavutil/mem.h"

#define FC_API __attribute__((visibility("default")))
#define FC_MAX_CONFIG 64          // AudioSpecificConfig bytes
#define FC_MAX_PACKET (1 << 20)   // one AAC frame is at most 6144 bits per channel
#define FC_MAX_CHANNELS 8

typedef struct { AVCodecContext *ctx; AVPacket *pkt; AVFrame *frame; } fc_aac;

FC_API void fc_aac_close(fc_aac *d) {
    if (!d) return;
    avcodec_free_context(&d->ctx);
    av_packet_free(&d->pkt);
    av_frame_free(&d->frame);
    av_free(d);
}

// A decoder for raw AAC frames described by config (the AudioSpecificConfig), or with config_len 0 for ADTS.
FC_API fc_aac *fc_aac_open(const unsigned char *config, int config_len) {
    if (config_len < 0 || config_len > FC_MAX_CONFIG || (config_len && !config)) return NULL;
    av_log_set_level(AV_LOG_QUIET);
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_AAC);
    fc_aac *d = codec ? av_mallocz(sizeof *d) : NULL;
    if (!d) return NULL;
    d->ctx = avcodec_alloc_context3(codec);
    d->pkt = av_packet_alloc();
    d->frame = av_frame_alloc();
    if (!d->ctx || !d->pkt || !d->frame) goto fail;
    if (config_len) {
        d->ctx->extradata = av_mallocz(config_len + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!d->ctx->extradata) goto fail;
        memcpy(d->ctx->extradata, config, config_len);
        d->ctx->extradata_size = config_len;
    }
    if (avcodec_open2(d->ctx, codec, NULL) < 0) goto fail;
    return d;
fail:
    fc_aac_close(d);
    return NULL;
}

// Decodes one packet into out as interleaved float, at most cap floats. Returns the frames written per
// channel (0 when nothing came out), or -1 when the packet is refused; the next packet can still decode.
// *channels and *rate are the output's (HE-AAC doubles the config's rate, PS makes mono stereo).
FC_API int fc_aac_decode(fc_aac *d, const unsigned char *data, int len, float *out, int cap, int *channels, int *rate) {
    if (!d || !data || len <= 0 || len > FC_MAX_PACKET || !out || cap <= 0 || !channels || !rate) return -1;
    // the decoder may read AV_INPUT_BUFFER_PADDING_SIZE bytes past the end: decode a zero-padded copy
    if (av_new_packet(d->pkt, len) < 0) return -1;
    memcpy(d->pkt->data, data, len);
    int r = avcodec_send_packet(d->ctx, d->pkt);
    av_packet_unref(d->pkt);
    if (r < 0) return -1;
    int n = 0;
    while (avcodec_receive_frame(d->ctx, d->frame) >= 0) {
        AVFrame *f = d->frame;
        int ch = f->ch_layout.nb_channels;
        // an explicit rate in the config can be anything up to 2^24 Hz: keep audio's
        if (f->format == AV_SAMPLE_FMT_FLTP && ch >= 1 && ch <= FC_MAX_CHANNELS && f->sample_rate >= 1000 && f->sample_rate <= 384000 && f->nb_samples > 0
            && (n == 0 || ch == *channels) && f->nb_samples <= cap / ch - n) {
            for (int s = 0; s < f->nb_samples; s++)
                for (int c = 0; c < ch; c++) out[(n + s) * ch + c] = ((const float *) f->extended_data[c])[s];
            n += f->nb_samples;
            *channels = ch;
            *rate = f->sample_rate;
        }
        av_frame_unref(f);
    }
    return n;
}
