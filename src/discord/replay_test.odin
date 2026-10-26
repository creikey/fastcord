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
import "core:strings"
import "core:testing"
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

// Requests the comparison leaves out: telemetry (unknowable values), UI assets
// and images the app fetches itself, the RTC probe and Cloudflare's page challenge.
@(private = "file")
R_IGNORE := [?]string{"/science", "/assets/", "collectibles-shop", "latency.discord.media", "/cdn-cgi/", "media.discordapp.net", "/app-icons/", "/emojis/", "/avatars/", "/stickers/", "images-ext"}

Replay :: struct {
	mu:      locks.Mutex,
	arena:   virtual.Arena,
	events:  [dynamic]etf.Map, // fixture lines (acct a), placeholders turned into ids
	used:    [dynamic]bool,
	ours:    [dynamic]Replay_Req,
	sends:   [dynamic]Replay_Send,
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
@(private = "file")
r_unscrub :: proc(v: V) -> V {
	#partial switch x in v {
	case string:
		if len(x) > 3 && x[0] == '<' && x[len(x) - 1] == '>' && strings.contains(x, ":") {
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
replay_load :: proc(r: ^Replay, scenario: string) -> bool {
	_ = virtual.arena_init_growing(&r.arena)
	context.allocator = virtual.arena_allocator(&r.arena)
	// appended to from worker threads later: keep them in the replay arena too
	r.ours = make([dynamic]Replay_Req)
	r.sends = make([dynamic]Replay_Send)
	data, err := os.read_entire_file(fmt.tprintf("traffic/%s.jsonl", scenario), context.allocator) // tests run from the repo root
	if err != nil do return false
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		v, perr := etf.from_json(line)
		if perr != .None do continue
		m := vmap(v)
		if a := fstr(m, "acct"); a != "" && a != "a" do continue
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

// ---- network stand-ins ----

@(private = "file")
replay_round_trip :: proc(data: rawptr, host: string, req: http.Request) -> (resp: http.Response, err: http.Error) {
	r := cast(^Replay)data
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
		// our wire order, as fc:http (h2) / fc:quic/h3 put it on the wire
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
		append(&r.ours, Replay_Req{strings.clone(key, alloc), strings.clone(strings.to_string(sb), alloc), strings.clone(shape, alloc)})
	}
	resp.version = .Http3 if proto == "h3" else .Http2
	resp.status = 200
	body := "{}"
	if ri >= 0 {
		id := fnum(r.events[ri], "id")
		for e in r.events {
			if fstr(e, "k") != "resp" || fnum(e, "id") != id do continue
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
	return resp, .None
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
	r: Replay,
	c: ^Client,
	t: ^testing.T,
}

@(private = "file")
replay_begin :: proc(run: ^Replay_Run, t: ^testing.T, scenario: string, guild, channel: Snowflake) -> bool {
	run.t = t
	if !replay_load(&run.r, scenario) {
		testing.expectf(t, false, "no fixture traffic/%s.jsonl", scenario)
		return false
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
	client_set_accessibility(run.c, A11Y_PREFERS_COLOR_SCHEME_LIGHT)
	identity_set_app_state(&run.c.id, .Unfocused)
	client_start(run.c)
	// session state from the fixture's READY
	for name in ([]string{"READY", "READY_SUPPLEMENTAL"}) {
		for e in run.r.events {
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
	return true
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

// replay_check compares our traffic since the mark with the official window.
// allow: keys / "op N" that may differ (known, documented gaps).
@(private = "file")
replay_check :: proc(run: ^Replay_Run, window: string, allow: []string = nil) {
	t := run.t
	defer {
		client_destroy(run.c)
		virtual.arena_destroy(&run.r.arena)
	}
	official := make([dynamic]etf.Map, context.temp_allocator)
	ops := make([dynamic]etf.Map, context.temp_allocator)
	for e in replay_window(&run.r, window) {
		switch fstr(e, "k") {
		case "req":
			if !r_ignored(fstr(e, "url")) do append(&official, e)
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
	locks.unlock(&run.r.mu)
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
		if wl, ok := vget(e, "wire").(etf.List); ok && fstr(e, "wire_src") == "netlog" {
			sb := strings.builder_make(context.temp_allocator)
			first := true
			for h in wl {
				n := strings.to_lower(vstr(vlist(h)[0]), context.temp_allocator)
				if n == "cookie" || n == "if-none-match" || n == "if-modified-since" do continue
				if !first do strings.write_byte(&sb, ',')
				first = false
				strings.write_string(&sb, n)
			}
			if w := strings.to_string(sb); w != ours[j].wire && !allowed(allow, key) {
				fmt.sbprintfln(&diffs, "  ~ wire     %s\n      official: %s\n      ours:     %s", key, w, ours[j].wire)
			}
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
	if len(diffs.buf) > 0 do testing.expectf(t, false, "window %q differs from the official client:\n%s", window, strings.to_string(diffs))
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
	open_message_context_menu(run.c, R_GUILD)
	open_emoji_picker(run.c, R_GUILD)
	replay_settle(&run, 200)
	add_reaction(run.c, R_TEXT, r_last_own(run.c, R_TEXT), "👍", 0, false, "Message Reaction Picker")
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
	open_message_context_menu(run.c, R_GUILD)
	replay_settle(&run, 200)
	delete_message(run.c, R_TEXT, r_last_own(run.c, R_TEXT))
	replay_settle(&run, 600)
	replay_check(&run, "delete_message")
}

@(test)
parity_edit_message :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "edit_message", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	open_message_context_menu(run.c, R_GUILD)
	replay_settle(&run, 200)
	edit_message(run.c, R_TEXT, r_last_own(run.c, R_TEXT), "this message was edited")
	replay_settle(&run, 600)
	replay_check(&run, "edit_message")
}

@(test)
parity_reply :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "reply", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	target := r_last_own(run.c, R_TEXT)
	open_message_context_menu(run.c, R_GUILD)
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
	open_profile_popout(run.c, run.c.store.me, R_GUILD)
	replay_settle(&run, 800)
	replay_check(&run, "open_profile_popout")
}

@(test)
parity_open_full_profile :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "open_full_profile", R_GUILD, R_TEXT) do return
	open_profile_popout(run.c, run.c.store.me, R_GUILD)
	replay_settle(&run, 600)
	replay_mark(&run)
	open_full_profile(run.c, run.c.store.me, R_GUILD)
	replay_settle(&run, 800)
	// not modelled: follow-ups driven by the profile's widget data (applications/public,
	// games, oauth2/tokens); the note is already loaded by the popout officially
	replay_check(&run, "open_full_profile", {"applications/public", "/games?", "oauth2/tokens", "/notes/"})
}

@(test)
parity_emoji_picker_reaction :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "emoji_picker_reaction", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	open_emoji_picker(run.c, R_GUILD)
	replay_settle(&run, 200)
	add_reaction(run.c, R_TEXT, r_last_own(run.c, R_TEXT), "🔥", 0, false, "Message Inline Button")
	replay_settle(&run, 600)
	replay_check(&run, "emoji_picker_reaction")
}

@(test)
parity_add_custom_reaction :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "add_custom_reaction", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	open_message_context_menu(run.c, R_GUILD)
	open_emoji_picker(run.c, R_GUILD)
	replay_settle(&run, 200)
	add_reaction(run.c, R_TEXT, r_last_own(run.c, R_TEXT), "fastcord_test", Snowflake(1564250154838528071), false, "Message Reaction Picker")
	replay_settle(&run, 600)
	replay_check(&run, "add_custom_reaction")
}

@(test)
parity_gif_send :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "gif_send", R_GUILD, R_TEXT) do return
	replay_mark(&run)
	gifs_trending(run.c)
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
	set_custom_status(run.c, {text = "testing fastcord", expires_at_ms = now_ms() + 24 * 3600 * 1000})
	replay_settle(&run, 400)
	replay_check(&run, "set_custom_status")
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
	replay_check(&run, "join_voice", {"op 4", "settings-proto/2"})
}

@(test)
parity_close_dm :: proc(t: ^testing.T) {
	run: Replay_Run
	if !replay_begin(&run, t, "close_dm", 0, 0) do return
	replay_mark(&run)
	open_message_context_menu(run.c, 0)
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
	create_guild(run.c, "Dingus Battle's serverfastcord test")
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
	create_group_dm(run.c)
	replay_settle(&run, 500)
	// the new DM is opened by the app; get-decisions is the ads timer, not this action
	replay_check(&run, "start_group_dm", {"/messages?limit", "op 13", "get-decisions"})
}
