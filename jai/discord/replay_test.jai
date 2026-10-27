// Offline parity: the library runs a scenario's action against the official
// fixture (traffic/<scenario>.jsonl) with no network. HTTP is answered from the
// recorded responses (Config.round_tripper), gateway frames go to a sink
// (Config.gateway_sink) and the window's recorded dispatches are injected.
// What we send in the action window is compared with what the official client
// sent: request set (method + URL shape), true wire header order, body shape,
// and the gateway ops with their payload shapes.
//
// Run all: jai build.jai - test; one: jai build.jai - test parity_send_message
// (arguments are substrings of test names; offline).

#scope_file

R_GUILD :: cast(Snowflake)(1564227669971832975);
R_TEXT :: cast(Snowflake)(1564227670806364343);
R_VOICE :: cast(Snowflake)(1564227670806364345);
R_DM :: cast(Snowflake)(1564228964451356713);
R_B :: cast(Snowflake)(1564202918369042442);
// the test guild's text channel after it was recreated (fixtures threads_browser,
// history_nav, discover...: no system channel)
R_TEXT2 :: cast(Snowflake)(1564405699197407414);

// Requests the comparison leaves out: UI assets and images the app fetches
// itself, the RTC probe and Cloudflare's page challenge. Telemetry (/science)
// is compared on its own, per event (r_science_check).
R_IGNORE := string.["/assets/", "collectibles-shop", "latency.discord.media", "/cdn-cgi/", "media.discordapp.net", "/app-icons/", "/emojis/", "/avatars/", "/stickers/", "images-ext"];
#scope_export

Replay :: struct {
	mu: locks.Mutex;
	arena: virtual.Arena;
	events: [..]etf.Map; // fixture lines (acct a), placeholders turned into ids
	used: [..]bool;
	ours: [..]Replay_Req;
	sends: [..]Replay_Send;
	science: [..]Sci_Batch; // our /science POSTs since the mark
	marked: bool;
}

Replay_Req :: struct {
	key: string;
	wire: string; // header names in send order
	shape: string;
}

Replay_Send :: struct {
	op: s64;
	shape: string;
}
#scope_file

// ---- fixture ----

// Scrubbed values ("<new:2>", "<user:3>", "<id:...>") become stable fake
// snowflakes so the client can parse and reuse them; URL keys normalize ids again.
// New objects ("<new:N>") sort after the fixture's real ids, in creation order.
r_unscrub :: (v: V) -> V {
	if v.kind == {
	case .String; x := v.s;
		if len(x) > 3 && x[0] == #char "<" && x[len(x) - 1] == #char ">" && strings.contains(x, ":") {
			// "<new:N>": created during the capture, in N order, after every real id
			if strings.has_prefix(x, "<new:") {
				{ n, ok := strconv.parse_u64(sub(x, 5, len(x) - 1));
				if ok { return to_v(fmt.aprintf("%d", 1_700_000_000_000_000_000 + (n << 22))); } }
			}
			return to_v(fmt.aprintf("%d", 1_100_000_000_000_000_000 + cast(u64)(fnv32a(x))));
		}
	case .List; x := v.list;
		for * e: x { e.* = r_unscrub(e.*); }
	case .Map; x := v.map;
		for * p: x { p.value = r_unscrub(p.value); }
	}
	return v;
}

fnv32a :: (s: string) -> u32 { // Odin's hash.fnv32a
	h: u32 = 0x811c9dc5;
	for i: 0..s.count-1 { h ^= s[i]; h *= 0x01000193; }
	return h;
}

replay_load :: (r: *Replay, scenario: string, acct := "a") -> bool {
	virtual.arena_init_growing(*r.arena);
	push_allocator(virtual.arena_allocator(*r.arena));
	// appended to from worker threads later: keep them in the replay arena too
	r.ours = make_dynamic(Replay_Req, 0, 0);
	r.sends = make_dynamic(Replay_Send, 0, 0);
	r.science = make_dynamic(Sci_Batch, 0, 0);
	data, err := os.read_entire_file(fmt.tprintf("traffic/%s.jsonl", scenario), context.allocator); // tests run from the repo root
	if err != null { return false; }
	text := as_string(data);
	while true { line, __ok2 := strings.split_lines_iterator(*text); if !__ok2 break;
		v, perr := etf.from_json(line);
		if perr != .None { continue; }
		m := vmap(v);
		// account a's lines carry no "acct" (or "a"); marks belong to both
		a := fstr(m, "acct");
		if a == "" { a = "a"; }
		if a != acct && fstr(m, "k") != "mark" { continue; }
		append(*r.events, vmap(r_unscrub(v)));
		append(*r.used, false);
	}
	return true;
}

// window: the fixture events between mark `name` and the next mark.
replay_window :: (r: *Replay, name: string) -> []etf.Map {
	start, end := -1, len(r.events);
	for e, i: r.events {
		if fstr(e, "k") != "mark" { continue; }
		if start >= 0 {
			end = i;
			break;
		}
		if fstr(e, "name") == name { start = i + 1; }
	}
	if start < 0 { return .{}; }
	return sub(r.events, start, end);
}

