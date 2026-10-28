// fastcord's build settings for WebRTC's sources, force-included by fc_webrtc.cflags: what upstream's
// meson.build passes as -D flags, picked per target here since one flags file serves every platform.
#pragma once
#if defined(_WIN32)
#define WEBRTC_WIN 1
#define NOMINMAX 1
#define _USE_MATH_DEFINES 1
#define WIN32_LEAN_AND_MEAN 1
// Upstream's Windows clock uses winmm's timeGetTime; fc_webrtc.cc supplies one instead.
#define WEBRTC_EXCLUDE_SYSTEM_TIME 1
#else
#define WEBRTC_POSIX 1
#if defined(__APPLE__)
#define WEBRTC_MAC 1
#else
#define WEBRTC_LINUX 1
#endif
#endif
#if defined(__aarch64__)
#define WEBRTC_ARCH_ARM64 1
#define WEBRTC_HAS_NEON 1
#elif defined(__x86_64__) || defined(_M_X64)
#define WEBRTC_ENABLE_AVX2 1
#endif
#define WEBRTC_APM_DEBUG_DUMP 0
#define RTC_DISABLE_METRICS 1
#define NDEBUG 1
