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
	data: []u8; // binary ops 26 / 28 (payload after the opcode byte), heap
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
	recognized: Table(u64, bool);
	transitions: Table(int, int); // transition id -> protocol version
	invalid_in_a_row: int;
	close_request: Close_Request;
	// media
	send_ratchet: Ratchet;
	send_active: bool;
	send_nonce: u32;
	send_epoch: u64;
	decryptors: Table(u64, Decryptor);
	passthrough_forever: bool;
	passthrough_until: s64;
	executed_epoch: u64;
	executed_auth: mls.Secret;
	has_executed: bool;
	roster: Table(u64, [mls.NPK]u8);
	out: [..]Outgoing;
	stats: Stats;
	now_ms: () -> s64;
	init_done: bool;
}

default_now_ms :: () -> s64 { return to_milliseconds(current_time_monotonic()); }

be_bytes :: (x: u64) -> [8]u8 {
	b: [8]u8;
	for i: 0..7 b[i] = cast(u8) (x >> (56 - 8 * cast(u64) i));
	return b;
}

// session_init: the session's own allocations use the heap (context.allocator here).
session_init :: (s: *Session, self_user: u64, channel_id: u64, stage := false) {
	s.self_user = self_user;
	s.group_id = be_bytes(channel_id);
	s.stage_channel = stage;
	s.identity.sig_priv, s.identity.sig_pub = mls.generate_signature_key();
	id := be_bytes(self_user);
	s.identity.credential = .{mls.CRED_BASIC, array_copy(id)};
	s.passthrough_forever = true;
	if !s.now_ms s.now_ms = default_now_ms;
	table_set(*s.recognized, self_user, true);
}

session_destroy :: (s: *Session) {
	reset_mls(s);
	array_free(s.identity.credential.data);
	array_free(s.ext_sender);
	if s.send_active ratchet_destroy(*s.send_ratchet);
	for * d: s.decryptors {
		for * c: d.cryptors ratchet_destroy(*c.ratchet);
		array_free(d.cryptors);
	}
	deinit(*s.decryptors);
	deinit(*s.recognized);
	deinit(*s.transitions);
	deinit(*s.roster);
	for s.out array_free(it.data);
	array_free(s.out);
}

reset_mls :: (s: *Session) {
	mls.group_destroy(s.pending);
	s.pending = null;
	mls.group_destroy(s.current);
	s.current = null;
	drop_outbound(s);
	array_free(s.kp_msg);
	s.kp_msg = .[];
}

drop_outbound :: (s: *Session) {
	if s.has_outbound {
		mls.group_destroy(s.outbound.group);
		array_free(s.outbound.commit);
		array_free(s.outbound.welcome);
	}
	s.outbound = .{};
	s.has_outbound = false;
}

push :: (s: *Session, o: Outgoing) { array_add(*s.out, o); }

// session_take_outgoing moves queued messages to the caller (context.allocator; the caller frees each .data).
session_take_outgoing :: (s: *Session) -> []Outgoing {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	out := array_copy(s.out);
	s.out.count = 0;
	return out;
}

session_close_request :: (s: *Session) -> Close_Request {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	return s.close_request;
}

new_key_package :: (s: *Session) {
	array_free(s.kp_msg);
	msg, _, secrets := mls.key_package_create(*s.identity,, temp);
	s.kp_msg = array_copy(msg);
	s.kp_secrets = secrets;
	// keep only what joining needs, aliasing kp_msg
	r := mls.reader_make(array_view(s.kp_msg, 4));
	kp := mls.r_key_package(*r,, temp);
	s.kp = .{
		version = kp.version,
		cipher_suite = kp.cipher_suite,
		init_key = kp.init_key,
		raw = kp.raw,
		leaf = .{encryption_key = kp.leaf.encryption_key, signature_key = kp.leaf.signature_key}
	};
	// The official client sends the bare KeyPackage (captured op 26 payload
	// starts 00 01 00 02: version, cipher suite), not an MLSMessage wrapper.
	push(s, .{op = OP_MLS_KEY_PACKAGE, data = array_copy(array_view(s.kp_msg, 4))});
}

create_pending :: (s: *Session) {
	if !s.ext_sender.data || !s.kp_msg.data || s.protocol_version == 0 return;
	mls.group_destroy(s.pending);
	s.pending = null;
	r := mls.reader_make(s.ext_sender);
	es := mls.r_external_sender(*r);
	if !mls.r_done(*r) return;
	ext := mls.external_senders_extension(.[es]);
	g, err := mls.group_create(s.group_id, *s.identity, *s.kp, *s.kp_secrets, .[ext]);
	if err == .None s.pending = g;
}