// URL key: host + path with ids folded to {id}, query names without values.
r_key :: (method: string, url: string) -> string {
	u := url;
	{ i := strings.index(u, "://");
	if i >= 0 { u = sub_from(u, i + 3); } }
	path, query := u, "";
	{ i := strings.index_byte(u, #char "?");
	if i >= 0 { path, query = sub(u, 0, i), sub_from(u, i + 1); } }
	sb := strings.builder_make(temp);
	fmt.sbprintf(*sb, "%s ", method);
	for seg, i: strings.split(path, "/", temp) {
		if i > 0 { strings.write_byte(*sb, #char "/"); }
		digits := len(seg) >= 15;
		for ch: seg { if ch < #char "0" || ch > #char "9" { digits = false; } }
		strings.write_string(*sb, ifx digits || (strings.has_prefix(seg, "%3C") || strings.has_prefix(seg, "<")) then "{id}" else seg);
	}
	if query != "" {
		strings.write_byte(*sb, #char "?");
		for kv, i: strings.split(query, "&", temp) {
			if i > 0 { strings.write_byte(*sb, #char "&"); }
			strings.write_string(*sb, ifx strings.contains(kv, "=") then sub(kv, 0, strings.index_byte(kv, #char "=")) else kv);
		}
	}
	return strings.to_string(sb);
}

r_ignored :: (url: string) -> bool {
	for s: R_IGNORE { if strings.contains(url, s) { return true; } }
	return false;
}

r_shape :: (v: V, sb: *strings.Builder, depth := 0) {
	if v.kind == {
	case .Nil;
		strings.write_string(sb, "null");
	case .Bool; x := v.b;
		strings.write_string(sb, "bool");
	case .Int; #through; case .Float; #through; case .Big; x := v;
		strings.write_string(sb, "num");
	case .String; #through; case .Atom; #through; case .Charlist; x := v;
		// unscrubbed ids are numeric strings on both sides
		strings.write_string(sb, "str");
	case .List; x := v.list;
		strings.write_byte(sb, #char "[");
		if len(x) > 0 && depth < 12 { r_shape(x[0], sb, depth + 1); }
		strings.write_byte(sb, #char "]");
	case .Tuple; x := v.list;
		strings.write_string(sb, "tuple");
	case .Map; x := v.map;
		strings.write_byte(sb, #char "{");
		for p, i: x {
			if i > 0 { strings.write_byte(sb, #char ","); }
			fmt.sbprintf(sb, "%s:", vstr(p.key)); // JSON keys are strings
			r_shape(p.value, sb, depth + 1);
		}
		strings.write_byte(sb, #char "}");
	}
}

shape_text :: (v: V) -> string {
	sb := strings.builder_make(temp);
	r_shape(v, *sb);
	return strings.to_string(sb);
}

// fixture body value -> the JSON the server sent (or "" when only a hash was kept)
r_body_value :: (v: V) -> V, bool {
	{ m := vmap(v);
	if len(m) == 1 {
		k := vstr(m[0].key);
		if k == "$b64json" { return m[0].value, true; }
		if strings.has_prefix(k, "$") { return .{}, false; }
	} }
	return v, !is_null(v);
}

// Science event signature: its type and property names in order, without the
// per-event decorations (timestamps, uuids, performance) every event carries.
R_SCIENCE_DECOR := string.["client_track_timestamp", "client_heartbeat_session_id", "event_sequence_number", "client_performance_cpu", "client_performance_memory", "cpu_core_count", "accessibility_features", "rendered_locale", "uptime_app", "uptime_process_renderer", "launch_signature", "client_rtc_state", "client_app_state", "client_viewport_width", "client_viewport_height", "client_uuid", "client_send_timestamp"];

r_event_sig :: (e: etf.Map) -> string {
	sb := strings.builder_make(temp);
	strings.write_string(*sb, fstr(e, "type"));
	strings.write_byte(*sb, #char "{");
	first := true;
	for p: fmap(e, "properties") {
		k := vstr(p.key);
		for d: R_SCIENCE_DECOR { if d == k { continue p; } }
		if !first { strings.write_byte(*sb, #char ","); }
		first = false;
		strings.write_string(*sb, k);
	}
	strings.write_byte(*sb, #char "}");
	return strings.to_string(sb);
}

// ---- network stand-ins ----

replay_round_trip :: (data: *void, host: string, req: http.Request) -> http.Response, http.Error {
	resp: http.Response;
	err: http.Error;
	delay: float64;
	resp, err, delay = replay_exchange(cast(*Replay)data, host, req);
	// after the mark, answer after the recorded latency (capped): response-time
	// events (telemetry, follow-ups) then land as far apart as they did officially
	if delay > 0 { time.sleep(cast(time.Duration)(min(delay, 1000) * cast(float64)(time.Millisecond))); }
	return resp, err;
}

replay_exchange :: (r: *Replay, host: string, req: http.Request) -> http.Response, http.Error, float64 {
	resp: http.Response;
	err: http.Error;
	delay_ms: float64;
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	url := strings.concatenate(string.["https://", host, req.path], temp);
	key := r_key(req.method, url);
	// the recorded exchange with the same URL shape, earliest first
	ri := -1;
	for e, i: r.events {
		if r.used[i] || fstr(e, "k") != "req" { continue; }
		if r_key(fstr(e, "method"), fstr(e, "url")) == key {
			ri = i;
			break;
		}
	}
	proto := "h3";
	official_wire: etf.List;
	if ri >= 0 {
		r.used[ri] = true;
		proto = fstr(r.events[ri], "proto");
		official_wire, _ = vget(r.events[ri], "wire").list, vget(r.events[ri], "wire").kind == .List;
	}
	if r.marked && !r_ignored(url) {
		// our wire order, as fc:http (h2) / fc:quic put it on the wire
		sb := strings.builder_make(temp);
		strings.write_string(*sb, ":method,:authority,:scheme,:path");
		has_priority := false;
		for h: req.headers {
			n := strings.to_lower(h.name, temp);
			if n == "priority" { has_priority = true; }
			if n == "cookie" || n == "if-none-match" || n == "if-modified-since" { continue; }
			fmt.sbprintf(*sb, ",%s", n);
		}
		if proto == "h3" && !has_priority { strings.write_string(*sb, ",priority"); }
		shape := "";
		if len(req.body) > 0 {
			{ v, perr := etf.from_json(as_string(req.body), temp);
			if perr == .None { shape = shape_text(v); } }
		}
		alloc := virtual.arena_allocator(*r.arena);
		if r_is_science(url) {
			{ v, perr := etf.from_json(as_string(req.body), temp);
			if perr == .None {
				b := r_sci_parse(v, alloc);
				b.wire = clone(strings.to_string(sb), alloc);
				append(*r.science, b);
			} }
		} else {
			append(*r.ours, Replay_Req.{clone(key, alloc), clone(strings.to_string(sb), alloc), clone(shape, alloc)});
		}
	}
	// Odin frees a nil-allocator response's strings as no-ops; here they live in the replay arena
	resp.allocator = virtual.arena_allocator(*r.arena);
	push_allocator(resp.allocator);
	resp.version = ifx proto == "h3" then .Http3 else .Http2;
	resp.status = 200;
	body := "{}";
	if ri >= 0 {
		id := fnum(r.events[ri], "id");
		for e: r.events {
			if fstr(e, "k") != "resp" || fnum(e, "id") != id { continue; }
			if r.marked { delay_ms = r_num_f(vget(e, "t")) - r_num_f(vget(r.events[ri], "t")); }
			resp.status = cast(int)(fnum(e, "status"));
			for h: flist(e, "headers") {
				l := vlist(h);
				if len(l) != 2 { continue; }
				n := vstr(l[0]);
				if n == "content-encoding" || n == "content-length" { continue; } // the body below is decoded
				ha := virtual.arena_allocator(*r.arena); // the response is the transport's; strings live with the replay
				append(*resp.headers, http.Header.{clone(n, ha), clone(vstr(l[1]), ha)});
			}
			{ bv, ok := r_body_value(vget(e, "body"));
			if ok {
				body = etf_json(bv);
			} else {
				body = "";
			} }
			break;
		}
	}
	append(*resp.body, ..transmute([]u8, body));
	return resp, .None, delay_ms;
}

r_num_f :: (v: V) -> float64 {
	if v.kind == {
	case .Float; x := v.f;
		return x;
	case .Int; x := v.i;
		return cast(float64)(x);
	}
	return 0;
}

etf_json :: (v: V) -> string {
	sb := strings.builder_make(temp);
	etf.to_json(v, *sb);
	return strings.to_string(sb);
}

fnum :: (m: etf.Map, k: string) -> s64 {
	{ __v6 := vget(m, k);
	if __v6.kind == {
	case .Int; x := __v6.i;
		return x;
	case .Float; x := __v6.f;
		return cast(s64)(x);
	} }
	return 0;
}

replay_sink :: (data: *void, op: Op, d: V) {
	r := cast(*Replay)data;
	if op == .Heartbeat || op == .Qos_Heartbeat { return; }
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	if !r.marked { return; }
	append(*r.sends, Replay_Send.{cast(s64)(op), clone(shape_text(d), virtual.arena_allocator(*r.arena))});
}
#scope_export

// ---- driving ----

Replay_Run :: struct {
	r: Replay;
	c: *Client;
	t: *T;
	donor: Replay; // ready_from's fixture (its READY)
	science: bool; // also compare /science events (type + property names); allow "science <type>"
}
#scope_file

replay_begin :: (run: *Replay_Run, t: *T, scenario: string, guild: Snowflake, channel: Snowflake, acct := "a", ready_from := "") -> bool {
	run.t = t;
	if !replay_load(*run.r, scenario, acct) {
		expectf(t, false, "no fixture traffic/%s.jsonl", scenario);
		return false;
	}
	ready_events := view(run.r.events);
	if ready_from != "" {
		donor: Replay;
		if !replay_load(*donor, ready_from, acct) {
			expectf(t, false, "no fixture traffic/%s.jsonl", ready_from);
			return false;
		}
		// the donor's arena lives as long as the run: its values are injected below
		ready_events = clone(view(donor.events), virtual.arena_allocator(*donor.arena));
		run.donor = donor;
	}
	run.c = client_create(Config.{
		token = "<token>",
		disable_startup = true,
		round_tripper = .{*run.r, replay_round_trip},
		gateway_sink = replay_sink,
		gateway_sink_data = *run.r,
		initial_guild_id = guild,
		initial_channel_id = channel
	});
	client_set_viewport(run.c, 1280, 720);
	client_set_accessibility(run.c, accessibility_flags(.{})); // light OS, store defaults: the fixtures' 524416
	identity_touch_heartbeat(*run.c.id, now_ms()); // the launch's heartbeat session (the window had focus)
	run.c.analytics.roundtrip_sample = 0; // send_message_roundtrip is sampled (10%): never offline
	identity_set_app_state(*run.c.id, .Unfocused);
	client_start(run.c);
	// session state from the fixture's READY
	for name: (string.["READY", "READY_SUPPLEMENTAL"]) {
		for e: ready_events {
			if fstr(e, "k") == "ws_recv" && fstr(e, "ev") == name {
				// what the gateway reader does with READY before dispatching it
				{ inst := fstr(fmap(vmap(vget(e, "d")), "apex_experiments"), "installation");
				if inst != "" && name == "READY" {
					run.c.id.installation_id = clone(inst, run.c.allocator);
				} }
				client_inject_dispatch(run.c, name, vget(e, "d"));
				break;
			}
		}
	}
	// READY's apex_experiments.installation is scrubbed from the fixtures
	if run.c.id.installation_id == "" { run.c.id.installation_id = clone("1100000000000000001", run.c.allocator); }
	replay_settle(run, 300);
	if channel != 0 || guild != 0 {
		select_channel(run.c, guild, channel, 10);
		replay_settle(run, 400);
	}
	replay_drain(run);
	return true;
}

// replay_drain: before the first mark, wait (bounded) until the setup's queued
// analytics and REST jobs have gone out. replay_settle only sees requests made
// after a mark, so on a slow machine (CI) the setup's first /science batch
// could otherwise land in the action window.
replay_drain :: (run: *Replay_Run, max_ms := 3000) {
	start := time.tick_now();
	while time.tick_since(start) < cast(time.Duration)(max_ms) * time.Millisecond {
		client_poll(run.c);
		locks.lock(*run.c.analytics.mu);
		queued := len(run.c.analytics.queue);
		locks.unlock(*run.c.analytics.mu);
		locks.lock(*run.c.job_mu);
		jobs := 0;
		for j: run.c.jobs { if j.not_before <= now_ms() { jobs += 1; } } // timers due later belong to the session
		jobs += run.c.jobs_running;
		locks.unlock(*run.c.job_mu);
		if queued == 0 && jobs == 0 { return; }
		time.sleep(5 * time.Millisecond);
	}
}

// replay_settle: poll until nothing new was sent for quiet_ms (bounded).
replay_settle :: (run: *Replay_Run, quiet_ms: int, max_ms := 4000) {
	start := time.tick_now();
	last := time.tick_now();
	n := -1;
	while time.tick_since(start) < cast(time.Duration)(max_ms) * time.Millisecond {
		client_poll(run.c);
		locks.lock(*run.r.mu);
		k := len(run.r.ours) + len(run.r.sends) + cast(int)(run.r.marked);
		locks.unlock(*run.r.mu);
		if k != n {
			n = k;
			last = time.tick_now();
		}
		if time.tick_since(last) >= cast(time.Duration)(quiet_ms) * time.Millisecond { return; }
		time.sleep(5 * time.Millisecond);
	}
}

// replay_pump: poll for a fixed time (library timers: typing 1.5 s...).
replay_pump :: (run: *Replay_Run, ms: int) {
	start := time.tick_now();
	while time.tick_since(start) < cast(time.Duration)(ms) * time.Millisecond {
		client_poll(run.c);
		time.sleep(5 * time.Millisecond);
	}
}

// replay_mark: start comparing from here (the official window `name`).
replay_mark :: (run: *Replay_Run) {
	locks.lock(*run.r.mu);
	run.r.marked = true;
	clear(*run.r.ours);
	clear(*run.r.sends);
	clear(*run.r.science);
	locks.unlock(*run.r.mu);
}

// replay_dispatches feeds the window's recorded dispatches (MESSAGE_CREATE...).
replay_dispatches :: (run: *Replay_Run, window: string, only := "") {
	for e: replay_window(*run.r, window) {
		if fstr(e, "k") != "ws_recv" || fnum(e, "op") != 0 { continue; }
		ev := fstr(e, "ev");
		if only != "" && ev != only { continue; }
		client_inject_dispatch(run.c, ev, vget(e, "d"));
	}
}

// replay_end frees a run whose windows were checked with keep = true.
replay_end :: (run: *Replay_Run) {
	client_destroy(run.c);
	virtual.arena_destroy(*run.r.arena);
	if run.donor.events.count { virtual.arena_destroy(*run.donor.arena); }
}
#scope_export

// replay_compare: one window of a multi-window run (the client is kept).
replay_compare :: (run: *Replay_Run, window: string, allow: []string = .{}) {
	replay_check(run, window, allow, keep = true);
}
#scope_file

// replay_check compares our traffic since the mark with the official window.
// allow: keys / "op N" that may differ (known, documented gaps).
// keep: the run goes on to the next window (finish with replay_end).
// science_only: compare only /science (windows whose request differences are
// session state documented in traffic/PARITY.md, not this test's subject).
replay_check :: (run: *Replay_Run, window: string, extra_allow: []string = .{}, keep := false, science_only := false) {
	t := run.t;
	defer if !keep { replay_end(run); }
	all := make_dynamic(string, 0, 0, temp);
	append(*all, ..R_SCI_NEVER);
	append(*all, ..extra_allow);
	allow := view(all);
	official := make_dynamic(etf.Map, 0, 0, temp);
	official_sci := make_dynamic(Sci_Batch, 0, 0, temp);
	ops := make_dynamic(etf.Map, 0, 0, temp);
	for e: replay_window(*run.r, window) {
		if fstr(e, "k") == {
		case "req";
			url := fstr(e, "url");
			if r_is_science(url) {
				{ bv, ok := r_body_value(vget(e, "body"));
				if ok {
					b := r_sci_parse(bv, temp);
					b.wire = r_official_wire(e);
					append(*official_sci, b);
				} }
			} else if !r_ignored(url) {
				append(*official, e);
			}
		case "ws_send";
			{ op := fnum(e, "op");
			if op != 1 && op != 40 { append(*ops, e); } }
		}
	}
	allowed :: (allow: []string, s: string) -> bool {
		for a: allow { if strings.contains(s, a) { return true; } }
		return false;
	}
	locks.lock(*run.r.mu);
	ours := clone(view(run.r.ours), temp);
	sends := clone(view(run.r.sends), temp);
	ours_sci := clone(view(run.r.science), temp);
	locks.unlock(*run.r.mu);
	if science_only {
		clear(*official);
		clear(*ops);
		ours, sends = .[], .[];
	}
	taken := make_slice(bool, len(ours), temp);
	diffs := strings.builder_make(temp);
	for e: official {
		key := r_key(fstr(e, "method"), fstr(e, "url"));
		j := -1;
		for o, i: ours { if !taken[i] && o.key == key {j = i; break;} }
		if j < 0 {
			if !allowed(allow, key) { fmt.sbprintfln(*diffs, "  - missing  %s", key); }
			continue;
		}
		taken[j] = true;
		// wire order (netlog), cache validators and cookies left out on both sides
		{ w := r_official_wire(e);
		if w != "" && w != ours[j].wire && !allowed(allow, key) {
			fmt.sbprintfln(*diffs, "  ~ wire     %s\n      official: %s\n      ours:     %s", key, w, ours[j].wire);
		} }
		{ bv, ok := r_body_value(vget(e, "body"));
		if ok && ours[j].shape != "" {
			{ s := shape_text(bv);
			if s != ours[j].shape && !allowed(allow, key) {
				fmt.sbprintfln(*diffs, "  ~ body     %s\n      official: %s\n      ours:     %s", key, s, ours[j].shape);
			} }
		} }
	}
	for o, i: ours { if !taken[i] && !allowed(allow, o.key) { fmt.sbprintfln(*diffs, "  + extra    %s", o.key); } }
	// gateway: same ops in the same order, same payload shapes (allowed ops left out)
	{
		k := 0;
		for e: ops { if !allowed(allow, fmt.tprintf("op %d", fnum(e, "op"))) {ops[k] = e; k += 1;} }
		resize(*ops, k);
		f := make_dynamic(Replay_Send, 0, 0, temp);
		for x: sends { if !allowed(allow, fmt.tprintf("op %d", x.op)) { append(*f, x); } }
		sends = view(f);
	}
	for i: 0..(max(len(ops), len(sends)))-1 {
		if i >= len(ops) {
			if !allowed(allow, fmt.tprintf("op %d", sends[i].op)) { fmt.sbprintfln(*diffs, "  + extra    gateway op %d", sends[i].op); }
			continue;
		}
		op := fnum(ops[i], "op");
		if i >= len(sends) {
			if !allowed(allow, fmt.tprintf("op %d", op)) { fmt.sbprintfln(*diffs, "  - missing  gateway op %d", op); }
			continue;
		}
		if sends[i].op != op {
			fmt.sbprintfln(*diffs, "  ~ gateway #%d: op %d vs %d", i + 1, op, sends[i].op);
		} else { s := shape_text(vget(ops[i], "d"));
if s != sends[i].shape && !allowed(allow, fmt.tprintf("op %d", op)) {
			fmt.sbprintfln(*diffs, "  ~ gateway op %d payload\n      official: %s\n      ours:     %s", op, s, sends[i].shape);
		} }
	}
	r_science_check(view(official_sci), ours_sci, allow, *diffs);
	if len(diffs.buf) > 0 { expectf(t, false, "window %q differs from the official client:\n%s", window, strings.to_string(diffs)); }
}
#scope_export

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
	type: string;
	keys: []string;
	kinds: []string; // value type per key
	consts: []string; // constant value per key, "" when the value is variable
	track: s64;
	batch: int;
}

Sci_Batch :: struct {
	events: []Sci_Event;
	send: s64;
	wire: string;
}
#scope_file

SCI_SAME_STEP_MS :: 3;
// officially separate batches closer than this are flush timing, not steps
SCI_SEPARATE_MS :: 100;

r_is_science :: (url: string) -> bool {return strings.contains(url, "/api/v9/science");}

r_allowed :: (allow: []string, s: string) -> bool {
	for a: allow { if strings.contains(s, a) { return true; } }
	return false;
}

// r_official_wire: the netlog header order of a fixture request (cookies and
// cache validators left out), "" without a netlog.
r_official_wire :: (e: etf.Map) -> string {
	wl, ok := vget(e, "wire").list, vget(e, "wire").kind == .List;
	if !ok || fstr(e, "wire_src") != "netlog" { return ""; }
	sb := strings.builder_make(temp);
	first := true;
	for h: wl {
		n := strings.to_lower(vstr(vlist(h)[0]), temp);
		if n == "cookie" || n == "if-none-match" || n == "if-modified-since" { continue; }
		if !first { strings.write_byte(*sb, #char ","); }
		first = false;
		strings.write_string(*sb, n);
	}
	return strings.to_string(sb);
}

// Keys whose numeric values are enums (compared by value).
SCI_NUM_ENUMS := string.["channel_type", "parent_channel_type", "current_channel_type", "relationship_type", "content_id", "status_code", "channel_resolved_unread_setting", "guild_resolved_unread_setting", "version"];

// r_sci_const: the value of a constant-valued property, "" when it varies by nature.
r_sci_const :: (key: string, v: V) -> string {
	if v.kind == {
	case .Nil;
		return "null";
	case .Bool; x := v.b;
		return ifx x then "true" else "false";
	case .Int; x := v.i;
		for k: SCI_NUM_ENUMS { if k == key { return fmt.tprintf("%d", x); } }
	case .String; x := v.s;
		if len(x) == 0 { return "\"\""; }
		digits := true;
		for ch: x { if ch < #char "0" || ch > #char "9" { digits = false; } }
		if digits { return ""; } // ids
		if len(x) >= 20 && !strings.contains(x, " ") && strings.contains_any(x, "0123456789") { return ""; } // uuids, base64, hex load ids
		if len(x) >= 19 && x[4] == #char "-" && strings.contains(x, "T") { return ""; } // ISO times
		if key == {
		case "query"; #through; case "emoji_name"; #through; case "launch_signature"; #through; case "client_heartbeat_session_id"; #through; case "client_uuid"; #through; case "load_id";
			return "";
		}
		return fmt.tprintf("%q", x);
	}
	return "";
}

r_sci_kind :: (v: V) -> string {
	if v.kind == {
	case .List; #through; case .Map;
		return shape_text(v);
	}
	sb := strings.builder_make(temp);
	r_shape(v, *sb);
	return strings.to_string(sb);
}

// r_sci_parse: one /science body. Strings live in `alloc`.
r_sci_parse :: (body: V, alloc: Allocator) -> Sci_Batch {
	b: Sci_Batch;
	evs := make_dynamic(Sci_Event, 0, 0, alloc);
	for ev: flist(vmap(body), "events") {
		m := vmap(ev);
		props := fmap(m, "properties");
		e := Sci_Event.{type = clone(fstr(m, "type"), alloc)};
		keys := make_dynamic(string, 0, 0, alloc);
		kinds := make_dynamic(string, 0, 0, alloc);
		consts := make_dynamic(string, 0, 0, alloc);
		for p: props {
			k := vstr(p.key);
			if k == {
			case "client_track_timestamp";
				e.track = vint(p.value);
			case "client_send_timestamp";
				b.send = vint(p.value);
			}
			append(*keys, clone(k, alloc));
			append(*kinds, clone(r_sci_kind(p.value), alloc));
			append(*consts, clone(r_sci_const(k, p.value), alloc));
		}
		e.keys, e.kinds, e.consts = view(keys), view(kinds), view(consts);
		append(*evs, e);
	}
	b.events = view(evs);
	return b;
}

// r_sci_filtered: an allow entry `science:<type>/<key>=<const>` drops the events
// of that type whose property has that constant value (e.g. one profile_action).
r_sci_filtered :: (allow: []string, e: Sci_Event) -> bool {
	for a: allow {
		if !strings.has_prefix(a, "science:") { continue; }
		slash := strings.index_byte(a, #char "/");
		eq := strings.index_byte(a, #char "=");
		if slash < 0 || eq < slash || sub(a, len("science:"), slash) != e.type { continue; }
		k, v := sub(a, slash + 1, eq), sub_from(a, eq + 1);
		for key, i: e.keys { if key == k && e.consts[i] == v { return true; } }
	}
	return false;
}

r_sci_flatten :: (batches: []Sci_Batch, allow: []string) -> []Sci_Event {
	out := make_dynamic(Sci_Event, 0, 0, temp);
	for b, bi: batches {
		for e: b.events {
			if r_allowed(allow, fmt.tprintf("science:%s", e.type)) { continue; }
			if r_sci_filtered(allow, e) { continue; }
			x := e;
			x.batch = bi;
			append(*out, x);
		}
	}
	return view(out);
}

// r_sci_key_diff: missing / extra keys, else the first out-of-order key.
r_sci_key_diff :: (diffs: *strings.Builder, o: Sci_Event, u: Sci_Event) {
	has :: (l: []string, k: string) -> bool {
		for x: l { if x == k { return true; } }
		return false;
	}
	missing, extra := make_dynamic(string, 0, 0, temp), make_dynamic(string, 0, 0, temp);
	for k: o.keys { if !has(u.keys, k) { append(*missing, k); } }
	for k: u.keys { if !has(o.keys, k) { append(*extra, k); } }
	if len(missing) > 0 || len(extra) > 0 {
		fmt.sbprintfln(diffs, "  ~ science  %s keys: missing [%s] extra [%s]", o.type, strings.join(view(missing), ",", temp), strings.join(view(extra), ",", temp));
		return;
	}
	for k, i: o.keys { if u.keys[i] != k {
		fmt.sbprintfln(diffs, "  ~ science  %s key order: official %s at #%d, ours %s", o.type, k, i, u.keys[i]);
		return;
	} }
}

// r_science_check compares our /science batches with the official window's.
r_science_check :: (official: []Sci_Batch, ours: []Sci_Batch, allow: []string, diffs: *strings.Builder) {
	// header order: every batch of ours against the official window's (no
	// x-science-test after the first batch of a launch)
	if len(official) > 0 && official[0].wire != "" {
		for b: ours { if b.wire != official[0].wire {
			fmt.sbprintfln(diffs, "  ~ wire     POST /science\n      official: %s\n      ours:     %s", official[0].wire, b.wire);
			break;
		} }
	}
	off := r_sci_flatten(official, allow);
	our := r_sci_flatten(ours, allow);
	// FASTCORD_SCI_DEBUG=1: print both event sequences (batch, type, constants)
	if os.get_env("FASTCORD_SCI_DEBUG", temp) != "" {
		for e: off { fmt.eprintfln("official  #%d %s %v", e.batch, e.type, e.consts); }
		for e: our { fmt.eprintfln("ours      #%d %s %v", e.batch, e.type, e.consts); }
		for b: ours { fmt.eprintfln("ours wire %s", b.wire); }
		for b: official { fmt.eprintfln("official wire %s", b.wire); }
	}
	// longest common subsequence of the event types
	n, m := len(off), len(our);
	lcs := make_slice(int, (n + 1) * (m + 1), temp);
	for < i: 0..n - 1 {
		{ j := m - 1;
		while j >= 0 {
			lcs[i * (m + 1) + j] = ifx off[i].type == our[j].type then lcs[(i + 1) * (m + 1) + j + 1] + 1 else max(lcs[(i + 1) * (m + 1) + j], lcs[i * (m + 1) + j + 1]);
			j -= 1;
} }
	}
	pairs := make_dynamic([2]int, 0, 0, temp);
	i, j := 0, 0;
	while i < n || j < m {
		if i < n && j < m && off[i].type == our[j].type {
			append(*pairs, int.[i, j]);
			i += 1;
			j += 1;
		} else if j < m && (i >= n || lcs[i * (m + 1) + j + 1] >= lcs[(i + 1) * (m + 1) + j]) {
			fmt.sbprintfln(diffs, "  + extra    science %s", our[j].type);
			j += 1;
		} else {
			fmt.sbprintfln(diffs, "  - missing  science %s", off[i].type);
			i += 1;
		}
	}
	// same-type events of one step (responses racing each other) may come in
	// either order: pair them by their constant values
	same_consts :: (a: Sci_Event, b: Sci_Event) -> bool {
		if len(a.consts) != len(b.consts) { return false; }
		for x, i: a.consts { if x != b.consts[i] { return false; } }
		return true;
	}
	for pi: 0..len(pairs)-1 {
		if same_consts(off[pairs[pi][0]], our[pairs[pi][1]]) { continue; }
		{ pj := pi + 1;
		while pj < len(pairs) && off[pairs[pj][0]].type == off[pairs[pi][0]].type {
			if same_consts(off[pairs[pi][0]], our[pairs[pj][1]]) && same_consts(off[pairs[pj][0]], our[pairs[pi][1]]) {
				tmp := pairs[pi][1]; pairs[pi][1] = pairs[pj][1]; pairs[pj][1] = tmp;
				break;
			}
			pj += 1;
} }
	}
	for p: pairs {
		o, u := off[p[0]], our[p[1]];
		ok_keys := len(o.keys) == len(u.keys);
		if ok_keys { for k, ki: o.keys { if k != u.keys[ki] { ok_keys = false; } } }
		if !ok_keys {
			r_sci_key_diff(diffs, o, u);
			continue;
		}
		for k, ki: o.keys {
			if r_allowed(allow, fmt.tprintf("science:%s.%s", o.type, k)) { continue; }
			if o.kinds[ki] != u.kinds[ki] {
				fmt.sbprintfln(diffs, "  ~ science  %s.%s type: official %s, ours %s", o.type, k, o.kinds[ki], u.kinds[ki]);
			} else if o.consts[ki] != "" && o.consts[ki] != u.consts[ki] {
				fmt.sbprintfln(diffs, "  ~ science  %s.%s: official %s, ours %s", o.type, k, o.consts[ki], ifx u.consts[ki] != "" then u.consts[ki] else "(variable)");
			}
		}
	}
	// batching
	if !r_allowed(allow, "science:batching") {
		for pi: 1..len(pairs)-1 {
			a, b := pairs[pi - 1], pairs[pi];
			oa, ob, ua, ub := off[a[0]], off[b[0]], our[a[1]], our[b[1]];
			same_off := oa.batch == ob.batch;
			if same_off && ob.track - oa.track <= SCI_SAME_STEP_MS && ua.batch != ub.batch {
				fmt.sbprintfln(diffs, "  ~ science  %s and %s: one batch officially, two in ours", oa.type, ob.type);
			} else if !same_off && ob.track - oa.track > SCI_SEPARATE_MS && ua.batch == ub.batch {
				fmt.sbprintfln(diffs, "  ~ science  %s and %s: two batches officially, one in ours", oa.type, ob.type);
			}
		}
		max_delay: s64 = -1;
		for b: official { if len(b.events) > 0 { max_delay = max(max_delay, b.send - b.events[0].track); } }
		if max_delay >= 0 {
			for b: ours { if len(b.events) > 0 {
				d := b.send - b.events[0].track;
				if d < 0 || d > max_delay + 50 {
					fmt.sbprintfln(diffs, "  ~ science  flush %d ms after the first event (official at most %d ms)", d, max_delay);
				}
			} }
		}
	}
}

// last message by us in the channel (the fixture's own setup message)
r_last_own :: (c: *Client, channel: Snowflake) -> Snowflake {
	msgs := messages_get(*c.store, channel);
	for < i: 0..len(msgs) - 1 { if msgs[i].author_id == c.store.me { return msgs[i].id; } }
	return ifx len(msgs) > 0 then msgs[len(msgs) - 1].id else 0;
}

r_type :: (c: *Client, channel: Snowflake, text: string) {
	for _: text { typing_keystroke(c, channel); }
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
R_SCI_NEVER :: string.["science:dismissible_content_shown", "science:hotspot_hidden", "science:quest_hover", "science:experiment_", "science:premium_upsell_viewed", "science:impression_custom_themes", "science:voice_connection_", "science:audio_input_initialized", "science:media_session_joined", "science:start_speaking", "science:start_listening", "science:secure_frames_transition", "science:voice_codec_detected", "science:voice_disconnect", "science:leave_voice_channel", "science:video_layout_toggled"];

// the official picker flow: menu "Add Reaction" -> picker -> search -> pick
r_react_via_menu :: (run: *Replay_Run, msg: Snowflake, query: string, results: []int) {
	c := run.c;
	message_menu_opened(c, R_GUILD, R_TEXT, msg);
	replay_settle(run, 500);
	message_menu_item_clicked(c);
	message_menu_closed(c);
	open_emoji_picker(c, R_GUILD);
	expression_picker_opened(c, .Reaction, R_GUILD, R_TEXT, message_id = msg);
	replay_settle(run, 200);
	r_search(run, query, results);
}

r_search :: (run: *Replay_Run, query: string, results: []int) {
	picker_search_typed(run.c, sub(query, 0, 1));
	replay_settle(run, 200);
	for n, i: results {
		// results render for the query typed so far (the last one is the full query)
		q := ifx i == len(results) - 1 then query else sub(query, 0, min(len(query), i + 1));
		picker_search_results(run.c, q, n);
		replay_settle(run, 200);
	}
}
#scope_export

// ---- per-feature parity tests (the action window of each fixture) ----

parity_send_message :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "send_message", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	r_type(run.c, R_TEXT, "hello from the official client");
	replay_pump(*run, 1700); // the typing timer fires while the text is typed
	send_message(run.c, R_TEXT, "hello from the official client");
	replay_dispatches(*run, "send_message", "MESSAGE_CREATE");
	replay_settle(*run, 600);
	replay_check(*run, "send_message", string.["settings-proto/2"]); // frecency write (not modelled)
}

parity_add_reaction :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "add_reaction", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	msg := r_last_own(run.c, R_TEXT);
	r_react_via_menu(*run, msg, "thumbsup", int.[1]);
	picker_emoji_selected(run.c, "thumbsup");
	add_reaction(run.c, R_TEXT, msg, "👍", 0, false, "Message Reaction Picker");
	replay_settle(*run, 600);
	replay_check(*run, "add_reaction");
}

parity_remove_reaction :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "remove_reaction", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	remove_reaction(run.c, R_TEXT, r_last_own(run.c, R_TEXT), "👍", 0, false, "Message Inline Button");
	replay_settle(*run, 600);
	replay_check(*run, "remove_reaction");
}

parity_delete_message :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "delete_message", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	msg := r_last_own(run.c, R_TEXT);
	message_menu_opened(run.c, R_GUILD, R_TEXT, msg);
	replay_settle(*run, 500);
	message_menu_item_clicked(run.c);
	message_menu_closed(run.c);
	delete_message(run.c, R_TEXT, msg);
	replay_settle(*run, 600);
	replay_check(*run, "delete_message");
}

parity_edit_message :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "edit_message", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	msg := r_last_own(run.c, R_TEXT);
	message_menu_opened(run.c, R_GUILD, R_TEXT, msg);
	replay_settle(*run, 500);
	message_menu_item_clicked(run.c);
	message_menu_closed(run.c);
	replay_settle(*run, 200);
	edit_message(run.c, R_TEXT, msg, "this message was edited");
	replay_settle(*run, 600);
	replay_check(*run, "edit_message");
}

parity_reply :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "reply", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	target := r_last_own(run.c, R_TEXT);
	message_menu_opened(run.c, R_GUILD, R_TEXT, target);
	replay_settle(*run, 500);
	message_menu_item_clicked(run.c);
	message_menu_closed(run.c);
	r_type(run.c, R_TEXT, "this is a reply");
	replay_pump(*run, 1700);
	send_message(run.c, R_TEXT, "this is a reply", .{reply_to = target, reply_guild_id = R_GUILD, mention_replied = false});
	replay_settle(*run, 600);
	replay_check(*run, "reply");
}

parity_typing :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "typing", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	r_type(run.c, R_TEXT, "i am typing something");
	replay_pump(*run, 1700);
	replay_settle(*run, 300);
	// the official window also holds the 10 s re-send, which is not waited for offline
	replay_check(*run, "typing", string.["/typing"]);
}

parity_open_profile_popout :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "open_profile_popout", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	open_profile_popout(run.c, run.c.store.me, R_GUILD, R_TEXT, r_last_own(run.c, R_TEXT));
	replay_settle(*run, 800);
	replay_check(*run, "open_profile_popout");
}

parity_open_full_profile :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "open_full_profile", R_GUILD, R_TEXT) { return; }
	open_profile_popout(run.c, run.c.store.me, R_GUILD, R_TEXT, r_last_own(run.c, R_TEXT));
	replay_settle(*run, 600);
	replay_mark(*run);
	open_full_profile(run.c, run.c.store.me, R_GUILD);
	replay_settle(*run, 800);
	// not modelled: follow-ups driven by the profile's widget data (applications/public,
	// games, oauth2/tokens); the note is already loaded by the popout officially
	// science: fastcord's profile modal has no widgets section (no VIEW_WIDGETS_EMPTY_STATE)
	replay_check(*run, "open_full_profile", string.["applications/public", "/games?", "oauth2/tokens", "/notes/", "science:user_profile_action/profile_action=\"VIEW_WIDGETS_EMPTY_STATE\""]);
}

parity_emoji_picker_reaction :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "emoji_picker_reaction", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	msg := r_last_own(run.c, R_TEXT);
	open_emoji_picker(run.c, R_GUILD);
	expression_picker_opened(run.c, .Reaction, R_GUILD, R_TEXT, message_id = msg);
	replay_settle(*run, 200);
	r_search(*run, "fire", int.[107, 11]);
	picker_emoji_selected(run.c, "fire");
	add_reaction(run.c, R_TEXT, msg, "🔥", 0, false, "Message Inline Button");
	replay_settle(*run, 600);
	replay_check(*run, "emoji_picker_reaction");
}

parity_add_custom_reaction :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "add_custom_reaction", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	msg := r_last_own(run.c, R_TEXT);
	r_react_via_menu(*run, msg, "fastcord", int.[624, 300, 40, 1]);
	picker_emoji_selected(run.c, "fastcord_test", cast(Snowflake)(1564250154838528071), R_GUILD);
	add_reaction(run.c, R_TEXT, msg, "fastcord_test", cast(Snowflake)(1564250154838528071), false, "Message Reaction Picker");
	replay_settle(*run, 600);
	replay_check(*run, "add_custom_reaction");
}

parity_gif_send :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "gif_send", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	gifs_trending(run.c);
	expression_picker_opened(run.c, .Gif, R_GUILD, R_TEXT, width = 498);
	replay_settle(*run, 400);
	replay_check(*run, "open_gif_picker");
}

parity_status_change :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "status_change", 0, 0) { return; }
	replay_mark(*run);
	open_account_popout(run.c);
	replay_settle(*run, 600);
	replay_check(*run, "open_status_menu");
}

parity_set_idle :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "status_change", 0, 0) { return; }
	replay_mark(*run);
	set_status(run.c, .Idle);
	replay_settle(*run, 400);
	replay_check(*run, "set_idle");
}

parity_custom_status :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "custom_status", 0, 0) { return; }
	replay_mark(*run);
	set_custom_status(run.c, .{text = "testing fastcord", expires_at_ms = now_ms() + 24 * 3600 * 1000, clear_after = .Today});
	replay_settle(*run, 400);
	// fastcord's custom status modal shows no prompt suggestion: prompt_type is null
	replay_check(*run, "set_custom_status", string.["science:custom_status_updated.prompt_type"]);
}

parity_switch_theme :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "switch_theme", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	set_theme(run.c, .Light);
	replay_settle(*run, 400);
	replay_check(*run, "theme_light");
}

parity_join_voice :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "join_voice_channel", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	voice_join(run.c, R_GUILD, R_VOICE);
	replay_settle(*run, 900);
	// op 4 preferred_region(s) come from the live RTC probe; settings-proto/2: frecency write (not modelled)
	// science: the voice engine's events (permission prompt, RTC connection, codec,
	// speaking) need src/voice connected, which the offline replay does not run;
	// fastcord has no voice invite suggestions
	replay_check(*run, "join_voice", string.["op 4", "settings-proto/2", ".client_rtc_state", "science:permissions_requested", "science:impression_voice_invite_suggestions"]);
}

parity_close_dm :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "close_dm", 0, 0) { return; }
	replay_mark(*run);
	private_channel_menu_opened(run.c);
	replay_settle(*run, 300);
	close_private_channel(run.c, R_DM);
	replay_settle(*run, 500);
	replay_check(*run, "close_dm", string.["settings-proto/2"]);
}

parity_create_guild :: (t: *T) {
	run: Replay_Run;
	// the scrubbed fixture names the new guild like the test guild: start elsewhere
	if !replay_begin(*run, t, "create_guild", 0, 0) { return; }
	run.c.session_guild_set_done = true; // the official session had entered a guild before
	replay_mark(*run);
	create_guild(run.c, "Dingus Battle's serverfastcord test", step_shown_ms = now_ms() - 8000);
	replay_settle(*run, 1100); // GUILD_CREATE follows the POST's response
	replay_dispatches(*run, "create_guild_submit", "GUILD_CREATE");
	replay_settle(*run, 900);
	// op 8: the scrubbed fixture aliases the new guild's channel to the test channel,
	// whose authors are not members of the new guild here
	replay_check(*run, "create_guild_submit", string.["op 8"]);
}

parity_start_group_dm :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "start_group_dm", 0, 0) { return; }
	replay_mark(*run);
	group_dm_picker_opened(run.c, Gdm_Entry.{"New Group DM", "Friends List"}, 0, 2);
	replay_settle(*run, 300);
	create_group_dm(run.c);
	replay_settle(*run, 500);
	// the new DM is opened by the app; get-decisions is the ads timer, not this action
	replay_check(*run, "start_group_dm", string.["/messages?limit", "op 13", "get-decisions"]);
}

