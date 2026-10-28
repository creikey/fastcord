// WebSocket client (RFC 6455) over a netio.Stream. Framing, masking, control frames, the close handshake
// and UTF-8 / close-code validation are wslay's (vendor/wslay); this file does the HTTP/1.1 upgrade and
// the threading.
//
// Threading: one thread may sit in ws_recv while others call ws_send / ws_close. Every wslay call happens
// under `mu`; ws_recv blocks on the socket only outside it, then hands wslay the bytes it read.
//
// Handshake: ws_connect writes the caller's request headers verbatim. A `Sec-WebSocket-Key` header with an
// empty value is filled with a fresh random key in place; if absent, one is appended. permessage-deflate
// (offered like Chrome) is accepted only with Ws_Options.allow_deflate: received compressed messages are
// inflated (with the server's context takeover), and sent messages are wrapped in DEFLATE stored blocks
// (RSV1 set). Without allow_deflate, a server that accepts any extension fails the handshake with
// .Handshake (the Discord gateway never does).

Ws_Message_Type :: enum u8 { Text; Binary; }

// Close codes
WS_NORMAL :: 1000;
WS_GOING_AWAY :: 1001;
WS_PROTOCOL_ERROR :: 1002;
WS_NO_STATUS :: 1005;
WS_TOO_BIG :: 1009;

Ws_Conn :: struct {
	s: netio.Stream;
	r: Reader;
	allocator: Allocator;
	mu: locks.Mutex;
	ctx: *#Context;           // under mu: the context wslay's callbacks run in
	wslay: *Wslay_Ctx;        // under mu
	inbox: [..]Ws_Inbound;    // complete messages wslay delivered, oldest first
	close_code: int;          // peer's close code (WS_NO_STATUS if none)
	close_reason: string;
	max_message: int;
	// permessage-deflate (negotiated with Ws_Options.allow_deflate)
	deflate: bool;
	no_takeover: bool;        // server_no_context_takeover: no history between messages
	inflater: inflate.Inflater; // kept across messages (context takeover)
	inflate_bad: bool;        // a compressed message failed to inflate (fails ws_recv)
	stored: [..]u8;           // under mu: an outgoing message as DEFLATE stored blocks
}

Ws_Options :: struct {
	max_message: int;    // 0 -> 64 MiB
	allow_deflate: bool; // accept the server's permessage-deflate (see the header comment)
	server: bool;        // the accepting side: the peer's frames must be masked, ours are not
}

// ws_connect performs the opening handshake on s and returns the connection plus the 101 response
// (headers preserved in order; caller destroys it), both from context.allocator.
ws_connect :: (s: netio.Stream, req: Request, opts := Ws_Options.{}) -> *Ws_Conn, Response, Error {
	key_raw: [16]u8;
	crypto.random_bytes(key_raw);
	key := base64_encode(cast(string) key_raw,, temp);

	headers := NewArray(req.headers.count + 1, Header,, temp);
	headers.count = 0;
	placed := false;
	for h: req.headers {
		headers.count += 1;
		headers[it_index] = h;
		if !equal_nocase(h.name, "sec-websocket-key") continue;
		if !h.value headers[it_index].value = key;
		else key = h.value; // caller-provided key (tests)
		placed = true;
	}
	if !placed { headers.count += 1; headers[headers.count - 1] = .{"Sec-WebSocket-Key", key}; }
	r2 := req;
	r2.headers = headers;
	if !r2.method r2.method = "GET";

	c := ws_attach(s, opts);
	err := h1_write_request(s, r2);
	if err != .None {
		ws_destroy(c);
		return null, .{}, err;
	}
	limits := H1_Limits.{max_header_bytes = 64 << 10, max_headers = 128, max_body = 1 << 20};
	resp := make_response(.Http1_1);
	while true {
		err = h1_read_head(*c.r, *resp, limits);
		if err != .None || resp.status < 100 || resp.status >= 200 || resp.status == 101 break;
		clear_headers(*resp.headers);
	}
	if err == .None && !ws_validate_response(*resp, key, opts.allow_deflate, c) err = .Handshake;
	if err == .None && c.deflate wslay_event_config_set_allowed_rsv_bits(c.wslay, WSLAY_RSV1_BIT);
	if err != .None {
		ws_destroy(c);
		return null, resp, err;
	}
	return c, resp, .None;
}

