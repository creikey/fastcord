package capture

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "cdp"
import "fc:etf"
import "fc:zstd"

// Raw recording format (.secrets/raw/*.jsonl), one object per line:
//   {"rt":ms,"acct":"a","m":<CDP message>}                      Network.*/Target.* events
//   {"rt":ms,"acct":"a","body_for":"<requestId>","s":"<session>","m":<getResponseBody reply>}
//   {"rt":ms,"acct":"a","gw":{"dir":"send"|"recv","ws":"<requestId>","len":n},"etf":<decoded>}
//   {"rt":ms,"acct":"a","mark":"<name>"}
//   {"rt":ms,"acct":"a","note":"..."}                           driver diagnostics
// rt is milliseconds since the recording started (shared by both accounts).

Out :: struct {
	f:     ^os.File,
	mu:    sync.Mutex,
	start: time.Tick,
}

out_open :: proc(path: string) -> (^Out, bool) {
	f, err := os.open(path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if err != nil do return nil, false
	o := new(Out)
	o.f = f
	o.start = time.tick_now()
	return o, true
}

out_close :: proc(o: ^Out) {
	os.close(o.f)
	free(o)
}

rt_now :: proc(o: ^Out) -> f64 {return f64(time.tick_since(o.start)) / f64(time.Millisecond)}

// out_line writes `{"rt":..,"acct":"x",<rest>}`; rest is pre-rendered JSON members.
out_line :: proc(o: ^Out, acct: string, rest: string) {
	line := fmt.tprintf(`{{"rt":%.1f,"acct":"%s",%s}}`+"\n", rt_now(o), acct, rest)
	sync.mutex_lock(&o.mu)
	os.write_string(o.f, line)
	sync.mutex_unlock(&o.mu)
}

Gw_Socket :: struct {
	url:  string,
	zs:   bool,
	dec:  zstd.Stream_Decoder,
	buf:  [dynamic]byte,
}

Body_Req :: struct {
	session, rid: string,
}

Gw_Event :: struct {
	rt:   f64,
	dir:  string, // "send"/"recv"
	op:   i64,
	name: string, // dispatch t
}

Recorder :: struct {
	acct:         string,
	c:            ^cdp.Client,
	out:          ^Out,
	page_session: string,
	stop:         bool,
	th:           ^thread.Thread,
	mu:           sync.Mutex, // guards everything below (driver reads it)
	sockets:      map[string]^Gw_Socket,
	types:        map[string]string, // session/requestId -> resourceType
	bodies:       map[int]Body_Req,
	gw_events:    [dynamic]Gw_Event,
	requests:     [dynamic]string, // "METHOD url" in send order
	loading:      int, // in-flight requests (for settle detection)
	sessions:     [dynamic]string, // every attached session (detached in recorder_stop)
	aborted:      bool, // watchdog tripped
	heap_peak:    f64,
	last_net:     f64, // rt of last network activity
}

// Memory safety (the instances once ran out of RAM under capture):
//   - modest DevTools network buffers; bodies are fetched right at loadingFinished
//     and only for XHR/Fetch/Document, so Chrome never has to retain much
//   - targets are not paused on start (waitForDebuggerOnStart=false)
//   - recorder_stop disables every domain it enabled and detaches every session
//   - a watchdog aborts when the page's JS heap exceeds HEAP_LIMIT
NET_ENABLE :: `{"maxTotalBufferSize":10000000,"maxResourceBufferSize":5000000,"maxPostDataSize":1000000}`
AUTO_ATTACH :: `{"autoAttach":true,"waitForDebuggerOnStart":false,"flatten":true}`
AUTO_ATTACH_OFF :: `{"autoAttach":false,"waitForDebuggerOnStart":false}`
HEAP_LIMIT :: 1536 * 1024 * 1024
MAX_CAPTURE_SECONDS :: 900 // nothing runs unattended for long
WATCHDOG_EVERY :: 5 * time.Second

recorder_start :: proc(acct: string, port: int, out: ^Out) -> (r: ^Recorder, ok: bool) {
	c := cdp.connect(port) or_return
	r = new(Recorder)
	r.acct = acct
	r.c = c
	r.out = out
	r.sockets = make(map[string]^Gw_Socket)
	r.types = make(map[string]string)
	r.bodies = make(map[int]Body_Req)
	r.th = thread.create_and_start_with_poly_data(r, recorder_loop, init_context = context)
	cdp.send(c, "Target.setAutoAttach", AUTO_ATTACH)
	// wait for the app page to be attached
	for _ in 0 ..< 100 {
		sync.mutex_lock(&r.mu)
		have := r.page_session != ""
		sync.mutex_unlock(&r.mu)
		if have do return r, true
		time.sleep(100 * time.Millisecond)
	}
	fmt.eprintln(acct, ": app page never attached")
	return r, false
}

// recorder_stop undoes everything the recorder did to the instance: stops
// auto-attach, disables Network/Emulation on every session, detaches them,
// then closes the DevTools connection.
recorder_stop :: proc(r: ^Recorder) {
	sync.atomic_store(&r.stop, true)
	thread.join(r.th)
	thread.destroy(r.th)
	cdp.call(r.c, "Target.setAutoAttach", AUTO_ATTACH_OFF, timeout = 5 * time.Second)
	for s in r.sessions {
		cdp.call(r.c, "Network.disable", "", s, 5 * time.Second)
		if s == r.page_session do cdp.call(r.c, "Emulation.setFocusEmulationEnabled", `{"enabled":false}`, s, 5 * time.Second)
		cdp.call(r.c, "Target.setAutoAttach", AUTO_ATTACH_OFF, s, 5 * time.Second)
	}
	for i := len(r.sessions) - 1; i >= 0; i -= 1 {
		cdp.call(r.c, "Target.detachFromTarget", fmt.tprintf(`{{"sessionId":%s}}`, cdp.quote(r.sessions[i])), timeout = 5 * time.Second)
	}
	cdp.close(r.c)
	for s in r.sessions do delete(s)
	delete(r.sessions)
}

// heap_check reads the page's JS heap (Runtime.getHeapUsage needs no domain
// enable). Returns false and marks the recorder aborted above HEAP_LIMIT.
heap_check :: proc(r: ^Recorder) -> bool {
	v, ok := cdp.call_value(r.c, "Runtime.getHeapUsage", "", r.page_session, 10 * time.Second)
	if !ok do return true
	used := cdp.num(v, "usedSize")
	r.heap_peak = max(r.heap_peak, used)
	if used > HEAP_LIMIT {
		sync.atomic_store(&r.aborted, true)
		out_line(r.out, r.acct, fmt.tprintf(`"note":"watchdog: JS heap %.0f MB > limit, aborting"`, used / (1 << 20)))
		fmt.eprintfln("%s: watchdog: JS heap %.0f MB exceeds limit; aborting capture", r.acct, used / (1 << 20))
		return false
	}
	return true
}

@(private)
recorder_loop :: proc(r: ^Recorder) {
	for !sync.atomic_load(&r.stop) {
		raw, ok := cdp.next(r.c, 200 * time.Millisecond)
		if !ok {
			if cdp.is_dead(r.c) do return
			continue
		}
		handle_message(r, raw)
		delete(raw)
		free_all(context.temp_allocator)
	}
}

@(private)
key_of :: proc(session, rid: string) -> string {return fmt.aprintf("%s/%s", session, rid)}

@(private)
handle_message :: proc(r: ^Recorder, raw: string) {
	v, err := etf.from_json(raw, context.temp_allocator)
	if err != .None do return
	session := cdp.str(v, "sessionId")
	if _, is_resp := cdp.get(v, "id"); is_resp {
		id := int(cdp.num(v, "id"))
		sync.mutex_lock(&r.mu)
		b, pending := r.bodies[id]
		if pending do delete_key(&r.bodies, id)
		sync.mutex_unlock(&r.mu)
		if pending {
			out_line(r.out, r.acct, fmt.tprintf(`"body_for":%s,"s":%s,"m":%s`, cdp.quote(b.rid), cdp.quote(b.session), raw))
			delete(b.rid)
			delete(b.session)
		}
		return
	}
	method := cdp.str(v, "method")
	params, _ := cdp.get(v, "params")
	switch method {
	case "Target.attachedToTarget":
		child := cdp.str(params, "sessionId")
		type := cdp.str(params, "targetInfo", "type")
		url := cdp.str(params, "targetInfo", "url")
		sync.mutex_lock(&r.mu)
		append(&r.sessions, strings.clone(child))
		sync.mutex_unlock(&r.mu)
		cdp.send(r.c, "Network.enable", NET_ENABLE, child)
		cdp.send(r.c, "Target.setAutoAttach", AUTO_ATTACH, child)
		cdp.send(r.c, "Runtime.runIfWaitingForDebugger", "", child)
		if type == "page" && strings.has_prefix(url, "https://discord.com/") && !strings.contains(url, "popout") {
			sync.mutex_lock(&r.mu)
			if r.page_session == "" do r.page_session = strings.clone(child)
			sync.mutex_unlock(&r.mu)
		}
	case "Target.detachedFromTarget":
		gone := cdp.str(params, "sessionId")
		sync.mutex_lock(&r.mu)
		for x, i in r.sessions {
			if x == gone {
				delete(x)
				unordered_remove(&r.sessions, i)
				break
			}
		}
		sync.mutex_unlock(&r.mu)
	case "Network.requestWillBeSent":
		rid := cdp.str(params, "requestId")
		sync.mutex_lock(&r.mu)
		r.types[key_of(session, rid)] = strings.clone(cdp.str(params, "type"))
		append(&r.requests, fmt.aprintf("%s %s", cdp.str(params, "request", "method"), cdp.str(params, "request", "url")))
		r.loading += 1
		r.last_net = rt_now(r.out)
		sync.mutex_unlock(&r.mu)
	case "Network.loadingFinished", "Network.loadingFailed":
		rid := cdp.str(params, "requestId")
		k := key_of(session, rid)
		defer delete(k)
		sync.mutex_lock(&r.mu)
		type := r.types[k]
		r.loading = max(r.loading - 1, 0)
		r.last_net = rt_now(r.out)
		sync.mutex_unlock(&r.mu)
		if method == "Network.loadingFinished" && want_body(type) {
			id := cdp.send(r.c, "Network.getResponseBody", fmt.tprintf(`{{"requestId":%s}}`, cdp.quote(rid)), session)
			sync.mutex_lock(&r.mu)
			r.bodies[id] = {strings.clone(session), strings.clone(rid)}
			sync.mutex_unlock(&r.mu)
		}
	case "Network.webSocketCreated":
		rid := cdp.str(params, "requestId")
		url := cdp.str(params, "url")
		s := new(Gw_Socket)
		s.url = strings.clone(url)
		s.zs = strings.contains(url, "compress=zstd-stream")
		if s.zs do zstd.stream_init(&s.dec)
		sync.mutex_lock(&r.mu)
		r.sockets[strings.clone(rid)] = s
		sync.mutex_unlock(&r.mu)
	case "Network.webSocketFrameReceived", "Network.webSocketFrameSent":
		handle_frame(r, params, method == "Network.webSocketFrameSent")
	}
	if method == "Network.dataReceived" do return // high volume, no protocol value
	if strings.has_prefix(method, "Network.") || strings.has_prefix(method, "Target.") {
		out_line(r.out, r.acct, fmt.tprintf(`"m":%s`, raw))
	}
}

@(private)
want_body :: proc(type: string) -> bool {
	switch type {
	case "XHR", "Fetch", "Document", "Preflight", "Other", "EventSource":
		return true
	}
	return false
}

@(private)
handle_frame :: proc(r: ^Recorder, params: etf.Value, sent: bool) {
	rid := cdp.str(params, "requestId")
	if cdp.num(params, "response", "opcode") != 2 do return
	sync.mutex_lock(&r.mu)
	s, found := r.sockets[rid]
	sync.mutex_unlock(&r.mu)
	if !found do return
	data, derr := base64.decode(cdp.str(params, "response", "payloadData"), allocator = context.temp_allocator)
	if derr != nil do return
	payload := data
	if !sent && s.zs {
		clear(&s.buf)
		if zerr := zstd.stream_decode(&s.dec, data, &s.buf); zerr != .None {
			out_line(r.out, r.acct, fmt.tprintf(`"note":"zstd error %v on %s"`, zerr, rid))
			return
		}
		payload = s.buf[:]
	}
	v, eerr := etf.decode(payload, {}, context.temp_allocator)
	if eerr != .None {
		out_line(r.out, r.acct, fmt.tprintf(`"note":"etf error %v on %s (%d bytes)"`, eerr, rid, len(payload)))
		return
	}
	m, _ := v.(etf.Map)
	opv, _ := etf.map_get(m, "op")
	op, _ := opv.(i64)
	tv, _ := etf.map_get(m, "t")
	name := ""
	#partial switch t in tv {
	case string:
		name = t
	case etf.Atom:
		name = string(t)
	}
	dir := "send" if sent else "recv"
	sync.mutex_lock(&r.mu)
	append(&r.gw_events, Gw_Event{rt = rt_now(r.out), dir = dir, op = op, name = strings.clone(name)})
	sync.mutex_unlock(&r.mu)
	out_line(r.out, r.acct, fmt.tprintf(`"gw":{{"dir":"%s","ws":%s,"len":%d}},"etf":%s`, dir, cdp.quote(rid), len(data), cdp.to_json(v)))
}

record_passive :: proc(port: int, path: string, secs: int) -> bool {
	out, ok := out_open(path)
	if !ok do return false
	defer out_close(out)
	r, rok := recorder_start("a", port, out)
	if !rok do return false
	start := time.tick_now()
	for time.tick_since(start) < time.Duration(min(secs, MAX_CAPTURE_SECONDS)) * time.Second {
		time.sleep(WATCHDOG_EVERY)
		if !heap_check(r) do break
	}
	recorder_stop(r)
	return !r.aborted
}
