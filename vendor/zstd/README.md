# zstd

Zstandard decoding (gateway `compress=zstd-stream`, HTTP `content-encoding: zstd`). The decompression
half of upstream's `lib/`, unmodified: `lib/zstd.h`, `lib/zstd_errors.h`, `lib/common/`,
`lib/decompress/` (minus the x86-64 assembly, which `ZSTD_DISABLE_ASM` replaces with C).

- Source: https://github.com/facebook/zstd/releases/tag/v1.5.7, `zstd-1.5.7.tar.gz`
  (tag commit f8745da6ff1ad1e7bab384bd1f9d742439278e99)
- sha256 of the tarball: eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3
- Licence: BSD (LICENSE); upstream is dual BSD / GPLv2 and we take BSD.

Why: it is the reference decoder, fuzzed continuously by OSS-Fuzz and shipped in Chrome. The
hand-written Odin decoder it replaced turned bounds checks off on network input.

`fc_zstd.c` is ours: a unity build of the decoder files with the defines upstream's own single-file
decoder (`build/single_file_libs/zstddeclib-in.c`) uses. `src/zstd` binds it.

To update: replace `lib/` with the new release's files (same subset), record the version, commit and
sha256 here, then run `jai build.jai - test`.