// ws_attach wraps a stream that already speaks WebSocket (after the upgrade); c lives in context.allocator.
ws_attach :: (s: netio.Stream, opts := Ws_Options.{}) -> *Ws_Conn {
	c := New(Ws_Conn);
	c.s = s;
	c.allocator = context.allocator;
	c.close_code = WS_NO_STATUS;
	c.inbox.allocator, c.stored.allocator = context.allocator, context.allocator;
	reader_init(*c.r, s);
	cb := Wslay_Callbacks.{recv = ws_recv_cb, send = ws_send_cb, genmask = ws_genmask_cb, on_msg_recv = ws_on_msg_cb};
	init := ifx opts.server then wslay_event_context_server_init else wslay_event_context_client_init;
	assert(init(*c.wslay, *cb, c) == 0, "wslay: out of memory");
	c.max_message = ifx opts.max_message > 0 then opts.max_message else 64 << 20;
	wslay_event_config_set_max_recv_msg_length(c.wslay, xx c.max_message);
	return c;
}

// ws_accept_for_key is the Sec-WebSocket-Accept a server answers key with, from context.allocator.
ws_accept_for_key :: (key: string) -> string {
	digest := crypto.sha1(cast([]u8) join(key, WS_GUID,, temp));
	return base64_encode(cast(string) digest);
}

ws_destroy :: (c: *Ws_Conn) {
	push_allocator(c.allocator);
	wslay_event_context_free(c.wslay);
	reader_destroy(*c.r);
	for c.inbox array_free(it.data);
	array_free(c.inbox);
	array_free(c.stored);
	inflate.destroy(*c.inflater);
	free_string(c.close_reason);
	free(c);
}

// ws_close_stream closes the transport and frees the connection. No other thread may be inside ws_* on c
// (shut the stream down and join it first).
ws_close_stream :: (c: *Ws_Conn) {
	netio.close(c.s);
	ws_destroy(c);
}

// ws_send sends one message as a single frame (what Chrome does for gateway payloads).
ws_send :: (c: *Ws_Conn, type: Ws_Message_Type, payload: []u8) -> Error {
	lock(c);
	defer locks.unlock(*c.mu);
	body := payload;
	rsv: u8 = 0;
	if c.deflate {
		deflate_stored(*c.stored, payload);
		body = c.stored;
		rsv = WSLAY_RSV1_BIT;
	}
	m := Wslay_Msg.{xx ifx type == .Text then 1 else 2, body.data, xx body.count};
	rv := wslay_event_queue_msg_ex(c.wslay, *m, rsv);
	if rv != 0 return ifx rv == WSLAY_ERR_NO_MORE_MSG then .Closed else .Out_Of_Memory;
	return ifx wslay_event_send(c.wslay) == 0 then .None else .Io;
}

// ws_close starts (or answers) the close handshake. Keep calling ws_recv until it returns .Closed, then
// ws_close_stream.
ws_close :: (c: *Ws_Conn, code := WS_NORMAL, reason := "") -> Error {
	lock(c);
	defer locks.unlock(*c.mu);
	r := slice(reason, 0, min(reason.count, 123));
	status := ifx code != WS_NO_STATUS then code else 0;
	if wslay_event_queue_close(c.wslay, xx status, r.data, xx r.count) != 0 return .None; // already closing
	return ifx wslay_event_send(c.wslay) == 0 then .None else .Io;
}

