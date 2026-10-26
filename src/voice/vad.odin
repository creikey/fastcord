package voice

import "core:math"

// Voice activity detection with the official client's default settings
// (MediaEngineStore defaults: mode VOICE_ACTIVITY, threshold -60 dB,
// autoThreshold on for desktop, vadLeading 5, vadTrailing 25 frames).
//
// Manual mode: speech when frame level > threshold_db.
// Auto mode: noise floor = minimum frame level over the last 2 s (minimum
// statistics; digital silence below -100 dBFS is ignored, e.g. VPIO warm-up),
// speech when the level clears floor + AUTO_MARGIN_DB (never below the manual
// -60 dB threshold, never above AUTO_CEILING_DB).
// Trailing: activity holds for `trailing` frames after the last speech frame.
// Leading: the sender keeps `leading` frames of pre-roll that are flushed
// when speech starts, so word onsets are not clipped.

VAD_DEFAULT_THRESHOLD :: -60.0
VAD_DEFAULT_LEADING :: 5
VAD_DEFAULT_TRAILING :: 25
AUTO_MARGIN_DB :: 12.0
AUTO_CEILING_DB :: -30.0
NOISE_WINDOW :: 100 // frames (2 s)

Vad :: struct {
	auto_threshold: bool,
	threshold_db:   f32,
	leading:        int,
	trailing:       int,
	noise_db:       f32,
	hang:           int,
	active:         bool,
	primed:         bool,
	history:        [NOISE_WINDOW]f32,
	hist_n:         int,
	hist_i:         int,
}

vad_init :: proc(v: ^Vad) {
	v^ = Vad {
		auto_threshold = true,
		threshold_db   = VAD_DEFAULT_THRESHOLD,
		leading        = VAD_DEFAULT_LEADING,
		trailing       = VAD_DEFAULT_TRAILING,
		noise_db       = -70,
	}
}

frame_level_db :: proc(pcm: []f32) -> f32 {
	if len(pcm) == 0 do return -127
	acc: f64 = 0
	for s in pcm do acc += f64(s) * f64(s)
	rms := math.sqrt(acc / f64(len(pcm)))
	return f32(20 * math.log10(rms + 1e-9))
}

// audio level for the RTP ssrc-audio-level extension: 0..127 = -dBov.
audio_level_byte :: proc(db: f32) -> u8 {
	return u8(clamp(-db, 0, 127))
}

vad_process :: proc(v: ^Vad, pcm: []f32) -> (active: bool, db: f32) {
	db = frame_level_db(pcm)
	thresh := v.threshold_db
	if v.auto_threshold {
		if db > -100 {
			v.history[v.hist_i] = db
			v.hist_i = (v.hist_i + 1) % NOISE_WINDOW
			v.hist_n = min(v.hist_n + 1, NOISE_WINDOW)
			m := v.history[0]
			for i in 0 ..< v.hist_n do m = min(m, v.history[i])
			v.noise_db = m
			v.primed = true
		}
		thresh = clamp(v.noise_db + AUTO_MARGIN_DB, VAD_DEFAULT_THRESHOLD, AUTO_CEILING_DB)
	}
	if db > thresh {
		v.hang = v.trailing
		v.active = true
	} else if v.hang > 0 {
		v.hang -= 1
	} else {
		v.active = false
	}
	return v.active, db
}
