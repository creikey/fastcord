# dav1d

AV1 decoding for call and Go Live video (`src/media/decode_sw.jai`, through `fc_dav1d.c`). Upstream's
release files, unmodified: `COPYING`, the headers under `include/` and the C sources and headers of `src/`,
without the assembly and per-CPU directories (`arm`, `x86`, `ppc`, `riscv`, `loongarch`, `ext`) and the
meson files.

- Upstream: https://code.videolan.org/videolan/dav1d 1.5.1
- Source: https://code.videolan.org/videolan/dav1d/-/archive/1.5.1/dav1d-1.5.1.tar.gz
- sha256 of the tarball: fa635e2bdb25147b1384007c83e15de44c589582bb3b9a53fc1579cb9d74b695
- Licence: BSD 2-clause (`COPYING`).

fastcord's files: `fc_dav1d.c` (the C interface: one temporal unit in, 8-bit 4:2:0 pictures out),
`fc/config.h` and `fc/vcs_version.h` (the headers meson generates: plain C, no assembly, 8 bits per
component only), `fc/bitdepth8/*8.c` (each `*_tmpl.c` built for 8 bits, as meson does with
`-DBITDEPTH=8`), and the source list `fc_dav1d.sources` with its flags. Plain C decodes 720p in a few
milliseconds per frame with dav1d's own threads.

To update: download the new release, replace `include/` and `src/` (leaving out the same directories),
check `fc_dav1d.sources` against `src/meson.build`, record the version and sha256 here, then run
`jai build.jai - c`.
