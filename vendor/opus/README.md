# libopus

Voice encoding and decoding. Upstream files, unmodified:

- Upstream: https://github.com/xiph/opus v1.6.1
- Source: https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz
- sha256: 6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
- Licence: BSD-3-Clause (COPYING)

Why libopus: it is the reference implementation (RFC 6716), continuously fuzzed by OSS-Fuzz, and what
browsers and Discord's own client use. Peers' packets reach us end-to-end encrypted, so nothing upstream
filters them: the decoder must be the most-tested one there is.

Only the float build's files are kept: `include/`, `celt/`, `silk/`, `silk/float/` and the `src/` files
the single-stream codec needs (no SIMD, DNN, multistream or demo code). `fc_opus.c` compiles them as one
translation unit with the flags in `fc_opus.cflags` (`ENABLE_HARDENING` is upstream's default) and adds a
non-variadic ctl wrapper. `src/opus/opus.jai` binds it.

To update: unpack a newer release, copy the same directories over (check `celt_sources.mk`,
`silk_sources.mk` and `opus_sources.mk` for added files and mirror them in `fc_opus.c`), record the
version and sha256 here, then run `jai build.jai - test`.