parity_upload_custom_emoji :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "upload_custom_emoji", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	// fastcord uploads from the emoji picker's "Add Emoji"; the capture is the
	// server settings upload (same request)
	upload_guild_emoji(run.c, R_GUILD, "src/imagefmt/testdata/t_trns_gray.png", "fastcord_test");
	replay_dispatches(*run, "upload_emoji", "GUILD_EMOJIS_UPDATE");
	replay_settle(*run, 600);
	// the upload's result, as the app takes it (the feature pool is shared by the parallel tests)
	for * r: feature_take(run.c) { feature_result_free(r); }
	// GET /emojis: the open settings page refreshing its list (fastcord has no such page)
	// science: the capture used server settings' Emoji Studio modal (open_modal,
	// impression, emoji_studio_ended); fastcord uploads from the picker without it
	replay_check(*run, "upload_emoji", string.["GET discord.com/api/v9/guilds/{id}/emojis", "science:open_modal", "science:impression_modal_root_legacy", "science:emoji_studio_ended"]);
}

// ---- telemetry of navigation and small UI events (science only: the request
// differences of these windows are session state, see traffic/PARITY.md) ----

parity_open_guild :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "open_guild_and_channel", 0, 0) { return; }
	replay_mark(*run);
	select_channel(run.c, R_GUILD, R_TEXT, 10, prefetch = true);
	replay_settle(*run, 600);
	replay_check(*run, "open_guild", science_only = true);
}

