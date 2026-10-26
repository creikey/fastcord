// Low-latency audio I/O: a mixer of app-fed sources -> the OS output device,
// and mono microphone capture (48 kHz) for voice.
//
//	audio.init()
//	s := audio.source_create()
//	audio.source_write(s, stereo_f32_48k)   // non-blocking, returns frames written
//	audio.source_played_frames(s)          // for A/V sync
//
// Threading: every source is a lock-free single-producer/single-consumer ring
// (app or decoder thread writes, the device thread reads). Capture is the
// mirror image (device thread writes, app reads). Nothing on the audio thread
// allocates or locks.
//
// Battery: the output device is stopped after OUTPUT_IDLE_STOP seconds with
// nothing to play (a watchdog thread that only exists while the device runs
// checks twice a second) and restarted on the next source_write.
package audio

import "base:runtime"
import "core:math"
import "core:sync"
import "core:thread"
import "core:time"

SAMPLE_RATE :: 48000
CHANNELS :: 2 // output is interleaved stereo f32
MAX_SOURCES :: 64
SOURCE_SECONDS :: 1 // ring capacity per source
CAPTURE_SECONDS :: 2
OUTPUT_IDLE_STOP :: 2.0

// ---------------------------------------------------------------------------
// SPSC ring of f32 samples. Capacity is a power of two.

Ring :: struct {
	buf:  []f32,
	mask: u64,
	r:    u64, // atomic; total samples read
	w:    u64, // atomic; total samples written
}

ring_init :: proc(r: ^Ring, min_capacity: int, allocator := context.allocator) {
	c := 1
	for c < min_capacity do c <<= 1
	r.buf = make([]f32, c, allocator)
	r.mask = u64(c - 1)
	r.r = 0
	r.w = 0
}

ring_destroy :: proc(r: ^Ring, allocator := context.allocator) {
	delete(r.buf, allocator)
	r^ = {}
}

ring_readable :: #force_inline proc "contextless" (r: ^Ring) -> int {
	return int(sync.atomic_load_explicit(&r.w, .Acquire) - sync.atomic_load_explicit(&r.r, .Relaxed))
}

ring_writable :: #force_inline proc "contextless" (r: ^Ring) -> int {
	return len(r.buf) - int(sync.atomic_load_explicit(&r.w, .Relaxed) - sync.atomic_load_explicit(&r.r, .Acquire))
}

// Producer side.
ring_write :: proc "contextless" (r: ^Ring, data: []f32) -> int {
	n := min(len(data), ring_writable(r))
	w := sync.atomic_load_explicit(&r.w, .Relaxed)
	for i in 0 ..< n do r.buf[(w + u64(i)) & r.mask] = data[i]
	sync.atomic_store_explicit(&r.w, w + u64(n), .Release)
	return n
}

// Consumer side.
ring_read :: proc "contextless" (r: ^Ring, out: []f32) -> int {
	n := min(len(out), ring_readable(r))
	rd := sync.atomic_load_explicit(&r.r, .Relaxed)
	for i in 0 ..< n do out[i] = r.buf[(rd + u64(i)) & r.mask]
	sync.atomic_store_explicit(&r.r, rd + u64(n), .Release)
	return n
}

// ---------------------------------------------------------------------------
// Sources

Source :: distinct u32 // 0 = invalid; index+1 into the slot table

@(private)
Slot :: struct {
	ring:          Ring,
	in_use:        bool, // main-thread bookkeeping
	active:        u32, // atomic bool read by the mixer
	paused:        u32, // atomic bool
	volume_bits:   u32, // atomic f32
	played:        u64, // atomic: frames consumed by the device since create/flush
	flush_req:     u64, // atomic: writer's w position to drop up to (0 = none)
}

