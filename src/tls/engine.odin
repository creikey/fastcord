package tls

import "core:crypto"
import "core:crypto/ecdh"
import "core:crypto/hash"
import "core:crypto/x509"
import "core:mem"
import "core:strings"

// The handshake engine is transport-agnostic: TLS-over-TCP (record layer)
// and QUIC (CRYPTO frames, RFC 9001) both drive run_handshake through a
// Handshake_Io.

// Level is the protection level a handshake flight or secret belongs to
// (QUIC encryption levels; the record layer only distinguishes them by keys).
Level :: enum u8 {
	Initial,
	Early, // 0-RTT
	Handshake,
	Application,
}

Handshake_Io :: struct {
	data:         rawptr,
	// next_message returns one complete handshake message (with its 4-byte
	// header) at the current read level; the caller frees it.
	next_message: proc(data: rawptr) -> ([]byte, Error),
	// send transmits a flight. first marks ClientHello1 (record version
	// 0x0301); ccs asks the record layer to prepend the compat CCS.
	send:         proc(data: rawptr, level: Level, flight: []byte, first: bool, ccs: bool) -> Error,
	// set_secret installs a traffic secret for reading or writing.
	set_secret:   proc(data: rawptr, level: Level, is_write: bool, suite: Suite, secret: []byte) -> Error,
}

// Handshake_State is the input and result of run_handshake.
Handshake_State :: struct {
	cfg:            Config,
	quic:           bool,
	quic_params:    []byte, // our transport parameters (QUIC)
	// Results.
	suite:          Suite,
	group:          u16,
	alpn:           string, // allocated
	alps:           bool,
	resumed:        bool,
	early_offered:  bool,
	early_accepted: bool,
	server_params:  []byte, // allocated; QUIC transport parameters from EncryptedExtensions
	res_master:     [MAX_HASH]byte,
	allocator:      mem.Allocator,
}

handshake_state_destroy :: proc(hs: ^Handshake_State) {
	delete(hs.alpn, hs.allocator)
	delete(hs.server_params, hs.allocator)
	crypto.zero_explicit(&hs.res_master, size_of(hs.res_master))
	hs.alpn = ""
	hs.server_params = nil
}

// key_log, when set, receives every traffic secret in NSS key log form
// (label, client_random, secret) so captures can be decrypted (Wireshark's
// SSLKEYLOGFILE). Debug only; leave nil in production.
key_log: proc(label: string, client_random: []byte, secret: []byte)

@(private)
log_secret :: proc(h: ^Hello, label: string, secret: []byte) {
	if key_log != nil do key_log(label, h.random[:], secret)
}

// resolve_cache returns the ticket cache a config uses, or nil if resumption is off.
resolve_cache :: proc(cfg: Config) -> ^Ticket_Cache {
	if cfg.disable_resumption do return nil
	return cfg.ticket_cache if cfg.ticket_cache != nil else &default_ticket_cache
}

// binder_mac computes a PSK binder over transcript-so-far + truncated hello.
@(private)
binder_mac :: proc(t: ^Transcript, psk_suite: Suite, psk: []byte, truncated: []byte, out: []byte) {
	hl := psk_suite.hash_len
	early, bk, th: [MAX_HASH]byte
	defer crypto.zero_explicit(&early, size_of(early))
	defer crypto.zero_explicit(&bk, size_of(bk))
	next_stage(psk_suite, nil, psk, early[:])
	empty: [MAX_HASH]byte
	hash.hash_bytes_to_buffer(psk_suite.hash, nil, empty[:hl])
	derive_secret(psk_suite, early[:hl], "res binder", empty[:hl], bk[:])
	ctx: hash.Context
	hash.clone(&ctx, &t.h256 if psk_suite.hash == .SHA256 else &t.h384)
	hash.update(&ctx, truncated)
	hash.final(&ctx, th[:hl])
	finished_mac(psk_suite, bk[:hl], th[:hl], out)
}

@(private)
expect_msg :: proc(io: Handshake_Io, typ: u8) -> (msg: []byte, err: Error) {
	msg = io.next_message(io.data) or_return
	if len(msg) < 4 || msg[0] != typ {
		delete(msg)
		return nil, .Unexpected_Message
	}
	return msg, .None
}

