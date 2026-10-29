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


R_GUILD :: cast(Snowflake) 1564227669971832975;
R_TEXT :: cast(Snowflake) 1564227670806364343;
R_VOICE :: cast(Snowflake) 1564227670806364345;
R_DM :: cast(Snowflake) 1564228964451356713;
R_B :: cast(Snowflake) 1564202918369042442;
// the test guild's text channel after it was recreated (fixtures threads_browser,
// history_nav, discover...: no system channel)
R_TEXT2 :: cast(Snowflake) 1564405699197407414;

// Requests the comparison leaves out: UI assets and images the app fetches
// itself, the RTC probe and Cloudflare's page challenge. Telemetry (/science)
// is compared on its own, per event (r_science_check).
R_IGNORE :: string.["/assets/", "collectibles-shop", "latency.discord.media", "/cdn-cgi/", "media.discordapp.net", "/app-icons/", "/emojis/", "/avatars/", "/stickers/", "images-ext"];

// A replay is shared by the test thread and the client's workers: everything below mu, and every
// allocation from pool (a Flat_Pool is single-threaded) happens with mu held or before the client starts.
Replay :: struct {
	mu: locks.Mutex;
	pool: Flat_Pool;
	events: [..]etf.Map; // fixture lines (acct a), placeholders turned into ids
	used: [..]bool;
	ours: [..]Replay_Req;
	sends: [..]Replay_Send;
	beats: [..]string; // QoS heartbeats since the mark: "<sends before it>:<reasons>"
	science: [..]Sci_Batch; // our /science POSTs since the mark
	marked: bool;
	fail: string; // requests whose URL contains it are answered fail_status (failure paths)
	fail_status: int;
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

// ---- fixture ----

// Scrubbed values ("<new:2>", "<user:3>", "<id:...>") become stable fake
// snowflakes so the client can parse and reuse them; URL keys normalize ids again.
// New objects ("<new:N>") sort after the fixture's real ids, in creation order.
r_unscrub :: (v: V) -> V {
	if v.kind == {
		case .String;
			x := v.s;
			if x.count > 3 && x[0] == #char "<" && x[x.count - 1] == #char ">" && contains(x, ":") {
				// "<new:N>": created during the capture, in N order, after every real id
				if begins_with(x, "<new:") {
					n, ok := parse_u64(slice(x, 5, x.count - 6));
					if ok return etf.vstring(sprint("%", 1_700_000_000_000_000_000 + (n << 22)));
				}
				return etf.vstring(sprint("%", 1_100_000_000_000_000_000 + cast(u64) fnv32a(x)));
			}
		case .List; for * v.list it.* = r_unscrub(it.*);
		case .Map;  for * v.map it.value = r_unscrub(it.value);
	}
	return v;
}

fnv32a :: (s: string) -> u32 {
	h: u32 = 0x811c9dc5;
	for cast([]u8) s { h ^= it; h *= 0x01000193; }
	return h;
}

replay_load :: (r: *Replay, scenario: string, acct := "a") -> bool {
	push_allocator(pool_allocator(*r.pool));
	// appended to from worker threads later (under mu): keep them in the pool too
	r.ours.allocator, r.sends.allocator, r.science.allocator, r.beats.allocator = context.allocator, context.allocator, context.allocator, context.allocator;
	text, ok := read_entire_file(tprint("traffic/%.jsonl", scenario)); // tests run from the repo root
	if !ok return false;
	for line: split(text, "\n") {
		v, err := etf.from_json(line);
		if err != .None continue;
		m := vmap(v);
		// account a's lines carry no "acct" (or "a"); marks belong to both
		a := fstr(m, "acct");
		if a == "" a = "a";
		if a != acct && fstr(m, "k") != "mark" continue;
		array_add(*r.events, vmap(r_unscrub(v)));
		array_add(*r.used, false);
	}
	return true;
}

// window: the fixture events between mark `name` and the next mark.
replay_window :: (r: *Replay, name: string) -> []etf.Map {
	start, end := -1, r.events.count;
	for r.events {
		if fstr(it, "k") != "mark" continue;
		if start >= 0 {
			end = it_index;
			break;
		}
		if fstr(it, "name") == name start = it_index + 1;
	}
	if start < 0 return .[];
	return array_view(r.events, start, end - start);
}

