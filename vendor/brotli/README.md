# brotli

Brotli decoding (HTTP `content-encoding: br`, TLS certificate compression). Upstream's decoder,
unmodified: `c/common/` → `common/`, `c/dec/` → `dec/`, and the decoder's public headers from
`c/include/brotli/` → `include/brotli/` (`fc_brotli.cflags` puts `include/` on the path).

- Source: https://github.com/google/brotli/releases/tag/v1.2.1, GitHub's tag archive
  `v1.2.1.tar.gz` (commit db24a98aed38a16de78cc05ca15cdd8dc2a0d92d)
- sha256 of the archive: 98d35d11a78dc453aebb7d10c3748f3f73ff78c8267c0dc697b8631f67bf7e8f
- Licence: MIT (LICENSE)

Why: it is the reference decoder, fuzzed continuously by OSS-Fuzz and shipped in Chrome. The
hand-written Odin decoder it replaced turned bounds checks off on network input.

`fc_brotli.c` is ours: a unity build of the decoder files. `src/brotli` binds it.

To update: replace `common/`, `dec/` and `include/brotli/` (decode.h, port.h, shared_dictionary.h,
types.h) with the new release's files, record the version, commit and sha256 here, then run
`./build.sh test brotli`.
