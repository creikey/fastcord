package discord

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/rsa"
import "core:encoding/base64"
import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"
import "fc:http"
import "fc:locks"
import "fc:netio"

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

REMOTE_AUTH_HOST :: "remote-auth-gateway.discord.gg"
REMOTE_AUTH_URL :: "wss://remote-auth-gateway.discord.gg/?v=2"
REMOTE_AUTH_QR_PREFIX :: "https://discord.com/ra/"

Ra_Step :: enum u8 {
	Initializing,
	Pending_Remote_Init, // QR code shown
	Pending_Ticket, // scanned: "Check your phone!"
	Pending_Login, // approved on the phone: logging in
	Finish,
}

// ---- protocol core (no I/O; unit-tested with a fake server) ----

Ra_Session :: struct {
	key:                rsa.Private_Key,
	spki:               []byte,
	fingerprint:        string,
	step:               Ra_Step,
	heartbeat_interval: i64,
	timeout_ms:         i64,
	user_id:            Snowflake,
	discriminator:      string,
	avatar:             string, // "" = default avatar
	username:           string,
	ticket:             string,
	allocator:          mem.Allocator,
}

Ra_Action :: enum u8 {
	None,
	Send, // reply holds the message to send
	Hello, // heartbeat_interval / timeout_ms set
	Heartbeat_Ack,
	Show_Qr, // pending_remote_init: fingerprint verified
	Show_User, // pending_ticket: user fields set
	Login, // pending_login: ticket set
	Cancel, // the server cancelled: restart now
	Fail, // bad message / fingerprint mismatch: restart with backoff
}

// ra_session_init makes the key pair (generateKey RSA-OAEP 2048, e = 65537).
ra_session_init :: proc(s: ^Ra_Session, allocator := context.allocator) -> bool {
	s.allocator = allocator
	if !rsa.private_key_generate(&s.key, 2048) do return false
	return ra_session_derive(s)
}

// ra_session_derive: the SPKI and the fingerprint of s.key.
ra_session_derive :: proc(s: ^Ra_Session) -> bool {
	allocator := s.allocator
	n: [256]byte
	nl := rsa.private_key_n(&s.key, n[:])
	if nl != 256 do return false
	s.spki = spki_rsa(n[:nl], rsa.private_key_e(&s.key), allocator)
	digest := sha256_bytes(s.spki)
	s.fingerprint = base64url_nopad(digest[:], allocator)
	return true
}

ra_session_destroy :: proc(s: ^Ra_Session) {
	rsa.private_key_clear(&s.key)
	delete(s.spki, s.allocator)
	delete(s.fingerprint, s.allocator)
	delete(s.discriminator, s.allocator)
	delete(s.avatar, s.allocator)
	delete(s.username, s.allocator)
	if len(s.ticket) > 0 do crypto.zero_explicit(raw_data(s.ticket), len(s.ticket))
	delete(s.ticket, s.allocator)
	s^ = {}
}

// {"op":"init","encoded_public_key":base64(SPKI)}
ra_init_message :: proc(s: ^Ra_Session, allocator := context.temp_allocator) -> string {
	w: Json
	json_init(&w, allocator)
	json_obj(&w)
	json_kstr(&w, "op", "init")
	json_kstr(&w, "encoded_public_key", base64.encode(s.spki, allocator = context.temp_allocator))
	json_obj_end(&w)
	return json_string(&w)
}

RA_HEARTBEAT_MESSAGE :: `{"op":"heartbeat"}`