@(private)
State :: struct {
	initialized:   bool,
	device_ok:     bool,
	running:       bool, // output unit started
	slots:         [MAX_SOURCES]Slot,
	master_bits:   u32, // atomic f32
	muted:         u32,
	idle_frames:   u64, // atomic, frames mixed with no source data
	mix_scratch:   []f32,
	capture:       Ring,
	capturing:     bool,
	voice_proc:    bool,
	ctx:           runtime.Context,
	latency:       f64,
	device_mu:     sync.Mutex, // start/stop
	watchdog:      ^thread.Thread,
	callbacks:     u64, // atomic, device callbacks (diagnostics)
	frames_out:    u64, // atomic, frames rendered (diagnostics)
}

@(private)
st: State

f32_bits :: #force_inline proc "contextless" (f: f32) -> u32 {return transmute(u32)f}
bits_f32 :: #force_inline proc "contextless" (b: u32) -> f32 {return transmute(f32)b}

// Opens the default output device (lazily started on first write).
// Returns false if no device; sources still work and can be pulled with mix().
init :: proc() -> bool {
	if st.initialized do return st.device_ok
	st.ctx = context
	st.master_bits = f32_bits(1)
	st.mix_scratch = make([]f32, 8192 * CHANNELS)
	for &sl in st.slots {
		ring_init(&sl.ring, SAMPLE_RATE * CHANNELS * SOURCE_SECONDS)
	}
	ring_init(&st.capture, SAMPLE_RATE * CAPTURE_SECONDS)
	st.initialized = true
	st.device_ok = _device_init()
	return st.device_ok
}

// No device at all: for tests. Pull audio with mix().
init_null :: proc() {
	if st.initialized do return
	st.ctx = context
	st.master_bits = f32_bits(1)
	st.mix_scratch = make([]f32, 8192 * CHANNELS)
	for &sl in st.slots do ring_init(&sl.ring, SAMPLE_RATE * CHANNELS * SOURCE_SECONDS)
	ring_init(&st.capture, SAMPLE_RATE * CAPTURE_SECONDS)
	st.initialized = true
	st.device_ok = false
}

shutdown :: proc() {
	if !st.initialized do return
	if st.capturing do capture_stop()
	if st.device_ok {
		sync.mutex_lock(&st.device_mu)
		_device_shutdown()
		sync.mutex_unlock(&st.device_mu)
		for {
			// wait for the watchdog to notice
			sync.mutex_lock(&st.device_mu)
			w := st.watchdog
			sync.mutex_unlock(&st.device_mu)
			if w == nil do break
			time.sleep(10 * time.Millisecond)
		}
	}
	for &sl in st.slots do ring_destroy(&sl.ring)
	ring_destroy(&st.capture)
	delete(st.mix_scratch)
	st = {}
}

device_available :: proc() -> bool {return st.device_ok}
is_running :: proc() -> bool {return st.running}

// Seconds between a sample being mixed and it reaching the speaker (estimate).
output_latency :: proc() -> f64 {return st.latency}

set_volume :: proc(v: f32) {sync.atomic_store(&st.master_bits, f32_bits(max(v, 0)))}
get_volume :: proc() -> f32 {return bits_f32(sync.atomic_load(&st.master_bits))}
set_muted :: proc(m: bool) {sync.atomic_store(&st.muted, u32(m))}

Stats :: struct {
	callbacks:  u64,
	frames_out: u64,
	running:    bool,
}

stats :: proc() -> Stats {
	return {sync.atomic_load(&st.callbacks), sync.atomic_load(&st.frames_out), st.running}
}

source_create :: proc() -> Source {
	for &sl, i in st.slots {
		if sl.in_use do continue
		sl.in_use = true
		sync.atomic_store(&sl.played, 0)
		sync.atomic_store(&sl.paused, 0)
		sync.atomic_store(&sl.flush_req, 0)
		sync.atomic_store(&sl.volume_bits, f32_bits(1))
		// Drop anything left from a previous user.
		sync.atomic_store(&sl.ring.r, sync.atomic_load(&sl.ring.w))
		sync.atomic_store(&sl.active, 1)
		return Source(i + 1)
	}
	return 0
}

