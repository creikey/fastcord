# HarfBuzz

Text shaping for the Linux text backend (`src/gfx/text_freetype_linux.jai`); macOS and Windows shape with
CoreText and DirectWrite, so `build.jai` builds this only for Linux (the `.linux` file). Upstream's release
files, unmodified: the `src/` files the one-unit build (`src/harfbuzz.cc`) includes on Linux (found with
`zig c++ -M` for x86_64-linux-gnu), plus `COPYING`.

- Upstream: https://github.com/harfbuzz/harfbuzz 15.0.0
- Source: https://github.com/harfbuzz/harfbuzz/releases/download/15.0.0/harfbuzz-15.0.0.tar.xz
- sha256 of the tarball: 968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df
- Licence: the "Old MIT" licence (`COPYING`).

Built without FreeType, ICU or GLib: the backend gives HarfBuzz each font's tables through
`FT_Load_Sfnt_Table` (so WOFF2 fonts FreeType unpacked shape too) and uses its built-in OpenType font
functions and Unicode data. `fc_harfbuzz.cflags` turns on pthread mutexes.

To update: download the new release, copy `src/harfbuzz.cc` and the files it includes (rerun
`zig c++ -M -target x86_64-linux-gnu -std=c++17 -DHAVE_PTHREAD vendor/harfbuzz/src/harfbuzz.cc`), record
the version and sha256 here, then run `jai build.jai - c linux`.
