// Package tls is a from-scratch TLS 1.3 client. It wraps a netio.Stream and
// exposes a netio.Stream, and its ClientHello reproduces the shape of the
// Chrome/BoringSSL hello sent by the official Discord desktop client
// (Electron 42 / Chrome 148): GREASE, permuted extensions, ECH GREASE,
// X25519MLKEM768 + X25519 key shares, ALPS, brotli cert compression.
//
// Only TLS 1.3 is implemented. TLS 1.2 suites are listed in the hello for
// fingerprint parity; a server that picks TLS 1.2 gets a protocol_version
// alert and connect fails.
package tls

import "fc:locks"
import "base:intrinsics"
import "core:crypto/aead"
import "core:crypto/chacha20"
import "core:crypto/hash"
import "core:mem"
import "core:strings"
import "core:time"

import "fc:netio"

Config :: struct {
	// ALPN protocols in preference order, e.g. {"h2", "http/1.1"}.
	// ALPS (application_settings) is offered automatically when "h2" is present, as Chrome does.
	alpn:        []string,
	// SNI and the name the certificate is checked against.
	server_name: string,
	// Skips OS trust evaluation (tests only). CertificateVerify and Finished are still checked.
	insecure_skip_verify: bool,
	// Session resumption: tickets are taken from / stored into this cache
	// (default_ticket_cache when nil) unless disable_resumption is set.
	ticket_cache:         ^Ticket_Cache,
	disable_resumption:   bool,
}

// Error is the detailed failure reason; netio.Error is what the Stream reports.
// The last failure on the calling thread is available from last_error().
Error :: enum u8 {
	None,
	Io,                      // underlying stream failed
	Closed,                  // peer sent close_notify or the stream hit EOF
	Decode,                  // malformed message
	Unexpected_Message,
	Bad_Record_Mac,
	Record_Overflow,
	Handshake_Failure,       // no common parameters, bad key share
	Protocol_Version,        // server chose something other than TLS 1.3
	Illegal_Parameter,
	Unsupported_Extension,
	Missing_Extension,
	Bad_Certificate,         // unparseable or unusable certificate
	Untrusted_Certificate,   // OS trust store rejected the chain / hostname
	Bad_Signature,           // CertificateVerify failed
	Bad_Finished,
	No_Application_Protocol,
	Unsupported_Compression, // compressed certificate with an algorithm we did not offer
	Alert_Received,          // peer sent a fatal alert (see Session.peer_alert)
	Too_Large,
	Internal,
}


// Ticket is a stored NewSessionTicket with its derived resumption PSK.
Ticket :: struct {
	lifetime:    u32,
	age_add:     u32,
	ticket:      []byte,
	psk:         [MAX_HASH]byte,
	psk_len:     int,
	suite:       u16,
	max_early:   u32,
	received:    time.Time,
	quic_params: []byte, // QUIC: the server's transport parameters (for 0-RTT)
}

MAX_HASH :: 48
MAX_PLAINTEXT :: 16384
MAX_CIPHERTEXT :: MAX_PLAINTEXT + 256

Suite :: struct {
	id:       u16,
	aead:     aead.Algorithm,
	key_len:  int,
	hash:     hash.Algorithm,
	hash_len: int,
}

SUITES := [?]Suite {
	{0x1301, .AES_GCM_128, 16, .SHA256, 32},
	{0x1302, .AES_GCM_256, 32, .SHA384, 48},
	{0x1303, .CHACHA20POLY1305, 32, .SHA256, 32},
}

// Odin dev-2026-10 miscompiles the AVX2 ChaCha20 in -debug builds on Windows: its round helper is not
// inlined, reads its stack arguments from the wrong slots and faults. Every ChaCha20 user in fastcord
// passes this implementation (tests/run_all.sh checks), so debug builds use the SSE one instead.
CHACHA20_IMPL :: chacha20.Implementation.Simd128 when ODIN_DEBUG else chacha20.DEFAULT_IMPLEMENTATION

// aead_impl is the implementation argument for aead.init(_, alg, _).
aead_impl :: proc(alg: aead.Algorithm) -> aead.Implementation {
	#partial switch alg {
	case .CHACHA20POLY1305, .XCHACHA20POLY1305:
		return CHACHA20_IMPL
	}
	return nil
}

// Direction is one half of the record protection state.
Direction :: struct {
	active: bool,
	ctx:    aead.Context,
	iv:     [12]byte,
	seq:    u64,
	secret: [MAX_HASH]byte,
}

