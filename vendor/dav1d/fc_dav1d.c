// fastcord's interface to dav1d: AV1 decoding for calls and Go Live (src/media/decode_sw.jai), 8-bit 4:2:0
// pictures out.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "dav1d/dav1d.h"

#define QUEUE 4

typedef struct {
	Dav1dContext *c;
	Dav1dPicture queue[QUEUE]; // pictures taken while sending (dav1d was full), oldest first
	int queued;
	Dav1dPicture pic; // the last picture handed out, until the next call
	int have_pic;
} Fc_Av1;

void *fc_av1_create(int threads) {
	Dav1dSettings s;
	dav1d_default_settings(&s);
	s.n_threads = threads;
	s.max_frame_delay = 1; // live video: every picture as soon as its data is in
	s.frame_size_limit = 8192 * 8192;
	Fc_Av1 *d = calloc(1, sizeof *d);
	if (!d) return NULL;
	if (dav1d_open(&d->c, &s) < 0) { free(d); return NULL; }
	return d;
}

// One temporal unit (OBUs with size fields). 0 ok, -1 a bad stream. Pictures come out of fc_av1_picture.
int fc_av1_decode(void *p, const uint8_t *data, size_t n) {
	Fc_Av1 *d = p;
	Dav1dData in = {0};
	uint8_t *buf = dav1d_data_create(&in, n);
	if (!buf) return -1;
	memcpy(buf, data, n);
	while (in.sz) {
		int r = dav1d_send_data(d->c, &in);
		if (r == DAV1D_ERR(EAGAIN) && d->queued < QUEUE && dav1d_get_picture(d->c, &d->queue[d->queued]) == 0) { d->queued++; continue; }
		if (r < 0) { dav1d_data_unref(&in); return -1; }
	}
	return 0;
}

// The next decoded picture's 8-bit 4:2:0 planes: 1 with one, 0 with none (others are skipped).
int fc_av1_picture(void *p, const uint8_t **y, const uint8_t **u, const uint8_t **v, int *ys, int *uvs, int *w, int *h) {
	Fc_Av1 *d = p;
	for (;;) {
		if (d->have_pic) dav1d_picture_unref(&d->pic);
		d->have_pic = 0;
		if (d->queued) {
			d->pic = d->queue[0];
			memmove(d->queue, d->queue + 1, (size_t)(--d->queued) * sizeof d->queue[0]);
		} else if (dav1d_get_picture(d->c, &d->pic) < 0) return 0;
		d->have_pic = 1;
		if (d->pic.p.bpc == 8 && d->pic.p.layout == DAV1D_PIXEL_LAYOUT_I420) break;
	}
	*y = d->pic.data[0]; *u = d->pic.data[1]; *v = d->pic.data[2];
	*ys = (int)d->pic.stride[0]; *uvs = (int)d->pic.stride[1];
	*w = d->pic.p.w; *h = d->pic.p.h;
	return 1;
}

void fc_av1_destroy(void *p) {
	Fc_Av1 *d = p;
	if (!d) return;
	if (d->have_pic) dav1d_picture_unref(&d->pic);
	for (int i = 0; i < d->queued; i++) dav1d_picture_unref(&d->queue[i]);
	dav1d_close(&d->c);
	free(d);
}
