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

OP_PREPARE_TRANSITION :: 21;
OP_EXECUTE_TRANSITION :: 22;
OP_READY_FOR_TRANSITION :: 23;
OP_PREPARE_EPOCH :: 24;
OP_MLS_EXTERNAL_SENDER :: 25;
OP_MLS_KEY_PACKAGE :: 26;
OP_MLS_PROPOSALS :: 27;
OP_MLS_COMMIT_WELCOME :: 28;
OP_MLS_ANNOUNCE_COMMIT :: 29;
OP_MLS_WELCOME :: 30;
OP_MLS_INVALID_COMMIT_WELCOME :: 31;

MAX_INVALID_IN_A_ROW :: 5; // then close 4803

Outgoing :: struct {
	op: int;
	transition_id: int; // JSON ops 23 / 31
	data: []u8; // binary ops 26 / 28 (payload after the opcode byte)
}

Close_Request :: enum u8 {
	None;
	Repeated_Invalid :: 1; // 4803
	Downgrade_Refused :: 2; // 4804
	Invalid_Message :: 3; // 4805
}

Cryptor :: struct {
	ratchet: Ratchet;
	expiry_ms: s64; // 0 = active
	window: Replay_Window;
	epoch: u64;
}

Decryptor :: struct {
	cryptors: [..]Cryptor; // newest last
}

Decrypt_Result :: enum u8 {
	Ok;
	Passthrough; // frame returned unmodified
	Failed;
}

Stats :: struct {
	encrypted, decrypted, passthrough_in, passthrough_out, decrypt_failures: u64;
}

Session :: struct {
	mu: locks.Mutex;
	self_user: u64;
	group_id: [8]u8;
	stage_channel: bool;
	protocol_version: int;
	identity: mls.Identity;
	ext_sender: []u8; // raw ExternalSender
	kp_msg: []u8;
	kp: mls.Key_Package;
	kp_secrets: mls.Key_Package_Secrets;
	pending: *mls.Group; // local unestablished group (epoch 0)
	current: *mls.Group; // established group (latest epoch processed)
	outbound: mls.Commit_Result;
	has_outbound: bool;
	recognized: Map(u64, bool);
	transitions: Map(int, int); // transition id -> protocol version
	invalid_in_a_row: int;
	close_request: Close_Request;
	// media
	send_ratchet: Ratchet;
	send_active: bool;
	send_nonce: u32;
	send_epoch: u64;
	decryptors: Map(u64, Decryptor);
	passthrough_forever: bool;
	passthrough_until: s64;
	executed_epoch: u64;
	executed_auth: mls.Secret;
	has_executed: bool;
	roster: Map(u64, [mls.NPK]u8);
	out: [..]Outgoing;
	stats: Stats;
	now_ms: () -> s64;
	init_done: bool;
}

default_now_ms :: () -> s64 {return time.to_unix_nanoseconds(time.now()) / 1000000;}

session_init :: (s: *Session, self_user: u64, channel_id: u64, stage := false) {
	s.self_user = self_user;
	for i: 0..7 { s.group_id[i] = cast(u8)(channel_id >> (56 - 8 * cast(u64)(i))); }
	s.stage_channel = stage;
	s.identity.sig_priv, s.identity.sig_pub = mls.generate_signature_key();
	id := make_slice(u8, 8);
	for i: 0..7 { id[i] = cast(u8)(self_user >> (56 - 8 * cast(u64)(i))); }
	s.identity.credential = mls.Credential.{mls.CRED_BASIC, id};
	s.recognized = Map(u64, bool).{};
	s.transitions = Map(int, int).{};
	s.decryptors = Map(u64, Decryptor).{};
	s.roster = Map(u64, [mls.NPK]u8).{};
	s.out = make_dynamic(Outgoing, 0, 0);
	s.passthrough_forever = true;
	if s.now_ms == null { s.now_ms = default_now_ms; }
	at(*s.recognized, self_user).* = true;
}

session_destroy :: (s: *Session) {
	reset_mls(s);
	delete(s.identity.credential.data);
	delete(s.ext_sender);
	if s.send_active { ratchet_destroy(*s.send_ratchet); }
	for * _, d: s.decryptors {
		for * c: d.cryptors { ratchet_destroy(*c.ratchet); }
		delete(d.cryptors);
	}
	delete(s.decryptors);
	delete(s.recognized);
	delete(s.transitions);
	delete(s.roster);
	for o: s.out { delete(o.data); }
	delete(s.out);
}
#scope_module