@(private)
slot :: proc(s: Source) -> ^Slot {
	if s == 0 || int(s) > MAX_SOURCES do return nil
	sl := &st.slots[s - 1]
	return sl.in_use ? sl : nil
}

source_destroy :: proc(s: Source) {
	sl := slot(s)
	if sl == nil do return
	sync.atomic_store(&sl.active, 0)
	sl.in_use = false
	// Ring memory is owned by the slot table and reused; the mixer may still be
	// reading it this callback, which is harmless.
}

// Write interleaved stereo f32 @48 kHz. Returns frames written (never blocks).
source_write :: proc(s: Source, frames: []f32) -> int {
	sl := slot(s)
	if sl == nil do return 0
	sync.atomic_store(&st.idle_frames, 0)
	n := ring_write(&sl.ring, frames[:len(frames) / CHANNELS * CHANNELS]) / CHANNELS
	if n > 0 && st.device_ok && !sync.atomic_load(&st.running) do start_output()
	return n
}

source_free_frames :: proc(s: Source) -> int {
	sl := slot(s)
	if sl == nil do return 0
	return ring_writable(&sl.ring) / CHANNELS
}

source_queued_frames :: proc(s: Source) -> int {
	sl := slot(s)
	if sl == nil do return 0
	q := int(sync.atomic_load(&sl.ring.w)) - int(max(sync.atomic_load(&sl.ring.r), sync.atomic_load(&sl.flush_req)))
	return max(q, 0) / CHANNELS
}

// Frames this source has delivered to the device since create / last flush.
source_played_frames :: proc(s: Source) -> u64 {
	sl := slot(s)
	if sl == nil do return 0
	return sync.atomic_load(&sl.played)
}

source_set_volume :: proc(s: Source, v: f32) {
	if sl := slot(s); sl != nil do sync.atomic_store(&sl.volume_bits, f32_bits(max(v, 0)))
}

source_set_paused :: proc(s: Source, paused: bool) {
	if sl := slot(s); sl != nil do sync.atomic_store(&sl.paused, u32(paused))
}

// Discard everything queued so far (seek). Writes after this call are kept.
// Resets played_frames to 0 once the mixer applies it.
source_flush :: proc(s: Source) {
	sl := slot(s)
	if sl == nil do return
	w := sync.atomic_load(&sl.ring.w)
	sync.atomic_store(&sl.flush_req, w)
	if !st.running {
		// No consumer running: apply directly (we're the only thread touching r now).
		apply_flush(sl)
	}
}

@(private)
apply_flush :: proc "contextless" (sl: ^Slot) {
	f := sync.atomic_exchange(&sl.flush_req, 0)
	if f == 0 do return
	if sync.atomic_load(&sl.ring.r) < f do sync.atomic_store(&sl.ring.r, f)
	sync.atomic_store(&sl.played, 0)
}

@(private)
start_output :: proc() {
	sync.mutex_lock(&st.device_mu)
	defer sync.mutex_unlock(&st.device_mu)
	if st.running do return
	sync.atomic_store(&st.idle_frames, 0)
	_device_start()
	if st.running && st.watchdog == nil {
		st.watchdog = thread.create_and_start(watchdog)
	}
}

@(private)
watchdog :: proc() {
	for {
		time.sleep(500 * time.Millisecond)
		sync.mutex_lock(&st.device_mu)
		if !st.running {
			st.watchdog = nil
			sync.mutex_unlock(&st.device_mu)
			return
		}
		if !st.capturing && f64(sync.atomic_load(&st.idle_frames)) > OUTPUT_IDLE_STOP * SAMPLE_RATE {
			_device_stop()
			st.watchdog = nil
			sync.mutex_unlock(&st.device_mu)
			return
		}
		sync.mutex_unlock(&st.device_mu)
	}
}

// Kept for API compatibility; idle shutdown is automatic.
update :: proc() {}

