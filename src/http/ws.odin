package http

import "fc:locks"
import "core:bytes"
import "core:compress"
import "core:compress/zlib"
import "core:crypto"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import "fc:netio"

// WebSocket client (RFC 6455) over a netio.Stream.
//
// Threading: one thread may sit in ws_recv while others call ws_send /
// ws_ping / ws_close (sends are serialized by a mutex). ws_recv answers
// PINGs and the close handshake itself.
//
// Handshake: ws_connect writes the caller's request headers verbatim (see
// WS_DISCORD_HEADERS-style usage below). A `Sec-WebSocket-Key` header with
// an empty value is filled with a fresh random key in place; if absent, one
// is appended. permessage-deflate (offered like Chrome) is accepted only with
// Ws_Options.allow_deflate: received compressed messages are inflated (with
// the server's context takeover), and sent messages are wrapped in DEFLATE
// stored blocks (RSV1 set, as Chrome compresses every message once the
// extension is negotiated). Without allow_deflate, a server that accepts any
// extension fails the handshake with .Handshake (the Discord gateway never does).

WS_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

Ws_Opcode :: enum u8 {
	Continuation = 0,
	Text         = 1,
	Binary       = 2,
	Close        = 8,
	Ping         = 9,
	Pong         = 10,
}

Ws_Message_Type :: enum u8 {
	Text,
	Binary,
}

// Close codes
WS_NORMAL :: 1000
WS_GOING_AWAY :: 1001
WS_PROTOCOL_ERROR :: 1002
WS_UNSUPPORTED :: 1003
WS_NO_STATUS :: 1005
WS_ABNORMAL :: 1006
WS_INVALID_DATA :: 1007
WS_POLICY :: 1008
WS_TOO_BIG :: 1009

Ws_Conn :: struct {
	s:              netio.Stream,
	r:              Reader,
	allocator:      mem.Allocator,
	max_message:    int,
	wmu:            locks.Mutex,
	sent_close:     bool, // under wmu
	recv_close:     bool,
	close_code:     int, // peer's close code (WS_NO_STATUS if none)
	close_reason:   string,
	last_pong:      [dynamic]byte,
	pongs:          int,
	// mask key entropy pool (under wmu)
	entropy:        [256]byte,
	entropy_pos:    int,
	// permessage-deflate (negotiated with Ws_Options.allow_deflate)
	deflate:        bool,
	no_takeover:    bool, // server_no_context_takeover: no history between messages
	history:        [dynamic]byte, // last 32 KiB of inflated output (the server's window)
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

	c = new(Ws_Conn)
	c.s = s
	c.allocator = allocator
	c.max_message = opts.max_message if opts.max_message > 0 else 64 << 20
	c.close_code = WS_NO_STATUS
	c.entropy_pos = len(c.entropy)
	c.last_pong = make([dynamic]byte)
	reader_init(&c.r, s, READER_SIZE)

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
	if err != .None {
		ws_destroy(c)
		return nil, resp, err
	}
	return c, resp, .None
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
	reader_destroy(&c.r)
	delete(c.last_pong)
	delete(c.history)
	if len(c.close_reason) > 0 do delete(c.close_reason)
	free(c)
}

// ws_shutdown wakes a thread blocked in ws_recv (it returns .Closed) without
// freeing anything. Join that thread, then call ws_close_stream.
ws_shutdown :: proc(c: ^Ws_Conn) {netio.shutdown(c.s)}

// ws_close_stream closes the transport and frees the connection. No other
// thread may be inside ws_* on c (use ws_shutdown + join first).
ws_close_stream :: proc(c: ^Ws_Conn) {
	netio.close(c.s)
	ws_destroy(c)
}

// ---- sending ----

@(private)
mask_key :: proc(c: ^Ws_Conn) -> (k: [4]byte) {
	if c.entropy_pos + 4 > len(c.entropy) {
		crypto.rand_bytes(c.entropy[:])
		c.entropy_pos = 0
	}
	copy(k[:], c.entropy[c.entropy_pos:][:4])
	c.entropy_pos += 4
	return
}

// ws_frame_header appends a client frame header (always masked).
ws_put_header :: proc(buf: ^[dynamic]byte, fin: bool, op: Ws_Opcode, length: int, key: [4]byte) {
	b0 := u8(op)
	if fin do b0 |= 0x80
	append(buf, b0)
	switch {
	case length < 126:
		append(buf, 0x80 | u8(length))
	case length <= 0xffff:
		append(buf, 0x80 | 126, u8(length >> 8), u8(length))
	case:
		append(buf, 0x80 | 127)
		for i := 7; i >= 0; i -= 1 do append(buf, u8(u64(length) >> (8 * uint(i))))
	}
	k := key
	append(buf, ..k[:])
}

