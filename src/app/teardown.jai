// Tearing down a client or voice connection joins network threads (which can sit in a handshake for
// up to netio.DIAL_IO_TIMEOUT_MS) and writes close frames, so it runs on its own thread instead of the
// UI's. New connections wait for it (teardown_busy) because the old and new ones share process-wide
// state: the expression and feature worker pools, and the audio devices.

teardown_busy :: () -> bool { return atomic_load(*teardowns) > 0; }

client_release :: (c: *dc.Client, logout := false) {
	if c == null return;
	undo_flush(c);
	voice_client_gone(c);
	if logout teardown_start(c, (c: *dc.Client) { dc.hosted_logout(c); dc.client_destroy(c); teardown_done(); });
	else teardown_start(c, (c: *dc.Client) { dc.client_destroy(c); teardown_done(); });
}

voice_release :: (c: *voice.Conn) {
	if c == null return;
	teardown_start(c, (c: *voice.Conn) { voice.voice_disconnect(c); teardown_done(); });
}

// teardown_wait is for process exit, when there is no window left to freeze: it lets the close
// frames go out before the process ends.
teardown_wait :: () {
	start := current_time_monotonic();
	while teardown_busy() && to_float64_seconds(current_time_monotonic() - start) < 3 sleep_milliseconds(10);
	if !teardown_busy() reap_teardowns(); // past 3 s (a server that doesn't answer), the process just ends
}

#scope_file

teardowns: int;
threads: [..]*Thread; // UI thread only; finished ones are freed by the next release or teardown_wait

teardown_start :: (data: $D, proc: (D)) {
	reap_teardowns();
	atomic_add(*teardowns, 1);
	array_add(*threads, dc.spawn(data, proc));
}

teardown_done :: () {
	atomic_add(*teardowns, -1);
	platform.request_frame();
}

// Frees finished threads without waiting (locks.join would flag a wait on the UI thread).
reap_teardowns :: () {
	for threads if thread_is_done(it) {
		thread_deinit(it);
		free(it);
		remove it;
	}
}