reset_mls :: (s: *Session) {
	mls.group_destroy(s.pending);
	s.pending = null;
	mls.group_destroy(s.current);
	s.current = null;
	drop_outbound(s);
	delete(s.kp_msg);
	s.kp_msg = null;
}

drop_outbound :: (s: *Session) {
	if s.has_outbound {
		mls.group_destroy(s.outbound.group);
		delete(s.outbound.commit);
		delete(s.outbound.welcome);
	}
	s.outbound = .{};
	s.has_outbound = false;
}

push :: (s: *Session, o: Outgoing) {append(*s.out, o);}
#scope_export

// session_take_outgoing moves queued messages to the caller (who frees each .data).
session_take_outgoing :: (s: *Session, allocator := context.allocator) -> []Outgoing {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	out := make_slice(Outgoing, len(s.out), allocator);
	copy(out, view(s.out));
	clear(*s.out);
	return out;
}

session_close_request :: (s: *Session) -> Close_Request {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	return s.close_request;
}
#scope_module

new_key_package :: (s: *Session) {
	delete(s.kp_msg);
	msg, _, secrets := mls.key_package_create(*s.identity, temp);
	s.kp_msg = clone(msg);
	s.kp_secrets = secrets;
	// keep only what joining needs, aliasing kp_msg
	r := mls.reader_make(sub_from(s.kp_msg, 4));
	kp := mls.r_key_package(*r, temp);
	s.kp = mls.Key_Package.{
		version = kp.version,
		cipher_suite = kp.cipher_suite,
		init_key = kp.init_key,
		raw = kp.raw,
		leaf = mls.Leaf_Node.{encryption_key = kp.leaf.encryption_key, signature_key = kp.leaf.signature_key}
	};
	// The official client sends the bare KeyPackage (captured op 26 payload
	// starts 00 01 00 02: version, cipher suite), not an MLSMessage wrapper.
	push(s, Outgoing.{op = OP_MLS_KEY_PACKAGE, data = clone(sub_from(s.kp_msg, 4))});
}

clone :: (b: []u8) -> []u8 {
	out := make_slice(u8, len(b));
	copy(out, b);
	return out;
}

create_pending :: (s: *Session) {
	if s.ext_sender == null || s.kp_msg == null || s.protocol_version == 0 { return; }
	mls.group_destroy(s.pending);
	s.pending = null;
	r := mls.reader_make(s.ext_sender);
	es := mls.r_external_sender(*r);
	if !mls.r_done(*r) { return; }
	ext := mls.external_senders_extension(.{es});
	g, err := mls.group_create(view(s.group_id), *s.identity, *s.kp, *s.kp_secrets, .{ext});
	if err == .None { s.pending = g; }
}

// init: select_protocol_ack (dave_protocol_version) or prepare_epoch with epoch 1.
init_epoch :: (s: *Session, version: int) {
	reset_mls(s);
	s.protocol_version = version;
	new_key_package(s);
	create_pending(s);
}

refuse_downgrade :: (s: *Session, version: int, at_init: bool) -> bool {
	if version != 0 { return false; }
	// official client (RTCConnection._ensureDaveProtocolVersionAllowed): version 0 is
	// only accepted at init for stage channels; anything else disconnects with 4804.
	if at_init && s.stage_channel { return false; }
	s.close_request = .Downgrade_Refused;
	return true;
}
#scope_export

// on_select_protocol_ack: dave_protocol_version from op 4.
on_select_protocol_ack :: (s: *Session, version: int) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	if version > 0 {
		init_epoch(s, version);
	} else {
		if refuse_downgrade(s, version, true) { return; }
		s.protocol_version = 0;
		execute_locked(s, 0, 0);
	}
	s.init_done = true;
}

on_prepare_epoch :: (s: *Session, ep: u64, version: int) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	if refuse_downgrade(s, version, false) { return; }
	if ep == 1 {
		init_epoch(s, version);
	} else {
		s.protocol_version = version;
	}
}

on_external_sender :: (s: *Session, payload: []u8) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	r := mls.reader_make(payload);
	mls.r_external_sender(*r);
	if !mls.r_done(*r) {
		s.close_request = .Invalid_Message;
		return;
	}
	delete(s.ext_sender);
	s.ext_sender = clone(payload);
	create_pending(s);
}

on_clients_connect :: (s: *Session, users: []u64) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	for u: users { at(*s.recognized, u).* = true; }
}

on_client_disconnect :: (s: *Session, user: u64) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	if user != s.self_user { delete_key(*s.recognized, user); }
}
#scope_module

user_of :: (cred: mls.Credential) -> u64, bool {
	if cred.type != mls.CRED_BASIC || len(cred.data) != 8 { return 0, false; }
	v: u64 = 0;
	for b: cred.data { v = v << 8 | cast(u64)(b); }
	return v, true;
}
#scope_export