// run_handshake performs the client side of a TLS 1.3 handshake.
run_handshake :: proc(hs: ^Handshake_State, io: Handshake_Io) -> (err: Error) {
	cfg := hs.cfg
	if hs.allocator.procedure == nil do hs.allocator = context.allocator
	for p in cfg.alpn do if len(p) == 0 || len(p) > 255 do return .Internal

	h: Hello
	h.quic = hs.quic
	h.quic_params = hs.quic_params
	if !hello_init(&h, cfg.server_name, cfg.alpn) do return .Internal
	defer hello_destroy(&h)
	t: Transcript
	transcript_init(&t)
	defer transcript_destroy(&t)

	// Resumption: take the newest ticket for this host (single use, as Chrome).
	cache := resolve_cache(cfg)
	ticket: Ticket
	have_ticket := false
	psk_suite: Suite
	if cache != nil {
		ticket, have_ticket = ticket_cache_take(cache, cfg.server_name, hs.quic)
		if have_ticket {
			ok: bool
			psk_suite, ok = find_suite(ticket.suite)
			have_ticket = ok
		}
	}
	defer if have_ticket do ticket_free(cache, &ticket)
	if have_ticket {
		h.psk = &ticket
		h.psk_age = obfuscated_age(&ticket)
		h.early_data = hs.quic && ticket.max_early > 0
		hs.early_offered = h.early_data
	}

	ch := make([dynamic]byte, 0, 2048)
	defer delete(ch)
	build_and_bind :: proc(h: ^Hello, t: ^Transcript, psk_suite: Suite, ch: ^[dynamic]byte) {
		clear(ch)
		bl := build_client_hello(h, ch)
		if h.psk != nil {
			hl := psk_suite.hash_len
			binder_mac(t, psk_suite, h.psk.psk[:hl], ch[:len(ch) - bl], ch[len(ch) - hl:])
		}
	}
	build_and_bind(&h, &t, psk_suite, &ch)
	transcript_update(&t, ch[:])
	io.send(io.data, .Initial, ch[:], true, false) or_return

	// 0-RTT secret (QUIC may use it; TCP never offers early data).
	if h.early_data {
		early, ce, th0: [MAX_HASH]byte
		defer crypto.zero_explicit(&early, size_of(early))
		defer crypto.zero_explicit(&ce, size_of(ce))
		hl := psk_suite.hash_len
		next_stage(psk_suite, nil, ticket.psk[:hl], early[:])
		ctx: hash.Context
		hash.clone(&ctx, &t.h256 if psk_suite.hash == .SHA256 else &t.h384)
		hash.final(&ctx, th0[:hl])
		derive_secret(psk_suite, early[:hl], "c e traffic", th0[:hl], ce[:])
		log_secret(&h, "CLIENT_EARLY_TRAFFIC_SECRET", ce[:hl])
		io.set_secret(io.data, .Early, true, psk_suite, ce[:hl]) or_return
	}

	// ServerHello, possibly preceded by one HelloRetryRequest.
	sent_ccs := false
	hrr_suite: u16
	sh: Server_Hello
	sh_msg: []byte
	defer delete(sh_msg)
	for {
		sh_msg = expect_msg(io, HS_SERVER_HELLO) or_return
		sh = parse_server_hello(sh_msg[4:]) or_return
		sid := h.session_id[:] if !h.quic else nil
		if len(sh.session_id) != len(sid) || crypto.compare_constant_time(sh.session_id, sid) != 1 do return .Illegal_Parameter
		suite, ok := find_suite(sh.suite)
		if !ok do return .Illegal_Parameter
		if h.retried && sh.suite != hrr_suite do return .Illegal_Parameter
		transcript_choose(&t, suite.hash)
		hs.suite = suite
		if !sh.is_hrr do break

		// HelloRetryRequest: at most one, and it must change something.
		if h.retried do return .Unexpected_Message
		if !sh.has_share && sh.cookie == nil do return .Illegal_Parameter
		if sh.has_share {
			if sh.group != GROUP_SECP256R1 && sh.group != GROUP_SECP384R1 do return .Illegal_Parameter
			curve := ecdh.Curve.SECP256R1 if sh.group == GROUP_SECP256R1 else ecdh.Curve.SECP384R1
			if !ecdh.private_key_generate(&h.hrr_priv, curve) do return .Internal
			h.hrr_group = sh.group
		}
		if sh.cookie != nil do h.cookie = clone_bytes(sh.cookie)
		h.retried = true
		hrr_suite = sh.suite
		// A PSK whose hash differs from the HRR suite cannot be offered again.
		if h.psk != nil && psk_suite.hash != suite.hash {
			h.psk = nil
			h.early_data = false
		}
		// No early data after HRR (RFC 8446 4.2.10).
		h.early_data = false
		transcript_hrr(&t)
		transcript_update(&t, sh_msg)
		delete(sh_msg)
		sh_msg = nil

		build_and_bind(&h, &t, psk_suite, &ch)
		transcript_update(&t, ch[:])
		io.send(io.data, .Initial, ch[:], false, true) or_return
		sent_ccs = true
	}
	if !sh.has_share do return .Missing_Extension
	if h.hrr_group != 0 && sh.group != h.hrr_group do return .Illegal_Parameter
	if sh.has_psk {
		if h.psk == nil do return .Unsupported_Extension
		if sh.psk_identity != 0 || psk_suite.hash != hs.suite.hash do return .Illegal_Parameter
		hs.resumed = true
	}
	transcript_update(&t, sh_msg)
	hs.group = sh.group
	suite := hs.suite
	hl := suite.hash_len

	// Handshake secrets.
	shared: [64]byte
	defer crypto.zero_explicit(&shared, size_of(shared))
	ss_len := key_exchange(&h, sh.group, sh.share, shared[:]) or_return
	early, hs_secret, master, c_hs, s_hs: [MAX_HASH]byte
	defer {
		crypto.zero_explicit(&early, size_of(early))
		crypto.zero_explicit(&hs_secret, size_of(hs_secret))
		crypto.zero_explicit(&master, size_of(master))
		crypto.zero_explicit(&c_hs, size_of(c_hs))
		crypto.zero_explicit(&s_hs, size_of(s_hs))
	}
	th: [MAX_HASH]byte
	next_stage(suite, nil, ticket.psk[:hl] if hs.resumed else nil, early[:])
	next_stage(suite, early[:hl], shared[:ss_len], hs_secret[:])
	transcript_sum(&t, th[:])
	derive_secret(suite, hs_secret[:hl], "c hs traffic", th[:hl], c_hs[:])
	derive_secret(suite, hs_secret[:hl], "s hs traffic", th[:hl], s_hs[:])
	log_secret(&h, "CLIENT_HANDSHAKE_TRAFFIC_SECRET", c_hs[:hl])
	log_secret(&h, "SERVER_HANDSHAKE_TRAFFIC_SECRET", s_hs[:hl])
	io.set_secret(io.data, .Handshake, false, suite, s_hs[:hl]) or_return
	io.set_secret(io.data, .Handshake, true, suite, c_hs[:hl]) or_return

	// EncryptedExtensions.
	{
		ee := expect_msg(io, HS_ENCRYPTED_EXTENSIONS) or_return
		defer delete(ee)
		parse_encrypted_extensions(hs, &h, ee[4:]) or_return
		transcript_update(&t, ee)
	}

	cert_requested := false
	cr_context: []byte
	defer delete(cr_context)
	leaf: x509.Certificate
	defer x509.destroy(&leaf)
	chain: [][]byte
	defer delete(chain)
	cert_msg: []byte
	defer delete(cert_msg)
	decompressed: []byte
	defer delete(decompressed)
	if !hs.resumed {
		// Optional CertificateRequest, then Certificate / CompressedCertificate.
		cert_msg = io.next_message(io.data) or_return
		if cert_msg[0] == HS_CERTIFICATE_REQUEST {
			r := reader(cert_msg[4:])
			ctx := r_vec8(&r)
			r_vec16(&r)
			if !r_done(&r) do return .Decode
			cert_requested = true
			cr_context = clone_bytes(ctx)
			transcript_update(&t, cert_msg)
			delete(cert_msg)
			cert_msg = nil
			cert_msg = io.next_message(io.data) or_return
		}
		cert_body: []byte
		switch cert_msg[0] {
		case HS_CERTIFICATE:
			cert_body = cert_msg[4:]
		case HS_COMPRESSED_CERTIFICATE:
			decompressed = decompress_certificate(cert_msg[4:]) or_return
			cert_body = decompressed
		case:
			return .Unexpected_Message
		}
		chain = parse_certificate(cert_body) or_return
		transcript_update(&t, cert_msg)

		perr: x509.Error
		leaf, perr = x509.parse(chain[0])
		if perr != .None do return .Bad_Certificate

		// CertificateVerify over the transcript through Certificate.
		cv := expect_msg(io, HS_CERTIFICATE_VERIFY) or_return
		defer delete(cv)
		r := reader(cv[4:])
		alg := r_u16(&r)
		sig := r_vec16(&r)
		if !r_done(&r) do return .Decode
		transcript_sum(&t, th[:])
		verify_certificate_verify(&leaf, alg, sig, th[:hl]) or_return
		transcript_update(&t, cv)
	}

	// Server Finished.
	{
		fin := expect_msg(io, HS_FINISHED) or_return
		defer delete(fin)
		want: [MAX_HASH]byte
		transcript_sum(&t, th[:])
		finished_mac(suite, s_hs[:hl], th[:hl], want[:])
		if len(fin) != 4 + hl || crypto.compare_constant_time(fin[4:], want[:hl]) != 1 do return .Bad_Finished
		transcript_update(&t, fin)
	}

	// Chain + hostname against the OS trust store, after the peer proved key
	// possession. A resumed session inherits the original verification.
	if !hs.resumed && !cfg.insecure_skip_verify {
		if x509.verify_hostname(&leaf, cfg.server_name) != .None do return .Untrusted_Certificate
		verify_chain_os(chain, cfg.server_name) or_return
	}

	// Application secrets from the transcript through server Finished.
	c_ap, s_ap: [MAX_HASH]byte
	defer crypto.zero_explicit(&c_ap, size_of(c_ap))
	defer crypto.zero_explicit(&s_ap, size_of(s_ap))
	next_stage(suite, hs_secret[:hl], nil, master[:])
	transcript_sum(&t, th[:])
	derive_secret(suite, master[:hl], "c ap traffic", th[:hl], c_ap[:])
	derive_secret(suite, master[:hl], "s ap traffic", th[:hl], s_ap[:])

	// Client second flight: [EncryptedExtensions w/ ALPS], [Certificate], Finished.
	flight := make([dynamic]byte, 0, 256)
	defer delete(flight)
	if hs.alps {
		// Chrome's application settings are empty.
		start := len(flight)
		put_u8(&flight, HS_ENCRYPTED_EXTENSIONS)
		m := begin_vec(&flight, 3)
		e := begin_vec(&flight, 2)
		put_u16(&flight, EXT_APPLICATION_SETTINGS)
		put_u16(&flight, 0)
		end_vec(&flight, e, 2)
		end_vec(&flight, m, 3)
		transcript_update(&t, flight[start:])
	}
	if cert_requested {
		// No client certificate: empty list, echoing the request context.
		start := len(flight)
		put_u8(&flight, HS_CERTIFICATE)
		m := begin_vec(&flight, 3)
		put_u8(&flight, u8(len(cr_context)))
		put_bytes(&flight, cr_context)
		put_u24(&flight, 0)
		end_vec(&flight, m, 3)
		transcript_update(&t, flight[start:])
	}
	fin_start := len(flight)
	mac: [MAX_HASH]byte
	transcript_sum(&t, th[:])
	finished_mac(suite, c_hs[:hl], th[:hl], mac[:])
	put_u8(&flight, HS_FINISHED)
	put_u24(&flight, hl)
	put_bytes(&flight, mac[:hl])
	transcript_update(&t, flight[fin_start:])
	io.send(io.data, .Handshake, flight[:], false, !sent_ccs) or_return

	transcript_sum(&t, th[:])
	derive_secret(suite, master[:hl], "res master", th[:hl], hs.res_master[:])
	log_secret(&h, "CLIENT_TRAFFIC_SECRET_0", c_ap[:hl])
	log_secret(&h, "SERVER_TRAFFIC_SECRET_0", s_ap[:hl])
	io.set_secret(io.data, .Application, false, suite, s_ap[:hl]) or_return
	io.set_secret(io.data, .Application, true, suite, c_ap[:hl]) or_return
	return .None
}

