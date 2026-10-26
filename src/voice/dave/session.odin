package dave

import "core:sync"
import "core:time"
import "fc:voice/mls"

// Session: one DAVE participant (one voice gateway connection). Feed it the
// gateway's DAVE opcodes; drain session_take_outgoing for what to send back.
// encrypt/decrypt are called from media threads; everything is behind mu.
//
// Behaviour mirrors the official client (RTCConnection JS + libdave):
//   - select_protocol_ack v>0 / prepare_epoch(epoch=1): reset MLS, new key package (op 26)
//   - external sender (op 25) -> local one-member pending group
//   - proposals (op 27) -> commit all cached proposals (+ welcome) (op 28)
//   - announce commit (op 29) / welcome (op 30) -> ready (op 23), or invalid (op 31) + new key package
//   - prepare transition (op 21): id 0 executes immediately, else ready (op 23)
//   - execute transition (op 22): switch sender key / passthrough
//   - downgrades to version 0 after init are refused (close 4804) except stage channels

OP_PREPARE_TRANSITION :: 21
OP_EXECUTE_TRANSITION :: 22
OP_READY_FOR_TRANSITION :: 23
OP_PREPARE_EPOCH :: 24
OP_MLS_EXTERNAL_SENDER :: 25
OP_MLS_KEY_PACKAGE :: 26
OP_MLS_PROPOSALS :: 27
OP_MLS_COMMIT_WELCOME :: 28
OP_MLS_ANNOUNCE_COMMIT :: 29
OP_MLS_WELCOME :: 30
OP_MLS_INVALID_COMMIT_WELCOME :: 31

MAX_INVALID_IN_A_ROW :: 5 // then close 4803

Outgoing :: struct {
	op:            int,
	transition_id: int, // JSON ops 23 / 31
	data:          []byte, // binary ops 26 / 28 (payload after the opcode byte)
}

Close_Request :: enum u8 {
	None,
	Repeated_Invalid = 1, // 4803
	Downgrade_Refused = 2, // 4804
	Invalid_Message = 3, // 4805
}

Cryptor :: struct {
	ratchet:   Ratchet,
	expiry_ms: i64, // 0 = active
	window:    Replay_Window,
	epoch:     u64,
}

Decryptor :: struct {
	cryptors: [dynamic]Cryptor, // newest last
}

Decrypt_Result :: enum u8 {
	Ok,
	Passthrough, // frame returned unmodified
	Failed,
}

Stats :: struct {
	encrypted, decrypted, passthrough_in, passthrough_out, decrypt_failures: u64,
}

Session :: struct {
	mu:               sync.Mutex,
	self_user:        u64,
	group_id:         [8]byte,
	stage_channel:    bool,
	protocol_version: int,
	identity:         mls.Identity,
	ext_sender:       []byte, // raw ExternalSender
	kp_msg:           []byte,
	kp:               mls.Key_Package,
	kp_secrets:       mls.Key_Package_Secrets,
	pending:          ^mls.Group, // local unestablished group (epoch 0)
	current:          ^mls.Group, // established group (latest epoch processed)
	outbound:         mls.Commit_Result,
	has_outbound:     bool,
	recognized:       map[u64]bool,
	transitions:      map[int]int, // transition id -> protocol version
	invalid_in_a_row: int,
	close_request:    Close_Request,
	// media
	send_ratchet:     Ratchet,
	send_active:      bool,
	send_nonce:       u32,
	send_epoch:       u64,
	decryptors:       map[u64]Decryptor,
	passthrough_forever: bool,
	passthrough_until:   i64,
	executed_epoch:   u64,
	executed_auth:    mls.Secret,
	has_executed:     bool,
	roster:           map[u64][mls.NPK]byte,
	out:              [dynamic]Outgoing,
	stats:            Stats,
	now_ms:           proc() -> i64,
	init_done:        bool,
}

