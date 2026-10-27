package http

import "base:runtime"
import "core:bytes"
import "core:c"
import "core:compress"
import "core:compress/zlib"
import "core:crypto"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:mem"
import "core:strings"
import "fc:locks"
import "fc:netio"

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

WS_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

Ws_Message_Type :: enum u8 {
	Text,
	Binary,
}

// Close codes
WS_NORMAL :: 1000
WS_GOING_AWAY :: 1001
WS_PROTOCOL_ERROR :: 1002
WS_NO_STATUS :: 1005
WS_TOO_BIG :: 1009

when ODIN_OS == .Windows {
	foreign import wslay "../../build/fc_wslay.obj"
} else {
	foreign import wslay "../../build/fc_wslay.o"
}

@(private)
Wslay_Ctx :: struct {}

@(private)
Wslay_Callbacks :: struct {
	recv:           proc "c" (ctx: ^Wslay_Ctx, buf: [^]byte, len: c.size_t, flags: c.int, user: rawptr) -> int,
	send:           proc "c" (ctx: ^Wslay_Ctx, data: [^]byte, len: c.size_t, flags: c.int, user: rawptr) -> int,
	genmask:        proc "c" (ctx: ^Wslay_Ctx, buf: [^]byte, len: c.size_t, user: rawptr) -> c.int,
	frame_start:    rawptr,
	frame_chunk:    rawptr,
	frame_end:      rawptr,
	on_msg_recv:    proc "c" (ctx: ^Wslay_Ctx, arg: ^Wslay_Msg_Recv, user: rawptr),
}

@(private)
Wslay_Msg_Recv :: struct {
	rsv, opcode: u8,
	msg:         [^]byte,
	msg_length:  c.size_t,
	status_code: u16,
}

@(private)
Wslay_Msg :: struct {
	opcode:     u8,
	msg:        [^]byte,
	msg_length: c.size_t,
}

@(private)
WSLAY_ERR_CALLBACK_FAILURE :: -400
@(private)
WSLAY_ERR_WOULDBLOCK :: -401
@(private)
WSLAY_ERR_NO_MORE_MSG :: -302
@(private)
WSLAY_RSV1_BIT :: 1 << 2

@(private, default_calling_convention = "c")
foreign wslay {
	wslay_event_context_client_init :: proc(ctx: ^^Wslay_Ctx, cb: ^Wslay_Callbacks, user: rawptr) -> c.int ---
	wslay_event_context_free :: proc(ctx: ^Wslay_Ctx) ---
	wslay_event_config_set_max_recv_msg_length :: proc(ctx: ^Wslay_Ctx, val: u64) ---
	wslay_event_recv :: proc(ctx: ^Wslay_Ctx) -> c.int ---
	wslay_event_send :: proc(ctx: ^Wslay_Ctx) -> c.int ---
	wslay_event_queue_msg :: proc(ctx: ^Wslay_Ctx, msg: ^Wslay_Msg) -> c.int ---
	wslay_event_queue_msg_ex :: proc(ctx: ^Wslay_Ctx, msg: ^Wslay_Msg, rsv: u8) -> c.int ---
	wslay_event_config_set_allowed_rsv_bits :: proc(ctx: ^Wslay_Ctx, rsv: u8) ---
	wslay_event_queue_close :: proc(ctx: ^Wslay_Ctx, status_code: u16, reason: [^]byte, reason_length: c.size_t) -> c.int ---
	wslay_event_set_error :: proc(ctx: ^Wslay_Ctx, val: c.int) ---
	wslay_event_get_read_enabled :: proc(ctx: ^Wslay_Ctx) -> c.int ---
	wslay_event_get_close_received :: proc(ctx: ^Wslay_Ctx) -> c.int ---
	wslay_event_get_status_code_received :: proc(ctx: ^Wslay_Ctx) -> u16 ---
	wslay_event_get_status_code_sent :: proc(ctx: ^Wslay_Ctx) -> u16 ---
}

@(private)
Ws_Inbound :: struct {
	type: Ws_Message_Type,
	data: []byte,
}

Ws_Conn :: struct {
	s:            netio.Stream,
	r:            Reader,
	allocator:    mem.Allocator,
	mu:           locks.Mutex,
	ctx:          ^Wslay_Ctx, // under mu
	inbox:        [dynamic]Ws_Inbound, // complete messages wslay delivered, oldest first
	close_code:   int, // peer's close code (WS_NO_STATUS if none)
	close_reason: string,
	max_message:  int,
	// permessage-deflate (negotiated with Ws_Options.allow_deflate)
	deflate:      bool,
	no_takeover:  bool, // server_no_context_takeover: no history between messages
	history:      [dynamic]byte, // last 32 KiB of inflated output (the server's window)
	inflate_bad:  bool, // a compressed message failed to inflate (fails ws_recv)
}