Session :: struct {
	under:          netio.Stream,
	server_name:    string,
	alpn:           string,
	suite:          Suite,
	group:          u16,  // negotiated key exchange group
	alps:           bool, // server negotiated application_settings
	resumed:        bool, // PSK accepted: no certificate this time
	cache:          ^Ticket_Cache,
	rd:             Direction,
	wr:             Direction,
	wmu:            locks.Mutex, // guards wr and the underlying write side
	// Buffered ciphertext from the underlying stream.
	inbuf:          [MAX_CIPHERTEXT + 5 + 1024]byte,
	in_lo, in_hi:   int,
	// Decrypted record payload and the unread part of it (application data).
	ptbuf:          [MAX_CIPHERTEXT]byte,
	pending:        []byte,
	// Partial handshake message bytes carried across records.
	hsbuf:          [dynamic]byte,
	res_master:     [MAX_HASH]byte,
	// Threading: one reader thread and one writer thread may use a Session
	// concurrently. rd/pending/hsbuf/got_close belong to the reader;
	// wr/sent_close are guarded by wmu; failed is accessed atomically.
	failed:         Error,
	peer_alert:     u8,
	got_close:      bool,
	sent_close:     bool,
	shut:           bool, // atomic; shutdown() was called
	handshake_done: bool,
	allocator:      mem.Allocator,
}

@(thread_local)
_last_error: Error

// last_error returns the detailed reason for the most recent failure on this thread.
last_error :: proc() -> Error {return _last_error}

// connect runs the TLS 1.3 handshake over `under`. On success the Session owns
// `under` and closes it in close(). On failure `under` is left open.
connect :: proc(under: netio.Stream, cfg: Config, allocator := context.allocator) -> (s: ^Session, err: netio.Error) {
	context.allocator = allocator
	s = new(Session)
	s.allocator = allocator
	s.under = under
	s.server_name = strings.clone(cfg.server_name)
	s.hsbuf = make([dynamic]byte)
	if e := handshake(s, cfg); e != .None {
		ne := to_netio(s, e)
		destroy(s)
		return nil, ne
	}
	s.handshake_done = true
	_last_error = .None
	return s, .None
}

stream :: proc(s: ^Session) -> netio.Stream {
	return netio.Stream{data = s, read = stream_read, write = stream_write, close = stream_close, shutdown = stream_shutdown, set_timeout = stream_set_timeout}
}

// negotiated_alpn returns the protocol the server selected, or "" if none.
negotiated_alpn :: proc(s: ^Session) -> string {return s.alpn}

// negotiated_group returns the key exchange group codepoint, e.g. 0x11ec.
negotiated_group :: proc(s: ^Session) -> u16 {return s.group}

// negotiated_suite returns the cipher suite codepoint, e.g. 0x1301.
negotiated_suite :: proc(s: ^Session) -> u16 {return s.suite.id}

// resumed reports whether the session was resumed from a ticket (PSK).
resumed :: proc(s: ^Session) -> bool {return s.resumed}

// close sends close_notify, closes the underlying stream and frees the session.
close :: proc(s: ^Session) {
	if s == nil do return
	if get_failed(s) == .None && !is_shut(s) do send_alert(s, 1, ALERT_CLOSE_NOTIFY)
	netio.close(s.under)
	destroy(s)
}

@(private)
destroy :: proc(s: ^Session) {
	context.allocator = s.allocator
	aead.reset(&s.rd.ctx)
	aead.reset(&s.wr.ctx)
	delete(s.hsbuf)
	delete(s.server_name)
	delete(s.alpn)
	mem.zero_explicit(s, size_of(Session))
	free(s)
}

@(private)
to_netio :: proc(s: ^Session, e: Error) -> netio.Error {
	#partial switch e {
	case .None:
		return .None
	case .Closed:
		return .Closed
	case .Too_Large:
		return .Too_Large
	case .Io:
		return .Io
	}
	return .Tls
}

@(private)
stream_read :: proc(data: rawptr, dst: []byte) -> (int, netio.Error) {
	s := cast(^Session)data
	n, e := read(s, dst)
	return n, to_netio(s, e)
}

@(private)
stream_write :: proc(data: rawptr, src: []byte) -> netio.Error {
	s := cast(^Session)data
	return to_netio(s, write(s, src))
}

@(private)
stream_close :: proc(data: rawptr) {close(cast(^Session)data)}

@(private)
stream_shutdown :: proc(data: rawptr) {shutdown(cast(^Session)data)}

@(private)
stream_set_timeout :: proc(data: rawptr, d: time.Duration) {netio.set_timeout((cast(^Session)data).under, d)}

