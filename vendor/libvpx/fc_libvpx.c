// fastcord's interface to libvpx: VP8 decoding for calls and Go Live (src/media/decode_sw.jai), 4:2:0
// pictures out.
#include <stdint.h>
#include <stdlib.h>
#include "vpx/vpx_decoder.h"
#include "vpx/vp8dx.h"

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