Ws_Options :: struct {
	max_message:   int, // 0 -> 64 MiB
	allow_deflate: bool, // accept the server's permessage-deflate (see the header comment)
}

// ws_connect performs the opening handshake on s and returns the connection
// plus the 101 response (headers preserved in order; caller destroys it).
ws_connect :: proc(
	s: netio.Stream,
	req: Request,
	opts := Ws_Options{},
	allocator := context.allocator,
) -> (
	c: ^Ws_Conn,
	resp: Response,
	err: Error,
) {
	context.allocator = allocator
	key_raw: [16]byte
	crypto.rand_bytes(key_raw[:])
	key := base64.encode(key_raw[:], allocator = context.temp_allocator)

	headers := make([dynamic]Header, 0, len(req.headers) + 1, context.temp_allocator)
	placed := false
	for h in req.headers {
		if strings.equal_fold(h.name, "sec-websocket-key") {
			if len(h.value) == 0 {
				append(&headers, Header{h.name, key})
			} else {
				key = h.value // caller-provided key (tests)
				append(&headers, h)
			}
			placed = true
		} else {
			append(&headers, h)
		}
	}
	if !placed do append(&headers, Header{"Sec-WebSocket-Key", key})
	r2 := req
	r2.headers = headers[:]
	if r2.method == "" do r2.method = "GET"

	c = ws_attach(s, opts, allocator)
	if err = h1_write_request(s, r2); err != .None {
		ws_destroy(c)
		return nil, {}, err
	}
	limits := H1_Limits{max_header_bytes = 64 << 10, max_headers = 128, max_body = 1 << 20}
	resp.allocator = allocator
	resp.headers = make([dynamic]Header, 0, 16)
	for {
		if err = h1_read_head(&c.r, &resp, limits, allocator); err != .None do break
		if resp.status >= 100 && resp.status < 200 && resp.status != 101 {
			clear_headers(&resp)
			continue
		}
		break
	}
	if err == .None && !ws_validate_response(&resp, key, opts.allow_deflate, c) do err = .Handshake
	if err == .None && c.deflate do wslay_event_config_set_allowed_rsv_bits(c.ctx, WSLAY_RSV1_BIT)
	if err != .None {
		ws_destroy(c)
		return nil, resp, err
	}
	return c, resp, .None
}

// ws_attach wraps a stream that already speaks WebSocket (after the upgrade).
ws_attach :: proc(s: netio.Stream, opts := Ws_Options{}, allocator := context.allocator) -> ^Ws_Conn {
	c := new(Ws_Conn, allocator)
	c.s = s
	c.allocator = allocator
	c.close_code = WS_NO_STATUS
	c.inbox = make([dynamic]Ws_Inbound, allocator)
	reader_init(&c.r, s, READER_SIZE, allocator)
	cb := Wslay_Callbacks {
		recv        = ws_recv_cb,
		send        = ws_send_cb,
		genmask     = ws_genmask_cb,
		on_msg_recv = ws_on_msg_cb,
	}
	if wslay_event_context_client_init(&c.ctx, &cb, c) != 0 do panic("wslay: out of memory")
	c.max_message = opts.max_message if opts.max_message > 0 else 64 << 20
	wslay_event_config_set_max_recv_msg_length(c.ctx, u64(c.max_message))
	return c
}

ws_accept_for_key :: proc(key: string, allocator := context.allocator) -> string {
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)key)
	sha1.update(&ctx, transmute([]byte)string(WS_GUID))
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	return base64.encode(digest[:], allocator = allocator)
}

@(private)
ws_validate_response :: proc(resp: ^Response, key: string, allow_deflate := false, c: ^Ws_Conn = nil) -> bool {
	if resp.status != 101 do return false
	if !header_has_token(resp.headers[:], "upgrade", "websocket") do return false
	if !header_has_token(resp.headers[:], "connection", "upgrade") do return false
	accept, ok := header_get(resp.headers[:], "sec-websocket-accept")
	if !ok || accept != ws_accept_for_key(key, context.temp_allocator) do return false
	if ext, has := header_get(resp.headers[:], "sec-websocket-extensions"); has && len(strings.trim_space(ext)) > 0 {
		if !allow_deflate || c == nil do return false
		return ws_accept_deflate(c, ext)
	}
	return true
}

