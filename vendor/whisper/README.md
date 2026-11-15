# whisper.cpp

Local speech-to-text for call transcription (`src/stt`, `src/app/transcribe.jai`): OpenAI's Whisper and
NVIDIA's Parakeet TDT, run on the CPU through ggml. Upstream files, unmodified:

- `include/whisper.h`, `include/parakeet.h`, `src/whisper.cpp`, `src/whisper-arch.h`, `src/parakeet.cpp`,
  `src/parakeet-arch.h`, `src/aneforge/*` (Apple Neural Engine hooks; stubs elsewhere, and only reached
  when `ANEFORGE_ENCODER` is set).
- `ggml/include/*.h`, and from `ggml/src/` the core (`ggml.c`, `ggml.cpp`, `ggml-alloc.c`, `ggml-quants.*`,
  `ggml-backend*.cpp`, `ggml-opt.cpp`, `ggml-threading.*`, `gguf.cpp` and their headers) and the CPU
  backend `ggml-cpu/` (with `amx/`, `tiled/`, `llamafile/` and `arch/x86`, `arch/arm`).
- `LICENSE`.

- Upstream: https://github.com/ggml-org/whisper.cpp v1.9.5 (ggml 0.26.0)
- Source: `archive/refs/tags/v1.9.5.tar.gz`
- sha256 of the tarball: ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720
- Licence: MIT (`LICENSE`).

Why: it is the reference C/C++ runtime for both models, CPU-only with no other dependency, and runs a
call's speech several times faster than real time on a laptop (TRANSCRIPTION.md).

Ours: `fc_whisper.c` (a CPU check, load, one utterance to text, free; bound in `src/stt`),
`fc_whisper.sources` (the files built), `fc_whisper.cflags`, and `fc_shim/` (`ggml-version.h` and the
version defines CMake would generate). On x86-64 the `simd` and `x86` lines in `fc_whisper.sources` are
built for x86-64-v3 (AVX2, FMA, F16C, BMI2), so `fc_stt_cpu_ok` checks the CPU before anything calls them;
`arm` lines are built only on arm64. Only the CPU backend is built: no GPU, no dynamic backend loading.

Models are not vendored: the app downloads one pinned file (URL, size and sha256 in `transcribe.jai`) on
first use, and never loads any other.

To update: replace the files above with the new release's (same subset), regenerate `fc_shim/ggml-version.h`
from `ggml/CMakeLists.txt`'s version, add any new files `src/CMakeLists.txt` and `ggml/src/CMakeLists.txt`
list for the whisper, parakeet, ggml-base and ggml-cpu targets, record the version and sha256 here, then
build and run `- test stt`.
