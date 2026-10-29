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
R_TEXT :: cast(Snowflake) 1564405699197407414;
R_VOICE :: cast(Snowflake) 1564227670806364345;
R_DM :: cast(Snowflake) 1564228964451356713;
R_B :: cast(Snowflake) 1564202918369042442;

// Requests the comparison leaves out: UI assets and images the app fetches
// itself, Shop art (collectibles-shop: the Shop entry's marketing art and the profile
// editor's random previews, which the library loads and drops, checked by editor_previews;
// the Shop entry's hover art; users' avatar decorations, `<sku>/static`), the RTC probe and Cloudflare's page challenge. Telemetry (/science) is compared
// on its own, per event (r_science_check).
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
	ready_timing: [2]float64; // our ready_payload_received's r_ready_timing (ready_seen)
	ready_seen: bool;
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
		case .Map;  for * v.map { it.key = r_unscrub(it.key); it.value = r_unscrub(it.value); } // keys: op 37 subscriptions
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
	// the recorded exchange with the same URL shape, earliest first; one for the same path (the same
	// ids) wins, so a channel's page is not answered with another channel's
	path_of :: (u: string) -> string { // its placeholders as the ids they stand for
		q := find_index_from_left(u, #char "?");
		p := ifx q >= 0 then slice(u, 0, q) else u;
		sb: String_Builder;
		sb.allocator = temp;
		i := 0;
		while i < p.count {
			e := ifx p[i] == #char "<" then find_index_from_left(p, #char ">", i) else -1;
			if e < 0 {
				append(*sb, p[i]);
				i += 1;
				continue;
			}
			append(*sb, r_unscrub(etf.vstring(slice(p, i, e + 1 - i))).s);
			i = e + 1;
		}
		return builder_to_string(*sb,, temp);
	}
	ri := -1;
	for r.events {
		if r.used[it_index] || fstr(it, "k") != "req" || r_key(fstr(it, "method"), fstr(it, "url")) != key continue;
		if ri < 0 ri = it_index;
		if path_of(fstr(it, "url")) == path_of(url) {
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
				ok, timing := r_ready_timing(body);
				if ok r.ready_seen, r.ready_timing = true, timing;
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

// launch: stop before the session (no READY; r_launch plays the launch).
replay_begin :: (run: *Replay_Run, t: *T, scenario: string, guild: Snowflake, channel: Snowflake, acct := "a", ready_from := "", launch := false) -> bool {
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
	run.c.promo.quest_roundtrip_sample, run.c.promo.render_delay_sample = 0, 0; // quest_decision_roundtrip, quest_bar_render_delay too
	identity_set_app_state(*run.c.id, recorded_app_state(run.r.events));
	client_start(run.c);
	if launch return true;
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
	// the session's Shop marketing, loaded READY + 2 s (startup loads are off here)
	for e: run.r.events {
		v, ok := r_body_value(vget(e, "body"));
		version := fint(fmap(fmap(vmap(v), "marketings"), "0"), "version");
		if fstr(e, "k") == "resp" && ok && version { atomic_store(*run.c.promo.shop_version, version); break; }
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
// recorded_app_state: whether the recorded window had focus when the actions began (client_app_state of
// the last /science event before the first mark that is not a setup): the 0.0.419 instances ran behind
// other windows, the 0.0.420 ones in front.
recorded_app_state :: (events: []etf.Map) -> App_State {
	state := App_State.Unfocused;
	for e: events {
		k := fstr(e, "k");
		if k == "mark" && !begins_with(fstr(e, "name"), "setup") break;
		if k != "req" || !r_is_science(fstr(e, "url")) continue;
		body, _ := r_body_value(vget(e, "body"));
		for ev: flist(vmap(body), "events") {
			s := fstr(fmap(vmap(ev), "properties"), "client_app_state");
			if s state = ifx s == "focused" then .Focused else .Unfocused;
		}
	}
	return state;
}

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
	array_add(*all, ..R_DRIVER);
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
	// header order: every batch of ours against the official window's (no x-science-test after the
	// first batch of a launch: a window with that batch compares the rest with its second)
	for ours {
		o := ifx official then official[0].wire else "";
		if it_index > 0 && official.count > 1 && contains(o, "x-science-test") o = official[1].wire;
		if o != "" && it.wire != o {
			print_to_builder(diffs, "  ~ wire     POST /science\n      official: %\n      ours:     %\n", o, it.wire);
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
// every window allows these (replay_check). No fake engagement with sponsored content
// (AGENTS.md): quest_hover / quest_hover_off (the capture driver's mouse path crossing the
// quests entry point) and the quest bar's viewability impressions, quest_content_loaded / _viewed /
// _view_time (0.0.420's launches render the bar with a served quest).
R_SCI_NEVER :: string.["science:quest_hover", "science:quest_content"];

// R_LAUNCH_TIMERS: requests on the launch's own timers, which the offline replay does not run
// (disable_startup) and which fall into an action window when the capture driver reached it early:
// the ads decision (get-decisions, READY + 3-11 s in the 0.0.420 captures) and the settings-proto/2
// lazy load and its first frecency write (READY + 5-12 s).
R_LAUNCH_TIMERS :: string.["get-decisions", "settings-proto/2"];

// The DM list's Nitro row (0.0.420: a "2 weeks free" offer) prefetches subscriptions, payment
// sources and storefront promotions when the capture driver's mouse crosses it; fastcord draws no
// Nitro row (AGENTS.md: no ads). Allowed where the capture crossed it.

// R_DRIVER: what the capture driver's mouse path causes on its way to a target, in any window:
// image_hovered when it crosses an image (fastcord's app does not report image hovers yet).
R_DRIVER :: string.["science:image_hovered"];

// r_refocus: the capture's window lost focus and got it back (the capture driver), which
// restarts AdSessionStore's heartbeat: account_edits has one in username_typing and one 21.6 s
// later in username_taken_check.
r_refocus :: (run: *Replay_Run) {
	client_set_focused(run.c, false);
	client_set_focused(run.c, true);
}

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
	replay_check(*run, "send_message", R_LAUNCH_TIMERS);
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
			// whether the official UI had shown the quick reactions (the hover toolbar) since the load is
			// not in the traffic: the write's computed reaction frecencies say it
			for news[Frecency_Kind.Reaction] if it.frecency != -1 f.reactions_read = true;
			got := base64_encode(cast(string) frecency_delta(*f, now));
			expectf(t, got == patch, "%/%: PATCH at % differs\n  official: %\n  ours:     %", scenario, acct, fnum(e, "t"), patch, got);
			checked += 1;
		}
	}
	expectf(t, checked == 13, "% PATCHes checked", checked);
}

// Pending frecency usage outlives the launch (the stores persist pendingUsages), so the next
// launch's startup run loads the proto and writes it, as every official launch does (GET at
// READY + 0-10 s, the PATCH right after its response). Channel selects alone don't load it.
// write_file_atomic replaces a file that exists (Windows' MoveFileW refused to) and leaves no .tmp.
file_atomic_replace :: (t: *T) {
	dir := "build/test_file_atomic";
	make_directory_if_it_does_not_exist(dir, recursive = true);
	path := tprint("%/f", dir);
	expect(t, write_file_atomic(path, cast([]u8) "old") && write_file_atomic(path, cast([]u8) "new"), "both writes succeed");
	got, ok := read_entire_file(path,, temp);
	expect(t, ok && got == "new", "the second write replaced the file");
	expect(t, !File_Utilities.file_exists(tprint("%.tmp", path)), "no .tmp left behind");
}

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
	replay_check(*run, "typing", string.["/typing", "get-decisions", "settings-proto/2"]); // and R_LAUNCH_TIMERS
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
	r_react_via_menu(*run, msg, "fastcord", int.[2]); // typed without a 300 ms rest: one results view
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

// A send marked failed whose MESSAGE_CREATE echo comes late is replaced by it, not shown twice.
failed_send_echo :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "add_reaction", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	c := run.c;
	l := message_list(*c.store, R_TEXT);
	before := l.messages.count;
	nonce: Snowflake = 1564300000000000999;
	m: Message;
	m.id, m.failed = nonce, true;
	m.channel_id, m.author_id = R_TEXT, c.store.me;
	m.nonce = clone_str(snowflake_string(nonce), c.store.allocator);
	insert_message(l, m);
	d, _ := etf.from_json(tprint("{\"id\":\"%\",\"channel_id\":\"%\",\"nonce\":\"%\",\"content\":\"late\",\"author\":{\"id\":\"%\",\"username\":\"me\"},\"type\":0}", nonce + 1, R_TEXT, nonce, c.store.me),, temp);
	upsert_message(*c.store, vmap(d));
	expect_value(t, l.messages.count, before + 1);
	expect(t, message_index(l, nonce + 1) >= 0 && message_index(l, nonce) < 0, "the echo replaced the failed copy");
}

// A jump to an old message (around=) shows that stretch alone, behind a gap (hasMoreAfter), not merged
// into the loaded present; newer pages (after=) close the gap when short or when they reach the present,
// and Jump to Present drops the stretch.
// The disk cache is trimmed to three quarters of its cap, the files written longest ago first.
cache_trimmed :: (t: *T) {
	dir := "build/cache_trim_test";
	delete_directory(dir);
	make_directory_if_it_does_not_exist(dir, recursive = true);
	kb := NewArray(1024, u8,, temp);
	for 0..9 {
		write_entire_file(tprint("%/%.body", dir, it), kb.data, kb.count);
		sleep_milliseconds(15); // distinct modification times
	}
	cache_trim(dir, 8 * 1024);
	left := File_Utilities.file_list(dir,, temp);
	expect_value(t, left.count, 6);
	expect(t, File_Utilities.file_exists(tprint("%/9.body", dir)) && !File_Utilities.file_exists(tprint("%/0.body", dir)), "the oldest go first");
	cache_trim(dir, 8 * 1024);
	expect_value(t, File_Utilities.file_list(dir,, temp).count, 6);
}

// Content-Encoding: a chain past two codings (nested decompression bombs) is refused before decoding.
content_encoding_chain :: (t: *T) {
	r: http.Response;
	array_add(*r.headers, .{"content-encoding", "gzip, gzip, gzip"});
	expect(t, http.decode_body(*r) == .Unsupported_Encoding, "three codings are refused");
	r.headers[0].value = "identity";
	expect(t, http.decode_body(*r) == .None, "identity is a no-op");
}

// Media privacy: Discord's media loads only from Discord's hosts (and the GIF picker's Tenor).
media_hosts :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "add_reaction", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	c := run.c;
	for string.["cdn.discordapp.com", "media.discordapp.net", "images-ext-1.discordapp.net", "discord.com", "media.tenor.com"]
		expect(t, media_host_ok(c, it), tprint("% loads", it));
	for string.["evil.example", "discord.com.evil.example", "notdiscordapp.net", "i.imgur.com", "tenor.com.evil"]
		expect(t, !media_host_ok(c, it), tprint("% is refused", it));
	status := media_get(c, "https://evil.example/pixel.png", .Image, true, "");
	expect_value(t, status, 0);
}

// Any server's member list ops: negative and huge indexes and ranges change nothing out of bounds.
member_list_hostile :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "add_reaction", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	s := *run.c.store;
	item :: "{\"member\":{\"user\":{\"id\":\"5\",\"username\":\"x\"}}}";
	for string.[
		tprint("{\"op\":\"SYNC\",\"range\":[-5,10],\"items\":[%]}", item),
		tprint("{\"op\":\"SYNC\",\"range\":[1000000000000,1000000000099],\"items\":[%]}", item),
		tprint("{\"op\":\"INSERT\",\"index\":-3,\"item\":%}", item),
		"{\"op\":\"INVALIDATE\",\"range\":[-100,5]}",
		"{\"op\":\"UPDATE\",\"index\":-1,\"item\":{}}",
		"{\"op\":\"DELETE\",\"index\":99999}",
		tprint("{\"op\":\"SYNC\",\"range\":[0,1],\"items\":[%,%]}", item, item),
	] {
		v, _ := etf.from_json(tprint("{\"guild_id\":\"%\",\"id\":\"everyone\",\"ops\":[%]}", R_GUILD, it),, temp);
		apply_member_list_update(s, v.map);
	}
	n := 0;
	for s.member_lists n += it.items.count;
	expect_value(t, n, 2);
}

history_gap :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "add_reaction", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	c := run.c;
	l := message_list(*c.store, R_TEXT);
	present := l.messages.count;
	if !expect(t, present > 0, "the scenario loads messages") return;
	page :: (first: Snowflake, n: int) -> V {
		sb: String_Builder;
		append(*sb, "[");
		for i: 0..n - 1 print_to_builder(*sb, "%{\"id\":\"%\",\"channel_id\":\"%\",\"content\":\"old\",\"author\":{\"id\":\"1\",\"username\":\"a\"},\"timestamp\":\"\",\"type\":0}", ifx i then "," else "", first + cast(Snowflake) i * (1 << 22), R_TEXT);
		append(*sb, "]");
		v, _ := etf.from_json(builder_to_string(*sb,, temp),, temp);
		return v;
	}
	start := l.messages[0].id - (cast(Snowflake) 1_000_000 << 22); // well before the loaded history
	r := Feature_Result.{op = .Around, tag = start + 15 * (1 << 22), channel_id = R_TEXT, ok = true, body = page(start, 30)};
	apply_around(c, *r);
	expect_value(t, messages_get(*c.store, R_TEXT).count, 30);
	expect_value(t, l.gap_after, start + 29 * (1 << 22));
	expect(t, l.has_more_before, "older messages remain before the stretch");
	// a full newer page moves the gap, a short one closes it
	e := Event.{data = page(start + 30 * (1 << 22), 50), result = .{op = .Fetch_Messages, ok = true, channel_id = R_TEXT, limit = 50, after = l.gap_after}};
	client_apply_rest(c, *e);
	expect_value(t, messages_get(*c.store, R_TEXT).count, 80);
	expect_value(t, l.gap_after, start + 79 * (1 << 22));
	e = .{data = page(start + 80 * (1 << 22), 3), result = .{op = .Fetch_Messages, ok = true, channel_id = R_TEXT, limit = 50, after = l.gap_after}};
	client_apply_rest(c, *e);
	expect_value(t, l.gap_after, 0);
	expect_value(t, messages_get(*c.store, R_TEXT).count, present + 83);
	// another jump, then Jump to Present: only the present stays
	r.body = page(start - (cast(Snowflake) 1000 << 22), 30);
	r.tag = start - (cast(Snowflake) 1000 << 22) + 15 * (1 << 22);
	apply_around(c, *r);
	expect_value(t, messages_get(*c.store, R_TEXT).count, 30);
	expect_value(t, l.messages.count, present + 83 + 30);
	drop_jumped_stretch(*c.store, l);
	expect_value(t, l.gap_after, 0);
	expect_value(t, messages_get(*c.store, R_TEXT).count, present + 83);
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
	replay_check(*run, "open_gif_picker", R_LAUNCH_TIMERS);
}