@(private)
clone_bytes :: proc(b: []byte) -> []byte {
	out := make([]byte, len(b))
	copy(out, b)
	return out
}

// parse_encrypted_extensions applies ALPN / ALPS / early_data / QUIC transport parameters.
@(private)
parse_encrypted_extensions :: proc(hs: ^Handshake_State, h: ^Hello, body: []byte) -> Error {
	r := reader(body)
	exts := reader(r_vec16(&r))
	if !r_done(&r) do return .Decode
	seen: [dynamic]u16
	defer delete(seen)
	for len(exts.b) > 0 {
		typ := r_u16(&exts)
		data := reader(r_vec16(&exts))
		if !exts.ok do return .Decode
		for x in seen do if x == typ do return .Illegal_Parameter
		append(&seen, typ)
		switch typ {
		case EXT_ALPN:
			list := reader(r_vec16(&data))
			proto := string(r_vec8(&list))
			if !r_done(&list) || len(proto) == 0 do return .Decode
			offered := false
			for p in h.alpn do if p == proto do offered = true
			if !offered do return .Illegal_Parameter
			hs.alpn = strings.clone(proto, hs.allocator)
		case EXT_APPLICATION_SETTINGS:
			// Server settings are opaque to us; consumed whole.
			if alps_protocol(h) == "" do return .Unsupported_Extension
			hs.alps = true
			data.b = nil
		case EXT_EARLY_DATA:
			if !h.early_data do return .Unsupported_Extension
			hs.early_accepted = true
		case EXT_QUIC_TRANSPORT_PARAMETERS:
			if !h.quic do return .Unsupported_Extension
			hs.server_params = make([]byte, len(data.b), hs.allocator)
			copy(hs.server_params, data.b)
			data.b = nil
		case EXT_SERVER_NAME:
			// Must be empty.
		case EXT_SUPPORTED_GROUPS, EXT_ECH:
			// Server's groups / ECH retry_configs: informative only for a GREASE ECH client.
			data.b = nil
		case:
			return .Unsupported_Extension
		}
		if !r_done(&data) do return .Decode
	}
	if hs.alps && hs.alpn != alps_protocol(h) do return .Illegal_Parameter
	if h.quic && hs.server_params == nil do return .Missing_Extension
	// QUIC requires ALPN agreement (RFC 9001 8.1).
	if h.quic && hs.alpn == "" do return .No_Application_Protocol
	return .None
}

