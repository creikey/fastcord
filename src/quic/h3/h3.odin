// Package h3 is an HTTP/3 client (RFC 9114) over fc:quic, shaped like
// fc:http's h2 API (connect / open / wait / request / close, sharing
// http.Request and http.Response) so callers can pick h1/h2/h3 per Alt-Svc.
//
// Wire behaviour follows Chrome 148: one control stream (id 2) carrying
// SETTINGS {QPACK_MAX_TABLE_CAPACITY 65536, MAX_FIELD_SECTION_SIZE 262144,
// QPACK_BLOCKED_STREAMS 100, H3_DATAGRAM 1, GREASE} followed by a GREASE
// frame; no QPACK encoder/decoder streams until needed; a PRIORITY_UPDATE
// on the control stream before every request plus a trailing `priority`
// header; pseudo-headers in Chrome's :method :authority :scheme :path order.
package h3

import "base:runtime"
import "core:crypto"
import "core:fmt"
import "core:math/rand"
import "core:strconv"
import "core:strings"

import "fc:http"
import "fc:quic"

FRAME_DATA :: 0x00
FRAME_HEADERS :: 0x01
FRAME_SETTINGS :: 0x04
FRAME_GOAWAY :: 0x07
FRAME_PRIORITY_UPDATE :: 0xf0700

STREAM_CONTROL :: 0x00
STREAM_PUSH :: 0x01
STREAM_QPACK_ENCODER :: 0x02
STREAM_QPACK_DECODER :: 0x03

SETTING_QPACK_MAX_TABLE_CAPACITY :: 0x01
SETTING_MAX_FIELD_SECTION_SIZE :: 0x06
SETTING_QPACK_BLOCKED_STREAMS :: 0x07
SETTING_H3_DATAGRAM :: 0x33

H3_NO_ERROR :: 0x100
H3_GENERAL_PROTOCOL_ERROR :: 0x101
H3_CLOSED_CRITICAL_STREAM :: 0x104
H3_FRAME_UNEXPECTED :: 0x105
H3_FRAME_ERROR :: 0x106
H3_ID_ERROR :: 0x108
H3_SETTINGS_ERROR :: 0x109
H3_MISSING_SETTINGS :: 0x10a
H3_STREAM_CREATION_ERROR :: 0x103
QPACK_DECOMPRESSION_FAILED :: 0x200
QPACK_ENCODER_STREAM_ERROR :: 0x201

CHROME_MAX_FIELD_SECTION :: 262144
CHROME_BLOCKED_STREAMS :: 100

Config :: struct {
	quic:         quic.Config, // tls.alpn defaults to {"h3"}, server_name to host
	max_response: int, // body limit, default 256 MiB
}

Peer_Settings :: struct {
	received:           bool,
	qpack_capacity:     u64,
	max_field_section:  u64,
	blocked_streams:    u64,
	datagram:           bool,
}

@(private)
Uni_State :: struct {
	typ:    i64, // -1 until the type varint arrived
	buf:    [dynamic]byte,
	ignore: bool,
}

Conn :: struct {
	q:            ^quic.Conn,
	control:      ^quic.Stream,
	dec_stream:   ^quic.Stream,
	dec:          Decoder,
	uni:          map[u64]^Uni_State,
	settings:     Peer_Settings,
	goaway:       bool,
	max_response: int,
	allocator:    runtime.Allocator,
}

Stream :: struct {
	c:  ^Conn,
	qs: ^quic.Stream,
}

@(private)
to_http :: proc(e: quic.Error) -> http.Error {
	#partial switch e {
	case .None:
		return .None
	case .Closed:
		return .Closed
	case .Timeout:
		return .Timeout
	case .Stream_Reset:
		return .Stream_Reset
	case .Flow_Control:
		return .Flow_Control
	case .Protocol, .Tls, .Peer_Closed, .Version_Negotiation:
		return .Protocol
	}
	return .Io
}

// connect opens a QUIC connection to host:443 and starts HTTP/3.
connect :: proc(host: string, cfg := Config{}) -> (c: ^Conn, err: http.Error) {
	context.allocator = quic.conn_allocator()
	qcfg := cfg.quic
	if len(qcfg.tls.alpn) == 0 do qcfg.tls.alpn = {"h3"}
	if qcfg.tls.server_name == "" do qcfg.tls.server_name = host
	q, qerr := quic.connect(host, qcfg)
	if qerr != .None do return nil, to_http(qerr)
	c = new(Conn)
	c.q = q
	c.allocator = context.allocator
	c.max_response = cfg.max_response if cfg.max_response > 0 else 256 << 20
	decoder_init(&c.dec)
	c.uni = make(map[u64]^Uni_State)
	quic.set_uni_handler(q, on_uni, c)

	ctl, oerr := quic.open_uni(q)
	if oerr != .None {
		close(c)
		return nil, to_http(oerr)
	}
	c.control = ctl
	pre := make([dynamic]byte, 0, 64)
	defer delete(pre)
	control_preamble(&pre)
	if e := quic.write(ctl, pre[:]); e != .None {
		close(c)
		return nil, to_http(e)
	}
	// Chrome's SETTINGS leave in their own packet before any request.
	if e := quic.flush(ctl); e != .None {
		close(c)
		return nil, to_http(e)
	}
	return c, .None
}

