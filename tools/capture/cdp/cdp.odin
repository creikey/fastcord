// Package cdp is a small Chrome DevTools Protocol client over fc:http's
// WebSocket. Used to record and drive the official Discord desktop client.
//
// One reader thread receives everything. Responses to `call` wake the caller;
// all other messages (events, and responses to fire-and-forget `send`s) are
// queued for `next`.
package cdp

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "fc:etf"
import "fc:http"
import "fc:netio"

Client :: struct {
	s:       netio.Stream,
	ws:      ^http.Ws_Conn,
	mu:      sync.Mutex,
	cond:    sync.Cond,
	wmu:     sync.Mutex,
	next_id: int,
	waiting: map[int]bool, // ids a `call` is blocked on
	results: map[int]string,
	queue:   [dynamic]string, // raw JSON messages for next()
	dead:    bool,
	reader:  ^thread.Thread,
}

// browser_ws_url asks a DevTools port for its browser-level endpoint.
browser_ws_url :: proc(port: int, allocator := context.allocator) -> (string, bool) {
	tcp, err := netio.dial_tcp("127.0.0.1", port)
	if err != .None do return "", false
	c: http.H1_Conn
	http.h1_init(&c, netio.tcp_stream(tcp))
	defer http.h1_destroy(&c)
	host := fmt.tprintf("127.0.0.1:%d", port)
	resp, rerr := http.h1_round_trip(&c, {method = "GET", path = "/json/version", headers = {{"Host", host}, {"Connection", "close"}}})
	defer http.response_destroy(&resp)
	if rerr != .None || resp.status != 200 do return "", false
	v, jerr := etf.from_json(string(resp.body[:]), context.temp_allocator)
	if jerr != .None do return "", false
	url := str(v, "webSocketDebuggerUrl")
	if url == "" do return "", false
	return strings.clone(url, allocator), true
}

connect :: proc(port: int) -> (c: ^Client, ok: bool) {
	url := browser_ws_url(port, context.temp_allocator) or_return
	rest := strings.trim_prefix(url, "ws://")
	slash := strings.index_byte(rest, '/')
	if slash < 0 do return nil, false
	hostport, path := rest[:slash], rest[slash:]
	tcp, err := netio.dial_tcp("127.0.0.1", port)
	if err != .None do return nil, false
	s := netio.tcp_stream(tcp)
	ws, resp, herr := http.ws_connect(
		s,
		{path = path, headers = {{"Host", hostport}, {"Connection", "Upgrade"}, {"Upgrade", "websocket"}, {"Sec-WebSocket-Version", "13"}, {"Sec-WebSocket-Key", ""}}},
		{max_message = 512 << 20},
	)
	http.response_destroy(&resp)
	if herr != .None {
		netio.close(s)
		return nil, false
	}
	c = new(Client)
	c.s = s
	c.ws = ws
	c.next_id = 1
	c.waiting = make(map[int]bool)
	c.results = make(map[int]string)
	c.queue = make([dynamic]string)
	c.reader = thread.create_and_start_with_poly_data(c, reader_loop, init_context = context)
	return c, true
}

close :: proc(c: ^Client) {
	http.ws_shutdown(c.ws)
	thread.join(c.reader)
	thread.destroy(c.reader)
	http.ws_close_stream(c.ws)
	for m in c.queue do delete(m)
	delete(c.queue)
	for _, r in c.results do delete(r)
	delete(c.results)
	delete(c.waiting)
	free(c)
}

@(private)
reader_loop :: proc(c: ^Client) {
	msg := make([dynamic]byte)
	defer delete(msg)
	for {
		_, err := http.ws_recv(c.ws, &msg)
		if err != .None {
			sync.mutex_lock(&c.mu)
			c.dead = true
			sync.cond_broadcast(&c.cond)
			sync.mutex_unlock(&c.mu)
			return
		}
		raw := strings.clone(string(msg[:]))
		id := -1
		// Chrome serializes responses as {"id":N,...}; events start with "method".
		if strings.has_prefix(raw, `{"id":`) {
			rest := raw[6:]
			end := 0
			for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' do end += 1
			id, _ = strconv.parse_int(rest[:end])
		}
		sync.mutex_lock(&c.mu)
		if id >= 0 && c.waiting[id] {
			c.results[id] = raw
		} else {
			append(&c.queue, raw)
		}
		sync.cond_broadcast(&c.cond)
		sync.mutex_unlock(&c.mu)
	}
}