// quic_handshake runs the handshake with Chrome's QUIC ClientHello profile.
// Transport parameters go in hs.quic_params; the server's come back in
// hs.server_params.
quic_handshake :: proc(hs: ^Handshake_State, io: Handshake_Io) -> Error {
	hs.quic = true
	return run_handshake(hs, io)
}

// quic_post_handshake handles a post-handshake message received in 1-RTT
// CRYPTO frames: NewSessionTicket is cached; anything else is an error
// (QUIC forbids KeyUpdate).
quic_post_handshake :: proc(hs: ^Handshake_State, msg: []byte) -> Error {
	if len(msg) < 4 do return .Decode
	if msg[0] != HS_NEW_SESSION_TICKET do return .Unexpected_Message
	cache := resolve_cache(hs.cfg)
	if cache == nil do return .None
	t, ok := parse_new_session_ticket(hs.suite, hs.res_master[:], msg[4:], cache_allocator(cache)) or_return
	if !ok do return .None
	if len(hs.server_params) > 0 {
		t.quic_params = make([]byte, len(hs.server_params), cache_allocator(cache))
		copy(t.quic_params, hs.server_params)
	}
	ticket_cache_put(cache, hs.cfg.server_name, true, t)
	return .None
}

// alert_code maps an Error to the TLS alert sent for it (QUIC uses 0x100+alert).
alert_code :: proc(e: Error) -> u8 {return alert_for(e)}
