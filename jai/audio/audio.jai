SAMPLE_RATE :: 48000;
CHANNELS :: 2; // output is interleaved stereo f32
MAX_SOURCES :: 64;
SOURCE_SECONDS :: 1; // ring capacity per source
CAPTURE_SECONDS :: 2;
OUTPUT_IDLE_STOP :: 2.0;

// ---------------------------------------------------------------------------
// SPSC ring of f32 samples. Capacity is a power of two.

Ring :: struct {
	buf: []float32;
	mask: u64;
	r: u64; // atomic; total samples read
	w: u64; // atomic; total samples written
}

ring_init :: (r: *Ring, min_capacity: int, allocator := context.allocator) {
	c := 1;
	while c < min_capacity { c <<= 1; }
	r.buf = make_slice(float32, c, allocator);
	r.mask = cast(u64)(c - 1);
	r.r = 0;
	r.w = 0;
}

ring_destroy :: (r: *Ring, allocator := context.allocator) {
	delete(r.buf, allocator);
	r.* = .{};
}

ring_readable :: inline (r: *Ring) -> int {
	return cast(int)(sync.atomic_load_explicit(*r.w, .Acquire) - sync.atomic_load_explicit(*r.r, .Relaxed));
}

ring_writable :: inline (r: *Ring) -> int {
	return len(r.buf) - cast(int)(sync.atomic_load_explicit(*r.w, .Relaxed) - sync.atomic_load_explicit(*r.r, .Acquire));
}

// Producer side.
ring_write :: (r: *Ring, data: []float32) -> int {
	n := min(len(data), ring_writable(r));
	w := sync.atomic_load_explicit(*r.w, .Relaxed);
	for i: 0..cast(int)(n)-1 { r.buf[(w + cast(u64)(i)) & r.mask] = data[i]; }
	sync.atomic_store_explicit(*r.w, w + cast(u64)(n), .Release);
	return n;
}

// Consumer side.
ring_read :: (r: *Ring, out: []float32) -> int {
	n := min(len(out), ring_readable(r));
	rd := sync.atomic_load_explicit(*r.r, .Relaxed);
	for i: 0..cast(int)(n)-1 { at(*out, i).* = r.buf[(rd + cast(u64)(i)) & r.mask]; }
	sync.atomic_store_explicit(*r.r, rd + cast(u64)(n), .Release);
	return n;
}

// ---------------------------------------------------------------------------
// Sources

Source :: u32;
#scope_module // 0 = invalid; index+1 into the slot table

Slot :: struct {
	ring: Ring;
	in_use: bool; // main-thread bookkeeping
	active: u32; // atomic bool read by the mixer
	paused: u32; // atomic bool
	volume_bits: u32; // atomic f32
	played: u64; // atomic: frames consumed by the device since create/flush
	flush_req: u64; // atomic: writer's w position to drop up to (0 = none)
}
#scope_module

State :: struct {
	initialized: bool;
	device_ok: bool;
	running: bool; // output unit started
	slots: [MAX_SOURCES]Slot;
	master_bits: u32; // atomic f32
	muted: u32;
	idle_frames: u64; // atomic, frames mixed with no source data
	mix_scratch: []float32;
	capture: Ring;
	capturing: bool;
	voice_proc: bool;
	ctx: type_of(context);
	latency: float64;
	device_mu: locks.Mutex; // start/stop
	watchdog: *thread.Thread;
	callbacks: u64; // atomic, device callbacks (diagnostics)
	frames_out: u64; // atomic, frames rendered (diagnostics)
}

st: State;
#scope_export

f32_bits :: inline (f: float32) -> u32 {return transmute(u32, f);}
bits_f32 :: inline (b: u32) -> float32 {return transmute(float32, b);}

// Opens the default output device (lazily started on first write).
// Returns false if no device; sources still work and can be pulled with mix().
init :: () -> bool {
	if st.initialized { return st.device_ok; }
	st.ctx = context;
	st.master_bits = f32_bits(1);
	st.mix_scratch = make_slice(float32, 8192 * CHANNELS);
	for * sl: st.slots {
		ring_init(*sl.ring, SAMPLE_RATE * CHANNELS * SOURCE_SECONDS);
	}
	ring_init(*st.capture, SAMPLE_RATE * CAPTURE_SECONDS);
	st.initialized = true;
	st.device_ok = _device_init();
	return st.device_ok;
}

// No device at all: for tests. Pull audio with mix().
init_null :: () {
	if st.initialized { return; }
	st.ctx = context;
	st.master_bits = f32_bits(1);
	st.mix_scratch = make_slice(float32, 8192 * CHANNELS);
	for * sl: st.slots { ring_init(*sl.ring, SAMPLE_RATE * CHANNELS * SOURCE_SECONDS); }
	ring_init(*st.capture, SAMPLE_RATE * CAPTURE_SECONDS);
	st.initialized = true;
	st.device_ok = false;
}

