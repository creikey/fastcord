// A small Chrome DevTools Protocol client over http's WebSocket. Used to record and drive the
// official Discord desktop client.
//
// One reader thread receives everything. Responses to `call` wake the caller;
// all other messages (events, and responses to fire-and-forget `send`s) are
// queued for `next`.

Client :: struct {
    ws: *http.Ws_Conn;
    mu: locks.Mutex;
    cond: locks.Cond;
    wmu: locks.Mutex;
    next_id: int;
    waiting: Table(int, bool);  // ids a `call` is blocked on
    results: Table(int, string);
    queue: [..]string;          // raw JSON messages for next()
    dead: bool;
    reader: *Thread;
}

// browser_ws_url asks a DevTools port for its browser-level endpoint (in context.allocator).
browser_ws_url :: (port: int) -> string, bool {
    tcp, err := netio.dial_tcp("127.0.0.1", port);
    if err != .None return "", false;
    c: http.H1_Conn;
    http.h1_init(*c, netio.tcp_stream(tcp));
    defer http.h1_destroy(*c);
    headers := http.Header.[.{"Host", tprint("127.0.0.1:%", port)}, .{"Connection", "close"}];
    resp, rerr := http.h1_round_trip(*c, .{method = "GET", path = "/json/version", headers = headers},, temp);
    if rerr != .None || resp.status != 200 return "", false;
    v, jerr := etf.from_json(cast(string) resp.body,, temp);
    url := str(v, "webSocketDebuggerUrl");
    if jerr != .None || !url return "", false;
    return copy_string(url), true;
}

connect :: (port: int) -> *Client, bool {
    url, ok := browser_ws_url(port,, temp);
    if !ok return null, false;
    if begins_with(url, "ws://") advance(*url, 5);
    slash := find_index_from_left(url, #char "/");
    if slash < 0 return null, false;
    tcp, err := netio.dial_tcp("127.0.0.1", port);
    if err != .None return null, false;
    s := netio.tcp_stream(tcp);
    headers := http.Header.[.{"Host", slice(url, 0, slash)}, .{"Connection", "Upgrade"}, .{"Upgrade", "websocket"},
        .{"Sec-WebSocket-Version", "13"}, .{"Sec-WebSocket-Key", ""}];
    ws, resp, herr := http.ws_connect(s, .{path = slice(url, slash, url.count - slash), headers = headers}, .{max_message = 512 << 20});
    http.response_destroy(*resp);
    if herr != .None {
        netio.close(s);
        return null, false;
    }
    c := New(Client);
    c.ws = ws;
    c.next_id = 1;
    c.reader = New(Thread);
    thread_init(c.reader, reader_loop);
    c.reader.data = c;
    thread_start(c.reader);
    return c, true;
}

close :: (c: *Client) {
    netio.shutdown(c.ws.s);
    locks.join(c.reader);
    http.ws_close_stream(c.ws);
    for c.queue free(it);
    array_free(c.queue);
    for c.results free(it);
    deinit(*c.results);
    deinit(*c.waiting);
    free(c);
}

#scope_file

reader_loop :: (t: *Thread) -> s64 {
    c := cast(*Client) t.data;
    msg: [..]u8;
    defer array_free(msg);
    while true {
        _, err := http.ws_recv(c.ws, *msg);
        if err != .None {
            locks.guard(*c.mu);
            c.dead = true;
            locks.cond_broadcast(*c.cond);
            return 0;
        }
        raw := copy_string(cast(string) msg);
        id := -1;
        // Chrome serializes responses as {"id":N,...}; events start with "method".
        if begins_with(raw, "{\"id\":") id = string_to_int(slice(raw, 6, raw.count - 6));
        locks.guard(*c.mu);
        if id >= 0 && table_find_pointer(*c.waiting, id) table_set(*c.results, id, raw);
        else array_add(*c.queue, raw);
        locks.cond_broadcast(*c.cond);
    }
    return 0;
}

send_ex :: (c: *Client, method: string, params: string, session: string, wait: bool) -> int {
    id: int;
    {
        locks.guard(*c.mu);
        id = c.next_id;
        c.next_id += 1;
        if wait table_set(*c.waiting, id, true);
    }
    b: String_Builder;
    b.allocator = temp;
    print_to_builder(*b, "{\"id\":%,\"method\":\"%\"", id, method);
    if params  print_to_builder(*b, ",\"params\":%", params);
    if session print_to_builder(*b, ",\"sessionId\":\"%\"", session);
    append(*b, "}");
    locks.guard(*c.wmu);
    http.ws_send(c.ws, .Text, cast([]u8) builder_to_string(*b,, temp));
    return id;
}

// wait_for waits on c.cond (c.mu held) until ready() or the deadline; false on timeout or a dead connection.
wait_for :: (c: *Client, timeout_ms: s64, ready: Code) -> bool #expand {
    start := current_time_monotonic();
    while !#insert ready {
        if c.dead return false;
        left := timeout_ms - to_milliseconds(current_time_monotonic() - start);
        if left <= 0 return false;
        locks.cond_wait_with_timeout(*c.cond, *c.mu, left);
    }
    return true;
}

