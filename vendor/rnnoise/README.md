# RNNoise

Noise suppression on the mic in calls (Voice & Video > Noise Suppression), on every platform. `include/`
and `src/` are upstream's files, unmodified (only the library's sources and the headers they include; the
training and dump tools are left out):

- Upstream: https://github.com/xiph/rnnoise v0.2
- Source: https://github.com/xiph/rnnoise, release v0.2, `rnnoise-0.2.tar.gz`
- sha256 (tarball): 90fce4b00b9ff24c08dbfe31b82ffd43bae383d85c5535676d28b0a2b11c0d37
- Licence: BSD 3-clause (COPYING)

Why RNNoise: Xiph's small recurrent network (the Opus authors), C with no dependencies, the model compiled
in (`src/rnnoise_data.c`), about 1% of a core per call. Krisp, the official client's suppressor, is a
proprietary SDK.

The v0.2 tarball lacks `os_support.h`, which `src/vec_neon.h` includes; it is the same Xiph header Opus
ships, so `fc_rnnoise.cflags` takes it from `vendor/opus/celt`.

`fc_rnnoise.c` is ours: create, destroy and an in-place 10 ms frame at f32 scale. `fc_rnnoise.sources`
lists upstream's library files; `build.jai` compiles them into `build/fc_vendor.a`.