// URL key: host + path with ids folded to {id}, query names without values.
r_key :: (method: string, url: string) -> string {
	u := url;
	i := find_index_from_left(u, "://");
	if i >= 0 u = advance(u, i + 3);
	path, query := u, "";
	i = find_index_from_left(u, #char "?");
	if i >= 0 path, query = slice(u, 0, i), advance(u, i + 1);
	sb: String_Builder;
	sb.allocator = temp;
	print_to_builder(*sb, "% ", method);
	for seg: split(path, "/",, temp) {
		if it_index > 0 append(*sb, "/");
		digits := seg.count >= 15;
		for cast([]u8) seg if !is_digit(it) digits = false;
		append(*sb, ifx digits || begins_with(seg, "%3C") || begins_with(seg, "<") then "{id}" else seg);
	}
	if query {
		append(*sb, "?");
		for kv: split(query, "&",, temp) {
			if it_index > 0 append(*sb, "&");
			eq := find_index_from_left(kv, #char "=");
			append(*sb, ifx eq >= 0 then slice(kv, 0, eq) else kv);
		}
	}
	return builder_to_string(*sb,, temp);
}

r_ignored :: (url: string) -> bool { return r_allowed(R_IGNORE, url); }

r_allowed :: (allow: []string, s: string) -> bool {
	for allow if contains(s, it) return true;
	return false;
}

r_shape :: (v: V, sb: *String_Builder, depth := 0) {
	if v.kind == {
		case .Nil;  append(sb, "null");
		case .Bool; append(sb, "bool");
		case .Int; #through;
		case .Float; #through;
		case .Big;  append(sb, "num");
		case .String; #through;
		case .Atom; #through;
		case .Charlist; append(sb, "str"); // unscrubbed ids are numeric strings on both sides
		case .List;
			append(sb, "[");
			if v.list && depth < 12 r_shape(v.list[0], sb, depth + 1);
			append(sb, "]");
		case .Tuple; append(sb, "tuple");
		case .Map;
			append(sb, "{");
			for v.map {
				if it_index > 0 append(sb, ",");
				print_to_builder(sb, "%:", vstr(it.key)); // JSON keys are strings
				r_shape(it.value, sb, depth + 1);
			}
			append(sb, "}");
	}
}

shape_text :: (v: V) -> string {
	sb: String_Builder;
	sb.allocator = temp;
	r_shape(v, *sb);
	return builder_to_string(*sb,, temp);
}

// fixture body value -> the JSON the server sent (false when only a hash was kept)
r_body_value :: (v: V) -> V, bool {
	m := vmap(v);
	if m.count == 1 {
		k := vstr(m[0].key);
		if k == "$b64json" return m[0].value, true;
		if begins_with(k, "$") return .{}, false;
	}
	return v, v.kind != .Nil;
}

// ---- network stand-ins ----

replay_round_trip :: (data: *void, host: string, req: http.Request) -> http.Response, http.Error {
	resp, err, delay_ms := replay_exchange(cast(*Replay) data, host, req);
	// after the mark, answer after the recorded latency (capped): response-time
	// events (telemetry, follow-ups) then land as far apart as they did officially
	if delay_ms > 0 sleep_milliseconds(cast(s32) ceil(min(delay_ms, 1000)));
	return resp, err;
}

replay_exchange :: (r: *Replay, host: string, req: http.Request) -> http.Response, http.Error, float64 {
	delay_ms: float64;
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	url := join("https://", host, req.path,, temp);
	key := r_key(req.method, url);
	// the recorded exchange with the same URL shape, earliest first
	ri := -1;
	for r.events {
		if r.used[it_index] || fstr(it, "k") != "req" continue;
		if r_key(fstr(it, "method"), fstr(it, "url")) == key {
			ri = it_index;
			break;
		}
	}
	proto := "h3";
	if ri >= 0 {
		r.used[ri] = true;
		proto = fstr(r.events[ri], "proto");
	}
	if r.marked && !r_ignored(url) {
		// our wire order, as http (h2) / quic put it on the wire
		sb: String_Builder;
		sb.allocator = temp;
		append(*sb, ":method,:authority,:scheme,:path");
		has_priority := false;
		for req.headers {
			n := to_lower_copy(it.name,, temp);
			if n == "priority" has_priority = true;
			if n == "cookie" || n == "if-none-match" || n == "if-modified-since" continue;
			print_to_builder(*sb, ",%", n);
		}
		if proto == "h3" && !has_priority append(*sb, ",priority");
		wire := builder_to_string(*sb,, temp);
		body, perr := etf.from_json(cast(string) req.body,, temp);
		push_allocator(pool_allocator(*r.pool));
		if r_is_science(url) {
			if perr == .None {
				b := r_sci_parse(body);
				b.wire = copy_string(wire);
				array_add(*r.science, b);
			}
		} else {
			shape := ifx req.body && perr == .None then shape_text(body) else "";
			array_add(*r.ours, .{copy_string(key), copy_string(wire), copy_string(shape)});
		}
	}
	// the transport owns the response (response_destroy): give it the heap, not the replay's pool,
	// which the caller's thread would use without mu
	resp := http.make_response(ifx proto == "h3" then .Http3 else .Http2,, context.default_allocator);
	push_allocator(resp.allocator);
	resp.status = 200;
	body := "{}";
	if ri >= 0 {
		id := fnum(r.events[ri], "id");
		for e: r.events {
			if fstr(e, "k") != "resp" || fnum(e, "id") != id continue;
			if r.marked delay_ms = vf64(vget(e, "t")) - vf64(vget(r.events[ri], "t"));
			resp.status = fnum(e, "status");
			for h: flist(e, "headers") {
				l := vlist(h);
				if l.count != 2 continue;
				n := vstr(l[0]);
				if n == "content-encoding" || n == "content-length" continue; // the body below is decoded
				array_add(*resp.headers, .{copy_string(n), copy_string(vstr(l[1]))});
			}
			bv, ok := r_body_value(vget(e, "body"));
			body = ifx ok then etf_json(bv) else "";
			break;
		}
	}
	if r.fail && contains(url, r.fail) {
		resp.status = r.fail_status;
		body = "{}";
	}
	append_string(*resp.body, body);
	return resp, .None, delay_ms;
}

etf_json :: (v: V) -> string {
	sb: String_Builder;
	sb.allocator = temp;
	etf.to_json(v, *sb);
	return builder_to_string(*sb,, temp);
}

fnum :: (m: etf.Map, k: string) -> s64 {
	v := vget(m, k);
	return ifx v.kind == .Int || v.kind == .Float then vint(v) else 0;
}

replay_sink :: (data: *void, op: Op, d: V) {
	r := cast(*Replay) data;
	if op == .Heartbeat return;
	locks.lock(*r.mu);
	defer locks.unlock(*r.mu);
	if !r.marked return;
	if op == .Qos_Heartbeat {
		reasons: [..]string;
		reasons.allocator = temp;
		for vlist(vget(fmap(vmap(d), "qos"), "reasons")) array_add(*reasons, vstr(it));
		array_add(*r.beats, sprint("%:%", r.sends.count, join(..reasons, ","),, pool_allocator(*r.pool)));
		return;
	}
	array_add(*r.sends, .{xx op, copy_string(shape_text(d),, pool_allocator(*r.pool))});
}

// ---- driving ----

Replay_Run :: struct {
	r: Replay;
	c: *Client;
	t: *T;
	donor: Replay; // ready_from's fixture (its READY)
	science: bool; // also compare /science events (type + property names); allow "science <type>"
}

replay_begin :: (run: *Replay_Run, t: *T, scenario: string, guild: Snowflake, channel: Snowflake, acct := "a", ready_from := "") -> bool {
	run.t = t;
	if !replay_load(*run.r, scenario, acct) {
		expectf(t, false, "no fixture traffic/%.jsonl", scenario);
		return false;
	}
	ready_events: []etf.Map = run.r.events;
	if ready_from != "" {
		// the donor's pool lives as long as the run: its values are injected below
		if !replay_load(*run.donor, ready_from, acct) {
			expectf(t, false, "no fixture traffic/%.jsonl", ready_from);
			return false;
		}
		ready_events = run.donor.events;
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
	// the recorded instances had read these legacy experiments since their last login
	for string.["guild|2025-08_portkey_enabled|0|ChannelRenderer", "user|2023-09_iar_user_reporting|user profile overflow menu"] {
		table_set(*run.c.analytics.exposed, copy_string(it,, run.c.analytics.allocator), true);
	}
	identity_touch_heartbeat(*run.c.id, now_ms()); // the launch's heartbeat session (the window had focus)
	run.c.analytics.roundtrip_sample = 0; // send_message_roundtrip is sampled (10%): never offline
	identity_set_app_state(*run.c.id, .Unfocused);
	client_start(run.c);
	// session state from the fixture's READY
	for name: string.["READY", "READY_SUPPLEMENTAL"] {
		for e: ready_events {
			if fstr(e, "k") != "ws_recv" || fstr(e, "ev") != name continue;
			// what the gateway reader does with READY before dispatching it
			inst := fstr(fmap(fmap(e, "d"), "apex_experiments"), "installation");
			if inst != "" && name == "READY" run.c.id.installation_id = copy_string(inst,, run.c.allocator);
			client_inject_dispatch(run.c, name, vget(e, "d"));
			break;
		}
	}
	// READY's apex_experiments.installation is scrubbed from the fixtures
	if run.c.id.installation_id == "" run.c.id.installation_id = copy_string("1100000000000000001",, run.c.allocator);
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
	start := mono_ms();
	while mono_ms() - start < max_ms {
		client_poll(run.c);
		locks.lock(*run.c.analytics.mu);
		queued := run.c.analytics.queue.count;
		locks.unlock(*run.c.analytics.mu);
		locks.lock(*run.c.job_mu);
		jobs := run.c.jobs_running;
		for run.c.jobs if it.not_before <= now_ms() jobs += 1; // timers due later belong to the session
		locks.unlock(*run.c.job_mu);
		if queued == 0 && jobs == 0 return;
		sleep_milliseconds(5);
	}
}

// replay_settle: poll until nothing new was sent for quiet_ms (bounded).
replay_settle :: (run: *Replay_Run, quiet_ms: int, max_ms := 4000) {
	start := mono_ms();
	last := start;
	n := -1;
	while mono_ms() - start < max_ms {
		client_poll(run.c);
		locks.lock(*run.r.mu);
		k := run.r.ours.count + run.r.sends.count + cast(int) run.r.marked;
		locks.unlock(*run.r.mu);
		if k != n {
			n = k;
			last = mono_ms();
		}
		if mono_ms() - last >= quiet_ms return;
		sleep_milliseconds(5);
	}
}

// replay_pump: poll for a fixed time (library timers: typing 1.5 s...).
replay_pump :: (run: *Replay_Run, ms: int) {
	start := mono_ms();
	while mono_ms() - start < ms {
		client_poll(run.c);
		sleep_milliseconds(5);
	}
}

// replay_mark: start comparing from here (the official window `name`).
replay_mark :: (run: *Replay_Run) {
	locks.lock(*run.r.mu);
	run.r.marked = true;
	run.r.ours.count, run.r.sends.count, run.r.science.count, run.r.beats.count = 0, 0, 0, 0;
	locks.unlock(*run.r.mu);
}

// replay_dispatches feeds the window's recorded dispatches (MESSAGE_CREATE...).
replay_dispatches :: (run: *Replay_Run, window: string, only := "") {
	for e: replay_window(*run.r, window) {
		if fstr(e, "k") != "ws_recv" || fnum(e, "op") != 0 continue;
		ev := fstr(e, "ev");
		if only != "" && ev != only continue;
		client_inject_dispatch(run.c, ev, vget(e, "d"));
	}
}

// replay_end frees a run whose windows were checked with keep = true.
replay_end :: (run: *Replay_Run) {
	client_destroy(run.c);
	fini(*run.r.pool);
	fini(*run.donor.pool);
}

// replay_compare: one window of a multi-window run (the client is kept).
replay_compare :: (run: *Replay_Run, window: string, allow: []string = .[]) {
	replay_check(run, window, allow, keep = true);
}

// replay_check compares our traffic since the mark with the official window.
// allow: keys / "op N" that may differ (known, documented gaps).
// keep: the run goes on to the next window (finish with replay_end).
// science_only: compare only /science (windows whose request differences are
// session state documented in traffic/PARITY.md, not this test's subject).
replay_check :: (run: *Replay_Run, window: string, extra_allow: []string = .[], keep := false, science_only := false) {
	t := run.t;
	defer if !keep replay_end(run);
	push_allocator(temp);
	all: [..]string;
	array_add(*all, ..R_SCI_NEVER);
	array_add(*all, ..extra_allow);
	allow: []string = all;
	official: [..]etf.Map;
	official_sci: [..]Sci_Batch;
	ops: [..]etf.Map;
	for e: replay_window(*run.r, window) {
		if fstr(e, "k") == {
			case "req";
				url := fstr(e, "url");
				if r_is_science(url) {
					bv, ok := r_body_value(vget(e, "body"));
					if ok {
						b := r_sci_parse(bv);
						b.wire = r_official_wire(e);
						array_add(*official_sci, b);
					}
				} else if !r_ignored(url) {
					array_add(*official, e);
				}
			case "ws_send";
				op := fnum(e, "op");
				if op != 1 && op != 40 array_add(*ops, e);
		}
	}
	locks.lock(*run.r.mu);
	ours := array_copy(run.r.ours);
	sends := array_copy(run.r.sends);
	ours_sci := array_copy(run.r.science);
	locks.unlock(*run.r.mu);
	if science_only {
		official.count, ops.count = 0, 0;
		ours, sends = .[], .[];
	}
	taken := NewArray(ours.count, bool);
	diffs: String_Builder;
	for e: official {
		key := r_key(fstr(e, "method"), fstr(e, "url"));
		j := -1;
		for ours if !taken[it_index] && it.key == key { j = it_index; break; }
		if j < 0 {
			if !r_allowed(allow, key) print_to_builder(*diffs, "  - missing  %\n", key);
			continue;
		}
		taken[j] = true;
		// wire order (netlog), cache validators and cookies left out on both sides
		w := r_official_wire(e);
		if w != "" && w != ours[j].wire && !r_allowed(allow, key) {
			print_to_builder(*diffs, "  ~ wire     %\n      official: %\n      ours:     %\n", key, w, ours[j].wire);
		}
		bv, ok := r_body_value(vget(e, "body"));
		if ok && ours[j].shape != "" {
			s := shape_text(bv);
			if s != ours[j].shape && !r_allowed(allow, key) {
				print_to_builder(*diffs, "  ~ body     %\n      official: %\n      ours:     %\n", key, s, ours[j].shape);
			}
		}
	}
	for ours if !taken[it_index] && !r_allowed(allow, it.key) print_to_builder(*diffs, "  + extra    %\n", it.key);
	// gateway: same ops in the same order, same payload shapes (allowed ops left out)
	op_allowed :: (allow: []string, op: s64) -> bool { return r_allowed(allow, tprint("op %", op)); }
	official_ops: [..]etf.Map;
	for ops if !op_allowed(allow, fnum(it, "op")) array_add(*official_ops, it);
	our_ops: [..]Replay_Send;
	for sends if !op_allowed(allow, it.op) array_add(*our_ops, it);
	for i: 0..max(official_ops.count, our_ops.count) - 1 {
		if i >= official_ops.count {
			print_to_builder(*diffs, "  + extra    gateway op %\n", our_ops[i].op);
			continue;
		}
		op := fnum(official_ops[i], "op");
		if i >= our_ops.count {
			print_to_builder(*diffs, "  - missing  gateway op %\n", op);
			continue;
		}
		if our_ops[i].op != op {
			print_to_builder(*diffs, "  ~ gateway #%: op % vs %\n", i + 1, op, our_ops[i].op);
		} else {
			s := shape_text(vget(official_ops[i], "d"));
			if s != our_ops[i].shape print_to_builder(*diffs, "  ~ gateway op % payload\n      official: %\n      ours:     %\n", op, s, our_ops[i].shape);
		}
	}
	r_science_check(official_sci, ours_sci, allow, *diffs);
	text := builder_to_string(*diffs);
	if text expectf(t, false, "window \"%\" differs from the official client:\n%", window, text);
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

SCI_SAME_STEP_MS :: 3;
// officially separate batches closer than this are flush timing, not steps
SCI_SEPARATE_MS :: 100;

r_is_science :: (url: string) -> bool { return contains(url, "/api/v9/science"); }

// r_official_wire: the netlog header order of a fixture request (cookies and
// cache validators left out), "" without a netlog.
r_official_wire :: (e: etf.Map) -> string {
	wl := vget(e, "wire");
	if wl.kind != .List || fstr(e, "wire_src") != "netlog" return "";
	names: [..]string;
	names.allocator = temp;
	for wl.list {
		n := to_lower_copy(vstr(vlist(it)[0]),, temp);
		if n != "cookie" && n != "if-none-match" && n != "if-modified-since" array_add(*names, n);
	}
	return join(..names, separator = ",",, temp);
}

// Keys whose numeric values are enums (compared by value).
SCI_NUM_ENUMS :: string.["channel_type", "parent_channel_type", "current_channel_type", "relationship_type", "content_id", "status_code", "channel_resolved_unread_setting", "guild_resolved_unread_setting", "version"];

// r_sci_const: the value of a constant-valued property, "" when it varies by nature.
r_sci_const :: (key: string, v: V) -> string {
	if v.kind == {
		case .Nil;  return "null";
		case .Bool; return ifx v.b then "true" else "false";
		case .Int;  for SCI_NUM_ENUMS if it == key return tprint("%", v.i);
		case .String;
			x := v.s;
			if !x return "\"\"";
			digits := true;
			for cast([]u8) x if !is_digit(it) digits = false;
			if digits return ""; // ids
			if x.count >= 20 && !contains(x, " ") && contains_any_character(x, "0123456789") return ""; // uuids, base64, hex load ids
			if x.count >= 19 && x[4] == #char "-" && contains(x, "T") return ""; // ISO times
			if key == {
				case "query"; #through;
				case "emoji_name"; #through;
				case "launch_signature"; #through;
				case "client_heartbeat_session_id"; #through;
				case "client_uuid"; #through;
				case "load_id"; return "";
			}
			q: [..]u8;
			q.allocator = temp;
			json_write_escaped(*q, x); // quoted as the allow entries write them
			return cast(string) q;
	}
	return "";
}

// r_sci_parse: one /science body, into context.allocator.
r_sci_parse :: (body: V) -> Sci_Batch {
	b: Sci_Batch;
	evs: [..]Sci_Event;
	for ev: flist(vmap(body), "events") {
		m := vmap(ev);
		props := fmap(m, "properties");
		e := Sci_Event.{type = copy_string(fstr(m, "type"))};
		keys, kinds, consts := NewArray(props.count, string), NewArray(props.count, string), NewArray(props.count, string);
		for p: props {
			k := vstr(p.key);
			if k == "client_track_timestamp" e.track = vint(p.value);
			if k == "client_send_timestamp" b.send = vint(p.value);
			keys[it_index] = copy_string(k);
			kinds[it_index] = copy_string(shape_text(p.value));
			consts[it_index] = copy_string(r_sci_const(k, p.value));
		}
		e.keys, e.kinds, e.consts = keys, kinds, consts;
		array_add(*evs, e);
	}
	b.events = evs;
	return b;
}

// r_sci_filtered: an allow entry `science:<type>/<key>=<const>` drops the events
// of that type whose property has that constant value (e.g. one profile_action).
r_sci_filtered :: (allow: []string, e: Sci_Event) -> bool {
	PREFIX :: "science:";
	for a: allow {
		if !begins_with(a, PREFIX) continue;
		slash := find_index_from_left(a, #char "/");
		eq := find_index_from_left(a, #char "=");
		if slash < 0 || eq < slash || slice(a, PREFIX.count, slash - PREFIX.count) != e.type continue;
		k, v := slice(a, slash + 1, eq - slash - 1), advance(a, eq + 1);
		for e.keys if it == k && e.consts[it_index] == v return true;
	}
	return false;
}

r_sci_flatten :: (batches: []Sci_Batch, allow: []string) -> []Sci_Event {
	out: [..]Sci_Event;
	out.allocator = temp;
	for b, bi: batches {
		for b.events {
			if r_allowed(allow, tprint("science:%", it.type)) || r_sci_filtered(allow, it) continue;
			x := it;
			x.batch = bi;
			array_add(*out, x);
		}
	}
	return out;
}

// r_sci_key_diff: missing / extra keys, else the first out-of-order key.
r_sci_key_diff :: (diffs: *String_Builder, o: Sci_Event, u: Sci_Event) {
	missing, extra: [..]string;
	missing.allocator, extra.allocator = temp, temp;
	for o.keys if !array_find(u.keys, it) array_add(*missing, it);
	for u.keys if !array_find(o.keys, it) array_add(*extra, it);
	if missing || extra {
		print_to_builder(diffs, "  ~ science  % keys: missing [%] extra [%]\n", o.type, join(..missing, separator = ",",, temp), join(..extra, separator = ",",, temp));
		return;
	}
	for o.keys if u.keys[it_index] != it {
		print_to_builder(diffs, "  ~ science  % key order: official % at #%, ours %\n", o.type, it, it_index, u.keys[it_index]);
		return;
	}
}

// r_science_check compares our /science batches with the official window's.
r_science_check :: (official: []Sci_Batch, ours: []Sci_Batch, allow: []string, diffs: *String_Builder) {
	// header order: every batch of ours against the official window's (no
	// x-science-test after the first batch of a launch)
	if official && official[0].wire != "" {
		for ours if it.wire != official[0].wire {
			print_to_builder(diffs, "  ~ wire     POST /science\n      official: %\n      ours:     %\n", official[0].wire, it.wire);
			break;
		}
	}
	off := r_sci_flatten(official, allow);
	our := r_sci_flatten(ours, allow);
	// FASTCORD_SCI_DEBUG=1: print both event sequences (batch, type, constants)
	if getenv("FASTCORD_SCI_DEBUG") {
		for off print("official  #% % %\n", it.batch, it.type, it.consts, to_standard_error = true);
		for our print("ours      #% % %\n", it.batch, it.type, it.consts, to_standard_error = true);
		for ours print("ours wire %\n", it.wire, to_standard_error = true);
		for official print("official wire %\n", it.wire, to_standard_error = true);
	}
	// longest common subsequence of the event types
	n, m := off.count, our.count;
	lcs := NewArray((n + 1) * (m + 1), int,, temp);
	for < i: 0..n - 1 {
		for < j: 0..m - 1 {
			lcs[i * (m + 1) + j] = ifx off[i].type == our[j].type then lcs[(i + 1) * (m + 1) + j + 1] + 1 else max(lcs[(i + 1) * (m + 1) + j], lcs[i * (m + 1) + j + 1]);
		}
	}
	pairs: [..][2]int;
	pairs.allocator = temp;
	i, j := 0, 0;
	while i < n || j < m {
		if i < n && j < m && off[i].type == our[j].type {
			array_add(*pairs, .[i, j]);
			i += 1;
			j += 1;
		} else if j < m && (i >= n || lcs[i * (m + 1) + j + 1] >= lcs[(i + 1) * (m + 1) + j]) {
			print_to_builder(diffs, "  + extra    science %\n", our[j].type);
			j += 1;
		} else {
			print_to_builder(diffs, "  - missing  science %\n", off[i].type);
			i += 1;
		}
	}
	// same-type events of one step (responses racing each other) may come in
	// either order: pair them by their constant values
	same_consts :: (a: Sci_Event, b: Sci_Event) -> bool {
		if a.consts.count != b.consts.count return false;
		for a.consts if it != b.consts[it_index] return false;
		return true;
	}
	for * p, pi: pairs {
		if same_consts(off[p.*[0]], our[p.*[1]]) continue;
		for pj: pi + 1..pairs.count - 1 {
			q := *pairs[pj];
			if off[q.*[0]].type != off[p.*[0]].type break;
			if same_consts(off[p.*[0]], our[q.*[1]]) && same_consts(off[q.*[0]], our[p.*[1]]) {
				tmp := p.*[1];
				p.*[1] = q.*[1];
				q.*[1] = tmp;
				break;
			}
		}
	}
	for p: pairs {
		o, u := off[p[0]], our[p[1]];
		ok_keys := o.keys.count == u.keys.count;
		if ok_keys for o.keys if it != u.keys[it_index] ok_keys = false;
		if !ok_keys {
			r_sci_key_diff(diffs, o, u);
			continue;
		}
		for k, ki: o.keys {
			if r_allowed(allow, tprint("science:%.%", o.type, k)) continue;
			if o.kinds[ki] != u.kinds[ki] {
				print_to_builder(diffs, "  ~ science  %.% type: official %, ours %\n", o.type, k, o.kinds[ki], u.kinds[ki]);
			} else if o.consts[ki] != "" && o.consts[ki] != u.consts[ki] {
				print_to_builder(diffs, "  ~ science  %.%: official %, ours %\n", o.type, k, o.consts[ki], ifx u.consts[ki] != "" then u.consts[ki] else "(variable)");
			}
		}
	}
	if r_allowed(allow, "science:batching") return;
	for pi: 1..pairs.count - 1 {
		a, b := pairs[pi - 1], pairs[pi];
		oa, ob, ua, ub := off[a[0]], off[b[0]], our[a[1]], our[b[1]];
		same_off := oa.batch == ob.batch;
		if same_off && ob.track - oa.track <= SCI_SAME_STEP_MS && ua.batch != ub.batch {
			print_to_builder(diffs, "  ~ science  % and %: one batch officially, two in ours\n", oa.type, ob.type);
		} else if !same_off && ob.track - oa.track > SCI_SEPARATE_MS && ua.batch == ub.batch {
			print_to_builder(diffs, "  ~ science  % and %: two batches officially, one in ours\n", oa.type, ob.type);
		}
	}
	max_delay: s64 = -1;
	for official if it.events max_delay = max(max_delay, it.send - it.events[0].track);
	if max_delay < 0 return;
	for ours if it.events {
		d := it.send - it.events[0].track;
		if d < 0 || d > max_delay + 50 print_to_builder(diffs, "  ~ science  flush % ms after the first event (official at most % ms)\n", d, max_delay);
	}
}

// last message by us in the channel (the fixture's own setup message)
r_last_own :: (c: *Client, channel: Snowflake) -> Snowflake {
	msgs := messages_get(*c.store, channel);
	for < msgs if it.author_id == c.store.me return it.id;
	return ifx msgs then msgs[msgs.count - 1].id else 0;
}

r_type :: (c: *Client, channel: Snowflake, text: string) {
	for 1..text.count typing_keystroke(c, channel);
}

// Telemetry fastcord never sends (traffic/PARITY.md "Telemetry", analytics_never):
// every window allows these (replay_check). No ads (AGENTS.md):
//   dismissible content of the Shop, Nitro and Orbs (by type), premium_upsell_viewed,
//   impression_custom_themes_* (Nitro themes), quest_hover / quest_hover_off (the quests
//   entry point; the hovers are the capture driver's mouse path anyway),
//   exposures of ad / Nitro-marketing / Orbs / quests experiments (by location).
R_SCI_NEVER :: string.[
	"science:quest_hover", "science:premium_upsell_viewed", "science:impression_custom_themes",
	"science:dismissible_content_shown/type=\"COLLECTIBLES_SHOP_ENTRY_MARKETING\"",
	"science:dismissible_content_shown/type=\"CUSTOM_CALL_SOUNDS_PICKER_UPSELL\"",
	"science:dismissible_content_shown/type=\"WISHLIST_NUX_TOOLTIP_AND_MODAL\"",
	"science:dismissible_content_shown/type=\"USER_PROFILE_PREMIUM_AND_SHOP_ENTRY_POINTS\"",
	"science:premium_feature_try_out",
	"science:dismissible_content_shown/type=\"DISPLAY_NAME_STYLES_FLYWHEEL_EDIT_PROFILE_NEW_BADGE\"",
	"science:dismissible_content_shown_before_connection_open/content_type=\"PREMIUM_ORBS_UPSELL_POPOVER\"",
	"science:dismissible_content_shown_before_connection_open/content_type=\"WISHLIST_SHOP_BUTTON_POPOVER\"",
	"science:experiment_user_evaluation_exposed/exposure_location=\"NitroTabButton\"",
	"science:experiment_user_evaluation_exposed/exposure_location=\"useNoFillAd\"",
	"science:experiment_user_evaluation_exposed/exposure_location=\"Account\"",
	"science:experiment_user_evaluation_exposed/exposure_location=\"GlobalDiscoverySidebar\"",
	"science:experiment_user_evaluation_exposed/experiment=\"2026-07-orbchievements\""
];

// The FrecencyUserSettingsManager's startup run (READY + 10 ms-10 s, one random draw per
// session) fell in the window after the session's lazy load: r_frecency_load before the mark,
// r_frecency_run in the window. It writes the channel selects pending since the setup.
r_frecency_load :: (run: *Replay_Run) {
	frecency_load(run.c);
	for 1..400 {
		client_poll(run.c);
		if run.c.store.frecency.loaded break;
		sleep_milliseconds(5);
	}
	run.c.store.frecency.timer_at = 0;
}

r_frecency_run :: (run: *Replay_Run) {
	f := *run.c.store.frecency;
	f.timer_at, f.timer_startup = now_ms(), true;
}

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
	picker_search_typed(run.c, slice(query, 0, 1));
	replay_settle(run, 200);
	for n, i: results {
		// results render for the query typed so far (the last one is the full query)
		q := ifx i == results.count - 1 then query else slice(query, 0, i + 1);
		picker_search_results(run.c, q, n);
		replay_settle(run, 200);
	}
}
#scope_export

// ---- per-feature parity tests (the action window of each fixture) ----

parity_send_message :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "send_message", R_GUILD, R_TEXT) { return; }
	r_frecency_load(*run);
	replay_mark(*run);
	r_type(run.c, R_TEXT, "hello from the official client");
	replay_pump(*run, 1700); // the typing timer fires while the text is typed
	r_frecency_run(*run);
	send_message(run.c, R_TEXT, "hello from the official client");
	replay_dispatches(*run, "send_message", "MESSAGE_CREATE");
	replay_settle(*run, 600);
	replay_check(*run, "send_message");
}

// FrecencyUserSettings writes byte for byte: every fixture PATCH of settings-proto/2 is rebuilt
// from the session's GET and the uses the official client had pending (the PATCH's totals over
// the GET's, the newest of its recent uses).
parity_frecency_proto :: (t: *T) {
	push_allocator(temp);
	checked := 0;
	for scenario: string.["send_message", "add_custom_reaction", "add_reaction", "close_dm", "create_channel", "create_guild", "delete_message", "emoji_picker_add_emoji", "emoji_picker_reaction", "guild_notifications", "inbox", "invite_people", "join_leave_server", "join_voice_channel", "open_profile_popout", "remove_reaction", "reply", "scroll_history", "send_dm", "upload_custom_emoji", "voice_with_b"] for acct: string.["a", "b"] {
		r: Replay;
		if !replay_load(*r, scenario, acct) continue;
		get_id: s64 = -1;
		get := "";
		for e: r.events {
			k, url := fstr(e, "k"), fstr(e, "url");
			if k == "req" && contains(url, "settings-proto/2") && fstr(e, "method") == "GET" get_id = fnum(e, "id");
			if k == "resp" && fnum(e, "id") == get_id {
				bv, _ := r_body_value(vget(e, "body"));
				get = fstr(vmap(bv), "settings");
			}
			if k != "req" || !contains(url, "settings-proto/2") || fstr(e, "method") != "PATCH" || !get continue;
			bv, _ := r_body_value(vget(e, "body"));
			patch := fstr(vmap(bv), "settings");
			olds := frecency_maps(frecency_settings_decode(get));
			news := frecency_maps(frecency_settings_decode(patch));
			f: Frecency_State;
			for items, kind: news for items {
				n := it.total_uses;
				for o: olds[kind] if o.key == it.key n -= o.total_uses;
				for i: it.recent_uses.count - n..it.recent_uses.count - 1 {
					use := Frecency_Use.{xx kind, it.key, it.recent_uses[i]};
					at := f.pending.count;
					while at > 0 && f.pending[at - 1].at > use.at at -= 1;
					array_insert_at(*f.pending, use, at);
				}
			}
			now := peek(f.pending).at;
			frecency_overwrite(*f, get, false, now);
			got := base64_encode(cast(string) frecency_delta(*f, now));
			expectf(t, got == patch, "%/%: PATCH at % differs\n  official: %\n  ours:     %", scenario, acct, fnum(e, "t"), patch, got);
			checked += 1;
		}
	}
	expectf(t, checked == 23, "% PATCHes checked", checked);
}

// Pending frecency usage outlives the launch (the stores persist pendingUsages), so the next
// launch's startup run loads the proto and writes it, as every official launch does (GET at
// READY + 0-10 s, the PATCH right after its response). Channel selects alone don't load it.
frecency_persisted :: (t: *T) {
	Rec :: struct { mu: locks.Mutex; methods: [..]string; }
	rec: Rec;
	rt :: (data: *void, host: string, req: http.Request) -> http.Response, http.Error {
		r := cast(*Rec) data;
		locks.lock(*r.mu);
		if contains(req.path, "settings-proto/2") array_add(*r.methods, ifx req.method == "GET" then "GET" else "PATCH");
		locks.unlock(*r.mu);
		resp := http.make_response(.Http3,, context.default_allocator);
		resp.status = 200;
		append_string(*resp.body, "{\"settings\":\"\"}");
		return resp, .None;
	}
	dir := "build/test_frecency_state";
	file_delete(tprint("%/identity.tsv", dir));
	cfg := Config.{token = "<token>", state_dir = dir, disable_startup = true, disable_gateway = true, disable_analytics = true, disable_remote_auth = true, round_tripper = .{*rec, rt}};
	launch :: (t: *T, cfg: Config, rec: *Rec, want: int, use: (c: *Client)) -> []Frecency_Use {
		c := client_create(cfg);
		client_start(c);
		saved := array_copy(c.store.frecency.pending,, temp);
		for * saved it.key = copy_string(it.key,, temp);
		f := *c.store.frecency;
		f.startup_ms, f.periodic_ms = 1, 7_200_000;
		c.store.connection = .Ready; // POST_CONNECTION_OPEN: R(true) 1 ms later
		start := mono_ms();
		while mono_ms() - start < 1000 {
			client_poll(c);
			locks.lock(*rec.mu);
			n := rec.methods.count;
			locks.unlock(*rec.mu);
			if f.timer_at - now_ms() > 60_000 && n >= want && !f.saving && !f.loading break; // R ran
			sleep_milliseconds(5);
		}
		use(c);
		client_destroy(c);
		return saved;
	}
	launch(t, cfg, *rec, 0, (c: *Client) { frecency_select(c, 1, 2); });
	expect_value(t, rec.methods.count, 0);
	got := launch(t, cfg, *rec, 0, (c: *Client) { frecency_use(c, .Reaction, "thumbsup"); });
	expect(t, rec.methods.count == 0 && got.count == 2 && got[0].kind == .Guild_Channel && got[0].key == "2", "restored channel selects; alone they don't load at startup");
	got = launch(t, cfg, *rec, 2, (c: *Client) {});
	expect(t, got.count == 4 && got[2].kind == .Reaction && got[2].key == "thumbsup" && got[3].kind == .Emoji, "a reaction is restored as both uses");
	expect(t, rec.methods.count == 2 && rec.methods[0] == "GET" && rec.methods[1] == "PATCH", "the startup run loads and writes the restored usage");
	got = launch(t, cfg, *rec, 2, (c: *Client) {});
	expect_value(t, got.count, 0); // written: nothing pending
	array_free(rec.methods);
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
	picker_emoji_selected(run.c, "fastcord_test", cast(Snowflake) 1564250154838528071, R_GUILD);
	add_reaction(run.c, R_TEXT, msg, "fastcord_test", cast(Snowflake) 1564250154838528071, false, "Message Reaction Picker");
	replay_settle(*run, 600);
	replay_check(*run, "add_custom_reaction");
}

// our reaction to msg with this emoji: (count, me)
r_reaction :: (c: *Client, msg: Snowflake, name: string) -> int, bool {
	for messages_get(*c.store, R_TEXT) if it.id == msg for r: it.reactions if r.emoji.name == name return r.count, r.me;
	return 0, false;
}

r_reaction_echo :: (run: *Replay_Run, msg: Snowflake, name: string, add: bool) {
	d, _ := etf.from_json(tprint("{\"user_id\":\"%\",\"channel_id\":\"%\",\"message_id\":\"%\",\"emoji\":{\"id\":null,\"name\":\"%\"},\"burst\":false,\"type\":0}", run.c.store.me, R_TEXT, msg, name));
	client_inject_dispatch(run.c, ifx add then "MESSAGE_REACTION_ADD" else "MESSAGE_REACTION_REMOVE", d);
	replay_settle(run, 100);
}

// requests since the mark whose key starts with method and contains part
r_count :: (run: *Replay_Run, method: string, part: string) -> int {
	locks.lock(*run.r.mu);
	defer locks.unlock(*run.r.mu);
	n := 0;
	for run.r.ours if begins_with(it.key, method) && contains(it.key, part) n += 1;
	return n;
}

// Reactions are predicted (ReactionActionCreators): the store changes before the request,
// the gateway echo doesn't count twice, a quick add -> remove sends PUT then DELETE and ends
// removed, and a failure is retried once (403: not) and then rolled back.
reaction_prediction :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "add_reaction", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	c := run.c;
	msg := r_last_own(c, R_TEXT);
	F :: "🔥";
	replay_mark(*run);
	add_reaction(c, R_TEXT, msg, F, location = "Message Inline Button");
	n, me := r_reaction(c, msg, F);
	expect(t, n == 1 && me, "add is shown before the response");
	replay_settle(*run, 200);
	r_reaction_echo(*run, msg, F, true);
	n, me = r_reaction(c, msg, F);
	expect(t, n == 1 && me, "the add echo does not count twice");
	remove_reaction(c, R_TEXT, msg, F, location = "Message Inline Button");
	n = r_reaction(c, msg, F);
	expect(t, n == 0, "remove is shown before the response");
	replay_settle(*run, 200);
	r_reaction_echo(*run, msg, F, false);
	expect(t, r_reaction(c, msg, F) == 0, "the remove echo does nothing");
	// add then remove before either answers: both requests, in order, and removed at the end
	before := r_count(*run, "PUT", "/reactions/");
	add_reaction(c, R_TEXT, msg, F);
	remove_reaction(c, R_TEXT, msg, F);
	expect(t, r_reaction(c, msg, F) == 0, "add -> remove ends removed at once");
	replay_settle(*run, 200);
	expect(t, r_count(*run, "PUT", "/reactions/") == before + 1 && r_count(*run, "DELETE", "/reactions/") == 2, "add -> remove sends PUT and DELETE");
	locks.lock(*run.r.mu);
	last_put, last_del := -1, -1;
	for run.r.ours if contains(it.key, "/reactions/") { if begins_with(it.key, "PUT") last_put = it_index; else last_del = it_index; }
	locks.unlock(*run.r.mu);
	expect(t, last_put < last_del, "PUT goes before DELETE");
	r_reaction_echo(*run, msg, F, true);
	r_reaction_echo(*run, msg, F, false);
	expect(t, r_reaction(c, msg, F) == 0, "both echoes leave it removed");
	// on, off, on before any answer, then the three echoes late: it stays on throughout,
	// and the requests go one at a time in click order (PUT, DELETE, PUT)
	puts, dels := r_count(*run, "PUT", "/reactions/"), r_count(*run, "DELETE", "/reactions/");
	add_reaction(c, R_TEXT, msg, F);
	remove_reaction(c, R_TEXT, msg, F);
	add_reaction(c, R_TEXT, msg, F);
	n, me = r_reaction(c, msg, F);
	expect(t, n == 1 && me, "on, off, on is shown on at once");
	replay_settle(*run, 400);
	expect(t, r_count(*run, "PUT", "/reactions/") == puts + 2 && r_count(*run, "DELETE", "/reactions/") == dels + 1, "on, off, on sends PUT, DELETE, PUT");
	locks.lock(*run.r.mu);
	order: [..]u8;
	order.allocator = temp;
	for run.r.ours if contains(it.key, "/reactions/") array_add(*order, it.key[0]);
	locks.unlock(*run.r.mu);
	expect(t, order.count >= 3 && order[order.count - 3] == #char "P" && order[order.count - 2] == #char "D" && order[order.count - 1] == #char "P", "in click order");
	r_reaction_echo(*run, msg, F, true);
	r_reaction_echo(*run, msg, F, false);
	n, me = r_reaction(c, msg, F);
	expect(t, n == 1 && me, "a late remove echo does not undo the last click");
	r_reaction_echo(*run, msg, F, true);
	n, me = r_reaction(c, msg, F);
	expect(t, n == 1 && me, "on, off, on ends on");
	// another session of ours removing it still shows (no echo of ours is expected)
	r_reaction_echo(*run, msg, F, false);
	expect(t, r_reaction(c, msg, F) == 0, "a remove from another device applies");
	// a 500 is retried once, then the add is rolled back
	run.r.fail, run.r.fail_status = "/reactions/", 500;
	before = r_count(*run, "PUT", "/reactions/");
	add_reaction(c, R_TEXT, msg, F);
	expect(t, r_reaction(c, msg, F) == 1, "shown while the request fails");
	replay_settle(*run, 300);
	expect(t, r_reaction(c, msg, F) == 0, "a failed add is rolled back");
	expect_value(t, r_count(*run, "PUT", "/reactions/") - before, 2);
	// a 403 is not retried; a failed remove puts the reaction back
	run.r.fail = "";
	add_reaction(c, R_TEXT, msg, F);
	replay_settle(*run, 200);
	run.r.fail, run.r.fail_status = "/reactions/", 403;
	before = r_count(*run, "DELETE", "/reactions/");
	remove_reaction(c, R_TEXT, msg, F);
	expect(t, r_reaction(c, msg, F) == 0, "remove shown while it fails");
	replay_settle(*run, 300);
	n, me = r_reaction(c, msg, F);
	expect(t, n == 1 && me, "a failed remove is rolled back");
	expect_value(t, r_count(*run, "DELETE", "/reactions/") - before, 1);
}

// Mark Unread (markUnread) and Pin / Unpin (ChannelPinsActionCreators), from the bundle (no
// capture): their requests, and the manual MESSAGE_ACK holding the channel unread until left.
mark_unread_and_pins :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "add_reaction", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	c := run.c;
	msgs := messages_get(*c.store, R_TEXT);
	if !expect(t, msgs.count >= 2, "fixture messages") return;
	target, prev := msgs[msgs.count - 1].id, msgs[msgs.count - 2].id;
	replay_mark(*run);
	mark_unread(c, R_TEXT, target);
	pin_message(c, R_TEXT, target, true);
	pin_message(c, R_TEXT, target, false);
	replay_settle(*run, 300);
	locks.lock(*run.r.mu);
	ack_shape := "";
	for run.r.ours if begins_with(it.key, "POST") && ends_with(it.key, "/ack") ack_shape = copy_string(it.shape,, temp);
	locks.unlock(*run.r.mu);
	expect_value(t, ack_shape, "{manual:bool,mention_count:num}");
	expect_value(t, r_count(*run, "PUT", "/messages/pins/{id}"), 1);
	expect_value(t, r_count(*run, "DELETE", "/messages/pins/{id}"), 1);
	d, _ := etf.from_json(tprint("{\"channel_id\":\"%\",\"message_id\":\"%\",\"manual\":true,\"mention_count\":0,\"version\":3}", R_TEXT, prev));
	client_inject_dispatch(c, "MESSAGE_ACK", d);
	replay_settle(*run, 100);
	_, rs := table_find(*c.store.read_states, R_TEXT);
	expect(t, rs.manual && rs.last_message_id == prev, "the manual ack moves the read state back and holds it");
	select_channel(c, R_GUILD, R_VOICE);
	_, rs = table_find(*c.store.read_states, R_TEXT);
	expect(t, !rs.manual, "leaving the channel ends the hold");
}

// A message's `thread` (an archived thread started from it) reaches the Store and the thread
// table, so the chat can show its thread card.
message_thread_object :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "add_reaction", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	c := run.c;
	msgs := messages_get(*c.store, R_TEXT);
	if !expect(t, msgs.count >= 1, "fixture messages") return;
	mid := msgs[msgs.count - 1].id + (1 << 22);
	d, _ := etf.from_json(tprint("{\"id\":\"%1\",\"channel_id\":\"%2\",\"guild_id\":\"%3\",\"type\":0,\"flags\":32,\"content\":\"hi\",\"author\":{\"id\":\"1\",\"username\":\"x\"},\"mentions\":[],\"mention_everyone\":false,\"thread\":{\"id\":\"%1\",\"type\":11,\"guild_id\":\"%3\",\"parent_id\":\"%2\",\"name\":\"old talk\",\"message_count\":7,\"thread_metadata\":{\"archived\":true}}}", mid, R_TEXT, R_GUILD));
	client_inject_dispatch(c, "MESSAGE_CREATE", d);
	replay_settle(*run, 100);
	th := channel_get(*c.store, mid);
	expect(t, th != null && is_thread(th) && th.parent_id == R_TEXT && th.name == "old talk", "the thread is in the Store");
	tm := thread_meta(mid);
	expect(t, tm != null && tm.message_count == 7 && tm.archived, "the thread's count and archived state are known");
}

// Read-state acks (ReadState.ack, no capture): a channel with mentions is acked at once,
// otherwise after 3 s; acks before the timer fires join it and keep the first location.
ack_timing :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "add_reaction", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	c := run.c;
	msgs := messages_get(*c.store, R_TEXT);
	if !expect(t, msgs.count >= 2, "fixture messages") return;
	// a mention while A looks elsewhere raises the count (ReadStateStore MESSAGE_CREATE)
	client_set_focused(c, false);
	mid := msgs[msgs.count - 1].id + (1 << 22);
	d, _ := etf.from_json(tprint("{\"id\":\"%\",\"channel_id\":\"%\",\"guild_id\":\"%\",\"type\":0,\"content\":\"hi\",\"author\":{\"id\":\"1\",\"username\":\"x\"},\"mentions\":[{\"id\":\"%\"}],\"mention_everyone\":false}", mid, R_TEXT, R_GUILD, c.store.me));
	client_inject_dispatch(c, "MESSAGE_CREATE", d);
	replay_settle(*run, 100);
	_, rs := table_find(*c.store.read_states, R_TEXT);
	expect_value(t, rs.mention_count, 1);
	client_set_focused(c, true);
	// focused but scrolled up: still not acked ("Not at bottom")
	set_route_scrolled_up(c, true);
	d, _ = etf.from_json(tprint("{\"id\":\"%\",\"channel_id\":\"%\",\"guild_id\":\"%\",\"type\":0,\"content\":\"hi\",\"author\":{\"id\":\"1\",\"username\":\"x\"},\"mentions\":[{\"id\":\"%\"}],\"mention_everyone\":false}", mid + (1 << 22), R_TEXT, R_GUILD, c.store.me));
	client_inject_dispatch(c, "MESSAGE_CREATE", d);
	replay_settle(*run, 100);
	_, rs = table_find(*c.store.read_states, R_TEXT);
	expect(t, rs.mention_count == 2 && c.pending_acks.count == 0, "a message while scrolled up isn't acked");
	set_route_scrolled_up(c, false);
	replay_mark(*run);
	ack_message(c, R_TEXT, msgs[msgs.count - 2].id, location = ACK_INCOMING_MESSAGE);
	replay_pump(*run, 300);
	expect_value(t, r_count(*run, "POST", "/ack"), 1);
	ack_message(c, R_TEXT, msgs[msgs.count - 2].id, location = ACK_CHANNEL_SCROLL);
	ack_message(c, R_TEXT, mid, location = ACK_INCOMING_MESSAGE);
	expect(t, c.pending_acks.count == 1 && c.pending_acks[0].location.object == ACK_CHANNEL_SCROLL.object && c.pending_acks[0].message_id == mid, "later acks join the pending one");
	replay_pump(*run, 2000);
	expect_value(t, r_count(*run, "POST", "/ack"), 1);
	replay_pump(*run, 1500);
	expect_value(t, r_count(*run, "POST", "/ack"), 2);
}