parity_open_unread_channel :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "mark_as_read", 0, 0) { return; }
	replay_dispatches(*run, "b_sends", "MESSAGE_CREATE"); // B's message makes the channel unread
	replay_settle(*run, 300);
	replay_mark(*run);
	select_channel(run.c, R_GUILD, R_TEXT, 10, prefetch = true);
	replay_settle(*run, 600);
	replay_check(*run, "open_unread_channel", science_only = true);
}

parity_open_dm :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "open_dm", 0, 0) { return; }
	replay_mark(*run);
	select_channel(run.c, 0, R_DM, 10, prefetch = true);
	replay_settle(*run, 1200);
	replay_check(*run, "open_dm", science_only = true);
}

parity_set_online :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "status_change", 0, 0) { return; }
	set_status(run.c, .Idle);
	replay_settle(*run, 300);
	replay_mark(*run);
	set_status(run.c, .Online);
	replay_settle(*run, 400);
	replay_check(*run, "set_online", science_only = true);
}

parity_close_popout_escape :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "open_profile_popout", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	analytics_keyboard_shortcut(run.c, "MARK_CHANNEL_READ", "esc"); // the app: Escape closes the popout
	replay_settle(*run, 300);
	replay_check(*run, "close_profile_popout", science_only = true);
}

parity_quick_switcher_open :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "quick_switcher_nav", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	analytics_keyboard_shortcut(run.c, "QUICKSWITCHER_SHOW", "mod+k");
	analytics_quickswitcher_opened(run.c, R_GUILD, R_TEXT);
	replay_settle(*run, 300);
	// the switcher's close / result events carry Discord's search scores (not sent);
	// opening a DM from it is select_channel (parity_open_dm), with the DM list's
	// view (dm_list_viewed) and the profile it shows
	replay_check(*run, "switch_to_dm", string.["science:quickswitcher_closed", "science:quickswitcher_result_selected", "science:dm_list_viewed", "science:channel_opened", "science:user_profile_action"], science_only = true);
}

parity_friends_add_tab :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "friend_request_send", 0, 0) { return; }
	replay_mark(*run);
	analytics_friends_list(run.c, "friends_list_clicked", .Add_Friend); // the app: the "Add Friend" tab
	replay_settle(*run, 300);
	replay_check(*run, "friend_request_send", science_only = true);
}

// ---- server notification settings (traffic/guild_*.jsonl, channel_notifications.jsonl) ----

