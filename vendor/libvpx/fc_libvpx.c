// fastcord's interface to libvpx: VP8 decoding for calls and Go Live (src/media/decode_sw.jai), 4:2:0
// pictures out, and realtime VP8 encoding of the camera and screen (src/video/encode_vp8.jai), NV12 in.
#include <stdint.h>
#include <stdlib.h>
#include "vpx/vpx_decoder.h"
#include "vpx/vp8dx.h"
#include "vpx/vpx_encoder.h"
#include "vpx/vp8cx.h"

typedef struct {
	vpx_codec_ctx_t ctx;
	vpx_codec_iter_t iter;
} Fc_Vp8;

void *fc_vp8_create(void) {
	Fc_Vp8 *d = calloc(1, sizeof *d);
	if (!d) return NULL;
	vpx_codec_dec_cfg_t cfg = {0};
	if (vpx_codec_dec_init(&d->ctx, vpx_codec_vp8_dx(), &cfg, 0) != VPX_CODEC_OK) { free(d); return NULL; }
	return d;
}

// One frame. 0 ok, -1 a bad one. Its picture comes out of fc_vp8_picture.
int fc_vp8_decode(void *p, const uint8_t *data, size_t n) {
	Fc_Vp8 *d = p;
	d->iter = NULL;
	if (n > 0x7fffffff) return -1;
	return vpx_codec_decode(&d->ctx, data, (unsigned int)n, NULL, 0) == VPX_CODEC_OK ? 0 : -1;
}

int fc_vp8_picture(void *p, const uint8_t **y, const uint8_t **u, const uint8_t **v, int *ys, int *uvs, int *w, int *h) {
	Fc_Vp8 *d = p;
	vpx_image_t *img;
	while ((img = vpx_codec_get_frame(&d->ctx, &d->iter))) {
		if (img->fmt != VPX_IMG_FMT_I420 || img->stride[1] != img->stride[2]) continue;
		*y = img->planes[0]; *u = img->planes[1]; *v = img->planes[2];
		*ys = img->stride[0]; *uvs = img->stride[1];
		*w = (int)img->d_w; *h = (int)img->d_h;
		return 1;
	}
	return 0;
}

void fc_vp8_destroy(void *p) {
	Fc_Vp8 *d = p;
	if (!d) return;
	vpx_codec_destroy(&d->ctx);
	free(d);
}

// The encoder, set up as WebRTC's LibvpxVp8Encoder for one stream: CBR, no lag, frame dropping, one token
// partition, keyframes only on request (and every kf_max_dist frames).
typedef struct {
	vpx_codec_ctx_t ctx;
	vpx_image_t img; // I420, the NV12 input deinterleaved
	int fps;
	int64_t pts_hi; // pts_90k wraps every 13 h; libvpx needs increasing timestamps
	uint32_t last_pts;
} Fc_Vp8_Enc;

