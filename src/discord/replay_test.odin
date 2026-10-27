package discord

// Offline parity: the library runs a scenario's action against the official
// fixture (traffic/<scenario>.jsonl) with no network. HTTP is answered from the
// recorded responses (Config.round_tripper), gateway frames go to a sink
// (Config.gateway_sink) and the window's recorded dispatches are injected.
// What we send in the action window is compared with what the official client
// sent: request set (method + URL shape), true wire header order, body shape,
// and the gateway ops with their payload shapes.
//
// Run one: ./build.sh test discord -define:ODIN_TEST_NAMES=discord.parity_send_message
// (all of them run with the package tests, in a few seconds, offline).

import "core:fmt"
import "core:hash"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "fc:etf"
import "fc:http"
import "fc:locks"

@(private = "file")
R_GUILD :: Snowflake(1564227669971832975)
@(private = "file")
R_TEXT :: Snowflake(1564227670806364343)
@(private = "file")
R_VOICE :: Snowflake(1564227670806364345)
@(private = "file")
R_DM :: Snowflake(1564228964451356713)
@(private = "file")
R_B :: Snowflake(1564202918369042442)
// the test guild's text channel after it was recreated (fixtures threads_browser,
// history_nav, discover...: no system channel)
@(private = "file")
R_TEXT2 :: Snowflake(1564405699197407414)

// Requests the comparison leaves out: UI assets and images the app fetches
// itself, the RTC probe and Cloudflare's page challenge. Telemetry (/science)
// is compared on its own, per event (r_science_check).
@(private = "file")
R_IGNORE := [?]string{"/assets/", "collectibles-shop", "latency.discord.media", "/cdn-cgi/", "media.discordapp.net", "/app-icons/", "/emojis/", "/avatars/", "/stickers/", "images-ext"}

Replay :: struct {
	mu:      locks.Mutex,
	arena:   virtual.Arena,
	events:  [dynamic]etf.Map, // fixture lines (acct a), placeholders turned into ids
	used:    [dynamic]bool,
	ours:    [dynamic]Replay_Req,
	sends:   [dynamic]Replay_Send,
	science: [dynamic]Sci_Batch, // our /science POSTs since the mark
	marked:  bool,
}

Replay_Req :: struct {
	key:   string,
	wire:  string, // header names in send order
	shape: string,
}

Replay_Send :: struct {
	op:    i64,
	shape: string,
}

// ---- fixture ----

// Scrubbed values ("<new:2>", "<user:3>", "<id:...>") become stable fake
// snowflakes so the client can parse and reuse them; URL keys normalize ids again.
// New objects ("<new:N>") sort after the fixture's real ids, in creation order.
@(private = "file")
r_unscrub :: proc(v: V) -> V {
	#partial switch x in v {
	case string:
		if len(x) > 3 && x[0] == '<' && x[len(x) - 1] == '>' && strings.contains(x, ":") {
			// "<new:N>": created during the capture, in N order, after every real id
			if strings.has_prefix(x, "<new:") {
				if n, ok := strconv.parse_u64(x[5:len(x) - 1]); ok do return V(fmt.aprintf("%d", 1_700_000_000_000_000_000 + n << 22))
			}
			return V(fmt.aprintf("%d", 1_100_000_000_000_000_000 + u64(hash.fnv32a(transmute([]byte)x))))
		}
	case etf.List:
		for &e in x do e = r_unscrub(e)
	case etf.Map:
		for &p in x do p.value = r_unscrub(p.value)
	}
	return v
}

@(private = "file")
replay_load :: proc(r: ^Replay, scenario: string, acct := "a") -> bool {
	_ = virtual.arena_init_growing(&r.arena)
	context.allocator = virtual.arena_allocator(&r.arena)
	// appended to from worker threads later: keep them in the replay arena too
	r.ours = make([dynamic]Replay_Req)
	r.sends = make([dynamic]Replay_Send)
	r.science = make([dynamic]Sci_Batch)
	data, err := os.read_entire_file(fmt.tprintf("traffic/%s.jsonl", scenario), context.allocator) // tests run from the repo root
	if err != nil do return false
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		v, perr := etf.from_json(line)
		if perr != .None do continue
		m := vmap(v)
		// account a's lines carry no "acct" (or "a"); marks belong to both
		a := fstr(m, "acct")
		if a == "" do a = "a"
		if a != acct && fstr(m, "k") != "mark" do continue
		append(&r.events, vmap(r_unscrub(v)))
		append(&r.used, false)
	}
	return true
}

// window: the fixture events between mark `name` and the next mark.
@(private = "file")
replay_window :: proc(r: ^Replay, name: string) -> []etf.Map {
	start, end := -1, len(r.events)
	for e, i in r.events {
		if fstr(e, "k") != "mark" do continue
		if start >= 0 {
			end = i
			break
		}
		if fstr(e, "name") == name do start = i + 1
	}
	if start < 0 do return nil
	return r.events[start:end]
}

// URL key: host + path with ids folded to {id}, query names without values.
@(private = "file")
r_key :: proc(method, url: string) -> string {
	u := url
	if i := strings.index(u, "://"); i >= 0 do u = u[i + 3:]
	path, query := u, ""
	if i := strings.index_byte(u, '?'); i >= 0 do path, query = u[:i], u[i + 1:]
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "%s ", method)
	for seg, i in strings.split(path, "/", context.temp_allocator) {
		if i > 0 do strings.write_byte(&sb, '/')
		digits := len(seg) >= 15
		for ch in seg do if ch < '0' || ch > '9' do digits = false
		strings.write_string(&sb, "{id}" if digits || (strings.has_prefix(seg, "%3C") || strings.has_prefix(seg, "<")) else seg)
	}
	if query != "" {
		strings.write_byte(&sb, '?')
		for kv, i in strings.split(query, "&", context.temp_allocator) {
			if i > 0 do strings.write_byte(&sb, '&')
			strings.write_string(&sb, kv[:strings.index_byte(kv, '=')] if strings.contains(kv, "=") else kv)
		}
	}
	return strings.to_string(sb)
}

@(private = "file")
r_ignored :: proc(url: string) -> bool {
	for s in R_IGNORE do if strings.contains(url, s) do return true
	return false
}

@(private = "file")
r_shape :: proc(v: V, sb: ^strings.Builder, depth := 0) {
	switch x in v {
	case nil:
		strings.write_string(sb, "null")
	case bool:
		strings.write_string(sb, "bool")
	case i64, f64, etf.Big:
		strings.write_string(sb, "num")
	case string, etf.Atom, etf.Charlist:
		// unscrubbed ids are numeric strings on both sides
		strings.write_string(sb, "str")
	case etf.List:
		strings.write_byte(sb, '[')
		if len(x) > 0 && depth < 12 do r_shape(x[0], sb, depth + 1)
		strings.write_byte(sb, ']')
	case etf.Tuple:
		strings.write_string(sb, "tuple")
	case etf.Map:
		strings.write_byte(sb, '{')
		for p, i in x {
			if i > 0 do strings.write_byte(sb, ',')
			fmt.sbprintf(sb, "%v:", p.key)
			r_shape(p.value, sb, depth + 1)
		}
		strings.write_byte(sb, '}')
	}
}

@(private = "file")
shape_text :: proc(v: V) -> string {
	sb := strings.builder_make(context.temp_allocator)
	r_shape(v, &sb)
	return strings.to_string(sb)
}

// fixture body value -> the JSON the server sent (or "" when only a hash was kept)
@(private = "file")
r_body_value :: proc(v: V) -> (V, bool) {
	if m := vmap(v); m != nil && len(m) == 1 {
		k := vstr(m[0].key)
		if k == "$b64json" do return m[0].value, true
		if strings.has_prefix(k, "$") do return nil, false
	}
	return v, v != nil
}

// Science event signature: its type and property names in order, without the
// per-event decorations (timestamps, uuids, performance) every event carries.
@(private = "file")
R_SCIENCE_DECOR := [?]string{"client_track_timestamp", "client_heartbeat_session_id", "event_sequence_number", "client_performance_cpu", "client_performance_memory", "cpu_core_count", "accessibility_features", "rendered_locale", "uptime_app", "uptime_process_renderer", "launch_signature", "client_rtc_state", "client_app_state", "client_viewport_width", "client_viewport_height", "client_uuid", "client_send_timestamp"}

@(private = "file")
r_event_sig :: proc(e: etf.Map) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, fstr(e, "type"))
	strings.write_byte(&sb, '{')
	first := true
	outer: for p in fmap(e, "properties") {
		k := vstr(p.key)
		for d in R_SCIENCE_DECOR do if d == k do continue outer
		if !first do strings.write_byte(&sb, ',')
		first = false
		strings.write_string(&sb, k)
	}
	strings.write_byte(&sb, '}')
	return strings.to_string(sb)
}

// ---- network stand-ins ----

@(private = "file")
replay_round_trip :: proc(data: rawptr, host: string, req: http.Request) -> (resp: http.Response, err: http.Error) {
	delay: f64
	resp, err, delay = replay_exchange(cast(^Replay)data, host, req)
	// after the mark, answer after the recorded latency (capped): response-time
	// events (telemetry, follow-ups) then land as far apart as they did officially
	if delay > 0 do time.sleep(time.Duration(min(delay, 1000) * f64(time.Millisecond)))
	return
}

@(private = "file")
replay_exchange :: proc(r: ^Replay, host: string, req: http.Request) -> (resp: http.Response, err: http.Error, delay_ms: f64) {
	locks.lock(&r.mu)
	defer locks.unlock(&r.mu)
	url := strings.concatenate({"https://", host, req.path}, context.temp_allocator)
	key := r_key(req.method, url)
	// the recorded exchange with the same URL shape, earliest first
	ri := -1
	for e, i in r.events {
		if r.used[i] || fstr(e, "k") != "req" do continue
		if r_key(fstr(e, "method"), fstr(e, "url")) == key {
			ri = i
			break
		}
	}
	proto := "h3"
	official_wire: etf.List
	if ri >= 0 {
		r.used[ri] = true
		proto = fstr(r.events[ri], "proto")
		official_wire, _ = vget(r.events[ri], "wire").(etf.List)
	}
	_ = official_wire
	if r.marked && !r_ignored(url) {
		// our wire order, as fc:http (h2) / fc:quic put it on the wire
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, ":method,:authority,:scheme,:path")
		has_priority := false
		for h in req.headers {
			n := strings.to_lower(h.name, context.temp_allocator)
			if n == "priority" do has_priority = true
			if n == "cookie" || n == "if-none-match" || n == "if-modified-since" do continue
			fmt.sbprintf(&sb, ",%s", n)
		}
		if proto == "h3" && !has_priority do strings.write_string(&sb, ",priority")
		shape := ""
		if len(req.body) > 0 {
			if v, perr := etf.from_json(string(req.body), context.temp_allocator); perr == .None do shape = shape_text(v)
		}
		alloc := virtual.arena_allocator(&r.arena)
		if r_is_science(url) {
			if v, perr := etf.from_json(string(req.body), context.temp_allocator); perr == .None {
				b := r_sci_parse(v, alloc)
				b.wire = strings.clone(strings.to_string(sb), alloc)
				append(&r.science, b)
			}
		} else {
			append(&r.ours, Replay_Req{strings.clone(key, alloc), strings.clone(strings.to_string(sb), alloc), strings.clone(shape, alloc)})
		}
	}
	resp.version = .Http3 if proto == "h3" else .Http2
	resp.status = 200
	body := "{}"
	if ri >= 0 {
		id := fnum(r.events[ri], "id")
		for e in r.events {
			if fstr(e, "k") != "resp" || fnum(e, "id") != id do continue
			if r.marked do delay_ms = r_num_f(vget(e, "t")) - r_num_f(vget(r.events[ri], "t"))
			resp.status = int(fnum(e, "status"))
			for h in flist(e, "headers") {
				l := vlist(h)
				if len(l) != 2 do continue
				n := vstr(l[0])
				if n == "content-encoding" || n == "content-length" do continue // the body below is decoded
				ha := virtual.arena_allocator(&r.arena) // the response is the transport's; strings live with the replay
				append(&resp.headers, http.Header{strings.clone(n, ha), strings.clone(vstr(l[1]), ha)})
			}
			if bv, ok := r_body_value(vget(e, "body")); ok {
				body = etf_json(bv)
			} else {
				body = ""
			}
			break
		}
	}
	append(&resp.body, ..transmute([]byte)body)
	return resp, .None, delay_ms
}

@(private = "file")
r_num_f :: proc(v: V) -> f64 {
	#partial switch x in v {
	case f64:
		return x
	case i64:
		return f64(x)
	}
	return 0
}

@(private = "file")
etf_json :: proc(v: V) -> string {
	sb := strings.builder_make(context.temp_allocator)
	etf.to_json(v, &sb)
	return strings.to_string(sb)
}

@(private = "file")
fnum :: proc(m: etf.Map, k: string) -> i64 {
	#partial switch x in vget(m, k) {
	case i64:
		return x
	case f64:
		return i64(x)
	}
	return 0
}