ra_handle :: proc(s: ^Ra_Session, msg: []byte, allocator := context.temp_allocator) -> (action: Ra_Action, reply: string) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	v, ok := parse_json(msg, virtual.arena_allocator(&arena))
	if !ok do return .None, ""
	m := vmap(v)
	switch fstr(m, "op") {
	case "hello":
		s.heartbeat_interval = fint(m, "heartbeat_interval")
		s.timeout_ms = fint(m, "timeout_ms")
		return .Hello, ""
	case "heartbeat_ack":
		return .Heartbeat_Ack, ""
	case "nonce_proof":
		plain, dok := ra_decrypt(s, fstr(m, "encrypted_nonce"), context.temp_allocator)
		if !dok do return .Fail, ""
		w: Json
		json_init(&w, allocator)
		json_obj(&w)
		json_kstr(&w, "op", "nonce_proof")
		json_kstr(&w, "nonce", base64url_nopad(plain, context.temp_allocator))
		json_obj_end(&w)
		return .Send, json_string(&w)
	case "pending_remote_init":
		if fstr(m, "fingerprint") != s.fingerprint do return .Fail, "" // "bad fingerprint"
		s.step = .Pending_Remote_Init
		return .Show_Qr, ""
	case "pending_ticket":
		plain, dok := ra_decrypt(s, fstr(m, "encrypted_user_payload"), context.temp_allocator)
		if !dok do return .Fail, ""
		id, disc, avatar, name, pok := ra_parse_user(string(plain))
		if !pok do return .Fail, "" // "Invalid encoded user record."
		delete(s.discriminator, s.allocator)
		delete(s.avatar, s.allocator)
		delete(s.username, s.allocator)
		s.user_id = id
		s.discriminator = strings.clone(disc, s.allocator)
		s.avatar = strings.clone("" if avatar == "0" else avatar, s.allocator)
		s.username = strings.clone(name, s.allocator)
		s.step = .Pending_Ticket
		return .Show_User, ""
	case "pending_login":
		t := fstr(m, "ticket")
		if t == "" do return .Fail, ""
		delete(s.ticket, s.allocator)
		s.ticket = strings.clone(t, s.allocator)
		s.step = .Pending_Login
		return .Login, ""
	case "cancel":
		return .Cancel, ""
	}
	return .None, "" // "received unsupported message"
}

// ra_decrypt: RSA-OAEP (SHA-256) of a base64 (atob) ciphertext.
ra_decrypt :: proc(s: ^Ra_Session, b64: string, allocator := context.temp_allocator) -> ([]byte, bool) {
	ct, err := base64.decode(b64, allocator = context.temp_allocator)
	if err != nil || len(ct) != 256 do return nil, false
	out := make([]byte, 256, allocator)
	pt, ok := rsa.decrypt_oaep(&s.key, .SHA256, ct, out)
	if !ok do return nil, false
	return pt, true
}

// ra_decrypt_token: the encrypted_token of POST /users/@me/remote-auth/login.
ra_decrypt_token :: proc(s: ^Ra_Session, encrypted_token: string, allocator := context.allocator) -> (string, bool) {
	pt, ok := ra_decrypt(s, encrypted_token, context.temp_allocator)
	if !ok do return "", false
	tok := strings.clone(string(pt), allocator)
	crypto.zero_explicit(raw_data(pt), len(pt))
	return tok, true
}

sha256_bytes :: proc(b: []byte) -> (d: [32]byte) {
	hash.hash_bytes_to_buffer(.SHA256, b, d[:])
	return
}

// "id:discriminator:avatar:username" (/^(\d+):(\d{1,4}):([a-zA-Z0-9_]+):(.*)$/)
ra_parse_user :: proc(s: string) -> (id: Snowflake, disc, avatar, name: string, ok: bool) {
	rest := s
	field :: proc(rest: ^string) -> (string, bool) {
		i := strings.index_byte(rest^, ':')
		if i < 0 do return "", false
		f := rest^[:i]
		rest^ = rest^[i + 1:]
		return f, true
	}
	all :: proc(s: string, pred: proc(r: byte) -> bool) -> bool {
		for i in 0 ..< len(s) do if !pred(s[i]) do return false
		return true
	}
	digit :: proc(r: byte) -> bool {return r >= '0' && r <= '9'}
	word :: proc(r: byte) -> bool {return digit(r) || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r == '_'}
	ids := field(&rest) or_return
	disc = field(&rest) or_return
	avatar = field(&rest) or_return
	name = rest
	if len(ids) == 0 || !all(ids, digit) do return
	if len(disc) < 1 || len(disc) > 4 || !all(disc, digit) do return
	if len(avatar) == 0 || !all(avatar, word) do return
	v, pok := strconv.parse_u64(ids)
	if !pok do return
	return Snowflake(v), disc, avatar, name, true
}

