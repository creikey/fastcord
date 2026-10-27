// Audio output (a mixer of sources) and microphone capture, at 48 kHz f32.
// CoreAudio on macOS (darwin.jai), WASAPI on Windows (windows.jai), ALSA on Linux (linux.jai).

SAMPLE_RATE :: 48000;
CHANNELS :: 2; // output is interleaved stereo f32
MAX_SOURCES :: 64;
SOURCE_SECONDS :: 1; // ring capacity per source
CAPTURE_SECONDS :: 2;
OUTPUT_IDLE_STOP_SECONDS :: 2;

// SPSC ring of f32 samples. Capacity is a power of two.
Ring :: struct {
	buf: []float32;
	mask: u64;
	r: u64; // atomic; total samples read
	w: u64; // atomic; total samples written
}

ring_init :: (r: *Ring, min_capacity: int) {
	c := 1;
	while c < min_capacity c <<= 1;
	r.* = .{buf = NewArray(c, float32), mask = cast(u64) (c - 1)};
}

ring_destroy :: (r: *Ring) {
	array_free(r.buf);
	r.* = .{};
}

ring_readable :: inline (r: *Ring) -> int { return cast(int) (atomic_load(*r.w) - atomic_load(*r.r)); }
ring_writable :: inline (r: *Ring) -> int { return r.buf.count - cast(int) (atomic_load(*r.w) - atomic_load(*r.r)); }

// Producer side.
ring_write :: (r: *Ring, data: []float32) -> int {
	n := min(data.count, ring_writable(r));
	w := atomic_load(*r.w);
	for 0..n-1 r.buf[(w + cast(u64) it) & r.mask] = data[it];
	atomic_store(*r.w, w + cast(u64) n);
	return n;
}

// Consumer side.
ring_read :: (r: *Ring, out: []float32) -> int {
	n := min(out.count, ring_readable(r));
	rd := atomic_load(*r.r);
	for 0..n-1 out[it] = r.buf[(rd + cast(u64) it) & r.mask];
	atomic_store(*r.r, rd + cast(u64) n);
	return n;
}

// 0 = invalid; index+1 into the slot table.
Source :: u32;

// Opens the default output device (lazily started on first write).
// Returns false if no device; sources still work and can be pulled with mix().
init :: () -> bool {
	if st.initialized return st.device_ok;
	init_null();
	st.device_ok = device_init();
	return st.device_ok;
}

// No device at all: for tests. Pull audio with mix().
init_null :: () {
	if st.initialized return;
	st.ctx = context; // for the device callbacks, which run on CoreAudio's threads
	st.master_bits = f32_bits(1);
	for * st.slots ring_init(*it.ring, SAMPLE_RATE * CHANNELS * SOURCE_SECONDS);
	ring_init(*st.capture, SAMPLE_RATE * CAPTURE_SECONDS);
	st.initialized = true;
}

shutdown :: () {
	if !st.initialized return;
	if st.capturing capture_stop();
	if st.device_ok {
		locks.lock(*st.device_mu);
		device_shutdown();
		locks.unlock(*st.device_mu);
		while true { // wait for the watchdog to notice
			locks.lock(*st.device_mu);
			live := st.watchdog_live;
			locks.unlock(*st.device_mu);
			if !live break;
			sleep_milliseconds(10);
		}
		if st.watchdog_started thread_deinit(*st.watchdog);
	}
	for * st.slots ring_destroy(*it.ring);
	ring_destroy(*st.capture);
	st = .{};
}

// Seconds between a sample being mixed and it reaching the speaker (estimate).
output_latency :: () -> float64 { return st.latency; }

set_volume :: (v: float32) { atomic_store(*st.master_bits, f32_bits(max(v, 0))); }

source_create :: () -> Source {
	for * sl: st.slots {
		if sl.in_use continue;
		sl.in_use = true;
		atomic_store(*sl.played, 0);
		atomic_store(*sl.paused, 0);
		atomic_store(*sl.flush_req, 0);
		atomic_store(*sl.volume_bits, f32_bits(1));
		// Drop anything left from a previous user.
		atomic_store(*sl.ring.r, atomic_load(*sl.ring.w));
		atomic_store(*sl.active, 1);
		return cast(Source) (it_index + 1);
	}
	return 0;
}