// Joining a voice channel acks its text chat unless it holds mentions ("Ack - Voice Channel Select").
voice_select_ack :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "join_voice_channel", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	c := run.c;
	ch := channel_get(*c.store, R_VOICE);
	if !expect(t, ch != null, "voice channel") return;
	rs := find_or_add(*c.store.read_states, R_VOICE);
	ch.last_message_id = rs.last_message_id + (1 << 22);
	rs.mention_count = 1;
	voice_join(c, R_GUILD, R_VOICE);
	found := false;
	for c.pending_acks if it.channel_id == R_VOICE found = true;
	expect(t, !found, "mentions keep the voice chat unread");
	rs = table_find_pointer(*c.store.read_states, R_VOICE);
	rs.mention_count = 0;
	voice_join(c, R_GUILD, R_VOICE);
	for c.pending_acks if it.channel_id == R_VOICE && it.location.object == ACK_VOICE_CHANNEL_SELECT.object found = true;
	expect(t, found, "joining acks the voice chat");
}

// Who reacted (reaction pill hover): one GET of the first 100 reactors, of the pill's type.
reactors_fetch :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "add_reaction", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	c := run.c;
	msgs := messages_get(*c.store, R_TEXT);
	if !expect(t, msgs.count >= 1, "fixture messages") return;
	replay_mark(*run);
	fetch_reactors(c, R_TEXT, msgs[0].id, "🔥", 0, false, 1);
	replay_settle(*run, 300);
	locks.lock(*run.r.mu);
	key := "";
	for run.r.ours if begins_with(it.key, "GET") && contains(it.key, "/reactions/") key = copy_string(it.key,, temp);
	locks.unlock(*run.r.mu);
	expect(t, ends_with(key, "/reactions/%F0%9F%94%A5?limit&type"), tprint("reactors request: %", key));
	fetch_reactors(c, R_TEXT, msgs[0].id, "🔥", 0, false, 2, after = c.store.me);
	remove_user_reaction(c, R_TEXT, msgs[0].id, "🔥", 0, false, c.store.me);
	replay_settle(*run, 300);
	locks.lock(*run.r.mu);
	page, del := "", "";
	for run.r.ours {
		if begins_with(it.key, "GET") && contains(it.key, "after") page = copy_string(it.key,, temp);
		if begins_with(it.key, "DELETE") && contains(it.key, "/reactions/") del = copy_string(it.key,, temp);
	}
	locks.unlock(*run.r.mu);
	expect(t, ends_with(page, "?limit&after&type"), tprint("next page: %", page));
	expect(t, ends_with(del, "/reactions/%F0%9F%94%A5/0/{id}?burst"), tprint("remove: %", del));
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