ra_qr_url :: proc(fingerprint: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({REMOTE_AUTH_QR_PREFIX, fingerprint}, allocator)
}

// btoa(...).replace(/\//g,"_").replace(/\+/g,"-").replace(/={1,2}$/,"")
base64url_nopad :: proc(b: []byte, allocator := context.allocator) -> string {
	s := base64.encode(b, allocator = allocator)
	out := transmute([]byte)s
	n := len(out)
	for n > 0 && out[n - 1] == '=' do n -= 1
	for &ch in out[:n] {
		if ch == '/' do ch = '_'
		else if ch == '+' do ch = '-'
	}
	return string(out[:n])
}

// SubjectPublicKeyInfo DER of an RSA public key (crypto.subtle exportKey "spki").
spki_rsa :: proc(n: []byte, e: u32, allocator := context.allocator) -> []byte {
	der_len :: proc(b: ^[dynamic]byte, n: int) {
		switch {
		case n < 0x80:
			append(b, byte(n))
		case n < 0x100:
			append(b, 0x81, byte(n))
		case:
			append(b, 0x82, byte(n >> 8), byte(n))
		}
	}
	der_int :: proc(b: ^[dynamic]byte, v: []byte) {
		v := v
		for len(v) > 1 && v[0] == 0 do v = v[1:]
		pad := v[0] & 0x80 != 0
		append(b, 0x02)
		der_len(b, len(v) + int(pad))
		if pad do append(b, 0)
		append(b, ..v)
	}
	eb := [4]byte{byte(e >> 24), byte(e >> 16), byte(e >> 8), byte(e)}
	rsakey := make([dynamic]byte, context.temp_allocator)
	der_int(&rsakey, n)
	der_int(&rsakey, eb[:])
	seq := make([dynamic]byte, context.temp_allocator)
	append(&seq, 0x30)
	der_len(&seq, len(rsakey))
	append(&seq, ..rsakey[:])
	ALG :: []byte{0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00}
	body := make([dynamic]byte, context.temp_allocator)
	append(&body, ..ALG)
	append(&body, 0x03)
	der_len(&body, len(seq) + 1)
	append(&body, 0x00)
	append(&body, ..seq[:])
	out := make([dynamic]byte, allocator)
	append(&out, 0x30)
	der_len(&out, len(body))
	append(&out, ..body[:])
	return out[:]
}

// ---- runner (one thread per logged-out client) ----

Remote_Auth :: struct {
	mu:            locks.Mutex,
	cond:          locks.Cond,
	th:            ^thread.Thread,
	running:       bool, // a QR session is wanted (the login page shows)
	stop:          bool, // no session: the thread idles
	quit:          bool, // the thread ends (client_destroy)
	restart:       bool, // "Not me, start over"
	// UI snapshot
	step:          Ra_Step,
	fingerprint:   string,
	user_id:       Snowflake,
	discriminator: string,
	avatar:        string,
	username:      string,
	gen:           int, // bumped whenever the snapshot changes
	// current socket (shut down by stop)
	ws:            ^http.Ws_Conn,
	stream:        netio.Stream,
	inbox:         [dynamic][]byte,
	reader_done:   bool,
}

Remote_Auth_View :: struct {
	step:          Ra_Step,
	fingerprint:   string,
	user_id:       Snowflake,
	discriminator: string,
	avatar:        string,
	username:      string,
	gen:           int,
}

// remote_auth_view: the UI's copy of the QR panel state (temp allocator).
remote_auth_view :: proc(c: ^Client) -> Remote_Auth_View {
	ra := &c.auth.ra
	locks.lock(&ra.mu)
	defer locks.unlock(&ra.mu)
	a := context.temp_allocator
	return {ra.step, strings.clone(ra.fingerprint, a), ra.user_id, strings.clone(ra.discriminator, a), strings.clone(ra.avatar, a), strings.clone(ra.username, a), ra.gen}
}