default_now_ms :: proc() -> i64 {return time.to_unix_nanoseconds(time.now()) / 1e6}

session_init :: proc(s: ^Session, self_user: u64, channel_id: u64, stage := false) {
	s.self_user = self_user
	for i in 0 ..< 8 do s.group_id[i] = u8(channel_id >> (56 - 8 * uint(i)))
	s.stage_channel = stage
	s.identity.sig_priv, s.identity.sig_pub = mls.generate_signature_key()
	id := make([]byte, 8)
	for i in 0 ..< 8 do id[i] = u8(self_user >> (56 - 8 * uint(i)))
	s.identity.credential = mls.Credential{mls.CRED_BASIC, id}
	s.recognized = make(map[u64]bool)
	s.transitions = make(map[int]int)
	s.decryptors = make(map[u64]Decryptor)
	s.roster = make(map[u64][mls.NPK]byte)
	s.out = make([dynamic]Outgoing)
	s.passthrough_forever = true
	if s.now_ms == nil do s.now_ms = default_now_ms
	s.recognized[self_user] = true
}

session_destroy :: proc(s: ^Session) {
	reset_mls(s)
	delete(s.identity.credential.data)
	delete(s.ext_sender)
	if s.send_active do ratchet_destroy(&s.send_ratchet)
	for _, &d in s.decryptors {
		for &c in d.cryptors do ratchet_destroy(&c.ratchet)
		delete(d.cryptors)
	}
	delete(s.decryptors)
	delete(s.recognized)
	delete(s.transitions)
	delete(s.roster)
	for o in s.out do delete(o.data)
	delete(s.out)
}

@(private)
reset_mls :: proc(s: ^Session) {
	mls.group_destroy(s.pending)
	s.pending = nil
	mls.group_destroy(s.current)
	s.current = nil
	drop_outbound(s)
	delete(s.kp_msg)
	s.kp_msg = nil
}

@(private)
drop_outbound :: proc(s: ^Session) {
	if s.has_outbound {
		mls.group_destroy(s.outbound.group)
		delete(s.outbound.commit)
		delete(s.outbound.welcome)
	}
	s.outbound = {}
	s.has_outbound = false
}

@(private)
push :: proc(s: ^Session, o: Outgoing) {append(&s.out, o)}

// session_take_outgoing moves queued messages to the caller (who frees each .data).
session_take_outgoing :: proc(s: ^Session, allocator := context.allocator) -> []Outgoing {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	out := make([]Outgoing, len(s.out), allocator)
	copy(out, s.out[:])
	clear(&s.out)
	return out
}

session_close_request :: proc(s: ^Session) -> Close_Request {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	return s.close_request
}

@(private)
new_key_package :: proc(s: ^Session) {
	delete(s.kp_msg)
	msg, _, secrets := mls.key_package_create(&s.identity, context.temp_allocator)
	s.kp_msg = clone(msg)
	s.kp_secrets = secrets
	// keep only what joining needs, aliasing kp_msg
	r := mls.reader_make(s.kp_msg[4:])
	kp := mls.r_key_package(&r, context.temp_allocator)
	s.kp = mls.Key_Package {
		version      = kp.version,
		cipher_suite = kp.cipher_suite,
		init_key     = kp.init_key,
		raw          = kp.raw,
		leaf         = mls.Leaf_Node{encryption_key = kp.leaf.encryption_key, signature_key = kp.leaf.signature_key},
	}
	// The official client sends the bare KeyPackage (captured op 26 payload
	// starts 00 01 00 02: version, cipher suite), not an MLSMessage wrapper.
	push(s, Outgoing{op = OP_MLS_KEY_PACKAGE, data = clone(s.kp_msg[4:])})
}

@(private)
clone :: proc(b: []byte) -> []byte {
	out := make([]byte, len(b))
	copy(out, b)
	return out
}