parity_guild_menu :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "guild_menu", R_GUILD, R_TEXT) { return; }
	run.science = true;
	replay_mark(*run);
	track_guild_dropdown_viewed(run.c, R_GUILD);
	replay_settle(*run, 400);
	// status page polls: a background timer that fell in the window
	replay_check(*run, "open_guild_menu", string.["status.discord.com"]);
}

parity_guild_mark_read :: (t: *T) {
	run: Replay_Run;
	// A is on Friends while B posts
	if !replay_begin(*run, t, "guild_mark_read", 0, 0) { return; }
	run.science = true;
	replay_dispatches(*run, "b_sends", "MESSAGE_CREATE");
	// B's message id is scrubbed ("<new:2>") and unscrubs below the real ids: put the
	// read state behind it so the channel is unread, as it was officially
	{ rs, ok := map_find_ptr(*run.c.store.read_states, R_TEXT);
	if ok { rs.last_message_id = 1; } }
	replay_settle(*run, 300);
	replay_mark(*run);
	ack_guild(run.c, R_GUILD);
	replay_dispatches(*run, "guild_mark_read", "MESSAGE_ACK");
	replay_settle(*run, 500);
	// notification_action ACK: the official client had shown a desktop banner for
	// B's message (the app's notifier, not this action)
	replay_check(*run, "guild_mark_read", string.["science:notification_action"]);
}

parity_guild_mute :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "guild_mute", R_GUILD, R_TEXT) { return; }
	run.science = true;
	replay_mark(*run);
	set_guild_muted(run.c, R_GUILD, true, 900);
	replay_dispatches(*run, "guild_mute_15m", "USER_GUILD_SETTINGS_UPDATE");
	replay_settle(*run, 400);
	replay_check(*run, "guild_mute_15m");
}

parity_guild_unmute :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "guild_mute", R_GUILD, R_TEXT) { return; }
	run.science = true;
	// the 15 min mute as fastcord applied it (the recorded dispatch's end_time lies
	// in the capture's past: replayed now, the mute would have run out)
	set_guild_muted(run.c, R_GUILD, true, 900);
	replay_settle(*run, 300);
	replay_mark(*run);
	set_guild_muted(run.c, R_GUILD, false);
	replay_dispatches(*run, "guild_unmute", "USER_GUILD_SETTINGS_UPDATE");
	replay_settle(*run, 400);
	replay_check(*run, "guild_unmute");
}

parity_guild_notifications :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "guild_notifications", R_GUILD, R_TEXT) { return; }
	run.science = true;
	replay_mark(*run);
	set_guild_notify_level(run.c, R_GUILD, NOTIFY_MENTIONS);
	replay_dispatches(*run, "guild_notify_mentions", "USER_GUILD_SETTINGS_UPDATE");
	replay_settle(*run, 400);
	replay_check(*run, "guild_notify_mentions");
}

parity_guild_notifications_all :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "guild_notifications", R_GUILD, R_TEXT) { return; }
	run.science = true;
	set_guild_notify_level(run.c, R_GUILD, NOTIFY_MENTIONS);
	replay_dispatches(*run, "guild_notify_mentions", "USER_GUILD_SETTINGS_UPDATE");
	replay_settle(*run, 300);
	replay_mark(*run);
	// the window opens the header menu again, then picks All Messages in the modal
	track_guild_dropdown_viewed(run.c, R_GUILD);
	replay_settle(*run, 300); // the modal is open a while before the click
	set_guild_notify_level(run.c, R_GUILD, NOTIFY_ALL);
	replay_dispatches(*run, "guild_notify_all", "USER_GUILD_SETTINGS_UPDATE");
	replay_settle(*run, 400);
	replay_check(*run, "guild_notify_all");
}

parity_channel_notifications :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "channel_notifications", R_GUILD, R_TEXT) { return; }
	run.science = true;
	replay_mark(*run);
	set_channel_muted(run.c, R_GUILD, R_TEXT, true, 900);
	replay_dispatches(*run, "channel_mute_15m", "USER_GUILD_SETTINGS_UPDATE");
	replay_settle(*run, 400);
	replay_check(*run, "channel_mute_15m");
}

parity_channel_notifications_sequence :: (t: *T) {
	// unmute, Only @mentions, Use Category Default: each its own window, in order
	steps := string.["channel_unmute", "channel_notify_mentions", "channel_notify_default"];
	for step, i: steps {
		run: Replay_Run;
		if !replay_begin(*run, t, "channel_notifications", R_GUILD, R_TEXT) { return; }
		run.science = true;
		// the 15 min mute as fastcord applied it (the recorded dispatch's end_time
		// lies in the capture's past: replayed now, the mute would have run out)
		set_channel_muted(run.c, R_GUILD, R_TEXT, true, 900);
		for j: 0..i-1 {
			if steps[j] == {
			case "channel_unmute";
				set_channel_muted(run.c, R_GUILD, R_TEXT, false);
			case "channel_notify_mentions";
				set_channel_notify_level(run.c, R_GUILD, R_TEXT, NOTIFY_MENTIONS);
			}
			replay_dispatches(*run, steps[j], "USER_GUILD_SETTINGS_UPDATE");
		}
		replay_settle(*run, 300);
		replay_mark(*run);
		if step == {
		case "channel_unmute";
			set_channel_muted(run.c, R_GUILD, R_TEXT, false);
		case "channel_notify_mentions";
			set_channel_notify_level(run.c, R_GUILD, R_TEXT, NOTIFY_MENTIONS);
		case "channel_notify_default";
			set_channel_notify_level(run.c, R_GUILD, R_TEXT, NOTIFY_INHERIT);
		}
		replay_dispatches(*run, step, "USER_GUILD_SETTINGS_UPDATE");
		replay_settle(*run, 400);
		replay_check(*run, step);
	}
}

// ---- invites, joining and leaving servers (fixtures invite_people, join_leave_server) ----

parity_invite_people :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "invite_people", R_GUILD, R_TEXT) { return; }
	// the header menu opens in its own window, Invite People in the next
	replay_mark(*run);
	track_guild_dropdown_viewed(run.c, R_GUILD);
	replay_settle(*run, 300);
	replay_check(*run, "open_guild_menu", string.["status.discord.com"], keep = true);
	replay_mark(*run);
	open_invite_modal(run.c, R_GUILD, R_TEXT, INVITE_LOC_HEADER);
	replay_settle(*run, 500);
	replay_check(*run, "invite_from_menu");
}
#scope_file

// later opens: validate is the first open's code; the suggestions' memberships are known
r_invite_reopen :: (t: *T, window: string, location: string) {
	run: Replay_Run;
	if !replay_begin(*run, t, "invite_people", R_GUILD, R_TEXT) { return; }
	open_invite_modal(run.c, R_GUILD, R_TEXT, INVITE_LOC_HEADER);
	replay_settle(*run, 500);
	replay_dispatches(*run, "invite_from_menu", "GUILD_MEMBERS_CHUNK");
	replay_settle(*run, 200);
	if invite_code_for(run.c, R_TEXT) == "" { expect(t, false, "the first invite's code was not kept"); }
	replay_mark(*run);
	open_invite_modal(run.c, R_GUILD, R_TEXT, location);
	replay_settle(*run, 500);
	replay_check(*run, window);
}
#scope_export

parity_invite_people_header_icon :: (t: *T) {r_invite_reopen(t, "invite_from_header_icon", INVITE_LOC_HEADER_BUTTON);}

parity_invite_people_channel_icon :: (t: *T) {r_invite_reopen(t, "invite_from_channel_icon", INVITE_LOC_CHANNELS);}

parity_invite_people_copy_close :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "invite_people", R_GUILD, R_TEXT) { return; }
	open_invite_modal(run.c, R_GUILD, R_TEXT, INVITE_LOC_HEADER);
	replay_settle(*run, 500);
	// Copy, then Escape (its own window): science only
	replay_mark(*run);
	invite_copied(run.c, R_GUILD, R_TEXT, invite_code_for(run.c, R_TEXT), INVITE_LOC_HEADER);
	replay_settle(*run, 300);
	replay_check(*run, "copy_invite", keep = true);
	replay_mark(*run);
	escape_shortcut_used(run.c);
	replay_settle(*run, 300);
	replay_check(*run, "close_invite");
}
#scope_file

// B leaves the test guild: the DELETE, then (on GUILD_DELETE) Friends' first render.
r_leave :: (run: *Replay_Run) {
	leave_guild(run.c, R_GUILD);
	replay_settle(run, 300);
	replay_dispatches(run, "b_leave_confirm");
	client_poll(run.c);
	select_channel(run.c, 0, 0); // the app routes to Friends once the guild is gone
	friends_page_viewed(run.c);
	replay_settle(run, 600);
}
#scope_export

parity_leave_server :: (t: *T) {
	locks.lock(*r_guild_side_tables);
	defer locks.unlock(*r_guild_side_tables);
	run: Replay_Run;
	if !replay_begin(*run, t, "join_leave_server", R_GUILD, R_TEXT, "b") { return; }
	// the session's quests (applications/public on the home surface)
	q := job_new(.Api, .Startup);
	q.method = "GET";
	q.path = "/quests/@me";
	job_submit(run.c, q);
	replay_settle(*run, 300);
	replay_mark(*run);
	r_leave(*run);
	replay_check(*run, "b_leave_confirm");
}

parity_join_server :: (t: *T) {
	locks.lock(*r_guild_side_tables);
	defer locks.unlock(*r_guild_side_tables);
	run: Replay_Run;
	if !replay_begin(*run, t, "join_leave_server", R_GUILD, R_TEXT, "b") { return; }
	r_leave(*run);
	// Add a Server -> Join a Server -> typing the link: science only
	replay_mark(*run);
	guild_add_step(run.c, .Templates, 0);
	guild_add_step(run.c, .Join, now_ms());
	replay_settle(*run, 300);
	{
		locks.lock(*run.r.mu);
		n := len(run.r.ours) + len(run.r.sends);
		locks.unlock(*run.r.mu);
		expectf(t, n == 0, "opening Add a Server / Join a Server sent %d requests or gateway ops (official: science only)", n);
	}
	replay_mark(*run);
	// the app runs join_invite on a worker while the UI thread polls (science flushes)
	Join :: struct {
		c: *Client;
		ok: bool;
		done: bool;
	}
	jn := Join.{c = run.c};
	th := thread.create_and_start_with_poly_data(*jn, (j: *Join) {
		res := join_invite(j.c, "https://discord.gg/w5wYynKUN", temp);
		j.ok = res.ok;
		reset_temporary_storage();
		atomic_store(*j.done, true);
	});
	while !atomic_load(*jn.done) {
		client_poll(run.c);
		time.sleep(5 * time.Millisecond);
	}
	thread.join(th);
	thread.destroy(th);
	expect(t, jn.ok, "the invite was not accepted");
	replay_dispatches(*run, "b_join_submit");
	replay_settle(*run, 800);
	locks.lock(*run.c.route_mu);
	g, ch := run.c.route_guild, run.c.route_channel;
	locks.unlock(*run.c.route_mu);
	expectf(t, g == R_GUILD && ch == R_TEXT, "the joined guild opened at %v/%v", g, ch);
	replay_check(*run, "b_join_submit");
}
#scope_file

R_UPLOAD_CH :: cast(Snowflake)(1564405699197407414);
#scope_export // upload_options was recorded in a second text channel