// on_proposals: op 27 payload (after seq/opcode).
on_proposals :: (s: *Session, payload: []u8) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	g := ifx s.current != null then s.current else s.pending;
	if g == null || len(payload) < 1 { return; } // no local group: ignored
	r := mls.reader_make(sub_from(payload, 1));
	if payload[0] == {
	case 0; // append
		sub := mls.r_sub(*r);
		if !mls.r_done(*r) {
			s.close_request = .Invalid_Message;
			return;
		}
		while mls.r_ok(*sub) && mls.r_left(*sub) > 0 {
			msg := mls.r_mls_message_raw(*sub);
			if msg == null { break; }
			m, err := mls.parse_mls_message(msg, temp);
			if err != .None || m.wire_format != .Public_Message { return; }
			fc := *m.public.content;
			if fc.sender.type != .External || fc.sender.index != 0 || fc.content_type != .Proposal { return; }
			if fc.proposal.type == {
			case .Add;
				uid, ok := user_of(fc.proposal.add.leaf.credential);
				if !ok || !__MAPIDX__(s.recognized|uid) { return; }
			case .Remove;
			case;
				return;
			}
			{ _, _, cerr := mls.group_cache_proposal(g, msg);
			if cerr != .None { return; } }
		}
		if !mls.r_ok(*sub) { return; }
	case 1; // revoke
		sub := mls.r_sub(*r);
		while mls.r_ok(*sub) && mls.r_left(*sub) > 0 {
			ref := mls.r_vec(*sub);
			if ref != null { mls.group_revoke_proposal(g, ref); }
		}
	case;
		s.close_request = .Invalid_Message;
		return;
	}
	drop_outbound(s);
	if len(g.proposals) == 0 { return; }
	res, err := mls.group_commit(g);
	if err != .None { return; }
	s.outbound = res;
	s.has_outbound = true;
	data := make_slice(u8, len(res.commit) + len(res.welcome));
	copy(data, res.commit);
	copy(sub_from(data, len(res.commit)), res.welcome);
	push(s, Outgoing.{op = OP_MLS_COMMIT_WELCOME, data = data});
}
#scope_module

valid_roster :: (g: *mls.Group) -> bool {
	seen := Map(u64, bool).{};
	for l: 0..(mls.n_leaves(*g.tree))-1 {
		n := mls.leaf_at(*g.tree, l);
		if n.kind != .Leaf { continue; }
		uid, ok := user_of(n.leaf.credential);
		if !ok || __MAPIDX__(seen|uid) { return false; }
		at(*seen, uid).* = true;
	}
	return true;
}

ext_sender_matches :: (s: *Session, g: *mls.Group) -> bool {
	es := mls.external_senders(g);
	if len(es) != 1 { return false; }
	w := mls.writer_make();
	mls.w_external_sender(*w, es[0]);
	return mls.bytes_equal(view(w.buf), s.ext_sender);
}

flag_invalid :: (s: *Session, tid: int) -> bool {
	s.invalid_in_a_row += 1;
	if s.invalid_in_a_row >= MAX_INVALID_IN_A_ROW {
		s.invalid_in_a_row = 0;
		s.close_request = .Repeated_Invalid;
		return false;
	}
	push(s, Outgoing.{op = OP_MLS_INVALID_COMMIT_WELCOME, transition_id = tid});
	return true;
}

// adopt: a new established group; prepare decryptors for every member.
adopt :: (s: *Session, g: *mls.Group, tid: int) {
	if s.current != g { mls.group_destroy(s.current); }
	s.current = g;
	if s.pending != g { mls.group_destroy(s.pending); }
	s.pending = null;
	s.invalid_in_a_row = 0;
	now := s.now_ms();
	set_roster(s, g);
	for l: 0..(mls.n_leaves(*g.tree))-1 {
		n := mls.leaf_at(*g.tree, l);
		if n.kind != .Leaf { continue; }
		uid, ok := user_of(n.leaf.credential);
		if !ok || uid == s.self_user { continue; }
		d := get(s.decryptors, uid);
		if d.cryptors == null { d.cryptors = make_dynamic(Cryptor, 0, 0); }
		// drop expired
		for < i: len(d.cryptors) - 1..0 {
			if d.cryptors[i].expiry_ms != 0 && d.cryptors[i].expiry_ms < now {
				ratchet_destroy(*d.cryptors[i].ratchet);
				ordered_remove(*d.cryptors, i);
			}
		}
		c: Cryptor;
		c.epoch = mls.epoch(g);
		base := sender_base_secret(g, uid);
		ratchet_init(*c.ratchet, view(base));
		append(*d.cryptors, c);
		at(*s.decryptors, uid).* = d;
	}
	at(*s.transitions, tid).* = s.protocol_version;
	if tid == 0 {
		execute_locked(s, 0, s.protocol_version);
	} else {
		push(s, Outgoing.{op = OP_READY_FOR_TRANSITION, transition_id = tid});
	}
}