@(private)
ws_write_frame_locked :: proc(c: ^Ws_Conn, fin: bool, op: Ws_Opcode, payload: []byte, rsv1 := false) -> Error {
	key := mask_key(c)
	buf := make([dynamic]byte, 0, len(payload) + 14, context.temp_allocator)
	ws_put_header(&buf, fin, op, len(payload), key)
	if rsv1 do buf[0] |= 0x40
	start := len(buf)
	append(&buf, ..payload)
	for i in 0 ..< len(payload) do buf[start + i] ~= key[i & 3]
	return map_net_error(netio.write(c.s, buf[:]))
}

// ws_send sends one message as a single frame (what Chrome does for gateway payloads).
ws_send :: proc(c: ^Ws_Conn, type: Ws_Message_Type, payload: []byte) -> Error {
	return ws_send_fragmented(c, type, payload, 0)
}

// ws_send_fragmented splits the message into frames of at most fragment_size (0 = one frame).
ws_send_fragmented :: proc(c: ^Ws_Conn, type: Ws_Message_Type, payload: []byte, fragment_size: int) -> Error {
	locks.lock(&c.wmu)
	defer locks.unlock(&c.wmu)
	if c.sent_close do return .Closed
	op := Ws_Opcode.Text if type == .Text else .Binary
	if c.deflate {
		return ws_write_frame_locked(c, true, op, deflate_stored(payload), rsv1 = true)
	}
	if fragment_size <= 0 || len(payload) <= fragment_size {
		return ws_write_frame_locked(c, true, op, payload)
	}
	rest := payload
	for len(rest) > 0 {
		n := min(len(rest), fragment_size)
		ws_write_frame_locked(c, n == len(rest), op, rest[:n]) or_return
		op = .Continuation
		rest = rest[n:]
	}
	return .None
}

ws_ping :: proc(c: ^Ws_Conn, payload: []byte = nil) -> Error {
	if len(payload) > 125 do return .Bad_Request
	locks.lock(&c.wmu)
	defer locks.unlock(&c.wmu)
	if c.sent_close do return .Closed
	return ws_write_frame_locked(c, true, .Ping, payload)
}

// ws_close starts (or answers) the close handshake. Keep calling ws_recv
// until it returns .Closed, then ws_close_stream.
ws_close :: proc(c: ^Ws_Conn, code := WS_NORMAL, reason := "") -> Error {
	locks.lock(&c.wmu)
	defer locks.unlock(&c.wmu)
	return ws_close_locked(c, code, reason)
}

@(private)
ws_close_locked :: proc(c: ^Ws_Conn, code: int, reason: string) -> Error {
	if c.sent_close do return .None
	c.sent_close = true
	if code == WS_NO_STATUS do return ws_write_frame_locked(c, true, .Close, nil)
	body := make([dynamic]byte, 0, 2 + len(reason), context.temp_allocator)
	append(&body, u8(code >> 8), u8(code))
	r := reason
	if len(r) > 123 do r = r[:123]
	append(&body, r)
	return ws_write_frame_locked(c, true, .Close, body[:])
}

// ---- receiving ----

Ws_Frame_Header :: struct {
	fin:    bool,
	rsv:    u8,
	opcode: u8,
	masked: bool,
	length: u64,
	key:    [4]byte,
}

// ws_read_frame_header parses a frame header from the reader.
ws_read_frame_header :: proc(r: ^Reader) -> (h: Ws_Frame_Header, err: Error) {
	b := peek_exact(r, 2) or_return
	h.fin = b[0] & 0x80 != 0
	h.rsv = (b[0] >> 4) & 7
	h.opcode = b[0] & 0x0f
	h.masked = b[1] & 0x80 != 0
	l := u64(b[1] & 0x7f)
	consume(r, 2)
	switch l {
	case 126:
		e := peek_exact(r, 2) or_return
		l = u64(e[0]) << 8 | u64(e[1])
		consume(r, 2)
	case 127:
		e := peek_exact(r, 8) or_return
		l = 0
		for i in 0 ..< 8 do l = l << 8 | u64(e[i])
		consume(r, 8)
		if l >> 63 != 0 do return h, .Protocol
	}
	h.length = l
	if h.masked {
		k := peek_exact(r, 4) or_return
		copy(h.key[:], k)
		consume(r, 4)
	}
	return h, .None
}

