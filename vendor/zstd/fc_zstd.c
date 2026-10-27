// fastcord's one translation unit for zstd: the decompression half of upstream's lib/, built the way
// upstream's own single-file decoder (build/single_file_libs/zstddeclib-in.c) builds it. Bound in
// src/zstd. Built by build.jai into build/fc_vendor.a.

#define DEBUGLEVEL 0
#define XXH_NAMESPACE ZSTD_
#define XXH_PRIVATE_API
#define XXH_INLINE_ALL
#define ZSTD_LEGACY_SUPPORT 0
#define ZSTD_LIB_COMPRESSION 0
#define ZSTD_LIB_DECOMPRESSION 1
#define ZSTD_LIB_DICTBUILDER 0
#define ZSTD_LIB_DEPRECATED 0
#define ZSTD_NOBENCH
#define ZSTD_STRIP_ERROR_STRINGS
#define ZSTD_TRACE 0
#define ZSTD_DISABLE_ASM 1

#include "lib/common/debug.c"
#include "lib/common/entropy_common.c"
#include "lib/common/error_private.c"
#include "lib/common/fse_decompress.c"
#include "lib/common/zstd_common.c"
#include "lib/decompress/huf_decompress.c"
#include "lib/decompress/zstd_ddict.c"
#include "lib/decompress/zstd_decompress.c"
#include "lib/decompress/zstd_decompress_block.c"