// Staged attachments: each staged file uploads at once; spoiler / modify send nothing;
// the trash deletes the uploaded file once (no retry after the capture's 429); Send posts
// the message with is_spoiler / description / the renamed filename.
parity_upload_options :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "upload_options", R_GUILD, R_UPLOAD_CH) { return; }
	png, err := os.read_entire_file("tests/scenarios/assets/test.png", context.allocator);
	if !expect(t, err == null) { return; }
	defer delete(png);
	c := run.c;

	replay_mark(*run);
	h1 := upload_draft(c, R_UPLOAD_CH, "test.png", "image/png", png, "file_picker");
	// the upload PUT answers after its recorded latency: wait for it, then settle
	for i: 0..600-1 {
		client_poll(c);
		{ st, _, _, _ := upload_draft_status(c, h1);
		if st == .Done || st == .Failed { break; } }
		time.sleep(5 * time.Millisecond);
	}
	replay_settle(*run, 500);
	st, sent, _, _ := upload_draft_status(c, h1);
	expect_value(t, st, Draft_State.Done);
	// the fixture's READY puts this user in the WebP experiment (variation 1): the PNG
	// is uploaded as a smaller lossless WebP, as the official client did (6302 -> 758)
	expect_value(t, c.webp_variation, 1);
	expect(t, sent > 0 && sent < cast(s64)(len(png)));
	replay_check(*run, "stage_file", string.["settings-proto/2"], keep = true);

	replay_mark(*run);
	analytics_media_draft_edited(c, "spoilered", true);
	replay_settle(*run, 300);
	replay_check(*run, "spoiler_toggle", string.["settings-proto/2"], keep = true); // the frecency GET is periodic

	replay_mark(*run);
	analytics_media_draft_edited(c, "has_alt_text", true);
	replay_settle(*run, 300);
	replay_check(*run, "modify_save", keep = true);

	replay_mark(*run);
	h2 := upload_draft(c, R_UPLOAD_CH, "fastcord_test.png", "image/png", png, "file_picker");
	replay_settle(*run, 500);
	replay_check(*run, "stage_second_file", keep = true);

	replay_mark(*run);
	upload_draft_remove(c, h2);
	replay_settle(*run, 500);
	replay_check(*run, "remove_second_file", keep = true);

	replay_mark(*run);
	send_message(c, R_UPLOAD_CH, "", .{attachments = Draft_Attachment.[.{handle = h1, filename = "fc_renamed.png", description = "a small test image", spoiler = true}]});
	replay_dispatches(*run, "send_with_options", "MESSAGE_CREATE");
	replay_settle(*run, 600);
	replay_check(*run, "send_with_options", keep = true);

	replay_mark(*run);
	// the official paste was a PNG the WebP didn't shrink (insufficient_savings): so is this one
	small, serr := os.read_entire_file("src/imagefmt/testdata/t_trns_gray.png", context.allocator);
	expect(t, serr == null);
	defer delete(small);
	h3 := upload_draft(c, R_UPLOAD_CH, "image.png", "image/png", small, "clipboard");
	replay_settle(*run, 500);
	{
		d := drafts_of(c);
		locks.lock(*d.mu);
		u, _ := draft_find(d, h3);
		if u != null { expect_value(t, u.conv.failure, "insufficient_savings"); }
		if u != null { expect_value(t, u.size, cast(s64)(len(small))); }
		locks.unlock(*d.mu);
	}
	replay_check(*run, "paste_image", keep = true);

	replay_mark(*run);
	send_message(c, R_UPLOAD_CH, "", .{attachments = Draft_Attachment.[.{handle = h3, filename = "image.png"}]});
	replay_dispatches(*run, "send_pasted", "MESSAGE_CREATE");
	replay_settle(*run, 600);
	replay_check(*run, "send_pasted");
}

draft_attachments_body :: (t: *T) {
	atts := Draft_Attachment.[.{handle = 1, filename = "fc_renamed.png", description = "a small test image", spoiler = true}, .{handle = 2, filename = "image.png"}];
	got := attachments_json(atts, string.["u1/test.png", "u2/image.png"], string.["image/png", "image/png"]);
	expect_value(t, got, "[{\"id\":\"0\",\"description\":\"a small test image\",\"filename\":\"fc_renamed.png\",\"uploaded_filename\":\"u1/test.png\",\"is_spoiler\":true,\"original_content_type\":\"image/png\"},{\"id\":\"1\",\"filename\":\"image.png\",\"uploaded_filename\":\"u2/image.png\",\"original_content_type\":\"image/png\"}]");
}

// ---- inbox, threads browser, back/forward (traffic/FEATURES_NEW.md) ----

// B's two mentions of A (MESSAGE_CREATE of the b_mentions window); A is on Friends.
inbox_begin :: (run: *Replay_Run, t: *T) -> bool {
	if !replay_begin(run, t, "inbox", 0, 0) { return false; }
	replay_dispatches(run, "b_mentions", "MESSAGE_CREATE");
	replay_settle(run, 300);
	return true;
}
#scope_export

parity_inbox_open :: (t: *T) {
	run: Replay_Run;
	if !inbox_begin(*run, t) { return; }
	replay_mark(*run);
	// the popout reopens on the stored tab (READY: inbox.current_tab = MENTIONS)
	expect_value(t, run.c.store.settings.inbox_tab, Inbox_Tab.Mentions);
	open_mentions(run.c);
	track_open_popout(run.c, "Recent Mentions");
	replay_settle(*run, 500);
	replay_check(*run, "open_inbox");
}

parity_inbox_tabs :: (t: *T) {
	run: Replay_Run;
	if !inbox_begin(*run, t) { return; }
	replay_mark(*run);
	// Unreads: nothing but science; the tab is saved 10 s later (not in this window)
	set_inbox_tab(run.c, .Unreads);
	track_open_popout(run.c, "Inbox");
	replay_settle(*run, 400);
	replay_check(*run, "inbox_unreads_tab", keep = true);
	replay_mark(*run);
	set_inbox_tab(run.c, .Mentions);
	track_open_popout(run.c, "Recent Mentions");
	replay_settle(*run, 400);
	replay_check(*run, "inbox_mentions_tab");
}

parity_inbox_mark_read :: (t: *T) {
	run: Replay_Run;
	if !inbox_begin(*run, t) { return; }
	// the app showed B's two mentions as desktop notifications
	for e: replay_window(*run.r, "b_mentions") {
		if fstr(e, "k") != "ws_recv" || fstr(e, "ev") != "MESSAGE_CREATE" { continue; }
		d := fmap(e, "d");
		analytics_notification_shown(run.c, fsnow(d, "id"), fsnow(d, "channel_id"), fsnow(fmap(d, "author"), "id"), cast(int)(fint(d, "type")), true);
	}
	replay_mark(*run);
	last := get(run.c.store.channels, R_TEXT).last_message_id;
	ack_message(run.c, R_TEXT, last, true, ACK_INBOX);
	track_inbox_channel_acked(run.c, R_TEXT);
	replay_settle(*run, 300);
	replay_dispatches(*run, "inbox_unreads_mark_read", "MESSAGE_ACK");
	replay_settle(*run, 500);
	replay_check(*run, "inbox_unreads_mark_read");
}

parity_inbox_remove_mention :: (t: *T) {
	run: Replay_Run;
	if !inbox_begin(*run, t) { return; }
	// the tab switches of the two windows before: the 10 s save timer started at
	// the first one, ~8.5 s before this window's mark
	set_inbox_tab(run.c, .Unreads);
	set_inbox_tab(run.c, .Mentions);
	run.c.settings_edit.due = now_ms() + 1500;
	replay_mark(*run);
	delete_mention(run.c, get(run.c.store.channels, R_TEXT).last_message_id);
	replay_dispatches(*run, "inbox_remove_mention", "RECENT_MENTION_DELETE");
	replay_pump(*run, 1600);
	replay_settle(*run, 400);
	replay_check(*run, "inbox_remove_mention");
}

parity_inbox_jump :: (t: *T) {
	run: Replay_Run;
	// the channel was loaded at launch (start route), then A went to Friends
	if !replay_begin(*run, t, "inbox", R_GUILD, R_TEXT) { return; }
	select_channel(run.c, 0, 0);
	replay_settle(*run, 400);
	replay_dispatches(*run, "b_mentions", "MESSAGE_CREATE");
	replay_settle(*run, 300);
	replay_mark(*run);
	msg := messages_get(*run.c.store, R_TEXT);
	select_channel(run.c, R_GUILD, R_TEXT, 10);
	if len(msg) > 0 { track_jump(run.c, "Recent Mentions", R_TEXT, msg[len(msg) - 1].id); }
	replay_settle(*run, 500);
	replay_check(*run, "inbox_jump_to_mention");
}

// Threads browser on the recreated #general: every window in order.
parity_threads_browser :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "threads_browser", R_GUILD, R_TEXT2) { return; }
	defer replay_end(*run);
	c := run.c;
	replay_mark(*run);
	fetch_channel_threads(c, R_TEXT2, 0);
	track_thread_browser_open(c, R_TEXT2);
	replay_settle(*run, 400);
	replay_check(*run, "open_threads_popout_empty", keep = true);

	replay_mark(*run);
	track_thread_creation_started(c, R_TEXT2, "Thread Browser Toolbar");
	replay_settle(*run, 300);
	replay_check(*run, "create_thread_open", keep = true);

	replay_mark(*run);
	r_type(c, R_TEXT2, "fastcord test thread");
	replay_pump(*run, 1700);
	replay_settle(*run, 300);
	// the official window also holds the ~8 s re-send, which is not waited for offline
	replay_check(*run, "create_thread_name", string.["/typing"], keep = true);

	// Enter: POST /threads; the reply (the thread) opens it and the first message goes out
	replay_mark(*run);
	create_thread(c, R_TEXT2, "fastcord test thread", tag = 77);
	thread: Snowflake;
	{ i := 0;
	while i < 400 && thread == 0 {
		client_poll(c);
		for * r: feature_take(c) {
			if r.op == .Thread_Create && r.tag == 77 && r.ok { thread = apply_created_thread(c, r.body); }
			feature_result_free(r);
		}
		time.sleep(5 * time.Millisecond);
		i += 1;
} }
	expect(t, thread != 0, "no thread from POST /threads");
	replay_dispatches(*run, "create_thread_submit");
	select_channel(c, R_GUILD, thread, 30);
	send_message(c, thread, "first thread message", .{location = "thread_creation"});
	replay_settle(*run, 600);
	// science: the official client opens the new thread in its split view
	// (channel_opened with channel_view "Split View"); fastcord opens it as the main
	// view, whose channel_opened (selected_guild_id) is checked in parity_thread_open_main
	replay_check(*run, "create_thread_submit", string.["science:channel_opened"], keep = true);

	// the official side view closes (the parent stayed the route); fastcord left the
	// parent for the thread, so returning renders it again (integrations, see
	// guild_channel_notice_check). settings-proto/2: the periodic frecency load.
	replay_mark(*run);
	select_channel(c, R_GUILD, R_TEXT2, 10);
	replay_settle(*run, 400);
	replay_check(*run, "close_thread_view", string.["settings-proto/2", "/integrations"], keep = true);

	// second open: active threads come from the gateway, no new search
	replay_mark(*run);
	track_thread_browser_open(c, R_TEXT2);
	replay_settle(*run, 300);
	replay_check(*run, "open_threads_popout", keep = true);

	// science: fastcord's main-view channel_opened for the thread was sent on create
	// and is throttled for 15 min (the official one went to the split view's key)
	replay_mark(*run);
	select_channel(c, R_GUILD, thread, 10, source = "Thread Browser");
	replay_settle(*run, 400);
	replay_check(*run, "open_thread_from_popout", string.["science:channel_opened"], keep = true);

	// the official ack is the new thread's first-view ack (its read state did not
	// exist yet); fastcord acks only unread channels in a focused window
	replay_mark(*run);
	replay_settle(*run, 300);
	replay_check(*run, "delete_thread_menu", string.["/ack"], keep = true);

	replay_mark(*run);
	fetch_role_member_counts(c, R_GUILD);
	replay_settle(*run, 400);
	replay_check(*run, "delete_thread", keep = true);

	replay_mark(*run);
	delete_channel(c, thread);
	replay_dispatches(*run, "delete_thread_confirm", "THREAD_DELETE");
	select_channel(c, R_GUILD, R_TEXT2, 10);
	replay_settle(*run, 500);
	replay_check(*run, "delete_thread_confirm", keep = true);
}

// A thread opened from the threads popout as the main view: channel_opened with
// the thread properties, selected_guild_id and location (science only).
parity_thread_open_main :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "threads_browser", R_GUILD, R_TEXT2) { return; }
	c := run.c;
	replay_dispatches(*run, "create_thread_submit"); // the thread and its first message
	replay_settle(*run, 300);
	thread: Snowflake;
	for e: replay_window(*run.r, "create_thread_submit") {
		if fstr(e, "k") == "ws_recv" && fstr(e, "ev") == "THREAD_CREATE" { thread = fsnow(fmap(e, "d"), "id"); }
	}
	expect(t, thread != 0, "no THREAD_CREATE in create_thread_submit");
	replay_mark(*run);
	select_channel(c, R_GUILD, thread, 10, source = "Thread Browser");
	replay_settle(*run, 400);
	replay_check(*run, "open_thread_from_popout", science_only = true);
}

// Back / forward between #general and Friends: plain route changes.
parity_history_nav :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "history_nav", R_GUILD, R_TEXT2) { return; }
	defer replay_end(*run);
	c := run.c;
	select_channel(c, 0, 0); // open_friends (its first-open set is not this test's)
	replay_settle(*run, 500);
	steps := struct {
		window: string;
		forward: bool;
		keybind: bool;
	}.[.{"history_back_key", false, true}, .{"history_forward_key", true, true}, .{"history_back_button", false, false}, .{"history_forward_button", true, false}];
	for st: steps {
		replay_mark(*run);
		track_back_forward(c, st.forward, st.keybind);
		if st.forward { select_channel(c, 0, 0); } else { select_channel(c, R_GUILD, R_TEXT2, 10); }
		replay_settle(*run, 400);
		replay_check(*run, st.window, keep = true);
	}
}

