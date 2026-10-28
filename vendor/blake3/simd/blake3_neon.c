// Upstream's NEON file doesn't guard itself: build it only on arm64.
#if defined(__aarch64__) || defined(_M_ARM64)
#include "../c/blake3_neon.c"
#endif