ws_destroy :: proc(c: ^Ws_Conn) {
	context.allocator = c.allocator
	wslay_event_context_free(c.ctx)
	reader_destroy(&c.r)
	for m in c.inbox do delete(m.data)
	delete(c.inbox)
	delete(c.history)
	if len(c.close_reason) > 0 do delete(c.close_reason)
	free(c)
}

// ws_close_stream closes the transport and frees the connection. No other
// thread may be inside ws_* on c (shut the stream down and join it first).
ws_close_stream :: proc(c: ^Ws_Conn) {
	netio.close(c.s)
	ws_destroy(c)
}

// ---- wslay callbacks (called with mu held) ----

// ws_recv_cb hands wslay only bytes already buffered, never blocking with mu held.
@(private)
ws_recv_cb :: proc "c" (ctx: ^Wslay_Ctx, buf: [^]byte, n: c.size_t, flags: c.int, user: rawptr) -> int {
	w := cast(^Ws_Conn)user
	got := min(int(n), w.r.end - w.r.start)
	if got == 0 {
		wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK)
		return -1
	}
	mem.copy(buf, &w.r.buf[w.r.start], got)
	w.r.start += got
	return got
}

@(private)
ws_send_cb :: proc "c" (ctx: ^Wslay_Ctx, data: [^]byte, n: c.size_t, flags: c.int, user: rawptr) -> int {
	context = runtime.default_context()
	w := cast(^Ws_Conn)user
	if netio.write(w.s, data[:n]) != .None {
		wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE)
		return -1
	}
	return int(n)
}

@(private)
ws_genmask_cb :: proc "c" (ctx: ^Wslay_Ctx, buf: [^]byte, n: c.size_t, user: rawptr) -> c.int {
	context = runtime.default_context()
	crypto.rand_bytes(buf[:n])
	return 0
}

@(private)
ws_on_msg_cb :: proc "c" (ctx: ^Wslay_Ctx, arg: ^Wslay_Msg_Recv, user: rawptr) {
	w := cast(^Ws_Conn)user
	context = runtime.default_context()
	context.allocator = w.allocator
	switch arg.opcode {
	case 1, 2:
		data := make([]byte, arg.msg_length)
		if arg.msg_length > 0 do mem.copy(raw_data(data), arg.msg, int(arg.msg_length))
		if arg.rsv & WSLAY_RSV1_BIT != 0 {
			// a compressed message (RSV1, only allowed once deflate is negotiated)
			buf := make([dynamic]byte, 0, len(data), context.temp_allocator)
			append(&buf, ..data)
			delete(data)
			if !ws_inflate(w, &buf) {
				w.inflate_bad = true
				return
			}
			data = make([]byte, len(buf))
			copy(data, buf[:])
		}
		append(&w.inbox, Ws_Inbound{.Text if arg.opcode == 1 else .Binary, data})
	case 8:
		if arg.msg_length > 2 && len(w.close_reason) == 0 do w.close_reason = strings.clone(string(arg.msg[2:arg.msg_length]))
	}
}

// ---- sending ----

// ws_send sends one message as a single frame (what Chrome does for gateway payloads).
ws_send :: proc(c: ^Ws_Conn, type: Ws_Message_Type, payload: []byte) -> Error {
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	body := payload
	rsv: u8 = 0
	if c.deflate {
		body = deflate_stored(payload)
		rsv = WSLAY_RSV1_BIT
	}
	m := Wslay_Msg{1 if type == .Text else 2, raw_data(body), len(body)}
	if rv := wslay_event_queue_msg_ex(c.ctx, &m, rsv); rv != 0 do return .Closed if rv == WSLAY_ERR_NO_MORE_MSG else .Out_Of_Memory
	return .None if wslay_event_send(c.ctx) == 0 else .Io
}

// ws_close starts (or answers) the close handshake. Keep calling ws_recv
// until it returns .Closed, then ws_close_stream.
ws_close :: proc(c: ^Ws_Conn, code := WS_NORMAL, reason := "") -> Error {
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	r := reason[:min(len(reason), 123)]
	code := code if code != WS_NO_STATUS else 0
	if wslay_event_queue_close(c.ctx, u16(code), raw_data(r), len(r)) != 0 do return .None // already closing
	return .None if wslay_event_send(c.ctx) == 0 else .Io
}

// ---- receiving ----