void *fc_vp8_enc_create(int w, int h, int fps, int bitrate, int screen) {
	if (w < 16 || h < 16 || w > 8192 || h > 8192 || fps < 1) return NULL;
	Fc_Vp8_Enc *e = calloc(1, sizeof *e);
	if (!e) return NULL;
	vpx_codec_enc_cfg_t c;
	if (vpx_codec_enc_config_default(vpx_codec_vp8_cx(), &c, 0) != VPX_CODEC_OK) { free(e); return NULL; }
	c.g_w = (unsigned)w;
	c.g_h = (unsigned)h;
	c.g_timebase.num = 1;
	c.g_timebase.den = 90000;
	c.g_threads = 1;
	c.g_lag_in_frames = 0;
	c.g_error_resilient = 0;
	c.rc_end_usage = VPX_CBR;
	c.rc_target_bitrate = (unsigned)(bitrate / 1000);
	c.rc_min_quantizer = screen ? 12 : 2;
	c.rc_max_quantizer = 56;
	c.rc_undershoot_pct = 100;
	c.rc_overshoot_pct = 15;
	c.rc_buf_initial_sz = 500;
	c.rc_buf_optimal_sz = 600;
	c.rc_buf_sz = 1000;
	c.rc_dropframe_thresh = screen ? 0 : 30;
	c.rc_resize_allowed = 0;
	c.kf_mode = VPX_KF_AUTO;
	c.kf_max_dist = 3000;
	if (vpx_codec_enc_init(&e->ctx, vpx_codec_vp8_cx(), &c, 0) != VPX_CODEC_OK) { free(e); return NULL; }
	vpx_codec_control(&e->ctx, VP8E_SET_CPUUSED, -12);
	vpx_codec_control(&e->ctx, VP8E_SET_NOISE_SENSITIVITY, 0);
	vpx_codec_control(&e->ctx, VP8E_SET_STATIC_THRESHOLD, 1);
	vpx_codec_control(&e->ctx, VP8E_SET_TOKEN_PARTITIONS, VP8_ONE_TOKENPARTITION);
	vpx_codec_control(&e->ctx, VP8E_SET_MAX_INTRA_BITRATE_PCT, 450);
	vpx_codec_control(&e->ctx, VP8E_SET_SCREEN_CONTENT_MODE, screen ? 1 : 0);
	if (!vpx_img_alloc(&e->img, VPX_IMG_FMT_I420, (unsigned)w, (unsigned)h, 16)) { vpx_codec_destroy(&e->ctx); free(e); return NULL; }
	e->fps = fps;
	return e;
}

// One NV12 picture of the encoder's size (ys, uvs: row pitches). 0 with the frame in out (valid until the next
// call; n 0 when rate control dropped it), -1 on error.
int fc_vp8_enc_encode(void *p, const uint8_t *y, const uint8_t *uv, int ys, int uvs, uint32_t pts_90k, int force_key, const uint8_t **out, size_t *n, int *key) {
	Fc_Vp8_Enc *e = p;
	vpx_image_t *im = &e->img;
	*out = NULL; *n = 0; *key = 0;
	for (unsigned r = 0; r < im->d_h; r++) {
		const uint8_t *s = y + (size_t)r * ys;
		uint8_t *d = im->planes[0] + (size_t)r * im->stride[0];
		for (unsigned i = 0; i < im->d_w; i++) d[i] = s[i];
	}
	for (unsigned r = 0; r < (im->d_h + 1) / 2; r++) {
		const uint8_t *s = uv + (size_t)r * uvs;
		uint8_t *u = im->planes[1] + (size_t)r * im->stride[1], *v = im->planes[2] + (size_t)r * im->stride[2];
		for (unsigned i = 0; i < (im->d_w + 1) / 2; i++) { u[i] = s[2 * i]; v[i] = s[2 * i + 1]; }
	}
	if (pts_90k < e->last_pts && e->last_pts - pts_90k > 0x80000000u) e->pts_hi += 0x100000000ll;
	e->last_pts = pts_90k;
	vpx_enc_frame_flags_t f = force_key ? VPX_EFLAG_FORCE_KF : 0;
	if (vpx_codec_encode(&e->ctx, im, e->pts_hi + pts_90k, (unsigned long)(90000 / e->fps), f, VPX_DL_REALTIME) != VPX_CODEC_OK) return -1;
	vpx_codec_iter_t it = NULL;
	const vpx_codec_cx_pkt_t *pkt;
	while ((pkt = vpx_codec_get_cx_data(&e->ctx, &it))) {
		if (pkt->kind != VPX_CODEC_CX_FRAME_PKT) continue;
		*out = pkt->data.frame.buf;
		*n = pkt->data.frame.sz;
		*key = (pkt->data.frame.flags & VPX_FRAME_IS_KEY) != 0;
	}
	return 0;
}

void fc_vp8_enc_destroy(void *p) {
	Fc_Vp8_Enc *e = p;
	if (!e) return;
	vpx_codec_destroy(&e->ctx);
	vpx_img_free(&e->img);
	free(e);
}
