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

VAD_DEFAULT_THRESHOLD :: -60.0;
VAD_DEFAULT_LEADING :: 5;
VAD_DEFAULT_TRAILING :: 25;
AUTO_MARGIN_DB :: 12.0;
AUTO_CEILING_DB :: -30.0;
NOISE_WINDOW :: 100;  // frames (2 s)

Vad :: struct {
    auto_threshold := true;
    threshold_db: float32 = VAD_DEFAULT_THRESHOLD;
    leading := VAD_DEFAULT_LEADING;
    trailing := VAD_DEFAULT_TRAILING;
    noise_db: float32 = -70;
    hang: int;
    active: bool;
    primed: bool;
    history: [NOISE_WINDOW]float32;
    hist_n: int;
    hist_i: int;
}

vad_init :: (v: *Vad) { v.* = .{}; }

frame_level_db :: (pcm: []float32) -> float32 {
    if !pcm.count return -127;
    acc: float64;
    for pcm { x := cast(float64) it; acc += x * x; }
    return cast(float32) (20 * log(sqrt(acc / pcm.count) + 0.000000001) / log(10.0));
}

// Software AGC (Voice Processing > Automatic Gain Control): follows the level of speech
// (frames above AGC_FLOOR_DB, fast up, slow down) and eases a gain of 0..AGC_MAX_GAIN_DB toward
// AGC_TARGET_DB, capped so no frame clips.
AGC_TARGET_DB :: -24.0;
AGC_MAX_GAIN_DB :: 18.0;
AGC_FLOOR_DB :: -55.0;

Agc :: struct {
    level_db: float32 = AGC_TARGET_DB;
    gain_db: float32;
}

agc_process :: (a: *Agc, pcm: []float32) {
    db := frame_level_db(pcm);
    if db > AGC_FLOOR_DB a.level_db += (db - a.level_db) * ifx db > a.level_db then 0.1 else 0.01;
    a.gain_db += (clamp(AGC_TARGET_DB - a.level_db, 0, AGC_MAX_GAIN_DB) - a.gain_db) * 0.05;
    g := pow(10.0, a.gain_db / 20);
    peak: float32;
    for pcm peak = max(peak, abs(it));
    if peak * g > 0.98 g = 0.98 / peak;
    for * pcm it.* *= g;
}

// audio level for the RTP ssrc-audio-level extension: 0..127 = -dBov.
audio_level_byte :: (db: float32) -> u8 { return cast(u8) clamp(-db, 0, 127); }

vad_process :: (v: *Vad, pcm: []float32) -> active: bool, db: float32 {
    db := frame_level_db(pcm);
    thresh := v.threshold_db;
    if v.auto_threshold {
        if db > -100 {
            v.history[v.hist_i] = db;
            v.hist_i = (v.hist_i + 1) % NOISE_WINDOW;
            v.hist_n = min(v.hist_n + 1, NOISE_WINDOW);
            m := v.history[0];
            for 0..v.hist_n-1 m = min(m, v.history[it]);
            v.noise_db = m;
            v.primed = true;
        }
        thresh = clamp(v.noise_db + AUTO_MARGIN_DB, VAD_DEFAULT_THRESHOLD, AUTO_CEILING_DB);
    }
    if db > thresh {
        v.hang = v.trailing;
        v.active = true;
    } else if v.hang > 0 {
        v.hang -= 1;
    } else {
        v.active = false;
    }
    return v.active, db;
}