// The compass: the official client shows server discovery in the app
// (/discovery/servers); fastcord opens https://discord.com/servers in the
// browser, so the client sends none of it and never leaves the channel.
parity_discover :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "discover", R_GUILD, R_TEXT2) { return; }
	defer replay_end(*run);
	replay_mark(*run);
	replay_settle(*run, 300);
	// science: the in-app discovery page's events (entry point, servers tab views);
	// fastcord's compass is a link to the web page, which is not that entry point
	replay_check(*run, "open_discover", string.["discoverable-guilds", "discovery/categories", "discovery-splashes", "/icons/", "science:global_discovery_"], keep = true);
	replay_mark(*run);
	replay_settle(*run, 300);
	// returning to the guild re-renders its channel officially (integrations)
	replay_check(*run, "leave_discover", string.["/integrations"], keep = true);
}
#scope_file

// ---- guild events and channel management (traffic/guild_events.jsonl, create_channel.jsonl) ----

// The scheduled-events side table is process-wide (one client in the app); tests that
// delete the test guild (leave/join) must not run while parity_guild_events does.
r_guild_side_tables: locks.Mutex;

R_TEXT_CATEGORY :: cast(Snowflake)(1564227670806364341);

// r_apply_features: what the app does with finished feature requests
// (guild_admin_apply sends the follow-ups), polled for ms.
r_apply_features :: (run: *Replay_Run, ms: int) {
	start := time.tick_now();
	while time.tick_since(start) < cast(time.Duration)(ms) * time.Millisecond {
		client_poll(run.c);
		for * r: feature_take_for(run.c) {
			guild_admin_apply(run.c, r);
			feature_result_free(r);
		}
		time.sleep(5 * time.Millisecond);
	}
}

// r_new_channel: the channel the fixture's create window made (the app opens it).
r_new_channel :: (run: *Replay_Run) -> Snowflake {
	for e: replay_window(*run.r, "create_channel_submit") {
		if fstr(e, "k") == "ws_recv" && fstr(e, "ev") == "CHANNEL_CREATE" { return fsnow(fmap(e, "d"), "id"); }
	}
	return 0;
}
#scope_export

parity_guild_events :: (t: *T) {
	locks.lock(*r_guild_side_tables);
	defer locks.unlock(*r_guild_side_tables);
	run: Replay_Run;
	if !replay_begin(*run, t, "guild_events", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	// Events modal, no events: science only. get-decisions is the ads timer, not this action.
	replay_mark(*run);
	open_guild_events(run.c, R_GUILD);
	r_apply_features(*run, 300);
	replay_compare(*run, "open_events_empty", string.["get-decisions"]);
	// Create Event: Location step (science only), then Event Info (nothing)
	replay_mark(*run);
	open_create_event(run.c, R_GUILD);
	r_apply_features(*run, 300);
	replay_compare(*run, "create_event_open");
	replay_mark(*run);
	r_apply_features(*run, 100);
	replay_compare(*run, "create_event_location");
	// Next on Event Info renders the Review step's preview: counts for event -1 (400)
	replay_mark(*run);
	event_preview_counts(run.c, R_GUILD);
	r_apply_features(*run, 300);
	replay_compare(*run, "create_event_info");
	// Create Event: POST, then the follow-ups and the share invite, the ack 3 s later
	replay_mark(*run);
	draft := Event_Draft.{name = "fastcord test event", start_ms = default_event_start_ms(now_ms(), 0), entity = .Voice, channel_id = R_VOICE};
	create_scheduled_event(run.c, R_GUILD, draft);
	r_apply_features(*run, 300);
	replay_dispatches(*run, "create_event_submit");
	// the ack is due EVENT_ACK_DELAY_MS after the POST's response (~0.9 s recorded latency)
	r_apply_features(*run, EVENT_ACK_DELAY_MS + 1000);
	replay_compare(*run, "create_event_submit");
	evs := guild_events(R_GUILD);
	expect_value(t, len(evs), 1);
	if len(evs) != 1 { return; }
	ev := evs[0].id;
	expect(t, evs[0].interested, "the creator is interested");
	expect_value(t, evs[0].user_count, 1);
	// Events modal with the event: science only (its count is known)
	replay_mark(*run);
	open_guild_events(run.c, R_GUILD);
	r_apply_features(*run, 300);
	replay_compare(*run, "open_events_one");
	// Interested toggles: DELETE, then PUT {"response":1}
	replay_mark(*run);
	set_event_interest(run.c, ev, false);
	r_apply_features(*run, 300);
	replay_dispatches(*run, "event_uninterested");
	r_apply_features(*run, 200);
	replay_compare(*run, "event_uninterested");
	expect_value(t, event_get(ev).user_count, 0);
	replay_mark(*run);
	set_event_interest(run.c, ev, true);
	r_apply_features(*run, 300);
	replay_dispatches(*run, "event_interested");
	r_apply_features(*run, 200);
	replay_compare(*run, "event_interested");
	expect_value(t, event_get(ev).user_count, 1);
	// the card's menu and Cancel Event (opens the confirm): nothing
	replay_mark(*run);
	r_apply_features(*run, 100);
	replay_compare(*run, "event_open_context_menu");
	replay_mark(*run);
	r_apply_features(*run, 100);
	replay_compare(*run, "event_cancel");
	// confirm: DELETE the event
	replay_mark(*run);
	cancel_scheduled_event(run.c, ev);
	r_apply_features(*run, 300);
	replay_dispatches(*run, "event_cancel_confirm");
	r_apply_features(*run, 200);
	replay_compare(*run, "event_cancel_confirm");
	expect_value(t, len(guild_events(R_GUILD)), 0);
}

parity_create_channel :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "create_channel", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	// opening the modal: GET profile (settings-proto/2 is an unrelated frecency write)
	replay_mark(*run);
	open_create_channel(run.c, R_GUILD);
	r_apply_features(*run, 300);
	replay_compare(*run, "open_create_channel", string.["settings-proto/2"]);
	// Create Channel: POST -> 201, templates; the app opens the new channel
	replay_mark(*run);
	create_channel(run.c, R_GUILD, .Guild_Text, "fc-temp", R_TEXT_CATEGORY);
	replay_dispatches(*run, "create_channel_submit"); // CHANNEL_CREATE comes before the response
	// the app opens the new channel when the POST's response is applied
	created := false;
	{ i := 0;
	while i < 400 && !created {
		client_poll(run.c);
		for * r: feature_take_for(run.c) {
			if r.op == .Channel_Create { created = true; }
			guild_admin_apply(run.c, r);
			feature_result_free(r);
		}
		time.sleep(5 * time.Millisecond);
		i += 1;
} }
	expect(t, created, "no response to the POST");
	nc := r_new_channel(*run);
	expect(t, channel_get(*run.c.store, nc) != null, "the new channel is in the Store");
	select_channel(run.c, R_GUILD, nc, 10);
	r_apply_features(*run, 400);
	replay_compare(*run, "create_channel_submit");
}

parity_channel_settings :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "create_channel", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	replay_dispatches(*run, "create_channel_submit"); // the channel from the create window
	r_apply_features(*run, 100);
	ch := channel_get(*run.c.store, r_new_channel(*run));
	expect(t, ch != null, "the new channel is in the Store");
	if ch == null { return; }
	nc := ch.id;
	// gear: GET regions
	replay_mark(*run);
	open_channel_settings(run.c, ch);
	r_apply_features(*run, 300);
	replay_compare(*run, "channel_settings_open");
	replay_mark(*run);
	r_apply_features(*run, 100);
	replay_compare(*run, "channel_topic_type");
	// Save Changes: PATCH with the whole Overview form, then templates
	replay_mark(*run);
	form := channel_form_of(ch);
	form.topic = "fastcord temporary channel";
	edit_channel(run.c, nc, form);
	r_apply_features(*run, 300);
	replay_dispatches(*run, "channel_settings_save");
	r_apply_features(*run, 200);
	replay_compare(*run, "channel_settings_save");
}

parity_channel_delete :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "create_channel", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	replay_dispatches(*run, "create_channel_submit");
	r_apply_features(*run, 100);
	nc := r_new_channel(*run);
	expect(t, channel_get(*run.c.store, nc) != null, "the new channel is in the Store");
	// Delete Channel (opens the confirm): GET roles/member-counts
	replay_mark(*run);
	open_delete_channel(run.c, R_GUILD);
	r_apply_features(*run, 300);
	replay_compare(*run, "channel_delete_open");
	// confirm: DELETE, then templates
	replay_mark(*run);
	delete_channel(run.c, nc);
	r_apply_features(*run, 300);
	replay_dispatches(*run, "channel_delete_confirm");
	r_apply_features(*run, 200);
	replay_compare(*run, "channel_delete_confirm");
	expect(t, channel_get(*run.c.store, nc) == null, "the channel is gone");
}

// ---- settings (fixture settings / streamer_mode: user settings modal) ----

parity_settings_open :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "settings", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run);
	settings_pane_shown(run.c, .None, .Account, R_GUILD, R_TEXT2);
	replay_pump(*run, 1500); // nothing more loads while the pane is open
	// science: the official settings modal's lazy-load spinner (impression variant
	// renderModalSpinner, absent from streamer_mode's identical open): its code-split
	// chunk loading, which fastcord has no counterpart for
	replay_check(*run, "open_settings", string.["science:impression_modal_root_legacy/variant=\"renderModalSpinner\""]);
}

parity_settings_open_profiles :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "settings", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run);
	open_profile_editor(run.c);
	replay_settle(*run, 600);
	// not modelled: follow-ups driven by the profile's widget data
	replay_check(*run, "open_profiles", string.["applications/public", "/games?", "oauth2/tokens"]);
}

parity_settings_profile_save :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "settings", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run);
	update_profile(run.c, "fc/test", "fastcord test bio");
	replay_settle(*run, 500);
	replay_check(*run, "profile_save");
}

parity_settings_display_name_save :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "settings", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run);
	update_global_name(run.c, "Dingus Test", .Profile_Name);
	replay_settle(*run, 500);
	replay_check(*run, "display_name_save");
}

parity_settings_notifications :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "settings", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run);
	settings_pane_shown(run.c, .Account, .Notifications, R_GUILD, R_TEXT2);
	replay_settle(*run, 500);
	replay_check(*run, "open_notifications_settings");
}

parity_settings_appearance :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "settings", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run);
	settings_pane_shown(run.c, .Notifications, .Appearance, R_GUILD, R_TEXT2);
	replay_settle(*run, 500);
	replay_check(*run, "open_appearance");
}

parity_settings_theme_sync :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "settings", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run);
	set_theme(run.c, .Dark, system = true); // "Sync with computer", OS dark
	replay_settle(*run, 400);
	replay_check(*run, "appearance_sync_on");
}

parity_settings_theme_dark :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "settings", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run);
	set_theme(run.c, .Darker); // UI "Dark"
	replay_settle(*run, 400);
	replay_check(*run, "appearance_sync_off");
}

parity_settings_friend_online_toggle :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "streamer_mode", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run);
	set_friend_online_notifications(run.c, false);
	replay_settle(*run, 400);
	replay_check(*run, "notifications_toggle_off");
	run2: Replay_Run;
	if !replay_begin(*run2, t, "streamer_mode", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run2);
	set_friend_online_notifications(run2.c, true);
	replay_settle(*run2, 400);
	replay_check(*run2, "notifications_toggle_on");
}

// Streamer Mode is local (science only); with it on, the Account pane shows an
// illustration and fetches nothing.
parity_streamer_mode :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "streamer_mode", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run);
	// the app: the switch, Streamer Mode on, and its notice bar on the guild route
	analytics_ui_setting(run.c, "streaming_enable_streamer_mode");
	analytics_streamer_mode_toggle(run.c, true, false);
	analytics_app_notice(run.c, "app_notice_viewed", "STREAMER_MODE", R_GUILD);
	replay_settle(*run, 300);
	replay_check(*run, "streamer_mode_on");
	run2: Replay_Run;
	if !replay_begin(*run2, t, "streamer_mode", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run2);
	settings_pane_shown(run2.c, .Appearance, .Account, R_GUILD, R_TEXT2, streamer_mode = true);
	replay_settle(*run2, 300);
	replay_check(*run2, "streamer_view_account");
	run3: Replay_Run;
	if !replay_begin(*run3, t, "streamer_mode", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run3);
	settings_pane_shown(run3.c, .Notifications, .Appearance, R_GUILD, R_TEXT2, streamer_mode = true);
	replay_settle(*run3, 300);
	replay_check(*run3, "open_settings_appearance");
}

// ---- friend nicknames, server nicknames, user menus (fixture friend_nickname) ----

parity_friend_nickname :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "friend_nickname", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run);
	open_user_context_menu(run.c, R_B, R_GUILD);
	replay_settle(*run, 500);
	replay_check(*run, "friend_nickname_open");
	run2: Replay_Run;
	if !replay_begin(*run2, t, "friend_nickname", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run2);
	set_friend_nickname(run2.c, R_B, "Bobby Nick");
	replay_settle(*run2, 400);
	replay_check(*run2, "friend_nickname_save");
	run3: Replay_Run;
	if !replay_begin(*run3, t, "friend_nickname", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run3);
	set_friend_nickname(run3.c, R_B, "");
	replay_settle(*run3, 400);
	replay_check(*run3, "friend_nickname_reset");
}