@(private = "file")
replay_sink :: proc(data: rawptr, op: Op, d: V) {
	r := cast(^Replay)data
	if op == .Heartbeat || op == .Qos_Heartbeat do return
	locks.lock(&r.mu)
	defer locks.unlock(&r.mu)
	if !r.marked do return
	append(&r.sends, Replay_Send{i64(op), strings.clone(shape_text(d), virtual.arena_allocator(&r.arena))})
}

// ---- driving ----

Replay_Run :: struct {
	r:       Replay,
	c:       ^Client,
	t:       ^testing.T,
	donor:   Replay, // ready_from's fixture (its READY)
	science: bool, // also compare /science events (type + property names); allow "science <type>"
}

@(private = "file")
// ready_from: a fixture of the same account whose READY / READY_SUPPLEMENTAL
// stand in when this one recorded none for the account (passive recordings that
// started on an open session).
replay_begin :: proc(run: ^Replay_Run, t: ^testing.T, scenario: string, guild, channel: Snowflake, acct := "a", ready_from := "") -> bool {
	run.t = t
	if !replay_load(&run.r, scenario, acct) {
		testing.expectf(t, false, "no fixture traffic/%s.jsonl", scenario)
		return false
	}
	ready_events := run.r.events[:]
	if ready_from != "" {
		donor: Replay
		if !replay_load(&donor, ready_from, acct) {
			testing.expectf(t, false, "no fixture traffic/%s.jsonl", ready_from)
			return false
		}
		// the donor's arena lives as long as the run: its values are injected below
		ready_events = slice.clone(donor.events[:], virtual.arena_allocator(&donor.arena))
		run.donor = donor
	}
	run.c = client_create(Config{
		token = "<token>",
		disable_startup = true,
		round_tripper = {&run.r, replay_round_trip},
		gateway_sink = replay_sink,
		gateway_sink_data = &run.r,
		initial_guild_id = guild,
		initial_channel_id = channel,
	})
	client_set_viewport(run.c, 1280, 720)
	client_set_accessibility(run.c, accessibility_flags({})) // light OS, store defaults: the fixtures' 524416
	identity_touch_heartbeat(&run.c.id, now_ms()) // the launch's heartbeat session (the window had focus)
	run.c.analytics.roundtrip_sample = 0 // send_message_roundtrip is sampled (10%): never offline
	identity_set_app_state(&run.c.id, .Unfocused)
	client_start(run.c)
	// session state from the fixture's READY
	for name in ([]string{"READY", "READY_SUPPLEMENTAL"}) {
		for e in ready_events {
			if fstr(e, "k") == "ws_recv" && fstr(e, "ev") == name {
				// what the gateway reader does with READY before dispatching it
				if inst := fstr(fmap(vmap(vget(e, "d")), "apex_experiments"), "installation"); inst != "" && name == "READY" {
					run.c.id.installation_id = strings.clone(inst, run.c.allocator)
				}
				client_inject_dispatch(run.c, name, vget(e, "d"))
				break
			}
		}
	}
	// READY's apex_experiments.installation is scrubbed from the fixtures
	if run.c.id.installation_id == "" do run.c.id.installation_id = strings.clone("1100000000000000001", run.c.allocator)
	replay_settle(run, 300)
	if channel != 0 || guild != 0 {
		select_channel(run.c, guild, channel, 10)
		replay_settle(run, 400)
	}
	replay_drain(run)
	return true
}

// replay_drain: before the first mark, wait (bounded) until the setup's queued
// analytics and REST jobs have gone out. replay_settle only sees requests made
// after a mark, so on a slow machine (CI) the setup's first /science batch
// could otherwise land in the action window.
@(private = "file")
replay_drain :: proc(run: ^Replay_Run, max_ms := 3000) {
	start := time.tick_now()
	for time.tick_since(start) < time.Duration(max_ms) * time.Millisecond {
		client_poll(run.c)
		locks.lock(&run.c.analytics.mu)
		queued := len(run.c.analytics.queue)
		locks.unlock(&run.c.analytics.mu)
		locks.lock(&run.c.job_mu)
		jobs := 0
		for j in run.c.jobs do if j.not_before <= now_ms() do jobs += 1 // timers due later belong to the session
		jobs += run.c.jobs_running
		locks.unlock(&run.c.job_mu)
		if queued == 0 && jobs == 0 do return
		time.sleep(5 * time.Millisecond)
	}
}

// replay_settle: poll until nothing new was sent for quiet_ms (bounded).
@(private = "file")
replay_settle :: proc(run: ^Replay_Run, quiet_ms: int, max_ms := 4000) {
	start := time.tick_now()
	last := time.tick_now()
	n := -1
	for time.tick_since(start) < time.Duration(max_ms) * time.Millisecond {
		client_poll(run.c)
		locks.lock(&run.r.mu)
		k := len(run.r.ours) + len(run.r.sends) + int(run.r.marked)
		locks.unlock(&run.r.mu)
		if k != n {
			n = k
			last = time.tick_now()
		}
		if time.tick_since(last) >= time.Duration(quiet_ms) * time.Millisecond do return
		time.sleep(5 * time.Millisecond)
	}
}

// replay_pump: poll for a fixed time (library timers: typing 1.5 s...).
@(private = "file")
replay_pump :: proc(run: ^Replay_Run, ms: int) {
	start := time.tick_now()
	for time.tick_since(start) < time.Duration(ms) * time.Millisecond {
		client_poll(run.c)
		time.sleep(5 * time.Millisecond)
	}
}

// replay_mark: start comparing from here (the official window `name`).
@(private = "file")
replay_mark :: proc(run: ^Replay_Run) {
	locks.lock(&run.r.mu)
	run.r.marked = true
	clear(&run.r.ours)
	clear(&run.r.sends)
	clear(&run.r.science)
	locks.unlock(&run.r.mu)
}

// replay_dispatches feeds the window's recorded dispatches (MESSAGE_CREATE...).
@(private = "file")
replay_dispatches :: proc(run: ^Replay_Run, window: string, only := "") {
	for e in replay_window(&run.r, window) {
		if fstr(e, "k") != "ws_recv" || fnum(e, "op") != 0 do continue
		ev := fstr(e, "ev")
		if only != "" && ev != only do continue
		client_inject_dispatch(run.c, ev, vget(e, "d"))
	}
}

// replay_end frees a run whose windows were checked with keep = true.
@(private = "file")
replay_end :: proc(run: ^Replay_Run) {
	client_destroy(run.c)
	virtual.arena_destroy(&run.r.arena)
	if run.donor.events != nil do virtual.arena_destroy(&run.donor.arena)
}

// replay_compare: one window of a multi-window run (the client is kept).
replay_compare :: proc(run: ^Replay_Run, window: string, allow: []string = nil) {
	replay_check(run, window, allow, keep = true)
}

// replay_check compares our traffic since the mark with the official window.
// allow: keys / "op N" that may differ (known, documented gaps).
// keep: the run goes on to the next window (finish with replay_end).
// science_only: compare only /science (windows whose request differences are
// session state documented in traffic/PARITY.md, not this test's subject).
@(private = "file")
replay_check :: proc(run: ^Replay_Run, window: string, extra_allow: []string = nil, keep := false, science_only := false) {
	t := run.t
	defer if !keep do replay_end(run)
	all := make([dynamic]string, context.temp_allocator)
	append(&all, ..R_SCI_NEVER)
	append(&all, ..extra_allow)
	allow := all[:]
	official := make([dynamic]etf.Map, context.temp_allocator)
	official_sci := make([dynamic]Sci_Batch, context.temp_allocator)
	ops := make([dynamic]etf.Map, context.temp_allocator)
	for e in replay_window(&run.r, window) {
		switch fstr(e, "k") {
		case "req":
			url := fstr(e, "url")
			if r_is_science(url) {
				if bv, ok := r_body_value(vget(e, "body")); ok {
					b := r_sci_parse(bv, context.temp_allocator)
					b.wire = r_official_wire(e)
					append(&official_sci, b)
				}
			} else if !r_ignored(url) {
				append(&official, e)
			}
		case "ws_send":
			if op := fnum(e, "op"); op != 1 && op != 40 do append(&ops, e)
		}
	}
	allowed :: proc(allow: []string, s: string) -> bool {
		for a in allow do if strings.contains(s, a) do return true
		return false
	}
	locks.lock(&run.r.mu)
	ours := slice.clone(run.r.ours[:], context.temp_allocator)
	sends := slice.clone(run.r.sends[:], context.temp_allocator)
	ours_sci := slice.clone(run.r.science[:], context.temp_allocator)
	locks.unlock(&run.r.mu)
	if science_only {
		clear(&official)
		clear(&ops)
		ours, sends = nil, nil
	}
	taken := make([]bool, len(ours), context.temp_allocator)
	diffs := strings.builder_make(context.temp_allocator)
	for e in official {
		key := r_key(fstr(e, "method"), fstr(e, "url"))
		j := -1
		for o, i in ours do if !taken[i] && o.key == key {j = i; break}
		if j < 0 {
			if !allowed(allow, key) do fmt.sbprintfln(&diffs, "  - missing  %s", key)
			continue
		}
		taken[j] = true
		// wire order (netlog), cache validators and cookies left out on both sides
		if w := r_official_wire(e); w != "" && w != ours[j].wire && !allowed(allow, key) {
			fmt.sbprintfln(&diffs, "  ~ wire     %s\n      official: %s\n      ours:     %s", key, w, ours[j].wire)
		}
		if bv, ok := r_body_value(vget(e, "body")); ok && ours[j].shape != "" {
			if s := shape_text(bv); s != ours[j].shape && !allowed(allow, key) {
				fmt.sbprintfln(&diffs, "  ~ body     %s\n      official: %s\n      ours:     %s", key, s, ours[j].shape)
			}
		}
	}
	for o, i in ours do if !taken[i] && !allowed(allow, o.key) do fmt.sbprintfln(&diffs, "  + extra    %s", o.key)
	// gateway: same ops in the same order, same payload shapes (allowed ops left out)
	{
		k := 0
		for e in ops do if !allowed(allow, fmt.tprintf("op %d", fnum(e, "op"))) {ops[k] = e; k += 1}
		resize(&ops, k)
		f := make([dynamic]Replay_Send, context.temp_allocator)
		for x in sends do if !allowed(allow, fmt.tprintf("op %d", x.op)) do append(&f, x)
		sends = f[:]
	}
	for i in 0 ..< max(len(ops), len(sends)) {
		if i >= len(ops) {
			if !allowed(allow, fmt.tprintf("op %d", sends[i].op)) do fmt.sbprintfln(&diffs, "  + extra    gateway op %d", sends[i].op)
			continue
		}
		op := fnum(ops[i], "op")
		if i >= len(sends) {
			if !allowed(allow, fmt.tprintf("op %d", op)) do fmt.sbprintfln(&diffs, "  - missing  gateway op %d", op)
			continue
		}
		if sends[i].op != op {
			fmt.sbprintfln(&diffs, "  ~ gateway #%d: op %d vs %d", i + 1, op, sends[i].op)
		} else if s := shape_text(vget(ops[i], "d")); s != sends[i].shape && !allowed(allow, fmt.tprintf("op %d", op)) {
			fmt.sbprintfln(&diffs, "  ~ gateway op %d payload\n      official: %s\n      ours:     %s", op, s, sends[i].shape)
		}
	}
	r_science_check(official_sci[:], ours_sci, allow, &diffs)
	if len(diffs.buf) > 0 do testing.expectf(t, false, "window %q differs from the official client:\n%s", window, strings.to_string(diffs))
}

// ---- telemetry (/science) ----
//
// Each POST /science is a batch of events. Per window the official and our
// events are compared in order: the event types, each event's property keys
// and their order, every value's type, and the values of constant-valued
// properties (locations, enums, flags; ids, timestamps, durations, counts and
// session ids differ by nature). Batching is checked too: events the official
// client queued in the same step (same batch, tracked within SCI_SAME_STEP_MS)
// must share a batch in ours, events it sent in different batches more than
// SCI_SEPARATE_MS apart must not,
// and our flush delay (send - first queued event) must stay within the
// official window's. Allow-list entries: "science:<type>" for an event we do
// not send (or send extra), "science:<type>.<key>" for one property's value,
// "science:batching" for batch boundaries.

Sci_Event :: struct {
	type:   string,
	keys:   []string,
	kinds:  []string, // value type per key
	consts: []string, // constant value per key, "" when the value is variable
	track:  i64,
	batch:  int,
}

Sci_Batch :: struct {
	events: []Sci_Event,
	send:   i64,
	wire:   string,
}

@(private = "file")
SCI_SAME_STEP_MS :: 3
// officially separate batches closer than this are flush timing, not steps
@(private = "file")
SCI_SEPARATE_MS :: 100

@(private = "file")
r_is_science :: proc(url: string) -> bool {return strings.contains(url, "/api/v9/science")}

@(private = "file")
r_allowed :: proc(allow: []string, s: string) -> bool {
	for a in allow do if strings.contains(s, a) do return true
	return false
}

// r_official_wire: the netlog header order of a fixture request (cookies and
// cache validators left out), "" without a netlog.
@(private = "file")
r_official_wire :: proc(e: etf.Map) -> string {
	wl, ok := vget(e, "wire").(etf.List)
	if !ok || fstr(e, "wire_src") != "netlog" do return ""
	sb := strings.builder_make(context.temp_allocator)
	first := true
	for h in wl {
		n := strings.to_lower(vstr(vlist(h)[0]), context.temp_allocator)
		if n == "cookie" || n == "if-none-match" || n == "if-modified-since" do continue
		if !first do strings.write_byte(&sb, ',')
		first = false
		strings.write_string(&sb, n)
	}
	return strings.to_string(sb)
}

