// fastcord's one translation unit for brotli: upstream's decoder (c/common + c/dec, laid out here as
// common/, dec/ and include/). Bound in src/brotli. Built by build.jai into
// build/fc_vendor.a, with fc_brotli.cflags putting include/ on the path.

#include "common/constants.c"
#include "common/context.c"
#include "common/dictionary.c"
#include "common/platform.c"
#include "common/shared_dictionary.c"
#include "common/transform.c"
#include "dec/bit_reader.c"
#include "dec/decode.c"
#include "dec/huffman.c"
#include "dec/prefix.c"
#include "dec/state.c"
#include "dec/static_init.c"
