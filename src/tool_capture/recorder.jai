// Raw recording format (.secrets/raw/*.jsonl), one object per line:
//   {"rt":ms,"acct":"a","m":<CDP message>}                      Network.*/Target.* events
//   {"rt":ms,"acct":"a","body_for":"<requestId>","s":"<session>","m":<getResponseBody reply>}
//   {"rt":ms,"acct":"a","gw":{"dir":"send"|"recv","ws":"<requestId>","len":n},"etf":<decoded>}
//   {"rt":ms,"acct":"a","mark":"<name>"}
//   {"rt":ms,"acct":"a","note":"..."}                           driver diagnostics
// rt is milliseconds since the recording started (shared by both accounts).

Out :: struct {
    fd: s32;
    mu: locks.Mutex;
    start: Apollo_Time;
}

out_open :: (path: string) -> *Out, bool {
    fd := open_private(path);
    if fd < 0 return null, false;
    o := New(Out);
    o.fd = fd;
    o.start = current_time_monotonic();
    return o, true;
}

out_close :: (o: *Out) {
    close(o.fd);
    free(o);
}

rt_now :: (o: *Out) -> float64 { return cast(float64) to_nanoseconds(current_time_monotonic() - o.start) / 1_000_000; }

// out_line writes `{"rt":..,"acct":"x",<rest>}`; rest is pre-rendered JSON members.
out_line :: (o: *Out, acct: string, rest: string) {
    line := tprint("{\"rt\":%,\"acct\":\"%\",%}\n", f1(rt_now(o)), acct, rest);
    locks.guard(*o.mu);
    write_all(o.fd, line);
}

Gw_Socket :: struct {
    zs: bool;
    dec: zstd.Stream_Decoder;
    buf: [..]u8;
}

Body_Req :: struct { session, rid: string; }

Gw_Event :: struct {
    rt: float64;
    dir: string;   // "send"/"recv"
    op: s64;
    name: string;  // dispatch t
}

Recorder :: struct {
    acct: string;
    c: *cdp.Client;
    out: *Out;
    page_session: string;
    stop: bool;
    th: *Thread;
    mu: locks.Mutex;  // guards everything below (driver reads it)
    sockets: Table(string, *Gw_Socket);
    types: Table(string, string);  // session/requestId -> resourceType
    bodies: Table(int, Body_Req);
    gw_events: [..]Gw_Event;
    requests: [..]string;  // "METHOD url" in send order
    loading: int;          // in-flight requests (for settle detection)
    sessions: [..]string;  // every attached session (detached in recorder_stop)
    aborted: bool;         // watchdog tripped
    heap_peak: float64;
    last_net: float64;     // rt of last network activity
}

// Memory safety (the instances once ran out of RAM under capture):
//   - modest DevTools network buffers; bodies are fetched right at loadingFinished
//     and only for XHR/Fetch/Document, so Chrome never has to retain much
//   - targets are not paused on start (waitForDebuggerOnStart=false)
//   - recorder_stop disables every domain it enabled and detaches every session
//   - a watchdog aborts when the page's JS heap exceeds HEAP_LIMIT
NET_ENABLE :: "{\"maxTotalBufferSize\":10000000,\"maxResourceBufferSize\":5000000,\"maxPostDataSize\":1000000}";
AUTO_ATTACH :: "{\"autoAttach\":true,\"waitForDebuggerOnStart\":false,\"flatten\":true}";
AUTO_ATTACH_OFF :: "{\"autoAttach\":false,\"waitForDebuggerOnStart\":false}";
HEAP_LIMIT :: 1536.0 * 1024 * 1024;
MAX_CAPTURE_SECONDS :: 900;  // nothing runs unattended for long
WATCHDOG_EVERY_MS :: 5_000;

