// Raw recording format (.secrets/raw/*.jsonl), one object per line:
//   {"rt":ms,"acct":"a","m":<CDP message>}                      Network.*/Target.* events
//   {"rt":ms,"acct":"a","body_for":"<requestId>","s":"<session>","m":<getResponseBody reply>}
//   {"rt":ms,"acct":"a","gw":{"dir":"send"|"recv","ws":"<requestId>","len":n},"etf":<decoded>}
//   {"rt":ms,"acct":"a","mark":"<name>"}
//   {"rt":ms,"acct":"a","note":"..."}                           driver diagnostics
// rt is milliseconds since the recording started (shared by both accounts).

Out :: struct {
	f: *os.File;
	mu: sync.Mutex;
	start: time.Tick;
}

out_open :: (path: string) -> *Out, bool {
	f, err := os.open(path, .{.Write, .Create, .Trunc}, .{.Read_User, .Write_User});
	if err != null { return null, false; }
	o := new(Out);
	o.f = f;
	o.start = time.tick_now();
	return o, true;
}

out_close :: (o: *Out) {
	os.close(o.f);
	free(o);
}

rt_now :: (o: *Out) -> float64 {return cast(float64)(time.tick_since(o.start)) / cast(float64)(time.Millisecond);}

// out_line writes `{"rt":..,"acct":"x",<rest>}`; rest is pre-rendered JSON members.
out_line :: (o: *Out, acct: string, rest: string) {
	line := fmt.tprintf("{{\"rt\":%.1f,\"acct\":\"%s\",%s}}"+"\n", rt_now(o), acct, rest);
	sync.mutex_lock(*o.mu);
	os.write_string(o.f, line);
	sync.mutex_unlock(*o.mu);
}

Gw_Socket :: struct {
	url: string;
	zs: bool;
	dec: zstd.Stream_Decoder;
	buf: [..]u8;
}

Body_Req :: struct {
	session, rid: string;
}

Gw_Event :: struct {
	rt: float64;
	dir: string; // "send"/"recv"
	op: s64;
	name: string; // dispatch t
}

