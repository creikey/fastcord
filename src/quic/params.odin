package quic

import "core:crypto"
import "core:math/rand"

// Transport parameters (RFC 9000 18).

TP_ORIGINAL_DCID :: 0x00
TP_MAX_IDLE_TIMEOUT :: 0x01
TP_STATELESS_RESET_TOKEN :: 0x02
TP_MAX_UDP_PAYLOAD_SIZE :: 0x03
TP_INITIAL_MAX_DATA :: 0x04
TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL :: 0x05
TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE :: 0x06
TP_INITIAL_MAX_STREAM_DATA_UNI :: 0x07
TP_INITIAL_MAX_STREAMS_BIDI :: 0x08
TP_INITIAL_MAX_STREAMS_UNI :: 0x09
TP_ACK_DELAY_EXPONENT :: 0x0a
TP_MAX_ACK_DELAY :: 0x0b
TP_DISABLE_ACTIVE_MIGRATION :: 0x0c
TP_PREFERRED_ADDRESS :: 0x0d
TP_ACTIVE_CONNECTION_ID_LIMIT :: 0x0e
TP_INITIAL_SCID :: 0x0f
TP_RETRY_SCID :: 0x10
TP_VERSION_INFORMATION :: 0x11
TP_MAX_DATAGRAM_FRAME_SIZE :: 0x20
TP_GOOGLE_INITIAL_RTT :: 0x3127 // QUICHE kInitialRoundTripTime, microseconds

// Chrome 148's values (net/quic defaults as seen on the wire).
CHROME_MAX_UDP_PAYLOAD :: 1472
CHROME_MAX_DATA :: 15728640
CHROME_MAX_STREAM_DATA :: 6291456
CHROME_MAX_STREAMS_BIDI :: 100
CHROME_MAX_STREAMS_UNI :: 103
CHROME_MAX_IDLE_MS :: 30000
CHROME_MAX_DATAGRAM_FRAME :: 65536

Peer_Params :: struct {
	original_dcid:     []byte,
	initial_scid:      []byte,
	retry_scid:        []byte,
	has_retry_scid:    bool,
	max_idle_ms:       u64,
	max_udp_payload:   u64,
	max_data:          u64,
	msd_bidi_local:    u64,
	msd_bidi_remote:   u64,
	msd_uni:           u64,
	max_streams_bidi:  u64,
	max_streams_uni:   u64,
	ack_delay_exp:     u64,
	max_ack_delay_ms:  u64,
	active_cid_limit:  u64,
	disable_migration: bool,
	max_datagram:      u64,
}

@(private)
put_param_int :: proc(b: ^[dynamic]byte, id, v: u64) {
	put_varint(b, id)
	put_varint(b, u64(varint_len(v)))
	put_varint(b, v)
}

@(private)
put_param_bytes :: proc(b: ^[dynamic]byte, id: u64, v: []byte) {
	put_varint(b, id)
	put_varint(b, u64(len(v)))
	put_bytes(b, v)
}

// grease_quic_version is a reserved 0x?a?a?a?a version (RFC 9000 15).
@(private)
grease_quic_version :: proc() -> u32 {
	r: [4]byte
	crypto.rand_bytes(r[:])
	v: u32
	for x in r do v = v << 8 | u32((x & 0xf0) | 0x0a)
	return v
}