// Keys whose numeric values are enums (compared by value).
@(private = "file")
SCI_NUM_ENUMS := [?]string{"channel_type", "parent_channel_type", "current_channel_type", "relationship_type", "content_id", "status_code", "channel_resolved_unread_setting", "guild_resolved_unread_setting", "version"}

// r_sci_const: the value of a constant-valued property, "" when it varies by nature.
@(private = "file")
r_sci_const :: proc(key: string, v: V) -> string {
	#partial switch x in v {
	case nil:
		return "null"
	case bool:
		return "true" if x else "false"
	case i64:
		for k in SCI_NUM_ENUMS do if k == key do return fmt.tprintf("%d", x)
	case string:
		if len(x) == 0 do return `""`
		digits := true
		for ch in x do if ch < '0' || ch > '9' do digits = false
		if digits do return "" // ids
		if len(x) >= 20 && !strings.contains(x, " ") && strings.contains_any(x, "0123456789") do return "" // uuids, base64, hex load ids
		if len(x) >= 19 && x[4] == '-' && strings.contains(x, "T") do return "" // ISO times
		switch key {
		case "query", "emoji_name", "launch_signature", "client_heartbeat_session_id", "client_uuid", "load_id":
			return ""
		}
		return fmt.tprintf("%q", x)
	}
	return ""
}

@(private = "file")
r_sci_kind :: proc(v: V) -> string {
	#partial switch _ in v {
	case etf.List, etf.Map:
		return shape_text(v)
	}
	sb := strings.builder_make(context.temp_allocator)
	r_shape(v, &sb)
	return strings.to_string(sb)
}

// r_sci_parse: one /science body. Strings live in `alloc`.
@(private = "file")
r_sci_parse :: proc(body: V, alloc: Allocator) -> (b: Sci_Batch) {
	evs := make([dynamic]Sci_Event, alloc)
	for ev in flist(vmap(body), "events") {
		m := vmap(ev)
		props := fmap(m, "properties")
		e := Sci_Event{type = strings.clone(fstr(m, "type"), alloc)}
		keys := make([dynamic]string, alloc)
		kinds := make([dynamic]string, alloc)
		consts := make([dynamic]string, alloc)
		for p in props {
			k := vstr(p.key)
			switch k {
			case "client_track_timestamp":
				e.track = vint(p.value)
			case "client_send_timestamp":
				b.send = vint(p.value)
			}
			append(&keys, strings.clone(k, alloc))
			append(&kinds, strings.clone(r_sci_kind(p.value), alloc))
			append(&consts, strings.clone(r_sci_const(k, p.value), alloc))
		}
		e.keys, e.kinds, e.consts = keys[:], kinds[:], consts[:]
		append(&evs, e)
	}
	b.events = evs[:]
	return
}

// r_sci_filtered: an allow entry `science:<type>/<key>=<const>` drops the events
// of that type whose property has that constant value (e.g. one profile_action).
@(private = "file")
r_sci_filtered :: proc(allow: []string, e: Sci_Event) -> bool {
	for a in allow {
		if !strings.has_prefix(a, "science:") do continue
		slash := strings.index_byte(a, '/')
		eq := strings.index_byte(a, '=')
		if slash < 0 || eq < slash || a[len("science:"):slash] != e.type do continue
		k, v := a[slash + 1:eq], a[eq + 1:]
		for key, i in e.keys do if key == k && e.consts[i] == v do return true
	}
	return false
}

@(private = "file")
r_sci_flatten :: proc(batches: []Sci_Batch, allow: []string) -> []Sci_Event {
	out := make([dynamic]Sci_Event, context.temp_allocator)
	for b, bi in batches {
		for e in b.events {
			if r_allowed(allow, fmt.tprintf("science:%s", e.type)) do continue
			if r_sci_filtered(allow, e) do continue
			x := e
			x.batch = bi
			append(&out, x)
		}
	}
	return out[:]
}

// r_sci_key_diff: missing / extra keys, else the first out-of-order key.
@(private = "file")
r_sci_key_diff :: proc(diffs: ^strings.Builder, o, u: Sci_Event) {
	has :: proc(l: []string, k: string) -> bool {
		for x in l do if x == k do return true
		return false
	}
	missing, extra := make([dynamic]string, context.temp_allocator), make([dynamic]string, context.temp_allocator)
	for k in o.keys do if !has(u.keys, k) do append(&missing, k)
	for k in u.keys do if !has(o.keys, k) do append(&extra, k)
	if len(missing) > 0 || len(extra) > 0 {
		fmt.sbprintfln(diffs, "  ~ science  %s keys: missing [%s] extra [%s]", o.type, strings.join(missing[:], ",", context.temp_allocator), strings.join(extra[:], ",", context.temp_allocator))
		return
	}
	for k, i in o.keys do if u.keys[i] != k {
		fmt.sbprintfln(diffs, "  ~ science  %s key order: official %s at #%d, ours %s", o.type, k, i, u.keys[i])
		return
	}
}

// r_science_check compares our /science batches with the official window's.
@(private = "file")
r_science_check :: proc(official, ours: []Sci_Batch, allow: []string, diffs: ^strings.Builder) {
	// header order: every batch of ours against the official window's (no
	// x-science-test after the first batch of a launch)
	if len(official) > 0 && official[0].wire != "" {
		for b in ours do if b.wire != official[0].wire {
			fmt.sbprintfln(diffs, "  ~ wire     POST /science\n      official: %s\n      ours:     %s", official[0].wire, b.wire)
			break
		}
	}
	off := r_sci_flatten(official, allow)
	our := r_sci_flatten(ours, allow)
	// FASTCORD_SCI_DEBUG=1: print both event sequences (batch, type, constants)
	if os.get_env("FASTCORD_SCI_DEBUG", context.temp_allocator) != "" {
		for e in off do fmt.eprintfln("official  #%d %s %v", e.batch, e.type, e.consts)
		for e in our do fmt.eprintfln("ours      #%d %s %v", e.batch, e.type, e.consts)
		for b in ours do fmt.eprintfln("ours wire %s", b.wire)
		for b in official do fmt.eprintfln("official wire %s", b.wire)
	}
	// longest common subsequence of the event types
	n, m := len(off), len(our)
	lcs := make([]int, (n + 1) * (m + 1), context.temp_allocator)
	for i := n - 1; i >= 0; i -= 1 {
		for j := m - 1; j >= 0; j -= 1 {
			lcs[i * (m + 1) + j] = lcs[(i + 1) * (m + 1) + j + 1] + 1 if off[i].type == our[j].type else max(lcs[(i + 1) * (m + 1) + j], lcs[i * (m + 1) + j + 1])
		}
	}
	pairs := make([dynamic][2]int, context.temp_allocator)
	i, j := 0, 0
	for i < n || j < m {
		if i < n && j < m && off[i].type == our[j].type {
			append(&pairs, [2]int{i, j})
			i += 1
			j += 1
		} else if j < m && (i >= n || lcs[i * (m + 1) + j + 1] >= lcs[(i + 1) * (m + 1) + j]) {
			fmt.sbprintfln(diffs, "  + extra    science %s", our[j].type)
			j += 1
		} else {
			fmt.sbprintfln(diffs, "  - missing  science %s", off[i].type)
			i += 1
		}
	}
	// same-type events of one step (responses racing each other) may come in
	// either order: pair them by their constant values
	same_consts :: proc(a, b: Sci_Event) -> bool {
		if len(a.consts) != len(b.consts) do return false
		for x, i in a.consts do if x != b.consts[i] do return false
		return true
	}
	for pi in 0 ..< len(pairs) {
		if same_consts(off[pairs[pi][0]], our[pairs[pi][1]]) do continue
		for pj := pi + 1; pj < len(pairs) && off[pairs[pj][0]].type == off[pairs[pi][0]].type; pj += 1 {
			if same_consts(off[pairs[pi][0]], our[pairs[pj][1]]) && same_consts(off[pairs[pj][0]], our[pairs[pi][1]]) {
				pairs[pi][1], pairs[pj][1] = pairs[pj][1], pairs[pi][1]
				break
			}
		}
	}
	for p in pairs {
		o, u := off[p[0]], our[p[1]]
		ok_keys := len(o.keys) == len(u.keys)
		if ok_keys do for k, ki in o.keys do if k != u.keys[ki] do ok_keys = false
		if !ok_keys {
			r_sci_key_diff(diffs, o, u)
			continue
		}
		for k, ki in o.keys {
			if r_allowed(allow, fmt.tprintf("science:%s.%s", o.type, k)) do continue
			if o.kinds[ki] != u.kinds[ki] {
				fmt.sbprintfln(diffs, "  ~ science  %s.%s type: official %s, ours %s", o.type, k, o.kinds[ki], u.kinds[ki])
			} else if o.consts[ki] != "" && o.consts[ki] != u.consts[ki] {
				fmt.sbprintfln(diffs, "  ~ science  %s.%s: official %s, ours %s", o.type, k, o.consts[ki], u.consts[ki] if u.consts[ki] != "" else "(variable)")
			}
		}
	}
	// batching
	if !r_allowed(allow, "science:batching") {
		for pi in 1 ..< len(pairs) {
			a, b := pairs[pi - 1], pairs[pi]
			oa, ob, ua, ub := off[a[0]], off[b[0]], our[a[1]], our[b[1]]
			same_off := oa.batch == ob.batch
			if same_off && ob.track - oa.track <= SCI_SAME_STEP_MS && ua.batch != ub.batch {
				fmt.sbprintfln(diffs, "  ~ science  %s and %s: one batch officially, two in ours", oa.type, ob.type)
			} else if !same_off && ob.track - oa.track > SCI_SEPARATE_MS && ua.batch == ub.batch {
				fmt.sbprintfln(diffs, "  ~ science  %s and %s: two batches officially, one in ours", oa.type, ob.type)
			}
		}
		max_delay: i64 = -1
		for b in official do if len(b.events) > 0 do max_delay = max(max_delay, b.send - b.events[0].track)
		if max_delay >= 0 {
			for b in ours do if len(b.events) > 0 {
				d := b.send - b.events[0].track
				if d < 0 || d > max_delay + 50 {
					fmt.sbprintfln(diffs, "  ~ science  flush %d ms after the first event (official at most %d ms)", d, max_delay)
				}
			}
		}
	}
}

// last message by us in the channel (the fixture's own setup message)
@(private = "file")
r_last_own :: proc(c: ^Client, channel: Snowflake) -> Snowflake {
	msgs := messages_get(&c.store, channel)
	for i := len(msgs) - 1; i >= 0; i -= 1 do if msgs[i].author_id == c.store.me do return msgs[i].id
	return msgs[len(msgs) - 1].id if len(msgs) > 0 else 0
}

@(private = "file")
r_type :: proc(c: ^Client, channel: Snowflake, text: string) {
	for _ in text do typing_keystroke(c, channel)
}

// Telemetry fastcord never sends (traffic/PARITY.md "Telemetry"): every window allows these (replay_check).
//   dismissible_content_shown, hotspot_hidden: Discord's NUX tooltips / upsells; fastcord shows none.
//   quest_hover, quest_hover_off: the quests entry point on the home page; fastcord has none
//     (and the hovers are the capture driver's mouse path, not the action).
//   experiment_*: exposures of experiments read by official UI components (their names are the location).
//   premium_upsell_viewed, impression_custom_themes_*: Nitro upsells.
//   voice_connection_*, audio_input_initialized, media_session_joined, start_speaking,
//   start_listening, secure_frames_transition, voice_codec_detected, voice_disconnect,
//   leave_voice_channel: the official media engine's internals and statistics
//   (versions, device lists, RTC timings, packet counts); src/voice is not that engine.
//   video_layout_toggled: the official call view's layout state; fastcord's has no layouts.
@(private = "file")
R_SCI_NEVER :: []string{"science:dismissible_content_shown", "science:hotspot_hidden", "science:quest_hover", "science:experiment_", "science:premium_upsell_viewed", "science:impression_custom_themes", "science:voice_connection_", "science:audio_input_initialized", "science:media_session_joined", "science:start_speaking", "science:start_listening", "science:secure_frames_transition", "science:voice_codec_detected", "science:voice_disconnect", "science:leave_voice_channel", "science:video_layout_toggled"}

// the official picker flow: menu "Add Reaction" -> picker -> search -> pick
@(private = "file")
r_react_via_menu :: proc(run: ^Replay_Run, msg: Snowflake, query: string, results: []int) {
	c := run.c
	message_menu_opened(c, R_GUILD, R_TEXT, msg)
	replay_settle(run, 500)
	message_menu_item_clicked(c)
	message_menu_closed(c)
	open_emoji_picker(c, R_GUILD)
	expression_picker_opened(c, .Reaction, R_GUILD, R_TEXT, message_id = msg)
	replay_settle(run, 200)
	r_search(run, query, results)
}