parity_status_change :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "status_change", 0, 0) { return; }
	replay_mark(*run);
	open_account_popout(run.c);
	replay_settle(*run, 600);
	replay_check(*run, "open_status_menu", string.["get-decisions", "settings-proto/2", "/billing/payment-sources", "/billing/subscriptions", "/storefront/promotions"]); // R_LAUNCH_TIMERS, the Nitro row
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
	r_voice_connect(*run, R_AIRPODS);
	r_frecency_run(*run); // writes the voice channel too (VOICE_CHANNEL_SELECT)
	replay_settle(*run, 900);
	// op 4 preferred_region(s) come from the live RTC probe; settings-proto/2: the frecency write
	// timer had not fired by the window's end officially (R_LAUNCH_TIMERS)
	replay_check(*run, "join_voice", string.["op 4", ".client_rtc_state", "settings-proto/2"]);
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
	// science: the web-vitals INP metric the official renderer reports now and then (no web page here);
	// the speech the capture's microphone picked up (0.0.420's: under 1000 ms, a start_speaking as it left)
	replay_check(*run, "leave_voice", string.["science:app_web_perf_startup_metrics", "science:start_speaking", "science:voice_disconnect"]);
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
	replay_check(*run, "close_dm", R_LAUNCH_TIMERS);
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
	// whose authors are not members of the new guild here. Batching: where the flush falls against
	// GUILD_CREATE varies by capture (0.0.419: nuo_transition 62 ms after it, alone; 0.0.420: 150 ms,
	// with the new guild's render)
	replay_check(*run, "create_guild_submit", string.["op 8", "science:batching"]);
}

parity_start_group_dm :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "start_group_dm", 0, 0) { return; }
	replay_mark(*run);
	group_dm_picker_opened(run.c, Gdm_Entry.{"New Group DM", "Friends List"}, 0, 2);
	replay_settle(*run, 300);
	create_group_dm(run.c);
	replay_settle(*run, 500);
	// the new DM is opened by the app; the launch timers (R_LAUNCH_TIMERS) are not this action
	replay_check(*run, "start_group_dm", string.["/messages?limit", "op 13", "get-decisions", "settings-proto/2"]);
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