// ws_recv returns the next complete data message into msg (cleared first). Control frames are handled by
// wslay. Returns .Closed once the peer's close frame arrived (c.close_code / c.close_reason hold its
// status); on protocol violations wslay sends the proper close code and this returns .Protocol /
// .Too_Large.
ws_recv :: (c: *Ws_Conn, msg: *[..]u8) -> Ws_Message_Type, Error {
	msg.count = 0;
	while true {
		lock(c);
		rv := wslay_event_recv(c.wslay);
		sv := wslay_event_send(c.wslay); // pongs and close replies
		have := c.inbox.count > 0;
		m: Ws_Inbound;
		if have { m = c.inbox[0]; array_ordered_remove_by_index(*c.inbox, 0); }
		closed := wslay_event_get_close_received(c.wslay) != 0;
		readable := wslay_event_get_read_enabled(c.wslay) != 0;
		if closed c.close_code = wslay_event_get_status_code_received(c.wslay);
		sent := wslay_event_get_status_code_sent(c.wslay);
		locks.unlock(*c.mu);
		if have {
			array_add(msg, ..m.data);
			array_free(m.data,, c.allocator);
			return m.type, .None;
		}
		if c.inflate_bad return .Text, .Protocol;
		if closed return .Text, .Closed;
		if !readable return .Text, ifx sent == WS_TOO_BIG then .Too_Large else .Protocol;
		if rv != 0 || sv != 0 return .Text, .Io;
		err := fill(*c.r);
		if err != .None return .Text, err;
	}
	return .Text, .None;
}

#scope_module

WS_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

Ws_Inbound :: struct {
	type: Ws_Message_Type;
	data: []u8;
}

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

wslay_event_context_client_init :: (ctx: **Wslay_Ctx, cb: *Wslay_Callbacks, user: *void) -> s32 #foreign vendor;
wslay_event_context_server_init :: (ctx: **Wslay_Ctx, cb: *Wslay_Callbacks, user: *void) -> s32 #foreign vendor;
wslay_event_context_free :: (ctx: *Wslay_Ctx) #foreign vendor;
wslay_event_config_set_max_recv_msg_length :: (ctx: *Wslay_Ctx, val: u64) #foreign vendor;
wslay_event_recv :: (ctx: *Wslay_Ctx) -> s32 #foreign vendor;
wslay_event_send :: (ctx: *Wslay_Ctx) -> s32 #foreign vendor;
wslay_event_queue_msg_ex :: (ctx: *Wslay_Ctx, msg: *Wslay_Msg, rsv: u8) -> s32 #foreign vendor;
wslay_event_config_set_allowed_rsv_bits :: (ctx: *Wslay_Ctx, rsv: u8) #foreign vendor;
wslay_event_queue_close :: (ctx: *Wslay_Ctx, status_code: u16, reason: *u8, reason_length: u64) -> s32 #foreign vendor;
wslay_event_set_error :: (ctx: *Wslay_Ctx, val: s32) #foreign vendor;
wslay_event_get_read_enabled :: (ctx: *Wslay_Ctx) -> s32 #foreign vendor;
wslay_event_get_close_received :: (ctx: *Wslay_Ctx) -> s32 #foreign vendor;
wslay_event_get_status_code_received :: (ctx: *Wslay_Ctx) -> u16 #foreign vendor;
wslay_event_get_status_code_sent :: (ctx: *Wslay_Ctx) -> u16 #foreign vendor;

// lock takes c.mu; wslay calls made under it run their callbacks in this thread's context.
lock :: (c: *Ws_Conn) #expand {
	locks.lock(*c.mu);
	c.ctx = *context;
}

ws_validate_response :: (resp: *Response, key: string, allow_deflate: bool, c: *Ws_Conn) -> bool {
	if resp.status != 101 return false;
	if !header_has_token(resp.headers, "upgrade", "websocket") return false;
	if !header_has_token(resp.headers, "connection", "upgrade") return false;
	accept, ok := header_get(resp.headers, "sec-websocket-accept");
	if !ok || accept != ws_accept_for_key(key,, temp) return false;
	ext, has := header_get(resp.headers, "sec-websocket-extensions");
	if has && trim(ext) {
		if !allow_deflate return false;
		return ws_accept_deflate(c, ext);
	}
	return true;
}

// ---- wslay callbacks (called with mu held) ----

// ws_recv_cb hands wslay only bytes already buffered, never blocking with mu held.
ws_recv_cb :: (ctx: *Wslay_Ctx, buf: *u8, n: u64, flags: s32, user: *void) -> int #c_call {
	w := cast(*Ws_Conn) user;
	got := w.r.end - w.r.start;
	if cast(s64) n < got got = xx n;
	if !got {
		wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK);
		return -1;
	}
	memcpy(buf, w.r.buf.data + w.r.start, got);
	w.r.start += got;
	return got;
}

