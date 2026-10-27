// QR code login: the remote auth gateway (useAuthWebsocket in the client's
// login chunk, protocol v2). Per socket the client makes an RSA-OAEP key pair
// (2048 bits, e = 65537, SHA-256), sends {"op":"init","encoded_public_key":
// base64(SPKI)}, answers {"op":"nonce_proof"} with base64url(decrypted nonce),
// and on pending_remote_init shows https://discord.com/ra/<fingerprint>
// (fingerprint = base64url(SHA-256(SPKI)), checked against the server's).
// pending_ticket carries the scanning user ("id:discriminator:avatar:username",
// encrypted); pending_login a ticket that POST /users/@me/remote-auth/login
// trades for the encrypted token. Heartbeats {"op":"heartbeat"} start at
// random()*interval after hello, then every interval; a missing ack, a close
// or an error restarts with a new key pair after Backoff(1500, 30000);
// "cancel" (and "Not me, start over") restarts at once. The server closes the
// socket after hello's timeout_ms, so the QR code refreshes the same way.

REMOTE_AUTH_HOST :: "remote-auth-gateway.discord.gg";
REMOTE_AUTH_URL :: "wss://remote-auth-gateway.discord.gg/?v=2";
REMOTE_AUTH_QR_PREFIX :: "https://discord.com/ra/";

Ra_Step :: enum u8 {
	Initializing;
	Pending_Remote_Init; // QR code shown
	Pending_Ticket; // scanned: "Check your phone!"
	Pending_Login; // approved on the phone: logging in
	Finish;
}

// ---- protocol core (no I/O; unit-tested with a fake server) ----

Ra_Session :: struct {
	key: *tls.EVP_PKEY; // BoringSSL
	spki: []u8;
	fingerprint: string;
	step: Ra_Step;
	heartbeat_interval: s64;
	timeout_ms: s64;
	user_id: Snowflake;
	discriminator: string;
	avatar: string; // "" = default avatar
	username: string;
	ticket: string;
	allocator: Allocator;
}

Ra_Action :: enum u8 {
	None;
	Send; // reply holds the message to send
	Hello; // heartbeat_interval / timeout_ms set
	Heartbeat_Ack;
	Show_Qr; // pending_remote_init: fingerprint verified
	Show_User; // pending_ticket: user fields set
	Login; // pending_login: ticket set
	Cancel; // the server cancelled: restart now
	Fail; // bad message / fingerprint mismatch: restart with backoff
}

// ra_session_init makes the key pair (generateKey RSA-OAEP 2048; e = 65537 is BoringSSL's default).
ra_session_init :: (s: *Ra_Session, allocator := context.allocator) -> bool {
	s.allocator = allocator;
	ctx := tls.EVP_PKEY_CTX_new_id(tls.EVP_PKEY_RSA, null);
	defer tls.EVP_PKEY_CTX_free(ctx);
	if is_null(ctx) || tls.EVP_PKEY_keygen_init(ctx) != 1 || tls.EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, 2048) != 1 { return false; }
	if tls.EVP_PKEY_keygen(ctx, *s.key) != 1 { return false; }
	return ra_session_derive(s);
}

// ra_session_derive: the SubjectPublicKeyInfo DER (exportKey "spki") and the fingerprint of s.key.
ra_session_derive :: (s: *Ra_Session) -> bool {
	der: *u8;
	n := tls.i2d_PUBKEY(s.key, *der);
	if n <= 0 { return false; }
	defer tls.OPENSSL_free(der);
	s.spki = clone(sub(der, 0, n), s.allocator);
	digest := sha256_bytes(s.spki);
	s.fingerprint = base64url_nopad(view(digest), s.allocator);
	return true;
}

ra_session_destroy :: (s: *Ra_Session) {
	tls.EVP_PKEY_free(s.key);
	delete(s.spki, s.allocator);
	delete(s.fingerprint, s.allocator);
	delete(s.discriminator, s.allocator);
	delete(s.avatar, s.allocator);
	delete(s.username, s.allocator);
	if len(s.ticket) > 0 { crypto.zero_explicit(raw_data(s.ticket), len(s.ticket)); }
	delete(s.ticket, s.allocator);
	s.* = .{};
}

