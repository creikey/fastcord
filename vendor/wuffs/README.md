# Wuffs

JPEG decoding. `wuffs-v0.4.c` is upstream's single-file release, unmodified:

- Source: https://github.com/google/wuffs, `release/c/wuffs-v0.4.c` at commit
  4be865da258c4b5e6d3e716fd4f36be016496a46
- sha256: 458066457347bd6d9bc3c906aa8292bea4488577727569ddd9436fdd89d5f04d
- Licence: MIT or Apache-2.0 (LICENSE-MIT, LICENSE-APACHE)

Why Wuffs: its decoders are memory-safe by construction (the Wuffs compiler proves every bounds and
overflow check), never allocate, and cover progressive JPEG. stb_image is smaller but has a run of
memory-safety CVEs in its decoders (e.g. CVE-2022-28041, CVE-2023-45661..45667). The same file also has
PNG, GIF and WebP decoders, so later formats need only a new `WUFFS_CONFIG__MODULE__*` line.

`fc_wuffs.c` is ours: it compiles only the modules we use and exposes a few plain C calls where the caller
owns all memory. `build.sh` / `build.bat` compile it into `build/fc_wuffs.obj` (`.o` on macOS), which
`src/imagefmt/jpeg.odin` links.

To update: replace `wuffs-v0.4.c` with a newer release, record the commit and sha256 here, then run
`./build.sh test imagefmt` (its JPEG vectors are compared bit for bit against libjpeg's output).