ws_send_cb :: (ctx: *Wslay_Ctx, data: *u8, n: u64, flags: s32, user: *void) -> int #c_call {
	w := cast(*Ws_Conn) user;
	push_context w.ctx.* {
		if netio.write(w.s, .{xx n, data}) != .None {
			wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
			return -1;
		}
		return xx n;
	}
}

ws_genmask_cb :: (ctx: *Wslay_Ctx, buf: *u8, n: u64, user: *void) -> s32 #c_call {
	w := cast(*Ws_Conn) user;
	push_context w.ctx.* {
		crypto.random_bytes(.{xx n, buf});
		return 0;
	}
}

ws_on_msg_cb :: (ctx: *Wslay_Ctx, arg: *Wslay_Msg_Recv, user: *void) #c_call {
	w := cast(*Ws_Conn) user;
	push_context w.ctx.* {
		push_allocator(w.allocator);
		src := []u8.{xx arg.msg_length, arg.msg};
		if arg.opcode == {
		case 1; #through;
		case 2;
			data: []u8;
			if arg.rsv & WSLAY_RSV1_BIT {
				// a compressed message (RSV1, only allowed once deflate is negotiated)
				ok: bool;
				data, ok = ws_inflate(w, src);
				if !ok { w.inflate_bad = true; return; }
			} else {
				data = array_copy(src);
			}
			array_add(*w.inbox, .{ifx arg.opcode == 1 then .Text else .Binary, data});
		case 8;
			if arg.msg_length > 2 && !w.close_reason w.close_reason = copy_string(cast(string) array_view(src, 2));
		}
	}
}

// ---- permessage-deflate (RFC 7692) ----

// ws_accept_deflate: the server's answer must be permessage-deflate alone; its parameters only shape what
// we may expect (window bits never exceed 15).
ws_accept_deflate :: (c: *Ws_Conn, ext: string) -> bool {
	parts := split(ext, #char ";",, temp);
	if trim(parts[0]) != "permessage-deflate" || contains(ext, #char ",") return false;
	for array_view(parts, 1) {
		_, name := split_from_left(trim(it), #char "=");
		if trim(name) == {
		case "server_no_context_takeover";
			c.no_takeover = true;
		case "client_no_context_takeover"; #through;
		case "server_max_window_bits"; #through;
		case "client_max_window_bits";
			// our stored blocks reference nothing; any window the server picks fits 32 KiB
		case;
			return false;
		}
	}
	c.deflate = true;
	return true;
}

// ws_inflate decodes one compressed message, from context.allocator. One raw-DEFLATE decoder per
// connection keeps the server's 32 KiB window across messages; each message ends with the sync-flush tail
// RFC 7692 strips.
ws_inflate :: (c: *Ws_Conn, msg: []u8) -> []u8, bool {
	if c.no_takeover || !c.inflater.state.count inflate.init(*c.inflater, .RAW);
	TAIL :: u8.[0x00, 0x00, 0xff, 0xff];
	out: [..]u8;
	_, ok := inflate.feed(*c.inflater, msg, *out, c.max_message);
	if ok _, ok = inflate.feed(*c.inflater, TAIL, *out, c.max_message);
	if !ok { array_free(out); return .[], false; }
	return out, true;
}

// deflate_stored writes payload into out as DEFLATE stored blocks, ending with the header byte of the empty
// sync-flush block whose 00 00 ff ff tail RFC 7692 strips.
deflate_stored :: (out: *[..]u8, payload: []u8) {
	out.count = 0;
	array_reserve(out, payload.count + 6 + 5 * (payload.count / 65535));
	rest := payload;
	while true {
		n := min(rest.count, 65535);
		array_add(out, 0x00, cast(u8) n, cast(u8) (n >> 8), ~(cast(u8) n), ~(cast(u8) (n >> 8)));
		array_add(out, ..array_view(rest, 0, n));
		rest = array_view(rest, n);
		if !rest.count break;
	}
	array_add(out, 0x00);
}
