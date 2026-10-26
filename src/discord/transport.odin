package discord

import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "fc:brotli"
import "fc:http"
import "fc:netio"
import "fc:zstd"

// Transport: one connection pool per origin, like Chrome's socket pools.
//   - TLS with Chrome's ClientHello, ALPN {"h2","http/1.1"}.
//   - HTTP/2 when negotiated (every Discord origin today); one session per
//     origin shared by all requests, kept read-serviced by a thread so PING/
//     SETTINGS/GOAWAY are handled while idle, as Chrome does.
//   - HTTP/1.1 keep-alive fallback.
//   - Alt-Svc: responses' `alt-svc: h3=":443"` are cached (and persisted) the
//     way Chrome's HttpServerProperties does. When an H3_Hook is installed and
//     the origin has a live h3 alternative that isn't marked broken, requests
//     go to the hook first and fall back to h2 on failure (the alternative is
//     then marked broken for 5 min, doubling per failure). This is the seam
//     for src/quic.
//   - Set-Cookie is applied to the jar; Content-Encoding (gzip/br/zstd) decoded.

Transport_Error :: enum u8 {
	None,
	Dial,
	Tls,
	Protocol,
	Timeout,
	Closed,
	Decode,
}

H3_Hook :: struct {
	data:       rawptr,
	round_trip: proc(data: rawptr, host: string, port: int, req: http.Request) -> (http.Response, http.Error),
}

// Round_Tripper replaces the network entirely (tests, replay of recorded traffic).
Round_Tripper :: struct {
	data:       rawptr,
	round_trip: proc(data: rawptr, host: string, req: http.Request) -> (http.Response, http.Error),
}

Alt_Svc :: struct {
	h3_port:      int,
	expires:      i64, // unix ms
	broken_until: i64,
	broken_count: int,
}

@(private)
H2_Ref :: struct {
	c:       ^http.H2_Conn,
	svc:     ^thread.Thread,
	refs:    int,
	retired: bool,
}

@(private)
Origin :: struct {
	host:    string,
	h2:      ^H2_Ref,
	idle_h1: [dynamic]^http.H1_Conn,
	dialing: bool,
}

Transport :: struct {
	mu:        sync.Mutex,
	cond:      sync.Cond,
	origins:   map[string]^Origin,
	alt_svc:   map[string]Alt_Svc,
	h3:        H3_Hook,
	override:  Round_Tripper,
	jar:       ^Cookie_Jar,
	allocator: Allocator,
	closed:    bool,
	// observer sees every request as sent (header order included) and its response: traffic tooling.
	observer:  proc(data: rawptr, host: string, req: http.Request, resp: ^http.Response, err: http.Error),
	observer_data: rawptr,
}

@(private)
decoders_once: sync.Once

@(private)
br_decoder :: proc(src: []byte, dst: ^[dynamic]byte, max_out: int) -> http.Error {
	out, err := brotli.decompress(src, context.temp_allocator, max_out)
	if err != .None do return .Decompress
	append(dst, ..out)
	return .None
}

@(private)
zstd_decoder :: proc(src: []byte, dst: ^[dynamic]byte, max_out: int) -> http.Error {
	out, err := zstd.decompress(src, context.temp_allocator, max_out)
	if err != .None do return .Decompress
	append(dst, ..out)
	return .None
}

register_content_decoders :: proc() {
	sync.once_do(&decoders_once, proc() {
		http.register_decoder("br", br_decoder)
		http.register_decoder("zstd", zstd_decoder)
	})
}

transport_init :: proc(t: ^Transport, jar: ^Cookie_Jar, allocator := context.allocator) {
	register_content_decoders()
	t.allocator = allocator
	t.jar = jar
	t.origins = make(map[string]^Origin, allocator = allocator)
	t.alt_svc = make(map[string]Alt_Svc, allocator = allocator)
}

transport_destroy :: proc(t: ^Transport) {
	sync.mutex_lock(&t.mu)
	t.closed = true
	origins := t.origins
	t.origins = {}
	sync.mutex_unlock(&t.mu)
	for k, o in origins {
		if o.h2 != nil {
			sync.mutex_lock(&t.mu)
			r := o.h2
			o.h2 = nil
			r.retired = true
			fin := r.refs == 0
			sync.mutex_unlock(&t.mu)
			if fin do h2_finalize(t, r)
		}
		for c in o.idle_h1 {
			http.h1_destroy(c)
			free(c, t.allocator)
		}
		delete(o.idle_h1)
		delete(o.host, t.allocator)
		free(o, t.allocator)
		delete(k, t.allocator)
	}
	delete(origins)
	for k in t.alt_svc do delete(k, t.allocator)
	delete(t.alt_svc)
}

@(private)
h2_service_proc :: proc(th: ^thread.Thread) {
	c := cast(^http.H2_Conn)th.data
	_ = http.h2_service(c)
}