// {"op":"init","encoded_public_key":base64(SPKI)}
ra_init_message :: (s: *Ra_Session, allocator := temp) -> string {
	w: Json;
	json_init(*w, allocator);
	json_obj(*w);
	json_kstr(*w, "op", "init");
	json_kstr(*w, "encoded_public_key", base64.encode(s.spki, allocator = temp));
	json_obj_end(*w);
	return json_string(*w);
}

RA_HEARTBEAT_MESSAGE :: "{\"op\":\"heartbeat\"}";

ra_handle :: (s: *Ra_Session, msg: []u8, allocator := temp) -> Ra_Action, string {
	action: Ra_Action;
	reply: string;
	arena: virtual.Arena;
	virtual.arena_init_growing(*arena);
	defer virtual.arena_destroy(*arena);
	v, ok := parse_json(msg, virtual.arena_allocator(*arena));
	if !ok { return .None, ""; }
	m := vmap(v);
	if fstr(m, "op") == {
	case "hello";
		s.heartbeat_interval = fint(m, "heartbeat_interval");
		s.timeout_ms = fint(m, "timeout_ms");
		return .Hello, "";
	case "heartbeat_ack";
		return .Heartbeat_Ack, "";
	case "nonce_proof";
		plain, dok := ra_decrypt(s, fstr(m, "encrypted_nonce"), temp);
		if !dok { return .Fail, ""; }
		w: Json;
		json_init(*w, allocator);
		json_obj(*w);
		json_kstr(*w, "op", "nonce_proof");
		json_kstr(*w, "nonce", base64url_nopad(plain, temp));
		json_obj_end(*w);
		return .Send, json_string(*w);
	case "pending_remote_init";
		if fstr(m, "fingerprint") != s.fingerprint { return .Fail, ""; } // "bad fingerprint"
		s.step = .Pending_Remote_Init;
		return .Show_Qr, "";
	case "pending_ticket";
		plain, dok := ra_decrypt(s, fstr(m, "encrypted_user_payload"), temp);
		if !dok { return .Fail, ""; }
		id, disc, avatar, name, pok := ra_parse_user(as_string(plain));
		if !pok { return .Fail, ""; } // "Invalid encoded user record."
		delete(s.discriminator, s.allocator);
		delete(s.avatar, s.allocator);
		delete(s.username, s.allocator);
		s.user_id = id;
		s.discriminator = clone(disc, s.allocator);
		s.avatar = clone(ifx avatar == "0" then "" else avatar, s.allocator);
		s.username = clone(name, s.allocator);
		s.step = .Pending_Ticket;
		return .Show_User, "";
	case "pending_login";
		t := fstr(m, "ticket");
		if t == "" { return .Fail, ""; }
		delete(s.ticket, s.allocator);
		s.ticket = clone(t, s.allocator);
		s.step = .Pending_Login;
		return .Login, "";
	case "cancel";
		return .Cancel, "";
	}
	return .None, ""; // "received unsupported message"
}

// ra_decrypt: RSA-OAEP (SHA-256) of a base64 (atob) ciphertext.
ra_decrypt :: (s: *Ra_Session, b64: string, allocator := temp) -> []u8, bool {
	ct, err := base64.decode(b64, allocator = temp);
	if err != null || len(ct) != 256 { return .{}, false; }
	ctx := tls.EVP_PKEY_CTX_new(s.key, null);
	defer tls.EVP_PKEY_CTX_free(ctx);
	out := make_slice(u8, 256, allocator);
	n := cast(u64)(len(out));
	if is_null(ctx) || tls.EVP_PKEY_decrypt_init(ctx) != 1 || tls.EVP_PKEY_CTX_set_rsa_padding(ctx, tls.RSA_PKCS1_OAEP_PADDING) != 1 ||
	   tls.EVP_PKEY_CTX_set_rsa_oaep_md(ctx, tls.EVP_sha256()) != 1 || tls.EVP_PKEY_decrypt(ctx, raw_data(out), *n, raw_data(ct), xx len(ct)) != 1 {
		tls.ERR_clear_error(); // a bad ciphertext must not linger for this thread's next TLS handshake
		return .{}, false;
	}
	return sub(out, 0, n), true;
}