// Timed statuses ("For 15 Minutes"...) and their expiry are not captured: the
// bundle's setStatus / CustomStatusManager (traffic/CLIENT_RULES.md "Status").
// Checked here: the delta's status_expires_at_ms, the telemetry's
// expire_duration_minutes, and the expiry going back to Online with
// location CUSTOM_STATUS_MANAGER.
parity_status_timed :: (t: *T) {
	e: Settings_Edit;
	e.has_status, e.status, e.status_ms, e.status_expires_ms = true, Status.Dnd, 1, 2;
	want :: u8.[0x5a, 0x14, 0x0a, 0x05, 0x0a, 0x03, #char "d", #char "n", #char "d", 0x21, 2, 0, 0, 0, 0, 0, 0, 0, 0x2a, 0x02, 0x08, 0x01];
	expect(t, cast(string) settings_delta_proto(*e) == cast(string) want, "StatusSettings delta with status_expires_at_ms");
	run: Replay_Run;
	if !replay_begin(*run, t, "status_change", 0, 0) { return; }
	replay_mark(*run);
	set_status(run.c, .Dnd, 15 * 60_000);
	expect(t, run.c.store.settings.status_expires_ms > now_ms(), "expiry set");
	replay_settle(*run, 300);
	run.c.store.settings.status_expires_ms = now_ms() - 1;
	replay_settle(*run, 300);
	expect_value(t, run.c.store.settings.status, Status.Online);
	expect_value(t, run.c.store.settings.status_expires_ms, 0);
	got: [..]string;
	got.allocator = temp;
	for b: run.r.science for ev: b.events if ev.type == "user_status_updated" {
		for ev.keys if it == "next_status" array_add(*got, ev.consts[it_index]);
		for ev.keys if it == "expire_duration_minutes" || it == "location" array_add(*got, it);
	}
	expectf(t, join(..got, ",",, temp) == "\"dnd\",expire_duration_minutes,\"online\",location", "telemetry: %", join(..got, ",",, temp));
	replay_end(*run);
}

// IdleStore: 10 min without input sends op 3 idle (IDLE, then AFK), input in the window sends online again.
idle_presence :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "status_change", 0, 0) { return; }
	defer replay_end(*run);
	replay_mark(*run);
	since := now_ms() - IDLE_AFTER_MS - 1;
	atomic_store(*run.c.idle_since, since);
	replay_pump(*run, 50);
	expect_value(t, run.c.idle_sent, since);
	v := presence_value(run.c,, temp);
	expect_value(t, fstr(v.map, "status"), "idle");
	expect_value(t, fint(v.map, "since"), since);
	expect(t, vbool(vget(v.map, "afk")), "afk");
	expect(t, !vbool(vget(presence_value(run.c, old_afk = true,, temp).map, "afk")), "the IDLE update has the old afk");
	client_note_activity(run.c); // in-window input ends idle at once, not at the next 10 s poll
	replay_pump(*run, 50);
	v = presence_value(run.c,, temp);
	expect_value(t, fstr(v.map, "status"), "online");
	expect_value(t, fint(v.map, "since"), 0);
	n := 0;
	locks.lock(*run.r.mu);
	for run.r.sends if it.op == 3 n += 1;
	locks.unlock(*run.r.mu);
	expect_value(t, n, 4);
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
	r_frecency_load(*run);
	replay_mark(*run);
	voice_join(run.c, R_GUILD, R_VOICE);
	r_voice_connect(*run, R_MACBOOK);
	r_frecency_run(*run); // writes the voice channel too (VOICE_CHANNEL_SELECT)
	replay_settle(*run, 900);
	// op 4 preferred_region(s) come from the live RTC probe
	// science: fastcord has no voice invite suggestions
	replay_check(*run, "join_voice", string.["op 4", ".client_rtc_state", "science:impression_voice_invite_suggestions"]);
}

