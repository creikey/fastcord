# libwebp

WebP encoding for uploads (`src/imagefmt/webp_encode.odin`, used by `src/discord/webp_convert.odin`).
Upstream's release files, unmodified: `src/{enc,dsp,utils,dec,webp}`, `src/mux/{muxedit,muxinternal,muxread}.c`
and `muxi.h`, `sharpyuv/`, plus `COPYING` and `PATENTS`. Only `.c` / `.h` files; no MIPS / MSA sources, demux,
animation encoder, examples, tests or build files. The decoder (`src/dec`) is here only because the mux
checks the image it is given with it; decoding for display stays with Wuffs.

- Source: https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz
- sha256 of the tarball: e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
  (the same as Homebrew's `webp` 1.6.0 formula)
- Licence: BSD-3-Clause (COPYING), with Google's patent grant (PATENTS).

Why: it is the encoder Chrome's `canvas.toBlob("image/webp", ...)` runs (through Skia), so the official
client's upload conversion can be reproduced byte for byte. It replaced a hand-written VP8L encoder that
could not match Chrome's output.

`fc_libwebp.c` is ours: one call that encodes as Skia's `SkWebpEncoder` does for a lossless canvas
(`WebPConfigPreset` default at quality 75, `lossless = 1`, `method = 0`, `use_argb = 1`,
`WebPPictureImportRGBA`, then `WebPMux` adds the ICC profile). `build.sh` / `build.bat` compile it into
`build/fc_libwebp.obj` (`.o` on macOS); `fc_libwebp.sources` lists the 99 library files they compile into
`build/fc_libwebp.lib` (Windows, with MSVC's `cl`: its SSE4.1 / AVX2 files need no `-m` flags there, unlike
clang-cl) or `build/libfc_libwebp.a` (macOS, arm64 + x86_64); `fc_libwebp.cflags` holds the include path.

To update: download the new release tarball, copy the same directories (`.c` / `.h` only, without
`*mips*` / `*msa*`, `src/demux`, `src/webp/demux.h`, `src/mux/anim_encode.c`, `src/mux/animi.h`), regenerate
`fc_libwebp.sources` (every `.c` but `fc_libwebp.c`, sorted), record the version and sha256 here, then run
`./build.sh test discord` (`webp_conversion_rules` checks the bytes against Chrome's).