source_destroy :: (s: Source) {
	sl := slot(s);
	if !sl return;
	atomic_store(*sl.active, 0);
	sl.in_use = false;
	// Ring memory is owned by the slot table and reused; the mixer may still be
	// reading it this callback, which is harmless.
}

// Write interleaved stereo f32 @48 kHz. Returns frames written (never blocks).
source_write :: (s: Source, frames: []float32) -> int {
	sl := slot(s);
	if !sl return 0;
	atomic_store(*st.idle_frames, 0);
	n := ring_write(*sl.ring, array_view(frames, 0, frames.count / CHANNELS * CHANNELS)) / CHANNELS;
	if n > 0 && st.device_ok && !atomic_load(*st.running) start_output();
	return n;
}

source_queued_frames :: (s: Source) -> int {
	sl := slot(s);
	if !sl return 0;
	q := cast(int) atomic_load(*sl.ring.w) - cast(int) max(atomic_load(*sl.ring.r), atomic_load(*sl.flush_req));
	return max(q, 0) / CHANNELS;
}

// Frames this source has delivered to the device since create / last flush.
source_played_frames :: (s: Source) -> u64 {
	sl := slot(s);
	return ifx sl then atomic_load(*sl.played);
}

source_set_volume :: (s: Source, v: float32) {
	sl := slot(s);
	if sl atomic_store(*sl.volume_bits, f32_bits(max(v, 0)));
}

source_set_paused :: (s: Source, paused: bool) {
	sl := slot(s);
	if sl atomic_store(*sl.paused, cast(u32) paused);
}

// Discard everything queued so far (seek). Writes after this call are kept.
// Resets played_frames to 0 once the mixer applies it.
source_flush :: (s: Source) {
	sl := slot(s);
	if !sl return;
	atomic_store(*sl.flush_req, atomic_load(*sl.ring.w));
	// No consumer running: apply directly (we're the only thread touching r now).
	if !st.running apply_flush(sl);
}

// Monotonic stream positions (frames). read_pos advances as the device consumes
// (and jumps forward on flush); write_pos as the producer writes. A producer
// that remembers write_pos when it starts a new segment can compute exactly
// how much of that segment has been played: read_pos - mark.
source_read_pos :: (s: Source) -> u64 {
	sl := slot(s);
	return ifx sl then atomic_load(*sl.ring.r) / CHANNELS;
}

source_write_pos :: (s: Source) -> u64 {
	sl := slot(s);
	return ifx sl then atomic_load(*sl.ring.w) / CHANNELS;
}

// Kept for API compatibility; idle shutdown is automatic.
update :: () {}

// The mixer. Called on the device thread (or by tests with init_null).
// out: interleaved stereo f32, count = frames*2.
mix :: (out: []float32) {
	memset(out.data, 0, out.count * size_of(float32));
	frames := out.count / CHANNELS;
	any_data := false;
	master := bits_f32(atomic_load(*st.master_bits));
	for * sl: st.slots {
		if atomic_load(*sl.active) == 0 continue;
		if atomic_load(*sl.flush_req) != 0 apply_flush(sl);
		if atomic_load(*sl.paused) != 0 continue;
		vol := bits_f32(atomic_load(*sl.volume_bits)) * master;
		r := *sl.ring;
		n := min(ring_readable(r), frames * CHANNELS);
		if n == 0 continue;
		any_data = true;
		rd := atomic_load(*r.r);
		for 0..n-1 out[it] += r.buf[(rd + cast(u64) it) & r.mask] * vol;
		atomic_store(*r.r, rd + cast(u64) n);
		atomic_add(*sl.played, cast(u64) (n / CHANNELS));
	}
	// Clip to avoid harsh wraparound when sources sum > 1.
	for * out it.* = clamp(it.*, -1, 1);
	if any_data atomic_store(*st.idle_frames, 0);
	else atomic_add(*st.idle_frames, cast(u64) frames);
}

