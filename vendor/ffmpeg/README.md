# FFmpeg (AAC decoder only)

AAC decoding on Linux (video soundtracks, .m4a), as Chrome and the official client do it: FFmpeg's native
AAC decoder (AAC-LC, HE-AAC with SBR, HE-AAC v2 with PS, xHE-AAC/USAC), in C only. macOS uses AudioToolbox
and Windows Media Foundation instead. Upstream files, unmodified: only the `libavcodec/` and `libavutil/`
sources and headers that the `aac` and `aac_latm` decoders and the `avcodec_send_packet` API compile from,
`compat/va_copy.h`, and `COPYING.LGPLv2.1`.

- Upstream: https://github.com/FFmpeg/FFmpeg n9.0.2
- Source: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
- sha256 of the tarball: 8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
- Licence: LGPL-2.1-or-later (`COPYING.LGPLv2.1`). No GPL or nonfree part is enabled.

Because it is LGPL, it is never linked into fastcord's binary: build.jai links these files (the `.shared`
marker) into `build/libfc_aac.so`, the Linux release ships it beside `fastcord`, and the app opens it with
`dlopen` (`src/media/decode_linux.jai`). Without it AAC is unsupported and plays silent. Anyone can build
their own from these files or any FFmpeg with the same three `fc_aac_*` procedures and replace it.

fastcord's files:
- `fc_aac.c`: the C interface (open with an AudioSpecificConfig, or none for ADTS; one packet in,
  interleaved float out; close), every size checked. Only its `fc_aac_*` procedures are exported.
- `fc_aac.sources` and `fc_aac.cflags`: the files built and their flags.
- `fc_config/`: what `configure` generates (`config.h`, `config_components.h`, `libavutil/avconfig.h`,
  `libavcodec/codec_list.c`, `libavcodec/bsf_list.c`), from

      ./configure --enable-cross-compile --target-os=linux --arch=x86_64 --cc='zig cc -target x86_64-linux-gnu.2.17' \
          --disable-everything --enable-decoder=aac,aac_latm --disable-asm --disable-programs --disable-doc \
          --disable-avformat --disable-avdevice --disable-avfilter --disable-swresample --disable-swscale \
          --disable-network --disable-autodetect --disable-iconv --disable-zlib --disable-runtime-cpudetect --enable-pic

  with three edits to `config.h`: `HAVE_SYSCTL 0` (zig's glibc headers have no `sys/sysctl.h`),
  `HAVE_INLINE_ASM 0`, and the configure line and `CC_IDENT` without local paths.

To update: unpack a newer release, run the configure line above in an empty directory and `make`, then
take the archive members a link of `fc_aac.o` against `libavcodec.a` and `libavutil.a` pulls in, and the
files their `.d` dependency files name. Copy those over, refresh `fc_config/` and `fc_aac.sources`, record
the version and sha256 here, then build `jai build.jai - dev linux` and run `src/tests/aac.jai` on Linux.