remote_auth_start :: proc(c: ^Client) {
	ra := &c.auth.ra
	if c.cfg.disable_remote_auth do return
	locks.lock(&ra.mu)
	defer locks.unlock(&ra.mu)
	ra.stop = false
	ra.restart = false
	if ra.th == nil {
		ra.th = thread.create_and_start_with_poly_data(c, remote_auth_proc, c.ctx)
	} else {
		locks.cond_broadcast(&ra.cond)
	}
	ra.running = true
}

// remote_auth_request_stop: end the QR session without waiting (UI thread). The
// thread idles until the next login page; remote_auth_stop ends it.
remote_auth_request_stop :: proc(c: ^Client) {
	ra := &c.auth.ra
	locks.lock(&ra.mu)
	ra.stop = true
	ra.running = false
	locks.cond_broadcast(&ra.cond)
	locks.unlock(&ra.mu)
	ra_shutdown_socket(ra)
}

// remote_auth_cancel: "Not me, start over" (a new session at once).
remote_auth_cancel :: proc(c: ^Client) {
	ra := &c.auth.ra
	locks.lock(&ra.mu)
	ra.restart = true
	locks.cond_broadcast(&ra.cond)
	locks.unlock(&ra.mu)
	ra_shutdown_socket(ra)
}

// remote_auth_stop ends the thread and joins it (client_destroy: not the UI
// thread, a connect in progress can take a while).
remote_auth_stop :: proc(c: ^Client) {
	ra := &c.auth.ra
	locks.lock(&ra.mu)
	th := ra.th
	ra.th = nil
	ra.stop = true
	ra.quit = true
	ra.running = false
	locks.cond_broadcast(&ra.cond)
	locks.unlock(&ra.mu)
	ra_shutdown_socket(ra)
	if th != nil {
		locks.join(th)
	}
}

remote_auth_destroy :: proc(c: ^Client) {
	remote_auth_stop(c)
	ra := &c.auth.ra
	delete(ra.fingerprint, c.allocator)
	delete(ra.discriminator, c.allocator)
	delete(ra.avatar, c.allocator)
	delete(ra.username, c.allocator)
	for m in ra.inbox do delete(m, c.allocator)
	delete(ra.inbox)
}

@(private = "file")
ra_shutdown_socket :: proc(ra: ^Remote_Auth) {
	locks.lock(&ra.mu)
	s := ra.stream
	has := ra.ws != nil
	locks.unlock(&ra.mu)
	if has do netio.shutdown(s)
}

@(private = "file")
ra_publish :: proc(c: ^Client, s: ^Ra_Session, step: Ra_Step) {
	ra := &c.auth.ra
	locks.lock(&ra.mu)
	ra.step = step
	set :: proc(dst: ^string, v: string, a: mem.Allocator) {
		delete(dst^, a)
		dst^ = strings.clone(v, a)
	}
	set(&ra.fingerprint, s.fingerprint if s != nil && step != .Initializing else "", c.allocator)
	set(&ra.discriminator, s.discriminator if s != nil else "", c.allocator)
	set(&ra.avatar, s.avatar if s != nil else "", c.allocator)
	set(&ra.username, s.username if s != nil else "", c.allocator)
	ra.user_id = s.user_id if s != nil else 0
	ra.gen += 1
	locks.unlock(&ra.mu)
	if c.cfg.wakeup != nil do c.cfg.wakeup(c.cfg.wakeup_data)
}

@(private = "file")
Ra_Reader :: struct {
	c:  ^Client,
	ws: ^http.Ws_Conn,
}

@(private = "file")
ra_reader_proc :: proc(rd: Ra_Reader) {
	ra := &rd.c.auth.ra
	msg := make([dynamic]byte)
	defer delete(msg)
	for {
		typ, err := http.ws_recv(rd.ws, &msg)
		if err != .None do break
		if typ != .Text do continue
		locks.lock(&ra.mu)
		append(&ra.inbox, clone_bytes(msg[:], rd.c.allocator))
		locks.cond_broadcast(&ra.cond)
		locks.unlock(&ra.mu)
	}
	locks.lock(&ra.mu)
	ra.reader_done = true
	locks.cond_broadcast(&ra.cond)
	locks.unlock(&ra.mu)
}

