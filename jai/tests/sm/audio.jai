#import "Basic";
m :: #import "audio";
// Running the built binary checks the ring and mixer (src/audio/audio_test.odin).
main :: () {
	using m;
	init_null();
	defer shutdown();
	a := source_create();
	b := source_create();
	assert(a != 0 && b != 0);
	data := float32.[0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]; // 4 stereo frames
	assert(source_write(a, data) == 4);
	assert(source_write(b, array_view(data, 0, 4)) == 2);
	source_set_volume(b, 0.5);
	out: [8]float32;
	mix(out);
	assert(out[0] == 0.75); // 0.5 + 0.5*0.5
	assert(out[4] == 0.5); // b ran dry
	assert(source_played_frames(a) == 4);
	assert(source_read_pos(b) == 2);

	// flush drops queued data but keeps later writes
	source_write(a, data);
	source_flush(a);
	source_write(a, float32.[0.25, 0.25]);
	assert(source_queued_frames(a) == 1);
	mix(array_view(out, 0, 2));
	assert(out[0] == 0.25);

	// ring wraparound
	r: Ring;
	ring_init(*r, 4);
	defer ring_destroy(*r);
	x := float32.[1, 2, 3];
	y: [3]float32;
	for 1..10 {
		assert(ring_write(*r, x) == 3);
		assert(ring_read(*r, y) == 3);
		assert(y[0] == 1 && y[1] == 2 && y[2] == 3);
	}
	assert(ring_write(*r, float32.[1, 1, 1, 1, 1]) == 4);
	print("audio ok\n");
}
