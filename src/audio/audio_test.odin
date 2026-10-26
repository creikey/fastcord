package audio

import "core:testing"

@(test)
test_ring_and_mixer :: proc(t: ^testing.T) {
	init_null()
	defer shutdown()
	a := source_create()
	b := source_create()
	testing.expect(t, a != 0 && b != 0)
	data := [8]f32{0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5} // 4 stereo frames
	testing.expect_value(t, source_write(a, data[:]), 4)
	testing.expect_value(t, source_write(b, data[:4]), 2)
	source_set_volume(b, 0.5)
	out: [8]f32
	mix(out[:])
	testing.expect_value(t, out[0], 0.75) // 0.5 + 0.5*0.5
	testing.expect_value(t, out[4], 0.5) // b ran dry
	testing.expect_value(t, source_played_frames(a), 4)
	testing.expect_value(t, source_read_pos(b), 2)

	// flush drops queued data but keeps later writes
	source_write(a, data[:])
	source_flush(a)
	more := [2]f32{0.25, 0.25}
	source_write(a, more[:])
	testing.expect_value(t, source_queued_frames(a), 1)
	mix(out[:2])
	testing.expect_value(t, out[0], 0.25)

	// ring wraparound
	r: Ring
	ring_init(&r, 4)
	defer ring_destroy(&r)
	x := [3]f32{1, 2, 3}
	y: [3]f32
	for _ in 0 ..< 10 {
		testing.expect_value(t, ring_write(&r, x[:]), 3)
		testing.expect_value(t, ring_read(&r, y[:]), 3)
		testing.expect_value(t, y, x)
	}
	testing.expect_value(t, ring_write(&r, []f32{1, 1, 1, 1, 1}), 4)
}
