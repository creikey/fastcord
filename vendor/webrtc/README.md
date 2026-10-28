# WebRTC echo canceller (AEC3)

Echo cancellation on the mic in calls (Voice & Video > Echo Cancellation), on every platform: the canceller
the official client's voice engine uses too. Only AEC3 and what it needs are vendored, upstream's files
unmodified at their upstream paths:

- WebRTC's audio processing as packaged by PulseAudio: https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz
  - sha256: ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe
  - Licence: BSD 3-clause (LICENSE, PATENTS)
- Abseil (`absl/`, the few headers and string sources WebRTC uses): https://github.com/abseil/abseil-cpp/releases/download/20240722.0/abseil-cpp-20240722.0.tar.gz
  - sha256: f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3
  - Licence: Apache 2.0 (absl/LICENSE)

The file set is AEC3's `#include` closure (about 120 sources, 300 files with headers, 2.6 MB). The rest of the audio processing
module (its noise suppressor, AGCs, the AudioProcessing front end) is left out: noise suppression is
RNNoise (`vendor/rnnoise`), AGC is `src/voice/vad.jai`.

Ours:
- `fc_webrtc.cc`: create, destroy, feed 10 ms of what the speakers played, cancel the echo in 10 ms of mic,
  with the high-pass filter and band split AudioProcessingImpl runs around AEC3. On Windows it also supplies
  `rtc::SystemTimeNanos`, so upstream's clock doesn't pull in winmm.
- `fc_webrtc_config.h`: upstream's meson `-D` flags, chosen per target, force-included by `fc_webrtc.cflags`.
- `fc_matched_filter_avx2.cc`: builds upstream's `matched_filter_avx2.cc` with `_MSC_VER` unset, since zig's
  clang sets it on Windows but lacks MSVC's `m256_f32` vector members.
- `fc_shim/`: `pthread_spis.h` and `CoreServices/CoreServices.h`, which WebRTC's macOS code includes and
  zig's macOS headers lack; each supplies only the names WebRTC uses.
- `fc_webrtc.sources`: the files `build.jai` compiles into `build/fc_vendor.a`. The `_neon`, `_sse`,
  `_sse2` and `_avx2` files are built only for their architecture (`_avx2` with `-mavx2 -mfma`, as
  upstream); WebRTC picks AVX2 at run time.
