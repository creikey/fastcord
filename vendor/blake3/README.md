# BLAKE3

The hash behind identity roots (`src/keys`) and, later, content addresses. Upstream's C implementation,
unmodified: `c/blake3.c`, `blake3.h`, `blake3_impl.h`, `blake3_dispatch.c`, `blake3_portable.c` and the
SSE2, SSE4.1, AVX2, AVX-512 and NEON intrinsics files, plus the licence files.

- Upstream: https://github.com/BLAKE3-team/BLAKE3 1.8.7
- Source: https://github.com/BLAKE3-team/BLAKE3/releases/tag/1.8.7, `archive/refs/tags/1.8.7.tar.gz`
  (tag commit f3149ec5bb5449af877ba20377a11008ff499fa2)
- sha256 of the tarball: c6782a28842b1c0478524ac06a4f2ede784038ee298d6e2162c0b089c4306a3c
- Licence: CC0-1.0, Apache-2.0 or Apache-2.0 with LLVM exceptions (LICENSE_*); we take CC0.

Why: it is the reference implementation, with run-time SIMD dispatch.

`fc_blake3.c` is ours: one-shot hashing and derive_key, bound in `src/crypto`. `fc_blake3.sources` lists
the library files. Upstream's intrinsics files don't guard themselves by architecture, so each is built
through `simd/`, which includes it only on the matching CPU; `build.jai` adds the `-m` flags by file name.

To update: replace `c/` with the new release's files (same subset), record the version, commit and
sha256 here, then build and run `src/tests/keys.jai`.