@(private)
create_pending :: proc(s: ^Session) {
	if s.ext_sender == nil || s.kp_msg == nil || s.protocol_version == 0 do return
	mls.group_destroy(s.pending)
	s.pending = nil
	r := mls.reader_make(s.ext_sender)
	es := mls.r_external_sender(&r)
	if !mls.r_done(&r) do return
	ext := mls.external_senders_extension({es})
	g, err := mls.group_create(s.group_id[:], &s.identity, &s.kp, &s.kp_secrets, {ext})
	if err == .None do s.pending = g
}

// init: select_protocol_ack (dave_protocol_version) or prepare_epoch with epoch 1.
@(private)
init_epoch :: proc(s: ^Session, version: int) {
	reset_mls(s)
	s.protocol_version = version
	new_key_package(s)
	create_pending(s)
}

@(private)
refuse_downgrade :: proc(s: ^Session, version: int, at_init: bool) -> bool {
	if version != 0 do return false
	// official client (RTCConnection._ensureDaveProtocolVersionAllowed): version 0 is
	// only accepted at init for stage channels; anything else disconnects with 4804.
	if at_init && s.stage_channel do return false
	s.close_request = .Downgrade_Refused
	return true
}

// on_select_protocol_ack: dave_protocol_version from op 4.
on_select_protocol_ack :: proc(s: ^Session, version: int) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if version > 0 {
		init_epoch(s, version)
	} else {
		if refuse_downgrade(s, version, true) do return
		s.protocol_version = 0
		execute_locked(s, 0, 0)
	}
	s.init_done = true
}

on_prepare_epoch :: proc(s: ^Session, ep: u64, version: int) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if refuse_downgrade(s, version, false) do return
	if ep == 1 {
		init_epoch(s, version)
	} else {
		s.protocol_version = version
	}
}

on_external_sender :: proc(s: ^Session, payload: []byte) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	r := mls.reader_make(payload)
	_ = mls.r_external_sender(&r)
	if !mls.r_done(&r) {
		s.close_request = .Invalid_Message
		return
	}
	delete(s.ext_sender)
	s.ext_sender = clone(payload)
	create_pending(s)
}

on_clients_connect :: proc(s: ^Session, users: []u64) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	for u in users do s.recognized[u] = true
}

on_client_disconnect :: proc(s: ^Session, user: u64) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if user != s.self_user do delete_key(&s.recognized, user)
}

@(private)
user_of :: proc(cred: mls.Credential) -> (u64, bool) {
	if cred.type != mls.CRED_BASIC || len(cred.data) != 8 do return 0, false
	v: u64 = 0
	for b in cred.data do v = v << 8 | u64(b)
	return v, true
}

// on_proposals: op 27 payload (after seq/opcode).
on_proposals :: proc(s: ^Session, payload: []byte) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	g := s.current if s.current != nil else s.pending
	if g == nil || len(payload) < 1 do return // no local group: ignored
	r := mls.reader_make(payload[1:])
	switch payload[0] {
	case 0: // append
		sub := mls.r_sub(&r)
		if !mls.r_done(&r) {
			s.close_request = .Invalid_Message
			return
		}
		for mls.r_ok(&sub) && mls.r_left(&sub) > 0 {
			msg := mls.r_mls_message_raw(&sub)
			if msg == nil do break
			m, err := mls.parse_mls_message(msg, context.temp_allocator)
			if err != .None || m.wire_format != .Public_Message do return
			fc := &m.public.content
			if fc.sender.type != .External || fc.sender.index != 0 || fc.content_type != .Proposal do return
			#partial switch fc.proposal.type {
			case .Add:
				uid, ok := user_of(fc.proposal.add.leaf.credential)
				if !ok || !s.recognized[uid] do return
			case .Remove:
			case:
				return
			}
			if _, _, cerr := mls.group_cache_proposal(g, msg); cerr != .None do return
		}
		if !mls.r_ok(&sub) do return
	case 1: // revoke
		sub := mls.r_sub(&r)
		for mls.r_ok(&sub) && mls.r_left(&sub) > 0 {
			ref := mls.r_vec(&sub)
			if ref != nil do mls.group_revoke_proposal(g, ref)
		}
	case:
		s.close_request = .Invalid_Message
		return
	}
	drop_outbound(s)
	if len(g.proposals) == 0 do return
	res, err := mls.group_commit(g)
	if err != .None do return
	s.outbound = res
	s.has_outbound = true
	data := make([]byte, len(res.commit) + len(res.welcome))
	copy(data, res.commit)
	copy(data[len(res.commit):], res.welcome)
	push(s, Outgoing{op = OP_MLS_COMMIT_WELCOME, data = data})
}