// The launch's /quests/decision serves a quest (quest_served, setup): quest_decision_received,
// then the unshown quest bar's collapsed render (its logotype, quest_bar_mode_changed with the
// decision's ad ids, its hero art). Only that is compared: the rest of the window is the launch.
// quest_served is upload_custom_emoji as recorded on 0.0.419, the only capture that drew a quest.
parity_quest_decision :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "quest_served", R_GUILD, R_TEXT) { return; }
	allow: [..]string;
	allow.allocator = temp;
	for e: replay_window(*run.r, "setup") {
		k, url := fstr(e, "k"), fstr(e, "url");
		if k == "ws_send" array_add(*allow, tprint("op %", fnum(e, "op")));
		if k != "req" continue;
		if !r_is_science(url) {
			if !contains(url, "/quests/decision") && !contains(url, "cdn.discordapp.com/quests/") array_add(*allow, r_key(fstr(e, "method"), url));
			continue;
		}
		bv, _ := r_body_value(vget(e, "body"));
		for ev: flist(vmap(bv), "events") {
			type := fstr(vmap(ev), "type");
			if !begins_with(type, "quest_") array_add(*allow, tprint("science:%", type));
		}
	}
	replay_mark(*run);
	for e: STARTUP_REQUESTS if begins_with(e.path, "/quests/decision?") { // the launch's request
		j := job_new(.Api, .Startup);
		j.method = "GET";
		j.path = job_str(j, startup_expand(run.c, e.path));
		j.context_b64 = job_str(j, context_b64(e.ctx_json));
		job_submit(run.c, j);
	}
	replay_pump(*run, 700);
	replay_settle(*run, 300);
	replay_check(*run, "setup", allow, keep = true);
	defer replay_end(*run);

	// useQuestBarFetch's 30 s check once the decision outlived its TTL (bundle, no capture)
	c, b := run.c, *run.c.promo.bar;
	expire :: (b: *Quest_Bar) {
		locks.lock(*b.mu);
		b.fetched_at, b.check_at = now_ms() - b.ttl_ms - 1, now_ms();
		locks.unlock(*b.mu);
	}
	sci :: (run: *Replay_Run, type: string, key: string) -> string {
		locks.lock(*run.r.mu);
		defer locks.unlock(*run.r.mu);
		for b: run.r.science for e: b.events if e.type == type for e.keys if it == key return copy_string(e.consts[it_index],, temp);
		return "-";
	}
	// unfocused: the decision is cleared, which unmounts the shown bar (mode null), and nothing is fetched
	client_set_focused(c, false);
	replay_mark(*run);
	expire(b);
	replay_pump(*run, 200);
	expect_value(t, sci(*run, "quest_bar_mode_changed", "previous_mode"), "\"collapsed\"");
	expect_value(t, sci(*run, "quest_bar_mode_changed", "mode"), "null");
	expect_value(t, sci(*run, "quest_bar_mode_changed", "is_targeted"), "false");
	expect_value(t, run.r.ours.count, 0);
	// focused: /quests/@me, then the decision again ("questBar-interval"); it serves nothing now
	client_set_focused(c, true);
	c.promo.quest_roundtrip_sample = 1;
	replay_mark(*run);
	expire(b);
	replay_pump(*run, 400);
	locks.lock(*run.r.mu);
	keys: [..]string;
	keys.allocator = temp;
	for run.r.ours if !contains(it.key, "/science") array_add(*keys, copy_string(it.key,, temp));
	locks.unlock(*run.r.mu);
	expect_value(t, join(..keys, separator = " | ",, temp), "GET discord.com/api/v9/quests/@me | GET discord.com/api/v9/quests/decision?placement&client_heartbeat_session_id&client_ad_session_id");
	expect_value(t, sci(*run, "quest_decision_roundtrip", "caller_source"), "\"questBar-interval\"");
	expect_value(t, sci(*run, "quest_decision_roundtrip", "transition_case"), "\"no_serve_to_no_serve\"");
	expect_value(t, sci(*run, "quest_decision_roundtrip", "previous_ad_request_id"), "null");
	expect_value(t, sci(*run, "quest_decision_received", "caller_source"), "-");
}

// Edit Profiles' empty fields preload one random Shop item each (settings, open_profiles): with the
// picks the capture drew, the URLs and their order are the official ones. The categories answer
// is not in the fixture (3 MB): tests/data/collectibles_categories.json is that answer cut to five
// categories, including the picked products. The picks and URLs are 0.0.419's open_profiles.
editor_previews :: (t: *T) {
	OFFICIAL :: #string END
https://cdn.discordapp.com/media/v1/collectibles-shop/1511111194394628196/static
https://cdn.discordapp.com/media/v1/collectibles-shop/1341506443701911552/animated
https://cdn.discordapp.com/media/v1/collectibles-shop/9f583302ac845847cc100f6cd6821d503d8bf150621246be0e4311dc751b3f3c
https://cdn.discordapp.com/media/v1/collectibles-shop/1551750280960286770/1551750347515633674/static
https://cdn.discordapp.com/media/v1/collectibles-shop/1551750280960286770/1551750351496159263/static
https://cdn.discordapp.com/media/v1/collectibles-shop/1551750280960286770/1551750355585335366/static
https://cdn.discordapp.com/media/v1/collectibles-shop/1551750280960286770/1551750358945243236/static
END
	text, ok := read_entire_file("tests/data/collectibles_categories.json",, temp);
	if !expect(t, ok, "test data") return;
	body, _ := etf.from_json(text,, temp);
	lists := editor_preview_items(body);
	expectf(t, lists[0].count == 7 && lists[1].count == 9 && lists[2].count == 4 && lists[3].count == 1, "item lists % % % %", lists[0].count, lists[1].count, lists[2].count, lists[3].count);
	picked := Snowflake.[1511111194394628196, 1341506443701911552, 0, 1551750280960286770]; // by field: nameplate, decoration, effect (by its thumbnail), frame
	ours: [..]string;
	ours.allocator = temp;
	for type, i: int.[2, 0, 1, 3] {
		for item: lists[type] {
			sku := fsnow(item, "sku_id");
			if sku != picked[i] && !(type == 1 && contains(fstr(item, "thumbnailPreviewSrc"), "9f583302ac84")) continue;
			array_add(*ours, ..editor_preview_urls(item, type));
			break;
		}
	}
	expect_value(t, join(..ours, separator = "\n",, temp), trim(OFFICIAL));
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
	for e: replay_window(*run.r, "b_sends") { // the app shows it as a desktop notification (no badge: focused)
		if fstr(e, "k") != "ws_recv" || fstr(e, "ev") != "MESSAGE_CREATE" { continue; }
		d := fmap(e, "d");
		analytics_notification_shown(run.c, fsnow(d, "id"), fsnow(d, "channel_id"), fsnow(fmap(d, "author"), "id"), fint(d, "type"), false);
	}
	replay_settle(*run, 300);
	replay_mark(*run);
	select_channel(run.c, R_GUILD, R_TEXT, 10, prefetch = true);
	replay_settle(*run, 600);
	replay_check(*run, "open_unread_channel", science_only = true);
}

parity_open_dm :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "open_dm", 0, 0) { return; }
	// UserAffinitiesV2Store is persisted (stale after 8 h): A's last load predates this recording,
	// whose user_profile_action carries B's values
	table_set(*run.c.affinities.users, R_B, .{copy_string("0.05814961535556656",, run.c.allocator), 1});
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
	// 0.0.420's capture tracked no keybind when Escape closed our own profile's popout here, though
	// it did closing B's (friend_nickname) and other layers: not explained by the capture, kept as is
	replay_check(*run, "close_profile_popout", string.["science:keyboard_shortcut_used"], science_only = true);
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
	select_channel(run.c, 0, R_DM, 10); // the DM list mounts with its Shop entry
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
	analytics_friends_list(run.c, "friends_list_viewed", .Add_Friend);
	replay_settle(*run, 300);
	// the prelude's click on the Online tab went out 6 ms after the mark
	replay_check(*run, "friend_request_send", string.["science:friends_list_clicked/tab_opened=\"ONLINE\""], science_only = true);
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
	replay_check(*run, "open_guild_menu", string.["status.discord.com", "get-decisions", "settings-proto/2"], keep = true); // and R_LAUNCH_TIMERS
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
	run.c.affinities.fetched_ms = now_ms(); // B's persisted last attempt (its 404) is recent
	// the session's quests (applications/public on the home surface)
	q := job_new(.Api, .Startup);
	q.method = "GET";
	q.path = "/quests/@me";
	job_submit(run.c, q);
	replay_settle(*run, 300);
	replay_mark(*run);
	r_leave(*run);
	// applications/public: 0.0.420's /quests/@me answer is over the fixture's 256 KiB body limit
	// (stored as a hash), so the quests' applications are not known offline
	replay_check(*run, "b_leave_confirm", string.["applications/public"]);
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
		res := join_invite(j.c, "https://discord.gg/85mC4E6zH", temp); // the code the capture created
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
	// messages?before: our viewport fill of the joined channel (the official one was full; the rendered
	// heights decide it, not modelled offline)
	replay_check(*run, "b_join_submit", string.["/messages?before"]);
}


// Staged attachments: each staged file uploads at once; spoiler / modify send nothing;
// the trash deletes the uploaded file once (no retry after the capture's 429); Send posts
// the message with is_spoiler / description / the renamed filename.
parity_upload_options :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "upload_options", R_GUILD, R_TEXT) { return; }
	png, ok := read_entire_file("tests/scenarios/assets/test.png");
	if !expect(t, ok) { return; }
	defer free(png);
	c := run.c;

	replay_mark(*run);
	h1 := upload_draft(c, R_TEXT, "test.png", "image/png", cast([]u8) png, "file_picker");
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
	h2 := upload_draft(c, R_TEXT, "fastcord_test.png", "image/png", cast([]u8) png, "file_picker");
	replay_settle(*run, 900); // the PUT took 527 ms in the 0.0.420 capture
	replay_check(*run, "stage_second_file", keep = true);

	replay_mark(*run);
	upload_draft_remove(c, h2);
	replay_settle(*run, 500);
	replay_check(*run, "remove_second_file", keep = true);

	replay_mark(*run);
	send_message(c, R_TEXT, "", .{attachments = Draft_Attachment.[.{handle = h1, filename = "fc_renamed.png", description = "a small test image", spoiler = true}]});
	replay_dispatches(*run, "send_with_options", "MESSAGE_CREATE");
	replay_settle(*run, 600);
	replay_check(*run, "send_with_options", keep = true);

	replay_mark(*run);
	// the official paste was a PNG the WebP didn't shrink (insufficient_savings): so is this one
	small, sok := read_entire_file("tests/data/t_trns_gray.png");
	expect(t, sok);
	defer free(small);
	h3 := upload_draft(c, R_TEXT, "image.png", "image/png", cast([]u8) small, "clipboard");
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
	send_message(c, R_TEXT, "", .{attachments = Draft_Attachment.[.{handle = h3, filename = "image.png"}]});
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
	// messages?before: the official viewport filled up with an older page around the jump target (the
	// rendered heights of the channel's images decide it; not modelled offline)
	replay_check(*run, "inbox_jump_to_mention", string.["/messages?before"]);
}

