// Upstream's x86 files don't guard themselves: build them only on x86-64.
#if defined(__x86_64__) || defined(_M_X64)
#include "../c/blake3_avx2.c"
#endif