set_roster :: (s: *Session, g: *mls.Group) {
	clear(*s.roster);
	for l: 0..(mls.n_leaves(*g.tree))-1 {
		n := mls.leaf_at(*g.tree, l);
		if n.kind != .Leaf { continue; }
		uid, ok := user_of(n.leaf.credential);
		if !ok { continue; }
		key: [mls.NPK]u8;
		copy(view(key), n.leaf.signature_key);
		at(*s.roster, uid).* = key;
	}
}
#scope_export

sender_base_secret :: (g: *mls.Group, uid: u64) -> [16]u8 {
	out: [16]u8;
	ctx: [8]u8;
	for i: 0..7 { ctx[i] = cast(u8)(uid >> (8 * cast(u64)(i))); } // little endian
	mls.exporter(g, EXPORT_LABEL, view(ctx), view(out));
	return out;
}

// on_announce_commit: op 29 (transition id, MLSMessage commit).
on_announce_commit :: (s: *Session, tid: int, commit: []u8) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	if s.has_outbound && mls.bytes_equal(s.outbound.commit, commit) {
		g := s.outbound.group;
		s.outbound.group = null;
		drop_outbound(s);
		if !valid_roster(g) {
			mls.group_destroy(g);
			if flag_invalid(s, tid) { init_epoch(s, s.protocol_version); }
			return;
		}
		adopt(s, g, tid);
		return;
	}
	if s.current == null { return; } // unestablished and not ours: a welcome follows
	ng, err := mls.group_process_commit(s.current, commit);
	if err == .None && !valid_roster(ng) {
		mls.group_destroy(ng);
		err = .Verify;
	}
	if err != .None {
		if flag_invalid(s, tid) { init_epoch(s, s.protocol_version); }
		return;
	}
	drop_outbound(s);
	adopt(s, ng, tid);
}

// on_welcome: op 30 (transition id, Welcome).
on_welcome :: (s: *Session, tid: int, welcome: []u8) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	if s.current != null || s.kp_msg == null { return; }
	jp := mls.Join_Params.{
		key_package = *s.kp,
		secrets = *s.kp_secrets,
		sig_priv = s.identity.sig_priv
	};
	g, err := mls.group_join(welcome, jp);
	if err == .None && (!ext_sender_matches(s, g) || !valid_roster(g)) {
		mls.group_destroy(g);
		err = .Verify;
	}
	if err != .None {
		if flag_invalid(s, tid) {
			reset_mls(s);
			new_key_package(s);
			create_pending(s);
		}
		return;
	}
	drop_outbound(s);
	adopt(s, g, tid);
}

on_prepare_transition :: (s: *Session, tid: int, version: int) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	if refuse_downgrade(s, version, false) { return; }
	at(*s.transitions, tid).* = version;
	if version == 0 { s.passthrough_forever = true; } // receive side accepts plain frames
	if tid == 0 {
		execute_locked(s, 0, version);
	} else {
		push(s, Outgoing.{op = OP_READY_FOR_TRANSITION, transition_id = tid});
	}
}

on_execute_transition :: (s: *Session, tid: int) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	version, ok := map_find(s.transitions, tid);
	if !ok { version = s.protocol_version; }
	execute_locked(s, tid, version);
}
#scope_module

execute_locked :: (s: *Session, tid: int, version: int) {
	delete_key(*s.transitions, tid);
	now := s.now_ms();
	s.protocol_version = version;
	if version == 0 {
		if s.send_active { ratchet_destroy(*s.send_ratchet); }
		s.send_active = false;
		s.passthrough_forever = true;
		return;
	}
	g := s.current;
	if g == null && tid == 0 && s.pending != null {
		// sole member reset: switch to the local one-member group
		g = s.pending;
		set_roster(s, g);
	}
	if g == null { return; }
	// sender switches to the new epoch's key
	if s.send_active { ratchet_destroy(*s.send_ratchet); }
	base := sender_base_secret(g, s.self_user);
	ratchet_init(*s.send_ratchet, view(base));
	s.send_active = true;
	s.send_nonce = 0;
	s.send_epoch = mls.epoch(g);
	// previous receive keys expire in 10 s
	for * _, d: s.decryptors {
		for * c: d.cryptors { if c.epoch != s.send_epoch && c.expiry_ms == 0 { c.expiry_ms = now + RATCHET_RETENTION_MS; } }
	}
	if s.passthrough_forever {
		s.passthrough_forever = false;
		s.passthrough_until = now + RATCHET_RETENTION_MS;
	}
	s.executed_epoch = mls.epoch(g);
	s.executed_auth = mls.epoch_authenticator(g);
	s.has_executed = true;
}
#scope_export