recorder_start :: (acct: string, port: int, out: *Out) -> *Recorder, bool {
    c, ok := cdp.connect(port);
    if !ok return null, false;
    r := New(Recorder);
    r.acct = acct;
    r.c = c;
    r.out = out;
    r.th = New(Thread);
    thread_init(r.th, (t: *Thread) -> s64 {
        r := cast(*Recorder) t.data;
        while !atomic_load(*r.stop) {
            raw, ok := cdp.next(r.c, 200);
            if !ok {
                if cdp.is_dead(r.c) return 0;
                continue;
            }
            handle_message(r, raw);
            free(raw);
            reset_temporary_storage();
        }
        return 0;
    });
    r.th.data = r;
    thread_start(r.th);
    cdp.send(c, "Target.setAutoAttach", AUTO_ATTACH);
    // wait for the app page to be attached
    for 1..100 {
        {
            locks.guard(*r.mu);
            if r.page_session return r, true;
        }
        sleep_milliseconds(100);
    }
    eprint("% : app page never attached\n", acct);
    return r, false;
}

// recorder_stop undoes everything the recorder did to the instance: stops
// auto-attach, disables Network/Emulation on every session, detaches them,
// then closes the DevTools connection.
recorder_stop :: (r: *Recorder) {
    atomic_store(*r.stop, true);
    locks.join(r.th);
    cdp.call(r.c, "Target.setAutoAttach", AUTO_ATTACH_OFF, timeout_ms = 5_000);
    for r.sessions {
        cdp.call(r.c, "Network.disable", "", it, 5_000);
        if it == r.page_session cdp.call(r.c, "Emulation.setFocusEmulationEnabled", "{\"enabled\":false}", it, 5_000);
        cdp.call(r.c, "Target.setAutoAttach", AUTO_ATTACH_OFF, it, 5_000);
    }
    for < r.sessions cdp.call(r.c, "Target.detachFromTarget", tprint("{\"sessionId\":%}", cdp.quote(it)), timeout_ms = 5_000);
    cdp.close(r.c);
    for r.sessions free(it);
    array_free(r.sessions);
}

// heap_check reads the page's JS heap (Runtime.getHeapUsage needs no domain
// enable). Returns false and marks the recorder aborted above HEAP_LIMIT.
heap_check :: (r: *Recorder) -> bool {
    v, ok := cdp.call_value(r.c, "Runtime.getHeapUsage", "", r.page_session, 10_000);
    if !ok return true;
    used := cdp.num(v, "usedSize");
    r.heap_peak = max(r.heap_peak, used);
    if used <= HEAP_LIMIT return true;
    atomic_store(*r.aborted, true);
    mb := formatFloat(used / (1 << 20), trailing_width = 0);
    out_line(r.out, r.acct, tprint("\"note\":\"watchdog: JS heap % MB > limit, aborting\"", mb));
    eprint("%: watchdog: JS heap % MB exceeds limit; aborting capture\n", r.acct, mb);
    return false;
}

#scope_file

key_of :: (session: string, rid: string) -> string { return tprint("%/%", session, rid); }