@(private)
valid_roster :: proc(g: ^mls.Group) -> bool {
	seen := make(map[u64]bool, context.temp_allocator)
	for l in 0 ..< mls.n_leaves(&g.tree) {
		n := mls.leaf_at(&g.tree, l)
		if n.kind != .Leaf do continue
		uid, ok := user_of(n.leaf.credential)
		if !ok || seen[uid] do return false
		seen[uid] = true
	}
	return true
}

@(private)
ext_sender_matches :: proc(s: ^Session, g: ^mls.Group) -> bool {
	es := mls.external_senders(g)
	if len(es) != 1 do return false
	w := mls.writer_make()
	mls.w_external_sender(&w, es[0])
	return mls.bytes_equal(w.buf[:], s.ext_sender)
}

@(private)
flag_invalid :: proc(s: ^Session, tid: int) -> bool {
	s.invalid_in_a_row += 1
	if s.invalid_in_a_row >= MAX_INVALID_IN_A_ROW {
		s.invalid_in_a_row = 0
		s.close_request = .Repeated_Invalid
		return false
	}
	push(s, Outgoing{op = OP_MLS_INVALID_COMMIT_WELCOME, transition_id = tid})
	return true
}

// adopt: a new established group; prepare decryptors for every member.
@(private)
adopt :: proc(s: ^Session, g: ^mls.Group, tid: int) {
	if s.current != g do mls.group_destroy(s.current)
	s.current = g
	if s.pending != g do mls.group_destroy(s.pending)
	s.pending = nil
	s.invalid_in_a_row = 0
	now := s.now_ms()
	clear(&s.roster)
	for l in 0 ..< mls.n_leaves(&g.tree) {
		n := mls.leaf_at(&g.tree, l)
		if n.kind != .Leaf do continue
		uid, ok := user_of(n.leaf.credential)
		if !ok do continue
		key: [mls.NPK]byte
		copy(key[:], n.leaf.signature_key)
		s.roster[uid] = key
		if uid == s.self_user do continue
		d := s.decryptors[uid]
		if d.cryptors == nil do d.cryptors = make([dynamic]Cryptor)
		// drop expired
		for i := len(d.cryptors) - 1; i >= 0; i -= 1 {
			if d.cryptors[i].expiry_ms != 0 && d.cryptors[i].expiry_ms < now {
				ratchet_destroy(&d.cryptors[i].ratchet)
				ordered_remove(&d.cryptors, i)
			}
		}
		c: Cryptor
		c.epoch = mls.epoch(g)
		base := sender_base_secret(g, uid)
		ratchet_init(&c.ratchet, base[:])
		append(&d.cryptors, c)
		s.decryptors[uid] = d
	}
	s.transitions[tid] = s.protocol_version
	if tid == 0 {
		execute_locked(s, 0, s.protocol_version)
	} else {
		push(s, Outgoing{op = OP_READY_FOR_TRANSITION, transition_id = tid})
	}
}

sender_base_secret :: proc(g: ^mls.Group, uid: u64) -> (out: [16]byte) {
	ctx: [8]byte
	for i in 0 ..< 8 do ctx[i] = u8(uid >> (8 * uint(i))) // little endian
	mls.exporter(g, EXPORT_LABEL, ctx[:], out[:])
	return
}