// ---------------------------------------------------------------------------
// Media

MAX_SUPPLEMENTAL :: TAG_SIZE + 5 + 1 + 2;

// session_encrypt: out must hold len(frame) + MAX_SUPPLEMENTAL. Returns the
// frame to send (encrypted, or passthrough when DAVE is not active).
session_encrypt :: (s: *Session, frame: []u8, out: []u8) -> int {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	if !s.send_active {
		// libdave encryptor: plain frames only in passthrough (protocol 0);
		// with E2EE negotiated but no key yet, media is dropped
		if s.protocol_version != 0 { return 0; }
		copy(out, frame);
		s.stats.passthrough_out += 1;
		return len(frame);
	}
	nonce := s.send_nonce;
	s.send_nonce += 1;
	key, ok := ratchet_get(*s.send_ratchet, nonce >> 24);
	if !ok { return 0; }
	s.stats.encrypted += 1;
	return encrypt_opus_frame(view(key), nonce, frame, out);
}

// session_decrypt: out must hold len(frame).
session_decrypt :: (s: *Session, user: u64, frame: []u8, out: []u8) -> int, Decrypt_Result {
	n: int;
	res: Decrypt_Result;
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	passthrough_ok := s.passthrough_forever || s.now_ms() < s.passthrough_until;
	if len(frame) == 3 && frame[0] == 0xF8 && frame[1] == 0xFF && frame[2] == 0xFE {
		copy(out, frame);
		return 3, .Passthrough;
	}
	p, is_protocol := parse_protocol_frame(frame);
	if !is_protocol {
		if passthrough_ok {
			copy(out, frame);
			s.stats.passthrough_in += 1;
			return len(frame), .Passthrough;
		}
		s.stats.decrypt_failures += 1;
		return 0, .Failed;
	}
	d, has := map_find_ptr(*s.decryptors, user);
	if has {
		now := s.now_ms();
		for < i: len(d.cryptors) - 1..0 {
			c := *d.cryptors[i];
			if c.expiry_ms != 0 && c.expiry_ms < now { continue; }
			if !replay_check(*c.window, p.nonce) { continue; }
			key, kok := ratchet_get(*c.ratchet, p.nonce >> 24);
			if !kok { continue; }
			{ m, ok := decrypt_frame(view(key), *p, out);
			if ok {
				replay_mark(*c.window, p.nonce);
				s.stats.decrypted += 1;
				return m, .Ok;
			} }
		}
	}
	s.stats.decrypt_failures += 1;
	return 0, .Failed;
}

// ---------------------------------------------------------------------------
// Status

Status :: struct {
	protocol_version: int;
	e2ee_active: bool; // sending with DAVE
	epoch: u64;
	privacy_code: string; // 30 digits, "" when not encrypted
	members: int;
	stats: Stats;
}

session_status :: (s: *Session, allocator := context.allocator) -> Status {
	st: Status;
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	st.protocol_version = s.protocol_version;
	st.e2ee_active = s.send_active;
	st.epoch = s.executed_epoch;
	st.members = len(s.roster);
	st.stats = s.stats;
	if s.has_executed && s.send_active {
		st.privacy_code, _ = privacy_code(view(s.executed_auth), allocator);
	}
	return st;
}

// session_verification_code: 45-digit pairwise code with another member
// (scrypt; takes ~100 ms). ok=false if the user is not in the group.
session_verification_code :: (s: *Session, user: u64, allocator := context.allocator) -> string, bool {
	code: string;
	ok: bool;
	locks.lock(*s.mu);
	their, has := map_find(s.roster, user);
	mine := s.identity.sig_pub;
	self := s.self_user;
	locks.unlock(*s.mu);
	if !has { return "", false; }
	fp := pairwise_fingerprint(self, view(mine), user, view(their));
	{ __r3, __r4 := verification_code(view(fp), allocator); return __r3, __r4; }
}

session_user_ids :: (s: *Session, allocator := context.allocator) -> []u64 {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	out := make_dynamic(u64, 0, len(s.roster), allocator);
	for k: s.roster { append(*out, k); }
	return view(out);
}