@(private = "file")
r_search :: proc(run: ^Replay_Run, query: string, results: []int) {
	picker_search_typed(run.c, query[:1])
	replay_settle(run, 200)
	for n, i in results {
		// results render for the query typed so far (the last one is the full query)
		q := query if i == len(results) - 1 else query[:min(len(query), i + 1)]
		picker_search_results(run.c, q, n)
		replay_settle(run, 200)
	}
}

// ---- per-feature parity tests (the action window of each fixture) ----

@(test)
parity_send_message :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "send_message", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	r_type(run.c, R_TEXT, "hello from the official client")
	replay_pump(&run, 1700) // the typing timer fires while the text is typed
	send_message(run.c, R_TEXT, "hello from the official client")
	replay_dispatches(&run, "send_message", "MESSAGE_CREATE")
	replay_settle(&run, 600)
	replay_check(&run, "send_message", {"settings-proto/2"}) // frecency write (not modelled)
}

@(test)
parity_add_reaction :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "add_reaction", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	msg := r_last_own(run.c, R_TEXT)
	r_react_via_menu(&run, msg, "thumbsup", {1})
	picker_emoji_selected(run.c, "thumbsup")
	add_reaction(run.c, R_TEXT, msg, "👍", 0, false, "Message Reaction Picker")
	replay_settle(&run, 600)
	replay_check(&run, "add_reaction")
}

@(test)
parity_remove_reaction :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "remove_reaction", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	remove_reaction(run.c, R_TEXT, r_last_own(run.c, R_TEXT), "👍", 0, false, "Message Inline Button")
	replay_settle(&run, 600)
	replay_check(&run, "remove_reaction")
}

@(test)
parity_delete_message :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "delete_message", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	msg := r_last_own(run.c, R_TEXT)
	message_menu_opened(run.c, R_GUILD, R_TEXT, msg)
	replay_settle(&run, 500)
	message_menu_item_clicked(run.c)
	message_menu_closed(run.c)
	delete_message(run.c, R_TEXT, msg)
	replay_settle(&run, 600)
	replay_check(&run, "delete_message")
}

@(test)
parity_edit_message :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "edit_message", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	msg := r_last_own(run.c, R_TEXT)
	message_menu_opened(run.c, R_GUILD, R_TEXT, msg)
	replay_settle(&run, 500)
	message_menu_item_clicked(run.c)
	message_menu_closed(run.c)
	replay_settle(&run, 200)
	edit_message(run.c, R_TEXT, msg, "this message was edited")
	replay_settle(&run, 600)
	replay_check(&run, "edit_message")
}

@(test)
parity_reply :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "reply", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	target := r_last_own(run.c, R_TEXT)
	message_menu_opened(run.c, R_GUILD, R_TEXT, target)
	replay_settle(&run, 500)
	message_menu_item_clicked(run.c)
	message_menu_closed(run.c)
	r_type(run.c, R_TEXT, "this is a reply")
	replay_pump(&run, 1700)
	send_message(run.c, R_TEXT, "this is a reply", {reply_to = target, reply_guild_id = R_GUILD, mention_replied = false})
	replay_settle(&run, 600)
	replay_check(&run, "reply")
}

@(test)
parity_typing :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "typing", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	r_type(run.c, R_TEXT, "i am typing something")
	replay_pump(&run, 1700)
	replay_settle(&run, 300)
	// the official window also holds the 10 s re-send, which is not waited for offline
	replay_check(&run, "typing", {"/typing"})
}

@(test)
parity_open_profile_popout :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "open_profile_popout", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	open_profile_popout(run.c, run.c.store.me, R_GUILD, R_TEXT, r_last_own(run.c, R_TEXT))
	replay_settle(&run, 800)
	replay_check(&run, "open_profile_popout")
}

@(test)
parity_open_full_profile :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "open_full_profile", R_GUILD, R_TEXT) do return
	open_profile_popout(run.c, run.c.store.me, R_GUILD, R_TEXT, r_last_own(run.c, R_TEXT))
	replay_settle(&run, 600)
	replay_mark(&run)
	open_full_profile(run.c, run.c.store.me, R_GUILD)
	replay_settle(&run, 800)
	// not modelled: follow-ups driven by the profile's widget data (applications/public,
	// games, oauth2/tokens); the note is already loaded by the popout officially
	// science: fastcord's profile modal has no widgets section (no VIEW_WIDGETS_EMPTY_STATE)
	replay_check(&run, "open_full_profile", {"applications/public", "/games?", "oauth2/tokens", "/notes/", `science:user_profile_action/profile_action="VIEW_WIDGETS_EMPTY_STATE"`})
}

@(test)
parity_emoji_picker_reaction :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "emoji_picker_reaction", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	msg := r_last_own(run.c, R_TEXT)
	open_emoji_picker(run.c, R_GUILD)
	expression_picker_opened(run.c, .Reaction, R_GUILD, R_TEXT, message_id = msg)
	replay_settle(&run, 200)
	r_search(&run, "fire", {107, 11})
	picker_emoji_selected(run.c, "fire")
	add_reaction(run.c, R_TEXT, msg, "🔥", 0, false, "Message Inline Button")
	replay_settle(&run, 600)
	replay_check(&run, "emoji_picker_reaction")
}

@(test)
parity_add_custom_reaction :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "add_custom_reaction", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	msg := r_last_own(run.c, R_TEXT)
	r_react_via_menu(&run, msg, "fastcord", {624, 300, 40, 1})
	picker_emoji_selected(run.c, "fastcord_test", Snowflake(1564250154838528071), R_GUILD)
	add_reaction(run.c, R_TEXT, msg, "fastcord_test", Snowflake(1564250154838528071), false, "Message Reaction Picker")
	replay_settle(&run, 600)
	replay_check(&run, "add_custom_reaction")
}

@(test)
parity_gif_send :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "gif_send", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	gifs_trending(run.c)
	expression_picker_opened(run.c, .Gif, R_GUILD, R_TEXT, width = 498)
	replay_settle(&run, 400)
	replay_check(&run, "open_gif_picker")
}

@(test)
parity_status_change :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "status_change", 0, 0) do return
	replay_mark(&run)
	open_account_popout(run.c)
	replay_settle(&run, 600)
	replay_check(&run, "open_status_menu")
}

@(test)
parity_set_idle :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "status_change", 0, 0) do return
	replay_mark(&run)
	set_status(run.c, .Idle)
	replay_settle(&run, 400)
	replay_check(&run, "set_idle")
}

@(test)
parity_custom_status :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "custom_status", 0, 0) do return
	replay_mark(&run)
	set_custom_status(run.c, {text = "testing fastcord", expires_at_ms = now_ms() + 24 * 3600 * 1000, clear_after = .Today})
	replay_settle(&run, 400)
	// fastcord's custom status modal shows no prompt suggestion: prompt_type is null
	replay_check(&run, "set_custom_status", {"science:custom_status_updated.prompt_type"})
}

@(test)
parity_switch_theme :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "switch_theme", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	set_theme(run.c, .Light)
	replay_settle(&run, 400)
	replay_check(&run, "theme_light")
}

@(test)
parity_join_voice :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "join_voice_channel", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	voice_join(run.c, R_GUILD, R_VOICE)
	replay_settle(&run, 900)
	// op 4 preferred_region(s) come from the live RTC probe; settings-proto/2: frecency write (not modelled)
	// science: the voice engine's events (permission prompt, RTC connection, codec,
	// speaking) need src/voice connected, which the offline replay does not run;
	// fastcord has no voice invite suggestions
	replay_check(&run, "join_voice", {"op 4", "settings-proto/2", ".client_rtc_state", "science:permissions_requested", "science:impression_voice_invite_suggestions"})
}

@(test)
parity_close_dm :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "close_dm", 0, 0) do return
	replay_mark(&run)
	private_channel_menu_opened(run.c)
	replay_settle(&run, 300)
	close_private_channel(run.c, R_DM)
	replay_settle(&run, 500)
	replay_check(&run, "close_dm", {"settings-proto/2"})
}

@(test)
parity_create_guild :: proc(t: ^testing.T) {
	run: Replay_Run
	// the scrubbed fixture names the new guild like the test guild: start elsewhere
	if !replay_begin(&run, t, "create_guild", 0, 0) do return
	run.c.session_guild_set_done = true // the official session had entered a guild before
	replay_mark(&run)
	create_guild(run.c, "Dingus Battle's serverfastcord test", step_shown_ms = now_ms() - 8000)
	replay_settle(&run, 1100) // GUILD_CREATE follows the POST's response
	replay_dispatches(&run, "create_guild_submit", "GUILD_CREATE")
	replay_settle(&run, 900)
	// op 8: the scrubbed fixture aliases the new guild's channel to the test channel,
	// whose authors are not members of the new guild here
	replay_check(&run, "create_guild_submit", {"op 8"})
}

@(test)
parity_start_group_dm :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "start_group_dm", 0, 0) do return
	replay_mark(&run)
	group_dm_picker_opened(run.c, {"New Group DM", "Friends List"}, 0, 2)
	replay_settle(&run, 300)
	create_group_dm(run.c)
	replay_settle(&run, 500)
	// the new DM is opened by the app; get-decisions is the ads timer, not this action
	replay_check(&run, "start_group_dm", {"/messages?limit", "op 13", "get-decisions"})
}

@(test)
parity_upload_custom_emoji :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "upload_custom_emoji", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	// fastcord uploads from the emoji picker's "Add Emoji"; the capture is the
	// server settings upload (same request)
	upload_guild_emoji(run.c, R_GUILD, "src/imagefmt/testdata/t_trns_gray.png", "fastcord_test")
	replay_dispatches(&run, "upload_emoji", "GUILD_EMOJIS_UPDATE")
	replay_settle(&run, 600)
	// the upload's result, as the app takes it (the feature pool is shared by the parallel tests)
	for &r in feature_take(run.c) do feature_result_free(&r)
	// GET /emojis: the open settings page refreshing its list (fastcord has no such page)
	// science: the capture used server settings' Emoji Studio modal (open_modal,
	// impression, emoji_studio_ended); fastcord uploads from the picker without it
	replay_check(&run, "upload_emoji", {"GET discord.com/api/v9/guilds/{id}/emojis", "science:open_modal", "science:impression_modal_root_legacy", "science:emoji_studio_ended"})
}

// ---- telemetry of navigation and small UI events (science only: the request
// differences of these windows are session state, see traffic/PARITY.md) ----

@(test)
parity_open_guild :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "open_guild_and_channel", 0, 0) do return
	replay_mark(&run)
	select_channel(run.c, R_GUILD, R_TEXT, 10, prefetch = true)
	replay_settle(&run, 600)
	replay_check(&run, "open_guild", science_only = true)
}

@(test)
parity_open_unread_channel :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "mark_as_read", 0, 0) do return
	replay_dispatches(&run, "b_sends", "MESSAGE_CREATE") // B's message makes the channel unread
	replay_settle(&run, 300)
	replay_mark(&run)
	select_channel(run.c, R_GUILD, R_TEXT, 10, prefetch = true)
	replay_settle(&run, 600)
	replay_check(&run, "open_unread_channel", science_only = true)
}

@(test)
parity_open_dm :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "open_dm", 0, 0) do return
	replay_mark(&run)
	select_channel(run.c, 0, R_DM, 10, prefetch = true)
	replay_settle(&run, 1200)
	replay_check(&run, "open_dm", science_only = true)
}

@(test)
parity_set_online :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "status_change", 0, 0) do return
	set_status(run.c, .Idle)
	replay_settle(&run, 300)
	replay_mark(&run)
	set_status(run.c, .Online)
	replay_settle(&run, 400)
	replay_check(&run, "set_online", science_only = true)
}

@(test)
parity_close_popout_escape :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "open_profile_popout", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	analytics_keyboard_shortcut(run.c, "MARK_CHANNEL_READ", "esc") // the app: Escape closes the popout
	replay_settle(&run, 300)
	replay_check(&run, "close_profile_popout", science_only = true)
}

@(test)
parity_quick_switcher_open :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "quick_switcher_nav", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	analytics_keyboard_shortcut(run.c, "QUICKSWITCHER_SHOW", "mod+k")
	analytics_quickswitcher_opened(run.c, R_GUILD, R_TEXT)
	replay_settle(&run, 300)
	// the switcher's close / result events carry Discord's search scores (not sent);
	// opening a DM from it is select_channel (parity_open_dm), with the DM list's
	// view (dm_list_viewed) and the profile it shows
	replay_check(&run, "switch_to_dm", {"science:quickswitcher_closed", "science:quickswitcher_result_selected", "science:dm_list_viewed", "science:channel_opened", "science:user_profile_action"}, science_only = true)
}

@(test)
parity_friends_add_tab :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "friend_request_send", 0, 0) do return
	replay_mark(&run)
	analytics_friends_list(run.c, "friends_list_clicked", .Add_Friend) // the app: the "Add Friend" tab
	replay_settle(&run, 300)
	replay_check(&run, "friend_request_send", science_only = true)
}

// ---- server notification settings (traffic/guild_*.jsonl, channel_notifications.jsonl) ----

@(test)
parity_guild_menu :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "guild_menu", R_GUILD, R_TEXT) do return
	run.science = true
	replay_mark(&run)
	track_guild_dropdown_viewed(run.c, R_GUILD)
	replay_settle(&run, 400)
	// status page polls: a background timer that fell in the window
	replay_check(&run, "open_guild_menu", {"status.discord.com"})
}

