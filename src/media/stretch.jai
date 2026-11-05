// Time-stretch (WSOLA) for player_set_rate: changes the speed of 48 kHz stereo audio but not its pitch,
// as the client's <audio> and <video> do (preservesPitch). Hann windows of STRETCH_W frames are
// overlap-added every STRETCH_HOP output frames; each is read near where the rate puts it, at the offset
// whose start best continues the previous window, so the waveform joins without a click.
//
//	s: Stretch;                          // zero is ready; stretch_reset after a seek
//	stretch(*s, pcm, rate, *out)         // appends about pcm.count / rate samples
//	array_free(s.input)

STRETCH_W :: 1536; // 32 ms
STRETCH_HOP :: STRETCH_W / 2;
STRETCH_SEEK :: 384; // how far (frames) a window may move from its place, either way

Stretch :: struct {
	input: [..]float32; // stereo, not yet used up
	next: float64; // the next window's place, in frames of input
	prev: int; // where the last window was read (may be before input, by up to STRETCH_HOP)
	started: bool; // a window was read
	ola: [STRETCH_W * 2]float32; // overlap-added output still to finish
}

stretch_reset :: (s: *Stretch) {
	s.input.count = 0;
	s.next = 0;
	s.started = false;
	memset(s.ola.data, 0, size_of(type_of(s.ola)));
}

stretch :: (s: *Stretch, pcm: []float32, rate: float64, out: *[..]float32) {
	array_add(*s.input, ..pcm);
	n := s.input.count / 2;
	x := s.input.data;
	while true {
		at := cast(int) s.next;
		if at + STRETCH_SEEK + STRETCH_W > n break;
		best := at;
		if s.started {
			// The natural continuation of the last window is the input right after its first half.
			ref := s.prev + STRETCH_HOP;
			lo := max(at - STRETCH_SEEK, 0);
			best = lo;
			top := -FLOAT64_MAX;
			o := lo;
			while o <= at + STRETCH_SEEK { // coarse
				v := similarity(x, ref, o, 4);
				if v > top { top = v; best = o; }
				o += 4;
			}
			coarse := best;
			for o: max(coarse - 3, lo)..min(coarse + 3, at + STRETCH_SEEK) { // fine
				v := similarity(x, ref, o, 1);
				if v > top { top = v; best = o; }
			}
		}
		for i: 0..STRETCH_W - 1 {
			w := cast(float32) (0.5 - 0.5 * cos(TAU64 * i / STRETCH_W));
			s.ola[2 * i] += x[2 * (best + i)] * w;
			s.ola[2 * i + 1] += x[2 * (best + i) + 1] * w;
		}
		array_add(out, ..array_view(s.ola, 0, STRETCH_HOP * 2));
		memcpy(s.ola.data, s.ola.data + STRETCH_HOP * 2, STRETCH_HOP * 2 * size_of(float32));
		memset(s.ola.data + STRETCH_HOP * 2, 0, STRETCH_HOP * 2 * size_of(float32));
		s.prev = best;
		s.started = true;
		s.next += STRETCH_HOP * rate;
	}
	// Drop the input no later window can read.
	if !s.started return;
	used := clamp(min(cast(int) s.next - STRETCH_SEEK, s.prev + STRETCH_HOP), 0, n);
	remove_range(*s.input, 0, used * 2);
	s.next -= used;
	s.prev -= used;
}

#scope_file

// Normalised correlation of the mono mix over a half window: ref's against the one at o.
similarity :: (x: *float32, ref: int, o: int, step: int) -> float64 {
	xy, yy: float64;
	i := 0;
	while i < STRETCH_HOP {
		a := x[2 * (ref + i)] + x[2 * (ref + i) + 1];
		b := x[2 * (o + i)] + x[2 * (o + i) + 1];
		xy += a * b;
		yy += b * b;
		i += step;
	}
	return xy / sqrt(yy + 1.0e-9);
}