// Capture (mono f32 @48 kHz).
// voice_processing: macOS VoiceProcessingIO (echo cancellation, AGC, noise
// suppression); output is routed through the same unit so the canceller hears it.
// Without it (the settings mic meter) macOS opens only the input device, at its own
// rate, so other apps aren't ducked and Bluetooth headsets stay in A2DP. A
// voice-processing start replaces a running plain capture.
capture_start :: (voice_processing := true) -> bool {
	if !st.device_ok return false;
	if st.capturing && (st.capture_vp || !voice_processing) return true;
	if st.capturing capture_stop();
	st.capture_vp = voice_processing;
	atomic_store(*st.capture.r, atomic_load(*st.capture.w));
	locks.lock(*st.device_mu);
	st.capturing = device_capture_start(voice_processing);
	locks.unlock(*st.device_mu);
	return st.capturing;
}

capture_stop :: () {
	if !st.capturing return;
	locks.lock(*st.device_mu);
	device_capture_stop();
	locks.unlock(*st.device_mu);
	st.capturing = false;
}

capture_available :: () -> int { return ring_readable(*st.capture); }

// Read captured mono samples. Use 480 (10 ms) / 960 (20 ms) frames for Opus.
capture_read :: (out: []float32) -> int { return ring_read(*st.capture, out); }

// Convert interleaved PCM with `ch` channels to stereo, appending to out.
to_stereo :: (out: *[..]float32, src: []float32, ch: int) {
	if ch == {
	case 1;
		for src array_add(out, it, it);
	case 2;
		array_add(out, ..src);
	case;
		for f: 0..src.count / max(ch, 1) - 1 array_add(out, src[f * ch], src[f * ch + 1]);
	}
}

#scope_module

#import "Basic";
#import "Atomics";
#import "Thread";
#import "String";
locks :: #import "locks";

#if OS == .MACOS #load "darwin.jai";
#if OS == .WINDOWS #load "windows.jai";
#if OS == .LINUX #load "linux.jai";

Slot :: struct {
	ring: Ring;
	in_use: bool; // main-thread bookkeeping
	active: u32; // atomic bool read by the mixer
	paused: u32; // atomic bool
	volume_bits: u32; // atomic f32
	played: u64; // atomic: frames consumed by the device since create/flush
	flush_req: u64; // atomic: writer's w position to drop up to (0 = none)
}

State :: struct {
	initialized: bool;
	device_ok: bool;
	running: bool; // output unit started
	slots: [MAX_SOURCES]Slot;
	master_bits: u32; // atomic f32
	idle_frames: u64; // atomic, frames mixed with no source data
	capture: Ring;
	capturing: bool;
	capture_vp: bool; // the running capture has voice processing
	ctx: #Context;
	latency: float64;
	device_mu: locks.Mutex; // start/stop
	watchdog: Thread;
	watchdog_started: bool; // watchdog was initialised (needs thread_deinit)
	watchdog_live: bool; // under device_mu
}

st: State;

f32_bits :: inline (f: float32) -> u32 { return (cast(*u32) *f).*; }
bits_f32 :: inline (b: u32) -> float32 { return (cast(*float32) *b).*; }

slot :: (s: Source) -> *Slot {
	if s == 0 || s > MAX_SOURCES return null;
	sl := *st.slots[s - 1];
	return ifx sl.in_use then sl;
}

apply_flush :: (sl: *Slot) {
	f := atomic_exchange(*sl.flush_req, 0);
	if f == 0 return;
	if atomic_load(*sl.ring.r) < f atomic_store(*sl.ring.r, f);
	atomic_store(*sl.played, 0);
}

start_output :: () {
	locks.lock(*st.device_mu);
	defer locks.unlock(*st.device_mu);
	if st.running return;
	atomic_store(*st.idle_frames, 0);
	device_start();
	if st.running && !st.watchdog_live {
		if st.watchdog_started thread_deinit(*st.watchdog); // the previous one has returned
		thread_init(*st.watchdog, watchdog);
		thread_start(*st.watchdog);
		st.watchdog_started = true;
		st.watchdog_live = true;
	}
}

// Stops the output device after OUTPUT_IDLE_STOP_SECONDS without source data.
watchdog :: (t: *Thread) -> s64 {
	while true {
		sleep_milliseconds(500);
		locks.lock(*st.device_mu);
		idle := !st.capturing && atomic_load(*st.idle_frames) > OUTPUT_IDLE_STOP_SECONDS * SAMPLE_RATE;
		if idle device_stop();
		if !st.running {
			st.watchdog_live = false;
			locks.unlock(*st.device_mu);
			return 0;
		}
		locks.unlock(*st.device_mu);
	}
	return 0;
}