// Threads browser on the recreated #general: every window in order.
parity_threads_browser :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "threads_browser", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	c := run.c;
	replay_mark(*run);
	fetch_channel_threads(c, R_TEXT, 0);
	track_thread_browser_open(c, R_TEXT);
	replay_settle(*run, 400);
	replay_check(*run, "open_threads_popout_empty", keep = true);

	replay_mark(*run);
	track_thread_creation_started(c, R_TEXT, "Thread Browser Toolbar");
	replay_settle(*run, 300);
	replay_check(*run, "create_thread_open", keep = true);

	replay_mark(*run);
	r_type(c, R_TEXT, "fastcord test thread");
	replay_pump(*run, 1700);
	replay_settle(*run, 300);
	// the official window also holds the ~8 s re-send, which is not waited for offline
	replay_check(*run, "create_thread_name", string.["/typing"], keep = true);

	// Enter: POST /threads; the reply (the thread) opens it and the first message goes out
	replay_mark(*run);
	create_thread(c, R_TEXT, "fastcord test thread", tag = 77);
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
	// parent for the thread, so returning renders it again. settings-proto/2: the frecency lazy load.
	replay_mark(*run);
	select_channel(c, R_GUILD, R_TEXT, 10);
	replay_settle(*run, 400);
	replay_check(*run, "close_thread_view", string.["settings-proto/2"], keep = true);

	// second open: active threads come from the gateway, no new search
	replay_mark(*run);
	track_thread_browser_open(c, R_TEXT);
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
	select_channel(c, R_GUILD, R_TEXT, 10);
	replay_settle(*run, 500);
	replay_check(*run, "delete_thread_confirm", keep = true);
}

// A thread opened from the threads popout as the main view: channel_opened with
// the thread properties, selected_guild_id and location (science only).
parity_thread_open_main :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "threads_browser", R_GUILD, R_TEXT) { return; }
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
	if !replay_begin(*run, t, "history_nav", R_GUILD, R_TEXT) { return; }
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
		track_back_forward(c, st.forward, ifx st.keybind then "keybind" else "nav_button");
		if st.forward { select_channel(c, 0, 0); } else { select_channel(c, R_GUILD, R_TEXT, 10); }
		replay_settle(*run, 400);
		// the prelude's Friends click went out 3 ms after the first mark; the renderer's web-vitals
		// INP metric (app_web_perf_startup_metrics) comes now and then (no web page here)
		replay_check(*run, st.window, string.["science:friends_list_clicked", "science:app_web_perf_startup_metrics"], keep = true);
	}
}

// The compass: the official client shows server discovery in the app
// (/discovery/servers); fastcord opens https://discord.com/servers in the
// browser, so the client sends none of it and never leaves the channel.
parity_discover :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "discover", R_GUILD, R_TEXT) { return; }
	defer replay_end(*run);
	replay_mark(*run);
	replay_settle(*run, 300);
	// science: the in-app discovery page's events (entry point, servers tab views, its
	// sidebar's exposure); fastcord's compass is a link to the web page, not that entry point
	replay_check(*run, "open_discover", string.["discoverable-guilds", "discovery/categories", "discovery-splashes", "/icons/", "science:global_discovery_", "science:experiment_user_evaluation_exposed/exposure_location=\"GlobalDiscoverySidebar\""], keep = true);
	replay_mark(*run);
	replay_settle(*run, 300);
	replay_check(*run, "leave_discover", keep = true);
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
	r_apply_features(*run, 600); // the DELETE's response (0.0.420's capture: 508 ms) before the next click
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
	replay_compare(*run, "open_create_channel", R_LAUNCH_TIMERS);
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
	if !replay_begin(*run, t, "settings", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	settings_pane_shown(run.c, .None, .Account, R_GUILD, R_TEXT);
	replay_pump(*run, 1500); // nothing more loads while the pane is open
	// science: the official settings modal's lazy-load spinner (impression variant
	// renderModalSpinner, absent from streamer_mode's identical open): its code-split
	// chunk loading, which fastcord has no counterpart for
	replay_check(*run, "open_settings", string.["science:impression_modal_root_legacy/variant=\"renderModalSpinner\""]);
}

parity_settings_open_profiles :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "settings", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	open_profile_editor(run.c);
	replay_settle(*run, 600);
	// not modelled: follow-ups driven by the profile's widget data
	replay_check(*run, "open_profiles", string.["applications/public", "/games?", "oauth2/tokens"]);
}

parity_settings_profile_save :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "settings", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	update_profile(run.c, "fc/test", "fastcord test bio");
	replay_settle(*run, 500);
	replay_check(*run, "profile_save");
}

parity_settings_display_name_save :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "settings", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	update_global_name(run.c, "Dingus Test", .Profile_Name);
	replay_settle(*run, 500);
	replay_check(*run, "display_name_save");
}

parity_settings_notifications :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "settings", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	settings_pane_shown(run.c, .Account, .Notifications, R_GUILD, R_TEXT);
	replay_settle(*run, 500);
	replay_check(*run, "open_notifications_settings");
}

parity_settings_appearance :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "settings", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	settings_pane_shown(run.c, .Notifications, .Appearance, R_GUILD, R_TEXT);
	replay_settle(*run, 500);
	replay_check(*run, "open_appearance");
}

parity_settings_theme_sync :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "settings", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	set_theme(run.c, .Dark, system = true); // "Sync with computer", OS dark
	replay_settle(*run, 400);
	replay_check(*run, "appearance_sync_on");
}

parity_settings_theme_dark :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "settings", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	set_theme(run.c, .Darker); // UI "Dark"
	replay_settle(*run, 400);
	replay_check(*run, "appearance_sync_off");
}

parity_settings_friend_online_toggle :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "streamer_mode", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	set_friend_online_notifications(run.c, false);
	replay_settle(*run, 400);
	replay_check(*run, "notifications_toggle_off");
	run2: Replay_Run;
	if !replay_begin(*run2, t, "streamer_mode", R_GUILD, R_TEXT) { return; }
	replay_mark(*run2);
	set_friend_online_notifications(run2.c, true);
	replay_settle(*run2, 400);
	replay_check(*run2, "notifications_toggle_on");
}

// Streamer Mode is local (science only); with it on, the Account pane shows an
// illustration and fetches nothing.
// r_user_offer: the fixture's launch billing/user-offer answer, as the startup job applies it.
r_user_offer :: (run: *Replay_Run) {
	id: s64 = -1;
	for run.r.events {
		if fstr(it, "k") == "req" && contains(fstr(it, "url"), "/billing/user-offer") id = fnum(it, "id");
		if fstr(it, "k") == "resp" && fnum(it, "id") == id { user_offer_loaded(run.c, vget(it, "body")); return; }
	}
}

parity_streamer_mode :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "streamer_mode", R_GUILD, R_TEXT) { return; }
	r_user_offer(*run); // the launch's trial offer (startup is off offline)
	replay_mark(*run);
	// the app: the switch, Streamer Mode on, and its notice bar on the guild route
	analytics_ui_setting(run.c, "streaming_enable_streamer_mode");
	analytics_streamer_mode_toggle(run.c, true, false);
	analytics_app_notice(run.c, "app_notice_viewed", "STREAMER_MODE", R_GUILD);
	replay_settle(*run, 300);
	replay_check(*run, "streamer_mode_on");
	run2: Replay_Run;
	if !replay_begin(*run2, t, "streamer_mode", R_GUILD, R_TEXT) { return; }
	replay_mark(*run2);
	settings_pane_shown(run2.c, .Appearance, .Account, R_GUILD, R_TEXT, streamer_mode = true);
	replay_settle(*run2, 300);
	replay_check(*run2, "streamer_view_account");
	run3: Replay_Run;
	if !replay_begin(*run3, t, "streamer_mode", R_GUILD, R_TEXT) { return; }
	replay_mark(*run3);
	settings_pane_shown(run3.c, .Notifications, .Appearance, R_GUILD, R_TEXT, streamer_mode = true);
	replay_settle(*run3, 300);
	replay_check(*run3, "open_settings_appearance");
}

// ---- friend nicknames, server nicknames, user menus (fixture friend_nickname) ----

parity_friend_nickname :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "friend_nickname", R_GUILD, R_TEXT) { return; }
	replay_mark(*run);
	open_user_context_menu(run.c, R_B, R_GUILD);
	replay_settle(*run, 500);
	replay_check(*run, "friend_nickname_open");
	run2: Replay_Run;
	if !replay_begin(*run2, t, "friend_nickname", R_GUILD, R_TEXT) { return; }
	replay_mark(*run2);
	set_friend_nickname(run2.c, R_B, "Bobby Nick");
	replay_settle(*run2, 400);
	replay_check(*run2, "friend_nickname_save");
	run3: Replay_Run;
	if !replay_begin(*run3, t, "friend_nickname", R_GUILD, R_TEXT) { return; }
	replay_mark(*run3);
	set_friend_nickname(run3.c, R_B, "");
	replay_settle(*run3, 400);
	replay_check(*run3, "friend_nickname_reset");
}