parity_leave_voice :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "join_voice_channel", R_GUILD, R_TEXT) { return; }
	voice_join(run.c, R_GUILD, R_VOICE);
	r_voice_connect(*run, R_MACBOOK);
	for 1..16 { // three bursts of speech
		replay_pump(*run, 100);
		analytics_voice_frame(run.c, .{speaking = it % 4 != 0, packets_sent = 5 * it, ping_ms = 48, members = 1});
	}
	analytics_voice_frame(run.c, .{packets_sent = 93, bytes_sent = 2511, ping_ms = 48, members = 1});
	replay_settle(*run, 300);
	replay_mark(*run);
	analytics_call_disconnect(run.c, R_GUILD, R_VOICE); // the app: the voice panel's Disconnect
	voice_leave(run.c);
	client_set_rtc_state(run.c, .Disconnected);
	replay_settle(*run, 300);
	// science: the web-vitals INP metric the official renderer reports now and then (no web page here)
	replay_check(*run, "leave_voice", string.["science:app_web_perf_startup_metrics"]);
}

// r_voice_connect: what the app reports of src/voice's connection (not run
// offline): the microphone prompt, the connection's steps, then our speech.
// devices: the official captures' (a MacBook's, or AirPods in dm_call).
R_MACBOOK :: Voice_Devices.{input = "MacBook Pro Microphone", output = "MacBook Pro Speakers", camera = "FaceTime HD Camera", inputs = 5, outputs = 5, cameras = 4};
R_AIRPODS :: Voice_Devices.{input = "Cameron’s AirPods Max", output = "Cameron’s AirPods Max", camera = "FaceTime HD Camera", inputs = 8, outputs = 9, cameras = 4};

r_voice_connect :: (run: *Replay_Run, devices: Voice_Devices, speak := true, prompt := true, members := 1, speak_after := 600) {
	c := run.c;
	replay_pump(run, 250);
	if prompt analytics_permissions_requested(c, "audio"); // the app opens the microphone on VOICE_SERVER_UPDATE
	client_set_rtc_state(c, .Awaiting_Endpoint);
	replay_pump(run, 150);
	t0 := now_ms();
	analytics_voice_connecting(c, "8c6ad1a8-2f8d-4c1e-9d5e-3a1b2c3d4e5f", "c-lax10-0bb324b8.discord.media", devices, false);
	replay_pump(run, 150);
	analytics_audio_input_initialized(c);
	replay_pump(run, 150);
	analytics_voice_ready(c, t0 + 20, now_ms(), 19339);
	replay_pump(run, 150);
	analytics_voice_connected(c, now_ms() - 120, now_ms(), "0f3a6b8c9d2e4f1a7b5c6d8e9f0a1b2c");
	client_set_rtc_state(c, .Rtc_Connected);
	if !speak return;
	replay_pump(run, 40);
	analytics_voice_frame(c, .{members = members}); // members 2: the E2EE group formed
	replay_settle(run, speak_after);
	analytics_voice_frame(c, .{speaking = true, packets_sent = 10, members = members});
}

parity_close_dm :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "close_dm", 0, 0) { return; }
	frecency_select(run.c, 0, R_DM); // the session opened on the DM
	r_frecency_load(*run);
	replay_mark(*run);
	private_channel_menu_opened(run.c);
	replay_settle(*run, 300);
	close_private_channel(run.c, R_DM);
	r_frecency_run(*run);
	replay_settle(*run, 500);
	replay_check(*run, "close_dm");
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
	// the fixture's buckets and hashes: the new guild's (filters fail, the hash in no range
	// of portkey's population: 0; mass mention's second, filterless population: 1) and a DM's
	r_bucket :: (c: *Client, name: string, gid: Snowflake) -> string {
		b, h := legacy_guild_bucket(c, legacy_entry(*c.analytics, true, name), name, gid);
		return tprint("%/%", b, h);
	}
	expect_value(t, r_bucket(run.c, LEGACY_PORTKEY, 1564227669971832975), "0/4968");
	expect_value(t, r_bucket(run.c, LEGACY_MASS_MENTION, 1564227669971832975), "1/3192");
	expect_value(t, r_bucket(run.c, LEGACY_PORTKEY, 0), "0/2490");
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
	upload_guild_emoji(run.c, R_GUILD, "tests/data/t_trns_gray.png", "fastcord_test");
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
	replay_check(*run, "open_dm", science_only = true, keep = true);
	// The lists' values (ProfileProperty, activity types, badge ids): B's profile has since gained
	// a bio, which the official client reports as [6] (recorded 2026-10-28); and in full.
	c := run.c;
	r_profile_props :: (c: *Client, user: Snowflake, guild: Snowflake, json: string) -> string {
		v, _ := etf.from_json(json,, temp);
		profile_props_apply(*c.store, user_get(*c.store, user), vmap(v));
		view := Profile_View.{layout = .Sidebar, user_id = user, guild_id = guild, session = "s"};
		profile_action(c, *view, .["user profile sidebar"], "VIEW");
		a := *c.analytics;
		locks.lock(*a.mu);
		defer locks.unlock(*a.mu);
		ev := peek(a.queue);
		i := find_index_from_left(ev, "\"profile_properties\"");
		return slice(ev, i, find_index_from_left(ev, ",\"user_status\"") - i);
	}
	got := r_profile_props(c, R_B, 0, "{\"user\":{\"id\":\"1564202918369042442\"},\"user_profile\":{\"bio\":\"hi\",\"pronouns\":\"\"}}");
	expect_value(t, got, "\"profile_properties\":[6],\"guild_profile_properties\":[],\"profile_activity_types\":[],\"profile_badges\":[]");
	apply_presence(*c.store, vmap(etf.from_json("{\"user\":{\"id\":\"1564202918369042442\"},\"status\":\"online\",\"activities\":[{\"type\":4,\"state\":\"x\"},{\"type\":0,\"name\":\"g\"}]}",, temp)));
	got = r_profile_props(c, R_B, R_GUILD, "{\"user\":{\"id\":\"1564202918369042442\",\"avatar\":\"a_1\",\"avatar_decoration_data\":{\"asset\":\"x\"}},\"user_profile\":{\"bio\":\"hi\",\"banner\":\"b\",\"theme_colors\":[null,1],\"profile_effect\":null},\"guild_member\":{\"nick\":\"n\"},\"guild_member_profile\":{\"pronouns\":\"p\"},\"badges\":[{\"id\":\"premium\"}],\"guild_badges\":[{\"id\":\"g\"}]}");
	expect_value(t, got, "\"profile_properties\":[3,4,6,7,8],\"guild_profile_properties\":[0,1],\"profile_activity_types\":[4,0],\"profile_badges\":[\"premium\",\"g\"]");
	replay_end(*run);
}