@(private = "file")
clone_bytes :: proc(b: []byte, a: mem.Allocator) -> []byte {
	out := make([]byte, len(b), a)
	copy(out, b)
	return out
}

@(private = "file")
Ra_End :: enum u8 {
	Stop, // logged in, or stopped
	Restart, // cancel: new session now
	Fail, // closed / error: new session after the backoff
}

@(private = "file")
remote_auth_proc :: proc(c: ^Client) {
	ra := &c.auth.ra
	for {
		// idle while no login page shows
		locks.lock(&ra.mu)
		for ra.stop && !ra.quit do locks.cond_wait_with_timeout(&ra.cond, &ra.mu, 1000 * time.Millisecond)
		quit := ra.quit
		locks.unlock(&ra.mu)
		if quit do return
		ra_sessions(c)
	}
}

// ra_sessions: QR sessions one after another until a login or a stop.
@(private = "file")
ra_sessions :: proc(c: ^Client) {
	ra := &c.auth.ra
	backoff := backoff_make(1500, 30000)
	for {
		locks.lock(&ra.mu)
		stop := ra.stop
		ra.restart = false
		locks.unlock(&ra.mu)
		if stop do return
		ra_publish(c, nil, .Initializing)
		end := ra_run_socket(c, &backoff)
		switch end {
		case .Stop:
			locks.lock(&ra.mu)
			ra.stop = true // logged in (or stopped): idle
			locks.unlock(&ra.mu)
			return
		case .Restart:
		case .Fail:
			wait := backoff_fail(&backoff)
			locks.lock(&ra.mu)
			deadline := now_ms() + wait
			for !ra.stop && !ra.restart && now_ms() < deadline {
				locks.cond_wait_with_timeout(&ra.cond, &ra.mu, time.Duration(max(deadline - now_ms(), 1)) * time.Millisecond)
			}
			locks.unlock(&ra.mu)
		}
	}
}

@(private = "file")
ra_run_socket :: proc(c: ^Client, backoff: ^Backoff) -> Ra_End {
	ra := &c.auth.ra
	// The client makes the key pair once the socket is open (WebCrypto: tens of
	// ms). Our constant-time keygen takes 0.1-3 s, so it runs before the dial
	// and init still follows the open at once.
	s: Ra_Session
	if !ra_session_init(&s, c.allocator) do return .Fail
	defer ra_session_destroy(&s)
	locks.lock(&ra.mu)
	halt, again := ra.stop, ra.restart
	locks.unlock(&ra.mu)
	if halt do return .Stop
	if again do return .Restart
	host := REMOTE_AUTH_HOST
	path := "/?v=2"
	stream, _, ok := dial_tls_stream(host, {"http/1.1"})
	if !ok do return .Fail
	now := now_ms()
	cookie := cookie_header(&c.jar, host, path, true, now)
	hdrs := gateway_ws_headers(c.id.platform, host, cookie)
	key_raw: [16]byte
	crypto.rand_bytes(key_raw[:])
	for &h in hdrs do if h.name == "Sec-WebSocket-Key" do h.value = base64.encode(key_raw[:], allocator = context.temp_allocator)
	req := http.Request{method = "GET", scheme = "https", authority = host, path = path, headers = hdrs}
	if c.on_ws_open != nil do c.on_ws_open(c.observer_data, REMOTE_AUTH_URL, req.headers)
	ws, resp, err := http.ws_connect(stream, req, {allow_deflate = true}, c.allocator)
	if err != .None {
		http.response_destroy(&resp)
		netio.close(stream)
		return .Fail
	}
	for h in resp.headers {
		if strings.equal_fold(h.name, "set-cookie") do cookie_set_from_header(&c.jar, host, path, h.value, now)
	}
	http.response_destroy(&resp)
	netio.set_timeout(stream, 0)
	locks.lock(&ra.mu)
	ra.ws = ws
	ra.stream = stream
	ra.reader_done = false
	locks.unlock(&ra.mu)
	rd := thread.create_and_start_with_poly_data(Ra_Reader{c, ws}, ra_reader_proc, c.ctx)

	end := ra_session_loop(c, ws, &s, backoff)

	locks.lock(&ra.mu)
	ra.ws = nil
	locks.unlock(&ra.mu)
	_ = http.ws_close(ws, 1000)
	netio.shutdown(stream)
	locks.join(rd)
	http.ws_close_stream(ws)
	locks.lock(&ra.mu)
	for m in ra.inbox do delete(m, c.allocator)
	clear(&ra.inbox)
	locks.unlock(&ra.mu)
	return end
}

