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

// ---- protocol core (no I/O) ----

// Ra_Session: one socket's key pair and what the server told it; its strings use allocator.
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

// ra_session_init makes the key pair (generateKey RSA-OAEP 2048; e = 65537 is BoringSSL's default)
// and derives the SubjectPublicKeyInfo DER (exportKey "spki") and its fingerprint.
ra_session_init :: (s: *Ra_Session, allocator: Allocator) -> bool {
	s.allocator = allocator;
	ctx := tls.EVP_PKEY_CTX_new_id(tls.EVP_PKEY_RSA, null);
	defer tls.EVP_PKEY_CTX_free(ctx);
	if !ctx || tls.EVP_PKEY_keygen_init(ctx) != 1 || tls.EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, 2048) != 1 return false;
	if tls.EVP_PKEY_keygen(ctx, *s.key) != 1 return false;
	der: *u8;
	n := tls.i2d_PUBKEY(s.key, *der);
	if n <= 0 return false;
	defer tls.OPENSSL_free(der);
	s.spki = array_copy(cast([]u8) to_string(der, n),, allocator);
	digest := crypto.sha256(s.spki);
	s.fingerprint = base64url_nopad(digest,, allocator);
	return true;
}

ra_session_destroy :: (s: *Ra_Session) {
	tls.EVP_PKEY_free(s.key);
	crypto.zero(cast([]u8) s.ticket);
	push_allocator(s.allocator);
	array_free(s.spki);
	free(s.fingerprint);
	free(s.discriminator);
	free(s.avatar);
	free(s.username);
	free(s.ticket);
	s.* = .{};
}

RA_HEARTBEAT_MESSAGE :: "{\"op\":\"heartbeat\"}";

// ra_handle: what to do about one server message (the reply in temp).
ra_handle :: (s: *Ra_Session, msg: []u8) -> Ra_Action, string {
	v, ok := parse_json(msg,, temp);
	if !ok return .None, "";
	m := vmap(v);
	if fstr(m, "op") == {
		case "hello";
			s.heartbeat_interval = fint(m, "heartbeat_interval");
			s.timeout_ms = fint(m, "timeout_ms");
			return .Hello, "";
		case "heartbeat_ack";
			return .Heartbeat_Ack, "";
		case "nonce_proof";
			plain, dok := ra_decrypt(s, fstr(m, "encrypted_nonce"));
			if !dok return .Fail, "";
			w: Json;
			json_init(*w);
			json_obj(*w);
			json_kstr(*w, "op", "nonce_proof");
			json_kstr(*w, "nonce", base64url_nopad(plain,, temp));
			json_obj_end(*w);
			return .Send, json_string(*w);
		case "pending_remote_init";
			if fstr(m, "fingerprint") != s.fingerprint return .Fail, ""; // "bad fingerprint"
			s.step = .Pending_Remote_Init;
			return .Show_Qr, "";
		case "pending_ticket";
			plain, dok := ra_decrypt(s, fstr(m, "encrypted_user_payload"));
			if !dok return .Fail, "";
			id, disc, avatar, name, pok := ra_parse_user(cast(string) plain);
			if !pok return .Fail, ""; // "Invalid encoded user record."
			push_allocator(s.allocator);
			free(s.discriminator);
			free(s.avatar);
			free(s.username);
			s.user_id = id;
			s.discriminator = copy_string(disc);
			s.avatar = copy_string(ifx avatar == "0" then "" else avatar);
			s.username = copy_string(name);
			s.step = .Pending_Ticket;
			return .Show_User, "";
		case "pending_login";
			t := fstr(m, "ticket");
			if !t return .Fail, "";
			free_str(s.ticket, s.allocator);
			s.ticket = copy_string(t,, s.allocator);
			s.step = .Pending_Login;
			return .Login, "";
		case "cancel";
			return .Cancel, "";
	}
	return .None, ""; // "received unsupported message"
}

