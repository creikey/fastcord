package app

import "core:sync"
import "core:thread"
import "core:time"
import dc "fc:discord"
import "fc:platform"
import "fc:voice"

// Tearing down a client or voice connection joins network threads (which can sit in a handshake for
// up to netio.DIAL_IO_TIMEOUT) and writes close frames, so it runs on its own thread instead of the
// UI's. New connections wait for it (teardown_busy) because the old and new ones share process-wide
// state: the expression and feature worker pools, and the audio devices.
@(private = "file")
teardowns: int

teardown_busy :: proc() -> bool {return sync.atomic_load(&teardowns) > 0}

client_release :: proc(c: ^dc.Client) {
	if c == nil do return
	sync.atomic_add(&teardowns, 1)
	thread.create_and_start_with_poly_data(c, proc(c: ^dc.Client) {
		dc.client_destroy(c)
		sync.atomic_sub(&teardowns, 1)
		platform.request_frame()
	}, self_cleanup = true)
}

voice_release :: proc(c: ^voice.Conn) {
	if c == nil do return
	sync.atomic_add(&teardowns, 1)
	thread.create_and_start_with_poly_data(c, proc(c: ^voice.Conn) {
		voice.voice_disconnect(c)
		sync.atomic_sub(&teardowns, 1)
		platform.request_frame()
	}, self_cleanup = true)
}

// teardown_wait is for process exit, when there is no window left to freeze: it lets the close
// frames go out before the process ends.
teardown_wait :: proc() {
	for teardown_busy() do time.sleep(10 * time.Millisecond)
}
