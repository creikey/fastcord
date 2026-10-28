// fastcord's wrapper over BLAKE3 (vendor/blake3; the library itself is built from fc_blake3.sources).
// Bound in src/crypto.
#include "c/blake3.h"

void fc_blake3(const void *in, size_t n, uint8_t out[32]) {
    blake3_hasher h;
    blake3_hasher_init(&h);
    blake3_hasher_update(&h, in, n);
    blake3_hasher_finalize(&h, out, 32);
}

// BLAKE3's derive_key mode: ctx is a hardcoded, globally unique context string, so hashes made for
// one purpose can never collide with another's.
void fc_blake3_derive(const char *ctx, const void *in, size_t n, uint8_t out[32]) {
    blake3_hasher h;
    blake3_hasher_init_derive_key(&h, ctx);
    blake3_hasher_update(&h, in, n);
    blake3_hasher_finalize(&h, out, 32);
}