// control_preamble writes the stream type, Chrome's SETTINGS and a GREASE frame.
control_preamble :: proc(b: ^[dynamic]byte) {
	quic.put_varint(b, STREAM_CONTROL)
	s := make([dynamic]byte, 0, 48, context.temp_allocator)
	setting :: proc(s: ^[dynamic]byte, id, v: u64) {
		quic.put_varint(s, id)
		quic.put_varint(s, v)
	}
	setting(&s, SETTING_QPACK_MAX_TABLE_CAPACITY, DECODER_MAX_CAPACITY)
	setting(&s, SETTING_MAX_FIELD_SECTION_SIZE, CHROME_MAX_FIELD_SECTION)
	setting(&s, SETTING_QPACK_BLOCKED_STREAMS, CHROME_BLOCKED_STREAMS)
	setting(&s, SETTING_H3_DATAGRAM, 1)
	// Reserved identifiers are 0x1f * N + 0x21 (RFC 9114 7.2.4.1).
	setting(&s, grease_id(), u64(rand.uint32()))
	quic.put_varint(b, FRAME_SETTINGS)
	quic.put_varint(b, u64(len(s)))
	append(b, ..s[:])
	// A reserved frame type with a few random bytes, as Chrome sends.
	payload: [3]byte
	crypto.rand_bytes(payload[:])
	n := int(rand.uint32() % 4)
	quic.put_varint(b, grease_id())
	quic.put_varint(b, u64(n))
	append(b, ..payload[:n])
}

@(private)
grease_id :: proc() -> u64 {return 0x1f * u64(rand.uint32()) + 0x21}

// urgency maps Chrome's request priority to an RFC 9218 urgency.
urgency :: proc(p: http.Priority) -> int {
	switch p {
	case .Highest:
		return 0
	case .Medium:
		return 1
	case .Low:
		return 2
	case .Lowest:
		return 3
	case .Idle:
		return 4
	case .Throttled:
		return 5
	}
	return 1
}

can_open :: proc(c: ^Conn) -> bool {
	return !c.goaway && quic.conn_error(c.q) == .None
}

// open sends a request; the response is read with wait.
open :: proc(c: ^Conn, req: http.Request) -> (st: ^Stream, err: http.Error) {
	context.allocator = c.allocator
	if req.method == "" || req.path == "" || req.authority == "" do return nil, .Bad_Request
	if c.goaway do return nil, .Goaway
	prio := fmt.tprintf("u=%d, i", urgency(req.priority))

	fields := make([dynamic]http.Header, 0, len(req.headers) + 5, context.temp_allocator)
	append(&fields, http.Header{":method", req.method})
	append(&fields, http.Header{":authority", req.authority})
	append(&fields, http.Header{":scheme", req.scheme if req.scheme != "" else "https"})
	append(&fields, http.Header{":path", req.path})
	has_priority := false
	for h in req.headers {
		if h.name == "priority" do has_priority = true
		append(&fields, h)
	}
	if !has_priority do append(&fields, http.Header{"priority", prio})
	block := make([dynamic]byte, 0, 512, context.temp_allocator)
	encode_section(&block, fields[:])

	quic.lock(c.q)
	qs := quic.open_bidi_locked(c.q)
	for qs == nil {
		if e := quic.wait_locked(c.q); e != .None {
			quic.unlock(c.q)
			return nil, to_http(e)
		}
		qs = quic.open_bidi_locked(c.q)
	}
	// PRIORITY_UPDATE (request stream) on the control stream first.
	pu := make([dynamic]byte, 0, 32, context.temp_allocator)
	pl := make([dynamic]byte, 0, 24, context.temp_allocator)
	quic.put_varint(&pl, quic.stream_id(qs))
	append(&pl, ..transmute([]byte)prio)
	quic.put_varint(&pu, FRAME_PRIORITY_UPDATE)
	quic.put_varint(&pu, u64(len(pl)))
	append(&pu, ..pl[:])
	e := quic.write_locked(c.control, pu[:])
	frame := make([dynamic]byte, 0, len(block) + 8 + len(req.body), context.temp_allocator)
	quic.put_varint(&frame, FRAME_HEADERS)
	quic.put_varint(&frame, u64(len(block)))
	append(&frame, ..block[:])
	if len(req.body) > 0 {
		quic.put_varint(&frame, FRAME_DATA)
		quic.put_varint(&frame, u64(len(req.body)))
		append(&frame, ..req.body)
	}
	if e == .None do e = quic.write_locked(qs, frame[:], true)
	quic.unlock(c.q)
	quic.wake(c.q)
	if e != .None {
		quic.release(qs)
		return nil, to_http(e)
	}
	st = new(Stream)
	st.c = c
	st.qs = qs
	return st, .None
}

