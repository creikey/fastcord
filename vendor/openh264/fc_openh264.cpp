// fastcord's C interface to openh264 (Linux video calls): a realtime camera encoder that takes NV12 and emits
// Annex B, and a decoder that takes one Annex B access unit and returns I420 planes.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "codec_api.h"

extern "C" {

void *fc_h264_dec_create(void) {
	ISVCDecoder *d = NULL;
	if (WelsCreateDecoder(&d) != 0 || !d) return NULL;
	SDecodingParam p;
	memset(&p, 0, sizeof p);
	p.sVideoProperty.eVideoBsType = VIDEO_BITSTREAM_AVC;
	if (d->Initialize(&p) != 0) { WelsDestroyDecoder(d); return NULL; }
	int level = WELS_LOG_QUIET;
	d->SetOption(DECODER_OPTION_TRACE_LEVEL, &level);
	return d;
}

// Returns 1 with I420 planes (valid until the next call) when a picture is ready, 0 when none is yet, -1 on error.
int fc_h264_dec_decode(void *dv, const uint8_t *annexb, int n, int64_t ts, uint8_t **y, uint8_t **u, uint8_t **v, int *y_stride, int *uv_stride, int *w, int *h, int64_t *out_ts) {
	ISVCDecoder *d = (ISVCDecoder *)dv;
	uint8_t *planes[3] = {NULL, NULL, NULL};
	SBufferInfo info;
	memset(&info, 0, sizeof info);
	info.uiInBsTimeStamp = (unsigned long long)ts;
	DECODING_STATE st = d->DecodeFrameNoDelay(annexb, n, planes, &info);
	if (st != dsErrorFree && info.iBufferStatus != 1) return -1;
	if (info.iBufferStatus != 1) return 0;
	*y = planes[0]; *u = planes[1]; *v = planes[2];
	*y_stride = info.UsrData.sSystemBuffer.iStride[0];
	*uv_stride = info.UsrData.sSystemBuffer.iStride[1];
	*w = info.UsrData.sSystemBuffer.iWidth;
	*h = info.UsrData.sSystemBuffer.iHeight;
	*out_ts = (int64_t)info.uiOutYuvTimeStamp;
	return 1;
}

void fc_h264_dec_destroy(void *dv) {
	ISVCDecoder *d = (ISVCDecoder *)dv;
	if (!d) return;
	d->Uninitialize();
	WelsDestroyDecoder(d);
}

struct Fc_H264_Enc {
	ISVCEncoder *e;
	int w, h;
	uint8_t *i420; // the NV12 input, deinterleaved
	uint8_t *out;
	int out_cap;
};

void *fc_h264_enc_create(int w, int h, int fps, int bitrate) {
	ISVCEncoder *e = NULL;
	if (WelsCreateSVCEncoder(&e) != 0 || !e) return NULL;
	int level = WELS_LOG_QUIET;
	e->SetOption(ENCODER_OPTION_TRACE_LEVEL, &level);
	SEncParamExt p;
	e->GetDefaultParams(&p);
	p.iUsageType = CAMERA_VIDEO_REAL_TIME;
	p.iPicWidth = w;
	p.iPicHeight = h;
	p.fMaxFrameRate = (float)fps;
	p.iTargetBitrate = bitrate;
	p.iMaxBitrate = bitrate * 3 / 2;
	p.iRCMode = RC_BITRATE_MODE;
	p.bEnableFrameSkip = true; // as WebRTC does: the only way openh264 holds the bitrate
	p.uiIntraPeriod = (unsigned)(fps * 2);
	p.eSpsPpsIdStrategy = CONSTANT_ID;
	p.bPrefixNalAddingCtrl = false;
	p.iSpatialLayerNum = 1;
	p.iTemporalLayerNum = 1;
	p.iMultipleThreadIdc = 2;
	p.iEntropyCodingModeFlag = 0; // CAVLC: constrained baseline
	SSpatialLayerConfig *l = &p.sSpatialLayers[0];
	l->iVideoWidth = w;
	l->iVideoHeight = h;
	l->fFrameRate = (float)fps;
	l->iSpatialBitrate = bitrate;
	l->iMaxSpatialBitrate = bitrate * 3 / 2;
	l->uiProfileIdc = PRO_BASELINE;
	l->sSliceArgument.uiSliceMode = SM_SINGLE_SLICE;
	if (e->InitializeExt(&p) != 0) { WelsDestroySVCEncoder(e); return NULL; }
	int fmt = videoFormatI420;
	e->SetOption(ENCODER_OPTION_DATAFORMAT, &fmt);
	Fc_H264_Enc *f = (Fc_H264_Enc *)calloc(1, sizeof *f);
	f->e = e;
	f->w = w;
	f->h = h;
	f->i420 = (uint8_t *)malloc((size_t)w * h * 3 / 2);
	return f;
}

int fc_h264_enc_encode(void *ev, const uint8_t *nv12, int64_t ts_ms, int force_keyframe, uint8_t **out, int *n, int *keyframe) {
	Fc_H264_Enc *f = (Fc_H264_Enc *)ev;
	int w = f->w, h = f->h;
	memcpy(f->i420, nv12, (size_t)w * h);
	uint8_t *u = f->i420 + w * h, *v = u + w * h / 4;
	const uint8_t *uv = nv12 + w * h;
	for (int i = 0; i < w * h / 4; i++) { u[i] = uv[2 * i]; v[i] = uv[2 * i + 1]; }
	SSourcePicture pic;
	memset(&pic, 0, sizeof pic);
	pic.iColorFormat = videoFormatI420;
	pic.iPicWidth = w;
	pic.iPicHeight = h;
	pic.iStride[0] = w;
	pic.iStride[1] = pic.iStride[2] = w / 2;
	pic.pData[0] = f->i420;
	pic.pData[1] = u;
	pic.pData[2] = v;
	pic.uiTimeStamp = ts_ms;
	if (force_keyframe) f->e->ForceIntraFrame(true);
	SFrameBSInfo bs;
	memset(&bs, 0, sizeof bs);
	*n = 0;
	*keyframe = 0;
	if (f->e->EncodeFrame(&pic, &bs) != cmResultSuccess) return -1;
	if (bs.eFrameType == videoFrameTypeSkip || bs.eFrameType == videoFrameTypeInvalid) return 0;
	int total = 0;
	for (int i = 0; i < bs.iLayerNum; i++)
		for (int j = 0; j < bs.sLayerInfo[i].iNalCount; j++) total += bs.sLayerInfo[i].pNalLengthInByte[j];
	if (total > f->out_cap) {
		free(f->out);
		f->out_cap = total * 2;
		f->out = (uint8_t *)malloc(f->out_cap);
	}
	int at = 0;
	for (int i = 0; i < bs.iLayerNum; i++) {
		int len = 0;
		for (int j = 0; j < bs.sLayerInfo[i].iNalCount; j++) len += bs.sLayerInfo[i].pNalLengthInByte[j];
		memcpy(f->out + at, bs.sLayerInfo[i].pBsBuf, len);
		at += len;
	}
	*out = f->out;
	*n = at;
	*keyframe = bs.eFrameType == videoFrameTypeIDR;
	return 0;
}

void fc_h264_enc_destroy(void *ev) {
	Fc_H264_Enc *f = (Fc_H264_Enc *)ev;
	if (!f) return;
	f->e->Uninitialize();
	WelsDestroySVCEncoder(f->e);
	free(f->i420);
	free(f->out);
	free(f);
}

}
