package wire

import "core:crypto"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:strings"

Ws_Opcode :: enum u8 {
	Continuation = 0x0,
	Text         = 0x1,
	Binary       = 0x2,
	Close        = 0x8,
	Ping         = 0x9,
	Pong         = 0xA,
}

Ws_Message :: struct {
	opcode:     Ws_Opcode, // Text, Binary or Close
	data:       [dynamic]byte,
	close_code: u16,
}

Ws :: struct {
	conn:     ^Conn,
	frag:     [dynamic]byte,
	frag_op:  Ws_Opcode,
	in_frag:  bool,
	max_size: int,
}

WS_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// Performs the HTTP upgrade. `headers` must include Host and everything else
// the impersonated client sends; Upgrade/Connection/Sec-WebSocket-* are taken
// from the list if present (so their order is preserved), and filled in if not.
ws_handshake :: proc(c: ^Conn, target: string, headers: []Header) -> (ws: ^Ws, resp: Response, err: Error) {
	key_raw: [16]byte
	crypto.rand_bytes(key_raw[:])
	key := base64.encode(key_raw[:], allocator = context.temp_allocator)

	hs := make([dynamic]Header, 0, len(headers) + 4, context.temp_allocator)
	has_key, has_ver, has_up, has_conn := false, false, false, false
	for h in headers {
		switch {
		case strings.equal_fold(h.name, "Sec-WebSocket-Key"):
			append(&hs, Header{h.name, key})
			has_key = true
			continue
		case strings.equal_fold(h.name, "Sec-WebSocket-Version"):
			has_ver = true
		case strings.equal_fold(h.name, "Upgrade"):
			has_up = true
		case strings.equal_fold(h.name, "Connection"):
			has_conn = true
		}
		append(&hs, h)
	}
	if !has_up do append(&hs, Header{"Upgrade", "websocket"})
	if !has_conn do append(&hs, Header{"Connection", "Upgrade"})
	if !has_key do append(&hs, Header{"Sec-WebSocket-Key", key})
	if !has_ver do append(&hs, Header{"Sec-WebSocket-Version", "13"})

	if err = write_request(c, "GET", target, hs[:], nil); err != .None do return
	if err = read_response_head(c, &resp); err != .None do return
	if resp.status != 101 {
		read_response_body(c, &resp, "GET")
		err = .Protocol
		return
	}
	accept, ok := header_get(resp.headers[:], "Sec-WebSocket-Accept")
	if !ok || accept != ws_accept_for(key, context.temp_allocator) {
		err = .Protocol
		return
	}
	ws = new(Ws)
	ws.conn = c
	ws.max_size = 128 * 1024 * 1024
	return
}

ws_accept_for :: proc(key: string, allocator := context.allocator) -> string {
	ctx: hash.Context
	hash.init(&ctx, .Insecure_SHA1)
	hash.update(&ctx, transmute([]byte)key)
	hash.update(&ctx, transmute([]byte)string(WS_GUID))
	digest: [20]byte
	hash.final(&ctx, digest[:])
	return base64.encode(digest[:], allocator = allocator)
}

ws_destroy :: proc(ws: ^Ws) {
	if ws == nil do return
	delete(ws.frag)
	free(ws)
}

// Client frames are always masked (RFC 6455 5.3).
ws_send :: proc(ws: ^Ws, op: Ws_Opcode, payload: []byte) -> Error {
	hdr: [14]byte
	n := 0
	hdr[0] = 0x80 | u8(op)
	l := len(payload)
	switch {
	case l < 126:
		hdr[1] = 0x80 | u8(l)
		n = 2
	case l <= 0xFFFF:
		hdr[1] = 0x80 | 126
		hdr[2] = u8(l >> 8)
		hdr[3] = u8(l)
		n = 4
	case:
		hdr[1] = 0x80 | 127
		for i in 0 ..< 8 do hdr[2 + i] = u8(u64(l) >> uint(56 - 8 * i))
		n = 10
	}
	mask: [4]byte
	crypto.rand_bytes(mask[:])
	copy(hdr[n:], mask[:])
	n += 4
	buf := make([]byte, n + l, context.temp_allocator)
	copy(buf, hdr[:n])
	for i in 0 ..< l do buf[n + i] = payload[i] ~ mask[i & 3]
	return write(ws.conn, buf)
}

ws_send_text :: proc(ws: ^Ws, s: string) -> Error {
	return ws_send(ws, .Text, transmute([]byte)s)
}

ws_send_close :: proc(ws: ^Ws, code: u16) -> Error {
	p := [2]byte{u8(code >> 8), u8(code)}
	return ws_send(ws, .Close, p[:])
}

// Reads frames until a full data message (or close) arrives. Pings are
// answered inline. The message's data is owned by the caller.
ws_recv :: proc(ws: ^Ws, msg: ^Ws_Message) -> Error {
	for {
		h: [2]byte
		if err := read_full(ws.conn, h[:]); err != .None do return err
		fin := h[0] & 0x80 != 0
		if h[0] & 0x70 != 0 do return .Protocol // no extensions negotiated
		op := Ws_Opcode(h[0] & 0x0F)
		masked := h[1] & 0x80 != 0
		l := u64(h[1] & 0x7F)
		if l == 126 {
			e: [2]byte
			if err := read_full(ws.conn, e[:]); err != .None do return err
			l = u64(e[0]) << 8 | u64(e[1])
		} else if l == 127 {
			e: [8]byte
			if err := read_full(ws.conn, e[:]); err != .None do return err
			l = 0
			for b in e do l = l << 8 | u64(b)
		}
		if l > u64(ws.max_size) do return .Too_Large
		mask: [4]byte
		if masked {
			if err := read_full(ws.conn, mask[:]); err != .None do return err
		}
		payload := make([]byte, int(l))
		defer delete(payload)
		if err := read_full(ws.conn, payload); err != .None do return err
		if masked do for i in 0 ..< len(payload) do payload[i] ~= mask[i & 3]

		#partial switch op {
		case .Ping:
			if err := ws_send(ws, .Pong, payload); err != .None do return err
		case .Pong:
		case .Close:
			msg.opcode = .Close
			msg.close_code = 1005
			if len(payload) >= 2 do msg.close_code = u16(payload[0]) << 8 | u16(payload[1])
			clear(&msg.data)
			if len(payload) > 2 do append(&msg.data, ..payload[2:])
			return .None
		case .Text, .Binary:
			if ws.in_frag do return .Protocol
			if fin {
				msg.opcode = op
				clear(&msg.data)
				append(&msg.data, ..payload)
				return .None
			}
			ws.in_frag = true
			ws.frag_op = op
			clear(&ws.frag)
			append(&ws.frag, ..payload)
		case .Continuation:
			if !ws.in_frag do return .Protocol
			append(&ws.frag, ..payload)
			if len(ws.frag) > ws.max_size do return .Too_Large
			if fin {
				ws.in_frag = false
				msg.opcode = ws.frag_op
				clear(&msg.data)
				append(&msg.data, ..ws.frag[:])
				return .None
			}
		case:
			return .Protocol
		}
	}
}