@(test)
parity_guild_mark_read :: proc(t: ^testing.T) {
	run: Replay_Run
	// A is on Friends while B posts
	if !replay_begin(&run, t, "guild_mark_read", 0, 0) do return
	run.science = true
	replay_dispatches(&run, "b_sends", "MESSAGE_CREATE")
	// B's message id is scrubbed ("<new:2>") and unscrubs below the real ids: put the
	// read state behind it so the channel is unread, as it was officially
	if rs, ok := &run.c.store.read_states[R_TEXT]; ok do rs.last_message_id = 1
	replay_settle(&run, 300)
	replay_mark(&run)
	ack_guild(run.c, R_GUILD)
	replay_dispatches(&run, "guild_mark_read", "MESSAGE_ACK")
	replay_settle(&run, 500)
	// notification_action ACK: the official client had shown a desktop banner for
	// B's message (the app's notifier, not this action)
	replay_check(&run, "guild_mark_read", {"science:notification_action"})
}

@(test)
parity_guild_mute :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "guild_mute", R_GUILD, R_TEXT) do return
	run.science = true
	replay_mark(&run)
	set_guild_muted(run.c, R_GUILD, true, 900)
	replay_dispatches(&run, "guild_mute_15m", "USER_GUILD_SETTINGS_UPDATE")
	replay_settle(&run, 400)
	replay_check(&run, "guild_mute_15m")
}

@(test)
parity_guild_unmute :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "guild_mute", R_GUILD, R_TEXT) do return
	run.science = true
	// the 15 min mute as fastcord applied it (the recorded dispatch's end_time lies
	// in the capture's past: replayed now, the mute would have run out)
	set_guild_muted(run.c, R_GUILD, true, 900)
	replay_settle(&run, 300)
	replay_mark(&run)
	set_guild_muted(run.c, R_GUILD, false)
	replay_dispatches(&run, "guild_unmute", "USER_GUILD_SETTINGS_UPDATE")
	replay_settle(&run, 400)
	replay_check(&run, "guild_unmute")
}

@(test)
parity_guild_notifications :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "guild_notifications", R_GUILD, R_TEXT) do return
	run.science = true
	replay_mark(&run)
	set_guild_notify_level(run.c, R_GUILD, NOTIFY_MENTIONS)
	replay_dispatches(&run, "guild_notify_mentions", "USER_GUILD_SETTINGS_UPDATE")
	replay_settle(&run, 400)
	replay_check(&run, "guild_notify_mentions")
}

@(test)
parity_guild_notifications_all :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "guild_notifications", R_GUILD, R_TEXT) do return
	run.science = true
	set_guild_notify_level(run.c, R_GUILD, NOTIFY_MENTIONS)
	replay_dispatches(&run, "guild_notify_mentions", "USER_GUILD_SETTINGS_UPDATE")
	replay_settle(&run, 300)
	replay_mark(&run)
	// the window opens the header menu again, then picks All Messages in the modal
	track_guild_dropdown_viewed(run.c, R_GUILD)
	replay_settle(&run, 300) // the modal is open a while before the click
	set_guild_notify_level(run.c, R_GUILD, NOTIFY_ALL)
	replay_dispatches(&run, "guild_notify_all", "USER_GUILD_SETTINGS_UPDATE")
	replay_settle(&run, 400)
	replay_check(&run, "guild_notify_all")
}

@(test)
parity_channel_notifications :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "channel_notifications", R_GUILD, R_TEXT) do return
	run.science = true
	replay_mark(&run)
	set_channel_muted(run.c, R_GUILD, R_TEXT, true, 900)
	replay_dispatches(&run, "channel_mute_15m", "USER_GUILD_SETTINGS_UPDATE")
	replay_settle(&run, 400)
	replay_check(&run, "channel_mute_15m")
}

@(test)
parity_channel_notifications_sequence :: proc(t: ^testing.T) {
	// unmute, Only @mentions, Use Category Default: each its own window, in order
	steps := [?]string{"channel_unmute", "channel_notify_mentions", "channel_notify_default"}
	for step, i in steps {
		run: Replay_Run
		if !replay_begin(&run, t, "channel_notifications", R_GUILD, R_TEXT) do return
		run.science = true
		// the 15 min mute as fastcord applied it (the recorded dispatch's end_time
		// lies in the capture's past: replayed now, the mute would have run out)
		set_channel_muted(run.c, R_GUILD, R_TEXT, true, 900)
		for j in 0 ..< i {
			switch steps[j] {
			case "channel_unmute":
				set_channel_muted(run.c, R_GUILD, R_TEXT, false)
			case "channel_notify_mentions":
				set_channel_notify_level(run.c, R_GUILD, R_TEXT, NOTIFY_MENTIONS)
			}
			replay_dispatches(&run, steps[j], "USER_GUILD_SETTINGS_UPDATE")
		}
		replay_settle(&run, 300)
		replay_mark(&run)
		switch step {
		case "channel_unmute":
			set_channel_muted(run.c, R_GUILD, R_TEXT, false)
		case "channel_notify_mentions":
			set_channel_notify_level(run.c, R_GUILD, R_TEXT, NOTIFY_MENTIONS)
		case "channel_notify_default":
			set_channel_notify_level(run.c, R_GUILD, R_TEXT, NOTIFY_INHERIT)
		}
		replay_dispatches(&run, step, "USER_GUILD_SETTINGS_UPDATE")
		replay_settle(&run, 400)
		replay_check(&run, step)
	}
}

// ---- invites, joining and leaving servers (fixtures invite_people, join_leave_server) ----

@(test)
parity_invite_people :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "invite_people", R_GUILD, R_TEXT) do return
	// the header menu opens in its own window, Invite People in the next
	replay_mark(&run)
	track_guild_dropdown_viewed(run.c, R_GUILD)
	replay_settle(&run, 300)
	replay_check(&run, "open_guild_menu", {"status.discord.com"}, keep = true)
	replay_mark(&run)
	open_invite_modal(run.c, R_GUILD, R_TEXT, INVITE_LOC_HEADER)
	replay_settle(&run, 500)
	replay_check(&run, "invite_from_menu")
}

// later opens: validate is the first open's code; the suggestions' memberships are known
@(private = "file")
r_invite_reopen :: proc(t: ^testing.T, window, location: string) {
	run: Replay_Run
	if !replay_begin(&run, t, "invite_people", R_GUILD, R_TEXT) do return
	open_invite_modal(run.c, R_GUILD, R_TEXT, INVITE_LOC_HEADER)
	replay_settle(&run, 500)
	replay_dispatches(&run, "invite_from_menu", "GUILD_MEMBERS_CHUNK")
	replay_settle(&run, 200)
	if invite_code_for(run.c, R_TEXT) == "" do testing.expect(t, false, "the first invite's code was not kept")
	replay_mark(&run)
	open_invite_modal(run.c, R_GUILD, R_TEXT, location)
	replay_settle(&run, 500)
	replay_check(&run, window)
}

@(test)
parity_invite_people_header_icon :: proc(t: ^testing.T) {r_invite_reopen(t, "invite_from_header_icon", INVITE_LOC_HEADER_BUTTON)}

@(test)
parity_invite_people_channel_icon :: proc(t: ^testing.T) {r_invite_reopen(t, "invite_from_channel_icon", INVITE_LOC_CHANNELS)}

@(test)
parity_invite_people_copy_close :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "invite_people", R_GUILD, R_TEXT) do return
	open_invite_modal(run.c, R_GUILD, R_TEXT, INVITE_LOC_HEADER)
	replay_settle(&run, 500)
	// Copy, then Escape (its own window): science only
	replay_mark(&run)
	invite_copied(run.c, R_GUILD, R_TEXT, invite_code_for(run.c, R_TEXT), INVITE_LOC_HEADER)
	replay_settle(&run, 300)
	replay_check(&run, "copy_invite", keep = true)
	replay_mark(&run)
	escape_shortcut_used(run.c)
	replay_settle(&run, 300)
	replay_check(&run, "close_invite")
}

// B leaves the test guild: the DELETE, then (on GUILD_DELETE) Friends' first render.
@(private = "file")
r_leave :: proc(run: ^Replay_Run) {
	leave_guild(run.c, R_GUILD)
	replay_settle(run, 300)
	replay_dispatches(run, "b_leave_confirm")
	client_poll(run.c)
	select_channel(run.c, 0, 0) // the app routes to Friends once the guild is gone
	friends_page_viewed(run.c)
	replay_settle(run, 600)
}

@(test)
parity_leave_server :: proc(t: ^testing.T) {
	locks.lock(&r_guild_side_tables)
	defer locks.unlock(&r_guild_side_tables)
	run: Replay_Run
	if !replay_begin(&run, t, "join_leave_server", R_GUILD, R_TEXT, "b") do return
	// the session's quests (applications/public on the home surface)
	q := job_new(.Api, .Startup)
	q.method = "GET"
	q.path = "/quests/@me"
	job_submit(run.c, q)
	replay_settle(&run, 300)
	replay_mark(&run)
	r_leave(&run)
	replay_check(&run, "b_leave_confirm")
}

@(test)
parity_join_server :: proc(t: ^testing.T) {
	locks.lock(&r_guild_side_tables)
	defer locks.unlock(&r_guild_side_tables)
	run: Replay_Run
	if !replay_begin(&run, t, "join_leave_server", R_GUILD, R_TEXT, "b") do return
	r_leave(&run)
	// Add a Server -> Join a Server -> typing the link: science only
	replay_mark(&run)
	guild_add_step(run.c, .Templates, 0)
	guild_add_step(run.c, .Join, now_ms())
	replay_settle(&run, 300)
	{
		locks.lock(&run.r.mu)
		n := len(run.r.ours) + len(run.r.sends)
		locks.unlock(&run.r.mu)
		testing.expectf(t, n == 0, "opening Add a Server / Join a Server sent %d requests or gateway ops (official: science only)", n)
	}
	replay_mark(&run)
	// the app runs join_invite on a worker while the UI thread polls (science flushes)
	Join :: struct {
		c:    ^Client,
		ok:   bool,
		done: bool,
	}
	jn := Join{c = run.c}
	th := thread.create_and_start_with_poly_data(&jn, proc(j: ^Join) {
		res := join_invite(j.c, "https://discord.gg/w5wYynKUN", context.temp_allocator)
		j.ok = res.ok
		free_all(context.temp_allocator)
		sync.atomic_store(&j.done, true)
	})
	for !sync.atomic_load(&jn.done) {
		client_poll(run.c)
		time.sleep(5 * time.Millisecond)
	}
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, jn.ok, "the invite was not accepted")
	replay_dispatches(&run, "b_join_submit")
	replay_settle(&run, 800)
	locks.lock(&run.c.route_mu)
	g, ch := run.c.route_guild, run.c.route_channel
	locks.unlock(&run.c.route_mu)
	testing.expectf(t, g == R_GUILD && ch == R_TEXT, "the joined guild opened at %v/%v", g, ch)
	replay_check(&run, "b_join_submit")
}

@(private = "file")
R_UPLOAD_CH :: Snowflake(1564405699197407414) // upload_options was recorded in a second text channel

// Staged attachments: each staged file uploads at once; spoiler / modify send nothing;
// the trash deletes the uploaded file once (no retry after the capture's 429); Send posts
// the message with is_spoiler / description / the renamed filename.
@(test)
parity_upload_options :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "upload_options", R_GUILD, R_UPLOAD_CH) do return
	png, err := os.read_entire_file("tests/scenarios/assets/test.png", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer delete(png)
	c := run.c

	replay_mark(&run)
	h1 := upload_draft(c, R_UPLOAD_CH, "test.png", "image/png", png, "file_picker")
	// the upload PUT answers after its recorded latency: wait for it, then settle
	for i := 0; i < 600; i += 1 {
		client_poll(c)
		if st, _, _, _ := upload_draft_status(c, h1); st == .Done || st == .Failed do break
		time.sleep(5 * time.Millisecond)
	}
	replay_settle(&run, 500)
	st, sent, _, _ := upload_draft_status(c, h1)
	testing.expect_value(t, st, Draft_State.Done)
	// the fixture's READY puts this user in the WebP experiment (variation 1): the PNG
	// is uploaded as a smaller lossless WebP, as the official client did (6302 -> 758)
	testing.expect_value(t, c.webp_variation, 1)
	testing.expect(t, sent > 0 && sent < i64(len(png)))
	replay_check(&run, "stage_file", {"settings-proto/2"}, keep = true)

	replay_mark(&run)
	analytics_media_draft_edited(c, "spoilered", true)
	replay_settle(&run, 300)
	replay_check(&run, "spoiler_toggle", {"settings-proto/2"}, keep = true) // the frecency GET is periodic

	replay_mark(&run)
	analytics_media_draft_edited(c, "has_alt_text", true)
	replay_settle(&run, 300)
	replay_check(&run, "modify_save", keep = true)

	replay_mark(&run)
	h2 := upload_draft(c, R_UPLOAD_CH, "fastcord_test.png", "image/png", png, "file_picker")
	replay_settle(&run, 500)
	replay_check(&run, "stage_second_file", keep = true)

	replay_mark(&run)
	upload_draft_remove(c, h2)
	replay_settle(&run, 500)
	replay_check(&run, "remove_second_file", keep = true)

	replay_mark(&run)
	send_message(c, R_UPLOAD_CH, "", {attachments = {{handle = h1, filename = "fc_renamed.png", description = "a small test image", spoiler = true}}})
	replay_dispatches(&run, "send_with_options", "MESSAGE_CREATE")
	replay_settle(&run, 600)
	replay_check(&run, "send_with_options", keep = true)

	replay_mark(&run)
	// the official paste was a PNG the WebP didn't shrink (insufficient_savings): so is this one
	small, serr := os.read_entire_file("src/imagefmt/testdata/t_trns_gray.png", context.allocator)
	testing.expect(t, serr == nil)
	defer delete(small)
	h3 := upload_draft(c, R_UPLOAD_CH, "image.png", "image/png", small, "clipboard")
	replay_settle(&run, 500)
	{
		d := drafts_of(c)
		locks.lock(&d.mu)
		u, _ := draft_find(d, h3)
		if u != nil do testing.expect_value(t, u.conv.failure, "insufficient_savings")
		if u != nil do testing.expect_value(t, u.size, i64(len(small)))
		locks.unlock(&d.mu)
	}
	replay_check(&run, "paste_image", keep = true)

	replay_mark(&run)
	send_message(c, R_UPLOAD_CH, "", {attachments = {{handle = h3, filename = "image.png"}}})
	replay_dispatches(&run, "send_pasted", "MESSAGE_CREATE")
	replay_settle(&run, 600)
	replay_check(&run, "send_pasted")
}