// ra_decrypt: RSA-OAEP (SHA-256) of a base64 (atob) ciphertext, into temp.
ra_decrypt :: (s: *Ra_Session, b64: string) -> []u8, bool {
	ct, ok := base64_decode(b64,, temp);
	if !ok || ct.count != 256 return .[], false;
	ctx := tls.EVP_PKEY_CTX_new(s.key, null);
	defer tls.EVP_PKEY_CTX_free(ctx);
	out := NewArray(256, u8,, temp);
	n := cast(u64) out.count;
	if !ctx || tls.EVP_PKEY_decrypt_init(ctx) != 1 || tls.EVP_PKEY_CTX_set_rsa_padding(ctx, tls.RSA_PKCS1_OAEP_PADDING) != 1 ||
	   tls.EVP_PKEY_CTX_set_rsa_oaep_md(ctx, tls.EVP_sha256()) != 1 || tls.EVP_PKEY_decrypt(ctx, out.data, *n, ct.data, xx ct.count) != 1 {
		tls.ERR_clear_error(); // a bad ciphertext must not linger for this thread's next TLS handshake
		return .[], false;
	}
	out.count = xx n;
	return out, true;
}

// "id:discriminator:avatar:username" (/^(\d+):(\d{1,4}):([a-zA-Z0-9_]+):(.*)$/)
ra_parse_user :: (s: string) -> Snowflake, string, string, string, bool {
	ok1, ids, rest := split_from_left(s, #char ":");
	ok2, disc, rest2 := split_from_left(rest, #char ":");
	ok3, avatar, name := split_from_left(rest2, #char ":");
	if !ok1 || !ok2 || !ok3 return 0, "", "", "", false;
	digits :: (s: string) -> bool { for cast([]u8) s if !is_digit(it) return false; return true; }
	word :: (s: string) -> bool { for cast([]u8) s if !is_alnum(it) return false; return true; } // is_alnum takes "_"
	if !ids || !digits(ids) || !disc || disc.count > 4 || !digits(disc) || !avatar || !word(avatar) return 0, "", "", "", false;
	id, pok := parse_u64(ids);
	if !pok return 0, "", "", "", false;
	return id, disc, avatar, name, true;
}

ra_qr_url :: (fingerprint: string, allocator := temp) -> string { return join(REMOTE_AUTH_QR_PREFIX, fingerprint,, allocator); }

// btoa(...).replace(/\//g,"_").replace(/\+/g,"-").replace(/={1,2}$/,"")
base64url_nopad :: (b: []u8) -> string { return base64_encode(cast(string) b, BASE64URL_ENCODER_TABLE, pad = false); }

// ---- runner (one thread per logged-out client) ----

Remote_Auth :: struct {
	mu: locks.Mutex;
	cond: locks.Cond;
	th: *Thread;
	running: bool; // a QR session is wanted (the login page shows)
	stop: bool; // no session: the thread idles
	quit: bool; // the thread ends (client_destroy)
	restart: bool; // "Not me, start over"
	// UI snapshot (client allocator)
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
	inbox: [..][]u8; // text messages from the reader thread (client allocator)
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
	using ra := *c.auth.ra;
	locks.lock(*mu);
	defer locks.unlock(*mu);
	push_allocator(temp);
	return .{step, copy_string(fingerprint), user_id, copy_string(discriminator), copy_string(avatar), copy_string(username), gen};
}

remote_auth_start :: (c: *Client) {
	ra := *c.auth.ra;
	if c.cfg.disable_remote_auth return;
	locks.lock(*ra.mu);
	defer locks.unlock(*ra.mu);
	ra.stop = false;
	ra.restart = false;
	if !ra.th {
		ra.inbox.allocator = c.allocator;
		ra.th = spawn(c, remote_auth_proc);
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
	if th locks.join(th);
}

remote_auth_destroy :: (c: *Client) {
	remote_auth_stop(c);
	using ra := *c.auth.ra;
	push_allocator(c.allocator);
	free(fingerprint);
	free(discriminator);
	free(avatar);
	free(username);
	for inbox array_free(it);
	array_free(inbox);
}

#scope_file

ra_shutdown_socket :: (ra: *Remote_Auth) {
	locks.lock(*ra.mu);
	s := ra.stream;
	has := ra.ws != null;
	locks.unlock(*ra.mu);
	if has netio.shutdown(s);
}

ra_publish :: (c: *Client, s: *Ra_Session, step: Ra_Step) {
	ra := *c.auth.ra;
	locks.lock(*ra.mu);
	push_allocator(c.allocator);
	set :: (dst: *string, v: string) {
		free(dst.*);
		dst.* = copy_string(v);
	}
	ra.step = step;
	set(*ra.fingerprint, ifx s && step != .Initializing then s.fingerprint else "");
	set(*ra.discriminator, ifx s then s.discriminator else "");
	set(*ra.avatar, ifx s then s.avatar else "");
	set(*ra.username, ifx s then s.username else "");
	ra.user_id = ifx s then s.user_id else 0;
	ra.gen += 1;
	locks.unlock(*ra.mu);
	if c.cfg.wakeup c.cfg.wakeup(c.cfg.wakeup_data);
}

Ra_Reader :: struct {
	c: *Client;
	ws: *http.Ws_Conn;
}

ra_reader_proc :: (rd: Ra_Reader) {
	ra := *rd.c.auth.ra;
	msg: [..]u8;
	defer array_free(msg);
	while true {
		typ, err := http.ws_recv(rd.ws, *msg);
		if err != .None break;
		if typ != .Text continue;
		locks.lock(*ra.mu);
		array_add(*ra.inbox, array_copy(msg,, rd.c.allocator));
		locks.cond_broadcast(*ra.cond);
		locks.unlock(*ra.mu);
	}
	locks.lock(*ra.mu);
	ra.reader_done = true;
	locks.cond_broadcast(*ra.cond);
	locks.unlock(*ra.mu);
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
		while ra.stop && !ra.quit locks.cond_wait_with_timeout(*ra.cond, *ra.mu, 1000);
		quit := ra.quit;
		locks.unlock(*ra.mu);
		if quit return;
		ra_sessions(c);
	}
}

// ra_sessions: QR sessions one after another until a login or a stop.
ra_sessions :: (c: *Client) {
	ra := *c.auth.ra;
	backoff := backoff_make(1500, 30000);
	while true {
		reset_temporary_storage(); // this thread's temp lives one socket
		locks.lock(*ra.mu);
		stop := ra.stop;
		ra.restart = false;
		locks.unlock(*ra.mu);
		if stop return;
		ra_publish(c, null, .Initializing);
		end := ra_run_socket(c, *backoff);
		if end == .Stop {
			locks.lock(*ra.mu);
			ra.stop = true; // logged in (or stopped): idle
			locks.unlock(*ra.mu);
			return;
		}
		if end == .Fail {
			wait := backoff_fail(*backoff);
			locks.lock(*ra.mu);
			deadline := now_ms() + wait;
			while !ra.stop && !ra.restart && now_ms() < deadline {
				locks.cond_wait_with_timeout(*ra.cond, *ra.mu, max(deadline - now_ms(), 1));
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
	if !ra_session_init(*s, c.allocator) return .Fail;
	defer ra_session_destroy(*s);
	locks.lock(*ra.mu);
	halt, again := ra.stop, ra.restart;
	locks.unlock(*ra.mu);
	if halt return .Stop;
	if again return .Restart;
	host :: REMOTE_AUTH_HOST;
	path :: "/?v=2";
	stream, _, ok := dial_tls_stream(host, .["http/1.1"]);
	if !ok return .Fail;
	now := now_ms();
	hdrs := gateway_ws_headers(c.id.platform, host, cookie_header(*c.jar, host, path, true, now));
	key_raw: [16]u8;
	crypto.random_bytes(key_raw);
	for * hdrs if it.name == "Sec-WebSocket-Key" it.value = base64_encode(cast(string) key_raw,, temp);
	req := http.Request.{method = "GET", scheme = "https", authority = host, path = path, headers = hdrs};
	if c.on_ws_open c.on_ws_open(c.observer_data, REMOTE_AUTH_URL, req.headers);
	ws, resp, err := http.ws_connect(stream, req, .{allow_deflate = true},, c.allocator);
	if err != .None {
		http.response_destroy(*resp);
		netio.close(stream);
		return .Fail;
	}
	for resp.headers if equal_nocase(it.name, "set-cookie") cookie_set_from_header(*c.jar, host, path, it.value, now);
	http.response_destroy(*resp);
	netio.set_timeout(stream, 0);
	locks.lock(*ra.mu);
	ra.ws = ws;
	ra.stream = stream;
	ra.reader_done = false;
	locks.unlock(*ra.mu);
	rd := spawn(Ra_Reader.{c, ws}, ra_reader_proc);

	end := ra_session_loop(c, ws, *s, backoff);

	locks.lock(*ra.mu);
	ra.ws = null;
	locks.unlock(*ra.mu);
	http.ws_close(ws, 1000);
	netio.shutdown(stream);
	locks.join(rd);
	http.ws_close_stream(ws);
	locks.lock(*ra.mu);
	for ra.inbox array_free(it);
	ra.inbox.count = 0;
	locks.unlock(*ra.mu);
	return end;
}

ra_session_loop :: (c: *Client, ws: *http.Ws_Conn, s: *Ra_Session, backoff: *Backoff) -> Ra_End {
	ra := *c.auth.ra;
	send :: (ws: *http.Ws_Conn, text: string) -> bool { return http.ws_send(ws, .Text, cast([]u8) text) == .None; }
	heartbeat_interval :: (s: *Ra_Session) -> s64 { return ifx s.heartbeat_interval > 0 then s.heartbeat_interval else 41250; }
	{
		// {"op":"init","encoded_public_key":base64(SPKI)}
		w: Json;
		json_init(*w);
		json_obj(*w);
		json_kstr(*w, "op", "init");
		json_kstr(*w, "encoded_public_key", base64_encode(cast(string) s.spki,, temp));
		json_obj_end(*w);
		if !send(ws, json_string(*w)) return .Fail;
	}
	next_beat: s64;
	acked := true;
	while true {
		reset_temporary_storage(); // nothing in temp outlives a batch of messages
		locks.lock(*ra.mu);
		while !ra.inbox && !ra.stop && !ra.restart && !ra.reader_done && (next_beat == 0 || now_ms() < next_beat) {
			locks.cond_wait_with_timeout(*ra.cond, *ra.mu, ifx next_beat then max(next_beat - now_ms(), 1) else 1000);
		}
		if ra.stop {
			locks.unlock(*ra.mu);
			return .Stop;
		}
		if ra.restart {
			locks.unlock(*ra.mu);
			return .Restart;
		}
		msgs := array_copy(ra.inbox,, temp);
		ra.inbox.count = 0;
		done := ra.reader_done;
		locks.unlock(*ra.mu);
		defer for msgs array_free(it,, c.allocator);
		for m: msgs {
			action, reply := ra_handle(s, m);
			if action == {
				case .Send;
					if !send(ws, reply) return .Fail;
				case .Hello;
					next_beat = now_ms() + cast(s64) (cast(float64) heartbeat_interval(s) * cast(float64) random_get_zero_to_one_open());
				case .Heartbeat_Ack;
					acked = true;
				case .Show_Qr;
					backoff_succeed(backoff);
					ra_publish(c, s, .Pending_Remote_Init);
				case .Show_User;
					ra_publish(c, s, .Pending_Ticket);
				case .Login;
					ra_publish(c, s, .Pending_Login);
					if !ra_ticket_login(c, s) return .Fail;
					ra_publish(c, s, .Finish);
					return .Stop;
				case .Cancel;
					return .Restart;
				case .Fail;
					return .Fail;
			}
		}
		if done && !msgs return .Fail;
		if next_beat != 0 && now_ms() >= next_beat {
			if !acked return .Fail; // "heartbeat timeout, reconnecting."
			acked = false;
			if !send(ws, RA_HEARTBEAT_MESSAGE) return .Fail;
			next_beat = now_ms() + heartbeat_interval(s);
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
	r := api_call(c, "POST", "/users/@me/remote-auth/login", w.buf, "application/json", "", .[], 0, 0, no_auth = true);
	defer if r.arena {
		fini(r.arena);
		free(r.arena);
	}
	if !r.ok return false;
	tok, ok := ra_decrypt(s, fstr(vmap(r.body), "encrypted_token"));
	if !ok return false;
	defer crypto.zero(tok);
	auth_push_token(c, cast(string) tok, s.fingerprint, .Remote_Token);
	return true;
}