@(private = "file")
ra_session_loop :: proc(c: ^Client, ws: ^http.Ws_Conn, s: ^Ra_Session, backoff: ^Backoff) -> Ra_End {
	ra := &c.auth.ra
	send :: proc(ws: ^http.Ws_Conn, text: string) -> bool {
		return http.ws_send(ws, .Text, transmute([]byte)text) == .None
	}
	if !send(ws, ra_init_message(s)) do return .Fail
	next_beat: i64 = 0
	acked := true
	for {
		locks.lock(&ra.mu)
		for len(ra.inbox) == 0 && !ra.stop && !ra.restart && !ra.reader_done && (next_beat == 0 || now_ms() < next_beat) {
			wait: i64 = 1000
			if next_beat != 0 do wait = max(next_beat - now_ms(), 1)
			locks.cond_wait_with_timeout(&ra.cond, &ra.mu, time.Duration(wait) * time.Millisecond)
		}
		if ra.stop {
			locks.unlock(&ra.mu)
			return .Stop
		}
		if ra.restart {
			locks.unlock(&ra.mu)
			return .Restart
		}
		msgs := ra.inbox
		ra.inbox = make([dynamic][]byte, c.allocator)
		done := ra.reader_done
		locks.unlock(&ra.mu)
		defer {
			for m in msgs do delete(m, c.allocator)
			delete(msgs)
		}
		for m in msgs {
			action, reply := ra_handle(s, m)
			switch action {
			case .None:
			case .Send:
				if !send(ws, reply) do return .Fail
			case .Hello:
				iv := s.heartbeat_interval if s.heartbeat_interval > 0 else 41250
				next_beat = now_ms() + i64(f64(iv) * rand.float64())
			case .Heartbeat_Ack:
				acked = true
			case .Show_Qr:
				backoff_succeed(backoff)
				ra_publish(c, s, .Pending_Remote_Init)
			case .Show_User:
				ra_publish(c, s, .Pending_Ticket)
			case .Login:
				ra_publish(c, s, .Pending_Login)
				if ra_ticket_login(c, s) {
					ra_publish(c, s, .Finish)
					return .Stop
				}
				return .Fail
			case .Cancel:
				return .Restart
			case .Fail:
				return .Fail
			}
		}
		if done && len(msgs) == 0 do return .Fail
		if next_beat != 0 && now_ms() >= next_beat {
			if !acked do return .Fail // "heartbeat timeout, reconnecting."
			acked = false
			if !send(ws, RA_HEARTBEAT_MESSAGE) do return .Fail
			iv := s.heartbeat_interval if s.heartbeat_interval > 0 else 41250
			next_beat = now_ms() + iv
		}
	}
}

// POST /users/@me/remote-auth/login {"ticket"} -> encrypted_token; the token
// goes to the UI thread, which logs in with it (auth_apply).
@(private = "file")
ra_ticket_login :: proc(c: ^Client, s: ^Ra_Session) -> bool {
	w: Json
	json_init(&w)
	json_obj(&w)
	json_kstr(&w, "ticket", s.ticket)
	json_obj_end(&w)
	body := json_string(&w)
	r := api_call(c, "POST", "/users/@me/remote-auth/login", transmute([]byte)body, "application/json", "", nil, 0, 0, no_auth = true)
	defer if r.arena != nil {
		virtual.arena_destroy(r.arena)
		free(r.arena)
	}
	if !r.ok do return false
	tok, ok := ra_decrypt_token(s, fstr(vmap(r.body), "encrypted_token"), context.temp_allocator)
	if !ok do return false
	defer crypto.zero_explicit(raw_data(tok), len(tok))
	auth_push_token(c, tok, s.fingerprint, .Remote_Token)
	return true
}