@(test)
draft_attachments_body :: proc(t: ^testing.T) {
	atts := []Draft_Attachment{{handle = 1, filename = "fc_renamed.png", description = "a small test image", spoiler = true}, {handle = 2, filename = "image.png"}}
	got := attachments_json(atts, {"u1/test.png", "u2/image.png"}, {"image/png", "image/png"})
	testing.expect_value(t, got, `[{"id":"0","description":"a small test image","filename":"fc_renamed.png","uploaded_filename":"u1/test.png","is_spoiler":true,"original_content_type":"image/png"},{"id":"1","filename":"image.png","uploaded_filename":"u2/image.png","original_content_type":"image/png"}]`)
}

// ---- inbox, threads browser, back/forward (traffic/FEATURES_NEW.md) ----

// B's two mentions of A (MESSAGE_CREATE of the b_mentions window); A is on Friends.
@(private = "file")
inbox_begin :: proc(run: ^Replay_Run, t: ^testing.T) -> bool {
	if !replay_begin(run, t, "inbox", 0, 0) do return false
	replay_dispatches(run, "b_mentions", "MESSAGE_CREATE")
	replay_settle(run, 300)
	return true
}

@(test)
parity_inbox_open :: proc(t: ^testing.T) {
	run: Replay_Run
	if !inbox_begin(&run, t) do return
	replay_mark(&run)
	// the popout reopens on the stored tab (READY: inbox.current_tab = MENTIONS)
	testing.expect_value(t, run.c.store.settings.inbox_tab, Inbox_Tab.Mentions)
	open_mentions(run.c)
	track_open_popout(run.c, "Recent Mentions")
	replay_settle(&run, 500)
	replay_check(&run, "open_inbox")
}

@(test)
parity_inbox_tabs :: proc(t: ^testing.T) {
	run: Replay_Run
	if !inbox_begin(&run, t) do return
	replay_mark(&run)
	// Unreads: nothing but science; the tab is saved 10 s later (not in this window)
	set_inbox_tab(run.c, .Unreads)
	track_open_popout(run.c, "Inbox")
	replay_settle(&run, 400)
	replay_check(&run, "inbox_unreads_tab", keep = true)
	replay_mark(&run)
	set_inbox_tab(run.c, .Mentions)
	track_open_popout(run.c, "Recent Mentions")
	replay_settle(&run, 400)
	replay_check(&run, "inbox_mentions_tab")
}

@(test)
parity_inbox_mark_read :: proc(t: ^testing.T) {
	run: Replay_Run
	if !inbox_begin(&run, t) do return
	// the app showed B's two mentions as desktop notifications
	for e in replay_window(&run.r, "b_mentions") {
		if fstr(e, "k") != "ws_recv" || fstr(e, "ev") != "MESSAGE_CREATE" do continue
		d := fmap(e, "d")
		analytics_notification_shown(run.c, fsnow(d, "id"), fsnow(d, "channel_id"), fsnow(fmap(d, "author"), "id"), int(fint(d, "type")), true)
	}
	replay_mark(&run)
	last := run.c.store.channels[R_TEXT].last_message_id
	ack_message(run.c, R_TEXT, last, true, ACK_INBOX)
	track_inbox_channel_acked(run.c, R_TEXT)
	replay_settle(&run, 300)
	replay_dispatches(&run, "inbox_unreads_mark_read", "MESSAGE_ACK")
	replay_settle(&run, 500)
	replay_check(&run, "inbox_unreads_mark_read")
}

@(test)
parity_inbox_remove_mention :: proc(t: ^testing.T) {
	run: Replay_Run
	if !inbox_begin(&run, t) do return
	// the tab switches of the two windows before: the 10 s save timer started at
	// the first one, ~8.5 s before this window's mark
	set_inbox_tab(run.c, .Unreads)
	set_inbox_tab(run.c, .Mentions)
	run.c.settings_edit.due = now_ms() + 1500
	replay_mark(&run)
	delete_mention(run.c, run.c.store.channels[R_TEXT].last_message_id)
	replay_dispatches(&run, "inbox_remove_mention", "RECENT_MENTION_DELETE")
	replay_pump(&run, 1600)
	replay_settle(&run, 400)
	replay_check(&run, "inbox_remove_mention")
}

@(test)
parity_inbox_jump :: proc(t: ^testing.T) {
	run: Replay_Run
	// the channel was loaded at launch (start route), then A went to Friends
	if !replay_begin(&run, t, "inbox", R_GUILD, R_TEXT) do return
	select_channel(run.c, 0, 0)
	replay_settle(&run, 400)
	replay_dispatches(&run, "b_mentions", "MESSAGE_CREATE")
	replay_settle(&run, 300)
	replay_mark(&run)
	msg := messages_get(&run.c.store, R_TEXT)
	select_channel(run.c, R_GUILD, R_TEXT, 10)
	if len(msg) > 0 do track_jump(run.c, "Recent Mentions", R_TEXT, msg[len(msg) - 1].id)
	replay_settle(&run, 500)
	replay_check(&run, "inbox_jump_to_mention")
}

// Threads browser on the recreated #general: every window in order.
@(test)
parity_threads_browser :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "threads_browser", R_GUILD, R_TEXT2) do return
	defer replay_end(&run)
	c := run.c
	replay_mark(&run)
	fetch_channel_threads(c, R_TEXT2, 0)
	track_thread_browser_open(c, R_TEXT2)
	replay_settle(&run, 400)
	replay_check(&run, "open_threads_popout_empty", keep = true)

	replay_mark(&run)
	track_thread_creation_started(c, R_TEXT2, "Thread Browser Toolbar")
	replay_settle(&run, 300)
	replay_check(&run, "create_thread_open", keep = true)

	replay_mark(&run)
	r_type(c, R_TEXT2, "fastcord test thread")
	replay_pump(&run, 1700)
	replay_settle(&run, 300)
	// the official window also holds the ~8 s re-send, which is not waited for offline
	replay_check(&run, "create_thread_name", {"/typing"}, keep = true)

	// Enter: POST /threads; the reply (the thread) opens it and the first message goes out
	replay_mark(&run)
	create_thread(c, R_TEXT2, "fastcord test thread", tag = 77)
	thread: Snowflake
	for i := 0; i < 400 && thread == 0; i += 1 {
		client_poll(c)
		for &r in feature_take(c) {
			if r.op == .Thread_Create && r.tag == 77 && r.ok do thread = apply_created_thread(c, r.body)
			feature_result_free(&r)
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, thread != 0, "no thread from POST /threads")
	replay_dispatches(&run, "create_thread_submit")
	select_channel(c, R_GUILD, thread, 30)
	send_message(c, thread, "first thread message", {location = "thread_creation"})
	replay_settle(&run, 600)
	// science: the official client opens the new thread in its split view
	// (channel_opened with channel_view "Split View"); fastcord opens it as the main
	// view, whose channel_opened (selected_guild_id) is checked in parity_thread_open_main
	replay_check(&run, "create_thread_submit", {"science:channel_opened"}, keep = true)

	// the official side view closes (the parent stayed the route); fastcord left the
	// parent for the thread, so returning renders it again (integrations, see
	// guild_channel_notice_check). settings-proto/2: the periodic frecency load.
	replay_mark(&run)
	select_channel(c, R_GUILD, R_TEXT2, 10)
	replay_settle(&run, 400)
	replay_check(&run, "close_thread_view", {"settings-proto/2", "/integrations"}, keep = true)

	// second open: active threads come from the gateway, no new search
	replay_mark(&run)
	track_thread_browser_open(c, R_TEXT2)
	replay_settle(&run, 300)
	replay_check(&run, "open_threads_popout", keep = true)

	// science: fastcord's main-view channel_opened for the thread was sent on create
	// and is throttled for 15 min (the official one went to the split view's key)
	replay_mark(&run)
	select_channel(c, R_GUILD, thread, 10, source = "Thread Browser")
	replay_settle(&run, 400)
	replay_check(&run, "open_thread_from_popout", {"science:channel_opened"}, keep = true)

	// the official ack is the new thread's first-view ack (its read state did not
	// exist yet); fastcord acks only unread channels in a focused window
	replay_mark(&run)
	replay_settle(&run, 300)
	replay_check(&run, "delete_thread_menu", {"/ack"}, keep = true)

	replay_mark(&run)
	fetch_role_member_counts(c, R_GUILD)
	replay_settle(&run, 400)
	replay_check(&run, "delete_thread", keep = true)

	replay_mark(&run)
	delete_channel(c, thread)
	replay_dispatches(&run, "delete_thread_confirm", "THREAD_DELETE")
	select_channel(c, R_GUILD, R_TEXT2, 10)
	replay_settle(&run, 500)
	replay_check(&run, "delete_thread_confirm", keep = true)
}

// A thread opened from the threads popout as the main view: channel_opened with
// the thread properties, selected_guild_id and location (science only).
@(test)
parity_thread_open_main :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "threads_browser", R_GUILD, R_TEXT2) do return
	c := run.c
	replay_dispatches(&run, "create_thread_submit") // the thread and its first message
	replay_settle(&run, 300)
	thread: Snowflake
	for e in replay_window(&run.r, "create_thread_submit") {
		if fstr(e, "k") == "ws_recv" && fstr(e, "ev") == "THREAD_CREATE" do thread = fsnow(fmap(e, "d"), "id")
	}
	testing.expect(t, thread != 0, "no THREAD_CREATE in create_thread_submit")
	replay_mark(&run)
	select_channel(c, R_GUILD, thread, 10, source = "Thread Browser")
	replay_settle(&run, 400)
	replay_check(&run, "open_thread_from_popout", science_only = true)
}

// Back / forward between #general and Friends: plain route changes.
@(test)
parity_history_nav :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "history_nav", R_GUILD, R_TEXT2) do return
	defer replay_end(&run)
	c := run.c
	select_channel(c, 0, 0) // open_friends (its first-open set is not this test's)
	replay_settle(&run, 500)
	steps := [?]struct {
		window:  string,
		forward: bool,
		keybind: bool,
	}{{"history_back_key", false, true}, {"history_forward_key", true, true}, {"history_back_button", false, false}, {"history_forward_button", true, false}}
	for st in steps {
		replay_mark(&run)
		track_back_forward(c, st.forward, st.keybind)
		if st.forward do select_channel(c, 0, 0)
		else do select_channel(c, R_GUILD, R_TEXT2, 10)
		replay_settle(&run, 400)
		replay_check(&run, st.window, keep = true)
	}
}

// The compass: the official client shows server discovery in the app
// (/discovery/servers); fastcord opens https://discord.com/servers in the
// browser, so the client sends none of it and never leaves the channel.
@(test)
parity_discover :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "discover", R_GUILD, R_TEXT2) do return
	defer replay_end(&run)
	replay_mark(&run)
	replay_settle(&run, 300)
	// science: the in-app discovery page's events (entry point, servers tab views);
	// fastcord's compass is a link to the web page, which is not that entry point
	replay_check(&run, "open_discover", {"discoverable-guilds", "discovery/categories", "discovery-splashes", "/icons/", "science:global_discovery_"}, keep = true)
	replay_mark(&run)
	replay_settle(&run, 300)
	// returning to the guild re-renders its channel officially (integrations)
	replay_check(&run, "leave_discover", {"/integrations"}, keep = true)
}

// ---- guild events and channel management (traffic/guild_events.jsonl, create_channel.jsonl) ----

// The scheduled-events side table is process-wide (one client in the app); tests that
// delete the test guild (leave/join) must not run while parity_guild_events does.
@(private = "file")
r_guild_side_tables: locks.Mutex

@(private = "file")
R_TEXT_CATEGORY :: Snowflake(1564227670806364341)