// transport_round_trip sends req to https://host and returns the decoded response.
transport_round_trip :: proc(t: ^Transport, host: string, req: http.Request) -> (resp: http.Response, err: http.Error) {
	req := req
	if req.scheme == "" do req.scheme = "https"
	if req.authority == "" do req.authority = host
	defer if t.observer != nil do t.observer(t.observer_data, host, req, &resp, err)

	if t.override.round_trip != nil {
		resp, err = t.override.round_trip(t.override.data, host, req)
	} else {
		resp, err = network_round_trip(t, host, req)
	}
	if err != .None do return
	now := now_ms()
	for h in resp.headers {
		if strings.equal_fold(h.name, "set-cookie") && t.jar != nil {
			cookie_set_from_header(t.jar, host, req.path, h.value, now)
		} else if strings.equal_fold(h.name, "alt-svc") {
			transport_note_alt_svc(t, host, h.value, now)
		}
	}
	if derr := http.decode_body(&resp); derr != .None do err = derr
	return
}

@(private)
network_round_trip :: proc(t: ^Transport, host: string, req: http.Request) -> (resp: http.Response, err: http.Error) {
	if t.h3.round_trip != nil {
		if port, ok := transport_h3_alternative(t, host); ok {
			resp, err = t.h3.round_trip(t.h3.data, host, port, req)
			if err == .None do return
			transport_mark_h3_broken(t, host)
		}
	}
	for attempt in 0 ..< 2 {
		o, ref := origin_get_h2(t, host)
		if ref != nil {
			resp, err = http.h2_request(ref.c, req)
			// Refused / GOAWAY before processing: safe to retry on a new session (Chrome does).
			retry := err == .Refused || err == .Goaway || (err == .Closed && attempt == 0)
			if retry do origin_drop_h2(t, o, ref)
			h2_release(t, ref)
			if retry do continue
			return
		}
		if o == nil do return {}, .Io
		// HTTP/1.1
		c := origin_take_h1(t, o)
		if c == nil do return {}, .Io
		resp, err = http.h1_round_trip(c, req)
		if err == .None && c.reusable {
			origin_put_h1(t, o, c)
		} else {
			http.h1_destroy(c)
			free(c, t.allocator)
			if err == .Closed && attempt == 0 do continue
		}
		return
	}
	return
}

@(private)
origin_lookup :: proc(t: ^Transport, host: string) -> ^Origin {
	o, ok := t.origins[host]
	if !ok {
		o = new(Origin, t.allocator)
		o.host = strings.clone(host, t.allocator)
		o.idle_h1 = make([dynamic]^http.H1_Conn, t.allocator)
		t.origins[strings.clone(host, t.allocator)] = o
	}
	return o
}

// origin_get_h2 returns a referenced h2 session, dialing if needed. If the
// server negotiated http/1.1 the connection is parked as an idle h1 conn and ref=nil.
@(private)
origin_get_h2 :: proc(t: ^Transport, host: string) -> (o: ^Origin, ref: ^H2_Ref) {
	sync.mutex_lock(&t.mu)
	if t.closed {
		sync.mutex_unlock(&t.mu)
		return nil, nil
	}
	o = origin_lookup(t, host)
	for {
		if o.h2 != nil && http.h2_can_open(o.h2.c) {
			o.h2.refs += 1
			r := o.h2
			sync.mutex_unlock(&t.mu)
			return o, r
		}
		if o.h2 != nil {
			r := o.h2
			o.h2 = nil
			r.retired = true
			if r.refs == 0 {
				sync.mutex_unlock(&t.mu)
				h2_finalize(t, r)
				sync.mutex_lock(&t.mu)
			}
			continue
		}
		if len(o.idle_h1) > 0 {
			sync.mutex_unlock(&t.mu)
			return o, nil
		}
		if !o.dialing do break
		sync.cond_wait(&t.cond, &t.mu)
	}
	o.dialing = true
	sync.mutex_unlock(&t.mu)

	stream, alpn, dok := dial_tls_stream(host, {"h2", "http/1.1"})
	new_h2: ^http.H2_Conn
	new_h1: ^http.H1_Conn
	if dok {
		if alpn == "h2" {
			c, herr := http.h2_connect(stream, {}, t.allocator)
			if herr == .None {
				new_h2 = c
			} else {
				netio.close(stream)
			}
		} else {
			new_h1 = new(http.H1_Conn, t.allocator)
			http.h1_init(new_h1, stream, {}, t.allocator)
		}
	}

	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	o.dialing = false
	sync.cond_broadcast(&t.cond)
	if new_h2 != nil {
		r := new(H2_Ref, t.allocator)
		r.c = new_h2
		r.svc = thread.create(h2_service_proc)
		r.svc.data = new_h2
		r.svc.init_context = context
		thread.start(r.svc)
		r.refs = 1
		o.h2 = r
		return o, r
	}
	if new_h1 != nil {
		append(&o.idle_h1, new_h1)
		return o, nil
	}
	return nil, nil
}

@(private)
h2_finalize :: proc(t: ^Transport, r: ^H2_Ref) {
	http.h2_close(r.c) // wakes the service thread, waits for users, frees the conn
	if r.svc != nil {
		thread.join(r.svc)
		thread.destroy(r.svc)
	}
	free(r, t.allocator)
}

