# libvpx

VP8 decoding and encoding for call and Go Live video (`src/media/decode_sw.jai` and
`src/video/encode_vp8.jai`, through `fc_libvpx.c`). Upstream's release files, unmodified: `LICENSE`,
`PATENTS`, `AUTHORS`, and the C sources and headers of `vp8/common`, `vp8/decoder`, `vp8/encoder`, `vp8/`
(the headers, `vp8_dx_iface.c` and `vp8_cx_iface.c`), `vpx`, `vpx_dsp`, `vpx_mem`, `vpx_ports`,
`vpx_scale` and `vpx_util`, without the per-CPU directories (`x86`, `arm`, `mips`, `ppc`, `loongarch`),
the VP9 code and the tests.

- Upstream: https://github.com/webmproject/libvpx v1.15.2
- Source: https://github.com/webmproject/libvpx/archive/refs/tags/v1.15.2.tar.gz
- sha256 of the tarball: 26fcd3db88045dee380e581862a6ef106f49b74b6396ee95c2993a260b4636aa
- Licence: BSD 3-clause (`LICENSE`), with Google's patent grant (`PATENTS`).

fastcord's files: `fc_libvpx.c` (the C interface: one frame in, its 4:2:0 picture out; an NV12 picture
in, deinterleaved to I420, one VP8 frame out), the files upstream's `configure` writes for
`--target=generic-gnu --disable-vp9 --enable-vp8-encoder --enable-vp8-decoder --disable-multithread --disable-postproc --disable-runtime-cpu-detect` (plus the
examples, tools, docs, tests, webm and libyuv turned off): `fc/vpx_config.h` (no `unistd.h` or
`pthread.h` on Windows), `fc/vpx_config.c`, `fc/vp8_rtcd.h`, `fc/vpx_dsp_rtcd.h`,
`fc/vpx_scale_rtcd.h` and `fc/vpx_version.h`; and the source list `fc_libvpx.sources` (what `make -n`
builds for that configuration) with its flags. Plain C is fast enough for a call's VP8 up to 720p30 (encoding takes about 17 ms a 720p frame on an M-series Mac).

To update: download the new release, run its `configure` with the flags above in a scratch directory and
`make vpx_dsp_rtcd.h vp8_rtcd.h vpx_scale_rtcd.h vpx_version.h`, copy those files into `fc/` (redoing the
Windows lines in `vpx_config.h`), replace the directories above, check the source list against
`make -n libvpx.a`, record the version and sha256 here, then run `jai build.jai - c`.