// shutdown wakes a thread blocked in read (it returns .Closed) and makes
// later reads and writes fail, without freeing anything. It forwards to the
// underlying stream's shutdown and is safe to call from any thread. close()
// is still required afterwards (once other threads have returned).
shutdown :: proc(s: ^Session) {
	intrinsics.atomic_store(&s.shut, true)
	netio.shutdown(s.under)
}

@(private)
is_shut :: proc(s: ^Session) -> bool {return intrinsics.atomic_load(&s.shut)}

// read returns at least one byte of application data, blocking as needed.
read :: proc(s: ^Session, dst: []byte) -> (int, Error) {
	if len(dst) == 0 do return 0, .None
	for len(s.pending) == 0 {
		if s.got_close || is_shut(s) do return 0, .Closed
		if f := get_failed(s); f != .None do return 0, f
		if e := read_record_app(s); e != .None {
			if is_shut(s) do return 0, .Closed // woken by shutdown: not a failure
			if e == .Closed {
				s.got_close = true
			} else {
				fail(s, e)
			}
			return 0, e
		}
	}
	n := copy(dst, s.pending)
	s.pending = s.pending[n:]
	return n, .None
}

// write sends all of src as application data.
write :: proc(s: ^Session, src: []byte) -> Error {
	if f := get_failed(s); f != .None do return f
	if is_shut(s) do return .Closed
	locks.lock(&s.wmu)
	defer locks.unlock(&s.wmu)
	if s.sent_close do return .Closed
	rest := src
	for len(rest) > 0 {
		n := min(len(rest), MAX_PLAINTEXT)
		if e := write_record_locked(s, CT_APPLICATION_DATA, rest[:n]); e != .None {
			set_failed(s, e)
			return e
		}
		rest = rest[n:]
	}
	return .None
}

// key_update rotates our write keys (RFC 8446 4.6.3). With request_peer the
// server is asked to rotate its keys too; its KeyUpdate is handled by read.
key_update :: proc(s: ^Session, request_peer := false) -> Error {
	if f := get_failed(s); f != .None do return f
	locks.lock(&s.wmu)
	defer locks.unlock(&s.wmu)
	if s.sent_close do return .Closed
	if e := send_key_update_locked(s, request_peer); e != .None {
		set_failed(s, e)
		return e
	}
	return .None
}

@(private)
get_failed :: proc(s: ^Session) -> Error {
	return intrinsics.atomic_load(&s.failed)
}

// set_failed records the first failure; it reports whether this call set it.
@(private)
set_failed :: proc(s: ^Session, e: Error) -> bool {
	_, ok := intrinsics.atomic_compare_exchange_strong(&s.failed, Error.None, e)
	return ok
}

// handshake runs the engine over the record layer. On error it sends the alert.
@(private)
handshake :: proc(s: ^Session, cfg: Config) -> (err: Error) {
	defer if err != .None do fail(s, err)
	hs := Handshake_State {
		cfg       = cfg,
		allocator = s.allocator,
	}
	defer handshake_state_destroy(&hs)
	io := Handshake_Io {
		data         = s,
		next_message = tcp_next_message,
		send         = tcp_send,
		set_secret   = tcp_set_secret,
	}
	run_handshake(&hs, io) or_return
	s.suite = hs.suite
	s.group = hs.group
	s.alpn = hs.alpn
	hs.alpn = ""
	s.alps = hs.alps
	s.resumed = hs.resumed
	s.res_master = hs.res_master
	s.cache = resolve_cache(cfg)
	return .None
}

@(private)
tcp_next_message :: proc(data: rawptr) -> ([]byte, Error) {
	return next_handshake_message(cast(^Session)data)
}

@(private)
tcp_send :: proc(data: rawptr, level: Level, flight: []byte, first: bool, ccs: bool) -> Error {
	return write_handshake(cast(^Session)data, flight, 0x0301 if first else 0x0303, ccs)
}

@(private)
tcp_set_secret :: proc(data: rawptr, level: Level, is_write: bool, suite: Suite, secret: []byte) -> Error {
	s := cast(^Session)data
	if level == .Early do return .None
	if !is_write {
		// Handshake messages must not span a key change (RFC 8446 5.1).
		if len(s.hsbuf) > 0 do return .Unexpected_Message
		set_keys(&s.rd, suite, secret)
		return .None
	}
	locks.lock(&s.wmu)
	defer locks.unlock(&s.wmu)
	set_keys(&s.wr, suite, secret)
	return .None
}
