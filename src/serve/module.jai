/// A self-hosted fastcord server (`fastcord -serve`): one SQLite file, TLS 1.3 under a pinned self-signed certificate, ALPN fc/1.
#import "Basic";
#import "Atomics";
#import "Thread";
#import "String";
crypto :: #import "crypto";
etf :: #import "etf";
http :: #import "http";
locks :: #import "locks";
netio :: #import "netio";
sqlite :: #import "sqlite";
tls :: #import "tls";

ALPN :: "fc/1";
HEARTBEAT_INTERVAL_MS :: 41_250;

Server :: struct {
	db: *sqlite.DB;
	id: [16]u8;      // Sent as SNI and part of every invite, so one host can serve several servers.
	pin: [32]u8;     // BLAKE3 of the certificate: what invites carry and clients check.
	ctx: *tls.SSL_CTX;
	listener: *netio.Listener;
	accept_thread: *Thread;
	mu: locks.Mutex; // Guards conns.
	conns: [..]*Conn;
}

Conn :: struct {
	server: *Server;
	tcp: *netio.Tcp;
	s: netio.Stream;
	thread: *Thread;
	done: bool; // atomic; the thread has finished with s.
}

// open makes the server file if needed: its ID, TLS key and certificate live in it, so the invite stays
// valid for as long as the file does.
open :: (path: string) -> *Server, bool {
	db, ok := sqlite.open(path);
	if !ok return null, false;
	s := New(Server);
	s.db = db;
	if !sqlite.exec(db, "CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v BLOB NOT NULL);") { close(s); return null, false; }

	id := meta_get(s, "id");
	key := meta_get(s, "tls_key");
	cert := meta_get(s, "tls_cert");
	if id.count != 16 || key.count != 32 || !cert.count {
		crypto.random_bytes(s.id);
		priv, _, made := crypto.p256_generate();
		if !made { close(s); return null, false; }
		cert = tls.selfsigned_cert(priv,, temp);
		key = array_copy(cast([]u8) priv,, temp);
		ok = sqlite.exec(db, "BEGIN;")
			&& meta_put(s, "id", s.id)
			&& meta_put(s, "tls_key", key)
			&& meta_put(s, "tls_cert", cert)
			&& sqlite.exec(db, "COMMIT;");
		if !ok { close(s); return null, false; }
	} else {
		memcpy(s.id.data, id.data, 16);
	}
	k: [32]u8;
	memcpy(k.data, key.data, 32);
	s.pin = crypto.blake3(cert);
	s.ctx = tls.server_ctx(k, cert, ALPN);
	crypto.zero(k);
	if !s.ctx { close(s); return null, false; }
	return s, true;
}

// invite_url is what a member pastes into fastcord to join: the pin, where to connect and which server.
invite_url :: (s: *Server, host: string, port: int, code: string, allocator := temp) -> string {
	return sprint("fc://%@%:%/%/%", hex(s.pin,, temp), host, port, hex(s.id,, temp), code,, allocator);
}

id_hex :: (s: *Server, allocator := temp) -> string { return hex(s.id,, allocator); }
pin_hex :: (s: *Server, allocator := temp) -> string { return hex(s.pin,, allocator); }

// listen accepts connections on a thread until stop. Port 0 picks a free port: see s.listener.port.
listen :: (s: *Server, port: int) -> bool {
	l, err := netio.listen_tcp(port);
	if err != .None return false;
	s.listener = l;
	s.accept_thread = spawn(s, accept_loop);
	return true;
}

// stop closes the listener and every connection, waits for their threads, then frees the server.
stop :: (s: *Server) {
	if s.listener {
		netio.close_listener(s.listener);
		locks.join(s.accept_thread);
		free(s.listener);
	}
	// The accept thread has returned, so nothing else touches conns now.
	for s.conns netio.shutdown(netio.tcp_stream(it.tcp)); // Not it.s: its thread may be replacing it.
	for s.conns {
		locks.join(it.thread);
		netio.close(it.s);
		free(it);
	}
	array_free(s.conns);
	close(s);
}

#scope_file

close :: (s: *Server) {
	if s.ctx tls.SSL_CTX_free(s.ctx);
	sqlite.close(s.db);
	free(s);
}

hex :: (b: []u8) -> string {
	DIGITS :: "0123456789abcdef";
	out := alloc_string(b.count * 2);
	for b { out[2 * it_index] = DIGITS[it >> 4]; out[2 * it_index + 1] = DIGITS[it & 15]; }
	return out;
}

meta_get :: (s: *Server, k: string) -> []u8 {
	st := sqlite.prepare(s.db, "SELECT v FROM meta WHERE k = ?;");
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, k);
	if sqlite.step(st) != .Row return .[];
	return array_copy(sqlite.col_blob(st, 0),, temp);
}

