// vpxkf <in.rgba> <w> <h> <out.vp8> <token_parts_log2> <cq> <sharpness> <noise>: one VP8 keyframe via libvpx.
#include <stdio.h>
#include <stdlib.h>
#include <vpx/vpx_encoder.h>
#include <vpx/vp8cx.h>
int main(int argc, char** argv) {
  int w = atoi(argv[2]), h = atoi(argv[3]);
  FILE* f = fopen(argv[1], "rb"); unsigned char* rgba = malloc(w*h*4); fread(rgba, 1, w*h*4, f); fclose(f);
  vpx_image_t img; vpx_img_alloc(&img, VPX_IMG_FMT_I420, w, h, 1);
  for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { unsigned char* p = rgba + (y*w+x)*4;
    img.planes[0][y*img.stride[0]+x] = (66*p[0]+129*p[1]+25*p[2]+128)/256+16; }
  for (int y = 0; y < (h+1)/2; y++) for (int x = 0; x < (w+1)/2; x++) { unsigned char* p = rgba + ((2*y)*w+2*x)*4;
    img.planes[1][y*img.stride[1]+x] = (-38*p[0]-74*p[1]+112*p[2]+128)/256+128; img.planes[2][y*img.stride[2]+x] = (112*p[0]-94*p[1]-18*p[2]+128)/256+128; }
  vpx_codec_enc_cfg_t cfg; vpx_codec_enc_config_default(vpx_codec_vp8_cx(), &cfg, 0);
  cfg.g_w = w; cfg.g_h = h; cfg.rc_end_usage = VPX_Q; cfg.g_lag_in_frames = 0;
  vpx_codec_ctx_t c; if (vpx_codec_enc_init(&c, vpx_codec_vp8_cx(), &cfg, 0)) { fprintf(stderr, "init\n"); return 1; }
  vpx_codec_control(&c, VP8E_SET_TOKEN_PARTITIONS, atoi(argv[5]));
  vpx_codec_control(&c, VP8E_SET_CQ_LEVEL, atoi(argv[6]));
  vpx_codec_control(&c, VP8E_SET_SHARPNESS, atoi(argv[7]));
  vpx_codec_control(&c, VP8E_SET_NOISE_SENSITIVITY, atoi(argv[8]));
  FILE* o = fopen(argv[4], "wb"); int done = 0;
  for (int pass = 0; pass < 2 && !done; pass++) {
    if (vpx_codec_encode(&c, pass ? NULL : &img, 0, 1, pass ? 0 : VPX_EFLAG_FORCE_KF, VPX_DL_BEST_QUALITY)) { fprintf(stderr, "enc %s\n", vpx_codec_error_detail(&c)); return 1; }
    const vpx_codec_cx_pkt_t* pkt; vpx_codec_iter_t it = NULL;
    while ((pkt = vpx_codec_get_cx_data(&c, &it))) if (pkt->kind == VPX_CODEC_CX_FRAME_PKT && !done) { fwrite(pkt->data.frame.buf, 1, pkt->data.frame.sz, o); done = 1; }
  }
  fclose(o); return 0;
}
