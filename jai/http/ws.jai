// WebSocket client (RFC 6455) over a netio.Stream. Framing, masking, control
// frames, the close handshake and UTF-8 / close-code validation are wslay's
// (vendor/wslay); this file does the HTTP/1.1 upgrade and the threading.
//
// Threading: one thread may sit in ws_recv while others call ws_send /
// ws_close. Every wslay call happens under `mu`; ws_recv blocks on the socket
// only outside it, then hands wslay the bytes it read.
//
// Handshake: ws_connect writes the caller's request headers verbatim. A
// `Sec-WebSocket-Key` header with an empty value is filled with a fresh random
// key in place; if absent, one is appended. permessage-deflate (offered like
// Chrome) is accepted only with Ws_Options.allow_deflate: received compressed
// messages are inflated (with the server's context takeover), and sent
// messages are wrapped in DEFLATE stored blocks (RSV1 set). Without
// allow_deflate, a server that accepts any extension fails the handshake with
// .Handshake (the Discord gateway never does).

WS_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

Ws_Message_Type :: enum u8 {
	Text;
	Binary;
}

// Close codes
WS_NORMAL :: 1000;
WS_GOING_AWAY :: 1001;
WS_PROTOCOL_ERROR :: 1002;
WS_NO_STATUS :: 1005;
WS_TOO_BIG :: 1009;

#if OS == .WINDOWS {
} else {
}
#scope_module

Wslay_Ctx :: struct {}

Wslay_Callbacks :: struct {
	recv: (ctx: *Wslay_Ctx, buf: *u8, len: u64, flags: s32, user: *void) -> int #c_call;
	send: (ctx: *Wslay_Ctx, data: *u8, len: u64, flags: s32, user: *void) -> int #c_call;
	genmask: (ctx: *Wslay_Ctx, buf: *u8, len: u64, user: *void) -> s32 #c_call;
	frame_start: *void;
	frame_chunk: *void;
	frame_end: *void;
	on_msg_recv: (ctx: *Wslay_Ctx, arg: *Wslay_Msg_Recv, user: *void) #c_call;
}

Wslay_Msg_Recv :: struct {
	rsv, opcode: u8;
	msg: *u8;
	msg_length: u64;
	status_code: u16;
}

Wslay_Msg :: struct {
	opcode: u8;
	msg: *u8;
	msg_length: u64;
}

WSLAY_ERR_CALLBACK_FAILURE :: -400;
WSLAY_ERR_WOULDBLOCK :: -401;
WSLAY_ERR_NO_MORE_MSG :: -302;
WSLAY_RSV1_BIT :: 1 << 2;
	wslay_event_context_client_init :: (ctx: **Wslay_Ctx, cb: *Wslay_Callbacks, user: *void) -> s32 #foreign wslay;
	wslay_event_context_free :: (ctx: *Wslay_Ctx) #foreign wslay;
	wslay_event_config_set_max_recv_msg_length :: (ctx: *Wslay_Ctx, val: u64) #foreign wslay;
	wslay_event_recv :: (ctx: *Wslay_Ctx) -> s32 #foreign wslay;
	wslay_event_send :: (ctx: *Wslay_Ctx) -> s32 #foreign wslay;
	wslay_event_queue_msg :: (ctx: *Wslay_Ctx, msg: *Wslay_Msg) -> s32 #foreign wslay;
	wslay_event_queue_msg_ex :: (ctx: *Wslay_Ctx, msg: *Wslay_Msg, rsv: u8) -> s32 #foreign wslay;
	wslay_event_config_set_allowed_rsv_bits :: (ctx: *Wslay_Ctx, rsv: u8) #foreign wslay;
	wslay_event_queue_close :: (ctx: *Wslay_Ctx, status_code: u16, reason: *u8, reason_length: u64) -> s32 #foreign wslay;
	wslay_event_set_error :: (ctx: *Wslay_Ctx, val: s32) #foreign wslay;
	wslay_event_get_read_enabled :: (ctx: *Wslay_Ctx) -> s32 #foreign wslay;
	wslay_event_get_close_received :: (ctx: *Wslay_Ctx) -> s32 #foreign wslay;
	wslay_event_get_status_code_received :: (ctx: *Wslay_Ctx) -> u16 #foreign wslay;
	wslay_event_get_status_code_sent :: (ctx: *Wslay_Ctx) -> u16 #foreign wslay;

Ws_Inbound :: struct {
	type: Ws_Message_Type;
	data: []u8;
}
#scope_export

