// Fuzzing: jai build.jai - fuzz <target> [seconds], or `all`, or 0 seconds to only replay. Replays every file
// in tests/fuzz/<target>/ (seeds and past crashes, kept as regression tests), then runs new inputs until the
// time is up: mutations for the parsers, and for the generator targets fresh choices as well, since a run
// repeating old inputs finds less than the same time spent on new ones.
//
// What counts as a failure, past a crash on a bounds check:
//   - An oracle: a round trip that changes the value, or a broken invariant (`oracle`, exit 4).
//   - An input that runs past HANG_S; a watchdog thread sees real infinite loops too (exit 3).
//   - One allocation past MAX_ALLOC, the shape of every "a length field reserved 4 GB" bug (exit 5).
//   - On one input in FENCE_ONE_IN, chosen by its hash so a replay does the same, the heap is the fence
//     allocator: each block ends at an inaccessible page and freed blocks stay inaccessible, so overruns past
//     a raw pointer, use after free and double frees stop the run. Jai has no address sanitizer.
//
// `fuzz mem <target> [seconds]` is the same program with Basic's Memory_Debugger on, slower: it names the
// allocation and first free of a double free, reports leaks at the end, and overwrites temp when it resets,
// so what was kept past a reset reads garbage. The fence still catches what the debugger can't see, which
// is anything done through a raw pointer.
//
// Each input is copied to the mapped file build/fuzz_inputs/<target>.last first, which outlives the process
// without a write per input (8 bytes of length, then the input), and build.jai saves it under
// tests/fuzz/<target>/ when the run dies. Generator targets read their input as a stream of choices, so the
// byte mutator, the crash files and tools/fuzz_min.py all work on them unchanged. Changing a generator
// changes what its old crash files mean: they stay valid inputs, but may no longer reach the same bug.
//
// A run ends by printing how many inputs each parser accepted. A parser at 0% is a target that only tests
// its first length check, whatever the run count says: give it a better seed or a generator.
//
// `scale` runs each text parser on repeated openers at two sizes and fails on superlinear time.
#import "Basic"()(MEMORY_DEBUGGER = MEM_DEBUG, TEMP_ALLOCATOR_OVERWRITE_MEMORY = MEM_DEBUG);
#import "File";
#import "File_Utilities";
#import "Hash_Table";
#import "Random";
#import "String";
#import "System";
#import "Thread";
#import "Atomics";
#import "Base64";
altsvc :: #import "quic_altsvc";
authority :: #import "authority";
crypto :: #import "crypto";
dc :: #import "discord";
DAVE :: #import "voice_dave";
e2e :: #import "e2e";
sqlite :: #import "sqlite";
etf :: #import "etf";
fc_text :: #import "fc_text";
http :: #import "http";
imagefmt :: #import "imagefmt";
keys :: #import "keys";
locks :: #import "locks";
lottie :: #import "lottie";
media :: #import "media";
mls :: #import "voice_mls";
netio :: #import "netio";
protobuf :: #import "protobuf";
serve :: #import "serve";
vector :: #import "vector";
voice :: #import "voice";
#load "../app/markdown.jai";
#import "Math";
L :: (s: string) -> string { return s; } // Markdown's one tie to the app: translation.
#if OS == .WINDOWS msvcprt :: #library,system,no_dll,link_always "msvcprt";

HANG_S :: 3;
HANG_FENCE_S :: 30; // Its system calls on every allocation make a busy input take seconds, more under load.
MAX_ALLOC :: 1 << 30;
FENCE_ONE_IN :: 8;

Input :: enum {
	Bytes;
	Choices; // A generator's: half of the runs start from fresh random bytes.
	Json;    // Mutated as a tree, so most inputs pass the syntax and reach what reads the values.
}

Target :: struct {
	name: string;
	run: (data: []u8);
	seed: string;       // Built in, used when tests/fuzz/<name>/ is empty.
	fixtures := "";     // Better seeds: real files, separated by spaces.
	input := Input.Bytes;
}