// ws_recv returns the next complete data message into msg (cleared first).
// Control frames are handled by wslay. Returns .Closed once the peer's close
// frame arrived (c.close_code / c.close_reason hold its status); on protocol
// violations wslay sends the proper close code and this returns .Protocol /
// .Too_Large.
ws_recv :: proc(c: ^Ws_Conn, msg: ^[dynamic]byte) -> (type: Ws_Message_Type, err: Error) {
	clear(msg)
	for {
		locks.lock(&c.mu)
		rv := wslay_event_recv(c.ctx)
		sv := wslay_event_send(c.ctx) // pongs and close replies
		have := len(c.inbox) > 0
		m: Ws_Inbound
		if have do m = pop_front(&c.inbox)
		closed := wslay_event_get_close_received(c.ctx) != 0
		readable := wslay_event_get_read_enabled(c.ctx) != 0
		if closed do c.close_code = int(wslay_event_get_status_code_received(c.ctx))
		sent := wslay_event_get_status_code_sent(c.ctx)
		locks.unlock(&c.mu)
		if have {
			append(msg, ..m.data)
			delete(m.data, c.allocator)
			return m.type, .None
		}
		if c.inflate_bad do return type, .Protocol
		if closed do return type, .Closed
		if !readable do return type, .Too_Large if sent == WS_TOO_BIG else .Protocol
		if rv != 0 || sv != 0 do return type, .Io
		fill(&c.r) or_return
	}
}

// ---- permessage-deflate (RFC 7692) ----

// ws_accept_deflate: the server's answer must be permessage-deflate alone; its
// parameters only shape what we may expect (window bits never exceed 15).
@(private)
ws_accept_deflate :: proc(c: ^Ws_Conn, ext: string) -> bool {
	parts := strings.split(ext, ";", context.temp_allocator)
	if len(parts) == 0 || strings.trim_space(parts[0]) != "permessage-deflate" || strings.contains(ext, ",") do return false
	for p in parts[1:] {
		kv := strings.trim_space(p)
		name := kv
		if i := strings.index_byte(kv, '='); i >= 0 do name = strings.trim_space(kv[:i])
		switch name {
		case "server_no_context_takeover":
			c.no_takeover = true
		case "client_no_context_takeover", "server_max_window_bits", "client_max_window_bits":
		// our stored blocks reference nothing; any window the server picks fits 32 KiB
		case:
			return false
		}
	}
	c.deflate = true
	return true
}

// ws_inflate replaces msg (one compressed message) with its inflated bytes.
@(private)
ws_inflate :: proc(c: ^Ws_Conn, msg: ^[dynamic]byte) -> bool {
	WINDOW :: 32768
	// the message + the stripped sync-flush tail, then an empty final block
	input := make([dynamic]byte, 0, len(msg) + 6, context.temp_allocator)
	append(&input, ..msg[:])
	append(&input, 0x00, 0x00, 0xff, 0xff, 0x03, 0x00)
	out: bytes.Buffer
	defer bytes.buffer_destroy(&out)
	hist := len(c.history) if !c.no_takeover else 0
	append(&out.buf, ..c.history[len(c.history) - hist:])
	ctx := compress.Context_Memory_Input{input_data = input[:], output = &out, bytes_written = i64(hist)}
	expected := min(hist + max(8 * len(msg), 4096), c.max_message + hist)
	if zlib.inflate_raw(&ctx, expected_output_size = expected) != nil do return false
	data := out.buf[hist:int(ctx.bytes_written)]
	if len(data) > c.max_message do return false
	clear(msg)
	append(msg, ..data)
	if !c.no_takeover {
		all := out.buf[:int(ctx.bytes_written)]
		keep := all[max(len(all) - WINDOW, 0):]
		clear(&c.history)
		append(&c.history, ..keep)
	}
	return true
}

// deflate_stored: payload as DEFLATE stored blocks, ending with the header byte
// of the empty sync-flush block whose 00 00 ff ff tail RFC 7692 strips.
@(private)
deflate_stored :: proc(payload: []byte) -> []byte {
	out := make([dynamic]byte, 0, len(payload) + 6 + 5 * (len(payload) / 65535), context.temp_allocator)
	rest := payload
	for {
		n := min(len(rest), 65535)
		append(&out, 0x00, u8(n), u8(n >> 8), ~u8(n), ~u8(n >> 8))
		append(&out, ..rest[:n])
		rest = rest[n:]
		if len(rest) == 0 do break
	}
	append(&out, 0x00)
	return out[:]
}