handle_message :: (r: *Recorder, raw: string) {
    v, err := etf.from_json(raw,, temp);
    if err != .None return;
    session := cdp.str(v, "sessionId");
    _, is_resp := cdp.get(v, "id");
    if is_resp {
        id := cast(int) cdp.num(v, "id");
        locks.lock(*r.mu);
        pending, b := table_remove(*r.bodies, id);
        locks.unlock(*r.mu);
        if pending {
            out_line(r.out, r.acct, tprint("\"body_for\":%,\"s\":%,\"m\":%", cdp.quote(b.rid), cdp.quote(b.session), raw));
            free(b.rid);
            free(b.session);
        }
        return;
    }
    method := cdp.str(v, "method");
    params := cdp.get(v, "params");
    rid := cdp.str(params, "requestId");
    if method == {
      case "Target.attachedToTarget";
        child := cdp.str(params, "sessionId");
        url := cdp.str(params, "targetInfo", "url");
        page := cdp.str(params, "targetInfo", "type") == "page" && begins_with(url, "https://discord.com/") && !contains(url, "popout");
        {
            locks.guard(*r.mu);
            array_add(*r.sessions, copy_string(child));
        }
        cdp.send(r.c, "Network.enable", NET_ENABLE, child);
        cdp.send(r.c, "Target.setAutoAttach", AUTO_ATTACH, child);
        cdp.send(r.c, "Runtime.runIfWaitingForDebugger", "", child);
        if page {
            locks.guard(*r.mu);
            if !r.page_session r.page_session = copy_string(child);
        }
      case "Target.detachedFromTarget";
        gone := cdp.str(params, "sessionId");
        locks.guard(*r.mu);
        for r.sessions if it == gone {
            free(it);
            array_unordered_remove_by_index(*r.sessions, it_index);
            break;
        }
      case "Network.requestWillBeSent";
        locks.guard(*r.mu);
        table_set(*r.types, sprint("%/%", session, rid), copy_string(cdp.str(params, "type")));
        array_add(*r.requests, sprint("% %", cdp.str(params, "request", "method"), cdp.str(params, "request", "url")));
        r.loading += 1;
        r.last_net = rt_now(r.out);
      case "Network.loadingFinished"; #through;
      case "Network.loadingFailed";
        type: string;
        {
            locks.guard(*r.mu);
            _, type = table_find(*r.types, key_of(session, rid));
            r.loading = max(r.loading - 1, 0);
            r.last_net = rt_now(r.out);
        }
        if method == "Network.loadingFinished" && array_find(string.["XHR", "Fetch", "Document", "Preflight", "Other", "EventSource"], type) {
            id := cdp.send(r.c, "Network.getResponseBody", tprint("{\"requestId\":%}", cdp.quote(rid)), session);
            locks.guard(*r.mu);
            table_set(*r.bodies, id, .{copy_string(session), copy_string(rid)});
        }
      case "Network.webSocketCreated";
        s := New(Gw_Socket);
        s.zs = contains(cdp.str(params, "url"), "compress=zstd-stream");
        if s.zs zstd.stream_init(*s.dec);
        locks.guard(*r.mu);
        table_set(*r.sockets, copy_string(rid), s);
      case "Network.webSocketFrameReceived"; #through;
      case "Network.webSocketFrameSent";
        handle_frame(r, params, method == "Network.webSocketFrameSent");
    }
    if method == "Network.dataReceived" return;  // high volume, no protocol value
    if begins_with(method, "Network.") || begins_with(method, "Target.") out_line(r.out, r.acct, tprint("\"m\":%", raw));
}

handle_frame :: (r: *Recorder, params: etf.Value, sent: bool) {
    rid := cdp.str(params, "requestId");
    if cdp.num(params, "response", "opcode") != 2 return;
    locks.lock(*r.mu);
    found, s := table_find(*r.sockets, rid);
    locks.unlock(*r.mu);
    if !found return;
    data, ok := base64_decode(cdp.str(params, "response", "payloadData"),, temp);
    if !ok return;
    payload := cast([]u8) data;
    if !sent && s.zs {
        s.buf.count = 0;
        zerr := zstd.stream_decode(*s.dec, payload, *s.buf);
        if zerr != .None {
            out_line(r.out, r.acct, tprint("\"note\":\"zstd error % on %\"", zerr, rid));
            return;
        }
        payload = s.buf;
    }
    v, eerr := etf.decode(payload,, temp);
    if eerr != .None {
        out_line(r.out, r.acct, tprint("\"note\":\"etf error % on % (% bytes)\"", eerr, rid, payload.count));
        return;
    }
    op := ifx v.kind == .Map then etf.map_get(v.map, "op") else etf.Value.{};
    t := ifx v.kind == .Map then etf.map_get(v.map, "t") else etf.Value.{};
    dir := ifx sent then "send" else "recv";
    {
        locks.guard(*r.mu);
        array_add(*r.gw_events, .{rt = rt_now(r.out), dir = dir, op = ifx op.kind == .Int then op.i else 0,
            name = copy_string(ifx t.kind == .String || t.kind == .Atom then t.s else "")});
    }
    out_line(r.out, r.acct, tprint("\"gw\":{\"dir\":\"%\",\"ws\":%,\"len\":%},\"etf\":%", dir, cdp.quote(rid), data.count, cdp.to_json(v)));
}

#scope_export

record_passive :: (port: int, path: string, secs: int) -> bool {
    out, ok := out_open(path);
    if !ok return false;
    defer out_close(out);
    r, rok := recorder_start("a", port, out);
    if !rok return false;
    start := current_time_monotonic();
    while to_milliseconds(current_time_monotonic() - start) < min(secs, MAX_CAPTURE_SECONDS) * 1000 {
        sleep_milliseconds(WATCHDOG_EVERY_MS);
        if !heap_check(r) break;
    }
    recorder_stop(r);
    return !r.aborted;
}