parity_server_nickname :: (t: *T) {
	run: Replay_Run;
	if !replay_begin(*run, t, "friend_nickname", R_GUILD, R_TEXT) { return; }
	open_user_context_menu(run.c, R_B, R_GUILD); // the first right-click (earlier window)
	replay_settle(*run, 400);
	replay_mark(*run);
	open_user_context_menu(run.c, R_B, R_GUILD);
	replay_settle(*run, 300); // the menu is open a moment before "Change Nickname"
	open_change_nickname(run.c);
	replay_settle(*run, 400);
	replay_check(*run, "server_nickname_open");
	run2: Replay_Run;
	if !replay_begin(*run2, t, "friend_nickname", R_GUILD, R_TEXT) { return; }
	replay_mark(*run2);
	set_server_nickname(run2.c, R_GUILD, R_B, "Server Bob");
	replay_settle(*run2, 400);
	replay_check(*run2, "server_nickname_save");
	run3: Replay_Run;
	if !replay_begin(*run3, t, "friend_nickname", R_GUILD, R_TEXT) { return; }
	replay_mark(*run3);
	set_server_nickname(run3.c, R_GUILD, R_B, "");
	replay_settle(*run3, 400);
	replay_check(*run3, "server_nickname_remove_save");
}

// ---- friend request from the DM row's menu (fixture friend_add_context_menu) ----