// The mixer. Called on the device thread (or by tests with init_null).
// out: interleaved stereo f32, len = frames*2.
mix :: proc "contextless" (out: []f32) {
	for &o in out do o = 0
	frames := len(out) / CHANNELS
	any_data := false
	master := bits_f32(sync.atomic_load(&st.master_bits))
	if sync.atomic_load(&st.muted) != 0 do master = 0
	for &sl in st.slots {
		if sync.atomic_load_explicit(&sl.active, .Acquire) == 0 do continue
		if sync.atomic_load(&sl.flush_req) != 0 do apply_flush(&sl)
		if sync.atomic_load(&sl.paused) != 0 do continue
		vol := bits_f32(sync.atomic_load(&sl.volume_bits)) * master
		r := &sl.ring
		avail := ring_readable(r)
		n := min(avail, frames * CHANNELS)
		if n == 0 do continue
		any_data = true
		rd := sync.atomic_load_explicit(&r.r, .Relaxed)
		for i in 0 ..< n {
			out[i] += r.buf[(rd + u64(i)) & r.mask] * vol
		}
		sync.atomic_store_explicit(&r.r, rd + u64(n), .Release)
		sync.atomic_add(&sl.played, u64(n / CHANNELS))
	}
	// Soft clip to avoid harsh wraparound when sources sum > 1.
	for &o in out {
		if o > 1 || o < -1 do o = math.clamp(o, -1, 1)
	}
	if !any_data do sync.atomic_add(&st.idle_frames, u64(frames))
	else do sync.atomic_store(&st.idle_frames, 0)
	sync.atomic_add(&st.frames_out, u64(frames))
}

// ---------------------------------------------------------------------------
// Capture (mono f32 @48 kHz)

// voice_processing: macOS VoiceProcessingIO (echo cancellation, AGC, noise
// suppression); output is routed through the same unit so the canceller hears it.
capture_start :: proc(voice_processing := true) -> bool {
	if !st.device_ok || st.capturing do return st.capturing
	sync.atomic_store(&st.capture.r, sync.atomic_load(&st.capture.w))
	sync.mutex_lock(&st.device_mu)
	st.capturing = _capture_start(voice_processing)
	sync.mutex_unlock(&st.device_mu)
	st.voice_proc = st.capturing && voice_processing
	return st.capturing
}

capture_stop :: proc() {
	if !st.capturing do return
	sync.mutex_lock(&st.device_mu)
	_capture_stop()
	sync.mutex_unlock(&st.device_mu)
	st.capturing = false
	st.voice_proc = false
}

capture_available :: proc() -> int {return ring_readable(&st.capture)}

// Read captured mono samples. Use 480 (10 ms) / 960 (20 ms) frames for Opus.
capture_read :: proc(out: []f32) -> int {return ring_read(&st.capture, out)}

// ---------------------------------------------------------------------------
// Helpers for decoders

// Convert interleaved PCM with `ch` channels to stereo, appending to out.
to_stereo :: proc(out: ^[dynamic]f32, src: []f32, ch: int) {
	switch ch {
	case 1:
		for s in src do append(out, s, s)
	case 2:
		append(out, ..src)
	case:
		frames := len(src) / max(ch, 1)
		for f in 0 ..< frames {
			append(out, src[f * ch], src[f * ch + 1])
		}
	}
}

// Monotonic stream positions (frames). read_pos advances as the device consumes
// (and jumps forward on flush); write_pos as the producer writes. A producer
// that remembers write_pos when it starts a new segment can compute exactly
// how much of that segment has been played: read_pos - mark.
source_read_pos :: proc(s: Source) -> u64 {
	sl := slot(s)
	if sl == nil do return 0
	return sync.atomic_load(&sl.ring.r) / CHANNELS
}

source_write_pos :: proc(s: Source) -> u64 {
	sl := slot(s)
	if sl == nil do return 0
	return sync.atomic_load(&sl.ring.w) / CHANNELS
}