// send fires a command and returns its id; the response arrives via next().
// params is a JSON object text ("" = none).
send :: proc(c: ^Client, method: string, params := "", session := "") -> int {
	return send_ex(c, method, params, session, false)
}

@(private)
send_ex :: proc(c: ^Client, method, params, session: string, wait: bool) -> int {
	sync.mutex_lock(&c.mu)
	id := c.next_id
	c.next_id += 1
	if wait do c.waiting[id] = true
	sync.mutex_unlock(&c.mu)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"id":%d,"method":"%s"`, id, method)
	if params != "" do fmt.sbprintf(&b, `,"params":%s`, params)
	if session != "" do fmt.sbprintf(&b, `,"sessionId":"%s"`, session)
	strings.write_byte(&b, '}')
	sync.mutex_lock(&c.wmu)
	http.ws_send(c.ws, .Text, transmute([]byte)strings.to_string(b))
	sync.mutex_unlock(&c.wmu)
	return id
}

// call sends a command and waits for its response (raw JSON, caller frees).
call :: proc(c: ^Client, method: string, params := "", session := "", timeout := 30 * time.Second) -> (raw: string, ok: bool) {
	id := send_ex(c, method, params, session, true)
	start := time.tick_now()
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	for {
		if r, has := c.results[id]; has {
			delete_key(&c.results, id)
			delete_key(&c.waiting, id)
			return r, true
		}
		if c.dead do return "", false
		left := timeout - time.tick_since(start)
		if left <= 0 {
			delete_key(&c.waiting, id)
			return "", false
		}
		sync.cond_wait_with_timeout(&c.cond, &c.mu, left)
	}
}

// call_value is call + parse; the result object ("result" field) is returned.
call_value :: proc(c: ^Client, method: string, params := "", session := "", timeout := 30 * time.Second) -> (etf.Value, bool) {
	raw, ok := call(c, method, params, session, timeout)
	if !ok do return nil, false
	defer delete(raw)
	v, err := etf.from_json(raw, context.temp_allocator)
	if err != .None do return nil, false
	if _, has_err := get(v, "error"); has_err do return v, false
	r, _ := get(v, "result")
	return r, true
}

// next pops the next queued message (raw JSON, caller frees), waiting up to timeout.
next :: proc(c: ^Client, timeout: time.Duration) -> (string, bool) {
	start := time.tick_now()
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	for len(c.queue) == 0 {
		if c.dead do return "", false
		left := timeout - time.tick_since(start)
		if left <= 0 do return "", false
		sync.cond_wait_with_timeout(&c.cond, &c.mu, left)
	}
	m := c.queue[0]
	ordered_remove(&c.queue, 0)
	return m, true
}

is_dead :: proc(c: ^Client) -> bool {
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	return c.dead
}

// ---- JSON helpers over etf.Value (ordered) ----

get :: proc(v: etf.Value, keys: ..string) -> (etf.Value, bool) {
	cur := v
	for k in keys {
		m, is_map := cur.(etf.Map)
		if !is_map do return nil, false
		nv, found := etf.map_get(m, k)
		if !found do return nil, false
		cur = nv
	}
	return cur, true
}

str :: proc(v: etf.Value, keys: ..string) -> string {
	x, _ := get(v, ..keys)
	s, _ := x.(string)
	return s
}

num :: proc(v: etf.Value, keys: ..string) -> f64 {
	x, _ := get(v, ..keys)
	#partial switch n in x {
	case i64:
		return f64(n)
	case f64:
		return n
	}
	return 0
}

boolean :: proc(v: etf.Value, keys: ..string) -> bool {
	x, _ := get(v, ..keys)
	b, _ := x.(bool)
	return b
}

// quote returns s as a JSON string literal.
quote :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	etf.write_json_string(&sb, s)
	return strings.to_string(sb)
}

to_json :: proc(v: etf.Value, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	etf.to_json(v, &sb)
	return strings.to_string(sb)
}
