Client :: struct {
	s: netio.Stream;
	ws: *http.Ws_Conn;
	mu: sync.Mutex;
	cond: sync.Cond;
	wmu: sync.Mutex;
	next_id: int;
	waiting: Map(int, bool); // ids a `call` is blocked on
	results: Map(int, string);
	queue: [..]string; // raw JSON messages for next()
	dead: bool;
	reader: *thread.Thread;
}

// browser_ws_url asks a DevTools port for its browser-level endpoint.
browser_ws_url :: (port: int, allocator := context.allocator) -> string, bool {
	tcp, err := netio.dial_tcp("127.0.0.1", port);
	if err != .None { return "", false; }
	c: http.H1_Conn;
	http.h1_init(*c, netio.tcp_stream(tcp));
	defer http.h1_destroy(*c);
	host := fmt.tprintf("127.0.0.1:%d", port);
	resp, rerr := http.h1_round_trip(*c, .{method = "GET", path = "/json/version", headers = .{.{"Host", host}, .{"Connection", "close"}}});
	defer http.response_destroy(*resp);
	if rerr != .None || resp.status != 200 { return "", false; }
	v, jerr := etf.from_json(as_string(view(resp.body)), temp);
	if jerr != .None { return "", false; }
	url := str(v, "webSocketDebuggerUrl");
	if url == "" { return "", false; }
	return clone(url, allocator), true;
}