// on_announce_commit: op 29 (transition id, MLSMessage commit).
on_announce_commit :: proc(s: ^Session, tid: int, commit: []byte) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if s.has_outbound && mls.bytes_equal(s.outbound.commit, commit) {
		g := s.outbound.group
		s.outbound.group = nil
		drop_outbound(s)
		if !valid_roster(g) {
			mls.group_destroy(g)
			if flag_invalid(s, tid) do init_epoch(s, s.protocol_version)
			return
		}
		adopt(s, g, tid)
		return
	}
	if s.current == nil do return // unestablished and not ours: a welcome follows
	ng, err := mls.group_process_commit(s.current, commit)
	if err == .None && !valid_roster(ng) {
		mls.group_destroy(ng)
		err = .Verify
	}
	if err != .None {
		if flag_invalid(s, tid) do init_epoch(s, s.protocol_version)
		return
	}
	drop_outbound(s)
	adopt(s, ng, tid)
}

// on_welcome: op 30 (transition id, Welcome).
on_welcome :: proc(s: ^Session, tid: int, welcome: []byte) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if s.current != nil || s.kp_msg == nil do return
	jp := mls.Join_Params {
		key_package = &s.kp,
		secrets     = &s.kp_secrets,
		sig_priv    = s.identity.sig_priv,
	}
	g, err := mls.group_join(welcome, jp)
	if err == .None && (!ext_sender_matches(s, g) || !valid_roster(g)) {
		mls.group_destroy(g)
		err = .Verify
	}
	if err != .None {
		if flag_invalid(s, tid) {
			reset_mls(s)
			new_key_package(s)
			create_pending(s)
		}
		return
	}
	drop_outbound(s)
	adopt(s, g, tid)
}

on_prepare_transition :: proc(s: ^Session, tid: int, version: int) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if refuse_downgrade(s, version, false) do return
	s.transitions[tid] = version
	if version == 0 do s.passthrough_forever = true // receive side accepts plain frames
	if tid == 0 {
		execute_locked(s, 0, version)
	} else {
		push(s, Outgoing{op = OP_READY_FOR_TRANSITION, transition_id = tid})
	}
}

on_execute_transition :: proc(s: ^Session, tid: int) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	version, ok := s.transitions[tid]
	if !ok do version = s.protocol_version
	execute_locked(s, tid, version)
}

@(private)
execute_locked :: proc(s: ^Session, tid: int, version: int) {
	delete_key(&s.transitions, tid)
	now := s.now_ms()
	s.protocol_version = version
	if version == 0 {
		if s.send_active do ratchet_destroy(&s.send_ratchet)
		s.send_active = false
		s.passthrough_forever = true
		return
	}
	g := s.current
	if g == nil && tid == 0 do g = s.pending // sole member reset: switch to the local group
	if g == nil do return
	// sender switches to the new epoch's key
	if s.send_active do ratchet_destroy(&s.send_ratchet)
	base := sender_base_secret(g, s.self_user)
	ratchet_init(&s.send_ratchet, base[:])
	s.send_active = true
	s.send_nonce = 0
	s.send_epoch = mls.epoch(g)
	// previous receive keys expire in 10 s
	for _, &d in s.decryptors {
		for &c in d.cryptors do if c.epoch != s.send_epoch && c.expiry_ms == 0 do c.expiry_ms = now + RATCHET_RETENTION_MS
	}
	if s.passthrough_forever {
		s.passthrough_forever = false
		s.passthrough_until = now + RATCHET_RETENTION_MS
	}
	s.executed_epoch = mls.epoch(g)
	s.executed_auth = mls.epoch_authenticator(g)
	s.has_executed = true
}

// ---------------------------------------------------------------------------
// Media

