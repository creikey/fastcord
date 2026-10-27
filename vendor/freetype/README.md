# FreeType

Font loading and glyph rasterization for the Linux text backend (`src/gfx/text_freetype_linux.jai`); macOS
and Windows use CoreText and DirectWrite, so `build.jai` builds this only for Linux (the `.linux` file).
Upstream's release files, unmodified: the `include/` and `src/` files the build compiles or includes
(found with `zig cc -M` for x86_64-linux-gnu over every source), plus `LICENSE.TXT` and `docs/FTL.TXT`.

- Source: https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz
- sha256 of the tarball: 0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289
- Licence: the FreeType License (`docs/FTL.TXT`; FreeType is dual-licensed FTL / GPLv2, fastcord uses FTL).

Ours:
- `fc_config/freetype/config/ftmodule.h` and `ftoption.h`: found before `include/` (`fc_freetype.cflags`).
  Modules: TrueType, CFF (with psaux, psnames, pshinter), SFNT and the smooth rasterizer; text is drawn
  unhinted, so no autofitter. Options: upstream's, then WOFF2 on (against `vendor/brotli`), PNG on, zlib /
  LZW / OT-SVG off.
- `fc_freetype.c`: `Load_SBit_Png`, the hook FreeType calls for PNG glyph bitmaps (CBDT colour emoji such as
  Noto Color Emoji), decoding with Wuffs (`vendor/wuffs/fc_wuffs.c`) instead of libpng; this is why
  `src/sfnt` is built file by file without `pngshim.c` rather than as `sfnt.c`. Also a few accessors so the
  Jai side reads no FreeType struct layouts.
- `fc_freetype.sources`: the library's translation units (module amalgamations, the `src/sfnt` files).

To update: download the new release, copy the same files (rerun `zig cc -M` over `fc_freetype.sources` and
`fc_freetype.c` with `fc_freetype.cflags` to list them), check that `Load_SBit_Png`'s signature in
`src/sfnt/pngshim.h` and the `src/sfnt` file list still match, record the version and sha256 here, then run
`jai build.jai - c linux`.