// ra_decrypt_token: the encrypted_token of POST /users/@me/remote-auth/login.
ra_decrypt_token :: (s: *Ra_Session, encrypted_token: string, allocator := context.allocator) -> string, bool {
	pt, ok := ra_decrypt(s, encrypted_token, temp);
	if !ok { return "", false; }
	tok := clone(as_string(pt), allocator);
	crypto.zero_explicit(raw_data(pt), len(pt));
	return tok, true;
}

sha256_bytes :: (b: []u8) -> [32]u8 {
	d: [32]u8;
	tls.SHA256(raw_data(b), xx len(b), *d[0]);
	return d;
}

// "id:discriminator:avatar:username" (/^(\d+):(\d{1,4}):([a-zA-Z0-9_]+):(.*)$/)
ra_parse_user :: (s: string) -> Snowflake, string, string, string, bool {
	id: Snowflake;
	disc: string;
	avatar: string;
	name: string;
	ok: bool;
	rest := s;
	field :: (rest: *string) -> string, bool {
		i := strings.index_byte(rest.*, #char ":");
		if i < 0 { return "", false; }
		f := sub(rest.*, 0, i);
		rest.* = sub_from(rest.*, i + 1);
		return f, true;
	}
	all :: (s: string, pred: (r: u8) -> bool) -> bool {
		for i: 0..len(s)-1 { if !pred(s[i]) { return false; } }
		return true;
	}
	digit :: (r: u8) -> bool {return r >= #char "0" && r <= #char "9";}
	word :: (r: u8) -> bool {return digit(r) || (r >= #char "a" && r <= #char "z") || (r >= #char "A" && r <= #char "Z") || r == #char "_";}
	ids, __e2 := field(*rest); if failed(__e2) return id, disc, avatar, name, __e2;
	__v4, __e3 := field(*rest); if failed(__e3) return id, disc, avatar, name, __e3; disc = __v4;
	__v6, __e5 := field(*rest); if failed(__e5) return id, disc, avatar, name, __e5; avatar = __v6;
	name = rest;
	if len(ids) == 0 || !all(ids, digit) { return id, disc, avatar, name, ok; }
	if len(disc) < 1 || len(disc) > 4 || !all(disc, digit) { return id, disc, avatar, name, ok; }
	if len(avatar) == 0 || !all(avatar, word) { return id, disc, avatar, name, ok; }
	v, pok := strconv.parse_u64(ids);
	if !pok { return id, disc, avatar, name, ok; }
	return cast(Snowflake)(v), disc, avatar, name, true;
}

ra_qr_url :: (fingerprint: string, allocator := temp) -> string {
	return strings.concatenate(string.[REMOTE_AUTH_QR_PREFIX, fingerprint], allocator);
}

// btoa(...).replace(/\//g,"_").replace(/\+/g,"-").replace(/={1,2}$/,"")
base64url_nopad :: (b: []u8, allocator := context.allocator) -> string {
	s := base64.encode(b, allocator = allocator);
	out := transmute([]u8, s);
	n := len(out);
	while n > 0 && get(out, n - 1) == #char "=" { n -= 1; }
	for * ch: sub(out, 0, n) {
		if ch.* == #char "/" { ch.* = #char "_"; } else if ch.* == #char "+" { ch.* = #char "-"; }
	}
	return as_string(sub(out, 0, n));
}

// ---- runner (one thread per logged-out client) ----

Remote_Auth :: struct {
	mu: locks.Mutex;
	cond: locks.Cond;
	th: *thread.Thread;
	running: bool; // a QR session is wanted (the login page shows)
	stop: bool; // no session: the thread idles
	quit: bool; // the thread ends (client_destroy)
	restart: bool; // "Not me, start over"
	// UI snapshot
	step: Ra_Step;
	fingerprint: string;
	user_id: Snowflake;
	discriminator: string;
	avatar: string;
	username: string;
	gen: int; // bumped whenever the snapshot changes
	// current socket (shut down by stop)
	ws: *http.Ws_Conn;
	stream: netio.Stream;
	inbox: [..][]u8;
	reader_done: bool;
}

Remote_Auth_View :: struct {
	step: Ra_Step;
	fingerprint: string;
	user_id: Snowflake;
	discriminator: string;
	avatar: string;
	username: string;
	gen: int;
}

// remote_auth_view: the UI's copy of the QR panel state (temp allocator).
remote_auth_view :: (c: *Client) -> Remote_Auth_View {
	ra := *c.auth.ra;
	locks.lock(*ra.mu);
	defer locks.unlock(*ra.mu);
	a := temp;
	return .{ra.step, clone(ra.fingerprint, a), ra.user_id, clone(ra.discriminator, a), clone(ra.avatar, a), clone(ra.username, a), ra.gen};
}

remote_auth_start :: (c: *Client) {
	ra := *c.auth.ra;
	if c.cfg.disable_remote_auth { return; }
	locks.lock(*ra.mu);
	defer locks.unlock(*ra.mu);
	ra.stop = false;
	ra.restart = false;
	if ra.th == null {
		ra.th = thread.create_and_start_with_poly_data(c, remote_auth_proc, *c.ctx);
	} else {
		locks.cond_broadcast(*ra.cond);
	}
	ra.running = true;
}

// remote_auth_request_stop: end the QR session without waiting (UI thread). The
// thread idles until the next login page; remote_auth_stop ends it.
remote_auth_request_stop :: (c: *Client) {
	ra := *c.auth.ra;
	locks.lock(*ra.mu);
	ra.stop = true;
	ra.running = false;
	locks.cond_broadcast(*ra.cond);
	locks.unlock(*ra.mu);
	ra_shutdown_socket(ra);
}

// remote_auth_cancel: "Not me, start over" (a new session at once).
remote_auth_cancel :: (c: *Client) {
	ra := *c.auth.ra;
	locks.lock(*ra.mu);
	ra.restart = true;
	locks.cond_broadcast(*ra.cond);
	locks.unlock(*ra.mu);
	ra_shutdown_socket(ra);
}

// remote_auth_stop ends the thread and joins it (client_destroy: not the UI
// thread, a connect in progress can take a while).
remote_auth_stop :: (c: *Client) {
	ra := *c.auth.ra;
	locks.lock(*ra.mu);
	th := ra.th;
	ra.th = null;
	ra.stop = true;
	ra.quit = true;
	ra.running = false;
	locks.cond_broadcast(*ra.cond);
	locks.unlock(*ra.mu);
	ra_shutdown_socket(ra);
	if !is_null(th) {
		locks.join(th);
	}
}

remote_auth_destroy :: (c: *Client) {
	remote_auth_stop(c);
	ra := *c.auth.ra;
	delete(ra.fingerprint, c.allocator);
	delete(ra.discriminator, c.allocator);
	delete(ra.avatar, c.allocator);
	delete(ra.username, c.allocator);
	for m: ra.inbox { delete(m, c.allocator); }
	delete(ra.inbox);
}
#scope_file

ra_shutdown_socket :: (ra: *Remote_Auth) {
	locks.lock(*ra.mu);
	s := ra.stream;
	has := ra.ws != null;
	locks.unlock(*ra.mu);
	if has { netio.shutdown(s); }
}

ra_publish :: (c: *Client, s: *Ra_Session, step: Ra_Step) {
	ra := *c.auth.ra;
	locks.lock(*ra.mu);
	ra.step = step;
	set :: (dst: *string, v: string, a: Allocator) {
		delete(dst.*, a);
		dst.* = clone(v, a);
	}
	set(*ra.fingerprint, ifx !is_null(s) && step != .Initializing then s.fingerprint else "", c.allocator);
	set(*ra.discriminator, ifx !is_null(s) then s.discriminator else "", c.allocator);
	set(*ra.avatar, ifx !is_null(s) then s.avatar else "", c.allocator);
	set(*ra.username, ifx !is_null(s) then s.username else "", c.allocator);
	ra.user_id = ifx !is_null(s) then s.user_id else 0;
	ra.gen += 1;
	locks.unlock(*ra.mu);
	if c.cfg.wakeup != null { c.cfg.wakeup(c.cfg.wakeup_data); }
}

Ra_Reader :: struct {
	c: *Client;
	ws: *http.Ws_Conn;
}

ra_reader_proc :: (rd: Ra_Reader) {
	ra := *rd.c.auth.ra;
	msg := make_dynamic(u8, 0, 0);
	defer delete(msg);
	while true {
		typ, err := http.ws_recv(rd.ws, *msg);
		if err != .None { break; }
		if typ != .Text { continue; }
		locks.lock(*ra.mu);
		append(*ra.inbox, clone_bytes(view(msg), rd.c.allocator));
		locks.cond_broadcast(*ra.cond);
		locks.unlock(*ra.mu);
	}
	locks.lock(*ra.mu);
	ra.reader_done = true;
	locks.cond_broadcast(*ra.cond);
	locks.unlock(*ra.mu);
}

clone_bytes :: (b: []u8, a: Allocator) -> []u8 {
	out := make_slice(u8, len(b), a);
	copy(out, b);
	return out;
}

Ra_End :: enum u8 {
	Stop; // logged in, or stopped
	Restart; // cancel: new session now
	Fail; // closed / error: new session after the backoff
}

remote_auth_proc :: (c: *Client) {
	ra := *c.auth.ra;
	while true {
		// idle while no login page shows
		locks.lock(*ra.mu);
		while ra.stop && !ra.quit { locks.cond_wait_with_timeout(*ra.cond, *ra.mu, 1000 * time.Millisecond); }
		quit := ra.quit;
		locks.unlock(*ra.mu);
		if quit { return; }
		ra_sessions(c);
	}
}

// ra_sessions: QR sessions one after another until a login or a stop.
ra_sessions :: (c: *Client) {
	ra := *c.auth.ra;
	backoff := backoff_make(1500, 30000);
	while true {
		locks.lock(*ra.mu);
		stop := ra.stop;
		ra.restart = false;
		locks.unlock(*ra.mu);
		if stop { return; }
		ra_publish(c, null, .Initializing);
		end := ra_run_socket(c, *backoff);
		if end == {
		case .Stop;
			locks.lock(*ra.mu);
			ra.stop = true; // logged in (or stopped): idle
			locks.unlock(*ra.mu);
			return;
		case .Restart;
		case .Fail;
			wait := backoff_fail(*backoff);
			locks.lock(*ra.mu);
			deadline := now_ms() + wait;
			while !ra.stop && !ra.restart && now_ms() < deadline {
				locks.cond_wait_with_timeout(*ra.cond, *ra.mu, cast(time.Duration)(max(deadline - now_ms(), 1)) * time.Millisecond);
			}
			locks.unlock(*ra.mu);
		}
	}
}

ra_run_socket :: (c: *Client, backoff: *Backoff) -> Ra_End {
	ra := *c.auth.ra;
	// The client makes the key pair once the socket is open (WebCrypto: tens of
	// ms). BoringSSL's keygen (built without assembly) can take longer, so it
	// runs before the dial and init still follows the open at once.
	s: Ra_Session;
	if !ra_session_init(*s, c.allocator) { return .Fail; }
	defer ra_session_destroy(*s);
	locks.lock(*ra.mu);
	halt, again := ra.stop, ra.restart;
	locks.unlock(*ra.mu);
	if halt { return .Stop; }
	if again { return .Restart; }
	host := REMOTE_AUTH_HOST;
	path := "/?v=2";
	stream, _, ok := dial_tls_stream(host, string.["http/1.1"]);
	if !ok { return .Fail; }
	now := now_ms();
	cookie := cookie_header(*c.jar, host, path, true, now);
	hdrs := gateway_ws_headers(c.id.platform, host, cookie);
	key_raw: [16]u8;
	crypto.rand_bytes(view(key_raw));
	for * h: hdrs { if h.name == "Sec-WebSocket-Key" { h.value = base64.encode(view(key_raw), allocator = temp); } }
	req := http.Request.{method = "GET", scheme = "https", authority = host, path = path, headers = hdrs};
	if c.on_ws_open != null { c.on_ws_open(c.observer_data, REMOTE_AUTH_URL, req.headers); }
	ws, resp, err := http.ws_connect(stream, req, .{allow_deflate = true}, c.allocator);
	if err != .None {
		http.response_destroy(*resp);
		netio.close(stream);
		return .Fail;
	}
	for h: resp.headers {
		if strings.equal_fold(h.name, "set-cookie") { cookie_set_from_header(*c.jar, host, path, h.value, now); }
	}
	http.response_destroy(*resp);
	netio.set_timeout(stream, 0);
	locks.lock(*ra.mu);
	ra.ws = ws;
	ra.stream = stream;
	ra.reader_done = false;
	locks.unlock(*ra.mu);
	rd := thread.create_and_start_with_poly_data(Ra_Reader.{c, ws}, ra_reader_proc, *c.ctx);

	end := ra_session_loop(c, ws, *s, backoff);

	locks.lock(*ra.mu);
	ra.ws = null;
	locks.unlock(*ra.mu);
	http.ws_close(ws, 1000);
	netio.shutdown(stream);
	locks.join(rd);
	http.ws_close_stream(ws);
	locks.lock(*ra.mu);
	for m: ra.inbox { delete(m, c.allocator); }
	clear(*ra.inbox);
	locks.unlock(*ra.mu);
	return end;
}

ra_session_loop :: (c: *Client, ws: *http.Ws_Conn, s: *Ra_Session, backoff: *Backoff) -> Ra_End {
	ra := *c.auth.ra;
	send :: (ws: *http.Ws_Conn, text: string) -> bool {
		return http.ws_send(ws, .Text, transmute([]u8, text)) == .None;
	}
	if !send(ws, ra_init_message(s)) { return .Fail; }
	next_beat: s64 = 0;
	acked := true;
	while true {
		locks.lock(*ra.mu);
		while len(ra.inbox) == 0 && !ra.stop && !ra.restart && !ra.reader_done && (next_beat == 0 || now_ms() < next_beat) {
			wait: s64 = 1000;
			if next_beat != 0 { wait = max(next_beat - now_ms(), 1); }
			locks.cond_wait_with_timeout(*ra.cond, *ra.mu, cast(time.Duration)(wait) * time.Millisecond);
		}
		if ra.stop {
			locks.unlock(*ra.mu);
			return .Stop;
		}
		if ra.restart {
			locks.unlock(*ra.mu);
			return .Restart;
		}
		msgs := ra.inbox;
		ra.inbox = make_dynamic([]u8, 0, 0, c.allocator);
		done := ra.reader_done;
		locks.unlock(*ra.mu);
		defer {
			for m: msgs { delete(m, c.allocator); }
			delete(msgs);
		}
		for m: msgs {
			action, reply := ra_handle(s, m);
			if action == {
			case .None;
			case .Send;
				if !send(ws, reply) { return .Fail; }
			case .Hello;
				iv := ifx s.heartbeat_interval > 0 then s.heartbeat_interval else 41250;
				next_beat = now_ms() + cast(s64)(cast(float64)(iv) * rand.float64_());
			case .Heartbeat_Ack;
				acked = true;
			case .Show_Qr;
				backoff_succeed(backoff);
				ra_publish(c, s, .Pending_Remote_Init);
			case .Show_User;
				ra_publish(c, s, .Pending_Ticket);
			case .Login;
				ra_publish(c, s, .Pending_Login);
				if ra_ticket_login(c, s) {
					ra_publish(c, s, .Finish);
					return .Stop;
				}
				return .Fail;
			case .Cancel;
				return .Restart;
			case .Fail;
				return .Fail;
			}
		}
		if done && len(msgs) == 0 { return .Fail; }
		if next_beat != 0 && now_ms() >= next_beat {
			if !acked { return .Fail; } // "heartbeat timeout, reconnecting."
			acked = false;
			if !send(ws, RA_HEARTBEAT_MESSAGE) { return .Fail; }
			iv := ifx s.heartbeat_interval > 0 then s.heartbeat_interval else 41250;
			next_beat = now_ms() + iv;
		}
	}
}

// POST /users/@me/remote-auth/login {"ticket"} -> encrypted_token; the token
// goes to the UI thread, which logs in with it (auth_apply).
ra_ticket_login :: (c: *Client, s: *Ra_Session) -> bool {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "ticket", s.ticket);
	json_obj_end(*w);
	body := json_string(*w);
	r := api_call(c, "POST", "/users/@me/remote-auth/login", transmute([]u8, body), "application/json", "", .[], 0, 0, no_auth = true);
	defer if r.arena != null {
		virtual.arena_destroy(r.arena);
		free(r.arena);
	}
	if !r.ok { return false; }
	tok, ok := ra_decrypt_token(s, fstr(vmap(r.body), "encrypted_token"), temp);
	if !ok { return false; }
	defer crypto.zero_explicit(raw_data(tok), len(tok));
	auth_push_token(c, tok, s.fingerprint, .Remote_Token);
	return true;
}
#scope_export