// wait reads the response (headers, body, trailers) and frees st.
wait :: proc(c: ^Conn, st: ^Stream, allocator := context.allocator) -> (resp: http.Response, err: http.Error) {
	resp.allocator = allocator
	resp.version = .Http3
	defer {
		quic.release(st.qs)
		free(st, c.allocator)
	}
	buf := make([dynamic]byte, 0, 16384, context.temp_allocator)
	chunk: [16384]byte
	got_headers := false
	for {
		// Parse complete frames.
		for {
			r := quic.reader(buf[:])
			typ := quic.r_varint(&r)
			n := quic.r_varint(&r)
			if !r.ok || n > u64(len(r.b)) do break
			hdr := len(buf) - len(r.b)
			payload := r.b[:n]
			switch typ {
			case FRAME_HEADERS:
				hs := make([dynamic]http.Header, 0, 16, context.temp_allocator)
				decode_headers(c, st, payload, &hs) or_return
				status := -1
				for h in hs do if h.name == ":status" {
					v, ok := strconv.parse_int(h.value)
					status = v if ok else -1
				}
				if !got_headers {
					if status < 100 || status > 999 do return resp, .Protocol
					if status < 200 do break // interim response
					got_headers = true
					resp.status = status
					for h in hs do if h.name[0] != ':' do append(&resp.headers, http.Header{strings.clone(h.name, allocator), strings.clone(h.value, allocator)})
				} else {
					for h in hs do append(&resp.trailers, http.Header{strings.clone(h.name, allocator), strings.clone(h.value, allocator)})
				}
			case FRAME_DATA:
				if !got_headers do return resp, .Protocol
				if len(resp.body) + len(payload) > c.max_response do return resp, .Too_Large
				if resp.body == nil do resp.body = make([dynamic]byte, 0, len(payload), allocator)
				append(&resp.body, ..payload)
			case FRAME_SETTINGS, FRAME_GOAWAY, 0x03, 0x05, 0x0d, FRAME_PRIORITY_UPDATE:
				return resp, .Protocol // not allowed on request streams
			}
			remove_range(&buf, 0, hdr + int(n))
		}
		n, e := quic.read(st.qs, chunk[:])
		if e == .Closed {
			if len(buf) > 0 || !got_headers do return resp, .Protocol
			return resp, .None
		}
		if e != .None {
			if e == .Stream_Reset do resp.h2_error = u32(st.qs.reset_code)
			return resp, to_http(e)
		}
		append(&buf, ..chunk[:n])
		if len(buf) > c.max_response + 65536 do return resp, .Too_Large
	}
}

// decode_headers runs QPACK, waiting for encoder-stream inserts if blocked.
@(private)
decode_headers :: proc(c: ^Conn, st: ^Stream, block: []byte, out: ^[dynamic]http.Header) -> http.Error {
	quic.lock(c.q)
	defer quic.unlock(c.q)
	for {
		res, ric := decode_section(&c.dec, block, out, context.temp_allocator)
		switch res {
		case .Ok:
			if ric > 0 do section_ack_locked(c, quic.stream_id(st.qs))
			return .None
		case .Error:
			quic.abort_locked(c.q, QPACK_DECOMPRESSION_FAILED)
			return .Protocol
		case .Blocked:
			if e := quic.wait_locked(c.q); e != .None do return to_http(e)
		}
	}
}

// section_ack_locked sends a Section Acknowledgment, opening our QPACK
// decoder stream on first use.
@(private)
section_ack_locked :: proc(c: ^Conn, id: u64) {
	context.allocator = c.allocator
	b := make([dynamic]byte, 0, 16, context.temp_allocator)
	if c.dec_stream == nil {
		// Opening a uni stream needs credit the server granted; skip if none.
		s, ok := open_uni_locked(c)
		if !ok do return
		c.dec_stream = s
		quic.put_varint(&b, STREAM_QPACK_DECODER)
	}
	put_int(&b, 0x80, 7, id)
	quic.write_locked(c.dec_stream, b[:])
}