Ws_Conn :: struct {
	s: netio.Stream;
	r: Reader;
	allocator: Allocator;
	mu: locks.Mutex;
	ctx: *Wslay_Ctx; // under mu
	inbox: [..]Ws_Inbound; // complete messages wslay delivered, oldest first
	close_code: int; // peer's close code (WS_NO_STATUS if none)
	close_reason: string;
	max_message: int;
	// permessage-deflate (negotiated with Ws_Options.allow_deflate)
	deflate: bool;
	no_takeover: bool; // server_no_context_takeover: no history between messages
	inflater: zlib.Inflater; // permessage-deflate decoder, kept across messages (context takeover)
	inflate_bad: bool; // a compressed message failed to inflate (fails ws_recv)
}

Ws_Options :: struct {
	max_message: int; // 0 -> 64 MiB
	allow_deflate: bool; // accept the server's permessage-deflate (see the header comment)
}

// ws_connect performs the opening handshake on s and returns the connection
// plus the 101 response (headers preserved in order; caller destroys it).
ws_connect :: (s: netio.Stream, req: Request, opts := Ws_Options.{}, allocator := context.allocator) -> *Ws_Conn, Response, Error {
	c: *Ws_Conn;
	resp: Response;
	err: Error;
	push_allocator(allocator);
	key_raw: [16]u8;
	crypto.rand_bytes(view(key_raw));
	key := base64.encode(view(key_raw), allocator = temp);

	headers := make_dynamic(Header, 0, len(req.headers) + 1, temp);
	placed := false;
	for h: req.headers {
		if strings.equal_fold(h.name, "sec-websocket-key") {
			if len(h.value) == 0 {
				append(*headers, Header.{h.name, key});
			} else {
				key = h.value; // caller-provided key (tests)
				append(*headers, h);
			}
			placed = true;
		} else {
			append(*headers, h);
		}
	}
	if !placed { append(*headers, Header.{"Sec-WebSocket-Key", key}); }
	r2 := req;
	r2.headers = view(headers);
	if r2.method == "" { r2.method = "GET"; }

	c = ws_attach(s, opts, allocator);
	{ err = h1_write_request(s, r2);
	if err != .None {
		ws_destroy(c);
		return null, .{}, err;
	} }
	limits := H1_Limits.{max_header_bytes = 64 << 10, max_headers = 128, max_body = 1 << 20};
	resp.allocator = allocator;
	resp.headers = make_dynamic(Header, 0, 16);
	while true {
		{ err = h1_read_head(*c.r, *resp, limits, allocator);
		if err != .None { break; } }
		if resp.status >= 100 && resp.status < 200 && resp.status != 101 {
			clear_headers(*resp);
			continue;
		}
		break;
	}
	if err == .None && !ws_validate_response(*resp, key, opts.allow_deflate, c) { err = .Handshake; }
	if err == .None && c.deflate { wslay_event_config_set_allowed_rsv_bits(c.ctx, WSLAY_RSV1_BIT); }
	if err != .None {
		ws_destroy(c);
		return null, resp, err;
	}
	return c, resp, .None;
}

// ws_attach wraps a stream that already speaks WebSocket (after the upgrade).
ws_attach :: (s: netio.Stream, opts := Ws_Options.{}, allocator := context.allocator) -> *Ws_Conn {
	c := new(Ws_Conn, allocator);
	c.s = s;
	c.allocator = allocator;
	c.close_code = WS_NO_STATUS;
	c.inbox = make_dynamic(Ws_Inbound, 0, 0, allocator);
	reader_init(*c.r, s, READER_SIZE, allocator);
	cb := Wslay_Callbacks.{
		recv = ws_recv_cb,
		send = ws_send_cb,
		genmask = ws_genmask_cb,
		on_msg_recv = ws_on_msg_cb
	};
	if wslay_event_context_client_init(*c.ctx, *cb, c) != 0 { panic("wslay: out of memory"); }
	c.max_message = ifx opts.max_message > 0 then opts.max_message else 64 << 20;
	wslay_event_config_set_max_recv_msg_length(c.ctx, cast(u64)(c.max_message));
	return c;
}

ws_accept_for_key :: (key: string, allocator := context.allocator) -> string {
	ctx: sha1.Context;
	sha1.init(*ctx);
	sha1.update(*ctx, transmute([]u8, key));
	sha1.update(*ctx, transmute([]u8, as_string(WS_GUID)));
	digest: [sha1.DIGEST_SIZE]u8;
	sha1.final(*ctx, view(digest));
	return base64.encode(view(digest), allocator = allocator);
}
#scope_module