// chrome_transport_params encodes Chrome's client transport parameters in a
// fresh random order, with a GREASE parameter and version_information
// carrying a GREASE version. initial_rtt_us > 0 adds QUICHE's initial RTT
// parameter, which Chrome sends when it has a cached RTT for the server.
chrome_transport_params :: proc(initial_rtt_us: u64, allocator := context.allocator) -> []byte {
	Param :: struct {
		id:    u64,
		value: u64,
		raw:   []byte,
		int:   bool,
	}
	vi: [12]byte
	vi[3] = 1 // chosen version
	vi[7] = 1 // available: v1, then GREASE
	g := grease_quic_version()
	vi[8], vi[9], vi[10], vi[11] = byte(g >> 24), byte(g >> 16), byte(g >> 8), byte(g)
	grease_val: [16]byte
	crypto.rand_bytes(grease_val[:])
	grease_len := int(grease_val[0] % 16)
	crypto.rand_bytes(grease_val[:])
	grease_id := 31 * (rand.uint64() % ((MAX_VARINT - 27) / 31)) + 27

	params: [dynamic]Param
	defer delete(params)
	append(&params, Param{id = TP_MAX_UDP_PAYLOAD_SIZE, value = CHROME_MAX_UDP_PAYLOAD, int = true})
	append(&params, Param{id = TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE, value = CHROME_MAX_STREAM_DATA, int = true})
	append(&params, Param{id = TP_INITIAL_MAX_STREAM_DATA_UNI, value = CHROME_MAX_STREAM_DATA, int = true})
	append(&params, Param{id = TP_INITIAL_MAX_STREAMS_BIDI, value = CHROME_MAX_STREAMS_BIDI, int = true})
	append(&params, Param{id = TP_MAX_DATAGRAM_FRAME_SIZE, value = CHROME_MAX_DATAGRAM_FRAME, int = true})
	append(&params, Param{id = TP_INITIAL_SCID, raw = nil}) // zero-length SCID
	append(&params, Param{id = TP_MAX_IDLE_TIMEOUT, value = CHROME_MAX_IDLE_MS, int = true})
	append(&params, Param{id = TP_INITIAL_MAX_DATA, value = CHROME_MAX_DATA, int = true})
	append(&params, Param{id = TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL, value = CHROME_MAX_STREAM_DATA, int = true})
	append(&params, Param{id = TP_VERSION_INFORMATION, raw = vi[:]})
	append(&params, Param{id = grease_id, raw = grease_val[:grease_len]})
	append(&params, Param{id = TP_INITIAL_MAX_STREAMS_UNI, value = CHROME_MAX_STREAMS_UNI, int = true})
	if initial_rtt_us > 0 do append(&params, Param{id = TP_GOOGLE_INITIAL_RTT, value = initial_rtt_us, int = true})

	// QUICHE writes parameters in a random order.
	for i := len(params) - 1; i > 0; i -= 1 {
		j := int(rand.uint64() % u64(i + 1))
		params[i], params[j] = params[j], params[i]
	}
	out := make([dynamic]byte, 0, 128, allocator)
	for p in params {
		if p.int {
			put_param_int(&out, p.id, p.value)
		} else {
			put_param_bytes(&out, p.id, p.raw)
		}
	}
	return out[:]
}

// parse_peer_params decodes the server's transport parameters. Slices view b.
parse_peer_params :: proc(b: []byte) -> (p: Peer_Params, ok: bool) {
	p.max_udp_payload = 65527
	p.ack_delay_exp = 3
	p.max_ack_delay_ms = 25
	p.active_cid_limit = 2
	r := reader(b)
	seen: [32]bool
	for len(r.b) > 0 {
		id := r_varint(&r)
		v := r_vec(&r)
		if !r.ok do return p, false
		if id < 32 {
			if seen[id] do return p, false
			seen[id] = true
		}
		vr := reader(v)
		int_val :: proc(vr: ^Reader) -> u64 {
			x := r_varint(vr)
			if !r_done(vr) do vr.ok = false
			return x
		}
		switch id {
		case TP_ORIGINAL_DCID:
			p.original_dcid = v
		case TP_INITIAL_SCID:
			p.initial_scid = v
		case TP_RETRY_SCID:
			p.retry_scid = v
			p.has_retry_scid = true
		case TP_MAX_IDLE_TIMEOUT:
			p.max_idle_ms = int_val(&vr)
		case TP_MAX_UDP_PAYLOAD_SIZE:
			p.max_udp_payload = int_val(&vr)
			if p.max_udp_payload < 1200 do return p, false
		case TP_INITIAL_MAX_DATA:
			p.max_data = int_val(&vr)
		case TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL:
			p.msd_bidi_local = int_val(&vr)
		case TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE:
			p.msd_bidi_remote = int_val(&vr)
		case TP_INITIAL_MAX_STREAM_DATA_UNI:
			p.msd_uni = int_val(&vr)
		case TP_INITIAL_MAX_STREAMS_BIDI:
			p.max_streams_bidi = int_val(&vr)
		case TP_INITIAL_MAX_STREAMS_UNI:
			p.max_streams_uni = int_val(&vr)
		case TP_ACK_DELAY_EXPONENT:
			p.ack_delay_exp = int_val(&vr)
			if p.ack_delay_exp > 20 do return p, false
		case TP_MAX_ACK_DELAY:
			p.max_ack_delay_ms = int_val(&vr)
			if p.max_ack_delay_ms >= 1 << 14 do return p, false
		case TP_ACTIVE_CONNECTION_ID_LIMIT:
			p.active_cid_limit = int_val(&vr)
		case TP_DISABLE_ACTIVE_MIGRATION:
			p.disable_migration = true
		case TP_MAX_DATAGRAM_FRAME_SIZE:
			p.max_datagram = int_val(&vr)
		}
		if !vr.ok do return p, false
	}
	return p, true
}
