# libjpeg-turbo (encoder only)

JPEG encoding for our Go Live stream's preview (`src/imagefmt/jpeg.jai`, used by `src/app/video_call.jai`
`preview_take`). It is the library Chrome's `canvas.toDataURL("image/jpeg")` runs (through Skia), which is how
the official client makes the thumbnail. Upstream files, unmodified: the compression sources of
`JPEG_SOURCES` in upstream's `CMakeLists.txt` (`src/jc*.c`, their `src/wrapper/*-{8,12,16}.c` builds, `jdatadst.c`,
`jerror.c`, `jfdct*.c`, `jmem*.c`, `jpeg_nbits.c`, `jutils.c`, `jstdhuff.c`), the headers they include
(`src/*.h`, `simd/jsimd.h`, `simd/jsimddct.h`), `LICENSE.md` and `README.ijg`. No decoder, SIMD, arithmetic
coding, TurboJPEG API, tools or build files: decoding stays with Wuffs, and a 512 x 288 thumbnail every five
minutes needs no SIMD (the C code's output is the same).

- Upstream: https://github.com/libjpeg-turbo/libjpeg-turbo 3.2.0
- Source: https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz
- sha256 of the tarball: 6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e
  (the same as Homebrew's `jpeg-turbo` 3.2.0 formula)
- Licence: IJG and BSD-3-Clause (`LICENSE.md`, `README.ijg`).

fastcord's files:
- `fc_libjpeg_turbo.c`: one call that encodes RGB at a quality as Skia's `SkJpegEncoder` does
  (`jpeg_set_defaults`, `jpeg_set_quality(q, TRUE)`, 4:2:0), with libjpeg's errors turned into a return
  instead of `exit()`.
- `fc_libjpeg_turbo.sources` and `fc_libjpeg_turbo.cflags`: the files built (into `build/fc_vendor.a`) and
  the include paths.
- `fc_config/`: what CMake generates from `src/jconfig.h.in`, `src/jconfigint.h.in` and `src/jversion.h.in`
  (also kept in `src/`) for the default build (`JPEG_LIB_VERSION` 62) with `WITH_SIMD`,
  `C_ARITH_CODING_SUPPORTED` and `D_ARITH_CODING_SUPPORTED` off and `SIZEOF_SIZE_T` 8.

To update: unpack the new release, copy the same files over (check `JPEG_SOURCES` for new compression
files), redo `fc_config/` from the `.in` templates, record the version and sha256 here, then build
`jai build.jai - dev` and run `src/tests/video_call.jai` (it checks a preview's JPEG).