// explicit_media_redactable_messages_loaded: the fixture occurrences in the test guild (all at
// startup, outside the tested windows; the others' media in A's own guild is scrubbed) are
// rebuilt from the session's message pages: the first page of the channel with other people's
// media counts (attachments, embeds, those not scanned yet), later ones are throttled. The
// accounts don't allow NSFW, so their unset settings blur guild media too. A's startup in the
// test channel holds only A's own media: no event.
explicit_media_redactable :: (t: *T) {
	checked := 0;
	for sa: string.["send_dm b", "mark_as_read b", "join_leave_server b", "voice_with_b b", "open_dm a"] {
		scenario, acct := slice(sa, 0, sa.count - 2), slice(sa, sa.count - 1, 1);
		run: Replay_Run;
		if !replay_begin(*run, t, scenario, 0, 0, acct) continue;
		push_allocator(temp);
		official := "";
		pages: [..]V;
		ids: [..]s64;
		channel: Snowflake;
		for e: run.r.events {
			k, url := fstr(e, "k"), fstr(e, "url");
			if k == "req" && contains(url, "/messages?") && fstr(e, "method") == "GET" array_add(*ids, fnum(e, "id"));
			if k == "resp" && array_find(ids, fnum(e, "id")) array_add(*pages, vget(e, "body")); // later ones: throttled
			if k != "req" || !r_is_science(url) || official continue;
			bv, _ := r_body_value(vget(e, "body"));
			for ev: flist(vmap(bv), "events") if fstr(vmap(ev), "type") == "explicit_media_redactable_messages_loaded" {
				p := fmap(vmap(ev), "properties");
				channel = fsnow(p, "channel_id");
				official = tprint("\"channel_id\":\"%\",\"guild_id\":%,\"num_of_attachments\":%,\"num_of_attachments_pending_scan\":%,\"num_of_embeds\":%,\"num_of_embeds_pending_scan\":%", channel, ifx fsnow(p, "guild_id") then tprint("\"%\"", fsnow(p, "guild_id")) else "null", fint(p, "num_of_attachments"), fint(p, "num_of_attachments_pending_scan"), fint(p, "num_of_embeds"), fint(p, "num_of_embeds_pending_scan"));
			}
		}
		if !official channel = R_TEXT;
		ours := "";
		for pages {
			items := vlist(it);
			if !items.count || fsnow(vmap(items[0]), "channel_id") != channel continue;
			analytics_redactable_page(run.c, channel, items);
			checked += 1;
		}
		a := *run.c.analytics;
		locks.lock(*a.mu);
		n := 0;
		for a.queue if contains(it, "explicit_media_redactable_messages_loaded") { n += 1; ours = it; }
		locks.unlock(*a.mu);
		if official expectf(t, n == 1 && contains(ours, official), "%: one event (% queued)\n  official: %\n  ours:     %", sa, n, official, ours);
		else expectf(t, n == 0, "%: no event for our own media, % queued", sa, n);
		replay_end(*run);
	}
	expect(t, checked >= 9, "pages fed");
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
	// the app: Enter on the first result, the DM with B (empty query)
	dm := channel_get(*run.c.store, R_DM);
	analytics_quickswitcher_closed(run.c, R_GUILD, R_TEXT, "", 0, .[.{kind = .User, id = ifx dm && dm.recipient_ids then dm.recipient_ids[0] else 1, score = 3}], 0);
	replay_settle(*run, 300);
	// opening the DM is select_channel (parity_open_dm), with the DM list's view
	// (dm_list_viewed) and the profile it shows
	replay_check(*run, "switch_to_dm", string.["science:dm_list_viewed", "science:channel_opened", "science:user_profile_action"], science_only = true);
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
	rs := table_find_pointer(*run.c.store.read_states, R_TEXT);
	if rs rs.last_message_id = 1;
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
		n := run.r.ours.count + run.r.sends.count;
		locks.unlock(*run.r.mu);
		expectf(t, n == 0, "opening Add a Server / Join a Server sent % requests or gateway ops (official: science only)", n);
	}
	replay_mark(*run);
	// the app runs join_invite on a worker while the UI thread polls (science flushes)
	Join :: struct {
		c: *Client;
		ok: bool;
		done: bool;
	}
	jn := Join.{c = run.c};
	th := spawn(*jn, (j: *Join) {
		res := join_invite(j.c, "https://discord.gg/w5wYynKUN", temp);
		j.ok = res.ok;
		reset_temporary_storage();
		atomic_store(*j.done, true);
	});
	while !atomic_load(*jn.done) {
		client_poll(run.c);
		sleep_milliseconds(5);
	}
	locks.join(th);
	expect(t, jn.ok, "the invite was not accepted");
	replay_dispatches(*run, "b_join_submit");
	replay_settle(*run, 800);
	locks.lock(*run.c.route_mu);
	g, ch := run.c.route_guild, run.c.route_channel;
	locks.unlock(*run.c.route_mu);
	expectf(t, g == R_GUILD && ch == R_TEXT, "the joined guild opened at %/%", g, ch);
	replay_check(*run, "b_join_submit");
}

R_UPLOAD_CH :: cast(Snowflake) 1564405699197407414; // upload_options was recorded in a second text channel

// Staged attachments: each staged file uploads at once; spoiler / modify send nothing;
// the trash deletes the uploaded file once (no retry after the capture's 429); Send posts
// the message with is_spoiler / description / the renamed filename.
parity_upload_options :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "upload_options", R_GUILD, R_UPLOAD_CH) { return; }
	png, ok := read_entire_file("tests/scenarios/assets/test.png");
	if !expect(t, ok) { return; }
	defer free(png);
	c := run.c;

	replay_mark(*run);
	h1 := upload_draft(c, R_UPLOAD_CH, "test.png", "image/png", cast([]u8) png, "file_picker");
	// the upload PUT answers after its recorded latency: wait for it, then settle
	for i: 0..600-1 {
		client_poll(c);
		{ st, _, _, _ := upload_draft_status(c, h1);
		if st == .Done || st == .Failed { break; } }
		sleep_milliseconds(5);
	}
	replay_settle(*run, 500);
	st, sent, _, _ := upload_draft_status(c, h1);
	expect_value(t, st, Draft_State.Done);
	// the fixture's READY puts this user in the WebP experiment (variation 1): the PNG
	// is uploaded as a smaller lossless WebP, as the official client did (6302 -> 758)
	expect_value(t, c.webp_variation, 1);
	expect(t, sent > 0 && sent < png.count);
	replay_check(*run, "stage_file", keep = true);

	replay_mark(*run);
	analytics_media_draft_edited(c, "spoilered", true);
	replay_settle(*run, 300);
	replay_check(*run, "spoiler_toggle", string.["settings-proto/2"], keep = true); // the frecency lazy load (offline: never)

	replay_mark(*run);
	analytics_media_draft_edited(c, "has_alt_text", true);
	replay_settle(*run, 300);
	replay_check(*run, "modify_save", keep = true);

	replay_mark(*run);
	h2 := upload_draft(c, R_UPLOAD_CH, "fastcord_test.png", "image/png", cast([]u8) png, "file_picker");
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
	small, sok := read_entire_file("tests/data/t_trns_gray.png");
	expect(t, sok);
	defer free(small);
	h3 := upload_draft(c, R_UPLOAD_CH, "image.png", "image/png", cast([]u8) small, "clipboard");
	replay_settle(*run, 500);
	{
		d := drafts_of(c);
		locks.lock(*d.mu);
		u, _ := draft_find(d, h3);
		if u != null { expect_value(t, u.conv.failure, "insufficient_savings"); }
		if u != null { expect_value(t, u.size, small.count); }
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
		analytics_notification_shown(run.c, fsnow(d, "id"), fsnow(d, "channel_id"), fsnow(fmap(d, "author"), "id"), fint(d, "type"), true);
	}
	replay_mark(*run);
	last := table_find_pointer(*run.c.store.channels, R_TEXT).last_message_id;
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
	delete_mention(run.c, table_find_pointer(*run.c.store.channels, R_TEXT).last_message_id);
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
	if msg { track_jump(run.c, "Recent Mentions", R_TEXT, msg[msg.count - 1].id); }
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
	for 1..400 {
		if thread != 0 break;
		client_poll(c);
		for * r: feature_take(c) {
			if r.op == .Thread_Create && r.tag == 77 && r.ok { thread = apply_created_thread(c, r.body); }
			feature_result_free(r);
		}
		sleep_milliseconds(5);
	}
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
	// guild_channel_notice_check). settings-proto/2: the frecency lazy load.
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

// ---- guild events and channel management (traffic/guild_events.jsonl, create_channel.jsonl) ----

// The scheduled-events side table is process-wide (one client in the app); tests that
// delete the test guild (leave/join) must not run while parity_guild_events does.
r_guild_side_tables: locks.Mutex;

R_TEXT_CATEGORY :: cast(Snowflake) 1564227670806364341;

// r_apply_features: what the app does with finished feature requests
// (guild_admin_apply sends the follow-ups), polled for ms.
r_apply_features :: (run: *Replay_Run, ms: int) {
	start := mono_ms();
	while mono_ms() - start < ms {
		client_poll(run.c);
		for * r: feature_take_for(run.c) {
			guild_admin_apply(run.c, r);
			feature_result_free(r);
		}
		sleep_milliseconds(5);
	}
}

// r_new_channel: the channel the fixture's create window made (the app opens it).
r_new_channel :: (run: *Replay_Run) -> Snowflake {
	for e: replay_window(*run.r, "create_channel_submit") {
		if fstr(e, "k") == "ws_recv" && fstr(e, "ev") == "CHANNEL_CREATE" { return fsnow(fmap(e, "d"), "id"); }
	}
	return 0;
}

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
	expect_value(t, evs.count, 1);
	if evs.count != 1 { return; }
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
	expect_value(t, guild_events(R_GUILD).count, 0);
}

parity_create_channel :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "create_channel", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	// opening the modal: GET profile
	r_frecency_load(*run);
	replay_mark(*run);
	open_create_channel(run.c, R_GUILD);
	r_frecency_run(*run);
	r_apply_features(*run, 300);
	replay_compare(*run, "open_create_channel");
	// Create Channel: POST -> 201, templates; the app opens the new channel
	replay_mark(*run);
	create_channel(run.c, R_GUILD, .Guild_Text, "fc-temp", R_TEXT_CATEGORY);
	replay_dispatches(*run, "create_channel_submit"); // CHANNEL_CREATE comes before the response
	// the app opens the new channel when the POST's response is applied
	created := false;
	for 1..400 {
		if created break;
		client_poll(run.c);
		for * r: feature_take_for(run.c) {
			if r.op == .Channel_Create { created = true; }
			guild_admin_apply(run.c, r);
			feature_result_free(r);
		}
		sleep_milliseconds(5);
	}
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
	accept_friend_request(run2.c, ifx run2.c.store.me == R_B then cast(Snowflake) 1546819257420087346 else R_B);
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
	client_set_rtc_state(run.c, .Awaiting_Endpoint);
	replay_settle(*run, 200);
	replay_dispatches(*run, "start_call");
	client_poll(run.c);
	r_voice_connect(*run, R_AIRPODS, speak = false); // the app reports src/voice's connection (not run offline)
	replay_settle(*run, 1800); // the two shelf loads answer ~1.2 s and ~1.9 s later
	analytics_voice_frame(run.c, .{members = 1});
	analytics_voice_frame(run.c, .{speaking = true, packets_sent = 10, members = 1});
	replay_settle(*run, 300);
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
	r_voice_connect(*run2, R_AIRPODS, members = 2, speak_after = 40); // A is in the call: B commits into its E2EE group
	replay_pump(*run2, 250);
	analytics_voice_frame(run2.c, .{hearing = true, packets_received = 20, members = 2});
	replay_settle(*run2, 400);
	expect_value(t, incoming_call(run2.c), cast(Snowflake) 0);
	replay_check(*run2, "b_join_from_ring", string.["op 4"]);
	run3: Replay_Run;
	if !replay_begin(*run3, t, "dm_call", 0, R_DM) { return; }
	replay_pump(*run3, 1500);
	dm_call_start(run3.c, R_DM); // A is in the call with B, both speaking now and then
	replay_dispatches(*run3, "start_call");
	r_voice_connect(*run3, R_AIRPODS, speak = false, prompt = false);
	for 1..16 {
		replay_pump(*run3, 100);
		analytics_voice_frame(run3.c, .{speaking = it % 4 != 0, hearing = it % 4 == 0, packets_sent = 20 * it, packets_received = 12 * it, jitter_ms = 30, target_frames = 2, ping_ms = 18, members = 2});
	}
	replay_settle(*run3, 300);
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
	auth_login(c, "<email>", cast([]u8) "<token>");
	for 1..400 { if !client_logged_out(c) break; replay_pump(*run, 5); }
	expect(t, !client_logged_out(c));
	if c.gw == null { return; }
	evs := auth_take_events(c);
	expect(t, evs.count == 1 && evs[0].kind == .Logged_In && evs[0].token == "<token>");
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
		// not modelled: the Friends activity feed's game profiles
		"science:game_profile_entry_point_available"
	]);
}

// ---- username change (fixture account_edits: a passive recording on the home route) ----

// account_edits starts on an open session (its only READY follows the re-login):
// account A's READY from settings stands in.
r_account_begin :: (run: *Replay_Run, t: *T) -> bool {
	if !replay_begin(run, t, "account_edits", 0, 0, ready_from = "settings") { return false; }
	identity_set_app_state(*run.c.id, .Focused); // recorded by hand: the window had focus
	return true;
}

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
	for 1..200 {
		if got_patch break;
		client_poll(run.c);
		for * r: feature_take(run.c) {
			if r.op == .User_Patch { got_patch = r.ok; }
			feature_result_free(r);
		}
		sleep_milliseconds(5);
	}
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

