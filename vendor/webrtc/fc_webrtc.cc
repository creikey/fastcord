// fastcord's translation unit for WebRTC's echo canceller (AEC3): 480-sample (10 ms) frames of mono
// 48 kHz f32 in [-1, 1], the steps AudioProcessingImpl runs around it (high-pass, band split) and
// nothing else. Bound in src/voice/conn.jai.

#include "modules/audio_processing/aec3/echo_canceller3.h"
#include "modules/audio_processing/audio_buffer.h"
#include "modules/audio_processing/high_pass_filter.h"

#if defined(WEBRTC_EXCLUDE_SYSTEM_TIME)
#include <chrono>
#include "rtc_base/system_time.h"

int64_t rtc::SystemTimeNanos() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
#endif

using namespace webrtc;

namespace {
const int kRate = 48000;
struct Aec {
    EchoCanceller3 aec{EchoCanceller3Config(), std::nullopt, kRate, 1, 1};
    HighPassFilter hpf{kRate, 1};
    AudioBuffer render{kRate, 1, kRate, 1, kRate, 1};
    AudioBuffer capture{kRate, 1, kRate, 1, kRate, 1};
};
const StreamConfig kStream(kRate, 1);
}

extern "C" {

void *fc_aec_create(void) { return new Aec(); }

void fc_aec_destroy(void *a) { delete (Aec *) a; }

// One frame of what the speakers played.
void fc_aec_render(void *p, const float *pcm) {
    Aec *a = (Aec *) p;
    a->render.CopyFrom(&pcm, kStream);
    a->render.SplitIntoFrequencyBands();
    a->aec.AnalyzeRender(&a->render);
}

// One mic frame, echo removed in place.
void fc_aec_capture(void *p, float *pcm) {
    Aec *a = (Aec *) p;
    a->capture.CopyFrom(&pcm, kStream);
    a->hpf.Process(&a->capture, false);
    a->aec.AnalyzeCapture(&a->capture);
    a->capture.SplitIntoFrequencyBands();
    a->aec.ProcessCapture(&a->capture, false);
    a->capture.MergeFrequencyBands();
    a->capture.CopyTo(kStream, &pcm);
}

}
