// Upstream's matched_filter_avx2.cc reads vector lanes MSVC's way (`v.m256_f32[i]`) whenever _MSC_VER is
// set, and zig's clang sets it on Windows but has no such members. Its includes go first with _MSC_VER
// intact, so only the file's own lane macros see it unset.
#include <immintrin.h>

#include "modules/audio_processing/aec3/matched_filter.h"
#include "rtc_base/checks.h"

#pragma push_macro("_MSC_VER")
#undef _MSC_VER
#include "modules/audio_processing/aec3/matched_filter_avx2.cc"
#pragma pop_macro("_MSC_VER")