// An older session's late leave (after a gateway reconnect) must not drop us from the list;
// our account joining on another computer takes the call over.
// RTC_CONNECTED: op 31 (once a session), then the QoS heartbeat with "rtc_connected" right away
// when the QoS was inactive (window unfocused); leaving drops the reason.
voice_rtc_qos :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "join_voice_channel", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	run.c.focused = false; // unfocused: the QoS is inactive until RTC_CONNECTED
	gateway_set_active(run.c.gw, qos_from_state(false, false));
	replay_mark(*run);
	voice_join(run.c, R_GUILD, R_VOICE);
	client_set_rtc_state(run.c, .Rtc_Connecting);
	client_set_rtc_state(run.c, .Rtc_Connected);
	client_set_rtc_state(run.c, .Rtc_Connected);
	locks.lock(*run.r.mu);
	ops := tprint("%", run.r.sends.count);
	for run.r.sends ops = tprint("%,%", ops, it.op);
	beats := join(..run.r.beats, ";",, temp);
	locks.unlock(*run.r.mu);
	expect_value(t, ops, "2,4,31");
	expect_value(t, beats, "2:rtc_connected");
	client_set_rtc_state(run.c, .Disconnected);
	client_set_focused(run.c, true);
	client_set_rtc_state(run.c, .Rtc_Connected);
	locks.lock(*run.r.mu);
	n31 := 0;
	for run.r.sends if it.op == 31 n31 += 1;
	locks.unlock(*run.r.mu);
	expect_value(t, n31, 1);
	g := run.c.gw;
	expect_value(t, join(..array_view(g.qos_upcoming.reasons, 0, g.qos_upcoming.n), ",",, temp), "foregrounded,rtc_connected");
}

r_sent_ops :: (run: *Replay_Run) -> string {
	locks.lock(*run.r.mu);
	defer locks.unlock(*run.r.mu);
	ops: [..]string;
	ops.allocator = temp;
	for run.r.sends array_add(*ops, tprint("%", it.op));
	return join(..ops, ",",, temp);
}

// While the socket is down a voice join and a member-list subscription aren't sent; RESUMED sends
// op 3 and op 4 (SelfPresenceStore, VoiceStateStore forceUpdate) and every guild's subscription (op 37).
gateway_resume_replay :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "join_voice_channel", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	replay_settle(*run, 300);
	replay_mark(*run);
	run.c.gw.state = .Closed; // the socket dropped
	voice_join(run.c, R_GUILD, R_VOICE);
	subscribe_member_list(run.c, R_GUILD, R_TEXT, .[.[0, 99]]);
	client_poll(run.c);
	expect_value(t, r_sent_ops(*run), "");
	run.c.gw.state = .Established;
	client_inject_dispatch(run.c, "RESUMED", .{});
	client_poll(run.c);
	expect_value(t, r_sent_ops(*run), "3,4,37");
	locks.lock(*run.r.mu);
	op4, op37 := run.r.sends[1].shape, run.r.sends[2].shape;
	locks.unlock(*run.r.mu);
	expect(t, contains(op4, "channel_id:str"), op4);
	expect(t, contains(op37, tprint("%:{typing:bool,threads:bool,activities:bool,members:[],member_updates:bool,channels:{%:[[num]]}", R_GUILD, R_TEXT)), op37);
	// a leave while down: the next RESUMED leaves
	run.c.gw.state = .Closed;
	voice_leave(run.c);
	run.c.gw.state = .Established;
	client_inject_dispatch(run.c, "RESUMED", .{});
	client_poll(run.c);
	locks.lock(*run.r.mu);
	op4 = run.r.sends[4].shape;
	locks.unlock(*run.r.mu);
	expect(t, contains(op4, "channel_id:null"), op4);
	// the app asks every frame while the list is empty: an equal subscription sends nothing
	before := r_sent_ops(*run);
	for 1..3 { subscribe_member_list(run.c, R_GUILD, R_TEXT, .[.[0, 99]]); client_poll(run.c); }
	expect_value(t, r_sent_ops(*run), before);
	subscribe_member_list(run.c, R_GUILD, R_TEXT, .[.[0, 99], .[100, 199]]);
	client_poll(run.c);
	subscribe_member_list(run.c, R_GUILD, R_TEXT, .[.[0, 99], .[100, 199]]);
	client_poll(run.c);
	expect_value(t, r_sent_ops(*run), join(before, ",37",, temp));
}

// A fresh READY (a new session) replaces the session state instead of merging into it, and the
// open channel's messages are fetched again and replace what was loaded.
ready_replaces_state :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "join_voice_channel", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	replay_settle(*run, 300);
	s := *run.c.store;
	expect(t, guild_get(s, R_GUILD) != null, "the fixture's guild");
	table_set(*s.guilds, 42, .{id = 42}); // a server left while the session was gone
	table_set(*s.voice_states, 43, .{user_id = 43, channel_id = R_VOICE}); // a ghost occupant
	l := message_list(s, R_TEXT);
	expect(t, l.loaded, "the route's page is loaded");
	ghost := array_add(*l.messages);
	ghost.id = 1; // a message deleted while the session was gone
	ready: V;
	for run.r.events if fstr(it, "k") == "ws_recv" && fstr(it, "ev") == "READY" { ready = vget(it, "d"); break; }
	replay_mark(*run);
	client_inject_dispatch(run.c, "READY", ready);
	client_poll(run.c);
	expect(t, guild_get(s, 42) == null && guild_get(s, R_GUILD) != null, "guilds replaced");
	expect(t, table_find_pointer(*s.voice_states, 43) == null, "voice states replaced");
	expect(t, message_list(s, R_TEXT).stale, "the loaded channel goes stale");
	replay_pump(*run, 1200); // the page answers after its recorded latency
	l = message_list(s, R_TEXT);
	expectf(t, l.loaded && !l.stale && !(l.messages.count > 0 && l.messages[0].id == 1), "refetched and replaced: % % % %", l.loaded, l.stale, l.messages.count, ifx l.messages.count then l.messages[0].id else 0);
	locks.lock(*run.r.mu);
	fetched := false;
	for run.r.ours if contains(it.key, "/messages?limit") fetched = true;
	locks.unlock(*run.r.mu);
	expect(t, fetched, "the open channel's page is requested again");
}

// A moderator moves us: the call follows (and a later READY / RESUMED op 4 asks for the new channel);
// our own join doesn't count until the server confirmed it; removal ends the call.
voice_moved :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "join_voice_channel", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	c := run.c;
	vsu :: (c: *Client, channel: Snowflake) {
		b := etf.map_builder(4,, temp);
		etf.map_put(*b, "user_id", etf.vstring(snowflake_string(c.store.me)));
		etf.map_put(*b, "guild_id", etf.vstring(snowflake_string(R_GUILD)));
		etf.map_put(*b, "channel_id", ifx channel then etf.vstring(snowflake_string(channel)) else .{});
		etf.map_put(*b, "session_id", etf.vstring(c.store.session_id));
		store_apply_dispatch(*c.store, "VOICE_STATE_UPDATE", etf.vmap(etf.map_done(*b)), 0);
	}
	seen: Snowflake;
	voice_join(c, R_GUILD, R_VOICE);
	expect_value(t, voice_followed(c, R_VOICE, *seen), R_VOICE); // not confirmed yet
	vsu(c, R_VOICE);
	expect_value(t, voice_followed(c, R_VOICE, *seen), R_VOICE);
	vsu(c, R_TEXT2); // moved
	expect_value(t, voice_followed(c, R_VOICE, *seen), R_TEXT2);
	expect_value(t, c.voice_self.channel_id, R_TEXT2);
	expect_value(t, voice_followed(c, R_TEXT2, *seen), R_TEXT2);
	vsu(c, 0); // disconnected by a moderator
	expect_value(t, voice_followed(c, R_TEXT2, *seen), 0);
	expect_value(t, c.voice_self.channel_id, 0);
}

// Quitting sends what is still waiting: an ack in its 3 s delay and the settings write in its 10 s.
quit_flushes_work :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "switch_theme", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	ack_message(run.c, R_TEXT, 1564256109777387634);
	set_theme(run.c, .Light);
	client_poll(run.c);
	client_destroy(run.c);
	keys: [..]string;
	keys.allocator = temp;
	for run.r.ours array_add(*keys, it.key);
	all := join(..keys, " ",, temp);
	expect(t, contains(all, "POST discord.com/api/v9/channels/{id}/messages/{id}/ack"), all);
	expect(t, contains(all, "PATCH discord.com/api/v9/users/@me/settings-proto/1"), all);
	fini(*run.r.pool);
	fini(*run.donor.pool);
}

voice_state_stale_leave :: (t: *T) {
	s: Store;
	store_init(*s, temp);
	vsu :: (s: *Store, channel: string, session: string) {
		b := etf.map_builder(3,, temp);
		etf.map_put(*b, "user_id", etf.vstring("7"));
		etf.map_put(*b, "channel_id", ifx channel then etf.vstring(channel) else .{});
		etf.map_put(*b, "session_id", etf.vstring(session));
		store_apply_dispatch(s, "VOICE_STATE_UPDATE", etf.vmap(etf.map_done(*b)), 0);
	}
	vsu(*s, "9", "old");
	vsu(*s, "9", "new");
	vsu(*s, "", "old");
	vs := table_find_pointer(*s.voice_states, 7);
	expect(t, vs != null && vs.session_id == "new", "the old session's leave is ignored");
	vsu(*s, "", "new");
	expect(t, table_find_pointer(*s.voice_states, 7) == null, "the current session's leave removes us");
	// our account joins a call on another computer: the call moves there (the app hangs up)
	s.me = 7;
	s.session_id = "ours";
	vsu(*s, "9", "ours");
	expect_value(t, s.voice_elsewhere, 0);
	vsu(*s, "5", "other");
	vs = table_find_pointer(*s.voice_states, 7);
	expect(t, vs != null && vs.channel_id == 5 && s.voice_elsewhere == 1, "another device's join takes the call");
	vsu(*s, "5", "other");
	expect_value(t, s.voice_elsewhere, 1);
}

// HTTPUtils' per-URL hold: after a 429, requests queued for the URL go one per response, in order.
rate_limit_queue :: (t: *T) {
	R :: struct { r: *Rate_Limiter; n: int; done: *[3]s64; }
	URL :: "https://discord.com/api/v9/x";
	r: Rate_Limiter;
	rate_limiter_init(*r);
	defer rate_limiter_destroy(*r);
	expect(t, rate_note_response(*r, URL, 429, .[.{"retry-after", "1"}], .{}, now_ms()) >= 1000);
	done: [3]s64;
	threads: [3]*Thread;
	for 0..2 {
		threads[it] = spawn(R.{*r, it, *done}, (a: R) {
			rate_acquire(a.r, URL);
			a.done.*[a.n] = now_ms();
		});
		sleep_milliseconds(20); // queue order
	}
	locks.lock(*r.mu);
	table_find_pointer(*r.holds, URL).until = now_ms() + 50; // shorten the hold
	locks.cond_broadcast(*r.cond);
	locks.unlock(*r.mu);
	sleep_milliseconds(250);
	expect(t, done[0] != 0 && done[1] == 0 && done[2] == 0, "the timer releases one request");
	rate_note_response(*r, URL, 200, .[], .{}, now_ms());
	sleep_milliseconds(50);
	expect(t, done[1] != 0 && done[2] == 0, "a response releases the next");
	rate_note_response(*r, URL, 200, .[], .{}, now_ms());
	for threads locks.join(it);
	rate_note_response(*r, URL, 200, .[], .{}, now_ms());
	expect(t, table_find_pointer(*r.holds, URL) == null, "an empty queue drops the hold");
	ra := retry_after_seconds(.[.{"retry-after", "2.5"}], .{});
	expect_value(t, ra, 2.0);
}

// Platform identity: Chromium's locale resolution, then the bundle's Discord locale matcher.
platform_locales :: (t: *T) {
	cases :: string.[
		"en-US", "en-US", "en-US",   "en-AU", "en-GB", "en-GB",   "de_DE.UTF-8", "de", "de",
		"es-MX", "es-419", "es-419", "es-ES", "es", "es-ES",      "pt-PT", "pt-PT", "pt-BR",
		"zh-Hant-TW", "zh-TW", "zh-TW", "zh-Hans-CN", "zh-CN", "zh-CN", "nb-NO", "nb", "no",
		"sv-SE", "sv", "sv-SE",      "ar-EG", "ar", "en-US",      "xx", "en-US", "en-US"
	];
	for i: 0..cases.count / 3 - 1 {
		c := chromium_locale(cases[3 * i]);
		expectf(t, c == cases[3 * i + 1], "chromium_locale(%) = %", cases[3 * i], c);
		d := discord_locale(c);
		expectf(t, d == cases[3 * i + 2], "discord_locale(%) = %", c, d);
	}
	p := host_platform();
	expect(t, p.os_version != "" && p.timezone != "" && p.locale != "", "host platform has OS version, timezone and locale");
	#if OS == .MACOS {
		expect(t, p.browser_user_agent == DEFAULT_USER_AGENT && p.sec_ch_ua_platform == "\"macOS\"", "the macOS user agent is Chrome's frozen one");
		expect(t, begins_with(p.os_version, p.os_sdk_version) && (p.os_arch == "arm64" || p.os_arch == "x64"), "os_sdk_version is the Darwin major");
	}
	expect(t, electron_user_agent("Windows NT 10.0; Win64; x64", "1.0.9266") == "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) discord/1.0.9266 Chrome/148.0.7778.280 Electron/42.11.15 Safari/537.36");
}