shutdown :: () {
	if !st.initialized { return; }
	if st.capturing { capture_stop(); }
	if st.device_ok {
		locks.lock(*st.device_mu);
		_device_shutdown();
		locks.unlock(*st.device_mu);
		while true {
			// wait for the watchdog to notice
			locks.lock(*st.device_mu);
			w := st.watchdog;
			locks.unlock(*st.device_mu);
			if w == null { break; }
			time.sleep(10 * time.Millisecond);
		}
	}
	for * sl: st.slots { ring_destroy(*sl.ring); }
	ring_destroy(*st.capture);
	delete(st.mix_scratch);
	st = .{};
}

device_available :: () -> bool {return st.device_ok;}
is_running :: () -> bool {return st.running;}

// Seconds between a sample being mixed and it reaching the speaker (estimate).
output_latency :: () -> float64 {return st.latency;}

set_volume :: (v: float32) {atomic_store(*st.master_bits, f32_bits(max(v, 0)));}
get_volume :: () -> float32 {return bits_f32(atomic_load(*st.master_bits));}
set_muted :: (m: bool) {atomic_store(*st.muted, cast(u32)(m));}

Stats :: struct {
	callbacks: u64;
	frames_out: u64;
	running: bool;
}

stats :: () -> Stats {
	return .{atomic_load(*st.callbacks), atomic_load(*st.frames_out), st.running};
}

source_create :: () -> Source {
	for * sl, i: st.slots {
		if sl.in_use { continue; }
		sl.in_use = true;
		atomic_store(*sl.played, 0);
		atomic_store(*sl.paused, 0);
		atomic_store(*sl.flush_req, 0);
		atomic_store(*sl.volume_bits, f32_bits(1));
		// Drop anything left from a previous user.
		atomic_store(*sl.ring.r, atomic_load(*sl.ring.w));
		atomic_store(*sl.active, 1);
		return cast(Source) (i + 1);
	}
	return 0;
}
#scope_module

slot :: (s: Source) -> *Slot {
	if s == 0 || cast(int)(s) > MAX_SOURCES { return null; }
	sl := *st.slots[s - 1];
	return ifx sl.in_use then sl else null;
}
#scope_export

source_destroy :: (s: Source) {
	sl := slot(s);
	if sl == null { return; }
	atomic_store(*sl.active, 0);
	sl.in_use = false;
	// Ring memory is owned by the slot table and reused; the mixer may still be
	// reading it this callback, which is harmless.
}

// Write interleaved stereo f32 @48 kHz. Returns frames written (never blocks).
source_write :: (s: Source, frames: []float32) -> int {
	sl := slot(s);
	if sl == null { return 0; }
	atomic_store(*st.idle_frames, 0);
	n := ring_write(*sl.ring, sub(frames, 0, len(frames) / CHANNELS * CHANNELS)) / CHANNELS;
	if n > 0 && st.device_ok && !atomic_load(*st.running) { start_output(); }
	return n;
}

source_free_frames :: (s: Source) -> int {
	sl := slot(s);
	if sl == null { return 0; }
	return ring_writable(*sl.ring) / CHANNELS;
}

source_queued_frames :: (s: Source) -> int {
	sl := slot(s);
	if sl == null { return 0; }
	q := cast(int)(atomic_load(*sl.ring.w)) - cast(int)(max(atomic_load(*sl.ring.r), atomic_load(*sl.flush_req)));
	return max(q, 0) / CHANNELS;
}

// Frames this source has delivered to the device since create / last flush.
source_played_frames :: (s: Source) -> u64 {
	sl := slot(s);
	if sl == null { return 0; }
	return atomic_load(*sl.played);
}

source_set_volume :: (s: Source, v: float32) {
	{ sl := slot(s);
	if sl != null { atomic_store(*sl.volume_bits, f32_bits(max(v, 0))); } }
}

source_set_paused :: (s: Source, paused: bool) {
	{ sl := slot(s);
	if sl != null { atomic_store(*sl.paused, cast(u32)(paused)); } }
}

// Discard everything queued so far (seek). Writes after this call are kept.
// Resets played_frames to 0 once the mixer applies it.
source_flush :: (s: Source) {
	sl := slot(s);
	if sl == null { return; }
	w := atomic_load(*sl.ring.w);
	atomic_store(*sl.flush_req, w);
	if !st.running {
		// No consumer running: apply directly (we're the only thread touching r now).
		apply_flush(sl);
	}
}
#scope_module

apply_flush :: (sl: *Slot) {
	f := atomic_exchange(*sl.flush_req, 0);
	if f == 0 { return; }
	if atomic_load(*sl.ring.r) < f { atomic_store(*sl.ring.r, f); }
	atomic_store(*sl.played, 0);
}

