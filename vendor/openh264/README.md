# openh264

H.264 encoding and decoding for Linux video calls (`src/video/encode_linux.jai`, `src/media/decode_linux.jai`);
macOS and Windows use the OS codecs, so `build.jai` builds this only for Linux (the `.linux` file). Upstream's
release files, unmodified: `LICENSE`, the public headers (`codec/api/wels`) and the C++ sources and headers
of `codec/common`, `codec/decoder`, `codec/encoder` and `codec/processing`, without the assembly
(`x86`, `arm*`, `mips`, `loongarch` directories) and `codec/encoder/plus/src/DllEntry.cpp` (Windows only).

- Upstream: https://github.com/cisco/openh264 v2.7.0
- Source: https://github.com/cisco/openh264/archive/refs/tags/v2.7.0.tar.gz
- sha256 of the tarball: 5178775c8b440073e70920e97d195efff721c0e56d0a78cc82c919e95d54924d
- Licence: BSD 2-clause (`LICENSE`). Building from source does not carry Cisco's H.264 patent licence, which
  covers only Cisco's own binaries.

fastcord's files: `fc_openh264.cpp` (the C interface), `fc/version_gen.h` (the header upstream's build
generates), and three source lists, since the decoder and the encoder have headers with the same names:
`fc_openh264_common` (common, processing and the wrapper), `fc_openh264_dec` and `fc_openh264_enc`, each with
its include paths in a `.cflags` file. Plain C++ without the assembly is fast enough for 720p30
(a few ms per frame).

To update: download the new release, replace the directories above (leaving out the same files), check the
source lists against `codec/*/targets.mk`, record the version and sha256 here, then run
`jai build.jai - c linux`.