ws_validate_response :: (resp: *Response, key: string, allow_deflate := false, c: *Ws_Conn = null) -> bool {
	if resp.status != 101 { return false; }
	if !header_has_token(view(resp.headers), "upgrade", "websocket") { return false; }
	if !header_has_token(view(resp.headers), "connection", "upgrade") { return false; }
	accept, ok := header_get(view(resp.headers), "sec-websocket-accept");
	if !ok || accept != ws_accept_for_key(key, temp) { return false; }
	{ ext, has := header_get(view(resp.headers), "sec-websocket-extensions");
	if has && len(strings.trim_space(ext)) > 0 {
		if !allow_deflate || c == null { return false; }
		return ws_accept_deflate(c, ext);
	} }
	return true;
}
#scope_export

ws_destroy :: (c: *Ws_Conn) {
	push_allocator(c.allocator);
	wslay_event_context_free(c.ctx);
	reader_destroy(*c.r);
	for m: c.inbox { delete(m.data); }
	delete(c.inbox);
	zlib.inflater_destroy(*c.inflater);
	if len(c.close_reason) > 0 { delete(c.close_reason); }
	free(c);
}

// ws_close_stream closes the transport and frees the connection. No other
// thread may be inside ws_* on c (shut the stream down and join it first).
ws_close_stream :: (c: *Ws_Conn) {
	netio.close(c.s);
	ws_destroy(c);
}
#scope_module

// ---- wslay callbacks (called with mu held) ----

// ws_recv_cb hands wslay only bytes already buffered, never blocking with mu held.
ws_recv_cb :: (ctx: *Wslay_Ctx, buf: *u8, n: u64, flags: s32, user: *void) -> int #c_call {
	push_context,defer_pop thread_context().*;
	w := cast(*Ws_Conn)user;
	got := min(cast(int)(n), w.r.end - w.r.start);
	if got == 0 {
		wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK);
		return -1;
	}
	mem.copy(buf, *w.r.buf[w.r.start], got);
	w.r.start += got;
	return got;
}

ws_send_cb :: (ctx: *Wslay_Ctx, data: *u8, n: u64, flags: s32, user: *void) -> int #c_call {
	push_context,defer_pop thread_context().*;
	w := cast(*Ws_Conn)user;
	if netio.write(w.s, sub(data, 0, n)) != .None {
		wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
		return -1;
	}
	return cast(int)(n);
}

ws_genmask_cb :: (ctx: *Wslay_Ctx, buf: *u8, n: u64, user: *void) -> s32 #c_call {
	push_context,defer_pop thread_context().*;
	crypto.rand_bytes(sub(buf, 0, n));
	return 0;
}

ws_on_msg_cb :: (ctx: *Wslay_Ctx, arg: *Wslay_Msg_Recv, user: *void) #c_call {
	w := cast(*Ws_Conn)user;
	push_context,defer_pop thread_context().*;
	push_allocator(w.allocator);
	if arg.opcode == {
	case 1; #through; case 2;
		data := make_slice(u8, cast(int) arg.msg_length);
		if arg.msg_length > 0 { mem.copy(raw_data(data), arg.msg, cast(int)(arg.msg_length)); }
		if (arg.rsv & WSLAY_RSV1_BIT) != 0 {
			// a compressed message (RSV1, only allowed once deflate is negotiated)
			buf := make_dynamic(u8, 0, len(data), temp);
			append(*buf, ..data);
			delete(data);
			if !ws_inflate(w, *buf) {
				w.inflate_bad = true;
				return;
			}
			data = make_slice(u8, len(buf));
			copy(data, view(buf));
		}
		append(*w.inbox, Ws_Inbound.{ifx arg.opcode == 1 then .Text else .Binary, data});
	case 8;
		if arg.msg_length > 2 && len(w.close_reason) == 0 { w.close_reason = clone(as_string(sub(arg.msg, 2, arg.msg_length))); }
	}
}
#scope_export

// ---- sending ----

// ws_send sends one message as a single frame (what Chrome does for gateway payloads).
ws_send :: (c: *Ws_Conn, type: Ws_Message_Type, payload: []u8) -> Error {
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	body := payload;
	rsv: u8 = 0;
	if c.deflate {
		body = deflate_stored(payload);
		rsv = WSLAY_RSV1_BIT;
	}
	m := Wslay_Msg.{xx ifx type == .Text then 1 else 2, raw_data(body), xx len(body)};
	{ rv := wslay_event_queue_msg_ex(c.ctx, *m, rsv);
	if rv != 0 { return ifx rv == WSLAY_ERR_NO_MORE_MSG then .Closed else .Out_Of_Memory; } }
	return ifx wslay_event_send(c.ctx) == 0 then .None else .Io;
}