// init: select_protocol_ack (dave_protocol_version) or prepare_epoch with epoch 1.
init_epoch :: (s: *Session, version: int) {
	reset_mls(s);
	s.protocol_version = version;
	new_key_package(s);
	create_pending(s);
}

refuse_downgrade :: (s: *Session, version: int, at_init: bool) -> bool {
	if version != 0 return false;
	// official client (RTCConnection._ensureDaveProtocolVersionAllowed): version 0 is
	// only accepted at init for stage channels; anything else disconnects with 4804.
	if at_init && s.stage_channel return false;
	s.close_request = .Downgrade_Refused;
	return true;
}

// on_select_protocol_ack: dave_protocol_version from op 4.
on_select_protocol_ack :: (s: *Session, version: int) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	if version > 0 {
		init_epoch(s, version);
	} else {
		if refuse_downgrade(s, version, true) return;
		s.protocol_version = 0;
		execute_locked(s, 0, 0);
	}
	s.init_done = true;
}

on_prepare_epoch :: (s: *Session, ep: u64, version: int) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	if refuse_downgrade(s, version, false) return;
	if ep == 1 init_epoch(s, version);
	else s.protocol_version = version;
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
	array_free(s.ext_sender);
	s.ext_sender = array_copy(payload);
	create_pending(s);
}

on_clients_connect :: (s: *Session, users: []u64) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	for users table_set(*s.recognized, it, true);
}

on_client_disconnect :: (s: *Session, user: u64) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	if user != s.self_user table_remove(*s.recognized, user);
}

// user_of: the user id in a basic credential (8 bytes, big endian).
user_of :: (cred: mls.Credential) -> u64, bool {
	if cred.type != mls.CRED_BASIC || cred.data.count != 8 return 0, false;
	v: u64 = 0;
	for cred.data v = (v << 8) | it;
	return v, true;
}

// on_proposals: op 27 payload (after seq/opcode).
on_proposals :: (s: *Session, payload: []u8) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	g := ifx s.current then s.current else s.pending;
	if !g || payload.count < 1 return; // no local group: ignored
	r := mls.reader_make(array_view(payload, 1));
	if payload[0] == {
	case 0; // append
		sub := mls.r_sub(*r);
		if !mls.r_done(*r) {
			s.close_request = .Invalid_Message;
			return;
		}
		while mls.r_ok(*sub) && mls.r_left(*sub) > 0 {
			msg := mls.r_mls_message_raw(*sub);
			if !msg.data break;
			m, err := mls.parse_mls_message(msg,, temp);
			if err != .None || m.wire_format != .Public_Message return;
			fc := *m.public.content;
			if fc.sender.type != .External || fc.sender.index != 0 || fc.content_type != .Proposal return;
			if fc.proposal.type == {
			case .Add;
				uid, ok := user_of(fc.proposal.add.leaf.credential);
				if !ok return;
				if !table_contains(*s.recognized, uid) return;
			case .Remove;
			case;
				return;
			}
			_, _, cerr := mls.group_cache_proposal(g, msg);
			if cerr != .None return;
		}
		if !mls.r_ok(*sub) return;
	case 1; // revoke
		sub := mls.r_sub(*r);
		while mls.r_ok(*sub) && mls.r_left(*sub) > 0 {
			ref := mls.r_vec(*sub);
			if ref.data mls.group_revoke_proposal(g, ref);
		}
	case;
		s.close_request = .Invalid_Message;
		return;
	}
	drop_outbound(s);
	if !g.proposals.count return;
	res, err := mls.group_commit(g);
	if err != .None return;
	s.outbound = res;
	s.has_outbound = true;
	data := NewArray(res.commit.count + res.welcome.count, u8, false);
	memcpy(data.data, res.commit.data, res.commit.count);
	memcpy(data.data + res.commit.count, res.welcome.data, res.welcome.count);
	push(s, .{op = OP_MLS_COMMIT_WELCOME, data = data});
}

valid_roster :: (g: *mls.Group) -> bool {
	seen: Table(u64, bool);
	seen.allocator = temp;
	for l: 0..cast(s64) mls.n_leaves(*g.tree) - 1 {
		n := mls.leaf_at(*g.tree, cast(u32) l);
		if n.kind != .Leaf continue;
		uid, ok := user_of(n.leaf.credential);
		if !ok || table_contains(*seen, uid) return false;
		table_set(*seen, uid, true);
	}
	return true;
}

ext_sender_matches :: (s: *Session, g: *mls.Group) -> bool {
	es := mls.external_senders(g);
	if es.count != 1 return false;
	w := mls.writer_make();
	mls.w_external_sender(*w, es[0]);
	return mls.bytes_equal(w.buf, s.ext_sender);
}