MAX_SUPPLEMENTAL :: TAG_SIZE + 5 + 1 + 2

// session_encrypt: out must hold len(frame) + MAX_SUPPLEMENTAL. Returns the
// frame to send (encrypted, or passthrough when DAVE is not active).
session_encrypt :: proc(s: ^Session, frame: []byte, out: []byte) -> int {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if !s.send_active {
		// libdave encryptor: plain frames only in passthrough (protocol 0);
		// with E2EE negotiated but no key yet, media is dropped
		if s.protocol_version != 0 do return 0
		copy(out, frame)
		s.stats.passthrough_out += 1
		return len(frame)
	}
	nonce := s.send_nonce
	s.send_nonce += 1
	key, ok := ratchet_get(&s.send_ratchet, nonce >> 24)
	if !ok do return 0
	s.stats.encrypted += 1
	return encrypt_opus_frame(key[:], nonce, frame, out)
}

// session_decrypt: out must hold len(frame).
session_decrypt :: proc(s: ^Session, user: u64, frame: []byte, out: []byte) -> (n: int, res: Decrypt_Result) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	passthrough_ok := s.passthrough_forever || s.now_ms() < s.passthrough_until
	if len(frame) == 3 && frame[0] == 0xF8 && frame[1] == 0xFF && frame[2] == 0xFE {
		copy(out, frame)
		return 3, .Passthrough
	}
	p, is_protocol := parse_protocol_frame(frame)
	if !is_protocol {
		if passthrough_ok {
			copy(out, frame)
			s.stats.passthrough_in += 1
			return len(frame), .Passthrough
		}
		s.stats.decrypt_failures += 1
		return 0, .Failed
	}
	d, has := &s.decryptors[user]
	if has {
		now := s.now_ms()
		for i := len(d.cryptors) - 1; i >= 0; i -= 1 {
			c := &d.cryptors[i]
			if c.expiry_ms != 0 && c.expiry_ms < now do continue
			if !replay_check(&c.window, p.nonce) do continue
			key, kok := ratchet_get(&c.ratchet, p.nonce >> 24)
			if !kok do continue
			if m, ok := decrypt_frame(key[:], &p, out); ok {
				replay_mark(&c.window, p.nonce)
				s.stats.decrypted += 1
				return m, .Ok
			}
		}
	}
	s.stats.decrypt_failures += 1
	return 0, .Failed
}

// ---------------------------------------------------------------------------
// Status

Status :: struct {
	protocol_version: int,
	e2ee_active:      bool, // sending with DAVE
	epoch:            u64,
	privacy_code:     string, // 30 digits, "" when not encrypted
	members:          int,
	stats:            Stats,
}

session_status :: proc(s: ^Session, allocator := context.allocator) -> (st: Status) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	st.protocol_version = s.protocol_version
	st.e2ee_active = s.send_active
	st.epoch = s.executed_epoch
	st.members = len(s.roster)
	st.stats = s.stats
	if s.has_executed && s.send_active {
		st.privacy_code, _ = privacy_code(s.executed_auth[:], allocator)
	}
	return
}

// session_verification_code: 45-digit pairwise code with another member
// (scrypt; takes ~100 ms). ok=false if the user is not in the group.
session_verification_code :: proc(s: ^Session, user: u64, allocator := context.allocator) -> (code: string, ok: bool) {
	sync.mutex_lock(&s.mu)
	their, has := s.roster[user]
	mine := s.identity.sig_pub
	self := s.self_user
	sync.mutex_unlock(&s.mu)
	if !has do return "", false
	fp := pairwise_fingerprint(self, mine[:], user, their[:])
	return verification_code(fp[:], allocator)
}

session_user_ids :: proc(s: ^Session, allocator := context.allocator) -> []u64 {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	out := make([dynamic]u64, 0, len(s.roster), allocator)
	for k in s.roster do append(&out, k)
	return out[:]
}