meta_put :: (s: *Server, k: string, v: []u8) -> bool {
	return sqlite.run(s.db, "INSERT OR REPLACE INTO meta(k, v) VALUES(?, ?);", k, v);
}

spawn :: (data: $D, proc: (D)) -> *Thread {
	Spawned :: struct { #as thread: Thread; arg: D; run: (D); }
	t := New(Spawned);
	t.arg, t.run = data, proc;
	thread_init(t, (t: *Thread) -> s64 { s := cast(*Spawned) t; s.run(s.arg); return 0; });
	thread_start(t);
	return t;
}

accept_loop :: (s: *Server) {
	while true {
		tcp, err := netio.accept_tcp(s.listener);
		if err == .Closed break;
		if err != .None continue;
		c := New(Conn);
		c.server, c.tcp, c.s = s, tcp, netio.tcp_stream(tcp);
		locks.lock(*s.mu);
		// Finished connections are reaped here, so a long-running server holds only live ones.
		for s.conns if atomic_load(*it.done) {
			locks.join(it.thread);
			netio.close(it.s);
			free(it);
			remove it;
		}
		array_add(*s.conns, c);
		c.thread = spawn(c, serve_conn);
		locks.unlock(*s.mu);
	}
}

// serve_conn runs one connection's TLS handshake and HTTP/1.1 requests, which end in a gateway upgrade.
// Its stream is closed by whoever reaps it (accept_loop or stop), so a shutdown never races a close.
serve_conn :: (c: *Conn) {
	defer atomic_store(*c.done, true);
	session, _, _ := tls.accept(c.s, c.server.ctx);
	if !session return;
	c.s = tls.stream(session);
	name := tls.server_name(session);
	if name && name != id_hex(c.server) return;

	h: http.H1_Conn;
	http.h1_init(*h, c.s, .{max_header_bytes = 16 << 10, max_headers = 64, max_body = 1 << 20});
	defer http.h1_destroy(*h, false);
	while true {
		reset_temporary_storage();
		req, err := http.h1_read_request(*h);
		defer http.request_destroy(*req);
		if err != .None {
			if err == .Too_Large http.h1_write_response(c.s, 413, .[], .[]);
			else if err == .Protocol http.h1_write_response(c.s, 400, .[], .[]);
			return;
		}
		if http.header_has_token(req.headers, "upgrade", "websocket") {
			gateway(c, req);
			return;
		}
		if http.h1_write_response(c.s, 404, .[], .[]) != .None return;
	}
}

gateway :: (c: *Conn, req: http.Request) {
	key, has_key := http.header_get(req.headers, "sec-websocket-key");
	// The plain profile sends no compress parameter; a client asking for zstd would fail to read us.
	if !has_key || !begins_with(req.path, "/?") || !contains(req.path, "encoding=etf") || contains(req.path, "compress=") {
		http.h1_write_response(c.s, 400, .[], .[]);
		return;
	}
	accept := http.ws_accept_for_key(key,, temp);
	headers := http.Header.[.{"Upgrade", "websocket"}, .{"Connection", "Upgrade"}, .{"Sec-WebSocket-Accept", accept}];
	if http.h1_write_response(c.s, 101, headers, .[], "Switching Protocols") != .None return;
	netio.set_timeout(c.s, HEARTBEAT_INTERVAL_MS * 2);

	ws := http.ws_attach(c.s, .{server = true, max_message = 1 << 20});
	defer http.ws_destroy(ws);

	hello := etf.map_builder(,, temp);
	etf.map_put(*hello, "heartbeat_interval", etf.vint(HEARTBEAT_INTERVAL_MS));
	if !send(ws, 10, etf.vmap(etf.map_done(*hello))) return;

	msg: [..]u8;
	defer array_free(msg);
	while true {
		reset_temporary_storage();
		msg.count = 0;
		type, err := http.ws_recv(ws, *msg);
		if err != .None || type != .Binary return;
		v, derr := etf.decode(msg,, temp);
		if derr != .None || v.kind != .Map { http.ws_close(ws, 4002, "Error while decoding payload."); return; }
		op, _ := etf.map_get(v.map, "op");
		if op.kind != .Int { http.ws_close(ws, 4002, "Error while decoding payload."); return; }
		if op.i == {
			case 1;
				if !send(ws, 11, .{}) return;
			case;
				http.ws_close(ws, 4001, "Unknown opcode.");
				return;
		}
	}
}

send :: (ws: *http.Ws_Conn, op: int, d: etf.Value) -> bool {
	m := etf.map_builder(4,, temp);
	etf.map_put(*m, "op", etf.vint(op));
	etf.map_put(*m, "d", d);
	etf.map_put(*m, "s", .{});
	etf.map_put(*m, "t", .{});
	bytes, err := etf.encode(etf.vmap(etf.map_done(*m)),, temp);
	return err == .None && http.ws_send(ws, .Binary, bytes) == .None;
}