flag_invalid :: (s: *Session, tid: int) -> bool {
	s.invalid_in_a_row += 1;
	if s.invalid_in_a_row >= MAX_INVALID_IN_A_ROW {
		s.invalid_in_a_row = 0;
		s.close_request = .Repeated_Invalid;
		return false;
	}
	push(s, .{op = OP_MLS_INVALID_COMMIT_WELCOME, transition_id = tid});
	return true;
}

// adopt: a new established group; prepare decryptors for every member.
adopt :: (s: *Session, g: *mls.Group, tid: int) {
	if s.current != g mls.group_destroy(s.current);
	s.current = g;
	if s.pending != g mls.group_destroy(s.pending);
	s.pending = null;
	s.invalid_in_a_row = 0;
	now := s.now_ms();
	set_roster(s, g);
	for l: 0..cast(s64) mls.n_leaves(*g.tree) - 1 {
		n := mls.leaf_at(*g.tree, cast(u32) l);
		if n.kind != .Leaf continue;
		uid, ok := user_of(n.leaf.credential);
		if !ok || uid == s.self_user continue;
		d := find_or_add(*s.decryptors, uid);
		// drop expired
		for < i: 0..d.cryptors.count-1 {
			c := *d.cryptors[i];
			if c.expiry_ms == 0 || c.expiry_ms >= now continue;
			ratchet_destroy(*c.ratchet);
			array_ordered_remove_by_index(*d.cryptors, i);
		}
		c := array_add(*d.cryptors);
		c.epoch = mls.epoch(g);
		base := sender_base_secret(g, uid);
		ratchet_init(*c.ratchet, base);
	}
	table_set(*s.transitions, tid, s.protocol_version);
	if tid == 0 execute_locked(s, 0, s.protocol_version);
	else push(s, .{op = OP_READY_FOR_TRANSITION, transition_id = tid});
}

set_roster :: (s: *Session, g: *mls.Group) {
	table_reset(*s.roster);
	for l: 0..cast(s64) mls.n_leaves(*g.tree) - 1 {
		n := mls.leaf_at(*g.tree, cast(u32) l);
		if n.kind != .Leaf continue;
		uid, ok := user_of(n.leaf.credential);
		if !ok continue;
		key: [mls.NPK]u8;
		memcpy(key.data, n.leaf.signature_key.data, min(n.leaf.signature_key.count, mls.NPK));
		table_set(*s.roster, uid, key);
	}
}

sender_base_secret :: (g: *mls.Group, uid: u64) -> [16]u8 {
	out: [16]u8;
	ctx: [8]u8;
	for i: 0..7 ctx[i] = cast(u8) (uid >> (8 * cast(u64) i)); // little endian
	mls.exporter(g, EXPORT_LABEL, ctx, out);
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
			if flag_invalid(s, tid) init_epoch(s, s.protocol_version);
			return;
		}
		adopt(s, g, tid);
		return;
	}
	if !s.current return; // unestablished and not ours: a welcome follows
	ng, err := mls.group_process_commit(s.current, commit);
	if err == .None && !valid_roster(ng) {
		mls.group_destroy(ng);
		err = .Verify;
	}
	if err != .None {
		if flag_invalid(s, tid) init_epoch(s, s.protocol_version);
		return;
	}
	drop_outbound(s);
	adopt(s, ng, tid);
}

// on_welcome: op 30 (transition id, Welcome).
on_welcome :: (s: *Session, tid: int, welcome: []u8) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	if s.current || !s.kp_msg.data return;
	g, err := mls.group_join(welcome, .{key_package = *s.kp, secrets = *s.kp_secrets, sig_priv = s.identity.sig_priv});
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
	if refuse_downgrade(s, version, false) return;
	table_set(*s.transitions, tid, version);
	if version == 0 s.passthrough_forever = true; // receive side accepts plain frames
	if tid == 0 execute_locked(s, 0, version);
	else push(s, .{op = OP_READY_FOR_TRANSITION, transition_id = tid});
}

on_execute_transition :: (s: *Session, tid: int) {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	ok, version := table_find(*s.transitions, tid);
	execute_locked(s, tid, ifx ok then version else s.protocol_version);
}