connect :: (port: int) -> *Client, bool {
	c: *Client;
	ok: bool;
	url, __e1 := browser_ws_url(port, temp); if failed(__e1) return c, __e1;
	rest := strings.trim_prefix(url, "ws://");
	slash := strings.index_byte(rest, #char "/");
	if slash < 0 { return null, false; }
	hostport, path := sub(rest, 0, slash), sub_from(rest, slash);
	tcp, err := netio.dial_tcp("127.0.0.1", port);
	if err != .None { return null, false; }
	s := netio.tcp_stream(tcp);
	ws, resp, herr := http.ws_connect(
		s,
		.{path = path, headers = .{.{"Host", hostport}, .{"Connection", "Upgrade"}, .{"Upgrade", "websocket"}, .{"Sec-WebSocket-Version", "13"}, .{"Sec-WebSocket-Key", ""}}},
		.{max_message = 512 << 20},
	);
	http.response_destroy(*resp);
	if herr != .None {
		netio.close(s);
		return null, false;
	}
	c = new(Client);
	c.s = s;
	c.ws = ws;
	c.next_id = 1;
	c.waiting = Map(int, bool).{};
	c.results = Map(int, string).{};
	c.queue = make_dynamic(string, 0, 0);
	c.reader = thread.create_and_start_with_poly_data(c, reader_loop);
	return c, true;
}

close :: (c: *Client) {
	netio.shutdown(c.ws.s);
	thread.join(c.reader);
	thread.destroy(c.reader);
	http.ws_close_stream(c.ws);
	for m: c.queue { delete(m); }
	delete(c.queue);
	for _, r: c.results { delete(r); }
	delete(c.results);
	delete(c.waiting);
	free(c);
}
#scope_module

reader_loop :: (c: *Client) {
	msg := make_dynamic(u8, 0, 0);
	defer delete(msg);
	while true {
		_, err := http.ws_recv(c.ws, *msg);
		if err != .None {
			sync.mutex_lock(*c.mu);
			c.dead = true;
			sync.cond_broadcast(*c.cond);
			sync.mutex_unlock(*c.mu);
			return;
		}
		raw := clone(as_string(view(msg)));
		id := -1;
		// Chrome serializes responses as {"id":N,...}; events start with "method".
		if strings.has_prefix(raw, "{\"id\":") {
			rest := sub_from(raw, 6);
			end := 0;
			while end < len(rest) && rest[end] >= #char "0" && rest[end] <= #char "9" { end += 1; }
			id, _ = strconv.parse_int(sub(rest, 0, end));
		}
		sync.mutex_lock(*c.mu);
		if id >= 0 && get(c.waiting, id) {
			at(*c.results, id).* = raw;
		} else {
			append(*c.queue, raw);
		}
		sync.cond_broadcast(*c.cond);
		sync.mutex_unlock(*c.mu);
	}
}
#scope_export

// send fires a command and returns its id; the response arrives via next().
// params is a JSON object text ("" = none).
send :: (c: *Client, method: string, params := "", session := "") -> int {
	return send_ex(c, method, params, session, false);
}
#scope_module

send_ex :: (c: *Client, method: string, params: string, session: string, wait: bool) -> int {
	sync.mutex_lock(*c.mu);
	id := c.next_id;
	c.next_id += 1;
	if wait { at(*c.waiting, id).* = true; }
	sync.mutex_unlock(*c.mu);
	b := strings.builder_make(temp);
	fmt.sbprintf(*b, "{{\"id\":%d,\"method\":\"%s\"", id, method);
	if params != "" { fmt.sbprintf(*b, ",\"params\":%s", params); }
	if session != "" { fmt.sbprintf(*b, ",\"sessionId\":\"%s\"", session); }
	strings.write_byte(*b, #char "}");
	sync.mutex_lock(*c.wmu);
	http.ws_send(c.ws, .Text, transmute([]u8, strings.to_string(b)));
	sync.mutex_unlock(*c.wmu);
	return id;
}
#scope_export

// call sends a command and waits for its response (raw JSON, caller frees).
call :: (c: *Client, method: string, params := "", session := "", timeout := 30 * time.Second) -> string, bool {
	raw: string;
	ok: bool;
	id := send_ex(c, method, params, session, true);
	start := time.tick_now();
	sync.mutex_lock(*c.mu);
	defer sync.mutex_unlock(*c.mu);
	while true {
		{ r, has := map_find(c.results, id);
		if has {
			delete_key(*c.results, id);
			delete_key(*c.waiting, id);
			return r, true;
		} }
		if c.dead { return "", false; }
		left := timeout - time.tick_since(start);
		if left <= 0 {
			delete_key(*c.waiting, id);
			return "", false;
		}
		sync.cond_wait_with_timeout(*c.cond, *c.mu, left);
	}
}

// call_value is call + parse; the result object ("result" field) is returned.
call_value :: (c: *Client, method: string, params := "", session := "", timeout := 30 * time.Second) -> etf.Value, bool {
	raw, ok := call(c, method, params, session, timeout);
	if !ok { return .{}, false; }
	defer delete(raw);
	v, err := etf.from_json(raw, temp);
	if err != .None { return .{}, false; }
	{ _, has_err := get(v, "error");
	if has_err { return v, false; } }
	r, _ := get(v, "result");
	return r, true;
}

// next pops the next queued message (raw JSON, caller frees), waiting up to timeout.
next :: (c: *Client, timeout: time.Duration) -> string, bool {
	start := time.tick_now();
	sync.mutex_lock(*c.mu);
	defer sync.mutex_unlock(*c.mu);
	while len(c.queue) == 0 {
		if c.dead { return "", false; }
		left := timeout - time.tick_since(start);
		if left <= 0 { return "", false; }
		sync.cond_wait_with_timeout(*c.cond, *c.mu, left);
	}
	m := c.queue[0];
	ordered_remove(*c.queue, 0);
	return m, true;
}

is_dead :: (c: *Client) -> bool {
	sync.mutex_lock(*c.mu);
	defer sync.mutex_unlock(*c.mu);
	return c.dead;
}

// ---- JSON helpers over etf.Value (ordered) ----

get :: (v: etf.Value, keys: ..string) -> etf.Value, bool {
	cur := v;
	for k: keys {
		m, is_map := cur.map, cur.kind == .Map;
		if !is_map { return .{}, false; }
		nv, found := etf.map_get(m, k);
		if !found { return .{}, false; }
		cur = nv;
	}
	return cur, true;
}

str :: (v: etf.Value, keys: ..string) -> string {
	x, _ := get(v, ..keys);
	s, _ := x.s, x.kind == .String;
	return s;
}

num :: (v: etf.Value, keys: ..string) -> float64 {
	x, _ := get(v, ..keys);
	if x.kind == {
	case .Int; n := x.i;
		return cast(float64)(n);
	case .Float; n := x.f;
		return n;
	}
	return 0;
}

boolean :: (v: etf.Value, keys: ..string) -> bool {
	x, _ := get(v, ..keys);
	b, _ := x.b, x.kind == .Bool;
	return b;
}

// quote returns s as a JSON string literal.
quote :: (s: string, allocator := temp) -> string {
	sb := strings.builder_make(allocator);
	etf.write_json_string(*sb, s);
	return strings.to_string(sb);
}

to_json :: (v: etf.Value, allocator := temp) -> string {
	sb := strings.builder_make(allocator);
	etf.to_json(v, *sb);
	return strings.to_string(sb);
}