parity_server_nickname :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "friend_nickname", R_GUILD, R_TEXT2) { return; }
	open_user_context_menu(run.c, R_B, R_GUILD); // the first right-click (earlier window)
	replay_settle(*run, 400);
	replay_mark(*run);
	open_user_context_menu(run.c, R_B, R_GUILD);
	replay_settle(*run, 300); // the menu is open a moment before "Change Nickname"
	open_change_nickname(run.c);
	replay_settle(*run, 400);
	replay_check(*run, "server_nickname_open");
	run2: Replay_Run;
	if !replay_begin(*run2, t, "friend_nickname", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run2);
	set_server_nickname(run2.c, R_GUILD, R_B, "Server Bob");
	replay_settle(*run2, 400);
	replay_check(*run2, "server_nickname_save");
	run3: Replay_Run;
	if !replay_begin(*run3, t, "friend_nickname", R_GUILD, R_TEXT2) { return; }
	replay_mark(*run3);
	set_server_nickname(run3.c, R_GUILD, R_B, "");
	replay_settle(*run3, 400);
	replay_check(*run3, "server_nickname_remove_save");
}

// ---- friend request from the DM row's menu (fixture friend_add_context_menu) ----

parity_friend_add_context_menu :: (t: *T) {
	run: Replay_Run;
	// A's side has no READY (the recording started on an open session): A's READY
	// from friend_request_send, where A and B weren't friends either
	if !replay_begin(*run, t, "friend_add_context_menu", 0, 0, ready_from = "friend_request_send") { return; }
	replay_mark(*run);
	open_dm_row_menu(run.c, R_B);
	replay_settle(*run, 300);
	add_relationship(run.c, R_B, "ContextMenu");
	replay_settle(*run, 400);
	// the hover prefetch of the DM's messages, the session's settings-proto/2 load and the
	// home route's entitlements belong to the hover / route, not to the menu
	replay_check(*run, "friend_request_from_dm_menu", string.["/messages?limit", "settings-proto/2", "/entitlements?"]);
	run2: Replay_Run;
	if !replay_begin(*run2, t, "friend_add_context_menu", 0, 0, "b") { return; }
	replay_mark(*run2);
	// the app: B opens the Pending tab (click, then the tab's view), then accepts
	analytics_friends_list(run2.c, "friends_list_clicked", .Pending);
	analytics_friends_list(run2.c, "friends_list_viewed", .Pending);
	replay_settle(*run2, 300);
	accept_friend_request(run2.c, ifx run2.c.store.me == R_B then cast(Snowflake)(1546819257420087346) else R_B);
	replay_settle(*run2, 400);
	// GET relationships: the Pending tab's refresh (Friends page)
	replay_check(*run2, "friend_request_accept", string.["GET discord.com/api/v9/users/@me/relationships", "referrals/eligibility"]);
}

// ---- DM call (fixture dm_call) ----

parity_dm_call :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "dm_call", 0, R_DM) { return; }
	replay_pump(*run, 1500); // the DM's open-time profile loads
	replay_mark(*run);
	dm_call_start(run.c, R_DM);
	// the app reports its voice connection's state (src/voice is not run offline):
	// waiting for the endpoint, then connected
	client_set_rtc_state(run.c, .Awaiting_Endpoint);
	replay_settle(*run, 200);
	replay_dispatches(*run, "start_call");
	client_poll(run.c);
	analytics_permissions_requested(run.c, "audio"); // the app opens the microphone on VOICE_SERVER_UPDATE
	client_set_rtc_state(run.c, .Rtc_Connected);
	replay_settle(*run, 2400); // the two shelf loads answer ~1.2 s and ~1.9 s later
	// op 4 preferred_region(s): the live RTC probe; messages?before: history paging after the
	// call message; settings-proto/2: the session's lazy load
	replay_check(*run, "start_call", string.["op 4", "/messages?before", "settings-proto/2"]);
	run2: Replay_Run;
	if !replay_begin(*run2, t, "dm_call", 0, R_DM, "b") { return; }
	replay_dispatches(*run2, "start_call");
	replay_settle(*run2, 300);
	expect_value(t, incoming_call(run2.c), R_DM);
	replay_mark(*run2);
	call_accept(run2.c, R_DM);
	client_set_rtc_state(run2.c, .Awaiting_Endpoint);
	replay_dispatches(*run2, "b_join_from_ring");
	replay_settle(*run2, 200);
	analytics_permissions_requested(run2.c, "audio"); // the app opens the microphone
	client_set_rtc_state(run2.c, .Rtc_Connected);
	replay_settle(*run2, 1500);
	expect_value(t, incoming_call(run2.c), cast(Snowflake)(0));
	replay_check(*run2, "b_join_from_ring", string.["op 4", "settings-proto/2"]);
	run3: Replay_Run;
	if !replay_begin(*run3, t, "dm_call", 0, R_DM) { return; }
	replay_pump(*run3, 1500);
	client_set_rtc_state(run3.c, .Rtc_Connected); // A is in the call
	replay_mark(*run3);
	analytics_call_disconnect(run3.c, 0, R_DM); // the app: the voice panel's Disconnect
	voice_leave(run3.c);
	replay_settle(*run3, 300);
	replay_check(*run3, "a_hang_up");
}

// ---- log out / log in (traffic/account_edits.jsonl) ----
// The fixture has no READY before these windows; the login_submit window's
// READY (account A, the same account) stands in for the session's.

// Log Out from the account switcher's Manage Accounts list (the fixture's
// path; Settings > Log Out sends logout_source "settings" and no
// multi_account_account_remove): POST /auth/logout, then logged out:
// /experiments from the old route, the stale 401 refetches, the fingerprint,
// and the login page (location metadata, login_viewed; the QR socket is off).
parity_logout :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "account_edits", 0, 0) { return; }
	run.c.cfg.disable_remote_auth = true;
	identity_set_app_state(*run.c.id, .Focused); // the user clicked Log Out
	replay_mark(*run);
	client_logout(run.c, "multi_accounts_list");
	replay_settle(*run, 700);
	expect(t, client_logged_out(run.c));
	expect(t, auth_fingerprint(run.c) != "");
	replay_check(*run, "logout");
}

// Log In with email and password on the login page after that logout:
// POST /auth/login, then the gateway (IDENTIFY without fast connect), READY
// and the login burst (auth.odin LOGIN_BURST).
parity_login_submit :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "account_edits", 0, 0) { return; }
	c := run.c;
	c.cfg.disable_remote_auth = true;
	identity_set_app_state(*c.id, .Focused);
	client_logout(c, "multi_accounts_list");
	replay_settle(*run, 700);
	auth_take_events(c); // Logged_Out
	replay_mark(*run);
	// the fixture's values are scrubbed placeholders: the body shape is compared
	auth_login(c, "<email>", transmute([]u8, as_string("<token>")));
	{ i := 0;
	while i < 400 && client_logged_out(c) { replay_pump(*run, 5);  i += 1; } }
	expect(t, !client_logged_out(c));
	if c.gw == null { return; }
	evs := auth_take_events(c);
	expect(t, len(evs) == 1 && evs[0].kind == .Logged_In && evs[0].token == "<token>");
	// what the gateway does on its own when it connects (the sink never does)
	gateway_send(c.gw, .Identify, identify_value(c.gw));
	analytics_gateway_connected(c, 0, "wss://gateway.discord.gg", false, false, 160, 160);
	replay_dispatches(*run, "login_submit", "READY");
	replay_dispatches(*run, "login_submit", "READY_SUPPLEMENTAL");
	replay_pump(*run, 20);
	locks.lock(*c.gw.mu);
	gateway_on_ready_locked(c.gw);
	locks.unlock(*c.gw.mu);
	replay_pump(*run, 1500);
	identity_set_app_state(*c.id, .Unfocused); // the window lost focus before the +2 s part of the burst
	replay_pump(*run, 6700); // the burst ends with get-decisions at READY + 7.8 s
	replay_check(*run, "login_submit", string.[
		// the Friends activity feed (games the friends play) is not modelled
		"applications/public", "/games?",
		// not sent by fastcord (analytics_unknowable / not modelled)
		"science:client_heartbeat", "science:session_start_client", "science:ready_payload_received", "science:game_profile_entry_point_available"
	]);
}
#scope_file

// ---- username change (fixture account_edits: a passive recording on the home route) ----

// account_edits starts on an open session (its only READY follows the re-login):
// account A's READY from settings stands in.
r_account_begin :: (run: *Replay_Run, t: *T) -> bool {
	if !replay_begin(run, t, "account_edits", 0, 0, ready_from = "settings") { return false; }
	identity_set_app_state(*run.c.id, .Focused); // recorded by hand: the window had focus
	return true;
}
#scope_export

// Settings > My Account, then "Edit" on the username: the field opens with the
// current name, which is checked 800 ms later (next window).
parity_open_account_settings :: (t: *T) {
	run: Replay_Run;
	if !r_account_begin(*run, t) { return; }
	replay_mark(*run);
	settings_pane_shown(run.c, .None, .Account, 0, 0);
	replay_pump(*run, 1500); // nothing more loads while the pane is open
	analytics_ui_setting(run.c, "account_info_username_setting"); // the app: Edit
	username_input_changed(run.c, "dingusbattle");
	replay_settle(*run, 100);
	// science: the settings modal's lazy-load spinner (see parity_settings_open);
	replay_check(*run, "open_account_settings", string.["science:impression_modal_root_legacy/variant=\"renderModalSpinner\""]);
}

// Typing a new username: the prefilled (current, taken) name is checked, then
// the typed one 800 ms after the last keystroke; a checked name is not re-checked.
parity_username_typing :: (t: *T) {
	run: Replay_Run;
	if !r_account_begin(*run, t) { return; }
	analytics_ui_setting(run.c, "account_info_username_setting");
	username_input_changed(run.c, "dingusbattle");
	replay_pump(*run, 700);
	replay_mark(*run);
	replay_pump(*run, 700); // the debounce fires; {"taken":true} -> pomelo_errors
	expect_value(t, username_check(run.c, "dingusbattle").state, Username_Check_State.Taken);
	for name: (string.["dingusbattle2", "dingusbattle", "dingusbattle2"]) {
		username_input_changed(run.c, name); // keystrokes (and the cached name typed back)
		replay_pump(*run, 100);
	}
	replay_pump(*run, 1200);
	expect_value(t, username_check(run.c, "dingusbattle2").state, Username_Check_State.Available);
	replay_settle(*run, 300);
	// metrics/v2: the web client's performance metrics batch (wasm asset loads...);
	// client_ad_heartbeat: the 5-minute ad heartbeat timer, not this action
	replay_check(*run, "username_typing", string.["metrics/v2", "science:client_ad_heartbeat"]);
}

// Done: PATCH /users/@me {"username","password"}; then "Edit" again (science).
parity_username_submit :: (t: *T) {
	run: Replay_Run;
	if !r_account_begin(*run, t) { return; }
	replay_mark(*run);
	update_username(run.c, "dingusbattle2", "fastcord-test-password");
	replay_settle(*run, 1200);
	got_patch := false;
	{ i := 0;
	while i < 200 && !got_patch {
		client_poll(run.c);
		for * r: feature_take(run.c) {
			if r.op == .User_Patch { got_patch = r.ok; }
			feature_result_free(r);
		}
		time.sleep(5 * time.Millisecond);
		i += 1;
} }
	expect(t, got_patch, "the PATCH was not answered");
	analytics_ui_setting(run.c, "account_info_username_setting"); // the app: Edit again
	replay_settle(*run, 300);
	replay_check(*run, "username_submit");
}

// A name not checked before (one keystroke after the editor reopened): available.
parity_username_taken_check :: (t: *T) {
	run: Replay_Run;
	if !r_account_begin(*run, t) { return; }
	// the session's earlier checks (username_typing), whose answers come first
	for name: (string.["dingusbattle", "dingusbattle2"]) {
		username_input_changed(run.c, name);
		replay_pump(*run, 1300);
	}
	replay_mark(*run);
	username_input_changed(run.c, "dingusbattle3");
	replay_pump(*run, 1300);
	expect_value(t, username_check(run.c, "dingusbattle3").state, Username_Check_State.Available);
	replay_settle(*run, 300);
	// client_ad_heartbeat: the 5-minute ad heartbeat timer, not this action
	replay_check(*run, "username_taken_check", string.["science:client_ad_heartbeat"]);
}

username_rules :: (t: *T) {
	expect_value(t, username_rule_error("dingus_battle.2"), "");
	expect_value(t, username_rule_error("a"), "This must be 2-32 characters.");
	expect_value(t, username_rule_error("a..b"), "Username cannot contain repeating dots.");
	expect_value(t, username_rule_error("no spaces"), "Please only use numbers, letters, underscores _ , or periods.");
}