execute_locked :: (s: *Session, tid: int, version: int) {
	table_remove(*s.transitions, tid);
	now := s.now_ms();
	s.protocol_version = version;
	if version == 0 {
		if s.send_active ratchet_destroy(*s.send_ratchet);
		s.send_active = false;
		s.passthrough_forever = true;
		return;
	}
	g := s.current;
	if !g && tid == 0 && s.pending {
		// sole member reset: switch to the local one-member group
		g = s.pending;
		set_roster(s, g);
	}
	if !g return;
	// sender switches to the new epoch's key
	if s.send_active ratchet_destroy(*s.send_ratchet);
	base := sender_base_secret(g, s.self_user);
	ratchet_init(*s.send_ratchet, base);
	s.send_active = true;
	s.send_nonce = 0;
	s.send_epoch = mls.epoch(g);
	// previous receive keys expire in 10 s
	for * d: s.decryptors for * c: d.cryptors {
		if c.epoch != s.send_epoch && c.expiry_ms == 0 c.expiry_ms = now + RATCHET_RETENTION_MS;
	}
	if s.passthrough_forever {
		s.passthrough_forever = false;
		s.passthrough_until = now + RATCHET_RETENTION_MS;
	}
	s.executed_epoch = mls.epoch(g);
	s.executed_auth = mls.epoch_authenticator(g);
	s.has_executed = true;
}

// ---------------------------------------------------------------------------
// Media

MAX_SUPPLEMENTAL :: TAG_SIZE + 5 + 1 + 2;

// session_encrypt: out must hold frame.count + MAX_SUPPLEMENTAL. Returns the
// frame to send (encrypted, or passthrough when DAVE is not active).
session_encrypt :: (s: *Session, frame: []u8, out: []u8) -> int {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	if !s.send_active {
		// libdave encryptor: plain frames only in passthrough (protocol 0);
		// with E2EE negotiated but no key yet, media is dropped
		if s.protocol_version != 0 return 0;
		memcpy(out.data, frame.data, frame.count);
		s.stats.passthrough_out += 1;
		return frame.count;
	}
	nonce := s.send_nonce;
	s.send_nonce += 1;
	key, ok := ratchet_get(*s.send_ratchet, nonce >> 24);
	if !ok return 0;
	s.stats.encrypted += 1;
	return encrypt_opus_frame(key, nonce, frame, out);
}

// session_decrypt: out must hold frame.count.
session_decrypt :: (s: *Session, user: u64, frame: []u8, out: []u8) -> int, Decrypt_Result {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	passthrough_ok := s.passthrough_forever || s.now_ms() < s.passthrough_until;
	// the Opus silence frame the SFU may synthesize is always allowed through
	if frame.count == 3 && frame[0] == 0xF8 && frame[1] == 0xFF && frame[2] == 0xFE {
		memcpy(out.data, frame.data, 3);
		return 3, .Passthrough;
	}
	p, is_protocol := parse_protocol_frame(frame);
	if !is_protocol {
		if passthrough_ok {
			memcpy(out.data, frame.data, frame.count);
			s.stats.passthrough_in += 1;
			return frame.count, .Passthrough;
		}
		s.stats.decrypt_failures += 1;
		return 0, .Failed;
	}
	d := table_find_pointer(*s.decryptors, user);
	if d {
		now := s.now_ms();
		for < i: 0..d.cryptors.count-1 {
			c := *d.cryptors[i];
			if c.expiry_ms != 0 && c.expiry_ms < now continue;
			if !replay_check(*c.window, p.nonce) continue;
			key, kok := ratchet_get(*c.ratchet, p.nonce >> 24);
			if !kok continue;
			m, ok := decrypt_frame(key, *p, out);
			if ok {
				replay_mark(*c.window, p.nonce);
				s.stats.decrypted += 1;
				return m, .Ok;
			}
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
	privacy_code: string; // 30 digits, "" when not encrypted; context.allocator
	members: int;
	stats: Stats;
}

session_status :: (s: *Session) -> Status {
	st: Status;
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	st.protocol_version = s.protocol_version;
	st.e2ee_active = s.send_active;
	st.epoch = s.executed_epoch;
	st.members = s.roster.count;
	st.stats = s.stats;
	if s.has_executed && s.send_active st.privacy_code = privacy_code(s.executed_auth);
	return st;
}

// session_verification_code: 45-digit pairwise code with another member, in
// context.allocator (scrypt; takes ~100 ms). ok=false if the user is not in the group.
session_verification_code :: (s: *Session, user: u64) -> string, bool {
	locks.lock(*s.mu);
	has, their := table_find(*s.roster, user);
	mine := s.identity.sig_pub;
	self := s.self_user;
	locks.unlock(*s.mu);
	if !has return "", false;
	fp := pairwise_fingerprint(self, mine, user, their);
	code, ok := verification_code(fp);
	return code, ok;
}

session_user_ids :: (s: *Session) -> []u64 {
	locks.lock(*s.mu);
	defer locks.unlock(*s.mu);
	out := NewArray(s.roster.count, u64, false);
	i := 0;
	for v, k: s.roster { out[i] = k; i += 1; }
	return out;
}