parity_friend_add_context_menu :: (t: *T) {
	run: Replay_Run;
	// A's side has no READY (the recording started on an open session, on #general): A's READY
	// from friend_request_send, where A and B weren't friends either
	if !replay_begin(*run, t, "friend_add_context_menu", R_GUILD, R_TEXT, ready_from = "friend_request_send") { return; }
	replay_mark(*run);
	select_channel(run.c, 0, 0); // the capture's navigation Home at the window start
	replay_settle(*run, 600);
	open_dm_row_menu(run.c, R_B);
	replay_settle(*run, 300);
	add_relationship(run.c, R_B, "ContextMenu");
	replay_settle(*run, 400);
	// the hover prefetch of the DM's messages, the session's settings-proto/2 load, and the Home
	// render's entitlements and Shop entry belong to the hover / route, not to the menu. 0.0.420 sent
	// no impression_dm_list_right_click_menu_shown here, though it did from Friends in close_dm. The
	// Home render's quests applications, affinities and list views follow the session state, which
	// the borrowed READY does not carry (this recording has no READY of A).
	replay_check(*run, "friend_request_from_dm_menu", string.["/messages?limit", "settings-proto/2", "/entitlements?", "science:dismissible_content_shown/type=\"COLLECTIBLES_SHOP_ENTRY_MARKETING\"", "science:impression_dm_list_right_click_menu_shown", "applications/public", "affinities/v2", "science:dm_list_viewed", "science:friends_list_viewed"]);
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
	// call message; settings-proto/2: the session's lazy load. The 0.0.420 capture ran after
	// join_voice_channel in the same capture session, whose voice exposures are remembered across
	// launches (none repeat here); where the shelf answers and the layout toggle fall against the
	// media engine's steps varies per capture.
	replay_check(*run, "start_call", string.["op 4", "/messages?before", "settings-proto/2", "science:experiment_user_evaluation_exposed", "science:experiment_installation_evaluation_exposed", "science:video_layout_toggled", "science:network_action_embedded_activities_fetch_shelf", "science:batching"]);
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
	replay_check(*run2, "b_join_from_ring", string.["op 4", "science:experiment_user_evaluation_exposed", "science:experiment_installation_evaluation_exposed", "science:video_layout_toggled", "science:network_action_embedded_activities_fetch_shelf", "science:batching"]);
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
	// voice_stream_ended (0.0.420, per stream on leaving a call with others: the media engine's send
	// and receive statistics) is not reported yet (TODO.md)
	replay_check(*run3, "a_hang_up", string.["science:voice_stream_ended"]);
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
	analytics_identify(c, false);
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

// session_start_client: GatewaySocket._doIdentify tracks it after every IDENTIFY the app sends,
// never after fast-connect.js's (is_fast_connect true) or a RESUME. Every start in these
// captures agrees: launches whose socket opened after the app took it over (typing ... the
// first send_dm), the re-IDENTIFY after open_dm's INVALID_SESSION, the login in account_edits.
session_start_identify :: (t: *T) {
	for sa: string.["typing a", "add_reaction a", "open_profile_popout a", "open_image_attachment a", "send_dm b", "send_dm a", "open_dm a", "account_edits a", "cold_start a", "send_message a"] {
		scenario, acct := slice(sa, 0, sa.count - 2), slice(sa, sa.count - 1, 1);
		r: Replay;
		if !replay_load(*r, scenario, acct) { expectf(t, false, "no fixture %", scenario); continue; }
		app, starts := 0, 0;
		for e: r.events {
			k := fstr(e, "k");
			if k == "ws_send" && fnum(e, "op") == 2 {
				fc := vget(fmap(fmap(e, "d"), "properties"), "is_fast_connect");
				if !(fc.kind == .Bool && fc.b) app += 1;
			}
			if k != "req" || !r_is_science(fstr(e, "url")) continue;
			bv, _ := r_body_value(vget(e, "body"));
			for ev: flist(vmap(bv), "events") if fstr(vmap(ev), "type") == "session_start_client" starts += 1;
		}
		expectf(t, starts == app, "%: % app IDENTIFYs, % session_start_client", sa, app, starts);
	}

	run: Replay_Run;
	if !replay_begin(*run, t, "typing", 0, 0) { return; }
	c := run.c;
	queued :: (c: *Client) -> string {
		a := *c.analytics;
		locks.lock(*a.mu);
		defer locks.unlock(*a.mu);
		s: [..]string;
		s.allocator = temp;
		for a.queue for type: string.["session_start_client", "gateway_connected"] {
			if begins_with(it, tprint("{\"type\":\"%\"", type)) array_add(*s, type);
		}
		return join(..s, " ",, temp);
	}
	url :: "wss://gateway.discord.gg";
	analytics_gateway_connected(c, 0, url, true, false, 160, 160); // after a RESUME
	expect_value(t, queued(c), "gateway_connected");
	analytics_identify(c, false); // on open, before HELLO: waits for the socket's gateway_connected
	expect_value(t, queued(c), "gateway_connected");
	analytics_gateway_connected(c, 0, url, true, false, 160, 160);
	expect_value(t, queued(c), "gateway_connected session_start_client gateway_connected");
	analytics_identify(c, true); // after INVALID_SESSION: at once
	expect_value(t, queued(c), "gateway_connected session_start_client gateway_connected session_start_client");
	replay_end(*run);
}

// ---- the launch burst (gateway.jai LAUNCH_*) ----

// Not this test's subject: what the startup requests send (off here: quest_decision_roundtrip,
// the later loads' events), and READY's experiment exposures, which the recorded instances had
// already sent in an earlier launch (persisted).
R_LAUNCH_ALLOW :: string.["science:fetch_user_offer_started", "science:notification_permission_status", "science:network_action_detectable_non_games_fetch", "science:network_action_detectable_applications_fetch", "science:experiment_user_evaluation_exposed", "science:experiment_installation_evaluation_exposed"];

// r_ready_timing: a /science body's ready_payload_received durations as [READY handled - identify
// start, identify start - connection start] (its three mixed-clock durations, combined).
r_ready_timing :: (body: V) -> bool, [2]float64 {
	for ev: flist(vmap(body), "events") {
		if fstr(vmap(ev), "type") != "ready_payload_received" continue;
		p := fmap(vmap(ev), "properties");
		id, conn, emit := vf64(vget(p, "duration_ms_since_identify_start")), vf64(vget(p, "duration_ms_since_connection_start")), vf64(vget(p, "duration_ms_since_emit_start"));
		return true, .[emit + id, conn - id];
	}
	return false, .[0, 0];
}

// r_launch plays a fixture's launch on the fixture's own timeline (ms after the socket's creation):
// its socket opens (at its app IDENTIFY when it took the app's path, else at 150 ms, before
// fast-connect.js ran), HELLO and READY arrive. The IDENTIFY and the window's telemetry are compared.
r_launch :: (t: *T, scenario: string, window: string, guild: Snowflake, channel: Snowflake, allow := "") {
	run: Replay_Run;
	if !replay_begin(*run, t, scenario, guild, channel, launch = true) return;
	c, g := run.c, run.c.gw;
	created, identify, hello, ready: float64 = -1, -1, -1, -1;
	fast := false;
	official_identify: string;
	for e: run.r.events {
		k, ts := fstr(e, "k"), vf64(vget(e, "t"));
		if k == "ws_open" && created < 0 created = ts;
		if k == "ws_send" && fnum(e, "op") == 2 && identify < 0 {
			identify = ts;
			official_identify = shape_text(vget(e, "d"));
			fc := vget(fmap(fmap(e, "d"), "properties"), "is_fast_connect");
			fast = fc.kind == .Bool && fc.b;
		}
		if k == "ws_recv" && fnum(e, "op") == 10 && hello < 0 hello = ts;
		if k == "ws_recv" && fstr(e, "ev") == "READY" && ready < 0 ready = ts;
	}
	if !expectf(t, created >= 0 && identify > created && hello > created && ready > hello, "% has no launch", scenario) { replay_end(*run); return; }
	at :: (ms: float64) -> s64 #expand { return `start + cast(s64) (ms - `created); }
	c.id.installation_id = copy_string("1100000000000000001",, c.allocator); // kept from the last session
	replay_mark(*run);
	start := now_ms();
	g.attempt_start = start;
	gateway_launch_begin(g);
	g.first_attempt = g.attempt_start;
	opened := ifx fast then 150 else at(identify) - start;
	replay_pump(*run, opened);
	gateway_launch_open(g, opened);
	expect(t, g.launch_fast == fast);
	replay_pump(*run, max(at(hello) - now_ms(), 0));
	analytics_gateway_connected(c, 0, GATEWAY_DEFAULT_URL, false, g.launch_fast, max(now_ms() - g.first_attempt, 0), max(now_ms() - g.attempt_start, 0));
	replay_pump(*run, max(at(ready) - now_ms(), 0));
	for e: run.r.events {
		if fstr(e, "k") == "ws_recv" && (fstr(e, "ev") == "READY" || fstr(e, "ev") == "READY_SUPPLEMENTAL") client_inject_dispatch(c, fstr(e, "ev"), vget(e, "d"));
	}
	replay_pump(*run, 1500);
	locks.lock(*run.r.mu);
	ours_identify: string;
	for run.r.sends if it.op == 2 { ours_identify = it.shape; break; }
	locks.unlock(*run.r.mu);
	expect_value(t, ours_identify, official_identify);
	// ready_payload_received's timings, played on the fixture's timeline: within 60 ms of the official
	official_ready: [2]float64;
	seen := false;
	for e: replay_window(*run.r, window) {
		if fstr(e, "k") != "req" || !r_is_science(fstr(e, "url")) continue;
		bv, ok := r_body_value(vget(e, "body"));
		if ok && !seen seen, official_ready = r_ready_timing(bv);
	}
	locks.lock(*run.r.mu);
	ours_seen, ours_ready := run.r.ready_seen, run.r.ready_timing;
	locks.unlock(*run.r.mu);
	if expect(t, seen && ours_seen, "ready_payload_received") {
		for 0..1 expectf(t, abs(ours_ready[it] - official_ready[it]) <= 60, "ready_payload_received % ms: official %, ours %", ifx it == 0 then "emit + identify" else "connection - identify", official_ready[it], ours_ready[it]);
	}
	all: [..]string;
	all.allocator = temp;
	array_add(*all, ..R_LAUNCH_ALLOW);
	if allow array_add(*all, allow);
	replay_check(*run, window, all, science_only = true);
}

// The socket opened after the app took it over (fixture typing, 566 ms after its creation): the
// app's IDENTIFY (AppSkeleton) and session_start_client, with the scripts' and takeover's telemetry
// on their own timeline.
// GUILD_POWERUP_PERKS_COACHMARK: a coachmark this launch showed once (1 of the 0.0.420 launches).
parity_launch_app :: (t: *T) {
	r_launch(t, "typing", "setup", R_GUILD, R_TEXT, "science:dismissible_content_shown/type=\"GUILD_POWERUP_PERKS_COACHMARK\"");
}

// The socket opened before fast-connect.js ran (fixture send_message): its IDENTIFY, then the
// app adopts the socket and handles the HELLO it kept.
// app_ui_viewed: this launch's app took the socket over later than the model's 490 ms (its render
// went out with the startup metric, READY + 88 ms; ours at takeover + 295 ms, just before READY);
// where the takeover falls in the launch race varies per capture.
parity_launch_fast :: (t: *T) {
	r_launch(t, "send_message", "setup", R_GUILD, R_TEXT, "science:app_ui_viewed");
}

// On Home (fixture cold_start) the app takes the socket over sooner and renders the Friends page
// after READY. The Shop entry's second dismissible_content_shown follows /collectibles-marketing,
// a startup request.
parity_launch_home :: (t: *T) {
	r_launch(t, "cold_start", "cold_start", 0, 0, "science:dismissible_content_shown/version=102");
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
	// science: the settings modal's lazy-load spinner (see parity_settings_open); account_edits is still
	// the 0.0.419 recording (its login cannot be re-run), before 0.0.420's member settings badge
	replay_check(*run, "open_account_settings", string.["science:impression_modal_root_legacy/variant=\"renderModalSpinner\"", "science:dismissible_content_shown/type=\"PINOT_MEMBER_SETTING_NEW_BADGE\""]);
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
	r_refocus(*run); // the window regained focus: the ad heartbeat the capture sent here
	replay_settle(*run, 300);
	// metrics/v2: the web client's performance metrics batch (wasm asset loads...)
	replay_check(*run, "username_typing", string.["metrics/v2"]);
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
	r_refocus(*run); // the window regained focus: the ad heartbeat the capture sent here
	replay_settle(*run, 300);
	replay_check(*run, "username_taken_check");
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
	vsu(c, R_TEXT); // moved
	expect_value(t, voice_followed(c, R_VOICE, *seen), R_TEXT);
	expect_value(t, c.voice_self.channel_id, R_TEXT);
	expect_value(t, voice_followed(c, R_TEXT, *seen), R_TEXT);
	vsu(c, 0); // disconnected by a moderator
	expect_value(t, voice_followed(c, R_TEXT, *seen), 0);
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
	expect(t, electron_user_agent("Windows NT 10.0; Win64; x64", WINDOWS_HOST) == "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) discord/1.0.9266 Chrome/152.0.7977.167 Electron/44.9.3 Safari/537.36");
	// Chromium's GREASE brand per major: 148 and 152 as captured.
	expect(t, sec_ch_ua("148.0.7778.280") == "\"Not/A)Brand\";v=\"99\", \"Chromium\";v=\"148\"" && sec_ch_ua("152.0.7977.167") == DEFAULT_PLATFORM.sec_ch_ua, "sec-ch-ua from the Chrome major");
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
			append_string(*resp.body, "{\"full\":{\"host_version\":[0,0,421],\"url\":\"x\"},\"metadata_version\":97100,\"required_update\":true}");
			return resp, .None;
		}
		if host == HOSTS_TABLE_HOST {
			resp := http.make_response(.Http2,, context.default_allocator);
			resp.status = 200;
			append_string(*resp.body, "{\"win\":{\"1.0.9300\":{\"electron\":\"1.2.3\",\"chrome\":\"1.0.0.0\"}},\"osx\":{\"0.0.420\":{\"electron\":\"44.9.3\",\"chrome\":\"152.0.7977.167\"},\"0.0.421\":{\"electron\":\"45.0.1\",\"chrome\":\"153.0.8000.12\"},\"0.0.422\":{\"electron\":\"x\",\"chrome\":\"153\"}}}");
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
		append_string(*resp.body, ifx begins_with(req.path, "/app?_=") then "<script>window.GLOBAL_ENV = {\"NODE_ENV\":\"production\",\"BUILD_NUMBER\":\"654001\",\"RELEASE_CHANNEL\":\"stable\"}</script>" else "{}");
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
	while (c.id.web_build == 0 || !c.id.host.version) && mono_ms() - start < 3000 sleep_milliseconds(5);
	expect_value(t, c.id.web_build, 654001);
	expect(t, c.id.host.version == "0.0.421" && c.id.host.native == 97100 && c.id.host.electron == "45.0.1" && c.id.platform.client_version == MAC_HOST_VERSION, "the updater's host waits for the next launch");
	expect(t, rec.manifest == tprint("/distributions/app/manifests/latest?install_id=%&channel=stable&platform=osx&arch=arm64&platform_version=27.0.1&client_version=%", c.id.updater_install_id, MAC_NATIVE_BUILD), "the updater's manifest check");
	install_id := copy_string(c.id.updater_install_id);
	defer free(install_id);
	expect_value(t, c.id.platform.client_build_number, 654001);
	locks.lock(*rec.mu);
	expect(t, rec.paths.count == 1 && rec.paths[0] == tprint("/app?_=%", c.launch_ms), "the launch's first request is /app?_=<Date.now()>");
	expect(t, rec.wire.count == 1 && rec.wire[0] == "upgrade-insecure-requests,user-agent,accept,sec-fetch-site,sec-fetch-mode,sec-fetch-user,sec-fetch-dest,accept-encoding,accept-language,priority", "navigation header order (netlog)");
	locks.unlock(*rec.mu);
	locks.lock(*c.job_mu);
	version_ok := false;
	for c.jobs if begins_with(it.path, "/assets/version.stable.json?_=") version_ok = it.not_before == c.launch_ms + APP_VERSION_CHECK_MS && it.path == tprint("/assets/version.stable.json?_=%", it.not_before / 300_000);
	locks.unlock(*c.job_mu);
	expect(t, version_ok, "version.stable.json queued 3.4 s after the document, with its 5-minute bucket");
	expect(t, contains(super_properties_json(*c.id, now_ms()), "\"client_build_number\":654001"), "super properties carry the page's build");
	identity_learn_build(*c.id, 654002, adopt = true);
	expect_value(t, c.id.platform.client_build_number, 654001); // sealed for the launch
	c.store.settings.locale = copy_string("fr",, c.allocator);
	client_poll(c);
	expect(t, c.id.platform.locale == "fr", "the language setting becomes x-discord-locale");
	client_destroy(c);
	c = client_create(.{token = "<token>", state_dir = dir, disable_startup = true, disable_gateway = true, disable_analytics = true, disable_remote_auth = true});
	expect_value(t, c.id.platform.client_build_number, 654002);
	expect(t, c.id.platform.locale == "fr", "the cached language is the boot locale");
	expect(t, c.id.platform.client_version == "0.0.421" && c.id.platform.browser_user_agent == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) discord/0.0.421 Chrome/153.0.8000.12 Electron/45.0.1 Safari/537.36", "the next launch runs the updated host");
	expect(t, c.id.platform.native_build_number == 97100 && c.id.platform.browser_version == "45.0.1" && c.id.platform.sec_ch_ua == "\"Chromium\";v=\"153\", \"Not_A Brand\";v=\"8\"", "with its native build, Electron and Chrome");
	expect(t, c.id.updater_install_id == install_id, "the updater's install id persists");
	client_destroy(c);
	free(rec.manifest);
	for rec.paths free(it);
	for rec.wire free(it);
	array_free(rec.paths);
	array_free(rec.wire);
}

// updater_wire: the native updater's manifest request, byte for byte as hyper wrote it (macOS 0.0.419 and
// Windows 1.0.9266 against a local NEW_UPDATE_ENDPOINT), and the package it fetches for a newer host.
updater_wire :: (t: *T) {
	b: String_Builder;
	b.allocator = temp;
	path := "/distributions/app/manifests/latest?install_id=3f1c9a52-7d4e-4b8a-9c21-5e6f0a1b2c3d&channel=stable&platform=osx&arch=arm64&platform_version=27.0.1&client_version=96312";
	expect(t, http.h1_serialize_request(*b, updater_request(UPDATER_HOST, path)) == .None, "serializes");
	expect(t, builder_to_string(*b,, temp) == tprint("GET % HTTP/1.1\r\naccept: */*\r\nuser-agent: Discord-Updater/1\r\naccept-encoding: gzip\r\nhost: updates.discord.com\r\n\r\n", path), "request line and headers in hyper's order");
	H :: "\"package_sha256\":\"4444444444444444444444444444444444444444444444444444444444444444\"";
	P :: "/distro/app/stable/osx/universal/0.0.420";
	U :: #run join("https://stable.dl2.discordapp.net", P);
	m, err := etf.from_json(join("{\"full\":{\"host_version\":[0,0,420],\"package_sha256\":\"11111111111111111111111111111111111111111111111111111111111111aa\",\"url\":\"", U, "/full.distro\"},\"deltas\":[{\"host_version\":[0,0,418],\"package_sha256\":\"2222222222222222222222222222222222222222222222222222222222222222\",\"url\":\"", U, "/from/0.0.418\"},{\"host_version\":[0,0,419],\"package_sha256\":\"3333333333333333333333333333333333333333333333333333333333333333\",\"url\":\"", U, "/from/0.0.419\"}],",
		"\"required_modules\":[\"discord_voice\",\"discord_utils\"],\"modules\":{",
		"\"discord_voice\":{\"full\":{\"host_version\":[0,0,420],\"module_version\":2,", H, ",\"url\":\"", U, "/discord_voice/2/full.distro\"},\"deltas\":[{\"host_version\":[0,0,419],\"module_version\":1,", H, ",\"url\":\"", U, "/discord_voice/2/from/0.0.419/1\"},{\"host_version\":[0,0,418],\"module_version\":1,", H, ",\"url\":\"", U, "/discord_voice/2/from/0.0.418/1\"}]},",
		"\"discord_utils\":{\"full\":{\"host_version\":[0,0,420],\"module_version\":1,", H, ",\"url\":\"", U, "/discord_utils/1/full.distro\"},\"deltas\":[]},",
		"\"discord_krisp\":{\"full\":{\"host_version\":[0,0,420],\"module_version\":1,", H, ",\"url\":\"", U, "/discord_krisp/1/full.distro\"},\"deltas\":[{\"host_version\":[0,0,419],\"module_version\":1,", H, ",\"url\":\"", U, "/discord_krisp/1/from/0.0.419/1\"}]},",
		"\"discord_ndi\":{\"full\":{\"host_version\":[0,0,420],\"module_version\":1,", H, ",\"url\":\"", U, "/discord_ndi/1/full.distro\"},\"deltas\":[]}}}",, temp),, temp);
	if !expect(t, err == .None, "manifest parses") return;
	version, pkgs := updater_packages(vmap(m), "0.0.419", .[]);
	if !expect(t, version == "0.0.420" && pkgs.count == 4, "the host and the installed modules: required, then ones installed on demand, not discord_ndi") return;
	expect(t, pkgs[0].host == "stable.dl2.discordapp.net" && pkgs[0].path == join(P, "/from/0.0.419",, temp) && pkgs[0].sha256[0] == 0x33, "the host's delta from the running host comes first");
	paths: [..]string;
	paths.allocator = temp;
	for 1..3 array_add(*paths, pkgs[it].path);
	expect(t, array_find(paths, join(P, "/discord_voice/2/from/0.0.419/1",, temp)) && array_find(paths, join(P, "/discord_utils/1/full.distro",, temp)) && array_find(paths, join(P, "/discord_krisp/1/from/0.0.419/1",, temp)), "each module's delta from the running host, else its full package");
	_, pkgs = updater_packages(vmap(m), "0.0.419", .[.{"discord_voice", 2}]);
	for pkgs if contains(it.path, "discord_voice") expect(t, ends_with(it.path, "/discord_voice/2/full.distro"), "no delta from an installed module version that isn't listed");
	_, pkgs = updater_packages(vmap(m), "0.0.417", .[]);
	expect(t, pkgs.count == 4 && pkgs[0].path == join(P, "/full.distro",, temp) && pkgs[0].sha256[31] == 0xaa, "else the full package");
	version, _ = updater_packages(vmap(m), "0.0.420", .[]);
	expect(t, version == "", "nothing for the host it runs");
	_, pkgs = updater_packages(vmap(m), "0.0.419", .[], "Windows");
	expect(t, pkgs.count == 4, "Windows installs krisp on demand too");
	u: Updater;
	updater_learn_modules(*u, vmap(m), "0.0.420");
	expect(t, u.modules.count == 4 && u.modules[0].name == "discord_voice" && u.modules[0].version == 2, "a manifest for the running host gives the installed module versions");
	for u.modules free(it.name,, context.default_allocator);
	array_free(u.modules);
	host, _ := https_url_parts("http://stable.dl2.discordapp.net/x");
	host2, _ := https_url_parts("https://stable.dl2.discordapp.net:8443/x");
	expect(t, host == "" && host2 == "", "only https on the default port");
}

// updater_schedule: the launch check, the splash's Backoff(1 s, 30 s) after failures, then hourly; a newer
// host's package is fetched through a hash with the updater's request shape, and once more if it is bad.
updater_schedule :: (t: *T) {
	expect(t, updater_backoff(0, 0) == 1000 && updater_backoff(0, 0.999) == 2998 && updater_backoff(20_000, 1) == 30_000 && updater_backoff(30_000, 0.5) == 30_000, "Backoff.fail with jitter");
	Rec :: struct { mu: locks.Mutex; status: int; calls: [..]string; headers_ok: bool; package_body: string; }
	rec := Rec.{headers_ok = true};
	rt :: (data: *void, host: string, req: http.Request) -> http.Response, http.Error {
		r := cast(*Rec) data;
		locks.lock(*r.mu);
		defer locks.unlock(*r.mu);
		array_add(*r.calls, join(host, req.path,, context.default_allocator),, context.default_allocator);
		r.headers_ok = r.headers_ok && req.headers.count == 4 && req.headers[1].value == "Discord-Updater/1" && req.headers[3].value == host;
		resp := http.make_response(.Http1_1,, context.default_allocator);
		resp.status = r.status;
		if host == UPDATER_HOST {
			hex: String_Builder;
			hex.allocator = temp;
			for crypto.sha256(cast([]u8) "package") print_to_builder(*hex, "%", formatInt(it, base = 16, minimum_digits = 2));
			h := builder_to_string(*hex,, temp);
			append_string(*resp.body, tprint("{\"full\":{\"host_version\":[0,0,421],\"package_sha256\":\"%\",\"url\":\"https://dl.example/full\"},\"deltas\":[{\"host_version\":[0,0,420],\"package_sha256\":\"%\",\"url\":\"https://dl.example/delta\"}],\"required_modules\":[\"discord_voice\"],\"modules\":{\"discord_voice\":{\"full\":{\"host_version\":[0,0,421],\"module_version\":1,\"package_sha256\":\"%\",\"url\":\"https://dl.example/voice\"},\"deltas\":[]}},\"metadata_version\":96400}", h, h, h));
		} else {
			append_string(*resp.body, r.package_body);
		}
		return resp, .None;
	}
	dir := "build/test_updater_state";
	file_delete(tprint("%/identity.tsv", dir));
	c := client_create(.{token = "<token>", state_dir = dir, disable_startup = true, disable_gateway = true, disable_analytics = true, disable_remote_auth = true, round_tripper = .{*rec, rt}});
	j := job_new(.Web, .Startup);
	rec.status = 503;
	t0 := now_ms();
	updater_run(c, j);
	expect(t, j.requeue && j.not_before >= t0 + 1000 && j.not_before <= now_ms() + 3000, "a failed check is retried in 1-3 s");
	c.updater.next_check_ms = 0;
	updater_run(c, j);
	expect(t, c.updater.backoff_ms >= 1000 && c.updater.backoff_ms <= 9000, "then backs off further");
	rec.status = 200;
	rec.package_body = "corrupt";
	c.updater.next_check_ms = 0;
	updater_run(c, j);
	n := 0;
	for rec.calls if it == "dl.example/delta" || it == "dl.example/voice" n += 1;
	expect(t, rec.calls.count == 7 && n == 4, "each bad package, host and module, is fetched twice");
	expect(t, c.updater.backoff_ms > 0 && !c.updater.fetched, "and the check fails");
	rec.package_body = "package";
	c.updater.next_check_ms = 0;
	t1 := now_ms();
	updater_run(c, j);
	expect(t, rec.calls.count == 10 && c.updater.fetched == "0.0.421" && c.updater.backoff_ms == 0, "the host's delta from 0.0.420 and the module come through");
	expect(t, j.not_before >= t1 + UPDATER_CHECK_MS && j.not_before <= now_ms() + UPDATER_CHECK_MS, "the next check in an hour");
	c.updater.next_check_ms = 0;
	updater_run(c, j);
	expect(t, rec.calls.count == 11, "fetched packages are not fetched again");
	expect(t, rec.headers_ok, "every request has the updater's headers");
	job_free(j);
	client_destroy(c);
	for rec.calls free(it,, context.default_allocator);
	array_free(rec.calls);
}

// ostls_client_hello: the OS library's ClientHello to a local listener equals the official updater's, captured
// with SNI "localhost" (macOS 0.0.419: SecureTransport; Windows 1.0.9266: SChannel), but for the random. Linux
// has no capture: its libssl's hello is only checked to be one.
ostls_client_hello :: (t: *T) {
	#if OS == .MACOS WANT :: "16030100a4010000a00303000000000000000000000000000000000000000000000000000000000000000000002c00ffc02cc02bc024c023c00ac009c008c030c02fc028c027c014c013c012009d009c003d003c0035002f000a0100004b0000000e000c0000096c6f63616c686f7374000a00080006001700180019000b00020100000d00120010040102010501060104030203050306030005000501000000000012000000170000";
	else #if OS == .WINDOWS WANT :: "16030300a00100009c03030000000000000000000000000000000000000000000000000000000000000000000024c02cc02bc030c02fc024c023c028c027c00ac009c014c013009d009c003d003c0035002f0100004f0000000e000c0000096c6f63616c686f7374000a00080006001d00170018000b00020100000d001a00180804080508060401050102010403050302030202060106030023000000170000ff01000100";
	else WANT :: "";
	l, lerr := netio.listen_tcp(0);
	if !expect(t, lerr == .None, "listens") return;
	Dial :: struct { port: int; err: ostls.Error; }
	d := Dial.{port = l.port};
	th := spawn(*d, (d: *Dial) {
		tcp, err := netio.dial_tcp("localhost", d.port);
		if err != .None { d.err = .Handshake; return; }
		s, terr := ostls.connect(netio.tcp_stream(tcp), "localhost");
		d.err = terr;
		if terr == .None netio.close(s);
	});
	conn, aerr := netio.accept_tcp(l);
	got: [..]u8;
	got.allocator = temp;
	if aerr == .None {
		s := netio.tcp_stream(conn);
		buf: [4096]u8;
		while got.count < 5 || got.count < 5 + ((cast(int) got[3]) << 8 | got[4]) {
			n, rerr := netio.read(s, buf);
			if rerr != .None break;
			array_add(*got, ..array_view(buf, 0, n));
		}
		netio.close(s);
	}
	locks.join(th);
	netio.close_listener(l);
	free(l);
	expect(t, d.err != .None, "the handshake stops at the listener");
	if !expect(t, got.count > 43 && got[0] == 0x16 && got[5] == 1, "a ClientHello") return;
	for 11..42 got[it] = 0;
	hex: String_Builder;
	hex.allocator = temp;
	for got print_to_builder(*hex, "%", formatInt(it, base = 16, minimum_digits = 2));
	if WANT expectf(t, builder_to_string(*hex,, temp) == WANT, "the official updater's ClientHello, got %", builder_to_string(*hex,, temp));
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

// tls_chrome_hello: our TCP ClientHello has Chrome 152's signature algorithms (a GREASE value, ML-DSA-44/65/87,
// then 148's list) by default, and exactly Chrome 148's when the host runs 148; the rest is the same in both.
tls_chrome_hello :: (t: *T) {
	be :: (h: []u8, p: int) -> int { return (cast(int) h[p]) * 256 + h[p + 1]; }
	// exts returns the number of extensions and signature_algorithms' body.
	exts :: (h: []u8) -> int, []u8 {
		if h.count < 39 return 0, .[];
		p := 39 + cast(int) h[38];
		p += 2 + be(h, p);
		p += 1 + cast(int) h[p];
		end := p + 2 + be(h, p);
		p += 2;
		count: int;
		sig: []u8;
		while p + 4 <= end && end <= h.count {
			n := be(h, p + 2);
			if be(h, p) == 13 sig = array_view(h, p + 4, n);
			count += 1;
			p += 4 + n;
		}
		return count, sig;
	}
	n152, sig152 := exts(tls.client_hello(.{alpn = .["h2", "http/1.1"], server_name = "discord.com", chrome_major = 152},, temp));
	n148, sig148 := exts(tls.client_hello(.{alpn = .["h2", "http/1.1"], server_name = "discord.com", chrome_major = 148},, temp));
	expect(t, n152 == 18 && n148 == 18, "18 extensions, two of them GREASE");
	if !expect(t, sig152.count == 26 && sig148.count == 18, "signature_algorithms") return;
	expect(t, (sig152[2] & 0x0f) == 0x0a && sig152[2] == sig152[3], "Chrome 152 leads with a GREASE value");
	expect(t, cast(string) array_view(sig152, 4) == cast(string) u8.[0x09, 0x04, 0x09, 0x05, 0x09, 0x06, 0x04, 0x03, 0x08, 0x04, 0x04, 0x01, 0x05, 0x03, 0x08, 0x05, 0x05, 0x01, 0x08, 0x06, 0x06, 0x01], "then ML-DSA and 148's list");
	expect(t, cast(string) array_view(sig148, 2) == cast(string) array_view(sig152, 10), "Chrome 148 sends just its list");
}

// quic_chrome_transport_params: Chrome 152 adds Google's connection options (0x3128) holding "ORIG"; 148 has none.
quic_chrome_transport_params :: (t: *T) {
	for major: int.[148, 152] {
		tp := quic.chrome_transport_params(1000, major,, temp);
		ids: [..]u64;
		ids.allocator = temp;
		orig := false;
		i := 0;
		while i < tp.count {
			id, ok := get_varint(tp, *i);
			n, ok2 := get_varint(tp, *i);
			if !expect(t, ok && ok2 && i + cast(int) n <= tp.count, "transport parameters parse") return;
			array_add(*ids, id);
			if id == 0x3128 orig = n == 4 && to_string(tp.data + i, 4) == "ORIG";
			i += xx n;
		}
		expectf(t, ids.count == 13 + cast(int) (major >= 152), "Chrome % sends % transport parameters", major, ids.count);
		expectf(t, orig == (major >= 152), "Chrome % connection options", major);
	}
}


// shouldNotify's channel rules (channel_notifies): mutes with their end, the channel > category > server
// level chain, voice chats, and Suppress @everyone / role @mentions.
notify_rules :: (t: *T) {
	s: Store;
	store_init(*s, temp);
	G, CAT, TXT, VC :: cast(Snowflake) 10, 11, 12, 13;
	NOW :: 1_000_000;
	table_set(*s.guilds, G, .{id = G, default_message_notifications = NOTIFY_ALL});
	table_set(*s.channels, CAT, .{id = CAT, kind = .Guild_Category, guild_id = G});
	table_set(*s.channels, TXT, .{id = TXT, kind = .Guild_Text, guild_id = G, parent_id = CAT});
	table_set(*s.channels, VC, .{id = VC, kind = .Guild_Voice, guild_id = G});
	n :: (s: *Store, cid: Snowflake, direct := false, everyone := false, open: Snowflake = 0) -> bool {
		return channel_notifies(s, G, cid, open, direct, everyone, .[], NOW);
	}
	expect(t, n(*s, TXT), "server default All Messages");
	expect(t, !n(*s, VC) && n(*s, VC, open = VC), "a voice chat's messages only while it is open");
	gs := ensure_settings(*s, G);
	ensure_override(gs, CAT).message_notifications = NOTIFY_MENTIONS;
	expect(t, !n(*s, TXT) && n(*s, TXT, direct = true), "the category's level");
	ensure_override(gs, TXT).message_notifications = NOTIFY_ALL;
	expect(t, n(*s, TXT), "the channel's own level wins");
	ensure_override(gs, TXT).message_notifications = NOTIFY_MENTIONS;
	gs.suppress_everyone = true;
	expect(t, !n(*s, TXT, everyone = true) && n(*s, TXT, direct = true), "suppressed @everyone");
	gs.suppress_everyone = false;
	expect(t, n(*s, TXT, everyone = true), "@everyone");
	o := ensure_override(gs, CAT);
	o.muted, o.mute_end_ms = true, NOW - 1;
	expect(t, n(*s, TXT, direct = true), "an expired category mute");
	o.mute_end_ms = NOW + 1;
	expect(t, !n(*s, TXT, direct = true), "a muted category silences mentions too");
	o.muted = false;
	gs.muted, gs.mute_end_ms = true, 0;
	expect(t, !n(*s, TXT, direct = true), "a muted server");
	gs.muted = false;
	ensure_override(gs, TXT).message_notifications = NOTIFY_NOTHING;
	expect(t, !n(*s, TXT, direct = true), "Nothing");
}