// r_apply_features: what the app does with finished feature requests
// (guild_admin_apply sends the follow-ups), polled for ms.
@(private = "file")
r_apply_features :: proc(run: ^Replay_Run, ms: int) {
	start := time.tick_now()
	for time.tick_since(start) < time.Duration(ms) * time.Millisecond {
		client_poll(run.c)
		for &r in feature_take_for(run.c) {
			guild_admin_apply(run.c, &r)
			feature_result_free(&r)
		}
		time.sleep(5 * time.Millisecond)
	}
}

// r_new_channel: the channel the fixture's create window made (the app opens it).
@(private = "file")
r_new_channel :: proc(run: ^Replay_Run) -> Snowflake {
	for e in replay_window(&run.r, "create_channel_submit") {
		if fstr(e, "k") == "ws_recv" && fstr(e, "ev") == "CHANNEL_CREATE" do return fsnow(fmap(e, "d"), "id")
	}
	return 0
}

@(test)
parity_guild_events :: proc(t: ^testing.T) {
	locks.lock(&r_guild_side_tables)
	defer locks.unlock(&r_guild_side_tables)
	run: Replay_Run
	if !replay_begin(&run, t, "guild_events", R_GUILD, R_TEXT) do return
	defer replay_end(&run)
	// Events modal, no events: science only. get-decisions is the ads timer, not this action.
	replay_mark(&run)
	open_guild_events(run.c, R_GUILD)
	r_apply_features(&run, 300)
	replay_compare(&run, "open_events_empty", {"get-decisions"})
	// Create Event: Location step (science only), then Event Info (nothing)
	replay_mark(&run)
	open_create_event(run.c, R_GUILD)
	r_apply_features(&run, 300)
	replay_compare(&run, "create_event_open")
	replay_mark(&run)
	r_apply_features(&run, 100)
	replay_compare(&run, "create_event_location")
	// Next on Event Info renders the Review step's preview: counts for event -1 (400)
	replay_mark(&run)
	event_preview_counts(run.c, R_GUILD)
	r_apply_features(&run, 300)
	replay_compare(&run, "create_event_info")
	// Create Event: POST, then the follow-ups and the share invite, the ack 3 s later
	replay_mark(&run)
	draft := Event_Draft{name = "fastcord test event", start_ms = default_event_start_ms(now_ms(), 0), entity = .Voice, channel_id = R_VOICE}
	create_scheduled_event(run.c, R_GUILD, draft)
	r_apply_features(&run, 300)
	replay_dispatches(&run, "create_event_submit")
	// the ack is due EVENT_ACK_DELAY_MS after the POST's response (~0.9 s recorded latency)
	r_apply_features(&run, EVENT_ACK_DELAY_MS + 1000)
	replay_compare(&run, "create_event_submit")
	evs := guild_events(R_GUILD)
	testing.expect_value(t, len(evs), 1)
	if len(evs) != 1 do return
	ev := evs[0].id
	testing.expect(t, evs[0].interested, "the creator is interested")
	testing.expect_value(t, evs[0].user_count, 1)
	// Events modal with the event: science only (its count is known)
	replay_mark(&run)
	open_guild_events(run.c, R_GUILD)
	r_apply_features(&run, 300)
	replay_compare(&run, "open_events_one")
	// Interested toggles: DELETE, then PUT {"response":1}
	replay_mark(&run)
	set_event_interest(run.c, ev, false)
	r_apply_features(&run, 300)
	replay_dispatches(&run, "event_uninterested")
	r_apply_features(&run, 200)
	replay_compare(&run, "event_uninterested")
	testing.expect_value(t, event_get(ev).user_count, 0)
	replay_mark(&run)
	set_event_interest(run.c, ev, true)
	r_apply_features(&run, 300)
	replay_dispatches(&run, "event_interested")
	r_apply_features(&run, 200)
	replay_compare(&run, "event_interested")
	testing.expect_value(t, event_get(ev).user_count, 1)
	// the card's menu and Cancel Event (opens the confirm): nothing
	replay_mark(&run)
	r_apply_features(&run, 100)
	replay_compare(&run, "event_open_context_menu")
	replay_mark(&run)
	r_apply_features(&run, 100)
	replay_compare(&run, "event_cancel")
	// confirm: DELETE the event
	replay_mark(&run)
	cancel_scheduled_event(run.c, ev)
	r_apply_features(&run, 300)
	replay_dispatches(&run, "event_cancel_confirm")
	r_apply_features(&run, 200)
	replay_compare(&run, "event_cancel_confirm")
	testing.expect_value(t, len(guild_events(R_GUILD)), 0)
}

@(test)
parity_create_channel :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "create_channel", R_GUILD, R_TEXT) do return
	defer replay_end(&run)
	// opening the modal: GET profile (settings-proto/2 is an unrelated frecency write)
	replay_mark(&run)
	open_create_channel(run.c, R_GUILD)
	r_apply_features(&run, 300)
	replay_compare(&run, "open_create_channel", {"settings-proto/2"})
	// Create Channel: POST -> 201, templates; the app opens the new channel
	replay_mark(&run)
	create_channel(run.c, R_GUILD, .Guild_Text, "fc-temp", R_TEXT_CATEGORY)
	replay_dispatches(&run, "create_channel_submit") // CHANNEL_CREATE comes before the response
	// the app opens the new channel when the POST's response is applied
	created := false
	for i := 0; i < 400 && !created; i += 1 {
		client_poll(run.c)
		for &r in feature_take_for(run.c) {
			if r.op == .Channel_Create do created = true
			guild_admin_apply(run.c, &r)
			feature_result_free(&r)
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, created, "no response to the POST")
	nc := r_new_channel(&run)
	testing.expect(t, channel_get(&run.c.store, nc) != nil, "the new channel is in the Store")
	select_channel(run.c, R_GUILD, nc, 10)
	r_apply_features(&run, 400)
	replay_compare(&run, "create_channel_submit")
}

@(test)
parity_channel_settings :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "create_channel", R_GUILD, R_TEXT) do return
	defer replay_end(&run)
	replay_dispatches(&run, "create_channel_submit") // the channel from the create window
	r_apply_features(&run, 100)
	ch := channel_get(&run.c.store, r_new_channel(&run))
	testing.expect(t, ch != nil, "the new channel is in the Store")
	if ch == nil do return
	nc := ch.id
	// gear: GET regions
	replay_mark(&run)
	open_channel_settings(run.c, ch)
	r_apply_features(&run, 300)
	replay_compare(&run, "channel_settings_open")
	replay_mark(&run)
	r_apply_features(&run, 100)
	replay_compare(&run, "channel_topic_type")
	// Save Changes: PATCH with the whole Overview form, then templates
	replay_mark(&run)
	form := channel_form_of(ch)
	form.topic = "fastcord temporary channel"
	edit_channel(run.c, nc, form)
	r_apply_features(&run, 300)
	replay_dispatches(&run, "channel_settings_save")
	r_apply_features(&run, 200)
	replay_compare(&run, "channel_settings_save")
}

@(test)
parity_channel_delete :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "create_channel", R_GUILD, R_TEXT) do return
	defer replay_end(&run)
	replay_dispatches(&run, "create_channel_submit")
	r_apply_features(&run, 100)
	nc := r_new_channel(&run)
	testing.expect(t, channel_get(&run.c.store, nc) != nil, "the new channel is in the Store")
	// Delete Channel (opens the confirm): GET roles/member-counts
	replay_mark(&run)
	open_delete_channel(run.c, R_GUILD)
	r_apply_features(&run, 300)
	replay_compare(&run, "channel_delete_open")
	// confirm: DELETE, then templates
	replay_mark(&run)
	delete_channel(run.c, nc)
	r_apply_features(&run, 300)
	replay_dispatches(&run, "channel_delete_confirm")
	r_apply_features(&run, 200)
	replay_compare(&run, "channel_delete_confirm")
	testing.expect(t, channel_get(&run.c.store, nc) == nil, "the channel is gone")
}

// ---- settings (fixture settings / streamer_mode: user settings modal) ----


@(test)
parity_settings_open :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "settings", R_GUILD, R_TEXT2) do return
	replay_mark(&run)
	settings_pane_shown(run.c, .None, .Account, R_GUILD, R_TEXT2)
	replay_pump(&run, 1500) // nothing more loads while the pane is open
	// science: the official settings modal's lazy-load spinner (impression variant
	// renderModalSpinner, absent from streamer_mode's identical open): its code-split
	// chunk loading, which fastcord has no counterpart for
	replay_check(&run, "open_settings", {`science:impression_modal_root_legacy/variant="renderModalSpinner"`})
}

@(test)
parity_settings_open_profiles :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "settings", R_GUILD, R_TEXT2) do return
	replay_mark(&run)
	open_profile_editor(run.c)
	replay_settle(&run, 600)
	// not modelled: follow-ups driven by the profile's widget data
	replay_check(&run, "open_profiles", {"applications/public", "/games?", "oauth2/tokens"})
}

@(test)
parity_settings_profile_save :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "settings", R_GUILD, R_TEXT2) do return
	replay_mark(&run)
	update_profile(run.c, "fc/test", "fastcord test bio")
	replay_settle(&run, 500)
	replay_check(&run, "profile_save")
}

@(test)
parity_settings_display_name_save :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "settings", R_GUILD, R_TEXT2) do return
	replay_mark(&run)
	update_global_name(run.c, "Dingus Test", .Profile_Name)
	replay_settle(&run, 500)
	replay_check(&run, "display_name_save")
}

@(test)
parity_settings_notifications :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "settings", R_GUILD, R_TEXT2) do return
	replay_mark(&run)
	settings_pane_shown(run.c, .Account, .Notifications, R_GUILD, R_TEXT2)
	replay_settle(&run, 500)
	replay_check(&run, "open_notifications_settings")
}

@(test)
parity_settings_appearance :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "settings", R_GUILD, R_TEXT2) do return
	replay_mark(&run)
	settings_pane_shown(run.c, .Notifications, .Appearance, R_GUILD, R_TEXT2)
	replay_settle(&run, 500)
	replay_check(&run, "open_appearance")
}

@(test)
parity_settings_theme_sync :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "settings", R_GUILD, R_TEXT2) do return
	replay_mark(&run)
	set_theme(run.c, .Dark, system = true) // "Sync with computer", OS dark
	replay_settle(&run, 400)
	replay_check(&run, "appearance_sync_on")
}

@(test)
parity_settings_theme_dark :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "settings", R_GUILD, R_TEXT2) do return
	replay_mark(&run)
	set_theme(run.c, .Darker) // UI "Dark"
	replay_settle(&run, 400)
	replay_check(&run, "appearance_sync_off")
}

@(test)
parity_settings_friend_online_toggle :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "streamer_mode", R_GUILD, R_TEXT2) do return
	replay_mark(&run)
	set_friend_online_notifications(run.c, false)
	replay_settle(&run, 400)
	replay_check(&run, "notifications_toggle_off")
	run2: Replay_Run
	if !replay_begin(&run2, t, "streamer_mode", R_GUILD, R_TEXT2) do return
	replay_mark(&run2)
	set_friend_online_notifications(run2.c, true)
	replay_settle(&run2, 400)
	replay_check(&run2, "notifications_toggle_on")
}

// Streamer Mode is local (science only); with it on, the Account pane shows an
// illustration and fetches nothing.
@(test)
parity_streamer_mode :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "streamer_mode", R_GUILD, R_TEXT2) do return
	replay_mark(&run)
	// the app: the switch, Streamer Mode on, and its notice bar on the guild route
	analytics_ui_setting(run.c, "streaming_enable_streamer_mode")
	analytics_streamer_mode_toggle(run.c, true, false)
	analytics_app_notice(run.c, "app_notice_viewed", "STREAMER_MODE", R_GUILD)
	replay_settle(&run, 300)
	replay_check(&run, "streamer_mode_on")
	run2: Replay_Run
	if !replay_begin(&run2, t, "streamer_mode", R_GUILD, R_TEXT2) do return
	replay_mark(&run2)
	settings_pane_shown(run2.c, .Appearance, .Account, R_GUILD, R_TEXT2, streamer_mode = true)
	replay_settle(&run2, 300)
	replay_check(&run2, "streamer_view_account")
	run3: Replay_Run
	if !replay_begin(&run3, t, "streamer_mode", R_GUILD, R_TEXT2) do return
	replay_mark(&run3)
	settings_pane_shown(run3.c, .Notifications, .Appearance, R_GUILD, R_TEXT2, streamer_mode = true)
	replay_settle(&run3, 300)
	replay_check(&run3, "open_settings_appearance")
}

// ---- friend nicknames, server nicknames, user menus (fixture friend_nickname) ----

@(test)
parity_friend_nickname :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "friend_nickname", R_GUILD, R_TEXT2) do return
	replay_mark(&run)
	open_user_context_menu(run.c, R_B, R_GUILD)
	replay_settle(&run, 500)
	replay_check(&run, "friend_nickname_open")
	run2: Replay_Run
	if !replay_begin(&run2, t, "friend_nickname", R_GUILD, R_TEXT2) do return
	replay_mark(&run2)
	set_friend_nickname(run2.c, R_B, "Bobby Nick")
	replay_settle(&run2, 400)
	replay_check(&run2, "friend_nickname_save")
	run3: Replay_Run
	if !replay_begin(&run3, t, "friend_nickname", R_GUILD, R_TEXT2) do return
	replay_mark(&run3)
	set_friend_nickname(run3.c, R_B, "")
	replay_settle(&run3, 400)
	replay_check(&run3, "friend_nickname_reset")
}