Recorder :: struct {
	acct: string;
	c: *cdp.Client;
	out: *Out;
	page_session: string;
	stop: bool;
	th: *thread.Thread;
	mu: sync.Mutex; // guards everything below (driver reads it)
	sockets: Map(string, *Gw_Socket);
	types: Map(string, string); // session/requestId -> resourceType
	bodies: Map(int, Body_Req);
	gw_events: [..]Gw_Event;
	requests: [..]string; // "METHOD url" in send order
	loading: int; // in-flight requests (for settle detection)
	sessions: [..]string; // every attached session (detached in recorder_stop)
	aborted: bool; // watchdog tripped
	heap_peak: float64;
	last_net: float64; // rt of last network activity
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
HEAP_LIMIT :: 1536 * 1024 * 1024;
MAX_CAPTURE_SECONDS :: 900; // nothing runs unattended for long
WATCHDOG_EVERY :: 5 * time.Second;

recorder_start :: (acct: string, port: int, out: *Out) -> *Recorder, bool {
	r: *Recorder;
	ok: bool;
	c, __e1 := cdp.connect(port); if failed(__e1) return r, __e1;
	r = new(Recorder);
	r.acct = acct;
	r.c = c;
	r.out = out;
	r.sockets = Map(string, *Gw_Socket).{};
	r.types = Map(string, string).{};
	r.bodies = Map(int, Body_Req).{};
	r.th = thread.create_and_start_with_poly_data(r, recorder_loop);
	cdp.send(c, "Target.setAutoAttach", AUTO_ATTACH);
	// wait for the app page to be attached
	for _: 0..99 {
		sync.mutex_lock(*r.mu);
		have := r.page_session != "";
		sync.mutex_unlock(*r.mu);
		if have { return r, true; }
		time.sleep(100 * time.Millisecond);
	}
	fmt.eprintln(acct, ": app page never attached");
	return r, false;
}

// recorder_stop undoes everything the recorder did to the instance: stops
// auto-attach, disables Network/Emulation on every session, detaches them,
// then closes the DevTools connection.
recorder_stop :: (r: *Recorder) {
	atomic_store(*r.stop, true);
	thread.join(r.th);
	thread.destroy(r.th);
	cdp.call(r.c, "Target.setAutoAttach", AUTO_ATTACH_OFF, timeout = 5 * time.Second);
	for s: r.sessions {
		cdp.call(r.c, "Network.disable", "", s, 5 * time.Second);
		if s == r.page_session { cdp.call(r.c, "Emulation.setFocusEmulationEnabled", "{\"enabled\":false}", s, 5 * time.Second); }
		cdp.call(r.c, "Target.setAutoAttach", AUTO_ATTACH_OFF, s, 5 * time.Second);
	}
	for < i: len(r.sessions) - 1..0 {
		cdp.call(r.c, "Target.detachFromTarget", fmt.tprintf("{{\"sessionId\":%s}}", cdp.quote(get(r.sessions, i))), timeout = 5 * time.Second);
	}
	cdp.close(r.c);
	for s: r.sessions { delete(s); }
	delete(r.sessions);
}

// heap_check reads the page's JS heap (Runtime.getHeapUsage needs no domain
// enable). Returns false and marks the recorder aborted above HEAP_LIMIT.
heap_check :: (r: *Recorder) -> bool {
	v, ok := cdp.call_value(r.c, "Runtime.getHeapUsage", "", r.page_session, 10 * time.Second);
	if !ok { return true; }
	used := cdp.num(v, "usedSize");
	r.heap_peak = max(r.heap_peak, used);
	if used > HEAP_LIMIT {
		atomic_store(*r.aborted, true);
		out_line(r.out, r.acct, fmt.tprintf("\"note\":\"watchdog: JS heap %.0f MB > limit, aborting\"", used / (1 << 20)));
		fmt.eprintfln("%s: watchdog: JS heap %.0f MB exceeds limit; aborting capture", r.acct, used / (1 << 20));
		return false;
	}
	return true;
}
#scope_module

recorder_loop :: (r: *Recorder) {
	while !atomic_load(*r.stop) {
		raw, ok := cdp.next(r.c, 200 * time.Millisecond);
		if !ok {
			if cdp.is_dead(r.c) { return; }
			continue;
		}
		handle_message(r, raw);
		delete(raw);
		free_all(temp);
	}
}

key_of :: (session: string, rid: string) -> string {return fmt.aprintf("%s/%s", session, rid);}

handle_message :: (r: *Recorder, raw: string) {
	v, err := etf.from_json(raw, temp);
	if err != .None { return; }
	session := cdp.str(v, "sessionId");
	{ _, is_resp := cdp.get(v, "id");
	if is_resp {
		id := cast(int)(cdp.num(v, "id"));
		sync.mutex_lock(*r.mu);
		b, pending := map_find(r.bodies, id);
		if pending { delete_key(*r.bodies, id); }
		sync.mutex_unlock(*r.mu);
		if pending {
			out_line(r.out, r.acct, fmt.tprintf("\"body_for\":%s,\"s\":%s,\"m\":%s", cdp.quote(b.rid), cdp.quote(b.session), raw));
			delete(b.rid);
			delete(b.session);
		}
		return;
	} }
	method := cdp.str(v, "method");
	params, _ := cdp.get(v, "params");
	if method == {
	case "Target.attachedToTarget";
		child := cdp.str(params, "sessionId");
		type := cdp.str(params, "targetInfo", "type");
		url := cdp.str(params, "targetInfo", "url");
		sync.mutex_lock(*r.mu);
		append(*r.sessions, clone(child));
		sync.mutex_unlock(*r.mu);
		cdp.send(r.c, "Network.enable", NET_ENABLE, child);
		cdp.send(r.c, "Target.setAutoAttach", AUTO_ATTACH, child);
		cdp.send(r.c, "Runtime.runIfWaitingForDebugger", "", child);
		if type == "page" && strings.has_prefix(url, "https://discord.com/") && !strings.contains(url, "popout") {
			sync.mutex_lock(*r.mu);
			if r.page_session == "" { r.page_session = clone(child); }
			sync.mutex_unlock(*r.mu);
		}
	case "Target.detachedFromTarget";
		gone := cdp.str(params, "sessionId");
		sync.mutex_lock(*r.mu);
		for x, i: r.sessions {
			if x == gone {
				delete(x);
				unordered_remove(*r.sessions, i);
				break;
			}
		}
		sync.mutex_unlock(*r.mu);
	case "Network.requestWillBeSent";
		rid := cdp.str(params, "requestId");
		sync.mutex_lock(*r.mu);
		at(*r.types, key_of(session, rid)).* = clone(cdp.str(params, "type"));
		append(*r.requests, fmt.aprintf("%s %s", cdp.str(params, "request", "method"), cdp.str(params, "request", "url")));
		r.loading += 1;
		r.last_net = rt_now(r.out);
		sync.mutex_unlock(*r.mu);
	case "Network.loadingFinished"; #through; case "Network.loadingFailed";
		rid := cdp.str(params, "requestId");
		k := key_of(session, rid);
		defer delete(k);
		sync.mutex_lock(*r.mu);
		type := get(r.types, k);
		r.loading = max(r.loading - 1, 0);
		r.last_net = rt_now(r.out);
		sync.mutex_unlock(*r.mu);
		if method == "Network.loadingFinished" && want_body(type) {
			id := cdp.send(r.c, "Network.getResponseBody", fmt.tprintf("{{\"requestId\":%s}}", cdp.quote(rid)), session);
			sync.mutex_lock(*r.mu);
			at(*r.bodies, id).* = .{clone(session), clone(rid)};
			sync.mutex_unlock(*r.mu);
		}
	case "Network.webSocketCreated";
		rid := cdp.str(params, "requestId");
		url := cdp.str(params, "url");
		s := new(Gw_Socket);
		s.url = clone(url);
		s.zs = strings.contains(url, "compress=zstd-stream");
		if s.zs { zstd.stream_init(*s.dec); }
		sync.mutex_lock(*r.mu);
		at(*r.sockets, clone(rid)).* = s;
		sync.mutex_unlock(*r.mu);
	case "Network.webSocketFrameReceived"; #through; case "Network.webSocketFrameSent";
		handle_frame(r, params, method == "Network.webSocketFrameSent");
	}
	if method == "Network.dataReceived" { return; } // high volume, no protocol value
	if strings.has_prefix(method, "Network.") || strings.has_prefix(method, "Target.") {
		out_line(r.out, r.acct, fmt.tprintf("\"m\":%s", raw));
	}
}

want_body :: (type: string) -> bool {
	if type == {
	case "XHR"; #through; case "Fetch"; #through; case "Document"; #through; case "Preflight"; #through; case "Other"; #through; case "EventSource";
		return true;
	}
	return false;
}

handle_frame :: (r: *Recorder, params: etf.Value, sent: bool) {
	rid := cdp.str(params, "requestId");
	if cdp.num(params, "response", "opcode") != 2 { return; }
	sync.mutex_lock(*r.mu);
	s, found := map_find(r.sockets, rid);
	sync.mutex_unlock(*r.mu);
	if !found { return; }
	data, derr := base64.decode(cdp.str(params, "response", "payloadData"), allocator = temp);
	if derr != null { return; }
	payload := data;
	if !sent && s.zs {
		clear(*s.buf);
		{ zerr := zstd.stream_decode(*s.dec, data, *s.buf);
		if zerr != .None {
			out_line(r.out, r.acct, fmt.tprintf("\"note\":\"zstd error %v on %s\"", zerr, rid));
			return;
		} }
		payload = view(s.buf);
	}
	v, eerr := etf.decode(payload, .{}, temp);
	if eerr != .None {
		out_line(r.out, r.acct, fmt.tprintf("\"note\":\"etf error %v on %s (%d bytes)\"", eerr, rid, len(payload)));
		return;
	}
	m, _ := v.map, v.kind == .Map;
	opv, _ := etf.map_get(m, "op");
	op, _ := opv.i, opv.kind == .Int;
	tv, _ := etf.map_get(m, "t");
	name := "";
	if tv.kind == {
	case .String; t := tv.s;
		name = t;
	case .Atom; t := tv.s;
		name = as_string(t);
	}
	dir := ifx sent then "send" else "recv";
	sync.mutex_lock(*r.mu);
	append(*r.gw_events, Gw_Event.{rt = rt_now(r.out), dir = dir, op = op, name = clone(name)});
	sync.mutex_unlock(*r.mu);
	out_line(r.out, r.acct, fmt.tprintf("\"gw\":{{\"dir\":\"%s\",\"ws\":%s,\"len\":%d}},\"etf\":%s", dir, cdp.quote(rid), len(data), cdp.to_json(v)));
}
#scope_export

record_passive :: (port: int, path: string, secs: int) -> bool {
	out, ok := out_open(path);
	if !ok { return false; }
	defer out_close(out);
	r, rok := recorder_start("a", port, out);
	if !rok { return false; }
	start := time.tick_now();
	while time.tick_since(start) < time.Duration(min(secs, MAX_CAPTURE_SECONDS)) * time.Second {
		time.sleep(WATCHDOG_EVERY);
		if !heap_check(r) { break; }
	}
	recorder_stop(r);
	return !r.aborted;
}