TARGETS :: Target.[
	.{"etf", run_etf, "\x83t\0\0\0\x02m\0\0\0\x02opa\x01m\0\0\0\x01dl\0\0\0\x01a\x05jj", "", .Bytes},
	.{"json", run_json, "{\"op\":1,\"d\":[1,2.5,\"x\",null,true,{\"a\":[[]]}]}", "tests/data/collectibles_categories.json", .Json},
	.{"lottie", run_lottie, "{\"w\":64,\"h\":64,\"fr\":30,\"ip\":0,\"op\":30,\"layers\":[{\"ty\":4,\"ks\":{},\"shapes\":[{\"ty\":\"gr\",\"it\":[{\"ty\":\"rc\",\"p\":{\"k\":[32,32]},\"s\":{\"k\":[20,20]}},{\"ty\":\"fl\",\"c\":{\"k\":[1,0,0,1]},\"o\":{\"k\":100}}]}]}]}", "", .Json},
	.{"demux", run_demux, "\0\0\0\x10ftypisom\0\0\0\0\0\0\0\x08moov", "tests/ui/media/clip.mp4 tests/data/aac_video.mp4 tests/data/moov_last.mp4 tests/data/vp8.ivf tests/data/av1.ivf tests/ui/media/dance.gif", .Bytes},
	.{"store", run_store, "", "", .Choices},
	.{"markdown", run_markdown, "", "", .Choices},
	.{"svg", run_svg, "<svg viewBox=\"0 0 24 24\"><g transform=\"rotate(45)\"><path fill=\"#f00\" d=\"M1 1L5 5C1 2 3 4 5 6z\"/><circle cx=\"3\" cy=\"3\" r=\"1\" opacity=\".5\"/></g></svg>", "tests/ui/emoji/media/15522480866a3e11.svg tests/ui/emoji/media/21f5a5ed99c27d76.svg tests/ui/emoji/media/8838f014a5d2ce59.svg", .Bytes},
	.{"image", run_image, "\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\0\x01\0\0\0\x01\x08\x06\0\0\0", "tests/data/t_trns_gray.png tests/scenarios/assets/test.png tests/ui/attach/photo.jpg tests/ui/emoji/media/1546820603343016300.webp tests/ui/media/dance.gif", .Bytes},
	.{"protobuf", run_protobuf, "\x08\x01\x12\x03abc\x1a\x04\x08\x01\x10\x02\x21\x01\x02\x03\x04\x05\x06\x07\x08", "", .Bytes},
	.{"rtp", run_rtp, "\x90\x78\0\x01\0\0\0\x02\0\0\0\x03\xbe\xde\0\x01\x10\xaa\0\0payload", "", .Bytes},
	.{"dave", run_dave, "payload\0\x10\xfa\xfa", "", .Bytes},
	.{"mls", run_mls, "\0\x01\0\x01\0\x02\0\0", "", .Bytes},
	.{"e2e", run_e2e, "\x01\x02\x03\x04\x05\x06\x07\x08", "", .Bytes},
	.{"ui", run_ui, "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17", "", .Choices},
	.{"serve", run_serve, "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17", "", .Choices},
	.{"session", run_session, "\x00\x00\x01\x05\x02\x00\x02\x01\x09\x00\x03\x00\x02\x08\x00\x01\x05\x02\x02", "", .Choices},
	.{"fc_text", run_fc_text, "fc-AAECAwQFBgcICQ", "", .Bytes},
	.{"authority", run_authority, "\0\0\0\0", "", .Bytes},
	.{"altsvc", run_altsvc, "h3=\":443\"; ma=86400, h3-29=\"alt.example:8443\"; persist=1, clear", "", .Bytes},
	.{"http", run_http, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nSet-Cookie: a=b; Path=/\r\n\r\nhello", "", .Bytes},
	.{"http_request", run_http_request, "POST /a?b=c HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}", "", .Bytes},
	.{"ws", run_ws, "\x81\x05hello\x82\x7e\0\x02ab\x88\x02\x03\xe8", "", .Bytes},
	.{"url", run_url, "https://user@example.com:8443/a/b?c=d#e", "", .Bytes},
	.{"page", run_page, "<html><head><title>a &amp; b</title><meta property=\"og:title\" content='x'><meta name=description content=\"d\"></head>", "", .Bytes},
];

oracle :: (ok: bool, what: string, args: ..Any) {
	if ok return;
	print("fuzz oracle: ");
	print(what, ..args);
	print("\n");
	exit(4);
}

Hit :: struct { name: string; ok, all: s64; }
hits: [64]Hit;
hit_count: int;

// Notes whether a parser took the input, and passes the result on.
took :: (name: string, ok: bool) -> bool {
	for i: 0..hit_count - 1 if hits[i].name == name {
		hits[i].all += 1;
		if ok hits[i].ok += 1;
		return ok;
	}
	hits[hit_count] = .{name, xx ok, 1};
	hit_count += 1;
	return ok;
}

// ---- Parsers, mutated bytes ----

run_etf :: (data: []u8) {
	v, err := etf.decode(data,, temp);
	if !took("decode", err == .None) return;
	// A term that decoded encodes, and that encoding decodes to the same JSON.
	out, enc := etf.encode(v,, temp);
	if enc != .None return;
	v2, err2 := etf.decode(out,, temp);
	oracle(err2 == .None, "etf: decoding our own encoding failed: %", err2);
	oracle(json_of(v) == json_of(v2), "etf: a round trip changed the value:\n%\n%", json_of(v), json_of(v2));
}

run_json :: (data: []u8) {
	v, err := etf.from_json(cast(string) data,, temp);
	if !took("parse", err == .None) return;
	a := json_of(v);
	v2, err2 := etf.from_json(a,, temp);
	oracle(err2 == .None, "json: our own output doesn't parse: %", err2);
	oracle(a == json_of(v2), "json: printing isn't stable across a round trip");
}

json_of :: (v: etf.Value) -> string {
	sb: String_Builder;
	sb.allocator = temp;
	etf.to_json(v, *sb);
	return builder_to_string(*sb,, temp);
}

run_lottie :: (data: []u8) {
	anim := lottie.load(data);
	if !took("load", anim != null) return;
	p: lottie.Player;
	lottie.player_init(*p, 32, 32);
	lottie.render(*p, anim, 0);
	lottie.render(*p, anim, lottie.frame_at(anim, 0.5));
	lottie.player_destroy(*p);
	lottie.destroy(anim);
}

run_demux :: (data: []u8) {
	src := media.source_from_memory(data);
	d := media.demux_open(*src);
	if !took("open", d != null) return;
	media.demux_scan_all(d);
	buf: [..]u8;
	for * t: d.tracks for t.packets media.demux_read(d, it, *buf);
	array_free(buf);
	media.demux_destroy(d);
}

run_svg :: (data: []u8) {
	_, ok := vector.parse_svg(cast(string) data, temp);
	took("parse", ok);
}

run_image :: (data: []u8) {
	img, err := imagefmt.decode(data, temp, max_pixels = 1 << 20);
	if !took("decode", err == .None) return;
	oracle(img.width > 0 && img.height > 0, "image: % x %", img.width, img.height);
}

run_protobuf :: (data: []u8) {
	walk :: (b: []u8, depth: int) {
		if depth > 8 return;
		r := protobuf.Reader.{buf = b};
		while true {
			f, ok := protobuf.next(*r);
			if !ok break;
			if f.wire == .Len {
				walk(f.bytes, depth + 1);
				protobuf.packed_fixed64(f.bytes);
			}
		}
	}
	walk(data, 0);
	protobuf.find_path(data, 1, 2, 3);
	dc.decode_item_map(data);
	dc.decode_favorite_gif(data);
	// The settings path as a server sends it: base64 of a proto.
	s: dc.Store;
	dc.store_init(*s);
	b64 := base64_encode(cast(string) data);
	dc.apply_settings_proto(*s, b64, false);
	dc.apply_settings_proto(*s, b64, true);
	dc.frecency_remote_update(*s, b64, false);
	dc.frecency_remote_update(*s, b64, true);
	dc.store_destroy(*s);
}

run_rtp :: (data: []u8) {
	h, ok := voice.parse_rtp_header(data);
	if took("header", ok) oracle(h.aad_len <= data.count, "rtp: aad_len % of %", h.aad_len, data.count);
	_, ok = voice.parse_report(data);
	took("report", ok);
	_, _, _, ok = voice.parse_discovery(data, 2);
	took("discovery", ok);
}

run_dave :: (data: []u8) {
	_, ok := DAVE.parse_protocol_frame(data);
	took("frame", ok);
}

run_mls :: (data: []u8) {
	_, e1 := mls.parse_mls_message(data);
	took("message", e1 == .None);
	_, e2 := mls.parse_ratchet_tree(data);
	took("tree", e2 == .None);
}

run_e2e :: (data: []u8) {
	_, ok := e2e.parse_body(data);
	took("body", ok);
	_, ok = e2e.parse_hello(data);
	took("hello", ok);
	_, ok = e2e.parse_init(data);
	took("init", ok);
	_, ok = e2e.parse_header(data);
	took("header", ok);
	_, _, ok = e2e.parse_group(data);
	took("group", ok);
}

run_fc_text :: (data: []u8) {
	p, ok := fc_text.decode(cast(string) data);
	if !took("decode", ok) return;
	oracle(fc_text.encode(p) == cast(string) data, "fc_text: more than one text form of a packet");
}

run_authority :: (data: []u8) {
	c, ok := authority.decode_checkpoint(data);
	if took("checkpoint", ok) {
		b := authority.encode_checkpoint(c);
		oracle(memcmp(b.data, data.data, b.count) == 0, "authority: a checkpoint's round trip changed it");
	}
	root: [32]u8;
	_, ok = authority.load(root, data);
	took("log", ok);
	_, ok = keys.decode(data);
	took("key", ok);
}

run_altsvc :: (data: []u8) {
	took("parse", altsvc.parse(cast(string) data).count > 0);
}

// A stream that reads the input and swallows what's written, so a client's request goes nowhere and the
// parser sees the whole input. No pipe: a write to a closed one fails before anything is parsed.
Memory_Stream :: struct { rest: []u8; chunk: int; }
memory_stream :: (data: []u8, chunk: int) -> netio.Stream {
	m := New(Memory_Stream,, temp);
	m.* = .{data, chunk};
	read :: (p: *void, dst: []u8) -> int, netio.Error {
		m := cast(*Memory_Stream) p;
		if !m.rest.count return 0, .Closed;
		n := min(dst.count, m.rest.count);
		if m.chunk n = min(n, m.chunk);
		memcpy(dst.data, m.rest.data, n);
		m.rest.data += n;
		m.rest.count -= n;
		return n, .None;
	}
	write :: (p: *void, src: []u8) -> netio.Error { return .None; }
	close :: (p: *void) {}
	return .{data = m, read = read, write = write, close = close};
}

run_http :: (data: []u8) {
	a := memory_stream(data, ifx data.count && data[0] & 1 then 1 else 0);
	h: http.H1_Conn;
	http.h1_init(*h, a);
	req := http.Request.{method = "GET", path = "/", authority = "x"};
	resp, err := http.h1_round_trip(*h, req);
	took("response", err == .None);
	http.h1_destroy(*h);
}

run_http_request :: (data: []u8) {
	a := memory_stream(data, 0);
	h: http.H1_Conn;
	http.h1_init(*h, a);
	req, err := http.h1_read_request(*h);
	if took("request", err == .None) http.request_destroy(*req);
	http.h1_destroy(*h);
}

run_ws :: (data: []u8) {
	a := memory_stream(data, 0);
	c := http.ws_attach(a);
	msg: [..]u8;
	for 1..32 {
		_, err := http.ws_recv(c, *msg);
		if !took("message", err == .None) break;
	}
	array_free(msg);
	http.ws_destroy(c);
}

run_page :: (data: []u8) {
	serve.scan_page(cast(string) data);
}

run_url :: (data: []u8) {
	text := cast(string) data;
	_, ok := serve.parse_url(text);
	took("url", ok);
	_, ok = dc.parse_http_date(text);
	took("date", ok);
	_, ok = dc.parse_proxy_url(text);
	took("proxy", ok);
	_, ok = serve.parse_iso(text);
	took("iso", ok);
	_, ok = serve.parse_invite(text);
	took("invite", ok);
}

// ---- Generators: the input is a stream of choices ----

Gen :: struct {
	b: []u8;
	at: int;
}

// Past the end every choice is 0, so any input is a complete run.
byte :: (g: *Gen) -> int {
	if g.at >= g.b.count return 0;
	g.at += 1;
	return g.b[g.at - 1];
}
done :: (g: *Gen) -> bool { return g.at >= g.b.count; }
pick :: (g: *Gen, n: int) -> int {
	if n <= 256 return byte(g) % n;
	return (byte(g) << 8 | byte(g)) % n;
}
pick_of :: (g: *Gen, a: []string) -> string { return a[pick(g, a.count)]; }

// ---- E2E sessions: two real clients, and a carrier that lies ----

SESSION_DIR :: "build/fuzz_e2e";
SESSION_CARRIER :: "mock";
SESSION_CONV :: "conv";
SESSION_PARTIES :: string.["alice", "bob"];

session_ids: [2]e2e.Identity;
session_files: [2]string; // Both databases with a session already open, since a Hello's signature costs milliseconds to seconds.

session_path :: (who: int) -> string { return tprint("%/%.db", SESSION_DIR, SESSION_PARTIES[who]); }

session_open :: (who: int) -> *e2e.Db {
	d := New(e2e.Db);
	d.path = copy_string(session_path(who));
	ok := e2e.open(d);
	oracle(ok, "session: can't open %: %", d.path, d.error);
	return d;
}

session_close :: (d: *e2e.Db) {
	sqlite.exec(d.sql, "PRAGMA wal_checkpoint(TRUNCATE);");
	sqlite.close(d.sql);
	crypto.aead_destroy(*d.seal);
	free(d.path);
	free(d);
}

session_ask :: (d: *e2e.Db, who: int, op: e2e.Op, packet := "", from := -1, at := "", id := SESSION_CONV, text := "", silent := false, content := e2e.Content.Text, target := "") -> *e2e.Request {
	r := e2e.request(op, .{SESSION_CARRIER, id, SESSION_PARTIES[who], SESSION_PARTIES[1 - who], e2e.MAX_PACKET}, text, packet);
	r.me, r.silent, r.content = session_ids[who], silent, content;
	r.target = copy_string(target);
	r.from = copy_string(SESSION_PARTIES[ifx from >= 0 then from else 1 - who]);
	r.delivery = copy_string(at);
	e2e.run_request(d, r);
	return r;
}

session_fixture :: () {
	if session_files[0] return;
	started := atomic_swap(*input_started, 0);
	defer atomic_swap(*input_started, started);
	push_allocator(context.default_allocator);
	delete_directory(SESSION_DIR);
	make_directory_if_it_does_not_exist(SESSION_DIR, recursive = true);
	session_ids[0] = e2e.identity_of(keys.generate("A"));
	session_ids[1] = e2e.identity_of(keys.generate("B"));
	a, b := session_open(0), session_open(1);
	hello := session_ask(b, 1, .Hello);
	oracle(hello.result == .Ok, "session: hello %", hello.result);
	init := session_ask(a, 0, .Accept, hello.packet);
	oracle(init.result == .Ok, "session: accept %", init.result);
	opened := session_ask(b, 1, .Receive, init.packet, at = "init");
	oracle(opened.result == .Ok, "session: init %", opened.result);
	session_close(a);
	session_close(b);
	for 0..1 session_files[it] = read_entire_file(session_path(it));
}

Session_Packet :: struct {
	packet, at, plain, word: string;
	author: int;
	silent, opened, echoed, spent: bool; // spent: its delivery ID was given to an attack.
}

run_session :: (data: []u8) {
	session_fixture();
	for 0..1 {
		path := session_path(it);
		file_delete(tprint("%-wal", path));
		file_delete(tprint("%-shm", path));
		write_entire_file(path, session_files[it]);
	}
	dbs := (*e2e.Db).[session_open(0), session_open(1)];
	defer for dbs session_close(it);

	sent: [..]Session_Packet;
	sent.allocator = temp;
	g := Gen.{b = data};
	deliveries := 0;
	next_at :: () -> string #expand {
		deliveries += 1;
		return tprint("d%", deliveries);
	}
	// What the carrier makes of a packet may fail any way but one: no lie opens.
	refused :: (r: *e2e.Request, what: string) {
		oracle(r.result != .Ok && r.result != .Hello, "session: % gave % (%)", what, r.result, r.out_text);
		e2e.free_request(r);
	}

	for step: 0..63 {
		if done(*g) break;
		action := pick(*g, 11);
		who := pick(*g, 2);
		// Every action but a send needs a packet.
		if action > 1 && !sent.count action = 0;
		if action == {
			case 0; #through;
			case 1;
				word := tprint("zq%q", sent.count);
				filler := NewArray(pick(*g, 200), u8,, temp);
				for * filler it.* = xx (#char "a" + byte(*g) % 26); // Bodies must be UTF-8.
				text := tprint("% %", word, cast(string) filler);
				silent := pick(*g, 4) == 0;
				r := session_ask(dbs[who], who, .Send, text = text, silent = silent);
				if r.result == .Ok array_add(*sent, .{packet = copy_string(r.packet,, temp), at = next_at(), plain = text, word = word, author = who, silent = silent});
				else oracle(r.result == .Too_Long, "session: send gave %", r.result);
				e2e.free_request(r);
			case 2;
				p := *sent[pick(*g, sent.count)];
				if p.spent continue;
				to := 1 - p.author;
				r := session_ask(dbs[to], to, .Receive, p.packet, at = p.at);
				oracle(r.result == .Ok && r.out_text == p.plain, "session: packet % gave % (%)", p.word, r.result, r.out_text);
				oracle(r.silent == p.silent, "session: packet % lost its silent flag", p.word);
				p.opened = true;
				e2e.free_request(r);
			case 3;
				p := sent[pick(*g, sent.count)];
				forged := copy_string(p.packet,, temp);
				for 0..pick(*g, 4) {
					i := pick(*g, forged.count);
					forged[i] ^= xx (1 + pick(*g, 255));
				}
				if forged == p.packet continue;
				to := 1 - p.author;
				refused(session_ask(dbs[to], to, .Receive, forged, at = next_at()), "a forgery");
			case 4;
				p := sent[pick(*g, sent.count)];
				cut := p.packet;
				cut.count = pick(*g, cut.count);
				to := 1 - p.author;
				refused(session_ask(dbs[to], to, .Receive, cut, at = next_at()), "a cut packet");
				grown := tprint("%\0", p.packet);
				refused(session_ask(dbs[to], to, .Receive, grown, at = next_at()), "a grown packet");
			case 5;
				p := *sent[pick(*g, sent.count)];
				if p.spent continue;
				if p.opened {
					to := 1 - p.author;
					r := session_ask(dbs[to], to, .Receive, p.packet, at = next_at());
					oracle(r.result == .Repeated, "session: replay of % gave %", p.word, r.result);
					e2e.free_request(r);
				} else if !p.echoed {
					r := session_ask(dbs[p.author], p.author, .Receive, p.packet, from = p.author, at = p.at);
					oracle(r.result == .Ok && r.out_text == p.plain, "session: echo of % gave %", p.word, r.result);
					p.echoed = true;
					e2e.free_request(r);
				}
			case 6;
				p := sent[pick(*g, sent.count)];
				to := 1 - p.author;
				if p.opened || p.spent continue;
				// The same bytes, said to come from elsewhere: the receiver itself, or another conversation.
				if pick(*g, 2) refused(session_ask(dbs[to], to, .Receive, p.packet, from = to, at = next_at()), "a packet claimed as our own");
				else refused(session_ask(dbs[to], to, .Receive, p.packet, at = next_at(), id = "elsewhere"), "a packet moved to another conversation");
			case 7;
				junk := NewArray(2 + pick(*g, 600), u8,, temp);
				for * junk it.* = xx byte(*g);
				junk[0] = e2e.VERSION;
				junk[1] = xx (pick(*g, 8));
				refused(session_ask(dbs[who], who, .Receive, cast(string) junk, at = next_at()), "a made-up packet");
			case 8;
				session_close(dbs[who]);
				dbs[who] = session_open(who);
			case 9;
				p := sent[pick(*g, sent.count)];
				if p.spent continue;
				to := 1 - p.author;
				r := session_ask(dbs[to], to, .Search, text = p.word);
				oracle(r.hits.count == ifx p.opened then 1 else 0, "session: search for % found % (opened %)", p.word, r.hits.count, p.opened);
				e2e.free_request(r);
			case 10;
				// The peer and the carrier together go after a message the victim wrote. The peer's own
				// database believes it wrote that delivery, so its client lets the Edit or Delete out.
				p := *sent[pick(*g, sent.count)];
				if p.opened || p.spent continue;
				victim, attacker := p.author, 1 - p.author;
				if !p.echoed {
					r := session_ask(dbs[victim], victim, .Receive, p.packet, from = victim, at = p.at);
					oracle(r.result == .Ok, "session: echo of % gave %", p.word, r.result);
					p.echoed = true;
					e2e.free_request(r);
				}
				p.spent = true;
				bait := session_ask(dbs[attacker], attacker, .Send, text = "bait");
				e2e.free_request(session_ask(dbs[attacker], attacker, .Receive, bait.packet, from = attacker, at = p.at));
				e2e.free_request(bait);
				delete := pick(*g, 2) == 1;
				hit := session_ask(dbs[attacker], attacker, .Send, text = ifx delete then "" else "zqtakenq", content = ifx delete then .Delete else .Edit, target = p.at);
				oracle(hit.result == .Ok, "session: attack send gave %", hit.result);
				at := ifx pick(*g, 2) then p.at else next_at();
				e2e.free_request(session_ask(dbs[victim], victim, .Receive, hit.packet, at = at));
				e2e.free_request(hit);
				r := session_ask(dbs[victim], victim, .Search, text = p.word);
				oracle(r.hits.count == 1, "session: the peer's % (delivered at %) took the victim's % at %", ifx delete then "Delete" else "Edit", at, p.word, p.at);
				e2e.free_request(r);
		}
	}
	// Nothing the carrier did may have cost a real message: all that's left still opens.
	for * sent if !it.opened && !it.spent {
		to := 1 - it.author;
		r := session_ask(dbs[to], to, .Receive, it.packet, at = it.at);
		oracle(r.result == .Ok && r.out_text == it.plain, "session: at the end, packet % gave %", it.word, r.result);
		e2e.free_request(r);
	}
}

// ---- Serve: a hostile member's requests and gateway ops, with no socket ----
//
// One connection, driven through conn_requests by a stream that makes each request as the server reads
// it, so a later request can name the IDs an earlier reply handed out. No listener runs, so neither does
// the unfurler, the one thing here that dials out; the login is left out since it needs a TLS session.

SERVE_DIR :: "build/fuzz_serve";
SERVE_USERS :: 3; // The owner, a member, and one more to act on.
SERVE_METHODS :: string.["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"];
SERVE_GATEWAY_OPS :: int.[1, 2, 3, 4, 6, 18, 19, 20, 37, 40];
SERVE_VOICE_OPS :: int.[0, 1, 3, 5, 12, 13, 18, 19, 21, 22, 23, 24, 25, 27, 28, 29, 30, 31];
SERVE_SOURCES :: string.["module", "dave", "dms", "expressions", "host", "polls", "roles", "settings", "soundboard", "unfurl", "voice", "webhook_formats"];
MAX_SERVE_IDS :: 256;

serve_table :: (paths: bool) -> []string {
	out: [..]string;
	for SERVE_SOURCES {
		rest := read_entire_file(tprint("src/serve/%.jai", it));
		while true {
			at := find_index_from_left(rest, #char "\"");
			if at < 0 break;
			advance(*rest, at + 1);
			close := find_index_from_left(rest, #char "\"");
			if close < 0 break;
			text := slice(rest, 0, close);
			advance(*rest, close + 1);
			if !text || text.count > 70 continue;
			ok := true;
			for text {
				c := it;
				name := (c >= #char "a" && c <= #char "z") || c == #char "_";
				if paths ok &&= name || (c >= #char "0" && c <= #char "9") || c == #char "/" || c == #char "%" || c == #char "-" || c == #char "@";
				else ok &&= name;
			}
			if !ok || (paths && text[0] != #char "/") || (!paths && text.count < 2) continue;
			seen := false;
			for out if it == text seen = true;
			if !seen array_add(*out, text);
		}
	}
	return out;
}
SERVE_PATHS :: #run serve_table(true);
SERVE_KEYS :: #run serve_table(false);

serve_file: string;
serve_guild: s64;
serve_tokens: [SERVE_USERS]string;

Serve_Stream :: struct {
	g: Gen;
	guild: s64;
	ids: [MAX_SERVE_IDS]s64;
	id_count: int;
	buf: [..]u8;
	at: int;
	ws: int; // 0: HTTP. 1: a gateway. 2: a voice gateway, which reads JSON.
	identified: bool;
	token: string;
}

serve_id :: (m: *Serve_Stream) -> s64 {
	choice := pick(*m.g, m.id_count + 3);
	if choice < m.id_count return m.ids[choice];
	return s64.[m.guild, 0, 1 << 62][choice - m.id_count];
}

serve_value :: (m: *Serve_Stream, depth := 0) -> etf.Value {
	g := *m.g;
	if pick(g, ifx depth < 4 then 12 else 9) == {
		case 0; return .{};
		case 1; return etf.vbool(pick(g, 2) == 1);
		case 2; return etf.vint(pick(g, 8));
		case 3; return etf.vint(s64.[-1, 0x7fff_ffff, 1 << 53, 0x7fff_ffff_ffff_ffff][pick(g, 4)]);
		case 4; return etf.vstring(tprint("%", serve_id(m)));
		case 5; return etf.vint(serve_id(m));
		case 6; return etf.vstring(pick_of(g, SERVE_KEYS));
		case 7; return etf.vstring(string.["", " ", "a", "\xff\xfe", "http://127.0.0.1/", "../../x", "<@1>", "\0"][pick(g, 8)]);
		case 8;
			long := NewArray(1 << pick(g, 17), u8,, temp);
			memset(long.data, #char "x", long.count);
			return etf.vstring(cast(string) long);
		case 9; #through;
		case 10;
			out: [..]etf.Value;
			out.allocator = temp;
			for 1..pick(g, 5) array_add(*out, serve_value(m, depth + 1));
			return etf.Value.{kind = .List, list = out};
	}
	return serve_map(m, depth);
}

serve_map :: (m: *Serve_Stream, depth := 0) -> etf.Value {
	b := etf.map_builder(,, temp);
	for 1..pick(*m.g, 8) etf.map_put(*b, pick_of(*m.g, SERVE_KEYS), serve_value(m, depth + 1));
	return etf.vmap(etf.map_done(*b));
}

serve_path :: (m: *Serve_Stream) -> string {
	g := *m.g;
	path := pick_of(g, SERVE_PATHS);
	sb: String_Builder;
	sb.allocator = temp;
	put_id :: (at: int) #expand {
		guild := at >= 7 && slice(path, at - 7, 7) == "guilds/";
		print_to_builder(*sb, "%", ifx guild then m.guild else serve_id(m));
	}
	for 0..path.count - 1 {
		if path[it] == #char "%" {
			put_id(it);
			continue;
		}
		if it > 0 && path[it - 1] == #char "%" && path[it] >= #char "0" && path[it] <= #char "9" continue;
		append(*sb, path[it]);
	}
	// A bare prefix wants an ID and most often one of the routes' tails after it.
	if ends_with(path, "/") {
		put_id(path.count);
		if pick(g, 3) {
			tail := pick_of(g, SERVE_PATHS);
			if find_index_from_left(tail, #char "%") < 0 append(*sb, tail);
			if ends_with(tail, "/") || pick(g, 3) == 0 print_to_builder(*sb, "%", serve_id(m));
		}
	}
	if pick(g, 3) == 0 print_to_builder(*sb, "?%=%&%=%", pick_of(g, SERVE_KEYS), serve_id(m), pick_of(g, SERVE_KEYS), pick(g, 200));
	return builder_to_string(*sb,, temp);
}

// A masked client frame; the mask is all zeros, so the payload goes as it is.
serve_frame :: (m: *Serve_Stream, opcode: u8, payload: []u8) {
	array_add(*m.buf, 0x80 | opcode);
	n := payload.count;
	if n < 126 array_add(*m.buf, cast(u8) (0x80 | n));
	else if n < 65536 {
		array_add(*m.buf, 0x80 | 126, cast(u8) (n >> 8), cast(u8) (n & 255));
	} else {
		array_add(*m.buf, 0x80 | 127, 0, 0, 0, 0);
		for i: 0..3 array_add(*m.buf, cast(u8) ((n >> (24 - 8 * i)) & 255));
	}
	for 0..3 array_add(*m.buf, 0);
	array_add(*m.buf, ..payload);
}

serve_payload :: (m: *Serve_Stream, op: int, d: etf.Value) {
	b := etf.map_builder(4,, temp);
	etf.map_put(*b, "op", etf.vint(op));
	etf.map_put(*b, "d", d);
	v := etf.vmap(etf.map_done(*b));
	if m.ws == 2 {
		serve_frame(m, 1, cast([]u8) json_of(v));
	} else {
		bytes, err := etf.encode(v,, temp);
		if err == .None serve_frame(m, 2, bytes);
	}
}

// serve_next puts the next request or frame in m.buf; false when the choices are spent.
serve_next :: (m: *Serve_Stream) -> bool {
	m.buf.count, m.at = 0, 0;
	g := *m.g;
	if done(g) return false;
	if m.ws {
		if !m.identified && m.ws == 1 {
			m.identified = true;
			d := etf.map_builder(,, temp);
			etf.map_put(*d, "token", etf.vstring(m.token));
			serve_payload(m, 2, etf.vmap(etf.map_done(*d)));
			return true;
		}
		op := ifx m.ws == 2 then SERVE_VOICE_OPS[pick(g, SERVE_VOICE_OPS.count)] else SERVE_GATEWAY_OPS[pick(g, SERVE_GATEWAY_OPS.count)];
		serve_payload(m, op, ifx pick(g, 4) then serve_map(m) else serve_value(m));
		return true;
	}
	token := serve_tokens[max(pick(g, SERVE_USERS + 2) - 2, 0)]; // Mostly the owner, whom no permission stops.
	if pick(g, 12) == 0 {
		m.ws = 1 + pick(g, 2);
		m.token = token;
		path := ifx m.ws == 2 then "/?v=9" else "/?v=9&encoding=etf";
		array_add(*m.buf, ..cast([]u8) tprint("GET % HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n", path));
		return true;
	}
	method := pick_of(g, SERVE_METHODS);
	path := serve_path(m);
	body := ifx method == "GET" || method == "HEAD" then "" else json_of(serve_map(m));
	array_add(*m.buf, ..cast([]u8) tprint("% % HTTP/1.1\r\nHost: x\r\nAuthorization: %\r\nContent-Type: application/json\r\nContent-Length: %\r\n\r\n%", method, path, token, body.count, body));
	return true;
}

serve_read :: (p: *void, dst: []u8) -> int, netio.Error {
	m := cast(*Serve_Stream) p;
	if m.at >= m.buf.count && !serve_next(m) return 0, .Closed;
	n := min(dst.count, m.buf.count - m.at);
	memcpy(dst.data, m.buf.data + m.at, n);
	m.at += n;
	return n, .None;
}

// While HTTP is all that's running, this is the only thread here: a gateway's writer never sees it pass m.ws.
serve_write :: (p: *void, src: []u8) -> netio.Error {
	m := cast(*Serve_Stream) p;
	if m.ws return .None;
	text := cast(string) src;
	if begins_with(text, "HTTP/1.1 ") && text.count > 10 {
		oracle(text[9] != #char "5", "serve: % after %", slice(text, 0, 12), cast(string) m.buf);
		took("reply", text[9] == #char "2");
	}
	while true {
		at := find_index_from_left(text, "\"id\":\"");
		if at < 0 break;
		advance(*text, at + 6);
		n: s64;
		i := 0;
		while i < text.count && i < 19 && text[i] >= #char "0" && text[i] <= #char "9" {
			n = n * 10 + text[i] - #char "0";
			i += 1;
		}
		if !i continue;
		seen := false;
		for 0..m.id_count - 1 if m.ids[it] == n seen = true;
		if !seen && m.id_count < MAX_SERVE_IDS {
			m.ids[m.id_count] = n;
			m.id_count += 1;
		}
	}
	return .None;
}

serve_fixture :: () {
	if serve_file return;
	started := atomic_swap(*input_started, 0);
	defer atomic_swap(*input_started, started);
	push_allocator(context.default_allocator);
	delete_directory(SERVE_DIR);
	make_directory_if_it_does_not_exist(SERVE_DIR, recursive = true);
	path := tprint("%/server.db", SERVE_DIR);
	s, ok, why := serve.open(path);
	oracle(ok, "serve: can't open: %", why);
	serve_guild = s.guild;
	for 0..SERVE_USERS - 1 {
		id := it + 1000;
		t: [32]u8;
		t[0] = xx (it + 1);
		root: [32]u8;
		root[1] = xx (it + 1);
		name := tprint("user%", it);
		ok = sqlite.run(s.db, "INSERT INTO users(id, root, signing_pub, name, joined_name) VALUES(?, ?, ?, ?, ?4);", id, cast([]u8) root, cast([]u8) root, name);
		h := crypto.blake3(t);
		ok = ok && sqlite.run(s.db, "INSERT INTO sessions(token_hash, user) VALUES(?, ?);", cast([]u8) h, id);
		oracle(ok, "serve: fixture: %", sqlite.errmsg(s.db));
		serve_tokens[it] = serve.hex(t);
	}
	sqlite.run(s.db, "INSERT OR REPLACE INTO meta(k, v) VALUES('owner', '1000');");
	serve.stop(s);
	serve_file = read_entire_file(path);
}

run_serve :: (data: []u8) {
	serve_fixture();
	path := tprint("%/server.db", SERVE_DIR);
	file_delete(tprint("%-wal", path));
	file_delete(tprint("%-shm", path));
	write_entire_file(path, serve_file);
	s, ok, why := serve.open(path);
	oracle(ok, "serve: can't open: %", why);

	m := New(Serve_Stream);
	defer { array_free(m.buf); free(m); }
	// The connection resets temp between requests, and the input may live there.
	m.g.b, m.guild = array_copy(data), s.guild;
	defer array_free(m.g.b);
	for 1000..1000 + SERVE_USERS - 1 { m.ids[m.id_count] = it; m.id_count += 1; }
	st := sqlite.prepare(s.db, "SELECT id FROM channels;");
	while sqlite.step(st) == .Row && m.id_count < 16 { m.ids[m.id_count] = sqlite.col_int(st, 0); m.id_count += 1; }
	sqlite.finalize(st);

	c := New(Conn_Of_Serve);
	defer free(c);
	tcp: netio.Tcp;
	tcp.peer[10], tcp.peer[11], tcp.peer[12] = 0xff, 0xff, 127; // Loopback has no rate limits.
	c.server, c.tcp, c.accepted = s, *tcp, current_time_monotonic();
	c.s = .{data = m, read = serve_read, write = serve_write, close = (p: *void) {}};
	atomic_swap(*c.authed, true);
	array_add(*s.conns, c);
	serve.conn_requests(c, null, false);
	s.conns.count = 0;
	serve.stop(s);
}
Conn_Of_Serve :: serve.Conn;

// ---- The store: sequences of gateway events ----

Key :: struct { name: string; kind: u8; }

STORE_SOURCES :: string.["store", "soundboard", "polls", "inbox", "stickers", "expressions", "relationships_extra"];

// Every event and field the client reads, taken from its source when this program compiles, so a new
// event or field is fuzzed without anyone listing it here.
KEYS :: #run key_table();
EVENTS :: #run event_table();

key_table :: () -> []Key {
	out: [..]Key;
	for STORE_SOURCES {
		s := read_entire_file(tprint("src/discord/%.jai", it));
		for accessor: string.["fstr", "fsnow", "fint", "fbool", "fmap", "flist", "vget"] {
			rest := s;
			needle := tprint("%(", accessor);
			while true {
				at := find_index_from_left(rest, needle);
				if at < 0 break;
				advance(*rest, at + needle.count);
				close := find_index_from_left(rest, #char ")");
				if close < 0 || close > 80 continue;
				inner := slice(rest, 0, close);
				quote := find_index_from_left(inner, #char "\"");
				if quote < 0 || inner[inner.count - 1] != #char "\"" || quote == inner.count - 1 continue;
				key := slice(inner, quote + 1, inner.count - quote - 2);
				if !key continue;
				seen := false;
				for out if it.name == key seen = true;
				if !seen array_add(*out, .{key, accessor[1]});
			}
		}
	}
	return out;
}

event_table :: () -> []string {
	out: [..]string;
	for STORE_SOURCES {
		for line: split(read_entire_file(tprint("src/discord/%.jai", it)), "\n") {
			at := find_index_from_left(line, "case \"");
			if at < 0 continue;
			rest := slice(line, at + 6, line.count);
			end := find_index_from_left(rest, #char "\"");
			if end < 4 continue;
			name := slice(rest, 0, end);
			upper := true;
			for name if !(it == #char "_" || (it >= #char "A" && it <= #char "Z") || (it >= #char "0" && it <= #char "9")) upper = false;
			if upper array_add_if_unique(*out, name);
		}
	}
	return out;
}

// Few ids, so that events land on the same guilds, channels, users and messages.
IDS :: string.["1", "2", "3", "4", "5", "1000000000000000001"];
ODD_IDS :: string.["0", "-1", "18446744073709551615", "18446744073709551616", "abc", "", "9999999999999999999999"];
TEXTS :: string.["", "a", "x y", "<@1>", "\xff\xfe", "\xf0\x9f\x98\x80", "https://cdn.discordapp.com/attachments/1/2/a.png", "AAAA", "2026-11-02T00:00:00.000000+00:00", "a_b", "#", "\0"];
INTS :: s64.[0, 1, 2, 3, 4, 6, 10, 46, 255, 65536, -1, 0x7FFF_FFFF, 0x8000_0000, 0x7FFF_FFFF_FFFF_FFFF, -0x7FFF_FFFF_FFFF_FFFF];

gen_real_ids: []string; // `ui`: the fixture's, so that events land on what's on screen.

gen_id :: (g: *Gen) -> etf.Value {
	r := pick(g, 16);
	if gen_real_ids.count && r < 12 return etf.vstring(pick_of(g, gen_real_ids));
	if r == 15 return etf.vstring(pick_of(g, ODD_IDS));
	if r == 14 return etf.vint(pick(g, 6) + 1);
	return etf.vstring(IDS[r % IDS.count]);
}

// kind is the second letter of the accessor that reads the field: fStr, fSnow, fInt, fBool, fMap, fList, vGet.
gen_value :: (g: *Gen, kind: u8, depth: int) -> etf.Value {
	if pick(g, 16) == 0 return etf.Value.{}; // Null, or a missing field read as one.
	k := kind;
	if pick(g, 12) == 0 k = "tsnimlg"[pick(g, 7)]; // The wrong type for this field.
	if k == {
		case #char "s"; #through;
		case #char "t";
			if k == #char "s" && kind == #char "s" && pick(g, 2) return gen_id(g);
			if pick(g, 6) == 0 {
				// Long enough to reach whatever a length cap guards.
				s := talloc_string(pick(g, 5000));
				memset(s.data, #char "a", s.count);
				return etf.vstring(s);
			}
			return etf.vstring(pick_of(g, TEXTS));
		case #char "i"; #through;
		case #char "n"; return etf.vint(INTS[pick(g, INTS.count)]);
		case #char "b"; return etf.vbool(pick(g, 2) == 0);
		case #char "l";
			if depth <= 0 return etf.vlist(.[]);
			n := pick(g, 6);
			out := NewArray(n, etf.Value,, temp);
			// A list holds one shape, as Discord's do.
			shape := "mmmsmt"[pick(g, 6)];
			for * out it.* = gen_value(g, shape, depth - 1);
			return etf.vlist(out);
		case #char "g"; #through;
		case #char "m";
			if depth <= 0 return etf.Value.{};
			return gen_map(g, depth - 1);
	}
	return etf.Value.{};
}

gen_map :: (g: *Gen, depth: int) -> etf.Value {
	m := etf.map_builder(,, temp);
	for 1..pick(g, 12) {
		k := KEYS[pick(g, KEYS.count)];
		etf.map_put(*m, k.name, gen_value(g, k.kind, depth));
	}
	// Most objects are named by an id, and most refer to a channel or guild.
	if pick(g, 8) etf.map_put(*m, "id", gen_id(g));
	if pick(g, 4) etf.map_put(*m, "channel_id", gen_id(g));
	if pick(g, 2) etf.map_put(*m, "guild_id", gen_id(g));
	if pick(g, 4) == 0 etf.map_put(*m, "message_id", gen_id(g));
	return etf.vmap(etf.map_done(*m));
}

check_store :: (s: *dc.Store) {
	for * l, cid: s.messages {
		for 1..l.messages.count - 1 {
			oracle(l.messages[it - 1].id < l.messages[it].id, "store: channel %'s messages out of order at %: % then %", cid, it, l.messages[it - 1].id, l.messages[it].id);
		}
	}
	for * g: s.guilds {
		for g.channels oracle(table_find_pointer(*s.channels, it) != null, "store: guild % lists channel %, which isn't stored", g.id, it);
	}
	for s.private_channels oracle(table_find_pointer(*s.channels, it) != null, "store: private channel % isn't stored", it);
}

run_store :: (data: []u8) {
	g := Gen.{b = data};
	s: dc.Store;
	dc.store_init(*s);
	now: s64 = 1000;
	n := 0;
	while !done(*g) && n < 64 {
		n += 1;
		now += 1;
		r := pick(*g, 32);
		if r == 0 {
			if replaying print("(reconnect)\n");
			dc.store_reset_session(*s);
		}
		else if r == 1 dc.store_expire_typing(*s, now + pick(*g, 20000));
		else if r == 2 {
			list := gen_value(*g, #char "l", 3);
			dc.store_apply_messages(*s, cast(dc.Snowflake) (pick(*g, 5) + 1), list, pick(*g, 60), pick(*g, 2) == 0);
		} else {
			// READY often comes first, or nothing has anywhere to land.
			name := ifx n == 1 && pick(*g, 4) then "READY" else EVENTS[pick(*g, EVENTS.count)];
			depth := ifx name == "READY" || name == "GUILD_CREATE" then 5 else 3;
			event := gen_map(*g, depth);
			if replaying print("% %\n", name, json_of(event));
			dc.store_apply_dispatch(*s, name, event, now);
		}
		check_store(*s);
	}
	dc.store_destroy(*s);
}

// ---- The UI: a hostile store on screen, and a user clicking through it ----

#if UI_TARGET fapp :: #import "app";

ui_fixtures: [..]string;

UI_KEYS :: string.["a", "k", "escape", "enter", "tab", "up", "down", "backspace", "shift", "ctrl", "alt", "f23", "keypad_7", "print_screen", "insert", "menu", "pause"];
UI_MODS :: string.["", "ctrl", "shift", "alt", "cmd", "ctrl shift"];

run_ui :: (data: []u8) {
	#if UI_TARGET {
		if !ui_fixtures.count {
			started := atomic_swap(*input_started, 0);
			defer atomic_swap(*input_started, started);
			push_allocator(context.default_allocator);
			netio.no_network = true;
			fapp.fuzz_ui_start("build/fuzz_ui_state");
			for file_list("tests/ui") if ends_with(it, ".jsonl") array_add(*ui_fixtures, read_entire_file(it));
		}
		// Frames reset temp, and the input may live there.
		input := array_copy(data);
		defer array_free(input);
		g := Gen.{b = input};
		ids := fapp.fuzz_ui_reset(ui_fixtures[pick(*g, ui_fixtures.count)]);
		kept := NewArray(ids.count, string);
		defer { for kept free(it); array_free(kept); }
		for ids kept[it_index] = copy_string(it);
		gen_real_ids = kept;
		fapp.fuzz_ui_open(pick(*g, 256));
		fapp.fuzz_ui_frame();
		now: s64 = 1700000000;
		n := 0;
		while !done(*g) && n < 48 {
			n += 1;
			now += 1;
			r := pick(*g, 17);
			if r < 7 {
				name := EVENTS[pick(*g, EVENTS.count)];
				event := gen_map(*g, 3);
				if replaying print("% %\n", name, json_of(event));
				fapp.fuzz_ui_event(name, event, now);
				fapp.fuzz_ui_frame();
			} else {
				x, y := pick(*g, 64) * 20, pick(*g, 36) * 20;
				line: string;
				if r == {
					case 7; #through;
					case 8; #through;
					case 9; line = tprint("click % %", x, y);
					case 10; line = tprint("rclick % %", x, y);
					case 11; line = tprint("move % %", x, y);
					case 12; line = tprint("scroll 0 %", pick(*g, 4000) - 2000);
					case 13; line = "go_home";
					case 14; fapp.fuzz_ui_open(pick(*g, 256));
					case 15; line = "resize 800 600";
					case 16; line = tprint("key % %", pick_of(*g, UI_KEYS), pick_of(*g, UI_MODS));
				}
				if replaying print("%\n", line);
				if line fapp.fuzz_ui_command(line);
				fapp.fuzz_ui_frame();
			}
			check_store(fapp.fuzz_ui_store());
		}
	} else {
		print("fuzz: `ui` needs its own binary: jai build.jai - fuzz ui\n");
		exit(2);
	}
}

// ---- Markdown: combinations of its syntax ----

MD_PIECES :: string.["*", "**", "***", "_", "__", "~~", "||", "`", "``", "```", "```js\n", "\n", "\n\n", "> ", ">>> ", "# ", "## ", "### ", "-# ", "- ", "* ", "1. ",
	"\\", "<@1>", "<@!1>", "<@&2>", "<#3>", "<a:x:1>", "<:x:1>", "<t:1:R>", "<t:", "<id:customize>", "@everyone", "@here", "[", "]", "(", ")", "](", "[a](https://a.b)", "[a](<https://a.b>)",
	"https://a.b/c_d", "http://", "<https://a.b>", "<", ">", "&lt;", ":smile:", " ", "a", "word", "\t", "\xf0\x9f\x98\x80", "\xff", "\xe2\x80\x8d", "\r\n"];

run_markdown :: (data: []u8) {
	g := Gen.{b = data};
	sb: String_Builder;
	sb.allocator = temp;
	while !done(*g) {
		piece := pick_of(*g, MD_PIECES);
		for 0..(ifx pick(*g, 8) == 0 then pick(*g, 16) else 0) append(*sb, piece);
	}
	text := builder_to_string(*sb,, temp);
	md_parse(text);
	md_inline(text);
	md_code_lines(text);
	for 0..min(text.count, 8) md_in_code_block(text, it);
}

// ---- Superlinear time ----

SCALE_MD :: string.["*", "**", "_", "__", "~~", "||", "`", "``", "[", "[a](", "](", "(", "<", "<@", "<t:", "<:a:", "\\", "> ", "```", "```\n", "\n", "http://a.b/(", "*_", "~~||", "[`", " "];
SCALE_JSON :: string.["[", "{\"a\":", "\"", "\\", "1", "-", "[[],", "{\"a\":1,"];
SCALE_SVG :: string.["<g>", "<", "<a b=\"", "&", "<!--", "<path d=\"M", "1 ", "<?", "<![CDATA["];
SCALE_ALTSVC :: string.["h3=\":1\",", "\"", ",", ";", "a=", "\\"];
SCALE_PAGE :: string.["<", "<meta ", "<meta a=\"", "<title>", "&", "&amp;", "<!--", "<meta property=", "'", "\""];

scale_one :: (name: string, pattern: string, f: (text: string), quiet := false) -> bool {
	time_of :: (f: (text: string), pattern: string, n: int) -> float64 {
		sb: String_Builder;
		for 1..n / pattern.count append(*sb, pattern);
		text := builder_to_string(*sb);
		defer free(text);
		best: float64 = 1000000000;
		for 1..3 {
			reset_temporary_storage();
			t := seconds_since_init();
			f(text);
			best = min(best, seconds_since_init() - t);
		}
		return best;
	}
	a := time_of(f, pattern, 16 << 10);
	b := time_of(f, pattern, 64 << 10);
	// Linear is 4x. Under a millisecond at the larger size is noise.
	if b < 0.001 || b < a * 8 return true;
	if !quiet print("fuzz scale: % on repeated \"%\": % ms at 16 KiB, % ms at 64 KiB\n", name, pattern, a * 1000, b * 1000);
	return false;
}

scale_sink: int;

run_scale :: () -> bool {
	ok := true;
	// A check that has never failed proves nothing: this scan from every 8th byte must be caught.
	quadratic :: (t: string) {
		for i: 0..t.count / 8 - 1 for j: i * 8..t.count - 1 scale_sink += t[j];
	}
	if scale_one("self-test", "ab", quadratic, quiet = true) {
		print("fuzz scale: a quadratic scan passed, so the check is broken\n");
		ok = false;
	}
	for SCALE_MD if !scale_one("markdown", it, (t: string) { md_parse(t); md_inline(t); }) ok = false;
	for SCALE_JSON if !scale_one("json", it, (t: string) { etf.from_json(t,, temp); }) ok = false;
	for SCALE_SVG if !scale_one("svg", it, (t: string) { vector.parse_svg(t, temp); }) ok = false;
	for SCALE_ALTSVC if !scale_one("altsvc", it, (t: string) { altsvc.parse(t); }) ok = false;
	for SCALE_PAGE if !scale_one("page", it, (t: string) { serve.scan_page(t); }) ok = false;
	return ok;
}

// ---- The fence allocator ----

PAGE :: 4096;
QUARANTINE :: 4096;

Fence_Head :: struct {
	magic: u64;
	size: s64;   // The caller's.
	mapped: s64; // Head page, data pages and guard page.
	next, prev: *Fence_Head;
	freed: bool;
}
FENCE_MAGIC :: 0xFE7CE_0000_C0DE;

fence_mu: locks.Mutex;
fence_live: *Fence_Head;
fence_ring: [QUARANTINE]*Fence_Head;
fence_at: int;

#if OS == .WINDOWS {
	kernel32 :: #system_library "kernel32";
	VirtualAlloc :: (addr: *void, size: u64, type: u32, protect: u32) -> *void #foreign kernel32;
	VirtualFree :: (addr: *void, size: u64, type: u32) -> s32 #foreign kernel32;
	VirtualProtect :: (addr: *void, size: u64, protect: u32, old: *u32) -> s32 #foreign kernel32;
	CreateFileA :: (name: *u8, access: u32, share: u32, security: *void, disposition: u32, flags: u32, template: *void) -> *void #foreign kernel32;
	CreateFileMappingA :: (file: *void, security: *void, protect: u32, high: u32, low: u32, name: *u8) -> *void #foreign kernel32;
	MapViewOfFile :: (mapping: *void, access: u32, high: u32, low: u32, n: u64) -> *void #foreign kernel32;
	map_file :: (path: string, n: s64) -> *u8 {
		file := CreateFileA(temp_c_string(path), 0xC000_0000, 3, null, 2, 0x80, null); // Read and write, created afresh.
		mapping := CreateFileMappingA(file, null, 0x04, 0, xx n, null);
		return ifx mapping then MapViewOfFile(mapping, 0xF001F, 0, 0, 0) else null;
	}
	map_pages :: (n: s64) -> *u8 { return VirtualAlloc(null, xx n, 0x3000, 0x04); }
	unmap_pages :: (p: *void, n: s64) { VirtualFree(p, 0, 0x8000); }
	block_pages :: (p: *void, n: s64) { old: u32; VirtualProtect(p, xx n, 0x01, *old); }
} else {
	#import "POSIX";
	map_file :: (path: string, n: s64) -> *u8 {
		fd := open(temp_c_string(path), O_RDWR | O_CREAT | O_TRUNC, 0x1A4);
		if fd < 0 || ftruncate(fd, n) != 0 return null;
		p := mmap(null, xx n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
		return ifx p == MAP_FAILED then null else p;
	}
	map_pages :: (n: s64) -> *u8 {
		p := mmap(null, xx n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		return ifx p == MAP_FAILED then null else p;
	}
	unmap_pages :: (p: *void, n: s64) { munmap(p, xx n); }
	block_pages :: (p: *void, n: s64) { mprotect(p, xx n, PROT_NONE); }
}

too_big :: (size: s64) {
	if size <= MAX_ALLOC return;
	print("fuzz alloc: one allocation of % bytes\n", size);
	exit(5);
}

fence_head :: (p: *void) -> *Fence_Head {
	page := cast(u64) p & ~cast(u64) (PAGE - 1);
	h := cast(*Fence_Head) (page - PAGE);
	if h.magic != FENCE_MAGIC {
		print("fuzz fence: free or resize of %, which this allocator never returned\n", p);
		if context.stack_trace print_stack_trace(context.stack_trace);
		exit(5);
	}
	return h;
}

fence_alloc :: (size: s64) -> *void {
	too_big(size);
	rounded := (size + 15) & ~15; // Callers expect 16-byte alignment, so an overrun under that goes unseen.
	data_pages := max((rounded + PAGE - 1) & ~(PAGE - 1), PAGE);
	mapped := PAGE + data_pages + PAGE;
	base := map_pages(mapped);
	if !base { print("fuzz fence: out of memory mapping % bytes\n", mapped); exit(5); }
	block_pages(base + mapped - PAGE, PAGE);
	h := cast(*Fence_Head) base;
	h.* = .{magic = FENCE_MAGIC, size = size, mapped = mapped, next = fence_live};
	if fence_live fence_live.prev = h;
	fence_live = h;
	return base + mapped - PAGE - rounded;
}

fence_free :: (p: *void) {
	h := fence_head(p);
	if h.freed {
		print("fuzz fence: double free of %\n", p);
		exit(5);
	}
	h.freed = true;
	if h.prev h.prev.next = h.next; else fence_live = h.next;
	if h.next h.next.prev = h.prev;
	block_pages((cast(*u8) h) + PAGE, h.mapped - PAGE);
	old := fence_ring[fence_at];
	if old unmap_pages(old, old.mapped);
	fence_ring[fence_at] = h;
	fence_at = (fence_at + 1) % QUARANTINE;
}

fence_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void {
	if mode == {
		case .ALLOCATE;
			locks.guard(*fence_mu);
			return fence_alloc(size);
		case .RESIZE;
			locks.guard(*fence_mu);
			p := fence_alloc(size);
			if old_memory {
				h := fence_head(old_memory);
				memcpy(p, old_memory, min(min(size, old_size), h.size));
				fence_free(old_memory);
			}
			return p;
		case .FREE;
			if old_memory { locks.guard(*fence_mu); fence_free(old_memory); }
			return null;
		case .CAPS;
			if old_memory { name := cast(*string) old_memory; name.* = "fuzz fence"; }
			return null;
	}
	return null;
}

// Whatever an input left behind goes with it, so a leak on an error path doesn't exhaust the address space.
fence_reset :: () {
	locks.guard(*fence_mu);
	while fence_live {
		p := fence_live;
		fence_live = p.next;
		unmap_pages(p, p.mapped);
	}
}

// The heap for inputs off the fence: only the size tripwire.
plain_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void {
	if mode == .ALLOCATE || mode == .RESIZE too_big(size);
	a := context.default_allocator;
	return a.proc(mode, size, old_size, old_memory, a.data);
}

// ---- Coverage ----
//
// build.jai's cover() makes every block of src/ bump context.fuzz_cov, on any thread that inherits this
// context. An input that hits a block, or hits it a new order of magnitude of times, joins the corpus:
// that is what lets runs build on each other instead of each starting over from the seeds.

#add_context fuzz_cov: *u8;

CORPUS_DIR :: "build/fuzz_corpus";
MAX_CORPUS :: 1 << 16;

cov_blocks: int;
cov_map: *u8;
cov_seen: *u8;
COV_BUCKET :: #run () -> [256]u8 {
	out: [256]u8;
	for 1..255 {
		out[it] = xx ifx it == 1 then 1 else ifx it == 2 then 2 else ifx it == 3 then 4
			else ifx it < 8 then 8 else ifx it < 16 then 16 else ifx it < 32 then 32 else ifx it < 128 then 64 else 128;
	}
	return out;
}();

cov_init :: () {
	path := tprint("%.blocks", path_strip_extension(get_path_of_running_executable())); // A soak runs a copy.
	text, ok := read_entire_file(path);
	if !ok { print("fuzz: no %\n", path); exit(2); }
	for cast([]u8) text if it == #char "\n" cov_blocks += 1;
	free(text);
	cov_map = alloc(cov_blocks + 8);
	cov_seen = alloc(cov_blocks + 8);
	memset(cov_map, 0, cov_blocks + 8);
	memset(cov_seen, 0, cov_blocks + 8);
	context.fuzz_cov = cov_map;
}

// cov_new takes what the last input hit into cov_seen; true when any of it is new.
cov_new :: () -> bool #no_abc {
	found := false;
	for i: 0..cov_blocks - 1 {
		hit := cov_map[i];
		if !hit continue;
		bit := COV_BUCKET[hit];
		if bit & ~cov_seen[i] {
			cov_seen[i] |= bit;
			found = true;
		}
	}
	return found;
}

cov_reached :: () -> int {
	n := 0;
	for i: 0..cov_blocks - 1 if cov_seen[i] n += 1;
	return n;
}

// tools/fuzz_report.py reads these to show what no target reaches.
cov_save :: (target: string) {
	make_directory_if_it_does_not_exist("build/fuzz_cov", recursive = true);
	write_entire_file(tprint("build/fuzz_cov/%.bin", target), cov_seen, cov_blocks);
}

// ---- Running ----

MAX_INPUT :: 32 << 20;
MAX_GROWN :: 64 << 10; // What mutation may grow an input to.

input_started: s64; // Milliseconds, 0 between inputs. The watchdog thread reads it.
hang_limit_s := HANG_S;
last_path: string;
last_map: *u8;
replaying: bool; // `one` shows what a generator made of its input, which is how to read a failure.

now_ms :: () -> s64 { return to_milliseconds(current_time_monotonic()); }

watchdog :: (thread: *Thread) -> s64 {
	while true {
		sleep_milliseconds(100);
		t := atomic_read(*input_started);
		if t && now_ms() - t > hang_limit_s * 1000 {
			print("fuzz hang: an input ran past % s, saved as %\n", hang_limit_s, last_path);
			exit(3);
		}
	}
	return 0;
}

hash_of :: (b: []u8) -> u64 {
	h: u64 = 0xcbf2_9ce4_8422_2325;
	for b { h ^= it; h *= 0x100_0000_01b3; }
	return h;
}

run_one :: (target: Target, input: []u8) {
	n := min(input.count, MAX_INPUT);
	(cast(*s64) last_map).* = n;
	memcpy(last_map + 8, input.data, n);
	// With the debugger on, every allocation must reach the heap it tracks: skip the fence.
	// A gateway's writer thread would race the fence, which takes no lock.
	fence := !MEM_DEBUG && hash_of(input) % FENCE_ONE_IN == 0 && target.name != "serve" && target.name != "ui";
	hang_limit_s = ifx fence || target.name == "ui" then HANG_FENCE_S else HANG_S;
	memset(cov_map, 0, cov_blocks);
	atomic_swap(*input_started, now_ms());
	{
		push_allocator(ifx fence then Allocator.{fence_proc, null} else .{plain_proc, null});
		target.run(input);
	}
	atomic_swap(*input_started, 0);
	if fence fence_reset();
}

// Seeds that only code can make: real encodings, and blobs of the exact length a parser wants, so that a
// mutation gets past the length check to the fields. A signature or hash still stops it past that; the
// layers behind one need a target of their own that holds real keys.
add_built_seeds :: (name: string, seeds: *[..][]u8) {
	add :: (s: string) #expand { array_add(`seeds, cast([]u8) s); }
	sized :: (n: int, head: ..u8) -> []u8 #expand {
		b := NewArray(n, u8);
		memcpy(b.data, head.data, head.count);
		array_add(`seeds, b);
		return b;
	}
	if name == {
		case "etf"; #through;
		case "json";
			// Real gateway traffic, with the shapes and sizes Discord sends.
			text := read_entire_file("tests/data/gw_a.jsonl");
			kept := 0;
			for line: split(text, "\n") {
				if line.count > 8192 || kept >= 32 continue;
				v, err := etf.from_json(line);
				if err != .None continue;
				kept += 1;
				if name == "json" add(line);
				else {
					b, e := etf.encode(v);
					if e == .None array_add(seeds, b);
				}
			}
		case "rtp";
			b := sized(voice.DISCOVERY_LEN);
			voice.build_discovery_response(b, 7, "203.0.113.5", 50000);
			r := NewArray(256, u8);
			n := voice.build_report(r, 1, true, 2, 3, 4, 5, voice.Report_Block.[.{}]);
			r.count = n;
			array_add(seeds, r);
		case "e2e";
			sized(e2e.HELLO_BYTES, e2e.VERSION, xx e2e.Kind.Hello);
			sized(e2e.INIT_PREFIX_BYTES + e2e.HEADER_BYTES + e2e.TAG_BYTES + 1, e2e.VERSION, xx e2e.Kind.Init);
			b := e2e.Body.{content = .Text, text = "hi"};
			array_add(seeds, e2e.encode_body(b));
		case "url";
			add("http://[::1]/");
			add("Wed, 21 Oct 2026 07:28:00 GMT");
			add("socks5://user:pw@127.0.0.1:1080");
			add("2026-11-02T00:00:00.000000+00:00");
			add("fastcord://invite/abc");
		case "authority";
			sized(authority.CHECKPOINT_BYTES);
			u := sized(2 + authority.CHECKPOINT_BYTES + crypto.SLHDSA_SIGNATURE_BYTES + 2, 1);
			k := sized(8 + 2 + 64 + 32 + 32 + 64 + 32 + 32 + 32, #char "f", #char "c", #char "k", #char "e", #char "y", #char "v", #char "1", #char "\n");
		case "http";
			add("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n");
			add("HTTP/1.1 301 Moved\r\nLocation: /x\r\nConnection: close\r\n\r\nbody until close");
			add("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n");
	}
}

json_grown: int;

// Parses the input and changes a few values in the tree: extreme numbers, other types, repeated items.
mutate_json :: (src: []u8) -> []u8, bool {
	root, err := etf.from_json(cast(string) src,, temp);
	if err != .None return .[], false;
	walk :: (v: *etf.Value, depth: int) {
		ODD :: etf.Value.[.{}, .{kind = .Bool, b = true}, .{kind = .Int, i = 0}, .{kind = .Int, i = -1}, .{kind = .Int, i = 0x7FFF_FFFF_FFFF_FFFF}, .{kind = .Int, i = 1000000000}, .{kind = .Float, f = 1000000000000000}, .{kind = .String}, .{kind = .List}, .{kind = .Map}];
		if random_get() % 24 == 0 { v.* = ODD[random_get() % ODD.count]; return; }
		if depth > 32 return;
		if v.kind == .List && v.list.count {
			if random_get() % 16 == 0 && json_grown < 64 << 10 {
				// Many of one item: the shape of counts nobody capped. Nested repeats multiply, so bound them.
				n := v.list.count * (cast(int) (random_get() % 16) + 2);
				json_grown += n;
				out := NewArray(n, etf.Value,, temp);
				for * out it.* = v.list[it_index % v.list.count];
				v.list = out;
			}
			for * v.list walk(it, depth + 1);
		} else if v.kind == .Map {
			if v.map.count && random_get() % 16 == 0 {
				v.map[random_get() % cast(u64) v.map.count] = v.map[v.map.count - 1];
				v.map.count -= 1;
			}
			for * v.map walk(*it.value, depth + 1);
		}
	}
	json_grown = 0;
	walk(*root, 0);
	// Repeated items share their children, so a repeat inside one multiplies past what json_grown counted.
	nodes :: (v: etf.Value, budget: *int, depth: int) {
		budget.* -= 1;
		if budget.* <= 0 || depth > 64 return;
		if v.kind == .List for v.list nodes(it, budget, depth + 1);
		if v.kind == .Map for v.map nodes(it.value, budget, depth + 1);
	}
	budget := 256 << 10;
	nodes(root, *budget, 0);
	if budget <= 0 return .[], false;
	return cast([]u8) json_of(root), true;
}

// pick_seed favours what coverage found last: that's where the unexplored code is.
pick_seed :: (seeds: [][]u8) -> []u8 {
	n := cast(u64) seeds.count;
	if random_get() % 2 return seeds[seeds.count - 1 - cast(int) (random_get() % min(n, 32))];
	return seeds[random_get() % n];
}

mutate :: (seeds: [][]u8) -> []u8 {
	src := pick_seed(seeds);
	out: [..]u8;
	out.allocator = temp;
	array_add(*out, ..src);
	INTERESTING :: u8.[0, 1, 0x7F, 0x80, 0xFF, #char "[", #char "{", #char "\"", #char "-", #char "9"];
	for 0..cast(int) (random_get() % 4) {
		if !out.count { array_add(*out, xx random_get()); continue; }
		at := cast(int) (random_get() % cast(u64) out.count);
		if random_get() % 7 == {
		case 6; // A sequence goes on past its end with another's, so runs grow deeper than either.
			other := pick_seed(seeds);
			if out.count + other.count <= MAX_GROWN array_add(*out, ..other);
		case 0; out[at] ^= cast(u8) (1 << (random_get() % 8));
		case 1; out[at] = INTERESTING[random_get() % INTERESTING.count];
		case 2; out[at] = xx random_get();
		case 3; // Delete a run.
			n := min(cast(int) (random_get() % 16) + 1, out.count - at);
			for at..out.count - n - 1 out[it] = out[it + n];
			out.count -= n;
		case 4; // Repeat a run.
			n := min(cast(int) (random_get() % 16) + 1, out.count - at);
			piece := array_copy(array_view(out, at, n),, temp);
			for 1..cast(int) (random_get() % 8) + 1 array_add(*out, ..piece);
		case 5; // Splice in part of another seed.
			other := seeds[random_get() % cast(u64) seeds.count];
			if !other.count continue;
			from := cast(int) (random_get() % cast(u64) other.count);
			array_add(*out, ..array_view(other, from, min(256, other.count - from)));
		}
	}
	return out;
}

fresh :: () -> []u8 {
	out := NewArray(cast(int) (random_get() % 1024) + 16, u8, false,, temp);
	for * out it.* = xx random_get();
	return out;
}

main :: () {
	args := get_command_line_arguments();
	name := ifx args.count > 1 then args[1] else "";
	netio.no_network = true;
	if name == "list" { for TARGETS if it.name != "ui" print("%\n", it.name); return; }
	if name == "scale" { if !run_scale() exit(6); return; }
	ti := -1;
	for TARGETS if it.name == name ti = it_index;
	if ti < 0 { print("fuzz: unknown target %\n", name); exit(2); }
	target := TARGETS[ti];
	make_directory_if_it_does_not_exist("build/fuzz_inputs", recursive = true);
	cov_init();
	last_path = sprint("build/fuzz_inputs/%.last", target.name);
	last_map = map_file(last_path, MAX_INPUT + 8);
	if !last_map { print("fuzz: can't map %\n", last_path); exit(2); }
	wd: Thread;
	thread_init(*wd, watchdog);
	thread_start(*wd);
	// `one <file>` runs one input and nothing else, for tools/fuzz_min.py.
	if args.count > 3 && args[2] == "one" {
		data, ok := read_entire_file(args[3]);
		if !ok exit(2);
		replaying = true;
		run_one(target, cast([]u8) data);
		exit(0);
	}
	seconds := ifx args.count > 2 then string_to_int(args[2]) else 30;
	seeds: [..][]u8;
	dir := tprint("tests/fuzz/%", target.name);
	for ifx file_exists(dir) then file_list(dir) else .[] {
		data, ok := read_entire_file(it);
		if !ok continue;
		reset_temporary_storage();
		run_one(target, cast([]u8) data);
		cov_new();
		array_add(*seeds, cast([]u8) data);
	}
	replayed := seeds.count;
	// What earlier runs found; they stop at nothing here, since a bad entry would have stopped them.
	corpus_dir := sprint("%/%", CORPUS_DIR, target.name);
	make_directory_if_it_does_not_exist(corpus_dir, recursive = true);
	for file_list(corpus_dir) {
		data, ok := read_entire_file(it);
		if !ok continue;
		reset_temporary_storage();
		run_one(target, cast([]u8) data);
		if cov_new() array_add(*seeds, cast([]u8) data);
		else free(data);
	}
	corpus := seeds.count - replayed;
	for split(target.fixtures, " ") {
		if !it continue;
		data, ok := read_entire_file(it);
		if ok array_add(*seeds, cast([]u8) data);
	}
	add_built_seeds(target.name, *seeds);
	if target.seed array_add(*seeds, cast([]u8) target.seed);
	if !seeds array_add(*seeds, .[]);
	random_seed(cast(u64) to_milliseconds(current_time_consensus()));
	start := seconds_since_init();
	runs := 0;
	while seconds_since_init() - start < xx seconds {
		reset_temporary_storage();
		input: []u8;
		if target.input == .Choices && random_get() % 2 == 0 input = fresh();
		else if target.input == .Json && random_get() % 4 {
			ok: bool;
			input, ok = mutate_json(seeds[random_get() % cast(u64) seeds.count]);
			if !ok input = mutate(seeds);
		} else input = mutate(seeds);
		run_one(target, input);
		runs += 1;
		if cov_new() && seeds.count < MAX_CORPUS {
			kept := array_copy(input);
			array_add(*seeds, kept);
			write_entire_file(tprint("%/%.bin", corpus_dir, formatInt(hash_of(kept), base = 16)), kept.data, kept.count);
		}
	}
	cov_save(target.name);
	#if MEM_DEBUG report_memory_leaks();
	print("fuzz %: % files replayed, % runs, no failure; % blocks reached of %, corpus % -> %\n", target.name, replayed, runs, cov_reached(), cov_blocks, corpus, seeds.count - replayed);
	for i: 0..hit_count - 1 print("  % took % of % (% in 1000)\n", hits[i].name, hits[i].ok, hits[i].all, hits[i].ok * 1000 / hits[i].all);
	exit(0); // The watchdog never returns.
}