@(private)
h2_release :: proc(t: ^Transport, r: ^H2_Ref) {
	sync.mutex_lock(&t.mu)
	r.refs -= 1
	fin := r.retired && r.refs == 0
	sync.mutex_unlock(&t.mu)
	if fin do h2_finalize(t, r)
}

@(private)
origin_drop_h2 :: proc(t: ^Transport, o: ^Origin, r: ^H2_Ref) {
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	if o != nil && o.h2 == r {
		o.h2 = nil
		r.retired = true // finalized by the last h2_release
	}
}

@(private)
origin_take_h1 :: proc(t: ^Transport, o: ^Origin) -> ^http.H1_Conn {
	sync.mutex_lock(&t.mu)
	if n := len(o.idle_h1); n > 0 {
		c := pop(&o.idle_h1)
		sync.mutex_unlock(&t.mu)
		return c
	}
	sync.mutex_unlock(&t.mu)
	stream, _, dok := dial_tls_stream(o.host, {"h2", "http/1.1"})
	if !dok do return nil
	c := new(http.H1_Conn, t.allocator)
	http.h1_init(c, stream, {}, t.allocator)
	return c
}

@(private)
origin_put_h1 :: proc(t: ^Transport, o: ^Origin, c: ^http.H1_Conn) {
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	if len(o.idle_h1) < 6 && !t.closed {
		append(&o.idle_h1, c)
	} else {
		http.h1_destroy(c)
		free(c, t.allocator)
	}
}

// ---- Alt-Svc ----

// transport_note_alt_svc parses `h3=":443"; ma=86400, h3-29=":443"` (and `clear`).
transport_note_alt_svc :: proc(t: ^Transport, host, value: string, now: i64) {
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	v := strings.trim_space(value)
	if v == "clear" {
		if k, _, ok := map_entry_key(t, host); ok {
			delete_key(&t.alt_svc, k)
			delete(k, t.allocator)
		}
		return
	}
	it := v
	for entry in strings.split_iterator(&it, ",") {
		e := strings.trim_space(entry)
		parts := strings.split(e, ";", context.temp_allocator)
		alpn_auth := strings.trim_space(parts[0])
		eq := strings.index_byte(alpn_auth, '=')
		if eq < 0 do continue
		proto := alpn_auth[:eq]
		if proto != "h3" do continue
		auth := strings.trim(alpn_auth[eq + 1:], "\"")
		colon := strings.last_index_byte(auth, ':')
		if colon < 0 do continue
		if colon > 0 && auth[:colon] != host do continue // alternative host: not supported
		port, pok := strconv.parse_int(auth[colon + 1:])
		if !pok do continue
		ma := 86400
		for p in parts[1:] {
			kv := strings.trim_space(p)
			if strings.has_prefix(kv, "ma=") {
				if m, ok := strconv.parse_int(kv[3:]); ok do ma = m
			}
		}
		prev, had := t.alt_svc[host]
		entry_v := Alt_Svc{h3_port = port, expires = now + i64(ma) * 1000}
		if had {
			entry_v.broken_until = prev.broken_until
			entry_v.broken_count = prev.broken_count
			t.alt_svc[host] = entry_v
		} else {
			t.alt_svc[strings.clone(host, t.allocator)] = entry_v
		}
		return
	}
}

@(private)
map_entry_key :: proc(t: ^Transport, host: string) -> (string, Alt_Svc, bool) {
	for k, v in t.alt_svc do if k == host do return k, v, true
	return "", {}, false
}

transport_h3_alternative :: proc(t: ^Transport, host: string) -> (port: int, ok: bool) {
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	a, found := t.alt_svc[host]
	now := now_ms()
	if !found || a.expires <= now || a.broken_until > now do return 0, false
	return a.h3_port, true
}

transport_mark_h3_broken :: proc(t: ^Transport, host: string) {
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	a, found := t.alt_svc[host]
	if !found do return
	a.broken_count += 1
	a.broken_until = now_ms() + i64(5 * 60 * 1000) << uint(min(a.broken_count - 1, 6))
	t.alt_svc[host] = a
}

transport_save_alt_svc :: proc(t: ^Transport, path: string) -> bool {
	sync.mutex_lock(&t.mu)
	sb := strings.builder_make(context.temp_allocator)
	for k, v in t.alt_svc {
		strings.write_string(&sb, k)
		strings.write_byte(&sb, '\t')
		strings.write_int(&sb, v.h3_port)
		strings.write_byte(&sb, '\t')
		strings.write_i64(&sb, v.expires)
		strings.write_byte(&sb, '\n')
	}
	sync.mutex_unlock(&t.mu)
	return write_file_atomic(path, transmute([]byte)strings.to_string(sb))
}

transport_load_alt_svc :: proc(t: ^Transport, data: string) {
	sync.mutex_lock(&t.mu)
	defer sync.mutex_unlock(&t.mu)
	text := data
	now := now_ms()
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) != 3 do continue
		port, _ := strconv.parse_int(f[1])
		exp, _ := strconv.parse_i64(f[2])
		if exp <= now do continue
		if _, had := t.alt_svc[f[0]]; had do continue
		t.alt_svc[strings.clone(f[0], t.allocator)] = Alt_Svc{h3_port = port, expires = exp}
	}
}