// ws_recv returns the next complete data message into msg (cleared first).
// Control frames are handled internally. Returns .Closed once the close
// handshake finished (c.close_code / c.close_reason hold the peer's status);
// on protocol violations it sends the proper close code and returns .Protocol
// / .Too_Large.
ws_recv :: proc(c: ^Ws_Conn, msg: ^[dynamic]byte) -> (type: Ws_Message_Type, err: Error) {
	clear(msg)
	in_message := false
	compressed := false
	for {
		if c.recv_close do return type, .Closed
		h, herr := ws_read_frame_header(&c.r)
		if herr != .None do return type, herr
		op := Ws_Opcode(h.opcode)
		// RSV1 marks a compressed message (its first frame) once deflate is negotiated
		rsv1_ok := c.deflate && h.rsv == 4 && (op == .Text || op == .Binary)
		if (h.rsv != 0 && !rsv1_ok) || h.masked do return type, ws_fail(c, WS_PROTOCOL_ERROR, .Protocol)
		if rsv1_ok do compressed = true
		is_control := h.opcode >= 8
		if is_control {
			if !h.fin || h.length > 125 do return type, ws_fail(c, WS_PROTOCOL_ERROR, .Protocol)
			ctl: [125]byte
			p := ctl[:h.length]
			read_exact(&c.r, p) or_return
			#partial switch op {
			case .Ping:
				locks.lock(&c.wmu)
				if !c.sent_close do ws_write_frame_locked(c, true, .Pong, p)
				locks.unlock(&c.wmu)
			case .Pong:
				clear(&c.last_pong)
				append(&c.last_pong, ..p)
				c.pongs += 1
			case .Close:
				code := WS_NO_STATUS
				reason := ""
				if len(p) == 1 do return type, ws_fail(c, WS_PROTOCOL_ERROR, .Protocol)
				if len(p) >= 2 {
					code = int(p[0]) << 8 | int(p[1])
					reason = string(p[2:])
					if !valid_close_code(code) do return type, ws_fail(c, WS_PROTOCOL_ERROR, .Protocol)
					if !utf8.valid_string(reason) do return type, ws_fail(c, WS_INVALID_DATA, .Protocol)
				}
				c.recv_close = true
				c.close_code = code
				if len(reason) > 0 do c.close_reason = strings.clone(reason, c.allocator)
				locks.lock(&c.wmu)
				ws_close_locked(c, code if code != WS_NO_STATUS else WS_NO_STATUS, "")
				locks.unlock(&c.wmu)
				return type, .Closed
			case:
				return type, ws_fail(c, WS_PROTOCOL_ERROR, .Protocol)
			}
			continue
		}
		switch op {
		case .Continuation:
			if !in_message do return type, ws_fail(c, WS_PROTOCOL_ERROR, .Protocol)
		case .Text, .Binary:
			if in_message do return type, ws_fail(c, WS_PROTOCOL_ERROR, .Protocol)
			in_message = true
			type = .Text if op == .Text else .Binary
		case .Close, .Ping, .Pong:
		case:
			return type, ws_fail(c, WS_PROTOCOL_ERROR, .Protocol)
		}
		if u64(len(msg)) + h.length > u64(c.max_message) do return type, ws_fail(c, WS_TOO_BIG, .Too_Large)
		read_body_n(&c.r, msg, int(h.length)) or_return
		if h.fin && compressed {
			if !ws_inflate(c, msg) do return type, ws_fail(c, WS_INVALID_DATA, .Protocol)
		}
		if h.fin {
			if type == .Text && !utf8.valid_string(string(msg[:])) do return type, ws_fail(c, WS_INVALID_DATA, .Protocol)
			return type, .None
		}
	}
}

@(private)
valid_close_code :: proc(code: int) -> bool {
	switch code {
	case 1000 ..= 1003, 1007 ..= 1014:
		return true
	case 3000 ..= 4999:
		return true
	}
	return false
}

@(private)
ws_fail :: proc(c: ^Ws_Conn, code: int, err: Error) -> Error {
	locks.lock(&c.wmu)
	ws_close_locked(c, code, "")
	locks.unlock(&c.wmu)
	return err
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
