// gw <msgs.bin> <out.zst> <out.idx> <level> <windowLog> : one zstd frame, ZSTD_e_flush after each message.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <zstd.h>
int main(int argc, char** argv) {
  FILE* f = fopen(argv[1], "rb"); fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  uint8_t* in = malloc(n); fread(in, 1, n, f); fclose(f);
  ZSTD_CCtx* c = ZSTD_createCCtx();
  ZSTD_CCtx_setParameter(c, ZSTD_c_compressionLevel, atoi(argv[4]));
  ZSTD_CCtx_setParameter(c, ZSTD_c_windowLog, atoi(argv[5]));
  ZSTD_CCtx_setParameter(c, ZSTD_c_checksumFlag, 0);
  FILE* o = fopen(argv[2], "wb"); FILE* idx = fopen(argv[3], "wb");
  size_t cap = ZSTD_compressBound(1 << 20) + 1024; uint8_t* buf = malloc(cap);
  long p = 0;
  while (p < n) {
    uint32_t len = in[p] | in[p+1] << 8 | in[p+2] << 16 | (uint32_t)in[p+3] << 24; p += 4;
    ZSTD_inBuffer ib = { in + p, len, 0 }; p += len;
    uint32_t total = 0; size_t rem;
    do { ZSTD_outBuffer ob = { buf, cap, 0 }; rem = ZSTD_compressStream2(c, &ob, &ib, ZSTD_e_flush);
         if (ZSTD_isError(rem)) { fprintf(stderr, "%s\n", ZSTD_getErrorName(rem)); return 1; }
         fwrite(buf, 1, ob.pos, o); total += ob.pos; } while (rem != 0);
    fwrite(&total, 4, 1, idx);
  }
  fclose(o); fclose(idx); return 0;
}
