// HTTP/2 flow-control and PING checks against a scripted server on a pipe (about 21 s: Chrome's PING
// timers are 10 s): jai build.jai - run src/tests/h2.jai, then build/h2.
//   - DATA for a stream the client already reset counts toward the connection's unacked bytes
//   - an unanswered preface PING ends the connection with GOAWAY (PROTOCOL_ERROR, "Failed ping.")
#import "Basic";
#import "Thread";
http :: #import "http";
netio :: #import "netio";

main :: () {
	failed := 0;
	check :: (ok: bool, what: string) #expand {
		if !ok { print("FAIL: %\n", what); `failed += 1; }
	}
	a, b := http.pipe_make(read_timeout_ms = 60_000);
	srv := Server.{s = b};
	c, err := http.h2_connect(a, .{max_response_body = 100});
	check(err == .None, "connect");
	preface: [24]u8;
	check(read_n(*srv, preface) && frame(*srv).type == SETTINGS && frame(*srv).type == WINDOW_UPDATE, "client preface");
	send(*srv, SETTINGS, 0, 0, .[]);
	send(*srv, SETTINGS, ACK, 0, .[]);

	// A response over max_response_body: the client resets stream 1; DATA already in flight follows.
	req := Request_Job.{c = c};
	t1 := start(*req);
	until(*srv, HEADERS);
	send(*srv, HEADERS, END_HEADERS, 1, .[0x88]); // :status 200
	body: [300]u8;
	send(*srv, DATA, 0, 1, array_view(body, 0, 200));
	until(*srv, RST_STREAM);
	join(t1);
	check(req.err == .Too_Large, "response over the limit fails");
	service := start(c);
	send(*srv, DATA, 0, 1, body);
	send(*srv, PING, 0, 0, .[1, 2, 3, 4, 5, 6, 7, 8]);
	until(*srv, PING, ack = true);
	check(c.unacked == 500, tprint("unacked % after DATA for a reset stream, want 500", c.unacked));

	// Idle for 10 s: the next request goes out behind a PING. Leave it unanswered.
	sleep_milliseconds(10_500);
	t2 := start(*req);
	f := frame(*srv);
	check(f.type == PING && !f.flags, "preface PING");
	until(*srv, HEADERS);
	start_time := current_time_monotonic();
	f = until(*srv, GOAWAY);
	waited := to_milliseconds(current_time_monotonic() - start_time);
	check(f.payload.count == 20 && f.payload[3] == 0 && f.payload[7] == 1 && to_string(f.payload.data + 8, 12) == "Failed ping.", "GOAWAY 0, PROTOCOL_ERROR, \"Failed ping.\"");
	check(waited >= 9_000 && waited <= 11_000, tprint("GOAWAY after % ms, want 10 s", waited));
	join(t2);
	check(req.err == .Timeout, "the request fails");
	join(service);
	http.h2_close(c);

	// A request waiting on a dead connection (after sleep): h2_abort fails it at once.
	a2, b2 := http.pipe_make(read_timeout_ms = 60_000);
	srv2 := Server.{s = b2};
	c2 := http.h2_connect(a2, .{});
	read_n(*srv2, preface);
	send(*srv2, SETTINGS, 0, 0, .[]);
	req2 := Request_Job.{c = c2};
	t3 := start(*req2);
	until(*srv2, HEADERS);
	start_time = current_time_monotonic();
	http.h2_abort(c2);
	join(t3);
	check(req2.err == .Closed && to_milliseconds(current_time_monotonic() - start_time) < 1000, "h2_abort fails the request at once");
	http.h2_close(c2);
	print("h2: % failed\n", failed);
	exit(xx ifx failed then 1 else 0);
}

DATA :: 0; HEADERS :: 1; RST_STREAM :: 3; SETTINGS :: 4; PING :: 6; GOAWAY :: 7; WINDOW_UPDATE :: 8;
ACK :: 1; END_HEADERS :: 4;

Server :: struct { s: netio.Stream; buf: [..]u8; }
Frame :: struct { type: u8; flags: u8; id: u32; payload: []u8; }

read_n :: (v: *Server, out: []u8) -> bool {
	tmp: [4096]u8;
	while v.buf.count < out.count {
		n, err := netio.read(v.s, tmp);
		if err != .None return false;
		array_add(*v.buf, ..array_view(tmp, 0, n));
	}
	memcpy(out.data, v.buf.data, out.count);
	for i: out.count..v.buf.count-1 v.buf[i - out.count] = v.buf[i];
	v.buf.count -= out.count;
	return true;
}

frame :: (v: *Server) -> Frame {
	h: [9]u8;
	if !read_n(v, h) return .{type = 255};
	f := Frame.{type = h[3], flags = h[4], id = (cast(u32) h[5] & 0x7f) << 24 | (cast(u32) h[6]) << 16 | (cast(u32) h[7]) << 8 | cast(u32) h[8]};
	f.payload = NewArray((cast(int) h[0]) << 16 | (cast(int) h[1]) << 8 | h[2], u8);
	if !read_n(v, f.payload) f.type = 255;
	return f;
}

// until skips frames up to the first of this type, a PING's ack flag as asked (or the connection's end).
until :: (v: *Server, type: u8, ack := false) -> Frame {
	f := frame(v);
	while f.type != 255 && (f.type != type || (type == PING && (f.flags & ACK != 0) != ack)) f = frame(v);
	return f;
}

join :: (t: *Thread) { while !thread_is_done(t) sleep_milliseconds(5); }

send :: (v: *Server, type: u8, flags: u8, id: u32, payload: []u8) {
	b: [..]u8;
	n := payload.count;
	array_add(*b, cast(u8) (n >> 16), cast(u8) (n >> 8), cast(u8) n, type, flags, cast(u8) (id >> 24), cast(u8) (id >> 16), cast(u8) (id >> 8), cast(u8) id);
	array_add(*b, ..payload);
	netio.write(v.s, b);
}

Request_Job :: struct { c: *http.H2_Conn; err: http.Error; }

start :: (job: *Request_Job) -> *Thread {
	t := New(Thread);
	thread_init(t, (t: *Thread) -> s64 {
		job := cast(*Request_Job) t.data;
		resp: http.Response;
		resp, job.err = http.h2_request(job.c, .{method = "GET", scheme = "https", authority = "example.com", path = "/"});
		return 0;
	});
	t.data = job;
	thread_start(t);
	return t;
}

start :: (c: *http.H2_Conn) -> *Thread {
	t := New(Thread);
	thread_init(t, (t: *Thread) -> s64 { http.h2_service(cast(*http.H2_Conn) t.data); return 0; });
	t.data = c;
	thread_start(t);
	return t;
}