// The /app document at launch: Chrome's navigation headers, GLOBAL_ENV.BUILD_NUMBER adopted before the
// gateway opens (never after the super properties went out) and persisted; the version check follows.
app_document_build :: (t: *T) {
	Rec :: struct { mu: locks.Mutex; paths: [..]string; wire: [..]string; manifest: string; }
	rec: Rec;
	rt :: (data: *void, host: string, req: http.Request) -> http.Response, http.Error {
		r := cast(*Rec) data;
		if host == "updates.discord.com" {
			locks.lock(*r.mu);
			r.manifest = copy_string(req.path,, context.default_allocator);
			locks.unlock(*r.mu);
			resp := http.make_response(.Http2,, context.default_allocator);
			resp.status = 200;
			append_string(*resp.body, "{\"full\":{\"host_version\":[0,0,421],\"url\":\"x\"},\"required_update\":true}");
			return resp, .None;
		}
		names: [..]string;
		names.allocator = temp;
		for req.headers array_add(*names, it.name);
		locks.lock(*r.mu);
		array_add(*r.paths, copy_string(req.path,, context.default_allocator));
		array_add(*r.wire, join(..names, separator = ",",, context.default_allocator));
		locks.unlock(*r.mu);
		resp := http.make_response(.Http3,, context.default_allocator);
		resp.status = 200;
		append_string(*resp.body, ifx begins_with(req.path, "/app?_=") then "<script>window.GLOBAL_ENV = {\"NODE_ENV\":\"production\",\"BUILD_NUMBER\":\"650001\",\"RELEASE_CHANNEL\":\"stable\"}</script>" else "{}");
		return resp, .None;
	}
	expect_value(t, html_build_number("{\"BUILD_NUMBER\":\"649389\",\"X\":1}"), 649389);
	expect_value(t, html_build_number("{\"BUILD_NUMBER\":\"\"}"), 0);
	expect_value(t, html_build_number("<html></html>"), 0);
	dir := "build/test_app_document_state";
	file_delete(tprint("%/identity.tsv", dir));
	c := client_create(.{token = "<token>", state_dir = dir, disable_startup = true, disable_gateway = true, disable_analytics = true, disable_remote_auth = true, ws_open_delay_ms = 10_000, round_tripper = .{*rec, rt}});
	client_start(c);
	schedule_app_load(c);
	start := mono_ms();
	while (c.id.web_build == 0 || !c.id.host_version) && mono_ms() - start < 3000 sleep_milliseconds(5);
	expect_value(t, c.id.web_build, 650001);
	expect(t, c.id.host_version == "0.0.421" && c.id.platform.client_version == HOST_VERSION, "the updater's host version waits for the next launch");
	expect(t, rec.manifest == "/distributions/app/manifests/latest?channel=stable&platform=osx&arch=arm64", "the updater's manifest check");
	expect_value(t, c.id.platform.client_build_number, 650001);
	locks.lock(*rec.mu);
	expect(t, rec.paths.count == 1 && rec.paths[0] == tprint("/app?_=%", c.launch_ms), "the launch's first request is /app?_=<Date.now()>");
	expect(t, rec.wire.count == 1 && rec.wire[0] == "upgrade-insecure-requests,user-agent,accept,sec-fetch-site,sec-fetch-mode,sec-fetch-user,sec-fetch-dest,accept-encoding,accept-language,priority", "navigation header order (netlog)");
	locks.unlock(*rec.mu);
	locks.lock(*c.job_mu);
	version_ok := false;
	for c.jobs if begins_with(it.path, "/assets/version.stable.json?_=") version_ok = it.not_before == c.launch_ms + APP_VERSION_CHECK_MS && it.path == tprint("/assets/version.stable.json?_=%", it.not_before / 300_000);
	locks.unlock(*c.job_mu);
	expect(t, version_ok, "version.stable.json queued 3.4 s after the document, with its 5-minute bucket");
	expect(t, contains(super_properties_json(*c.id, now_ms()), "\"client_build_number\":650001"), "super properties carry the page's build");
	identity_learn_build(*c.id, 650002, adopt = true);
	expect_value(t, c.id.platform.client_build_number, 650001); // sealed for the launch
	c.store.settings.locale = copy_string("fr",, c.allocator);
	client_poll(c);
	expect(t, c.id.platform.locale == "fr", "the language setting becomes x-discord-locale");
	client_destroy(c);
	c = client_create(.{token = "<token>", state_dir = dir, disable_startup = true, disable_gateway = true, disable_analytics = true, disable_remote_auth = true});
	expect_value(t, c.id.platform.client_build_number, 650002);
	expect(t, c.id.platform.locale == "fr", "the cached language is the boot locale");
	expect(t, c.id.platform.client_version == "0.0.421" && contains(c.id.platform.browser_user_agent, " discord/0.0.421 Chrome/"), "the next launch runs the updated host");
	client_destroy(c);
	expect(t, host_version_newer("0.0.421", "0.0.419") && host_version_newer("1.0.10000", "1.0.9266") && !host_version_newer("0.0.418", "0.0.419") && !host_version_newer("0.0.x", "0.0.419") && !host_version_newer("0.0.1.2", "0.0.1"), "host version order");
	free(rec.manifest);
	for rec.paths free(it);
	for rec.wire free(it);
	array_free(rec.paths);
	array_free(rec.wire);
}

// quic_chrome_initials: our first flight has the layout of Chrome 148's (QUICHE's multi-packet chaos protection,
// seen in the official client's Initials to discord.com): two 1250-byte datagrams, packets 1 and 2 with 1- then
// 2-byte packet numbers, the ClientHello's head (55-86 bytes) and tail in packet 1 and its middle in packet 2,
// each packet's CRYPTO split further among 2-10 PINGs and PADDING.
quic_chrome_initials :: (t: *T) {
	for 1..10 {
		dg := quic.first_flight("discord.com",, temp);
		if !expect_value(t, dg.count, 2) return;
		have: [2][..][2]u64;
		for d, di: dg {
			expect_value(t, d.count, 1250);
			dcid := array_view(d, 6, d[5]);
			pos := 6 + dcid.count + 1 + d[6 + dcid.count];
			token, _ := get_varint(d, *pos);
			pos += xx token;
			length, _ := get_varint(d, *pos);
			if !expect_value(t, pos + cast(int) length, d.count) return;
			secret := crypto.hkdf_extract(u8.[0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a], dcid);
			label :: (secret: []u8, name: string, out: []u8) {
				info: [..]u8;
				info.allocator = temp;
				array_add(*info, 0, cast(u8) out.count, cast(u8) (6 + name.count));
				array_add(*info, ..cast([]u8) "tls13 ");
				array_add(*info, ..cast([]u8) name);
				array_add(*info, 0);
				crypto.hkdf_expand(secret, info, out);
			}
			client, key, iv, hp: [32]u8;
			label(secret, "client in", client);
			label(client, "quic key", array_view(key, 0, 16));
			label(client, "quic iv", array_view(iv, 0, 12));
			label(client, "quic hp", array_view(hp, 0, 16));
			pkt := array_copy(d,, temp);
			mask, zero: [16]u8;
			crypto.aes_ctr(array_view(hp, 0, 16), array_view(pkt, pos + 4, 16), zero, mask);
			pkt[0] ^= mask[0] & 0x0f;
			pnlen := (pkt[0] & 3) + 1;
			pn: u64;
			for i: 0..pnlen - 1 { pkt[pos + i] ^= mask[1 + i]; pn = pn << 8 | pkt[pos + i]; }
			expect_value(t, pn, di + 1);
			expect_value(t, pnlen, di + 1);
			for i: 0..7 iv[11 - i] ^= cast,trunc(u8) (pn >> (8 * i));
			a: crypto.Aead;
			crypto.aead_init(*a, .AES_GCM, array_view(key, 0, 16));
			hdr := pos + pnlen;
			ct := array_view(pkt, hdr, pkt.count - hdr - 16);
			pt := NewArray(ct.count, u8,, temp);
			ok := crypto.open(*a, pt, array_view(iv, 0, 12), array_view(pkt, 0, hdr), ct, array_view(pkt, pkt.count - 16, 16));
			crypto.aead_destroy(*a);
			if !expect(t, ok, "Initial decrypts") return;
			// Chrome's header: 8-byte DCID, empty SCID and token, 2-byte Length; 1215 then 1214 bytes of frames.
			expect(t, dcid.count == 8 && pos == 18 && pt.count == 1215 - di, "Chrome's Initial header");
			pings, frames := 0, 0;
			i := 0;
			while i < pt.count {
				if pt[i] == 0 { i += 1; continue; }
				if pt[i] == 1 { pings += 1; i += 1; continue; }
				if !expect_value(t, pt[i], 6) return;
				i += 1;
				off, _ := get_varint(pt, *i);
				n, _ := get_varint(pt, *i);
				array_add(*have[di], .[off, off + n],, temp);
				frames += 1;
				i += xx n;
			}
			expectf(t, pings >= 2 && pings <= 10, "packet % has % PINGs", pn, pings);
			expectf(t, frames >= 4 - di && frames <= 12 - di, "packet % has % CRYPTO frames", pn, frames);
		}
		// Packet 1 holds [0, head) and [tail, total), packet 2 exactly [head, tail).
		merge :: (r: [..][2]u64) -> [..][2]u64 {
			quick_sort(r, (a: [2]u64, b: [2]u64) -> s64 { return cast(s64) a[0] - cast(s64) b[0]; });
			out: [..][2]u64;
			out.allocator = temp;
			for r {
				if out && out[out.count - 1][1] == it[0] out[out.count - 1][1] = it[1];
				else array_add(*out, it);
			}
			return out;
		}
		p1, p2 := merge(have[0]), merge(have[1]);
		if !expect_value(t, p1.count, 2) || !expect_value(t, p2.count, 1) return;
		head, tail, total := p1[0][1], p1[1][0], p1[1][1];
		expect(t, p1[0][0] == 0 && head >= 55 && head < 87 && p2[0][0] == head && p2[0][1] == tail, "head and tail in packet 1, middle in packet 2");
		// QUICHE's split: packet 1 carries ceil((total + m) / packets) - m bytes, m being one CRYPTO frame's
		// header for the whole hello; 1215 bytes of frames fit in the first packet.
		vl :: (v: u64) -> u64 { return cast(u64) ifx v < 64 then 1 else ifx v < 16384 then 2 else 4; }
		m := 1 + vl(total - 1) + vl(total);
		npkts := (total + m + 1215 - m - 1) / (1215 - m);
		expect_value(t, head + total - tail, (total + m + npkts - 1) / npkts - m);
	}
}

// quic_h3_control_stream: our HTTP/3 start matches Chrome 148's (QUICHE's): the control stream sends Chrome's
// captured SETTINGS (sorted ids, then a GREASE setting) and a GREASE frame, the QPACK streams stay silent, and
// each request's PRIORITY_UPDATE leaves just before its HEADERS.
quic_h3_control_stream :: (t: *T) {
	b := quic.h3_preview("u=1, i", 2,, temp);
	Rec :: struct { id: u8; data: []u8; }
	recs: [..]Rec;
	recs.allocator = temp;
	i := 0;
	while i + 3 <= b.count {
		n := (cast(int) b[i + 1] << 8) | b[i + 2];
		array_add(*recs, .{b[i], array_view(b, i + 3, n)});
		i += 3 + n;
	}
	if !expect_value(t, recs.count, 5) return;
	// Chrome's control stream (official capture) up to its GREASE setting: type 0, SETTINGS, then 01, 06, 07, 33.
	CHROME :: "\x01\x80\x01\x00\x00\x06\x80\x04\x00\x00\x07\x40\x64\x33\x01";
	c := recs[0].data;
	expect(t, recs[0].id == 2 && c.count > 18 && c[0] == 0 && c[1] == 4 && cast(string) array_view(c, 3, CHROME.count) == CHROME, "control stream starts like Chrome's");
	pos := 3 + CHROME.count;
	gid, _ := get_varint(c, *pos);
	get_varint(c, *pos);
	expectf(t, gid > 0x21 && (gid - 0x21) % 0x1f == 0 && pos == 3 + cast(int) c[2], "GREASE setting %", gid);
	gtype, _ := get_varint(c, *pos);
	glen, _ := get_varint(c, *pos);
	expectf(t, (gtype - 0x21) % 0x1f == 0 && glen == ((gtype - 0x21) / 0x1f) % 4 && pos + cast(int) glen == c.count, "GREASE frame type % length %", gtype, glen);
	for 1..2 {
		pu := recs[2 * it - 1];
		pos = 0;
		typ, _ := get_varint(pu.data, *pos);
		get_varint(pu.data, *pos);
		elem, _ := get_varint(pu.data, *pos);
		expect(t, pu.id == 2 && typ == 0xf0700 && elem == xx (4 * (it - 1)) && cast(string) array_view(pu.data, pos, pu.data.count - pos) == "u=1, i", "PRIORITY_UPDATE before its request");
		expect(t, recs[2 * it].id == 4 * (it - 1) && recs[2 * it].data[0] == 1, "then the request's HEADERS");
	}
}