#scope_export

// send fires a command and returns its id; the response arrives via next().
// params is a JSON object text ("" = none).
send :: (c: *Client, method: string, params := "", session := "") -> int {
    return send_ex(c, method, params, session, false);
}

// call sends a command and waits for its response (raw JSON, caller frees).
call :: (c: *Client, method: string, params := "", session := "", timeout_ms: s64 = 30_000) -> raw: string, ok: bool {
    id := send_ex(c, method, params, session, true);
    locks.guard(*c.mu);
    got := wait_for(c, timeout_ms, #code table_find_pointer(*c.results, id) != null);
    table_remove(*c.waiting, id);
    if !got return "", false;
    _, r := table_remove(*c.results, id);
    return r, true;
}

// call_value is call + parse (into temp); the result object ("result" field) is returned.
call_value :: (c: *Client, method: string, params := "", session := "", timeout_ms: s64 = 30_000) -> etf.Value, bool {
    raw, ok := call(c, method, params, session, timeout_ms);
    if !ok return .{}, false;
    defer free(raw);
    v, err := etf.from_json(raw,, temp);
    if err != .None return .{}, false;
    _, has_err := get(v, "error");
    if has_err return v, false;
    r := get(v, "result");
    return r, true;
}

// next pops the next queued message (raw JSON, caller frees), waiting up to timeout_ms.
next :: (c: *Client, timeout_ms: s64) -> string, bool {
    locks.guard(*c.mu);
    if !wait_for(c, timeout_ms, #code c.queue.count > 0) return "", false;
    m := c.queue[0];
    array_ordered_remove_by_index(*c.queue, 0);
    return m, true;
}

is_dead :: (c: *Client) -> bool {
    locks.guard(*c.mu);
    return c.dead;
}

// ---- JSON helpers over etf.Value (ordered) ----

get :: (v: etf.Value, keys: ..string) -> etf.Value, bool {
    cur := v;
    for keys {
        if cur.kind != .Map return .{}, false;
        nv, found := etf.map_get(cur.map, it);
        if !found return .{}, false;
        cur = nv;
    }
    return cur, true;
}

str :: (v: etf.Value, keys: ..string) -> string {
    x := get(v, ..keys);
    return ifx x.kind == .String then x.s else "";
}

num :: (v: etf.Value, keys: ..string) -> float64 {
    x := get(v, ..keys);
    if x.kind == .Int   return cast(float64) x.i;
    if x.kind == .Float return x.f;
    return 0;
}

boolean :: (v: etf.Value, keys: ..string) -> bool {
    x := get(v, ..keys);
    return x.kind == .Bool && x.b;
}

// quote returns s as a JSON string literal, in temp.
quote :: (s: string) -> string {
    sb: String_Builder;
    sb.allocator = temp;
    etf.write_json_string(*sb, s);
    return builder_to_string(*sb,, temp);
}

// to_json renders v as JSON text, in temp.
to_json :: (v: etf.Value) -> string {
    sb: String_Builder;
    sb.allocator = temp;
    etf.to_json(v, *sb);
    return builder_to_string(*sb,, temp);
}