@(test)
parity_server_nickname :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "friend_nickname", R_GUILD, R_TEXT2) do return
	open_user_context_menu(run.c, R_B, R_GUILD) // the first right-click (earlier window)
	replay_settle(&run, 400)
	replay_mark(&run)
	open_user_context_menu(run.c, R_B, R_GUILD)
	replay_settle(&run, 300) // the menu is open a moment before "Change Nickname"
	open_change_nickname(run.c)
	replay_settle(&run, 400)
	replay_check(&run, "server_nickname_open")
	run2: Replay_Run
	if !replay_begin(&run2, t, "friend_nickname", R_GUILD, R_TEXT2) do return
	replay_mark(&run2)
	set_server_nickname(run2.c, R_GUILD, R_B, "Server Bob")
	replay_settle(&run2, 400)
	replay_check(&run2, "server_nickname_save")
	run3: Replay_Run
	if !replay_begin(&run3, t, "friend_nickname", R_GUILD, R_TEXT2) do return
	replay_mark(&run3)
	set_server_nickname(run3.c, R_GUILD, R_B, "")
	replay_settle(&run3, 400)
	replay_check(&run3, "server_nickname_remove_save")
}

// ---- friend request from the DM row's menu (fixture friend_add_context_menu) ----

@(test)
parity_friend_add_context_menu :: proc(t: ^testing.T) {
	run: Replay_Run
	// A's side has no READY (the recording started on an open session): A's READY
	// from friend_request_send, where A and B weren't friends either
	if !replay_begin(&run, t, "friend_add_context_menu", 0, 0, ready_from = "friend_request_send") do return
	replay_mark(&run)
	open_dm_row_menu(run.c, R_B)
	replay_settle(&run, 300)
	add_relationship(run.c, R_B, "ContextMenu")
	replay_settle(&run, 400)
	// the hover prefetch of the DM's messages, the session's settings-proto/2 load and the
	// home route's entitlements belong to the hover / route, not to the menu
	replay_check(&run, "friend_request_from_dm_menu", {"/messages?limit", "settings-proto/2", "/entitlements?"})
	run2: Replay_Run
	if !replay_begin(&run2, t, "friend_add_context_menu", 0, 0, "b") do return
	replay_mark(&run2)
	// the app: B opens the Pending tab (click, then the tab's view), then accepts
	analytics_friends_list(run2.c, "friends_list_clicked", .Pending)
	analytics_friends_list(run2.c, "friends_list_viewed", .Pending)
	replay_settle(&run2, 300)
	accept_friend_request(run2.c, run2.c.store.me == R_B ? Snowflake(1546819257420087346) : R_B)
	replay_settle(&run2, 400)
	// GET relationships: the Pending tab's refresh (Friends page)
	replay_check(&run2, "friend_request_accept", {"GET discord.com/api/v9/users/@me/relationships", "referrals/eligibility"})
}

// ---- DM call (fixture dm_call) ----

@(test)
parity_dm_call :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "dm_call", 0, R_DM) do return
	replay_pump(&run, 1500) // the DM's open-time profile loads
	replay_mark(&run)
	dm_call_start(run.c, R_DM)
	// the app reports its voice connection's state (src/voice is not run offline):
	// waiting for the endpoint, then connected
	client_set_rtc_state(run.c, .Awaiting_Endpoint)
	replay_settle(&run, 200)
	replay_dispatches(&run, "start_call")
	client_poll(run.c)
	analytics_permissions_requested(run.c, "audio") // the app opens the microphone on VOICE_SERVER_UPDATE
	client_set_rtc_state(run.c, .Rtc_Connected)
	replay_settle(&run, 2400) // the two shelf loads answer ~1.2 s and ~1.9 s later
	// op 4 preferred_region(s): the live RTC probe; messages?before: history paging after the
	// call message; settings-proto/2: the session's lazy load
	replay_check(&run, "start_call", {"op 4", "/messages?before", "settings-proto/2"})
	run2: Replay_Run
	if !replay_begin(&run2, t, "dm_call", 0, R_DM, "b") do return
	replay_dispatches(&run2, "start_call")
	replay_settle(&run2, 300)
	testing.expect_value(t, incoming_call(run2.c), R_DM)
	replay_mark(&run2)
	call_accept(run2.c, R_DM)
	client_set_rtc_state(run2.c, .Awaiting_Endpoint)
	replay_dispatches(&run2, "b_join_from_ring")
	replay_settle(&run2, 200)
	analytics_permissions_requested(run2.c, "audio") // the app opens the microphone
	client_set_rtc_state(run2.c, .Rtc_Connected)
	replay_settle(&run2, 1500)
	testing.expect_value(t, incoming_call(run2.c), Snowflake(0))
	replay_check(&run2, "b_join_from_ring", {"op 4", "settings-proto/2"})
	run3: Replay_Run
	if !replay_begin(&run3, t, "dm_call", 0, R_DM) do return
	replay_pump(&run3, 1500)
	client_set_rtc_state(run3.c, .Rtc_Connected) // A is in the call
	replay_mark(&run3)
	analytics_call_disconnect(run3.c, 0, R_DM) // the app: the voice panel's Disconnect
	voice_leave(run3.c)
	replay_settle(&run3, 300)
	replay_check(&run3, "a_hang_up")
}

// ---- log out / log in (traffic/account_edits.jsonl) ----
// The fixture has no READY before these windows; the login_submit window's
// READY (account A, the same account) stands in for the session's.

// Log Out from the account switcher's Manage Accounts list (the fixture's
// path; Settings > Log Out sends logout_source "settings" and no
// multi_account_account_remove): POST /auth/logout, then logged out:
// /experiments from the old route, the stale 401 refetches, the fingerprint,
// and the login page (location metadata, login_viewed; the QR socket is off).
@(test)
parity_logout :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "account_edits", 0, 0) do return
	run.c.cfg.disable_remote_auth = true
	identity_set_app_state(&run.c.id, .Focused) // the user clicked Log Out
	replay_mark(&run)
	client_logout(run.c, "multi_accounts_list")
	replay_settle(&run, 700)
	testing.expect(t, client_logged_out(run.c))
	testing.expect(t, auth_fingerprint(run.c) != "")
	replay_check(&run, "logout")
}

// Log In with email and password on the login page after that logout:
// POST /auth/login, then the gateway (IDENTIFY without fast connect), READY
// and the login burst (auth.odin LOGIN_BURST).
@(test)
parity_login_submit :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "account_edits", 0, 0) do return
	c := run.c
	c.cfg.disable_remote_auth = true
	identity_set_app_state(&c.id, .Focused)
	client_logout(c, "multi_accounts_list")
	replay_settle(&run, 700)
	_ = auth_take_events(c) // Logged_Out
	replay_mark(&run)
	// the fixture's values are scrubbed placeholders: the body shape is compared
	auth_login(c, "<email>", transmute([]byte)string("<token>"))
	for i := 0; i < 400 && client_logged_out(c); i += 1 do replay_pump(&run, 5)
	testing.expect(t, !client_logged_out(c))
	if c.gw == nil do return
	evs := auth_take_events(c)
	testing.expect(t, len(evs) == 1 && evs[0].kind == .Logged_In && evs[0].token == "<token>")
	// what the gateway does on its own when it connects (the sink never does)
	gateway_send(c.gw, .Identify, identify_value(c.gw))
	analytics_gateway_connected(c, 0, "wss://gateway.discord.gg", false, false, 160, 160)
	replay_dispatches(&run, "login_submit", "READY")
	replay_dispatches(&run, "login_submit", "READY_SUPPLEMENTAL")
	replay_pump(&run, 20)
	locks.lock(&c.gw.mu)
	gateway_on_ready_locked(c.gw)
	locks.unlock(&c.gw.mu)
	replay_pump(&run, 1500)
	identity_set_app_state(&c.id, .Unfocused) // the window lost focus before the +2 s part of the burst
	replay_pump(&run, 6700) // the burst ends with get-decisions at READY + 7.8 s
	replay_check(&run, "login_submit", {
		// the Friends activity feed (games the friends play) is not modelled
		"applications/public", "/games?",
		// not sent by fastcord (analytics_unknowable / not modelled)
		"science:client_heartbeat", "science:session_start_client", "science:ready_payload_received", "science:game_profile_entry_point_available",
	})
}

// ---- username change (fixture account_edits: a passive recording on the home route) ----

// account_edits starts on an open session (its only READY follows the re-login):
// account A's READY from settings stands in.
@(private = "file")
r_account_begin :: proc(run: ^Replay_Run, t: ^testing.T) -> bool {
	if !replay_begin(run, t, "account_edits", 0, 0, ready_from = "settings") do return false
	identity_set_app_state(&run.c.id, .Focused) // recorded by hand: the window had focus
	return true
}

// Settings > My Account, then "Edit" on the username: the field opens with the
// current name, which is checked 800 ms later (next window).
@(test)
parity_open_account_settings :: proc(t: ^testing.T) {
	run: Replay_Run
	if !r_account_begin(&run, t) do return
	replay_mark(&run)
	settings_pane_shown(run.c, .None, .Account, 0, 0)
	replay_pump(&run, 1500) // nothing more loads while the pane is open
	analytics_ui_setting(run.c, "account_info_username_setting") // the app: Edit
	username_input_changed(run.c, "dingusbattle")
	replay_settle(&run, 100)
	// science: the settings modal's lazy-load spinner (see parity_settings_open);
	replay_check(&run, "open_account_settings", {`science:impression_modal_root_legacy/variant="renderModalSpinner"`})
}

// Typing a new username: the prefilled (current, taken) name is checked, then
// the typed one 800 ms after the last keystroke; a checked name is not re-checked.
@(test)
parity_username_typing :: proc(t: ^testing.T) {
	run: Replay_Run
	if !r_account_begin(&run, t) do return
	analytics_ui_setting(run.c, "account_info_username_setting")
	username_input_changed(run.c, "dingusbattle")
	replay_pump(&run, 700)
	replay_mark(&run)
	replay_pump(&run, 700) // the debounce fires; {"taken":true} -> pomelo_errors
	testing.expect_value(t, username_check(run.c, "dingusbattle").state, Username_Check_State.Taken)
	for name in ([]string{"dingusbattle2", "dingusbattle", "dingusbattle2"}) {
		username_input_changed(run.c, name) // keystrokes (and the cached name typed back)
		replay_pump(&run, 100)
	}
	replay_pump(&run, 1200)
	testing.expect_value(t, username_check(run.c, "dingusbattle2").state, Username_Check_State.Available)
	replay_settle(&run, 300)
	// metrics/v2: the web client's performance metrics batch (wasm asset loads...);
	// client_ad_heartbeat: the 5-minute ad heartbeat timer, not this action
	replay_check(&run, "username_typing", {"metrics/v2", "science:client_ad_heartbeat"})
}

// Done: PATCH /users/@me {"username","password"}; then "Edit" again (science).
@(test)
parity_username_submit :: proc(t: ^testing.T) {
	run: Replay_Run
	if !r_account_begin(&run, t) do return
	replay_mark(&run)
	update_username(run.c, "dingusbattle2", "fastcord-test-password")
	replay_settle(&run, 1200)
	got_patch := false
	for i := 0; i < 200 && !got_patch; i += 1 {
		client_poll(run.c)
		for &r in feature_take(run.c) {
			if r.op == .User_Patch do got_patch = r.ok
			feature_result_free(&r)
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, got_patch, "the PATCH was not answered")
	analytics_ui_setting(run.c, "account_info_username_setting") // the app: Edit again
	replay_settle(&run, 300)
	replay_check(&run, "username_submit")
}

// A name not checked before (one keystroke after the editor reopened): available.
@(test)
parity_username_taken_check :: proc(t: ^testing.T) {
	run: Replay_Run
	if !r_account_begin(&run, t) do return
	// the session's earlier checks (username_typing), whose answers come first
	for name in ([]string{"dingusbattle", "dingusbattle2"}) {
		username_input_changed(run.c, name)
		replay_pump(&run, 1300)
	}
	replay_mark(&run)
	username_input_changed(run.c, "dingusbattle3")
	replay_pump(&run, 1300)
	testing.expect_value(t, username_check(run.c, "dingusbattle3").state, Username_Check_State.Available)
	replay_settle(&run, 300)
	// client_ad_heartbeat: the 5-minute ad heartbeat timer, not this action
	replay_check(&run, "username_taken_check", {"science:client_ad_heartbeat"})
}

@(test)
username_rules :: proc(t: ^testing.T) {
	testing.expect_value(t, username_rule_error("dingus_battle.2"), "")
	testing.expect_value(t, username_rule_error("a"), "This must be 2-32 characters.")
	testing.expect_value(t, username_rule_error("a..b"), "Username cannot contain repeating dots.")
	testing.expect_value(t, username_rule_error("no spaces"), "Please only use numbers, letters, underscores _ , or periods.")
}
