# Wuffs

PNG/APNG, GIF, JPEG and WebP decoding. `wuffs-v0.4.c` is upstream's single-file release, unmodified:

- Source: https://github.com/google/wuffs, `release/c/wuffs-v0.4.c` at commit
  4be865da258c4b5e6d3e716fd4f36be016496a46
- sha256: 458066457347bd6d9bc3c906aa8292bea4488577727569ddd9436fdd89d5f04d
- Licence: MIT or Apache-2.0 (LICENSE-MIT, LICENSE-APACHE)

Why Wuffs: its decoders are memory-safe by construction (the Wuffs compiler proves every bounds and
overflow check), never allocate, and cover progressive JPEG and APNG. stb_image is smaller but has a run
of memory-safety CVEs in its decoders (e.g. CVE-2022-28041, CVE-2023-45661..45667).

v0.4 decodes still WebP but not animated WebP, which Discord serves for stickers and animated avatars,
so `src/imagefmt/webp.jai` parses the animation container and gives Wuffs each frame as a still file.
Drop that when a Wuffs release animates WebP.

`fc_wuffs.c` is ours: it compiles only the modules we use and exposes a few plain C calls where the caller
owns all memory. `build.jai` compiles it into `build/fc_vendor.a`, which
`src/imagefmt/wuffs.jai` links.

To update: replace `wuffs-v0.4.c` with a newer release, record the commit and sha256 here, then run
`jai build.jai - test` (its vectors are compared against libjpeg, ImageMagick and ffmpeg output).
