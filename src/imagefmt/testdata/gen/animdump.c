// animdump <in.webp> <out.rgba>: all composited frames via WebPAnimDecoder (RGBA, straight alpha).
#include <stdio.h>
#include <stdlib.h>
#include <webp/demux.h>
int main(int argc, char** argv) {
  FILE* f = fopen(argv[1], "rb"); fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  uint8_t* d = malloc(n); fread(d, 1, n, f); fclose(f);
  WebPData wd = { d, n }; WebPAnimDecoderOptions o; WebPAnimDecoderOptionsInit(&o); o.color_mode = MODE_RGBA; o.use_threads = 0;
  WebPAnimDecoder* dec = WebPAnimDecoderNew(&wd, &o); if (!dec) { fprintf(stderr, "fail\n"); return 1; }
  WebPAnimInfo info; WebPAnimDecoderGetInfo(dec, &info);
  FILE* out = fopen(argv[2], "wb"); uint8_t* buf; int ts, nf = 0;
  while (WebPAnimDecoderHasMoreFrames(dec)) { if (!WebPAnimDecoderGetNext(dec, &buf, &ts)) { fprintf(stderr, "frame fail\n"); return 1; } fwrite(buf, 1, info.canvas_width * info.canvas_height * 4, out); nf++; }
  printf("%u %u %d loop=%u\n", info.canvas_width, info.canvas_height, nf, info.loop_count); fclose(out); return 0;
}