@(private)
open_uni_locked :: proc(c: ^Conn) -> (^quic.Stream, bool) {
	s := quic.open_uni_locked(c.q)
	return s, s != nil
}

// request is open + wait.
request :: proc(c: ^Conn, req: http.Request, allocator := context.allocator) -> (http.Response, http.Error) {
	st, err := open(c, req)
	if err != .None do return {}, err
	return wait(c, st, allocator)
}

// close sends CONNECTION_CLOSE (H3_NO_ERROR) and frees the connection.
close :: proc(c: ^Conn) {
	if c == nil do return
	context.allocator = c.allocator
	quic.close(c.q)
	for _, u in c.uni {
		delete(u.buf)
		free(u)
	}
	delete(c.uni)
	decoder_destroy(&c.dec)
	free(c)
}

// on_uni handles server-initiated unidirectional streams on the QUIC I/O
// thread (connection lock held).
@(private)
on_uni :: proc(user: rawptr, qs: ^quic.Stream, data: []byte, fin: bool) {
	c := cast(^Conn)user
	context.allocator = c.allocator
	id := quic.stream_id(qs)
	u, found := c.uni[id]
	if !found {
		u = new(Uni_State)
		u.typ = -1
		c.uni[id] = u
	}
	if u.ignore do return
	append(&u.buf, ..data)
	if u.typ < 0 {
		r := quic.reader(u.buf[:])
		t := quic.r_varint(&r)
		if !r.ok do return
		u.typ = i64(t)
		remove_range(&u.buf, 0, len(u.buf) - len(r.b))
	}
	switch u.typ {
	case STREAM_CONTROL:
		if fin {
			quic.abort_locked(c.q, H3_CLOSED_CRITICAL_STREAM)
			return
		}
		on_control(c, u)
	case STREAM_QPACK_ENCODER:
		if !feed_encoder_stream(&c.dec, u.buf[:]) {
			quic.abort_locked(c.q, QPACK_ENCODER_STREAM_ERROR)
			return
		}
		clear(&u.buf)
		quic.broadcast_locked(c.q) // unblock waiting decoders
	case STREAM_QPACK_DECODER:
		clear(&u.buf) // acknowledgments for an encoder that never inserts
	case STREAM_PUSH:
		quic.abort_locked(c.q, H3_ID_ERROR) // we never sent MAX_PUSH_ID
	case:
		// Unknown / GREASE stream types: ask the server to stop (Chrome does).
		u.ignore = true
		clear(&u.buf)
		quic.stop_sending_locked(qs, H3_STREAM_CREATION_ERROR)
	}
}

@(private)
on_control :: proc(c: ^Conn, u: ^Uni_State) {
	for {
		r := quic.reader(u.buf[:])
		typ := quic.r_varint(&r)
		n := quic.r_varint(&r)
		if !r.ok || n > u64(len(r.b)) do return
		payload := quic.reader(r.b[:n])
		used := len(u.buf) - len(r.b) + int(n)
		if !c.settings.received && typ != FRAME_SETTINGS {
			quic.abort_locked(c.q, H3_MISSING_SETTINGS)
			return
		}
		switch typ {
		case FRAME_SETTINGS:
			if c.settings.received {
				quic.abort_locked(c.q, H3_FRAME_UNEXPECTED)
				return
			}
			c.settings.received = true
			for len(payload.b) > 0 {
				id := quic.r_varint(&payload)
				v := quic.r_varint(&payload)
				if !payload.ok {
					quic.abort_locked(c.q, H3_FRAME_ERROR)
					return
				}
				switch id {
				case SETTING_QPACK_MAX_TABLE_CAPACITY:
					c.settings.qpack_capacity = v
				case SETTING_MAX_FIELD_SECTION_SIZE:
					c.settings.max_field_section = v
				case SETTING_QPACK_BLOCKED_STREAMS:
					c.settings.blocked_streams = v
				case SETTING_H3_DATAGRAM:
					c.settings.datagram = v == 1
				case 0x02, 0x03, 0x04, 0x05:
					// HTTP/2 settings are forbidden in HTTP/3.
					quic.abort_locked(c.q, H3_SETTINGS_ERROR)
					return
				}
			}
		case FRAME_GOAWAY:
			c.goaway = true
			quic.broadcast_locked(c.q)
		case FRAME_DATA, FRAME_HEADERS:
			quic.abort_locked(c.q, H3_FRAME_UNEXPECTED)
			return
		}
		remove_range(&u.buf, 0, used)
	}
}
