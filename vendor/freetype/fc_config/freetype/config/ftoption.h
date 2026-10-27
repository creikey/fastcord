// fastcord's FreeType options: upstream's defaults (include_next), then the changes below. This
// directory comes before include/ on the path (fc_freetype.cflags), so FreeType finds it first.
#include_next <freetype/config/ftoption.h>

// WOFF2 (gg sans) through the vendored brotli; no WOFF1, gzip or LZW.
#undef FT_CONFIG_OPTION_USE_ZLIB
#undef FT_CONFIG_OPTION_USE_LZW
#define FT_CONFIG_OPTION_USE_BROTLI
// CBDT colour emoji (Noto Color Emoji): Load_SBit_Png is fc_freetype.c's, decoding with Wuffs.
#define FT_CONFIG_OPTION_USE_PNG
// No OT-SVG renderer is built; with this on, FT_LOAD_COLOR would pick SVG glyphs it can't render.
#undef FT_CONFIG_OPTION_SVG