// ws_close starts (or answers) the close handshake. Keep calling ws_recv
// until it returns .Closed, then ws_close_stream.
ws_close :: (c: *Ws_Conn, code := WS_NORMAL, reason := "") -> Error {
	locks.lock(*c.mu);
	defer locks.unlock(*c.mu);
	r := sub(reason, 0, min(len(reason), 123));
	status := ifx code != WS_NO_STATUS then code else 0;
	if wslay_event_queue_close(c.ctx, cast(u16)(status), raw_data(r), xx len(r)) != 0 { return .None; } // already closing
	return ifx wslay_event_send(c.ctx) == 0 then .None else .Io;
}

// ---- receiving ----

// ws_recv returns the next complete data message into msg (cleared first).
// Control frames are handled by wslay. Returns .Closed once the peer's close
// frame arrived (c.close_code / c.close_reason hold its status); on protocol
// violations wslay sends the proper close code and this returns .Protocol /
// .Too_Large.
ws_recv :: (c: *Ws_Conn, msg: *[..]u8) -> Ws_Message_Type, Error {
	type: Ws_Message_Type;
	err: Error;
	clear(msg);
	while true {
		locks.lock(*c.mu);
		rv := wslay_event_recv(c.ctx);
		sv := wslay_event_send(c.ctx); // pongs and close replies
		have := len(c.inbox) > 0;
		m: Ws_Inbound;
		if have { m = pop_front(*c.inbox); }
		closed := wslay_event_get_close_received(c.ctx) != 0;
		readable := wslay_event_get_read_enabled(c.ctx) != 0;
		if closed { c.close_code = cast(int)(wslay_event_get_status_code_received(c.ctx)); }
		sent := wslay_event_get_status_code_sent(c.ctx);
		locks.unlock(*c.mu);
		if have {
			append(msg, ..m.data);
			delete(m.data, c.allocator);
			return m.type, .None;
		}
		if c.inflate_bad { return type, .Protocol; }
		if closed { return type, .Closed; }
		if !readable { return type, ifx sent == WS_TOO_BIG then .Too_Large else .Protocol; }
		if rv != 0 || sv != 0 { return type, .Io; }
		__e5 := fill(*c.r); if failed(__e5) return type, __e5;
	}
}
#scope_module

// ---- permessage-deflate (RFC 7692) ----

// ws_accept_deflate: the server's answer must be permessage-deflate alone; its
// parameters only shape what we may expect (window bits never exceed 15).
ws_accept_deflate :: (c: *Ws_Conn, ext: string) -> bool {
	parts := strings.split(ext, ";", temp);
	if len(parts) == 0 || strings.trim_space(parts[0]) != "permessage-deflate" || strings.contains(ext, ",") { return false; }
	for p: sub_from(parts, 1) {
		kv := strings.trim_space(p);
		name := kv;
		{ i := strings.index_byte(kv, #char "=");
		if i >= 0 { name = strings.trim_space(sub(kv, 0, i)); } }
		if name == {
		case "server_no_context_takeover";
			c.no_takeover = true;
		case "client_no_context_takeover"; #through; case "server_max_window_bits"; #through; case "client_max_window_bits";
		// our stored blocks reference nothing; any window the server picks fits 32 KiB
		case;
			return false;
		}
	}
	c.deflate = true;
	return true;
}

// ws_inflate replaces msg (one compressed message) with its inflated bytes.
ws_inflate :: (c: *Ws_Conn, msg: *[..]u8) -> bool {
	// One raw-DEFLATE decoder per connection keeps the server's 32 KiB window across messages;
	// each message ends with the sync-flush tail RFC 7692 strips.
	if c.no_takeover || !c.inflater.state.count { zlib.inflater_init(*c.inflater, .Raw); }
	input := make_dynamic(u8, 0, len(msg) + 4, temp);
	append(*input, ..view(msg.*));
	append(*input, 0x00, 0x00, 0xff, 0xff);
	out: [..]u8;
	out.allocator = temp;
	_, ok := zlib.feed(*c.inflater, input, *out, c.max_message);
	if !ok { return false; }
	clear(msg);
	append(msg, ..out);
	return true;
}

// deflate_stored: payload as DEFLATE stored blocks, ending with the header byte
// of the empty sync-flush block whose 00 00 ff ff tail RFC 7692 strips.
deflate_stored :: (payload: []u8) -> []u8 {
	out := make_dynamic(u8, 0, len(payload) + 6 + 5 * (len(payload) / 65535), temp);
	rest := payload;
	while true {
		n := min(len(rest), 65535);
		append(*out, 0x00, cast(u8)(n), cast(u8)(n >> 8), ~cast(u8)(n), ~cast(u8)(n >> 8));
		append(*out, ..sub(rest, 0, n));
		rest = sub_from(rest, n);
		if len(rest) == 0 { break; }
	}
	append(*out, 0x00);
	return view(out);
}
#scope_export