start_output :: () {
	locks.lock(*st.device_mu);
	defer locks.unlock(*st.device_mu);
	if st.running { return; }
	atomic_store(*st.idle_frames, 0);
	_device_start();
	if st.running && st.watchdog == null {
		st.watchdog = thread.create_and_start(watchdog);
	}
}

watchdog :: () {
	while true {
		time.sleep(500 * time.Millisecond);
		locks.lock(*st.device_mu);
		if !st.running {
			st.watchdog = null;
			locks.unlock(*st.device_mu);
			return;
		}
		if !st.capturing && cast(float64)(atomic_load(*st.idle_frames)) > OUTPUT_IDLE_STOP * SAMPLE_RATE {
			_device_stop();
			st.watchdog = null;
			locks.unlock(*st.device_mu);
			return;
		}
		locks.unlock(*st.device_mu);
	}
}
#scope_export

// Kept for API compatibility; idle shutdown is automatic.
update :: () {}

// The mixer. Called on the device thread (or by tests with init_null).
// out: interleaved stereo f32, len = frames*2.
mix :: (out: []float32) {
	for * o: out { o.* = 0; }
	frames := len(out) / CHANNELS;
	any_data := false;
	master := bits_f32(atomic_load(*st.master_bits));
	if atomic_load(*st.muted) != 0 { master = 0; }
	for * sl: st.slots {
		if sync.atomic_load_explicit(*sl.active, .Acquire) == 0 { continue; }
		if atomic_load(*sl.flush_req) != 0 { apply_flush(sl); }
		if atomic_load(*sl.paused) != 0 { continue; }
		vol := bits_f32(atomic_load(*sl.volume_bits)) * master;
		r := *sl.ring;
		avail := ring_readable(r);
		n := min(avail, frames * CHANNELS);
		if n == 0 { continue; }
		any_data = true;
		rd := sync.atomic_load_explicit(*r.r, .Relaxed);
		for i: 0..cast(int)(n)-1 {
			at(*out, i).* += r.buf[(rd + cast(u64)(i)) & r.mask] * vol;
		}
		sync.atomic_store_explicit(*r.r, rd + cast(u64)(n), .Release);
		atomic_add(*sl.played, cast(u64)(n / CHANNELS));
	}
	// Soft clip to avoid harsh wraparound when sources sum > 1.
	for * o: out {
		if o.* > 1 || o.* < -1 { o.* = math.clamp(o.*, -1, 1); }
	}
	if !any_data { atomic_add(*st.idle_frames, cast(u64)(frames)); } else { atomic_store(*st.idle_frames, 0); }
	atomic_add(*st.frames_out, cast(u64)(frames));
}

// ---------------------------------------------------------------------------
// Capture (mono f32 @48 kHz)

// voice_processing: macOS VoiceProcessingIO (echo cancellation, AGC, noise
// suppression); output is routed through the same unit so the canceller hears it.
capture_start :: (voice_processing := true) -> bool {
	if !st.device_ok || st.capturing { return st.capturing; }
	atomic_store(*st.capture.r, atomic_load(*st.capture.w));
	locks.lock(*st.device_mu);
	st.capturing = _capture_start(voice_processing);
	locks.unlock(*st.device_mu);
	st.voice_proc = st.capturing && voice_processing;
	return st.capturing;
}

capture_stop :: () {
	if !st.capturing { return; }
	locks.lock(*st.device_mu);
	_capture_stop();
	locks.unlock(*st.device_mu);
	st.capturing = false;
	st.voice_proc = false;
}

capture_available :: () -> int {return ring_readable(*st.capture);}

// Read captured mono samples. Use 480 (10 ms) / 960 (20 ms) frames for Opus.
capture_read :: (out: []float32) -> int {return ring_read(*st.capture, out);}

// ---------------------------------------------------------------------------
// Helpers for decoders

// Convert interleaved PCM with `ch` channels to stereo, appending to out.
to_stereo :: (out: *[..]float32, src: []float32, ch: int) {
	if ch == {
	case 1;
		for s: src { append(out, s, s); }
	case 2;
		append(out, ..src);
	case;
		frames := len(src) / max(ch, 1);
		for f: 0..cast(int)(frames)-1 {
			append(out, src[f * ch], src[f * ch + 1]);
		}
	}
}

// Monotonic stream positions (frames). read_pos advances as the device consumes
// (and jumps forward on flush); write_pos as the producer writes. A producer
// that remembers write_pos when it starts a new segment can compute exactly
// how much of that segment has been played: read_pos - mark.
source_read_pos :: (s: Source) -> u64 {
	sl := slot(s);
	if sl == null { return 0; }
	return atomic_load(*sl.ring.r) / CHANNELS;
}

source_write_pos :: (s: Source) -> u64 {
	sl := slot(s);
	if sl == null { return 0; }
	return atomic_load(*sl.ring.w) / CHANNELS;
}

